defmodule Ainalrami.TeamCLITest do
  @moduledoc """
  The standalone CLI on team events: `-g --team=...` writes a TRF26 team
  event that `-c` passes, `-p` pairs the next round team against team (a
  C.04.6 Swiss with `Ainalrami.TeamPairing`, a round robin by the Berger
  tables) in the documented format, `-x` explains it, and the options the
  team path does not have are refused. The large run is
  `tools/team_cli_corpus.exs`.
  """
  # Not async: `capture_io(:stderr, ...)` captures the whole VM's standard
  # error, and the DIFFERS warnings these files provoke on purpose would land
  # in an async neighbour's capture (team_replay_test refutes "DIFFERS").
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{Berger, CLI, TeamGenerator, TeamReplay, Trf}

  defp tmp(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_team_cli_#{System.unique_integer([:positive])}_#{name}"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  defp write(text) do
    path = tmp("in.trf")
    File.write!(path, text)
    path
  end

  # The file as it stood before round `k` was paired: earlier rounds, round
  # k's announced byes and its `300` lineups.
  defp cut(text, k) do
    parsed = Trf.parse(text)

    players =
      Enum.map(parsed.players, fn p ->
        earlier = Enum.take(p.games, k - 1)

        games =
          case Enum.at(p.games, k - 1) do
            %{opponent_rank: nil, result: "Z"} = g -> earlier ++ [g]
            _ -> earlier
          end

        %{p | games: games, points: 0.0}
      end)

    t = parsed.tournament

    t =
      t
      |> Map.drop([:standings_order, :tie_breaks, :byes])
      |> Map.update(:forfeited_matches, nil, fn l -> l && Enum.filter(l, &(&1.round < k)) end)
      |> Map.update(:board_orders, nil, fn l -> l && Enum.filter(l, &(&1.round <= k)) end)
      |> Map.update(:team_pab, nil, fn p -> p && %{p | teams: Enum.take(p.teams, k - 1)} end)
      |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
      |> Map.new()

    teams = Enum.map(parsed.teams, &Map.put(&1, :final_rank, nil))
    Trf.serialize(%{parsed | players: players, tournament: t, teams: teams}, dialect: :trf26)
  end

  defp pairs_of(output) do
    [count | rest] = String.split(output, "\r\n", trim: true)

    rest
    |> Enum.take(String.to_integer(count))
    |> Enum.map(fn line ->
      [a, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
      {a, b}
    end)
  end

  describe "-g --team=swiss" do
    test "writes a TRF26 team Swiss that -c passes, the seed printed and repeatable" do
      out_path = tmp("gen.trf")
      {err, code} = cli(["-g", out_path, "--team=swiss", "--seed=42", "--teams=9"])
      assert code == 0, err
      assert err =~ "seed 42"

      text = File.read!(out_path)
      assert text =~ "\r\n192 FIDE_TEAM_"
      assert text =~ "\r\n310 "
      assert text =~ "\r\n362 "
      assert text =~ "\r\n320 "
      assert text =~ "\r\n152 "
      assert length(Trf.parse(text).teams) == 9

      again = tmp("again.trf")
      {_, 0} = cli(["-g", again, "--team=swiss", "--seed=42", "--teams=9"])
      assert File.read!(again) == text

      {out, code} = cli([out_path, "-c"])
      assert code == 0, out
      assert out =~ "round(s) match this engine's own pairing"
    end

    test "the C.04.6 settings become the 192 code" do
      for {flags, code} <- [
            {["--team-type=b", "--score=gp", "--secondary=yes"], "FIDE_TEAM_TYPEB_GP_MP"},
            {["--team-type=none", "--score=mp", "--secondary=no"], "FIDE_TEAM_MP"},
            {["--team-type=a", "--score=mp", "--secondary=yes"], "FIDE_TEAM_TYPEA_MP_GP"}
          ] do
        path = tmp("code.trf")
        {err, 0} = cli(["-g", path, "--team=swiss", "--seed=3"] ++ flags)
        text = File.read!(path)
        assert text =~ "\r\n192 #{code}\r\n", err

        {out, c} = cli([path, "-c"])
        assert c == 0, out
      end
    end

    test "every axis switched on still checks clean" do
      for seed <- 1..6 do
        path = tmp("axes.trf")

        {err, 0} =
          cli([
            "-g",
            path,
            "--team=swiss",
            "--seed=#{seed}",
            "--absent-team-pct=15",
            "--absent-player-pct=20",
            "--forfeit-pct=8",
            "--match-forfeit-pct=10",
            "--out-of-order-pct=40",
            "--pab=win",
            "--match-points=3,1,0",
            "--tie-breaks=MPTS,GPTS,EDE"
          ])

        {out, code} = cli([path, "-c"])
        assert code == 0, err <> out
        assert out =~ "standings: all"
      end
    end
  end

  describe "-p on a team Swiss" do
    test "reproduces every round the generator paired with TeamPairing directly" do
      for seed <- [5, 6, 7] do
        g =
          TeamGenerator.run(
            seed: seed,
            absent_team_pct: 10,
            absent_player_pct: 15,
            out_of_order_pct: 30
          )

        for k <- 1..g.rounds do
          path = write(cut(g.text, k))
          out = tmp("out.txt")
          {err, code} = cli([path, "-p", out, "--lineups", "--boards=#{g.boards}"])
          assert code == 0, err

          text = File.read!(out)
          pairs = pairs_of(text)
          expected = g.pairings[k]

          assert Enum.sort(Enum.reject(pairs, fn {_, b} -> b == 0 end)) ==
                   Enum.sort(expected.matches),
                 "seed #{seed} round #{k}"

          assert Enum.find_value(pairs, fn {a, b} -> if b == 0, do: a end) == expected.bye
        end
      end
    end

    test "the output: a count line, white team first, the bye as TEAM 0, then the boards" do
      g = TeamGenerator.run(seed: 11, teams: 7, rounds: 3, boards: 4, absent_team_pct: 0)
      path = write(cut(g.text, 2))
      {out, 0} = cli([path, "-p", "--lineups", "-q"])

      [count | lines] = String.split(out, "\r\n", trim: true)
      assert count == "4"
      {teams, [boards | board_lines]} = Enum.split(lines, 4)
      assert List.last(teams) =~ ~r/^\d+ 0$/
      assert boards == "12"
      assert length(board_lines) == 12

      for line <- board_lines do
        assert [_match, board, _w, _b] = String.split(line)
        assert String.to_integer(board) in 1..4
      end
    end

    test "-x explains the round: the bye, the brackets, the colours" do
      g = TeamGenerator.run(seed: 12, teams: 9, rounds: 3, absent_team_pct: 0)
      path = write(cut(g.text, 3))
      {out, code} = cli([path, "-x", "-q"])
      assert code == 0, out
      assert out =~ "Round 3"
      assert out =~ "Pairing-allocated bye (3.4): team"
      assert out =~ "Bracket 1"
      assert out =~ "Colours (Article 4)"
    end

    test "a team sitting the round out is left out of the pairing and passed as absent" do
      g = TeamGenerator.run(seed: 21, teams: 8, rounds: 2, absent_team_pct: 0)
      parsed = Trf.parse(cut(g.text, 3))

      # Team 2's players all announce a zero-point bye for round 3.
      ranks = Enum.find(parsed.teams, &(&1.number == 2)).player_ranks

      players =
        Enum.map(parsed.players, fn p ->
          if p.rank in ranks do
            blank = %{opponent_rank: nil, colour: nil, result: ""}
            padding = List.duplicate(blank, 2 - length(p.games))
            zero = %{opponent_rank: nil, colour: nil, result: "Z"}
            %{p | games: p.games ++ padding ++ [zero]}
          else
            p
          end
        end)

      parsed = %{parsed | players: players}
      history = TeamReplay.history(parsed)
      {:team, settings} = TeamReplay.system(parsed)
      next = TeamReplay.next_round(parsed, history, settings)

      assert next.round == 3
      assert next.out == [2]
      assert next.absent == [2]
      refute 2 in next.field

      path = write(Trf.serialize(parsed, dialect: :trf26))
      {out, 0} = cli([path, "-p", "-q"])
      refute Enum.any?(pairs_of(out), fn {a, b} -> 2 in [a, b] end)
    end

    test "the bye's match points come from the file (320, else 362 P)" do
      for {pab, points} <- [{:draw, 1.0}, {:win, 2.0}] do
        g =
          TeamGenerator.run(
            seed: 31,
            teams: 7,
            rounds: 1,
            pab: pab,
            match_points: {2, 1, 0},
            absent_team_pct: 0,
            score_mode: :match_points
          )

        bye = g.pairings[1].bye
        assert bye
        parsed = Trf.parse(g.text)
        history = TeamReplay.history(parsed)
        assert history[bye][1].kind == :pab
        assert history[bye][1].mp == points

        # Without the 320 record the 362 P says the same.
        parsed = %{parsed | tournament: Map.delete(parsed.tournament, :team_pab)}
        assert TeamReplay.history(parsed)[bye][1].mp == points
      end
    end

    test "an accelerated team Swiss is not paired (exit 2)" do
      g = TeamGenerator.run(seed: 2, rounds: 2)
      path = write(String.replace(g.text, ~r/192 FIDE_TEAM_\S+/, "192 FIDE_TEAM_BAKU"))
      {out, code} = cli([path, "-p"])
      assert code == 2, out
      assert out =~ "not paired"
    end
  end

  describe "team round robins" do
    test "-g --team=roundrobin writes a Berger event that -c passes" do
      for {seed, flags} <- [
            {1, []},
            {2, ["--cycles=2"]},
            {3, ["--teams=7", "--absent-team-pct=20"]}
          ] do
        path = tmp("rr.trf")
        {err, 0} = cli(["-g", path, "--team=roundrobin", "--seed=#{seed}"] ++ flags)
        text = File.read!(path)
        assert text =~ "\r\n192 BERGER_TEAM_ROUNDROBIN_G", err

        {out, code} = cli([path, "-c"])
        assert code == 0, out
        assert out =~ "Berger"
      end
    end

    test "-p gives the next round of the Berger table" do
      g = TeamGenerator.run(seed: 4, system: :round_robin, teams: 6, cycles: 1)

      for k <- 1..g.rounds do
        path = write(cut(g.text, k))
        {out, 0} = cli([path, "-p", "-q"])
        {:ok, expected, nil} = Berger.round(6, 1, k)
        assert Enum.sort(pairs_of(out)) == Enum.sort(expected)
      end

      {out, code} = cli([write(g.text), "-p"])
      assert code == 1
      assert out =~ "every round of the Berger table is paired"
    end

    test "an odd field gives the free team as TEAM 0" do
      g = TeamGenerator.run(seed: 8, system: :round_robin, teams: 5, rounds: 2)
      {out, 0} = cli([write(cut(g.text, 2)), "-p", "-q"])
      {:ok, _pairs, free} = Berger.round(5, 1, 2)
      assert {free, 0} in pairs_of(out)
    end

    test "a round with its colours reversed is flagged" do
      g =
        TeamGenerator.run(
          seed: 9,
          system: :round_robin,
          teams: 4,
          absent_team_pct: 0,
          match_forfeit_pct: 0,
          out_of_order_pct: 0
        )

      parsed = Trf.parse(g.text)

      players =
        Enum.map(parsed.players, fn p ->
          games =
            List.update_at(p.games, 1, fn
              %{colour: "w"} = game -> %{game | colour: "b"}
              %{colour: "b"} = game -> %{game | colour: "w"}
              game -> game
            end)

          %{p | games: games}
        end)

      {out, code} = cli([write(Trf.serialize(%{parsed | players: players})), "-c"])
      assert code == 1
      assert out =~ "round 2: DIFFERS in colours only"
    end

    test "a 092 round robin with no 192 whose games show teams is replayed too" do
      g = TeamGenerator.run(seed: 10, system: :round_robin, teams: 4)
      parsed = Trf.parse(g.text)
      tournament = Map.delete(parsed.tournament, :type_code)
      {out, code} = cli([write(Trf.serialize(%{parsed | tournament: tournament})), "-c"])
      assert code == 0, out
      assert out =~ "092 round robin"
    end
  end

  describe "TRF26 300 records" do
    test "round-trip through parse and serialize" do
      text =
        Trf.serialize(%{
          tournament: %{
            name: "T",
            board_orders: [%{round: 3, team: 1, opponent: 2, order: [5, 0, 12]}]
          },
          players: [],
          teams: [%{number: 1, name: "One", player_ranks: []}]
        })

      line = "300   3   1   2    5    0   12"
      assert line in String.split(text, "\r\n")
      parsed = Trf.parse(text)

      assert [%{round: 3, team: 1, opponent: 2, order: [5, 0, 12]}] =
               parsed.tournament.board_orders

      assert line in String.split(Trf.serialize(parsed), "\r\n")
    end

    test "a lineup out of roster order still reads board 1's colour" do
      g = TeamGenerator.run(seed: 13, out_of_order_pct: 100, absent_team_pct: 0)
      assert g.text =~ "\r\n300 "
      {out, code} = cli([write(g.text), "-c"])
      assert code == 0, out

      # Without the 300 records the colours of a reordered team are misread.
      stripped = g.text |> String.split("\r\n") |> Enum.reject(&String.starts_with?(&1, "300 "))
      {out, code} = cli([write(Enum.join(stripped, "\r\n")), "-c"])
      assert code == 1, out
    end
  end

  describe "options" do
    test "a team option without --team, an individual one with it, are refused" do
      {out, 1} = cli(["-g", "--teams=8"])
      assert out =~ "--teams is a team event's option"

      {out, 1} = cli(["-g", "--team=swiss", "--players=8"])
      assert out =~ "--players is an individual tournament's option"

      {out, 1} = cli(["-g", "--team=knockout"])
      assert out =~ "unknown --team"

      {out, 1} = cli(["-g", "--team=swiss", "--match-points=1,2,0"])
      assert out =~ "--match-points takes"
    end

    test "bye preferences, --force and --absent are refused on a team file" do
      g = TeamGenerator.run(seed: 14, rounds: 2)
      path = write(g.text)

      {out, 1} = cli([path, "-p", "--bye-want=3"])
      assert out =~ "individual tournament"

      {out, 1} = cli([path, "-x", "--force=1-2"])
      assert out =~ "--force is for an individual tournament"
    end

    test "--lineups is refused on an individual file" do
      {text, _seed} = Ainalrami.Generator.generate(seed: 3, players: 10, rounds: 2)
      {out, 1} = cli([write(text), "-p", "--lineups"])
      assert out =~ "--lineups is for a team event"
    end

    test "--lineups before any match needs --boards, unless 352 says" do
      g = TeamGenerator.run(seed: 15, absent_team_pct: 0)
      with_352 = cut(g.text, 1)
      assert with_352 =~ ~r/^352 [WB]+\r?$/m

      # Record 352 states the board count, so nothing has to be inferred.
      {out, 0} = cli([write(with_352), "-p", "--lineups", "-q"])
      assert out =~ "\r\n1 1 "

      # Without it, and with no match played yet, there is nothing to count.
      path = write(String.replace(with_352, ~r/^352 [^\r\n]*\r?\n/m, ""))
      {out, 1} = cli([path, "-p", "--lineups"])
      assert out =~ "--boards=N"

      {out, 0} = cli([path, "-p", "--lineups", "--boards=#{g.boards}", "-q"])
      assert out =~ "\r\n1 1 "
    end
  end

  describe "keeping teams apart (XXO team-forbidden / team-soft-pairs)" do
    defp with_line(text, line), do: String.trim_trailing(text, "\r\n") <> "\r\n" <> line <> "\r\n"

    defp round_one(extra \\ []) do
      g = TeamGenerator.run(seed: 21, teams: 16, rounds: 5, boards: 2, absent_team_pct: 0)
      text = cut(g.text, 1)
      Enum.reduce(extra, text, &with_line(&2, &1))
    end

    defp pair_file(text, flags) do
      out = tmp("out.txt")
      {err, code} = cli([write(text), "-p", out] ++ flags)
      {if(code == 0, do: pairs_of(File.read!(out)), else: err), code, err}
    end

    defp met?(pairs, a, b), do: {a, b} in pairs or {b, a} in pairs

    test "round one: the record and the flag both keep 3 and 11 apart" do
      {plain, 0, _} = pair_file(round_one(), [])
      assert met?(plain, 3, 11)

      {by_record, 0, err} = pair_file(round_one(["XXO team-forbidden 3 11 16"]), [])
      refute met?(by_record, 3, 11)
      assert err =~ "never paired (the organiser's rule, not C.04.6): [3 11 16]"

      {by_flag, 0, _} = pair_file(round_one(), ["--team-forbidden=3,11,16"])
      assert by_flag == by_record

      {soft, 0, err} = pair_file(round_one(), ["--team-soft-pairs=3,11,16"])
      assert soft == by_record
      assert err =~ "kept apart where no FIDE criterion minds"

      # Out of its rounds, the group says nothing.
      {later, 0, _} = pair_file(round_one(["XXO team-forbidden 3 11 @2-5"]), [])
      assert later == plain
    end

    test "-x shows the soft count per bracket" do
      {out, 0} = cli([write(round_one(["XXO team-soft-pairs 3 11 16"])), "-x", "-q"])
      assert out =~ "soft pairs it could not avoid: 0"
    end

    test "groups that make the round unpairable are refused, by name" do
      text = round_one(["XXO team-forbidden 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15"])
      {err, 1, _} = pair_file(text, [])
      assert err =~ "leave no legal pairing, and without them the round pairs"
      assert err =~ "lifting any one of [1 2 3 4 5 6 7 8 9 10 11 12 13 14 15] would"
    end

    test "a team number the file does not have is refused" do
      {err, 1, _} = pair_file(round_one(["XXO team-soft-pairs 3 99"]), [])
      assert err =~ "team-soft-pairs names team 99, which the file does not have"

      {err, 1, _} = pair_file(round_one(), ["--team-forbidden=3,42"])
      assert err =~ "team-forbidden names team 42"
    end

    test "-c replays with the records, and says it is not a pure FIDE check" do
      g = TeamGenerator.run(seed: 22, teams: 10, rounds: 4, absent_team_pct: 0)
      {out, 0} = cli([write(g.text), "-c"])
      refute out =~ "keeps teams apart"

      # Forbid a pair the file has playing in round 1: that round now differs.
      [{a, b} | _] = g.pairings[1].matches
      {out, 1} = cli([write(with_line(g.text, "XXO team-forbidden #{a} #{b}")), "-c"])
      assert out =~ "keeps teams apart"
      assert out =~ "round 1: DIFFERS"

      # --team-soft-pairs is -p and -x only, as --soft-pairs is.
      {out, 1} = cli([write(g.text), "-c", "--team-soft-pairs=1,2"])
      assert out =~ "--team-soft-pairs is for -p, -x"
    end

    test "the records round-trip through parse and serialize" do
      text = with_line(round_one(), "XXO team-forbidden 3 11 16")
      text = with_line(text, "XXO team-soft-pairs 1 8 @1-2")
      parsed = Trf.parse(text)
      assert parsed.tournament.team_forbidden_pairs == [[3, 11, 16]]
      assert parsed.tournament.team_soft_pairs == [{[1, 8], 1, 2}]

      again = Trf.serialize(parsed, dialect: :trf26)
      assert again =~ "\r\nXXO team-forbidden 3 11 16\r\n"
      assert again =~ ~r/\r\nXXO team-soft-pairs 1 8 @1-2\r\n/
      assert Trf.parse(again).tournament.team_soft_pairs == [{[1, 8], 1, 2}]
    end

    test "a malformed record is refused" do
      assert_raise Trf.ValidationError, ~r/team-forbidden takes two or more team numbers/, fn ->
        Trf.parse(with_line(round_one(), "XXO team-forbidden 3"))
      end
    end

    test "XXP names players, so a team Swiss refuses it rather than ignoring it" do
      {err, 1, _} = pair_file(round_one(["XXP 1 2"]), [])
      assert err =~ "XXP/260 forbidden pairs name players"
    end

    test "the team records and flags are refused where nothing pairs by them" do
      {text, _seed} = Ainalrami.Generator.generate(seed: 3, players: 10, rounds: 2)
      {out, 1} = cli([write(text), "-p", "--team-forbidden=1,2"])
      assert out =~ "--team-forbidden is for a team event"

      {out, 1} = cli([write(with_line(text, "XXO team-soft-pairs 1 2")), "-p"])
      assert out =~ "are for a team Swiss, not an individual tournament"

      rr = TeamGenerator.run(seed: 23, system: :round_robin)
      {out, 1} = cli([write(rr.text), "-p", "--team-forbidden=1,2"])
      assert out =~ "--team-forbidden is for a team Swiss, not a team round robin"

      {out, 1} = cli([write(with_line(rr.text, "XXO team-forbidden 1 2")), "-c"])
      assert out =~ "are for a team Swiss"
    end
  end
end

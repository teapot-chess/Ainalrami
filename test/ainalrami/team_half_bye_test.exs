defmodule Ainalrami.TeamHalfByeTest do
  @moduledoc """
  A team's requested half-point bye, TRF-2026's "Bye Section": in a team
  event a `240` names TEAMS ("two teams (26 and 47) getting a HPB in the
  third round", `240 H 003  026  047`), and a `299 H` is the team's value
  ("teams getting half-point-byes (type: H) don't receive TD MP and N*D
  GP"). Until 0.57.0 both were read as a player's, and `-c` refused every
  team report with such a bye in it.

  Read (`Ainalrami.Trf.parse/1`), written back (`serialize/2`), scored
  (`Ainalrami.Tiebreaks.Team.from_trf/2`), replayed (`-c`,
  `Ainalrami.TeamReplay`) and paired around (`-p`, `--half-bye-teams`);
  an individual file's `240` is untouched.
  """
  # Not async: the CLI tests capture the whole VM's standard error.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, TeamGenerator, TeamReplay, Trf}
  alias Ainalrami.Tiebreaks.Team, as: TeamEvent
  alias Ainalrami.Trf.ValidationError

  # The spec's own example: 48 teams of four boards, teams 26 and 47 take
  # a half-point bye in round 3 - generated, so every pairing in it is the
  # engine's, and the `240` then spelt exactly as the spec spells it.
  @spec_opts [
    seed: 7,
    teams: 48,
    rounds: 3,
    boards: 4,
    reserves: 0,
    absent_team_pct: 0,
    match_forfeit_pct: 0,
    half_byes: %{3 => [26, 47]}
  ]

  defp spec_run, do: TeamGenerator.run(@spec_opts)

  defp spec_file do
    %{text: text} = spec_run()
    assert text =~ "240 H 003   26   47\r\n"
    String.replace(text, "240 H 003   26   47", "240 H 003  026  047")
  end

  defp without_240(text),
    do:
      text
      |> String.split("\r\n")
      |> Enum.reject(&String.starts_with?(&1, "240"))
      |> Enum.join("\r\n")

  defp tmp(name) do
    path =
      Path.join(System.tmp_dir!(), "ainalrami_hb_#{System.unique_integer([:positive])}_#{name}")

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write(text) do
    path = tmp("in.trf")
    File.write!(path, text)
    path
  end

  # The file as it stood before round 3 was paired: rounds 1 and 2 only.
  defp before_round_3(parsed) do
    parsed
    |> Map.update!(:players, fn ps -> Enum.map(ps, &%{&1 | games: Enum.take(&1.games, 2)}) end)
    |> Map.update!(:teams, fn ts ->
      Enum.map(ts, &Map.drop(&1, [:match_points, :game_points, :final_rank]))
    end)
    |> update_in([:tournament], fn t ->
      t
      |> Map.drop([:standings_order])
      |> Map.update(:team_pab, nil, fn p -> p && %{p | teams: Enum.take(p.teams, 2)} end)
      |> Map.update(:board_orders, nil, fn l -> l && Enum.filter(l, &(&1.round < 3)) end)
    end)
  end

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  describe "reading" do
    test "the spec's 240 H 003  026  047 names teams 26 and 47, and no player" do
      text = spec_file()
      parsed = Trf.parse(text)

      assert parsed.tournament[:team_byes] == [%{type: "H", round: 3, teams: [26, 47]}]
      refute Map.has_key?(parsed, :byes)
      refute Map.has_key?(parsed.tournament, :byes)
      # Players 26 and 47 played round 3; 0.56.0 said so, and refused the file.
      assert parsed.players == Trf.parse(without_240(text)).players
    end

    test "a team's 299 H is the team's match and game points, not a player's bye" do
      %{text: text} = TeamGenerator.run(Keyword.put(@spec_opts, :half_bye_points, {0.5, 1.0}))
      assert text =~ "\r\n299 H   0.5   1.0\r\n"

      parsed = Trf.parse(text)

      assert parsed.tournament[:team_bye_points] == %{
               "H" => %{match_points: 0.5, game_points: 1.0}
             }

      refute Map.has_key?(parsed.tournament[:point_system] || %{}, :half_point_bye)

      event = TeamEvent.from_trf(parsed)
      assert %{kind: :half_bye, mp: 0.5, gp: 1.0} = event.teams[26].rounds[3]
    end

    test "without a 299 H the bye is a drawn match: TD MP and N*D GP" do
      event = spec_file() |> Trf.parse() |> TeamEvent.from_trf()

      for team <- [26, 47] do
        assert %{kind: :half_bye, opponent: nil, mp: 1.0, gp: 2.0} = event.teams[team].rounds[3]
      end

      # Everybody else in round 3 was paired.
      refute Enum.any?(event.teams, fn {id, t} ->
               id not in [26, 47] and t.rounds[3].kind == :half_bye
             end)
    end

    test "a 240 naming a team the file does not have is refused" do
      text = String.replace(spec_file(), "240 H 003  026  047", "240 H 003  026  049")
      assert_raise ValidationError, ~r/names team 49/, fn -> Trf.parse(text) end
    end

    test "a 240 for a round the file pairs the team in is refused" do
      text = String.replace(spec_file(), "240 H 003  026  047", "240 H 002  026")
      assert_raise ValidationError, ~r/team 26 a H bye in round 2/, fn -> Trf.parse(text) end
    end

    test "an individual file's 240 still names players, 013 team lines or not" do
      base = File.read!("test/fixtures/future_bye/announced-full-bye-trf26.trf")

      no_code =
        String.replace(base, "192 FIDE_DUTCH_2025\n", "")
        |> String.replace("192 FIDE_DUTCH_2025\r\n", "")

      refute no_code =~ "192"

      team_013 =
        "013 Club A                             1    2    3\r\n" <>
          "013 Club B                             4    5    6\r\n"

      for text <- [
            base,
            no_code <> team_013,
            base <> "310   1 Club A" <> String.duplicate(" ", 60) <> "   1    2\r\n"
          ] do
        parsed = Trf.parse(text)
        six = Enum.find(parsed.players, &(&1.rank == 6))
        assert parsed.tournament[:byes] == [%{type: "F", round: 3, ranks: [6]}]
        assert %{result: "F", opponent_rank: nil} = List.last(six.games)
        refute Map.has_key?(parsed.tournament, :team_byes)
      end
    end
  end

  describe "writing" do
    test "team 240 and 299 H round-trip in both dialects" do
      %{text: text} = TeamGenerator.run(Keyword.put(@spec_opts, :half_bye_points, {0.5, 1.0}))
      parsed = Trf.parse(text)

      for dialect <- [:trf26, :engine] do
        written = Trf.serialize(parsed, dialect: dialect)
        assert written =~ "\r\n240 H 003   26   47\r\n"
        assert written =~ "\r\n299 H   0.5   1.0\r\n"

        back = Trf.parse(written)
        assert back.tournament[:team_byes] == parsed.tournament[:team_byes]
        assert back.tournament[:team_bye_points] == parsed.tournament[:team_bye_points]
        assert back.players == parsed.players
      end
    end

    test "a player's announced bye in a team event stays in the column, not a 240" do
      parsed = Trf.parse(spec_file())

      # Before round 3: rounds 1-2, team 26's players announced absent.
      roster26 = Enum.at(parsed.teams, 25).player_ranks
      z = %{opponent_rank: nil, colour: nil, result: "Z"}

      cut =
        parsed
        |> before_round_3()
        |> update_in([:tournament], &Map.delete(&1, :team_byes))
        |> Map.update!(:players, fn ps ->
          Enum.map(ps, &if(&1.rank in roster26, do: %{&1 | games: &1.games ++ [z]}, else: &1))
        end)

      written = Trf.serialize(cut, dialect: :trf26)
      refute written =~ ~r/^240/m
      back = Trf.parse(written)
      roster = Enum.at(back.teams, 25).player_ranks
      assert Enum.all?(back.players, &(&1.rank in roster == (length(&1.games) == 3)))
    end

    test "a player's own F/H value cannot be written into a team event" do
      parsed = Trf.parse(spec_file())

      bad =
        put_in(
          parsed.tournament[:point_system],
          Map.put(Trf.default_point_system(), :half_point_bye, 0.0)
        )

      assert_raise ValidationError, ~r/team_bye_points/, fn ->
        Trf.serialize(bad, dialect: :trf26)
      end
    end
  end

  describe "replaying (-c) and pairing (-p)" do
    test "-c replays the spec's example: every round is the engine's" do
      {out, code} = cli([write(spec_file()), "-c"])
      assert code == 0, out
    end

    test "the half-point bye is not a pairing: no opponent, no colour, no float, no PAB, no arrival" do
      parsed = Trf.parse(spec_file())
      history = TeamReplay.history(parsed)

      assert %{kind: :half_bye, opponent: nil, colour: nil, played?: false, mp: 1.0} =
               history[26][3]

      {pairs, bye} = TeamReplay.recorded(history, 3)
      refute Enum.any?(pairs, fn {w, b, _} -> 26 in [w, b] or 47 in [w, b] end)
      refute bye in [26, 47]

      field = TeamReplay.team_numbers(parsed)
      {teams, absent} = TeamReplay.state_for(history, 4, %{score_mode: :match_points}, field)
      t26 = Enum.find(teams, &(&1.tpn == 26))
      assert t26.had_pab? == false
      assert t26.won_by_forfeit? == false
      assert t26.floated_last_round? == false
      assert length(t26.opponents) == 2
      assert absent == []
    end

    test "-p leaves out a team a 240 names for the next round - and --half-bye-teams says the same" do
      run = spec_run()
      parsed = Trf.parse(spec_file())

      # The file as it stood before round 3: rounds 1 and 2, and the 240.
      cut = before_round_3(parsed)
      with_240 = Trf.serialize(cut, dialect: :trf26)
      assert with_240 =~ "\r\n240 H 003   26   47\r\n"

      without =
        Trf.serialize(update_in(cut.tournament, &Map.delete(&1, :team_byes)), dialect: :trf26)

      expected =
        run.pairings[3].matches
        |> Enum.map(fn {w, b} -> "#{w} #{b}" end)
        |> Kernel.++(if b = run.pairings[3].bye, do: ["#{b} 0"], else: [])
        |> Enum.sort()

      for args <- [
            [write(with_240), "-p", "-q"],
            [write(without), "-p", "-q", "--half-bye-teams=26,47"]
          ] do
        {out, code} = cli(args)
        assert code == 0, out
        [_count | lines] = out |> String.split(["\r\n", "\n"], trim: true)
        assert Enum.sort(lines) == expected
      end
    end

    test "--half-bye-teams is refused where it means nothing" do
      file = write(spec_file())
      {out, code} = cli([file, "-p", "--half-bye-teams=49"])
      assert code != 0 and out =~ "team 49"

      {_out, code} = cli([file, "-p", "--half-bye-teams=3", "--absent-teams=3"])
      assert code != 0

      {text, _seed} = TeamGenerator.generate(seed: 3, system: :round_robin, teams: 4)
      {_out, code} = cli([write(text), "-p", "--half-bye-teams=2"])
      assert code != 0

      {_out, code} =
        cli([
          write(File.read!("test/fixtures/future_bye/announced-full-bye-trf26.trf")),
          "-p",
          "--half-bye-teams=2"
        ])

      assert code != 0
    end

    # Generated events with random half-point byes, some worth something
    # other than a drawn match: `-c`'s replay reproduces every round the
    # generator paired with the engine directly.
    test "random team Swiss events with half-point byes replay round for round" do
      results =
        for seed <- 1..30 do
          opts = [seed: seed, half_bye_team_pct: 15, teams: 6 + rem(seed, 9), rounds: 5]
          opts = if rem(seed, 3) == 0, do: [{:half_bye_points, {0.5, 1.0}} | opts], else: opts
          run = TeamGenerator.run(opts)
          parsed = Trf.parse(run.text)
          {:team, settings} = TeamReplay.system(parsed)
          history = TeamReplay.history(parsed)
          {colour, _} = TeamReplay.initial_colour(history, parsed.tournament, settings)

          for r <- 1..run.rounds//1 do
            assert {:ok, _} =
                     TeamReplay.check_round(history, r, settings,
                       initial_colour: colour,
                       expected_rounds: run.planned
                     ),
                   "seed #{seed} round #{r}"
          end

          # A half-point bye keeps the team's claim to the PAB ([C2], 2.1.2).
          for {r, %{bye: bye}} <- run.pairings,
              bye != nil,
              {earlier, %{half_byes: half}} <- run.pairings,
              earlier < r,
              bye in half,
              do: {seed, bye}
        end

      assert List.flatten(results) != [], "no half-bye team ever got the PAB later"
    end
  end
end

defmodule Ainalrami.TeamReplayTest do
  @moduledoc """
  `ainalrami -c` on team files: a team Swiss is replayed with the C.04.6
  engine (`Ainalrami.TeamReplay`), a deliberately altered pairing or colour
  is flagged, and a team system that cannot be replayed exits 2.

  The Swiss files come from `Ainalrami.TeamTrfGenerator` with
  `pairing: :engine`, which pairs every round with `Ainalrami.TeamPairing`
  itself - so a clean file must check clean, and an edit to one round must
  be found in that round.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, TeamReplay, TeamTrfGenerator, Trf}

  defp check(text) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_team_replay_#{System.unique_integer([:positive])}.trf"
      )

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)

    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run([path, "-c"])) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  defp swiss(seed, opts) do
    TeamTrfGenerator.generate(seed, [selector: 0, pairing: :engine] ++ opts)
  end

  # A generated Swiss with at least `min` rounds, from the first seed that
  # gives one.
  defp swiss_with_rounds(seed, min, opts \\ []) do
    Stream.iterate(seed, &(&1 + 1))
    |> Stream.map(&swiss(&1, opts))
    |> Enum.find(&(&1.rounds >= min))
  end

  describe "a C.04.6 Swiss paired by the engine checks clean" do
    for {seed, opts} <- [
          {1, []},
          {2, []},
          {3, [type: :b]},
          {4, [type: :b]},
          {5, [score_mode: :game_points]},
          {6, [initial_colour: :black]},
          {7, [type: :b, initial_colour: :black]},
          {8, [score_mode: :game_points, type: :b]},
          {11, []},
          {12, [initial_colour: :black]},
          {13, []},
          {14, [type: :b]},
          {15, [type: :none]},
          {16, [type: :none]},
          {17, [type: :none, score_mode: :game_points]},
          {18, [type: :none, initial_colour: :black]}
        ] do
      test "seed #{seed} #{inspect(opts)}" do
        gen = swiss(unquote(seed), unquote(opts))
        {out, code} = check(gen.text)

        assert code == 0, out
        assert out =~ "#{gen.rounds}/#{gen.rounds} round(s) match this engine's own pairing"
        assert out =~ "C.04.6"
      end
    end

    test "a no-preference code is replayed without preferences, not as Type A" do
      # Seed 15 paired with no colour preferences, as FIDE_TEAM_MP_GP says.
      # Read as Type A - this module's reading until 2026-09-27 - one of its
      # rounds differs (20 of seeds 15-60 did, 2026-09-27).
      gen = swiss(15, type: :none)
      assert gen.text =~ "192 FIDE_TEAM_MP_GP"

      {out, code} = check(gen.text)
      assert code == 0, out
      assert out =~ "no colour preferences, match points primary, game points for colours"

      {out, code} =
        check(String.replace(gen.text, "192 FIDE_TEAM_MP_GP", "192 FIDE_TEAM_TYPEA_MP_GP"))

      assert code == 1, out
      assert out =~ "DIFFERS"
    end

    test "with no 152, the initial colour is the one round 1 shows" do
      gen = swiss_with_rounds(20, 2, initial_colour: :black)
      parsed = Trf.parse(gen.text)
      text = Trf.serialize(%{parsed | tournament: Map.delete(parsed.tournament, :initial_colour)})

      {out, code} = check(text)
      assert code == 0, out
      assert out =~ "initial colour black (no 152 in the file"
    end

    test "with no 192 and 013 team records instead of 310, the games show a team event" do
      gen = swiss_with_rounds(30, 2)
      parsed = Trf.parse(gen.text)

      text =
        Trf.serialize(%{
          parsed
          | tournament: Map.delete(parsed.tournament, :type_code),
            teams: Enum.map(parsed.teams, &Map.take(&1, [:name, :player_ranks]))
        })

      assert text =~ "\n013 "
      refute text =~ "\n310 "

      {out, code} = check(text)
      assert code == 0, out
      assert out =~ "no 192: the C.04.6 defaults"
    end
  end

  describe "an altered file is flagged" do
    test "two matches of one round with their opponents exchanged" do
      gen = swiss_with_rounds(40, 3)
      parsed = Trf.parse(gen.text)
      history = TeamReplay.history(parsed)
      {[{a, b, _}, {c, d, _} | _], _bye} = TeamReplay.recorded(history, 2)

      altered = exchange_opponents(parsed, 2, {a, b}, {c, d})
      {out, code} = check(Trf.serialize(altered))

      assert code == 1
      assert out =~ "round 1: matches"
      assert out =~ "round 2: DIFFERS\n"
      assert out =~ "{#{a}, #{d}}"
    end

    test "one match of one round with its colours reversed" do
      gen = swiss_with_rounds(50, 3)
      parsed = Trf.parse(gen.text)
      history = TeamReplay.history(parsed)
      {[{a, b, true} | _], _bye} = TeamReplay.recorded(history, 3)

      altered = reverse_colours(parsed, 3, [a, b])
      {out, code} = check(Trf.serialize(altered))

      assert code == 1
      assert out =~ "round 2: matches"
      assert out =~ "round 3: DIFFERS in colours only"
      assert out =~ "[{#{b}, #{a}}]"
    end
  end

  describe "a team system this checker cannot replay" do
    for {selector, what} <- [{8, "Scheveningen"}, {9, "Schiller"}] do
      test "a team #{what} exits 2 and says why" do
        gen = TeamTrfGenerator.generate(100 + unquote(selector), selector: unquote(selector))
        {out, code} = check(gen.text)

        assert code == 2, out
        assert out =~ "rounds: not replayed"
        assert out =~ "exit code 2"
        refute out =~ "DIFFERS"
      end
    end

    test "FIDE_DUBOV is replayed by the Dubov system, so a Dutch-paired file differs" do
      {out, exit_code} = check(individual([], "FIDE_DUBOV"))
      assert exit_code == 1, out
      assert out =~ "the Dubov system (C.04.4.1)"
      assert out =~ "DIFFERS"
    end

    for code <- ~w(FIDE_TEAM_BAKU FIDE_TEAM_TYPEA_MP_GP_BAKU CUSTOM_TEAM_SWISS_MP) do
      test "#{code} exits 2" do
        gen = swiss_with_rounds(60, 2)
        parsed = Trf.parse(gen.text)

        text =
          Trf.serialize(%{
            parsed
            | tournament: Map.put(parsed.tournament, :type_code, unquote(code))
          })

        {out, exit_code} = check(text)
        assert exit_code == 2, out
        assert out =~ "rounds: not replayed - #{unquote(code)}"
      end
    end

    test "a standings difference still exits 1" do
      gen = TeamTrfGenerator.generate(108, selector: 8)
      parsed = Trf.parse(gen.text)

      teams =
        parsed.teams
        |> Enum.with_index(1)
        |> Enum.map(fn {t, i} -> Map.put(t, :final_rank, length(parsed.teams) + 1 - i) end)

      text =
        Trf.serialize(%{
          parsed
          | teams: teams,
            tournament: Map.put(parsed.tournament, :standings_order, ~w(MPTS))
        })

      {out, code} = check(text)
      assert out =~ "rounds: not replayed"

      # Reversed ranks follow MPTS only if every team is level.
      if out =~ "do not follow", do: assert(code == 1), else: assert(code == 2)
    end
  end

  describe "system/1" do
    defp sys(code, teams \\ [%{name: "T", player_ranks: [1]}], players \\ []) do
      TeamReplay.system(%{
        tournament: %{type_code: code},
        teams: teams,
        players: players
      })
    end

    # Every C.04.6 code of TRF26's Tournament Type Code Table (FIDE TEC):
    # TYPEA/TYPEB the colour preferences, NEITHER "no colour preferences";
    # X_Y X primary and Y for colours, a single X "secondary score not used".
    test "reads every team Swiss code's settings as FIDE's table gives them" do
      for {type, prefix} <- [a: "TYPEA_", b: "TYPEB_", none: ""],
          {scores, mode, secondary?} <- [
            {"MP_GP", :match_points, true},
            {"GP_MP", :game_points, true},
            {"MP", :match_points, false},
            {"GP", :game_points, false}
          ] do
        code = "FIDE_TEAM_" <> prefix <> scores

        assert {:team,
                %{type: ^type, score_mode: ^mode, use_secondary?: ^secondary?, code: ^code}} =
                 sys(code),
               code
      end

      # The two shorthands: FIDE_TEAM is FIDE_TEAM_TYPEA_MP_GP.
      assert {:team, %{type: :a, score_mode: :match_points, use_secondary?: true}} =
               sys("FIDE_TEAM")

      assert {:team, %{type: :none}} = sys("fide_team_mp_gp")
    end

    test "the Dutch system keeps the individual replay, team records or not" do
      for code <- ~w(FIDE_DUTCH FIDE_DUTCH_2017 FIDE_DUTCH_2025 FIDE_DUTCH_2026) do
        assert sys(code) == :individual, code
        assert sys(code, []) == :individual, code
      end

      assert sys(nil, []) == :individual
    end

    test "a Baku Dutch file is replayed only with its virtual points" do
      accelerated = [%{rank: 1, accelerations: [1.0, 0.5, 0.0]}, %{rank: 2}]

      for code <- ~w(FIDE_DUTCH_BAKU FIDE_DUTCH_2017_BAKU FIDE_DUTCH_2025_BAKU) do
        assert {:unreplayable, reason} = sys(code, [])
        assert reason =~ "no virtual points", code
        assert sys(code, [], accelerated) == :individual, code
      end
    end

    test "predetermined, other, custom and accelerated systems are not replayed" do
      for code <-
            ~w(CUSTOM_TEAM_ROUNDROBIN FIDE_SCHEVENINGEN FIDE_SCHEVENINGEN_G2 FIDE_DOUBLESCHEVENINGEN
               CUSTOM_SCHEVENINGEN FIDE_SCHILLER FIDE_SCHILLER_4x2 CUSTOM_SCHILLER
               CUSTOM_TEAM_KNOCKOUT CUSTOM_KNOCKOUT CUSTOM_TEAM_SWISS CUSTOM_TEAM_SWISS_MP
               CUSTOM_TEAM_SWISS_GP FIDE_TEAM_BAKU FIDE_TEAM_MP_BAKU FIDE_TEAM_MP_GP_BAKU
               FIDE_TEAM_TYPEA_MP_GP_BAKU FIDE_TEAM_TYPEB_MP_BAKU CUSTOM_ROUNDROBIN
               FIDE_DUBOV FIDE_DUBOV_BAKU FIDE_BURSTEIN FIDE_BURSTEIN_BAKU CUSTOM_SWISS
               FIDE_DOUBLESWISS FIDE_DOUBLESWISS_BAKU CUSTOM_DOUBLESWISS),
          teams <- [[%{name: "T", player_ranks: [1]}], []] do
        assert {:unreplayable, reason} = sys(code, teams), code
        assert String.starts_with?(reason, code), reason
      end
    end

    test "a team round robin code is replayed by the Berger tables, its cycles from the code" do
      for {code, games} <- [
            {"FIDE_TEAM_ROUNDROBIN", 1},
            {"BERGER_TEAM_ROUNDROBIN", 1},
            {"BERGER_TEAM_ROUNDROBIN_G1", 1},
            {"FIDE_TEAM_DOUBLEROUNDROBIN", 2},
            {"BERGER_TEAM_DOUBLEROUNDROBIN", 2},
            {"BERGER_TEAM_ROUNDROBIN_G3", 3}
          ] do
        assert {:team_round_robin, %{games: ^games}} = sys(code), code
        assert {:unreplayable, reason} = sys(code, []), code
        assert reason =~ "no team records"
      end
    end

    test "a team Swiss code on a file with no team records is not replayed" do
      assert {:unreplayable, reason} = sys("FIDE_TEAM", [])
      assert reason =~ "no team records"
    end

    test "a code off the table falls back to the file's type and games" do
      assert sys("FIDE_DUTCH_2022", []) == :individual

      assert {:round_robin, %{code: nil}} =
               TeamReplay.system(%{
                 tournament: %{type_code: "RR", type: "Individual: Round Robin System"},
                 teams: [],
                 players: []
               })
    end
  end

  describe "individual files and their 192 code" do
    defp individual(opts, code) do
      {text, _seed} = Ainalrami.Generator.generate([seed: 11, players: 14, rounds: 5] ++ opts)
      parsed = Trf.parse(text)

      tournament =
        if code, do: Map.put(parsed.tournament, :type_code, code), else: parsed.tournament

      Trf.serialize(%{parsed | tournament: tournament})
    end

    test "a custom round robin, a Schiller, a knockout or a non-Dutch Swiss exits 2, not 1" do
      for code <-
            ~w(CUSTOM_ROUNDROBIN FIDE_SCHILLER_4x3 FIDE_SCHEVENINGEN CUSTOM_KNOCKOUT CUSTOM_SWISS
               FIDE_DOUBLESWISS) do
        {out, exit_code} = check(individual([], code))
        assert exit_code == 2, "#{code}: #{out}"
        assert out =~ "rounds: not replayed - #{code}"
        refute out =~ "DIFFERS"
      end
    end

    test "a Swiss file labelled a round robin (092, no 192) is checked against the Berger table" do
      {text, _seed} = Ainalrami.Generator.generate(seed: 12, players: 10, rounds: 4)
      parsed = Trf.parse(text)
      tournament = Map.put(parsed.tournament, :type, "Individual: Round Robin System")

      {out, exit_code} = check(Trf.serialize(%{parsed | tournament: tournament}))
      assert exit_code == 1, out
      assert out =~ "DIFFERS from the Berger table"
    end

    test "the Dutch codes replay, the 2017 edition with a warning" do
      for code <- ~w(FIDE_DUTCH FIDE_DUTCH_2025 FIDE_DUTCH_2026) do
        {out, exit_code} = check(individual([], code))
        assert exit_code == 0, "#{code}: #{out}"
        refute out =~ "2017 edition"
      end

      {out, exit_code} = check(individual([], "FIDE_DUTCH_2017"))
      assert exit_code == 0, out
      assert out =~ "2017 edition"
    end

    test "FIDE_DUTCH is the 2017 edition for an event that started before 1 July 2025" do
      {text, _seed} = Ainalrami.Generator.generate(seed: 11, players: 14, rounds: 5)
      parsed = Trf.parse(text)

      tournament =
        parsed.tournament
        |> Map.put(:type_code, "FIDE_DUTCH")
        |> Map.put(:start_date, "2025/03/14")

      {out, _exit_code} = check(Trf.serialize(%{parsed | tournament: tournament}))
      assert out =~ "2017 edition"
    end

    test "a Baku file replays with its virtual points and exits 2 without them" do
      {out, exit_code} = check(individual([acceleration: :baku], "FIDE_DUTCH_2025_BAKU"))
      assert exit_code == 0, out
      assert out =~ "Baku acceleration"

      {out, exit_code} = check(individual([], "FIDE_DUTCH_BAKU"))
      assert exit_code == 2, out
      assert out =~ "no virtual points"
    end

    test "a code off the table is said to be one and replayed as the Dutch system" do
      # `Trf.serialize/2` refuses to write such a code, so it is put in by
      # hand, as another program would have.
      text =
        Regex.replace(~r/^012 [^\n]*\n/, individual([], nil), &(&1 <> "192 FIDE_DUTCH_2022\r\n"))

      assert text =~ "\n192 FIDE_DUTCH_2022\r\n"
      {out, exit_code} = check(text)
      assert exit_code == 0, out
      assert out =~ "192 FIDE_DUTCH_2022 is not a code in FIDE's Tournament Type Code Table"
    end
  end

  test "an individual Swiss with team records keeps the individual replay" do
    {text, _seed} = Ainalrami.Generator.generate(seed: 7, players: 16, rounds: 5)
    parsed = Trf.parse(text)
    ranks = Enum.map(parsed.players, & &1.rank)

    teams =
      ranks
      |> Enum.chunk_every(4)
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, i} -> %{name: "Club #{i}", player_ranks: chunk} end)

    assert TeamReplay.system(%{parsed | teams: teams}) == :individual

    {out, code} = check(Trf.serialize(%{parsed | teams: teams}))
    assert code == 0, out
    refute out =~ "team round(s)"
  end

  # ---- editing a parsed file --------------------------------------------------

  defp roster(parsed, team) do
    Enum.find_value(Enum.with_index(parsed.teams, 1), fn {t, i} ->
      if (Map.get(t, :number) || i) == team, do: t.player_ranks
    end)
  end

  # The players of `team` who met somebody in `round`, in roster order.
  defp lineup(parsed, team, round) do
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    for rank <- roster(parsed, team),
        game = Enum.at(by_rank[rank].games, round - 1),
        game != nil and is_integer(game.opponent_rank),
        do: rank
  end

  # A-B and C-D become A-D and C-B: B's and D's players swap their round
  # games (opponent, colour, result), and A's and C's point at them.
  defp exchange_opponents(parsed, round, {a, b}, {c, d}) do
    [la, lb, lc, ld] = Enum.map([a, b, c, d], &lineup(parsed, &1, round))
    by_rank = Map.new(parsed.players, &{&1.rank, &1})
    game = fn rank -> Enum.at(by_rank[rank].games, round - 1) end

    b_to_d = Map.new(Enum.zip(lb, ld))
    d_to_b = Map.new(Enum.zip(ld, lb))

    new_games =
      Map.new(
        for(r <- la, do: {r, %{game.(r) | opponent_rank: b_to_d[game.(r).opponent_rank]}}) ++
          for(r <- lc, do: {r, %{game.(r) | opponent_rank: d_to_b[game.(r).opponent_rank]}}) ++
          for({x, y} <- Enum.zip(lb, ld), do: {x, game.(y)}) ++
          for({x, y} <- Enum.zip(lb, ld), do: {y, game.(x)})
      )

    put_round_games(parsed, round, new_games)
  end

  defp reverse_colours(parsed, round, teams) do
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    new_games =
      for team <- teams, rank <- lineup(parsed, team, round), into: %{} do
        g = Enum.at(by_rank[rank].games, round - 1)
        {rank, %{g | colour: if(g.colour == "w", do: "b", else: "w")}}
      end

    put_round_games(parsed, round, new_games)
  end

  defp put_round_games(parsed, round, new_games) do
    players =
      Enum.map(parsed.players, fn p ->
        case new_games[p.rank] do
          nil -> p
          g -> %{p | games: List.replace_at(p.games, round - 1, g)}
        end
      end)

    %{parsed | players: players}
  end
end

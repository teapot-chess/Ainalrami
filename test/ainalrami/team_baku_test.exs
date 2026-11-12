defmodule Ainalrami.TeamBakuTest do
  @moduledoc """
  C.04.7 (the Baku Acceleration Method) over a C.04.6 team Swiss: Group A
  by team number, virtual MATCH points on the pairing score only, TRF-2026
  `250` records naming teams, and the replay that reads them back. The
  reading, and which parts of it are FIDE's text: docs/team-baku.md.
  """
  # Not async: the CLI tests capture the whole VM's standard error.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{Acceleration, CLI, TeamCertificate, TeamGenerator, TeamPairing, TeamReplay}
  alias Ainalrami.{Tiebreaks, Trf}
  alias Ainalrami.TeamPairing.Team

  defp tmp(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_team_baku_#{System.unique_integer([:positive])}_#{name}"
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

  defp strip_250(text), do: String.replace(text, ~r/^250 .*\r\n/m, "")

  defp replay_all(text) do
    parsed = Trf.parse(text)
    {:team, settings} = TeamReplay.system(parsed)
    history = TeamReplay.history(parsed)
    colour = if parsed.tournament[:initial_colour] == "b", do: :black, else: :white

    for r <- 1..TeamReplay.paired_rounds(history)//1 do
      TeamReplay.check_round(history, r, settings,
        initial_colour: colour,
        expected_rounds: parsed.tournament[:number_of_rounds]
      )
    end
  end

  describe "Group A and the virtual points (Acceleration.team_baku_table/3)" do
    test "Group A is the top half of the teams, rounded up to an even number (C.04.7 1.2)" do
      for {n, last} <- [
            {2, 2},
            {3, 2},
            {4, 2},
            {5, 4},
            {6, 4},
            {7, 4},
            {8, 4},
            {9, 6},
            {11, 6},
            {178, 90}
          ] do
        table = Acceleration.team_baku_table(n, 9)
        assert table |> Map.keys() |> Enum.sort() == Enum.to_list(1..last), "#{n} teams"
      end
    end

    test "Example 2: eleven rounds on match points - 2 MP in rounds 1-3, 1 MP in 4-6" do
      row = Acceleration.team_baku_table(20, 11)[1]

      assert Enum.map(row, &elem(&1, 0)) == [
               2.0,
               2.0,
               2.0,
               1.0,
               1.0,
               1.0,
               0.0,
               0.0,
               0.0,
               0.0,
               0.0
             ]

      assert Enum.all?(row, &(elem(&1, 1) == 0.0)), "no virtual game points"
    end

    test "nine rounds: five accelerated, the first three on a win's worth" do
      row = Acceleration.team_baku_table(8, 9)[1]
      assert Enum.map(row, &elem(&1, 0)) == [2.0, 2.0, 2.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0]
    end

    test "the win's worth follows the event's match points, and only where C.04.7 1.1 allows" do
      row = Acceleration.team_baku_table(8, 5, match_points: {4, 2, 0})[1]
      assert Enum.map(row, &elem(&1, 0)) == [4.0, 4.0, 2.0, 0.0, 0.0]

      for points <- [{3, 1, 0}, {2, 1, 1}, {0, 0, 0}] do
        assert_raise ArgumentError, ~r/C.04.7 1.1/, fn ->
          Acceleration.team_baku_table(8, 5, match_points: points)
        end
      end
    end

    test ":group_a_last fixes the group a late entrant does not grow (C.04.7 1.3)" do
      assert Acceleration.team_baku_table(9, 5, group_a_last: 4) |> Map.keys() |> Enum.sort() ==
               [1, 2, 3, 4]

      assert Acceleration.team_baku_table(9, 5, group_a_last: 0) == %{}
    end

    test "acceleration ends: a round after the accelerated ones carries nothing" do
      teams = for t <- 1..8, do: %Team{tpn: t}

      for {round, expected} <- [
            {1, 2.0},
            {3, 2.0},
            {4, 1.0},
            {5, 1.0},
            {6, 0.0},
            {9, 0.0},
            {12, 0.0}
          ] do
        given = Acceleration.team_baku(teams, 9, round: round, team_count: 8)
        assert Enum.find(given, &(&1.tpn == 1)).virtual_match_points == expected, "round #{round}"
        assert Enum.find(given, &(&1.tpn == 5)).virtual_match_points == 0.0
        assert Enum.all?(given, &(&1.virtual_game_points == 0.0))
      end
    end

    test "team_baku/3 will not guess the event's size from one round's field" do
      assert_raise ArgumentError, ~r/:team_count or :group_a_last/, fn ->
        Acceleration.team_baku([%Team{tpn: 1}], 9, round: 1)
      end
    end

    test "a team already carrying virtual points is refused" do
      assert_raise ArgumentError, ~r/already carries/, fn ->
        Acceleration.team_virtual_points([%Team{tpn: 1, virtual_match_points: 1.0}], %{}, 1)
      end
    end
  end

  describe "the engine pairs on the pairing score (C.04.7 1.5)" do
    test "round 1: Group A is a scoregroup of its own" do
      teams = for t <- 1..8, do: %Team{tpn: t}

      {:ok, plain} = TeamPairing.pair_round(teams, round: 1, expected_rounds: 9)
      accelerated = Acceleration.team_baku(teams, 9, round: 1, team_count: 8)
      {:ok, baku} = TeamPairing.pair_round(accelerated, round: 1, expected_rounds: 9)

      meetings = fn result -> MapSet.new(result.pairs, &Enum.sort([&1.white, &1.black])) end

      # Group A is 1-4: they meet each other, and so does Group B.
      assert Enum.all?(meetings.(baku), fn [a, b] -> a <= 4 == b <= 4 end)
      refute meetings.(plain) == meetings.(baku)
    end

    test "virtual points never touch the real scores the engine was given" do
      teams =
        Acceleration.team_baku(for(t <- 1..6, do: %Team{tpn: t}), 7, round: 1, team_count: 6)

      assert Enum.all?(teams, &(&1.match_points == 0.0 and &1.game_points == 0.0))
      assert Team.score(hd(teams), :match_points) == 2.0
      assert Team.secondary_score(hd(teams), :match_points) == 0.0
    end

    test "an odd field: the bye goes to the lowest PAIRING score (3.4.2)" do
      # Team 3 (Group A, lost round 1) has 0 MP + 2 virtual; team 5 (Group B)
      # won round 1 and has 2 MP + 0. Without acceleration team 3 is the
      # lowest-ranked team on the lowest score; with it, team 4 is.
      teams = [
        %Team{tpn: 1, match_points: 2.0, game_points: 3.0, opponents: [2], colours: [:white]},
        %Team{tpn: 2, match_points: 0.0, game_points: 1.0, opponents: [1], colours: [:black]},
        %Team{tpn: 3, match_points: 0.0, game_points: 1.0, opponents: [5], colours: [:white]},
        %Team{tpn: 4, match_points: 0.0, game_points: 0.0, had_pab?: false, opponents: []},
        %Team{tpn: 5, match_points: 2.0, game_points: 3.0, opponents: [3], colours: [:black]}
      ]

      # Team 4 had the round-1 bye in real life, so give it 1 MP and bar it.
      teams =
        Enum.map(teams, fn
          %{tpn: 4} = t -> %{t | match_points: 1.0, game_points: 2.0, had_pab?: true}
          t -> t
        end)

      {:ok, plain} = TeamPairing.pair_round(teams, round: 2, expected_rounds: 5)
      assert plain.bye == 3

      accelerated = Acceleration.team_baku(teams, 5, round: 2, team_count: 5)
      {:ok, baku} = TeamPairing.pair_round(accelerated, round: 2, expected_rounds: 5)
      # Group A (1-4) on 4, 2, 2, (barred); team 5 alone on 2 real points.
      assert baku.bye in [2, 3, 5]
      refute baku.bye == 4
      assert Team.score(Enum.find(accelerated, &(&1.tpn == baku.bye)), :match_points) == 2.0
    end

    test "a negative or non-numeric virtual point is refused, not paired" do
      for bad <- [-1.0, nil, "2"] do
        teams = [%Team{tpn: 1, virtual_match_points: bad}, %Team{tpn: 2}]
        assert {:error, {:invalid_option, :teams, _}} = TeamPairing.pair_round(teams)
      end
    end

    test "a round without virtual points is exactly the round it always was" do
      teams = for t <- 1..6, do: %Team{tpn: t, match_points: rem(t, 3), game_points: t}

      assert TeamPairing.pair_round(teams, round: 2) ==
               TeamPairing.pair_round(Acceleration.team_virtual_points(teams, %{}, 2), round: 2)
    end
  end

  describe "TRF-2026 250 records naming teams" do
    test "written and read back, match points in 5-8 and nothing in 10-13" do
      g = TeamGenerator.run(seed: 7, teams: 10, rounds: 7, baku: true)
      lines = g.text |> String.split("\r\n") |> Enum.filter(&String.starts_with?(&1, "250"))

      # 10 teams: Group A 1-6; 7 rounds: 4 accelerated, 2 on a win's worth.
      assert lines == [
               "250  2.0        1   2    1    6",
               "250  1.0        3   4    1    6"
             ]

      assert g.text =~ ~r/\r\n192 FIDE_TEAM_\w*MP\w*_BAKU\r\n/

      parsed = Trf.parse(g.text)

      trimmed =
        Map.new(Acceleration.team_baku_table(10, 7), fn {tpn, row} ->
          {tpn, Enum.take(row, 4)}
        end)

      assert parsed.tournament[:team_accelerations] == trimmed
      assert Enum.all?(parsed.players, &(Map.get(&1, :accelerations) == nil))

      assert Trf.parse(Trf.serialize(parsed, dialect: :trf26)).tournament[:team_accelerations] ==
               parsed.tournament[:team_accelerations]
    end

    test "FIDE's own example reads as the 178-team Group A, rounds 1-3 and 4-6" do
      text =
        """
        012 Example
        192 FIDE_TEAM_BAKU
        250 00.0 02.0 001 003 0001 0090
        250 00.0 01.0 004 006 0001 0090
        """
        |> String.replace("\n", "\r\n")

      table = Trf.parse(text).tournament[:team_accelerations]
      assert table |> Map.keys() |> Enum.sort() == Enum.to_list(1..90)
      assert table[90] == [{0.0, 2.0}, {0.0, 2.0}, {0.0, 2.0}, {0.0, 1.0}, {0.0, 1.0}, {0.0, 1.0}]
    end

    test "a 250 with neither match nor game points is refused" do
      text = "192 FIDE_TEAM_BAKU\r\n250             1   3    1    4\r\n"
      assert_raise Trf.ValidationError, ~r/no fictitious points/, fn -> Trf.parse(text) end
    end

    test "an individual file's 250 is read as it always was" do
      text = "192 FIDE_DUTCH_BAKU\r\n250        1.0   1   2    1    4\r\n"
      parsed = Trf.parse(text)
      assert parsed.tournament[:team_accelerations] == nil
    end
  end

  describe "the replay (-c) and the next round (-p)" do
    test "generated Baku events replay round for round: odd and even fields, byes, absences" do
      for seed <- 1..40 do
        opts = [
          seed: seed,
          baku: true,
          teams: 5 + rem(seed, 12),
          rounds: 4 + rem(seed, 6),
          absent_team_pct: Enum.at([0, 10], rem(seed, 2)),
          half_bye_team_pct: Enum.at([0, 0, 15], rem(seed, 3))
        ]

        g = TeamGenerator.run(opts)
        results = replay_all(g.text)
        assert Enum.all?(results, &match?({:ok, _}, &1)), "seed #{seed}: #{inspect(results)}"
      end
    end

    test "a half-point team bye worth something else (299 H) replays too" do
      g =
        TeamGenerator.run(
          seed: 11,
          baku: true,
          teams: 9,
          rounds: 7,
          boards: 4,
          half_byes: %{2 => [3], 4 => [8]},
          half_bye_points: {1, 1.5}
        )

      assert g.text =~ "\r\n299 H"
      assert Enum.all?(replay_all(g.text), &match?({:ok, _}, &1))
    end

    test "-c passes a Baku event and fails it without its 250 records" do
      g = TeamGenerator.run(seed: 3, baku: true, teams: 12, rounds: 7)
      {out, code} = cli([write(g.text), "-c"])
      assert code == 0, out
      assert out =~ "virtual points for 6 teams"

      {out, code} = cli([write(strip_250(g.text)), "-c"])
      assert code == 2, out
      assert out =~ "gives no virtual points"
    end

    test "-c --acceleration=baku works the virtual points out for a file without them" do
      g = TeamGenerator.run(seed: 5, baku: true, teams: 11, rounds: 7)
      plain = String.replace(strip_250(g.text), "_BAKU\r\n", "\r\n")

      # Without them the same file is a different event, round 1 already.
      {out, code} = cli([write(plain), "-c"])
      assert code == 1, out
      assert out =~ "DIFFERS"

      {out, code} = cli([write(plain), "-c", "--acceleration=baku"])
      assert code == 0, out

      {out, code} = cli([write(g.text), "-c", "--acceleration=baku"])
      assert code != 0, out
      assert out =~ "already carries virtual points"
    end

    test "--baku-group-a names the last team of Group A" do
      g = TeamGenerator.run(seed: 9, baku: true, teams: 10, rounds: 6, baku_group_a: 4)
      assert g.text =~ "\r\n250  2.0        1   2    1    4\r\n"
      plain = String.replace(strip_250(g.text), "_BAKU\r\n", "\r\n")

      {out, code} = cli([write(plain), "-c", "--acceleration=baku", "--baku-group-a=4"])
      assert code == 0, out

      {out, code} = cli([write(plain), "-c", "--acceleration=baku", "--baku-group-a=40"])
      assert code != 0
      assert out =~ "team 40"
    end

    test "the TEC example's layout - virtual points in the game-points column - reads as match points" do
      g = TeamGenerator.run(seed: 3, baku: true, teams: 12, rounds: 7)

      moved =
        Regex.replace(~r/^250 (....) (....)/m, g.text, fn _, mp, _gp -> "250  0.0 #{mp}" end)

      assert moved =~ "\r\n250  0.0  2.0   1   2    1    6\r\n"
      assert Enum.all?(replay_all(moved), &match?({:ok, _}, &1))
    end

    test "the engine's input carries the virtual points of the round being paired" do
      g = TeamGenerator.run(seed: 21, baku: true, teams: 8, rounds: 5)
      parsed = Trf.parse(g.text)
      {:team, settings} = TeamReplay.system(parsed)
      # Before round 2 Group A carries a win's worth; before round 4, none.
      history = TeamReplay.history(parsed)
      {teams2, _} = TeamReplay.state_before(history, 2, settings)
      {teams4, _} = TeamReplay.state_before(history, 4, settings)
      assert Enum.find(teams2, &(&1.tpn == 1)).virtual_match_points == 2.0
      assert Enum.find(teams4, &(&1.tpn == 1)).virtual_match_points == 0.0
    end

    test "-x shows a team's virtual points beside its real ones" do
      g = TeamGenerator.run(seed: 4, baku: true, teams: 8, rounds: 5)
      # The file up to round 1 only: cut every player's games.
      parsed = Trf.parse(g.text)

      cut = %{
        parsed
        | players: Enum.map(parsed.players, &%{&1 | games: []}),
          tournament:
            parsed.tournament
            |> Map.delete(:team_pab)
            |> Map.delete(:forfeited_matches)
            |> Map.delete(:board_orders)
            |> Map.delete(:team_byes)
            |> Map.delete(:standings_order)
      }

      teams = Enum.map(parsed.teams, &Map.drop(&1, [:final_rank, :match_points, :game_points]))
      text = Trf.serialize(%{cut | teams: teams}, dialect: :trf26)
      {out, code} = cli([write(text), "-x"])
      assert code == 0, out
      assert out =~ "virtual +2.0 MP"
    end

    test "a GP-primary team Swiss is refused Baku (C.04.7, Example 2)" do
      g = TeamGenerator.run(seed: 2, score_mode: :game_points, teams: 6, rounds: 4)
      {out, code} = cli([write(g.text), "-c", "--acceleration=baku"])
      assert code != 0
      assert out =~ "gamepoints were the primary score"

      assert_raise ArgumentError, ~r/game points/, fn ->
        TeamGenerator.run(seed: 2, baku: true, score_mode: :game_points)
      end
    end

    test "a team round robin is refused the flag" do
      g = TeamGenerator.run(seed: 2, system: :round_robin, teams: 6)
      {out, code} = cli([write(g.text), "-c", "--acceleration=baku"])
      assert code != 0
      assert out =~ "--acceleration is not for a team round robin"

      {out, code} = cli(["-g", tmp("rr.trf"), "--team=roundrobin", "--acceleration=baku"])
      assert code != 0
      assert out =~ "team Swiss"
    end
  end

  describe "virtual points never reach the standings" do
    test "the teams' match and game points are the same with and without the 250s" do
      g = TeamGenerator.run(seed: 8, baku: true, teams: 9, rounds: 7)

      totals = fn text ->
        event = Tiebreaks.Team.from_trf(Trf.parse(text))

        Map.new(event.teams, fn {id, team} ->
          {id,
           {team.rounds |> Map.values() |> Enum.map(& &1.mp) |> Enum.sum(),
            team.rounds |> Map.values() |> Enum.map(& &1.gp) |> Enum.sum()}}
        end)
      end

      assert totals.(g.text) == totals.(strip_250(g.text))

      # And the 310 records carry the real totals.
      parsed = Trf.parse(g.text)

      for team <- parsed.teams do
        {mp, gp} = totals.(g.text)[team.number]
        assert team.match_points == mp
        assert team.game_points == gp
      end
    end
  end

  describe "the team certificate" do
    test "an accelerated round's input record carries the virtual points, and certifies" do
      teams =
        Acceleration.team_baku(for(t <- 1..8, do: %Team{tpn: t}), 7, round: 1, team_count: 8)

      opts = [round: 1, expected_rounds: 7]
      {:ok, result} = TeamPairing.pair_round(teams, opts)
      input = TeamCertificate.input(teams, opts)

      assert Enum.find(input["teams"], &(&1["tpn"] == 1))["virtual_match_points"] == 2.0
      refute Map.has_key?(Enum.find(input["teams"], &(&1["tpn"] == 8)), "virtual_match_points")

      assert {:ok, decoded, decoded_opts} = TeamCertificate.decode_input(input)
      assert TeamPairing.pair_round(decoded, decoded_opts) == {:ok, result}
      assert {:ok, _cert} = TeamCertificate.certify(input, result, String.duplicate("0", 64))
    end
  end
end

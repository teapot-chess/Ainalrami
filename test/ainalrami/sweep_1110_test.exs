defmodule Ainalrami.Sweep1110Test do
  @moduledoc """
  Sweep 2026-11: the reader's and the team engine's edges (AIN-2, AIN-3,
  AIN-4, AIN-6, AIN-7). AIN-1 has its own file,
  `dubov_upfloater_scale_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{TeamPairing, TeamReplay, Trf}
  alias Ainalrami.TeamPairing.Team
  alias Ainalrami.Tiebreaks.Team, as: TeamTiebreaks

  @fixtures Path.expand("../fixtures/sweep_2026_11", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # A `001` line in the spec's columns: rank 5-8, name 15-48, rating 49-52,
  # points 81-84, final rank 86-89, round 1 from 92.
  defp player(rank, games \\ ""), do: raw_player(String.pad_leading(to_string(rank), 4), games)

  defp raw_player(rank_field, games \\ "") do
    name = "P" <> String.trim(rank_field)

    "001 " <>
      rank_field <>
      String.duplicate(" ", 6) <>
      String.pad_trailing(name, 34) <>
      "2000" <> String.duplicate(" ", 29) <> "0.0 " <> rank_field <> games
  end

  defp file(lines), do: Enum.join(["012 Sweep", "XXR 5" | lines], "\n") <> "\n"

  describe "AIN-2: a game against a player on no team's roster" do
    test "is ignored by the tie-breaks and the replay, as read_round ignores it" do
      parsed = Trf.parse(fixture("unrostered_opponents.trf"))

      event = TeamTiebreaks.from_trf(parsed)
      assert Map.keys(event.teams) == [1]
      assert %{1 => rounds} = TeamReplay.history(parsed)
      assert Enum.all?(Map.values(rounds), &(&1.opponent == nil))
    end
  end

  describe "AIN-3: the starting rank" do
    for {label, rank} <- [zero: "   0", negative: "  -1", blank: "    "] do
      test "#{label} is refused, naming the line" do
        text = file([raw_player(unquote(rank)), player(1), player(2)])

        assert_raise Trf.ValidationError, ~r/starting rank must be 1\.\.9999/, fn ->
          Trf.parse(text)
        end
      end
    end

    test "9999 is still a rank" do
      assert [%{rank: 1}, %{rank: 9999}] = Trf.parse(file([player(1), player(9999)])).players
    end
  end

  describe "AIN-4: 300 and 330 records" do
    test "keep file order" do
      lines = for t <- 1..40, do: "330 +- #{String.pad_leading(to_string(t), 3)}   1   2"
      orders = for t <- 1..40, do: "300 #{String.pad_leading(to_string(t), 3)}   1   2    1"
      parsed = Trf.parse(file([player(1), player(2) | lines ++ orders]))

      assert Enum.map(parsed.tournament.forfeited_matches, & &1.round) == Enum.to_list(1..40)
      assert Enum.map(parsed.tournament.board_orders, & &1.round) == Enum.to_list(1..40)
    end

    # Quadratic before: 32,000 records took 13 s, so 64,000 would take
    # close to a minute. Linear, it is a fraction of a second; the timeout
    # is the assertion.
    @tag timeout: 15_000
    test "are read in linear time" do
      lines = for k <- 1..64_000, do: "300   #{rem(k, 9) + 1}   1   2    1"
      parsed = Trf.parse(file([player(1), player(2) | lines]))
      assert length(parsed.tournament.board_orders) == 64_000
    end
  end

  describe "AIN-6: 310 team numbers" do
    test "0 is refused" do
      text = String.replace(fixture("teams_base.trf"), "310   5 ", "310   0 ")

      assert_raise Trf.ValidationError, ~r/team number must be 1 or more/, fn ->
        Trf.parse(text)
      end
    end

    test "a number used twice is refused" do
      text = String.replace(fixture("teams_base.trf"), "310   5 ", "310   4 ")

      assert_raise Trf.ValidationError, ~r/team number 4 is already another team's/, fn ->
        Trf.parse(text)
      end
    end
  end

  describe "AIN-7: pair_round/2 checks the teams" do
    defp team(tpn, fields \\ []),
      do: struct(%Team{tpn: tpn, match_points: 0.0, game_points: 0.0}, fields)

    test "two teams on one TPN" do
      assert {:error, {:invalid_option, :teams, {:duplicate_tpn, 1}}} =
               TeamPairing.pair_round([team(1), team(1), team(2)])
    end

    test "a TPN below 1, or a score that is not a number" do
      assert {:error, {:invalid_option, :teams, %Team{tpn: 0}}} =
               TeamPairing.pair_round([team(0), team(1)])

      assert {:error, {:invalid_option, :teams, %Team{tpn: 2}}} =
               TeamPairing.pair_round([team(1), team(2, match_points: nil)])
    end

    test "valid teams still pair" do
      assert {:ok, _} = TeamPairing.pair_round([team(1), team(2)])
    end
  end
end

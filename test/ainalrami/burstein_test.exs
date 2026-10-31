defmodule Ainalrami.BursteinTest do
  @moduledoc """
  The Burstein system (C.04.4.2) by hand: the text's own example of 4.3's
  order, the seeding rounds, each reading of the index, the colour ladder,
  a bracket small enough to work out on paper, and the refusals. The
  whole-round answers against an independent brute force are
  `burstein_validation_test.exs`'s; the seeding rounds against bbpPairings
  are `burstein_bbp_test.exs`'s.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{Burstein, Generator, Pairing, Trf}
  alias Ainalrami.Burstein.{Bracket, Colour, Order, Player}
  alias Ainalrami.Dubov.Graph

  defp roster(n, rounds) do
    {text, _} = Generator.generate(unset: :fixed, seed: 3, players: n, rounds: rounds)
    Trf.parse(text).players
  end

  defp p(rank, fields), do: struct!(Player, [rank: rank] ++ fields)

  defp g(opp, colour, result), do: %{opponent_rank: opp, colour: colour, result: result}

  describe "4.3's example (six players, two floaters)" do
    # The note's first candidate, then its list in order - which prints
    # "1-3, 2-0, 4-5, 6-0" twice (reading B2); dropped once, nothing is
    # missing: 45 pairings, C(6,4) x 3.
    @listed """
    1-6 2-5 3-0 4-0
    1-6 2-4 3-0 5-0
    1-6 2-3 4-0 5-0
    1-6 2-0 3-5 4-0
    1-6 2-0 3-4 5-0
    1-6 2-0 3-0 4-5
    1-5 2-6 3-0 4-0
    1-5 2-4 3-0 6-0
    1-5 2-3 4-0 6-0
    1-5 2-0 3-6 4-0
    1-5 2-0 3-4 6-0
    1-5 2-0 3-0 4-6
    1-4 2-6 3-0 5-0
    1-4 2-5 3-0 6-0
    1-4 2-3 5-0 6-0
    1-4 2-0 3-6 5-0
    1-4 2-0 3-5 6-0
    1-4 2-0 3-0 5-6
    1-3 2-6 4-0 5-0
    1-3 2-5 4-0 6-0
    1-3 2-4 5-0 6-0
    1-3 2-0 4-6 5-0
    1-3 2-0 4-5 6-0
    1-3 2-0 4-0 5-6
    1-2 3-6 4-0 5-0
    1-2 3-5 4-0 6-0
    1-2 3-4 5-0 6-0
    1-2 3-0 4-6 5-0
    1-2 3-0 4-5 6-0
    1-2 3-0 4-0 5-6
    1-0 2-6 3-5 4-0
    1-0 2-6 3-4 5-0
    1-0 2-6 3-0 4-5
    1-0 2-5 3-6 4-0
    1-0 2-5 3-4 6-0
    1-0 2-5 3-0 4-6
    1-0 2-4 3-6 5-0
    1-0 2-4 3-5 6-0
    1-0 2-4 3-0 5-6
    1-0 2-3 4-6 5-0
    1-0 2-3 4-5 6-0
    1-0 2-3 4-0 5-6
    1-0 2-0 3-6 4-5
    1-0 2-0 3-5 4-6
    1-0 2-0 3-4 5-6
    """

    defp parse_line(line) do
      for pair <- String.split(line) do
        [a, b] = pair |> String.split("-") |> Enum.map(&String.to_integer/1)
        {a, b}
      end
    end

    test "Order.enumerate/2 lists them exactly as the text does" do
      listed = @listed |> String.split("\n", trim: true) |> Enum.map(&parse_line/1)
      assert length(listed) == 45
      assert Order.enumerate(6, 2) == listed
    end

    test "the sort key orders them the same way" do
      all = Order.enumerate(6, 2)
      assert Enum.sort_by(all, &Order.key(6, &1), :desc) == all
    end
  end

  describe "the seeding rounds (1.6)" do
    test "half the rounds, rounded down, at most four" do
      assert Enum.map([1, 2, 3, 5, 7, 9, 11], &Burstein.seeding_rounds/1) == [0, 1, 1, 2, 3, 4, 4]
    end

    test "are the Dutch system's pairing, colours and all" do
      players = roster(11, 2)
      opts = [expected_rounds: 7, initial_colour: "w"]
      assert {:ok, round} = Burstein.pair_round(players, opts)
      assert round.seeding?
      assert {:ok, pairs} = Burstein.pair_next_round(players, opts)
      assert pairs == Pairing.pair_next_round(players, opts)
    end

    test "the round after them is Burstein's" do
      players = roster(11, 3)

      assert {:ok, %{seeding?: false, brackets: [_ | _]}} =
               Burstein.pair_round(players, expected_rounds: 7, initial_colour: "w")
    end
  end

  describe "the index (1.7, 1.8)" do
    # 1 beat 2 in round 1 and 2 beat 3 in round 2; 1 had the bye in round 2;
    # 3 had a zero-point bye in round 1.
    defp history do
      [
        %{rank: 1, points: 2.0, games: [g(2, "w", "1"), g(nil, nil, "U")]},
        %{rank: 2, points: 1.0, games: [g(1, "b", "0"), g(3, "w", "1")]},
        %{rank: 3, points: 0.0, games: [g(nil, nil, "Z"), g(2, "b", "0")]}
      ]
    end

    test "reading B3: an unplayed round is a game against oneself, at one's own score" do
      index = Player.index(history(), 3, Trf.default_point_system())
      # 1: opponent 2 (1.0) beaten, plus the bye against "himself" (2.0) won.
      assert index[1] == {3.0, 3.0}
      # 2: opponents 1 (2.0, lost) and 3 (seen as 0.0, beaten).
      assert index[2] == {2.0, 0.0}
      # 3: its own Z, at its own 0.0, then 2 (1.0) lost.
      assert index[3] == {1.0, 0.0}
    end

    test "reading B4: a run of zero-point byes to the current round reads as draws to the opponents" do
      players = [
        %{rank: 1, points: 1.0, games: [g(2, "w", "1"), g(nil, nil, "Z")]},
        %{rank: 2, points: 0.0, games: [g(1, "b", "0"), g(nil, nil, "Z")]}
      ]

      index = Player.index(players, 3, Trf.default_point_system())
      # 1 sees 2 at 0 + one draw for 2's withdrawal; its own Z is at its own 1.0.
      assert index[1] == {0.5 + 1.0, 0.5}
      # 2 sees 1 at 1.0 + 0.5 - 1's Z reaches the current round too.
      assert index[2] == {1.5 + 0.0, 0.0}
    end

    test "reading B4: a player who came back is seen at their real score" do
      players = [
        %{rank: 1, points: 1.0, games: [g(2, "w", "1"), g(3, "w", "=")]},
        %{rank: 2, points: 0.5, games: [g(1, "b", "0"), g(nil, nil, "Z"), g(3, "b", "=")]},
        %{rank: 3, points: 1.0, games: [g(nil, nil, "Z"), g(1, "b", "="), g(2, "w", "=")]}
      ]

      index = Player.index(players, 4, Trf.default_point_system())
      assert elem(index[1], 0) == 0.5 + 1.0 + 1.0
    end

    test "virtual points are in the score and not in the index (1.7.2)" do
      players = [
        %{rank: 1, points: 1.0, games: [g(2, "w", "1")], accelerations: [1.0, 1.0]},
        %{rank: 2, points: 0.0, games: [g(1, "b", "0")], accelerations: [1.0, 1.0]}
      ]

      index = Player.index(players, 2, Trf.default_point_system())
      assert index[2] == {1.0, 0.0}

      built =
        Player.build(hd(players), 2, %{index: index, eligible: %{}})

      assert built.score == 2.0
    end
  end

  describe "colours (5.2)" do
    defp hi(fields), do: p(1, [buchholz: 5.0, played: 3] ++ fields)
    defp lo(fields), do: p(2, [buchholz: 2.0, played: 3] ++ fields)

    test "5.2.1: neither has played - the higher ranked by the index" do
      a = p(4, buchholz: 1.0, played: 0)
      b = p(3, buchholz: 0.0, played: 0)
      # 4 is the higher ranked although 3 has the smaller TPN.
      assert {4, 3, "5.2.1"} = Colour.allocate(a, b, %{3 => 3, 4 => 4}, :black)
      assert {3, 4, "5.2.1"} = Colour.allocate(a, b, %{3 => 3, 4 => 4}, :white)
    end

    test "5.2.2: a player with no game has no preference, the other's is granted (1.5.4)" do
      a = p(1, played: 0)
      b = lo(colour: :black, strength: :mild, colours: [:white])
      assert {1, 2, "5.2.2"} = Colour.allocate(a, b, %{1 => 1, 2 => 2}, :white)
    end

    test "5.2.3 then 5.2.4 then 5.2.5" do
      a = hi(colour: :white, strength: :absolute, colours: [:white, :black, :black])
      b = lo(colour: :white, strength: :mild, colours: [:black, :white, :black])
      assert {1, 2, "5.2.3"} = Colour.allocate(a, b, %{}, :white)

      a = hi(colour: :white, strength: :mild, colours: [:black, :white, :black])
      b = lo(colour: :white, strength: :mild, colours: [:white, :white, :black])
      assert {1, 2, "5.2.4"} = Colour.allocate(a, b, %{}, :white)

      a = hi(colour: :black, strength: :mild, colours: [:white])
      b = lo(colour: :black, strength: :mild, colours: [:white])
      assert {2, 1, "5.2.5"} = Colour.allocate(a, b, %{}, :white)
    end

    test "reading B6: the higher ranked is by index even against a higher score" do
      a =
        p(1,
          score: 3.0,
          buchholz: 1.0,
          played: 1,
          colour: :white,
          strength: :mild,
          colours: [:black]
        )

      b =
        p(2,
          score: 1.0,
          buchholz: 4.0,
          played: 1,
          colour: :white,
          strength: :mild,
          colours: [:black]
        )

      assert {2, 1, "5.2.5"} = Colour.allocate(a, b, %{}, :white)
    end
  end

  describe "a bracket (3.2)" do
    test "[C6]: a resident floats rather than the incoming floater, against 4.3's order" do
      # 1 (2.0) came down and ranks last by index; 2 and 3 (1.0) are
      # residents; 4-6 (0.0) below. 1 and 2 have met. 4.3 alone would pair
      # BSN 1 (player 2) with BSN 2 (player 3) and float 1; [C6] floats the
      # lower score instead: 2 floats, 3 meets 1.
      players = [
        p(1, score: 2.0, buchholz: 1.0),
        p(2, score: 1.0, buchholz: 9.0),
        p(3, score: 1.0, buchholz: 8.0),
        p(4, score: 0.0, buchholz: 5.0),
        p(5, score: 0.0, buchholz: 4.0),
        p(6, score: 0.0, buchholz: 3.0)
      ]

      field =
        Graph.new(players, fn a, b -> {min(a.rank, b.rank), max(a.rank, b.rank)} == {1, 2} end)

      {bracket, lower} = Enum.split(players, 3)
      assert {:ok, result} = Bracket.pair(bracket, lower, field)
      assert Enum.map(result.floaters, & &1.rank) == [2]
      assert Enum.map(result.pairs, fn {a, b} -> {a.rank, b.rank} end) == [{3, 1}]
    end

    test "4.3: BSN 1 meets the largest BSN that keeps everything else best" do
      players = for r <- 1..6, do: p(r, score: if(r <= 4, do: 1.0, else: 0.0), buchholz: 10.0 - r)
      open = Graph.new(players, fn _, _ -> false end)
      {bracket, lower} = Enum.split(players, 4)
      assert {:ok, result} = Bracket.pair(bracket, lower, open)
      assert result.floaters == []
      assert Enum.map(result.pairs, fn {a, b} -> {a.rank, b.rank} end) == [{1, 4}, {2, 3}]
    end
  end

  describe "refusals" do
    test "the round count is required and bounds the rounds" do
      assert {:error, :expected_rounds_required} = Burstein.pair_round(roster(6, 0))

      assert {:error, {:beyond_expected_rounds, 3}} =
               Burstein.pair_round(roster(6, 2), expected_rounds: 2)
    end

    test "the organiser's options are not Burstein's" do
      assert {:error, {:unsupported_option, :soft_pairs}} =
               Burstein.pair_round(roster(6, 0), expected_rounds: 5, soft_pairs: [[1, 2]])
    end
  end

  describe "the generator" do
    test "system: :burstein pairs by Burstein and says so in 192" do
      {text, _} = Generator.generate(seed: 8, players: 10, rounds: 6, system: :burstein)
      assert text =~ ~r/^192 FIDE_BURSTEIN\s*$/m
    end
  end
end

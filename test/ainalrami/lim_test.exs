defmodule Ainalrami.LimTest do
  @moduledoc """
  C.04.4.3 (Lim) against the rule text's own examples - 4.2 and 4.3's
  exchange tables, 4.4's floater, 7.2's round one - and the readings of
  `docs/conformance-c0443-lim.md` that a small case can show.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Lim
  alias Ainalrami.Lim.{Colour, Group, Order, Player}
  alias Ainalrami.Dubov.Graph

  defp p(rank, opts \\ []) do
    struct(Player, [rank: rank, score: 1.0] ++ opts)
  end

  defp field(players, incompatible) do
    bad = MapSet.new(incompatible, fn {a, b} -> {min(a, b), max(a, b)} end)
    Graph.new(players, &MapSet.member?(bad, {min(&1.rank, &2.rank), max(&1.rank, &2.rank)}))
  end

  defp ranks({picker, candidates}), do: {picker.rank, Enum.map(candidates, & &1.rank)}

  describe "4.2 and 4.3: the exchange order" do
    test "#1 of six tries 4, 5, 6, 3, 2" do
      order = Order.new(Enum.map(1..6, &p/1), 1.0, :down)
      assert ranks(Order.next(order, %{})) == {1, [4, 5, 6, 3, 2]}
    end

    test "#2, with #1 v #6 fixed, tries 4, 5, 3" do
      order = Order.new(Enum.map(1..6, &p/1), 1.0, :down)
      assert ranks(Order.next(order, %{1 => 6, 6 => 1})) == {2, [4, 5, 3]}
    end

    test "pairing upward starts from the bottom (4.1.2)" do
      order = Order.new(Enum.map(1..6, &p/1), 1.0, :up)
      assert ranks(Order.next(order, %{})) == {6, [3, 2, 1, 4, 5]}
    end

    test "1 v 4 and 1 v 5 have met: 1 v 6, 2 v 4, 3 v 5" do
      players = Enum.map(1..6, &p/1)
      f = field(players, [{1, 4}, {1, 5}])
      pairs = Group.pairs(players, 1.0, :down, f, {1.0, :white})
      assert Enum.map(pairs, fn {x, y} -> {x.rank, y.rank} end) == [{1, 6}, {2, 4}, {3, 5}]
    end

    test "a down-floater is paired first, with the best resident due the other colour (3.6, 3.8)" do
      floater = p(9, score: 2.0, colour: :white)

      residents = [
        p(1, colour: :white),
        p(2, colour: :black),
        p(3, colour: :white),
        p(4, colour: :black),
        p(5, colour: :white)
      ]

      order = Order.new([floater | residents], 1.0, :down)
      assert ranks(Order.next(order, %{})) == {9, [2, 4, 1, 3, 5]}
    end
  end

  describe "4.4: who floats when #1 and #2 both need #6" do
    # #1 and #2 have met each other and everyone in the group but #6.
    defp blocked(members) do
      for a <- [1, 2], b <- members, b not in [a, 6], do: {a, b}
    end

    test "an odd group floats #2 instead of the lowest (4.4.1)" do
      members = Enum.map(1..7, &p/1)
      lower = [p(8, score: 0.0)]
      f = field(members ++ lower, blocked(1..7))
      assert {:ok, paired, [floater]} = Group.floaters(members, 1.0, :down, lower, lower, f)
      assert floater.rank == 2
      assert Enum.sort(Enum.map(paired, & &1.rank)) == [1, 3, 4, 5, 6, 7]
    end

    test "an even group floats #2 and the lowest player left (4.4.2)" do
      members = Enum.map(1..6, &p/1)
      lower = [p(7, score: 0.0), p(8, score: 0.0)]
      f = field(members ++ lower, blocked(1..6))
      assert {:ok, _paired, floaters} = Group.floaters(members, 1.0, :down, lower, lower, f)
      assert Enum.sort(Enum.map(floaters, & &1.rank)) == [2, 5]
    end
  end

  describe "5: colours" do
    test "7.2: no history - the higher ranked takes the initial colour on an odd number" do
      assert {3, 23, _} = Colour.allocate(p(3), p(23), 0.0, 0.0, :white)
      assert {22, 2, _} = Colour.allocate(p(2), p(22), 0.0, 0.0, :white)
    end

    test "5.4: back to the most recent round where the histories differ" do
      x = p(1, colour: :black, strength: :mild, colours: [:white, :black, :black, :white])
      y = p(2, colour: :black, strength: :mild, colours: [:black, :white, :black, :white])
      # Going back: W/W, B/B, then x had Black and y White - y gets Black.
      assert {1, 2, "5.4"} = Colour.allocate(x, y, 1.0, 1.0, :white)
    end

    test "5.4: identical histories - higher ranked at or above the median, lower below" do
      x = p(1, colour: :black, strength: :mild, colours: [:black, :white])
      y = p(2, colour: :black, strength: :mild, colours: [:black, :white])
      assert {2, 1, _} = Colour.allocate(x, y, 1.0, 1.0, :white)
      assert {1, 2, _} = Colour.allocate(x, y, 0.5, 1.0, :white)
    end

    test "5.3: the player who must alternate does" do
      x = p(1, colour: :black, strength: :mild, colours: [:black, :white])
      y = p(2, colour: :black, strength: :absolute, colours: [:white, :white])
      assert {1, 2, "5.3"} = Colour.allocate(x, y, 1.0, 1.0, :white)
    end
  end

  defp fresh(n), do: for(r <- 1..n, do: %{rank: r, points: 0.0, games: [], fide_rating: 2400 - r})

  describe "7: round one" do
    test "forty players: 1 v 21, 22 v 2, 3 v 23, ... 40 v 20" do
      {:ok, r} = Lim.pair_round(fresh(40), expected_rounds: 9, initial_colour: "w")

      expected =
        for i <- 1..20, do: if(rem(i, 2) == 1, do: {i, i + 20}, else: {i + 20, i})

      assert Enum.sort(r.pairs) == Enum.sort(expected)
      assert r.bye == nil
    end

    test "the other draw: 21 v 1, 2 v 22, ..." do
      {:ok, r} = Lim.pair_round(fresh(40), expected_rounds: 9, initial_colour: "b")
      assert {21, 1} in r.pairs and {2, 22} in r.pairs and {20, 40} in r.pairs
    end

    test "7.1: an odd field gives the bye to the lowest rated" do
      {:ok, r} = Lim.pair_round(fresh(5), expected_rounds: 5, initial_colour: "w")
      assert r.bye == 5
      assert Enum.sort(r.pairs) == [{1, 3}, {4, 2}]
    end
  end

  defp game(opp, colour, result), do: %{opponent_rank: opp, colour: colour, result: result}

  describe "the round" do
    # Round 1: 1 beat 3, 4 beat 2, 5 had the pairing-allocated bye.
    defp after_round_one do
      [
        %{rank: 1, points: 1.0, games: [game(3, "w", "1")], fide_rating: 2400},
        %{rank: 2, points: 0.0, games: [game(4, "b", "0")], fide_rating: 2390},
        %{rank: 3, points: 0.0, games: [game(1, "b", "0")], fide_rating: 2380},
        %{rank: 4, points: 1.0, games: [game(2, "w", "1")], fide_rating: 2370},
        %{
          rank: 5,
          points: 1.0,
          games: [%{opponent_rank: nil, colour: nil, result: "U"}],
          fide_rating: 2360
        }
      ]
    end

    test "1.1: the bye goes to the lowest ranked of the lowest scoregroup who may have it" do
      {:ok, r} = Lim.pair_round(after_round_one(), expected_rounds: 5, initial_colour: "w")
      assert r.bye == 3
    end

    test "2.2: the groups above the median first, then from the bottom up, the median last" do
      {:ok, r} = Lim.pair_round(after_round_one(), expected_rounds: 5, initial_colour: "w")
      assert Enum.map(r.groups, & &1.direction) |> List.last() == :median
    end
  end

  describe "refusals" do
    test "the round count is required" do
      assert {:error, :expected_rounds_required} = Lim.pair_round(fresh(4), [])
    end

    test "the Dutch engine's organiser options and Maxi are refused" do
      assert {:error, {:unsupported_option, :soft_pairs}} =
               Lim.pair_round(fresh(4), expected_rounds: 3, soft_pairs: [[1, 2]])

      assert {:error, {:unsupported_option, :maxi}} =
               Lim.pair_round(fresh(4), expected_rounds: 3, maxi: true)
    end

    test "an acceleration is refused: Lim has none" do
      players = Enum.map(fresh(4), &Map.put(&1, :accelerations, [1.0, 1.0, 0.0]))

      assert {:error, {:unsupported_option, :acceleration}} =
               Lim.pair_round(players, expected_rounds: 3)
    end
  end
end

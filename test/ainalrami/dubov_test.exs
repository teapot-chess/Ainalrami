defmodule Ainalrami.DubovTest do
  @moduledoc """
  The Dubov system (C.04.4.1) by hand: the text's own examples, each step
  of the procedure on a field small enough to work out on paper, the
  readings that are switches, and every refusal. The whole-round answers
  against an independent brute force are `dubov_validation_test.exs`'s.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{Dubov, Generator, Trf}
  alias Ainalrami.Dubov.{Bracket, Colour, Graph, Order, Player}

  doctest Ainalrami.Dubov.Order

  defp field(generate_opts) do
    {text, _} = Generator.generate([unset: :fixed, seed: 1] ++ generate_opts)
    Trf.parse(text).players
  end

  defp roster(n, rounds \\ 0), do: field(players: n, rounds: rounds)

  defp p(rank, fields), do: struct!(Player, [rank: rank] ++ fields)

  defp open_graph(players), do: Graph.new(players, fn _, _ -> false end)

  describe "the text's examples" do
    test "4.3.3: A B C D E F G gets sequence numbers D C E B F A G" do
      assert Order.middle_out(~w(A B C D E F G)) == ~w(D C E B F A G)
    end

    test "4.4.2: the transpositions of A B C, in order" do
      assert Order.transpositions(~w(A B C)) ==
               [~w(A B C), ~w(A C B), ~w(B A C), ~w(B C A), ~w(C A B), ~w(C B A)]
    end

    test "4.1.3: sets of two from four, in the article's order" do
      assert Order.sets(~w(a b c d), 2) ==
               [~w(a b), ~w(a c), ~w(a d), ~w(b c), ~w(b d), ~w(c d)]
    end
  end

  describe "a first round" do
    test "G1 is the first half by TPN, S1 meets T2 in order, 5.2.1 colours" do
      assert {:ok, round} = Dubov.pair_round(roster(8), expected_rounds: 5, initial_colour: "w")
      assert round.bye == nil
      assert Enum.sort(round.pairs) == Enum.sort([{1, 5}, {6, 2}, {3, 7}, {8, 4}])
    end

    test "the other initial colour swaps every board" do
      assert {:ok, round} = Dubov.pair_round(roster(8), expected_rounds: 5, initial_colour: "b")
      assert Enum.sort(round.pairs) == Enum.sort([{5, 1}, {2, 6}, {7, 3}, {4, 8}])
    end

    test "an odd field gives the bye to the lowest-ranked player (3.1)" do
      assert {:ok, round} = Dubov.pair_round(roster(7), expected_rounds: 5)
      assert round.bye == 7
      assert {:ok, pairs} = Dubov.pair_next_round(roster(7), expected_rounds: 5)
      assert List.last(pairs) == {7, nil}
    end
  end

  describe "3.2.4" do
    test "a bracket of four White seekers shifts two by 4.3's numbers" do
      players = for r <- 1..4, do: p(r, colour: :white, played: 1, aro: 0)
      {g1, g2, moved} = Bracket.subgroups(players, open_graph(players))

      # 4.3.3 numbers 1 2 3 4 as 2 3 1 4; the first two move across.
      assert moved == %{unavoidable: 0, first: [], second: [2, 3]}
      assert Enum.map(g1, & &1.rank) |> Enum.sort() == [1, 4]
      assert Enum.map(g2, & &1.rank) |> Enum.sort() == [2, 3]
    end

    test "a shifter that would leave the bracket unpairable is passed over" do
      players = for r <- 1..4, do: p(r, colour: :white, played: 1, aro: 0)
      # 1 has met 2 and 3: moving {2, 3} across leaves 1 nobody to meet.
      graph = Graph.new(players, fn a, b -> Enum.sort([a.rank, b.rank]) in [[1, 2], [1, 3]] end)
      {_g1, _g2, moved} = Bracket.subgroups(players, graph)
      assert moved.second == [2, 1]
    end
  end

  describe "reading D2 (3.2.6)" do
    setup do
      g1 = [p(1, colour: :white), p(2, colour: :black)]
      g2 = [p(3, colour: :white), p(4, colour: :black)]
      {:ok, g1: g1, g2: g2, graph: open_graph(g1 ++ g2)}
    end

    test "(a), the default, takes the first legal transposition", ctx do
      assert Dubov.default_transposition_rule() == :first_legal
      pairs = Bracket.transposition(ctx.g1, ctx.g2, ctx.graph, :first_legal)
      assert Enum.map(pairs, fn {a, b} -> {a.rank, b.rank} end) == [{1, 3}, {2, 4}]
      assert Bracket.denied(pairs) == 2
    end

    test "(b) skips to the first that reaches 3.2.2's colour count", ctx do
      pairs = Bracket.transposition(ctx.g1, ctx.g2, ctx.graph, :first_reaching_c7, 0)
      assert Enum.map(pairs, fn {a, b} -> {a.rank, b.rank} end) == [{1, 4}, {2, 3}]
    end

    test "the two never part on a real round (the moduledoc's t = 0)" do
      for seed <- 1..12 do
        {text, _} = Generator.generate(seed: seed, players: 11, rounds: 5, system: :dubov)
        players = Trf.parse(text).players

        for round <- 1..4 do
          before = before_round(players, round)
          opts = [expected_rounds: 5]

          assert Dubov.pair_round(before, opts ++ [transposition_rule: :first_legal]) ==
                   Dubov.pair_round(before, opts ++ [transposition_rule: :first_reaching_c7])
        end
      end
    end
  end

  defp before_round(players, round) do
    Enum.map(players, fn pl ->
      games = Enum.take(pl.games, round - 1)

      %{
        pl
        | games: games,
          points: Enum.sum(Enum.map(games, &Trf.points_for_game(&1, Trf.default_point_system())))
      }
    end)
  end

  describe "Article 5" do
    @numbers %{1 => 1, 2 => 2}

    test "5.2.2 grants both preferences" do
      a = p(1, colour: :black, strength: :mild, played: 1, colours: [:white])
      b = p(2, colour: :white, strength: :mild, played: 1, colours: [:black])
      assert Colour.allocate(a, b, @numbers, :white) == {2, 1, "5.2.2"}
    end

    test "5.2.3 grants the stronger one" do
      a = p(1, colour: :white, strength: :mild, played: 2, colours: [:white, :black])
      b = p(2, colour: :white, strength: :absolute, played: 2, colours: [:black, :black])
      assert Colour.allocate(a, b, @numbers, :white) == {2, 1, "5.2.3"}
    end

    test "5.2.4 alternates from the last round they differed" do
      a = p(1, colour: :black, strength: :mild, played: 2, colours: [:black, :white])
      b = p(2, colour: :black, strength: :mild, played: 2, colours: [:white, :white])
      # Latest round alike (White); the one before: 1 Black, 2 White.
      assert Colour.allocate(a, b, @numbers, :white) == {1, 2, "5.2.4"}
    end

    test "5.2.5 grants the higher ranked player's preference" do
      a = p(1, colour: :black, strength: :mild, played: 1, colours: [:white], score: 1.0)
      b = p(2, colour: :black, strength: :mild, played: 1, colours: [:white], score: 1.0)
      assert Colour.allocate(a, b, @numbers, :white) == {2, 1, "5.2.5"}
    end
  end

  describe "refusals" do
    test "1.1.1: an unrated player needs a provisional rating (1.1.2)" do
      players = roster(6) |> List.update_at(2, &Map.put(&1, :fide_rating, 0))
      assert Dubov.pair_round(players, expected_rounds: 5) == {:error, {:unrated, [3]}}

      assert {:ok, _} =
               Dubov.pair_round(players, expected_rounds: 5, provisional_ratings: %{3 => 1500})

      assert Dubov.pair_round(players, expected_rounds: 5, provisional_ratings: %{1 => 1500}) ==
               {:error, {:provisional_for_rated, [1]}}
    end

    test "the round count is required and bounds the rounds" do
      assert Dubov.pair_round(roster(6), []) == {:error, :expected_rounds_required}

      assert Dubov.pair_round(field(players: 6, rounds: 2), expected_rounds: 2) ==
               {:error, {:beyond_expected_rounds, 3}}
    end

    test "the organiser's options are not Dubov's" do
      assert Dubov.pair_round(roster(6), expected_rounds: 5, soft_pairs: [[1, 2]]) ==
               {:error, {:unsupported_option, :soft_pairs}}

      assert {:error, {:invalid_option, :transposition_rule, :sideways}} =
               Dubov.pair_round(roster(6), expected_rounds: 5, transposition_rule: :sideways)
    end

    test "reading D8: an unpairable round is refused, not bent" do
      assert Dubov.pair_round(field(players: 2, rounds: 1), expected_rounds: 3) ==
               {:error, :no_legal_pairing}
    end
  end

  describe "TRF" do
    test "XXO provisional-rating reads and writes back" do
      {text, _} = Generator.generate(seed: 3, players: 6, rounds: 0, unset: :fixed)
      parsed = Trf.parse(text <> "XXO provisional-rating 4 1500\nXXO provisional-rating 2 1320\n")
      assert parsed.tournament.provisional_ratings == %{2 => 1320, 4 => 1500}

      again = parsed |> Trf.serialize() |> Trf.parse()
      assert again.tournament.provisional_ratings == %{2 => 1320, 4 => 1500}
    end

    test "two lines for one player are refused" do
      {text, _} = Generator.generate(seed: 3, players: 6, rounds: 0, unset: :fixed)

      assert_raise Trf.ValidationError, ~r/two XXO provisional-rating/, fn ->
        Trf.parse(text <> "XXO provisional-rating 4 1500\nXXO provisional-rating 4 1400\n")
      end
    end
  end

  describe "the generator" do
    test "system: :dubov pairs by Dubov and says so in 192" do
      {text, _} =
        Generator.generate(seed: 8, players: 9, rounds: 4, unset: :fixed, system: :dubov)

      assert text =~ ~r/^192 FIDE_DUBOV\s*$/m
    end

    test "system: :dutch is the default, byte for byte" do
      opts = [seed: 8, players: 9, rounds: 4]
      assert Generator.generate(opts) == Generator.generate(opts ++ [system: :dutch])
    end

    test "Dubov with the match format is refused" do
      assert_raise ArgumentError, fn ->
        Generator.generate(seed: 8, players: 9, rounds: 4, system: :dubov, match_format: true)
      end
    end
  end
end

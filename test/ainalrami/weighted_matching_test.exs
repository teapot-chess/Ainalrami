defmodule Ainalrami.WeightedMatchingTest do
  use ExUnit.Case

  alias Ainalrami.WeightedMatching

  describe "solve/2" do
    test "n <= 1 has no matching to make" do
      assert WeightedMatching.solve(0, []) == %{}
      assert WeightedMatching.solve(1, []) == %{}
    end

    test "no edges means nothing gets matched" do
      assert WeightedMatching.solve(4, []) == %{}
    end

    test "a single edge is matched, both directions" do
      assert WeightedMatching.solve(2, [{0, 1, 7}]) == %{0 => 1, 1 => 0}
    end

    test "zero and negative weights are treated as no edge" do
      assert WeightedMatching.solve(2, [{0, 1, 0}]) == %{}
      assert WeightedMatching.solve(2, [{0, 1, -3}]) == %{}
    end

    test "disjoint edges are all taken" do
      result = WeightedMatching.solve(4, [{0, 1, 3}, {2, 3, 5}])

      assert result == %{0 => 1, 1 => 0, 2 => 3, 3 => 2}
    end

    test "picks the heavier of two edges sharing a vertex over both" do
      result = WeightedMatching.solve(3, [{0, 1, 3}, {1, 2, 9}])

      assert result == %{1 => 2, 2 => 1}
    end

    test "a triangle (odd cycle) forces a blossom: only one edge can ever be used" do
      # The textbook minimal case for blossom contraction in a WEIGHTED
      # graph: with all three edges present, no matching can use more than
      # one of them (any two share a vertex), so the maximum-weight
      # matching is simply the single heaviest edge, leaving the third
      # vertex unmatched. Confirmed by hand-tracing this exact case while
      # developing WeightedMatching, back when it was the first graph that
      # made the algorithm form a blossom at all.
      edges = [{0, 1, 5}, {1, 2, 9}, {0, 2, 5}]

      assert WeightedMatching.solve(3, edges) == %{1 => 2, 2 => 1}
    end

    test "reaches the DP-oracle maximum on random small graphs, some requiring blossom formation" do
      for seed <- 1..80 do
        :rand.seed(:exsss, {seed, seed * 3, seed * 7})
        n = Enum.random(3..7)

        edges =
          for a <- 0..(n - 1), b <- 0..(n - 1), a < b, :rand.uniform() < 0.5 do
            {a, b, Enum.random(1..9)}
          end

        result = WeightedMatching.solve(n, edges)

        assert valid_matching?(result, edges),
               "seed #{seed}: invalid matching #{inspect(result)} for edges #{inspect(edges)}"

        expected = oracle_max_weight(n, edges)
        got = total_weight(result, edges)

        assert got == expected,
               "seed #{seed}: got #{got}, oracle says #{expected} is possible, " <>
                 "edges: #{inspect(edges)}, matching: #{inspect(result)}"
      end
    end

    test "reaches the DP-oracle maximum on denser random graphs, exercising blossom expansion" do
      # Wider (n up to 10) and denser (edge probability 0.45) than the test
      # above specifically to reach blossom EXPANSION, not just formation
      # - a blossom's own dual variable hitting zero mid-search only
      # happens when a graph is dense/large enough that a blossom forms
      # and then needs to be dissolved again before the stage finishes.
      # `n` and the edge probability here were picked empirically (during
      # development) to reliably exercise that path.
      for seed <- 101..180 do
        :rand.seed(:exsss, {seed, seed * 3, seed * 7})
        n = Enum.random(4..10)

        edges =
          for a <- 0..(n - 1), b <- 0..(n - 1), a < b, :rand.uniform() < 0.45 do
            {a, b, Enum.random(1..15)}
          end

        result = WeightedMatching.solve(n, edges)

        assert valid_matching?(result, edges),
               "seed #{seed}: invalid matching #{inspect(result)} for edges #{inspect(edges)}"

        expected = oracle_max_weight(n, edges)
        got = total_weight(result, edges)

        assert got == expected,
               "seed #{seed}: got #{got}, oracle says #{expected} is possible, " <>
                 "edges: #{inspect(edges)}, matching: #{inspect(result)}"
      end
    end
  end

  describe "new/3 on an empty vertex set" do
    # `solve/2` never gets here - it answers `n <= 1` from a guard clause -
    # so the only way in is `new/3`, which is the path `Ainalrami.Pairing`
    # takes. Its per-vertex maps were seeded from a two-argument `0..(n -
    # 1)`, which at n = 0 is `0..-1`: a DESCENDING range in Elixir, so it
    # enumerated `[0, -1]` and put a `-1 => -1` entry for a vertex that does
    # not exist into both. No matching was ever wrong - an empty graph has
    # no edges to walk, and nothing reads those entries - but a state that
    # describes a vertex the caller never declared is a state no invariant
    # can be written against.
    test "declares no vertices" do
      state = WeightedMatching.new(0, [])

      assert state.in_blossom == %{}
      assert state.bases == %{}
      assert state.members == %{}
    end
  end

  describe "the incremental path: new/3, set_weight/4, solve/1" do
    # `solve/2` is the pure entry, and every test above uses it. `Pairing`
    # does not: it builds one state with `new/3` and then edits weights
    # with `set_weight/4`, re-solving between edits, so the search
    # RESUMES from a previous optimum instead of starting fresh. That is
    # the path `even_up_exposed_duals/1` and `prepare_vertex/2` exist for,
    # and it had no direct coverage at all - it was reached only through
    # whole pairings, where a wrong matching shows up as a different
    # bracket rather than as a smaller total weight.
    test "an edited state reaches the same optimum a fresh solve would" do
      for seed <- 201..320 do
        :rand.seed(:exsss, {seed, seed * 3, seed * 7})
        n = Enum.random(4..10)

        edges =
          for a <- 0..(n - 1), b <- 0..(n - 1), a < b, :rand.uniform() < 0.45 do
            {a, b, Enum.random(1..15)}
          end

        {state, _} =
          n |> WeightedMatching.new(edges, max_weight: 16, gcd: 1) |> WeightedMatching.solve()

        # A handful of edits, each followed by its own resume. The final
        # weights are what the oracle is asked about.
        {state, final} =
          Enum.reduce(1..5, {state, edges}, fn _step, {state, current} ->
            a = Enum.random(0..(n - 1))
            b = Enum.random(0..(n - 1))

            if a == b do
              {state, current}
            else
              w = Enum.random(0..15)

              {state, _} =
                state |> WeightedMatching.set_weight(a, b, w) |> WeightedMatching.solve()

              {lo, hi} = {min(a, b), max(a, b)}
              current = Enum.reject(current, fn {x, y, _} -> {x, y} == {lo, hi} end)
              {state, if(w > 0, do: [{lo, hi, w} | current], else: current)}
            end
          end)

        result = matching_of(state, n)

        assert valid_matching?(result, final),
               "seed #{seed}: invalid matching #{inspect(result)} for edges #{inspect(final)}"

        expected = oracle_max_weight(n, final)
        got = total_weight(result, final)

        assert got == expected,
               "seed #{seed}: incremental got #{got}, oracle says #{expected}, " <>
                 "edges: #{inspect(final)}, matching: #{inspect(result)}"
      end
    end
  end

  defp matching_of(state, n) do
    for v <- 0..(n - 1), u = WeightedMatching.mate_of(state, v), u != nil, into: %{} do
      {v, u}
    end
  end

  # `Ainalrami.Matching`'s bracket DP is a genuinely INDEPENDENT
  # implementation (different algorithm, memoized subset DP over ANY
  # subset rather than a primal-dual blossom search) already relied on
  # elsewhere in this codebase - exactly the oracle `WeightedMatching`'s
  # own moduledoc says it was checked against. `float_weight_fun` returns
  # 0 so leaving a vertex unmatched is free, matching `solve/2`'s own
  # semantics of simply omitting unmatched vertices at no cost.
  defp oracle_max_weight(n, edges) do
    lookup = Map.new(edges, fn {a, b, w} -> {Enum.sort([a, b]), w} end)

    pair_weight_fun = fn a, b ->
      case Map.get(lookup, Enum.sort([a, b])) do
        w when is_integer(w) and w > 0 -> w
        _ -> nil
      end
    end

    {pairs, _floaters} =
      Ainalrami.Matching.max_weight_matching(Enum.to_list(0..(n - 1)), pair_weight_fun, fn _ ->
        0
      end)

    Enum.reduce(pairs, 0, fn {a, b}, acc -> acc + pair_weight_fun.(a, b) end)
  end

  describe "duals of either parity" do
    # Two exposed vertices whose duals sum to an odd amount over their
    # edge. One tree moves at a time, so the parity of a tree's outer duals
    # is the root's own and no step is ever half a unit; the exposed ends
    # are first lowered to the least feasible dual, which pairs them here.
    test "an odd dual sum over an exposed edge is still matched" do
      state = WeightedMatching.new(2, [{0, 1, 5}], duals: %{0 => 7, 1 => 6})
      assert {_, %{0 => 1, 1 => 0}} = WeightedMatching.solve(state)
    end

    test "a released vertex inside a blossom leaves only it and the blossom's mate exposed" do
      # A triangle 0-1-2 heavier than anything outside, 3 hanging off 0.
      edges = [{0, 1, 10}, {1, 2, 10}, {0, 2, 10}, {0, 3, 9}, {3, 4, 1}]
      {state, _} = 5 |> WeightedMatching.new(edges, max_weight: 20) |> WeightedMatching.solve()
      edited = WeightedMatching.set_weight(state, 1, 2, 1)
      exposed = for v <- 0..4, WeightedMatching.mate_of(edited, v) == nil, do: v
      assert length(exposed) <= 3
      {_, matching} = WeightedMatching.solve(edited)
      fresh = WeightedMatching.solve(5, [{0, 1, 10}, {1, 2, 1}, {0, 2, 10}, {0, 3, 9}, {3, 4, 1}])

      assert total_weight(matching, [{0, 1, 10}, {1, 2, 1}, {0, 2, 10}, {0, 3, 9}, {3, 4, 1}]) ==
               total_weight(fresh, [{0, 1, 10}, {1, 2, 1}, {0, 2, 10}, {0, 3, 9}, {3, 4, 1}])
    end
  end

  describe "the :gcd option" do
    test "the weights are reduced by the gcd the state records" do
      state = WeightedMatching.new(3, [{0, 1, 12}, {1, 2, 24}], gcd: 2)

      assert state.gcd == 2
      assert WeightedMatching.edge_weight(state, 0, 1) == 12
      assert WeightedMatching.edge_weight(state, 1, 2) == 24
      assert Enum.sort(WeightedMatching.neighbours(state, 1)) == [{0, 12}, {2, 24}]

      # A later weight on that scale is accepted and read back as given.
      state = WeightedMatching.set_weight(state, 0, 2, 14)
      assert WeightedMatching.edge_weight(state, 0, 2) == 14
      assert {_, %{1 => 2, 2 => 1}} = WeightedMatching.solve(state)
    end

    test "the default reduces by the weights' own gcd, and reads them back" do
      state = WeightedMatching.new(3, [{0, 1, 12}, {1, 2, 24}])

      assert state.gcd == 12
      assert WeightedMatching.edge_weight(state, 1, 2) == 24
    end

    test "a supplied gcd that does not divide every weight is refused" do
      assert_raise ArgumentError, ~r/gcd: 5 does not divide the weight 12/, fn ->
        WeightedMatching.new(3, [{0, 1, 10}, {1, 2, 12}], gcd: 5)
      end
    end

    test "a supplied gcd above 1 is refused with duals or a ready adjacency" do
      assert_raise ArgumentError, ~r/cannot be combined/, fn ->
        WeightedMatching.new(2, [{0, 1, 4}], gcd: 2, duals: %{0 => 4, 1 => 4})
      end
    end

    test "shift_and_set/3 refuses a weight off the scale instead of truncating it" do
      state = WeightedMatching.new(2, [{0, 1, 12}], gcd: 4)

      assert_raise ArgumentError, ~r/not on the scale/, fn ->
        WeightedMatching.shift_and_set(state, %{}, [{0, 1, 10}])
      end
    end

    test "set_weight/4 refuses a weight off the scale or over the ceiling" do
      state = WeightedMatching.new(3, [{0, 1, 12}, {1, 2, 24}], gcd: 4, max_weight: 24)

      assert_raise ArgumentError, ~r/not on the scale/, fn ->
        WeightedMatching.set_weight(state, 0, 2, 10)
      end

      assert_raise ArgumentError, ~r/exceeds the initial dual/, fn ->
        WeightedMatching.set_weight(state, 0, 2, 28)
      end

      # On the scale and under the ceiling, it is read back as given.
      assert state |> WeightedMatching.set_weight(0, 2, 20) |> WeightedMatching.edge_weight(2, 0) ==
               20
    end
  end

  describe "shift_and_set/3" do
    # A shift moves the slack of EVERY edge at the shifted vertex. This one
    # lowers vertex 0's dual so that its listed matched edge (0, 1) stays
    # tight at its new, smaller weight - and leaves the UNLISTED edge
    # (0, 2) with a negative slack. Until 2026-10-02 only listed edges were
    # checked: the call returned `{:ok, state}`, the solve after it found
    # nothing to do, and the matching came back as 0-1 (weight 2) where 0-2
    # (weight 8) is the maximum.
    test "refuses a lowered dual that leaves an unlisted edge infeasible" do
      {state, %{0 => 1}} =
        3
        |> WeightedMatching.new([{0, 1, 10}, {0, 2, 8}], gcd: 1, max_weight: 10)
        |> WeightedMatching.solve()

      assert %{0 => 16, 1 => 4, 2 => 0} = state.dual
      assert WeightedMatching.shift_and_set(state, %{0 => -16}, [{0, 1, 2}]) == :error

      # The fallback the contract names reaches the real optimum.
      {_, matching} = state |> WeightedMatching.set_weight(0, 1, 2) |> WeightedMatching.solve()
      assert matching == %{0 => 2, 2 => 0}
    end

    test "accepts a lowered dual exactly while every edge at the vertex stays feasible" do
      {state, _} =
        3
        |> WeightedMatching.new([{0, 1, 10}, {0, 2, 4}], gcd: 1, max_weight: 10)
        |> WeightedMatching.solve()

      assert %{0 => 10, 1 => 10, 2 => 0} = state.dual

      # 10 - 2 + 0 = 8 = 2 * 4 on the unlisted edge, which is feasible; and
      # 8 + 10 = 18 = 2 * 9 keeps the matched one tight.
      assert {:ok, shifted} = WeightedMatching.shift_and_set(state, %{0 => -2}, [{0, 1, 9}])
      assert {_, %{0 => 1, 1 => 0}} = WeightedMatching.solve(shifted)

      # Two more down and the unlisted edge is at 6 < 8.
      assert WeightedMatching.shift_and_set(state, %{0 => -4}, [{0, 1, 8}]) == :error
    end

    test "refuses arguments outside its contract loudly" do
      state = WeightedMatching.new(3, [{0, 1, 10}, {0, 2, 8}], gcd: 1, max_weight: 10)

      assert_raise ArgumentError, ~r/even integer/, fn ->
        WeightedMatching.shift_and_set(state, %{0 => 3}, [])
      end

      assert_raise ArgumentError, ~r/even integer/, fn ->
        WeightedMatching.shift_and_set(state, %{7 => 2}, [])
      end

      assert_raise ArgumentError, ~r/two distinct vertices/, fn ->
        WeightedMatching.shift_and_set(state, %{}, [{1, 1, 4}])
      end

      assert_raise ArgumentError, ~r/two distinct vertices/, fn ->
        WeightedMatching.shift_and_set(state, %{}, [{0, 3, 4}])
      end
    end
  end

  describe "long paths" do
    test "a 40-vertex path is matched" do
      edges = for i <- 0..38, do: {i, i + 1, 10 + rem(i * 7, 5)}
      matching = WeightedMatching.solve(40, edges)
      assert map_size(matching) > 0
      assert valid_matching?(matching, edges)
    end
  end

  defp total_weight(matching, edges) do
    lookup = Map.new(edges, fn {a, b, w} -> {{a, b}, w} end)

    matching
    |> Map.to_list()
    |> Enum.uniq_by(fn {a, b} -> Enum.sort([a, b]) end)
    |> Enum.reduce(0, fn {a, b}, acc ->
      w = Map.get(lookup, {a, b}) || Map.fetch!(lookup, {b, a})
      acc + w
    end)
  end

  defp valid_matching?(matching, edges) do
    edge_set = MapSet.new(edges, fn {a, b, _w} -> Enum.sort([a, b]) end)

    Enum.all?(matching, fn {a, b} ->
      Map.get(matching, b) == a and MapSet.member?(edge_set, Enum.sort([a, b]))
    end)
  end
end

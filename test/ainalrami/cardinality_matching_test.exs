defmodule Ainalrami.CardinalityMatchingTest do
  @moduledoc """
  `Ainalrami.CardinalityMatching` against exhaustive search on random
  graphs: the matching's size, and the exposable set as "the vertices whose
  removal leaves the maximum matching's size unchanged".
  """

  use ExUnit.Case, async: true

  alias Ainalrami.CardinalityMatching

  test "maximum matchings and exposable sets agree with exhaustive search" do
    rng = :rand.seed_s(:exsss, {7, 11, 13})

    {checked, _rng} =
      Enum.reduce(1..3000, {0, rng}, fn _, {checked, rng} ->
        {n, rng} = :rand.uniform_s(11, rng)
        {density, rng} = :rand.uniform_s(9, rng)
        {edges, rng} = random_edges(n, density, rng)
        adj = adjacency(n, edges)

        match = CardinalityMatching.maximum(adj)
        nu = nu(Enum.to_list(0..(n - 1)//1), edges)

        assert map_size(match) == 2 * nu

        assert Enum.all?(match, fn {v, u} ->
                 Map.fetch!(match, u) == v and {min(u, v), max(u, v)} in edges
               end)

        case CardinalityMatching.exposable(adj) do
          {:ok, set} ->
            assert n - 2 * nu == 1

            expected =
              for v <- 0..(n - 1)//1,
                  nu(List.delete(Enum.to_list(0..(n - 1)//1), v), edges) == nu,
                  do: v

            assert Enum.sort(MapSet.to_list(set)) == expected, "n=#{n} edges=#{inspect(edges)}"
            {checked + 1, rng}

          :no ->
            assert n - 2 * nu != 1
            {checked, rng}
        end
      end)

    assert checked > 500
  end

  # The completability oracle's use: a matching kept while vertices die,
  # re-augmented from every exposed live vertex.
  test "augmenting from each exposed vertex around dead ones reaches a maximum matching" do
    rng = :rand.seed_s(:exsss, {17, 19, 23})

    Enum.reduce(1..2000, rng, fn _, rng ->
      {n, rng} = :rand.uniform_s(12, rng)
      {density, rng} = :rand.uniform_s(9, rng)
      {edges, rng} = random_edges(n, density, rng)
      adj = adjacency(n, edges)

      # A maximum matching of the whole graph, then some vertices die.
      match = CardinalityMatching.maximum(adj)

      {dead, rng} =
        Enum.reduce(0..(n - 1)//1, {MapSet.new(), rng}, fn v, {dead, rng} ->
          {roll, rng} = :rand.uniform_s(4, rng)
          {if(roll == 1, do: MapSet.put(dead, v), else: dead), rng}
        end)

      match =
        Enum.reduce(dead, match, fn v, match ->
          case Map.pop(match, v) do
            {nil, match} -> match
            {u, match} -> Map.delete(match, u)
          end
        end)

      live = Enum.reject(0..(n - 1)//1, &MapSet.member?(dead, &1))
      live_edges = Enum.filter(edges, fn {i, j} -> i in live and j in live end)

      match =
        Enum.reduce(live, match, fn v, match ->
          if is_map_key(match, v) do
            match
          else
            case CardinalityMatching.augment_from(adj, match, v, dead) do
              {:ok, match} ->
                assert is_map_key(match, v)
                match

              :none ->
                # Some maximum matching of the live graph leaves `v` exposed.
                assert nu(List.delete(live, v), live_edges) == nu(live, live_edges)
                match
            end
          end
        end)

      assert map_size(match) == 2 * nu(live, live_edges), "n=#{n} edges=#{inspect(edges)}"

      assert Enum.all?(match, fn {v, u} ->
               Map.fetch!(match, u) == v and {min(u, v), max(u, v)} in live_edges
             end)

      rng
    end)
  end

  # Larger graphs than exhaustive search can take, where blossoms nest
  # (the groups `contract/4` merges): the size against the weighted matcher
  # with every weight equal, and the search over a neighbour FUNCTION - the
  # dense oracle's form - against the same search over the tuple.
  test "maximum matchings of larger graphs agree with the weighted matcher" do
    rng = :rand.seed_s(:exsss, {29, 31, 37})

    Enum.reduce(1..300, rng, fn _, rng ->
      {k, rng} = :rand.uniform_s(120, rng)
      n = k + 20
      {degree, rng} = :rand.uniform_s(6, rng)
      {edges, rng} = random_sparse_edges(n, degree + 1, rng)
      adj = adjacency(n, edges)

      match = CardinalityMatching.maximum(adj)
      weighted = Ainalrami.WeightedMatching.solve(n, Enum.map(edges, fn {i, j} -> {i, j, 1} end))
      assert map_size(match) == map_size(weighted), "n=#{n} edges=#{inspect(edges)}"

      assert Enum.all?(match, fn {v, u} ->
               Map.fetch!(match, u) == v and {min(u, v), max(u, v)} in edges
             end)

      # From the greedy start alone, every exposed vertex searched over the
      # function form, as the dense oracle searches.
      row = fn v -> elem(adj, v) end

      grown =
        Enum.reduce(0..(n - 1)//1, %{}, fn v, m ->
          if is_map_key(m, v) do
            m
          else
            case CardinalityMatching.augment_from(row, m, v, MapSet.new()) do
              {:ok, m} -> m
              :none -> m
            end
          end
        end)

      assert map_size(grown) == map_size(match)
      rng
    end)
  end

  # A matching whose pairs lie outside `adj` is searched as `adj` plus those
  # pairs: the sparse oracle after the dense one has grown its matching.
  test "a search over a subgraph keeps pairs of the matching outside it" do
    rng = :rand.seed_s(:exsss, {41, 43, 47})

    Enum.reduce(1..300, rng, fn _, rng ->
      {k, rng} = :rand.uniform_s(60, rng)
      n = k + 10
      {edges, rng} = random_sparse_edges(n, 6, rng)
      dense = adjacency(n, edges)

      {sparse_edges, rng} =
        Enum.reduce(edges, {[], rng}, fn e, {acc, rng} ->
          {roll, rng} = :rand.uniform_s(3, rng)
          {if(roll == 1, do: acc, else: [e | acc]), rng}
        end)

      sparse = adjacency(n, sparse_edges)

      match = CardinalityMatching.maximum(dense)

      {dead, rng} =
        Enum.reduce(0..(n - 1)//1, {MapSet.new(), rng}, fn v, {dead, rng} ->
          {roll, rng} = :rand.uniform_s(5, rng)
          {if(roll == 1, do: MapSet.put(dead, v), else: dead), rng}
        end)

      match =
        Enum.reduce(dead, match, fn v, match ->
          case Map.pop(match, v) do
            {nil, match} -> match
            {u, match} -> Map.delete(match, u)
          end
        end)

      match =
        Enum.reduce(0..(n - 1)//1, match, fn v, match ->
          if MapSet.member?(dead, v) or is_map_key(match, v) do
            match
          else
            case CardinalityMatching.augment_from(sparse, match, v, dead) do
              {:ok, match} -> match
              :none -> match
            end
          end
        end)

      assert Enum.all?(match, fn {v, u} ->
               Map.fetch!(match, u) == v and {min(u, v), max(u, v)} in edges and
                 not MapSet.member?(dead, v)
             end)

      rng
    end)
  end

  defp random_sparse_edges(n, degree, rng) do
    Enum.reduce(0..(n - 1)//1, {MapSet.new(), rng}, fn i, {acc, rng} ->
      Enum.reduce(1..degree//1, {acc, rng}, fn _, {acc, rng} ->
        {j, rng} = :rand.uniform_s(n, rng)
        j = j - 1
        if j == i, do: {acc, rng}, else: {MapSet.put(acc, {min(i, j), max(i, j)}), rng}
      end)
    end)
    |> then(fn {set, rng} -> {Enum.sort(set), rng} end)
  end

  # `exposable_lazy/2` is `exposable/1` without the graph built: the same
  # answer on every graph, sparse to complete, odd and even orders.
  test "the lazy exposable set is the built graph's" do
    rng = :rand.seed_s(:exsss, {29, 31, 37})

    {checked, _rng} =
      Enum.reduce(1..1500, {0, rng}, fn _, {checked, rng} ->
        {n, rng} = :rand.uniform_s(70, rng)
        {density, rng} = :rand.uniform_s(10, rng)
        {edges, rng} = random_edges(n, density, rng)
        set = MapSet.new(edges)
        edge? = fn u, v -> MapSet.member?(set, {min(u, v), max(u, v)}) end

        built = CardinalityMatching.exposable(adjacency(n, edges))

        assert CardinalityMatching.exposable_lazy(n, edge?) == built,
               "n=#{n} edges=#{inspect(edges)}"

        {checked + if(match?({:ok, _}, built), do: 1, else: 0), rng}
      end)

    assert checked > 300
  end

  defp random_edges(n, density, rng) do
    pairs = for i <- 0..(n - 1)//1, j <- (i + 1)..(n - 1)//1, do: {i, j}

    Enum.reduce(pairs, {[], rng}, fn pair, {acc, rng} ->
      {roll, rng} = :rand.uniform_s(10, rng)
      {if(roll <= density, do: [pair | acc], else: acc), rng}
    end)
  end

  defp adjacency(n, edges) do
    edges
    |> Enum.reduce(Map.new(0..(n - 1)//1, &{&1, []}), fn {i, j}, acc ->
      acc |> Map.update!(i, &[j | &1]) |> Map.update!(j, &[i | &1])
    end)
    |> then(fn map ->
      List.to_tuple(for v <- 0..(n - 1)//1, do: Enum.sort(Map.fetch!(map, v)))
    end)
  end

  # Exhaustive: the first vertex is left out or paired with each neighbour.
  defp nu([], _edges), do: 0

  defp nu([v | rest], edges) do
    skip = nu(rest, edges)

    rest
    |> Enum.filter(&({min(v, &1), max(v, &1)} in edges))
    |> Enum.reduce(skip, fn u, best -> max(best, 1 + nu(List.delete(rest, u), edges)) end)
  end
end

defmodule Ainalrami.CardinalityMatching do
  @moduledoc """
  Maximum-cardinality matching in a general graph, and the vertices some
  maximum matching leaves exposed.

  `Ainalrami.Pairing` asks one question of a score group that this answers
  exactly: which players of the group can be the one left over by a
  largest matching of it (with a stand-in vertex added for "the bye", see
  `Pairing`'s odd bracket over the bye group). That set is the `D` of the
  Gallai-Edmonds decomposition: with `M` a maximum matching and `u` a
  vertex it leaves exposed, `D` is the set of vertices reachable from `u`
  by an alternating path of even length - flipping the path exposes its
  far end instead, and conversely every maximum matching that exposes `v`
  differs from `M` by such a path. Edmonds' search from `u`, which finds no
  augmenting path because `M` is maximum, labels exactly those vertices
  OUTER (blossoms contracted: every vertex of a blossom is outer).

  The search is the textbook one (Edmonds 1965, in the array form of the
  common O(n^3) implementation: `base`, parent links `p`, blossom marking
  through the least common ancestor). Only the single-exposed-vertex case
  is answered, which is the one `Pairing` needs (a graph of odd order with
  a near-perfect matching); anything else is `:no`.

  `augment_from/4` is the same search on the graph less a set of dead
  vertices, for `Pairing`'s completability oracle: a matching kept across a
  round's brackets, whose players leave the graph bracket by bracket. The
  search's state is proportional to the tree it grows, not to the graph
  (each vertex its own base until a blossom takes it, and a blossom merging
  the groups of vertices that share a base - smaller into larger - rather
  than relabelling the tree vertex by vertex), so a search that finds a
  short path costs a short path, and one that grows a tree over most of a
  large field does not pay for its size at every blossom. Its rows may be
  a function, for a graph too dense to build whole (`augment_from/4`).

  Checked against brute force (every vertex removed in turn, the maximum
  matching recomputed by exhaustive search), and on larger graphs against
  `Ainalrami.WeightedMatching` with every weight equal, in
  `test/ainalrami/cardinality_matching_test.exs`.
  """

  @doc """
  A maximum matching of the graph on vertices `0..n-1`, `adj` a tuple of
  neighbour lists (symmetric). Returns a map `v => mate` holding both ends
  of every pair.
  """
  def maximum(adj) do
    match = do_maximum(adj)

    # A pairing proof writes the answer down with its witness.
    if Ainalrami.Proof.recording?(),
      do: Ainalrami.Proof.cardinality(adj, maximum_claim("maximum", adj, match))

    match
  end

  defp do_maximum(adj) do
    n = tuple_size(adj)
    match = greedy(adj, n)

    Enum.reduce(0..(n - 1)//1, match, fn v, match ->
      if is_map_key(match, v) do
        match
      else
        case search(adj, match, v, MapSet.new()) do
          {:path, to, p} -> augment(to, p, match)
          {:none, _outer, _p} -> match
        end
      end
    end)
  end

  @doc """
  One augmenting search from the exposed vertex `root` of `match`, in the
  graph `adj` less the vertices in `dead` (which `match` must not cover):
  `{:ok, match}` with `root` matched, or `:none` when no augmenting path
  starts at `root` - and then some maximum matching of that graph leaves
  `root` exposed.

  `adj` may also be a function from a vertex to its neighbour list, for a
  graph too dense to build whole: the search asks only for the rows of the
  vertices it scans. The pairs of `match` need not be in `adj` - the
  search reaches a matched vertex's mate through `match` alone - so the
  graph searched is `adj` plus the pairs of `match`.
  """
  def augment_from(adj, match, root, dead) do
    case search(adj, match, root, dead) do
      {:path, to, p} ->
        if Ainalrami.Proof.recording?() do
          Ainalrami.Proof.cardinality(adj, %{
            "claim" => "augment",
            "matching" => pairs(match),
            "root" => root,
            "dead" => Enum.sort(dead),
            "path" => to |> path_to_root(p, match) |> Enum.reverse()
          })
        end

        {:ok, augment(to, p, match)}

      {:none, used, p} ->
        # The search's inner vertices are a Tutte set: what it reached, less
        # them, falls apart into one more odd piece than there are of them,
        # every piece inside what the matching covers plus the root.
        if Ainalrami.Proof.recording?() do
          Ainalrami.Proof.cardinality(adj, %{
            "claim" => "blocked",
            "matching" => pairs(match),
            "root" => root,
            "dead" => Enum.sort(dead),
            "barrier" => p |> Map.keys() |> Enum.reject(&MapSet.member?(used, &1)) |> Enum.sort()
          })
        end

        :none
    end
  end

  @doc """
  `{:ok, set}`: the vertices some maximum matching leaves exposed, when a
  maximum matching leaves exactly one vertex exposed; `:no` otherwise.
  """
  def exposable(adj) do
    n = tuple_size(adj)
    match = do_maximum(adj)

    case Enum.reject(0..(n - 1)//1, &is_map_key(match, &1)) do
      [u] ->
        {:none, outer, p} = search(adj, match, u, MapSet.new())

        # The witness: the matching, the Gallai-Edmonds barrier (the
        # neighbours of the exposable set outside it), and for each
        # exposable vertex the even alternating path from `u` that flips to
        # expose it, as the search's parent links.
        if Ainalrami.Proof.recording?() do
          Ainalrami.Proof.cardinality(adj, %{
            "claim" => "exposable",
            "matching" => pairs(match),
            "root" => u,
            "exposable" => Enum.sort(outer),
            "barrier" => barrier(adj, outer),
            "parent" => p |> Enum.sort() |> Enum.map(fn {v, q} -> [v, q] end)
          })
        end

        {:ok, outer}

      _ ->
        if Ainalrami.Proof.recording?(),
          do: Ainalrami.Proof.cardinality(adj, maximum_claim("not_exposable", adj, match))

        :no
    end
  end

  # A maximum matching's witness: the matching and the Gallai-Edmonds
  # barrier - the neighbours, outside it, of the set some maximum matching
  # leaves exposed (everything an alternating search from an exposed vertex
  # reaches at even depth). Removing it leaves exactly as many more odd
  # pieces than its size as the matching leaves vertices exposed, which is
  # the Tutte-Berge bound met.
  defp maximum_claim(claim, adj, match) do
    exposed = Enum.reject(0..(tuple_size(adj) - 1)//1, &is_map_key(match, &1))

    d =
      Enum.reduce(exposed, MapSet.new(), fn u, acc ->
        {:none, outer, _p} = search(adj, match, u, MapSet.new())
        MapSet.union(acc, outer)
      end)

    %{"claim" => claim, "matching" => pairs(match), "barrier" => barrier(adj, d)}
  end

  defp barrier(adj, d) do
    d
    |> Enum.flat_map(&neighbours(adj, &1))
    |> Enum.reject(&MapSet.member?(d, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp pairs(match) do
    match
    |> Enum.filter(fn {u, v} -> u < v end)
    |> Enum.sort()
    |> Enum.map(fn {u, v} -> [u, v] end)
  end

  # The augmenting path `augment/3` flips, from the exposed end found back
  # to the root.
  defp path_to_root(v, p, match) do
    pv = Map.fetch!(p, v)

    case Map.get(match, pv) do
      nil -> [v, pv]
      ppv -> [v, pv | path_to_root(ppv, p, match)]
    end
  end

  defp greedy(adj, n) do
    Enum.reduce(0..(n - 1)//1, %{}, fn v, match ->
      if is_map_key(match, v) do
        match
      else
        case Enum.find(elem(adj, v), &(not is_map_key(match, &1))) do
          nil -> match
          u -> match |> Map.put(v, u) |> Map.put(u, v)
        end
      end
    end)
  end

  # Edmonds' search from `root`, never entering a vertex of `dead`:
  # `{:path, exposed vertex, parents}` when an augmenting path exists, else
  # `{:none, outer vertices, parents}`. `base` holds only the vertices a blossom has
  # relabelled (`base_of/2`).
  defp search(adj, match, root, dead) do
    st = %{
      group: %{},
      gbase: %{},
      members: %{},
      p: %{},
      used: MapSet.new([root]),
      match: match,
      root: root,
      dead: dead
    }

    bfs(:queue.from_list([root]), adj, st)
  end

  # A vertex's base, through the group it was contracted into (see
  # `contract/4`); a vertex no blossom has taken is its own.
  defp base_of(st, v) do
    g = Map.get(st.group, v, v)
    Map.get(st.gbase, g, g)
  end

  defp bfs(queue, adj, st) do
    case :queue.out(queue) do
      {:empty, _} ->
        {:none, st.used, st.p}

      {{:value, v}, queue} ->
        case scan(neighbours(adj, v), v, queue, st) do
          {:path, _to, _p} = found -> found
          {:cont, queue, st} -> bfs(queue, adj, st)
        end
    end
  end

  defp neighbours(adj, v) when is_tuple(adj), do: elem(adj, v)
  defp neighbours(adj, v) when is_function(adj, 1), do: adj.(v)

  defp scan([], _v, queue, st), do: {:cont, queue, st}

  defp scan([to | rest], v, queue, st) do
    cond do
      MapSet.member?(st.dead, to) or base_of(st, v) == base_of(st, to) or
          Map.get(st.match, v) == to ->
        scan(rest, v, queue, st)

      to == st.root or
          (is_map_key(st.match, to) and is_map_key(st.p, Map.fetch!(st.match, to))) ->
        {queue, st} = contract(v, to, queue, st)
        scan(rest, v, queue, st)

      not is_map_key(st.p, to) ->
        p = Map.put(st.p, to, v)

        case Map.get(st.match, to) do
          nil ->
            {:path, to, p}

          mt ->
            st = %{st | p: p, used: MapSet.put(st.used, mt)}
            scan(rest, v, :queue.in(mt, queue), st)
        end

      true ->
        scan(rest, v, queue, st)
    end
  end

  # An edge between two outer vertices of the tree closes an odd cycle:
  # every vertex whose base lies on it takes the cycle's base, and becomes
  # outer. Only a vertex of the tree can (an outer one, or an inner one with
  # a parent link), and the ones newly outer are queued in index order.
  #
  # The vertices sharing a base are kept as one group (`group`, `members`,
  # the group's base in `gbase`; a vertex in no group is its own), so a
  # contraction merges the groups of the cycle's bases - the smaller ones
  # into the largest - and names the cycle's base as the merged group's,
  # rather than scanning the whole tree, sorted, for vertices to relabel: a
  # search that grew a tree over most of a 1,000-player field spent two
  # thirds of its time in those scans. Every vertex of a group of more than
  # one was made outer by the contraction that formed it, so the vertices
  # newly outer are the cycle's bases that are not yet (its inner
  # vertices), exactly the ones the scan over the tree queued.
  defp contract(v, to, queue, st) do
    cur = lca(v, to, st)
    {p, blossom} = mark_path(v, cur, to, st.p, MapSet.new(), st)
    {p, blossom} = mark_path(to, cur, v, p, blossom, st)

    fresh =
      blossom
      |> Enum.filter(fn b -> members_of(st, group_of(st, b)) == [b] end)
      |> Enum.reject(&MapSet.member?(st.used, &1))
      |> Enum.sort()

    used = Enum.reduce(fresh, st.used, &MapSet.put(&2, &1))
    queue = Enum.reduce(fresh, queue, &:queue.in(&1, &2))

    groups = blossom |> MapSet.put(cur) |> Enum.map(&group_of(st, &1)) |> Enum.uniq()
    survivor = Enum.max_by(groups, &length(members_of(st, &1)))

    st =
      groups
      |> List.delete(survivor)
      |> Enum.reduce(st, fn g, st ->
        moved = members_of(st, g)

        %{
          st
          | group: Enum.reduce(moved, st.group, &Map.put(&2, &1, survivor)),
            members:
              st.members
              |> Map.delete(g)
              |> Map.put(survivor, moved ++ members_of(st, survivor)),
            gbase: Map.delete(st.gbase, g)
        }
      end)

    {queue, %{st | p: p, used: used, gbase: Map.put(st.gbase, survivor, cur)}}
  end

  defp group_of(st, v), do: Map.get(st.group, v, v)
  defp members_of(st, g), do: Map.get(st.members, g, [g])

  defp lca(a, b, st), do: rise_b(b, rise_a(a, MapSet.new(), st), st)

  defp rise_a(a, seen, st) do
    a = base_of(st, a)
    seen = MapSet.put(seen, a)

    case Map.get(st.match, a) do
      nil -> seen
      ma -> rise_a(Map.fetch!(st.p, ma), seen, st)
    end
  end

  defp rise_b(b, seen, st) do
    b = base_of(st, b)

    if MapSet.member?(seen, b),
      do: b,
      else: rise_b(Map.fetch!(st.p, Map.fetch!(st.match, b)), seen, st)
  end

  defp mark_path(v, b, children, p, blossom, st) do
    if base_of(st, v) == b do
      {p, blossom}
    else
      mv = Map.fetch!(st.match, v)

      blossom =
        blossom |> MapSet.put(base_of(st, v)) |> MapSet.put(base_of(st, mv))

      p = Map.put(p, v, children)
      mark_path(Map.fetch!(p, mv), b, mv, p, blossom, st)
    end
  end

  defp augment(nil, _p, match), do: match

  defp augment(v, p, match) do
    pv = Map.fetch!(p, v)
    ppv = Map.get(match, pv)
    augment(ppv, p, match |> Map.put(v, pv) |> Map.put(pv, v))
  end
end

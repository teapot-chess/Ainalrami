defmodule Ainalrami.Dubov.Graph do
  @moduledoc """
  The matching questions the Dubov procedure asks, over one round's
  compatibility graph. None of them chooses a pairing - the text does that
  by order - they answer "can these players still be paired?" and "how
  many pairs of a kind must any pairing contain?".

  Two players are compatible when the absolute criteria let them meet:
  [C1] they have not played each other (an arbiter's `XXP` exclusion
  counts as having played, as in the Dutch engine), and [C3] they do not
  share an absolute colour preference. [C3] has no topscorer exception in
  the Dubov system.

  The graph is the team engine's `Ainalrami.TeamPairing.Field` - one
  adjacency per round, bitmasks indexed by position - built over stand-in
  `%Team{}` structs whose "opponents" are exactly the incompatible players.
  `Field.feasible?/2` is [C4]'s oracle, `Field.min_cross/3` is 3.2.1's
  minimum, and `TeamPairing.Matching.bipartite_perfect?/3` answers 3.2.4
  and 3.2.6, all unchanged. The two questions the team engine never asks -
  the most pairs of a kind (3.2.2's [C7], 3.2.4's "unavoidably") and the
  restricted perfect matching of 3.2.4 - are one maximum-weight matching
  (`Ainalrami.WeightedMatching`) and one maximum-cardinality matching
  (`Ainalrami.CardinalityMatching`).
  """

  import Bitwise

  alias Ainalrami.{CardinalityMatching, WeightedMatching}
  alias Ainalrami.TeamPairing.{Field, Matching, Team}

  @doc """
  The round's graph over `players` (`%Dubov.Player{}`), given
  `incompatible?.(a, b)` for two of them.
  """
  def new(players, incompatible?) do
    teams =
      Enum.map(players, fn p ->
        bad = for q <- players, q.rank != p.rank, incompatible?.(p, q), do: q.rank
        %Team{tpn: p.rank, opponents: bad}
      end)

    field = Field.new(teams)

    if field == nil,
      do: raise(ArgumentError, "Dubov graph: duplicate ranks or one-sided incompatibility")

    field
  end

  defp teams(ranks), do: Enum.map(ranks, &%Team{tpn: &1})

  @doc "[C4]: whether the players `ranks` can all be paired among themselves."
  def feasible?([], _field), do: true
  def feasible?(ranks, field), do: Field.feasible?(teams(ranks), field)

  @doc "Whether `a` and `b` may meet."
  def allowed?(field, a, b) do
    i = Map.fetch!(field.index, a)
    j = Map.fetch!(field.index, b)
    (elem(field.allowed, i) >>> j &&& 1) == 1
  end

  @doc """
  3.2.1: the fewest players of `lower` that must join `residents` for the
  residents to be paired legally with everybody else still pairable - the
  least number of resident-to-lower pairs in a perfect matching of both.
  nil when the two together cannot be paired at all.
  """
  def min_upfloaters(residents, lower, field) do
    case lower do
      [] -> if feasible?(residents, field), do: 0
      _ -> Field.min_cross(teams(residents), teams(lower), field)
    end
  end

  @doc """
  The most pairs joining `first` to `second` in any perfect matching of the
  two together, or nil when there is none. 3.2.2's [C7] is the bracket
  less twice this, over its White and Black seekers; 3.2.4's "unavoidably
  paired together" is the smaller subgroup less this, halved.
  """
  def max_cross(first, second, field) do
    order = first ++ second
    n = length(order)
    nf = length(first)

    cond do
      n == 0 ->
        0

      rem(n, 2) == 1 ->
        nil

      true ->
        local = List.to_tuple(order)
        base = n + 1

        edges =
          for i <- 0..(n - 2)//1,
              j <- (i + 1)..(n - 1)//1,
              allowed?(field, elem(local, i), elem(local, j)),
              do: {i, j, base + if(i < nf != j < nf, do: 1, else: 0)}

        mate = if n <= 1, do: %{}, else: WeightedMatching.solve(n, edges)

        if map_size(mate) == n,
          do: Enum.count(mate, fn {i, j} -> i < j and i < nf != j < nf end)
    end
  end

  @doc """
  Whether `tops` and `bottoms` (equal sizes) can be paired top against
  bottom - 3.2.4's "can yield a legal pairing" and 3.2.6's completion test.
  """
  def bipartite?([], [], _field), do: true

  def bipartite?(tops, bottoms, field) do
    top_idx = Enum.map(tops, &Map.fetch!(field.index, &1))
    mask = Enum.reduce(bottoms, 0, &(&2 ||| 1 <<< Map.fetch!(field.index, &1)))
    Matching.bipartite_perfect?(top_idx, mask, field.allowed)
  end

  @doc """
  The least number of `denied?` pairs in a top-against-bottom pairing of
  `tops` and `bottoms`, or nil when there is none. For 3.2.6 under reading
  D2 (b) only.
  """
  def min_denied([], [], _field, _denied?), do: 0

  def min_denied(tops, bottoms, field, denied?) do
    order = tops ++ bottoms
    n = length(order)
    nt = length(tops)
    local = List.to_tuple(order)
    base = n + 1

    edges =
      for i <- 0..(nt - 1)//1,
          j <- nt..(n - 1)//1,
          a = elem(local, i),
          b = elem(local, j),
          allowed?(field, a, b),
          do: {i, j, base + if(denied?.(a, b), do: 0, else: 1)}

    mate = WeightedMatching.solve(n, edges)

    if map_size(mate) == n do
      Enum.count(mate, fn {i, j} ->
        i < nt and j >= nt and denied?.(elem(local, i), elem(local, j))
      end)
    end
  end

  @doc """
  Whether `players` have a perfect matching in which only the pairs
  `keep?.(a, b)` admits are used - 3.2.4's test of a shift set.
  """
  def perfect_restricted?([], _field, _keep?), do: true

  def perfect_restricted?(players, field, keep?) do
    n = length(players)

    if rem(n, 2) == 1 do
      false
    else
      local = List.to_tuple(players)

      adj =
        List.to_tuple(
          for i <- 0..(n - 1)//1 do
            a = elem(local, i)

            for j <- 0..(n - 1)//1,
                j != i,
                b = elem(local, j),
                allowed?(field, a, b),
                keep?.(a, b),
                do: j
          end
        )

      map_size(CardinalityMatching.maximum(adj)) == n
    end
  end
end

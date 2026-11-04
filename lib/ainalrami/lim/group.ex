defmodule Ainalrami.Lim.Group do
  @moduledoc """
  The pairing of one scoregroup (C.04.4.3 Articles 2-4), in two steps.

  ## 1. Who floats (2.3, 3)

  The players of the group `M` - its residents and the floaters that came
  in - are split into the players paired here, `P`, and the floaters `F`
  sent on to the next group (down while pairing downward, up while
  pairing upward; the median group sends nobody). Of the splits for which
  `P` can be paired among themselves and everybody else still unpaired can
  be paired too (reading L7: 2.6's cracking done in advance), the one that
  is, in this order (reading L4):

    1. the most pairs in the group (2.3: only players without a partner,
       and one to make the number even, are transferred; 4.4);
    2. fewest floaters of 3.9's type a, then b, then c - a floater that
       already floated into this group and has no compatible player in the
       adjacent group, one that floated in and has, one from the group with
       none;
    3. fewest floaters who floated in the round before (3.10);
    4. fewest floaters who are not due the colour most of the group is due
       (3.2.2: "tend to equalise the number of players due different
       colours");
    5. pairing downward the lowest-ranked players, upward the highest
       ranked (3.2.4, 3.3, 3.4; 4.4.1 and 4.4.2 follow from it).

  Every criterion is a sum over the floaters, so the split is one
  maximum-weight perfect matching over every unpaired player: a pair inside
  `M` is a pair of this group, an `M` player matched outside it a floater,
  and each criterion is a digit of the weight. The last digit gives a
  floater at position `i` the weight `2^i`, which makes the best set
  unique.

  ## 2. The pairs (2.4, 3.6-3.8, 4, 5.2)

  Of the pairings of `P`, those denying the fewest due colours (5.2's
  second scrutiny, reading L6), and of those the first in scrutiny order
  (reading L5): the incoming floaters first, each taking the first partner
  in its list (3.6-3.8); then the residents left, in pairing-number order
  (downward from the top, upward from the bottom: 4.1), split into halves
  (2.4), each in turn taking the first partner in its list - the other
  half in order, then its own half from the far end back (4.2-4.3). The
  pairing is fixed one choice at a time, each kept only if a pairing with
  the fewest denials still completes it.

  ## Two ways to the same answer

  `Ainalrami.MatchingWalk` chooses between the original computations and
  faster ones that give the same answer (`docs/perf-burstein-lim-2026-11.md`):
  the split solved on the group plus stand-in "float" vertices, checked
  against the players outside and falling back to the full matching when
  the check fails; and the pairs walk on one persistent matcher, pruned by
  the optimal dual.
  """

  alias Ainalrami.Dubov.Graph
  alias Ainalrami.Lim.{Colour, Order}
  alias Ainalrami.{MatchingWalk, WeightedMatching}

  @doc """
  The floaters of group `members` (`%Lim.Player{}`) whose own score is
  `score`, pairing in `direction` (`:down`, `:up`, `:median`), with
  `adjacent` the residents of the group the floaters would go to and
  `outside` everybody else still unpaired. `{:ok, paired, floaters}` or
  `:error` when nobody can complete the round.
  """
  def floaters(members, _score, :median, _adjacent, outside, field) do
    if Graph.feasible?(Enum.map(members ++ outside, & &1.rank), field),
      do: {:ok, members, []},
      else: :error
  end

  def floaters(members, score, direction, adjacent, outside, field) do
    weights = split_weights(members, score, direction, adjacent, field)

    case MatchingWalk.mode() do
      :old ->
        floaters_full(members, outside, field, weights)

      :new ->
        floaters_relaxed(members, outside, field, weights)

      :check ->
        old = floaters_full(members, outside, field, weights)
        new = floaters_relaxed(members, outside, field, weights)
        MatchingWalk.same!("Lim floaters", split_ranks(old), split_ranks(new))
        old
    end
  end

  defp split_ranks({:ok, paired, floating}),
    do: {:ok, Enum.map(paired, & &1.rank), Enum.map(floating, & &1.rank)}

  defp split_ranks(:error), do: :error

  # The split as one matching over the group and everybody still unpaired.
  defp floaters_full(members, outside, field, {unit, pair_value, values}) do
    m = length(members)
    vertices = members ++ outside
    n = length(vertices)
    local = List.to_tuple(vertices)

    edges =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          a = elem(local, i),
          b = elem(local, j),
          Graph.allowed?(field, a.rank, b.rank) do
        value =
          cond do
            i < m and j < m -> pair_value
            i < m -> values[a.rank]
            true -> 0
          end

        {i, j, unit + value}
      end

    mate = WeightedMatching.solve(n, edges)

    if map_size(mate) == n do
      {paired, floating} = Enum.split_with(0..(m - 1)//1, &(mate[&1] < m))
      {:ok, Enum.map(paired, &elem(local, &1)), Enum.map(floating, &elem(local, &1))}
    else
      :error
    end
  end

  # Proposal 2 of `docs/perf-burstein-lim-2026-11.md`: the same split on
  # the group alone. The players outside enter the full matching only as
  # "somebody for a floater to meet", and a floater's value never depended
  # on whom, so they are replaced by `m` float vertices: a member reaching
  # at least one outside player has an edge to each at its float value, and
  # the float vertices pair off among themselves at the base unit. Every
  # split the full matching can reach is reachable here at the same value,
  # so the optimum `F` here is at least as good; the tie digit makes it
  # unique. If the players outside plus `F` can be paired with no two of
  # `F` meeting (two floaters meeting would be a pair of the group, not two
  # floats), the full matching can reach `F` too, and it is its answer.
  # Otherwise, or with no perfect matching here, the full solve decides.
  defp floaters_relaxed(members, outside, field, {unit, pair_value, values} = weights) do
    m = length(members)
    local = List.to_tuple(members)
    outside_ranks = Enum.map(outside, & &1.rank)

    reach? = fn a -> Enum.any?(outside_ranks, &Graph.allowed?(field, a.rank, &1)) end

    pair_edges =
      for i <- 0..(m - 2)//1,
          j <- (i + 1)..(m - 1)//1,
          Graph.allowed?(field, elem(local, i).rank, elem(local, j).rank),
          do: {i, j, unit + pair_value}

    float_edges =
      for i <- 0..(m - 1)//1,
          a = elem(local, i),
          reach?.(a),
          k <- m..(2 * m - 1)//1,
          do: {i, k, unit + values[a.rank]}

    spare_edges = for k <- m..(2 * m - 2)//1, l <- (k + 1)..(2 * m - 1)//1, do: {k, l, unit}

    mate = WeightedMatching.solve(2 * m, pair_edges ++ float_edges ++ spare_edges)

    with true <- map_size(mate) == 2 * m,
         {paired, floating} = Enum.split_with(0..(m - 1)//1, &(mate[&1] < m)),
         floating = Enum.map(floating, &elem(local, &1)),
         ranks = MapSet.new(floating, & &1.rank),
         true <- rest_pairable?(outside_ranks, ranks, field) do
      MatchingWalk.count(:floater_relaxed)
      {:ok, Enum.map(paired, &elem(local, &1)), floating}
    else
      _ ->
        MatchingWalk.count(:floater_fallback)
        floaters_full(members, outside, field, weights)
    end
  end

  # The players outside and the floaters `ranks` can all be paired, no two
  # floaters together. (The sabotage arms are the corpus run's sensitivity
  # check: no check at all, and the plain feasibility test the prototype's
  # review caught.)
  defp rest_pairable?(outside_ranks, ranks, field) do
    players = outside_ranks ++ MapSet.to_list(ranks)

    cond do
      MatchingWalk.sabotage?(:floater_check) ->
        true

      MatchingWalk.sabotage?(:floater_feasible) ->
        Graph.feasible?(players, field)

      true ->
        Graph.perfect_restricted?(
          players,
          field,
          &(not (MapSet.member?(ranks, &1) and MapSet.member?(ranks, &2)))
        )
    end
  end

  # The weights both matchings share: `{unit, pair_value, %{rank => value
  # of floating}}`.
  defp split_weights(members, score, direction, adjacent, field) do
    m = length(members)

    order = Enum.sort_by(members, & &1.rank, if(direction == :down, do: :asc, else: :desc))
    pos = order |> Enum.with_index() |> Map.new(fn {p, i} -> {p.rank, i} end)
    majority = majority(members)

    base = m + 1
    top = Integer.pow(base, 5)
    tie = Integer.pow(2, m + 1)
    pair_value = (m + 1) * top * tie
    unit = (m + 1) * pair_value

    float_value = fn p ->
      incoming? = p.score != score
      reach? = Enum.any?(adjacent, &Graph.allowed?(field, p.rank, &1.rank))

      penalty =
        bit(incoming? and not reach?) * Integer.pow(base, 4) +
          bit(incoming? and reach?) * Integer.pow(base, 3) +
          bit(not incoming? and not reach?) * Integer.pow(base, 2) +
          bit(p.floated?) * base +
          bit(majority != nil and p.colour != majority)

      (top - penalty) * tie + Integer.pow(2, pos[p.rank])
    end

    {unit, pair_value, Map.new(members, &{&1.rank, float_value.(&1)})}
  end

  defp bit(true), do: 1
  defp bit(false), do: 0

  # 3.2.2: the colour most of the group is due, nil when it is even.
  defp majority(members) do
    whites = Enum.count(members, &(&1.colour == :white))
    blacks = Enum.count(members, &(&1.colour == :black))

    cond do
      whites > blacks -> :white
      blacks > whites -> :black
      true -> nil
    end
  end

  @doc """
  The pairs of `paired` (an even number of `%Lim.Player{}` that can be
  paired among themselves) in a group of score `score` pairing in
  `direction`. `colour` is `{median, initial}` for `Lim.Colour`.
  Returns `[{x, y}]`, in the order they were fixed.
  """
  def pairs([], _score, _direction, _field, _colour), do: []

  def pairs(paired, score, direction, field, colour) do
    case MatchingWalk.mode() do
      :old ->
        pairs_old(paired, score, direction, field, colour)

      :new ->
        pairs_new(paired, score, direction, field, colour)

      :check ->
        old = pairs_old(paired, score, direction, field, colour)
        new = pairs_new(paired, score, direction, field, colour)
        MatchingWalk.same!("Lim pairs", ranks(old), ranks(new))
        old
    end
  end

  defp ranks(pairs), do: Enum.map(pairs, fn {a, b} -> {a.rank, b.rank} end)

  defp pairs_old(paired, score, direction, field, {median, initial}) do
    n = length(paired)
    local = List.to_tuple(paired)
    index = paired |> Enum.with_index() |> Map.new(fn {p, i} -> {p.rank, i} end)
    unit = 4 * n

    edges =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          a = elem(local, i),
          b = elem(local, j),
          Graph.allowed?(field, a.rank, b.rank),
          do: {i, j, unit + 2 - Colour.denied(a, b, score, median, initial)}

    {best, witness} = solve(n, edges)
    if map_size(witness) != n, do: raise("Lim group: the paired players cannot be paired")

    by_rank = Map.new(paired, &{&1.rank, &1})

    # A trial (pairs fixed so far, by rank) is kept when some pairing with
    # the fewest denials still contains it; the matching that shows it is
    # the next witness.
    check = fn partner ->
      fixed = Map.new(partner, fn {a, b} -> {index[a], index[b]} end)

      case solve(n, restrict(edges, fixed)) do
        {^best, mate} when map_size(mate) == n -> {:ok, mate}
        _ -> :no
      end
    end

    witness = Map.new(witness, fn {i, j} -> {elem(local, i).rank, elem(local, j).rank} end)

    paired
    |> Order.new(score, direction)
    |> walk(%{}, witness, check, index, local, [])
    |> Enum.map(fn {a, b} -> {by_rank[a], by_rank[b]} end)
  end

  # Each step: the next player in scrutiny order and their partners in
  # order; the first partner some best pairing still allows is fixed. A
  # choice the witness already makes needs no solve.
  defp walk(order, partner, witness, check, index, local, acc) do
    case Order.next(order, partner) do
      :done ->
        Enum.reverse(acc)

      {picker, candidates} ->
        Enum.reduce_while(candidates, nil, fn c, nil ->
          trial = partner |> Map.put(picker.rank, c.rank) |> Map.put(c.rank, picker.rank)

          if witness[picker.rank] == c.rank do
            {:halt, {trial, witness}}
          else
            case check.(trial) do
              {:ok, mate} ->
                {:halt,
                 {trial,
                  Map.new(mate, fn {i, j} -> {elem(local, i).rank, elem(local, j).rank} end)}}

              :no ->
                {:cont, nil}
            end
          end
        end)
        |> case do
          nil ->
            raise "Lim group: no partner for #{picker.rank} reaches the best pairing"

          {partner, witness} ->
            walk(order, partner, witness, check, index, local, [
              {picker.rank, partner[picker.rank]} | acc
            ])
        end
    end
  end

  # The same walk on one persistent matcher (`Ainalrami.MatchingWalk`),
  # solved at every step on exactly the graph the pairs fixed so far leave;
  # its matching is the witness, and a partner whose edge the optimal dual
  # says is not tight is skipped unsolved.
  defp pairs_new(paired, score, direction, field, {median, initial}) do
    n = length(paired)
    local = List.to_tuple(paired)
    index = paired |> Enum.with_index() |> Map.new(fn {p, i} -> {p.rank, i} end)
    unit = 4 * n

    edges =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          a = elem(local, i),
          b = elem(local, j),
          Graph.allowed?(field, a.rank, b.rank),
          do: {i, j, unit + 2 - Colour.denied(a, b, score, median, initial)}

    {state, best} =
      case MatchingWalk.start(n, edges) do
        {state, best, true} -> {state, best}
        _ -> raise("Lim group: the paired players cannot be paired")
      end

    by_rank = Map.new(paired, &{&1.rank, &1})

    paired
    |> Order.new(score, direction)
    |> walk_new(%{}, state, {n, best, index}, [])
    |> Enum.map(fn {a, b} -> {by_rank[a], by_rank[b]} end)
  end

  defp walk_new(order, partner, state, {n, best, index} = ctx, acc) do
    case Order.next(order, partner) do
      :done ->
        Enum.reverse(acc)

      {picker, candidates} ->
        i = index[picker.rank]
        tight = MatchingWalk.tight(state, i)
        witness = MatchingWalk.mate_of(state, i)

        Enum.reduce_while(candidates, nil, fn c, nil ->
          j = index[c.rank]
          trial = partner |> Map.put(picker.rank, c.rank) |> Map.put(c.rank, picker.rank)

          cond do
            witness == j ->
              {:halt, {trial, MatchingWalk.lock_pair(state, i, j, n, best)}}

            tight != nil and not MapSet.member?(tight, j) ->
              MatchingWalk.count(:pruned)
              {:cont, nil}

            true ->
              case MatchingWalk.settle(MatchingWalk.restrict_pair(state, i, j), n, best) do
                {:ok, state} -> {:halt, {trial, state}}
                :no -> {:cont, nil}
              end
          end
        end)
        |> case do
          nil ->
            raise "Lim group: no partner for #{picker.rank} reaches the best pairing"

          {partner, state} ->
            walk_new(order, partner, state, ctx, [{picker.rank, partner[picker.rank]} | acc])
        end
    end
  end

  defp solve(n, edges) do
    mate = WeightedMatching.solve(n, edges)
    weights = Map.new(edges, fn {i, j, w} -> {{i, j}, w} end)
    {for({i, j} <- mate, i < j, do: Map.fetch!(weights, {i, j})) |> Enum.sum(), mate}
  end

  defp restrict(edges, fixed) do
    Enum.filter(edges, fn {i, j, _} -> keep?(fixed, i, j) and keep?(fixed, j, i) end)
  end

  defp keep?(fixed, i, j) do
    case Map.fetch(fixed, i) do
      :error -> true
      {:ok, partner} -> partner == j
    end
  end
end

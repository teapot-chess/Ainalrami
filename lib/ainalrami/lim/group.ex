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
  """

  alias Ainalrami.Dubov.Graph
  alias Ainalrami.Lim.{Colour, Order}
  alias Ainalrami.WeightedMatching

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
    m = length(members)
    vertices = members ++ outside
    n = length(vertices)
    local = List.to_tuple(vertices)

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

    values = Map.new(members, &{&1.rank, float_value.(&1)})

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

  def pairs(paired, score, direction, field, {median, initial}) do
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

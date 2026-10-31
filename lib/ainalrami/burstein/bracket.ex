defmodule Ainalrami.Burstein.Bracket do
  @moduledoc """
  C.04.4.2 Article 3.2: the pairing of one bracket - "the first pairing
  (as ordered according to Article 4) that complies best with all the
  pairing criteria".

  ## One matching for the whole rest of the round

  The criteria reach past the bracket: [C4] asks that everybody not yet
  paired can still be paired, [C6] scores the players the bracket sends
  down, and [C7] asks how well the *next* bracket - those floaters plus
  the next scoregroup - can then be paired. A perfect matching of every
  player still unpaired (the bracket `B` and everybody below it, `L`)
  answers all of them at once, the way the Dutch engine and bbpPairings
  pair a bracket: a pair inside `B` is a pair of this bracket, a `B`
  player matched into `L` is an outgoing floater, and the floaters
  together with `R2` (the next scoregroup's residents) are the next
  bracket. Each criterion is a sum over the matching's edges, so each
  becomes one "digit" of the edge weight, most significant first:

    1. [C5] the pairs inside `B`, as many as possible;
    2. [C6] the floaters at each score, highest score first, as few as
       possible - with the number of floaters fixed by [C5], fewest at the
       top score, then fewest at the next, is exactly "the scores, in
       descending order, as low as possible";
    3. [C7], read as B5: the next bracket's own [C5] (pairs inside
       `F + R2`) and then its [C6] (its floaters into `L - R2` by score);
    4. [C8] the pairs inside `B` that deny a colour preference, as few as
       possible.

  Digits run from -n to n, so base 2n + 3 keeps them apart; every edge also
  carries one unit above the top digit, so a heavier matching is always a
  larger one, and on a field where a perfect matching exists ([C4], checked
  before) the maximum is perfect. Weights are bignums; the matching
  (`Ainalrami.WeightedMatching`) does not mind.

  ## The first in 4.3's order

  With the best value `W*` known, the pairing is fixed one BSN at a time
  (`Ainalrami.Burstein.Order`): BSN 1's opponent is the largest BSN for
  which some matching still reaches `W*`, else 0 (float); then BSN 2, and
  so on. A matching found on the way is kept as a witness, so a choice it
  already makes needs no further solve.
  """

  alias Ainalrami.Burstein.Player
  alias Ainalrami.Dubov.Graph
  alias Ainalrami.WeightedMatching

  @doc """
  Pairs the bracket `bracket` (`%Player{}`, residents and incoming
  floaters) over `lower` (everybody below it, still unpaired) on the
  round's compatibility graph `field` (`Ainalrami.Dubov.Graph`).

  `{:ok, %{pairs: [{a, b}], floaters: [%Player{}], bsn: [rank]}}` - pairs
  as players in BSN order, smaller BSN first - or `:error` when the
  players cannot all be paired.
  """
  def pair(bracket, lower, field) do
    bracket = Enum.sort_by(bracket, &Player.ranking_key/1)
    next_score = lower |> Enum.map(& &1.score) |> Enum.max(fn -> nil end)
    {r2, l2} = Enum.split_with(lower, &(&1.score == next_score))

    vertices = bracket ++ r2 ++ l2
    nb = length(bracket)
    nr = length(r2)
    n = length(vertices)
    local = List.to_tuple(vertices)
    side = fn i -> if i < nb, do: :b, else: if(i < nb + nr, do: :r, else: :l) end

    levels_b = bracket |> Enum.map(& &1.score) |> Enum.uniq() |> Enum.sort(:desc)
    levels_n = (bracket ++ r2) |> Enum.map(& &1.score) |> Enum.uniq() |> Enum.sort(:desc)

    # Digit positions, most significant first.
    c5 = 0
    c6 = Map.new(Enum.with_index(levels_b, 1))
    c7_pairs = length(levels_b) + 1
    c7 = Map.new(levels_n, fn s -> {s, c7_pairs + 1 + Enum.find_index(levels_n, &(&1 == s))} end)
    c8 = c7_pairs + length(levels_n) + 1
    digits = c8 + 1
    base = 2 * n + 3
    unit = Integer.pow(base, digits)
    place = fn pos -> Integer.pow(base, digits - 1 - pos) end

    value = fn i, j ->
      a = elem(local, i)
      b = elem(local, j)

      case {side.(i), side.(j)} do
        {:b, :b} ->
          place.(c5) - if(denied?(a, b), do: place.(c8), else: 0)

        {:b, :r} ->
          -place.(c6[a.score]) + place.(c7_pairs)

        {:b, :l} ->
          -place.(c6[a.score]) - place.(c7[a.score])

        {:r, :r} ->
          place.(c7_pairs)

        {:r, :l} ->
          -place.(c7[a.score])

        {:l, :l} ->
          0
      end
    end

    edges =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          Graph.allowed?(field, elem(local, i).rank, elem(local, j).rank),
          do: {i, j, unit + value.(i, j)}

    case solve(n, edges) do
      {weight, mate} when map_size(mate) == n ->
        mate = first_in_order(nb, n, edges, weight, mate)

        pairs =
          for i <- 0..(nb - 1)//1,
              j = mate[i],
              j > i,
              j < nb,
              do: {elem(local, i), elem(local, j)}

        floaters = for i <- 0..(nb - 1)//1, mate[i] >= nb, do: elem(local, i)
        {:ok, %{pairs: pairs, floaters: floaters, bsn: Enum.map(bracket, & &1.rank)}}

      _ ->
        :error
    end
  end

  # 5.2.2's sense of a denied preference, for [C8]: both players have one
  # and it is the same colour. A player with no preference (1.5.4) is
  # never denied.
  defp denied?(a, b), do: a.colour != nil and a.colour == b.colour

  defp solve(n, edges) do
    mate = WeightedMatching.solve(n, edges)
    weights = Map.new(edges, fn {i, j, w} -> {{i, j}, w} end)
    total = for({i, j} <- mate, i < j, do: Map.fetch!(weights, {i, j})) |> Enum.sum()
    {total, mate}
  end

  # BSN by BSN (vertex i is BSN i + 1), the largest opponent that still
  # reaches the best weight, then a float.
  defp first_in_order(nb, n, edges, best, witness) do
    Enum.reduce(0..(nb - 1)//1, {%{}, witness}, fn i, {fixed, witness} ->
      if Map.has_key?(fixed, i) do
        {fixed, witness}
      else
        choices = Enum.to_list((nb - 1)..(i + 1)//-1) ++ [:float]
        open = Enum.reject(choices, &Map.has_key?(fixed, &1))

        Enum.reduce_while(open, nil, fn choice, nil ->
          cond do
            witness_choice(witness, i, nb) == choice ->
              {:halt, {fix(fixed, i, choice), witness}}

            true ->
              trial = fix(fixed, i, choice)

              case solve(n, restrict(edges, trial, nb)) do
                {^best, mate} when map_size(mate) == n -> {:halt, {trial, mate}}
                _ -> {:cont, nil}
              end
          end
        end)
        |> case do
          nil -> raise "Burstein bracket: no choice reaches the optimum for BSN #{i + 1}"
          result -> result
        end
      end
    end)
    |> elem(1)
  end

  defp witness_choice(mate, i, nb) do
    j = Map.fetch!(mate, i)
    if j < nb, do: j, else: :float
  end

  defp fix(fixed, i, :float), do: Map.put(fixed, i, :float)
  defp fix(fixed, i, j), do: fixed |> Map.put(i, j) |> Map.put(j, i)

  # Only the edges every fixed choice allows: a fixed pair keeps its own
  # edge and no other at either end; a fixed floater keeps only its edges
  # out of the bracket.
  defp restrict(edges, fixed, nb) do
    Enum.filter(edges, fn {i, j, _w} -> keep?(fixed, i, j, nb) and keep?(fixed, j, i, nb) end)
  end

  defp keep?(fixed, i, j, nb) do
    case Map.fetch(fixed, i) do
      :error -> true
      {:ok, :float} -> j >= nb
      {:ok, partner} -> partner == j
    end
  end
end

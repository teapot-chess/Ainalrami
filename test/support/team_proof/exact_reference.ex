defmodule Ainalrami.TeamProof.ExactReference do
  @moduledoc """
  An exact, polynomial reading of C.04.6 Articles 3.4-3.6 for whole rounds -
  the naive reference's definition, computed without its enumeration, so it
  stays tractable at 80 teams. Method, proofs and measurements are written
  up in `docs/team-proof-large-fields.md`; this moduledoc is the summary.

  ## Independent of the engine

  It shares no code with `Ainalrami.TeamPairing.*`, `Ainalrami.WeightedMatching`
  or `Ainalrami.Matching`. Its one algorithmic tool is
  `Ainalrami.TeamProof.Blossom`, a minimum-cost perfect matching written for
  it. It reuses the NAIVE reference's Article 4 (`ref_colours/4`,
  `ref_numbers/2`, `ref_preference/1` - per pair, already polynomial, and
  itself written from the text), and nothing else.

  ## Readings - the naive reference's, unchanged

    * [C1]: two teams have met when either lists the other.
    * 3.4: [C2] first, then lowest score, most matches played (the played
      colours), largest TPN; the first that leaves the rest pairable.
    * [C4] then [C5] judged over LEGAL sets - the bracket pairable and the
      teams left behind pairable ([C1], [C3]).
    * [C5] maximises the upfloaters' scores taken in ascending order.
    * [C6] minimises how many more upfloaters than the parity minimum the
      following scoregroup would need: the next score below the residents'
      among every team of the round, the bye's included (2026-11-11;
      before, the highest score among the lower teams); 0 when no team of
      that score is left to pair.
    * [C7] minimises upfloaters that floated last round, before 3.5.4's
      order; off in the last two rounds, as is [C10].
    * 3.6: least {C8, C10} (C8 before C10), then the smallest identifier.
      Type A preferences only.

  ## Why it is exact - the three facts it rests on

  1. **Every criterion here is a lexicographic comparison of counts**, and a
     lexicographic comparison of bounded counts is an integer comparison
     once each count is given its own digit in a wide enough base
     (`pack/2`). So "least in the ordering" becomes "cheapest perfect
     matching" when every count is a sum over the matching's edges.

  2. **Upfloater sets are matchings of the whole remaining field.** If S is
     a legal set of the smallest size, every member of S is paired with a
     resident in EVERY pairing of the bracket: were two members paired with
     each other, dropping both would leave a smaller legal set. So the sets
     of minimal size are exactly "the lower teams matched to a resident" in
     the perfect matchings of the remaining field that use fewest
     resident-lower edges, and [C4], [C5], [C7] and 3.5.4's order are sums
     over those edges. [C6]'s look-ahead has the same shape one level down:
     for a fixed S, the fewest upfloaters into the following scoregroup is
     the fewest edges between that scoregroup and the teams below it in a
     perfect matching of what S leaves behind - so the SAME matching carries
     it, and minimising the joint cost minimises [C6] over S.

  3. **Identifier order is a sum too.** Among sets of equal size, the one
     whose sorted list is lexicographically first is the one whose smallest
     element of the symmetric difference it contains - i.e. the one with the
     larger sum of `2^(size - index)`. 3.6.2's identifier is the top members
     sorted (all pairings have the same number of tops) and then the bottoms
     in the tops' order: one matching picks the top set, a second, confined
     to that top set, picks the bottoms with a base-`h` positional digit per
     top. 3.5.4's order of sets is the same argument on the lower teams
     ordered by (score descending, TPN).

  So a round is a handful of matchings - one per bye candidate tried, one
  per bracket for the upfloaters (plus at most three for the recorded
  reason), two per bracket for 3.6 - where the naive reference enumerates
  every subset and every pairing.
  """

  import Bitwise

  alias Ainalrami.TeamProof.{Blossom, NaiveReference}

  @doc """
  The same contract as `NaiveReference.ref_round/2`: `%{bye:, pairs:,
  reasons:}` or `:impossible`.
  """
  def round(field, opts) do
    absent = Keyword.fetch!(opts, :absent)
    initial = Keyword.fetch!(opts, :initial)
    engine_opts = Keyword.fetch!(opts, :opts)
    last_two? = engine_opts[:round] >= engine_opts[:expected_rounds] - 1

    numbers = NaiveReference.ref_numbers(field, absent)
    by_tpn = Map.new(field, &{&1.tpn, &1})

    with {bye, rest, bye_reasons} <- bye(field),
         true <- pairable?(rest) do
      {bracket_pairs, bracket_reasons} =
        rest |> brackets({last_two?, levels(field)}, []) |> Enum.unzip()

      allocated =
        bracket_pairs
        |> Enum.concat()
        |> Enum.map(fn {a, b} ->
          NaiveReference.ref_colours(by_tpn[a], by_tpn[b], numbers, initial)
        end)

      %{
        bye: bye,
        pairs: allocated |> Enum.map(fn {w, b, _rules} -> {w, b} end) |> Enum.sort(),
        reasons: %{
          bye: bye_reasons,
          brackets: bracket_reasons,
          rules:
            allocated
            |> Enum.map(fn {w, b, {first, colour}} -> {w, b, first, colour} end)
            |> Enum.sort()
        }
      }
    else
      _ -> :impossible
    end
  end

  # ------------------------------------------------------------------
  # [C1] and [C3]
  # ------------------------------------------------------------------

  defp met?(a, b), do: a.tpn in b.opponents or b.tpn in a.opponents

  @doc "Whether the teams can all be paired without a rematch."
  def pairable?(teams) do
    indexed = Enum.with_index(teams)

    edges =
      for {a, i} <- indexed, {b, j} <- indexed, i < j, not met?(a, b), do: {i, j}

    Blossom.perfect?(length(teams), edges)
  end

  # ------------------------------------------------------------------
  # 3.4 - the bye, and its reasons (as the naive reference records them)
  # ------------------------------------------------------------------

  defp bye(field) when rem(length(field), 2) == 0, do: {nil, field, nil}

  defp bye(field) do
    ordered =
      field
      |> Enum.reject(&(&1.had_pab? or &1.won_by_forfeit?))
      |> Enum.sort_by(&{&1.match_points, -length(&1.colours), -&1.tpn})

    case Enum.find_index(ordered, fn t -> pairable?(List.delete(field, t)) end) do
      nil ->
        :impossible

      i ->
        t = Enum.at(ordered, i)
        next = Enum.at(ordered, i + 1)

        decided_by =
          cond do
            next == nil -> nil
            t.match_points != next.match_points -> "3.4.2"
            length(t.colours) != length(next.colours) -> "3.4.3"
            true -> "3.4.4"
          end

        reasons = %{
          tpn: t.tpn,
          passed_over: ordered |> Enum.take(i) |> Enum.map(& &1.tpn),
          decided_by: decided_by
        }

        {t.tpn, List.delete(field, t), reasons}
    end
  end

  # ------------------------------------------------------------------
  # 3.3.2's loop: top scoregroup + upfloaters (3.5), paired (3.6)
  # ------------------------------------------------------------------

  # The round's score levels, from the whole field before the bye leaves it:
  # [C6]'s following scoregroup is the next of these below the residents.
  defp levels(field), do: field |> Enum.map(& &1.match_points) |> Enum.uniq()

  defp brackets([], _settings, acc), do: Enum.reverse(acc)

  defp brackets(remaining, {last_two?, round_levels} = settings, acc) do
    top = remaining |> Enum.map(& &1.match_points) |> Enum.max()
    {residents, lower} = Enum.split_with(remaining, &(&1.match_points == top))

    {set, decided_by} = select(residents, lower, last_two?, round_levels)

    tpns = set |> Enum.sort_by(&{0 - &1.match_points, &1.tpn}) |> Enum.map(& &1.tpn)
    ups = MapSet.new(set, & &1.tpn)
    pairs = bracket_pairing(residents ++ set, ups, last_two?)
    reasons = %{upfloaters: tpns, decided_by: decided_by}
    brackets(lower -- set, settings, [{pairs, reasons} | acc])
  end

  # ------------------------------------------------------------------
  # 3.5 - the upfloater set, as a matching of the whole remaining field
  # ------------------------------------------------------------------
  #
  # Vertices: residents first, then the lower teams. Per edge, the digits
  # (most significant first) of the ordering the naive reference sorts by:
  #
  #   :k          1 on a resident-lower edge                          [C4]
  #   {:c5, i}    1 on a resident-lower edge whose lower team is on
  #               score level i, levels lowest score first - "maximise
  #               the scores in ascending order" is "fewest on the
  #               lowest level, then the next", sets being equal-sized  [C5]
  #   :u          1 on an edge between the following scoregroup (the
  #               next score below the residents' in the round) and a team
  #               below it - that team is an upfloater into the
  #               following scoregroup's bracket                      [C6]
  #   :c7         1 on a resident-lower edge whose lower team floated
  #               last round (0 in the last two rounds)                [C7]
  #   :pos        2^|L| - 2^(|L| - p) on a resident-lower edge, p the
  #               lower team's place in (score desc, TPN) order - the
  #               lexicographically first sorted set has the largest
  #               sum of 2^(|L| - p)                                 3.5.4
  #   :other      1 on a resident-lower edge to a member of the CHOSEN
  #               set - fewer than |S| means another set exists with
  #               the digits above it at their optimum (for the reason)
  #
  # The number of upfloaters the following scoregroup needs is |U| (its
  # fewest edges to the teams below); [C6]'s value is (|U| - its parity) /
  # 2, and its parity is the same for every set with [C5]'s optimum (the
  # same number of that score floats), so minimising |U| minimises [C6].

  defp select(residents, lower, last_two?, round_levels) do
    r = length(residents)
    teams = residents ++ lower
    n = length(teams)
    nl = length(lower)

    levels = lower |> Enum.map(& &1.match_points) |> Enum.uniq() |> Enum.sort()
    level_of = Map.new(Enum.with_index(levels))
    # [C6]: the next level below the residents' in the ROUND, whoever is
    # left of it. With nobody of that score among the lower teams no edge
    # carries `:u` and every set scores 0 on [C6].
    top = hd(residents).match_points
    following = round_levels |> Enum.filter(&(&1 < top)) |> Enum.max(fn -> nil end)

    place =
      lower
      |> Enum.sort_by(&{0 - &1.match_points, &1.tpn})
      |> Enum.with_index()
      |> Map.new(fn {t, p} -> {t.tpn, p} end)

    indexed = Enum.with_index(teams)

    pairs =
      for {a, i} <- indexed, {b, j} <- indexed, i < j, not met?(a, b), do: {i, j, a, b}

    digits = fn chosen ->
      fn {i, j, a, b} ->
        cond do
          j < r ->
            %{}

          i < r ->
            # a resident, b a lower team: b floats up.
            %{
              :k => 1,
              {:c5, level_of[b.match_points]} => 1,
              :c7 => if(not last_two? and b.floated_last_round?, do: 1, else: 0),
              :pos => (1 <<< nl) - (1 <<< (nl - place[b.tpn])),
              :other => if(MapSet.member?(chosen, b.tpn), do: 1, else: 0)
            }

          true ->
            # Two lower teams paired together below the bracket.
            if a.match_points == following != (b.match_points == following),
              do: %{u: 1},
              else: %{}
        end
      end
    end

    c5 = for i <- 0..(length(levels) - 1)//1, do: {:c5, i}

    solve = fn names, chosen ->
      {:ok, values, mate} = solve(n, pairs, digits.(chosen), names)
      {values, mate}
    end

    {_values, mate} = solve.([:k] ++ c5 ++ [:u, :c7, :pos], MapSet.new())

    set = for {t, v} <- Enum.drop(indexed, r), mate[v] < r, do: t
    chosen = MapSet.new(set, & &1.tpn)
    k = length(set)

    # Another set exists, with the named digits at their optimum?
    another? = fn names -> List.last(elem(solve.(names ++ [:other], chosen), 0)) < k end

    decided_by =
      cond do
        another?.([:k] ++ c5) ->
          cond do
            another?.([:k] ++ c5 ++ [:u, :c7]) -> "3.5.4"
            another?.([:k] ++ c5 ++ [:u]) -> "C7"
            true -> "C6"
          end

        another?.([:k]) ->
          "C5"

        true ->
          "C4"
      end

    {set, decided_by}
  end

  # ------------------------------------------------------------------
  # 3.6 - least {C8, C10}, then the smallest identifier
  # ------------------------------------------------------------------

  defp bracket_pairing(bracket, ups, last_two?) do
    teams = Enum.sort_by(bracket, & &1.tpn)
    m = length(teams)
    tuple = List.to_tuple(teams)
    pref = Map.new(teams, &{&1.tpn, NaiveReference.ref_preference(&1)})
    indexed = Enum.with_index(teams)

    pairs =
      for {a, i} <- indexed, {b, j} <- indexed, i < j, not met?(a, b), do: {i, j, a, b}

    c8 = fn a, b -> if pref[a.tpn] != nil and pref[a.tpn] == pref[b.tpn], do: 1, else: 0 end

    c10 = fn a, b ->
      if last_two? do
        0
      else
        # Per TEAM, as the text reads: each floated team facing an upfloater.
        up = &MapSet.member?(ups, &1.tpn)

        if(up.(b) and a.floated_last_round?, do: 1, else: 0) +
          if up.(a) and b.floated_last_round?, do: 1, else: 0
      end
    end

    # First: the top set. The smaller member of a pair is its top; the
    # lexicographically first sorted top set has the largest sum of
    # 2^(m - index) over its members.
    tops_digits = fn {i, _j, a, b} ->
      %{c8: c8.(a, b), c10: c10.(a, b), tops: (1 <<< m) - (1 <<< (m - i))}
    end

    {:ok, [best8, best10, _], mate} = solve(m, pairs, tops_digits, [:c8, :c10, :tops])

    tops = for i <- 0..(m - 1)//1, mate[i] > i, do: i
    h = length(tops)
    top_rank = Map.new(Enum.with_index(tops))
    bottom_rank = (Enum.to_list(0..(m - 1)//1) -- tops) |> Enum.with_index() |> Map.new()

    # Then the bottoms, in the tops' order: a base-h digit per top, the
    # first top most significant.
    confined =
      for {i, j, _a, _b} = e <- pairs,
          Map.has_key?(top_rank, i) and Map.has_key?(bottom_rank, j),
          do: e

    bottoms_digits = fn {i, j, a, b} ->
      %{
        c8: c8.(a, b),
        c10: c10.(a, b),
        bottoms: bottom_rank[j] * Integer.pow(h, h - 1 - top_rank[i])
      }
    end

    {:ok, [^best8, ^best10, _], mate} = solve(m, confined, bottoms_digits, [:c8, :c10, :bottoms])

    for i <- tops, do: {elem(tuple, i).tpn, elem(tuple, mate[i]).tpn}
  end

  # ------------------------------------------------------------------
  # Lexicographic digits packed into one integer cost
  # ------------------------------------------------------------------

  # `pairs` are `{i, j, a, b}`, `digits_of` gives each a map of digit =>
  # non-negative count (absent = 0), `names` the digits in significance
  # order. Returns `{:ok, [value of each digit], mate}` for the matching
  # that is least in that lexicographic order, or `:none`.
  #
  # Each digit's base is one more than the largest total it can reach in
  # ANY perfect matching - bounded by summing, over the vertices, the
  # largest value on an edge at that vertex (a matching edge is counted at
  # least once, at either end) - so no digit can carry into the next and
  # the integer order is the lexicographic order exactly.
  defp solve(n, pairs, digits_of, names) do
    valued = Enum.map(pairs, fn {i, j, _a, _b} = e -> {i, j, digits_of.(e)} end)

    bases =
      Enum.map(names, fn name ->
        per_vertex =
          Enum.reduce(valued, %{}, fn {i, j, d}, acc ->
            v = Map.get(d, name, 0)
            true = is_integer(v) and v >= 0

            acc
            |> Map.update(i, v, &max(&1, v))
            |> Map.update(j, v, &max(&1, v))
          end)

        1 + (per_vertex |> Map.values() |> Enum.sum())
      end)

    edges =
      Enum.map(valued, fn {i, j, d} ->
        {i, j, pack(Enum.map(names, &Map.get(d, &1, 0)), bases)}
      end)

    case Blossom.min_cost_perfect(n, edges) do
      :none -> :none
      {:ok, cost, mate} -> {:ok, unpack(cost, bases), mate}
    end
  end

  defp pack(values, bases) do
    Enum.zip(values, bases) |> Enum.reduce(0, fn {v, base}, acc -> acc * base + v end)
  end

  defp unpack(total, bases) do
    {values, 0} =
      bases
      |> Enum.reverse()
      |> Enum.reduce({[], total}, fn base, {values, rest} ->
        {[rem(rest, base) | values], div(rest, base)}
      end)

    values
  end
end

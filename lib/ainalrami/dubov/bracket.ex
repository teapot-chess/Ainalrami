defmodule Ainalrami.Dubov.Bracket do
  @moduledoc """
  C.04.4.1 Article 3.2: one scoregroup's bracket, from choosing its
  upfloaters to the pairs.

    * 3.2.1 - the fewest upfloaters giving a legal pairing ([C1], [C3],
      [C4]): `Graph.min_upfloaters/3`.
    * 3.2.2 - of the sets of that size, the one whose bracket complies best
      with [C5]-[C10], then the first in 4.2's order: `select/3`.
    * 3.2.3-3.2.4 - G1 (the White seekers, or the first half by TPN when
      nobody in the bracket has played) and G2, and their re-composition:
      `subgroups/2`.
    * 3.2.5-3.2.6 - S1 sorted by ARO then TPN, and T2 the first
      transposition of G2 giving a legal pairing: `transposition/4`.

  ## [C7] across the procedure, and why reading D2 does not move a pairing

  Every player in the Dubov system has a preference (1.6.4), so in a
  bracket of White seekers W and Black seekers B a pair denies a preference
  exactly when both seek the same colour, and

      [C7] = (pairs inside W) + (pairs inside B)
           = 2 * (pairs inside the smaller of the two) + |W - B| / 2.

  3.2.4 shifts p players out of the smaller subgroup S, p the fewest pairs
  inside S any legal pairing has, then q = p + (|L| - |S|) / 2 players of
  the larger L the other way. After that every pair is S1[i]-T2[i], one
  from each new subgroup, and a pair is one of: S-native against L-native
  (granted), S-native against a shifted S player (denied), shifted L
  player against L-native (denied), or shifted L against shifted S
  (granted). With t pairs of the last kind the round denies p + q - 2t
  preferences, and holds p - t pairs inside S. p is the least possible, so
  t = 0 in every legal pairing the re-composed subgroups allow, and EVERY
  such pairing denies exactly p + q preferences - which is 3.2.2's [C7].

  So 3.2.6's first legal transposition (reading D2 (a), the text) always
  reaches the [C7] value 3.2.2 chose the upfloaters by (reading D2 (b)).
  The engine implements both behind `:transposition_rule`; (b) costs a
  weighted matching per step and is only taken when (a)'s answer misses
  its target, which the argument above says never happens. The brute-force
  reference runs both readings literally and counts where they part.

  The argument rests on reading D3: 3.2.4's second step moves players of
  the larger subgroup's OWN colour (4.3: a shift moves "players seeking a
  colour ... to the subgroup of players initially seeking the other
  colour"), never the players its first step moved there.
  """

  alias Ainalrami.Dubov.{Graph, Order}

  @doc """
  3.2.2: the upfloaters for `residents` from `lower` (all `%Player{}`),
  given that `k` are needed. `ctx` is the round's: `:field`, `:last_round?`,
  `:max_t`.

  [C5] is fixed by `k`. [C6] (reading D6, the team engine's): the best
  profile - upfloaters' scores in ascending order, as high as possible -
  among the LEGAL sets of that size (bracket pairable, everything left
  pairable). Then the least [C7] (the fewest preferences the bracket must
  deny), [C8] maximum upfloaters, [C9] their previous upfloats, [C10]
  upfloaters of the previous round ([C8]-[C10] not in the last round), and
  finally 4.2's order.

  Returns the set in 4.2 order, or nil when no set of size `k` is legal.
  """
  def select(residents, lower, k, ctx)

  def select(_residents, _lower, 0, _ctx), do: []

  def select(residents, lower, k, ctx) do
    pool = Order.upfloater_pool(lower)

    groups =
      pool
      |> Enum.chunk_by(& &1.score)
      |> Enum.map(&{hd(&1).score, &1})

    groups
    |> profiles(k)
    |> Enum.find_value(&best_in_profile(&1, groups, residents, lower, ctx))
  end

  # Every way of drawing `k` players from the score groups (highest score
  # first), best [C6] profile first: compared as the upfloaters' scores in
  # ascending order, the larger list the better.
  defp profiles(groups, k) do
    sizes = Enum.map(groups, fn {score, members} -> {score, length(members)} end)

    sizes
    |> compositions(k)
    |> Enum.sort_by(&profile(&1, sizes), :desc)
  end

  defp compositions([], 0), do: [[]]
  defp compositions([], _k), do: []

  defp compositions([{_score, size} | rest], k) do
    for take <- 0..min(size, k)//1, tail <- compositions(rest, k - take), do: [take | tail]
  end

  defp profile(counts, sizes) do
    counts
    |> Enum.zip(sizes)
    |> Enum.flat_map(fn {c, {score, _}} -> List.duplicate(score, c) end)
    |> Enum.sort()
  end

  # The sets of one profile in 4.1.3 order (the score groups are 4.2's
  # numbering in blocks, so the order is the first group's combination,
  # then the second's ...), keeping the least {C7, C8, C9, C10} and the
  # first set to reach it. A set is only looked at closely when the cheap
  # half of its key could still win.
  defp best_in_profile(counts, groups, residents, lower, ctx) do
    parts = Enum.zip(counts, groups)

    result =
      reduce_product(parts, [], nil, fn set, best ->
        rough = {c7_bound(residents ++ set), c8(set, ctx), c9(set, ctx), c10(set, ctx)}

        if best != nil and rough >= best.key do
          {:cont, best}
        else
          bracket = Enum.map(residents ++ set, & &1.rank)
          rest = Enum.map(lower -- set, & &1.rank)

          if Graph.feasible?(bracket, ctx.field) and Graph.feasible?(rest, ctx.field) do
            key = put_elem(rough, 0, c7(residents ++ set, ctx.field))
            best = if best == nil or key < best.key, do: %{key: key, set: set}, else: best
            # Nothing beats a bracket that denies nobody and floats nobody it
            # should not; anything short of that may still be beaten later.
            if key == {0, 0, 0, 0}, do: {:halt, best}, else: {:cont, best}
          else
            {:cont, best}
          end
        end
      end)

    result && result.set
  end

  defp reduce_product(parts, chosen, acc, fun) do
    {_, acc} = product(parts, chosen, acc, fun)
    acc
  end

  defp product([], chosen, acc, fun), do: fun.(chosen, acc)

  defp product([{count, {_score, members}} | rest], chosen, acc, fun) do
    Order.reduce_sets(members, count, {:cont, acc}, fn picked, {_, acc} ->
      case product(rest, chosen ++ picked, acc, fun) do
        {:halt, acc} -> {:halt, {:halt, acc}}
        {:cont, acc} -> {:cont, {:cont, acc}}
      end
    end)
  end

  @doc """
  [C7] for a bracket: the fewest players any legal pairing of it denies
  their colour preference, nil when it cannot be paired.
  """
  def c7(players, field) do
    {white, black} = Enum.split_with(players, &(&1.colour == :white))

    case Graph.max_cross(ranks(white), ranks(black), field) do
      nil -> nil
      cross -> div(length(players), 2) - cross
    end
  end

  defp c7_bound(players) do
    whites = Enum.count(players, &(&1.colour == :white))
    div(abs(2 * whites - length(players)), 2)
  end

  defp c8(_set, %{last_round?: true}), do: 0
  defp c8(set, ctx), do: Enum.count(set, &(&1.upfloats >= ctx.max_t))

  # "The number of times a maximum upfloater is upfloated": the upfloats the
  # maximum upfloaters among the set already have.
  defp c9(_set, %{last_round?: true}), do: 0

  defp c9(set, ctx),
    do: set |> Enum.filter(&(&1.upfloats >= ctx.max_t)) |> Enum.map(& &1.upfloats) |> Enum.sum()

  defp c10(_set, %{last_round?: true}), do: 0
  defp c10(set, _ctx), do: Enum.count(set, & &1.upfloated_last?)

  @doc """
  3.2.3-3.2.4: `{g1, g2}`, the subgroups after re-composition, each a list
  of `%Player{}` and equal in size. Also returns what moved:
  `{g1, g2, %{unavoidable: p, first: shifted, second: shifted}}`.
  """
  def subgroups(players, field) do
    {g1, g2} =
      if Enum.all?(players, &(&1.played == 0)) do
        players |> Enum.sort_by(& &1.rank) |> Enum.split(div(length(players), 2))
      else
        Enum.split_with(players, &(&1.colour == :white))
      end

    {small, large, small_is_g1?} =
      if length(g1) <= length(g2), do: {g1, g2, true}, else: {g2, g1, false}

    cross = Graph.max_cross(ranks(small), ranks(large), field)
    p = div(length(small) - cross, 2)

    first = shift_first(small, large, p, field)
    q = div(length(large) - length(small), 2) + p
    small_left = small -- first
    large_now = large ++ first
    second = shift_second(small_left, large, large_now, q, field)

    new_small = small_left ++ second
    new_large = large_now -- second
    moved = %{unavoidable: p, first: ranks(first), second: ranks(second)}

    if small_is_g1?,
      do: {new_small, new_large, moved},
      else: {new_large, new_small, moved}
  end

  # The first p players of the smaller subgroup (4.3 order) whose shift
  # leaves a legal pairing. Such a shift works exactly when the bracket has
  # a perfect matching where every shifted player meets an unshifted one of
  # its own subgroup and no two unshifted ones meet - that matching's
  # pairs inside the larger subgroup then say which players the second
  # step can move, and every legal pairing after both steps is of this
  # kind (the moduledoc's t = 0).
  defp shift_first(_small, _large, 0, _field), do: []

  defp shift_first(small, large, p, field) do
    pool = Order.shifter_pool(small)
    everyone = ranks(small ++ large)
    in_small = MapSet.new(ranks(small))

    Order.reduce_sets(pool, p, nil, fn set, _ ->
      shifted = MapSet.new(ranks(set))

      keep? = fn a, b ->
        side_a = side(a, shifted, in_small)
        side_b = side(b, shifted, in_small)

        case Enum.sort([side_a, side_b]) do
          [:shifted, :stay] -> true
          [:large, :stay] -> true
          [:large, :large] -> true
          _ -> false
        end
      end

      if Graph.perfect_restricted?(everyone, field, keep?),
        do: {:halt, set},
        else: {:cont, nil}
    end)
  end

  defp side(rank, shifted, in_small) do
    cond do
      MapSet.member?(shifted, rank) -> :shifted
      MapSet.member?(in_small, rank) -> :stay
      true -> :large
    end
  end

  # The first q of the larger subgroup's own players (4.3 order) whose move
  # leaves the two subgroups pairable one against the other.
  defp shift_second(_small_left, _large_natives, _large_now, 0, _field), do: []

  defp shift_second(small_left, large_natives, large_now, q, field) do
    pool = Order.shifter_pool(large_natives)

    Order.reduce_sets(pool, q, nil, fn set, _ ->
      if Graph.bipartite?(ranks(small_left ++ set), ranks(large_now -- set), field),
        do: {:halt, set},
        else: {:cont, nil}
    end)
  end

  @doc """
  3.2.5-3.2.6: the pairs `[{s1_player, t2_player}]` - S1 is `g1` by
  ascending ARO then TPN, T2 the first transposition of `g2` (4.4,
  ascending TPN) that pairs S1[i] with T2[i] legally.

  `rule` is reading D2: `:first_legal` (a, the text) or
  `:first_reaching_c7` (b: the first legal transposition that also denies
  no more than `target` preferences, the [C7] 3.2.2 assumed).
  """
  def transposition(g1, g2, field, rule, target \\ nil) do
    s1 = Enum.sort_by(g1, &{&1.aro, &1.rank})
    g2 = Enum.sort_by(g2, & &1.rank)
    legal = first_legal(s1, g2, field)

    case rule do
      :first_legal ->
        legal

      :first_reaching_c7 ->
        if denied(legal) <= target, do: legal, else: first_reaching(s1, g2, field, target)
    end
  end

  defp first_legal([], [], _field), do: []

  defp first_legal([s | rest], g2, field) do
    Enum.find_value(g2, fn t ->
      others = List.delete(g2, t)

      if Graph.allowed?(field, s.rank, t.rank) and
           Graph.bipartite?(ranks(rest), ranks(others), field) do
        [{s, t} | first_legal(rest, others, field)]
      end
    end)
  end

  defp first_reaching([], [], _field, _budget), do: []

  defp first_reaching([s | rest], g2, field, budget) do
    by_rank = Map.new(rest ++ g2, &{&1.rank, &1})
    denied? = fn a, b -> by_rank[a].colour == by_rank[b].colour end

    Enum.find_value(g2, fn t ->
      others = List.delete(g2, t)
      cost = if s.colour == t.colour, do: 1, else: 0

      with true <- Graph.allowed?(field, s.rank, t.rank),
           least when is_integer(least) <-
             Graph.min_denied(ranks(rest), ranks(others), field, denied?),
           true <- cost + least <= budget do
        [{s, t} | first_reaching(rest, others, field, budget - cost)]
      else
        _ -> nil
      end
    end)
  end

  @doc "Preferences a list of pairs denies: pairs whose players seek the same colour."
  def denied(pairs), do: Enum.count(pairs, fn {a, b} -> a.colour == b.colour end)

  defp ranks(players), do: Enum.map(players, & &1.rank)
end

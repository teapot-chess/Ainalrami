defmodule Ainalrami.TeamPairing.Bracket do
  @moduledoc """
  Article 3.6 - pairing one bracket.

  This is the module where team pairing stops resembling the individual
  system. C.04.3 defines a lexicographic weight ladder and asks for the best
  candidate under it; 3.6 defines an ORDER over pairings and asks for the
  first one satisfying a predicate.

  ## The order (3.6.1-3.6.3)

  A pairing is a set of pairs covering the bracket. In each pair the smaller
  TPN is the *top member*, the larger the *bottom member*. The identifier is
  the top members ascending, followed by their corresponding bottom members;
  pairings sort by that identifier lexicographically. The regulation's own
  example: `11-24  16-6  10-9  8-4` has identifier `4 6 9 11 8 16 10 24`.

  Since the top-half of every identifier has the same length, comparing
  identifiers is: compare the sorted top-member sets, and only on a tie
  compare the bottom sequence.

  ## The predicate (3.6.4), and why it is not simply a filter

  3.6.4 says to take the first pairing "that also complies with criteria
  [C1], [C8], [C9] and [C10]". [C1] is a genuine predicate - no rematches.
  The other three are *minimisation* criteria ("minimise the number of teams
  whose colour preference is not fulfilled"), and a pairing cannot comply
  with a minimisation in isolation: it complies by achieving the minimum
  attainable over the bracket's legal pairings.

  So the answer is the pairing that minimises `{c8, c9, c10}`
  lexicographically, tie-broken by identifier order.

  ## How it is computed (since 2026-09-25): exact, no budget

  1. **The walk, as a fast path.** Top-sets in lexicographic order, and
     within each the bottom assignments in lexicographic order, pruned by
     [C1] and a completion check - so its first complete candidate is the
     first legal pairing in identifier order. If that candidate scores
     `{0, 0, 0}` it is the answer (nothing scores lower, nothing legal comes
     earlier), and that is what this module has always returned there; a
     round-one bracket, or any bracket whose preferences can all be met by
     the first legal pairing, ends here. A walk that finishes without any
     candidate is a proof that no legal pairing exists. The walk is capped at
     20,000 steps; beyond that, or when the first candidate costs
     anything, it hands over to step 2.
  2. **Two minimum-cost perfect matchings** (`exact/1`, method in
     `docs/team-proof-large-fields.md` section 3): the criteria and the
     identifier packed into one integer cost per pair, one matching for the
     least criteria and the first top set, one confined to that top set for
     the first bottom sequence. The matcher is the engine's own
     `Ainalrami.WeightedMatching` (Edmonds' blossom method, Galil 1986),
     not the proof's test-only reference.

  Until 2026-09-25 step 2 was the walk continued under a candidate budget
  (`:max_candidates`, default 200,000) and a step budget (`:max_steps`,
  default 10,000,000), keeping the best pairing found when either ran out.
  On large early-round brackets that returned a legal pairing 3.6 does not
  choose (seed 126 of the large-field proof at the default budget, seed 480
  even at 10,000,000 candidates). Both options are still ACCEPTED, and
  ignored: the result is exact whatever they say, `exhaustive?` is always
  true, and `{:error, :budget_exhausted}` is no longer returned from here.
  """

  alias Ainalrami.TeamPairing.{Matching, Team}
  alias Ainalrami.WeightedMatching

  import Bitwise

  # The fast path's walk budget. The walk's first candidate is found in a few
  # hundred steps on an ordinary bracket (402 for a forty-team round one);
  # only a tangled one runs longer, and then the matching answers instead.
  @fast_path_steps 20_000

  @doc """
  Pairs `teams` (a bracket - an even-sized list) and returns

      {:ok, %{pairs: [{top_tpn, bottom_tpn}], scores: {c8, c9, c10},
              candidates: n, steps: n, exhaustive?: true}}

  or `{:error, :no_legal_pairing}` when [C1] admits none. `pairs` are in the
  identifier's order (tops ascending). `candidates` and `steps` are the fast
  path's walk when it answered, and 0 when the matching did.

  Options:

    * `:type` / `:last_round?` - colour-preference type (1.7: `:a`, `:b` or
      `:none`), for [C8]/[C9].
    * `:upfloater_tpns` - the TPNs in this bracket that are upfloaters, for
      [C10] (which counts upfloaters' OPPONENTS that were floaters in the
      previous round). Empty for a bracket of residents only.
    * `:last_two_rounds?` - [C7] and [C10] "with the exception of the last
      two rounds". When true, [C10] contributes nothing.
    * `:max_candidates`, `:max_steps` - accepted for compatibility and
      ignored (see the module doc).
    * `:soft_pairs` - `%{tpn => MapSet.t(tpn)}`, the pairs to seat as few
      of as possible among the pairings that tie on `{c8, c9, c10}`: one
      more digit after [C10] and before the identifier, so it never
      outranks anything 3.6 counts. Given (and not empty), the result also
      has `soft:`, how many such pairs the answer could not avoid. Absent,
      the result is the map it always was.
  """
  def pair(teams, opts \\ [])

  def pair([], _opts),
    do: {:ok, %{pairs: [], scores: {0, 0, 0}, candidates: 0, exhaustive?: true}}

  def pair(teams, opts) when is_list(teams) do
    if rem(length(teams), 2) == 1 do
      # 1.3.2: a bracket is "an even numbered group of teams all to be
      # paired". An odd one is a caller bug, not a pairing outcome - the odd
      # team should have become the PAB (3.4) or an upfloater target.
      raise ArgumentError,
            "a bracket must have an even number of teams (Article 1.3.2), got #{length(teams)}"
    end

    ctx = context(teams, opts)

    case search(ctx) do
      # The first legal pairing in identifier order, and nothing can score
      # below {0, 0, 0}: it is 3.6's answer, and the walk's answer always was.
      # With soft pairs the fourth digit has to be nothing too, or a later
      # pairing equal on the FIDE three might seat fewer of them.
      {:ok, %{costs: {0, 0, 0, 0}}} = found ->
        finish(found, ctx)

      # The walk completed without finding a single legal pairing (it cannot
      # have stopped at the candidate budget, which needs a candidate): that
      # is a proof, the same one the matching would give.
      {:error, :no_legal_pairing} = none ->
        none

      # A better-scoring pairing may lie further on, or the walk ran out of
      # steps before its first candidate: decide exactly.
      _ ->
        ctx |> exact() |> finish(ctx)
    end
  end

  # The internal four-digit cost as the result reports it: `scores` is the
  # FIDE three, exactly as before soft pairs existed, and `soft` - the soft
  # pairs the bracket could not avoid - is there only when some were asked
  # for, so a round paired without them returns the map it always did.
  defp finish({:ok, %{costs: {c8, c9, c10, soft}} = result}, ctx) do
    result = result |> Map.delete(:costs) |> Map.put(:scores, {c8, c9, c10})
    {:ok, if(ctx.soft, do: Map.put(result, :soft, soft), else: result)}
  end

  defp finish(other, _ctx), do: other

  @doc false
  # The matching path alone, skipping the fast path, so tests can hold it to
  # the pre-change walk on every shape rather than only where the first
  # candidate costs something.
  def __exact_for_test__([], _opts), do: {:ok, %{pairs: [], scores: {0, 0, 0}}}

  def __exact_for_test__(teams, opts) do
    ctx = context(teams, opts)
    ctx |> exact() |> finish(ctx)
  end

  defp context(teams, opts) do
    sorted = Enum.sort_by(teams, & &1.tpn)
    by_tpn = Map.new(sorted, &{&1.tpn, &1})
    tpns = Enum.map(sorted, & &1.tpn)
    type = Keyword.get(opts, :type, :a)
    last_round? = Keyword.get(opts, :last_round?, false)
    upfloaters = MapSet.new(Keyword.get(opts, :upfloater_tpns, []))
    last_two_rounds? = Keyword.get(opts, :last_two_rounds?, false)

    # `%{tpn => MapSet.t(tpn)}`: the pairs to avoid where it costs nothing
    # FIDE counts (`Ainalrami.TeamPairing`, "Keeping teams apart"), or nil.
    # nil - and an empty map - leave this module exactly as it was.
    soft = Keyword.get(opts, :soft_pairs)
    soft = if soft in [nil, %{}], do: nil, else: soft

    ctx = %{
      tpns: List.to_tuple(tpns),
      by_tpn: by_tpn,
      n: length(tpns),
      type: type,
      last_round?: last_round?,
      upfloaters: upfloaters,
      last_two_rounds?: last_two_rounds?,
      soft: soft,
      # The fast path's walk: it only has to reach the first legal pairing.
      max_candidates: 1,
      max_steps: @fast_path_steps
    }

    Map.merge(ctx, walk_tables(tpns, by_tpn, ctx))
  end

  # ---------------------------------------------------------------------
  # Article 3.6 by minimum-cost perfect matching (2026-09-25)
  #
  # The answer is the pairing with the least {c8, c9, c10}, and among those
  # the smallest identifier (3.6.2). Every count is a sum over the pairs, and
  # so, as `docs/team-proof-large-fields.md` section 3 sets out, is the
  # identifier order once it is split in two:
  #
  #   1. Tops. Every pairing has n/2 tops, and of two equal-sized sets the
  #      lexicographically first sorted list is the one containing the
  #      smallest index of their symmetric difference - the larger sum of
  #      2^(n-1-i). One matching over the bracket with the digits c8, c9,
  #      c10, then 2^n - 2^(n-1-i) for the edge's top (smaller index) i,
  #      returns the least criteria and, among those, the first top set.
  #   2. Bottoms. Confined to edges from that top set T to the rest (smaller
  #      index in T), every perfect matching has exactly T as its tops. With
  #      the digits c8, c9, c10, then rank(bottom) * h^(h-1-rank(top)), the
  #      bottoms read in the tops' order form a base-h number, so the cheapest
  #      matching is the first bottom sequence. It must reach the criteria of
  #      step 1 (the step-1 optimum with tops T is one of its matchings).
  #
  # Each digit's base exceeds the largest total it can reach in a perfect
  # matching, so the packed integer's order is the lexicographic order and
  # nothing carries. `Ainalrami.WeightedMatching` maximises weight, so the
  # cost goes in as W - cost with W above any matching's total cost: a
  # larger matching then always outweighs a smaller one, the maximum-weight
  # matching is perfect whenever a perfect one exists, and among perfect
  # matchings it is the cheapest.
  # ---------------------------------------------------------------------

  defp exact(ctx) do
    n = ctx.n
    h = div(n, 2)

    criteria =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          (elem(ctx.allowed, i) >>> j &&& 1) == 1,
          do: {i, j, add_costs({0, 0, 0, 0}, i, j, ctx)}

    # c8 and c9 count at most one per pair, c10 at most two.
    pack_fide = fn {c8, c9, c10, _soft} -> (c8 * (h + 1) + c9) * (2 * h + 1) + c10 end

    # The soft count is one more digit BELOW the FIDE three (at most one per
    # pair, so base h + 1) and above the identifier: it only ever chooses
    # among pairings FIDE already ranks equal. Without soft pairs the digit
    # is not there at all, so every packed cost is the integer it always was.
    pack_criteria =
      if ctx.soft,
        do: fn {_, _, _, soft} = costs -> pack_fide.(costs) * (h + 1) + soft end,
        else: pack_fide

    top_base = h * (1 <<< n) + 1

    tops_edges =
      for {i, j, costs} <- criteria,
          do: {i, j, pack_criteria.(costs) * top_base + (1 <<< n) - (1 <<< (n - 1 - i))}

    with {:ok, first} <- min_cost_perfect(n, tops_edges) do
      tops = first |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      top_rank = tops |> Enum.with_index() |> Map.new()
      in_tops = MapSet.new(tops)

      bottom_rank =
        0..(n - 1)
        |> Enum.reject(&MapSet.member?(in_tops, &1))
        |> Enum.with_index()
        |> Map.new()

      bottom_base = Integer.pow(h, h)

      bottoms_edges =
        for {i, j, costs} <- criteria,
            Map.has_key?(top_rank, i),
            Map.has_key?(bottom_rank, j),
            do:
              {i, j,
               pack_criteria.(costs) * bottom_base +
                 Map.fetch!(bottom_rank, j) * Integer.pow(h, h - 1 - Map.fetch!(top_rank, i))}

      {:ok, second} = min_cost_perfect(n, bottoms_edges)

      costs_of = fn pairs ->
        Enum.reduce(pairs, {0, 0, 0, 0}, fn {t, b}, acc -> add_costs(acc, t, b, ctx) end)
      end

      costs = costs_of.(second)

      if costs != costs_of.(first) or Enum.map(second, &elem(&1, 0)) != tops do
        raise "3.6 matching: the bottom step did not keep the top step's optimum " <>
                "(#{inspect(costs_of.(first))} -> #{inspect(costs)})"
      end

      pairs = Enum.map(second, fn {t, b} -> {elem(ctx.tpns, t), elem(ctx.tpns, b)} end)

      {:ok, %{pairs: pairs, costs: costs, candidates: 0, steps: 0, exhaustive?: true}}
    end
  end

  # The cheapest perfect matching over `edges` ({i, j, cost}, i < j), as
  # `{:ok, [{i, j}]}` sorted by i, or `{:error, :no_legal_pairing}` when
  # there is no perfect matching at all.
  defp min_cost_perfect(n, edges) do
    max_cost = edges |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> 0 end)
    ceiling = div(n, 2) * max_cost + 1

    mate = WeightedMatching.solve(n, Enum.map(edges, fn {i, j, c} -> {i, j, ceiling - c} end))
    pairs = for {i, j} <- mate, i < j, do: {i, j}

    if length(pairs) * 2 == n do
      allowed = MapSet.new(edges, fn {i, j, _} -> {i, j} end)

      unless Enum.all?(pairs, &MapSet.member?(allowed, &1)) do
        raise "3.6 matching returned a pair that is not an edge of the bracket"
      end

      {:ok, Enum.sort(pairs)}
    else
      {:error, :no_legal_pairing}
    end
  end

  # Everything the walk asks about a team or a pair, worked out once per
  # bracket instead of once per question (2026-09-16). The walk used to call
  # `Team.met?/2` for every bottom it tried, rebuild an adjacency map for
  # every feasibility query, and recompute every team's colour preference -
  # `Team.preference/3` counts the whole colour history - for every pair of
  # every complete candidate. On a 79-team bracket that runs to its 200,000
  # candidate budget, the preference recounting alone was three quarters of
  # the round.
  #
  # Nothing here changes an answer:
  #
  #   * `allowed` is `Team.met?/2` from the TOP member's side, exactly the
  #     question the walk asked (`try_bottoms/4`) and exactly the adjacency
  #     `completable?/5` used to build - from the lowest index, which is
  #     always a top;
  #   * `info` holds, per team, what `criteria/2` reads: the colour and
  #     strength of `Team.preference/3` (a pure function of the team),
  #     whether it is an upfloater here, and whether it floated last round.
  defp walk_tables(tpns, by_tpn, ctx) do
    positions =
      tpns
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {tpn, i}, acc -> Map.update(acc, tpn, [i], &[i | &1]) end)

    full = (1 <<< length(tpns)) - 1

    allowed =
      tpns
      |> Enum.with_index()
      |> Enum.map(fn {tpn, i} ->
        met =
          by_tpn
          |> Map.fetch!(tpn)
          |> Map.fetch!(:opponents)
          |> Enum.reduce(0, fn opp, acc ->
            positions |> Map.get(opp, []) |> Enum.reduce(acc, &(&2 ||| 1 <<< &1))
          end)

        full &&& bnot(met ||| 1 <<< i)
      end)
      |> List.to_tuple()

    info =
      tpns
      |> Enum.map(fn tpn ->
        team = Map.fetch!(by_tpn, tpn)
        preference = Team.preference(team, ctx.type, ctx.last_round?)

        {Team.preferred_colour(preference), Team.strong?(preference),
         MapSet.member?(ctx.upfloaters, tpn), team.floated_last_round?}
      end)
      |> List.to_tuple()

    # The soft pairs the way `allowed` is built - per index, a mask of the
    # positions it would rather not meet - or nil when there are none.
    soft_masks =
      ctx.soft &&
        tpns
        |> Enum.map(fn tpn ->
          ctx.soft
          |> Map.get(tpn, MapSet.new())
          |> Enum.reduce(0, fn other, acc ->
            positions |> Map.get(other, []) |> Enum.reduce(acc, &(&2 ||| 1 <<< &1))
          end)
        end)
        |> List.to_tuple()

    %{
      allowed: allowed,
      soft_masks: soft_masks,
      info: info,
      c10?: not (ctx.last_two_rounds? or MapSet.size(ctx.upfloaters) == 0)
    }
  end

  # Walk top-sets in lexicographic order; for each, walk bottom assignments
  # in lexicographic order. Track the best {c8,c9,c10}; stop dead on {0,0,0}.
  defp search(ctx) do
    half = div(ctx.n, 2)

    state = %{
      best: nil,
      best_scores: nil,
      candidates: 0,
      exhausted: false,
      steps: 0,
      out_of_steps: false
    }

    state = walk_top_sets(half, [], 0, ctx, state)

    cond do
      state.out_of_steps ->
        {:error, :budget_exhausted}

      is_nil(state.best) ->
        {:error, :no_legal_pairing}

      true ->
        pairs = state.best

        {:ok,
         %{
           pairs: pairs,
           costs: state.best_scores,
           candidates: state.candidates,
           steps: state.steps,
           exhaustive?: not state.exhausted
         }}
    end
  end

  # One unit of walk. Counted in the three places the walk actually spends
  # itself, so the bound holds whether the cost is in enumerating top-sets,
  # assigning bottoms, or proving a subtree dead.
  defp step(state, ctx, cost \\ 1) do
    steps = state.steps + cost

    if steps > ctx.max_steps do
      %{state | steps: steps, out_of_steps: true}
    else
      %{state | steps: steps}
    end
  end

  # Choose which indices are top members, in ascending (hence lexicographic)
  # order. `chosen` accumulates reversed. Every index already chosen is below
  # `from`, so the indices still available from `from` on are exactly
  # `from..n-1`.
  defp walk_top_sets(0, chosen, _from, ctx, state) do
    state = step(state, ctx)
    tops = Enum.reverse(chosen)
    top_mask = Enum.reduce(tops, 0, &(&2 ||| 1 <<< &1))
    bottoms = for i <- 0..(ctx.n - 1)//1, (top_mask >>> i &&& 1) == 0, do: i
    bottom_mask = (1 <<< ctx.n) - 1 &&& bnot(top_mask)
    walk_bottoms(tops, length(tops), bottoms, bottom_mask, [], {0, 0, 0, 0}, ctx, state)
  end

  defp walk_top_sets(need, chosen, from, ctx, state) do
    Enum.reduce_while(from..(ctx.n - 1)//1, state, fn idx, state ->
      if done?(state) do
        {:halt, state}
      else
        # A top member must have SOMETHING larger left to pair with; the
        # largest index can never be a top. Cheap prefix prune.
        if idx == ctx.n - 1 do
          {:cont, state}
        else
          state = walk_top_sets(need - 1, [idx | chosen], idx + 1, ctx, state)

          {:cont, state}
        end
      end
    end)
  end

  # Assign each top (in ascending order) its bottom, trying bottoms in
  # ascending order so the bottom sequence comes out lexicographically.
  #
  # `k` is `length(tops)`, and `length(bottoms)` is always the same. `costs`
  # is `{c8, c9, c10, soft}` of the pairs in `acc`, summed as they are added, so a
  # complete candidate's criteria cost nothing more to know.
  defp walk_bottoms([], _k, [], _bottom_mask, acc, costs, ctx, state) do
    state = step(state, ctx)
    score_candidate(acc, costs, ctx, state)
  end

  defp walk_bottoms([t | tops], k, bottoms, bottom_mask, acc, costs, ctx, state) do
    state = step(state, ctx)
    node = {t, tops, k, bottoms, bottom_mask, elem(ctx.allowed, t), acc, costs}
    try_bottoms(bottoms, node, ctx, state)
  end

  # The bottoms of one top, in order - a plain recursion rather than
  # `Enum.reduce_while/3`, whose protocol dispatch was a sixth of the walk.
  defp try_bottoms([], _node, _ctx, state), do: state

  defp try_bottoms([b | more], node, ctx, state) do
    {t, tops, k, bottoms, bottom_mask, allowed, acc, costs} = node

    cond do
      done?(state) ->
        state

      # The top member is by definition the smaller TPN of its pair.
      b < t ->
        try_bottoms(more, node, ctx, state)

      # [C1] (2.1.1) - prefix prune. Everything below this choice is dead,
      # and "everything below" is most of the tree.
      (allowed >>> b &&& 1) == 0 ->
        try_bottoms(more, node, ctx, state)

      true ->
        rest = List.delete(bottoms, b)
        rest_mask = bxor(bottom_mask, 1 <<< b)

        # Weighted: `completable?/5` is a matching over the whole
        # remainder, so it is not one unit of the same work `walk_bottoms/8`
        # is. Charged by the size of the sub-problem it is asked about -
        # `length(tops) + length(rest)`, the two being equal - which is what
        # its cost was proportional to when the budget was set. The charge
        # is unchanged by the 2026-09-16 speed-up, so a bracket runs out of
        # steps at exactly the point it always did.
        state = step(state, ctx, 2 * (k - 1))

        state =
          if not state.out_of_steps and completable?(tops, k - 1, rest, rest_mask, ctx) do
            costs = add_costs(costs, t, b, ctx)
            walk_bottoms(tops, k - 1, rest, rest_mask, [{t, b} | acc], costs, ctx, state)
          else
            state
          end

        try_bottoms(more, node, ctx, state)
    end
  end

  # [C3]-flavoured prune inside the bracket: can the remaining tops still be
  # given distinct legal bottoms at all? Answering it here turns a doomed
  # subtree into one feasibility query instead of a full descent.
  #
  # Skipped for tiny remainders, where descending is cheaper than asking. A
  # single top and a single bottom answer "yes" without checking that the two
  # have not met: the descent finds out, and the answer has always been
  # given this way, so the walk's step count depends on it.
  #
  # The matching is `Matching.bipartite_perfect?/3` over the precomputed
  # `allowed` masks. It used to build a fresh adjacency map over the whole
  # remainder with a list-membership test per pair - cubic in the bracket
  # size, and on a 500-team round one nearly all of the fifty seconds the
  # round took. Both answer whether a perfect matching exists, so the walk
  # prunes exactly the same subtrees. Up to three tops - most of the calls,
  # the walk spending its time near the leaves - every assignment is simply
  # tried.
  defp completable?(_tops, k, _bottoms, _bottom_mask, _ctx) when k <= 1, do: true

  defp completable?(tops, k, bottoms, _bottom_mask, ctx) when k <= 3,
    do: assignable?(tops, bottoms, ctx.allowed)

  defp completable?(tops, _k, _bottoms, bottom_mask, ctx),
    do: Matching.bipartite_perfect?(tops, bottom_mask, ctx.allowed)

  defp assignable?([], [], _allowed), do: true

  defp assignable?([t | tops], bottoms, allowed) do
    mask = elem(allowed, t)

    Enum.any?(bottoms, fn b ->
      (mask >>> b &&& 1) == 1 and assignable?(tops, List.delete(bottoms, b), allowed)
    end)
  end

  # {c8, c9, c10, soft} of one pair, added to the running sums: the same
  # three counts `criteria/2` makes per pair, from the tables, and whether
  # the pair is one the arbiter would rather not see (always 0 without soft
  # pairs, so the comparisons below order exactly as the three did).
  defp add_costs({c8, c9, c10, soft} = costs, t, b, ctx) do
    {colour_t, strong_t, up_t, floated_t} = elem(ctx.info, t)
    {colour_b, strong_b, up_b, floated_b} = elem(ctx.info, b)

    c10_add =
      if ctx.c10? do
        bool_to_int(up_t and floated_b) + bool_to_int(up_b and floated_t)
      else
        0
      end

    soft_add = soft_bit(ctx.soft_masks, t, b)

    cond do
      # `clash?/2`: both want a colour, and the same one.
      colour_t != nil and colour_t == colour_b ->
        c9_add = if ctx.type == :b and strong_t and strong_b, do: 1, else: 0
        {c8 + 1, c9 + c9_add, c10 + c10_add, soft + soft_add}

      c10_add == 0 and soft_add == 0 ->
        costs

      true ->
        {c8, c9, c10 + c10_add, soft + soft_add}
    end
  end

  defp soft_bit(nil, _t, _b), do: 0
  defp soft_bit(masks, t, b), do: elem(masks, t) >>> b &&& 1

  # 3.6.4's three minimisation criteria for a complete candidate - already
  # summed along the walk (`add_costs/4`), so equal to `criteria/2` of its
  # pairs. The pairs themselves are only built for a new best.
  defp score_candidate(acc, scores, ctx, state) do
    state = %{state | candidates: state.candidates + 1}

    cond do
      state.candidates > ctx.max_candidates ->
        %{state | exhausted: true}

      is_nil(state.best_scores) or scores < state.best_scores ->
        pairs =
          acc
          |> Enum.reverse()
          |> Enum.map(fn {t, b} -> {elem(ctx.tpns, t), elem(ctx.tpns, b)} end)

        %{state | best: pairs, best_scores: scores}

      true ->
        state
    end
  end

  @doc """
  `{c8, c9, c10}` for a complete candidate pairing.

  * [C8] (2.3.5) - teams whose colour preference is not fulfilled. A pair
    where both want the same colour leaves exactly one unfulfilled; a pair
    with opposite or absent preferences leaves none. This counts what
    Article 4 will be forced to refuse, without running Article 4 - and it
    does not need to, because the only pairs that cost anything are the ones
    wanting the same colour.
  * [C9] (2.3.6) - the same count restricted to STRONG preferences, Type B
    only. Zero under Type A, where no preference is mild and 4.3.4 never
    fires.
  * [C10] (2.3.7) - upfloaters' opponents that were floaters in the previous
    round. Nothing in the last two rounds.
  """
  def criteria(pairs, ctx) do
    c8 =
      Enum.count(pairs, fn {a, b} ->
        clash?(
          Team.preference(Map.fetch!(ctx.by_tpn, a), ctx.type, ctx.last_round?),
          Team.preference(Map.fetch!(ctx.by_tpn, b), ctx.type, ctx.last_round?)
        )
      end)

    c9 =
      if ctx.type == :b do
        Enum.count(pairs, fn {a, b} ->
          pa = Team.preference(Map.fetch!(ctx.by_tpn, a), ctx.type, ctx.last_round?)
          pb = Team.preference(Map.fetch!(ctx.by_tpn, b), ctx.type, ctx.last_round?)
          clash?(pa, pb) and Team.strong?(pa) and Team.strong?(pb)
        end)
      else
        0
      end

    c10 =
      if ctx.last_two_rounds? or MapSet.size(ctx.upfloaters) == 0 do
        0
      else
        # Counted per TEAM, as 2.3.7 reads ("the number of upfloaters'
        # opponents"): when two upfloaters meet and both floated last round,
        # each is an upfloater's opponent that floated, and that is two. It
        # was counted once per pair; found by reading while writing the
        # whole-round reference in `team_pairing_validation_test.exs`, whose
        # generated rounds had not happened to reach the shape.
        Enum.reduce(pairs, 0, fn {a, b}, n ->
          n + bool_to_int(opponent_of_upfloater_floated?(a, b, ctx)) +
            bool_to_int(opponent_of_upfloater_floated?(b, a, ctx))
        end)
      end

    {c8, c9, c10}
  end

  # Both teams wanting the same colour is the only shape that costs a team
  # its preference: one of them must be refused.
  defp clash?(:none, _), do: false
  defp clash?(_, :none), do: false
  defp clash?({c, _}, {c, _}), do: true
  defp clash?(_, _), do: false

  defp opponent_of_upfloater_floated?(upfloater_tpn, opponent_tpn, ctx) do
    MapSet.member?(ctx.upfloaters, upfloater_tpn) and
      Map.fetch!(ctx.by_tpn, opponent_tpn).floated_last_round?
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp done?(%{out_of_steps: true}), do: true
  defp done?(%{best_scores: {0, 0, 0, 0}}), do: true
  defp done?(%{exhausted: true}), do: true
  defp done?(_), do: false
end

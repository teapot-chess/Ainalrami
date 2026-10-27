defmodule Ainalrami.WeightedMatching do
  @moduledoc """
  Maximum-weight matching in a general (non-bipartite) graph - the
  Galil/Micali/Gabow (1986) primal-dual algorithm, confirmed as what
  bbpPairings actually uses from its own source (`src/matching/computer.h`:
  "the basic algorithm presented in 'An O(EV log V) Algorithm for Finding
  a Maximal Weighted Matching in General Graphs'", implemented at O(n^3)).

  This is a port of the CONTROL FLOW read directly from that source
  (`src/matching/detail/graph.cpp`, `rootblossom.cpp`, `parentblossom.cpp`,
  `computer.cpp`) - not a reconstruction from memory. An earlier attempt
  in this project WAS written from memory and was wrong in a way that
  wouldn't have announced itself (a stub main loop, a silently-overwritten
  branch) - exactly the failure mode a weighted matcher is dangerous for,
  since a wrong result here is a legal-looking pairing that simply isn't
  the best one, not an illegal one a legality check would catch.

  ## Finding the minimum without rescanning

  Every "find the minimum X" step in `graph.cpp` was originally reproduced
  here as a plain `Enum` walk over the whole state - a much smaller and
  more directly verifiable translation, at the cost of the asymptotics
  bbpPairings buys with its `minOuterEdges` tables and per-blossom
  `minOuterEdgeResistance`.

  That was defensible while `Ainalrami.Pairing`'s brackets were small
  (median 9, p90 19 for a combined current+next bracket) and stopped being
  so once the engine was pointed at a 209-player field, where the whole
  round is handed to this module 124 times: one round took ninety seconds.

  The two dominant scans are now maintained incrementally instead - see
  the "delta-scan caches" section below for what is stored and, more
  importantly, for the property that makes maintaining it sound. The
  remaining walks are over one blossom or one label class rather than over
  every vertex pair.

  **That changed which minimum was found when several tie, and 86% of
  delta steps have a tied minimum.** It was measured before the caches
  were written rather than assumed: inverting the tie-break of the old
  scans left the engine agreeing with bbpPairings on 1358/1358 rounds.
  That is evidence that the PAIRING rarely depends on it, not that the
  matching does: when several maximum-weight matchings exist, which one
  this module returns - and the duals and blossoms it leaves for the next
  solve - is decided by the order the search meets equal-resistance
  edges. Every tie-break here is therefore a fixed, canonical rule
  (`{resistance, vertex}` orders, "first offered wins" in a fixed walk
  order, sorted blossom ids), and a change to this module must keep each
  one exactly: `tools/matching_lockstep.exs` holds it to a previous
  release call by call.

  ## The four dual-adjustment cases

  Every "stage" (one call to `augment_once/1`) grows an alternating
  forest from every currently-unmatched vertex, repeatedly finding the
  SMALLEST amount by which every dual variable in the forest can move
  before something becomes tight, and reacting to whichever thing that
  is:

    * an unmatched OUTER vertex's own dual variable hits zero - done,
      matching increases by one (see `graph.cpp`'s
      `!minOuterDualVariable` branch)
    * a ZERO-labelled (already-zero-dual, unmatched) vertex becomes
      tight against an OUTER vertex - augment directly between them
    * two OUTER vertices in DIFFERENT trees become tight - augment
      between them
    * two OUTER vertices in the SAME tree become tight - that closes an
      odd cycle; contract it into one blossom
    * a FREE (matched, not yet in the forest) vertex becomes tight
      against an OUTER vertex - grow the tree: label it INNER, label its
      match OUTER
    * an INNER blossom's OWN dual variable hits zero - it has no slack
      left to contribute; dissolve it back into its children, relabelling
      each by position relative to where the tree entered it

  Verified against `Ainalrami.Matching`'s exact subset-DP as an
  independent oracle - see `weighted_matching_test.exs` - because total
  weight is the one thing a legality check cannot confirm.

  ## Doubled weights

  Following bbpPairings exactly: every edge weight is doubled internally
  so dual variables stay integral through the `>> 1` divisions the
  four-way minimum needs. `solve/2` takes plain integer weights and
  doubles them itself.
  """

  alias Ainalrami.WeightedMatching.Profile

  @doc """
  Maximum-weight matching over vertices `0..n-1`.

  `edges` is `[{i, j, weight}]` with POSITIVE integer weights (zero and
  negative are treated as "no edge" - bbpPairings' own convention, and
  safe here because `Ainalrami.Pairing`'s packed criterion weights are
  always at least 1 for any legal pair: the lowest-priority term, rank
  spread, is `abs(a.rank - b.rank)` and a pair's two ranks are always
  distinct).

  Returns `%{vertex => partner}` with both directions of every matched
  pair present; unmatched vertices are absent from the map.
  """
  def solve(n, _edges) when n <= 1, do: %{}

  def solve(n, edges) do
    n
    |> new(edges)
    |> solve()
    |> elem(1)
  end

  @doc """
  A persistent matcher over vertices `0..n-1`, for callers that solve the
  same graph repeatedly with small changes between solves.

  `Ainalrami.Pairing`'s bracket cascade solves the whole field about a
  hundred and twenty times per round, and between consecutive solves the
  median change is about two hundred edges out of five thousand -- under
  four percent -- and sometimes none at all. Solving each from an empty
  matching ran roughly a hundred stages every time; re-augmenting from the
  previous solution runs a handful.

  This is exactly what bbpPairings' `Computer` does, and the algorithm is
  its `setEdgeWeight` / `prepareVertexForWeightAdjustments`: when an
  edge's weight changes, its MODIFIED endpoint (`u` in `set_weight/4`) is
  unmatched, every blossom containing it is dissolved back to trivial, and
  its dual is reset to the initial maximum; the other endpoint keeps its
  match, dual and blossoms (it is left exposed only if it was matched to
  `u`), as does every other vertex. That state is still a valid starting
  point for the primal-dual search -- the invariants the algorithm
  maintains (dual feasibility, complementary slackness on matched edges)
  hold on the untouched part, and the prepared vertex is exactly as it was
  at the start of a fresh solve -- so `solve/1` reaches an optimum of the
  new weights. See `set_weight/4` for why one side is enough.

      state = WeightedMatching.new(n, edges)
      {state, matching} = WeightedMatching.solve(state)
      state = WeightedMatching.set_weight(state, u, v, new_w)
      {state, matching} = WeightedMatching.solve(state)

  `solve/2` is `new/3` followed by one `solve/1`, and remains the API for
  one-shot callers and for the tests.

  Options: `:max_weight` (the ceiling every later weight must stay under,
  on the caller's scale), `:gcd` (override the weight reduction), and
  `:duals` -- a map of initial dual values, one per vertex, on TWICE the
  weight scale: `duals[u] + duals[v] >= 2 * w(u, v)` must hold on every
  edge, and the edges where it holds with equality are the ones the
  greedy start may match. A caller whose weights are a sum of per-vertex
  terms can make every edge tight this way and hand the search an almost
  complete matching; see `greedy_start/3`.

  `:adjacency` hands over the nested `%{u => %{v => 2w}}` map that
  `build_state/5` would otherwise fold out of `edges`, ALREADY DOUBLED, and
  `edges` is then ignored. It exists for a caller that knows its whole graph
  up front and can emit that structure directly: `Ainalrami.Pairing`'s
  odd-field bye bootstrap builds a COMPLETE graph, so the `[{i, j, w}]` list
  in between was 500,500 tuples at n=1,001 allocated only to be consumed
  here, and the fold on top of them was a million `Map.update/4`s. Pass
  `:max_weight` with it - the ceiling is otherwise derived from `edges`,
  which such a caller does not supply. `symmetric: true` with it says every
  edge sits in both its endpoints' rows at one weight, as `adjacency_of/1`
  leaves them, so the greedy start may test tightness the way it does for
  a graph built here (`greedy_start/4`); the state is then the one `edges`
  would have built.
  """
  def new(n, edges, opts \\ []) do
    if Profile.on?() do
      t0 = System.monotonic_time(:microsecond)
      state = new_state(n, edges, opts)
      us = System.monotonic_time(:microsecond) - t0
      site = Profile.site()
      Profile.record(:new, site, n, us, profile_info(state))
      Profile.capture({:new, site, n, edges, opts})
      state
    else
      new_state(n, edges, opts)
    end
  end

  defp new_state(n, edges, opts) do
    # `:gcd` overrides the reduction. A persistent caller whose LATER
    # weights may not share the initial edges' common factor passes
    # `gcd: 1` and forgoes the bignum saving rather than risk
    # `set_weight/4` refusing a weight that is not on the initial scale.
    # `:duals` -- see `greedy_start/3` -- are on the doubled scale the
    # matcher compares against, so they are not reduced, and neither is a
    # ready-made `:adjacency`; a caller giving either gets no reduction.
    #
    # The weights are divided by the gcd the state RECORDS, which every
    # later conversion (`set_weight/4`, `shift_and_set/3`, `edge_weight/3`,
    # `neighbours/2`) reads. They used to be divided by their own gcd
    # whatever `:gcd` said, so `gcd: 2` over weights 12 and 24 stored them
    # divided by 12 and read them back on a scale of 2. A supplied gcd that
    # does not divide every positive weight is refused, as `set_weight/4`
    # refuses such a weight later.
    gcd =
      case {Keyword.get(opts, :gcd), Keyword.get(opts, :duals), Keyword.get(opts, :adjacency)} do
        {nil, nil, nil} ->
          gcd_of(edges)

        {nil, _, _} ->
          1

        {1, _, _} ->
          1

        {g, nil, nil} when is_integer(g) and g > 1 ->
          check_divides!(edges, g)
          g

        {g, _, _} when is_integer(g) and g > 1 ->
          raise ArgumentError,
                "new/3: gcd: #{g} cannot be combined with :duals or :adjacency, " <>
                  "which are on the unreduced scale"
      end

    edges = if gcd > 1, do: divide_weights(edges, gcd), else: edges

    # The initial dual, and the ceiling every later weight must stay under
    # -- bbpPairings fixes `aboveMaxEdgeWeight` at construction and asserts
    # on `setEdgeWeight`. Defaults to the largest weight present, which is
    # right for a one-shot solve; a caller that will raise weights later
    # passes `:max_weight` explicitly, on the caller's own scale.
    ceiling =
      case Keyword.get(opts, :max_weight) do
        nil -> nil
        w -> 2 * div(w, gcd)
      end

    state =
      build_state(
        n,
        edges,
        ceiling,
        Keyword.get(opts, :duals),
        Keyword.get(opts, :adjacency),
        Keyword.get(opts, :symmetric, false)
      )

    Map.put(state, :gcd, gcd)
  end

  @doc """
  Re-augment from the current matching to a maximum-weight one. Returns
  `{state, matching}`; the state carries the solution forward.
  """
  def solve(state) do
    if Profile.on?() do
      Process.put(:wm_stages, 0)
      Process.put(:wm_grow_total, 0)
      Process.put(:wm_expanded, 0)
      t0 = System.monotonic_time(:microsecond)
      {solved, _} = result = solve_state(state)
      us = System.monotonic_time(:microsecond) - t0

      info =
        Map.merge(profile_info(solved), %{
          stages: Process.get(:wm_stages),
          grow: Process.get(:wm_grow_total),
          formed: solved.next_blossom_id - state.next_blossom_id,
          expanded: Process.get(:wm_expanded)
        })

      site = Profile.site()
      Profile.record(:solve, site, state.n, us, info)
      Profile.capture({:solve, site, state})
      result
    else
      solve_state(state)
    end
  end

  defp profile_info(state) do
    edges = Enum.reduce(state.weight, 0, fn {_, row}, acc -> acc + map_size(row) end)
    bits = if state.max_w > 0, do: length(Integer.digits(state.max_w, 2)), else: 0
    %{edges: div(edges, 2), bits: bits}
  end

  defp solve_state(state) do
    # Caches are carried stage to stage WITHIN a solve (`carry_caches/2`)
    # and never across one: a `set_weight/4` in between changed weights the
    # cached resistances were computed from. Cleared here so the first stage
    # rebuilds; an empty label map is the signal `carry_caches/2` reads.
    state = %{state | label: %{}}

    state =
      state
      |> greedy_resume()
      |> even_up_exposed_duals()
      |> augment_until_done()
      |> resolve_all_matching()

    {state, to_matching(state)}
  end

  # The resumed-solve counterpart of `greedy_start/3`: every vertex that
  # `prepare_vertex/2` reset -- exposed, its own top-level blossom, its
  # dual back at the ceiling -- gets the lowest dual that keeps every edge
  # at it feasible against its neighbours' CURRENT duals, `max(2w - y_u)`,
  # and is then matched to its lowest-indexed exposed neighbour on a tight
  # edge if it has one. That is exactly what the first stage would do for
  # it when its tightest neighbour is exposed -- bring the dual down, find
  # the tight outer-outer edge, augment -- minus the stage: its label reset,
  # cache rebuild and tree growth across the field. At a bracket boundary
  # every resident is prepared and their heaviest edges are to each other,
  # so most of them pair here.
  defp greedy_resume(state) do
    max_w = state.max_w

    fresh =
      for v <- 0..(state.n - 1)//1,
          Map.fetch!(state.in_blossom, v) == v,
          not Map.has_key?(state.blossom_match, v),
          Map.fetch!(state.dual, v) == max_w,
          do: v

    case fresh do
      [] ->
        state

      _ ->
        {dual, bm} =
          Enum.reduce(fresh, {state.dual, state.blossom_match}, fn v, {dual, bm} ->
            # Both walks of the row keep a maximum or a least vertex, so the
            # row's order does not matter.
            row = :maps.to_list(Map.get(state.weight, v, %{}))
            yv = feasible_dual(row, dual, 0)
            dual = Map.put(dual, v, yv)

            if Map.has_key?(bm, v) do
              {dual, bm}
            else
              partner = resume_partner(row, yv, dual, state.in_blossom, bm, nil)

              case partner do
                nil -> {dual, bm}
                u -> {dual, bm |> Map.put(v, u) |> Map.put(u, v)}
              end
            end
          end)

        %{state | dual: dual, blossom_match: bm}
    end
  end

  # `max(2w - y_u)` over the row, and 0.
  defp feasible_dual([], _dual, acc), do: acc

  defp feasible_dual([{u, w2} | rest], dual, acc) do
    need = w2 - :erlang.map_get(u, dual)
    feasible_dual(rest, dual, if(need > acc, do: need, else: acc))
  end

  # The lowest-indexed neighbour on a tight edge that is its own top-level
  # blossom and exposed.
  defp resume_partner([], _yv, _dual, _ib, _bm, best), do: best

  defp resume_partner([{u, w2} | rest], yv, dual, ib, bm, best) do
    if (best == nil or u < best) and not is_map_key(bm, u) and :erlang.map_get(u, ib) == u and
         yv + :erlang.map_get(u, dual) == w2,
       do: resume_partner(rest, yv, dual, ib, bm, u),
       else: resume_partner(rest, yv, dual, ib, bm, best)
  end

  # bbpPairings' `computeMatching()` prologue (graph.cpp:793-845): "Make
  # sure all exposed Vertex dualVariables have the same parity."
  #
  # Within a stage the dual adjustment can be half a unit of the doubled
  # scale, so a MATCHED vertex can finish a solve with an odd dual -- which
  # is fine while it stays matched, because the sum along its matched edge
  # stays even. `prepare_vertex/2` unmatches that vertex's partner without
  # touching the partner's dual, and an EXPOSED vertex with an odd dual
  # breaks the arithmetic: the four-way minimum halves the outer-outer and
  # inner-blossom candidates, every tightness event is missed by one, and
  # `grow_with_delta/6` reaches its "nothing became tight" branch. That
  # branch used to stop the solve early - measured: three odd duals at
  # entry, and a twelve-vertex solve that stopped after one augmentation
  # with ten exposed vertices left - and now raises (`no_event!/6`).
  #
  # The fix is theirs exactly: every exposed blossom whose base dual is odd
  # gets +1 on each of its vertices, and -2 on its own blossom dual if it
  # is non-trivial, so every edge's dual sum is unchanged. On a fresh solve
  # every dual is `max_w`, which is even, so this is a no-op there and
  # `solve/2` is unaffected.
  #
  # "Every exposed blossom" is not "every exposed TOP-LEVEL blossom", and
  # the difference is the whole of `descend_to_adjustable/3`. The -2 has to
  # come from a blossom that HAS 2 to give, and a top-level one need not:
  # `form_blossom/5` creates a blossom at dual 0, and it only gains
  # `2 * delta` while it is labelled `:outer`, so one formed around a tree
  # root whose stage ends on an immediately-following delta-0 augmentation
  # finishes the solve matched and still at 0. `set_weight/4` then prepares
  # only its external partner, and `prepare_vertex/2` leaves that blossom
  # non-trivial and EXPOSED with its dual untouched - so the next `solve/1`
  # took 2 from a zero and left a NEGATIVE blossom dual behind, which is
  # not a feasible dual solution and which every later delta computation
  # then reads as though it were.
  #
  # The reference descends instead (`graph.cpp:805-843`): from the exposed
  # root blossom, walk into the child holding the base while that child is
  # itself a non-trivial blossom with dual 0, dissolving each zero-dual
  # ancestor on the way down (`freeAncestorOfBase`), and take the -2 from
  # the first blossom that has it - or from nothing at all, if the descent
  # reaches a bare vertex. The +1 goes to the vertices of THAT blossom, not
  # of the one we started from; the siblings dropped on the way down came
  # out matched to each other, so their own parity is already right.
  #
  # Dissolving a zero-dual blossom is free: `dissolve_one/3` hands each
  # vertex `z_B / 2`, which is 0.
  defp even_up_exposed_duals(state) do
    # Before the first stage the label map is empty and `top_blossoms/1`
    # would see nothing; on a fresh state every dual is `max_w`, even, so
    # falling back to `in_blossom` here costs one walk and changes nothing.
    top =
      if map_size(state.label) == 0,
        do: :lists.usort(Map.values(state.in_blossom)),
        else: top_blossoms(state)

    Enum.reduce(top, state, fn b, state ->
      if not matched?(state, b) and rem(dual_of(state, base_vertex(state, b)), 2) == 1 do
        label_before = state.label
        {state, b, dissolved} = descend_to_adjustable(state, b, [])

        # `dissolve_one/3` is written for the BETWEEN-STAGES path and
        # labels every child it frees `:free`. Here there is no tree yet:
        # `solve/1` has just cleared the label map, and `carry_caches/2`
        # reads an empty one as "rebuild from scratch". Leaving the labels
        # behind made the first stage carry caches computed against the
        # weights of the previous solve, and cost a bracket that had been
        # right - seed 19 round 2 of the default bbpPairings corpus,
        # 23 players, four boards different. Only the labels are undone;
        # everything else `dissolve_one/3` writes is the structural edit
        # this wants.
        state = %{state | label: Map.drop(label_before, dissolved)}

        vs = blossom_vertices(state, b)
        dual = Enum.reduce(vs, state.dual, fn v, d -> Map.update!(d, v, &(&1 + 1)) end)

        dual =
          if Map.has_key?(state.children, b),
            do: Map.update!(dual, b, &take_two(&1, b)),
            else: dual

        %{state | dual: dual}
      else
        state
      end
    end)
  end

  # `graph.cpp:827-830` asserts this rather than checking it, and so does
  # this - the descent above is what makes it true, and a blossom dual
  # below zero is not a dual solution at all. Left as a raise because it is
  # cheap, because the negative value is otherwise silent (every later
  # delta computation simply reads it), and because it took a probe to see
  # it at all: instrumented right here, the version without the descent
  # produced 734 negative duals over 800 nine-round tournaments while
  # agreeing with bbpPairings on every one of them.
  defp take_two(z, _b) when z >= 2, do: z - 2

  defp take_two(z, b) do
    raise "WeightedMatching: blossom #{b} has dual #{z}, too little to even up its base"
  end

  # `graph.cpp:812-823`. Returns the blossom (or bare vertex) the -2 is to
  # come from, with every zero-dual ancestor between it and `b` dissolved,
  # and the ids of the ones dissolved on the way.
  defp descend_to_adjustable(state, b, dissolved) do
    cond do
      not Map.has_key?(state.children, b) ->
        {state, b, dissolved}

      Map.fetch!(state.dual, b) != 0 ->
        {state, b, dissolved}

      true ->
        base = base_vertex(state, b)
        state = dissolve_one(state, b, base)
        descend_to_adjustable(state, Map.fetch!(state.in_blossom, base), [b | dissolved])
    end
  end

  @doc """
  The vertex `v` is matched to, or `nil` when it is exposed. Valid after a
  `solve/1`.
  """
  def mate_of(state, v), do: Map.get(state.mate, v)

  @doc """
  Re-weight edges WITHOUT preparing anyone, by moving duals instead.

  `shifts` is `%{vertex => delta}` (on the doubled scale; an even integer,
  or it raises); `edges` is `[{u, v, w}]` on the caller's scale (a multiple
  of the state's gcd, or it raises) between two distinct vertices of the
  graph. The result is `{:ok, state}` with every listed edge feasible,
  EVERY edge at a vertex whose dual went down feasible whether listed or
  not, every matched edge at a shifted vertex and every matched listed
  edge tight, and the shifted duals non-negative -- or `:error`, in which
  case the caller falls back to `set_weight/4`. `:error` also covers a
  touched vertex inside a non-trivial blossom: such a vertex is refused,
  not dissolved (see the comment in the body). Nothing is unmatched, so a
  `solve/1` after a successful call finds the matching already optimal
  when it was optimal before.

  Why the unlisted edges are checked at a LOWERED dual and nowhere else:
  a shift moves the slack of every edge at its vertex, not only the
  listed ones. Every touched vertex is its own top-level blossom, so an
  edge at it carries no blossom dual and its slack is `y[u] + y[v] - w2`.
  An unlisted edge kept its weight, so its slack moved by exactly the
  shifts of its ends: up (or not at all) unless one of them went down.
  Until 2026-10-02 only the listed edges were checked, so a caller that
  lowered a dual and did not list every edge at that vertex could get
  `{:ok, state}` for a state that was not dual feasible - and a `solve/1`
  that then returned a matching that was not maximum. `Ainalrami.Pairing`
  always listed them itself (`shift_to_live/5`), so no pairing changed.

  This exists for one caller: the refinement stage that rewrites every
  remainder pair's weight at once (`Ainalrami.Pairing`'s stage 4). Done
  through `set_weight/4` that prepared every remainder vertex and
  rediscovered the matching from nothing -- 372 stages and 2.7 s of a
  1,000-player round -- for weights whose change is a per-vertex amount
  on one side of every pair, which is exactly what a dual can absorb.
  """
  def shift_and_set(state, shifts, edges) do
    check_shift_args!(state, shifts, edges)

    touched =
      shifts
      |> Map.keys()
      |> Enum.concat(Enum.flat_map(edges, fn {u, v, _} -> [u, v] end))
      |> Enum.uniq()

    # A touched vertex inside a non-trivial blossom is a refusal, not a
    # dissolution: dissolving pushes half the blossom dual into every vertex,
    # which keeps the INTERNAL edges tight but puts that half onto the
    # base.s external match -- fine for `prepare_vertex/2`, which unmatches
    # the base next, and not for this, which unmatches nothing. Tried;
    # the state passed every check here and broke the next real search.

    if Enum.any?(touched, &(Map.fetch!(state.in_blossom, &1) != &1)) do
      :error
    else
      dual =
        Enum.reduce(shifts, state.dual, fn {v, d}, acc -> Map.update!(acc, v, &(&1 + d)) end)

      state =
        Enum.reduce(edges, %{state | dual: dual}, fn {u, v, w}, acc ->
          put_weight(acc, u, v, on_scale!(acc, w, "shift_and_set"))
        end)

      # Every matched edge at a shifted vertex must still be tight, whether
      # or not the caller listed it; every listed edge must be feasible.
      matched_tight? = fn v ->
        case Map.get(state.blossom_match, v) do
          nil ->
            true

          u ->
            w2 = state.weight |> Map.get(v, %{}) |> Map.get(u, 0)
            Map.fetch!(state.dual, v) + Map.fetch!(state.dual, u) == w2
        end
      end

      ok? =
        Enum.all?(shifts, fn {v, _} -> Map.fetch!(state.dual, v) >= 0 and matched_tight?.(v) end) and
          Enum.all?(edges, fn {u, v, w} ->
            w2 = if w <= 0, do: 0, else: 2 * div(w, state.gcd)
            slack = Map.fetch!(state.dual, u) + Map.fetch!(state.dual, v) - w2

            matched? =
              Map.get(state.blossom_match, u) == v or Map.get(state.blossom_match, v) == u

            slack >= 0 and (not matched? or slack == 0)
          end) and
          Enum.all?(shifts, fn {v, d} -> d >= 0 or row_feasible?(state, v) end)

      if ok?, do: {:ok, state}, else: :error
    end
  end

  # Every edge at `v` - a top-level trivial blossom, so no blossom dual sits
  # on any of them - has non-negative slack. See `shift_and_set/3`.
  defp row_feasible?(state, v) do
    yv = Map.fetch!(state.dual, v)
    dual = state.dual

    state.weight
    |> Map.get(v, %{})
    |> Enum.all?(fn {u, w2} -> yv + :erlang.map_get(u, dual) >= w2 end)
  end

  # The shape `shift_and_set/3` promises to work on, refused loudly rather
  # than computed with: an odd shift would leave an exposed dual odd (the
  # parity `even_up_exposed_duals/1` exists to restore), a vertex outside
  # the graph used to surface as a `KeyError` from the middle of the dual
  # update, and a self-loop would be stored as an edge.
  defp check_shift_args!(state, shifts, edges) do
    n = state.n

    if not is_map(shifts),
      do: raise(ArgumentError, "shift_and_set/3: shifts must be a map, got #{inspect(shifts)}")

    Enum.each(shifts, fn
      {v, d} when is_integer(v) and v >= 0 and v < n and is_integer(d) and rem(d, 2) == 0 ->
        :ok

      {v, d} ->
        raise ArgumentError,
              "shift_and_set/3: a shift is a vertex in 0..#{n - 1} and an even integer " <>
                "(the doubled scale), got #{inspect(v)} => #{inspect(d)}"
    end)

    Enum.each(edges, fn
      {u, v, w}
      when is_integer(u) and is_integer(v) and is_integer(w) and u != v and u >= 0 and
             v >= 0 and u < n and v < n ->
        :ok

      other ->
        raise ArgumentError,
              "shift_and_set/3: an edge is {u, v, weight} between two distinct vertices " <>
                "in 0..#{n - 1} with an integer weight, got #{inspect(other)}"
    end)
  end

  @doc """
  Every vertex's dual with the duals of the blossoms containing it folded
  in: `y[v] + sum(z[B] / 2 : B contains v)`, on the doubled scale.

  In this module a blossom's dual is kept apart from its vertices'
  (`dissolve_one/3` hands each vertex `z[B] / 2` when `B` goes), so an edge
  inside a blossom reads `y[u] + y[v] - w2` below zero by the blossom duals
  around it. Folded like this, every edge is feasible on vertex duals
  alone; an edge of the matching that leaves a blossom through its base is
  over-covered by that blossom's half, which is why this is a starting
  point for `Ainalrami.MatchCertificate.certify/5` and not a certificate.
  """
  def vertex_duals(state) do
    tops = state.in_blossom |> Map.values() |> Enum.uniq()

    Enum.reduce(tops, %{}, fn b, acc -> fold_duals(state, b, 0, acc) end)
  end

  defp fold_duals(state, b, above, acc) do
    case Map.get(state.children, b) do
      nil ->
        Map.put(acc, b, Map.fetch!(state.dual, b) + above)

      children ->
        here = above + div(Map.get(state.dual, b, 0), 2)
        Enum.reduce(children, acc, fn c, acc -> fold_duals(state, c, here, acc) end)
    end
  end

  @doc """
  Replace the search state by a certified one: `mate` as the matching,
  `dual` (on the doubled scale) as the vertex duals, no blossoms, and every
  per-solve cache empty. Vertices `dual` does not mention get 0.

  The caller vouches, by `Ainalrami.MatchCertificate.check/5`, that `dual`
  is feasible on every edge, tight on every edge of `mate`, non-negative,
  and that at most one exposed vertex with an edge has a non-zero dual.
  That is a valid state for everything this module does next: `solve/1`
  resumes from any dual-feasible state whose matched edges are tight (the
  resumed solves after `set_weight/4` rely on exactly that), and
  `shift_and_set/3` and `finalize_pair/3` check what they need themselves.
  """
  def install(state, mate, dual) do
    n = state.n
    vertices = 0..(n - 1)//1

    %{
      state
      | dual: Map.new(vertices, fn v -> {v, Map.get(dual, v, 0)} end),
        mate: mate,
        blossom_match: mate,
        in_blossom: Map.new(vertices, &{&1, &1}),
        base: Map.new(vertices, &{&1, &1}),
        children: %{},
        vertices_of: %{},
        parent_of: %{},
        connectors: %{},
        label: %{},
        forest: %{},
        label_edge: %{},
        best_outer: %{},
        cross: cross_empty(),
        shift_outer: 0,
        shift_cross: 0,
        min_outer: nil,
        roots: %{},
        root_min: %{}
    }
  end

  @doc """
  The same state for every weight multiplied by `k`: weights, every dual
  (vertex and blossom) and the ceiling scaled, the structure unchanged. A
  valid state stays valid - feasibility, tight matched edges and tight
  blossom cycles are all linear - so a search resumed from it after a few
  small `set_weight/4` perturbations finds an optimum of the scaled,
  perturbed weights. `Ainalrami.Pairing` asks exactly that to learn how
  far a quantity can move among the optima of the unscaled weights.
  """
  def scale(state, k) when is_integer(k) and k >= 1 do
    %{
      state
      | weight:
          Map.new(state.weight, fn {u, row} ->
            {u, Map.new(row, fn {v, w2} -> {v, k * w2} end)}
          end),
        dual: Map.new(state.dual, fn {v, y} -> {v, k * y} end),
        max_w: k * state.max_w
    }
  end

  @doc """
  A solved state's dual solution in the form
  `Ainalrami.MatchCertificate.certify/5` takes with its `:family` option:
  `{hint, family}`, the vertex duals and every vertex's chain of enclosing
  blossoms (outermost first, with running sums of their duals).

  One change of form, when exactly one vertex with edges is unmatched: the
  top-level blossom around it (if any) is left out of the family and its
  dual moved onto its vertices, half each - the same numbers, now read as
  the certificate's `xi` on the odd set of every vertex with edges. That
  set contains the blossom, so every edge inside the blossom keeps the
  blossom's dual; an edge outside it gains it, which the certificate's
  search takes back off the vertices outside (their dual must stay at or
  above `xi` for that, and the check refuses otherwise).
  """
  def certificate_hint(state) do
    live = for {v, row} <- state.weight, map_size(row) > 0, do: v
    exposed = Enum.reject(live, &is_map_key(state.mate, &1))

    top =
      case exposed do
        [x] ->
          b = Map.fetch!(state.in_blossom, x)
          if Map.has_key?(state.children, b), do: b

        _ ->
          nil
      end

    z_top = if top, do: Map.get(state.dual, top, 0), else: 0

    Enum.reduce(live, {%{}, %{}}, fn v, {hint, family} ->
      chain = blossom_chain(state, v, [])

      {in_top?, chain} =
        if top != nil and chain != [] and hd(chain) == top,
          do: {true, tl(chain)},
          else: {false, chain}

      y = Map.fetch!(state.dual, v) + if(in_top?, do: div(z_top, 2), else: 0)

      family =
        case chain do
          [] ->
            family

          _ ->
            {with_sums, _} =
              Enum.map_reduce(chain, 0, fn b, sum ->
                sum = sum + Map.get(state.dual, b, 0)
                {{b, sum}, sum}
              end)

            Map.put(family, v, with_sums)
        end

      {Map.put(hint, v, y), family}
    end)
  end

  # The blossoms enclosing `v`, outermost first.
  defp blossom_chain(state, v, acc) do
    case Map.get(state.parent_of, v) do
      nil -> acc
      b -> blossom_chain(state, b, [b | acc])
    end
  end

  @doc """
  What a state's duals say about EVERY maximum-weight matching, for
  `possible_partners/3`.

  A state produced by this module's own operations holds an optimal dual
  solution for its weights: vertex duals `y`, blossom duals `z` (keyed by
  blossom id in `state.dual`), every edge's reduced cost
  `y[u] + y[v] + sum(z[B] : B contains u and v) - w2(u, v)` non-negative and
  zero on the matching, and every exposed vertex at dual 0 - or, after
  `install/3`, the one exposed vertex at a dual `xi` no other vertex is
  below, which is the same thing with a dual `2 * xi` on the odd set of all
  vertices that have edges (see `Ainalrami.MatchCertificate`). Either way,
  complementary slackness holds between that dual and EVERY optimal
  matching: each of its edges has reduced cost zero, and each vertex whose
  dual exceeds `xi` is covered.

  Returns the context `possible_partners/3` reads (`xi`, and each nested
  vertex's chain of enclosing blossoms), or `:invalid` when the exposed
  vertices' duals do not have that shape - which a state from `solve/1`,
  `shift_and_set/3`, `finalize_pair/3` or `install/3` never is, and a
  prepared state awaiting a solve always is.
  """
  def dual_context(state) do
    live = for {v, row} <- state.weight, map_size(row) > 0, do: v
    exposed = Enum.reject(live, &is_map_key(state.mate, &1))

    xi =
      case exposed do
        [x] -> Map.fetch!(state.dual, x)
        _ -> 0
      end

    valid? =
      xi >= 0 and Enum.all?(exposed, &(Map.fetch!(state.dual, &1) == xi)) and
        Enum.all?(live, &(Map.fetch!(state.dual, &1) >= xi)) and
        Enum.all?(state.children, fn {b, _} -> Map.get(state.dual, b, 0) >= 0 end) and
        Enum.all?(state.mate, fn {u, v} -> Map.get(state.mate, v) == u end)

    if valid? do
      anc =
        for {v, _} <- state.parent_of, v < state.n, into: %{} do
          {v, ancestors(state, v, [])}
        end

      %{xi: xi, anc: anc}
    else
      :invalid
    end
  end

  # The blossoms enclosing `v`, outermost first, each with the sum of the
  # blossom duals from the outermost down to it.
  defp ancestors(state, v, acc) do
    case Map.get(state.parent_of, v) do
      nil ->
        {chain, _} =
          Enum.map_reduce(acc, 0, fn b, sum ->
            sum = sum + Map.get(state.dual, b, 0)
            {{b, sum}, sum}
          end)

        chain

      b ->
        ancestors(state, b, [b | acc])
    end
  end

  # The sum of the duals of every blossom holding both `u` and `v`: the
  # running sum at their innermost common blossom.
  defp common_z(anc, u, v) do
    case {Map.get(anc, u), Map.get(anc, v)} do
      {nil, _} -> 0
      {_, nil} -> 0
      {cu, cv} -> common_prefix(cu, cv, 0)
    end
  end

  defp common_prefix([{b, s} | cu], [{b, _} | cv], _), do: common_prefix(cu, cv, s)
  defp common_prefix(_, _, s), do: s

  @doc """
  The partners `v` can have in a maximum-weight matching: every neighbour
  joined to it by an edge of reduced cost zero, and whether it can be left
  exposed (its dual is at `xi`). A superset of the truth - see
  `dual_context/1` - so a property every candidate shares is a property of
  every optimum.
  """
  def possible_partners(state, ctx, v) do
    yv = Map.fetch!(state.dual, v)
    anc = ctx.anc

    tight =
      state.weight
      |> Map.get(v, %{})
      |> Enum.reduce([], fn {u, w2}, acc ->
        if yv + Map.fetch!(state.dual, u) + common_z(anc, v, u) == w2, do: [u | acc], else: acc
      end)

    {tight, yv == ctx.xi}
  end

  @doc """
  The weight of the edge `{u, v}` as the caller gave it (to `new/3` or
  `set_weight/4`), or 0 when there is no edge.
  """
  def edge_weight(state, u, v) do
    case state.weight do
      %{^u => %{^v => w2}} -> div(w2 * state.gcd, 2)
      _ -> 0
    end
  end

  @doc """
  Every edge at `u` with a positive weight, as `{neighbour, weight}` pairs on
  the caller's scale.
  """
  def neighbours(state, u) do
    state.weight
    |> Map.get(u, %{})
    |> Enum.map(fn {v, w2} -> {v, div(w2 * state.gcd, 2)} end)
  end

  @doc """
  Change the weight of the edge between `u` and `v`. Zero or negative
  removes it. The next `solve/1` re-augments from the previous solution.

  **Only `u` is prepared** -- unmatched, its blossoms dissolved, its dual
  reset. `v` is left exactly as it was, match and all. This asymmetry is
  bbpPairings' `setEdgeWeight(modifiedVertex, neighbor, w)` and it is
  what makes the whole thing fast: `finalizePair` writes every edge of two
  vertices, `2m` calls, and with only the modified end prepared those `2m`
  calls disturb exactly two vertices. Preparing both ends -- as this did at
  first, from reading the two arguments as symmetric -- unmatched every
  vertex in the graph on every finalisation, and the "resumed" solve ran
  ~m/2 stages, the same as a cold one. Measured: 104 stages against 11.

  Why one side is enough: the invariants are per edge. Dual feasibility on
  `(u, v)` holds for any weight under the ceiling once `u`'s dual is back
  at the maximum. Complementary slackness on `v`'s matched edge `(v, x)`
  is untouched, since that edge's weight did not change. The one case
  where `v`'s state DID depend on `(u, v)` is `v` matched to `u`, and
  preparing `u` unmatches that pair from `u`'s side, leaving `v` exposed
  -- which is exactly the state a fresh solve would put it in.

  The weight is reduced by the same GCD `new/3` found, so it lands on the
  same scale as the edges already stored; a weight that is not a multiple
  of that GCD, or that would exceed the initial dual, raises -- both mean
  the caller's weights have changed shape and a fresh `new/3` is needed.
  """
  def set_weight(state, u, v, w) when u != v do
    w2 = doubled!(state, w, "set_weight")

    state
    |> prepare_vertex(u)
    |> put_weight(u, v, w2)
  end

  @doc """
  Lock a pair that is ALREADY matched to each other, by dropping every
  OTHER edge either endpoint holds -- with no `prepare_vertex/2` at all.

  `Ainalrami.Pairing`'s `finalize_pair/3` calls this right after a `solve/1`
  found `u` and `v` matched together. The old way to lock that in was
  `set_weight/4` on every one of their edges: raise `(u, v)` to the
  ceiling, zero everything else, each write through `prepare_vertex/2` --
  which unmatches `u`, then unmatches `v`, dissolving any blossom either
  sits in and resetting both duals to the maximum, so the NEXT `solve/1`
  re-discovers this exact pair from scratch by augmenting path search. At
  1000 players `stage_first_group_partners` alone does ~482 of these.

  Dropping an edge is a pure RELAXATION and needs none of that. Dual
  feasibility only requires `y_u + y_v >= w(u, v)`; lowering `w` to zero
  can only make that easier. Complementary slackness only constrains
  MATCHED edges, and every edge being dropped here is by construction
  unmatched -- `u` and `v` have only each other. So `state.dual`,
  `state.mate`, `state.blossom_match` and `state.in_blossom` all stay
  exactly as they are, and the matched edge `(u, v)` is left at whatever
  weight it already had -- NOT raised to the ceiling. It doesn't need to
  be: once every other edge at `u` and `v` is gone, `(u, v)` is the only
  edge either vertex has, every weight is positive
  (`solve/2`'s own doc), and a maximum-weight matching always takes the
  one positive edge available over leaving both ends exposed. So the pair
  stays forced without the weight bump that used to force it.

  Refuses (`:error`) when `u` or `v` sits inside a non-trivial blossom, or
  when they turn out not to be matched to each other after all (the
  caller's invariant broken, or the wrong vertex ids passed). The blossom
  case is the one that matters and mirrors `shift_and_set/3`'s own guard:
  `dissolve_one/3` rebases a blossom at whichever vertex is about to be
  unmatched and pushes half the blossom's dual onto the base's OLD
  external match -- sound when that match is removed right after, which
  is what `prepare_vertex/2` does next and this never does. A version
  that dissolved anyway and checked every local invariant still broke the
  next real search. Either refusal sends the caller back to `set_weight/4`,
  which is correctness-safe by construction -- it is the path already
  proven right, just slower.
  """
  def finalize_pair(state, u, v) when u != v do
    if Map.fetch!(state.in_blossom, u) != u or Map.fetch!(state.in_blossom, v) != v or
         Map.get(state.blossom_match, u) != v or Map.get(state.blossom_match, v) != u do
      :error
    else
      weight = state.weight |> drop_other_edges(u, v) |> drop_other_edges(v, u)
      {:ok, %{state | weight: weight}}
    end
  end

  # A caller's weight on the doubled, reduced scale the state stores - zero
  # for no edge - refused when it is not a multiple of the state's gcd
  # (`shift_and_set/3` used to truncate such a weight silently) or, for
  # `set_weight/4`, exceeds the ceiling the duals are reset to: both mean
  # the caller's weights have changed shape and a fresh `new/3` is needed.
  # `shift_and_set/3` resets no dual, and checks the feasibility it needs
  # itself.
  defp on_scale!(state, w, who) do
    cond do
      w <= 0 ->
        0

      rem(w, state.gcd) != 0 ->
        raise ArgumentError,
              "#{who}: #{w} is not on the scale this matcher was built at " <>
                "(gcd #{state.gcd}); build a fresh state"

      true ->
        2 * div(w, state.gcd)
    end
  end

  defp doubled!(state, w, who) do
    w2 = on_scale!(state, w, who)

    if w2 > state.max_w do
      raise ArgumentError,
            "#{who}: weight exceeds the initial dual this matcher was built with; " <>
              "build a fresh state"
    end

    w2
  end

  # Zero every edge `keep_v` has except the one to `keep`, both directions
  # -- `state.weight` is kept symmetric by `put_weight/4`, so the far side
  # of each dropped edge needs its own entry removed too.
  defp drop_other_edges(weight, keep_v, keep) do
    row = Map.get(weight, keep_v, %{})

    weight =
      Enum.reduce(row, weight, fn {u, _w2}, acc ->
        if u == keep, do: acc, else: Map.update!(acc, u, &Map.delete(&1, keep_v))
      end)

    Map.put(weight, keep_v, Map.take(row, [keep]))
  end

  # `prepareVertexForWeightAdjustments`, exactly: unmatch, dissolve every
  # enclosing blossom, reset the dual to the initial maximum. Idempotent,
  # so touching both endpoints of several edges in a row costs nothing
  # extra for a vertex already prepared.
  defp prepare_vertex(state, v) do
    state = dissolve_to_vertex(state, v)

    # `v` is now its own top-level blossom. Unmatch it, both directions.
    state =
      case Map.get(state.blossom_match, v) do
        nil ->
          state

        partner ->
          partner_blossom = Map.fetch!(state.in_blossom, partner)

          %{
            state
            | blossom_match: state.blossom_match |> Map.delete(v) |> Map.delete(partner_blossom)
          }
      end

    %{state | dual: Map.put(state.dual, v, state.max_w)}
  end

  # Dissolve the top-level blossom containing `v`, and keep dissolving
  # until `v` IS the top-level blossom. Each dissolution pushes the parent
  # blossom's dual (halved) down into its vertices -- `freeAncestorOfBase`'s
  # `dualVariableAdjustment` -- so the sum of duals over any edge is
  # unchanged and dual feasibility survives.
  defp dissolve_to_vertex(state, v) do
    case Map.fetch!(state.in_blossom, v) do
      ^v -> state
      b -> state |> dissolve_one(b, v) |> dissolve_to_vertex(v)
    end
  end

  # One level: `b` becomes its children, paired off around its base along
  # the odd cycle exactly as `pair_children/4` pairs them for the final
  # answer -- but at the BLOSSOM level (`blossom_match`), and permanently.
  # No labels are involved: this runs between stages, when there is no
  # tree.
  # `v` is the vertex being prepared, and the blossom is REBASED at it
  # before it is taken apart. This is `prepareVertexForWeightAdjustments`'
  # `baseVertex = &vertex` and it is not optional.
  #
  # In this port a blossom's dual is a separate quantity from its vertices'
  # duals: it records how far the vertex duals have been driven BELOW what
  # the blossom's INTERNAL edges need, so those read as `-z_B` slack while
  # every edge CROSSING the boundary is exactly tight on vertex duals
  # alone. Dissolving adds `z_B / 2` to every vertex, which makes the
  # internal edges tight and pushes every crossing edge OUT of tightness
  # by that same amount. That is fine for the crossing edges that are
  # unmatched -- slack is allowed -- and fatal for the ONE crossing edge
  # that is matched: the base's external match, which the algorithm treats
  # as tight and never revisits.
  #
  # Rebasing at `v` moves that external match onto `v`'s own child --
  # which `prepare_vertex/2` is about to unmatch anyway -- so no matched
  # crossing edge survives the dissolution. Every sibling pair that comes
  # out matched sits on an INTERNAL edge, which the adjustment has just
  # made tight. Complementary slackness holds on every matched edge, and
  # `even_up_exposed_duals/1` then handles the parity of whatever was left
  # exposed.
  #
  # Rebasing is a one-field write here, exactly as in `augment_to_source/3`:
  # the internal alternating structure is resolved lazily from the base by
  # `resolve_all_matching/1`, never stored.
  #
  # Found by checking the invariants directly rather than by reading the
  # reference: with the OLD base kept, two matched crossing edges came out
  # with dual sums 85 against a weight of 82 and 51 against 32, and the
  # search stalled with ten exposed vertices left.
  defp dissolve_one(state, b, v) do
    state = %{state | base: Map.put(state.base, b, v)}
    children = Map.fetch!(state.children, b)
    base_v = v
    partner = Map.get(state.blossom_match, b)
    half_dual = div(Map.fetch!(state.dual, b), 2)

    base_child = Enum.find(children, &(base_v in blossom_vertices(state, &1)))
    base_idx = Enum.find_index(children, &(&1 == base_child))
    rotated = Enum.drop(children, base_idx) ++ Enum.take(children, base_idx)

    # Every vertex of `b` absorbs the blossom's dual. `blossom_vertices/2`
    # is read BEFORE the structure changes.
    all_vertices = blossom_vertices(state, b)
    # Positional reads of the cycle by index: a tuple, where `Enum.at/2` on
    # the list was a walk per read (quadratic in the cycle's length).
    rotated_t = List.to_tuple(rotated)

    dual =
      Enum.reduce(all_vertices, state.dual, fn x, d -> Map.update!(d, x, &(&1 + half_dual)) end)
      |> Map.delete(b)

    # Each child becomes top-level: `in_blossom` for its vertices points at
    # it, and it gets its own base and match. The base child inherits `b`'s
    # external match; the others pair up (1,2), (3,4), ... via connectors.
    state =
      rotated
      |> Enum.with_index()
      |> Enum.reduce(%{state | dual: dual}, fn {child, i}, state ->
        in_blossom =
          Enum.reduce(blossom_vertices(state, child), state.in_blossom, &Map.put(&2, &1, child))

        {child_base, child_match} =
          cond do
            i == 0 ->
              {base_v, partner}

            rem(i, 2) == 1 ->
              {out_a, in_b} = connector(state, child, elem(rotated_t, i + 1))
              {out_a, in_b}

            true ->
              {out_a, in_b} = connector(state, elem(rotated_t, i - 1), child)
              {in_b, out_a}
          end

        %{
          state
          | in_blossom: in_blossom,
            base: Map.put(state.base, child, child_base),
            blossom_match: put_or_delete(state.blossom_match, child, child_match),
            parent_of: Map.delete(state.parent_of, child),
            label: Map.put(state.label, child, :free)
        }
      end)

    # The partner's own match pointed at `b`'s base vertex already (matches
    # are recorded as VERTICES); the base child now owns that vertex, so
    # nothing to redirect. `b` itself is gone.
    %{
      state
      | children: Map.delete(state.children, b),
        base: Map.delete(state.base, b),
        vertices_of: Map.delete(state.vertices_of, b),
        blossom_match: Map.delete(state.blossom_match, b),
        label: Map.delete(state.label, b),
        label_edge: Map.delete(state.label_edge, b)
    }
  end

  defp put_weight(state, u, v, 0) do
    weight =
      state.weight
      |> Map.update(u, %{}, &Map.delete(&1, v))
      |> Map.update(v, %{}, &Map.delete(&1, u))

    %{state | weight: weight}
  end

  defp put_weight(state, u, v, w2) do
    weight =
      state.weight
      |> Map.update(u, %{v => w2}, &Map.put(&1, v, w2))
      |> Map.update(v, %{u => w2}, &Map.put(&1, u, w2))

    %{state | weight: weight}
  end

  defp gcd_of(edges) do
    edges
    |> Enum.reduce(0, fn {_i, _j, w}, acc -> if w > 0, do: Integer.gcd(acc, w), else: acc end)
    |> max(1)
  end

  # Divide every weight by the greatest common divisor of all of them
  # (`gcd_of/1`, or the one the caller supplied and `check_divides!/2`
  # confirmed).
  #
  # This is worth far more than it looks. `Ainalrami.Pairing` packs
  # C1-C21 into a single integer by giving each criterion its own band, and
  # on a 209-player field that produces edge weights of about a HUNDRED AND
  # THREE DIGITS - every `dual + dual - weight` inside the matcher is then
  # arbitrary-precision arithmetic, on the innermost operation of the whole
  # algorithm. In one real solve the 21,221 edges carried five distinct
  # weights sharing a ninety-digit common factor; dividing it out left
  # values that fit in 64 bits.
  #
  # Exact, not an approximation. Every matching's total scales by exactly
  # 1/g, so the argmax is unchanged, and `solve/2` returns the pairs rather
  # than any weight, so no caller can observe the scale at all. Doubling
  # happens afterwards in `adjacency_of/1`, so the invariant that keeps dual
  # variables integral through the algorithm's halvings still holds.
  #
  # Costs one pass of Euclid over the edge list, against millions of
  # bignum operations saved.
  defp divide_weights(edges, gcd) do
    Enum.map(edges, fn
      {i, j, w} when w > 0 -> {i, j, div(w, gcd)}
      edge -> edge
    end)
  end

  defp check_divides!(edges, g) do
    Enum.each(edges, fn {i, j, w} ->
      if w > 0 and rem(w, g) != 0 do
        raise ArgumentError,
              "new/3: gcd: #{g} does not divide the weight #{w} of edge {#{i}, #{j}}"
      end
    end)
  end

  defp build_state(n, edges, ceiling, duals, adjacency, symmetric?) do
    # Adjacency, not a flat `{u, v} => w` map. A resistance (`dual[u] +
    # dual[v] - w`) is the innermost operation in the whole algorithm --
    # every row walk computes one per neighbour -- and a tuple key means
    # allocating and hashing a two-tuple on each of those. Nesting lets a
    # walk fetch one vertex's row once and then do plain single-key lookups
    # against it.
    #
    # A caller that hands the finished structure over as `:adjacency` skips
    # this fold; see `new/3` for who does and why.
    weights = adjacency || adjacency_of(edges)

    # `:adjacency` without `:max_weight` still has to get the ceiling from
    # somewhere, and the only place left is the map itself -- a full O(E)
    # walk, which is exactly what such a caller is trying to avoid, so it
    # should pass the ceiling. Kept as a fallback rather than a raise
    # because the value is derivable and a wrong one is not caught until
    # `greedy_resume/1` misreads a dual.
    max_w =
      ceiling ||
        if adjacency do
          Enum.reduce(adjacency, 0, fn {_u, row}, acc ->
            Enum.reduce(row, acc, fn {_v, w2}, best -> max(best, w2) end)
          end)
        else
          Enum.reduce(edges, 0, fn {_i, _j, w}, acc ->
            if w > 0, do: max(acc, 2 * w), else: acc
          end)
        end

    {dual, blossom_match} = greedy_start(n, weights, duals, adjacency == nil or symmetric?)

    state = %{
      n: n,
      max_w: max_w,
      weight: weights,
      # Dual variable per VERTEX only - bbpPairings separately tracks a
      # dual variable per BLOSSOM (`ParentBlossom.dualVariable`); this
      # merges that into the same map keyed by blossom id (>= n for
      # non-trivial blossoms), since nothing about the algorithm needs
      # them kept apart.
      dual: dual,
      mate: %{},
      # `in_blossom[v]` is always the TOP-LEVEL blossom currently
      # containing vertex v - the direct analogue of bbpPairings'
      # `Vertex.rootBlossom`.
      #
      # The explicit `//1` is what keeps an EMPTY vertex set empty. Elixir's
      # two-argument `0..-1` is a descending range, so it enumerates `[0,
      # -1]` and seeds both this map and `base` below with a `-1 => -1`
      # entry for a vertex that does not exist. Nothing reads it - an empty
      # graph has no edges to walk - so the matching came out right either
      # way, and the only visible symptom was the deprecation warning.
      # Every other range in this module already carries the step; these two
      # were missed.
      in_blossom: Map.new(0..(n - 1)//1, &{&1, &1}),
      # Nested structure, needed only for expansion: children in cyclic
      # order starting from the child containing the base, and each
      # child's parent. Trivial (single-vertex) blossoms have no entry.
      children: %{},
      vertices_of: %{},
      parent_of: %{},
      base: Map.new(0..(n - 1)//1, &{&1, &1}),
      # Per TOP-LEVEL blossom, ASYMMETRIC: the external vertex this
      # blossom's base is matched to, or nil. This is the direct
      # analogue of bbpPairings' `RootBlossom.baseVertexMatch` - a
      # per-blossom field, deliberately NOT required to agree with the
      # other side's own field at every instant.
      #
      # Kept separate from `mate` (below) after tracing exactly why that
      # separation matters: augmenting a tight edge between two DIFFERENT
      # trees calls `augment_to_source` from BOTH endpoints in turn. If
      # "was this blossom already matched" were read from the same
      # SYMMETRIC map the first call just wrote into, the second call
      # would see its own sibling's brand-new write and misread it as a
      # stale match needing further walking - an infinite loop on
      # anything past the trivial one-edge case.
      blossom_match: blossom_match,
      # Connector vertex pair for every cyclically-adjacent pair of
      # children ever formed - see `form_blossom/5`'s doc.
      connectors: %{},
      # Per TOP-LEVEL blossom only.
      label: %{},
      # The top-level blossoms labelled `:outer` or `:inner`, with that
      # label: the part of `label` a dual step moves (`apply_delta/2`).
      forest: %{},
      # {labeling_vertex, labeled_vertex}: the edge that connected this
      # INNER blossom to its OUTER parent when the tree grew into it.
      label_edge: %{},
      # The delta-scan caches - see the "delta-scan caches" section below.
      best_outer: %{},
      cross: cross_empty(),
      shift_outer: 0,
      shift_cross: 0,
      min_outer: nil,
      # The root-edge table - see its own section.
      roots: %{},
      root_min: %{},
      next_blossom_id: n
    }

    state
  end

  # `%{u => %{v => 2w}}` from `[{u, v, w}]`, both directions of every edge
  # with a positive weight; a later occurrence of the same edge overwrites
  # an earlier one, and a non-positive one is skipped without removing
  # anything.
  #
  # Built a row at a time: every endpoint's `{neighbour, 2w}` entries are
  # gathered as a list first, and each row becomes a map in one
  # `Map.new/1`, which keeps the LAST value for a repeated key - the same
  # overwrite the edge-by-edge fold made. The fold this replaces did two
  # nested map updates per edge, each rebuilding a path through an inner
  # row and the outer map: 80,000 of them for the 40,000 edges of a
  # 300-player round's field graph. The result is the same map, and a map's
  # iteration order depends on its keys alone, so every later walk of a row
  # visits it in the order it always did.
  defp adjacency_of(edges) do
    edges
    |> Enum.reduce(%{}, fn
      {i, j, w}, acc when w > 0 ->
        w2 = 2 * w

        acc
        |> Map.update(i, [{j, w2}], &[{j, w2} | &1])
        |> Map.update(j, [{i, w2}], &[{i, w2} | &1])

      _edge, acc ->
        acc
    end)
    |> Map.new(fn {v, entries} -> {v, Map.new(Enum.reverse(entries))} end)
  end

  # The starting point of a fresh solve: duals and a greedy matching, both
  # on the tight edges, instead of every dual at the ceiling and no
  # matching at all.
  #
  # bbpPairings starts cold -- every dual `aboveMaxEdgeWeight`, nothing
  # matched -- and so did this, and a cold solve on a 209-player field ran
  # 106 stages: the first delta lowers every dual to the top weight, the
  # heaviest edge goes tight and is matched, and from there it is one
  # augmentation per stage, each stage paying O(V^2) in cache rebuilds and
  # tree growth while the outer set is still most of the graph. Two of
  # those per round (the bye bootstrap and the round matcher's first
  # solve) were 43% of a 209-player round and would be 45% of a
  # 400-player one.
  #
  # Any state that satisfies the invariants is a legal starting point, and
  # the resumed solves after `set_weight/4` already rely on that. So:
  #
  #   * `dual[v]` = the weight of v's heaviest edge (half of it on the
  #     doubled scale). Feasible, since `dual[u] + dual[v]` is then at
  #     least `w(u, v)` from each side; at most `max_w`; and an isolated
  #     vertex sits at zero, which is where the search would put it.
  #   * match each exposed vertex, in index order, to its lowest-indexed
  #     exposed neighbour with which its heaviest edge is TIGHT -- the
  #     two are each other's heaviest, counting ties. Those are exactly
  #     the edges the first stages would have matched; the greedy pass
  #     does it in one walk of the adjacency.
  #
  # No blossoms, so `even_up_exposed_duals/1`'s parity step (which is
  # the one place the doubled scale cares) applies unchanged. On the
  # 209-player round's first graph 5 distinct weights cover 21,221 edges
  # and the greedy pass matches 202 of 209 vertices; the remaining stages
  # are the real work, and the outer set at their start is seven vertices
  # rather than two hundred and nine. When the optimum is not unique the
  # matching returned may differ from the cold search's -- which was
  # itself decided by map internals, not by anything canonical -- and the
  # corpus is the arbiter of whether that matters.
  #
  # `symmetric?` says the weights came from `adjacency_of/1`, where every
  # edge sits in both its endpoints' rows at one weight. With the default
  # duals that makes tightness a pair of comparisons: `y_v` is half of v's
  # heaviest edge and `y_u` half of u's, each at least half of any `w(u,
  # v)`, so `y_v + y_u == w(u, v)` exactly when `w(u, v)` is the heaviest
  # edge of both, i.e. `w(u, v) == 2 y_v` and `y_u == y_v` - no bignum sum
  # per edge. Given duals, or a caller's adjacency, take the sum.
  defp greedy_start(n, weights, given, symmetric?) do
    dual =
      case given do
        nil ->
          # Half the heaviest edge: `div(max(w2), 2)` is `max(div(w2, 2))`,
          # `div/2` being monotone, and an empty or non-positive row gives 0
          # as the fold from 0 did.
          Map.new(0..(n - 1)//1, fn v ->
            case weights do
              %{^v => row} when map_size(row) > 0 ->
                {v, max(0, div(:lists.max(:maps.values(row)), 2))}

              _ ->
                {v, 0}
            end
          end)

        given ->
          Map.new(0..(n - 1)//1, fn v -> {v, Map.get(given, v, 0)} end)
      end

    # `dual` is final from here, and keyed by exactly `0..n-1`, so the two
    # O(E) scans below read it out of a flat tuple instead of hashing the
    # map on every edge endpoint. On `Ainalrami.Pairing`'s odd-field bye
    # bootstrap those two scans are two million lookups between them, and
    # `elem/2` is a pointer offset where `Map.fetch!/2` is a hash and a
    # probe.
    dual_t = 0..(n - 1)//1 |> Enum.map(&Map.fetch!(dual, &1)) |> List.to_tuple()

    if given != nil, do: check_duals!(weights, dual_t)

    fast? = symmetric? and given == nil

    blossom_match =
      Enum.reduce(0..(n - 1)//1, %{}, fn v, bm ->
        yv = elem(dual_t, v)

        partner =
          case {bm, weights} do
            {%{^v => _}, _} ->
              nil

            {_, %{^v => row}} when fast? ->
              tight_partner_fast(:maps.to_list(row), 2 * yv, yv, dual_t, bm, nil)

            {_, %{^v => row}} ->
              tight_partner(:maps.to_list(row), yv, dual_t, bm, nil)

            _ ->
              nil
          end

        case partner do
          nil -> bm
          u -> bm |> Map.put(v, u) |> Map.put(u, v)
        end
      end)

    {dual, blossom_match}
  end

  # The lowest-indexed exposed neighbour on a tight edge (the least of a
  # set: the row's order does not matter).
  defp tight_partner([], _yv, _dual_t, _bm, best), do: best

  defp tight_partner([{u, w2} | rest], yv, dual_t, bm, best) do
    if (best == nil or u < best) and not is_map_key(bm, u) and yv + elem(dual_t, u) == w2,
      do: tight_partner(rest, yv, dual_t, bm, u),
      else: tight_partner(rest, yv, dual_t, bm, best)
  end

  defp tight_partner_fast([], _top, _yv, _dual_t, _bm, best), do: best

  defp tight_partner_fast([{u, w2} | rest], top, yv, dual_t, bm, best) do
    if w2 == top and (best == nil or u < best) and not is_map_key(bm, u) and
         elem(dual_t, u) == yv,
       do: tight_partner_fast(rest, top, yv, dual_t, bm, u),
       else: tight_partner_fast(rest, top, yv, dual_t, bm, best)
  end

  # `duals[u] + duals[v] >= 2 * w(u, v)` on every edge -- the precondition
  # `new/3` documents, checked rather than trusted because a caller that
  # gets it wrong gets a silently suboptimal matching, not a crash.
  #
  # Written as a `for` comprehension, which built and then discarded a list
  # one element per EDGE: 500,500 of them on the bye bootstrap, allocated
  # for nothing. `Enum.each` keeps every assertion, in the same order, and
  # allocates none of it.
  defp check_duals!(weights, dual_t) do
    Enum.each(weights, fn {u, row} ->
      yu = elem(dual_t, u)

      Enum.each(row, fn {v, w2} ->
        if u < v and yu + elem(dual_t, v) < w2 do
          raise ArgumentError,
                "new/3: the given duals are infeasible on edge {#{u}, #{v}}: " <>
                  "#{yu} + #{elem(dual_t, v)} < #{w2}"
        end
      end)
    end)
  end

  # A stage bound of `2n` is generous - the reference algorithm needs at
  # most n stages total (one per matching-size increase) - so hitting
  # this is a bug, not a slow instance, and failing loudly beats hanging.
  defp augment_until_done(state), do: augment_until_done(state, 2 * state.n + 5)

  defp augment_until_done(_state, 0), do: raise("WeightedMatching: exceeded stage budget")

  defp augment_until_done(state, budget) do
    result = augment_once(state)
    Process.put(:wm_stages, Process.get(:wm_stages, 0) + 1)
    Process.put(:wm_grow_total, Process.get(:wm_grow_total, 0) + Process.get(:wm_grow_steps, 0))

    case result do
      {:ok, state} -> augment_until_done(state, budget - 1)
      {:done, state} -> state
    end
  end

  defp to_matching(state) do
    # `state.mate` is already `%{vertex => partner}`; this used to rebuild it
    # key by key, which is an identity copy with extra steps.
    state.mate
  end

  # ---------------------------------------------------------- one stage

  # Grows one alternating forest from every exposed vertex until either
  # the matching grows by one (returns `{:ok, state}`) or no exposed
  # OUTER vertex remains, meaning the current matching is already maximum
  # (Berge's theorem: no augmenting path exists) - `:done`.
  defp augment_once(state) do
    state = init_labels(state)
    Process.put(:wm_grow_steps, 0)

    # The labelled state is returned on BOTH paths. Returning a bare `:done`
    # here discarded `init_labels/1`'s work, which was harmless while the
    # label map always held the previous stage's labels and became a real
    # bug the moment `solve/1` started clearing it: `resolve_all_matching/1`
    # reads `top_blossoms/1`, which reads the label keys, and found none.
    case min_outer_dual(state) do
      nil -> {:done, state}
      _ -> grow(state)
    end
  end

  defp init_labels(state) do
    # The set of top-level blossoms is exactly the previous stage's label
    # KEYS: `form_blossom/5` and `expand_blossom/2` keep that key set
    # current, so it survives the boundary even though the label VALUES do
    # not. Re-deriving it from `in_blossom` -- as this used to, with a
    # `Map.values |> Enum.uniq` over every vertex -- was a full O(V) walk
    # per stage for information already in hand. The very first stage has
    # no labels yet and falls back to `in_blossom`.
    #
    # A blossom labelled `:free` at the end of a stage is matched - every
    # writer of the label gives `:free` only to a matched blossom
    # (`init_labels/1` itself, the other arc of `expand_blossom/2`) - and
    # stays matched, since an augmentation only walks the forest and a
    # zero blossom; so its label at the next stage is `:free` again, and
    # only the rest (the forest, the zero blossoms) are re-derived. Same
    # labels, from one pass that reads three maps only for those.
    bm = state.blossom_match
    base = state.base
    dual = state.dual

    relabel = fn b ->
      cond do
        is_map_key(bm, b) -> :free
        :erlang.map_get(:erlang.map_get(b, base), dual) > 0 -> :outer
        true -> :zero
      end
    end

    label =
      if map_size(state.label) == 0 do
        top = :lists.usort(Map.values(state.in_blossom))
        :maps.from_list(for b <- top, do: {b, relabel.(b)})
      else
        :maps.map(fn b, l -> if l == :free, do: :free, else: relabel.(b) end, state.label)
      end

    # A new stage relabels everything at once, which is the one moment the
    # outer set can SHRINK. The delta-scan caches are rebuilt from scratch at
    # a solve's first stage and filtered down to the new outer set at every
    # later one (`carry_caches/2`), never repaired across a shrink - that is
    # the whole reason maintaining them incrementally within a stage is
    # sound; see the "delta-scan caches" section.
    carry_caches(
      %{
        state
        | label: label,
          forest: :maps.filter(fn _b, l -> l == :outer end, label),
          label_edge: %{}
      },
      state.label
    )
  end

  # Every currently top-level blossom id - vertices not absorbed into a
  # larger blossom, plus every non-trivial blossom with no parent.
  #
  # SORTED, and that is not cosmetic. The set comes from `state.label`'s
  # keys, and Erlang's map order changes shape at the 32-key
  # flatmap-to-hashmap transition, so an unsorted result would hand each
  # consumer an order that is a property of the runtime rather than of the
  # graph.
  #
  # Its consumers do not care: `even_up_exposed_duals/1` and
  # `resolve_all_matching/1` are order-independent folds - each visits
  # every blossom and the edits commute. (`min_inner_blossom_dual/1`, which
  # once took the FIRST least dual over this list, now takes the least
  # `{dual, id}`, the same tie-break without the list; `apply_delta/2`
  # walks the label map directly.)
  #
  # The caches are no longer in that group. `best_outer` and the cross
  # table are keyed by vertex and blossom pair and do their own canonical
  # tie-break on `{r, v}` / `{r, partner}` / `{r, a, b}` (`scan_row/5`,
  # `offer/4`, `min_free_or_zero_to_outer/1`, `lower_min/2`), so they no
  # longer inherit any order from here - except the vertex pair a cross
  # entry names, where the first offered of equal resistances wins
  # (`cross_gather/6`), in the order rows are walked.
  #
  # Blossom ids are integers (vertices are `0..n-1`, blossoms are allocated
  # above that), so sorting gives a total order that is stable, cheap, and
  # tied to the problem rather than to the runtime. docs/engineering-log.md's argument that
  # the refinement stages leave no ties to break is an empirical observation
  # over one corpus, not an invariant - and an invariant is what a pairing
  # engine's determinism should rest on.
  defp top_blossoms(state) do
    # The label map's keys ARE the top-level blossoms: `init_labels/1`
    # populates it for every one at a stage boundary, `form_blossom/5` adds
    # the new blossom and removes its children, `expand_blossom/2` and
    # `dissolve_one/3` do the reverse. Deriving the same set from
    # `in_blossom` -- as this once did -- was O(V) per call.
    #
    # This was once called on every delta step, and so kept as a sorted
    # list patched at every structural event (`state.tops`). Nothing on a
    # delta step reads it any more - `apply_delta/2` walks the label map,
    # `min_inner_blossom_dual/1` the blossoms, each with its own
    # order-independent rule - and its readers left, `resolve_all_matching/1`
    # (once a solve) and `even_up_exposed_duals/1` (only with labels, which
    # it never has), are order-independent folds, so the list is sorted
    # here, once per call, rather than kept.
    state.label |> Map.keys() |> Enum.sort()
  end

  defp matched?(state, b), do: Map.has_key?(state.blossom_match, b)
  defp base_vertex(state, b), do: Map.fetch!(state.base, b)
  defp dual_of(state, v), do: Map.fetch!(state.dual, v)

  # The minimum dual over every OUTER VERTEX -- not over each outer
  # blossom's base. bbpPairings' `updateMinOuterDualVariable` is called for
  # every vertex whose root blossom is outer (graph.cpp:401-412), and the
  # vertex that reaches zero is passed to `augmentToSource`, which rebases
  # the blossom at it.
  #
  # In a fresh solve the two are the same number: every vertex of an outer
  # blossom entered together and has moved together, so they share a dual.
  # After `prepare_vertex/2` they need not: a vertex reset to the maximum
  # can share a blossom with one inherited at 7, and guarding the base
  # alone let the low one be driven to -10. Measured, seed 168 of
  # `tools/matching_incremental.exs`.
  # Tracked, not scanned: `state.min_outer` is `{biased_dual, vertex}` over
  # every outer vertex, where the biased dual is the dual plus `shift_outer`
  # -- invariant under `apply_delta/2`, since every outer dual falls by
  # exactly what the shift rises by. Within a stage the outer set only
  # grows, so the minimum only ever has to take new vertices into account,
  # and every vertex that becomes outer passes through `settle_outer_vertex/2`,
  # which offers it. A stage start recomputes it from the outer set once
  # (`carry_caches/2`, `rebuild_caches/1`). This was a scan of every outer
  # vertex on every delta step -- bbpPairings tracks `minOuterDualVariable`
  # the same way (graph.cpp:401-412, updated on growth). Ties go to the
  # lower vertex id, a canonical order.
  defp min_outer_dual(state) do
    case state.min_outer do
      nil -> nil
      {biased, _v} -> biased - state.shift_outer
    end
  end

  defp min_outer_dual_vertex(state) do
    case state.min_outer do
      nil -> nil
      {biased, v} -> {biased - state.shift_outer, v}
    end
  end

  defp offer_min_outer(state, v) do
    biased = Map.fetch!(state.dual, v) + state.shift_outer

    case state.min_outer do
      {b0, v0} when b0 < biased or (b0 == biased and v0 < v) -> state
      _ -> %{state | min_outer: {biased, v}}
    end
  end

  # The least `{biased dual, vertex}` over the outer blossoms' vertices -
  # what offering each in turn to an empty minimum reaches - written into
  # the state once.
  defp recompute_min_outer(state, outer_blossoms) do
    duals = state.dual
    shift = state.shift_outer

    least =
      Enum.reduce(outer_blossoms, nil, fn b, acc ->
        least_outer_dual(blossom_vertices(state, b), duals, shift, acc)
      end)

    %{state | min_outer: least}
  end

  defp least_outer_dual([], _duals, _shift, acc), do: acc

  defp least_outer_dual([v | rest], duals, shift, acc) do
    biased = :erlang.map_get(v, duals) + shift

    acc =
      case acc do
        {b0, v0} when b0 < biased or (b0 == biased and v0 < v) -> acc
        _ -> {biased, v}
      end

    least_outer_dual(rest, duals, shift, acc)
  end

  # ------------------------------------------------------- the main loop

  defp grow(state) do
    # A cheap safety net, not a normal path: this many iterations within
    # ONE stage would mean the search is stuck, not merely slow, since
    # each iteration makes the search strictly more constrained. Left in
    # after using it (with tracing, since removed) to localise the
    # infinite-recursion bug in an earlier version's blossom resolution -
    # failing loudly beats hanging silently if a future change
    # reintroduces something similar.
    steps = Process.get(:wm_grow_steps, 0)

    if steps > 4 * state.n + 20 do
      raise "WeightedMatching: exceeded grow-step budget (#{steps} steps, n=#{state.n})"
    end

    Process.put(:wm_grow_steps, steps + 1)

    min_outer = min_outer_dual(state)

    # The smallest resistance from ANY free-or-zero vertex to an OUTER
    # one, tracked alongside which vertex achieves it - bbpPairings'
    # `minInnerOuterEdgeResistance`. Read off the `best_outer` cache (see
    # the "delta-scan caches" section) rather than by a scan of vertex
    # pairs; the outer-outer minimum is the cross table's running best.
    {min_free_outer, free_outer_vertex} = min_free_or_zero_to_outer(state)
    {min_outer_outer, outer_pair} = min_outer_outer(state)
    {min_inner_blossom, inner_blossom_id} = min_inner_blossom_dual(state)

    candidates =
      [
        min_outer,
        min_free_outer,
        (min_outer_outer && div(min_outer_outer, 2)) || nil,
        (min_inner_blossom && div(min_inner_blossom, 2)) || nil
      ]
      |> Enum.reject(&is_nil/1)

    # `augment_once/1` checks `min_outer_dual/1` before the FIRST call, but
    # `grow/1` re-enters itself (`{:grow, state} -> grow(state)` below) and
    # nothing rechecks it there. With no outer vertex left, `min_outer` is nil
    # and every other candidate can be nil too: `Enum.min([])` raised
    # `Enum.EmptyError`, and `min_outer - delta` below raised `ArithmeticError`
    # on nil. The step and stage budgets catch loops, not this.
    #
    # No matching this engine produces is known to reach it - it is guarded
    # rather than reproduced. An exhausted search is the same answer
    # `augment_once/1`'s own precheck gives: stop, and let the caller see the
    # matching as it stands.
    if candidates == [] or is_nil(min_outer) do
      {:done, state}
    else
      # The rest of the step as one tuple: a keyword list here was four
      # `Access` lookups on every delta step.
      grow_with_delta(
        state,
        min_outer,
        min_free_outer,
        free_outer_vertex,
        min_outer_outer,
        {outer_pair, min_inner_blossom, inner_blossom_id, Enum.min(candidates)}
      )
    end
  end

  defp grow_with_delta(state, min_outer, min_free_outer, free_outer_vertex, min_outer_outer, step) do
    {outer_pair, min_inner_blossom, inner_blossom_id, delta} = step

    state = apply_delta(state, delta)

    cond do
      min_outer - delta == 0 ->
        # An exposed OUTER vertex's dual variable is now zero: it is its
        # own trivial augmenting path.
        # The VERTEX whose dual reached zero, which `augment_to_source/3`
        # rebases its blossom at. Not the blossom's current base: after
        # `prepare_vertex/2` a blossom's vertices can hold different duals,
        # and the one at zero need not be the base.
        {0, v} = min_outer_dual_vertex(state)

        {:ok, augment_to_source(state, v, nil)}

      min_free_outer && min_free_outer - delta == 0 ->
        handle_free_outer_tight(state, free_outer_vertex)

      min_outer_outer && min_outer_outer - 2 * delta == 0 ->
        handle_outer_outer_tight(state, outer_pair)

      min_inner_blossom && min_inner_blossom - 2 * delta == 0 ->
        # Captured BEFORE the expansion, because the blossom id stops
        # existing. Its vertices were inner and so held no cache entries;
        # the children that come out `:free` need them computed now.
        expanded = blossom_vertices(state, inner_blossom_id)
        Process.put(:wm_expanded, Process.get(:wm_expanded, 0) + 1)

        {:cont, refresh_caches(expand_blossom(state, inner_blossom_id), expanded)}
        |> continue_growing()

      true ->
        # One of the four must hit zero: `delta` IS the least of them. None
        # does only when a halved candidate was odd before halving - an
        # outer-outer resistance or an inner blossom dual that the doubled
        # scale should have kept even - and that is a broken invariant, not
        # a slow instance. This used to return `{:done, state}`, which ended
        # the solve with the matching as it stood: `even_up_exposed_duals/1`'s
        # comment records the one time it was reached, a twelve-vertex solve
        # that "succeeded" with ten vertices exposed. Raised, like the stage
        # and step budgets and `take_two/2`, so it cannot pass for an answer.
        no_event!(state, delta, min_outer, min_free_outer, min_outer_outer, min_inner_blossom)
    end
    |> case do
      {:ok, _state} = result -> result
      {:grow, state} -> grow(state)
    end
  end

  defp continue_growing({:cont, state}), do: {:grow, state}

  # The four minima as `grow/1` read them (before the dual update), the
  # step taken, and enough of the state to place the failure.
  defp no_event!(state, delta, min_outer, min_free_outer, min_outer_outer, min_inner_blossom) do
    labels = state.label |> Map.values() |> Enum.frequencies()
    exposed = Enum.count(state.label, fn {b, _} -> not matched?(state, b) end)

    raise "WeightedMatching: a dual step of #{delta} made nothing tight " <>
            "(min outer dual #{inspect(min_outer)}, min free/zero-outer resistance " <>
            "#{inspect(min_free_outer)}, min outer-outer resistance #{inspect(min_outer_outer)}, " <>
            "min inner blossom dual #{inspect(min_inner_blossom)}); n=#{state.n}, " <>
            "top-level blossoms by label #{inspect(labels)}, #{exposed} exposed, " <>
            "#{map_size(state.children)} non-trivial blossoms"
  end

  defp handle_free_outer_tight(state, v) do
    outer_partner = min_outer_edge(state, v)

    if Map.get(state.label, Map.fetch!(state.in_blossom, v)) == :zero do
      # ZERO vertex tight against OUTER: augment directly.
      state = augment_to_source(state, outer_partner, v)
      state = augment_to_source(state, v, outer_partner)
      {:ok, state}
    else
      # FREE vertex tight against OUTER: grow the tree through it. Reads
      # v's BLOSSOM's own match field (asymmetric, per-blossom - see
      # `state.blossom_match`'s doc), not a vertex-level lookup on `v`
      # itself: v may not be its blossom's current base if that blossom
      # persisted, still non-trivial, from an earlier stage.
      v_blossom = Map.fetch!(state.in_blossom, v)
      matched_blossom = Map.fetch!(state.in_blossom, Map.fetch!(state.blossom_match, v_blossom))

      state = %{
        state
        | label: state.label |> Map.put(v_blossom, :inner) |> Map.put(matched_blossom, :outer),
          forest: state.forest |> Map.put(v_blossom, :inner) |> Map.put(matched_blossom, :outer),
          label_edge: Map.put(state.label_edge, v_blossom, {outer_partner, v})
      }

      # One blossom left the non-outer set and one joined the outer set, so
      # both need their own cache entries rebuilt and the newly-outer one
      # needs offering to everything it neighbours.
      changed =
        blossom_vertices(state, v_blossom) ++ blossom_vertices(state, matched_blossom)

      {:grow, refresh_caches(state, changed)}
    end
  end

  defp handle_outer_outer_tight(state, {v0, v1}) do
    b0 = Map.fetch!(state.in_blossom, v0)
    b1 = Map.fetch!(state.in_blossom, v1)
    # Both ends are outer, so each one's walk to its root is
    # `blossom_ids_to_root/2` (its tree root is the last id) - walked once
    # here and handed to `form_blossom/5`, which needs the same two paths.
    ids0 = blossom_ids_to_root(state, b0)
    ids1 = blossom_ids_to_root(state, b1)

    if List.last(ids0) == List.last(ids1) do
      # Formation is the one event that INVALIDATES rather than extends: an
      # edge between two vertices now inside the same blossom has stopped
      # being a cross edge, and any inner child has just become outer. Both
      # are covered by recomputing every vertex of the new blossom.
      # Which children were INNER before formation is knowable only now,
      # before `form_blossom/5` relabels everything: their vertices have no
      # cache entries and made no offers, so they need the full treatment.
      # The OUTER children's vertices already hold valid entries and have
      # already offered themselves; formation can only INVALIDATE one of
      # those -- by putting its partner inside the same new blossom -- so
      # they are filtered, and rescanned only if their entry died.
      #
      # This is bbpPairings' `initializeFromChildren`: `updateOuterOuterEdges`
      # for the LABEL_INNER children, and a min over existing tables for the
      # rest. Re-settling every vertex of every new blossom -- as this did --
      # was 479,000 row walks per 209-player round, 78% of it.
      {state, children, formerly_inner} = form_blossom(state, v0, v1, ids0, ids1)
      new_b = Map.fetch!(state.in_blossom, v0)
      {:grow, refresh_after_formation(state, new_b, children, formerly_inner)}
    else
      state = augment_to_source(state, v0, v1)
      state = augment_to_source(state, v1, v0)
      {:ok, state}
    end
  end

  # (The tree root reachable from an outer blossom is the last id of its
  # `blossom_ids_to_root/2` walk; `handle_outer_outer_tight/2` compares the
  # two ends' roots that way. The walk's shape, in full:)
  #
  # This is the one place the earlier version of this port was
  # structurally wrong, not just off by a constant: an OUTER blossom
  # comes in two kinds. The literal tree root is unmatched (found in
  # `init_labels`). Every OTHER outer blossom got there by being some
  # INNER vertex's match partner - its base vertex's mate sits inside
  # that INNER blossom - and only the INNER SIDE of that connection ever
  # gets a `label_edge` entry (`handle_free_outer_tight` sets it on
  # `v_blossom`, never on `matched_blossom`). Treating a matched OUTER
  # blossom as a dead end, as an earlier version of this function did,
  # made every non-root OUTER blossom in a tree indistinguishable from
  # one in a different tree entirely.
  #
  # Confirmed against `graph.cpp`'s own walk-back loop
  # (`rootblossom->baseVertex` / `baseVertexMatch` / `labeledVertex` /
  # `labelingVertex`, four fields read in that order each step): from a
  # matched OUTER blossom, follow base -> its mate -> the mate's INNER
  # blossom -> that blossom's OWN label edge -> continue from there.

  ## ------------------------------------------------- delta-scan caches
  #
  # `min_free_or_zero_to_outer/1` and `min_outer_outer/1` were 84% of a
  # solve between them, and both rescanned every relevant vertex pair on
  # every delta step: O(V^2) a step, O(V^2) steps, which is the O(V^4) this
  # module was measured at. bbpPairings avoids that with `minOuterEdges`
  # and per-blossom `minOuterEdgeResistance`, and NOTICE records dropping
  # them as a deliberate trade for a smaller translation. These are them,
  # in the form this port can carry.
  #
  # Two caches:
  #
  #   * `best_outer[v]`, for v labelled `:free` or `:zero` - the
  #     least-resistance edge from v to any outer vertex, as
  #     `{resistance, outer_vertex}`.
  #   * the cross table, for every pair of OUTER top-level blossoms - the
  #     least-resistance edge between them (its own section below; it was
  #     once a per-vertex `best_cross[v]`, which blossom formation
  #     invalidated wholesale).
  #
  # Nothing is stored for an `:inner` vertex. It would never be read, and
  # storing it would go stale: `shift_caches/2` moves every entry by the
  # amount an outer-to-non-outer edge moves, and an inner vertex's own dual
  # rises by delta rather than staying put, so the two cancel instead.
  #
  # ## Why maintaining these is sound
  #
  # **Within a stage the outer set only ever grows.** Growing the tree
  # makes a free blossom inner and its mate outer; forming a blossom makes
  # inner children outer; expanding one splits an INNER blossom, whose
  # vertices were never outer. Nothing leaves the outer set until the stage
  # ends and `init_labels/1` starts over.
  #
  # So a cached entry can never go stale by pointing at a vertex that has
  # STOPPED being outer. It can only fall out of date by missing one that
  # has newly joined - which is exactly what `refresh_caches/2` folds in,
  # in one pass over the changed vertices' own adjacency.
  #
  # Blossom formation is the one event that invalidates rather than
  # extends: an edge between two vertices that end up inside the SAME new
  # blossom stops being a cross edge. Both of its endpoints are in that
  # blossom, and every vertex of a new blossom is recomputed from scratch,
  # so the same pass covers it.

  # The caches at a stage boundary, carried forward from the previous stage
  # rather than rebuilt -- WITHIN one solve only.
  #
  # Measured on a cold 209-vertex solve, 105 boundaries: the new stage's
  # outer set was ALWAYS a subset of the previous stage's final outer set --
  # 10,816 of 10,816 kept, 0 newly outer. It has to be: a stage ends by
  # augmenting, which matches exactly two exposed vertices, and then
  # `init_labels/1` makes every matched blossom free; the only blossoms
  # outer at the new start are the still-exposed ones, every one of which
  # was exposed (so outer) a moment ago. And no edge weight changes
  # between two stages of one solve.
  #
  # So the cross table needs FILTERING, not rebuilding: keep an entry when
  # both its blossoms are still outer, drop it otherwise. `best_outer`
  # likewise: an entry whose partner is still outer is still the minimum
  # over a set that only shrank. The only vertices needing a new entry are
  # the ones that left the outer set -- the augmented pair and the tree
  # that hung off them -- and those get one row walk each.
  #
  # Before: every outer vertex re-settled at every stage start,
  # O(|outer| x V) per stage and Theta(V^3) over a cold solve -- 86,000
  # `settle_outer_vertex` calls per 209-player round.
  #
  # ACROSS solves it does not hold and is not attempted. `set_weight/4`
  # changes edge weights, so cached resistances for those edges are stale
  # whatever the labels say, and it exposes vertices that were never outer.
  # `solve/1` clears the caches on entry, so the first stage of every solve
  # rebuilds from nothing -- which is what `prepare_vertex/2` already made
  # cheap, since a resumed solve's outer set is small. A first attempt that
  # carried across solves and patched the newly-outer vertices failed the
  # incremental net on 266 of 300 graphs; the stale resistances were the
  # reason.
  defp carry_caches(state, prev_label) do
    if map_size(prev_label) == 0 do
      rebuild_caches(state)
    else
      # A set as `%{blossom => true}`: membership is a map match.
      outer_list = for {b, :outer} <- state.label, do: b
      outer_blossoms = Map.from_keys(outer_list, true)
      state = recompute_min_outer(state, outer_list)
      cross = cross_retain(state.cross, outer_blossoms)

      in_blossom = state.in_blossom
      labels = state.label

      kept =
        :maps.filter(
          fn v, {_r, partner} ->
            label_of(partner, labels, in_blossom) == :outer and
              label_of(v, labels, in_blossom) != :outer
          end,
          state.best_outer
        )

      outer_vertices = Enum.flat_map(outer_list, &blossom_vertices(state, &1))
      state = %{state | cross: cross, best_outer: kept} |> carry_roots(outer_vertices)

      needing =
        for {b, l} <- state.label,
            l == :free or l == :zero,
            v <- blossom_vertices(state, b),
            not is_map_key(kept, v),
            do: v

      # The needing vertices' entries come straight off `root_min`, which is
      # exactly their least-resistance edge to the outer set - see
      # `carry_roots/2`. They used to be found by walking rows: each needing
      # vertex its own, or every outer vertex its own offering to them,
      # whichever was fewer, which kept a cold solve at O(V^2) a stage and
      # was half of it.
      duals = state.dual

      best_outer =
        Enum.reduce(needing, state.best_outer, fn v, bo ->
          case state.root_min do
            %{^v => {key, x}} -> Map.put(bo, v, {key + :erlang.map_get(v, duals), x})
            _ -> bo
          end
        end)

      %{state | best_outer: best_outer}
    end
  end

  ## ------------------------------------------------ the root-edge table
  #
  # `root_min[u]`, for every vertex u that is NOT a root, is u's least edge
  # to the stage's ROOTS - the vertices outer at the stage's start, i.e.
  # those of the exposed blossoms (`state.roots`) - keyed so that it
  # survives the stage:
  #
  #     key(u, x) = (dual[x] + shift_outer) - w(u, x)       for a root x
  #
  # stored as `{key, x}`, least `{key, x}` wins. `dual[x] + shift_outer` is
  # constant while x stays outer - every `apply_delta/2` takes delta off an
  # outer dual and adds it to `shift_outer` - and a root stays outer until
  # its tree augments. So the key never has to be recomputed while x is a
  # root, whatever happens to u, and it is the same key a scan would compute
  # today. u's resistance to x is `key + dual[u] - shift_outer`: for a
  # fixed u that is the key plus a constant, so the least key is the least
  # resistance, tie for tie, and `best_outer`'s stored (biased) value is
  # `key + dual[u]` exactly.
  #
  # At a stage start the outer set IS the root set, so a vertex that needs a
  # `best_outer` entry there - one that was in last stage's forest, or
  # whose best edge was to a vertex that has since left the outer set - is
  # answered from this table instead of by a walk. Keeping it current costs
  # work only where the root set CHANGES:
  #
  #   * a vertex that has become a root (absorbed into a still-exposed
  #     blossom last stage) drops its own entry and offers itself to its
  #     non-root neighbours;
  #   * a root that has left (its tree augmented) is a non-root now and
  #     gets an entry, and so does every non-root whose least root it was:
  #     each one re-derives its least root by `least_root/4`, over whichever
  #     is shorter, its row or the root set.
  #
  # Early in a cold solve nearly every vertex is a root, so there is almost
  # nobody to keep an entry for; late in one the roots are few, so every
  # re-derivation is short. Either way it is a small fraction of what
  # finding the needing vertices' entries by walking rows cost - that was
  # O(V^2) a stage and half of a cold solve.
  #
  # Rebuilt from nothing by `rebuild_caches/1` at the first stage of every
  # solve, with the other caches: a `set_weight/4` in between has changed
  # weights the keys were computed from.

  # The root table at a later stage start. `roots` is the new root set.
  #
  # The root set is a map from each root to its constant `dual[x] +
  # shift_outer`: membership is a map match where a `MapSet` was a call
  # into `:sets` per test, and the constant comes with it rather than from
  # a dual lookup and an addition per key. Nothing here depends on the
  # order a set or a row is visited in - each re-derivation and each offer
  # keeps the least `{key, x}` - so the walks take whatever order is
  # cheapest.
  defp carry_roots(state, roots) do
    root_set = root_constants(state, roots)
    old = state.roots
    arrived = Enum.reject(roots, &is_map_key(old, &1))
    left = Map.drop(old, roots)
    root_min = Map.drop(state.root_min, arrived)

    # Re-derived: the vertices that are no longer roots, and every non-root
    # whose least root was one of them. A re-derivation sees the whole
    # current root set, arrivals included.
    rescan =
      if map_size(left) == 0 do
        []
      else
        Map.keys(left) ++ for({u, {_key, x}} <- root_min, is_map_key(left, x), do: u)
      end

    roots_list = :maps.to_list(root_set)

    root_min =
      Enum.reduce(rescan, root_min, fn u, rm ->
        case least_root(state, u, root_set, roots_list) do
          nil -> Map.delete(rm, u)
          best -> Map.put(rm, u, best)
        end
      end)

    root_min =
      Enum.reduce(arrived, root_min, fn x, rm ->
        root_offers(state, rm, {x, :erlang.map_get(x, root_set)}, root_set)
      end)

    %{state | root_min: root_min, roots: root_set}
  end

  # The root table from nothing, for a solve's first stage: every outer
  # vertex is a root. Whichever side is cheaper does the walking - the
  # roots offering along their rows, or each non-root deriving its own.
  defp build_roots(state, roots) do
    root_set = root_constants(state, roots)
    roots_list = :maps.to_list(root_set)
    r = length(roots_list)
    non_roots = for v <- 0..(state.n - 1)//1, not is_map_key(root_set, v), do: v

    # The two walks build the same table, so the choice is cost alone:
    # every non-root deriving its own (at most `r` lookups each), or every
    # root offering along its row. This compared `(n - r) * min(r, n)` with
    # `r * n`, which is true for any `r > 0`, so the non-roots always
    # derived - a lookup per root for every vertex of the graph, where the
    # few roots of a resumed solve have far fewer edges between them.
    weight = state.weight

    push =
      Enum.reduce(roots_list, 0, fn {x, _}, acc ->
        case weight do
          %{^x => row} -> acc + map_size(row)
          _ -> acc
        end
      end)

    root_min =
      if length(non_roots) * r < push do
        Enum.reduce(non_roots, %{}, fn u, rm ->
          case least_root(state, u, root_set, roots_list) do
            nil -> rm
            best -> Map.put(rm, u, best)
          end
        end)
      else
        Enum.reduce(roots_list, %{}, &root_offers(state, &2, &1, root_set))
      end

    %{state | root_min: root_min, roots: root_set}
  end

  defp root_constants(state, roots) do
    duals = state.dual
    shift = state.shift_outer
    :maps.from_list(for x <- roots, do: {x, :erlang.map_get(x, duals) + shift})
  end

  # Root `x` offers itself to every non-root neighbour.
  defp root_offers(state, root_min, {x, dx}, roots) do
    case state.weight do
      %{^x => row} ->
        offer_roots(:maps.to_list(row), x, dx, roots, root_min)

      _ ->
        root_min
    end
  end

  defp offer_roots([], _x, _dx, _roots, rm), do: rm

  defp offer_roots([{u, w} | rest], x, dx, roots, rm) do
    case roots do
      %{^u => _} ->
        offer_roots(rest, x, dx, roots, rm)

      _ ->
        key = dx - w

        case rm do
          %{^u => {k0, x0}} when {k0, x0} <= {key, x} -> offer_roots(rest, x, dx, roots, rm)
          _ -> offer_roots(rest, x, dx, roots, Map.put(rm, u, {key, x}))
        end
    end
  end

  # `u`'s least `{key, x}` over its neighbours in `roots`, or nil - by
  # walking `u`'s row and testing membership, or the roots and looking each
  # one up in the row, whichever is shorter. The least of a set does not
  # depend on the order it is visited in.
  defp least_root(state, u, roots, roots_list) do
    case state.weight do
      %{^u => row} ->
        if map_size(roots) < map_size(row),
          do: least_root_by_roots(roots_list, row, nil),
          else: least_root_by_row(:maps.to_list(row), roots, nil)

      _ ->
        nil
    end
  end

  defp least_root_by_roots([], _row, best), do: best

  defp least_root_by_roots([{x, c} | rest], row, best) do
    case row do
      %{^x => w} -> least_root_by_roots(rest, row, lower_root(x, c - w, best))
      _ -> least_root_by_roots(rest, row, best)
    end
  end

  defp least_root_by_row([], _roots, best), do: best

  defp least_root_by_row([{x, w} | rest], roots, best) do
    case roots do
      %{^x => c} -> least_root_by_row(rest, roots, lower_root(x, c - w, best))
      _ -> least_root_by_row(rest, roots, best)
    end
  end

  defp lower_root(x, key, best) do
    candidate = {key, x}
    if best == nil or candidate < best, do: candidate, else: best
  end

  # Every vertex's entry, from nothing: O(|outer| x V), at the first stage
  # of every solve (later stages carry the caches, `carry_caches/2`).
  defp rebuild_caches(state) do
    state = %{
      state
      | best_outer: %{},
        cross: cross_empty(),
        shift_outer: 0,
        shift_cross: 0,
        min_outer: nil
    }

    # Driven from the OUTER vertices, not from all of them. Every entry in
    # either cache is an edge with an outer far end, so offering each outer
    # vertex to its neighbours produces exactly the same maps as asking
    # every vertex to find its own best - and costs O(|outer| x V) instead
    # of O(V^2).
    #
    # That difference is the point at a stage boundary, which is when this
    # runs: `init_labels/1` has just marked every MATCHED blossom free, so
    # the outer set is only the unmatched ones. It starts at the whole
    # field and shrinks towards nothing as the matching fills in, which is
    # precisely the shape that makes iterating all V vertices wasteful.
    # Only the outer vertices are walked at all -- everything a non-outer
    # vertex needs is delivered TO it by an outer neighbour's offer.
    outer =
      state.label
      |> Enum.filter(fn {_b, l} -> l == :outer end)
      |> Enum.flat_map(fn {b, _} -> blossom_vertices(state, b) end)

    outer
    |> Enum.reduce(state, &settle_outer_vertex(&2, &1))
    |> build_roots(outer)
  end

  # Fold a set of just-changed vertices back in, doing exactly what each
  # one's NEW label requires and no more.
  #
  # This used to recompute every changed vertex's own entry and then offer
  # every changed vertex to its neighbours - two full walks of each
  # adjacency row, and half of them for nothing: a vertex that has just
  # become INNER is neither a cache subject nor a candidate for anyone, so
  # offering it walked two hundred neighbours to hit `_ -> state` every
  # time. That walk (`offer_vertex/2`, since removed) was 62% of a solve,
  # from 35,000 calls.
  #
  # Now:
  #
  #   * newly INNER - delete its entries. No walk.
  #   * newly OUTER - ONE walk of its row that computes its own best cross
  #     edge and offers it to every neighbour in the same pass. The two
  #     jobs read the same neighbours with the same duals; fusing them is
  #     free.
  #   * newly FREE or ZERO (only after an expansion) - recompute its
  #     `best_outer`, which does need a walk, since its neighbours' outer
  #     status is what it depends on. Nothing to offer: it is not outer.
  #
  # Same maps as before, reached with roughly a third of the row visits.
  # After `form_blossom/5`: the new blossom `b` is outer, built from
  # `children`, of which the `formerly_inner` vertices had no presence in
  # any cache. This is bbpPairings' `initializeFromChildren`.
  #
  #   * The cross table: MERGE the outer children's rows into `b`'s, and
  #     every other blossom's entries for the children into one entry for
  #     `b`. No vertex walked. The second-best edge to every other blossom
  #     was already in the table, so nothing is lost when the best one
  #     becomes internal -- which is exactly the case formation produces,
  #     since blossoms merge because their best edges pointed at each
  #     other. Under the previous per-vertex design that invalidated almost
  #     every entry and cost 252,000 rescans per 209-player round.
  #   * The formerly-inner vertices: walked once, offering their edges to
  #     the table and to `best_outer` (they are outer now).
  #   * Every vertex of `b` loses its `best_outer` entry, since an outer
  #     vertex holds none.
  defp refresh_after_formation(state, b, children, formerly_inner) do
    state = cross_merge(state, b, children)

    Enum.reduce(blossom_vertices(state, b), state, fn v, state ->
      if is_map_key(formerly_inner, v),
        do: settle_outer_vertex(state, v),
        else: %{state | best_outer: Map.delete(state.best_outer, v)}
    end)
  end

  defp refresh_caches(state, changed) do
    Enum.reduce(changed, state, fn v, state ->
      case Map.get(state.label, Map.fetch!(state.in_blossom, v)) do
        :inner ->
          %{state | best_outer: Map.delete(state.best_outer, v)}

        :outer ->
          settle_outer_vertex(state, v)

        _ ->
          recompute_vertex(state, v)
      end
    end)
  end

  # For a vertex that is (now) outer, in one pass over its adjacency row:
  # offer itself to every free/zero neighbour (`best_outer`), and offer
  # every edge to an outer neighbour in another blossom to the cross table
  # (both rows). This is the ONLY place a vertex's edges are ever walked
  # for the cross table; everything else about the table is a merge or a
  # delete.
  defp settle_outer_vertex(state, v) do
    state = offer_min_outer(state, v)
    blossom = Map.fetch!(state.in_blossom, v)
    best_outer = Map.delete(state.best_outer, v)
    cross = state.cross

    case Map.get(state.weight, v) do
      nil ->
        %{state | best_outer: best_outer, cross: cross}

      row ->
        # Everything the loop reads is pulled out of `state` ONCE, and the
        # two caches are threaded through the reduce as bare maps. Writing
        # `%{state | ...}` inside the loop rebuilds the whole state map on
        # every neighbour visited, which measured at four times the cost of
        # the work it wrapped.
        dual_v = Map.fetch!(state.dual, v)
        duals = state.dual
        labels = state.label
        in_blossom = state.in_blossom
        # The stored (biased) resistance is `dual_v + dual_u - w + shift`;
        # folding the shift into `dual_v` once saves a bignum addition per
        # neighbour.
        dv_cross = dual_v + state.shift_cross
        dv_outer = dual_v + state.shift_outer

        # The label is read FIRST and the resistance computed only for the
        # neighbours that take an offer: an inner neighbour, or one in the
        # same blossom, costs one lookup rather than two lookups and two
        # bignum operations.
        #
        # The cross-table offers are GATHERED here and applied once, after
        # the walk - see `cross_gather/6` for why that is the same table.
        # `own` is `blossom`'s row as the walk started.
        own = cross_row(cross, blossom)

        #
        # The row is walked as `:maps.to_list/1` gives it, which is the order
        # `Enum.reduce/3` on the map (`:maps.fold/3`) visits it in - both are
        # `erts_internal:map_next/3` from the same start - and that order
        # matters here: of two equal-resistance edges to one blossom the
        # first offered is kept. A plain recursion over the list is a third
        # of the cost of the fold and its two closures per neighbour.
        {updates, best_outer} =
          settle_walk(
            :maps.to_list(row),
            in_blossom,
            labels,
            duals,
            blossom,
            own,
            dv_cross,
            dv_outer,
            v,
            %{},
            best_outer
          )

        %{state | cross: cross_apply(cross, blossom, updates), best_outer: best_outer}
    end
  end

  defp settle_walk([], _ib, _labels, _duals, _blossom, _own, _dvc, _dvo, _v, up, bo), do: {up, bo}

  defp settle_walk([{u, w} | rest], ib, labels, duals, blossom, own, dvc, dvo, v, up, bo) do
    # `u`'s top-level blossom and its label in one match when `u` is its own
    # top-level blossom (see `top_of/3`), through `in_blossom` otherwise.
    {ub, label} =
      case labels do
        %{^u => label} ->
          {u, label}

        _ ->
          ub = :erlang.map_get(u, ib)

          case labels do
            %{^ub => label} -> {ub, label}
            _ -> {ub, nil}
          end
      end

    cond do
      label == :outer and ub != blossom ->
        up = cross_gather(up, own, ub, dvc + :erlang.map_get(u, duals) - w, v, u)
        settle_walk(rest, ib, labels, duals, blossom, own, dvc, dvo, v, up, bo)

      label == :free or label == :zero ->
        bo = offer(bo, u, dvo + :erlang.map_get(u, duals) - w, v)
        settle_walk(rest, ib, labels, duals, blossom, own, dvc, dvo, v, up, bo)

      true ->
        settle_walk(rest, ib, labels, duals, blossom, own, dvc, dvo, v, up, bo)
    end
  end

  # The top-level blossom holding vertex `u`. The label map's keys are
  # exactly the top-level blossoms (`top_blossoms/1`), and a vertex id among
  # them is a trivial blossom - the vertex itself - which is what most
  # vertices are: one map match on the label map that the walk reads
  # anyway, and `in_blossom` only for a vertex inside a non-trivial one.
  # (Checked against `in_blossom` on every walk of the replayed corpus
  # before the check was taken out.)
  defp top_of(u, labels, ib) do
    case labels do
      %{^u => _} -> u
      _ -> :erlang.map_get(u, ib)
    end
  end

  # The label of the top-level blossom holding vertex `u`, or nil.
  defp label_of(u, labels, ib) do
    case labels do
      %{^u => label} ->
        label

      _ ->
        ub = :erlang.map_get(u, ib)

        case labels do
          %{^ub => label} -> label
          _ -> nil
        end
    end
  end

  # For a FREE or ZERO vertex: its best edge to any outer vertex. (An outer
  # vertex is handled by `settle_outer_vertex/2`; an inner one holds
  # nothing.) The cross table is not a per-vertex thing any more, so only
  # `best_outer` is in question here.
  defp recompute_vertex(state, v) do
    blossom = Map.fetch!(state.in_blossom, v)
    row = Map.get(state.weight, v)

    case Map.get(state.label, blossom) do
      label when label in [:free, :zero] ->
        best = bias(scan_row(state, v, row, blossom, :outer), state.shift_outer)
        %{state | best_outer: put_best(state.best_outer, v, best)}

      _ ->
        %{state | best_outer: Map.delete(state.best_outer, v)}
    end
  end

  defp scan_row(_state, _v, nil, _blossom, _kind), do: nil

  # Ties on resistance break on the lower vertex id, so the winner is a
  # property of the graph rather than of `row`'s map order - the same
  # `{r, v}` rule the cross table uses (see `lower_min/2`) - and the walk
  # may take the row in any order.
  defp scan_row(state, v, row, blossom, kind) do
    scan_walk(
      :maps.to_list(row),
      state.in_blossom,
      state.label,
      state.dual,
      :erlang.map_get(v, state.dual),
      kind == :outer,
      blossom,
      nil
    )
  end

  defp scan_walk([], _ib, _labels, _duals, _dual_v, _any?, _blossom, best), do: best

  defp scan_walk([{u, w} | rest], ib, labels, duals, dual_v, any?, blossom, best) do
    u_blossom = top_of(u, labels, ib)

    case labels do
      %{^u_blossom => :outer} when any? or u_blossom != blossom ->
        r = dual_v + :erlang.map_get(u, duals) - w
        best = if best == nil or {r, u} < best, do: {r, u}, else: best
        scan_walk(rest, ib, labels, duals, dual_v, any?, blossom, best)

      _ ->
        scan_walk(rest, ib, labels, duals, dual_v, any?, blossom, best)
    end
  end

  # An equal-resistance offer replaces the incumbent only when it names a
  # lower vertex, so `best_outer[u]` is the `{r, v}`-minimum over the
  # offers rather than whichever arrived first.
  defp offer(cache, u, r, v) do
    case cache do
      %{^u => {best, best_v}} when {best, best_v} <= {r, v} -> cache
      _ -> Map.put(cache, u, {r, v})
    end
  end

  defp put_best(cache, v, nil), do: Map.delete(cache, v)
  defp put_best(cache, v, best), do: Map.put(cache, v, best)

  defp bias(nil, _shift), do: nil
  defp bias({r, u}, shift), do: {stored(r, shift), u}

  # `apply_delta/2` moves every outer vertex's dual down by delta and every
  # inner vertex's up by the same, so a cached resistance moves by a fixed
  # amount that depends only on how many of its endpoints are outer: one
  # for `best_outer` (the far end), two for `best_cross` (both ends).
  #
  # Crucially, EVERY entry in a given cache moves by the same amount. So
  # rather than rewriting the map - O(V) allocation on every one of O(V^2)
  # delta steps, which measured as costing more than the scans it replaced
  # - the shift is carried as a running offset. Entries are stored biased
  # by the offset at the moment they were written, and read back unbiased,
  # so they all track the duals for free.
  defp shift_caches(state, 0), do: state

  defp shift_caches(state, delta) do
    %{state | shift_outer: state.shift_outer + delta, shift_cross: state.shift_cross + 2 * delta}
  end

  # Stored biased, read unbiased. Comparisons between two entries of the
  # same cache can use the stored form directly, since the bias is common.
  defp stored(r, shift), do: r + shift
  defp unbiased(r, shift), do: r - shift

  # Straight off `best_outer`, which holds an entry for exactly the free
  # and zero vertices that have any edge to an outer one. Was a rescan of
  # every (non-outer, outer) pair on every delta step.
  defp min_free_or_zero_to_outer(state) do
    # The walk is over a plain map, so "first seen wins" would make the
    # answer an artefact of Erlang's map order. Ties break on the lower
    # vertex id instead: canonical, and stable across OTP releases and
    # across the 32-key flatmap/hashmap boundary - and the walk may take the
    # entries in any order.
    case least_best_outer(:maps.to_list(state.best_outer), nil, nil) do
      nil -> {nil, nil}
      {r, v} -> {unbiased(r, state.shift_outer), v}
    end
  end

  defp least_best_outer([], nil, _v), do: nil
  defp least_best_outer([], r, v), do: {r, v}
  defp least_best_outer([{v, {r, _u}} | rest], nil, _), do: least_best_outer(rest, r, v)

  defp least_best_outer([{v, {r, _u}} | rest], best_r, best_v)
       when r < best_r or (r == best_r and v < best_v),
       do: least_best_outer(rest, r, v)

  defp least_best_outer([_ | rest], best_r, best_v), do: least_best_outer(rest, best_r, best_v)

  # The partner achieving that minimum, which the cache already recorded.
  defp min_outer_edge(state, v) do
    case state.best_outer do
      %{^v => {_r, u}} -> u
      _ -> nil
    end
  end

  # The flat vertex list of a blossom.
  #
  # `state.vertices_of` caches it for every NON-TRIVIAL blossom, maintained
  # at the three places the structure changes: `form_blossom/5` sets the new
  # blossom's list to the concatenation of its children's; `expand_blossom/2`
  # and `dissolve_one/3` delete the parent's entry (the children's are still
  # there, since they were non-trivial blossoms or bare vertices before).
  # A trivial blossom IS its vertex.
  #
  # Before this it was recomputed by recursion on every call -- 5.5 million
  # calls per 209-player round, most of them from `refresh_caches/2`
  # expanding a changed blossom to feed `settle_outer_vertex/2`, and each
  # one walking a nested tree that had not changed since the last call. It
  # was the largest cost in the profile once the stage count was right.
  #
  # The recursive walk is kept as the fallback for anything not in the
  # cache, so a caller asking about a blossom mid-transition still gets the
  # right answer rather than a crash.
  defp blossom_vertices(state, b) do
    case state.vertices_of do
      %{^b => vs} -> vs
      _ -> if Map.has_key?(state.children, b), do: walk_blossom_vertices(state, b), else: [b]
    end
  end

  defp walk_blossom_vertices(state, b) do
    if Map.has_key?(state.children, b) do
      state.children |> Map.fetch!(b) |> Enum.flat_map(&walk_blossom_vertices(state, &1))
    else
      [b]
    end
  end

  ## --------------------------------------------- the cross-edge table
  #
  # `state.cross` is bbpPairings' `minOuterEdges`: for every pair of OUTER
  # top-level blossoms, the least-resistance edge between them.
  #
  #     cross :: %{blossom => %{other_blossom => {stored_r, v_here, v_there}}}
  #
  # Symmetric -- both rows hold the edge, each from its own side -- and
  # keyed by BLOSSOM, which is the whole point. The previous design kept one
  # entry per VERTEX (its single best cross edge), and that died on blossom
  # formation: when outer blossoms merge it is because their best edges
  # point at each other, so nearly every entry was invalidated and had to
  # be rescanned -- 252,000 row walks per 209-player round, 58% of it.
  #
  # Per blossom pair, formation is a MERGE: the new blossom's row is the
  # min over its children's rows, and every other blossom's entry for the
  # new one is the min over its entries for the children. No vertex is
  # visited. The second-best edge to every other blossom was already in
  # the table, so nothing is lost when the best one becomes internal.
  #
  # Maintained at:
  #   * `rebuild_caches/1`     -- a solve's first stage: every outer
  #                               vertex's row walked by
  #                               `settle_outer_vertex/2`
  #   * `settle_outer_vertex/2` -- a vertex has just become outer: one walk
  #                               of its row offers every edge to another
  #                               outer blossom (`cross_gather/6`,
  #                               `cross_apply/3`)
  #   * `cross_merge/3`        -- formation: merge children's rows
  #   * `cross_retain/2`       -- a later stage's start: drop every row and
  #                               entry of a blossom no longer outer
  #
  # Stored resistances carry `shift_cross` bias exactly as before, so the
  # dual shift stays O(1). The running minimum over the whole table
  # (bbpPairings' `minOuterOuterEdgeResistance`) is kept with it, so
  # `min_outer_outer/1` reads it instead of scanning the table - which at a
  # stage start holds ~|outer|^2 entries and was scanned on every one of
  # ~27,000 delta steps a round, 20% of it. (It was once one flat map keyed
  # `{lo, hi}`; the row layout below replaced it.)
  ## ------------------------------------------------------ the cross table
  #
  # bbpPairings' `minOuterEdges`: for every pair of OUTER top-level
  # blossoms, the least-resistance edge between them, as `{resistance,
  # vertex_here, vertex_there}`. Kept as ROWS, one per outer blossom,
  # each row a map from partner blossom to that entry, with the symmetric
  # entry in the partner's row -- the same shape as the weight adjacency,
  # and for the same reason: the two operations that change the table
  # touch one blossom's row and its partners' entries for it, and a flat
  # `{lo, hi}`-keyed map made both of them a walk of the whole table.
  #
  #   * `cross_merge/3` (blossom formation) used to rebuild the flat map
  #     from scratch -- O(k^2) in the number of outer blossoms -- and
  #     formations are the commonest event after tree growth: 9,877 of
  #     them on a 400-player round, 5.3 s of 15. Now it folds the
  #     children's rows into one and re-keys the partners' entries:
  #     O(children x k).
  #   * the stage-start filter in `carry_caches/2` dropped every entry of
  #     a blossom that left the outer set by testing all k^2 entries; now
  #     it walks the leaving blossoms' rows: O(left x k).
  #
  # Alongside the rows, `mins[a]` is row a's minimum as `{r, partner}`,
  # and `best` the minimum over the rows as `{r, a, b}` with `a < b`.
  # Offers only lower minima and update them in place; merges and the
  # stage filter can raise them, and recompute exactly the rows they
  # touched plus `best` (one pass over `mins`, O(k)). Ties are broken on
  # `{r, partner}` / `{r, a, b}` -- a canonical order, where the flat map
  # had "first offered wins", which was deterministic but an accident of
  # iteration order.
  #
  # Resistances are stored biased by `shift_cross` at the moment they are
  # written and read back unbiased (`stored/2`, `unbiased/2`), exactly as
  # before; comparisons between entries are on the stored form.

  defp cross_empty, do: {%{}, %{}, nil}

  # An OFFER of the edge `(va in a, vb in b)` at stored resistance `r` is
  # kept unless the table already holds an entry for `{a, b}` with
  # `old <= r` - so among equal resistances the first offered wins - and a
  # kept offer writes `{r, va, vb}` into `a`'s row, its mirror
  # `{r, vb, va}` into `b`'s, and lowers both row minima and the running
  # best. That rule is applied in batches, one per settling blossom
  # (`settle_outer_vertex/2`, the one place edges are offered):
  #
  # `cross_row/2` is `a`'s row as it stands. `cross_gather/6` records one
  # offer in `updates`, keeping the incumbent exactly as the rule says -
  # whether that incumbent is in the table or was gathered earlier in the
  # same run - and `cross_apply/3` then writes the survivors. An offer only
  # ever replaces an entry by a strictly smaller one, and a row's minimum,
  # the running best and the partner's mirror entry are each a function of
  # the final entries alone, so one write per touched entry reaches the
  # same table as one write per offer did. That used to be one rewrite of
  # `a`'s row, `a`'s minimum and the best per outer neighbour: a hundred
  # rewrites of the same row per settle on a cold solve, where nearly every
  # neighbour is outer.
  defp cross_row({rows, _mins, _best}, a), do: Map.get(rows, a, %{})

  defp cross_gather(updates, own, b, r, va, vb) do
    case updates do
      %{^b => {old, _, _}} when old <= r ->
        updates

      %{^b => _} ->
        Map.put(updates, b, {r, va, vb})

      _ ->
        case own do
          %{^b => {old, _, _}} when old <= r -> updates
          _ -> Map.put(updates, b, {r, va, vb})
        end
    end
  end

  defp cross_apply(cross, _a, updates) when map_size(updates) == 0, do: cross

  defp cross_apply({rows, mins, best}, a, updates) do
    rows = Map.put(rows, a, Map.merge(Map.get(rows, a, %{}), updates))

    # Each partner's mirror entry and minimum are its own; `a`'s minimum and
    # the running best are one minimum over all the updates, offered once.
    # (For a fixed `a`, the least `{r, lo, hi}` is the entry with the least
    # `{r, partner}`: equal `r` puts the pair with the smaller partner first
    # whether that partner sits below `a` or above it.)
    {rows, mins, least} = mirror_updates(:maps.to_list(updates), a, rows, mins, nil)

    {r, b} = least
    {lo, hi} = if a < b, do: {a, b}, else: {b, a}
    {rows, offer_min(mins, a, least), lower_best(best, {r, lo, hi})}
  end

  # Each update's mirror entry in its partner's row, the partner's minimum,
  # and the least update - all per-partner edits or a minimum, so the order
  # the updates are taken in does not matter.
  defp mirror_updates([], _a, rows, mins, least), do: {rows, mins, least}

  defp mirror_updates([{b, {r, va, vb}} | rest], a, rows, mins, least) do
    rows =
      case rows do
        %{^b => row} -> Map.put(rows, b, Map.put(row, a, {r, vb, va}))
        _ -> Map.put(rows, b, %{a => {r, vb, va}})
      end

    mins = offer_min(mins, b, {r, a})
    least = if least == nil, do: {r, b}, else: lower_min(least, {r, b})
    mirror_updates(rest, a, rows, mins, least)
  end

  # Write the row minimum only when it changes; a `Map.update` that puts
  # the old value back still rebuilds the map.
  defp offer_min(mins, a, cand) do
    case mins do
      %{^a => old} ->
        case lower_min(old, cand) do
          ^old -> mins
          new -> Map.put(mins, a, new)
        end

      _ ->
        Map.put(mins, a, cand)
    end
  end

  defp lower_min({r0, _} = old, {r, _}) when r0 < r, do: old
  defp lower_min({r0, b0} = old, {r, b}) when r0 == r and b0 <= b, do: old
  defp lower_min(_old, new), do: new

  defp lower_best(nil, new), do: new
  defp lower_best(old, new), do: if(new < old, do: new, else: old)

  # Row a's minimum, from its entries: the least `{r, partner}`.
  #
  # A tight loop over the row's entries rather than a fold calling
  # `lower_min/2` with a fresh tuple per entry - this is the most-called
  # scan in the matcher (a row is rescanned whenever the blossom its
  # minimum pointed at merges or leaves the outer set, which on a cold
  # solve is most rows at most steps). The minimum of a set under a total
  # order does not depend on the order it is visited in, and every entry
  # has its own partner, so the order here is free.
  defp row_min(row), do: row |> :maps.to_list() |> least_entry(nil, nil)

  defp least_entry([], nil, _b), do: nil
  defp least_entry([], r, b), do: {r, b}
  defp least_entry([{b, {r, _, _}} | rest], nil, _), do: least_entry(rest, r, b)

  defp least_entry([{b, {r, _, _}} | rest], best_r, best_b)
       when r < best_r or (r == best_r and b < best_b),
       do: least_entry(rest, r, b)

  defp least_entry([_ | rest], best_r, best_b), do: least_entry(rest, best_r, best_b)

  defp cross_best(mins), do: best_of_mins(:maps.to_list(mins), nil)

  defp best_of_mins([], acc), do: acc

  defp best_of_mins([{a, {r, b}} | rest], acc) do
    {lo, hi} = if a < b, do: {a, b}, else: {b, a}
    best_of_mins(rest, lower_best(acc, {r, lo, hi}))
  end

  # The new blossom `new_b` has absorbed `children`, all of which were
  # top-level and some of which were outer. Every entry touching a child
  # is re-keyed: an entry between two children is now INTERNAL and is
  # dropped; an entry between a child and an outsider `k` becomes an entry
  # between `new_b` and `k`, keeping the minimum if several collapse onto
  # the same key. No vertex is visited.
  #
  # The second-best edge to every outsider was already in the table, so
  # nothing is lost when the best one becomes internal -- which is exactly
  # the case formation produces, since blossoms merge because their best
  # edges pointed at each other. Under a per-vertex design that
  # invalidated almost every entry and cost 252,000 rescans per 209-player
  # round.
  #
  # Children that were INNER had no entries; the caller walks their
  # vertices with `settle_outer_vertex/2`.
  defp cross_merge(state, new_b, children) do
    child_set = Map.from_keys(children, true)
    {rows, mins, _best} = state.cross

    # The merged row: every child's entries to outsiders, best per outsider,
    # the first of equal resistances kept - so the children are taken in
    # cycle order and each row in `Enum.reduce/3`'s order, which
    # `:maps.to_list/1` gives (see `settle_outer_vertex/2`).
    new_row =
      Enum.reduce(children, %{}, fn c, acc ->
        case rows do
          %{^c => row} -> merge_row(:maps.to_list(row), child_set, acc)
          _ -> acc
        end
      end)

    rows = Map.drop(rows, children)
    mins = Map.drop(mins, children)

    # Each outsider loses its entries for the children and gains one for
    # `new_b`; its row minimum is recomputed only if it pointed at a child
    # or the new entry beats it.
    {rows, mins} = rekey_outsiders(:maps.to_list(new_row), new_b, children, child_set, rows, mins)

    {rows, mins} =
      if map_size(new_row) == 0,
        do: {rows, mins},
        else: {Map.put(rows, new_b, new_row), Map.put(mins, new_b, row_min(new_row))}

    %{state | cross: {rows, mins, cross_best(mins)}}
  end

  defp merge_row([], _child_set, acc), do: acc

  defp merge_row([{k, {r, _, _} = entry} | rest], child_set, acc) do
    cond do
      is_map_key(child_set, k) -> merge_row(rest, child_set, acc)
      match?(%{^k => {old, _, _}} when old <= r, acc) -> merge_row(rest, child_set, acc)
      true -> merge_row(rest, child_set, Map.put(acc, k, entry))
    end
  end

  # Per outsider `k` of the merged row: its entries for the children become
  # one for `new_b`, and its minimum is recomputed only if it pointed at a
  # child or the new entry beats it. Each outsider's edits are its own, so
  # the order does not matter.
  defp rekey_outsiders([], _new_b, _children, _child_set, rows, mins), do: {rows, mins}

  defp rekey_outsiders([{k, {r, vc, vk}} | rest], new_b, children, child_set, rows, mins) do
    row = rows |> Map.fetch!(k) |> Map.drop(children) |> Map.put(new_b, {r, vk, vc})
    rows = Map.put(rows, k, row)

    mins =
      case Map.get(mins, k) do
        {_, p} = old ->
          if is_map_key(child_set, p),
            do: Map.put(mins, k, row_min(row)),
            else: Map.put(mins, k, lower_min(old, {r, new_b}))

        nil ->
          Map.put(mins, k, row_min(row))
      end

    rekey_outsiders(rest, new_b, children, child_set, rows, mins)
  end

  # Drop every entry of the blossoms that are no longer outer -- the
  # stage-start filter. Walks the leaving blossoms' rows, not the table.
  #
  # The removals are gathered first and applied once per surviving row, and
  # a surviving row's minimum is recomputed at most ONCE, after all of its
  # removals. This used to remove one leaving blossom at a time and
  # recompute a row's minimum every time it pointed at the blossom just
  # removed - often straight at the next leaving blossom, which then cost
  # another full walk of the same row. At a stage boundary most of the
  # forest leaves the outer set at once, and those repeated walks were a
  # quarter of a cold solve.
  #
  # The result is the same table. The rows lose exactly the same entries.
  # A row whose minimum pointed at a survivor keeps it: it was the least
  # entry of the old row and is still in the new one. A row whose minimum
  # pointed at a leaving blossom gets `row_min/1` of its final row - and
  # that is what the one-at-a-time loop ended on too, because each
  # recomputation there was over a superset of the final row, and it only
  # stopped recomputing once the minimum it found was a survivor, i.e. an
  # entry of the final row and so its least entry as well. The order
  # `row_min/1` breaks ties in (`{r, partner}`) is a total order on the
  # entries, so "the least entry" names one entry.
  defp cross_retain({rows, mins, _best}, outer_blossoms) do
    left = for {b, _} <- rows, not is_map_key(outer_blossoms, b), do: b
    left_set = Map.from_keys(left, true)

    # Surviving row -> the leaving blossoms it holds entries for.
    removals =
      Enum.reduce(left, %{}, fn b, acc ->
        gather_removals(:maps.to_list(:erlang.map_get(b, rows)), b, left_set, acc)
      end)

    {rows, mins} = apply_removals(:maps.to_list(removals), left_set, rows, mins)

    rows = Map.drop(rows, left)
    mins = mins |> Map.drop(left) |> Map.reject(fn {_, m} -> m == nil end)
    {rows, mins, cross_best(mins)}
  end

  # Surviving row -> the leaving blossoms it holds entries for. Which order
  # each list comes out in does not matter: it is only dropped.
  defp gather_removals([], _b, _left_set, acc), do: acc

  defp gather_removals([{k, _} | rest], b, left_set, acc) do
    case left_set do
      %{^k => _} ->
        gather_removals(rest, b, left_set, acc)

      _ ->
        acc =
          case acc do
            %{^k => gone} -> Map.put(acc, k, [b | gone])
            _ -> Map.put(acc, k, [b])
          end

        gather_removals(rest, b, left_set, acc)
    end
  end

  # Each surviving row loses its entries for the leaving blossoms, and its
  # minimum is recomputed once if it pointed at one - per row, so in any
  # order.
  defp apply_removals([], _left_set, rows, mins), do: {rows, mins}

  defp apply_removals([{k, gone} | rest], left_set, rows, mins) do
    row = Map.drop(:erlang.map_get(k, rows), gone)
    rows = Map.put(rows, k, row)

    mins =
      case mins do
        %{^k => {_, p}} when is_map_key(left_set, p) -> Map.put(mins, k, row_min(row))
        _ -> mins
      end

    apply_removals(rest, left_set, rows, mins)
  end

  # The least-resistance outer-outer edge overall, straight off the running
  # minimum.
  defp min_outer_outer(state) do
    case state.cross do
      {_, _, nil} ->
        {nil, nil}

      {rows, _, {r, a, b}} ->
        {_, va, vb} = rows |> Map.fetch!(a) |> Map.fetch!(b)
        {unbiased(r, state.shift_cross), {va, vb}}
    end
  end

  # The least dual over the INNER non-trivial top-level blossoms, ties to
  # the lowest blossom id.
  #
  # Found by walking the non-trivial blossoms (`state.children`'s keys)
  # rather than every top-level blossom: the label map holds an entry only
  # for a TOP-level blossom, so "has children and is labelled inner" is
  # exactly the set the walk over `top_blossoms/1` filtered down to. That
  # walk visited every vertex of the graph on every delta step - a resumed
  # solve grows its tree one pair at a time, so that was O(V) per step for
  # a set that is usually empty. The tie-break is the same: the old walk
  # took `Enum.min_by/2`'s FIRST minimum over ids in ascending order, which
  # is the least `{dual, id}`.
  defp min_inner_blossom_dual(state) do
    labels = state.label
    duals = state.dual

    case least_inner(:maps.keys(state.children), labels, duals, nil) do
      nil -> {nil, nil}
      best -> best
    end
  end

  defp least_inner([], _labels, _duals, best), do: best

  defp least_inner([b | rest], labels, duals, best) do
    case labels do
      %{^b => :inner} ->
        candidate = {:erlang.map_get(b, duals), b}

        least_inner(
          rest,
          labels,
          duals,
          if(best == nil or candidate < best, do: candidate, else: best)
        )

      _ ->
        least_inner(rest, labels, duals, best)
    end
  end

  # ------------------------------------------------------ dual updates

  defp apply_delta(state, 0), do: state

  # Every outer blossom's vertices down by `delta` and its own dual up by
  # twice that, every inner one the other way. The edits are to disjoint
  # keys, so the order the blossoms are visited in does not matter; the
  # walk is over `state.forest`, the outer and inner top-level blossoms,
  # kept beside the label map by every writer of a label within a stage
  # (`init_labels/1`, the growth, `form_blossom/5`, `expand_blossom/2`) -
  # where walking every top-level blossom's label, as this did, made each
  # delta step O(V) on a forest of a few blossoms.
  defp apply_delta(state, delta) do
    dual = shift_forest(:maps.to_list(state.forest), state, delta, state.dual)
    shift_caches(%{state | dual: dual}, delta)
  end

  defp shift_forest([], _state, _delta, dual), do: dual

  defp shift_forest([{b, :outer} | rest], state, delta, dual),
    do: shift_forest(rest, state, delta, shift_blossom(state, b, -delta, dual))

  defp shift_forest([{b, :inner} | rest], state, delta, dual),
    do: shift_forest(rest, state, delta, shift_blossom(state, b, delta, dual))

  defp shift_forest([_ | rest], state, delta, dual), do: shift_forest(rest, state, delta, dual)

  defp shift_blossom(state, b, delta, dual) do
    dual = shift_vertices(blossom_vertices(state, b), delta, dual)

    case state.children do
      %{^b => _} -> Map.put(dual, b, :erlang.map_get(b, dual) - 2 * delta)
      _ -> dual
    end
  end

  defp shift_vertices([], _delta, dual), do: dual

  defp shift_vertices([v | rest], delta, dual),
    do: shift_vertices(rest, delta, Map.put(dual, v, :erlang.map_get(v, dual) + delta))

  # ------------------------------------------------------- augmentation

  # Direct translation of bbpPairings' `augmentToSource`.
  #
  # An earlier version of this tried to resolve vertex-level `mate`
  # INLINE as it walked - treating each visited blossom as needing
  # resolution "from an entry vertex to a specific exit vertex". That
  # turned out to be the wrong problem entirely, found by hand-tracing
  # the bare-triangle case against a brute-force oracle: for the
  # entry-equals-exit case (a blossom visited via its own dual variable
  # hitting zero, not via a further match), that design just returned
  # immediately WITHOUT EVER PAIRING UP THE BLOSSOM'S OTHER CHILDREN -
  # not a recursion bug, a real correctness gap.
  #
  # Re-reading `augmentToSource` itself settled it: bbpPairings does not
  # resolve entry-to-exit at all. It CASCADES a base reassignment through
  # every blossom the walk touches (`rootBlossom->baseVertex = vertex`,
  # repeated for the next blossom up via `originalMatch.baseVertex =
  # originalMatch.labeledVertex`) and defers ALL internal vertex pairing
  # to one separate pass (`putVerticesInMatchingOrder`), run once after
  # the WHOLE algorithm terminates - see `resolve_all_matching/1`. Only
  # ONE special point (the base) ever needs handling per blossom, which
  # is both simpler and the actual textbook blossom lemma: given any one
  # base, the remaining even number of vertices pairs up consecutively
  # around the cycle. No "exit" concept exists in the correct model.
  defp augment_to_source(state, v, new_match) do
    b = Map.fetch!(state.in_blossom, v)
    # The asymmetric, per-blossom field - see `state.blossom_match`'s doc
    # on why this must NOT be the same symmetric map `mate` is.
    old_partner = Map.get(state.blossom_match, b)

    state = %{
      state
      | base: Map.put(state.base, b, v),
        blossom_match: put_or_delete(state.blossom_match, b, new_match)
    }

    case old_partner do
      nil ->
        state

      partner ->
        parent_blossom = Map.fetch!(state.in_blossom, partner)
        {labeling_v, labeled_v} = Map.fetch!(state.label_edge, parent_blossom)

        state = %{
          state
          | base: Map.put(state.base, parent_blossom, labeled_v),
            blossom_match: put_or_delete(state.blossom_match, parent_blossom, labeling_v)
        }

        augment_to_source(state, labeling_v, labeled_v)
    end
  end

  defp set_mate(mate, a, nil), do: Map.delete(mate, a)
  defp set_mate(mate, a, b), do: mate |> Map.put(a, b) |> Map.put(b, a)

  # `matched?/2` uses `Map.has_key?`, so an "unmatch" must DELETE the key
  # rather than set it to nil - leaving a `b => nil` entry behind would
  # make an exposed blossom look matched.
  defp put_or_delete(map, k, nil), do: Map.delete(map, k)
  defp put_or_delete(map, k, v), do: Map.put(map, k, v)

  # The vertex-level matching, from the blossom-level one.
  #
  # (An earlier version resolved it per entry/exit pair, from the top-level
  # blossom `in_blossom` names, which recursed into itself for ever on a
  # bare triangle; nothing here looks a blossom up through `in_blossom` -
  # each step descends into the CHILD it names.)
  #
  # Run once, after `augment_until_done/1` has finished cascading every
  # blossom's base to its final value - the direct analogue of
  # bbpPairings' separate `putVerticesInMatchingOrder` pass
  # (`Computer::computeMatching()` runs it once per root blossom only
  # after `graph->computeMatching()` itself has fully converged).
  #
  # Two independent things to set, per top-level blossom: the EXTERNAL
  # pair (this blossom's base, matched to `blossom_match`, an asymmetric
  # field - see that field's own doc) and the INTERNAL pairing (every
  # other vertex in the blossom, paired up two at a time relative to
  # that SAME base - the textbook one-special-point blossom lemma: given
  # any one base, the remaining even number of vertices pairs up
  # consecutively around the odd cycle).
  # `mate` is a DERIVED view of `blossom_match`, rebuilt here from nothing
  # at the end of every solve. It used to accumulate instead -- harmless
  # when each solve started from an empty state, and wrong the moment a
  # solve started from a previous one: `prepare_vertex/2` re-pairs siblings
  # at the blossom level, and a vertex re-absorbed into a new blossom
  # before the end of the next solve never had its old `mate` entry
  # overwritten. Result: `%{1 => 5, 5 => 1}` alongside `blossom_match`
  # saying `1 <-> 4`, and an asymmetric "matching" handed to the caller.
  defp resolve_all_matching(state) do
    state = %{state | mate: %{}}

    Enum.reduce(top_blossoms(state), state, fn b, state ->
      state =
        case Map.get(state.blossom_match, b) do
          nil -> state
          partner -> %{state | mate: set_mate(state.mate, base_vertex(state, b), partner)}
        end

      resolve_blossom_internal(state, b)
    end)
  end

  defp resolve_blossom_internal(state, b) do
    if Map.has_key?(state.children, b) do
      resolve_blossom_internal_nontrivial(state, b)
    else
      state
    end
  end

  defp resolve_blossom_internal_nontrivial(state, b) do
    children = Map.fetch!(state.children, b)
    base_v = base_vertex(state, b)
    base_child = Enum.find(children, &(base_v in blossom_vertices(state, &1)))
    base_idx = Enum.find_index(children, &(&1 == base_child))
    rotated = List.to_tuple(Enum.drop(children, base_idx) ++ Enum.take(children, base_idx))
    n = tuple_size(rotated)

    # The base child's OWN base is `base_v` itself (possibly deep inside
    # it, if base_child is non-trivial) - set explicitly before
    # recursing, since `base_v` may not already equal whatever
    # `base_child`'s own base field happens to hold.
    state = %{state | base: Map.put(state.base, base_child, base_v)}
    state = resolve_blossom_internal(state, base_child)

    pair_children(state, rotated, 1, n)
  end

  # Children at rotated positions 1, 2, ..., n-1 (base_child is position
  # 0 and already handled) pair up two at a time: (1,2), (3,4), and so
  # on - always an even count, since `n` (the blossom's own child count)
  # is always odd.
  defp pair_children(state, _rotated, i, n) when i >= n, do: state

  defp pair_children(state, rotated, i, n) do
    child_a = elem(rotated, i)
    child_b = elem(rotated, i + 1)
    {out_a, in_b} = connector(state, child_a, child_b)

    state = %{state | base: Map.put(state.base, child_a, out_a)}
    state = resolve_blossom_internal(state, child_a)
    state = %{state | base: Map.put(state.base, child_b, in_b)}
    state = resolve_blossom_internal(state, child_b)
    state = %{state | mate: set_mate(state.mate, out_a, in_b)}

    pair_children(state, rotated, i + 2, n)
  end

  # The connector vertex pair for a cyclically-adjacent pair of children
  # `{from, to}` (a vertex in `from`, a vertex in `to`, joined by a real
  # graph edge) - recorded once, at whichever blossom formation first
  # made them adjacent, and read many times across however many further
  # augmentations touch that blossom before it next expands.
  defp connector(state, from, to), do: Map.fetch!(state.connectors, {from, to})

  # ----------------------------------------------------- blossom lifecycle

  # Contract the odd cycle closed by the tight edge (v0, v1) - both
  # OUTER, both in the same tree - into one new blossom, labelled OUTER.
  #
  # Building `cycle` needed a second pass beyond `blossom_ids_to_root/2`
  # once `augment_to_source` needed real connector VERTICES, not just the
  # blossom-id chain: `path_to_target/4` walks the same chain but returns
  # the actual vertex sequence, from which consecutive pairs ARE the
  # connectors - each blossom but the last contributes an (entry, exit)
  # pair, and the vertex the walk continues on is exactly the next
  # blossom's own entry, by construction of the walk itself.
  defp form_blossom(state, v0, v1, ids0, ids1) do
    b0 = Map.fetch!(state.in_blossom, v0)
    b1 = Map.fetch!(state.in_blossom, v1)
    common = find_common_ancestor(ids0, ids1)

    ids0_before = Enum.take_while(ids0, &(&1 != common))
    ids1_before = Enum.take_while(ids1, &(&1 != common))

    flat0 = path_to_target(state, b0, v0, common)
    flat1 = path_to_target(state, b1, v1, common)

    cycle = ids0_before ++ [common] ++ Enum.reverse(ids1_before)

    # Which cycle members were INNER, captured before the relabel below:
    # their vertices hold no cache entries and need the full treatment after
    # formation, where the outer children's only need filtering. Returned
    # to the caller alongside the new state.
    formerly_inner =
      cycle
      |> Enum.filter(&(Map.get(state.label, &1) == :inner))
      |> Enum.flat_map(&blossom_vertices(state, &1))
      |> Map.from_keys(true)

    # `add_connectors/3` needs each id list in the SAME direction its own
    # `flat` was actually walked - `path_to_target/4` always walks UP
    # (b -> ... -> common), so that direction is `ids0_before ++
    # [common]` and `ids1_before ++ [common]`, never reversed. An earlier
    # version reversed BOTH the id list and (separately) the flat vertex
    # list here, meaning to "flip" the walk direction for the b1 side to
    # match `cycle`'s own down-oriented listing - but a connector is the
    # same edge regardless of which direction it's conceptually walked,
    # so reversing it at all was never correct, and doing it to both
    # lists independently misaligned them against each other. Found by
    # hand-tracing a bare triangle: the reversed pairing produced a
    # connector `{0,1} => {2,2}`, claiming vertex 2 belongs to blossom 0
    # and blossom 1, when neither actually contains it.
    connectors =
      state.connectors
      |> add_connectors(ids0_before ++ [common], flat0)
      |> add_connectors(ids1_before ++ [common], flat1)
      # The fresh tight edge itself closes the cycle from the last child
      # (b1) back to the first (b0).
      |> Map.put({List.last(cycle), List.first(cycle)}, {v1, v0})
      |> Map.put({List.first(cycle), List.last(cycle)}, {v0, v1})

    new_id = state.next_blossom_id
    children_map = Map.put(state.children, new_id, cycle)

    # The new blossom's vertex list is its children's, concatenated -- read
    # BEFORE `in_blossom` is rewritten below, while each child's own list
    # is still what `blossom_vertices/2` returns for it.
    new_vertices = Enum.flat_map(cycle, &blossom_vertices(state, &1))
    parent_of = Enum.reduce(cycle, state.parent_of, &Map.put(&2, &1, new_id))

    in_blossom =
      Enum.reduce(cycle, state.in_blossom, fn c, acc ->
        Enum.reduce(blossom_vertices(state, c), acc, &Map.put(&2, &1, new_id))
      end)

    base = Map.put(state.base, new_id, base_vertex(state, common))

    # The new blossom's own external connection is whatever `common` had
    # - contracting around it doesn't change what it was matched to.
    blossom_match =
      put_or_delete(state.blossom_match, new_id, Map.get(state.blossom_match, common))

    %{
      state
      | children: children_map,
        vertices_of: Map.put(state.vertices_of, new_id, new_vertices),
        parent_of: parent_of,
        in_blossom: in_blossom,
        base: base,
        blossom_match: blossom_match,
        connectors: connectors,
        dual: Map.put(state.dual, new_id, 0),
        # The children stop being top-level, so their labels go. This
        # keeps `state.label`'s KEY SET equal to the top-level blossom set,
        # which `top_blossoms/1` now relies on - see its comment. Before
        # this the stale child entries were harmless only because
        # `top_blossoms/1` was derived from `in_blossom` instead.
        label: Enum.reduce(cycle, Map.put(state.label, new_id, :outer), &Map.delete(&2, &1)),
        forest: state.forest |> Map.drop(cycle) |> Map.put(new_id, :outer),
        next_blossom_id: new_id + 1
    }
    |> then(&{&1, cycle, formerly_inner})
  end

  # Records the connector between every CONSECUTIVE pair of blossoms in
  # `ids` (both directions), reading the vertex pairs straight off
  # `flat`, which `path_to_target/4` built alongside the same walk.
  #
  # Pair i joins `ids[i]` to `ids[i + 1]` through `flat[2i + 1]` and
  # `flat[2i + 2]`: walked in step, two vertices of `flat` per id, where
  # indexing both lists with `Enum.at/2` (and `length/1` per step) was
  # quadratic in the path.
  defp add_connectors(connectors, [id, next_id | ids], [_entry | flat]) do
    {out_v, in_v, rest} =
      case flat do
        [out_v, in_v | rest] -> {out_v, in_v, rest}
        [out_v] -> {out_v, nil, []}
        [] -> {nil, nil, []}
      end

    connectors
    |> Map.put({id, next_id}, {out_v, in_v})
    |> Map.put({next_id, id}, {in_v, out_v})
    |> add_connectors([next_id | ids], [in_v | rest])
  end

  defp add_connectors(connectors, _ids, _flat), do: connectors

  # Flat vertex-level walk from `entry_vertex` (in blossom `b`) up to and
  # INCLUDING the entry into `target` - the same chain
  # `blossom_ids_to_root/2` walks at blossom-id granularity, but
  # returning the actual connecting VERTICES (two per blossom passed
  # through: how the walk entered it, and how it leaves), which is what
  # `add_connectors/3` needs and `blossom_ids_to_root/2` alone cannot
  # provide.
  defp path_to_target(state, b, entry_vertex, target),
    do: path_to_target(state, b, entry_vertex, target, walk_budget(state))

  defp path_to_target(_state, target, entry_vertex, target, _budget), do: [entry_vertex]

  defp path_to_target(state, _b, _entry_vertex, _target, 0),
    do: walk_exhausted!(state, "path_to_target/4")

  defp path_to_target(state, b, entry_vertex, target, budget) do
    case Map.get(state.label, b) do
      :outer ->
        base = base_vertex(state, b)
        mate_v = Map.fetch!(state.blossom_match, b)
        next_blossom = Map.fetch!(state.in_blossom, mate_v)
        [entry_vertex, base] ++ path_to_target(state, next_blossom, mate_v, target, budget - 1)

      :inner ->
        {labeling_v, labeled_v} = Map.fetch!(state.label_edge, b)
        next_blossom = Map.fetch!(state.in_blossom, labeling_v)

        [entry_vertex, labeled_v] ++
          path_to_target(state, next_blossom, labeling_v, target, budget - 1)
    end
  end

  # The step budget both tree walks below share, and the same `2n + 5` and
  # the same reasoning as `augment_until_done/1`'s stage budget: a walk
  # from a blossom up to its tree root passes through each top-level
  # blossom at most once, and there are fewer of those than vertices, so
  # anything longer means `label_edge`/`blossom_match` has a cycle in it.
  # No input is known to produce one - `grow/1`'s and
  # `augment_until_done/1`'s budgets were added after hunting exactly this
  # class of bug twice - but a cycle here spins for ever inside `Map.fetch!`
  # with no output at all, and failing loudly beats hanging silently.
  defp walk_budget(state), do: 2 * state.n + 5

  defp walk_exhausted!(state, what) do
    raise "WeightedMatching: exceeded #{what} step budget " <>
            "(#{walk_budget(state)} steps, n=#{state.n})"
  end

  @doc false
  # Tooling hook, not API: a state captured from an earlier build of this
  # module (`Ainalrami.WeightedMatching.Profile`'s capture), in the form
  # this one reads. Only the per-solve caches can differ, and `solve/1`
  # rebuilds those on entry.
  def __upgrade__(state),
    do: state |> Map.put(:roots, %{}) |> Map.put(:forest, %{}) |> Map.delete(:tops)

  @doc false
  # Test hook, not API. The two walks above are only reachable through a
  # `solve/2` that has already built a well-formed tree, so the budget
  # they carry cannot be exercised end to end; this drives them against a
  # hand-built state whose `label_edge` / `blossom_match` deliberately
  # cycles, which is the shape the budget exists to catch.
  def __walk_for_test__(:blossom_ids_to_root, state, b),
    do: blossom_ids_to_root(state, b)

  def __walk_for_test__(:path_to_target, state, {b, entry_vertex, target}),
    do: path_to_target(state, b, entry_vertex, target)

  # The stages of `solve/1` WITHOUT its prologue (`greedy_resume/1`,
  # `even_up_exposed_duals/1`), so a test can hand the search a state the
  # prologue would have repaired - odd exposed duals - and see
  # `grow_with_delta/6` refuse it.
  def __walk_for_test__(:stages, state, _), do: augment_until_done(%{state | label: %{}})

  # Full path from `b` up to (and including) its tree root, WITHOUT
  # skipping any blossom along the way - unlike an earlier version of
  # this function, which jumped straight from an OUTER blossom to the
  # next one up without recording the INNER blossom it passed through to
  # get there.
  #
  # That skip was invisible to the tree-root comparison (skipping intermediate
  # blossoms never changes where a walk eventually TERMINATES, so which
  # root two searches share is unaffected). It was NOT invisible to
  # `form_blossom/5`, which uses this same chain to build the new
  # blossom's actual cycle: a bare triangle graph (`n=3`, all three
  # edges present) produced a two-child cycle `[0, 2]`, silently missing
  # blossom 1 - a blossom the whole method's correctness DEPENDS on
  # having an odd number of children in, and `blossom_vertices/2`
  # recursing over that broken structure never terminated. Found by
  # tracing that exact minimal case after the triangle hung with no
  # output at all.
  defp blossom_ids_to_root(state, b), do: blossom_ids_to_root(state, b, walk_budget(state))

  defp blossom_ids_to_root(state, _b, 0), do: walk_exhausted!(state, "blossom_ids_to_root/2")

  defp blossom_ids_to_root(state, b, budget) do
    case Map.get(state.label, b) do
      :outer ->
        case Map.get(state.blossom_match, b) do
          nil ->
            [b]

          partner ->
            next_blossom = Map.fetch!(state.in_blossom, partner)
            [b | blossom_ids_to_root(state, next_blossom, budget - 1)]
        end

      :inner ->
        {labeling_v, _} = Map.fetch!(state.label_edge, b)
        [b | blossom_ids_to_root(state, Map.fetch!(state.in_blossom, labeling_v), budget - 1)]
    end
  end

  defp find_common_ancestor(path0, path1) do
    set1 = Map.from_keys(path1, true)
    Enum.find(path0, &is_map_key(set1, &1))
  end

  # Dissolve blossom `b` (its dual variable just hit zero) back into its
  # children - direct translation of `graph.cpp`'s `!minInnerDualVariable`
  # branch (the `rootBlossomPool.construct` calls around line 680).
  #
  # Every child but the base one (`rootChild`) sits on the cycle between
  # `base_child` (holds b's own current base vertex, still matched
  # EXTERNALLY exactly as b was) and `connect_child` (holds b's entry
  # vertex `labeled_v`, still entered EXTERNALLY exactly as b was, via
  # b's own original `label_edge`). Walking the cycle from `base_child`
  # one way reaches `connect_child`; that arc becomes the live tree chain
  # (children alternate OUTER/INNER, each adjacent pair matched to each
  # other via their recorded `connector`, continuing the SAME alternation
  # that made b a valid blossom in the first place); the *other* arc is
  # simply not part of the tree and its children pair off the same way
  # but are labelled FREE. `base_child` and `connect_child` are always
  # labelled INNER (an odd cycle has an odd-length chain between them),
  # confirmed against the C++'s explicit `&rootChild == currentChild`
  # override.
  #
  # `connect_forward` (whether walking forward from `base_child` reaches
  # `connect_child` in an even or odd number of hops) is what the C++
  # computes by toggling a bool once per hop starting `true` - i.e. even
  # hop count keeps it `true` - and is what decides BOTH which arc is
  # "the tree chain" and, per INNER child, which of its two neighbours is
  # its tree-parent (`label_edge`) versus its match partner (`base`,
  # via `linksToNext`, which toggles every position regardless of arc).
  #
  # An earlier version of this function always walked forward only, never
  # set `blossom_match` for any newly-exposed child, and always treated
  # the base child as OUTER - none of which match the source. Rewritten
  # from a line-by-line reading of the actual construct-call ternaries
  # after two crashes downstream (a missing vertex in the final matching,
  # a `nil` leaking into a connector lookup) traced back to this gap.
  defp expand_blossom(state, b) do
    children = Map.fetch!(state.children, b)
    {labeling_v, labeled_v} = Map.fetch!(state.label_edge, b)
    root_vertex = base_vertex(state, b)
    root_match = Map.get(state.blossom_match, b)

    base_child = Enum.find(children, &(root_vertex in blossom_vertices(state, &1)))
    connect_child = Enum.find(children, &(labeled_v in blossom_vertices(state, &1)))

    base_idx = Enum.find_index(children, &(&1 == base_child))
    rotated = Enum.drop(children, base_idx) ++ Enum.take(children, base_idx)
    n = length(rotated)
    connect_idx = Enum.find_index(rotated, &(&1 == connect_child))
    connect_forward = rem(connect_idx, 2) == 0
    rotated_t = List.to_tuple(rotated)

    state =
      rotated
      |> Enum.with_index()
      |> Enum.reduce(state, fn {child, i}, state ->
        links_to_next = rem(i, 2) == 1
        next_child = elem(rotated_t, rem(i + 1, n))
        prev_child = elem(rotated_t, rem(i - 1 + n, n))
        neighbor = if links_to_next, do: next_child, else: prev_child

        free? =
          if connect_forward do
            i > connect_idx
          else
            i > 0 and i < connect_idx
          end

        label =
          cond do
            free? -> :free
            i == 0 -> :inner
            links_to_next != connect_forward -> :inner
            true -> :outer
          end

        {base_v, base_match_v} =
          if i == 0 do
            {root_vertex, root_match}
          else
            connector(state, child, neighbor)
          end

        label_edge =
          cond do
            child == connect_child ->
              {labeling_v, labeled_v}

            label == :inner ->
              le_neighbor = if connect_forward, do: next_child, else: prev_child
              connector(state, le_neighbor, child)

            true ->
              nil
          end

        in_blossom =
          Enum.reduce(blossom_vertices(state, child), state.in_blossom, &Map.put(&2, &1, child))

        state = %{
          state
          | in_blossom: in_blossom,
            base: Map.put(state.base, child, base_v),
            blossom_match: put_or_delete(state.blossom_match, child, base_match_v),
            label: Map.put(state.label, child, label),
            forest:
              if(label == :free, do: state.forest, else: Map.put(state.forest, child, label))
        }

        if label_edge do
          %{state | label_edge: Map.put(state.label_edge, child, label_edge)}
        else
          state
        end
      end)

    %{
      state
      | children: Map.delete(state.children, b),
        # The entries naming `b` are exactly its children's (set when `b`
        # was formed, and blossom ids are never reused): dropped by key, not
        # by a walk of every nested blossom's entry.
        parent_of: Map.drop(state.parent_of, children),
        vertices_of: Map.delete(state.vertices_of, b),
        label: Map.delete(state.label, b),
        forest: Map.delete(state.forest, b),
        label_edge: Map.delete(state.label_edge, b),
        dual: Map.delete(state.dual, b)
    }
  end
end

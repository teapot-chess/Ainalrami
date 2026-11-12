defmodule Ainalrami.WeightedMatching do
  @moduledoc """
  Maximum-weight matching in a general graph by the primal-dual blossom
  method: Edmonds' (1965) blossoms, in the integral weighted form Galil's
  1986 survey ("Efficient algorithms for finding maximum matching in
  graphs", ACM Computing Surveys 18(1)) presents, grown one alternating tree
  at a time. Written for this project from the published method; the
  structure below is this module's own.

  ## The linear program it keeps

  Weights are stored doubled (`W = 2w`, after dividing out a common
  factor, see `new/3`), so that every quantity below stays an integer. The
  dual solution is a number `y[v] >= 0` per vertex and `z[B] >= 0` per
  blossom `B` (an odd set of vertices with a near-perfect matching inside
  it, held as a cycle of sub-blossoms), and the REDUCED COST of an edge is

      y[u] + y[v] + sum(z[B] : B holds both u and v) - W(u, v)

  The state between calls always satisfies:

    * every reduced cost is `>= 0` (dual feasibility);
    * every matched edge has reduced cost 0, and so does every edge that
      joins two consecutive sub-blossoms of a blossom;
    * every blossom is full: all its vertices but one (its base) are
      matched inside it.

  After `solve/1` every exposed vertex also has `y = 0`, and those four
  facts together are the LP optimality certificate: the matching is of
  maximum weight. Nothing else is assumed between calls, which is what
  lets `set_weight/4`, `shift_and_set/3`, `install/3` and `scale/2` edit a
  solved state and hand it back for a cheap re-solve.

  ## The search

  A ROOT is an exposed vertex with a positive dual (an exposed blossom's
  base, when it sits in one). `solve/1` first lowers every exposed trivial
  vertex's dual to the least feasible value and pairs exposed vertices
  that are then tight against each other (`settle_exposed/1`), and then
  grows a FOREST: one alternating tree per root, all at once. A tree
  labels top-level blossoms OUTER (the root, and the mates of inner ones)
  or INNER, and the whole forest moves the duals by a common amount `d`:
  outer vertex duals down by `d`, inner up by `d`, outer blossom duals up
  by `2d`, inner down by `2d`. That keeps every tree edge tight and every
  other edge feasible, until one of four things happens:

    * an outer vertex's dual reaches 0: the path from its root to it is
      flipped, leaving that vertex exposed at dual 0 and the root matched;
    * an edge from an outer vertex to a vertex outside the forest becomes
      tight: if that vertex's blossom is exposed the path is augmented,
      otherwise the blossom is labelled inner and its mate's outer;
    * an edge between two outer blossoms becomes tight: in one tree, the
      cycle it closes through their nearest common ancestor becomes a new
      blossom; in two, the path from root to root through it is augmented;
    * an inner blossom's dual reaches 0: it is opened back into its
      sub-blossoms, the path through it relabelled and the rest freed.

  An augmentation or a flip ends the trees it ran through - their roots
  are roots no longer - and the rest of the forest carries on, offering
  afresh for every vertex the ended trees let go.

  Integrality is a parity argument. Every tree edge is tight and every
  weight even, so the outer vertices of one tree share the parity of
  their root's dual, and the outer-outer step `slack / 2` is whole inside
  a tree. Between two trees it is whole only when their roots agree, so a
  forest takes the roots whose dual has the parity of the lowest root's;
  the others are plain exposed vertices to it, which a tree may augment
  into, and grow in a forest of their own once it is done. That is at
  most two forests per solve.

  Duals inside the forest are lazy. A labelled vertex carries `{label, c}`
  with its dual `c - d` (outer) or `c + d` (inner), and every event is
  keyed by the value of `2d` at which it happens - a number fixed when the
  event is offered, since everything it depends on moves at a known rate.
  Events sit in a pairing heap (Fredman, Sedgewick, Sleator and Tarjan
  1986) and are checked against the live state when taken, so a stale one
  is simply dropped.

  An outer blossom offers one event per outside neighbour, not one per
  edge. Its members' duals move together for as long as it stands, so the
  cheapest edge from it into each outside vertex is worked out once and
  kept until the blossom is opened or an edge at one of its vertices
  changes; a large blossom that keeps being reached costs a pass over that
  summary, not over all its members' rows.

  ## Which optimum

  When several matchings have the maximum weight, which one comes back -
  and which duals and blossoms are left for the next call - follows from
  the fixed rules above: roots in vertex order, events by key and then by
  kind (blossom or augmentation, grow, open, floor) and vertex, the
  greedy starts by lowest index. Nothing depends on a map's iteration
  order, so a session of calls is reproducible. It is NOT always the
  optimum the previous implementation (0.58.0 and before) returned on
  ties; the callers' answers were held to that release instead
  (`tools/matching_lockstep.exs` checks optimality call by call;
  `docs/performance.md` has the corpus runs).
  """

  alias Ainalrami.WeightedMatching.Profile

  # Event kinds, in the order ties on the key are taken.
  @shrink 0
  @grow 1
  @open 2
  @floor 3

  # ------------------------------------------------------------------ API

  @doc """
  Maximum-weight matching over vertices `0..n-1`.

  `edges` is `[{i, j, weight}]` with integer weights; zero and negative
  weights are no edge. Returns `%{vertex => partner}` with both directions
  of every matched pair; unmatched vertices are absent.
  """
  def solve(n, _edges) when n <= 1, do: %{}

  def solve(n, edges) do
    n
    |> new(edges)
    |> solve()
    |> elem(1)
  end

  @doc """
  A persistent matcher over vertices `0..n-1`, for a caller that solves one
  graph many times with small edits between solves:

      state = WeightedMatching.new(n, edges)
      {state, matching} = WeightedMatching.solve(state)
      state = WeightedMatching.set_weight(state, u, v, new_w)
      {state, matching} = WeightedMatching.solve(state)

  Options:

    * `:max_weight` - the ceiling every later weight stays under, on the
      caller's scale (default: the heaviest edge given). `set_weight/4`
      resets a vertex's dual to it.
    * `:gcd` - the common factor to divide every weight by (default: the
      weights' own gcd). A caller whose later weights need not share the
      first ones' factor passes `gcd: 1`.
    * `:duals` - initial vertex duals on the doubled scale; they must be
      feasible (`duals[u] + duals[v] >= 2 * w(u, v)`), and the greedy start
      matches only edges where they are tight. Default: each vertex at its
      heaviest edge.
    * `:adjacency` - the rows `%{u => %{v => 2w}}`, already doubled, in
      place of `edges` (which is then ignored); pass `:max_weight` with it.
      `:symmetric` is accepted for compatibility and changes nothing.

  `:duals` and `:adjacency` are on the unreduced scale, so neither combines
  with a `:gcd` above 1.
  """
  def new(n, edges, opts \\ []) do
    if Profile.on?() do
      t0 = System.monotonic_time(:microsecond)
      state = build(n, edges, opts)
      us = System.monotonic_time(:microsecond) - t0
      site = Profile.site()
      Profile.record(:new, site, n, us, profile_info(state))
      Profile.capture({:new, site, n, edges, opts})
      state
    else
      build(n, edges, opts)
    end
  end

  @doc """
  Re-optimise from the current state. Returns `{state, matching}`; the
  state carries the solution forward.
  """
  def solve(state) do
    result =
      if Profile.on?(),
        do: profiled_solve(state),
        else: run(state)

    case Process.get({Ainalrami.Proof, :recording}) do
      nil -> result
      _ -> Ainalrami.Proof.solved(result)
    end
  end

  @doc """
  The vertex `v` is matched to, or `nil` when it is exposed.
  """
  def mate_of(state, v), do: Map.get(state.mate, v)

  @doc """
  The weight of the edge `{u, v}` on the caller's scale, or 0 when there is
  no edge.
  """
  def edge_weight(state, u, v) do
    case state.weight do
      %{^u => %{^v => w2}} -> div(w2 * state.gcd, 2)
      _ -> 0
    end
  end

  @doc """
  Every edge at `u`, as `{neighbour, weight}` on the caller's scale.
  """
  def neighbours(state, u) do
    state.weight
    |> Map.get(u, %{})
    |> Enum.map(fn {v, w2} -> {v, div(w2 * state.gcd, 2)} end)
  end

  @doc """
  Change the weight of `{u, v}` (zero or less removes the edge); the next
  `solve/1` re-optimises from the previous solution.

  Only `u` is touched: it is unmatched, every blossom around it opened, and
  its dual raised to the ceiling, which makes every edge at it feasible
  whatever its new weight. `v` keeps its match, its dual and its blossoms -
  unless it was `u`'s mate, in which case it is now exposed. Every other
  edge keeps its reduced cost, so the state is a valid start for the
  search. A caller rewriting a vertex's whole row therefore passes that
  vertex as `u` throughout, and disturbs two vertices, not the row.

  The weight must be a multiple of the state's gcd and at most its
  ceiling; anything else raises (build a new state).
  """
  def set_weight(state, u, v, w) when u != v do
    w2 = within_ceiling!(state, w, "set_weight")

    state
    |> release(u)
    |> store_weight(u, v, w2)
    |> forget_around([v])
  end

  @doc """
  Fix a pair that is already matched, by deleting every OTHER edge either
  end has. Deleting an edge only relaxes the program and the deleted edges
  are unmatched, so no dual or match moves. `:error` when either end sits
  inside a blossom or the two are not matched to each other; the caller
  then falls back to `set_weight/4`.
  """
  def finalize_pair(state, u, v) when u != v do
    trivial? = top(state, u) == u and top(state, v) == v

    if trivial? and Map.get(state.mate, u) == v and Map.get(state.mate, v) == u do
      near = Map.keys(Map.get(state.weight, u, %{})) ++ Map.keys(Map.get(state.weight, v, %{}))
      state = forget_around(state, near)
      weight = state.weight |> keep_only(u, v) |> keep_only(v, u)
      {:ok, %{state | weight: weight}}
    else
      :error
    end
  end

  @doc """
  Re-weight edges by moving duals instead of releasing anyone.

  `shifts` is `%{vertex => delta}` on the doubled scale (even integers);
  `edges` is `[{u, v, w}]` on the caller's scale. Every vertex touched must
  be its own top-level blossom, or `:error`. The result is `{:ok, state}`
  when, after the shifts and the new weights, every shifted dual is
  non-negative, every matched edge at a shifted vertex and every matched
  listed edge has reduced cost 0, every listed edge is feasible, and every
  edge at a vertex whose dual went down is feasible - so the matching is
  still optimal and a `solve/1` finds nothing to do. Otherwise `:error`,
  and the caller falls back to `set_weight/4`.
  """
  def shift_and_set(state, shifts, edges) do
    check_shift_args!(state, shifts, edges)

    touched =
      Enum.reduce(edges, Map.keys(shifts), fn {u, v, _}, acc -> [u, v | acc] end)

    if Enum.any?(touched, &(top(state, &1) != &1)) do
      :error
    else
      dual = Enum.reduce(shifts, state.dual, fn {v, d}, acc -> Map.update!(acc, v, &(&1 + d)) end)

      state =
        Enum.reduce(edges, %{state | dual: dual}, fn {u, v, w}, acc ->
          store_weight(acc, u, v, scaled!(acc, w, "shift_and_set"))
        end)

      if shift_holds?(state, shifts, edges) do
        if Process.get({Ainalrami.Proof, :recording}) == nil,
          do: {:ok, state},
          else: {:ok, Ainalrami.Proof.shifted(state)}
      else
        :error
      end
    end
  end

  @doc """
  Every vertex's dual with the halves of the blossom duals around it added
  in: `y[v] + sum(z[B] / 2 : B holds v)`, on the doubled scale. Every edge
  is feasible on these alone; a starting point for
  `Ainalrami.MatchCertificate.certify/5`.
  """
  def vertex_duals(state) do
    Map.new(0..(state.n - 1)//1, fn v ->
      {v, Map.fetch!(state.dual, v) + enclosing_halves(state, v, 0)}
    end)
  end

  @doc """
  Replace the solution by a certified one: `mate` the matching, `dual` the
  vertex duals on the doubled scale (0 where absent), no blossoms. The
  caller vouches (`Ainalrami.MatchCertificate.check/5`) that `dual` is
  feasible, tight on `mate`, non-negative, and that at most one exposed
  vertex with an edge has a positive dual.
  """
  def install(state, mate, dual) do
    vertices = 0..(state.n - 1)//1

    %{
      state
      | dual: Map.new(vertices, &{&1, Map.get(dual, &1, 0)}),
        mate: mate,
        in_blossom: Map.new(vertices, &{&1, &1}),
        children: %{},
        parent_of: %{},
        links: %{},
        bases: %{},
        members: %{},
        bcache: %{}
    }
  end

  @doc """
  The same state with every weight multiplied by `k`: weights, every dual
  and the ceiling scaled, nothing else. Feasibility, tightness and fullness
  are all linear, so it stays a valid (and, if it was, optimal) state.
  """
  def scale(state, k) when is_integer(k) and k >= 1 do
    %{
      state
      | weight:
          Map.new(state.weight, fn {u, row} ->
            {u, Map.new(row, fn {v, w2} -> {v, k * w2} end)}
          end),
        dual: Map.new(state.dual, fn {v, y} -> {v, k * y} end),
        max_w: k * state.max_w,
        bcache: %{}
    }
  end

  @doc """
  A solved state's dual solution in the form
  `Ainalrami.MatchCertificate.certify/5` takes with `:family`:
  `{hint, family}`, the vertex duals and, per vertex inside blossoms, its
  enclosing blossoms outermost first with running sums of their duals.

  When exactly one vertex with edges is exposed, the top-level blossom
  around it (if any) is left out of the family and half its dual moved onto
  each of its vertices: the same numbers, read as the certificate's dual
  on the odd set of all vertices with edges.
  """
  def certificate_hint(state) do
    live = live_vertices(state)

    left_out =
      case Enum.reject(live, &is_map_key(state.mate, &1)) do
        [x] ->
          b = top(state, x)
          if b >= state.n, do: b

        _ ->
          nil
      end

    z_out = if left_out, do: Map.get(state.dual, left_out, 0), else: 0

    Enum.reduce(live, {%{}, %{}}, fn v, {hint, family} ->
      chain = enclosing(state, v)

      {inside?, chain} =
        case chain do
          [^left_out | rest] when left_out != nil -> {true, rest}
          _ -> {false, chain}
        end

      y = Map.fetch!(state.dual, v) + if(inside?, do: div(z_out, 2), else: 0)

      family =
        if chain == [],
          do: family,
          else: Map.put(family, v, running_sums(state, chain))

      {Map.put(hint, v, y), family}
    end)
  end

  @doc """
  What the duals say about EVERY maximum-weight matching, for
  `possible_partners/3`: `%{xi:, anc:}`, or `:invalid`.

  A state from `solve/1`, `shift_and_set/3`, `finalize_pair/3` or
  `install/3` holds an optimal dual solution in which every exposed vertex
  sits at one common dual `xi` (0, or after `install/3` the certificate's
  value) that no vertex with edges is below. Complementary slackness then
  holds against every optimal matching: it uses only edges of reduced cost
  0 and covers every vertex whose dual is above `xi`. A state whose
  exposed duals do not have that shape - a released one awaiting a solve -
  is `:invalid`.
  """
  def dual_context(state) do
    live = live_vertices(state)
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
        for v <- 0..(state.n - 1)//1, is_map_key(state.parent_of, v), into: %{} do
          {v, running_sums(state, enclosing(state, v))}
        end

      %{xi: xi, anc: anc}
    else
      :invalid
    end
  end

  @doc """
  The partners `v` can have in a maximum-weight matching - every neighbour
  on an edge of reduced cost 0 - and whether it can be left exposed (its
  dual is at `xi`). A superset of the truth (see `dual_context/1`).
  """
  def possible_partners(state, ctx, v) do
    yv = Map.fetch!(state.dual, v)
    anc = ctx.anc

    tight =
      state.weight
      |> Map.get(v, %{})
      |> Enum.reduce([], fn {u, w2}, acc ->
        if yv + Map.fetch!(state.dual, u) + shared_z(anc, v, u) == w2,
          do: [u | acc],
          else: acc
      end)

    {tight, yv == ctx.xi}
  end

  @doc """
  A solved state's graph, matching and duals, for `Ainalrami.Proof`:
  `weight` the doubled rows, `mate`, `dual` the vertex duals and `blossoms`
  every blossom as `{sorted vertices, z}`, so that an edge's reduced cost
  is `dual[u] + dual[v] + sum(z : a blossom holds both) - w2`.
  """
  def proof_export(state) do
    blossoms =
      state.members
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn b ->
        {Enum.sort(Map.fetch!(state.members, b)), Map.get(state.dual, b, 0)}
      end)

    %{
      n: state.n,
      gcd: state.gcd,
      weight: state.weight,
      mate: state.mate,
      dual: Map.take(state.dual, Enum.to_list(0..(state.n - 1)//1)),
      blossoms: blossoms
    }
  end

  # --------------------------------------------------------- construction

  defp build(n, edges, opts) do
    given = Keyword.get(opts, :duals)
    adjacency = Keyword.get(opts, :adjacency)
    gcd = pick_gcd(edges, Keyword.get(opts, :gcd), given, adjacency)
    rows = adjacency || rows_of(edges, gcd)

    ceiling =
      case Keyword.get(opts, :max_weight) do
        nil -> heaviest(rows)
        w -> 2 * div(w, gcd)
      end

    vertices = 0..(n - 1)//1
    dual = starting_duals(n, rows, given)

    %{
      n: n,
      gcd: gcd,
      max_w: ceiling,
      weight: rows,
      dual: dual,
      mate: greedy_pairs(n, rows, dual),
      # The top-level blossom holding each vertex (the vertex itself when
      # it is in none). Blossoms are numbered from `n` up and never reused.
      in_blossom: Map.new(vertices, &{&1, &1}),
      # Per blossom: its sub-blossoms as a cycle, the base's first.
      children: %{},
      # The blossom directly holding a vertex or blossom.
      parent_of: %{},
      # Per blossom, a tuple: element `i` is the edge `{x, y}` joining
      # sub-blossom `i` (x in it) to sub-blossom `i + 1` (y), cyclically.
      # The odd-numbered ones are matched.
      links: %{},
      # Per blossom: its base vertex, the one not matched inside it.
      bases: %{},
      # Per blossom: every vertex in it.
      members: %{},
      next_blossom_id: n,
      # Per blossom, what its vertices offer outside it (`offers_of/3`),
      # kept while the blossom and the duals inside it stand.
      bcache: %{}
    }
  end

  defp pick_gcd(edges, gcd, given, adjacency) do
    case {gcd, given, adjacency} do
      {nil, nil, nil} ->
        Enum.reduce(edges, 0, fn {_, _, w}, acc ->
          if w > 0, do: Integer.gcd(acc, w), else: acc
        end)
        |> max(1)

      {nil, _, _} ->
        1

      {1, _, _} ->
        1

      {g, nil, nil} when is_integer(g) and g > 1 ->
        Enum.each(edges, fn {i, j, w} ->
          if w > 0 and rem(w, g) != 0 do
            raise ArgumentError,
                  "new/3: gcd: #{g} does not divide the weight #{w} of edge {#{i}, #{j}}"
          end
        end)

        g

      {g, _, _} when is_integer(g) and g > 1 ->
        raise ArgumentError,
              "new/3: gcd: #{g} cannot be combined with :duals or :adjacency, " <>
                "which are on the unreduced scale"
    end
  end

  # Doubled, reduced rows, both directions; a later duplicate of an edge
  # wins, a non-positive weight is skipped.
  defp rows_of(edges, gcd) do
    edges
    |> Enum.reduce(%{}, fn
      {i, j, w}, acc when w > 0 ->
        w2 = 2 * div(w, gcd)

        acc
        |> Map.update(i, [{j, w2}], &[{j, w2} | &1])
        |> Map.update(j, [{i, w2}], &[{i, w2} | &1])

      _, acc ->
        acc
    end)
    |> Map.new(fn {v, half_edges} -> {v, Map.new(:lists.reverse(half_edges))} end)
  end

  defp heaviest(rows) do
    Enum.reduce(rows, 0, fn {_, row}, acc ->
      Enum.reduce(row, acc, fn {_, w2}, acc -> max(acc, w2) end)
    end)
  end

  # Default: every vertex at half its heaviest doubled edge - each edge is
  # then covered from both ends, and an edge is tight exactly when it is
  # the heaviest at both.
  defp starting_duals(n, rows, nil) do
    Map.new(0..(n - 1)//1, fn v ->
      case rows do
        %{^v => row} when map_size(row) > 0 -> {v, max(0, div(:lists.max(Map.values(row)), 2))}
        _ -> {v, 0}
      end
    end)
  end

  defp starting_duals(n, rows, given) do
    dual = Map.new(0..(n - 1)//1, fn v -> {v, Map.get(given, v, 0)} end)

    Enum.each(rows, fn {u, row} ->
      yu = Map.fetch!(dual, u)

      Enum.each(row, fn {v, w2} ->
        if u < v and yu + Map.fetch!(dual, v) < w2 do
          raise ArgumentError,
                "new/3: the given duals are infeasible on edge {#{u}, #{v}}: " <>
                  "#{yu} + #{Map.fetch!(dual, v)} < #{w2}"
        end
      end)
    end)

    dual
  end

  # In vertex order, each unmatched vertex takes its lowest-numbered
  # unmatched neighbour on a tight edge.
  defp greedy_pairs(n, rows, dual) do
    y = 0..(n - 1)//1 |> Enum.map(&Map.fetch!(dual, &1)) |> List.to_tuple()

    Enum.reduce(0..(n - 1)//1, %{}, fn v, mate ->
      case {mate, rows} do
        {%{^v => _}, _} ->
          mate

        {_, %{^v => row}} ->
          case lowest_tight(:maps.to_list(row), elem(y, v), y, mate, nil) do
            nil -> mate
            u -> mate |> Map.put(v, u) |> Map.put(u, v)
          end

        _ ->
          mate
      end
    end)
  end

  defp lowest_tight([], _yv, _y, _mate, best), do: best

  defp lowest_tight([{u, w2} | rest], yv, y, mate, best) do
    if (best == nil or u < best) and not is_map_key(mate, u) and yv + elem(y, u) == w2,
      do: lowest_tight(rest, yv, y, mate, u),
      else: lowest_tight(rest, yv, y, mate, best)
  end

  # ------------------------------------------------------------ the solve

  defp run(st) do
    st = settle_exposed(st)

    st = forests(st)
    st = shed_empty_blossoms(st)
    {st, st.mate}
  end

  defp profiled_solve(state) do
    Process.put(:wm_trees, 0)
    Process.put(:wm_formed, 0)
    Process.put(:wm_opened, 0)
    Process.put(:wm_grown, 0)
    t0 = System.monotonic_time(:microsecond)
    {solved, _} = result = run(state)
    us = System.monotonic_time(:microsecond) - t0

    info =
      Map.merge(profile_info(solved), %{
        stages: Process.get(:wm_trees),
        formed: Process.get(:wm_formed),
        expanded: Process.get(:wm_opened),
        grow: Process.get(:wm_grown)
      })

    site = Profile.site()
    Profile.record(:solve, site, state.n, us, info)
    Profile.capture({:solve, site, state})
    result
  end

  defp profile_info(state) do
    edges = Enum.reduce(state.weight, 0, fn {_, row}, acc -> acc + map_size(row) end)
    bits = if state.max_w > 0, do: length(Integer.digits(state.max_w, 2)), else: 0
    %{edges: div(edges, 2), bits: bits}
  end

  defp count(key, by) do
    if Profile.on?(), do: Process.put(key, Process.get(key, 0) + by)
    :ok
  end

  # Every exposed vertex that is its own blossom gets the least dual that
  # keeps its edges feasible, and is paired with its lowest-numbered exposed
  # trivial neighbour if an edge is then tight. Both moves keep the
  # invariants; they spare a tree each vertex they settle.
  defp settle_exposed(st) do
    Enum.reduce(0..(st.n - 1)//1, st, fn v, st ->
      if top(st, v) == v and not is_map_key(st.mate, v) and Map.fetch!(st.dual, v) > 0 do
        settle(st, v)
      else
        st
      end
    end)
  end

  defp settle(st, v) do
    row = :maps.to_list(Map.get(st.weight, v, %{}))
    need = least_feasible(row, st.dual, 0)
    st = %{st | dual: Map.put(st.dual, v, need)}

    with true <- need > 0,
         u when u != nil <- exposed_tight(row, need, st, nil) do
      pair(st, v, u)
    else
      _ -> st
    end
  end

  defp least_feasible([], _dual, acc), do: acc

  defp least_feasible([{u, w2} | rest], dual, acc) do
    need = w2 - :erlang.map_get(u, dual)
    least_feasible(rest, dual, if(need > acc, do: need, else: acc))
  end

  defp exposed_tight([], _yv, _st, best), do: best

  defp exposed_tight([{u, w2} | rest], yv, st, best) do
    if (best == nil or u < best) and not is_map_key(st.mate, u) and
         :erlang.map_get(u, st.in_blossom) == u and yv + :erlang.map_get(u, st.dual) == w2,
       do: exposed_tight(rest, yv, st, u),
       else: exposed_tight(rest, yv, st, best)
  end

  defp roots(st), do: for(v <- 0..(st.n - 1)//1, root?(st, v), do: v)

  # The base of an exposed top-level blossom, with a positive dual.
  defp root?(st, v) do
    not is_map_key(st.mate, v) and base_of(st, top(st, v)) == v and
      Map.fetch!(st.dual, v) > 0
  end

  # Top-level blossoms whose dual is 0 constrain nothing; opening them
  # between solves keeps the structure the next search inherits small.
  # The matching is held per vertex, so nothing but the structure changes.
  defp shed_empty_blossoms(%{members: members} = st) when map_size(members) == 0, do: st

  defp shed_empty_blossoms(st) do
    st.children
    |> Map.keys()
    |> Enum.reject(&is_map_key(st.parent_of, &1))
    |> Enum.sort()
    |> Enum.reduce(st, &shed_if_empty/2)
  end

  defp shed_if_empty(b, st) do
    if b >= st.n and Map.get(st.dual, b, 0) == 0 do
      kids = Map.fetch!(st.children, b)
      Enum.reduce(kids, unwrap(st, b, 0), &shed_if_empty/2)
    else
      st
    end
  end

  # ------------------------------------------------------------- the forest

  # Every root whose dual has the parity of the lowest root's grows at
  # once, one tree each, all moving by the same `d`. Roots of the other
  # parity wait for the next forest: they are still exposed vertices the
  # first one can augment into, just not trees of it.
  defp forests(st) do
    case roots(st) do
      [] ->
        st

      [r | _] = rs ->
        p = rem(Map.fetch!(st.dual, r), 2)
        forests(grow_forest(st, Enum.filter(rs, &(rem(Map.fetch!(st.dual, &1), 2) == p))))
    end
  end

  defp grow_forest(st, roots) do
    count(:wm_trees, length(roots))

    t = %{
      d: 0,
      heap: nil,
      label: %{},
      owner: %{},
      live: %{},
      zlive: %{},
      entry: %{},
      best: %{},
      alive: length(roots),
      bcache: st.bcache
    }

    t = Enum.reduce(roots, t, fn r, t -> mark_outer(st, t, top(st, r), r) end)
    next_event(st, t)
  end

  defp next_event(st, %{alive: 0} = t) do
    %{st | bcache: Map.filter(t.bcache, fn {b, _} -> is_map_key(st.children, b) end)}
  end

  defp next_event(st, t) do
    if t.heap == nil do
      raise "WeightedMatching: a forest ran out of events with a root still outer"
    end

    {event, heap} = pop(t.heap)
    t = %{t | heap: heap}

    case event do
      {k, @grow, x, s} ->
        if grow_live?(st, t, k, x, s), do: on_grow(st, at(t, k), x, s), else: next_event(st, t)

      {k, @shrink, a, b} ->
        if shrink_live?(st, t, k, a, b),
          do: on_shrink(st, at(t, k), a, b),
          else: next_event(st, t)

      {k, @open, b, _} ->
        if open_live?(t, k, b), do: on_open(st, at(t, k), b), else: next_event(st, t)

      {k, @floor, s, _} ->
        case t.live do
          %{^s => {:out, c}} when 2 * c == k -> on_floor(st, at(t, k), s)
          _ -> next_event(st, t)
        end
    end
  end

  # Advance `d` to the event's key. Keys are whole multiples of 2 by the
  # parity argument in the moduledoc, and never behind `d`; either failing
  # means the invariants are already broken, and saying so beats a wrong
  # matching that looks right.
  defp at(t, k) do
    cond do
      rem(k, 2) != 0 -> raise "WeightedMatching: an event at the odd key #{k}"
      k < 2 * t.d -> raise "WeightedMatching: an event behind the dual step (#{k} < #{2 * t.d})"
      true -> %{t | d: div(k, 2)}
    end
  end

  defp grow_live?(st, t, k, x, s) do
    not is_map_key(t.label, top(st, x)) and
      case t.live do
        %{^s => {:out, c}} ->
          k == 2 * (c + Map.fetch!(st.dual, x) - weight_of(st, s, x))

        _ ->
          false
      end
  end

  defp shrink_live?(st, t, k, a, b) do
    top(st, a) != top(st, b) and
      case t.live do
        %{^a => {:out, ca}, ^b => {:out, cb}} -> k == ca + cb - weight_of(st, a, b)
        _ -> false
      end
  end

  defp open_live?(t, k, b) do
    case {t.label, t.zlive} do
      {%{^b => :inner}, %{^b => {:in, ^k}}} -> true
      _ -> false
    end
  end

  # An outer `s` and a vertex `x` outside the tree are tight.
  defp on_grow(st, t, x, s) do
    count(:wm_grown, 1)
    tx = top(st, x)

    case Map.get(st.mate, base_of(st, tx)) do
      nil ->
        r = owner_of(st, t, s)

        st
        |> rebase(tx, x)
        |> point(x, s)
        |> flip_up(t, s, x)
        |> dissolve(t, [r])

      p ->
        r = owner_of(st, t, s)
        t = mark_inner(st, t, tx, {s, x}, r)
        t = mark_outer(st, t, top(st, p), r)
        next_event(st, t)
    end
  end

  # An outer vertex's dual is 0: flip the path from the root down to it,
  # leaving it exposed.
  defp on_floor(st, t, s) do
    r = owner_of(st, t, s)

    st
    |> flip_up(t, s, nil)
    |> dissolve(t, [r])
  end

  # Two outer blossoms `top(a)`, `top(b)` are tight. In two trees, the
  # path root to root through the edge is augmenting.
  defp on_shrink(st, t, a, b) do
    ra = owner_of(st, t, a)
    rb = owner_of(st, t, b)

    if ra == rb do
      form_blossom(st, t, a, b, ra)
    else
      st
      |> flip_up(t, a, b)
      |> flip_up(t, b, a)
      |> dissolve(t, [ra, rb])
    end
  end

  # The cycle the edge closes through the nearest common ancestor becomes
  # a new blossom.
  defp form_blossom(st, t, a, b, r) do
    count(:wm_formed, 1)
    ta = top(st, a)
    tb = top(st, b)
    apex = nearest_common(st, t, ta, tb, %{})
    a_side = climb(st, t, ta, apex, [])
    b_side = climb(st, t, tb, apex, [])

    kids = [apex | Enum.reverse(Enum.map(a_side, &elem(&1, 0)))] ++ Enum.map(b_side, &elem(&1, 0))

    links =
      Enum.reverse(Enum.map(a_side, &elem(&1, 1))) ++
        [{a, b}] ++ Enum.map(b_side, fn {_, {p, c}} -> {c, p} end)

    id = st.next_blossom_id
    vs = Enum.flat_map(kids, &vertices(st, &1))

    # The sub-blossoms' own duals stop moving now that they are nested.
    {dual, zlive} =
      Enum.reduce(kids, {st.dual, t.zlive}, fn c, {dual, zlive} ->
        case Map.pop(zlive, c) do
          {nil, zlive} -> {dual, zlive}
          {pair, zlive} -> {Map.put(dual, c, z_from(pair, t.d)), zlive}
        end
      end)

    st = %{
      st
      | next_blossom_id: id + 1,
        children: Map.put(st.children, id, kids),
        links: Map.put(st.links, id, List.to_tuple(links)),
        bases: Map.put(st.bases, id, base_of(st, apex)),
        members: Map.put(st.members, id, vs),
        in_blossom: Enum.reduce(vs, st.in_blossom, &Map.put(&2, &1, id)),
        parent_of: Enum.reduce(kids, st.parent_of, &Map.put(&2, &1, id)),
        dual: Map.put(dual, id, 0)
    }

    t = %{
      t
      | label: t.label |> Map.drop(kids) |> Map.put(id, :outer),
        owner: t.owner |> Map.drop(kids) |> Map.put(id, r),
        entry: Map.drop(t.entry, kids),
        zlive: Map.put(zlive, id, {:out, -2 * t.d})
    }

    # The formerly inner vertices turn outer: new duals first, then their
    # rows, so every scan sees the final labels.
    turning =
      Enum.filter(kids, fn c -> match?({:in, _}, Map.get(t.live, hd(vertices(st, c)))) end)

    t =
      Enum.reduce(turning, t, fn c, t ->
        Enum.reduce(vertices(st, c), t, fn v, t ->
          %{t | live: Map.put(t.live, v, {:out, y_of(st, t, v) + t.d})}
        end)
      end)

    t = Enum.reduce(turning, t, &offer_from(st, &2, &1))
    next_event(st, t)
  end

  # An inner blossom's dual is 0: open it.
  defp on_open(st, t, b) do
    count(:wm_opened, 1)
    {s, x} = Map.fetch!(t.entry, b)
    kids = List.to_tuple(Map.fetch!(st.children, b))
    links = Map.fetch!(st.links, b)
    k = tuple_size(kids)
    j = position(kids, child_toward(st, b, x))

    # The even way round from the entered child to the base child: its
    # first link is the matched one.
    path =
      cond do
        j == 0 ->
          [{0, nil}]

        rem(j, 2) == 1 ->
          for m <- j..k//1, do: {rem(m, k), if(m == j, do: nil, else: elem(links, m - 1))}

        true ->
          for m <- j..0//-1 do
            {m, if(m == j, do: nil, else: flip(elem(links, m)))}
          end
      end

    on_path = Map.new(path, fn {m, _} -> {m, true} end)

    # Out of the tree first: the vertices of every child off the path get
    # their dual back as a plain number.
    freed =
      for m <- 0..(k - 1)//1, not is_map_key(on_path, m), v <- vertices(st, elem(kids, m)), do: v

    dual = Enum.reduce(freed, st.dual, fn v, dual -> Map.put(dual, v, y_of(st, t, v)) end)
    st = unwrap(%{st | dual: Map.delete(dual, b)}, b, 0)

    r = Map.fetch!(t.owner, b)

    t = %{
      t
      | label: Map.delete(t.label, b),
        owner: Map.delete(t.owner, b),
        zlive: Map.delete(t.zlive, b),
        entry: Map.delete(t.entry, b),
        live: Map.drop(t.live, freed),
        best: Map.drop(t.best, freed)
    }

    {t, outer_vs} =
      path
      |> Enum.with_index()
      |> Enum.reduce({t, []}, fn {{m, edge}, i}, {t, outer_vs} ->
        c = elem(kids, m)

        if rem(i, 2) == 0 do
          entry = if i == 0, do: {s, x}, else: edge

          t = %{
            t
            | label: Map.put(t.label, c, :inner),
              owner: Map.put(t.owner, c, r),
              entry: Map.put(t.entry, c, entry)
          }

          t = if c >= st.n, do: inner_z(t, c, Map.get(st.dual, c, 0)), else: t
          {t, outer_vs}
        else
          t = %{t | label: Map.put(t.label, c, :outer), owner: Map.put(t.owner, c, r)}

          t =
            if c >= st.n,
              do: %{t | zlive: Map.put(t.zlive, c, {:out, Map.get(st.dual, c, 0) - 2 * t.d})},
              else: t

          vs = vertices(st, c)

          t =
            Enum.reduce(vs, t, fn v, t ->
              %{t | live: Map.put(t.live, v, {:out, y_of(st, t, v) + t.d})}
            end)

          {t, [c | outer_vs]}
        end
      end)

    t = Enum.reduce(outer_vs, t, &offer_from(st, &2, &1))
    t = Enum.reduce(freed, t, &scan_freed(st, &2, &1))
    next_event(st, t)
  end

  # The trees rooted at `roots` are done (their roots are matched now, or
  # flipped to an exposed vertex at dual 0). Their duals are written back,
  # their blossoms left at dual 0 taken apart, and the rest of the forest
  # carries on: every vertex they held is outside it now, so the outer
  # neighbours that remain offer for it afresh, and so do the offers this
  # forest's queue held FROM those vertices, which died with them.
  defp dissolve(st, t, roots) do
    gone = for {b, r} <- t.owner, r in roots, do: b
    vs = Enum.flat_map(gone, &vertices(st, &1))
    freed = Map.new(vs, &{&1, true})

    dual =
      Enum.reduce(vs, st.dual, fn v, dual ->
        Map.put(dual, v, y_from(:erlang.map_get(v, t.live), t.d))
      end)

    dual =
      Enum.reduce(gone, dual, fn b, dual ->
        case t.zlive do
          %{^b => pair} -> Map.put(dual, b, z_from(pair, t.d))
          _ -> dual
        end
      end)

    st = %{st | dual: dual}

    # A blossom left at dual 0 constrains nothing. Taken apart now it
    # costs a few map updates; left whole, the next tree to reach it as
    # inner would have to open it on the spot and rescan everything in it.
    st =
      gone
      |> Enum.filter(&(&1 >= st.n))
      |> Enum.sort()
      |> Enum.reduce(st, &shed_if_empty/2)

    orphans = for {x, {_, s}} <- t.best, is_map_key(freed, s), do: x

    t = %{
      t
      | label: Map.drop(t.label, gone),
        owner: Map.drop(t.owner, gone),
        entry: Map.drop(t.entry, gone),
        zlive: Map.drop(t.zlive, gone),
        live: Map.drop(t.live, vs),
        best: t.best |> Map.drop(vs) |> Map.drop(orphans),
        alive: t.alive - length(roots)
    }

    t =
      if t.alive == 0,
        do: t,
        else: Enum.reduce(Enum.sort(vs ++ orphans), t, &scan_freed(st, &2, &1))

    next_event(st, t)
  end

  # ------------------------------------------------------------ the queue

  # A pairing heap: `nil` or `{event, subheaps}`. Inserting is a single
  # comparison, which matters because a forest offers far more events than
  # it ever takes; taking the least pairs the subheaps up. Events compare
  # as whole tuples, so equal keys still come out in one fixed order.
  defp push(nil, e), do: {e, []}
  defp push(h, e), do: meld({e, []}, h)

  defp pop({e, kids}), do: {e, pair_up(kids)}

  defp meld({a, ka} = ha, {b, kb} = hb) do
    if a <= b, do: {a, [hb | ka]}, else: {b, [ha | kb]}
  end

  defp pair_up([]), do: nil
  defp pair_up([h]), do: h
  defp pair_up([a, b]), do: meld(a, b)
  defp pair_up([a, b | rest]), do: meld(meld(a, b), pair_up(rest))

  # ------------------------------------------------------- labels, offers

  defp mark_outer(st, t, b, r) do
    t = %{t | label: Map.put(t.label, b, :outer), owner: Map.put(t.owner, b, r)}

    t =
      if b >= st.n,
        do: %{t | zlive: Map.put(t.zlive, b, {:out, z_of(st, t, b) - 2 * t.d})},
        else: t

    vs = vertices(st, b)

    t =
      Enum.reduce(vs, t, fn v, t ->
        %{t | live: Map.put(t.live, v, {:out, y_of(st, t, v) + t.d})}
      end)

    offer_from(st, t, b)
  end

  defp mark_inner(st, t, b, entry, r) do
    t = %{
      t
      | label: Map.put(t.label, b, :inner),
        owner: Map.put(t.owner, b, r),
        entry: Map.put(t.entry, b, entry)
    }

    t = if b >= st.n, do: inner_z(t, b, Map.get(st.dual, b, 0)), else: t

    live =
      Enum.reduce(vertices(st, b), t.live, fn v, live ->
        Map.put(live, v, {:in, Map.fetch!(st.dual, v) - t.d})
      end)

    %{t | live: live}
  end

  defp inner_z(t, b, z) do
    c = z + 2 * t.d
    %{t | zlive: Map.put(t.zlive, b, {:in, c}), heap: push(t.heap, {c, @open, b, 0})}
  end

  # A vertex that has just turned outer: its floor event, and every edge
  # in its row offered as whatever event it can become.
  defp scan_outer(st, t, s) do
    %{^s => {:out, c}} = t.live
    row = Map.get(st.weight, s, %{})

    {heap, best} =
      offer_row(
        :maps.to_list(row),
        s,
        top(st, s),
        c,
        st.in_blossom,
        st.dual,
        t.label,
        t.live,
        push(t.heap, {2 * c, @floor, s, 0}),
        t.best
      )

    %{t | heap: heap, best: best}
  end

  # The row is walked with everything it reads and writes held in
  # arguments: a dense row is most of a solve's work, and rebuilding the
  # tree's map once per edge was most of that.
  defp offer_row([], _s, _ts, _c, _top, _dual, _label, _live, heap, best), do: {heap, best}

  defp offer_row([{x, w2} | rest], s, ts, c, top, dual, label, live, heap, best) do
    tx = :erlang.map_get(x, top)

    if tx == ts do
      offer_row(rest, s, ts, c, top, dual, label, live, heap, best)
    else
      case label do
        %{^tx => :outer} ->
          {:out, cx} = :erlang.map_get(x, live)
          ev = if s < x, do: {c + cx - w2, @shrink, s, x}, else: {c + cx - w2, @shrink, x, s}
          offer_row(rest, s, ts, c, top, dual, label, live, push(heap, ev), best)

        %{^tx => :inner} ->
          offer_row(rest, s, ts, c, top, dual, label, live, heap, best)

        _ ->
          k = 2 * (c + :erlang.map_get(x, dual) - w2)

          case best do
            %{^x => b} when b <= {k, s} ->
              offer_row(rest, s, ts, c, top, dual, label, live, heap, best)

            _ ->
              heap = push(heap, {k, @grow, x, s})
              offer_row(rest, s, ts, c, top, dual, label, live, heap, Map.put(best, x, {k, s}))
          end
      end
    end
  end

  # Whatever has just turned outer as a whole (`c`, every vertex of it at
  # `{:out, _}`) offers its edges: a vertex scans its row, a blossom
  # offers from its summary.
  defp offer_from(st, t, c) when c < st.n, do: scan_outer(st, t, c)

  defp offer_from(st, t, b) do
    {{v0, rel, {low, vlow}}, t} = offers_of(st, t, b)
    {:out, c0} = :erlang.map_get(v0, t.live)

    {heap, best} =
      offer_summary(
        :maps.to_list(rel),
        c0,
        top(st, v0),
        st.in_blossom,
        st.dual,
        t.label,
        t.live,
        push(t.heap, {2 * (c0 + low), @floor, vlow, 0}),
        t.best
      )

    %{t | heap: heap, best: best}
  end

  # A blossom's summary: every vertex's dual moves with every other's while
  # the blossom stands, so measured against one member `v0` they keep their
  # differences, and per neighbour `x` outside it only the member with the
  # least `(y[v] - y[v0]) - w(v, x)` can ever be the edge taken into `x`
  # (lowest member on a tie, as the queue orders events); likewise only the
  # member with the least dual can floor first. `{v0, %{x => {rel, v}},
  # {low, v}}`, built from one scan of the rows and reused every time the
  # blossom turns outer again, which on a large field is often: a blossom
  # of a hundred vertices that keeps being reached would otherwise have its
  # whole rows walked each time. Dropped when the blossom is taken apart,
  # when an edge at one of its vertices changes, and on `install/3` and
  # `scale/2`.
  defp offers_of(st, t, b) do
    case t.bcache do
      %{^b => summary} ->
        {summary, t}

      _ ->
        [v0 | _] = vs = vertices(st, b)
        y0 = y_of(st, t, v0)

        {rel, low} =
          Enum.reduce(vs, {%{}, nil}, fn v, {rel, low} ->
            dv = y_of(st, t, v) - y0
            low = if low == nil or {dv, v} < low, do: {dv, v}, else: low
            {least_edges(:maps.to_list(Map.get(st.weight, v, %{})), dv, v, rel), low}
          end)

        summary = {v0, Map.drop(rel, vs), low}
        {summary, %{t | bcache: Map.put(t.bcache, b, summary)}}
    end
  end

  defp least_edges([], _dv, _v, rel), do: rel

  defp least_edges([{x, w2} | rest], dv, v, rel) do
    r = dv - w2

    case rel do
      %{^x => old} when old <= {r, v} -> least_edges(rest, dv, v, rel)
      _ -> least_edges(rest, dv, v, Map.put(rel, x, {r, v}))
    end
  end

  # `offer_row/10` for a summary: the same events, one per neighbour.
  defp offer_summary([], _c0, _tb, _top, _dual, _label, _live, heap, best), do: {heap, best}

  defp offer_summary([{x, {r, v}} | rest], c0, tb, top, dual, label, live, heap, best) do
    tx = :erlang.map_get(x, top)

    if tx == tb do
      offer_summary(rest, c0, tb, top, dual, label, live, heap, best)
    else
      case label do
        %{^tx => :outer} ->
          {:out, cx} = :erlang.map_get(x, live)
          k = c0 + r + cx
          ev = if v < x, do: {k, @shrink, v, x}, else: {k, @shrink, x, v}
          offer_summary(rest, c0, tb, top, dual, label, live, push(heap, ev), best)

        %{^tx => :inner} ->
          offer_summary(rest, c0, tb, top, dual, label, live, heap, best)

        _ ->
          k = 2 * (c0 + r + :erlang.map_get(x, dual))

          case best do
            %{^x => b} when b <= {k, v} ->
              offer_summary(rest, c0, tb, top, dual, label, live, heap, best)

            _ ->
              heap = push(heap, {k, @grow, x, v})
              offer_summary(rest, c0, tb, top, dual, label, live, heap, Map.put(best, x, {k, v}))
          end
      end
    end
  end

  # The summaries of every blossom around any of `vs`, dropped: an edge at
  # one of them is about to change.
  defp forget_around(state, vs) do
    bcache =
      Enum.reduce(vs, state.bcache, fn v, acc ->
        if map_size(acc) == 0, do: acc, else: forget_up(state.parent_of, v, acc)
      end)

    %{state | bcache: bcache}
  end

  defp forget_up(parent_of, v, acc) do
    case parent_of do
      %{^v => b} -> forget_up(parent_of, b, Map.delete(acc, b))
      _ -> acc
    end
  end

  # A vertex just put back outside the tree: of its outer neighbours'
  # edges, the cheapest is offered at its new dual. Only that one could
  # ever be taken, so it is the only one queued. Whichever is shorter is
  # walked, the row or the forest's labelled vertices: late in a forest
  # few trees are left, and a dense row is mostly vertices outside them.
  defp scan_freed(st, t, x) do
    row = Map.get(st.weight, x, %{})

    cheapest =
      if map_size(t.live) < map_size(row),
        do: cheapest_of(:maps.to_list(t.live), row, nil),
        else: cheapest_in(:maps.to_list(row), t.live, nil)

    case cheapest do
      nil -> t
      {k, s} -> offer(t, x, 2 * (k + Map.fetch!(st.dual, x)), s)
    end
  end

  # `cheapest_in/3` from the other side: the labelled vertices, looked up
  # in the row.
  defp cheapest_of([], _row, acc), do: acc

  defp cheapest_of([{s, {:out, c}} | rest], row, acc) do
    case row do
      %{^s => w2} ->
        v = {c - w2, s}
        cheapest_of(rest, row, if(acc == nil or v < acc, do: v, else: acc))

      _ ->
        cheapest_of(rest, row, acc)
    end
  end

  defp cheapest_of([_ | rest], row, acc), do: cheapest_of(rest, row, acc)

  # The least `c - w2` over outer neighbours, with its vertex; lowest
  # vertex on a tie, as the queue would order them.
  defp cheapest_in([], _live, acc), do: acc

  defp cheapest_in([{s, w2} | rest], live, acc) do
    case live do
      %{^s => {:out, c}} ->
        v = {c - w2, s}
        cheapest_in(rest, live, if(acc == nil or v < acc, do: v, else: acc))

      _ ->
        cheapest_in(rest, live, acc)
    end
  end

  # The cheapest way into `x` so far is all the queue needs; a worse offer
  # could only ever be taken after it, and by then `x` is in the tree.
  defp offer(t, x, k, s) do
    case t.best do
      %{^x => best} when best <= {k, s} ->
        t

      _ ->
        %{t | best: Map.put(t.best, x, {k, s}), heap: push(t.heap, {k, @grow, x, s})}
    end
  end

  defp owner_of(st, t, v), do: :erlang.map_get(top(st, v), t.owner)

  defp y_of(st, t, v) do
    case t.live do
      %{^v => pair} -> y_from(pair, t.d)
      _ -> Map.fetch!(st.dual, v)
    end
  end

  defp y_from({:out, c}, d), do: c - d
  defp y_from({:in, c}, d), do: c + d

  defp z_of(st, t, b) do
    case t.zlive do
      %{^b => pair} -> z_from(pair, t.d)
      _ -> Map.get(st.dual, b, 0)
    end
  end

  defp z_from({:out, c}, d), do: c + 2 * d
  defp z_from({:in, c}, d), do: c - 2 * d

  # --------------------------------------------------------- tree walking

  # The outer blossom above outer `o`, or nil at the root.
  defp outer_above(st, t, o) do
    case Map.get(st.mate, base_of(st, o)) do
      nil ->
        nil

      p ->
        {s, _} = Map.fetch!(t.entry, top(st, p))
        top(st, s)
    end
  end

  # Both walks step up one outer blossom at a time, taking turns; the
  # first blossom seen twice is where the paths meet.
  defp nearest_common(_st, _t, nil, nil, _seen),
    do: raise("WeightedMatching: two outer blossoms of one tree share no ancestor")

  defp nearest_common(st, t, nil, b, seen), do: nearest_common(st, t, b, nil, seen)

  defp nearest_common(st, t, a, b, seen) do
    if is_map_key(seen, a),
      do: a,
      else: nearest_common(st, t, b, outer_above(st, t, a), Map.put(seen, a, true))
  end

  # From `x` up to (not including) `stop`: each blossom passed, with the
  # tree edge above it as `{vertex above, vertex in it}`.
  defp climb(_st, _t, stop, stop, acc), do: Enum.reverse(acc)

  defp climb(st, t, x, stop, acc) do
    case Map.fetch!(t.label, x) do
      :outer ->
        b = base_of(st, x)
        p = Map.fetch!(st.mate, b)
        climb(st, t, top(st, p), stop, [{x, {p, b}} | acc])

      :inner ->
        {s, y} = Map.fetch!(t.entry, x)
        climb(st, t, top(st, s), stop, [{x, {s, y}} | acc])
    end
  end

  # `v` (outer) is now matched to `partner` (nil: left exposed). Its
  # blossom is rebased at it, and the tree path above flipped edge by edge
  # up to the root, which ends matched.
  defp flip_up(st, t, v, partner) do
    b = top(st, v)
    above = Map.get(st.mate, base_of(st, b))
    st = rebase(st, b, v)

    st =
      if partner == nil,
        do: %{st | mate: Map.delete(st.mate, v)},
        else: %{st | mate: Map.put(st.mate, v, partner)}

    case above do
      nil ->
        st

      p ->
        inner = top(st, p)
        {s, y} = Map.fetch!(t.entry, inner)

        st
        |> rebase(inner, y)
        |> point(y, s)
        |> flip_up(t, s, y)
    end
  end

  # ------------------------------------------------------------- blossoms

  # Make `v` the base of blossom `b`: the even path round the cycle from
  # the old base child to `v`'s child is flipped, every sub-blossom on it
  # rebased at its new matched link, and the cycle rotated so `v`'s child
  # comes first. Matches outside `b` are not touched; `v`'s own entry is
  # the caller's to set.
  defp rebase(st, b, _v) when b < st.n, do: st

  defp rebase(st, b, v) do
    kids = List.to_tuple(Map.fetch!(st.children, b))
    links = Map.fetch!(st.links, b)
    k = tuple_size(kids)
    i = position(kids, child_toward(st, b, v))
    st = rebase(st, elem(kids, i), v)

    if i == 0 do
      %{st | bases: Map.put(st.bases, b, v)}
    else
      flips = if rem(i, 2) == 0, do: (i - 2)..0//-2, else: (i + 1)..(k - 1)//2

      st =
        Enum.reduce(flips, st, fn m, st ->
          {x, y} = elem(links, m)

          st
          |> rebase(elem(kids, m), x)
          |> rebase(elem(kids, rem(m + 1, k)), y)
          |> pair(x, y)
        end)

      %{
        st
        | children: Map.put(st.children, b, rotate(Tuple.to_list(kids), i)),
          links: Map.put(st.links, b, List.to_tuple(rotate(Tuple.to_list(links), i))),
          bases: Map.put(st.bases, b, v)
      }
    end
  end

  defp rotate(list, i), do: Enum.drop(list, i) ++ Enum.take(list, i)

  # Take blossom `b` apart: its children become top-level, each vertex's
  # dual gains `half` (`z[b] / 2`, which keeps every edge inside `b` at the
  # reduced cost it had). `b` must be top-level.
  defp unwrap(st, b, half) do
    kids = Map.fetch!(st.children, b)

    in_blossom =
      Enum.reduce(kids, st.in_blossom, fn c, acc ->
        Enum.reduce(vertices(st, c), acc, &Map.put(&2, &1, c))
      end)

    dual =
      if half == 0,
        do: st.dual,
        else:
          Enum.reduce(Map.fetch!(st.members, b), st.dual, fn v, d ->
            Map.update!(d, v, &(&1 + half))
          end)

    %{
      st
      | in_blossom: in_blossom,
        dual: Map.delete(dual, b),
        children: Map.delete(st.children, b),
        links: Map.delete(st.links, b),
        bases: Map.delete(st.bases, b),
        members: Map.delete(st.members, b),
        parent_of: Map.drop(st.parent_of, kids),
        bcache: Map.delete(st.bcache, b)
    }
  end

  # `set_weight/4`'s preparation of `u`: exposed, its own blossom, its dual
  # at the ceiling. The blossom around it is cut loose from its mate, rebased
  # at `u` so that every other vertex of it stays matched inside, and peeled
  # one level at a time with its dual handed down; only `u` and the
  # blossom's old mate end up exposed.
  defp release(st, u) do
    b = top(st, u)

    st =
      if b == u do
        unmatch(st, u)
      else
        st = st |> unmatch(base_of(st, b)) |> rebase(b, u)
        peel(%{st | mate: Map.delete(st.mate, u)}, b, u)
      end

    %{st | dual: Map.put(st.dual, u, st.max_w)}
  end

  defp peel(st, b, u) when b == u, do: st

  defp peel(st, b, u) do
    st = unwrap(st, b, div(Map.get(st.dual, b, 0), 2))
    peel(st, top(st, u), u)
  end

  defp unmatch(st, v) do
    case Map.pop(st.mate, v) do
      {nil, _} -> st
      {p, mate} -> %{st | mate: Map.delete(mate, p)}
    end
  end

  defp pair(st, a, b), do: %{st | mate: st.mate |> Map.put(a, b) |> Map.put(b, a)}
  # One direction only: the other end is set by `flip_up/4` as it reaches
  # it, after it has read where that end's blossom was matched before.
  defp point(st, a, b), do: %{st | mate: Map.put(st.mate, a, b)}

  # ------------------------------------------------------------- helpers

  defp top(st, v), do: :erlang.map_get(v, st.in_blossom)

  defp base_of(st, b) when b < st.n, do: b
  defp base_of(st, b), do: Map.fetch!(st.bases, b)

  defp vertices(st, b) when b < st.n, do: [b]
  defp vertices(st, b), do: Map.fetch!(st.members, b)

  defp weight_of(st, u, v), do: st.weight |> Map.fetch!(u) |> Map.fetch!(v)

  # The child of `b` that holds `v`.
  defp child_toward(st, b, v) do
    case Map.fetch!(st.parent_of, v) do
      ^b -> v
      p -> child_toward(st, b, p)
    end
  end

  defp position(tuple, x), do: position(tuple, x, 0)
  defp position(tuple, x, i) when elem(tuple, i) == x, do: i
  defp position(tuple, x, i), do: position(tuple, x, i + 1)

  defp flip({a, b}), do: {b, a}

  defp live_vertices(state), do: for({v, row} <- state.weight, map_size(row) > 0, do: v)

  # The blossoms around `v`, outermost first.
  defp enclosing(state, v), do: enclosing(state, v, [])

  defp enclosing(state, v, acc) do
    case Map.get(state.parent_of, v) do
      nil -> acc
      b -> enclosing(state, b, [b | acc])
    end
  end

  defp running_sums(state, chain) do
    {with_sums, _} =
      Enum.map_reduce(chain, 0, fn b, sum ->
        sum = sum + Map.get(state.dual, b, 0)
        {{b, sum}, sum}
      end)

    with_sums
  end

  defp enclosing_halves(state, v, acc) do
    case Map.get(state.parent_of, v) do
      nil -> acc
      b -> enclosing_halves(state, b, acc + div(Map.get(state.dual, b, 0), 2))
    end
  end

  # The duals of the blossoms holding both `u` and `v`: the running sum at
  # the innermost one their chains share.
  defp shared_z(anc, u, v) do
    case {Map.get(anc, u), Map.get(anc, v)} do
      {nil, _} -> 0
      {_, nil} -> 0
      {cu, cv} -> shared_prefix(cu, cv, 0)
    end
  end

  defp shared_prefix([{b, s} | cu], [{b, _} | cv], _), do: shared_prefix(cu, cv, s)
  defp shared_prefix(_, _, s), do: s

  defp store_weight(state, u, v, 0) do
    weight =
      state.weight
      |> Map.update(u, %{}, &Map.delete(&1, v))
      |> Map.update(v, %{}, &Map.delete(&1, u))

    %{state | weight: weight}
  end

  defp store_weight(state, u, v, w2) do
    weight =
      state.weight
      |> Map.update(u, %{v => w2}, &Map.put(&1, v, w2))
      |> Map.update(v, %{u => w2}, &Map.put(&1, u, w2))

    %{state | weight: weight}
  end

  # Every edge at `keep_v` but the one to `keep` removed, both directions.
  defp keep_only(weight, keep_v, keep) do
    row = Map.get(weight, keep_v, %{})

    weight =
      Enum.reduce(row, weight, fn {u, _}, acc ->
        if u == keep, do: acc, else: Map.update!(acc, u, &Map.delete(&1, keep_v))
      end)

    Map.put(weight, keep_v, Map.take(row, [keep]))
  end

  # A caller's weight on the stored scale: doubled, reduced, 0 for none.
  defp scaled!(state, w, who) do
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

  defp within_ceiling!(state, w, who) do
    w2 = scaled!(state, w, who)

    if w2 > state.max_w do
      raise ArgumentError,
            "#{who}: weight exceeds the initial dual this matcher was built with; " <>
              "build a fresh state"
    end

    w2
  end

  defp shift_holds?(state, shifts, edges) do
    dual = state.dual

    slack = fn u, v, w2 -> :erlang.map_get(u, dual) + :erlang.map_get(v, dual) - w2 end

    matched_tight? = fn v ->
      case Map.get(state.mate, v) do
        nil -> true
        u -> slack.(v, u, state.weight |> Map.get(v, %{}) |> Map.get(u, 0)) == 0
      end
    end

    Enum.all?(shifts, fn {v, _} -> Map.fetch!(dual, v) >= 0 and matched_tight?.(v) end) and
      Enum.all?(edges, fn {u, v, w} ->
        s = slack.(u, v, if(w <= 0, do: 0, else: 2 * div(w, state.gcd)))
        matched? = Map.get(state.mate, u) == v
        s >= 0 and (not matched? or s == 0)
      end) and
      Enum.all?(shifts, fn {v, d} ->
        d >= 0 or
          state.weight
          |> Map.get(v, %{})
          |> Enum.all?(fn {u, w2} -> slack.(v, u, w2) >= 0 end)
      end)
  end

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
end

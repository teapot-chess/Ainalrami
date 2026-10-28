defmodule Ainalrami.MatchCertificate do
  @moduledoc """
  A proof, by linear-programming duality, that a given matching is a
  maximum-weight matching of a graph - and that EVERY maximum-weight
  matching gives a chosen set of vertices (the "window") exactly the
  partners this one gives them.

  `Ainalrami.Pairing` reads a matching only through the partners of its
  bracket and the next score group, and the refinement stages ask the
  round matcher the same questions over and over after small weight
  changes. When the answer to a question can be proved without searching
  for it, the search can be skipped - but only if the proof also shows that
  the answer is the one the search would have produced. The matcher breaks
  ties by the order of its search, so "a maximum-weight matching" is not
  enough; what is proved here is that there is no tie to break where the
  engine looks.

  ## The certificate

  Weights and duals are on the matcher's doubled scale (`w2`). `V` is the
  set of live vertices (those with at least one edge). The certificate is a
  map `y` of vertex duals and the matching `M`, with:

    1. `y[u] + y[v] == w2(u, v)` on every edge of `M`;
    2. `y[u] + y[v] >= w2(u, v)` on every other edge, and
       `y[u] + y[v] >= w2(u, v) + 1` when either end is in the window;
    3. one of
       * nobody in `V` exposed: `y >= 0`, and `xi = 0` below;
       * exactly one `x` in `V` exposed: `0 <= xi <= y[v]` for every `v`
         in `V`, where `xi = y[x]`;
       * several exposed: `y >= 0`, `y[x] == 0` for every exposed `x`, and
         `xi = 0` below;
    4. for every edge `(u, v)` of `M` with `u` in the window: `y[u] >= xi + 1`
       if `v` is not in the window, and `y[u] + y[v] >= 2 * xi + 1` if it is.

  ## Why that is a proof

  Edmonds' matching polytope is `{x >= 0 : x(delta(v)) <= 1 for every v,
  x(E(S)) <= (|S| - 1) / 2 for every odd S}`. Its LP dual has a variable
  `p[v] >= 0` per vertex and `z[S] >= 0` per odd set, with
  `p[u] + p[v] + sum(z[S] : S contains u and v) >= w(u, v)` on every edge.

  In the one-exposed case take `S = V` (odd, since `M` covers all but one of
  its vertices), `z[V] = 2 * xi` and `p = y - xi`; otherwise `z = 0` and
  `p = y`. Condition 3 is exactly `p >= 0, z >= 0`, and the edge
  constraint is `y[u] + y[v] >= w2`, condition 2. So `(p, z)` is dual
  feasible.

  Complementary slackness holds for `M`: every edge of `M` is tight
  (condition 1); every vertex with `p > 0` is covered (an exposed vertex
  has `p = 0` by condition 3); and `z[V] > 0` only when `M` leaves one
  vertex of `V` exposed, i.e. `|M| = (|V| - 1) / 2`. So `M` is optimal, and
  `(p, z)` is an optimal dual.

  Now let `M'` be ANY maximum-weight matching. Complementary slackness holds
  between every optimal primal and every optimal dual solution: every edge
  of `M'` is tight, and every vertex with `p > 0` is covered by `M'`. Take a
  window vertex `u`:

    * If `M` leaves `u` exposed, no edge at `u` is tight (condition 2), so
      `M'` leaves it exposed too.
    * If `M` pairs `u` with `v`, the only tight edge at `u` is `(u, v)`
      (condition 2), so `M'` either pairs `u` with `v` or leaves `u`
      exposed, and the second needs `p[u] = 0`. When `v` is outside the
      window, condition 4 says `p[u] >= 1`. When `v` is inside it, the only
      tight edge at `v` is `(u, v)` as well, so `M'` would have to leave
      both exposed, needing `p[u] = p[v] = 0`, which condition 4
      (`p[u] + p[v] >= 1`) rules out.

  So every maximum-weight matching agrees with `M` on the window. With the
  whole vertex set as the window, `M` is the unique optimum.

  The certificate is CHECKED, edge by edge, by `check/5`; how the duals
  were found (`certify/5`'s search) has no bearing on its validity.

  ## Finding the duals

  The search starts from a `hint`: duals that are (nearly) optimal already
  - a matcher's own duals with its blossoms folded in
  (`WeightedMatching.vertex_duals/1`), or a previous certificate. What the
  hint usually lacks is strictness: an optimal dual from the search leaves
  many edges outside the matching tight. The correction is found on the
  bipartite double cover: every matched vertex `v` gets
  `y[v] = h[v] + (D[v] - D[M(v)]) / 2` for an even integer `D[v]`, which
  keeps every matched edge tight whatever `D` is. An edge `(u, v)` outside
  the matching needs its slack `s = h[u] + h[v] - w2` to become at least
  its margin `d` (2 inside the window, 0 outside), and both
  `D[u] >= D[M(v)] + d - s` and `D[v] >= D[M(u)] + d - s` together
  guarantee it; the lower bounds of conditions 3-4 and the edges to exposed
  vertices are constraints `D[v] >= D[M(v)] + c`. These are difference
  constraints in small integers: an edge whose slack already exceeds any
  correction the search can make is left out, the rest are added lazily
  as they bind, and the least solution is a longest-path computation
  (strongly connected components in topological order, label-correcting
  within each). A correction that outgrows its bound means the
  constraints have a positive cycle - an odd structure the double cover
  cannot express, or a genuine tie in the window - and the caller searches
  as before.
  """

  import Bitwise

  @doc """
  Look for a certificate that `mate` (symmetric, `%{v => u}`) is a
  maximum-weight matching of `weight` (the matcher's rows, `%{u => %{v =>
  w2}}`, symmetric) that every optimum agrees with on the vertices for
  which `window?` is true.

  `hint` is a map of starting duals, one per live vertex. Where the hint is
  not tight on an edge of `mate`, the difference is put on the edge's
  lower-numbered end - which is where every refinement stage of
  `Ainalrami.Pairing` puts its addends.

  Returns `{:ok, %{dual: y, xi: xi, exposed: [x]}}` or `{:error, reason}`.
  """
  def certify(weight, mate, window?, hint, opts \\ []) do
    family = Keyword.get(opts, :family)
    original = weight

    with :ok <- check_matching(weight, mate),
         :ok <- check_family(family, mate) do
      live = live_vertices(weight)
      weight = reduce_by_family(weight, family)
      exposed = Enum.reject(live, &is_map_key(mate, &1))
      matched = Enum.filter(live, &is_map_key(mate, &1))
      h = tight_hint(weight, mate, matched, hint)

      search(weight, mate, window?, live, matched, exposed, h, opts)
      |> prove(original, mate, window?, live, family, opts)
    end
  end

  # A round being pair-proved (`Ainalrami.Proof`) writes every certificate
  # found here down, on the weights it was asked about; the window is listed
  # only when the search was strict on it.
  defp prove({:ok, cert} = ok, weight, mate, window?, live, family, opts) do
    if Ainalrami.Proof.recording?() do
      window =
        if Keyword.get(opts, :strict, true), do: Enum.filter(live, window?), else: []

      Ainalrami.Proof.certified(weight, mate, window, cert, family)
    end

    ok
  end

  defp prove(other, _weight, _mate, _window?, _live, _family, _opts), do: other

  # ## A fixed family of odd sets
  #
  # `opts[:family]`, when given, is `%{v => [{set_id, cumulative_z}]}`: for
  # every vertex inside one or more odd sets, those sets outermost first,
  # each with the sum of the set duals from the outermost down to it. The
  # sets form a laminar family (a matcher's blossoms), their duals `z` are
  # fixed and non-negative, and an edge's constraint becomes
  # `y[u] + y[v] + sum(z[S] : S holds u and v) >= w2(u, v)` - which is the
  # vertex-only problem on the reduced weight `w2 - sum(...)`. The search
  # and the checks run on those reduced weights; `check_family/2` adds the
  # sets' own complementary slackness: a set with `z > 0` holds exactly
  # `(|S| - 1) / 2` edges of the matching. The proof in the moduledoc goes
  # through unchanged with the family's duals added to the dual solution.
  defp reduce_by_family(weight, nil), do: weight

  defp reduce_by_family(weight, anc) do
    Map.new(weight, fn {u, row} ->
      case Map.get(anc, u) do
        nil ->
          {u, row}

        cu ->
          {u,
           Map.new(row, fn {v, w2} ->
             case Map.get(anc, v) do
               nil -> {v, w2}
               cv -> {v, w2 - common_z(cu, cv, 0)}
             end
           end)}
      end
    end)
  end

  defp common_z([{b, s} | cu], [{b, _} | cv], _), do: common_z(cu, cv, s)
  defp common_z(_, _, s), do: s

  defp check_family(nil, _mate), do: :ok

  defp check_family(anc, mate) do
    # Members of each set, and the matching's edges inside it.
    {size, z_of} =
      Enum.reduce(anc, {%{}, %{}}, fn {_v, chain}, acc ->
        {_, acc} =
          Enum.reduce(chain, {0, acc}, fn {b, cum}, {above, {size, z}} ->
            {cum, {Map.update(size, b, 1, &(&1 + 1)), Map.put(z, b, cum - above)}}
          end)

        acc
      end)

    inside =
      Enum.reduce(mate, %{}, fn {u, v}, acc ->
        if u < v do
          shared(Map.get(anc, u, []), Map.get(anc, v, []), [])
          |> Enum.reduce(acc, fn b, acc -> Map.update(acc, b, 1, &(&1 + 1)) end)
        else
          acc
        end
      end)

    ok? =
      Enum.all?(z_of, fn {b, z} ->
        z >= 0 and (z == 0 or 2 * Map.get(inside, b, 0) + 1 == Map.fetch!(size, b))
      end)

    if ok?, do: :ok, else: {:error, :family}
  end

  defp shared([{b, _} | cu], [{b, _} | cv], acc), do: shared(cu, cv, [b | acc])
  defp shared(_, _, acc), do: acc

  # The virtual partner of the one exposed vertex (vertex ids are >= 0).
  @xstar -1

  # Arcs more negative than this are dropped in the first pass; see
  # `search_once/9`.
  @first_cut Bitwise.bsl(1, 160)

  # One exposed vertex `x`: condition 3 (`y[v] >= y[x]` for all `v`) is a
  # perfect matching's dual constraint once `x` is given a virtual partner
  # `x*` joined to every vertex at weight 0 - `y[v] + y[x*] >= 0` with
  # `y[x*] = -y[x]` - which makes `xi` one more unknown of the same
  # difference system instead of a number to guess. Otherwise the exposed
  # vertices' duals are fixed at 0 and their edges are lower bounds.
  defp search(weight, mate, window?, live, matched, exposed, h, opts) do
    margin? = Keyword.get(opts, :strict, true)

    # Strict: first with every vertex but the unmatched one strictly above
    # the floor (then no other vertex can be the one an optimum leaves out,
    # and reads made against these duals need no search); failing that,
    # with only condition 4's window vertices above it.
    if margin? and match?([_], exposed) do
      case search_once(weight, mate, window?, live, matched, exposed, h, opts, true) do
        {:ok, _} = ok ->
          ok

        _ ->
          search_once(weight, mate, window?, live, matched, exposed, h, opts, false)
      end
    else
      window? = if margin?, do: window?, else: fn _ -> false end
      search_once(weight, mate, window?, live, matched, exposed, h, opts, false)
    end
  end

  defp search_once(weight, mate, window?, live, matched, exposed, h, opts, above_floor?) do
    bound = Keyword.get(opts, :bound, 4 * length(matched) + 16)

    {mate2, h2, single?} =
      case exposed do
        [x] ->
          # Above the floor, the search starts the floor one unit lower:
          # the corrections are least solutions from the start, and a start
          # already below every other vertex is what lets them stay there.
          hx = h |> Map.get(x, 0) |> Kernel.-(if above_floor?, do: 1, else: 0) |> max(0)

          {mate |> Map.put(x, @xstar) |> Map.put(@xstar, x),
           h |> Map.put(x, hx) |> Map.put(@xstar, -hx), true}

        _ ->
          {mate, h, false}
      end

    vars = if single?, do: [@xstar, hd(exposed) | matched], else: matched
    exposed_set = if single?, do: MapSet.new(), else: MapSet.new(exposed)

    # Every correction is a longest path over arcs, so it is at most the
    # number of arcs on a path times the longest arc: the bound grows with
    # how far the hint is from feasible, and every arc more negative than it
    # can be left out. One pass keeps every arc above a generous cut and
    # the longest length; the bound then filters the kept arcs (and, in the
    # rare case the cut was not generous enough, a second pass redoes it).
    graph = {weight, mate2, h2, window?, exposed_set, single?, above_floor?}
    cut = @first_cut

    {kept, max_len} =
      Enum.reduce(vars, {[], 0}, fn u, acc ->
        edge_arcs(u, graph, acc, fn {arcs, m}, from, to, len ->
          {if(len < -cut, do: arcs, else: [{from, to, len} | arcs]), max(m, len)}
        end)
      end)

    bound = max(bound, (length(vars) + 2) * max_len)

    arcs =
      if bound <= cut do
        Enum.filter(kept, fn {_, _, len} -> len >= -bound end)
      else
        Enum.reduce(vars, [], fn u, arcs ->
          edge_arcs(u, graph, arcs, fn arcs, from, to, len ->
            add_arc(arcs, from, to, len, bound)
          end)
        end)
      end

    case longest(arcs, vars, bound) do
      {:ok, d} ->
        y = fn v ->
          Map.fetch!(h2, v) + ((Map.fetch!(d, v) - Map.fetch!(d, Map.fetch!(mate2, v))) >>> 1)
        end

        dual = Map.new(matched, &{&1, y.(&1)})

        dual =
          if single?,
            do: Map.put(dual, hd(exposed), y.(hd(exposed))),
            else: Enum.reduce(exposed, dual, &Map.put(&2, &1, 0))

        # `weight` is the reduced one here; the matching was checked on the
        # real weights on the way in.
        verify(weight, mate, window?, dual, live)

      error ->
        error
    end
  end

  # The arcs for vertex `u` of the difference system: its edges to
  # higher-numbered partnered vertices (each edge once), and its lower
  # bound.
  #
  # Every arc goes through `emit.(acc, from, to, length)`: the first pass
  # folds the longest one, the second collects them.
  defp edge_arcs(@xstar, _graph, acc, _emit), do: acc

  defp edge_arcs(u, {weight, mate2, h2, window?, exposed_set, single?, above_floor?}, acc, emit) do
    hu = Map.fetch!(h2, u)
    mu = Map.fetch!(mate2, u)
    win_u? = window?.(u)

    # Lower bounds on y[u] outside the virtual construction: y >= 0, the
    # window cover (condition 4), and edges to exposed vertices.
    acc =
      cond do
        mu == @xstar ->
          # y[x] >= 0.
          emit.(acc, @xstar, u, -2 * hu)

        single? ->
          # y[u] >= y[x] (+1 for condition 4) is the virtual edge (u, x*).
          margin = if above_floor? or (win_u? and not window?.(mu)), do: 1, else: 0
          len = even_ceil(margin - (hu + Map.fetch!(h2, @xstar)))
          acc = emit.(acc, Map.fetch!(mate2, @xstar), u, len)
          emit.(acc, mu, @xstar, len)

        true ->
          base = if win_u? and not window?.(mu), do: 1, else: 0

          lower =
            weight
            |> Map.fetch!(u)
            |> Enum.reduce(base, fn {v, w2}, acc ->
              if MapSet.member?(exposed_set, v) do
                margin = if win_u? or window?.(v), do: 1, else: 0
                max(acc, w2 + margin)
              else
                acc
              end
            end)

          emit.(acc, mu, u, 2 * (lower - hu))
      end

    Enum.reduce(Map.fetch!(weight, u), acc, fn {v, w2}, acc ->
      cond do
        # Each edge once, from its lower end; partnerless vertices are
        # lower bounds above.
        v <= u or v == mu or not is_map_key(mate2, v) ->
          acc

        true ->
          margin = if win_u? or window?.(v), do: 1, else: 0
          len = even_ceil(margin - (hu + Map.fetch!(h2, v) - w2))
          acc = emit.(acc, Map.fetch!(mate2, v), u, len)
          emit.(acc, mu, v, len)
      end
    end)
  end

  # Corrections move in steps of 2 (so that halving them is exact); a
  # constraint's length is rounded up to the step.
  defp even_ceil(n), do: n + (n &&& 1)

  # An arc whose length is below `-bound` can never bind: every correction
  # stays within [0, bound].
  defp add_arc(arcs, _from, _to, len, bound) when len < -bound, do: arcs
  defp add_arc(arcs, from, to, len, _bound), do: [{from, to, len} | arcs]

  # Least D >= 0 with D[to] >= D[from] + len on every arc, or :error when
  # some D exceeds `bound`. Arcs of negative length rarely bind: the solve
  # starts on the non-negative ones and adds any other it finds violated.
  defp longest(arcs, vertices, bound) do
    {active, lazy} = Enum.split_with(arcs, fn {_, _, len} -> len >= 0 end)
    d0 = Map.new(vertices, &{&1, 0})
    longest_rounds(active, lazy, d0, bound, 50)
  end

  defp longest_rounds(_active, _lazy, _d, _bound, 0), do: {:error, :rounds}

  defp longest_rounds(active, lazy, d, bound, rounds_left) do
    case solve_arcs(active, d, bound) do
      {:ok, d} ->
        {violated, lazy} =
          Enum.split_with(lazy, fn {f, t, len} -> Map.fetch!(d, t) < Map.fetch!(d, f) + len end)

        if violated == [],
          do: {:ok, d},
          else: longest_rounds(violated ++ active, lazy, d, bound, rounds_left - 1)

      error ->
        error
    end
  end

  # Components in topological order (Tarjan emits them sinks first, so the
  # list is reversed), a label-correcting pass inside each, then the arcs
  # leaving it, applied once.
  defp solve_arcs(arcs, d, bound) do
    out = Enum.group_by(arcs, &elem(&1, 0), fn {_, t, len} -> {t, len} end)
    comps = sccs(Map.keys(d), out)
    comp_of = for {c, i} <- Enum.with_index(comps), v <- c, into: %{}, do: {v, i}

    Enum.reduce_while(comps, {:ok, d}, fn comp, {:ok, d} ->
      idx = Map.fetch!(comp_of, hd(comp))

      case relax_component(comp, idx, comp_of, out, d, bound) do
        {:ok, d} ->
          d =
            Enum.reduce(comp, d, fn v, d ->
              Enum.reduce(Map.get(out, v, []), d, fn {t, len}, d ->
                if Map.fetch!(comp_of, t) != idx do
                  cand = Map.fetch!(d, v) + len
                  if cand > Map.fetch!(d, t), do: Map.put(d, t, cand), else: d
                else
                  d
                end
              end)
            end)

          if Enum.any?(comp, &(Map.fetch!(d, &1) > bound)),
            do: {:halt, {:error, :bound}},
            else: {:cont, {:ok, d}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, d} ->
        if Enum.any?(d, fn {_, x} -> x > bound end), do: {:error, :bound}, else: {:ok, d}

      error ->
        error
    end
  end

  defp relax_component([_single], _idx, _comp_of, _out, d, _bound), do: {:ok, d}

  # A label-correcting pass inside one component. Each improvement records
  # how many arcs its path has; a path of as many arcs as the component has
  # vertices repeats one, and a repeated vertex on an improving path is a
  # positive cycle - the constraints have no solution, found as soon as it
  # is walked rather than when the values outgrow the bound.
  defp relax_component(comp, idx, comp_of, out, d, bound) do
    queue = :queue.from_list(comp)
    queued = MapSet.new(comp)
    size = length(comp)
    spfa(queue, queued, d, %{}, idx, comp_of, out, bound, size)
  end

  defp spfa(queue, queued, d, hops, idx, comp_of, out, bound, size) do
    case :queue.out(queue) do
      {:empty, _} ->
        {:ok, d}

      {{:value, v}, queue} ->
        queued = MapSet.delete(queued, v)
        dv = Map.fetch!(d, v)
        hv = Map.get(hops, v, 0)

        cond do
          dv > bound ->
            {:error, :bound}

          hv >= size ->
            {:error, :cycle}

          true ->
            {d, hops, queue, queued} =
              Enum.reduce(Map.get(out, v, []), {d, hops, queue, queued}, fn {t, len},
                                                                            {d, h, q, qd} = acc ->
                if Map.fetch!(comp_of, t) == idx and dv + len > Map.fetch!(d, t) do
                  d = Map.put(d, t, dv + len)
                  h = Map.put(h, t, hv + 1)

                  if MapSet.member?(qd, t),
                    do: {d, h, q, qd},
                    else: {d, h, :queue.in(t, q), MapSet.put(qd, t)}
                else
                  acc
                end
              end)

            spfa(queue, queued, d, hops, idx, comp_of, out, bound, size)
        end
    end
  end

  # Tarjan's strongly connected components, iterative. Returns components
  # in reverse topological order of the condensation reversed - i.e.
  # sources first.
  defp sccs(vertices, out) do
    {_, _, _, _, comps} =
      Enum.reduce(vertices, {%{}, %{}, [], 0, []}, fn v, {index, low, stack, next, comps} = acc ->
        if is_map_key(index, v),
          do: acc,
          else: strong(v, out, index, low, stack, next, comps)
      end)

    comps
  end

  defp strong(root, out, index, low, stack, next, comps) do
    index = Map.put(index, root, next)
    low = Map.put(low, root, next)
    frames = [{root, targets(out, root)}]
    walk(frames, out, index, low, [root | stack], MapSet.new([root]), next + 1, comps)
  end

  defp targets(out, v), do: out |> Map.get(v, []) |> Enum.map(&elem(&1, 0))

  defp walk([], _out, index, low, stack, _on, next, comps), do: {index, low, stack, next, comps}

  defp walk([{v, [w | rest]} | frames], out, index, low, stack, on, next, comps) do
    cond do
      not is_map_key(index, w) ->
        index = Map.put(index, w, next)
        low = Map.put(low, w, next)

        walk(
          [{w, targets(out, w)}, {v, rest} | frames],
          out,
          index,
          low,
          [w | stack],
          MapSet.put(on, w),
          next + 1,
          comps
        )

      MapSet.member?(on, w) ->
        low = Map.put(low, v, min(Map.fetch!(low, v), Map.fetch!(index, w)))
        walk([{v, rest} | frames], out, index, low, stack, on, next, comps)

      true ->
        walk([{v, rest} | frames], out, index, low, stack, on, next, comps)
    end
  end

  defp walk([{v, []} | frames], out, index, low, stack, on, next, comps) do
    {low, stack, on, comps} =
      if Map.fetch!(low, v) == Map.fetch!(index, v) do
        {comp, stack} = pop_component(stack, v, [])
        on = Enum.reduce(comp, on, &MapSet.delete(&2, &1))
        {low, stack, on, [comp | comps]}
      else
        {low, stack, on, comps}
      end

    low =
      case frames do
        [{parent, _} | _] ->
          Map.put(low, parent, min(Map.fetch!(low, parent), Map.fetch!(low, v)))

        [] ->
          low
      end

    walk(frames, out, index, low, stack, on, next, comps)
  end

  defp pop_component([v | stack], v, acc), do: {[v | acc], stack}
  defp pop_component([w | stack], v, acc), do: pop_component(stack, v, [w | acc])

  # The hint made tight on every matched edge: the difference goes on the
  # lower-numbered end. Vertices the hint does not mention start at half
  # their matched edge.
  defp tight_hint(weight, mate, matched, hint) do
    hint = hint || %{}

    Enum.reduce(matched, %{}, fn u, acc ->
      v = Map.fetch!(mate, u)

      if u < v do
        w = weight |> Map.fetch!(u) |> Map.fetch!(v)

        {hu, hv} =
          case {Map.get(hint, u), Map.get(hint, v)} do
            {nil, nil} -> {div(w, 2), w - div(w, 2)}
            {nil, hv} -> {w - hv, hv}
            {hu, nil} -> {hu, w - hu}
            {_hu, hv} -> {w - hv, hv}
          end

        acc |> Map.put(u, hu) |> Map.put(v, hv)
      else
        acc
      end
    end)
    |> then(fn h ->
      # Exposed vertices keep the hint's value (the start for xi).
      Enum.reduce(hint, h, fn {v, y}, h -> if is_map_key(h, v), do: h, else: Map.put(h, v, y) end)
    end)
  end

  @doc """
  Check a certificate: conditions 1-4 of the moduledoc over every edge and
  every live vertex of `weight`. `live` may be passed when the caller has
  it; otherwise it is recomputed. Returns `{:ok, %{dual:, xi:, exposed:}}`
  or `{:error, reason}`.
  """
  def check(weight, mate, window?, dual, live \\ nil) do
    with :ok <- check_matching(weight, mate) do
      verify(weight, mate, window?, dual, live || live_vertices(weight))
    end
  end

  defp verify(weight, mate, window?, dual, live) do
    exposed = Enum.reject(live, &is_map_key(mate, &1))

    xi =
      case exposed do
        [x] -> Map.get(dual, x)
        _ -> 0
      end

    with :ok <- check_duals(live, mate, exposed, dual, xi),
         :ok <- check_edges(weight, live, mate, window?, dual),
         :ok <- check_window_cover(mate, window?, dual, xi) do
      {:ok, %{dual: dual, xi: xi, exposed: exposed}}
    end
  end

  defp check_matching(weight, mate) do
    if Enum.all?(mate, fn {u, v} ->
         Map.get(mate, v) == u and match?(%{^u => %{^v => w}} when w > 0, weight)
       end),
       do: :ok,
       else: {:error, :matching}
  end

  defp check_duals(live, mate, exposed, dual, xi) do
    single? = length(exposed) == 1

    ok? =
      is_integer(xi) and xi >= 0 and
        Enum.all?(live, fn v ->
          y = Map.get(dual, v)

          cond do
            not is_integer(y) -> false
            is_map_key(mate, v) -> y >= xi
            single? -> true
            true -> y == 0
          end
        end)

    if ok?, do: :ok, else: {:error, :duals}
  end

  defp check_edges(weight, live, mate, window?, dual) do
    bad =
      Enum.find(live, fn u ->
        yu = Map.fetch!(dual, u)
        mu = Map.get(mate, u)
        wu? = window?.(u)

        weight
        |> Map.fetch!(u)
        |> Enum.any?(fn {v, w2} ->
          cond do
            v < u -> false
            v == mu -> yu + Map.fetch!(dual, v) != w2
            wu? or window?.(v) -> yu + Map.fetch!(dual, v) <= w2
            true -> yu + Map.fetch!(dual, v) < w2
          end
        end)
      end)

    if bad == nil, do: :ok, else: {:error, {:edge, bad}}
  end

  defp check_window_cover(mate, window?, dual, xi) do
    bad =
      Enum.find(mate, fn {u, v} ->
        window?.(u) and
          if window?.(v),
            do: Map.fetch!(dual, u) + Map.fetch!(dual, v) < 2 * xi + 1,
            else: Map.fetch!(dual, u) < xi + 1
      end)

    if bad == nil, do: :ok, else: {:error, {:cover, bad}}
  end

  @doc "Vertices with at least one edge."
  def live_vertices(weight) do
    for {v, row} <- weight, map_size(row) > 0, do: v
  end
end

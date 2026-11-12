# The matcher, held to an earlier release call by call.
#
#   MIX_ENV=test mix run tools/matching_lockstep.exs     # 2,000 random sessions
#   LOCKSTEP_SESSIONS=20000 LOCKSTEP_REF=v0.58.0 MIX_ENV=test mix run tools/matching_lockstep.exs
#   LOCKSTEP_LARGE=1 ...                                  # graphs of up to 400 vertices
#
# This compiles the matcher as it stood at `LOCKSTEP_REF` (default
# `v0.58.0`, the last release of the previous implementation) under another
# module name and drives both through the same random session: `new/3`,
# `solve/1`, `set_weight/4`, `finalize_pair/3`, `shift_and_set/3`,
# `scale/2` and the reads the engine makes. The two are different
# implementations of one specification, so their internal states are not
# compared; each call is held to what the specification says:
#
#   * every `solve/1` and `solve/2` returns a matching of exactly the
#     reference's total weight on the same graph;
#   * the new state after every call that claims optimality (a solve, a
#     finalised pair, a scaling; an accepted shift is certified by the
#     solve after it, since it may leave an exposed dual above 0) carries a valid LP
#     certificate: every reduced cost non-negative and zero on matched
#     edges, every blossom full, no dual negative, every exposed vertex at
#     dual 0 - checked here from `proof_export/1`, not by the module's own
#     code;
#   * `dual_context/1` is valid on it, and `possible_partners/3` lists the
#     held partner, and allows exposure, wherever the matching does;
#   * a scaled solved state solves to the same matching;
#   * `neighbours/2`, `edge_weight/3` and the gcd agree with the reference.
#
# The graphs stay identical on both sides: every edit is applied to both,
# and a finalised pair or an accepted shift (chosen from the new matcher's
# state) is replayed on the reference through `set_weight/4` when the
# reference refuses it, since its matching may differ on ties.
#
# The run also counts how often the two matchings are the same pairs. On
# graphs with several optima they need not be; the engine's own answers are
# held to the reference by the corpus runs (`tools/perf_diff.exs`,
# `bench/scale.exs`), not by this.
#
# Sessions are shaped like the engine's: packed bignum weights with a
# nearness term (the round matcher), six criteria bands at the engine's own
# widths with few distinct values (`:wide`, heavy ties), small plain
# weights, a few weights only (`:ties`), complete graphs with per-vertex
# duals (the bye bootstrap); and batches of edits that release one vertex, a
# row, or everything at once.

ref = System.get_env("LOCKSTEP_REF", "v0.58.0")
sessions = String.to_integer(System.get_env("LOCKSTEP_SESSIONS", "2000"))
seed_from = String.to_integer(System.get_env("LOCKSTEP_SEED_FROM", "1"))

{source, 0} = System.cmd("git", ["show", "#{ref}:lib/ainalrami/weighted_matching.ex"])

source
|> String.replace(
  "defmodule Ainalrami.WeightedMatching do",
  "defmodule Ainalrami.WeightedMatchingReference do"
)
|> Code.compile_string("weighted_matching_reference.ex")

defmodule Lockstep do
  alias Ainalrami.WeightedMatching, as: New
  alias Ainalrami.WeightedMatchingReference, as: Ref

  def check!(true, _where), do: :ok
  def check!(false, where), do: raise("lockstep: #{inspect(where)}")

  defp tally(key), do: Process.put(key, Process.get(key, 0) + 1)

  # Total weight of a matching on a state's current graph (caller's scale).
  defp total(mod, state, matching) do
    Enum.reduce(matching, 0, fn {u, v}, acc ->
      if u < v, do: acc + mod.edge_weight(state, u, v), else: acc
    end)
  end

  defp graph_of(mod, state) do
    for u <- 0..(state.n - 1)//1, {v, w} <- mod.neighbours(state, u), u < v, into: %{} do
      {{u, v}, w}
    end
  end

  # The LP certificate, from the exported solution alone.
  def certified!(state, where) do
    ex = New.proof_export(state)
    mate = ex.mate
    check!(Enum.all?(mate, fn {u, v} -> Map.get(mate, v) == u end), {where, :mate_symmetric})

    zs = Enum.map(ex.blossoms, fn {vs, z} -> {MapSet.new(vs), z} end)
    check!(Enum.all?(zs, fn {_, z} -> z >= 0 end), {where, :negative_z})
    check!(Enum.all?(ex.dual, fn {_, y} -> y >= 0 end), {where, :negative_y})

    for {u, row} <- ex.weight, {v, w2} <- row, u < v do
      common =
        Enum.reduce(zs, 0, fn {s, z}, acc ->
          if MapSet.member?(s, u) and MapSet.member?(s, v), do: acc + z, else: acc
        end)

      rc = Map.fetch!(ex.dual, u) + Map.fetch!(ex.dual, v) + common - w2
      check!(rc >= 0, {where, :infeasible, u, v})
      if Map.get(mate, u) == v, do: check!(rc == 0, {where, :matched_not_tight, u, v})
    end

    for {s, _} <- zs do
      inside = Enum.count(s, fn v -> MapSet.member?(s, Map.get(mate, v)) end)
      check!(inside == MapSet.size(s) - 1, {where, :blossom_not_full})
    end

    for v <- 0..(ex.n - 1)//1, not is_map_key(mate, v) do
      check!(Map.fetch!(ex.dual, v) == 0, {where, :exposed_dual, v})
    end

    ctx = New.dual_context(state)
    check!(ctx != :invalid, {where, :dual_context})

    for v <- 0..(ex.n - 1)//1, map_size(Map.get(ex.weight, v, %{})) > 0 do
      {tight, exposable?} = New.possible_partners(state, ctx, v)

      case Map.get(mate, v) do
        nil -> check!(exposable?, {where, :not_exposable, v})
        u -> check!(u in tight, {where, :partner_not_tight, v})
      end
    end

    :ok
  end

  def solved!(where, a, ma, b, mb) do
    check!(ma == a.mate, {where, :returned_mate})
    check!(total(New, a, ma) == total(Ref, b, mb), {where, :weight})
    certified!(a, where)
    tally(:solves)
    if ma == mb, do: tally(:same_matching)
  end

  def run(seed) do
    :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})

    n =
      if System.get_env("LOCKSTEP_LARGE") == "1",
        do: Enum.random([2, 3, 5, 8, 13, 24, 40, 65, 90, 120, 160, 200, 260, 330, 400]),
        else: Enum.random([2, 3, 4, 5, 6, 8, 11, 16, 24, 40, 65, 90])

    shape = Enum.random([:packed, :wide, :plain, :ties, :complete])
    shape = if shape == :complete and n > 120, do: :wide, else: shape
    {edges, opts, draw} = graph(shape, n)

    if shape != :complete and :rand.uniform(4) == 1 do
      ma = New.solve(n, edges)
      mb = Ref.solve(n, edges)
      w = Map.new(edges, fn {i, j, w} -> {{min(i, j), max(i, j)}, w} end)

      wt = fn m ->
        Enum.reduce(m, 0, fn {u, v}, acc -> if u < v, do: acc + w[{u, v}], else: acc end)
      end

      check!(wt.(ma) == wt.(mb), {seed, :solve2_weight})
      tally(:solves)
      if ma == mb, do: tally(:same_matching)
    end

    a = New.new(n, edges, opts)
    b = Ref.new(n, edges, opts)
    check!(a.gcd == b.gcd and graph_of(New, a) == graph_of(Ref, b), {seed, :new})

    steps = if n > 120, do: Enum.random(4..16), else: Enum.random(4..40)

    Enum.reduce(1..steps, {a, b}, fn step, {a, b} ->
      tally(:calls)
      where = {seed, shape, n, step}

      case op(n) do
        :solve ->
          {a, ma} = New.solve(a)
          {b, mb} = Ref.solve(b)
          solved!(where, a, ma, b, mb)
          {a, b}

        {:edit, batch} ->
          changes = changes(batch, n, draw, a.gcd)

          Enum.reduce(changes, {a, b}, fn {u, v, w}, {a, b} ->
            {New.set_weight(a, u, v, w), Ref.set_weight(b, u, v, w)}
          end)

        :finalize ->
          # Solved first, so the pair is one an optimum holds.
          {a, ma} = New.solve(a)
          {b, mb} = Ref.solve(b)
          solved!({where, :before_finalize}, a, ma, b, mb)

          case Enum.find(Enum.sort(ma), fn {u, v} -> u < v end) do
            nil ->
              {a, b}

            {u, v} ->
              case New.finalize_pair(a, u, v) do
                :error ->
                  {a, b}

                {:ok, a} ->
                  tally(:finalize_ok)
                  certified!(a, {where, :finalize})
                  {a, ref_finalize(b, u, v)}
              end
          end

        :shift ->
          {a, ma} = New.solve(a)
          {b, mb} = Ref.solve(b)
          solved!({where, :before_shift}, a, ma, b, mb)
          vs = Enum.take_random(0..(n - 1)//1, min(n, Enum.random(1..4)))
          shifts = Map.new(vs, &{&1, 2 * Enum.random(-1..3)})

          edges =
            for u <- vs,
                v <- Enum.take_random(0..(n - 1)//1, 2),
                u != v,
                do: {min(u, v), max(u, v), draw.() * a.gcd}

          case New.shift_and_set(a, shifts, edges) do
            :error ->
              tally(:shift_error)
              {a, b}

            {:ok, a} ->
              tally(:shift_ok)
              {a, ref_shift(b, shifts, edges)}
          end

        :read ->
          v = Enum.random(0..(n - 1)//1)
          u = Enum.random(0..(n - 1)//1)

          check!(
            Enum.sort(New.neighbours(a, v)) == Enum.sort(Ref.neighbours(b, v)),
            {where, :neighbours}
          )

          check!(New.edge_weight(a, v, u) == Ref.edge_weight(b, v, u), {where, :edge_weight})
          _ = New.vertex_duals(a)
          _ = New.certificate_hint(a)
          {a, b}

        :scale ->
          k = Enum.random(2..5)
          {a, ma} = New.solve(a)
          {b, mb} = Ref.solve(b)
          solved!({where, :before_scale}, a, ma, b, mb)
          a = New.scale(a, k)
          b = Ref.scale(b, k)
          certified!(a, {where, :scale})
          {a, ma2} = New.solve(a)
          check!(ma2 == ma, {where, :scale_kept_matching})
          {a, b}
      end
    end)

    {:ok, n, shape}
  end

  # The reference's graph brought to what `finalize_pair/3` left the new
  # one: only `{u, v}` at `u` and `v`.
  defp ref_finalize(b, u, v) do
    case Ref.finalize_pair(b, u, v) do
      {:ok, b} ->
        b

      :error ->
        Enum.reduce([{u, v}, {v, u}], b, fn {x, keep}, b ->
          b
          |> Ref.neighbours(x)
          |> Enum.reduce(b, fn {y, _}, b ->
            if y == keep, do: b, else: Ref.set_weight(b, x, y, 0)
          end)
        end)
    end
  end

  defp ref_shift(b, shifts, edges) do
    case Ref.shift_and_set(b, shifts, edges) do
      {:ok, b} -> b
      :error -> Enum.reduce(edges, b, fn {u, v, w}, b -> Ref.set_weight(b, u, v, w) end)
    end
  end

  defp op(n) do
    case :rand.uniform(20) do
      x when x <= 7 -> :solve
      x when x <= 10 -> {:edit, :one}
      x when x <= 12 -> {:edit, :few}
      13 -> {:edit, :row}
      14 -> if n <= 40, do: {:edit, :all}, else: {:edit, :few}
      x when x <= 17 -> :finalize
      18 -> :shift
      19 -> if :rand.uniform(4) == 1, do: :scale, else: :read
      _ -> :read
    end
  end

  # Weight shapes. Every one returns `{edges, new_opts, draw}` where `draw`
  # produces a weight on the same scale for later edits.
  defp graph(:packed, n) do
    # Criteria packed into a bignum band, times the nearness scale, plus a
    # nearness term - the round matcher's `edge_weigher/3` shape.
    band = Integer.pow(n + 1, 12) * 64
    p = n * n + 1
    base = fn -> :rand.uniform(4) * band + :rand.uniform(6) end
    density = if n > 100, do: Enum.random([3, 8, 15, 50]), else: Enum.random([35, 70, 100])

    edges =
      for i <- 0..(n - 2)//1, j <- (i + 1)..(n - 1)//1, :rand.uniform(100) <= density do
        {i, j, base.() * p + n - abs(j - i - div(n, 2))}
      end

    ceiling = 8 * band * p + p

    draw = fn ->
      if :rand.uniform(5) == 1, do: 0, else: base.() * p + :rand.uniform(n)
    end

    {edges, [max_weight: ceiling, gcd: 1], draw}
  end

  defp graph(:wide, n) do
    # The engine's widths: six criteria packed into bands of 24-110 bits
    # each, a few values per criterion (so many edges share a weight and
    # optima tie), times a nearness scale, plus the nearness term.
    bits = Enum.random([24, 40, 64, 110])
    span = Integer.pow(2, bits)
    p = n * n + 1

    base = fn ->
      Enum.reduce(1..6, 0, fn _, acc -> acc * span + Enum.random([0, 1, 1, 2, 3]) end) + 1
    end

    density = if n > 100, do: Enum.random([3, 8, 15, 50]), else: Enum.random([30, 70, 100])

    edges =
      for i <- 0..(n - 2)//1, j <- (i + 1)..(n - 1)//1, :rand.uniform(100) <= density do
        {i, j, base.() * p + n - abs(j - i - div(n, 2))}
      end

    ceiling = 8 * Integer.pow(span, 6) * p + p

    draw = fn ->
      if :rand.uniform(5) == 1, do: 0, else: base.() * p + :rand.uniform(n)
    end

    {edges, [max_weight: ceiling, gcd: 1], draw}
  end

  defp graph(:plain, n) do
    density = if n > 100, do: Enum.random([3, 8, 15, 50]), else: Enum.random([30, 60, 100])

    edges =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          :rand.uniform(100) <= density,
          do: {i, j, :rand.uniform(50)}

    {edges, [max_weight: 60, gcd: 1],
     fn -> if :rand.uniform(5) == 1, do: 0, else: :rand.uniform(50) end}
  end

  defp graph(:ties, n) do
    density = if n > 100, do: Enum.random([3, 8, 15, 50]), else: 70

    edges =
      for i <- 0..(n - 2)//1,
          j <- (i + 1)..(n - 1)//1,
          :rand.uniform(100) <= density,
          do: {i, j, Enum.random([10, 10, 10, 12])}

    {edges, [max_weight: 20, gcd: 1], fn -> Enum.random([0, 10, 10, 12]) end}
  end

  defp graph(:complete, n) do
    # Per-vertex decomposable weights on a complete graph with the duals
    # handed in - `bye_assignee_score_from_field/2`'s bootstrap shape.
    vertex = Map.new(0..(n - 1)//1, &{&1, 2 * :rand.uniform(6)})

    adjacency =
      Map.new(0..(n - 1)//1, fn i ->
        {i,
         Map.new(Enum.reject(0..(n - 1)//1, &(&1 == i)), fn j ->
           {j, Map.fetch!(vertex, i) + Map.fetch!(vertex, j)}
         end)}
      end)

    duals = Map.new(vertex, fn {v, w} -> {v, w} end)
    max = 2 * Enum.max(Map.values(vertex), fn -> 2 end)

    {[], [adjacency: adjacency, duals: duals, max_weight: max],
     fn -> if :rand.uniform(4) == 1, do: 0, else: :rand.uniform(max) end}
  end

  defp changes(:one, n, draw, gcd), do: pairs(1, n, draw, gcd)
  defp changes(:few, n, draw, gcd), do: pairs(Enum.random(2..10), n, draw, gcd)

  defp changes(:row, n, draw, gcd) do
    v = Enum.random(0..(n - 1)//1)
    for u <- 0..(n - 1)//1, u != v, do: {v, u, scale(draw.(), gcd)}
  end

  defp changes(:all, n, draw, gcd) do
    for u <- 0..(n - 2)//1,
        v <- (u + 1)..(n - 1)//1,
        :rand.uniform(3) == 1,
        do: {u, v, scale(draw.(), gcd)}
  end

  defp pairs(k, n, draw, gcd) do
    for _ <- 1..k, n > 1 do
      u = Enum.random(0..(n - 1)//1)
      v = Enum.random(0..(n - 1)//1)
      if u == v, do: nil, else: {u, v, scale(draw.(), gcd)}
    end
    |> Enum.reject(&is_nil/1)
  end

  defp scale(0, _gcd), do: 0
  defp scale(w, gcd), do: max(w - rem(w, gcd), gcd)
end

started = System.monotonic_time(:millisecond)
keys = [:calls, :solves, :same_matching, :finalize_ok, :shift_ok, :shift_error]

results =
  seed_from..(seed_from + sessions - 1)
  |> Task.async_stream(
    fn seed ->
      try do
        r = Lockstep.run(seed)
        {r, Map.new(keys, &{&1, Process.get(&1, 0)})}
      rescue
        e -> {{:failed, seed, Exception.message(e)}, %{}}
      end
    end,
    max_concurrency: System.schedulers_online(),
    timeout: :infinity
  )
  |> Enum.map(fn {:ok, r} -> r end)

failures = for {{:failed, _, _} = f, _} <- results, do: f
passed = for {{:ok, n, shape}, _} <- results, do: {n, shape}

counts =
  Enum.reduce(results, %{}, fn {_, c}, acc -> Map.merge(acc, c, fn _, x, y -> x + y end) end)

by_size =
  passed
  |> Enum.group_by(fn {n, _} ->
    cond do
      n <= 16 -> "2-16"
      n <= 64 -> "17-64"
      n <= 128 -> "65-128"
      true -> "129-400"
    end
  end)
  |> Enum.map(fn {k, v} -> {k, length(v)} end)
  |> Enum.sort()

IO.puts("sessions by vertex count: #{inspect(by_size)}")

IO.puts(
  "sessions by shape: #{inspect(passed |> Enum.frequencies_by(&elem(&1, 1)) |> Enum.sort())}"
)

IO.puts("counts: #{inspect(counts)}")

secs = (System.monotonic_time(:millisecond) - started) / 1000
IO.puts("#{sessions} sessions against #{ref} in #{Float.round(secs, 1)} s")

case failures do
  [] ->
    IO.puts("LOCKSTEP: every solve at the reference's weight, every state certified optimal")

  _ ->
    IO.puts("#{length(failures)} FAILURES")
    for f <- Enum.take(failures, 10), do: IO.puts("  #{inspect(f)}")
    System.halt(1)
end

defmodule Ainalrami.MatchingWalk do
  @moduledoc """
  The persistent matcher behind Burstein's `first_in_order` and Lim's
  pairs walk (`docs/perf-burstein-lim-2026-11.md`, proposal 1), and the
  switch that chooses between it and the walks it replaces.

  Both walks answer the same question many times over: "fix this choice -
  can some maximum-weight matching of the restricted graph still reach the
  optimum `W*`?". The old walks build each restricted graph from the edge
  list and solve it from nothing. Here one `Ainalrami.WeightedMatching`
  state lives for the whole walk, always solved on exactly the graph the
  choices fixed so far leave:

    * a trial drops the edges it forbids (`set_weight/4` to 0, which
      prepares only the trial's own vertices) and re-solves warm; a
      failed trial is simply forgotten - the state is immutable, so the
      one before it is still there;
    * a choice the current matching already makes is locked with
      `finalize_pair/3` (no solve), or by the drop-and-solve path when
      that refuses;
    * before a trial, `possible_partners/3` reads the optimal dual: a
      choice whose edge is not tight is in no maximum-weight matching of
      the current graph, and therefore in none of the restricted one that
      reaches `W*` either (such a matching is also optimal for the current
      graph). It is skipped without a solve.

  The walk's answer is "the first choice, in the article's order, for which
  the restricted graph still reaches `W*`". That depends only on optimum
  VALUES, which a warm and a cold solve agree on, never on which optimum
  the matcher returns.

  ## The switch

  `mode/0` is `:new` (this module), `:old` (the walks as they were) or
  `:check` (both, raising `Ainalrami.MatchingWalk.Mismatch` on any
  difference - the corpus run's mode). Read from, first to last: the
  calling process (`with_mode/2`), the `AINALRAMI_WALK` environment
  variable (`old`, `new`, `check`; so the CLI takes it too), then the
  `:ainalrami, :walk` application setting. The default is `:new` since
  the corpus run recorded in the perf doc; `:old` stays selectable for one
  release.
  """

  alias Ainalrami.WeightedMatching

  @default :old
  @key {__MODULE__, :mode}

  defmodule Mismatch do
    @moduledoc "The old and the new walk answered differently (`:check` mode)."
    defexception [:message]
  end

  @doc "The walk in force for this process: `:old`, `:new` or `:check`."
  def mode do
    case Process.get(@key) do
      nil -> from_env()
      mode -> mode
    end
  end

  defp from_env do
    case System.get_env("AINALRAMI_WALK") do
      "old" -> :old
      "new" -> :new
      "check" -> :check
      _ -> Application.get_env(:ainalrami, :walk, @default)
    end
  end

  @doc "Runs `fun` with the walk `mode` in force in this process."
  def with_mode(mode, fun) when mode in [:old, :new, :check] do
    previous = Process.put(@key, mode)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc """
  In `:check` mode: raises unless `old == new`, naming `what`. Returns
  `old`.
  """
  def same!(what, old, new) do
    if old == new do
      old
    else
      raise Mismatch,
        message:
          "#{what}: the old and the new walk differ\nold: #{inspect(old)}\nnew: #{inspect(new)}"
    end
  end

  @doc """
  A solved matcher over `0..n-1` and `edges`: `{state, weight, perfect?}`.
  The same matcher calls as `WeightedMatching.solve/2`.
  """
  def start(n, edges) do
    {state, mate} = n |> WeightedMatching.new(edges) |> WeightedMatching.solve()
    {state, weight(state, mate), map_size(mate) == n}
  end

  @doc "The weight of `mate` (both directions) on `state`'s edges, on the caller's scale."
  def weight(state, mate) do
    for({i, j} <- mate, i < j, do: WeightedMatching.edge_weight(state, i, j)) |> Enum.sum()
  end

  @doc """
  The vertices `v` can be matched to in some maximum-weight matching of
  `state`'s graph, as a `MapSet` (a superset of the truth), or `nil` when
  `state`'s dual cannot be read (no pruning then).
  """
  def tight(state, v) do
    case WeightedMatching.dual_context(state) do
      :invalid ->
        count(:no_dual)
        nil

      ctx ->
        {partners, _exposable?} = WeightedMatching.possible_partners(state, ctx, v)
        partners = if sabotage?(:prune), do: drop_largest(partners), else: partners
        MapSet.new(partners)
    end
  end

  defp drop_largest([]), do: []
  defp drop_largest(partners), do: List.delete(partners, Enum.max(partners))

  @doc false
  # The corpus run's counters: kept in the calling process only when it
  # asked for them (`stats/0`), so nothing is counted in normal use.
  def count(key) do
    case Process.get({__MODULE__, :stats}) do
      nil -> :ok
      stats -> Process.put({__MODULE__, :stats}, Map.update(stats, key, 1, &(&1 + 1)))
    end
  end

  @doc false
  # Starts counting in this process (`take_stats/0` reads and resets).
  def stats_on, do: Process.put({__MODULE__, :stats}, %{})

  @doc false
  def take_stats do
    stats = Process.get({__MODULE__, :stats}) || %{}
    if Process.get({__MODULE__, :stats}), do: Process.put({__MODULE__, :stats}, %{})
    stats
  end

  @doc false
  # The corpus run's sensitivity arm (the perf doc's proof plan, step 4):
  # a deliberately broken new path, set in the calling process only, to
  # show the comparison can see a difference at all. `:prune` drops one
  # tight partner from every pruning read (a stale dual, in effect);
  # `:floater_check` accepts the relaxed floater split without checking
  # that the rest can be paired with no two floaters meeting - the trap
  # the prototype's review found.
  def sabotage?(kind), do: Process.get({__MODULE__, :sabotage}) == kind

  @doc "The vertex `v` is matched to in `state`, or nil."
  def mate_of(state, v), do: WeightedMatching.mate_of(state, v)

  @doc """
  Drops every edge at `v` whose other end `keep?` refuses. The state is
  prepared at `v` (only) when anything was dropped, and then needs a
  `settle/3` before its matching or duals are read.
  """
  def drop(state, v, keep?) do
    state
    |> WeightedMatching.neighbours(v)
    |> Enum.reduce(state, fn {x, _w}, acc ->
      if keep?.(x), do: acc, else: WeightedMatching.set_weight(acc, v, x, 0)
    end)
  end

  @doc """
  Re-solves `state` warm: `{:ok, state}` when its maximum matching is
  perfect over `n` and weighs `best`, otherwise `:no`.
  """
  def settle(state, n, best) do
    count(:solve)
    {state, mate} = WeightedMatching.solve(state)
    if map_size(mate) == n and weight(state, mate) == best, do: {:ok, state}, else: :no
  end

  @doc """
  Locks the pair `{i, j}`, which `state`'s matching already makes, so that
  neither keeps any other edge. `finalize_pair/3` when it can; otherwise
  the edges are dropped and the state re-solved, which must still reach
  `best` (the matching it held is still there).
  """
  def lock_pair(state, i, j, n, best) do
    case WeightedMatching.finalize_pair(state, i, j) do
      {:ok, state} -> state
      :error -> state |> restrict_pair(i, j) |> settle!(n, best)
    end
  end

  @doc "Drops every edge at `i` and at `j` but `{i, j}` itself (unsolved)."
  def restrict_pair(state, i, j) do
    state
    |> drop(i, &(&1 == j))
    |> drop(j, &(&1 == i))
  end

  @doc "`settle/3` that must succeed: the locked choice was in the matching."
  def settle!(state, n, best) do
    case settle(state, n, best) do
      {:ok, state} -> state
      :no -> raise "matching walk: a locked choice lost the optimum"
    end
  end
end

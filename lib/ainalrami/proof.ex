defmodule Ainalrami.Proof do
  @moduledoc """
  Pairing proofs: a certificate, per round, for every matching question the
  engine answered while pairing it, and for the pairs it then published.

  Asked for with `proof: fun` on `Ainalrami.Pairing.pair_next_round/2` (and
  `--proof=FILE` on the command line). Without the option nothing here runs
  beyond a process-dictionary read per solve, per cardinality question and
  per bracket read, and the pairing is the same either way - the recorder
  reads the matchers' state, it never writes to it except to tag a weighted
  matcher with where it was last written down.

  What a proof proves, what it leaves to trust, and the format are in
  `docs/pairing-proofs.md`; `tools/verify-proof/verify.exs` checks one. A
  round is JSON Lines, one record per line, written as it happens:

    * `"round"` - first: the format, the engine, and the round as published
      (the pairs, or the refusal).
    * `"weighted"` - a weighted matching (`Ainalrami.WeightedMatching`) with
      a dual solution of Edmonds' matching polytope proving it maximum
      (`"solve"`, `"shift"`), or a certified shortcut's claim that also
      fixes some vertices' partners in every optimum (`"window"`).
    * `"cardinality"` - an answer of `Ainalrami.CardinalityMatching` with
      its witness: a maximum matching with a Tutte-Berge barrier, an
      augmenting path, a barrier showing there is none, or the vertices a
      maximum matching can leave exposed with an alternating path to each.
    * `"read"` - pairs a bracket read off a weighted matching: the record,
      the vertices, the players.
    * `"end"` - last: the counts of anything not covered.

  Weights and duals are on the matcher's doubled scale: an edge is
  feasible when `y[u] + y[v] + sum(z[S] : S holds u and v) >= w`. Scaling
  every number by one positive factor changes nothing the checks look at,
  so the matcher's own gcd reduction is left in and reported as `scale`.
  """

  @key {__MODULE__, :recording}
  @format "ainalrami-pairing-proof"
  @version 2
  # A weighted record's graph may be written as changes against one of the
  # records this many ids back, and no further; a cardinality record's
  # against one of the last this-many cardinality graphs. The verifier holds
  # exactly that much, which is what keeps it from holding a round.
  @kept_bases 8
  @kept_plain 4

  @doc "Whether this process is recording a round's proof."
  def recording?, do: Process.get(@key) != nil

  @doc "Whether this process is recording on the reference path."
  def reference?, do: match?(%{mode: :reference}, Process.get(@key))

  @doc """
  Run `fun` with recording on and return `{result, recording}`, where
  `result` is `run/1`'s. `mode` is `:reference` to pair on the reference
  path while recording (see `reference_flag/1`), or `:as_paired`. `round`
  is the `"round"` record's round (players, the published pairs). `emit`,
  when given, is called with each line as it is written (a binary ending in
  a newline); otherwise the lines are kept for `finish/2` to return. A
  nested call records into the outer recording and returns `nil` for it.
  """
  def capture(fun, mode \\ :reference, round \\ %{}, emit \\ nil) do
    if recording?() do
      {run(fun), nil}
    else
      rec =
        %{
          token: make_ref(),
          mode: mode,
          next: 0,
          bases: %{},
          plain: [],
          last: nil,
          events: %{},
          emit: emit,
          lines: []
        }
        |> write(%{
          "type" => "round",
          "format" => @format,
          "version" => @version,
          "engine" => "ainalrami " <> engine_version(),
          "path" => Atom.to_string(mode),
          "round" => round
        })

      Process.put(@key, rec)

      try do
        result = run(fun)
        {result, Process.get(@key)}
      after
        Process.delete(@key)
      end
    end
  end

  @doc """
  Close a recording with its `"end"` record (`extra` merged in). Returns
  the round's text when the lines were kept, `:ok` when they were emitted.
  """
  def finish(rec, extra \\ %{}) do
    rec = write(rec, Map.merge(%{"type" => "end", "uncertified" => rec.events}, extra))
    if rec.emit, do: :ok, else: rec.lines |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp write(rec, map), do: write_encoded(rec, encode(map))

  defp write_encoded(rec, iodata) do
    line = IO.iodata_to_binary([iodata, ?\n])

    case rec.emit do
      nil ->
        %{rec | lines: [line | rec.lines]}

      emit ->
        emit.(line)
        rec
    end
  end

  @doc "`{:ok, fun.()}`, or `{:raised, exception, stacktrace}`."
  def run(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e, __STACKTRACE__}
  end

  @doc """
  The engine switch `name` as the reference path sets it, while a
  reference recording runs; nil otherwise (the environment decides).

  The reference path is the engine with none of its shortcuts: no certified
  shortcuts (`AINALRAMI_CERT=off`), no direct or small brackets
  (`AINALRAMI_DIRECT=off`), and every bracket solved on the whole field
  graph rather than a local one (`AINALRAMI_NOFAST`); round one, too, goes
  through the brackets (`reference?/0`). Every bracket is then decided by
  the refinement stages, each of which reads a weighted matching - which is
  what makes the round provable solve by solve, and the published pairs
  checkable against what the brackets read.
  """
  def reference_flag(name) do
    case Process.get(@key) do
      %{mode: :reference} ->
        case name do
          "AINALRAMI_CERT" -> "off"
          "AINALRAMI_DIRECT" -> "off"
          "AINALRAMI_NOFAST" -> "1"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Count one of the engine's decisions that no certificate covers, by its
  `Ainalrami.Pairing` counter name. A no-op when not recording. On the
  reference path nothing is counted; the shortcuts that count are off.
  """
  def count(key, by \\ 1) do
    case Process.get(@key) do
      nil ->
        :ok

      rec ->
        name = if is_atom(key), do: Atom.to_string(key), else: inspect(key)
        Process.put(@key, %{rec | events: Map.update(rec.events, name, by, &(&1 + by))})
        :ok
    end
  end

  # ------------------------------------------------------------ recording

  @doc false
  # `WeightedMatching.solve/1`'s result, recorded; the state comes back
  # tagged with the record's id so the next solve on it can be written as
  # a change list, and a read of it names the record.
  def solved({state, matching}), do: {recorded(state, "solve"), matching}

  @doc false
  # A state `WeightedMatching.shift_and_set/3` accepted: the matching kept,
  # the duals moved so that it stays optimal under the new weights. The
  # refinement stages read some of these without a solve in between, so
  # they are claims of their own.
  def shifted(state), do: recorded(state, "shift")

  @doc false
  # Pairs a bracket read off a weighted matcher's matching: `pairs` as
  # `{u, v, player_u, player_v}`, `u`/`v` the matcher's vertices. Named by
  # the record the matcher was last written down as; a matcher that never
  # was gets `nil`, which the verifier fails.
  def read(state, pairs) do
    case Process.get(@key) do
      nil ->
        :ok

      rec ->
        solve =
          case is_map(state) and Map.get(state, :proof_ref) do
            {token, id} when token == rec.token -> id
            _ -> nil
          end

        rec =
          write(rec, %{
            "type" => "read",
            "solve" => solve,
            "pairs" => Enum.map(pairs, fn {u, v, a, b} -> [u, v, a, b] end)
          })

        Process.put(@key, rec)
        :ok
    end
  end

  @doc false
  # A `CardinalityMatching` answer and its witness: `adj` the graph (a
  # tuple of neighbour lists), `claim` the record's other fields. A graph
  # given as a function has no size to write down, so that answer is
  # counted instead (never on the reference path, whose graphs are tuples).
  def cardinality(adj, _claim) when is_function(adj, 1), do: count(:cardinality_dense_rows)

  def cardinality(adj, claim) do
    case Process.get(@key) do
      nil ->
        :ok

      rec ->
        id = rec.next

        {graph, plain} =
          case Enum.find(rec.plain, fn {g, _} -> g == adj end) do
            {_, same} ->
              {%{"same" => same}, rec.plain}

            nil ->
              {%{"edges" => plain_edges(adj)}, Enum.take([{adj, id} | rec.plain], @kept_plain)}
          end

        entry =
          Map.merge(claim, %{
            "type" => "cardinality",
            "id" => id,
            "n" => tuple_size(adj),
            "graph" => graph
          })

        rec = write(%{rec | next: id + 1, plain: plain, bases: prune(rec.bases, id)}, entry)
        Process.put(@key, rec)
        :ok
    end
  end

  defp plain_edges(adj) do
    for u <- 0..(tuple_size(adj) - 1)//1,
        v <- adj |> elem(u) |> Enum.uniq() |> Enum.sort(),
        v > u,
        do: [u, v]
  end

  defp prune(bases, id), do: Map.filter(bases, fn {b, _} -> b > id - @kept_bases end)

  defp recorded(state, kind) do
    rec = Process.get(@key)
    export = Ainalrami.WeightedMatching.proof_export(state)
    live = for {v, row} <- export.weight, map_size(row) > 0, do: v
    exposed = Enum.reject(live, &is_map_key(export.mate, &1))

    # The one-exposed shape (`install/3`'s `xi`, see
    # `WeightedMatching.dual_context/1`): the same duals read as `xi` lower
    # on every live vertex and `2 * xi` on the odd set of all of them.
    {duals, sets} =
      case exposed do
        [x] ->
          xi = Map.fetch!(export.dual, x)

          if xi > 0 do
            {Map.new(live, &{&1, Map.fetch!(export.dual, &1) - xi}),
             [{Enum.sort(live), 2 * xi} | export.blossoms]}
          else
            {Map.new(live, &{&1, Map.fetch!(export.dual, &1)}), export.blossoms}
          end

        _ ->
          {Map.new(live, &{&1, Map.fetch!(export.dual, &1)}), export.blossoms}
      end

    {id, rec} =
      record(rec, kind, export.n, export.gcd, export.weight, Map.get(state, :proof_ref), %{
        mate: export.mate,
        duals: duals,
        sets: sets
      })

    Process.put(@key, rec)
    Map.put(state, :proof_ref, {rec.token, id})
  end

  @doc false
  # A certificate `MatchCertificate.certify/5` found: `weight` the rows it
  # was asked about (before any family reduction), `family` its
  # `%{v => [{set, cumulative_z}]}` or nil, `window` the window vertices it
  # was strict on (or `[]`).
  def certified(weight, mate, window, cert, family) do
    rec = Process.get(@key)
    live = for {v, row} <- weight, map_size(row) > 0, do: v
    xi = cert.xi
    single? = match?([_], cert.exposed)

    duals =
      Map.new(live, fn v ->
        y = Map.get(cert.dual, v, 0)
        {v, if(single?, do: y - xi, else: y)}
      end)

    family_sets = family_sets(family)

    sets =
      if single? and xi > 0,
        do: [{Enum.sort(live), 2 * xi} | family_sets],
        else: family_sets

    n = Enum.reduce(live, 0, &max(&1 + 1, &2))

    {_id, rec} =
      record(rec, "window", n, 1, weight, nil, %{
        mate: mate,
        duals: duals,
        sets: sets,
        window: Enum.sort(window)
      })

    Process.put(@key, rec)
    :ok
  end

  # JSON, for the shapes a certificate holds: maps with string keys, lists,
  # integers, strings, booleans and nil. Written out here because
  # `mix.exs` still admits Elixir 1.17, which has no `JSON` module.
  defp encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [encode(to_string(k)), ?:, encode(v)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp encode(list) when is_list(list),
    do: [?[, list |> Enum.map(&encode/1) |> Enum.intersperse(?,), ?]]

  defp encode(n) when is_integer(n), do: Integer.to_string(n)
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(nil), do: "null"

  defp encode(s) when is_binary(s) do
    # Almost every string is a decimal number, which needs no escaping.
    if plain?(s), do: [?", s, ?"], else: [?", escape(s, []), ?"]
  end

  defp plain?(<<>>), do: true

  defp plain?(<<c, rest::binary>>) when c >= 0x20 and c < 0x80 and c != ?" and c != ?\\,
    do: plain?(rest)

  defp plain?(_), do: false

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])

  defp escape(<<c, rest::binary>>, acc) when c < 0x20,
    do: escape(rest, [:io_lib.format("\\u~4.16.0b", [c]) | acc])

  defp escape(<<c::utf8, rest::binary>>, acc), do: escape(rest, [<<c::utf8>> | acc])

  defp escape(<<c, rest::binary>>, acc),
    do: escape(rest, [:io_lib.format("\\u~4.16.0b", [c]) | acc])

  defp engine_version do
    case Application.spec(:ainalrami, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp family_sets(nil), do: []

  defp family_sets(anc) do
    {members, z} =
      Enum.reduce(anc, {%{}, %{}}, fn {v, chain}, acc ->
        {_, acc} =
          Enum.reduce(chain, {0, acc}, fn {b, cum}, {above, {members, z}} ->
            {cum, {Map.update(members, b, [v], &[v | &1]), Map.put(z, b, cum - above)}}
          end)

        acc
      end)

    members
    |> Enum.sort()
    |> Enum.map(fn {b, vs} -> {Enum.sort(vs), Map.fetch!(z, b)} end)
  end

  defp record(rec, kind, n, gcd, weight, ref, body) do
    id = rec.next
    bases = prune(rec.bases, id)
    graph = encode_graph(%{rec | bases: bases}, weight, ref)

    entry =
      %{
        "type" => "weighted",
        "id" => id,
        "kind" => kind,
        "n" => n,
        "scale" => gcd,
        "graph" => graph,
        "matching" =>
          body.mate
          |> Enum.filter(fn {u, v} -> u < v end)
          |> Enum.sort()
          |> Enum.map(fn {u, v} -> [u, v] end),
        "duals" =>
          body.duals
          |> Enum.reject(fn {_, y} -> y == 0 end)
          |> Enum.sort()
          |> Enum.map(fn {v, y} -> [v, Integer.to_string(y)] end),
        "sets" =>
          body.sets
          |> Enum.reject(fn {_, z} -> z == 0 end)
          |> Enum.map(fn {vs, z} -> %{"vertices" => vs, "z" => Integer.to_string(z)} end)
      }
      |> then(fn e ->
        case Map.get(body, :window) do
          nil -> e
          w -> Map.put(e, "window", w)
        end
      end)

    # Written out now, not held: a round on a large field records hundreds
    # of these, and holding them made the recording process's heap, and
    # every collection of it, the largest cost of the proof. Only the last
    # few graphs are kept, to write the next one against.
    rec = write(%{rec | next: id + 1, bases: Map.put(bases, id, weight), last: id}, entry)
    {id, rec}
  end

  # The graph in full, or as the edges changed against an earlier record of
  # this round: the one the state was last recorded as, else the last one
  # recorded. A change list longer than half the graph is not worth
  # the indirection.
  defp encode_graph(rec, weight, ref) do
    tagged =
      case ref do
        {token, id} when token == rec.token -> [id]
        _ -> []
      end

    candidates = Enum.uniq(tagged ++ if(rec.last, do: [rec.last], else: []))
    size = Enum.reduce(weight, 0, fn {_, row}, acc -> acc + map_size(row) end) |> div(2)
    limit = max(16, div(size, 2))

    Enum.find_value(candidates, fn id ->
      with %{^id => base} <- rec.bases,
           {:ok, changes} <- diff(base, weight, limit) do
        %{"base" => id, "set" => changes}
      else
        _ -> nil
      end
    end) || %{"edges" => full_edges(weight)}
  end

  defp full_edges(weight) do
    weight
    |> Enum.sort()
    |> Enum.flat_map(fn {u, row} ->
      row
      |> Enum.filter(fn {v, _} -> v > u end)
      |> Enum.sort()
      |> Enum.map(fn {v, w} -> [u, v, Integer.to_string(w)] end)
    end)
  end

  # Edges `{u, v, w}` (u < v, w = 0 for a removed edge) that turn `base`
  # into `cur`. Rows are compared by identity first: a row the matcher did
  # not touch since the base was recorded is the same term.
  defp diff(base, cur, limit) do
    add = fn item, {list, count} ->
      if count >= limit, do: throw(:too_many), else: {[item | list], count + 1}
    end

    acc =
      Enum.reduce(cur, {[], 0}, fn {u, row}, acc ->
        brow = Map.get(base, u, %{})

        if brow == row do
          acc
        else
          # One walk over the row; the base row is walked only when some of
          # its edges were not met there (an edge removed).
          {acc, seen} =
            :maps.fold(
              fn v, w, {acc, seen} ->
                case brow do
                  %{^v => ^w} -> {acc, seen + 1}
                  %{^v => _} when v > u -> {add.([u, v, Integer.to_string(w)], acc), seen + 1}
                  %{^v => _} -> {acc, seen + 1}
                  _ when v > u -> {add.([u, v, Integer.to_string(w)], acc), seen}
                  _ -> {acc, seen}
                end
              end,
              {acc, 0},
              row
            )

          if seen == map_size(brow) do
            acc
          else
            Enum.reduce(brow, acc, fn {v, _}, acc ->
              if v > u and not is_map_key(row, v), do: add.([u, v, "0"], acc), else: acc
            end)
          end
        end
      end)

    {changes, _} =
      Enum.reduce(base, acc, fn {u, brow}, acc ->
        if is_map_key(cur, u) do
          acc
        else
          Enum.reduce(brow, acc, fn {v, _}, acc ->
            if v > u, do: add.([u, v, "0"], acc), else: acc
          end)
        end
      end)

    {:ok, Enum.sort(changes)}
  catch
    :too_many -> :too_many
  end
end

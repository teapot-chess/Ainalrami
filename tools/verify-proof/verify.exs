# Verifier for Ainalrami pairing proofs.
#
#   elixir tools/verify-proof/verify.exs PROOF_FILE [--summary]   (.jsonl, or gzipped)
#
# Reads a proof (JSON Lines, as written by `ainalrami input.trf -p out.txt
# --proof=PROOF_FILE` or by the library's `:proof` option) one line at a
# time and checks every record in it. Prints, per round, PASS or FAIL with
# the reason for each failing record, and exits 0 when every round passes,
# 1 when any fails, 2 when the file cannot be read as a proof. `--summary`
# prints one line per round.
#
# This file is deliberately self-contained: Elixir's standard library only,
# no code shared with the engine, nothing that knows how the engine found
# its answers. It needs Elixir 1.18 or later (for the built-in JSON module).
# It holds one line at a time plus a bounded window of earlier graphs (see
# "graph" below), so a proof of any length verifies in bounded memory.
#
# ## A round
#
#   {"type": "round", "format": "ainalrami-pairing-proof", "version": 2,
#    "round": {"players": N, "pairs": [[white, black | null], ...]}}
#                                         -- or "refused": "why", pairs null
#   ... "weighted", "cardinality" and "read" records ...
#   {"type": "end", "uncertified": {...}, "agrees": true}
#
# The round passes when every record passes and the published pairs (two
# players, not a bye) are exactly the pairs "read" records read off
# proven-optimal matchings, no player twice. (A refused round publishes
# nothing; its reads are only checked against their matchings.) What that does and does not establish is in docs/pairing-proofs.md;
# in one line: each question the engine asked a matcher is answered
# correctly, and the published pairs are answers it read - which questions
# it asked, and what the weights encode, are the engine's.
#
# ## "weighted": a maximum-weight matching
#
#   {"type": "weighted", "id": I, "kind": "solve" | "shift" | "window",
#    "n": N, "scale": G, "graph": GRAPH, "matching": [[u, v], ...],
#    "duals": [[v, "y"], ...], "sets": [{"vertices": [...], "z": "..."}, ...],
#    "window": [...]}                                 -- optional
#
#   GRAPH = {"edges": [[u, v, "w"], ...]}             -- the whole graph
#         | {"base": J, "set": [[u, v, "w"], ...]}    -- weighted record J's
#                                                        graph, these edges
#                                                        changed ("0" = gone);
#                                                        J > I - 8
#
# Weights and duals are decimal strings: integers of any size. The claim is
# that the matching is a maximum-weight matching of the graph. Edmonds: the
# matchings' convex hull is x >= 0, x(edges at v) <= 1, x(edges inside S)
# <= (|S| - 1) / 2 for odd S; its LP dual is: minimise sum(y) + sum(z[S] *
# (|S| - 1) / 2) with y, z >= 0 and y[u] + y[v] + sum(z[S] : S holds u, v)
# >= w(u, v) on every edge. The checks:
#
#   1. M is a matching of the graph: no vertex twice, every pair an edge.
#   2. y >= 0, z >= 0, every set has an odd number of distinct vertices.
#   3. Every edge has reduced cost rc(u, v) = y[u] + y[v] + sum(z[S] : S
#      holds u and v) - w(u, v) >= 0 (a non-edge has weight 0, and its
#      reduced cost is a sum of non-negative numbers): dual feasible.
#   4. Every edge of M has rc = 0.
#   5. Every vertex with y > 0 is matched.
#   6. Every set with z > 0 holds exactly (|S| - 1) / 2 edges of M.
#
# 1-3 bound every matching's weight by the dual objective (weak duality);
# 4-6 are complementary slackness and make M meet the bound. So no matching
# weighs more than M. Both sides are also computed and compared.
#
# With a "window" the claim is stronger: EVERY maximum-weight matching gives
# each window vertex the partner M gives it (or leaves it exposed):
#
#   7. Every edge NOT in M with an end in the window has rc > 0.
#   8. For every edge (u, v) of M with u in the window: y[u] > 0 if v is
#      outside the window, y[u] + y[v] > 0 if v is inside it.
#
# (Complementary slackness holds between this dual and ANY optimum M',
# which so uses only edges with rc = 0 and covers every vertex with y > 0.)
#
# The same argument classifies every pair of M that a "read" names: the
# pair is FORCED - in every maximum-weight matching of the graph - when one
# end has y > 0 and no other edge with rc = 0. A pair that is not forced
# may be one of several optima; which of them the engine took is its
# tie-break, reported here and not checked.
#
# ## "cardinality": an unweighted matching question
#
#   {"type": "cardinality", "id": I, "claim": CLAIM, "n": N,
#    "graph": {"edges": [[u, v], ...]} | {"same": J},  -- J one of the last 4
#    "dead": [...], "matching": [[u, v], ...], ...}       cardinality graphs
#
# The graph G is the edges among the vertices not "dead", plus the pairs of
# the matching M (which must avoid the dead). odd(X) is the set of
# components of odd size of G less the vertices X. Tutte-Berge: every
# matching leaves at least |odd(X)| - |X| vertices exposed, for any X -
# each odd component keeps a vertex exposed or matched into X. The claims:
#
#   "maximum"       M is a maximum matching. Witness "barrier" X with
#                   (vertices - 2|M|) = |odd(X)| - |X|: the bound, met.
#   "not_exposable" the same, and the deficiency (vertices - 2|M|) is not 1:
#                   no maximum matching leaves exactly one vertex exposed.
#   "exposable"     the vertices some maximum matching leaves exposed are
#                   exactly "exposable". M is maximum with deficiency 1
#                   (barrier X as above) and leaves "root" exposed. Since X
#                   meets the bound, every maximum matching leaves its
#                   exposed vertex inside a component of odd(X); the claim
#                   lists exactly the union of those components; and each
#                   listed vertex v is shown exposable by an even
#                   alternating path from root to v (flip it and v is the
#                   exposed one), walked from v by the "parent" links:
#                   v, M(v), parent(M(v)), M(parent(M(v))), ... root.
#   "augment"       there is an M-augmenting path from "root": "path", from
#                   root (exposed) to an exposed vertex, alternating
#                   non-M / M edges of G, no vertex twice.
#   "blocked"       there is none: no matching of G covers every vertex M
#                   covers and root besides. Witness "barrier" X: more
#                   components of odd(X) lie wholly inside those vertices
#                   than X has members, and each needs one of them.
#
# ## "read": pairs a bracket read off a weighted matching
#
#   {"type": "read", "solve": I, "pairs": [[u, v, player_u, player_v], ...]}
#
# Each (u, v) must be a pair of weighted record I's matching; record I must
# have passed. The players are the engine's name for those vertices.

defmodule VerifyProof do
  @format "ainalrami-pairing-proof"
  @versions [2]
  @kept_bases 8
  @kept_plain 4

  def main(args) do
    {flags, files} = Enum.split_with(args, &String.starts_with?(&1, "--"))
    summary? = "--summary" in flags

    case files do
      [path] ->
        verify_file(path, summary?)

      _ ->
        IO.puts(:stderr, "usage: elixir verify.exs PROOF_FILE [--summary]")
        2
    end
  end

  def verify_file(path, summary?) do
    # `:compressed` reads a gzipped file through gunzip and a plain one as
    # it is.
    case File.open(path, [:read, :binary, :compressed]) do
      {:ok, device} ->
        try do
          rounds = device |> IO.binstream(:line) |> verify_stream(&print(&1, summary?))
          totals(rounds)
        after
          File.close(device)
        end

      {:error, reason} ->
        IO.puts(:stderr, "cannot read #{path}: #{:file.format_error(reason)}")
        2
    end
  end

  @doc """
  Every round in `lines` (an enumerable of lines), each passed to
  `on_round` as it closes; returns the list of round results.
  """
  def verify_stream(lines, on_round \\ fn _ -> :ok end) do
    {done, open} =
      lines
      |> Stream.with_index(1)
      |> Enum.reduce({[], nil}, fn {line, number}, {done, open} ->
        if String.trim(line) == "" do
          {done, open}
        else
          case step(open, line, number) do
            {:open, round} ->
              {done, round}

            {:closed, result, next} ->
              on_round.(result)
              {[result | done], next}
          end
        end
      end)

    done =
      case open do
        nil ->
          done

        round ->
          result = close(fail(round, "the round has no end record"))
          on_round.(result)
          [result | done]
      end

    Enum.reverse(done)
  end

  @doc "The rounds of a proof held as text."
  def verify_text(text), do: text |> String.split("\n") |> verify_stream()

  defp totals(rounds) do
    failed = Enum.count(rounds, &(&1.verdict != :pass))
    records = rounds |> Enum.map(& &1.records) |> Enum.sum()
    unreadable = Enum.count(rounds, & &1.unreadable)

    IO.puts(
      "#{length(rounds)} round(s), #{records} record(s): #{length(rounds) - failed} PASS, " <>
        "#{failed} FAIL"
    )

    cond do
      rounds == [] -> 2
      unreadable > 0 -> 2
      failed > 0 -> 1
      true -> 0
    end
  end

  defp print(r, summary?) do
    verdict = if r.verdict == :pass, do: "PASS", else: "FAIL"
    p = r.pairs

    IO.puts(
      "round at line #{r.line}: #{r.players} player(s), #{r.records} record(s), " <>
        "#{p.published} published pair(s), #{p.read} read off a proven matching, " <>
        "#{p.forced} of them forced - #{verdict}"
    )

    for reason <- Enum.reverse(r.failures), do: IO.puts("  FAIL - #{reason}")

    if r.uncertified != %{} and not summary? do
      text = r.uncertified |> Enum.map_join(", ", fn {k, v} -> "#{k} x#{v}" end)
      IO.puts("  not covered by a certificate (reported, not checked): #{text}")
    end
  end

  # -------------------------------------------------------------- a round

  defp new_round(header, number) do
    round = if is_map(header["round"]), do: header["round"], else: %{}

    %{
      line: number,
      players: Map.get(round, "players", "?"),
      published: Map.get(round, "pairs"),
      refused: Map.get(round, "refused"),
      records: 0,
      failures: [],
      unreadable: false,
      # weighted id => edges, for the next records to build on
      graphs: %{},
      # weighted id => {mate, forced pairs}, for reads
      matchings: %{},
      # [{id, plain graph}], newest first
      plain: [],
      read: %{},
      uncertified: %{}
    }
  end

  defp fail(round, reason), do: %{round | failures: [reason | round.failures]}

  defp step(open, line, number) do
    case JSON.decode(line) do
      {:ok, %{"type" => "round"} = doc} ->
        header_failure =
          cond do
            doc["format"] != @format -> "line #{number}: format is not #{@format}"
            doc["version"] not in @versions -> "line #{number}: unsupported version"
            true -> nil
          end

        round = new_round(doc, number)
        round = if header_failure, do: fail(round, header_failure), else: round

        case open do
          nil -> {:open, round}
          prev -> {:closed, close(fail(prev, "the round has no end record")), round}
        end

      {:ok, %{"type" => type} = doc} when open != nil ->
        case type do
          "end" ->
            uncertified = if is_map(doc["uncertified"]), do: doc["uncertified"], else: %{}
            {:closed, close(%{open | uncertified: uncertified}), nil}

          _ ->
            {:open, record(open, type, doc, number)}
        end

      {:ok, _} ->
        orphan(open, "line #{number}: not a record of a round", number)

      {:error, reason} ->
        orphan(open, "line #{number}: not JSON (#{inspect(reason)})", number)
    end
  end

  defp orphan(nil, reason, number) do
    round = %{new_round(%{}, number) | unreadable: true}
    {:closed, close(fail(round, reason)), nil}
  end

  defp orphan(open, reason, _number), do: {:open, %{fail(open, reason) | unreadable: true}}

  defp close(round) do
    # Every published pair of two players must be one a bracket read off a
    # proven matching. A bye is the player the pairs leave over, and a
    # refused round publishes nothing: neither has a matching to check.
    pairs = if is_list(round.published), do: round.published, else: []

    {round, published, forced} =
      Enum.reduce(pairs, {round, 0, 0}, fn
        [a, b], {round, n, f} when is_integer(a) and is_integer(b) ->
          case Map.fetch(round.read, {min(a, b), max(a, b)}) do
            {:ok, forced?} ->
              {round, n + 1, f + if(forced?, do: 1, else: 0)}

            :error ->
              {fail(round, "published pair (#{a}, #{b}) was not read off a proven matching"),
               n + 1, f}
          end

        [a, nil], acc when is_integer(a) ->
          acc

        other, {round, n, f} ->
          {fail(round, "published pair #{inspect(other)} is malformed"), n, f}
      end)

    read =
      Enum.count(pairs, fn
        [a, b] when is_integer(a) and is_integer(b) ->
          Map.has_key?(round.read, {min(a, b), max(a, b)})

        _ ->
          false
      end)

    # And the other way: on a published round, every pair read off a
    # matching is a published pair, and no player sits at two boards. With
    # the first direction, the boards ARE the pairs read - the reference
    # path's pairing, checked rather than reported (the bye is whoever the
    # boards leave over, the same player on both sides).
    round =
      if is_list(round.published) do
        boards =
          for [a, b] <- pairs, is_integer(b), into: MapSet.new(), do: {min(a, b), max(a, b)}

        seats = pairs |> List.flatten() |> Enum.filter(&is_integer/1)

        round =
          round.read
          |> Map.keys()
          |> Enum.sort()
          |> Enum.reject(&MapSet.member?(boards, &1))
          |> Enum.reduce(round, fn {a, b}, round ->
            fail(round, "read pair (#{a}, #{b}) was not published")
          end)

        if length(seats) == length(Enum.uniq(seats)),
          do: round,
          else: fail(round, "a player is published at two boards")
      else
        round
      end

    Map.merge(round, %{
      verdict: if(round.failures == [], do: :pass, else: :fail),
      pairs: %{published: published, read: read, forced: forced}
    })
  end

  defp record(round, type, doc, number) do
    round = %{round | records: round.records + 1}
    label = "line #{number} (#{type} #{inspect(doc["id"])}#{kind(doc)})"

    try do
      case type do
        "weighted" -> weighted(round, doc, label)
        "cardinality" -> cardinality(round, doc, label)
        "read" -> read(round, doc, label)
        other -> fail(round, "#{label}: unknown record type #{inspect(other)}")
      end
    catch
      {:bad, reason} -> fail(round, "#{label}: malformed: #{reason}")
      {:fail, reason} -> fail(round, "#{label}: #{reason}")
    end
  end

  defp kind(%{"kind" => k}), do: ", " <> to_string(k)
  defp kind(%{"claim" => c}), do: ", " <> to_string(c)
  defp kind(_), do: ""

  # ------------------------------------------------------------ weighted

  defp weighted(round, doc, label) do
    id = doc["id"]
    unless is_integer(id), do: throw({:bad, "id"})
    graphs = Map.filter(round.graphs, fn {b, _} -> b > id - @kept_bases end)

    case weighted_graph(doc["graph"], graphs) do
      {:ok, edges} ->
        round = %{round | graphs: Map.put(graphs, id, edges)}

        case check_weighted(doc, edges) do
          {:ok, info} -> %{round | matchings: Map.put(round.matchings, id, info)}
          {:fail, reason} -> fail(round, "#{label}: #{reason}")
        end

      {:fail, reason} ->
        fail(%{round | graphs: graphs}, "#{label}: #{reason}")
    end
  end

  defp weighted_graph(%{"edges" => list}, _graphs) when is_list(list),
    do: apply_edges(%{}, list, false)

  defp weighted_graph(%{"base" => base, "set" => list}, graphs) when is_list(list) do
    case Map.fetch(graphs, base) do
      {:ok, edges} ->
        apply_edges(edges, list, true)

      :error ->
        {:fail, "base graph #{inspect(base)} is not one of the last #{@kept_bases} records"}
    end
  end

  defp weighted_graph(_, _), do: {:fail, "malformed: no graph"}

  defp apply_edges(edges, list, zero_ok?) do
    Enum.reduce_while(list, {:ok, edges}, fn item, {:ok, acc} ->
      case item do
        [u, v, w] when is_integer(u) and is_integer(v) and u >= 0 and u < v ->
          w = int!(w, "weight")

          cond do
            w > 0 -> {:cont, {:ok, Map.put(acc, {u, v}, w)}}
            w == 0 and zero_ok? -> {:cont, {:ok, Map.delete(acc, {u, v})}}
            true -> {:halt, {:fail, "edge (#{u}, #{v}) has weight #{w}, not positive"}}
          end

        other ->
          {:halt, {:fail, "malformed edge #{inspect(other)}"}}
      end
    end)
  end

  defp check_weighted(doc, edges) do
    n = doc["n"]
    unless is_integer(n) and n >= 0, do: throw({:bad, "n"})

    duals = duals!(doc["duals"], n)
    sets = sets!(doc["sets"], n)
    {mate, pairs} = matching!(doc["matching"], n, MapSet.new())

    # Which sets hold each vertex, for the reduced costs.
    sets_of =
      sets
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{members, _z}, i}, acc ->
        Enum.reduce(members, acc, fn v, acc -> Map.update(acc, v, [i], &[i | &1]) end)
      end)

    set_tuple = List.to_tuple(sets)
    y = fn v -> Map.get(duals, v, 0) end

    rc = fn u, v, w ->
      shared =
        sets_of
        |> Map.get(u, [])
        |> Enum.reduce(0, fn i, acc ->
          {members, z} = elem(set_tuple, i)
          if MapSet.member?(members, v), do: acc + z, else: acc
        end)

      y.(u) + y.(v) + shared - w
    end

    window = window!(doc["window"], n)

    with :ok <- check_vertices(edges, n),
         :ok <- check_pairs_are_edges(pairs, edges),
         {:ok, tight} <- check_edges(edges, mate, rc, window),
         :ok <- check_exposed(duals, mate),
         :ok <- check_sets(sets, pairs),
         :ok <- check_window_pairs(pairs, window, y),
         :ok <- check_objective(pairs, edges, duals, sets) do
      # Forced: one end has y > 0 (so every optimum matches it) and the
      # pair is its only tight edge (so every optimum matches it there).
      forced =
        for {u, v} <- pairs,
            (y.(u) > 0 and Map.get(tight, u) == 1) or (y.(v) > 0 and Map.get(tight, v) == 1),
            into: MapSet.new(),
            do: {u, v}

      {:ok, {mate, forced}}
    end
  end

  defp int!(text, what) when is_binary(text) do
    case Integer.parse(text) do
      {value, ""} -> value
      _ -> throw({:bad, "#{what} #{inspect(text)} is not an integer"})
    end
  end

  defp int!(other, what), do: throw({:bad, "#{what} #{inspect(other)} is not a decimal string"})

  defp vertex!(v, n) when is_integer(v) and v >= 0 and v < n, do: v
  defp vertex!(v, n), do: throw({:bad, "vertex #{inspect(v)} is outside 0..#{n - 1}"})

  defp duals!(nil, _n), do: %{}

  defp duals!(list, n) when is_list(list) do
    Enum.reduce(list, %{}, fn
      [v, y], acc ->
        v = vertex!(v, n)
        y = int!(y, "dual")
        if y < 0, do: throw({:fail, "dual of vertex #{v} is negative (#{y})"})
        if Map.has_key?(acc, v), do: throw({:bad, "vertex #{v} has two duals"})
        Map.put(acc, v, y)

      other, _ ->
        throw({:bad, "dual entry #{inspect(other)}"})
    end)
  end

  defp duals!(_, _), do: throw({:bad, "duals is not a list"})

  defp sets!(nil, _n), do: []

  defp sets!(list, n) when is_list(list) do
    Enum.map(list, fn
      %{"vertices" => vs, "z" => z} when is_list(vs) ->
        vs = Enum.map(vs, &vertex!(&1, n))
        members = MapSet.new(vs)
        z = int!(z, "set dual")

        cond do
          MapSet.size(members) != length(vs) -> throw({:bad, "a set lists a vertex twice"})
          rem(length(vs), 2) != 1 -> throw({:fail, "a set has an even number of vertices"})
          z < 0 -> throw({:fail, "a set dual is negative (#{z})"})
          true -> {members, z}
        end

      other ->
        throw({:bad, "set entry #{inspect(other)}"})
    end)
  end

  defp sets!(_, _), do: throw({:bad, "sets is not a list"})

  # {mate, pairs as {low, high}}; no vertex twice, none of `dead`.
  defp matching!(list, n, dead) when is_list(list) do
    Enum.reduce(list, {%{}, []}, fn
      [u, v], {mate, pairs} ->
        u = vertex!(u, n)
        v = vertex!(v, n)
        if u == v, do: throw({:fail, "vertex #{u} is matched to itself"})

        if Map.has_key?(mate, u) or Map.has_key?(mate, v),
          do: throw({:fail, "a vertex of (#{u}, #{v}) is matched twice"})

        if MapSet.member?(dead, u) or MapSet.member?(dead, v),
          do: throw({:fail, "matched pair (#{u}, #{v}) has a dead vertex"})

        {mate |> Map.put(u, v) |> Map.put(v, u), [{min(u, v), max(u, v)} | pairs]}

      other, _ ->
        throw({:bad, "matching entry #{inspect(other)}"})
    end)
  end

  defp matching!(_, _, _), do: throw({:bad, "matching is not a list"})

  defp window!(nil, _n), do: MapSet.new()
  defp window!(list, n) when is_list(list), do: MapSet.new(list, &vertex!(&1, n))
  defp window!(_, _), do: throw({:bad, "window is not a list"})

  defp check_vertices(edges, n) do
    case Enum.find(edges, fn {{_u, v}, _} -> v >= n end) do
      nil -> :ok
      {{u, v}, _} -> {:fail, "edge (#{u}, #{v}) has a vertex outside 0..#{n - 1}"}
    end
  end

  defp check_pairs_are_edges(pairs, edges) do
    case Enum.find(pairs, &(not Map.has_key?(edges, &1))) do
      nil -> :ok
      {u, v} -> {:fail, "matched pair (#{u}, #{v}) is not an edge of the graph"}
    end
  end

  # :ok with the number of tight edges at each vertex, or the first failure.
  defp check_edges(edges, mate, rc, window) do
    Enum.reduce_while(edges, {:ok, %{}}, fn {{u, v}, w}, {:ok, tight} ->
      r = rc.(u, v, w)
      matched? = Map.get(mate, u) == v

      cond do
        r < 0 ->
          {:halt, {:fail, "edge (#{u}, #{v}) violates its dual constraint: reduced cost #{r}"}}

        matched? and r != 0 ->
          {:halt, {:fail, "matched edge (#{u}, #{v}) is not tight: reduced cost #{r}"}}

        not matched? and r == 0 and
            (MapSet.member?(window, u) or MapSet.member?(window, v)) ->
          {:halt,
           {:fail,
            "edge (#{u}, #{v}) at a window vertex is tight but unmatched: " <>
              "another optimum could use it"}}

        r == 0 ->
          tight = tight |> Map.update(u, 1, &(&1 + 1)) |> Map.update(v, 1, &(&1 + 1))
          {:cont, {:ok, tight}}

        true ->
          {:cont, {:ok, tight}}
      end
    end)
  end

  defp check_exposed(duals, mate) do
    case Enum.find(duals, fn {v, y} -> y > 0 and not Map.has_key?(mate, v) end) do
      nil -> :ok
      {v, y} -> {:fail, "vertex #{v} has dual #{y} > 0 but is exposed"}
    end
  end

  defp check_sets(sets, pairs) do
    bad =
      Enum.find(sets, fn {members, z} ->
        z > 0 and
          2 *
            Enum.count(pairs, fn {u, v} ->
              MapSet.member?(members, u) and MapSet.member?(members, v)
            end) +
            1 != MapSet.size(members)
      end)

    case bad do
      nil ->
        :ok

      {members, z} ->
        {:fail,
         "a set of #{MapSet.size(members)} vertices with dual #{z} does not hold " <>
           "#{div(MapSet.size(members) - 1, 2)} matched edges"}
    end
  end

  defp check_window_pairs(pairs, window, y) do
    bad =
      Enum.find(pairs, fn {u, v} ->
        in_u = MapSet.member?(window, u)
        in_v = MapSet.member?(window, v)

        cond do
          in_u and in_v -> y.(u) + y.(v) <= 0
          in_u -> y.(u) <= 0
          in_v -> y.(v) <= 0
          true -> false
        end
      end)

    case bad do
      nil ->
        :ok

      {u, v} ->
        {:fail,
         "window pair (#{u}, #{v}) could be left exposed by another optimum: its dual is 0"}
    end
  end

  defp check_objective(pairs, edges, duals, sets) do
    primal = Enum.reduce(pairs, 0, fn e, acc -> acc + Map.fetch!(edges, e) end)

    dual =
      Enum.reduce(duals, 0, fn {_, y}, acc -> acc + y end) +
        Enum.reduce(sets, 0, fn {m, z}, acc -> acc + z * div(MapSet.size(m) - 1, 2) end)

    if primal == dual,
      do: :ok,
      else: {:fail, "matching weight #{primal} differs from the dual objective #{dual}"}
  end

  # ----------------------------------------------------------------- read

  defp read(round, doc, label) do
    solve = doc["solve"]
    pairs = doc["pairs"]
    unless is_list(pairs), do: throw({:bad, "pairs"})

    case Map.fetch(round.matchings, solve) do
      :error ->
        fail(round, "#{label}: names #{inspect(solve)}, not a weighted record that passed")

      {:ok, {mate, forced}} ->
        Enum.reduce(pairs, round, fn
          [u, v, a, b], round when is_integer(a) and is_integer(b) ->
            if Map.get(mate, u) == v do
              key = {min(a, b), max(a, b)}
              forced? = MapSet.member?(forced, {min(u, v), max(u, v)})
              %{round | read: Map.update(round.read, key, forced?, &(&1 or forced?))}
            else
              fail(round, "#{label}: (#{u}, #{v}) is not a pair of record #{solve}'s matching")
            end

          other, round ->
            fail(round, "#{label}: malformed read #{inspect(other)}")
        end)
    end
  end

  # ---------------------------------------------------------- cardinality

  defp cardinality(round, doc, label) do
    id = doc["id"]
    n = doc["n"]
    unless is_integer(n) and n >= 0, do: throw({:bad, "n"})

    {graph, round} =
      case doc["graph"] do
        %{"edges" => list} when is_list(list) ->
          g = plain_graph!(list, n)
          {g, %{round | plain: Enum.take([{id, g} | round.plain], @kept_plain)}}

        %{"same" => same} ->
          case List.keyfind(round.plain, same, 0) do
            {_, g} -> {g, round}
            nil -> throw({:fail, "graph #{inspect(same)} is not one of the last #{@kept_plain}"})
          end

        _ ->
          throw({:bad, "no graph"})
      end

    case check_cardinality(doc, graph, n) do
      :ok -> round
      {:fail, reason} -> fail(round, "#{label}: #{reason}")
    end
  end

  # %{v => MapSet of neighbours}
  defp plain_graph!(list, n) do
    Enum.reduce(list, %{}, fn
      [u, v], acc when u != v ->
        u = vertex!(u, n)
        v = vertex!(v, n)

        acc
        |> Map.update(u, MapSet.new([v]), &MapSet.put(&1, v))
        |> Map.update(v, MapSet.new([u]), &MapSet.put(&1, u))

      other, _ ->
        throw({:bad, "edge #{inspect(other)}"})
    end)
  end

  defp check_cardinality(doc, graph, n) do
    dead = MapSet.new(list!(doc["dead"] || [], n, "dead"))
    {mate, pairs} = matching!(doc["matching"] || [], n, dead)

    # The graph asked about: the edges among the living, and M's pairs.
    graph =
      graph
      |> Map.drop(MapSet.to_list(dead))
      |> Map.new(fn {v, ns} -> {v, MapSet.difference(ns, dead)} end)

    graph =
      Enum.reduce(pairs, graph, fn {u, v}, g ->
        g
        |> Map.update(u, MapSet.new([v]), &MapSet.put(&1, v))
        |> Map.update(v, MapSet.new([u]), &MapSet.put(&1, u))
      end)

    live = Enum.reject(0..(n - 1)//1, &MapSet.member?(dead, &1))
    deficiency = length(live) - 2 * length(pairs)

    case doc["claim"] do
      "maximum" ->
        check_barrier_meets(graph, live, doc, deficiency, n)

      "not_exposable" ->
        with :ok <- check_barrier_meets(graph, live, doc, deficiency, n) do
          if deficiency == 1,
            do: {:fail, "the matching leaves exactly one vertex exposed: the claim is false"},
            else: :ok
        end

      "exposable" ->
        check_exposable(graph, live, doc, mate, deficiency, n)

      "augment" ->
        check_augment(graph, doc, mate, dead, n)

      "blocked" ->
        check_blocked(graph, live, doc, mate, dead, n)

      other ->
        {:fail, "unknown claim #{inspect(other)}"}
    end
  end

  defp list!(list, n, what) when is_list(list) do
    vs = Enum.map(list, &vertex!(&1, n))
    if length(Enum.uniq(vs)) != length(vs), do: throw({:bad, "#{what} lists a vertex twice"})
    vs
  end

  defp list!(_, _, what), do: throw({:bad, "#{what} is not a list"})

  # The components of the graph on `live` less `removed`, as lists.
  defp components(graph, live, removed) do
    keep = live |> MapSet.new() |> MapSet.difference(removed)

    {comps, _} =
      Enum.reduce(keep, {[], MapSet.new()}, fn v, {comps, seen} ->
        if MapSet.member?(seen, v) do
          {comps, seen}
        else
          {comp, seen} = flood([v], MapSet.put(seen, v), [], graph, keep)
          {[comp | comps], seen}
        end
      end)

    comps
  end

  defp flood([], seen, acc, _graph, _keep), do: {acc, seen}

  defp flood([v | rest], seen, acc, graph, keep) do
    {next, seen} =
      graph
      |> Map.get(v, MapSet.new())
      |> Enum.reduce({rest, seen}, fn u, {stack, seen} ->
        if MapSet.member?(keep, u) and not MapSet.member?(seen, u),
          do: {[u | stack], MapSet.put(seen, u)},
          else: {stack, seen}
      end)

    flood(next, seen, [v | acc], graph, keep)
  end

  defp barrier!(doc, live, n) do
    x = list!(doc["barrier"] || [], n, "barrier")
    live_set = MapSet.new(live)

    if not Enum.all?(x, &MapSet.member?(live_set, &1)),
      do: throw({:fail, "barrier holds a dead vertex"})

    MapSet.new(x)
  end

  defp check_barrier_meets(graph, live, doc, deficiency, n) do
    x = barrier!(doc, live, n)
    odd = graph |> components(live, x) |> Enum.count(&(rem(length(&1), 2) == 1))

    if deficiency == odd - MapSet.size(x),
      do: :ok,
      else:
        {:fail,
         "barrier of #{MapSet.size(x)} leaves #{odd} odd component(s), which does not show " <>
           "a matching leaving #{deficiency} exposed is maximum"}
  end

  defp check_exposable(graph, live, doc, mate, deficiency, n) do
    root = vertex!(doc["root"], n)
    claimed = MapSet.new(list!(doc["exposable"] || [], n, "exposable"))

    parent =
      Enum.reduce(doc["parent"] || [], %{}, fn
        [v, p], acc when is_integer(v) and is_integer(p) -> Map.put(acc, v, p)
        other, _ -> throw({:bad, "parent entry #{inspect(other)}"})
      end)

    x = barrier!(doc, live, n)

    odd_union =
      graph
      |> components(live, x)
      |> Enum.filter(&(rem(length(&1), 2) == 1))
      |> List.flatten()
      |> MapSet.new()

    cond do
      deficiency != 1 ->
        {:fail, "the matching leaves #{deficiency} vertices exposed, not one"}

      Map.has_key?(mate, root) or root not in live ->
        {:fail, "root #{root} is not the exposed vertex"}

      check_barrier_meets(graph, live, doc, deficiency, n) != :ok ->
        check_barrier_meets(graph, live, doc, deficiency, n)

      not MapSet.equal?(claimed, odd_union) ->
        {:fail,
         "the exposable set is not the union of the barrier's odd components " <>
           "(#{MapSet.size(claimed)} claimed, #{MapSet.size(odd_union)} there)"}

      true ->
        Enum.find_value(claimed, :ok, fn v ->
          case walk(v, root, mate, parent, graph, MapSet.new([v]), length(live)) do
            :ok -> nil
            {:fail, reason} -> {:fail, "vertex #{v}: #{reason}"}
          end
        end)
    end
  end

  # v, M(v), parent(M(v)), ... must reach root: an even alternating path
  # that flips to leave v exposed instead of root.
  defp walk(v, root, _mate, _parent, _graph, _seen, _budget) when v == root, do: :ok
  defp walk(_v, _root, _mate, _parent, _graph, _seen, 0), do: {:fail, "the path does not end"}

  defp walk(v, root, mate, parent, graph, seen, budget) do
    with {:ok, m} <- fetch(mate, v, "#{v} is exposed but not the root"),
         false <- MapSet.member?(seen, m) and {:fail, "the path meets #{m} twice"},
         {:ok, p} <- fetch(parent, m, "#{m} has no parent"),
         false <- MapSet.member?(seen, p) and {:fail, "the path meets #{p} twice"},
         false <- Map.get(mate, m) == p and {:fail, "(#{m}, #{p}) is a matched pair, not a step"},
         true <- adjacent?(graph, m, p) or {:fail, "(#{m}, #{p}) is not an edge"} do
      walk(p, root, mate, parent, graph, seen |> MapSet.put(m) |> MapSet.put(p), budget - 1)
    end
  end

  defp fetch(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:fail, reason}
    end
  end

  defp adjacent?(graph, u, v), do: graph |> Map.get(u, MapSet.new()) |> MapSet.member?(v)

  defp check_augment(graph, doc, mate, dead, n) do
    root = vertex!(doc["root"], n)
    path = list!(doc["path"] || [], n, "path")

    cond do
      MapSet.member?(dead, root) or Map.has_key?(mate, root) ->
        {:fail, "root #{root} is not an exposed living vertex"}

      path == [] or hd(path) != root ->
        {:fail, "the path does not start at the root"}

      rem(length(path), 2) != 0 ->
        {:fail, "the path has an even number of edges: it does not augment"}

      Enum.any?(path, &MapSet.member?(dead, &1)) ->
        {:fail, "the path runs through a dead vertex"}

      Map.has_key?(mate, List.last(path)) ->
        {:fail, "the path ends at a matched vertex"}

      true ->
        path
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.with_index()
        |> Enum.find_value(:ok, fn {[a, b], i} ->
          cond do
            not adjacent?(graph, a, b) -> {:fail, "(#{a}, #{b}) is not an edge"}
            rem(i, 2) == 1 and Map.get(mate, a) != b -> {:fail, "(#{a}, #{b}) should be matched"}
            rem(i, 2) == 0 and Map.get(mate, a) == b -> {:fail, "(#{a}, #{b}) should not be"}
            true -> nil
          end
        end)
    end
  end

  defp check_blocked(graph, live, doc, mate, dead, n) do
    root = vertex!(doc["root"], n)
    x = barrier!(doc, live, n)
    covered = mate |> Map.keys() |> MapSet.new() |> MapSet.put(root)

    inside =
      graph
      |> components(live, x)
      |> Enum.count(fn comp ->
        rem(length(comp), 2) == 1 and Enum.all?(comp, &MapSet.member?(covered, &1))
      end)

    cond do
      MapSet.member?(dead, root) or Map.has_key?(mate, root) ->
        {:fail, "root #{root} is not an exposed living vertex"}

      inside <= MapSet.size(x) ->
        {:fail,
         "barrier of #{MapSet.size(x)} leaves only #{inside} odd component(s) inside the " <>
           "vertices to cover: an augmenting path is not ruled out"}

      true ->
        :ok
    end
  end
end

# Run as a script unless loaded as a library (the tests do that).
unless Process.get(:verify_proof_as_library) do
  System.halt(VerifyProof.main(System.argv()))
end

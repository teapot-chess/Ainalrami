# Verifier for Ainalrami pairing proofs.
#
#   elixir tools/verify-proof/verify.exs PROOF_FILE [--summary]   (.jsonl, or gzipped)
#
# Reads a proof file (JSON Lines: one round certificate per line, as written
# by `ainalrami input.trf -p out.txt --proof=PROOF_FILE` or by the library's
# `:proof` option) and checks every solve in it. Prints PASS or FAIL per
# solve, with the reason for a FAIL, and exits 0 when every solve in the
# file passes, 1 when any fails, 2 when the file cannot be read as a proof.
# `--summary` prints one line per round instead of one per solve.
#
# This file is deliberately self-contained: Elixir's standard library only,
# no code shared with the engine, nothing that knows how the engine found
# its answer. It needs Elixir 1.18 or later (for the built-in JSON module).
#
# ## What a solve claims, and why these checks prove it
#
# A solve is a graph on vertices 0..n-1 with positive integer edge weights
# w(u, v), a matching M, and a dual solution: a number y[v] >= 0 for every
# vertex (missing means 0) and a list of vertex sets S, each with a number
# z[S] >= 0. The claim is that M is a maximum-weight matching of the graph.
#
# Edmonds' theorem: the convex hull of the matchings of a graph is
#
#   x >= 0,  x(edges at v) <= 1 for every v,
#   x(edges inside S) <= (|S| - 1) / 2 for every odd set S.
#
# The LP dual of maximising sum(w * x) over that polytope is: minimise
# sum(y) + sum(z[S] * (|S| - 1) / 2) subject to y >= 0, z >= 0 and, for
# every edge, y[u] + y[v] + sum(z[S] : S holds u and v) >= w(u, v).
#
# The checks:
#
#   1. M is a matching of the graph: no vertex twice, every pair an edge.
#   2. y >= 0, z >= 0, every set has an odd number of distinct vertices.
#   3. Every edge has reduced cost
#        rc(u, v) = y[u] + y[v] + sum(z[S] : S holds u and v) - w(u, v) >= 0.
#      (A pair that is not an edge has weight 0, and its reduced cost is a
#      sum of non-negative numbers.) So (y, z) is dual feasible.
#   4. Every edge of M has rc = 0.
#   5. Every vertex with y > 0 is matched.
#   6. Every set with z > 0 holds exactly (|S| - 1) / 2 edges of M.
#
# 1-3 make sum(w(M')) <= dual objective for ANY matching M' (weak duality:
# sum over M' of w <= sum over M' of (y[u] + y[v] + sum z) <= sum(y) +
# sum(z[S] * (|S| - 1) / 2), using x(edges at v) <= 1 and the odd-set
# bound). 4-6 are complementary slackness and make the two sides equal for
# M itself. So no matching weighs more than M. The verifier also computes
# both sides and checks they are equal, as a cross-check of the arithmetic.
#
# Some solves carry a "window": a list of vertices on which the claim is
# stronger - EVERY maximum-weight matching gives each window vertex the
# same partner as M (or leaves it exposed when M does). Extra checks:
#
#   7. Every edge NOT in M with an end in the window has rc > 0.
#   8. For every edge (u, v) of M with u in the window: y[u] > 0 if v is
#      outside the window, y[u] + y[v] > 0 if v is inside it.
#
# Why: complementary slackness holds between any optimal matching M' and
# this (optimal) dual, so M' uses only edges with rc = 0 and covers every
# vertex with y > 0. By 7, a window vertex's only possible partner in M'
# is its partner in M (or none); by 8, "none" would leave a vertex with
# y > 0 exposed - or both ends of a window pair exposed, one of them with
# y > 0. An exposed window vertex of M has no edge with rc = 0 at all, so
# M' leaves it exposed too.
#
# ## The format
#
# Each line: {"format": "ainalrami-pairing-proof", "version": 1,
# "round": {...}, "solves": [...], "uncertified": {...}}. A solve:
#
#   {"id": 0, "kind": "solve" | "window", "n": N, "scale": G,
#    "graph": {"edges": [[u, v, "w"], ...]}            -- the whole graph
#          or {"base": ID, "set": [[u, v, "w"], ...]}  -- solve ID's graph
#                                                         with these edges
#                                                         changed ("0" = gone)
#    "matching": [[u, v], ...],
#    "duals": [[v, "y"], ...],
#    "sets": [{"vertices": [...], "z": "..."}, ...],
#    "window": [...]}                                  -- optional
#
# Weights and duals are decimal strings: they are integers of any size.
# "uncertified" counts decisions of the engine that no certificate in the
# file covers; the verifier reports them and does not judge them.

defmodule VerifyProof do
  @format "ainalrami-pairing-proof"
  @versions [1]

  def main(args) do
    {summary?, files} =
      case Enum.split_with(args, &(&1 == "--summary")) do
        {flags, files} -> {flags != [], files}
      end

    case files do
      [path] ->
        verify_file(path, summary?)

      _ ->
        IO.puts(:stderr, "usage: elixir verify.exs PROOF_FILE [--summary]")
        2
    end
  end

  def verify_file(path, summary?) do
    case File.read(path) do
      {:ok, <<0x1F, 0x8B, _::binary>> = gz} ->
        verify_text(:zlib.gunzip(gz), summary?)

      {:ok, text} ->
        verify_text(text, summary?)

      {:error, reason} ->
        IO.puts(:stderr, "cannot read #{path}: #{:file.format_error(reason)}")
        2
    end
  end

  defp verify_text(text, summary?) do
    results =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
      |> Enum.map(fn {line, number} -> {number, verify_line(line)} end)

    Enum.each(results, fn {number, result} -> print(number, result, summary?) end)
    totals(results)
  end

  defp totals(results) do
    rounds = length(results)
    bad_lines = Enum.count(results, fn {_, r} -> match?({:error, _}, r) end)

    solves = for {_, {:ok, r}} <- results, s <- r.solves, do: s
    failed = Enum.count(solves, fn {_, _, verdict} -> verdict != :pass end)

    IO.puts(
      "#{rounds} round(s), #{length(solves)} solve(s): #{length(solves) - failed} PASS, " <>
        "#{failed} FAIL" <> if(bad_lines > 0, do: ", #{bad_lines} unreadable line(s)", else: "")
    )

    cond do
      rounds == 0 -> 2
      bad_lines > 0 -> 2
      failed > 0 -> 1
      true -> 0
    end
  end

  defp print(number, {:error, reason}, _summary?) do
    IO.puts("line #{number}: UNREADABLE - #{reason}")
  end

  defp print(number, {:ok, r}, summary?) do
    failed = Enum.count(r.solves, fn {_, _, v} -> v != :pass end)
    verdict = if failed == 0, do: "PASS", else: "FAIL"

    IO.puts(
      "line #{number}: round of #{r.players} player(s), #{length(r.solves)} solve(s), " <>
        "#{failed} failed - #{verdict}"
    )

    Enum.each(r.solves, fn
      {id, kind, :pass} ->
        unless summary?, do: IO.puts("  solve #{id} (#{kind}): PASS")

      {id, kind, {:fail, reason}} ->
        IO.puts("  solve #{id} (#{kind}): FAIL - #{reason}")
    end)

    if r.uncertified != %{} and not summary? do
      text = r.uncertified |> Enum.map_join(", ", fn {k, v} -> "#{k} x#{v}" end)
      IO.puts("  not covered by a certificate (reported, not checked): #{text}")
    end
  end

  # ------------------------------------------------------------------ a line

  def verify_line(line) do
    with {:ok, doc} <- decode(line),
         :ok <- header(doc),
         {:ok, solves} <- list_field(doc, "solves") do
      round = if is_map(doc["round"]), do: doc["round"], else: %{}
      uncertified = if is_map(doc["uncertified"]), do: doc["uncertified"], else: %{}

      # A graph is kept only while a later solve still names it as its
      # base: at a thousand players a round holds hundreds of graphs of
      # half a million edges, and keeping them all costs tens of gigabytes.
      last_use = last_uses(solves)

      {checked, _graphs} =
        solves
        |> Enum.with_index()
        |> Enum.map_reduce(%{}, fn {solve, at}, graphs ->
          id = Map.get(solve, "id")
          kind = Map.get(solve, "kind", "?")

          {verdict, edges} =
            case verify_solve(solve, graphs) do
              {:ok, edges} -> {:pass, edges}
              {:fail, reason, edges} -> {{:fail, reason}, edges}
            end

          graphs =
            graphs
            |> Map.reject(fn {base, _} -> Map.get(last_use, base, -1) <= at end)
            |> put_graph(id, edges, Map.get(last_use, id, -1) > at)

          {{id, kind, verdict}, graphs}
        end)

      # The engine's own statement that the round it published is the one
      # the certified computation produced. Not something this file can
      # check (that would need the engine's pairing rules); a "false" here
      # means the solves below do not describe the published round.
      agreement =
        case round["agrees"] do
          false ->
            [
              {"round", "agreement",
               {:fail,
                "the engine reports that the published pairing " <>
                  "differs from the one the certified solves produced"}}
            ]

          _ ->
            []
        end

      {:ok,
       %{
         players: Map.get(round, "players", "?"),
         solves: agreement ++ checked,
         uncertified: uncertified
       }}
    end
  end

  defp put_graph(graphs, _id, nil, _wanted), do: graphs
  defp put_graph(graphs, id, edges, true), do: Map.put(graphs, id, edges)
  defp put_graph(graphs, _id, _edges, false), do: graphs

  # base id => index of the last solve that names it
  defp last_uses(solves) do
    solves
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%{"graph" => %{"base" => base}}, at}, acc -> Map.put(acc, base, at)
      _, acc -> acc
    end)
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:ok, _} -> {:error, "not a JSON object"}
      {:error, reason} -> {:error, "not JSON: #{inspect(reason)}"}
    end
  end

  defp header(doc) do
    cond do
      doc["format"] != @format ->
        {:error, "format is not #{@format}"}

      doc["version"] not in @versions ->
        {:error, "unsupported version #{inspect(doc["version"])}"}

      true ->
        :ok
    end
  end

  defp list_field(doc, key) do
    case doc[key] do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, "#{key} is not a list"}
    end
  end

  # ----------------------------------------------------------------- a solve

  # {:ok, edges} or {:fail, reason, edges | nil}; edges is %{{u, v} => w}
  # with u < v, kept for later solves that name this one as their base.
  defp verify_solve(solve, graphs) do
    case graph(solve, graphs) do
      {:ok, edges} ->
        case check(solve, edges) do
          :ok -> {:ok, edges}
          {:fail, reason} -> {:fail, reason, edges}
        end

      {:fail, reason} ->
        {:fail, reason, nil}
    end
  catch
    {:bad, reason} -> {:fail, "malformed: #{reason}", nil}
  end

  defp graph(%{"graph" => %{"edges" => list}}, _graphs) when is_list(list) do
    apply_edges(%{}, list, false)
  end

  defp graph(%{"graph" => %{"base" => base, "set" => list}}, graphs) when is_list(list) do
    case Map.fetch(graphs, base) do
      {:ok, edges} -> apply_edges(edges, list, true)
      :error -> {:fail, "base graph #{inspect(base)} is not an earlier solve of this round"}
    end
  end

  defp graph(_, _), do: {:fail, "malformed: no graph"}

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

  defp check(solve, edges) do
    n = solve["n"]
    unless is_integer(n) and n >= 0, do: throw({:bad, "n"})

    duals = duals!(solve["duals"], n)
    sets = sets!(solve["sets"], n)
    {mate, pairs} = matching!(solve["matching"], n)

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

    window = window!(solve["window"], n)

    with :ok <- check_vertices(edges, n),
         :ok <- check_pairs_are_edges(pairs, edges),
         :ok <- check_edges(edges, mate, rc, window),
         :ok <- check_exposed(duals, mate),
         :ok <- check_sets(sets, pairs),
         :ok <- check_window_pairs(pairs, window, y),
         :ok <- check_objective(pairs, edges, duals, sets) do
      :ok
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
        if y < 0, do: throw({:bad, "dual of vertex #{v} is negative (#{y})"})
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
          rem(length(vs), 2) != 1 -> throw({:bad, "a set has an even number of vertices"})
          z < 0 -> throw({:bad, "a set dual is negative (#{z})"})
          true -> {members, z}
        end

      other ->
        throw({:bad, "set entry #{inspect(other)}"})
    end)
  end

  defp sets!(_, _), do: throw({:bad, "sets is not a list"})

  defp matching!(list, n) when is_list(list) do
    Enum.reduce(list, {%{}, []}, fn
      [u, v], {mate, pairs} ->
        u = vertex!(u, n)
        v = vertex!(v, n)
        if u == v, do: throw({:bad, "vertex #{u} is matched to itself"})

        if Map.has_key?(mate, u) or Map.has_key?(mate, v),
          do: throw({:bad, "a vertex of (#{u}, #{v}) is matched twice"})

        {mate |> Map.put(u, v) |> Map.put(v, u), [{min(u, v), max(u, v)} | pairs]}

      other, _ ->
        throw({:bad, "matching entry #{inspect(other)}"})
    end)
  end

  defp matching!(_, _), do: throw({:bad, "matching is not a list"})

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

  defp check_edges(edges, mate, rc, window) do
    bad =
      Enum.find_value(edges, fn {{u, v}, w} ->
        r = rc.(u, v, w)
        matched? = Map.get(mate, u) == v

        cond do
          r < 0 ->
            "edge (#{u}, #{v}) violates its dual constraint: reduced cost #{r}"

          matched? and r != 0 ->
            "matched edge (#{u}, #{v}) is not tight: reduced cost #{r}"

          not matched? and r == 0 and
              (MapSet.member?(window, u) or MapSet.member?(window, v)) ->
            "edge (#{u}, #{v}) at a window vertex is tight but unmatched: " <>
              "another optimum could use it"

          true ->
            nil
        end
      end)

    if bad, do: {:fail, bad}, else: :ok
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
end

# Run as a script unless loaded as a library (the tamper tests do that).
unless Process.get(:verify_proof_as_library) do
  System.halt(VerifyProof.main(System.argv()))
end

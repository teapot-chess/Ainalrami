# Exhaustion by matching: the refusal proof without the 12-player ceiling.
#
# `tools/exhaustion_bruteforce.exs` PROVED that bbpPairings' "no legal pairing"
# answers are right by enumerating all (n-1)!! complete pairings. That stops
# at 12-14 players. This tool closes the gap without enumeration.
#
# ## The reduction
#
# "Does a legal complete pairing exist" is a perfect-matching existence
# question. The graph has one vertex per active player and an edge for every
# pair the absolute criteria allow (C1 no rematch, C3 the colour rule with its
# topscorer exemption, the arbiter's forbidden pairs). On an odd field one
# bye-eligible player (C2) sits out: a dummy vertex joined to every eligible
# player turns that into the same question on N+1 vertices. A legal pairing
# exists iff the graph has a perfect matching. That is polynomial for any
# field size.
#
# ## What is reused and what is not
#
# The reading of the rules (what an allowed pair and an eligible bye are) is
# the brute-force tool's, copied verbatim into `Rules` below, because the 4.8
# million positive controls already validated it. Nothing is shared with
# `Ainalrami.Pairing`, `Ainalrami.Matching` or `Ainalrami.WeightedMatching`.
#
# The SOLVING half is `Solver` below: the size of the maximum matching is the
# rank of a random Tutte matrix over GF(2^61 - 1) - algebraic, no blossoms.
# The 2026-10-12 run also had a Python half (networkx's blossom matching,
# which had to agree on the size); that half was retired with the Python on
# 2026-10-31, so "none" verdicts above 12 players now rest on the Tutte rank
# alone (wrong with probability at most N/p, about 2e-17, and only ever
# towards "none"), and enumeration for 12 players and fewer.
#
# For fields up to 12 players this file also enumerates over the same graph,
# so the matching answer can be checked against enumeration position by
# position (`enum` column). Run `tools/exhaustion_bruteforce.exs` over the
# same seeds as well to check the graph itself against the original tool.
#
# ## Positive controls
#
# On every round bbpPairings DID pair, three things are checked: the solver
# says a legal pairing exists; the reference's own pairing is a witness (every
# pair is an edge of the graph, the bye holder is eligible, the seated set is
# exactly the active set); and the two solvers agree. A solver or an edge
# reading that is too strict fails here and would otherwise "prove" every
# refusal for the same wrong reason.
#
# ## Usage
#
#   MIX_ENV=test mix run tools/exhaustion_matching.exs FROM TO ROUNDS MIN MAX [DUMP_DIR]
#
# Env: MATCH_CHUNK (seeds per solver batch, default 1500), MATCH_GEN (Elixir
# generator concurrency, default schedulers-4), MATCH_SOLVE (solver processes,
# default same), PAIRING_FUZZ_* (the generator knobs, as for the probe).
# bbpPairings located as in
# `Ainalrami.Test.Bbppairings` (BBPPAIRINGS_EXE or the sibling OpenPairings
# copy). Disagreements are written to DUMP_DIR as TRF + graph line.

alias Ainalrami.Test.{Bbppairings, FuzzTournament}

defmodule Rules do
  # ----- verbatim from tools/exhaustion_bruteforce.exs (see its comments for
  # the sources of each reading) ---------------------------------------------

  def met_before?(a, b) do
    Enum.any?(a.games, &(&1.result in ~w(1 = 0) and &1.opponent_rank == b.rank))
  end

  def bye_eligible?(player, ps) do
    not Enum.any?(player.games, &(pairing_allocated_bye?(&1) or unplayed_win?(&1, ps)))
  end

  defp pairing_allocated_bye?(g), do: is_nil(g.opponent_rank) and g.result in ~w(U +)
  defp unplayed_win?(g, ps), do: unplayed?(g) and unplayed_value(g, ps) >= ps.win
  defp unplayed?(g), do: g.result in ~w(+ - H F U Z) or g.result in [nil, ""]

  defp unplayed_value(%{result: r}, ps) when r in ~w(F +), do: ps.win
  defp unplayed_value(%{result: "H"}, ps), do: ps.draw
  defp unplayed_value(%{result: "U"}, ps), do: ps.pairing_allocated_bye
  defp unplayed_value(%{result: "-", opponent_rank: nil}, ps), do: ps.zero_point_bye
  defp unplayed_value(%{result: "-"}, ps), do: ps.forfeit_loss
  defp unplayed_value(_game, ps), do: ps.zero_point_bye

  defp absolute_preference(player) do
    coloured =
      player.games
      |> Enum.filter(&(&1.result in ~w(1 = 0) and &1.colour in ~w(w b)))

    whites = Enum.count(coloured, &(&1.colour == "w"))
    blacks = Enum.count(coloured, &(&1.colour == "b"))
    diff = whites - blacks

    last_two = coloured |> Enum.reverse() |> Enum.take(2) |> Enum.map(& &1.colour)

    cond do
      diff > 1 -> "b"
      diff < -1 -> "w"
      match?([x, x], last_two) -> invert(hd(last_two))
      true -> nil
    end
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"

  defp topscorer?(player, ctx) do
    final_round? = ctx.played >= ctx.expected - 1
    per_round = max(ctx.ps.win, ctx.ps.draw)

    final_round? and accelerated_score(player, ctx) > ctx.played * per_round / 2
  end

  defp accelerated_score(player, ctx) do
    boost = player |> Map.get(:accelerations, []) |> Enum.at(ctx.played) || 0.0
    player.points + boost
  end

  # The reading the sources settle on: ONE topscorer lifts the prohibition.
  defp colour_clash?(a, b, ctx) do
    pa = absolute_preference(a)
    pb = absolute_preference(b)
    same_absolute? = not is_nil(pa) and pa == pb
    same_absolute? and not (topscorer?(a, ctx) or topscorer?(b, ctx))
  end

  def legal_pair?(a, b, ctx) do
    not met_before?(a, b) and not colour_clash?(a, b, ctx) and not forbidden?(a, b, ctx)
  end

  defp forbidden?(a, b, ctx) do
    MapSet.member?(ctx.forbidden_set, {min(a.rank, b.rank), max(a.rank, b.rank)})
  end
end

defmodule Graph do
  import Bitwise

  # Adjacency as one integer bitmask per player (bit j = legal opponent j),
  # plus the bye-eligible mask. Index = position in `active`.
  def build(active, ctx) do
    indexed = Enum.with_index(active)

    rows =
      for {a, i} <- indexed do
        Enum.reduce(indexed, 0, fn {b, j}, acc ->
          if i != j and Rules.legal_pair?(a, b, ctx), do: acc ||| 1 <<< j, else: acc
        end)
      end

    bye =
      Enum.reduce(indexed, 0, fn {p, i}, acc ->
        if Rules.bye_eligible?(p, ctx.ps), do: acc ||| 1 <<< i, else: acc
      end)

    {rows, bye}
  end

  # Enumeration over the graph (n <= 12): fix the lowest free player, try
  # every legal partner. Walks all perfect matchings, stops at the first.
  def enum_verdict(rows, bye, n) do
    row = List.to_tuple(rows)
    all = (1 <<< n) - 1

    ok? =
      if rem(n, 2) == 0 do
        pm?(all, row)
      else
        Enum.any?(0..(n - 1), fn b -> (bye >>> b &&& 1) == 1 and pm?(all &&& bnot(1 <<< b), row) end)
      end

    if ok?, do: "legal", else: "none"
  end

  defp pm?(0, _row), do: true

  defp pm?(free, row) do
    i = lowest(free)
    rest = free &&& bnot(1 <<< i)
    cand = elem(row, i) &&& rest
    try_partners(cand, i, rest, row)
  end

  defp try_partners(0, _i, _rest, _row), do: false

  defp try_partners(cand, i, rest, row) do
    j = lowest(cand)

    pm?(rest &&& bnot(1 <<< j), row) or
      try_partners(cand &&& bnot(1 <<< j), i, rest, row)
  end

  defp lowest(x), do: lowest(x, 0)
  defp lowest(x, k) when (x &&& 1) == 1, do: k
  defp lowest(x, k), do: lowest(x >>> 1, k + 1)

  def line(kind, seed, round, n, enum, witness, rows, bye) do
    Enum.join(
      [
        kind,
        seed,
        round,
        n,
        enum,
        witness,
        Integer.to_string(bye, 16),
        Enum.map_join(rows, ",", &Integer.to_string(&1, 16))
      ],
      "\t"
    )
  end
end

defmodule Driver do
  @default_points %{
    win: 1.0,
    draw: 0.5,
    loss: 0.0,
    pairing_allocated_bye: 1.0,
    forfeit_loss: 0.0,
    zero_point_bye: 0.0
  }
  @enum_max 12

  # Returns {lines, extras}: one line per position, extras are the records the
  # Elixir side keeps itself (trf for refusals, so a disagreement is dumpable).
  def run(seed, rounds, player_range) do
    {rounds, player_count, forbidden, roster} =
      FuzzTournament.begin!(seed, rounds, player_range)

    {out, _} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, players} ->
        FuzzTournament.withdraw_some(round, player_count)

        case play(players, seed, round, rounds, forbidden) do
          {:cont, next, entry} -> {:cont, {[entry | acc], next}}
          {:halt, entry} -> {:halt, {[entry | acc], players}}
        end
      end)

    out
  rescue
    e -> [{:error, "#{seed}: " <> (Exception.message(e) |> String.slice(0, 160))}]
  end

  defp play(players, seed, round, total_rounds, forbidden) do
    players = FuzzTournament.assign_requested_byes(players)
    trf = FuzzTournament.build_trf(players, total_rounds, forbidden)
    active = active_players(players)
    ctx = context(round_being_paired(players), total_rounds, forbidden)
    n = length(active)
    {rows, bye} = Graph.build(active, ctx)
    enum = if n <= @enum_max and n > 0, do: Graph.enum_verdict(rows, bye, n), else: "-"

    case Bbppairings.pair(trf) do
      {:no_valid_pairing, _} ->
        {:halt, {:position, Graph.line("refusal", seed, round, n, enum, "-", rows, bye), trf}}

      {:ok, pairs} ->
        witness = witness(active, rows, bye, pairs)
        line = Graph.line("control", seed, round, n, enum, witness, rows, bye)
        next = FuzzTournament.apply_round(players, pairs, FuzzTournament.simulate_results(pairs))
        {:cont, next, {:position, line, nil}}

      _ ->
        {:halt, {:error, "bbp process error seed=#{seed} round=#{round}"}}
    end
  end

  # The reference's pairing as a certificate against OUR graph: every pair is
  # an edge, the bye holder is eligible, and exactly the active players are
  # seated. "ok" or the name of what failed.
  defp witness(active, rows, bye, pairs) do
    import Bitwise
    idx = active |> Enum.with_index() |> Map.new(fn {p, i} -> {p.rank, i} end)
    row = List.to_tuple(rows)

    seated = Enum.flat_map(pairs, fn {w, b} -> if b, do: [w, b], else: [w] end)

    cond do
      Enum.sort(seated) != Enum.sort(Map.keys(idx)) ->
        "active_set_mismatch"

      Enum.any?(pairs, fn
        {_w, nil} -> false
        {w, b} -> (elem(row, idx[w]) >>> idx[b] &&& 1) == 0
      end) ->
        "pair_not_an_edge"

      Enum.any?(pairs, fn
        {w, nil} -> (bye >>> idx[w] &&& 1) == 0
        _ -> false
      end) ->
        "bye_not_eligible"

      true ->
        "ok"
    end
  end

  defp round_being_paired(players) do
    players |> Enum.map(&length(&1.games)) |> Enum.min(fn -> 0 end) |> Kernel.+(1)
  end

  defp active_players(players) do
    r = round_being_paired(players)
    Enum.filter(players, &(length(&1.games) < r))
  end

  defp context(round, total_rounds, forbidden) do
    %{
      played: round - 1,
      expected: total_rounds,
      ps: FuzzTournament.point_system() || @default_points,
      forbidden_set:
        Enum.reduce(forbidden, MapSet.new(), fn group, acc ->
          for a <- group, b <- group, a < b, into: acc, do: {a, b}
        end)
    }
  end
end

defmodule Solver do
  # Decides, for one position line, whether a complete legal pairing exists.
  # Shares no code with Ainalrami. The answer is the size of a maximum matching,
  # read off the rank of a random Tutte matrix over GF(2^61 - 1) (Lovasz 1979):
  # maximum matching = rank / 2. Algebraic, no blossoms. It can only err by
  # reporting a rank that is too LOW, with probability at most N/p (about
  # 2e-17) per graph; a rank it reports is never too high, so a "legal"
  # verdict is certain and a "none" verdict is probabilistic.
  #
  # (Until 2026-10-31 a Python half also ran networkx's blossom matching next
  # to this and the two had to agree. That half is retired with the Python;
  # the 2026-10-12 results in docs/validation.md were produced with both.)
  #
  # An odd field is handled by one dummy vertex joined to every bye-eligible
  # player: the field can be paired iff the extended graph has a perfect
  # matching, the dummy's partner being the player who sits out.
  #
  # Line format (tab separated): kind seed round n enum witness byehex rows,
  # each row the hex bitmask of that player's legal opponents.

  import Bitwise

  @p (1 <<< 61) - 1

  def solve(line) do
    [kind, seed, rnd, n, enum, witness, byehex, rows] = String.split(String.trim_trailing(line, "\n"), "\t")
    {seed, rnd, n} = {String.to_integer(seed), String.to_integer(rnd), String.to_integer(n)}
    base = %{kind: kind, seed: seed, rnd: rnd, n: n, enum: enum, witness: witness, line: line}

    if n == 0 do
      Map.put(base, :verdict, "empty")
    else
      rows = rows |> String.split(",") |> Enum.map(&String.to_integer(&1, 16))
      bye = String.to_integer(byehex, 16)
      size_n = n + rem(n, 2)
      pairs = tutte_size(size_n, edges(n, rows, bye), :rand.seed_s(:exsss, {seed, rnd, 1}))
      Map.merge(base, %{verdict: if(pairs * 2 == size_n, do: "legal", else: "none"), tutte_pairs: pairs})
    end
  end

  defp edges(n, rows, bye) do
    row = List.to_tuple(rows)

    inner = for i <- 0..(n - 1), j <- (i + 1)..(n - 1)//1, (elem(row, i) >>> j &&& 1) == 1, do: {i, j}
    dummy = if rem(n, 2) == 1, do: for(i <- 0..(n - 1), (bye >>> i &&& 1) == 1, do: {i, n}), else: []
    inner ++ dummy
  end

  defp tutte_size(size_n, edges, rng) do
    {cells, _} =
      Enum.reduce(edges, {%{}, rng}, fn {i, j}, {m, st} ->
        {x, st} = :rand.uniform_s(@p - 1, st)
        {m |> Map.put({i, j}, x) |> Map.put({j, i}, @p - x), st}
      end)

    rows = for i <- 0..(size_n - 1), do: for(j <- 0..(size_n - 1), do: Map.get(cells, {i, j}, 0))
    div(rank(rows, 0), 2)
  end

  # Gaussian elimination mod p over a list of rows; returns the rank.
  defp rank([], acc), do: acc

  defp rank(rows, acc) do
    case Enum.split_while(rows, fn [h | _] -> h == 0 end) do
      {_, []} ->
        # No pivot in this column: drop it.
        rank(Enum.map(rows, &tl/1) |> drop_empty(), acc)

      {zeros, [[pv | _] = prow | rest]} ->
        inv = pow(pv, @p - 2)

        reduced =
          for [h | t] <- zeros ++ rest do
            if h == 0 do
              t
            else
              f = rem(h * inv, @p)
              Enum.zip_with(t, tl(prow), fn a, b -> Integer.mod(a - f * b, @p) end)
            end
          end

        rank(drop_empty(reduced), acc + 1)
    end
  end

  defp drop_empty(rows), do: Enum.reject(rows, &(&1 == []))

  defp pow(b, e), do: :crypto.mod_pow(b, e, @p) |> :binary.decode_unsigned()

  @doc "Counts and flagged positions, as the report prints them."
  def summarize(results) do
    Enum.reduce(results, {%{}, []}, fn r, {counts, bad} ->
      k = r.kind
      counts = counts |> inc("#{k}:total") |> inc("#{k}:#{r.verdict}") |> inc("n:#{k}:#{r.n}")

      flags =
        if r.verdict == "empty" do
          ["empty_field"]
        else
          List.flatten([
            if(r.enum != "-" and r.enum != r.verdict, do: ["matching_vs_enum matching=#{r.verdict} enum=#{r.enum}"], else: []),
            if(k == "refusal" and r.verdict != "none", do: ["refusal_but_legal_pairing_exists"], else: []),
            if(k == "control" and r.verdict != "legal", do: ["control_says_none"], else: []),
            if(k == "control" and r.witness != "ok", do: ["witness_" <> r.witness], else: [])
          ])
        end

      counts = if r.verdict != "empty" and r.enum != "-", do: inc(counts, "enum:compared"), else: counts

      if flags == [],
        do: {counts, bad},
        else: {inc(counts, "flagged"), [%{flags: flags, line: String.trim_trailing(r.line, "\n")} | bad]}
    end)
    |> then(fn {counts, bad} -> {counts, Enum.reverse(bad)} end)
  end

  defp inc(map, key), do: Map.update(map, key, 1, &(&1 + 1))
end

# ---------------------------------------------------------------- driver

args = System.argv()
from = String.to_integer(Enum.at(args, 0))
to = String.to_integer(Enum.at(args, 1))
rounds = String.to_integer(Enum.at(args, 2, "16"))
min_p = String.to_integer(Enum.at(args, 3, "11"))
max_p = String.to_integer(Enum.at(args, 4, "20"))
dump_dir = Enum.at(args, 5, "tmp/matching_dumps")
chunk = String.to_integer(System.get_env("MATCH_CHUNK", "1500"))
gen = String.to_integer(System.get_env("MATCH_GEN", "#{max(System.schedulers_online() - 4, 1)}"))
py = String.to_integer(System.get_env("MATCH_SOLVE", "#{gen}"))
work = Path.join(System.tmp_dir!(), "exh-matching-#{System.unique_integer([:positive])}")

File.mkdir_p!(dump_dir)
File.mkdir_p!(work)

IO.puts("matching oracle: seeds #{from}..#{to}, #{rounds} rounds, #{min_p}-#{max_p} players, chunk #{chunk}, gen #{gen}, solver procs #{py}")

merge = fn a, b -> Map.merge(a, b, fn _k, x, y -> x + y end) end

{totals, bad_all, errors, tournaments, t_gen, t_py} =
  from..to
  |> Enum.chunk_every(chunk)
  |> Enum.reduce({%{}, [], [], 0, 0, 0}, fn seeds, {tot, bad_all, errs, tcount, tg, tp} ->
    t0 = System.monotonic_time(:millisecond)

    results =
      seeds
      |> Task.async_stream(&Driver.run(&1, rounds, min_p..max_p),
        max_concurrency: gen,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, l} -> l end)

    errors = for {:error, m} <- results, do: m
    positions = for {:position, line, trf} <- results, do: {line, trf}
    t1 = System.monotonic_time(:millisecond)

    solved =
      positions
      |> Task.async_stream(fn {l, _} -> Solver.solve(l) end,
        max_concurrency: py,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    {counts, bad} = Solver.summarize(solved)
    t2 = System.monotonic_time(:millisecond)

    trf_by_line = for {l, t} <- positions, t, into: %{}, do: {l, t}

    bad =
      for %{flags: f, line: l} <- bad do
        %{flags: f, line: l, trf: Map.get(trf_by_line, l)}
      end

    IO.puts(
      "  seeds #{hd(seeds)}..#{List.last(seeds)}: #{length(positions)} positions, " <>
        "#{Map.get(counts, "refusal:total", 0)} refusals, flagged #{Map.get(counts, "flagged", 0)}, " <>
        "gen #{div(t1 - t0, 1000)}s solve #{div(t2 - t1, 1000)}s"
    )

    {merge.(tot, counts), bad_all ++ bad, errs ++ errors, tcount + length(seeds), tg + (t1 - t0), tp + (t2 - t1)}
  end)

File.rm_rf!(work)

g = fn k -> Map.get(totals, k, 0) end

IO.puts("\n=== #{tournaments} tournaments ===")
IO.puts("  refusals (bbpPairings: no legal pairing): #{g.("refusal:total")}")
IO.puts("    proved impossible (no perfect matching):  #{g.("refusal:none")}")
IO.puts("    a legal pairing EXISTS:                   #{g.("refusal:legal")}")
IO.puts("  positive controls (rounds bbpPairings paired): #{g.("control:total")}")
IO.puts("    solver found a legal pairing:             #{g.("control:legal")}")
IO.puts("    solver said none (oracle too strict):     #{g.("control:none")}")
IO.puts("  empty active fields:                        #{g.("refusal:empty") + g.("control:empty")}")
IO.puts("  matching vs enumeration compared on:        #{g.("enum:compared")} positions (n <= 12)")
IO.puts("  flagged positions:                          #{g.("flagged")}")
IO.puts("  harness errors:                             #{length(errors)}")
IO.puts("  time: generation #{div(t_gen, 1000)}s, solving #{div(t_py, 1000)}s")

IO.puts("\n  refusals by active-field size:")

for {k, v} <- totals,
    String.starts_with?(k, "n:refusal:"),
    n = k |> String.split(":") |> List.last() |> String.to_integer(),
    reduce: [] do
  acc -> [{n, v} | acc]
end
|> Enum.sort()
|> Enum.map_join("  ", fn {n, v} -> "#{n}:#{v}" end)
|> then(&IO.puts("    " <> &1))

IO.puts("  positions by active-field size (refusal+control):")

for {k, v} <- totals,
    String.starts_with?(k, "n:"),
    n = k |> String.split(":") |> List.last() |> String.to_integer(),
    reduce: %{} do
  acc -> Map.update(acc, n, v, &(&1 + v))
end
|> Enum.sort()
|> Enum.map_join("  ", fn {n, v} -> "#{n}:#{v}" end)
|> then(&IO.puts("    " <> &1))

for e <- Enum.take(errors, 10), do: IO.puts("  ERROR #{e}")

if bad_all == [] do
  IO.puts("\n  No disagreement. Every refusal agrees with the Tutte-rank solver (and with enumeration up to 12 players).")
else
  IO.puts("\n  #{length(bad_all)} FLAGGED position(s) - dumping to #{dump_dir}")

  bad_all
  |> Enum.take(200)
  |> Enum.with_index()
  |> Enum.each(fn {b, i} ->
    base = Path.join(dump_dir, "flag#{i}")
    File.write!(base <> ".txt", "flags: #{inspect(b.flags)}\n#{b.line}\n")
    if b.trf, do: File.write!(base <> ".trf", b.trf)
  end)

  for b <- Enum.take(bad_all, 12), do: IO.puts("    #{inspect(b.flags)}  #{String.slice(b.line, 0, 60)}")
end

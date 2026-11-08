# The minimal examples in docs/fide-rules-evidence-draft.md.
#
#     cd lab && mix run tools/examples.exs
#
# Walks small generated tournaments (6 to 9 players, brute-force
# reference, 2026 text) and prints, for each kind of oddity, the first
# position found in the smallest field: the TRF of the position, the
# round the 2026 text pairs, and what the oddity is. Deterministic.

alias AinalramiLab.{Brute, Metrics, Rules, Tournament, Variant}
alias AinalramiVerify.Position

base = Variant.baseline()

positions = fn spec, seeds ->
  Stream.flat_map(seeds, fn seed ->
    Tournament.play(spec, :brute, base, seed).rounds
    |> Enum.filter(&match?({:ok, _}, &1.result))
    |> Enum.map(&Map.put(&1, :seed, seed))
  end)
end

show = fn title, rec, note ->
  {:ok, r} = rec.result

  IO.puts("""

  === #{title}
  seed #{rec.seed}, round #{rec.round}, #{map_size(rec.pos.players)} players
  #{rec.trf |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, ["001", "XXR", "152"])) |> Enum.join("\n")}
  2026 text pairs: #{Enum.map_join(r.pairs, "  ", fn {w, b} -> "#{w}-#{b}" end)}#{if r.bye, do: "  bye #{r.bye}", else: ""}
  #{note}
  """)
end

# 1. A player given the same colour a third time running.
streak = fn rec ->
  {:ok, r} = rec.result

  Enum.find_value(r.pairs, fn {w, b} ->
    Enum.find_value([{w, :w}, {b, :b}], fn {p, c} ->
      if Enum.take(rec.pos.players[p].colours, -2) == [c, c], do: {p, c}, else: nil
    end)
  end)
end

found =
  Enum.find_value([6, 7, 8, 9], fn n ->
    positions.(%Tournament{players: n, rounds: 5}, 1..400)
    |> Enum.find_value(fn rec -> if x = streak.(rec), do: {rec, x} end)
  end)

case found do
  {rec, {p, c}} ->
    pl = rec.pos.players[p]

    show.("third colour in a row", rec,
      "player #{p} (colours #{inspect(pl.colours)}, score #{pl.score / 2}, topscorer #{pl.topscorer?}) gets #{c} again")

  nil ->
    IO.puts("no third colour in a row found")
end

# 2. The longest downfloat cascade in the smallest field.
found =
  Enum.find_value([6, 7, 8, 9], fn n ->
    positions.(%Tournament{players: n, rounds: 5}, 1..300)
    |> Enum.find_value(fn rec ->
      {:ok, r} = rec.result
      c = Metrics.cascade(rec.pos, r.pairs)
      if c >= 3, do: {rec, c}
    end)
  end)

case found do
  {rec, c} -> show.("downfloat cascade", rec, "#{c} consecutive brackets each pass a downfloater on")
  nil -> IO.puts("no cascade of 3 found")
end

# 3. A player downfloated in two consecutive rounds (C14 could not prevent it).
found =
  Enum.find_value([6, 7, 8], fn n ->
    positions.(%Tournament{players: n, rounds: 5}, 1..300)
    |> Enum.find_value(fn rec ->
      {:ok, r} = rec.result
      ctx = AinalramiVerify.Bracket.context(rec.pos)
      s = AinalramiVerify.Bracket.structure(ctx, r.pairs)
      AinalramiVerify.Bracket.cleanup(ctx)

      Enum.find_value(Enum.drop(s, -1), fn {b, {_ps, df}} ->
        Enum.find_value(df, fn d ->
          if d in b.residents and Rules.floated?(rec.pos, d, :down, 1), do: {rec, d}
        end)
      end)
    end)
  end)

case found do
  {rec, d} -> show.("repeated downfloat", rec, "player #{d} downfloated last round and downfloats again")
  nil -> IO.puts("no repeated downfloat found")
end

# 4. A 5.2.5 board whose colours depend on the numbering.
found =
  positions.(%Tournament{players: 8, rounds: 4, late: 2, forfeit: 0.3}, 1..400)
  |> Enum.find_value(fn rec ->
    {:ok, r} = rec.result

    r.pairs
    |> Enum.zip(r.articles)
    |> Enum.find_value(fn
      {{w, b}, "5.2.5"} when rec.round > 1 ->
        hi = if Position.order_key(rec.pos, w) <= Position.order_key(rec.pos, b), do: w, else: b

        if Rules.c525_colour(rec.pos, hi, :arrival) != Rules.c525_colour(rec.pos, hi, :tpn),
          do: {rec, {w, b}, hi}

      _ ->
        nil
    end)
  end)

case found do
  {rec, {w, b}, hi} ->
    n = Map.get(rec.pos.arrival, hi)

    show.("5.2.5 and the numbering", rec,
      "board #{w}-#{b}: higher-ranked #{hi} has TPN #{hi} and arrival number #{n}; the two readings give opposite colours")

  nil ->
    IO.puts("no numbering-dependent 5.2.5 board found")
end

# 5. What a dropped C14 changes, smallest field.
found =
  Enum.find_value([6, 7, 8], fn n ->
    positions.(%Tournament{players: n, rounds: 5}, 1..300)
    |> Enum.find_value(fn rec ->
      {:ok, a} = rec.result

      case Brute.pair(rec.pos, Variant.parse("float_memory=1")) do
        {:ok, b} when b.pairs != a.pairs -> {rec, b}
        _ -> nil
      end
    end)
  end)

case found do
  {rec, b} ->
    show.("float_memory=1 changes the round", rec,
      "with one round of float memory: #{Enum.map_join(b.pairs, "  ", fn {w, x} -> "#{w}-#{x}" end)}#{if b.bye, do: "  bye #{b.bye}", else: ""}")

  nil ->
    IO.puts("float_memory=1 changed nothing")
end

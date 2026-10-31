# Independent rule check (C1, C2, C3, completeness) of two pairings of one TRF
# round. Shares no code with Ainalrami: it reads the TRF and the two output
# files itself.
#
# usage: elixir tools/rule_check_round.exs file.trf bbp_out.txt ainalrami_out.txt
#
# Output files are bbpPairings' -p format: count, then "w b" lines, "x 0" = PAB.

defmodule RuleCheckRound do
  # `String.contains?(set, x)` is Python's `x in set`, empty string included.
  defp in?(x, set), do: String.contains?(set, x)

  def parse(path) do
    lines = path |> File.read!() |> String.replace_invalid() |> String.split("\n")

    xxr =
      Enum.find_value(lines, fn l ->
        if String.starts_with?(l, "XXR"), do: l |> String.split() |> Enum.at(1) |> String.to_integer()
      end)

    players =
      for l <- lines, String.starts_with?(l, "001"), into: %{} do
        rank = l |> String.slice(4, 4) |> String.trim() |> String.to_integer()
        {rank, rounds(String.slice(l, 91..-1//1) |> String.trim_trailing("\r"))}
      end

    {players, xxr}
  end

  defp rounds(rest), do: rounds(rest, 0, [])

  defp rounds(rest, i, acc) do
    if i + 8 > String.length(rest) + 1 do
      Enum.reverse(acc)
    else
      chunk = String.slice(rest, i, 8)

      if String.trim(chunk) == "" do
        rounds(rest, i + 10, acc)
      else
        opp = chunk |> String.slice(0, 4) |> String.trim()
        col = String.slice(chunk, 5, 1)
        res = String.slice(chunk, 7, 1)
        n = if opp != "" and opp =~ ~r/^\d+$/, do: String.to_integer(opp), else: 0
        rounds(rest, i + 10, [{n, col, res} | acc])
      end
    end
  end

  def read_out(path) do
    [_count | pairs] = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.split/1)
    for [a, b] <- Enum.reject(pairs, &(&1 == [])), do: {String.to_integer(a), String.to_integer(b)}
  end

  def played_rounds(players) do
    for {_r, rounds} <- players, {{opp, _c, _r}, k} <- Enum.with_index(rounds, 1), opp != 0, reduce: 0 do
      n -> max(n, k)
    end
  end

  def colour_pref(rounds) do
    cols = for {opp, c, r} <- rounds, opp != 0, in?("wb", c), not in?("+-", r), do: c

    if cols == [] do
      nil
    else
      w = Enum.count(cols, &(&1 == "w"))
      b = Enum.count(cols, &(&1 == "b"))
      diff = w - b
      [last, prev | _] = Enum.reverse(cols) ++ [nil, nil]

      cond do
        diff > 1 or (length(cols) >= 2 and last == prev and last == "w") -> "B"
        diff < -1 or (length(cols) >= 2 and last == prev and last == "b") -> "W"
        true -> nil
      end
    end
  end

  def check(players, pairing, rnd) do
    hist = Map.new(players, fn {r, rounds} -> {r, Enum.take(rounds, rnd - 1)} end)

    absent =
      for {r, rounds} <- players, length(rounds) >= rnd, elem(Enum.at(rounds, rnd - 1), 0) == 0, into: MapSet.new(), do: r

    present = players |> Map.keys() |> MapSet.new() |> MapSet.difference(absent)

    {probs, seen, byes} =
      Enum.reduce(pairing, {[], [], []}, fn
        {w, 0}, {p, s, by} ->
          {p, [w | s], by ++ [w]}

        {w, b}, {p, s, by} ->
          opps_w = for {o, _c, _r} <- hist[w], o != 0, do: o
          p = if b in opps_w, do: p ++ ["C1 rematch #{w}-#{b}"], else: p
          pw = colour_pref(hist[w])
          pb = colour_pref(hist[b])
          p = if pw && pw == pb, do: p ++ ["C3 both absolute #{pw}: #{w}-#{b}"], else: p
          {p, [b, w | s], by}
      end)

    probs =
      if Enum.sort(seen) != Enum.sort(MapSet.to_list(present)) do
        probs ++
          ["not every present player paired once: #{inspect(Enum.sort(seen))} vs #{inspect(Enum.sort(MapSet.to_list(present)))}"]
      else
        probs
      end

    probs =
      if length(byes) > 1 or (byes != [] and rem(MapSet.size(present), 2) == 0),
        do: probs ++ ["bad bye count"],
        else: probs

    probs =
      Enum.reduce(byes, probs, fn x, acc ->
        unplayed_full =
          for {{o, _c, r}, k} <- Enum.with_index(hist[x], 1), (o == 0 and in?("UF", r)) or r == "+", do: k

        if unplayed_full == [],
          do: acc,
          else: acc ++ ["C2 bye to #{x}, who already scored unplayed full point in round(s) #{inspect(unplayed_full)}"]
      end)

    {probs, byes, Enum.sort(MapSet.to_list(absent))}
  end
end

[trf, bbp, ain] =
  case System.argv() do
    [_, _, _] = argv -> argv
    _ -> IO.puts(:stderr, "usage: elixir tools/rule_check_round.exs file.trf bbp_out.txt ainalrami_out.txt") && System.halt(2)
  end

{players, xxr} = RuleCheckRound.parse(trf)
rnd = RuleCheckRound.played_rounds(players) + 1
IO.puts("round paired: #{rnd} (XXR #{xxr}); players #{map_size(players)}")

for {label, path} <- [{"bbpPairings", bbp}, {"Ainalrami", ain}] do
  pairing = RuleCheckRound.read_out(path)
  {probs, byes, absent} = RuleCheckRound.check(players, pairing, rnd)
  shown = "[" <> Enum.map_join(pairing, ", ", fn {a, b} -> "(#{a}, #{b})" end) <> "]"
  IO.puts("  #{label}: #{shown}  bye=#{inspect(byes, charlists: :as_lists)} absent=#{inspect(absent, charlists: :as_lists)}")
  IO.puts("    " <> if(probs == [], do: "LEGAL (C1, C2, C3, completeness)", else: Enum.join(probs, "; ")))
end

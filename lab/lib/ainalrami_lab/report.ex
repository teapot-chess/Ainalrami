defmodule AinalramiLab.Report do
  @moduledoc "Prints a simulation report as text, and writes it as JSON."

  alias AinalramiLab.{Metrics, Stats}

  @labels %{
    "streak3" => "3rd+ same colour in a row, per 100 player-games",
    "abs_cd" => "mean |CD| at the end",
    "cd2_share" => "% players ending |CD| >= 2",
    "denied" => "colour preferences denied, per 100 boards",
    "floats" => "floats per player per round",
    "double_floats" => "boards across >= 1 point, per 100 boards",
    "repeat_float_1" => "same float two rounds running, per 100 player-rounds",
    "repeat_float_2" => "same float two rounds apart, per 100 player-rounds",
    "cascade" => "longest downfloat chain (brackets) per round",
    "score_gap" => "sum of board score gaps, points per round",
    "top_games" => "games among the top quarter of seeds",
    "top2_met" => "% tournaments where seeds 1 and 2 met",
    "rematches" => "rematches per tournament",
    "c525_boards" => "boards decided by 5.2.5 from round 2",
    "c525_sensitive" => "... of which arrival vs TPN numbering flips colours"
  }

  def label(name), do: Map.fetch!(@labels, name)

  @doc "The report as text."
  def text(r) do
    head = [
      "variant:  #{r.variant}  (#{r.variant_described})",
      "baseline: #{r.baseline}",
      "pairer:   #{r.pairer}   engine #{r.engine}   seed #{r.seed}   #{r.seconds} s",
      corpus_line(r.corpus)
    ]

    metrics =
      case r do
        %{metrics: m} ->
          [
            "",
            "tournaments: #{r.tournaments}, compared (both arms complete): #{r.compared}, " <>
              "ended early: baseline #{r.ended_early.baseline}, variant #{r.ended_early.variant}",
            "",
            pad("metric (per tournament, mean [95% CI])", 54) <>
              pad("baseline", 27) <> pad("variant", 27) <> "variant - baseline"
          ] ++
            Enum.map(Metrics.names(), fn name ->
              x = m[name]
              star = if Stats.significant?(x.diff), do: " *", else: ""

              pad(label(name), 54) <>
                pad(ci(x.baseline), 27) <> pad(ci(x.variant), 27) <> signed_ci(x.diff) <> star
            end) ++ ["", "* the 95% interval of the paired difference excludes 0"]

        _ ->
          []
      end

    p = r.positions

    positions = [
      "",
      "same position, both arms (#{p.compared} positions):",
      "  pairing differs:      #{prop(p.pairs_differ)}",
      "  only colours differ:  #{prop(p.colours_only_differ)}",
      "  boards changed per differing round: #{fmt(p.boards_changed_per_differing_round)}",
      "  refused by one arm only: baseline #{p.refused.baseline_only}, variant #{p.refused.variant_only}"
    ]

    examples =
      case r.examples do
        [] -> ["", "no example: the variant changed no round"]
        list -> ["", "examples:"] ++ Enum.flat_map(list, &example/1)
      end

    Enum.join(head ++ metrics ++ positions ++ examples, "\n") <> "\n"
  end

  defp corpus_line(%{kind: :generated} = c),
    do:
      "corpus:   generated, #{c.tournaments} tournaments of #{c.players} players x #{c.rounds} rounds" <>
        ", absent #{c.absent}, forfeit #{c.forfeit}, late #{c.late}"

  defp corpus_line(%{kind: :trf} = c),
    do: "corpus:   TRF files, #{c.files_read} of #{c.files} readable"

  defp example(e) do
    file = if e[:file], do: " (#{e.file})", else: ""

    [
      "",
      "--- round #{e.round}, #{e.kind} differ#{file}",
      e.trf
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, ["001", "XXR", "152"]))
      |> Enum.join("\n"),
      "baseline: " <> boards(e.baseline),
      "variant:  " <> boards(e.variant)
    ]
  end

  defp boards(%{pairs: pairs, bye: bye}) do
    s = Enum.map_join(pairs, "  ", fn {w, b} -> "#{w}-#{b}" end)
    if bye, do: s <> "  bye #{bye}", else: s
  end

  defp ci(%{mean: m, lo: lo, hi: hi}), do: "#{fmt(m)} [#{fmt(lo)}, #{fmt(hi)}]"

  defp signed_ci(%{mean: m, lo: lo, hi: hi}),
    do: "#{sign(m)} [#{sign(lo)}, #{sign(hi)}]"

  defp prop(%{k: k, n: n, p: p, lo: lo, hi: hi}),
    do: "#{k}/#{n} = #{fmt(100 * p)}% [#{fmt(100 * lo)}, #{fmt(100 * hi)}]"

  defp sign(x) when x >= 0, do: "+" <> fmt(x)
  defp sign(x), do: fmt(x)

  defp fmt(x) when is_integer(x), do: Integer.to_string(x)
  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3)

  defp pad(s, n), do: String.pad_trailing(s, n)

  @doc "The report as JSON (tuples as lists)."
  def json(r), do: r |> plain() |> JSON.encode!()

  defp plain(%{__struct__: _} = s), do: s |> Map.from_struct() |> plain()
  defp plain(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), plain(v)} end)
  defp plain(l) when is_list(l), do: Enum.map(l, &plain/1)
  defp plain(t) when is_tuple(t), do: t |> Tuple.to_list() |> plain()
  defp plain(a) when is_atom(a) and a not in [nil, true, false], do: Atom.to_string(a)
  defp plain(x), do: x
end

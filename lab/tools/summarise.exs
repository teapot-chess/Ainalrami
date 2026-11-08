# Summarise a directory of simulation reports as Markdown tables.
#
#     cd lab && mix run tools/summarise.exs runs/paper
#
# One table per corpus: per variant, the share of positions whose round
# the variant changes, and the paired difference (variant - baseline,
# 95% interval) of each metric; a difference whose interval excludes 0
# is marked with *.

[root] = System.argv()

fmt = fn x -> :erlang.float_to_binary(x * 1.0, decimals: 2) end
sign = fn x -> if x >= 0, do: "+" <> fmt.(x), else: fmt.(x) end

metrics = ~w(streak3 cd2_share denied floats double_floats repeat_float_1 repeat_float_2 cascade score_gap top_games top2_met c525_boards c525_sensitive)

for corpus <- root |> File.ls!() |> Enum.sort(), File.dir?(Path.join(root, corpus)) do
  reports =
    Path.wildcard(Path.join([root, corpus, "*", "report.json"]))
    |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))

  base = Enum.find(reports, &(&1["variant"] == "baseline"))

  IO.puts("\n### #{corpus}\n")

  if c = base && base["corpus"] do
    IO.puts(
      "#{c["tournaments"]} tournaments of #{c["players"]} players x #{c["rounds"]} rounds, " <>
        "absent #{c["absent"]}, forfeit #{c["forfeit"]}, late #{c["late"]}; pairer #{base["pairer"]}\n"
    )

    IO.puts("Baseline (2026 text), mean [95% CI]:\n")
    IO.puts("| metric | baseline |\n|---|---|")

    for m <- metrics do
      b = base["metrics"][m]["baseline"]
      IO.puts("| `#{m}` | #{fmt.(b["mean"])} [#{fmt.(b["lo"])}, #{fmt.(b["hi"])}] |")
    end

    IO.puts("")
  end

  IO.puts("| variant | rounds changed | " <> Enum.map_join(metrics, " | ", &"`#{&1}`") <> " |")
  IO.puts("|---|---|" <> String.duplicate("---|", length(metrics)))

  for r <- Enum.sort_by(reports, & &1["variant"]), r["variant"] != "baseline" do
    p = r["positions"]["pairs_differ"]
    co = r["positions"]["colours_only_differ"]

    changed =
      "#{fmt.(100 * p["p"])}%" <>
        if(co["k"] > 0, do: " (+#{fmt.(100 * co["p"])}% colours only)", else: "")

    cells =
      Enum.map(metrics, fn m ->
        d = r["metrics"][m]["diff"]
        star = if d["lo"] > 0 or d["hi"] < 0, do: "*", else: ""
        "#{sign.(d["mean"])}#{star} [#{sign.(d["lo"])}, #{sign.(d["hi"])}]"
      end)

    IO.puts("| `#{r["variant"]}` | #{changed} | " <> Enum.join(cells, " | ") <> " |")
  end
end

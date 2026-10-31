# One-line progress of the large-field C.04.6 run (tools/team_large_run.exs).
#
#     elixir tools/team_large_status.exs [team_large_state.json]

path = List.first(System.argv()) || Path.expand("../team_large_state.json", __DIR__)
s = path |> File.read!() |> JSON.decode!()

plan = Map.get(s, "planned", %{})
total = Map.get(plan, "last", 0) - Map.get(plan, "first", 1) + 1
secs = s["done"] |> Enum.map(& &1["secs"]) |> Enum.sum()
workers = Map.get(plan, "workers", 1)
per_seed = if s["seeds"] > 0, do: secs / s["seeds"], else: 0
left_h = (total - s["seeds"]) * per_seed / workers / 3600
f = fn x, d -> :erlang.float_to_binary(x * 1.0, decimals: d) end

IO.puts(
  "seeds #{s["seeds"]} of #{total} (#{plan["first"]}..#{plan["last"]})  " <>
    "rounds #{s["rounds"]}  failures #{length(s["failures"])}  errors #{length(s["errors"])}  " <>
    "brackets checked #{s["brackets_checked"]} / skipped #{s["brackets_skipped"]}  " <>
    "#{f.(per_seed, 1)} core-s per seed  about #{f.(left_h, 1)} h left at #{workers} workers  " <>
    "updated #{Map.get(s, "updated", "-")}  runner pid #{inspect(s["pid"])}"
)

for x <- s["failures"],
    do: IO.puts("  FAILURE seed #{x["seed"]} round #{x["round"]} (#{x["teams"]} teams): #{x["file"]}")

for e <- s["errors"], do: IO.puts("  ERROR chunk #{inspect(e["range"])} exit #{e["code"]}")

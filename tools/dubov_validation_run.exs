# The long C.04.4.1 (Dubov) validation run: rounds against the brute-force reference.
#
# Runs `test/ainalrami/dubov_validation_test.exs --only dubov_whole_rounds` -
# the ordinary test, whose reference is written from the regulation text and
# shares no code with the engine - many times at once, each copy on its own
# seed range (DUBOV_VALIDATION_SEEDS; roster sizes from DUBOV_VALIDATION_SIZES, default 4..10) and its own core (`+S 1:1`), at
# below-normal priority on Windows.
#
# Resumable: every finished chunk is recorded in the state file, and a restart
# skips them. A disagreement fails that chunk's test; the seed is read from the
# failure message, recorded with the message, and the rest of the chunk is
# queued again from the next seed - one bad seed never hides the ones after it.
#
#     elixir tools/dubov_validation_run.exs --first 1 --last 100000 --workers 8
#
# Options: --chunk (seeds per test run, 10000), --state (dubov_validation_state.json),
# --repo (the checkout to test in; default this one).
#
# Run it from a separate checkout (a git worktree) so compiling in the main one
# cannot change the code under a run that takes hours.

Code.require_file("chunk_runner.exs", __DIR__)

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [first: :integer, last: :integer, chunk: :integer, workers: :integer, state: :string, repo: :string]
  )

first = Keyword.get(opts, :first, 1)
last = Keyword.get(opts, :last, 100_000)
chunk = Keyword.get(opts, :chunk, 10_000)
workers = Keyword.get(opts, :workers, 12)
state_path = Keyword.get(opts, :state, "dubov_validation_state.json")
repo = Keyword.get(opts, :repo, Path.expand("..", __DIR__))
sizes = if s = System.get_env("DUBOV_VALIDATION_SIZES"), do: [{"DUBOV_VALIDATION_SIZES", s}], else: []

state =
  ChunkRunner.load_state(state_path, %{
    "done" => [],
    "failures" => [],
    "errors" => [],
    "rounds" => 0,
    "seeds" => 0
  })

# Seeds already accounted for: finished ranges, plus seeds that failed.
spans =
  Enum.map(state["done"], fn %{"range" => [a, b]} -> {a, b} end) ++
    Enum.map(state["failures"], fn %{"seed" => s} -> {s, s} end)

queue = ChunkRunner.todo(first, last, chunk, spans)
started = System.monotonic_time(:second)
rounds_at_start = state["rounds"]

IO.puts("#{length(queue)} chunks to run, #{workers} workers, state in #{state_path}")
ChunkRunner.lower_priority()

exec = fn {a, b} ->
  ChunkRunner.mix_test(
    repo,
    [{"DUBOV_VALIDATION_SEEDS", "#{a}..#{b}"}] ++ sizes,
    ["test/ainalrami/dubov_validation_test.exs", "--only", "dubov_whole_rounds"]
  )
end

on_result = fn {a, b}, {code, out, secs}, s ->
  ok = Regex.run(~r/DUBOVRUN seeds=(\d+) rounds=(\d+)/, out)
  seed = Regex.run(~r/seed (\d+),/, out)

  cond do
    code == 0 and ok != nil ->
      [_, seeds, rounds] = ok
      rounds = String.to_integer(rounds)

      s =
        s
        |> Map.update!("done", &(&1 ++ [%{"range" => [a, b], "rounds" => rounds, "secs" => secs}]))
        |> Map.update!("rounds", &(&1 + rounds))
        |> Map.update!("seeds", &(&1 + String.to_integer(seeds)))

      {s, [], []}

    seed != nil and a <= String.to_integer(Enum.at(seed, 1)) and String.to_integer(Enum.at(seed, 1)) <= b ->
      bad = String.to_integer(Enum.at(seed, 1))
      s = Map.update!(s, "failures", &(&1 ++ [%{"seed" => bad, "output" => ChunkRunner.tail(out)}]))

      # Seeds before the bad one passed, but their count is not reported on a
      # failure: re-run them rather than claim rounds nobody counted.
      requeue =
        (if bad < b, do: [{bad + 1, b}], else: []) ++ if a < bad, do: [{a, bad - 1}], else: []

      {s, requeue, ["DISAGREEMENT at seed #{bad} - recorded, continuing"]}

    true ->
      s =
        Map.update!(s, "errors", &(&1 ++ [%{"range" => [a, b], "code" => code, "output" => ChunkRunner.tail(out)}]))

      {s, [], ["chunk #{a}..#{b} errored (exit #{code}) - recorded, not retried"]}
  end
end

progress = fn s, q ->
  elapsed = max(System.monotonic_time(:second) - started, 1)
  rate = (s["rounds"] - rounds_at_start) / elapsed
  left = Enum.sum(for {a, b} <- q, do: b - a + 1) * (s["rounds"] / max(s["seeds"], 1))
  eta_h = if rate > 0, do: Float.round(left / rate / 3600, 1), else: "inf"

  "#{ChunkRunner.hms()}  rounds #{s["rounds"]}  #{round(rate)}/s  failures #{length(s["failures"])}  " <>
    "errors #{length(s["errors"])}  chunks left #{length(q)}  ETA #{eta_h} h"
end

final =
  ChunkRunner.run(queue, state, state_path, workers, exec: exec, on_result: on_result, progress: progress)

IO.puts(
  "FINISHED  seeds #{final["seeds"]}  rounds #{final["rounds"]}  " <>
    "failures #{length(final["failures"])}  errors #{length(final["errors"])}"
)

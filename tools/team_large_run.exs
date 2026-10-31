# The long C.04.6 large-field run: 100-200 team rounds against the exact
# reference.
#
# Runs `test/ainalrami/team_proof_xl_test.exs --only whole_rounds_xl` many times
# at once, each copy on its own seed range (TEAM_XL_SEEDS) and its own core
# (`+S 1:1`), at below-normal priority on Windows. What the run proves is
# written up in `docs/team-proof-large-fields.md`, section "100-200 teams".
#
# Resumable: every finished chunk is recorded in the state file, and a restart
# with the same command skips them. A disagreement does not stop anything: the
# test writes the full reproducer (seed, field, options, engine round,
# reference round) into the failures directory, the seed is counted in the
# state file, and the chunk carries on with the next seed.
#
#     elixir tools/team_large_run.exs --first 1 --last 14000 --workers 6
#
# Options: --chunk (6), --sizes ("100..200"), --check-max (64), --state
# (team_large_state.json), --failures (failures), --stop, --repo.
#
# Stop it by creating the file named by --stop (default `STOP` next to the
# state file): no new chunk starts, the running ones finish. Run it from its own
# worktree so compiling elsewhere cannot change the code under it.
# Progress: `elixir tools/team_large_status.exs`.

Code.require_file("chunk_runner.exs", __DIR__)

max_workers = 6

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [
      first: :integer,
      last: :integer,
      chunk: :integer,
      workers: :integer,
      sizes: :string,
      check_max: :integer,
      state: :string,
      failures: :string,
      stop: :string,
      repo: :string
    ]
  )

first = Keyword.get(opts, :first, 1)

last =
  case Keyword.fetch(opts, :last) do
    {:ok, n} ->
      n

    :error ->
      IO.puts(:stderr, "--last is required")
      System.halt(2)
  end

chunk = Keyword.get(opts, :chunk, 6)
workers = Keyword.get(opts, :workers, 6)
sizes = Keyword.get(opts, :sizes, "100..200")
check_max = Keyword.get(opts, :check_max, 64)
state_path = Keyword.get(opts, :state, "team_large_state.json")
failures_dir = Path.expand(Keyword.get(opts, :failures, "failures"))
repo = Keyword.get(opts, :repo, Path.expand("..", __DIR__))

if workers < 1 or workers > max_workers do
  IO.puts(:stderr, "--workers must be 1..#{max_workers}: this PC is shared")
  System.halt(2)
end

stop_file = Keyword.get(opts, :stop) || Path.join(Path.dirname(Path.expand(state_path)), "STOP")
totals = ~w(seeds rounds teams byes ref_ms engine_ms checker_ms brackets_checked brackets_skipped)

summary =
  ~r/TEAMXL seeds=(\d+) rounds=(\d+) failures=(\d+) teams=(\d+) byes=(\d+) ref_ms=(\d+) engine_ms=(\d+) checker_ms=(\d+) brackets_checked=(\d+) brackets_skipped=(\d+)/

fail_re = ~r/TEAMXL-FAIL seed=(\d+) round=(\d+) teams=(\d+) file=(.+)$/m

now = fn ->
  {{y, mo, d}, {h, mi, s}} = :calendar.local_time()
  IO.iodata_to_binary(:io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [y, mo, d, h, mi, s]))
end

state =
  ChunkRunner.load_state(
    state_path,
    Map.merge(%{"done" => [], "failures" => [], "errors" => []}, Map.new(totals, &{&1, 0}))
  )

state =
  state
  |> Map.put("planned", %{
    "first" => first,
    "last" => last,
    "chunk" => chunk,
    "workers" => workers,
    "sizes" => sizes,
    "check_max" => check_max
  })
  |> Map.put_new("first_started", now.())
  |> Map.put("last_started", now.())
  |> Map.put("pid", String.to_integer(System.pid()))

ChunkRunner.save_state(state_path, state)

spans = Enum.map(state["done"], fn %{"range" => [a, b]} -> {a, b} end)
queue = ChunkRunner.todo(first, last, chunk, spans)
started = System.monotonic_time(:second)
seeds_at_start = state["seeds"]

IO.puts(
  "#{now.()}  pid #{System.pid()}  #{length(queue)} chunks to run (seeds #{first}..#{last}), " <>
    "#{workers} workers, state in #{state_path}"
)

ChunkRunner.lower_priority()

exec = fn {a, b} ->
  ChunkRunner.mix_test(
    repo,
    [
      {"TEAM_XL_SEEDS", "#{a}..#{b}"},
      {"TEAM_XL_SIZES", sizes},
      {"TEAM_XL_CHECK_MAX", "#{check_max}"},
      {"TEAM_XL_FAILURES", failures_dir}
    ],
    ["test/ainalrami/team_proof_xl_test.exs", "--only", "whole_rounds_xl"]
  )
end

on_result = fn {a, b}, {code, out, secs}, s ->
  case Regex.run(summary, out) do
    [_ | groups] when code == 0 ->
      # groups: seeds rounds failures teams byes ref_ms engine_ms checker_ms checked skipped
      [seeds, rounds, fails | rest] = Enum.map(groups, &String.to_integer/1)
      values = Map.new(Enum.zip(totals, [seeds, rounds | rest]))
      s = Enum.reduce(totals, s, fn k, acc -> Map.update!(acc, k, &(&1 + values[k])) end)
      entry = %{"range" => [a, b], "rounds" => rounds, "failures" => fails, "secs" => secs}
      s = Map.update!(s, "done", &(&1 ++ [entry]))
      found = Regex.scan(fail_re, out)

      s =
        Enum.reduce(found, s, fn [_, seed, round_no, teams, file], acc ->
          failure = %{
            "seed" => String.to_integer(seed),
            "round" => String.to_integer(round_no),
            "teams" => String.to_integer(teams),
            "file" => file
          }

          Map.update!(acc, "failures", &(&1 ++ [failure]))
        end)

      msgs =
        for [_, seed, round_no, _, file] <- found,
            do: "DISAGREEMENT at seed #{seed} round #{round_no} - reproducer #{file} - continuing"

      {Map.put(s, "updated", now.()), [], msgs}

    _ ->
      # mix itself failed (it should not: the test counts disagreements instead
      # of failing). Recorded, and NOT counted as done: a restart tries the
      # range again.
      err = %{"range" => [a, b], "code" => code, "secs" => secs, "output" => ChunkRunner.tail(out)}
      s = s |> Map.update!("errors", &(&1 ++ [err])) |> Map.put("updated", now.())
      {s, [], ["chunk #{a}..#{b} errored (exit #{code}) - recorded"]}
  end
end

progress = fn s, q ->
  elapsed = max(System.monotonic_time(:second) - started, 1)
  rate = (s["seeds"] - seeds_at_start) / elapsed
  left = Enum.sum(for {a, b} <- q, do: b - a + 1)
  eta_h = if rate > 0, do: Float.round(left / rate / 3600, 1), else: "inf"

  "#{ChunkRunner.hms()}  seeds #{s["seeds"]}  rounds #{s["rounds"]}  #{round(rate * 3600)} seeds/h  " <>
    "failures #{length(s["failures"])}  errors #{length(s["errors"])}  chunks left #{length(q)}  ETA #{eta_h} h"
end

final =
  ChunkRunner.run(queue, state, state_path, workers,
    exec: exec,
    on_result: on_result,
    progress: progress,
    stop?: fn -> File.exists?(stop_file) end
  )

final = Map.put(final, "pid", nil)
ChunkRunner.save_state(state_path, final)

IO.puts(
  "#{now.()}  FINISHED  seeds #{final["seeds"]}  rounds #{final["rounds"]}  " <>
    "failures #{length(final["failures"])}  errors #{length(final["errors"])}"
)

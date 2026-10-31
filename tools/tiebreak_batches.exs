# Shared by tools/tiebreak_direction1.exs and tools/tiebreak_direction2.exs
# (VCL4THP Q33): the batch loop, the state file and the log line the two
# directions have in common. Loaded with Code.require_file.
#
# A batch is generated into its own directory, compared with
# `tools/tiebreak_compare.exs`, and either deleted (it agreed) or kept with
# compare.txt (it did not). The state file records every finished batch, so a
# rerun skips them.

defmodule TiebreakBatches do
  @moduledoc false

  @root Path.expand("..", __DIR__)
  @summary ~r/files (\d+), skipped (\d+), values compared (\d+), mismatches (\d+), known differences (\d+)/
  @ranks ~r/rankings compared (\d+), rank known (\d+)/

  def root, do: @root

  @doc "The Python that runs TieBreakServer's own tools (TBS_PYTHON, else python3/python)."
  def python do
    System.get_env("TBS_PYTHON") || System.find_executable("python3") || System.find_executable("python") || "python"
  end

  def mix_env(extra \\ []), do: [{"ELIXIR_ERL_OPTIONS", "+S 1:1"}, {"TBS_PYTHON", python()} | extra]

  @doc "`mix run ARGS` in the repo, one scheduler. Returns {exit code, stdout+stderr}."
  def mix_run(args) do
    {out, code} = System.cmd("mix", ["run" | args], cd: @root, env: mix_env(), stderr_to_stdout: true)
    {code, out}
  end

  @doc """
  Reads tools/tiebreak_compare.exs's output into the batch result, deletes the
  directory when the batch is clean (`keep?` decides), else leaves compare.txt.
  """
  def settle(batch, extra, dir, {_code, out}, keep?) do
    case Regex.run(@summary, out) do
      nil ->
        Map.merge(%{"batch" => batch, "error" => "compare: " <> ChunkRunner.tail(out, 300)}, extra)

      [_ | nums] ->
        [files, skipped, values, bad, known] = Enum.map(nums, &String.to_integer/1)

        result =
          Map.merge(
            %{"batch" => batch, "files" => files, "skipped" => skipped, "values" => values, "mismatches" => bad, "known" => known},
            extra
          )

        result =
          case Regex.run(@ranks, out) do
            [_, compared, rank_known] ->
              Map.merge(result, %{"rankings" => String.to_integer(compared), "rank_known" => String.to_integer(rank_known)})

            nil ->
              result
          end

        if keep?.(bad, skipped) do
          File.write!(Path.join(dir, "compare.txt"), out)
        else
          File.rm_rf!(dir)
        end

        result
    end
  end

  @doc """
  Runs `batches` (a list of batch numbers) with `workers` at a time through
  `run_batch.(b)`, recording each in the state file and printing the running
  totals. With `strict`, exits 1 if any batch errored or disagreed.
  """
  def drive(batches, total, run_batch, opts) do
    state_path = Keyword.fetch!(opts, :state)
    workers = Keyword.fetch!(opts, :workers)
    state = ChunkRunner.load_state(state_path, %{"done" => %{}})
    todo = Enum.reject(batches, &Map.has_key?(state["done"], Integer.to_string(&1)))
    File.mkdir_p!(Keyword.fetch!(opts, :work))
    started = System.monotonic_time(:second)

    state =
      todo
      |> Task.async_stream(run_batch, max_concurrency: workers, timeout: :infinity)
      |> Enum.reduce(state, fn {:ok, r}, state ->
        state = put_in(state, ["done", Integer.to_string(r["batch"])], r)
        ChunkRunner.save_state(state_path, state)
        if failed?(r), do: IO.puts("   " <> JSON.encode!(r))
        IO.puts(report(state, total))
        state
      end)

    IO.puts("finished in #{Float.round((System.monotonic_time(:second) - started) / 3600, 1)} h")

    if opts[:strict] do
      failed = Enum.filter(Map.values(state["done"]), &failed?/1)
      for r <- failed, do: IO.puts("FAILED batch " <> JSON.encode!(r))
      if failed != [], do: System.halt(1)
    end
  end

  defp failed?(r), do: Map.has_key?(r, "error") or (r["mismatches"] || 0) > 0

  defp report(state, total) do
    done = Map.values(state["done"])
    ok = Enum.reject(done, &Map.has_key?(&1, "error"))
    sum = fn k -> ok |> Enum.map(&Map.get(&1, k, 0)) |> Enum.sum() end

    "#{ChunkRunner.hms()}  batches #{length(done)}/#{total}  tournaments #{sum.("files")}  " <>
      "values #{sum.("values")}  mismatches #{sum.("mismatches")}  known #{sum.("known")}  " <>
      "rankings #{sum.("rankings")} (known #{sum.("rank_known")})  " <>
      "skipped #{sum.("skipped")}  errors #{length(done) - length(ok)}"
  end

  def common_switches do
    [batches: :integer, size: :integer, workers: :integer, work: :string, state: :string, random_lists: :integer, strict: :boolean]
  end
end

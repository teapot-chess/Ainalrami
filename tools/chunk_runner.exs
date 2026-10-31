# Shared by the long-run drivers (team_validation_run.exs, team_large_run.exs):
# a resumable queue of seed ranges, N workers, a JSON state file written after
# every chunk. Loaded with Code.require_file, so the drivers stay plain scripts
# that need no compiled project:
#
#     elixir tools/team_large_run.exs --first 1 --last 14000 --workers 6
#
# The state files keep the layout the Python drivers wrote, so a run started by
# one can be resumed by the other.

defmodule ChunkRunner do
  @moduledoc false

  @doc "The chunks of first..last that no finished range already covers."
  def todo(first, last, chunk, spans) do
    spans = Enum.sort(spans) ++ [{last + 1, last + 1}]

    {out, _at} =
      Enum.reduce_while(spans, {[], first}, fn {a, b}, {out, at} ->
        if b < at do
          {:cont, {out, at}}
        else
          gap_end = min(a - 1, last)
          out = out ++ cut(at, gap_end, chunk)
          at = max(next_after(at, gap_end), b + 1)
          if at > last, do: {:halt, {out, at}}, else: {:cont, {out, at}}
        end
      end)

    out
  end

  defp next_after(at, gap_end), do: max(at, gap_end + 1)

  defp cut(at, gap_end, _chunk) when at > gap_end, do: []

  defp cut(at, gap_end, chunk) do
    stop = min(at + chunk - 1, gap_end)
    [{at, stop} | cut(stop + 1, gap_end, chunk)]
  end

  def load_state(path, default) do
    case File.read(path) do
      {:ok, bin} -> JSON.decode!(bin)
      {:error, _} -> default
    end
  end

  def save_state(path, state) do
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(state))
    File.rename!(tmp, path)
  end

  @doc """
  Drops the BEAM to below-normal priority on Windows, so the test processes it
  starts inherit it. Elsewhere the caller can `nice` the whole thing.
  """
  def lower_priority do
    if match?({:win32, _}, :os.type()) do
      System.cmd("powershell", [
        "-NoProfile",
        "-Command",
        "(Get-Process -Id #{System.pid()}).PriorityClass = 'BelowNormal'"
      ])
    end

    :ok
  end

  @doc "One `mix test` run on one core. Returns {exit code, output, seconds}."
  def mix_test(repo, env, args) do
    t0 = System.monotonic_time(:millisecond)

    {out, code} =
      System.cmd("mix", ["test" | args],
        cd: repo,
        env: [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 1:1"} | env],
        stderr_to_stdout: true
      )

    {code, out, Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)}
  end

  def tail(out, n \\ 6000) do
    size = byte_size(out)
    if size <= n, do: out, else: binary_part(out, size - n, n)
  end

  def hms do
    {_, {h, m, s}} = :calendar.local_time()
    IO.iodata_to_binary(:io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]))
  end

  @doc """
  Runs `workers` workers over `queue` (a list of {first, last}).

    * `:exec`      fn {first, last} -> {code, output, secs}
    * `:on_result` fn {first, last}, {code, output, secs}, state ->
                     {state, requeue (list of chunks, run next), messages}
    * `:progress`  fn state, queue -> line
    * `:stop?`     fn -> boolean, asked before each chunk starts
  Returns the final state.
  """
  def run(queue, state, state_path, workers, opts) do
    {:ok, agent} = Agent.start_link(fn -> {queue, state} end)
    stop? = Keyword.get(opts, :stop?, fn -> false end)

    pop = fn ->
      Agent.get_and_update(agent, fn
        {[], s} ->
          {nil, {[], s}}

        {[chunk | rest], s} ->
          if stop?.(), do: {:stop, {[chunk | rest], s}}, else: {chunk, {rest, s}}
      end)
    end

    loop = fn loop ->
      case pop.() do
        nil ->
          :ok

        :stop ->
          IO.puts("stop file exists - not starting another chunk")

        chunk ->
          result = opts[:exec].(chunk)

          Agent.update(agent, fn {q, s} ->
            {s, requeue, messages} = opts[:on_result].(chunk, result, s)
            q = requeue ++ q
            save_state(state_path, s)
            Enum.each(messages, &IO.puts/1)
            IO.puts(opts[:progress].(s, q))
            {q, s}
          end)

          loop.(loop)
      end
    end

    1..workers
    |> Task.async_stream(fn _ -> loop.(loop) end, timeout: :infinity, ordered: false)
    |> Stream.run()

    {_q, final} = Agent.get(agent, & &1)
    final
  end
end

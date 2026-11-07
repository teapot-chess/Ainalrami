defmodule Ainalrami.Test.Chesspairing do
  @moduledoc """
  Thin wrapper for Gert Nutterts' chesspairing
  (<https://github.com/gnutterts/chesspairing>, Go, Apache-2.0), used by
  `Ainalrami.TeamThreeWayTest` as the third C.04.6 team engine beside
  Ainalrami and Gacrux.

  NOT vendored, like the other references. Built from source on the
  machine that runs the comparison (`go build ./cmd/chesspairing`, no
  dependencies) and located via `CHESSPAIRING_EXE`.

  ## Invocation and output

  `chesspairing pair --team FILE` reads a TRF-2026 team file (the system
  and the C.04.6 settings come from the `192` code, the initial colour
  from `152`, the round count from `142`) and pairs the round after the
  last one in it. The list format is a count line and one `white black`
  per match, the team with White on board 1 first.

  It does NOT print the team given the pairing-allocated bye: the CLI
  writes `result.Byes` and the team pairer puts the bye in
  `result.TeamByes`, which no output format writes. So the bye is read as
  the one team of the field missing from the pairs. The harness gives it
  files in which every team is in the field, so that is well defined; two
  or more teams missing is reported as an error, not guessed at.

  Exit 1 is "no valid pairing could be produced"; every other non-zero
  exit is an error.
  """

  def exe, do: System.get_env("CHESSPAIRING_EXE", "chesspairing")

  def available?, do: System.find_executable(exe()) != nil or File.exists?(exe())

  @doc """
  Pairs the round after the file's last. `teams` is the field (every team
  number of the file). Returns `{:ok, [{white, black | nil}]}`,
  `:refused`, or `{:error, detail}`.
  """
  def pair(trf_text, teams) do
    dir = Path.join(System.tmp_dir!(), "ainalrami-cp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "input.trf")

    try do
      File.write!(input, trf_text)

      case run(["pair", "--team", input]) do
        {out, 0} -> parse(out, teams)
        {_out, 1} -> :refused
        {out, 124} -> {:error, {:timeout, String.trim(out)}}
        {out, code} -> {:error, {code, String.trim(out)}}
      end
    after
      File.rm_rf(dir)
    end
  end

  # Same two guards as `Ainalrami.Test.Gacrux.run/1`: stdin at EOF, and a
  # bound on one invocation. stderr is kept apart: it carries warnings.
  defp run(args) do
    timeout = System.get_env("CHESSPAIRING_TIMEOUT", "180")

    if File.exists?("/bin/sh") do
      wrapper = "exec timeout #{String.to_integer(timeout)} \"$0\" \"$@\" < /dev/null 2>&1"
      System.cmd("/bin/sh", ["-c", wrapper, exe() | args])
    else
      System.cmd(exe(), args, stderr_to_stdout: true)
    end
  end

  defp parse(out, teams) do
    lines =
      out
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reject(&String.starts_with?(&1, "warning"))

    with [count | rest] <- lines,
         {n, ""} <- Integer.parse(count),
         true <- length(rest) == n,
         {:ok, pairs} <- pairs(rest) do
      seated = Enum.flat_map(pairs, fn {w, b} -> [w, b] end)

      case teams -- seated do
        [] -> {:ok, pairs}
        [bye] -> {:ok, pairs ++ [{bye, nil}]}
        missing -> {:error, {:teams_missing, missing, out}}
      end
    else
      _ -> {:error, {:unreadable, out}}
    end
  end

  defp pairs(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      with [w, b] <- String.split(line),
           {w, ""} <- Integer.parse(w),
           {b, ""} <- Integer.parse(b) do
        {:cont, {:ok, acc ++ [{w, if(b == 0, do: nil, else: b)}]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end
end

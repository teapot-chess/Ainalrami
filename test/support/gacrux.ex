defmodule Ainalrami.Test.Gacrux do
  @moduledoc """
  Thin wrapper for invoking Otto Milvang's `pairingchecker.py` (the pairing
  half of the FIDE Tie Break Server, gacrux.no) locally - the THIRD
  independent Dutch implementation this project compares against, after
  `Ainalrami.Test.Javafo` and `Ainalrami.Test.Bbppairings`.

  Worth having for two reasons the other two cannot cover.

  It implements a NEWER rulebook. `pairingdutch.py` carries

      DUTCH_RULES = { 0: "2022-01-01",
                      1: "2026-02-01" }  # Approved by FIDE Council on 01/02/2026

  and selects the 2026 one. bbpPairings 6.0.0 also implements the revised
  rules ("the 2025 rules ... effective date delayed to 2026"), but JaVaFo
  2.2 predates them, so without this there is no way to tell a genuine
  disagreement from a rulebook difference.

  And it breaks ties. Most of this engine's remaining disagreements are
  cases where several pairings satisfy every documented criterion equally
  and the reference simply picked one; with two references a tie is a
  coin-toss between them, with three it is a majority.

  NOT vendored, same reasoning as the other two - third-party source that
  is not ours to redistribute. Located via `GACRUX_DIR`, defaulting to a
  sibling checkout of <https://github.com/OttoMilvang/TieBreakServer>.
  Its only dependency is `networkx`.

  ## Output format

  Confirmed by direct invocation, not assumed: `-p -dT` writes the same
  shape javafo and bbpPairings do - a count line, then one `white black`
  per pair, `0` for a pairing-allocated bye - so `parse_output/1` is the
  same logic as theirs.
  """

  def dir_path, do: System.get_env("GACRUX_DIR", "../TieBreakServer")

  def script_path, do: Path.join(dir_path(), "pairingchecker.py")

  def python_bin, do: System.get_env("GACRUX_PYTHON", "python")

  def available?, do: File.exists?(script_path())

  @doc """
  Runs the pairing mode (`-p -dT -m dutch`) on `trf_text` and returns:

    * `{:ok, pairs}` - `[{white_rank, black_rank | nil}]`, the same
      convention the other two wrappers and `Ainalrami.Pairing` all use
    * `{:no_valid_pairing, output}` - it produced no pairs at all, which
      is how it reports a round with no legal completion
    * `{:crashed, detail}` - it raised inside the checker and wrote
      `### Error 510` into its output file. Missing data, not an answer;
      see `classify/4`
    * `{:error, {code, output}}` - anything else
  """
  def pair(trf_text, round \\ nil) do
    dir = Path.join(System.tmp_dir!(), "ainalrami-gacrux-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "input.trf")
    output = Path.join(dir, "output.txt")

    try do
      File.write!(input, trf_text)

      args =
        [script_path(), "-i", input, "-o", output, "-p", "-dT", "-m", "dutch"] ++
          round_args(round)

      case run(args) do
        {out, 0} ->
          case File.read(output) do
            {:ok, text} -> classify(text, out, input, round)
            {:error, _} -> {:no_valid_pairing, out}
          end

        {out, 124} ->
          {:error, {:timeout, "no answer in #{timeout_seconds()}s: " <> String.trim(out)}}

        {out, code} ->
          {:error, {code, out}}
      end
    after
      remove_dir(dir)
    end
  end

  # `round` is the round being paired and MUST be passed by any caller that
  # knows it. Without `-n R` Gacrux pairs "1 + the last round that holds an
  # over-the-board game" (`trf2json.py:699-706`; `+`, `-` and byes are not
  # played games), so after a round of forfeits and byes only it re-pairs
  # THAT round and returns the pairing already in the file. Every
  # Ainalrami-versus-Gacrux "disagreement" recorded before 2026-10-25 was
  # that artefact. `nil` keeps the old behaviour for callers that do not
  # know the round.
  defp round_args(nil), do: []

  defp round_args(round) when is_integer(round) and round > 0,
    do: ["-n", Integer.to_string(round)]

  # Two things `System.cmd/3` cannot express on its own, both learned the
  # expensive way: a validation run wedged silently at 19:50 and was still
  # wedged two hours later, having produced nothing and reported nothing.
  #
  # **stdin must be at EOF.** `System.cmd` gives the child a pipe for stdin
  # and never closes the write end, so any read on fd 0 blocks forever.
  # Gacrux reads stdin on paths this harness does not deliberately take -
  # `commonmain.py` does it whenever it decides the input file is `-` - and
  # 36 workers each blocked in `read(0, ...)` is a run that never finishes
  # and never fails. Confirmed from `/proc/<pid>/syscall`: syscall 0, fd 0,
  # a pipe.
  #
  # **A single invocation must not be able to stall the run.** `timeout`
  # bounds it and exit 124 becomes a reported error, so a hang costs one
  # round and a loud failure instead of a whole night.
  #
  # Both are POSIX, which is fine: Gacrux needs `networkx` and only ever
  # runs on the Linux box. The direct call stays as the fallback so the
  # module still loads and still reports honestly anywhere else.
  defp run(args) do
    if File.exists?("/bin/sh") do
      wrapper = "exec timeout #{timeout_seconds()} \"$0\" \"$@\" < /dev/null"
      System.cmd("/bin/sh", ["-c", wrapper, python_bin() | args], stderr_to_stdout: true)
    else
      System.cmd(python_bin(), args, stderr_to_stdout: true)
    end
  end

  @doc """
  How long a single Gacrux invocation may take before it is killed.

  Generous by default - a 120-player field genuinely takes it a while - and
  raiseable for a large-field axis via `GACRUX_TIMEOUT`. It exists to bound
  a HANG, not to police slowness.
  """
  # Validated because the value is spliced into a `sh -c` string, and it is
  # the one thing in that call that is not passed as `"$0" "$@"`. It is
  # test-only and operator-set, so this is not a vulnerability so much as
  # the last unchecked interpolation in the harness - and an operator who
  # exports `GACRUX_TIMEOUT=3m` (which `timeout` itself would accept, but
  # nothing here validates) deserves to be told rather than to have `sh`
  # decide what the rest of the line means.
  def timeout_seconds do
    value = System.get_env("GACRUX_TIMEOUT", "180")

    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 ->
        seconds

      _ ->
        raise ArgumentError,
              "GACRUX_TIMEOUT must be a positive whole number of seconds, got #{inspect(value)}"
    end
  end

  # Gacrux reports failure INSIDE the output file, with exit status 0:
  # `commonmain.py:289` writes `### Error <code>` there and leaves the
  # process successful. Reading that as a pairing is what
  # `binary_to_integer("Program")` was - a crash that took a whole run down,
  # found on seed 21 with byes on.
  #
  # 510 USED to be treated as "no legal pairing here", on the argument that
  # the assumption was being measured rather than hidden: the three-way
  # harness records every round where one reference refuses while the other
  # pairs, so a wrong reading would surface as a pile of exhaustion splits.
  #
  # It did, and the assumption is now falsified - though not in the way it
  # first appeared, and the difference matters. The 2026-08-24 run produced
  # 234 such splits; re-running Gacrux on every one found 203 were
  # `### Error 510` and 31 a genuinely empty pairing list. Under `-v` Gacrux
  # re-raises instead of swallowing, and all 60 sampled 510s were the same
  # exception, `crosstabledutch.py:253 KeyError: 'n'`, which read like a
  # single bug. That sample was biased by construction: a split is only
  # DUMPED when bbpPairings paired the position, so it can only ever contain
  # the crash that fires on pairable positions. Sampled without that filter,
  # 510 has at least three sites and they do not mean the same thing:
  #
  #     pairingdutch.py:314    `if len(edges) == 0: raise` - a bare `raise`
  #                            with no active exception, so it always throws
  #                            RuntimeError. It is where Gacrux means "this
  #                            bracket has no pairable edges", and
  #                            bbpPairings independently found no legal
  #                            pairing on 196 of 196 of them.
  #
  #     crosstabledutch.py:253 `{"w": "bb", "b": "ww", " ": "nc"}[acop[0]]`,
  #                            where `color_preference` (`crosstable.py:80`)
  #                            returns the STRING `"nc"`, so `acop[0]` is
  #                            `?n` and a dict whose only no-preference key
  #                            is `" "` raises. Dead code - `opp` is
  #                            recomputed two lines down inside the guard
  #                            that needs it - in the topscorer branch, so
  #                            it takes a last round plus a topscorer with
  #                            no colour history. bbpPairings paired 2 of 2.
  #
  #     pairingdutch.py:465    KeyError `rem_hamilton`. Rare; both observed
  #                            were positions bbpPairings also refuses.
  #
  #     pairing.py:216         `breakpoint()` then a bare `raise` - the same
  #                            idiom as 314, and a STRAY DEBUGGER CALL left
  #                            in the shipped code. There are 28 of them
  #                            across the tree. It drops the process into
  #                            pdb, which reads stdin; with stdin at
  #                            /dev/null pdb hits EOF and the run dies with
  #                            no traceback, which is why these arrive as a
  #                            bare "### Error 510". WITHOUT the /dev/null
  #                            guard in `run/1` it would block on fd 0
  #                            forever - so that guard is load-bearing, and
  #                            this is very likely what wedged the first
  #                            validation attempt for two silent hours.
  #
  # 510 is a CATCH-ALL - `do_command` turns any exception raised inside the
  # checker into `error(510, "Program error")` - so at THIS layer it means
  # "Gacrux fell over", full stop, and nothing more may be inferred here.
  # Deciding which crashes cost something needs the other engine's answer,
  # which this module does not have, so it reports the crash and the site
  # and leaves the judgement to the caller that can make it.
  #
  # Every other code is a real failure - a bad command line, an unreadable
  # input, a method it does not implement - and stays an error, so a harness
  # stops rather than quoting a rate built on whatever survived.
  defp classify(text, out, input, round) do
    case Regex.run(~r/^###\s+Error\s+(\d+)/m, text) do
      nil -> classify_pairs(parse_output(text), out)
      [_, "510"] -> {:crashed, crash_detail(input, text, round)}
      [_, code] -> {:error, {String.to_integer(code), String.trim(text) <> out}}
    end
  end

  # Being able to say WHICH crash is what turned "Gacrux refuses a lot of
  # positions" into "Gacrux has one bug at a known line", so it is worth a
  # second invocation - but only on the crash path, which has already
  # produced nothing. The normal path never runs this. `GACRUX_TRACEBACK=0`
  # switches it off for an axis where crashes are expected to be common.
  defp crash_detail(input, text, round) do
    if System.get_env("GACRUX_TRACEBACK", "1") in ["1", "true"] do
      traceback(input, round) || String.trim(text)
    else
      String.trim(text)
    end
  end

  # `-v` makes `do_command` re-raise instead of writing the error page, so
  # the exception reaches stderr. Anything unexpected here returns `nil` and
  # the caller falls back to the error page: a failure to explain a crash
  # must not become a second crash.
  defp traceback(input, round) do
    args =
      [script_path(), "-i", input, "-o", input <> ".v.out", "-p", "-dT", "-m", "dutch", "-v"] ++
        round_args(round)

    {out, _code} = run(args)

    lines = out |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    exception_frame(lines) || pdb_frame(lines)
  rescue
    _ -> nil
  end

  defp exception_frame(lines) do
    frame =
      lines
      |> Enum.filter(&String.starts_with?(&1, "File \""))
      |> List.last()

    with frame when is_binary(frame) <- frame,
         [_, file, line] <- Regex.run(~r/File "(?:.*[\/\\])?([^\/\\"]+)", line (\d+)/, frame) do
      "#{file}:#{line}  #{List.last(lines)}"
    else
      _ -> nil
    end
  end

  # A stray `breakpoint()` is not an exception, so it leaves no traceback -
  # just pdb's banner. Naming the frame anyway is what turns 600 identical
  # "### Error 510" lines into one actionable sentence.
  defp pdb_frame(lines) do
    lines
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^> (?:.*[\/\\])?([^\/\\(]+\.py)\((\d+)\)(\S*)/, line) do
        [_, file, num, fun] -> "#{file}:#{num}  breakpoint() dropped into pdb in #{fun}"
        _ -> nil
      end
    end)
  end

  defp classify_pairs({:error, reason}, _out), do: {:error, {0, reason}}
  defp classify_pairs([], out), do: {:no_valid_pairing, out}
  defp classify_pairs(pairs, _out), do: {:ok, pairs}

  # See `Ainalrami.Test.Javafo`'s identical helper for why this retries
  # instead of a plain `File.rm_rf!/1` - same Windows transient-handle
  # cause, same fix.
  defp remove_dir(dir, attempts_left \\ 5)

  defp remove_dir(_dir, 0), do: :ok

  defp remove_dir(dir, attempts_left) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, _reason, _path} ->
        Process.sleep(20)
        remove_dir(dir, attempts_left - 1)
    end
  end

  defp parse_output(text) do
    case text |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == "")) do
      [] ->
        []

      [_count | lines] ->
        lines
        |> Enum.reduce_while([], fn line, acc ->
          case parse_pair(line) do
            {:ok, pair} -> {:cont, [pair | acc]}
            :error -> {:halt, {:error, "unreadable pairing line: " <> inspect(line)}}
          end
        end)
        |> case do
          {:error, _} = error -> error
          pairs -> Enum.reverse(pairs)
        end
    end
  end

  # Returns `{:ok, pair}` or `:error` rather than matching and converting
  # inline. The inline version raised from inside a `Task`, which killed the
  # whole run instead of reporting one bad round.
  defp parse_pair(line) do
    with [w, b] <- line |> String.trim() |> String.split(~r/\s+/),
         {white, ""} <- Integer.parse(w),
         {black, ""} <- Integer.parse(b) do
      {:ok, {white, if(black == 0, do: nil, else: black)}}
    else
      _ -> :error
    end
  end
end

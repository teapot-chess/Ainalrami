defmodule Ainalrami.CliSweep0901Test do
  @moduledoc """
  The CLI half of the 2026-09-01 sweep: H2 (a `260` line crashed the trace),
  H3 (input and output being the same path destroyed the tournament), and the
  `run/1` backstop that turns an unexpected exception into this program's own
  "message, then a non-zero exit" contract instead of a stack trace.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log}

  setup do
    on_exit(fn -> Log.set_level(:normal) end)
  end

  defp tmp_path(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_sweep0901_#{System.unique_integer([:positive])}#{suffix}"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  # Both streams, as `cli_options_test.exs` does: the trace and the errors go
  # to stderr, the pairing output to stdout, and reading one alone proves
  # nothing about the other.
  defp run(argv) do
    out =
      capture_io(fn ->
        err = capture_io(:stderr, fn -> send(self(), {:code, CLI.run(argv)}) end)
        send(self(), {:stderr, err})
      end)

    assert_received {:code, code}
    assert_received {:stderr, err}

    {code, out, err}
  end

  # A four-player round-one roster carrying one `260` group. Columns per
  # `readForbiddenPairs260`: first round 5-7, last round 9-11, then
  # four-character starting ranks from column 13 every five.
  defp roster_with_260 do
    """
    012 Sweep 0901\r
    062 4\r
    XXR 5\r
    152 W\r
    001    1 m  gm Alpha                            2400 BEL     1000001 1990/01/01  0.0    1\r
    001    2 m  gm Beta                             2300 BEL     1000002 1990/01/01  0.0    2\r
    001    3 m  gm Gamma                            2200 BEL     1000003 1990/01/01  0.0    3\r
    001    4 m  gm Delta                            2100 BEL     1000004 1990/01/01  0.0    4\r
    """ <> line_260("1", "3", "1", "3")
  end

  defp line_260(first, last, a, b) do
    "260 " <>
      String.pad_leading(first, 3) <>
      " " <>
      String.pad_leading(last, 3) <>
      " " <> String.pad_leading(a, 4) <> " " <> String.pad_leading(b, 4) <> "\r\n"
  end

  defp write_260_file! do
    path = tmp_path(".trf")
    File.write!(path, roster_with_260())
    path
  end

  describe "H2 - a 260 line in the trace" do
    test "-p reports the forbidden group instead of raising on the tuple" do
      input = write_260_file!()
      output = tmp_path(".out")

      {code, out, _err} = run([input, "-p", output])

      assert code == 0
      assert out =~ "forbidden pairing: #1 / #3"
      assert out =~ "rounds 1-3"
      # The pairing itself still happened, and honoured the group.
      assert File.read!(output) =~ "2\r\n"
      refute File.read!(output) =~ "1 3\r\n"
    end

    test "-x reports the forbidden group instead of raising on the tuple" do
      input = write_260_file!()

      {code, out, _err} = run([input, "-x"])

      assert code == 0
      assert out =~ "forbidden pairing: #1 / #3"
    end
  end

  describe "H2 - run/1's backstop" do
    test "an unexpected exception is reported as a usage error, not a stack trace" do
      # A file that parses but whose `142` claims more rounds of history than
      # the players carry is not the point here; the point is that ANY
      # unexpected raise from below `run/1` comes back as an exit code. A
      # directory handed in where a file is expected is the cheapest such
      # raise: `File.write!` on it raises `File.Error`.
      #
      # Was the cheapest. Since sweep 2026-11b (AIN4-7) a write that fails is
      # an ordinary error with the output's name, which is what the backstop
      # was standing in for; the contract - exit 1, a message, no trace - is
      # the same either way.
      input = write_260_file!()
      output = tmp_path("_dir")
      File.mkdir_p!(output)
      on_exit(fn -> File.rm_rf(output) end)

      {code, _out, err} = run([input, "-p", output])

      assert code == 1
      assert err =~ "could not write #{output}"
      refute err =~ "** (File.Error)"
    end
  end

  describe "H3 - refusing to write over the input" do
    test "-p with the input path as output is refused and leaves the file intact" do
      input = write_260_file!()
      before = File.read!(input)

      {code, _out, err} = run([input, "-p", input])

      assert code == 1
      assert err =~ "output file is the input file"
      assert File.read!(input) == before
    end

    test "-p refuses a differently spelled path that resolves to the input" do
      input = write_260_file!()
      before = File.read!(input)
      indirect = Path.join([Path.dirname(input), ".", Path.basename(input)])

      {code, _out, err} = run([input, "-p", indirect])

      assert code == 1
      assert err =~ "output file is the input file"
      assert File.read!(input) == before
    end

    test "-g refuses to overwrite a file it is also reading nothing from" do
      # `-g` has no input, so the only same-path hazard it has is writing
      # into a directory; it must still refuse rather than raise.
      output = tmp_path("_gdir")
      File.mkdir_p!(output)
      on_exit(fn -> File.rm_rf(output) end)

      {code, _out, err} = run(["-g", output, "--players=8", "--rounds=2", "--seed=1"])

      assert code == 1
      assert err =~ "could not write"
    end

    test "a normal -p write still works and lands atomically" do
      input = write_260_file!()
      output = tmp_path(".out")

      {code, _out, _err} = run([input, "-p", output])

      assert code == 0
      assert File.read!(output) =~ ~r/\A2\r\n/
      # No temp file left behind in the directory.
      leftovers =
        output
        |> Path.dirname()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, Path.basename(output) <> "."))

      assert leftovers == []
    end

    test "-g writing over its own output path is fine (there is no input)" do
      output = tmp_path(".trf")

      {code, _out, _err} = run(["-g", output, "--players=8", "--rounds=2", "--seed=7"])

      assert code == 0
      assert File.read!(output) =~ "012 Ainalrami RTG seed=7"
    end
  end
end

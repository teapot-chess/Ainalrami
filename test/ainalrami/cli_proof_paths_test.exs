defmodule Ainalrami.CliProofPathsTest do
  @moduledoc """
  `--proof=FILE` pointed at the input or at `-p`'s output: refused before
  anything is opened, so a refused run leaves every file as it was. Before
  this, the input became a proof and a proof became a board list, both with
  exit 0.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log}

  @fixture "test/fixtures/c2_seed8112174-r9-p18.trf"

  setup do
    on_exit(fn -> Log.set_level(:normal) end)
  end

  defp tmp_path(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_proof_paths_#{System.unique_integer([:positive])}#{suffix}"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp input! do
    path = tmp_path(".trf")
    File.cp!(@fixture, path)
    path
  end

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

  test "--proof at the input path is refused and the input is untouched" do
    input = input!()
    before = File.read!(input)
    output = tmp_path(".txt")

    {code, _out, err} = run([input, "-p", output, "--proof=#{input}"])

    assert code == 1
    assert err =~ "the --proof file"
    assert err =~ "is the input file"
    assert File.read!(input) == before
    refute File.exists?(output)
  end

  test "--proof at the input path is refused when -p writes to stdout" do
    input = input!()
    before = File.read!(input)

    {code, out, err} = run([input, "-p", "--proof=#{input}"])

    assert code == 1
    assert err =~ "is the input file"
    refute out =~ ~r/^\d+ \d+\r?$/m
    assert File.read!(input) == before
  end

  test "--proof at a differently spelled input path is refused" do
    input = input!()
    before = File.read!(input)
    indirect = Path.join([Path.dirname(input), ".", Path.basename(input)])

    {code, _out, err} = run([input, "-p", "--proof=#{indirect}"])

    assert code == 1
    assert err =~ "is the input file"
    assert File.read!(input) == before
  end

  test "--proof at the output path is refused and an existing output is untouched" do
    input = input!()
    output = tmp_path(".txt")
    File.write!(output, "previous boards\n")

    {code, _out, err} = run([input, "-p", output, "--proof=#{output}"])

    assert code == 1
    assert err =~ "is the output file"
    assert File.read!(output) == "previous boards\n"
  end

  if match?({:win32, _}, :os.type()) or match?({:unix, :darwin}, :os.type()) do
    test "on case-blind systems a path differing only in case is the same file" do
      input = input!()
      before = File.read!(input)

      {code, _out, err} = run([input, "-p", "--proof=#{String.upcase(input)}"])

      assert code == 1
      assert err =~ "is the input file"
      assert File.read!(input) == before
    end
  end

  test "distinct proof, input and output still pair and write all three" do
    input = input!()
    before = File.read!(input)
    output = tmp_path(".txt")
    proof = tmp_path(".jsonl")

    {code, _out, _err} = run([input, "-p", output, "--proof=#{proof}"])

    assert code == 0
    assert File.read!(input) == before
    assert File.read!(output) =~ ~r/^\d+\r?\n/
    assert File.read!(proof) =~ ~s("format":"ainalrami-pairing-proof")
  end
end

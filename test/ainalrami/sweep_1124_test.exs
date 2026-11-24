defmodule Ainalrami.Sweep1124Test do
  @moduledoc """
  Sweep 2026-11b: the CLI's arguments and the reader's roster (AIN4-1,
  AIN4-4 to AIN4-8).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Trf}

  # A `001` line in the spec's columns: rank 5-8, name 15-48, rating 49-52,
  # points 81-84, final rank 86-89, round 1 from 92.
  defp player(rank, games \\ "") do
    field = String.pad_leading(to_string(rank), 4)

    "001 " <>
      field <>
      String.duplicate(" ", 6) <>
      String.pad_trailing("P#{rank}", 34) <>
      "2000" <> String.duplicate(" ", 29) <> "0.0 " <> field <> games
  end

  defp file(lines, header \\ ["XXR 5"]),
    do: Enum.join(["012 Sweep" | header] ++ lines, "\n") <> "\n"

  defp roster, do: file(for rank <- 1..4, do: player(rank))

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

  defp tmp_path(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ainalrami_1124_#{System.unique_integer([:positive])}#{suffix}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp input(text \\ roster()) do
    path = tmp_path(".trf")
    File.write!(path, text)
    path
  end

  describe "AIN4-1: more file names than the mode uses" do
    test "-g after an input file refuses, and leaves the input alone" do
      in_path = input()
      out_path = tmp_path(".trf")

      {code, _out, err} = run([in_path, "-g", out_path, "--players=6", "--rounds=2"])

      assert code == 1
      assert err =~ "-g takes at most one file name"
      assert File.read!(in_path) == roster()
      refute File.exists?(out_path)
    end

    for {mode, names} <- [{"-c", 2}, {"-x", 2}, {"-p", 3}, {"-s", 3}] do
      test "#{mode} with #{names} file names refuses" do
        names = [input() | for(_ <- 2..unquote(names)//1, do: tmp_path(".out"))]

        {code, _out, err} = run(names ++ [unquote(mode), "--tie-breaks=BH"])

        assert code == 1
        assert err =~ "#{unquote(mode)} takes"
      end
    end

    test "-p with an input and an output still pairs" do
      out_path = tmp_path(".out")
      assert {0, _, _} = run([input(), "-p", out_path])
      assert File.read!(out_path) =~ ~r/^2\r\n/
    end
  end

  describe "AIN4-8: two modes at once" do
    for modes <- [["-p", "-c"], ["-g", "-p"], ["-x", "-s"], ["--explain", "--standings"]] do
      test "#{Enum.join(modes, " ")} is refused" do
        {code, _out, err} = run([input() | unquote(modes)])
        assert code == 1
        assert err =~ "one mode at a time"
      end
    end

    test "-x and --explain are one mode" do
      assert {0, _, _} = run([input(), "-x", "--explain"])
    end
  end

  describe "AIN4-4: a starting rank given twice" do
    test "is refused by the reader, naming the second line" do
      text = file([player(1), player(2), player(2, "     1 b 0"), player(3)])

      assert_raise Trf.ValidationError, ~r/duplicate starting rank 2 .*1 b 0/, fn ->
        Trf.parse(text)
      end
    end

    test "-s refuses rather than keeping one of them" do
      text = file([player(1), player(2), player(2), player(3)])
      {code, _out, err} = run([input(text), "-s", "--tie-breaks=BH"])
      assert code == 1
      assert err =~ "invalid TRF file: 001: duplicate starting rank 2"
    end
  end

  describe "AIN4-5: a file with no player records" do
    for {label, text} <- [
          empty: "",
          binary: <<0, 159, 146, 150, 255, 1, 2, 3>>,
          header_only: "012 Nobody\nXXR 5\n"
        ] do
      test "#{label} is refused by -p" do
        out_path = tmp_path(".out")
        {code, _out, err} = run([input(unquote(text)), "-p", out_path])

        assert code == 1
        assert err =~ "no player records"
        refute File.exists?(out_path)
      end
    end

    test "-g needs no input and still generates" do
      out_path = tmp_path(".trf")
      assert {0, _, _} = run(["-g", out_path, "--players=6", "--rounds=2", "--seed=1"])
      assert File.read!(out_path) =~ "001"
    end
  end

  describe "AIN4-6: the round count" do
    for {code, value} <- [{"XXR", "-3"}, {"XXR", "1000000"}, {"142", "-1"}, {"142", "1000"}] do
      test "#{code} #{value} is refused" do
        text = file([player(1), player(2)], ["#{unquote(code)} #{unquote(value)}"])

        assert_raise Trf.ValidationError, ~r/round count must be 0\.\.999/, fn ->
          Trf.parse(text)
        end
      end
    end

    test "0 and 999 are still round counts" do
      for value <- [0, 999] do
        parsed = Trf.parse(file([player(1), player(2)], ["XXR #{value}"]))
        assert parsed.tournament[:number_of_rounds] == value
      end
    end

    test "a negative count under --acceleration=baku is an invalid file, not a crash" do
      text = file(for(rank <- 1..4, do: player(rank)), ["XXR -3"])
      {code, _out, err} = run([input(text), "-p", "--acceleration=baku"])
      assert code == 1
      assert err =~ "invalid TRF file"
      refute err =~ "unexpected error"
    end

    test "--rounds is held to the same ceiling" do
      {code, _out, err} = run(["-g", tmp_path(".trf"), "--players=6", "--rounds=1000"])
      assert code == 1
      assert err =~ "--rounds must be at most 999"
    end
  end

  describe "AIN4-7: an output that cannot be written" do
    test "-p names the output, not a temp file, and is no unexpected error" do
      out_path = Path.join([tmp_path(""), "missing", "out.txt"])
      {code, _out, err} = run([input(), "-p", out_path])

      assert code == 1
      assert err =~ "could not write #{out_path}"
      refute err =~ "unexpected error"
      refute err =~ ".tmp"
    end

    test "--proof names the proof file" do
      proof = Path.join([tmp_path(""), "missing", "proof.jsonl"])
      {code, _out, err} = run([input(), "-p", "--proof=#{proof}"])

      assert code == 1
      assert err =~ "could not write #{proof}"
      refute err =~ "unexpected error"
    end
  end
end

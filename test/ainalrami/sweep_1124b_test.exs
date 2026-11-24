defmodule Ainalrami.Sweep1124bTest do
  # Sweep 2026-11b, the three findings that waited for a ruling:
  # AIN4-2 (an opponent with no 001 line), AIN4-3 (`-p` over a round paired
  # but not played) and AIN4-9 (Dubov, Burstein and Lim `-c` with no round
  # count).
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log, Trf}

  @fixtures Path.expand("../fixtures/sweep_2026_11b", __DIR__)

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  describe "AIN4-2: an opponent rank no 001 line carries" do
    test "is refused by the reader, naming the line, the round and the rank" do
      text =
        fixture("round_paired_not_played.trf")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "001    4"))
        |> Enum.join("\n")

      assert_raise Trf.ValidationError,
                   ~r/001 line for starting rank 2 \(P2\), round 1: opponent 4 has no 001 line/,
                   fn -> Trf.parse(text) end
    end

    test "is let through when the caller asks by name (an importer that makes it a bye)" do
      text =
        fixture("round_paired_not_played.trf")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "001    4"))
        |> Enum.join("\n")

      parsed = Trf.parse(text, allow_missing_opponents: true)
      p2 = Enum.find(parsed.players, &(&1[:rank] == 2))
      assert hd(p2.games)[:opponent_rank] == 4
    end

    test "and -p says so and exits 1" do
      dir = Path.join(System.tmp_dir!(), "ain4-2-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "dangling.trf")

      fixture("round_paired_not_played.trf")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "001    4"))
      |> Enum.join("\n")
      |> then(&File.write!(path, &1 <> "\n"))

      {out, code} = cli([path, "-p"])
      assert out =~ "opponent 4 has no 001 line"
      assert code == 1
    end
  end

  describe "AIN4-3: -p after a round paired but not played" do
    test "refuses, naming the round, instead of pairing it again" do
      {out, code} = cli([fixture("round_paired_not_played.trf"), "-p"])

      assert out =~ "round 2 has no results yet"
      assert code == 1
    end

    test "one result entered is enough to pair on" do
      text = File.read!(fixture("round_paired_not_played.trf"))
      # P1 (rank 1) beat P2 in round 2: both sides of board one entered.
      text =
        text
        |> String.replace(~r/^(001    1 .*     2 b ) /m, ~S"\g{1}1")
        |> String.replace(~r/^(001    2 .*     1 w ) /m, ~S"\g{1}0")

      dir = Path.join(System.tmp_dir!(), "ain4-3-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "one_result.trf")
      File.write!(path, text)

      {out, code} = cli([path, "-p"])
      refute out =~ "has no results yet"
      assert code == 0
    end
  end

  describe "AIN4-9: -c with no round count" do
    for system <- ~w(dubov burstein lim) do
      test "#{system}: the rounds in the file are the tournament" do
        path = fixture("no_round_count_#{unquote(system)}.trf")
        refute File.read!(path) =~ ~r/(^|\n)(142|XXR)/

        {out, code} = cli([path, "-c"])
        assert out =~ "5/5 round(s) match"
        assert code == 0
      end
    end
  end
end

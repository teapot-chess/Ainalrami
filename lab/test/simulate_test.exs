defmodule AinalramiLab.SimulateTest do
  use ExUnit.Case, async: true

  alias AinalramiLab.{CLI, Metrics, Report, Simulate, Stats, Tournament, Variant}

  @moduletag :tmp_dir

  test "Wilson and paired intervals" do
    assert %{p: +0.0, lo: +0.0} = w = Stats.wilson(0, 100)
    assert w.hi > 0.03 and w.hi < 0.04
    assert Stats.paired_diff([1, 2, 3], [1, 2, 3]).mean == 0
    d = Stats.paired_diff([0, 0, 0, 0], [1, 1, 1, 1])
    assert d.mean == 1 and d.lo == 1 and Stats.significant?(d)
  end

  test "common random numbers: the same two players in the same round get the same result" do
    spec = %Tournament{players: 6, rounds: 3}
    {a, b} = Tournament.result(spec, 7, 2, 4, 1)
    assert Tournament.result(spec, 7, 2, 1, 4) == {b, a}
  end

  test "metrics of a tournament are finite and the cascade is a bracket count" do
    spec = %Tournament{players: 8, rounds: 5, absent: 0.1}
    t = Tournament.play(spec, :brute, Variant.baseline(), 3)
    m = Metrics.tournament(spec, t)
    assert Enum.sort(Map.keys(m)) == Enum.sort(Metrics.names())
    assert m["cascade"] >= 0 and m["cascade"] <= 5
    assert m["rematches"] == 0
  end

  test "a TRF corpus is replayed round by round" do
    dir = Path.expand("../../verify/test/fixtures/disputes", __DIR__)
    {:trf, paths} = CLI.corpus("trf:" <> dir)

    r =
      Simulate.run(
        variant: Variant.parse("drop:C14"),
        corpus: {:trf, paths},
        pairer: :brute,
        workers: 4
      )

    assert r.corpus.files_read > 0
    assert r.positions.compared > 0
    assert Report.text(r) =~ "same position, both arms"
  end

  test "simulate writes a text and a JSON report", %{tmp_dir: dir} do
    out = Path.join(dir, "run")

    text =
      ExUnit.CaptureIO.capture_io(fn ->
        code =
          CLI.run([
            "simulate",
            "--variant",
            "float_memory=1",
            "--corpus",
            "generated:players=7,rounds=4,count=4",
            "--pairer",
            "brute",
            "--out",
            out
          ])

        send(self(), {:code, code})
      end)

    assert text =~ "float_memory=1"
    assert_received {:code, 0}

    assert %{"variant" => "float_memory=1"} =
             out |> Path.join("report.json") |> File.read!() |> JSON.decode!()
  end

  test "usage errors are exit code 2" do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> send(self(), {:code, CLI.run(["nonsense"])}) end)
    assert_received {:code, 2}
    assert_raise ArgumentError, fn -> CLI.corpus("generated:players=8,colour=blue") end
  end
end

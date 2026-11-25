defmodule Ainalrami.Sweep1125Test do
  # Sweep 2026-11c (fifth sweep).
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log}

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

  describe "AIN5-1: -x after a round paired but not played" do
    test "refuses like -p, instead of explaining the same boards again" do
      {out, code} = cli([fixture("round_paired_not_played.trf"), "-x"])

      assert out =~ "round 2 has no results yet"
      refute out =~ "explaining round 3"
      assert code == 1
    end

    test "--explain is the same mode and refuses the same way" do
      {out, code} = cli([fixture("round_paired_not_played.trf"), "--explain"])

      assert out =~ "round 2 has no results yet"
      assert code == 1
    end
  end
end

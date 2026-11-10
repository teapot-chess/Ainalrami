defmodule Ainalrami.DubovUpfloaterScaleTest do
  @moduledoc """
  3.2.2's upfloater choice on a field where every set of the profile has
  the same rough key (sweep 2026-11, AIN-1): K = 10 players on 2.0 with an
  absolute White preference who cannot meet, and 28 on 1.5 all seeking
  White, so every one of the C(28, 10) = 13,123,110 sets denies 10
  preferences. The set-by-set walk visited all of them (19-38 s); the
  branch and bound stops after the first.

  The expected pairing is the one the full enumeration printed before the
  change, kept as `upfloaters_28_10.pairs`.
  """
  # Not async: `capture_io` and a wall-clock bound.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @dir Path.expand("../fixtures/dubov", __DIR__)

  test "a 114-player round pairs in seconds, as the full enumeration did" do
    trf = Path.join(@dir, "upfloaters_28_10.trf")
    expected = File.read!(Path.join(@dir, "upfloaters_28_10.pairs"))

    {micros, out} =
      :timer.tc(fn -> capture_io(fn -> 0 = Ainalrami.CLI.run([trf, "-p", "-q"]) end) end)

    assert lines(out) == lines(expected)
    # Before: 19-38 s. After: well under a second; the bound is for a busy CI box.
    assert micros < 5_000_000, "took #{div(micros, 1000)} ms"
  end

  defp lines(text), do: String.split(text, ["\r\n", "\n"], trim: true)
end

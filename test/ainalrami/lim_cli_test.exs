defmodule Ainalrami.LimCLITest do
  @moduledoc """
  The command line's Lim system: chosen by `192 CUSTOM_SWISS` with `XXO
  system lim` (reading L11), or `--system=lim`; paired with `-p`, replayed
  with `-c`, generated with `-g`, and refused wherever the Dutch engine's
  own tools were asked of it.
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Generator}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ainalrami_lim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    full = Path.join(dir, "lim.trf")
    {_, _, 0} = cli(["-g", full, "--system=lim", "--players=13", "--rounds=7", "--seed=21"])

    {text, _} = Generator.generate(seed: 4, players: 10, rounds: 4, unset: :fixed, system: :lim)
    partial = Path.join(dir, "partial.trf")
    File.write!(partial, text)

    {:ok, dir: dir, full: full, partial: partial}
  end

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        err = capture_io(:stderr, fn -> Process.put({ref, :code}, CLI.run(args)) end)
        Process.put({ref, :err}, err)
      end)

    {out, Process.get({ref, :err}), Process.get({ref, :code})}
  end

  test "-g --system=lim writes 192 CUSTOM_SWISS and XXO system lim; -c replays it clean", ctx do
    text = File.read!(ctx.full)
    assert text =~ ~r/^192 CUSTOM_SWISS/m
    assert text =~ ~r/^XXO system lim/m
    {out, err, code} = cli([ctx.full, "-c"])
    err = out <> err
    assert code == 0, err
    assert err =~ "the Lim system"
    assert err =~ "7/7 round(s) match"
  end

  test "-c finds a Dutch file passed off as Lim", ctx do
    {dutch, _} = Generator.generate(seed: 21, players: 13, rounds: 7)
    path = Path.join(ctx.dir, "dutch_as_lim.trf")
    File.write!(path, dutch <> "XXO system lim\r\n")
    {_out, err, code} = cli([path, "-c"])
    assert code == 1, err
    assert err =~ "DIFFERS"
  end

  test "-p pairs the next round from the file alone", ctx do
    {out, err, code} = cli([ctx.partial, "-p", "--rounds=7"])
    assert code == 0, err
    assert out =~ "the Lim system (C.04.4.3), round 5"
  end

  test "--system=lim pairs a file with no system record", ctx do
    plain = ctx.partial |> File.read!() |> String.replace(~r/^XXO system lim\r?\n/m, "")
    path = Path.join(ctx.dir, "plain.trf")
    File.write!(path, String.replace(plain, ~r/^192 CUSTOM_SWISS\r?\n/m, ""))
    {out, err, code} = cli([path, "-p", "--rounds=7", "--system=lim"])
    assert code == 0, err
    assert out =~ "the Lim system (C.04.4.3)"
  end

  test "XXO system lim beside a FIDE code, or a contradicting flag, exits 2", ctx do
    text = String.replace(File.read!(ctx.full), "192 CUSTOM_SWISS", "192 FIDE_DUTCH")
    path = Path.join(ctx.dir, "both.trf")
    File.write!(path, text)
    assert {_, err, 2} = cli([path, "-c"])
    assert err =~ "contradicts"
    assert {_, _, 2} = cli([ctx.full, "-c", "--system=dubov"])
  end

  test "--provisional-rating is refused: Lim reads no ratings", ctx do
    {_out, err, code} = cli([ctx.partial, "-p", "--rounds=7", "--provisional-rating=3:1500"])
    assert code == 1
    assert err =~ "Lim reads no ratings"
  end

  test "-x is not explained for Lim", ctx do
    assert {_, _, 2} = cli([ctx.partial, "-x", "--rounds=7"])
  end

  test "the Dutch engine's own flags are refused for Lim", ctx do
    for flag <- ["--proof=x.jsonl", "--cascade-order", "--soft-pairs=1,2", "--bye-exclude=3"] do
      {_out, err, code} = cli([ctx.partial, "-p", "--rounds=7", flag])
      assert code == 1, "#{flag}: #{err}"
      assert err =~ "not for the Lim system", flag
    end
  end

  test "an acceleration is refused: Lim has none", ctx do
    {_out, err, code} = cli([ctx.partial, "-p", "--rounds=7", "--acceleration=baku"])
    assert code == 1, err
    assert err =~ "no acceleration"
  end

  test "-g refuses Lim with the match format", ctx do
    out = Path.join(ctx.dir, "x.trf")
    assert {_, _, 1} = cli(["-g", out, "--system=lim", "--match-format"])
  end
end

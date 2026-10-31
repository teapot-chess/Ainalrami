defmodule Ainalrami.DubovCLITest do
  @moduledoc """
  The command line's Dubov system: chosen by `192 FIDE_DUBOV[_BAKU]` or
  `--system=dubov`, paired with `-p`, replayed with `-c`, generated with
  `-g`, and refused - with the right exit code - wherever the Dutch
  engine's own tools were asked of it.
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Generator}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ainalrami_dubov_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    dubov = Path.join(dir, "dubov.trf")
    {_, _, 0} = cli(["-g", dubov, "--system=dubov", "--players=13", "--rounds=6", "--seed=21"])

    # Four rounds played; -p is given --rounds=6 so there is a fifth to pair.
    {text, _} = Generator.generate(seed: 4, players: 10, rounds: 4, unset: :fixed, system: :dubov)
    partial = Path.join(dir, "partial.trf")
    File.write!(partial, text)

    {dutch_text, _} = Generator.generate(seed: 4, players: 10, rounds: 2, unset: :fixed)
    dutch = Path.join(dir, "dutch.trf")
    File.write!(dutch, dutch_text)

    {:ok, dir: dir, dubov: dubov, partial: partial, dutch: dutch}
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

  test "-g --system=dubov writes 192 FIDE_DUBOV and -c replays it clean", ctx do
    assert File.read!(ctx.dubov) =~ ~r/^192 FIDE_DUBOV/m
    {out, err, code} = cli([ctx.dubov, "-c"])
    err = out <> err
    assert code == 0, err
    assert err =~ "the Dubov system"
    assert err =~ "6/6 round(s) match"
  end

  test "-c finds a doctored round", ctx do
    text = File.read!(ctx.dubov)
    # The other initial colour: round 1's 5.2.1 colours now read wrong.
    flipped =
      if text =~ ~r/^152 W/m,
        do: String.replace(text, ~r/^152 W/m, "152 B"),
        else: String.replace(text, ~r/^152 B/m, "152 W")

    path = Path.join(ctx.dir, "flipped.trf")
    File.write!(path, flipped)
    {_out, err, code} = cli([path, "-c"])
    assert code == 1
    assert err =~ "DIFFERS"
  end

  test "-p pairs the next round from 192 alone", ctx do
    {out, err, code} = cli([ctx.partial, "-p", "--rounds=6"])
    assert code == 0, err
    assert out =~ "the Dubov system (C.04.4.1), round 5"
  end

  test "-p --system=dubov pairs a file with no 192", ctx do
    {out, err, code} = cli([ctx.dutch, "-p", "--rounds=6", "--system=dubov"])
    assert code == 0, err
    assert out =~ "the Dubov system"
  end

  test "--provisional-rating for a rated player is refused", ctx do
    {_out, err, code} =
      cli([ctx.dutch, "-p", "--rounds=6", "--system=dubov", "--provisional-rating=1:1500"])

    assert code == 1
    assert err =~ "already have one"
  end

  test "a malformed --provisional-rating is a usage error", ctx do
    {_out, err, code} =
      cli([ctx.dutch, "-p", "--rounds=6", "--system=dubov", "--provisional-rating=1-1500"])

    assert code == 1
    assert err =~ "RANK:RATING"
  end

  test "--provisional-rating without Dubov is refused", ctx do
    {_out, err, code} = cli([ctx.dutch, "-p", "--rounds=6", "--provisional-rating=1:1500"])
    assert code == 1
    assert err =~ "--system=dubov"
  end

  test "a --system that contradicts 192 is refused with exit 2", ctx do
    {_out, err, code} = cli([ctx.dubov, "-c", "--system=dutch"])
    assert code == 2
    assert err =~ "contradicts"
  end

  test "Lim is not built; an unknown system is a usage error", ctx do
    assert {_, _, 2} = cli([ctx.dutch, "-p", "--rounds=6", "--system=lim"])
    assert {_, err, 1} = cli([ctx.dutch, "-p", "--rounds=6", "--system=monrad"])
    assert err =~ "unknown --system"
  end

  test "-x is the Dutch ladder's and is not explained for Dubov", ctx do
    {_out, _err, code} = cli([ctx.partial, "-x"])
    assert code == 2
  end

  test "the Dutch engine's own flags are refused for Dubov", ctx do
    for flag <- ["--proof=x.jsonl", "--cascade-order", "--soft-pairs=1,2", "--bye-exclude=3"] do
      {_out, err, code} = cli([ctx.partial, "-p", "--rounds=6", flag])
      assert code == 1, "#{flag}: #{err}"
      assert err =~ "not for the Dubov system", flag
    end
  end

  test "-g refuses Dubov with the match format and an unknown system", ctx do
    out = Path.join(ctx.dir, "x.trf")
    assert {_, _, 1} = cli(["-g", out, "--system=dubov", "--match-format"])
    assert {_, _, 1} = cli(["-g", out, "--system=swiss"])
  end
end

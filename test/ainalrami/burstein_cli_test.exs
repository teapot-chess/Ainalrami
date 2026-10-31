defmodule Ainalrami.BursteinCLITest do
  @moduledoc """
  The command line's Burstein system: chosen by `192 FIDE_BURSTEIN[_BAKU]`
  or `--system=burstein`, paired with `-p`, replayed with `-c`, generated
  with `-g`, and refused wherever the Dutch engine's own tools were asked
  of it.
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Generator}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ainalrami_burstein_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    full = Path.join(dir, "burstein.trf")
    {_, _, 0} = cli(["-g", full, "--system=burstein", "--players=13", "--rounds=7", "--seed=21"])

    # Four rounds played (three seeding rounds of seven); a fifth to pair.
    {text, _} =
      Generator.generate(seed: 4, players: 10, rounds: 4, unset: :fixed, system: :burstein)

    partial = Path.join(dir, "partial.trf")
    File.write!(partial, text)

    {dutch_text, _} = Generator.generate(seed: 4, players: 10, rounds: 2, unset: :fixed)
    dutch = Path.join(dir, "dutch.trf")
    File.write!(dutch, dutch_text)

    {:ok, dir: dir, full: full, partial: partial, dutch: dutch}
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

  test "-g --system=burstein writes 192 FIDE_BURSTEIN and -c replays it clean", ctx do
    assert File.read!(ctx.full) =~ ~r/^192 FIDE_BURSTEIN/m
    {out, err, code} = cli([ctx.full, "-c"])
    err = out <> err
    assert code == 0, err
    assert err =~ "the Burstein system"
    assert err =~ "7/7 round(s) match"
  end

  test "-c finds a doctored round", ctx do
    text = File.read!(ctx.full)
    # A Dutch file under the Burstein code: the rounds after seeding differ.
    {dutch, _} = Generator.generate(seed: 21, players: 13, rounds: 7)
    path = Path.join(ctx.dir, "dutch_as_burstein.trf")

    File.write!(
      path,
      String.replace(dutch, ~r/^(012 .*)$/m, "\\1\r\n192 FIDE_BURSTEIN", global: false)
    )

    assert text != File.read!(path)
    {_out, err, code} = cli([path, "-c"])
    assert code == 1, err
    assert err =~ "DIFFERS"
  end

  test "-p pairs the next round from 192 alone", ctx do
    {out, err, code} = cli([ctx.partial, "-p", "--rounds=7"])
    assert code == 0, err
    assert out =~ "the Burstein system (C.04.4.2), round 5"
    refute out =~ "seeding round"
  end

  test "-p in a seeding round says it is the Dutch system's", ctx do
    {out, err, code} = cli([ctx.dutch, "-p", "--rounds=12", "--system=burstein"])
    assert code == 0, err
    assert out =~ "a seeding round, paired by the Dutch system (1.6)"
  end

  test "--provisional-rating is refused: Burstein reads no ratings", ctx do
    {_out, err, code} = cli([ctx.partial, "-p", "--rounds=7", "--provisional-rating=3:1500"])
    assert code == 1
    assert err =~ "Burstein reads no ratings"
  end

  test "a --system that contradicts 192 is refused with exit 2", ctx do
    assert {_, err, 2} = cli([ctx.full, "-c", "--system=dutch"])
    assert err =~ "contradicts"
    assert {_, _, 2} = cli([ctx.full, "-c", "--system=dubov"])
  end

  test "-x is the Dutch ladder's and is not explained for Burstein", ctx do
    assert {_, _, 2} = cli([ctx.partial, "-x", "--rounds=7"])
  end

  test "the Dutch engine's own flags are refused for Burstein", ctx do
    for flag <- ["--proof=x.jsonl", "--cascade-order", "--soft-pairs=1,2", "--bye-exclude=3"] do
      {_out, err, code} = cli([ctx.partial, "-p", "--rounds=7", flag])
      assert code == 1, "#{flag}: #{err}"
      assert err =~ "not for the Burstein system", flag
    end
  end

  test "-g refuses Burstein with the match format", ctx do
    out = Path.join(ctx.dir, "x.trf")
    assert {_, _, 1} = cli(["-g", out, "--system=burstein", "--match-format"])
  end
end

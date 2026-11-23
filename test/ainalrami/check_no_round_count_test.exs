defmodule Ainalrami.CheckNoRoundCountTest do
  # `-c` on a file that never says how many rounds there are: no `142`, no
  # `XXR`. bbpPairings' generator writes exactly such files, and the FE1
  # run on v0.59.0 found 90 tournaments in 5,000 whose final round differed
  # - every time the last one, every time because the checker paired it as
  # if a round 11 were coming and skipped the last round's colour rules.
  #
  # The fixture is one of those 90: fifteen players, ten rounds, written
  # by `bbpPairings --dutch -g`.
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log}

  @fixture Path.expand("../fixtures/no_round_count_last_round.trf", __DIR__)

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  test "the fixture really has no round count" do
    refute File.read!(@fixture) =~ ~r/(^|[\r\n])(142|XXR)/
  end

  test "the rounds in the file are the tournament: the last one is the last round" do
    {out, code} = cli([@fixture, "-c"])

    assert out =~ "10/10 round(s) match"
    assert code == 0
  end

  test "--rounds still says otherwise, and then round 10 is not the last" do
    {out, code} = cli([@fixture, "-c", "--rounds=11"])

    assert out =~ "round 10: DIFFERS"
    assert code == 1
  end
end

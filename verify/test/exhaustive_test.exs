defmodule AinalramiVerify.ExhaustiveTest do
  # Not async: the positive controls bend the reference through the
  # application environment, which every reference in the VM reads.
  use ExUnit.Case, async: false

  alias AinalramiVerify.{Exhaustive, TrfWriter}

  @moduletag :tmp_dir

  defp quiet, do: fn _ -> :ok end

  test "5 players, 3 rounds: every reachable position, no disagreement", %{tmp_dir: dir} do
    s = Exhaustive.run(players: 5, rounds: 3, dir: dir, log: quiet())
    assert s["complete"]
    assert s["disagree"] == 0
    assert s["positions"] > 0
    assert s["agree"] + s["refused_both"] == s["positions"]
    assert File.exists?(Path.join(dir, "summary.json"))
  end

  test "a finished run resumes to the same totals and pairs nothing twice", %{tmp_dir: dir} do
    first = Exhaustive.run(players: 6, rounds: 3, dir: dir, log: quiet())
    again = Exhaustive.run(players: 6, rounds: 3, dir: dir, log: quiet())
    assert Map.drop(first, ["seconds_this_run"]) == Map.drop(again, ["seconds_this_run"])
  end

  test "a run stopped part-way finishes where it stopped", %{tmp_dir: dir} do
    whole = Exhaustive.run(players: 6, rounds: 3, dir: Path.join(dir, "whole"), log: quiet())

    part =
      Exhaustive.run(
        players: 6,
        rounds: 3,
        dir: Path.join(dir, "part"),
        max_jobs: 100,
        log: quiet()
      )

    refute part["complete"]
    rest = Exhaustive.run(players: 6, rounds: 3, dir: Path.join(dir, "part"), log: quiet())
    assert rest["complete"]

    assert Map.take(rest, ~w(positions reached agree disagree refused_both)) ==
             Map.take(whole, ~w(positions reached agree disagree refused_both))
  end

  test "a directory holds one run: other parameters are refused", %{tmp_dir: dir} do
    Exhaustive.run(players: 5, rounds: 3, dir: dir, log: quiet())

    assert_raise ArgumentError, fn ->
      Exhaustive.run(players: 6, rounds: 3, dir: dir, log: quiet())
    end
  end

  test "positions merge on what C.04.3 reads, not on names" do
    # Two round-2 histories that are mirror images of each other in who
    # won are different positions; the same history twice is one.
    r1a = %{1 => {3, :w, "1"}, 3 => {1, :b, "0"}, 2 => {4, :b, "1"}, 4 => {2, :w, "0"}}
    r1b = %{1 => {3, :w, "0"}, 3 => {1, :b, "1"}, 2 => {4, :b, "1"}, 4 => {2, :w, "0"}}
    a = TrfWriter.write(4, [r1a], 3)
    b = TrfWriter.write(4, [r1b], 3)
    assert Exhaustive.position_key(a) == Exhaustive.position_key(TrfWriter.write(4, [r1a], 3))
    refute Exhaustive.position_key(a) == Exhaustive.position_key(b)
  end

  describe "positive controls: a reference with one rule quietly dropped disagrees" do
    # If the comparison could not tell a bent reference from a straight
    # one, its zero would mean nothing.
    for bend <- [:no_c7, :no_c8, :no_c12, :no_c14, :order_last] do
      @tag bend: bend
      test "#{bend}", %{tmp_dir: dir, bend: bend} do
        Application.put_env(:ainalrami_verify, :bend, bend)

        try do
          s = Exhaustive.run(players: 7, rounds: 4, dir: dir, log: quiet())
          assert s["disagree"] > 0
        after
          Application.delete_env(:ainalrami_verify, :bend)
        end
      end
    end
  end
end

defmodule AinalramiLab.VariantsTest do
  use ExUnit.Case, async: true

  alias AinalramiLab.{Brute, Hybrid, Simulate, Tournament, Variant}
  alias AinalramiVerify.{Position, Trf}

  @articles Path.expand("../../verify/test/fixtures/articles", __DIR__)

  defp article(name),
    do: Path.join(@articles, name <> ".trf") |> File.read!() |> Trf.parse() |> Position.build()

  defp plain({:ok, r}), do: {:ok, Enum.sort(r.pairs), r.bye}
  defp plain(e), do: e

  describe "dropping a criterion changes the fixture built to need it" do
    # verify/'s article fixtures are positions where the named criterion
    # separates the best round from a worse one. Dropped, it can no longer
    # decide, and in these nine fixtures the best round changes. In the
    # other eight a lower criterion, or Article 4, happens to land on the
    # same round, and that is recorded below rather than hidden.
    for c <- ~w(C7 C8 C13 C14 C15 C16 C18 C20 C21) do
      test "drop:#{c}" do
        c = unquote(c)
        pos = article(c)
        base = Brute.pair(pos, Variant.baseline())
        dropped = Brute.pair(pos, Variant.parse("drop:" <> c))
        refute plain(base) == plain(dropped)
      end
    end

    test "the eight it does not change stay put" do
      for c <- ~w(C5 C6 C9 C10 C11 C12 C17 C19) do
        pos = article(c)

        assert plain(Brute.pair(pos, Variant.baseline())) ==
                 plain(Brute.pair(pos, Variant.parse("drop:" <> c))),
               c
      end
    end
  end

  test "C12 dropped changes rounds of an ordinary generated corpus" do
    r =
      Simulate.run(
        variant: Variant.parse("drop:C12"),
        corpus: {:generated, %Tournament{players: 8, rounds: 5}, 12},
        pairer: :brute,
        workers: 4
      )

    assert r.positions.pairs_differ.k > 0
    assert r.metrics["denied"].diff.mean > 0
  end

  test "the baseline against itself differs nowhere" do
    r =
      Simulate.run(
        variant: Variant.baseline(),
        corpus: {:generated, %Tournament{players: 7, rounds: 4, absent: 0.1}, 8},
        pairer: :brute,
        workers: 4
      )

    assert r.positions.pairs_differ.k == 0
    assert r.positions.colours_only_differ.k == 0
    for {_, m} <- r.metrics, do: assert(m.diff.mean == 0)
    assert r.examples == []
  end

  test "c525=tpn changes colours, and only colours, when players arrive late" do
    spec = %Tournament{players: 8, rounds: 4, late: 2, forfeit: 0.3}

    r =
      Simulate.run(
        variant: Variant.parse("c525=tpn"),
        corpus: {:generated, spec, 20},
        pairer: :brute,
        workers: 4
      )

    assert r.positions.pairs_differ.k == 0
    assert r.positions.colours_only_differ.k > 0
  end

  describe "the hybrid pairer equals the brute force" do
    for spec <- [
          "baseline",
          "drop:C12",
          "float_memory=1",
          "float_memory=3",
          "move:C14:before:C10",
          "c18=paired",
          "absolute_cd=2",
          "rematches=allowed"
        ] do
      test spec do
        v = Variant.parse(unquote(spec))
        t = %Tournament{players: 8, rounds: 5, absent: 0.1, forfeit: 0.05, late: 1}

        for seed <- 1..5, rec <- Tournament.play(t, :brute, v, seed).rounds do
          assert plain(Hybrid.pair(rec.pos, v)) == plain(rec.result),
                 "seed #{seed} round #{rec.round}"
        end
      end
    end
  end

  test "the hybrid baseline equals the engine on a 24-player field" do
    t = %Tournament{players: 24, rounds: 6, absent: 0.05}

    for seed <- 1..2, rec <- Tournament.play(t, :hybrid, Variant.baseline(), seed).rounds do
      {:ok, e} = AinalramiVerify.Engine.pair(rec.trf)
      assert plain(rec.result) == plain({:ok, e})
    end
  end
end

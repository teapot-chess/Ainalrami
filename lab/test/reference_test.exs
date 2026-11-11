defmodule AinalramiLab.ReferenceTest do
  # The baseline must be verify/'s reference, exactly: same rounds, same
  # colours, same criteria vectors, same legality.
  use ExUnit.Case, async: true

  alias AinalramiLab.{Brute, Rules, Tournament, Variant}
  alias AinalramiVerify.{Bracket, Position, Trf}

  @verify_fixtures Path.expand("../../verify/test/fixtures", __DIR__)

  defp fixture_positions do
    Path.wildcard(Path.join(@verify_fixtures, "**/*.trf"))
    |> Enum.map(fn path -> path |> File.read!() |> Trf.parse() |> Position.build() end)
  end

  defp generated_positions do
    for seed <- 1..12,
        spec <- [
          %Tournament{players: 7, rounds: 5},
          %Tournament{players: 8, rounds: 5, absent: 0.12, forfeit: 0.05, late: 1}
        ],
        rec <- Tournament.play(spec, :brute, Variant.baseline(), seed).rounds,
        do: rec.pos
  end

  defp plain({:ok, r}), do: {:ok, Enum.sort(r.pairs), r.bye}
  defp plain(e), do: e

  test "baseline rounds equal AinalramiVerify.Bracket.pair/1, colours included" do
    positions = fixture_positions() ++ generated_positions()
    assert length(positions) > 140

    for pos <- positions do
      assert plain(Brute.pair(pos, Variant.baseline())) == plain(Bracket.pair(pos)),
             "round #{pos.round} of a #{map_size(pos.players)}-player position"
    end
  end

  test "baseline legality, colours and colour costs equal AinalramiVerify.Rules" do
    v = Variant.baseline()

    for pos <- fixture_positions() ++ Enum.take(generated_positions(), 40),
        a <- pos.pool,
        b <- pos.pool,
        a < b do
      assert Rules.legal?(pos, a, b, v) == AinalramiVerify.Rules.legal?(pos, a, b)
      assert Rules.colours(pos, a, b, v) == AinalramiVerify.Rules.colours(pos, a, b)
      assert Rules.colour_costs(pos, a, b, v) == AinalramiVerify.Rules.colour_costs(pos, a, b)
    end
  end

  test "the baseline's criteria vector equals Bracket.evaluate/3's for every candidate" do
    v = Variant.baseline()

    for pos <- Enum.take(fixture_positions(), 12) ++ Enum.take(generated_positions(), 25) do
      ctx = Brute.context(pos, v)
      groups = Bracket.scoregroups(ctx)
      b = Bracket.bracket(ctx, groups, 0, [])

      for cand <- ctx |> Bracket.candidates(b.players) |> Enum.take(300) do
        assert Brute.evaluate(ctx, b, cand, v) == Bracket.evaluate(ctx, b, cand)
      end

      Bracket.cleanup(ctx)
    end
  end

  test "preferences re-derived with the 2026 thresholds are the position's own" do
    v = Variant.baseline()

    for pos <- Enum.take(generated_positions(), 40), {_, p} <- pos.players do
      assert Rules.preference(p.cd, p.colours, v) == p.pref
    end
  end
end

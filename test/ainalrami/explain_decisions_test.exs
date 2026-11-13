defmodule Ainalrami.ExplainDecisionsTest do
  @moduledoc """
  `Pairing.explain_decisions/2` (docs/dutch-cascade.md, section 10) over
  every TRF fixture and a run of generated tournaments: the pairs are
  `pair_next_round/2`'s, every bracket has a record, and every record says
  how it was decided in the shapes the documentation promises.
  """

  use ExUnit.Case, async: true

  alias Ainalrami.{Generator, Pairing, Trf}

  @fixtures Path.wildcard("test/fixtures/**/*.trf")
  @paths [:idle, :local, :direct, :field, :round_one, :repair]
  @articles ["4.2", "4.3", "4.4", "4.6", "4.7", "4.8"]

  defp check(players, opts, where) do
    pairs = Pairing.pair_next_round(players, opts)
    %{pairs: explained, brackets: brackets} = Pairing.explain_decisions(players, opts)

    assert explained == pairs, "#{where}: explaining changed the pairs"
    # A lone active player takes the bye without a bracket being paired.
    assert brackets != [] or Enum.all?(pairs, &match?({_, nil}, &1)), "#{where}: no records"

    for record <- brackets do
      assert record.path in @paths, "#{where}: path #{inspect(record.path)}"

      if record.path in [:local, :field] do
        assert record.shortcut == nil
      else
        assert %{name: _, guarantee: text} = record.shortcut
        assert is_binary(text)
        assert record.steps == []
      end

      for %{name: _, guarantee: text} <- record.shortcuts, do: assert(is_binary(text))

      for step <- record.steps do
        assert step.filter in @articles
        assert length(step.beat) <= 8

        for %{choice: _, by: by} <- step.beat do
          assert valid_by?(by), "#{where}: by #{inspect(by)}"
        end
      end
    end

    # Every pair the cascade finalised is in exactly one record.
    recorded =
      for r <- brackets, r.path != :repair, {w, b} <- r.pairs, do: Enum.sort([w, b])

    if not Enum.any?(brackets, &(&1.path == :repair)) do
      played = for {w, b} <- pairs, b != nil, do: Enum.sort([w, b])
      assert Enum.sort(recorded) == Enum.sort(played), "#{where}: records miss pairs"
    end

    brackets
  end

  defp valid_by?({:rung, label}) when is_binary(label), do: true
  defp valid_by?({:beyond_window, label}) when is_binary(label), do: true
  defp valid_by?({:absolute, r}) when r in [:rematch, :forbidden, :colour], do: true
  defp valid_by?({:filters, a}) when a in @articles or a == :earlier, do: true
  defp valid_by?(:unknown), do: true
  defp valid_by?(_), do: false

  for path <- @fixtures do
    @path path

    test "#{Path.relative_to(path, "test/fixtures")}" do
      parsed = @path |> File.read!() |> Trf.parse()
      opts = [expected_rounds: 11, forbidden_pairs: parsed.tournament[:forbidden_pairs]]
      check(parsed.players, opts, @path)
    end
  end

  test "generated tournaments, certified sizes included, decide something" do
    steps =
      for seed <- 1..12, reduce: 0 do
        acc ->
          {trf, _} = Generator.generate(seed: seed, players: 20 + 7 * seed)
          parsed = Trf.parse(trf)
          opts = [forbidden_pairs: parsed.tournament[:forbidden_pairs]]
          brackets = check(parsed.players, opts, "seed #{seed}")
          acc + (brackets |> Enum.map(&length(&1.steps)) |> Enum.sum())
      end

    assert steps > 0
  end

  test "round one is one record" do
    players = for r <- 1..9, do: %{rank: r, points: 0, rating: 2000 - r, games: []}

    assert %{brackets: [%{path: :round_one, shortcut: %{name: :round_one}}]} =
             Pairing.explain_decisions(players)
  end

  test "explanations and alternatives answer alike in a fresh process, and leave nothing" do
    {trf, _} = Generator.generate(seed: 77, players: 45)
    parsed = Trf.parse(trf)
    opts = [forbidden_pairs: parsed.tournament[:forbidden_pairs]]

    everything = fn ->
      decisions = Pairing.explain_decisions(parsed.players, opts)

      {decisions, Pairing.explain_round(parsed.players, decisions.pairs, opts),
       Ainalrami.Alternatives.float_alternatives(parsed.players, decisions.pairs, opts)}
    end

    keys = Process.get_keys()
    here = everything.()
    assert Process.get_keys() -- (keys -- [:ainalrami_cert_stats]) == []
    assert here == everything |> Task.async() |> Task.await(:infinity)
  end
end

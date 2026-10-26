defmodule Ainalrami.GacruxRoundArgumentTest do
  @moduledoc """
  Gacrux has to be told which round to pair.

  Without `-n R` it pairs "1 + the last round that holds an over-the-board
  game" (`trf2json.py:699-706`; forfeits and byes are not played games). After
  a round made only of forfeits and byes it therefore pairs THAT round again
  and returns the pairing already in the file. Every Ainalrami-versus-Gacrux
  disagreement recorded in `docs/finding-gacrux-5-2-4.md` and
  `docs/finding-gacrux-5-2-5.md` was this and nothing else (both retracted).

  These two fixtures are the positions from the second finding. With the round
  given, Gacrux, bbpPairings and Ainalrami return the same boards, colours
  included. Needs Gacrux and bbpPairings, so it runs with the three-way tag:

      mix test --only three_way test/ainalrami/gacrux_round_argument_test.exs
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Pairing
  alias Ainalrami.Test.{Bbppairings, Gacrux}

  @moduletag :three_way

  @dir "test/fixtures/gacrux_5_2_5"

  for {file, round} <- [{"seed32007296_r2_p8.trf", 2}, {"seed32010783_r2_p8.trf", 2}] do
    test "#{file}: Gacrux with -n #{round} agrees with bbpPairings and Ainalrami" do
      trf = File.read!(Path.join(@dir, unquote(file)))
      round = unquote(round)

      {:ok, gacrux} = Gacrux.pair(trf, round)
      {:ok, bbp} = Bbppairings.pair(trf)

      %{players: players} = Ainalrami.Trf.parse(trf)
      ours = Pairing.pair_next_round(players, expected_rounds: 7, initial_colour: "b")

      assert boards(gacrux) == boards(bbp)
      assert boards(ours) == boards(bbp)
    end

    test "#{file}: without the round Gacrux re-pairs the previous one" do
      trf = File.read!(Path.join(@dir, unquote(file)))

      {:ok, with_round} = Gacrux.pair(trf, unquote(round))
      {:ok, without} = Gacrux.pair(trf)

      refute boards(without) == boards(with_round)
    end
  end

  defp boards(pairs), do: MapSet.new(pairs)
end

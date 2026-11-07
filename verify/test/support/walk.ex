defmodule AinalramiVerify.Walk do
  @moduledoc """
  Random tournaments for the tests: `n` players, rounds paired by the
  engine, random results, and (optionally) players sitting a round out
  with a requested bye (`H`, `Z` or `F`) decided before the round is
  paired. Deterministic in the seed.
  """

  alias AinalramiVerify.{Engine, TrfWriter}

  @doc """
  The TRF of every position reached on one walk: `[trf_text]`, one per
  round paired (the last one not yet paired). Options: `:players`,
  `:rounds`, `:seed`, `:absences` (per-player chance of sitting a round
  out, default 0.0).
  """
  def positions(opts) do
    n = Keyword.fetch!(opts, :players)
    rounds = Keyword.fetch!(opts, :rounds)
    seed = Keyword.fetch!(opts, :seed)
    absences = Keyword.get(opts, :absences, 0.0)
    :rand.seed(:exsss, {seed, n, rounds})

    Enum.reduce_while(1..rounds, {[], []}, fn r, {hist, acc} ->
      out =
        if r > 1,
          do:
            for(
              p <- 1..n,
              :rand.uniform() < absences,
              into: %{},
              do: {p, {nil, nil, Enum.random(["H", "Z", "F"])}}
            ),
          else: %{}

      trf = TrfWriter.write(n, hist ++ [out], rounds)
      trf = if out == %{}, do: TrfWriter.write(n, hist, rounds), else: trf
      acc = [trf | acc]

      case Engine.pair(trf) do
        {:ok, round} when r < rounds ->
          games =
            Enum.reduce(round.pairs, out, fn {w, b}, m ->
              res = Enum.random(["1", "=", "0"])
              m |> Map.put(w, {b, :w, res}) |> Map.put(b, {w, :b, invert(res)})
            end)

          games = if round.bye, do: Map.put(games, round.bye, {nil, nil, "U"}), else: games
          {:cont, {hist ++ [games], acc}}

        _ ->
          {:halt, {hist, acc}}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp invert("1"), do: "0"
  defp invert("0"), do: "1"
  defp invert("="), do: "="
end

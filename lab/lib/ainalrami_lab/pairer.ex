defmodule AinalramiLab.Pairer do
  @moduledoc """
  Which pairer pairs a position: `:brute` (`AinalramiLab.Brute`, exact,
  to about 10 players), `:hybrid` (`AinalramiLab.Hybrid`, any size,
  Article 4's order approximated), `:engine` (Ainalrami itself through
  `AinalramiVerify.Engine`, baseline only), or `:auto` (brute to
  `@brute_max` players in the pool, hybrid above).
  """

  alias AinalramiLab.{Brute, Hybrid, Variant}
  alias AinalramiVerify.{Engine, Position}

  @brute_max 10

  def brute_max, do: @brute_max

  @doc "Pair `pos` (built from `trf_text`) under `variant` with `pairer`."
  def pair(pairer, %Position{} = pos, trf_text, %Variant{} = v) do
    case resolve(pairer, pos) do
      :brute ->
        Brute.pair(pos, v)

      :hybrid ->
        Hybrid.pair(pos, v)

      :engine ->
        if not Variant.baseline?(v),
          do: raise(ArgumentError, "the engine pairs the 2026 text only; use brute or hybrid")

        case Engine.pair(trf_text) do
          {:ok, round} ->
            {:ok, Map.put(round, :articles, articles(pos, round, v))}

          {:error, _} ->
            {:error, :no_legal_pairing}
        end
    end
  end

  def resolve(:auto, pos), do: if(length(pos.pool) <= @brute_max, do: :brute, else: :hybrid)
  def resolve(p, _pos) when p in [:brute, :hybrid, :engine], do: p

  defp articles(pos, round, v) do
    pos = AinalramiLab.Rules.position(pos, v)

    Enum.map(round.pairs, fn {w, b} ->
      {_, _, art} = AinalramiLab.Rules.colours(pos, w, b, v)
      art
    end)
  end
end

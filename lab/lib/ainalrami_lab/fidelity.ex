defmodule AinalramiLab.Fidelity do
  @moduledoc """
  How far the hybrid pairer can be trusted: play tournaments with it and
  pair every position again with a reference, the brute force (any
  variant, small fields) or the engine (baseline only, any size), and
  count the rounds on which the two differ, colours included.
  """

  alias AinalramiLab.{Brute, Simulate, Stats, Tournament, Variant}
  alias AinalramiVerify.Engine

  @doc "Options: `:spec`, `:count`, `:variant`, `:against` (`:brute` | `:engine`), `:seed`, `:workers`."
  def run(opts) do
    spec = Keyword.fetch!(opts, :spec)
    v = Keyword.get(opts, :variant, Variant.baseline())
    against = Keyword.fetch!(opts, :against)
    seed = Keyword.get(opts, :seed, 1)

    if against == :engine and not Variant.baseline?(v),
      do: raise(ArgumentError, "the engine pairs the 2026 text only")

    per =
      1..Keyword.fetch!(opts, :count)
      |> Task.async_stream(
        fn i ->
          Tournament.play(spec, :hybrid, v, {seed, i}).rounds
          |> Enum.map(fn rec ->
            ref =
              case against do
                :brute -> Brute.pair(rec.pos, v)
                :engine -> engine(rec.trf)
              end

            {rec, Simulate.compare(rec.result, ref)}
          end)
        end,
        max_concurrency: Keyword.get(opts, :workers, System.schedulers_online()),
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, list} -> list end)

    differ = Enum.reject(per, fn {_, c} -> c in [:same, :both_refused] end)

    %{
      rounds: length(per),
      differ: Stats.wilson(length(differ), length(per)),
      first: differ |> Enum.take(3) |> Enum.map(fn {rec, c} -> %{kind: c, trf: rec.trf} end)
    }
  end

  defp engine(trf) do
    case Engine.pair(trf) do
      {:ok, r} -> {:ok, r}
      {:error, _} -> {:error, :no_legal_pairing}
    end
  end
end

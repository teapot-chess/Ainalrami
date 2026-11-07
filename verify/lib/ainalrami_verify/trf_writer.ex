defmodule AinalramiVerify.TrfWriter do
  @moduledoc """
  Writes the small TRF16 files the exhaustive run feeds to both the engine
  and the reference: players `1..n` (rated in starting-rank order), the
  rounds played so far, `XXR` and `152`.

  `history` is a list of rounds, oldest first; each round is a map
  `rank => {opponent | nil, colour :w | :b | nil, code}`.
  """

  alias AinalramiVerify.Trf

  def write(n, history, rounds, opts \\ []) do
    initial = Keyword.get(opts, :initial_colour, :w)

    header = [
      "012 ainalrami-verify exhaustive",
      "062 #{n}",
      "092 Individual: Swiss-System",
      "XXR #{rounds}",
      "152 #{if initial == :w, do: "W", else: "B"}"
    ]

    players =
      for rank <- 1..n do
        games = Enum.map(history, &Map.get(&1, rank))

        points =
          games
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn {_, _, c} -> Trf.points(c) end)
          |> Enum.sum()

        head =
          "001 " <>
            pad_l(rank, 4) <>
            " " <>
            " " <>
            "   " <>
            " " <>
            String.pad_trailing("P#{rank}", 33) <>
            " " <>
            pad_l(2600 - 10 * rank, 4) <>
            " " <>
            "   " <>
            " " <>
            String.duplicate(" ", 11) <>
            " " <>
            String.duplicate(" ", 10) <>
            " " <>
            pad_l(:erlang.float_to_binary(points / 2, decimals: 1), 4) <>
            " " <> pad_l(rank, 4)

        head <> Enum.map_join(games, "", &block/1)
      end

    Enum.join(header ++ players, "\n") <> "\n"
  end

  defp block(nil), do: "          "

  defp block({opp, colour, code}) do
    "  " <>
      pad_l(opp || "0000", 4) <>
      " " <>
      case colour do
        :w -> "w"
        :b -> "b"
        nil -> "-"
      end <> " " <> code
  end

  defp pad_l(v, n), do: String.pad_leading(to_string(v), n)
end

defmodule AinalramiVerify.PairsFile do
  @moduledoc """
  The board list bbpPairings, JaVaFo and Ainalrami write with `-p`: the
  number of boards, then one `white black` line per board, `rank 0` for
  the pairing-allocated bye.

  A round can also be read from a TRF that already holds it (another
  program's output file): `from_trf/2` takes the column of the round being
  checked.
  """

  alias AinalramiVerify.Trf

  def parse(text) do
    [count | lines] =
      text
      |> String.split(~r/\r\n|\r|\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    boards =
      Enum.map(lines, fn line ->
        case line |> String.split() |> Enum.map(&String.to_integer/1) do
          [a, 0] -> {:bye, a}
          [a, b] -> {:pair, a, b}
          _ -> raise ArgumentError, "not a board: #{inspect(line)}"
        end
      end)

    if String.to_integer(count) != length(boards),
      do: raise(ArgumentError, "the file says #{count} boards and lists #{length(boards)}")

    to_round(boards)
  end

  defp to_round(boards) do
    byes = for {:bye, a} <- boards, do: a

    %{
      pairs: for({:pair, a, b} <- boards, do: {a, b}),
      bye: List.first(byes),
      extra_byes: Enum.drop(byes, 1)
    }
  end

  @doc "The round `round` as recorded in a TRF (colours from the file)."
  def from_trf(text, round) do
    trf = Trf.parse(text)

    boards =
      trf.players
      |> Enum.sort()
      |> Enum.flat_map(fn {rank, p} ->
        case p.games[round] do
          %{opponent: opp, colour: :w} when opp != nil -> [{:pair, rank, opp}]
          %{opponent: nil, code: "U"} -> [{:bye, rank}]
          _ -> []
        end
      end)

    to_round(boards)
  end

  def write(%{pairs: pairs, bye: bye}) do
    lines = Enum.map(pairs, fn {a, b} -> "#{a} #{b}" end) ++ if(bye, do: ["#{bye} 0"], else: [])
    Enum.join(["#{length(lines)}" | lines], "\n") <> "\n"
  end
end

defmodule Ainalrami.Burstein.Order do
  @moduledoc """
  C.04.4.2 Article 4: the order of a bracket's pairings.

  The players carry in-bracket sequence numbers (BSN) 1..n in 1.8's
  ranking order (4.1); one virtual player with BSN 0 joins per outgoing
  floater (4.2). Pairing A precedes pairing B when BSN 1's opponent in A
  has the larger BSN; on a tie, BSN 2's opponent decides, and so on (4.3).
  0 is the smallest BSN, so floating is every player's last choice.

  `Ainalrami.Burstein.Bracket` never lists the pairings - it fixes BSN 1's
  opponent, then BSN 2's, each time the largest that still reaches the
  best value of [C5]-[C8] - but the order it walks is this one, and
  `enumerate/2` is what the 4.3 note's example is checked against.
  """

  @doc """
  Every pairing of BSNs `1..n` with `floaters` of them floating, in 4.3's
  order, as lists of `{bsn, opponent_bsn}` with the floaters as
  `{bsn, 0}`; each pair is listed once, under its smaller BSN.
  """
  def enumerate(n, floaters), do: walk(Enum.to_list(1..n//1), floaters)

  defp walk([], 0), do: [[]]
  defp walk([], _left), do: []

  defp walk([first | rest], left) do
    paired =
      for opp <- Enum.reverse(rest),
          tail <- walk(List.delete(rest, opp), left),
          do: [{first, opp} | tail]

    floated =
      if left > 0, do: for(tail <- walk(rest, left - 1), do: [{first, 0} | tail]), else: []

    paired ++ floated
  end

  @doc """
  4.3's sort key for a pairing of BSNs `1..n`: every BSN's opponent, BSN
  1 first, 0 for a floater. The pairing with the LARGER key comes first.
  """
  def key(n, pairs) do
    opponent =
      Enum.reduce(pairs, %{}, fn
        {a, 0}, acc -> Map.put(acc, a, 0)
        {a, b}, acc -> acc |> Map.put(a, b) |> Map.put(b, a)
      end)

    for bsn <- 1..n//1, do: Map.get(opponent, bsn, 0)
  end
end

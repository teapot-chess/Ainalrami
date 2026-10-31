defmodule Ainalrami.Burstein.Colour do
  @moduledoc """
  C.04.4.2 Article 5: who of a pair gets White, after the seeding rounds
  (the seeding rounds' colours are the Dutch system's). For each pair, in
  descending priority:

    * 5.2.1 - neither has played a game: the higher ranked player (1.8:
      the index, then the TPN - **not the score**, reading B6) gets the
      initial colour if their number is odd, the opposite otherwise;
    * 5.2.2 - grant both colour preferences (a player with no game has
      none, 1.5.4, and the opponent's is granted);
    * 5.2.3 - grant the stronger one (absolute over strong over mild);
    * 5.2.4 - alternate from the most recent round in which one had White
      and the other Black, the played colours aligned from the latest game
      (C.04.2 Article 3.4);
    * 5.2.5 - grant the higher ranked player's preference (1.8).

  The number 5.2.1 takes the parity of is the arrival numbering
  (`Ainalrami.Pairing.arrival_numbers/2`), as for the Dubov system's
  identical sentence (reading B9, after the SPP's 2026-08-27 ruling on the
  Dutch 5.2.5).
  """

  alias Ainalrami.Burstein.Player

  @strength %{absolute: 3, strong: 2, mild: 1}

  @doc """
  `{white_rank, black_rank, article}` for the pair `a`/`b`
  (`%Ainalrami.Burstein.Player{}`).
  """
  def allocate(a, b, numbers, initial) do
    high = higher(a, b)
    low = if high == a, do: b, else: a

    cond do
      a.played == 0 and b.played == 0 ->
        number = Map.fetch!(numbers, high.rank)
        colour = if rem(number, 2) == 1, do: initial, else: opposite(initial)
        give(high, colour, low, "5.2.1")

      is_nil(a.colour) ->
        give(b, b.colour, a, "5.2.2")

      is_nil(b.colour) ->
        give(a, a.colour, b, "5.2.2")

      a.colour != b.colour ->
        give(a, a.colour, b, "5.2.2")

      @strength[a.strength] != @strength[b.strength] ->
        strong = if @strength[a.strength] > @strength[b.strength], do: a, else: b
        weak = if strong == a, do: b, else: a
        give(strong, strong.colour, weak, "5.2.3")

      colour = last_difference(a.colours, b.colours) ->
        give(a, opposite(colour), b, "5.2.4")

      true ->
        give(high, high.colour, low, "5.2.5")
    end
  end

  @doc "The higher ranked of two players by 1.8: the index, then the smaller TPN."
  def higher(a, b) do
    if Player.ranking_key(a) <= Player.ranking_key(b), do: a, else: b
  end

  defp last_difference(a, b) do
    Enum.zip(Enum.reverse(a), Enum.reverse(b))
    |> Enum.find_value(fn {x, y} -> if x != y, do: x end)
  end

  defp give(player, :white, other, article), do: {player.rank, other.rank, article}
  defp give(player, :black, other, article), do: {other.rank, player.rank, article}

  defp opposite(:white), do: :black
  defp opposite(:black), do: :white
end

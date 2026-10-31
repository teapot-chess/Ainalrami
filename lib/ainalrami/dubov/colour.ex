defmodule Ainalrami.Dubov.Colour do
  @moduledoc """
  C.04.4.1 Article 5: who of a pair gets White. For each pair, in
  descending priority:

    * 5.2.1 - neither has played a game: the higher ranked player (more
      points, then the smaller TPN) gets the initial colour if their number
      is odd, the opposite colour otherwise;
    * 5.2.2 - grant both colour preferences;
    * 5.2.3 - grant the stronger one (absolute over strong over mild);
    * 5.2.4 - alternate from the most recent round in which one had White
      and the other Black, the played colours aligned from the latest game
      (C.04.2 Article 3.4: unplayed rounds drop out);
    * 5.2.5 - grant the higher ranked player's preference.

  Every player has a preference in the Dubov system (1.6.4 gives one to a
  player with no games), so 5.2.5 always decides what is left.

  **The number 5.2.1 takes the parity of** is the arrival numbering
  `Ainalrami.Pairing.arrival_numbers/2` computes, not the starting rank:
  the SPP's 2026-08-27 ruling on the identical sentence in the Dutch
  system's 5.2.5 (C.04.2 Article 2.4: a late entry has no TPN until it
  arrives). See `docs/conformance-c0441-dubov.md`, reading D9.

  The ladder is written for Dubov alone; Burstein's 5.2 is the same ladder
  with "higher ranked" by its index instead of by score, and is the reason
  `higher/2` takes the ranking from the caller.
  """

  @strength %{absolute: 3, strong: 2, mild: 1}

  @doc """
  `{white_rank, black_rank, article}` for the pair `a`/`b`
  (`%Ainalrami.Dubov.Player{}`), where `article` names the rule that
  decided ("5.2.1" ... "5.2.5"). `numbers` is the arrival numbering,
  `initial` the initial colour (`:white` or `:black`).
  """
  def allocate(a, b, numbers, initial) do
    high = higher(a, b)
    low = if high == a, do: b, else: a

    cond do
      a.played == 0 and b.played == 0 ->
        number = Map.fetch!(numbers, high.rank)
        colour = if rem(number, 2) == 1, do: initial, else: opposite(initial)
        give(high, colour, low, "5.2.1")

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

  @doc "The higher ranked of two players (5.2.1): more points, then the smaller TPN."
  def higher(a, b) do
    if {-a.score, a.rank} <= {-b.score, b.rank}, do: a, else: b
  end

  # `a`'s colour in the latest round where the two histories, aligned from
  # their last played game, hold different colours; nil if there is none.
  defp last_difference(a, b) do
    Enum.zip(Enum.reverse(a), Enum.reverse(b))
    |> Enum.find_value(fn {x, y} -> if x != y, do: x end)
  end

  defp give(player, :white, other, article), do: {player.rank, other.rank, article}
  defp give(player, :black, other, article), do: {other.rank, player.rank, article}

  defp opposite(:white), do: :black
  defp opposite(:black), do: :white
end

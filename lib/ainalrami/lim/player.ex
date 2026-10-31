defmodule Ainalrami.Lim.Player do
  @moduledoc """
  One player as the Lim system (C.04.4.3) sees them for the round about to
  be paired, read off the TRF-shaped player maps `Ainalrami.Trf.parse/1`
  returns.

    * `:score` - points before this round (Lim has no acceleration).
    * `:colour`, `:strength` - the colour the player is due and whether it
      is a must (`:absolute`: 5.1.1/5.1.2/5.3 - the same colour twice in a
      row, or two more of one colour). The due colour is the equalising
      one while the colours are unequal and the alternating one when they
      are equal (5.5/5.6); a player who has played the same colour twice
      running must alternate (5.3) unless the colours are already two
      apart. Unplayed rounds drop out of the history (C.04.2 3.4). Both nil
      for a player with no game.
    * `:colours` - the played colours, oldest first, for 5.4.
    * `:floated?` - floated in the round before (3.10): paired, played or
      forfeited, against an opponent whose score before that round was
      different.
    * `:bye_eligible?` - C.04.1 Article 3.

  The colour ladder is the Burstein system's (`Ainalrami.Burstein.Player`),
  which is the Dutch one: it says exactly what 2.1 and 5.1-5.6 say.
  """

  alias Ainalrami.Burstein.Player, as: BursteinPlayer
  alias Ainalrami.Trf

  @enforce_keys [:rank]
  defstruct rank: nil,
            score: 0.0,
            colour: nil,
            strength: nil,
            colours: [],
            allowed: [:white, :black],
            floated?: false,
            bye_eligible?: true

  @type t :: %__MODULE__{}

  @doc """
  The `%Player{}` for `player` before round `round`. `context` is
  `%{eligible: %{rank => reason | nil}, before: %{rank => [score before round 1, 2, ...]}}`.
  """
  def build(player, round, context) do
    b =
      BursteinPlayer.build(player, round, %{
        index: %{player.rank => {0.0, 0.0}},
        eligible: context.eligible
      })

    %__MODULE__{
      rank: player.rank,
      score: score_before(context, player.rank, round),
      colour: b.colour,
      strength: b.strength,
      colours: b.colours,
      allowed: allowed(b.colours),
      floated?: floated?(player, round, context),
      bye_eligible?: b.bye_eligible?
    }
  end

  @doc """
  The score of every player before each round up to `round`:
  `%{rank => {score before round 1, before round 2, ...}}` (a tuple, round
  r at index r - 1).
  """
  def scores_before(players, round, point_system) do
    Map.new(players, fn p ->
      scores =
        1..(round - 1)//1
        |> Enum.scan(0.0, fn r, acc ->
          case Enum.at(p.games, r - 1) do
            nil -> acc
            game -> acc + Trf.points_for_game(game, point_system)
          end
        end)

      {p.rank, List.to_tuple([0.0 | scores])}
    end)
  end

  # 2.1 and 5.1: the colours this player may still be given - neither a
  # third in succession nor a third more of one colour than the other.
  defp allowed(colours) do
    whites = Enum.count(colours, &(&1 == :white))
    difference = whites - (length(colours) - whites)
    tail = colours |> Enum.reverse() |> Enum.take(2)

    for {c, step} <- [white: 1, black: -1], abs(difference + step) <= 2, tail != [c, c], do: c
  end

  defp score_before(context, rank, round), do: elem(Map.fetch!(context.before, rank), round - 1)

  defp floated?(_player, round, _context) when round < 2, do: false

  defp floated?(player, round, context) do
    case Enum.at(player.games, round - 2) do
      %{opponent_rank: opp} = game when is_integer(opp) ->
        Trf.participated_in_pairing?(game) and Map.has_key?(context.before, opp) and
          score_before(context, opp, round - 1) != score_before(context, player.rank, round - 1)

      _ ->
        false
    end
  end
end

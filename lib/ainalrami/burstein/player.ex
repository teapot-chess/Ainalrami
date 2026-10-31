defmodule Ainalrami.Burstein.Player do
  @moduledoc """
  One player as the Burstein system (C.04.4.2) sees them for the round
  about to be paired, after the seeding rounds, read off the TRF-shaped
  player maps `Ainalrami.Trf.parse/1` returns.

    * `:score` - points, plus this round's virtual points when the file
      carries an acceleration (C.04.7). Reading B8 in
      `docs/conformance-c0442-burstein.md`: virtual points count wherever
      the text says "score" (scoregroups, [C6], the bye's lowest score) and
      nowhere in the index, which 1.7.2 excludes them from.
    * `:buchholz`, `:sonneborn` - the index of 1.7/1.8.1, from real points
      only. Readings B3 and B4: see `index/3`.
    * `:colour`, `:strength` - 1.5's colour preference (`:white`/`:black`)
      and its class (`:absolute`, `:strong`, `:mild`); both nil for a player
      with no game (1.5.4: no preference). Unplayed rounds drop out of the
      colour history (C.04.2 Article 3.4).
    * `:colours` - the played colours, oldest first, for 5.2.4.
    * `:played` - games played over the board (3.1.4).
    * `:bye_eligible?` - [C2].
  """

  alias Ainalrami.Trf

  @enforce_keys [:rank]
  defstruct rank: nil,
            score: 0.0,
            buchholz: 0.0,
            sonneborn: 0.0,
            colour: nil,
            strength: nil,
            colours: [],
            played: 0,
            bye_eligible?: true

  @type t :: %__MODULE__{}

  @doc """
  The `%Player{}` for `player` before round `round` is paired. `context` is
  `%{index: %{rank => {buchholz, sonneborn}}, eligible: %{rank => reason | nil}}`.
  """
  def build(player, round, context) do
    played_games = player.games |> Enum.take(round - 1) |> Enum.filter(&played?/1)
    {colour, strength} = preference(played_games)
    {bh, sb} = Map.fetch!(context.index, player.rank)

    %__MODULE__{
      rank: player.rank,
      score: player.points + acceleration(player, round),
      buchholz: bh,
      sonneborn: sb,
      colour: colour,
      strength: strength,
      colours: Enum.map(played_games, &colour_of/1),
      played: length(played_games),
      bye_eligible?: is_nil(Map.get(context.eligible, player.rank))
    }
  end

  @doc """
  1.8's ranking key: the index (Buchholz, then Sonneborn-Berger, both
  descending), then the TPN ascending. Sorting by it puts the highest
  ranked first. The score is not part of it (1.8's note).
  """
  def ranking_key(p), do: {-p.buchholz, -p.sonneborn, p.rank}

  @doc "A game played over the board: a real result against a real opponent."
  def played?(game) do
    is_integer(game.opponent_rank) and Trf.game_was_played?(game.result) and
      game.colour in ["w", "b"]
  end

  @doc """
  The index (1.7) of every player on the roster before round `round`:
  `%{rank => {buchholz, sonneborn}}`, over real points (1.7.2 excludes
  virtual ones).

  Reading B3 - 1.7.2's "played against himself": a round the player did not
  play (a bye of any kind, a forfeit either way, an absence) counts as a
  game against an opponent whose current score is the player's own, with
  the points the player was given for it. No cap, no category: C.07
  Article 16's dummy-opponent machinery is not imported.

  Reading B4 - the zero-point-bye exception: a player whose rounds, from
  some round to the last one paired, are all zero-point byes (no opponent,
  not played, nothing scored) is seen by the players they actually met as
  having drawn each of them. Only their opponents see it; the player's own
  virtual games use their real score. A player who comes back loses the
  adjustment, because the run no longer reaches the current round.
  """
  def index(players, round, point_system) do
    current = Map.new(players, &{&1.rank, current_score(&1, round, point_system)})

    as_seen =
      Map.new(players, fn p ->
        {p.rank, current[p.rank] + trailing_zero_byes(p, round, point_system) * point_system.draw}
      end)

    Map.new(players, fn p ->
      own = current[p.rank]

      {bh, sb} =
        Enum.reduce(1..(round - 1)//1, {0.0, 0.0}, fn r, {bh, sb} ->
          game = Enum.at(p.games, r - 1)
          earned = if game, do: Trf.points_for_game(game, point_system), else: 0.0

          opponent_score =
            if game && played?(game), do: Map.get(as_seen, game.opponent_rank, 0.0), else: own

          {bh + opponent_score, sb + earned * opponent_score}
        end)

      {p.rank, {bh, sb}}
    end)
  end

  # The points of the rounds before `round`: the file's total less any
  # round already recorded for the round being paired or later (a
  # pre-recorded bye).
  defp current_score(player, round, point_system) do
    later =
      player.games
      |> Enum.drop(round - 1)
      |> Enum.map(&Trf.points_for_game(&1, point_system))
      |> Enum.sum()

    player.points - later
  end

  defp trailing_zero_byes(player, round, point_system) do
    1..(round - 1)//1
    |> Enum.map(&Enum.at(player.games, &1 - 1))
    |> Enum.reverse()
    |> Enum.take_while(&zero_point_bye?(&1, point_system))
    |> length()
  end

  defp zero_point_bye?(nil, _point_system), do: true

  defp zero_point_bye?(game, point_system) do
    is_nil(game.opponent_rank) and not Trf.game_was_played?(game.result) and
      Trf.points_for_game(game, point_system) == 0
  end

  defp colour_of(%{colour: "w"}), do: :white
  defp colour_of(%{colour: "b"}), do: :black

  # 1.5, the Dutch engine's ladder (an imbalance beyond one decides before
  # a repeated colour, the order 1.5.1 states them in); no games, no
  # preference (1.5.4).
  defp preference([]), do: {nil, nil}

  defp preference(games) do
    colours = Enum.map(games, &colour_of/1)
    whites = Enum.count(colours, &(&1 == :white))
    difference = whites - (length(colours) - whites)
    last = List.last(colours)
    repeated? = match?([c, c | _], Enum.reverse(colours))

    cond do
      difference < -1 -> {:white, :absolute}
      difference > 1 -> {:black, :absolute}
      repeated? -> {other(last), :absolute}
      difference == -1 -> {:white, :strong}
      difference == 1 -> {:black, :strong}
      true -> {other(last), :mild}
    end
  end

  defp other(:white), do: :black
  defp other(:black), do: :white

  defp acceleration(player, round) do
    case player do
      %{accelerations: values} when is_list(values) -> Enum.at(values, round - 1) || 0.0
      _ -> 0.0
    end
  end
end

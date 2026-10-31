defmodule Ainalrami.Dubov.Player do
  @moduledoc """
  One player as the Dubov system sees them for the round about to be paired,
  read off the TRF-shaped player maps `Ainalrami.Trf.parse/1` returns.

  Everything the procedure asks about a player, worked out once per round:

    * `:score` - points, plus this round's virtual points when the file
      carries an acceleration (`:accelerations`, C.04.7). Reading D7 in
      `docs/conformance-c0441-dubov.md`: virtual points count wherever the
      text says "score" or "points".
    * `:rating` - the `001` rating, or the Chief Arbiter's provisional
      rating for an unrated player (1.1.2). Reading D5: the rating the file
      holds now, the one the TPNs are computed from, for every opponent
      whenever they were met.
    * `:aro` - 1.7: the mean rating of the opponents met over the board,
      rounded to the nearest integer, .5 upwards; 0 with no game played.
    * `:colour`, `:strength` - 1.6's colour preference (`:white` or
      `:black`) and its class (`:absolute`, `:strong` or `:mild`). A player
      with no game has a mild preference for Black (1.6.4). Unplayed rounds
      drop out of the colour history (C.04.2 Article 3.4).
    * `:colours` - the played colours, oldest first, for 5.2.4.
    * `:played` - games played over the board (3.1.4).
    * `:upfloats`, `:upfloated_last?` - how often the player was an
      upfloater before this round, and whether in the previous round, for
      [C8]-[C10]. Reading D4: an upfloat is a PLAYED game against an
      opponent who had a higher score when the round was paired; a forfeit
      and the pairing-allocated bye are not upfloats.
    * `:bye_eligible?` - [C2], as `Ainalrami.Pairing.bye_eligibility/2`
      decides it (the same article as the Dutch system's, under the file's
      point system).
  """

  alias Ainalrami.Trf

  @enforce_keys [:rank]
  defstruct rank: nil,
            score: 0.0,
            rating: 0,
            aro: 0,
            colour: :black,
            strength: :mild,
            colours: [],
            played: 0,
            upfloats: 0,
            upfloated_last?: false,
            bye_eligible?: true

  @type t :: %__MODULE__{}

  @doc """
  Every rating the round needs: `%{rank => rating}` over the whole roster,
  the `001` rating or, for an unrated player, `provisional[rank]`.

  `{:error, {:unrated, ranks}}` names the players with neither - 1.1.1 says
  every player MUST have a rating, so the round is not paired without them.
  `{:error, {:provisional_for_rated, ranks}}` names players given a
  provisional rating who already have one: 1.1.2 is for players who do not,
  and quietly preferring either number would pair a tournament nobody
  asked for.
  """
  def ratings(players, provisional) do
    provisional = provisional || %{}

    rated =
      for p <- players, own = rating_of(p), own > 0, Map.has_key?(provisional, p.rank), do: p.rank

    table =
      Map.new(players, fn p ->
        case rating_of(p) do
          r when r > 0 -> {p.rank, r}
          _ -> {p.rank, Map.get(provisional, p.rank, 0)}
        end
      end)

    unrated = for {rank, r} <- table, not (is_integer(r) and r > 0), do: rank

    cond do
      rated != [] -> {:error, {:provisional_for_rated, Enum.sort(rated)}}
      unrated != [] -> {:error, {:unrated, Enum.sort(unrated)}}
      true -> {:ok, table}
    end
  end

  defp rating_of(p) do
    case p[:fide_rating] do
      r when is_integer(r) -> r
      _ -> 0
    end
  end

  @doc """
  The `%Player{}` for `player` before round `round` (1-based) is paired.

  `context` is `%{ratings:, by_rank:, point_system:, eligible:}`: the
  rating table from `ratings/2`, the whole roster by rank (opponents'
  scores at the time decide an upfloat), the point system, and the [C2]
  answers by rank.
  """
  def build(player, round, context) do
    played_games = Enum.filter(player.games, &played?/1)
    {colour, strength} = preference(played_games)

    %__MODULE__{
      rank: player.rank,
      score: player.points + acceleration(player, round),
      rating: Map.fetch!(context.ratings, player.rank),
      aro: aro(played_games, context.ratings),
      colour: colour,
      strength: strength,
      colours: Enum.map(played_games, &colour_of/1),
      played: length(played_games),
      upfloats: count_upfloats(player, round, context),
      upfloated_last?: upfloated_in?(player, round - 1, context),
      bye_eligible?: is_nil(Map.get(context.eligible, player.rank))
    }
  end

  @doc "A game played over the board: a real result against a real opponent."
  def played?(game) do
    is_integer(game.opponent_rank) and Trf.game_was_played?(game.result) and
      game.colour in ["w", "b"]
  end

  defp colour_of(%{colour: "w"}), do: :white
  defp colour_of(%{colour: "b"}), do: :black

  # 1.7.1: rounded to the nearest integer, the higher on .5. Ratings are
  # positive integers, so (2 * sum + n) div (2 * n) is exact.
  defp aro([], _ratings), do: 0

  defp aro(games, ratings) do
    n = length(games)
    sum = games |> Enum.map(&Map.fetch!(ratings, &1.opponent_rank)) |> Enum.sum()
    div(2 * sum + n, 2 * n)
  end

  # 1.6. The ladder is the Dutch engine's (`Ainalrami.Pairing`'s
  # `colour_stats/1`): an imbalance beyond one decides before a repeated
  # colour, which is the order 1.6.1 states them in. 1.6.4 replaces "no
  # preference" with a mild one for Black.
  defp preference([]), do: {:black, :mild}

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

  # `accelerations[round - 1]`, as `Ainalrami.Pairing` reads XXA.
  defp acceleration(player, round) when round >= 1 do
    case player do
      %{accelerations: values} when is_list(values) -> Enum.at(values, round - 1) || 0.0
      _ -> 0.0
    end
  end

  defp acceleration(_player, _round), do: 0.0

  @doc """
  A player's score when round `round` was paired: the points of every
  earlier game under the point system, plus that round's virtual points.
  """
  def score_before(player, round, point_system) do
    earned =
      player.games
      |> Enum.take(round - 1)
      |> Enum.map(&Trf.points_for_game(&1, point_system))
      |> Enum.sum()

    earned + acceleration(player, round)
  end

  defp count_upfloats(player, round, context) do
    Enum.count(1..(round - 1)//1, &upfloated_in?(player, &1, context))
  end

  defp upfloated_in?(_player, r, _context) when r < 1, do: false

  defp upfloated_in?(player, r, context) do
    with %{} = game <- Enum.at(player.games, r - 1),
         true <- played?(game),
         %{} = opponent <- Map.get(context.by_rank, game.opponent_rank) do
      score_before(player, r, context.point_system) <
        score_before(opponent, r, context.point_system)
    else
      _ -> false
    end
  end
end

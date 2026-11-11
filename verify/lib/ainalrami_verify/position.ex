defmodule AinalramiVerify.Position do
  @moduledoc """
  Everything C.04.3 (2026) asks about a player before a round is paired,
  computed from a parsed TRF (`AinalramiVerify.Trf`) and nothing else.

  Each field is labelled with the article it comes from. Scores are in
  half-points.

    * `score` - points before round `r` (1.2.1).
    * `whites`, `blacks`, `cd` - games played with each colour, colour
      difference (1.6). Only games played over the board count.
    * `colours` - the colours of the played games, oldest first.
    * `pref` - `{colour, strength}` or `nil` (1.7): strength `:absolute`
      (1.7.1), `:strong` (1.7.2), `:mild` (1.7.3); `nil` with no game
      played (1.7.4).
    * `opponents` - players met over the board ([C1]).
    * `bye_ineligible?` - [C2]: had a pairing-allocated bye, or scored a
      win's points in a round without playing.
    * `float` - `%{r => :down | :up}` for every earlier round in which the
      player floated (1.4.2-1.4.4).
    * `unplayed` - rounds before `r` without a game played ([C9]).
    * `topscorer?` - 1.8: over 50% of the maximum possible score, and only
      when pairing the final round.
  """

  alias AinalramiVerify.Trf

  defstruct [:round, :pool, :players, :final?, :initial_colour, :arrival, :trf]

  @type t :: %__MODULE__{}

  @doc "The position before round `round` (default: the file's next round)."
  def build(trf, round \\ nil) do
    r = round || Trf.next_round(trf)
    all = trf.players

    scores_before =
      for t <- 1..r//1, into: %{} do
        {t,
         Map.new(all, fn {rank, p} ->
           {rank,
            p.games
            |> Enum.filter(fn {rr, _} -> rr < t end)
            |> Enum.map(fn {_, g} -> Trf.points(g.code) end)
            |> Enum.sum()}
         end)}
      end

    final? = trf.rounds != nil and r == trf.rounds
    # 1.8: the maximum possible score before the final round is (r - 1)
    # wins; "over 50%" is strictly more than half of it. In half-points a
    # win is 2, so half of (r - 1) wins is r - 1.
    top_threshold = r - 1

    players =
      Map.new(all, fn {rank, p} ->
        hist = for t <- 1..(r - 1)//1, g = p.games[t], do: {t, g}
        played = for {t, g} <- hist, Trf.played?(g.code), do: {t, g}
        colours = Enum.map(played, fn {_, g} -> g.colour end)
        whites = Enum.count(colours, &(&1 == :w))
        blacks = Enum.count(colours, &(&1 == :b))
        score = scores_before[r][rank]

        float =
          for t <- 1..(r - 1)//1, f = float_in(p, t, scores_before[t], all), into: %{}, do: {t, f}

        {rank,
         %{
           rank: rank,
           rating: p.rating,
           score: score,
           whites: whites,
           blacks: blacks,
           cd: whites - blacks,
           colours: colours,
           pref: preference(whites - blacks, colours),
           opponents: MapSet.new(for {_, g} <- played, do: g.opponent),
           bye_ineligible?:
             Enum.any?(hist, fn {_, g} ->
               g.code == "U" or (not Trf.played?(g.code) and Trf.points(g.code) >= 2)
             end),
           float: float,
           unplayed: r - 1 - length(played),
           topscorer?: final? and score > top_threshold
         }}
      end)

    pool =
      all
      |> Enum.filter(fn {_, p} -> not Map.has_key?(p.games, r) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    %__MODULE__{
      round: r,
      pool: pool,
      players: players,
      final?: final?,
      initial_colour: trf.initial_colour || infer_initial_colour(trf, all, pool, r),
      arrival: arrival_numbers(all, pool, r),
      trf: trf
    }
  end

  # 1.4.2 and 1.4.3, for round t.
  defp float_in(p, t, before, all) do
    case p.games[t] do
      nil ->
        nil

      g ->
        cond do
          Trf.played?(g.code) ->
            mine = before[p.rank]
            theirs = before[g.opponent]

            cond do
              mine > theirs -> :down
              mine < theirs -> :up
              true -> nil
            end

          g.code == "U" ->
            :down

          # "without playing, scores more points than those rewarded for a loss"
          Trf.points(g.code) > 0 ->
            :down

          true ->
            _ = all
            nil
        end
    end
  end

  # 1.7.1-1.7.4
  defp preference(_cd, []), do: nil

  defp preference(cd, colours) do
    last_two =
      case Enum.take(colours, -2) do
        [c, c] -> c
        _ -> nil
      end

    cond do
      cd < -1 -> {:w, :absolute}
      cd > 1 -> {:b, :absolute}
      last_two == :b -> {:w, :absolute}
      last_two == :w -> {:b, :absolute}
      cd == -1 -> {:w, :strong}
      cd == 1 -> {:b, :strong}
      true -> {opposite(List.last(colours)), :mild}
    end
  end

  def opposite(:w), do: :b
  def opposite(:b), do: :w

  @doc "Strength of a preference as a number: none 0, mild 1, strong 2, absolute 3."
  def strength(nil), do: 0
  def strength({_, :mild}), do: 1
  def strength({_, :strong}), do: 2
  def strength({_, :absolute}), do: 3

  @doc """
  5.2.5's number: the SPP's numbering of the players who have arrived (see
  the engine's `docs/conformance-c0403-2026.md`, note 5). A player is
  numbered when in round `r`'s pool, or when an earlier game of theirs was
  seated by a pairing: a real opponent, a `U` or a `+`.
  """
  def arrival_numbers(all, pool, r) do
    pool = MapSet.new(pool)

    all
    |> Enum.filter(fn {rank, p} ->
      MapSet.member?(pool, rank) or
        Enum.any?(p.games, fn {t, g} -> t < r and (g.opponent != nil or g.code in ["U", "+"]) end)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Map.new()
  end

  # With no 152/XXC, the initial colour is read off round one, as a file
  # paired by these rules must allow: the higher-ranked player of a played
  # round-one board had the initial colour if their number was odd.
  defp infer_initial_colour(_trf, all, _pool, r) when r <= 1 do
    _ = all
    :w
  end

  defp infer_initial_colour(_trf, all, _pool, _r) do
    numbers = arrival_numbers(all, [], 2)

    all
    |> Enum.sort()
    |> Enum.find_value(:w, fn {rank, p} ->
      case p.games[1] do
        %{opponent: opp, colour: c} when opp != nil and c != nil and opp > rank ->
          n = Map.get(numbers, rank, rank)
          if rem(n, 2) == 1, do: c, else: opposite(c)

        _ ->
          nil
      end
    end)
  end

  @doc "1.2: score descending, then starting rank ascending."
  def order_key(pos, rank), do: {-pos.players[rank].score, rank}

  def sort(pos, ranks), do: Enum.sort_by(ranks, &order_key(pos, &1))
end

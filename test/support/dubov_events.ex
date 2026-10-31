defmodule Ainalrami.Test.DubovEvents do
  @moduledoc """
  Reachable Dubov tournaments for the validation tests: a roster drawn from
  a seed, then played forward round by round - each round paired by the
  engine under test and given random results, as `Ainalrami.Generator` and
  the team events do (a history random structs could describe is not one a
  tournament produces).

  What a seed can switch on: unrated players with a provisional rating,
  arbiter byes recorded before the pairing (`H`, `Z`), a late entrant who
  arrives in round 3, forfeits (one-sided and double), an `XXP` pair,
  Baku virtual points (C.04.7), and either initial colour.
  """

  alias Ainalrami.Acceleration

  @doc """
  Plays the event of `seed` and calls `visit.(players, opts, round)` before
  each round; `visit` returns the round's pairs (`{w, b}`, the bye as
  `{rank, nil}`) to play, or `:stop`. Returns the number of rounds visited.

  `sizes` is the range the roster size is drawn from.
  """
  def play(seed, sizes, visit) do
    :rand.seed(:exsss, {seed, seed * 31 + 7, seed * 977 + 13})
    n = Enum.random(sizes)
    rounds = Enum.random(3..max(3, min(n - 1, 9)))

    unrated = if chance(20), do: Enum.take_random(1..n, Enum.random(1..2)), else: []

    players =
      for r <- 1..n do
        rating =
          if r in unrated, do: 0, else: 2600 - r * Enum.random(10..60) + Enum.random(-40..40)

        %{
          rank: r,
          points: 0.0,
          games: [],
          fide_rating: if(r in unrated, do: 0, else: max(rating, 1001))
        }
      end

    provisional = Map.new(unrated, &{&1, Enum.random(1100..1900)})
    players = if chance(20), do: Acceleration.baku(players, rounds), else: players
    late = if chance(15) and n >= 6, do: Enum.random(1..n), else: nil

    opts =
      [
        expected_rounds: rounds,
        initial_colour: Enum.random(["w", "b"]),
        provisional_ratings: provisional
      ] ++
        if(chance(20),
          do: [forbidden_pairs: [Enum.take_random(1..n, 2)]],
          else: []
        )

    bye_pct = if chance(40), do: Enum.random(3..12), else: 0
    forfeit_pct = if chance(40), do: Enum.random(3..15), else: 0

    Enum.reduce_while(1..rounds, {players, 0}, fn round, {players, visited} ->
      players = pre_record(players, round, late, bye_pct)

      if Enum.all?(players, &(length(&1.games) >= round)) do
        {:cont, {players, visited}}
      else
        case visit.(players, opts, round) do
          :stop -> {:halt, {players, visited + 1}}
          pairs -> {:cont, {play_round(players, pairs, forfeit_pct), visited + 1}}
        end
      end
    end)
    |> elem(1)
  end

  defp chance(pct), do: :rand.uniform(100) <= pct

  # A late entrant's first two rounds, and arbiter byes asked for before
  # the pairing: the engine leaves such a player out of the round.
  defp pre_record(players, round, late, bye_pct) do
    Enum.map(players, fn p ->
      cond do
        p.rank == late and round <= 2 -> record(p, "Z", 0.0)
        bye_pct > 0 and round > 1 and :rand.uniform(100) <= bye_pct -> record(p, "H", 0.5)
        true -> p
      end
    end)
  end

  defp record(p, code, points) do
    %{
      p
      | points: p.points + points,
        games: p.games ++ [%{opponent_rank: nil, colour: nil, result: code}]
    }
  end

  defp play_round(players, pairs, forfeit_pct) do
    results =
      pairs
      |> Enum.flat_map(fn
        {w, nil} ->
          [{w, {%{opponent_rank: nil, colour: nil, result: "U"}, 1.0}}]

        {w, b} ->
          {rw, rb, pw, pb} =
            if forfeit_pct > 0 and :rand.uniform(100) <= forfeit_pct do
              Enum.random([{"+", "-", 1.0, 0.0}, {"-", "+", 0.0, 1.0}, {"-", "-", 0.0, 0.0}])
            else
              Enum.random([{"1", "0", 1.0, 0.0}, {"0", "1", 0.0, 1.0}, {"=", "=", 0.5, 0.5}])
            end

          [
            {w, {%{opponent_rank: b, colour: "w", result: rw}, pw}},
            {b, {%{opponent_rank: w, colour: "b", result: rb}, pb}}
          ]
      end)
      |> Map.new()

    Enum.map(players, fn p ->
      case Map.fetch(results, p.rank) do
        {:ok, {g, pts}} -> %{p | points: p.points + pts, games: p.games ++ [g]}
        _ -> p
      end
    end)
  end
end

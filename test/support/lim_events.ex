defmodule Ainalrami.Test.LimEvents do
  @moduledoc """
  Reachable Lim tournaments for the validation tests: a roster drawn
  from a seed, played forward round by round - each round paired by the
  engine under test, given random results - as `Ainalrami.Test.DubovEvents`
  does for Dubov.

  What a seed can switch on: half-point byes recorded before the pairing
  (`H`), zero-point byes (`Z`), withdrawals (a `Z` every round from some
  round on, sometimes with a return),
  a late entrant who arrives in round 3, forfeits (one-sided and double),
  an `XXP` pair, a 3-1-0 point system, and either
  initial colour.
  """

  alias Ainalrami.Trf

  @doc """
  Plays the event of `seed` and calls `visit.(players, opts, round)` before
  each round; `visit` returns the round's pairs (`{w, b}`, the bye as
  `{rank, nil}`) to play, or `:stop`. Returns the number of rounds visited.
  """
  def play(seed, sizes, visit) do
    :rand.seed(:exsss, {seed, seed * 31 + 7, seed * 977 + 13})
    n = Enum.random(sizes)
    rounds = Enum.random(3..max(3, min(n - 1, 9)))

    players =
      for r <- 1..n do
        rating = 2600 - r * Enum.random(10..60) + Enum.random(-40..40)
        %{rank: r, points: 0.0, games: [], fide_rating: max(rating, 1001)}
      end

    late = if chance(15) and n >= 6, do: Enum.random(1..n), else: nil

    point_system =
      if chance(15),
        do: %{Trf.default_point_system() | win: 3.0, draw: 1.0, pairing_allocated_bye: 3.0},
        else: nil

    withdrawn =
      if chance(30) do
        for r <- Enum.take_random(1..n, Enum.random(1..2)),
            into: %{},
            do: {r, {Enum.random(2..rounds), if(chance(40), do: Enum.random(1..2))}}
      else
        %{}
      end

    opts =
      [expected_rounds: rounds, initial_colour: Enum.random(["w", "b"])] ++
        if(point_system, do: [point_system: point_system], else: []) ++
        if(chance(20), do: [forbidden_pairs: [Enum.take_random(1..n, 2)]], else: [])

    ps = point_system || Trf.default_point_system()
    bye_pct = if chance(40), do: Enum.random(3..12), else: 0
    forfeit_pct = if chance(40), do: Enum.random(3..15), else: 0

    Enum.reduce_while(1..rounds, {players, 0}, fn round, {players, visited} ->
      players = pre_record(players, round, late, withdrawn, bye_pct, ps)

      if Enum.all?(players, &(length(&1.games) >= round)) do
        {:cont, {players, visited}}
      else
        case visit.(players, opts, round) do
          :stop -> {:halt, {players, visited + 1}}
          pairs -> {:cont, {play_round(players, pairs, forfeit_pct, ps), visited + 1}}
        end
      end
    end)
    |> elem(1)
  end

  defp chance(pct), do: :rand.uniform(100) <= pct

  defp pre_record(players, round, late, withdrawn, bye_pct, ps) do
    Enum.map(players, fn p ->
      away? =
        case withdrawn[p.rank] do
          {from, nil} -> round >= from
          {from, gone} -> round >= from and round < from + gone
          nil -> false
        end

      cond do
        p.rank == late and round <= 2 -> record(p, "Z", ps)
        away? -> record(p, "Z", ps)
        bye_pct > 0 and round > 1 and :rand.uniform(100) <= bye_pct -> record(p, "H", ps)
        bye_pct > 0 and round > 1 and :rand.uniform(200) <= bye_pct -> record(p, "Z", ps)
        true -> p
      end
    end)
  end

  defp record(p, code, ps) do
    game = %{opponent_rank: nil, colour: nil, result: code}
    %{p | points: p.points + Trf.points_for_game(game, ps), games: p.games ++ [game]}
  end

  defp play_round(players, pairs, forfeit_pct, ps) do
    results =
      pairs
      |> Enum.flat_map(fn
        {w, nil} ->
          [{w, %{opponent_rank: nil, colour: nil, result: "U"}}]

        {w, b} ->
          {rw, rb} =
            if forfeit_pct > 0 and :rand.uniform(100) <= forfeit_pct,
              do: Enum.random([{"+", "-"}, {"-", "+"}, {"-", "-"}]),
              else: Enum.random([{"1", "0"}, {"0", "1"}, {"=", "="}])

          [
            {w, %{opponent_rank: b, colour: "w", result: rw}},
            {b, %{opponent_rank: w, colour: "b", result: rb}}
          ]
      end)
      |> Map.new()

    Enum.map(players, fn p ->
      case Map.fetch(results, p.rank) do
        {:ok, g} -> %{p | points: p.points + Trf.points_for_game(g, ps), games: p.games ++ [g]}
        _ -> p
      end
    end)
  end
end

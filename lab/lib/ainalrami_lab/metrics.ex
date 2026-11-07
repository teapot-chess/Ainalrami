defmodule AinalramiLab.Metrics do
  @moduledoc """
  What a tournament looked like, measured on a fixed yardstick: the 2026
  text's own definitions (colour difference and preference, 1.6-1.7;
  floats, 1.4; scoregroups, 1.3), computed by `verify/`'s position model
  whatever variant paired the tournament. A variant that redefines an
  absolute preference is judged by what its players actually got, not by
  its own definitions.

  Per tournament (`tournament/2`):

  | metric | meaning |
  |---|---|
  | `streak3` | games that were a player's third or later consecutive game with the same colour, per 100 player-games from each player's third game on |
  | `abs_cd` | mean \\|CD\\| (whites minus blacks, played games) at the end |
  | `cd2_share` | % of players ending with \\|CD\\| >= 2 |
  | `denied` | colour preferences denied (1.7, as held before the game), per 100 boards |
  | `floats` | floats (1.4.2-1.4.4, up or down) per player per round |
  | `double_floats` | boards whose players' scores differ by a point or more, per 100 boards |
  | `repeat_float_1` | players floating the same way in two consecutive rounds, per 100 player-rounds |
  | `repeat_float_2` | the same, two rounds apart |
  | `cascade` | per round, the longest run of consecutive brackets each passing a downfloater on (the bye's bracket excluded), averaged |
  | `score_gap` | sum of score differences across the boards, points per round |
  | `top_games` | games among the top quarter of the seeds |
  | `top2_met` | % of tournaments in which seeds 1 and 2 met |
  | `rematches` | games between players who had already met (only nonzero with `rematches=allowed`) |
  | `c525_boards` | boards from round 2 on whose colours Article 5.2.5 decided |
  | `c525_sensitive` | of those, boards on which the arrival numbering and the TPN give opposite colours |
  """

  alias AinalramiLab.Rules
  alias AinalramiVerify.{Bracket, Position, Trf}

  @names ~w(streak3 abs_cd cd2_share denied floats double_floats repeat_float_1 repeat_float_2 cascade score_gap top_games top2_met rematches c525_boards c525_sensitive)

  def names, do: @names

  @doc "Metrics of one played tournament (`AinalramiLab.Tournament.play/5`'s result)."
  def tournament(spec, played) do
    n = played.players
    hist = played.history
    rounds_done = length(hist)
    final_trf = AinalramiLab.Tournament.write(spec, hist)
    final = final_trf |> Trf.parse() |> Position.build(rounds_done + 1)
    players = Map.values(final.players)
    paired = Enum.filter(played.rounds, &match?({:ok, _}, &1.result))
    boards = Enum.flat_map(paired, fn r -> elem(r.result, 1).pairs end)
    nboards = max(length(boards), 1)

    {streaks, streak_den} =
      Enum.reduce(players, {0, 0}, fn p, {s, d} ->
        cs = p.colours

        runs =
          cs
          |> Enum.chunk_every(3, 1, :discard)
          |> Enum.count(fn [a, b, c] -> a == b and b == c end)

        {s + runs, d + max(length(cs) - 2, 0)}
      end)

    floats = players |> Enum.map(&map_size(&1.float)) |> Enum.sum()

    repeat = fn gap ->
      players
      |> Enum.map(fn p ->
        Enum.count(p.float, fn {t, dir} -> Map.get(p.float, t - gap) == dir end)
      end)
      |> Enum.sum()
    end

    {double, gap_sum, rematches, top_games, met12} =
      Enum.reduce(paired, {0, 0, 0, 0, false}, fn rec, acc ->
        {:ok, round} = rec.result
        pl = rec.pos.players
        top = div(n + 3, 4)

        Enum.reduce(round.pairs, acc, fn {w, b}, {d, g, rm, tg, m} ->
          diff = abs(pl[w].score - pl[b].score)

          {d + if(diff >= 2, do: 1, else: 0), g + diff,
           rm + if(MapSet.member?(pl[w].opponents, b), do: 1, else: 0),
           tg + if(w <= top and b <= top, do: 1, else: 0), m or Enum.sort([w, b]) == [1, 2]}
        end)
      end)

    denied =
      Enum.reduce(paired, 0, fn rec, acc ->
        {:ok, round} = rec.result
        pl = rec.pos.players

        acc +
          Enum.sum(
            for {w, b} <- round.pairs do
              d = fn p, got -> if p.pref != nil and elem(p.pref, 0) != got, do: 1, else: 0 end
              d.(pl[w], :w) + d.(pl[b], :b)
            end
          )
      end)

    {c525, sensitive} =
      Enum.reduce(paired, {0, 0}, fn rec, acc ->
        {:ok, round} = rec.result

        if rec.round < 2 do
          acc
        else
          round.pairs
          |> Enum.zip(Map.get(round, :articles, List.duplicate(nil, length(round.pairs))))
          |> Enum.reduce(acc, fn
            {{w, b}, "5.2.5"}, {c, s} ->
              hi =
                if Position.order_key(rec.pos, w) <= Position.order_key(rec.pos, b),
                  do: w,
                  else: b

              diff? =
                Rules.c525_colour(rec.pos, hi, :arrival) != Rules.c525_colour(rec.pos, hi, :tpn)

              {c + 1, s + if(diff?, do: 1, else: 0)}

            _, acc ->
              acc
          end)
        end
      end)

    cascades =
      Enum.map(paired, fn rec ->
        {:ok, round} = rec.result
        cascade(rec.pos, round.pairs)
      end)

    %{
      "streak3" => 100 * streaks / max(streak_den, 1),
      "abs_cd" => mean(Enum.map(players, &abs(&1.cd))),
      "cd2_share" => 100 * Enum.count(players, &(abs(&1.cd) >= 2)) / n,
      "denied" => 100 * denied / nboards,
      "floats" => floats / n / max(rounds_done, 1),
      "double_floats" => 100 * double / nboards,
      "repeat_float_1" => 100 * repeat.(1) / n / max(rounds_done, 1),
      "repeat_float_2" => 100 * repeat.(2) / n / max(rounds_done, 1),
      "cascade" => mean(cascades),
      "score_gap" => gap_sum / 2 / max(length(paired), 1),
      "top_games" => top_games,
      "top2_met" => if(met12, do: 100, else: 0),
      "rematches" => rematches,
      "c525_boards" => c525,
      "c525_sensitive" => sensitive
    }
  end

  @doc """
  The cascade of one round: the brackets the round implies (1.3.2), top
  down, and the longest run of consecutive ones that each passed at
  least one downfloater on. The lowest bracket's leftover is the bye and
  does not count.
  """
  def cascade(%Position{} = pos, pairs) do
    ctx = Bracket.context(pos)

    try do
      ctx
      |> Bracket.structure(pairs)
      |> Enum.drop(-1)
      |> Enum.map(fn {_b, {_ps, df}} -> df != [] end)
      |> Enum.chunk_by(& &1)
      |> Enum.filter(&hd/1)
      |> Enum.map(&length/1)
      |> Enum.max(fn -> 0 end)
    after
      Bracket.cleanup(ctx)
    end
  end

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
end

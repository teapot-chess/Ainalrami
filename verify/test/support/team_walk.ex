defmodule AinalramiVerify.TeamWalk do
  @moduledoc """
  Played team events for the team certificate tests: every round's input
  record (`ainalrami-team-input`) as a host would store it, paired by the
  engine through `AinalramiVerify.Engine`, then given random match results
  - including teams sitting a round out - before the next round is built.
  """

  alias AinalramiVerify.Engine

  @boards 4

  @doc """
  `[{input_record, round}]` for one event. Options: `:teams`, `:rounds`,
  `:seed`, `:score_mode` ("match_points" | "game_points"), `:keep_apart`
  (adds a forbidden and a soft group of the first teams).
  """
  def rounds(opts) do
    n = Keyword.fetch!(opts, :teams)
    rounds = Keyword.fetch!(opts, :rounds)
    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), n, rounds})
    mode = Keyword.get(opts, :score_mode, "match_points")
    initial = Enum.random(["white", "black"])

    state =
      Map.new(1..n, fn tpn ->
        {tpn,
         %{
           "tpn" => tpn,
           "match_points" => 0,
           "game_points" => 0.0,
           "opponents" => [],
           "colours" => [],
           "had_pab" => false,
           "won_by_forfeit" => false,
           "floated_last_round" => false,
           arrived: false
         }}
      end)

    {_, acc} =
      Enum.reduce_while(1..rounds, {state, []}, fn r, {state, acc} ->
        out = if r > 1, do: for({tpn, _} <- state, :rand.uniform(10) == 1, do: tpn), else: []
        field = state |> Map.values() |> Enum.reject(&(&1["tpn"] in out))

        input = %{
          "format" => "ainalrami-team-input",
          "version" => 1,
          "round" => r,
          "expected_rounds" => rounds,
          "score_mode" => mode,
          "use_secondary" => true,
          "type" => "a",
          "initial_colour" => initial,
          "absent" => for(tpn <- out, state[tpn].arrived, do: tpn) |> Enum.sort(),
          "forbidden_pairs" => keep_apart(opts, [1, 2]),
          "soft_pairs" => keep_apart(opts, [3, 4]),
          "teams" => field |> Enum.sort_by(& &1["tpn"]) |> Enum.map(&Map.delete(&1, :arrived))
        }

        case length(field) >= 2 && Engine.team_pair(input) do
          {:ok, round} -> {:cont, {play(state, round, mode), [{input, round} | acc]}}
          _ -> {:halt, {state, acc}}
        end
      end)

    Enum.reverse(acc)
  end

  defp keep_apart(opts, tpns), do: if(opts[:keep_apart], do: [%{"teams" => tpns}], else: [])

  defp play(state, round, mode) do
    primary = fn t -> t[mode] end

    state =
      Enum.reduce(round.pairs, state, fn %{white: w, black: b}, st ->
        gw = Enum.sum(for _ <- 1..@boards, do: Enum.random([0, 0.5, 1]))
        gb = @boards - gw

        {mw, mb} =
          cond do
            gw > gb -> {2, 0}
            gw < gb -> {0, 2}
            true -> {1, 1}
          end

        floated? = primary.(st[w]) != primary.(st[b])

        st
        |> Map.update!(w, &result(&1, b, :white, mw, gw, floated?))
        |> Map.update!(b, &result(&1, w, :black, mb, gb, floated?))
      end)

    paired = MapSet.new(Enum.flat_map(round.pairs, &[&1.white, &1.black]))

    Map.new(state, fn {tpn, t} ->
      cond do
        tpn == round.bye ->
          {tpn,
           %{
             t
             | "match_points" => t["match_points"] + 1,
               "game_points" => t["game_points"] + @boards / 2
           }
           |> Map.merge(%{"had_pab" => true, "floated_last_round" => false, arrived: true})}

        MapSet.member?(paired, tpn) ->
          {tpn, t}

        true ->
          {tpn, %{t | "floated_last_round" => false}}
      end
    end)
  end

  defp result(t, opp, colour, mp, gp, floated?) do
    %{
      t
      | "match_points" => t["match_points"] + mp,
        "game_points" => t["game_points"] + gp,
        "opponents" => t["opponents"] ++ [opp],
        "colours" => t["colours"] ++ [Atom.to_string(colour)],
        "floated_last_round" => floated?
    }
    |> Map.put(:arrived, true)
  end
end

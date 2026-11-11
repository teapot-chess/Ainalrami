defmodule Ainalrami.TeamProof.LargeEvents do
  @moduledoc """
  Played C.04.6 events shaped like real large team tournaments, for the
  100-200 team proof (`test/ainalrami/team_proof_xl_test.exs`).

  `Ainalrami.TeamProof.Events` plays one shape: 4 boards, coin-flip boards,
  3-9 rounds, one team in twelve sitting out. That is a fine way to reach
  odd histories and a poor likeness of an Olympiad. This generator draws a
  SHAPE per seed and plays that:

    * 100-200 teams, 4-6 boards, 7-11 rounds;
    * results either flat (every board a coin with a draw side) or RATED
      (team strength falls with the TPN, so the field sorts itself into the
      long thin scoregroups a real event has, with a spread drawn per event);
    * teams sitting a round out, teams WITHDRAWING for good, late entrants
      joining in round 2 or 3, matches forfeited as a whole - each at a rate
      drawn per event, including zero;
    * odd fields (and so pairing-allocated byes) whenever the head-count of
      the round happens to be odd, which absences make happen about half
      the time.

  Colour histories, float flags, byes and forfeit wins are whatever the
  played rounds produced; nothing is invented. As in `Events`, every round is
  paired by the caller's function (the engine), given results, and the next
  round is paired from that. Its own random stream: a seed here is not the
  same event as that seed in `Events`.
  """

  alias Ainalrami.TeamPairing.Team

  @doc """
  The shape seed `seed` plays. `sizes` is the list (or range) the field size
  is drawn from.
  """
  def shape(seed, sizes \\ 100..200) do
    :rand.seed(:exsss, {seed, 11 * seed + 5, 13 * seed + 7})

    %{
      seed: seed,
      size: Enum.random(sizes),
      boards: Enum.random(4..6),
      rounds: Enum.random(7..11),
      initial: Enum.random([:white, :black]),
      # nil = flat results; a number = the strength gap, in logistic units,
      # between the first and the last TPN.
      spread: Enum.random([nil, 1.5, 3.0, 5.0]),
      sit_out: Enum.random([0, 60, 25, 12]),
      withdraw: Enum.random([0, 0, 200, 80]),
      forfeit: Enum.random([0, 60, 25, 15]),
      late: Enum.random([0, 0, 1, 3, 6])
    }
  end

  @doc """
  Plays the event of `shape`. `pair` is called with the round number, the
  round's field, the arrived-but-absent TPNs and the options to pair with;
  it returns the engine's round (results are then made up and applied) or
  `:stop`. Returns the number of rounds paired. Call `shape/2` first: it
  seeds the stream this continues.
  """
  def play(shape, pair) do
    late = Enum.take_random(1..shape.size, min(shape.late, shape.size - 2))

    state =
      Map.new(1..shape.size, fn tpn ->
        joins = if tpn in late, do: Enum.random(2..3), else: 1
        noise = :rand.normal() * 0.35

        {tpn,
         %{
           team: %Team{tpn: tpn, match_points: 0.0, game_points: 0.0},
           arrived?: false,
           joins: joins,
           withdrawn?: false,
           strength: -((tpn - 1) / shape.size) * (shape.spread || 0.0) + noise
         }}
      end)

    {_state, count} =
      Enum.reduce_while(1..shape.rounds, {state, 0}, fn round_no, {state, count} ->
        # Withdrawals are for good, and only of teams that have played.
        state =
          Map.new(state, fn {tpn, s} ->
            gone? =
              s.withdrawn? or
                (round_no > 1 and s.arrived? and shape.withdraw > 0 and
                   :rand.uniform(shape.withdraw) == 1)

            {tpn, %{s | withdrawn?: gone?}}
          end)

        sitting_out =
          for {tpn, s} <- state,
              round_no > 1 and not s.withdrawn? and s.joins <= round_no and shape.sit_out > 0 and
                :rand.uniform(shape.sit_out) == 1,
              do: tpn

        out = MapSet.new(sitting_out)

        field =
          state
          |> Enum.filter(fn {tpn, s} ->
            s.joins <= round_no and not s.withdrawn? and not MapSet.member?(out, tpn)
          end)
          |> Enum.map(fn {_tpn, s} -> s.team end)
          |> Enum.sort_by(& &1.tpn)

        in_field = MapSet.new(field, & &1.tpn)

        absent =
          for({tpn, s} <- state, s.arrived? and not MapSet.member?(in_field, tpn), do: tpn)
          |> Enum.sort()

        if length(field) < 2 do
          {:cont, {state, count}}
        else
          opts = [
            round: round_no,
            expected_rounds: shape.rounds,
            initial_colour: shape.initial,
            absent: absent
          ]

          case pair.(round_no, field, absent, opts) do
            :stop -> {:halt, {state, count}}
            round -> {:cont, {apply_round(state, round, shape), count + 1}}
          end
        end
      end)

    count
  end

  defp apply_round(state, round, shape) do
    scores = Map.new(state, fn {tpn, s} -> {tpn, s.team.match_points} end)
    boards = shape.boards

    state =
      Enum.reduce(round.pairs, state, fn %{white: w, black: b}, state ->
        floated? = scores[w] != scores[b]

        if shape.forfeit > 0 and :rand.uniform(shape.forfeit) == 1 do
          # The whole match forfeited by one side (C.04.2 3.5: not played, so
          # not a meeting and no colour - and, 1.5, nobody's float).
          {winner, loser} = if :rand.uniform(2) == 1, do: {w, b}, else: {b, w}

          state
          |> update_team(winner, fn t ->
            %{
              t
              | match_points: t.match_points + 2.0,
                game_points: t.game_points + boards,
                won_by_forfeit?: true,
                floated_last_round?: false
            }
          end)
          |> update_team(loser, &%{&1 | floated_last_round?: false})
        else
          gap = state[w].strength - state[b].strength
          gp_w = Enum.sum(for _ <- 1..boards, do: board(gap, shape.spread))
          gp_b = boards - gp_w

          {mp_w, mp_b} =
            cond do
              gp_w > gp_b -> {2.0, 0.0}
              gp_w < gp_b -> {0.0, 2.0}
              true -> {1.0, 1.0}
            end

          state
          |> update_team(w, fn t ->
            %{
              t
              | match_points: t.match_points + mp_w,
                game_points: t.game_points + gp_w,
                opponents: [b | t.opponents],
                colours: t.colours ++ [:white],
                floated_last_round?: floated?
            }
          end)
          |> update_team(b, fn t ->
            %{
              t
              | match_points: t.match_points + mp_b,
                game_points: t.game_points + gp_b,
                opponents: [w | t.opponents],
                colours: t.colours ++ [:black],
                floated_last_round?: floated?
            }
          end)
        end
      end)

    state =
      if round.bye do
        # 1.4: as many match points and game points as a draw.
        update_team(state, round.bye, fn t ->
          %{
            t
            | match_points: t.match_points + 1.0,
              game_points: t.game_points + boards / 2,
              had_pab?: true,
              floated_last_round?: false
          }
        end)
      else
        state
      end

    paired = MapSet.new(Enum.flat_map(round.pairs, &[&1.white, &1.black]) ++ List.wrap(round.bye))

    Map.new(state, fn {tpn, s} ->
      if MapSet.member?(paired, tpn),
        do: {tpn, %{s | arrived?: true}},
        else: {tpn, %{s | team: %{s.team | floated_last_round?: false}}}
    end)
  end

  # One board, from the first team's side.
  defp board(_gap, nil), do: Enum.random([1.0, 0.5, 0.0])

  defp board(gap, _spread) do
    expected = 1 / (1 + :math.exp(-gap))
    draw = 0.4 * (1 - abs(2 * expected - 1))
    win = expected - draw / 2
    x = :rand.uniform()

    cond do
      x < win -> 1.0
      x < win + draw -> 0.5
      true -> 0.0
    end
  end

  defp update_team(state, tpn, fun), do: Map.update!(state, tpn, &%{&1 | team: fun.(&1.team)})
end

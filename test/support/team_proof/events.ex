defmodule Ainalrami.TeamProof.Events do
  @moduledoc """
  Played C.04.6 events for the whole-round proofs, and the views of an
  engine round the proofs compare.

  Moved here unchanged from `test/ainalrami/team_pairing_validation_test.exs`
  so the naive proof (4-10 teams) and the exact proof (11-80 teams,
  `test/ainalrami/team_proof_large_test.exs`) generate histories the same
  way. The random stream is consumed in exactly the order it was before the
  move, so a seed means the same event it always did.

  Every history is PLAYED: each round is paired by the caller's function
  (the engine) and given random results - including matches forfeited as a
  whole, pairing-allocated byes and teams sitting a round out - and the next
  round is paired from that.
  """

  alias Ainalrami.TeamPairing.Team

  @boards 4

  # Plays `rounds` rounds of a `size`-team event. `pair` is called with the
  # round number, the teams in this round's field, the arrived-but-absent
  # TPNs and the options to pair with; it returns the engine's round, whose
  # results are then made up and applied. Returns the number of rounds
  # paired.
  def play_event(size, rounds, initial, pair) do
    teams = for tpn <- 1..size, do: {tpn, %{team: team(tpn), arrived?: false}}

    {_teams, count} =
      Enum.reduce_while(1..rounds, {Map.new(teams), 0}, fn round_no, {state, count} ->
        # About one team in twelve sits a round out, from round 2 on.
        sitting_out =
          if round_no > 1,
            do: for({tpn, _} <- state, :rand.uniform(12) == 1, do: tpn),
            else: []

        field =
          state
          |> Enum.reject(fn {tpn, _} -> tpn in sitting_out end)
          |> Enum.map(fn {_tpn, s} -> s.team end)
          |> Enum.sort_by(& &1.tpn)

        absent =
          for {tpn, s} <- state, tpn in sitting_out, s.arrived?, do: tpn

        if length(field) < 2 do
          {:cont, {state, count}}
        else
          opts = [
            round: round_no,
            expected_rounds: rounds,
            initial_colour: initial,
            absent: Enum.sort(absent)
          ]

          case pair.(round_no, field, Enum.sort(absent), opts) do
            :stop -> {:halt, {state, count}}
            round -> {:cont, {apply_round(state, round, sitting_out), count + 1}}
          end
        end
      end)

    count
  end

  defp apply_round(state, round, sitting_out) do
    scores = Map.new(state, fn {tpn, s} -> {tpn, s.team.match_points} end)

    state =
      Enum.reduce(round.pairs, state, fn %{white: w, black: b}, state ->
        floated? = scores[w] != scores[b]

        if :rand.uniform(15) == 1 do
          # The whole match forfeited by one side (C.04.2 3.5: not played, so
          # not a meeting and no colour - and, 1.5, nobody's float).
          {winner, loser} = if :rand.uniform(2) == 1, do: {w, b}, else: {b, w}

          state
          |> update_team(winner, fn t ->
            %{
              t
              | match_points: t.match_points + 2.0,
                game_points: t.game_points + @boards,
                won_by_forfeit?: true,
                floated_last_round?: false
            }
          end)
          |> update_team(loser, &%{&1 | floated_last_round?: false})
        else
          boards = for _ <- 1..@boards, do: Enum.random([1.0, 0.5, 0.0])
          gp_w = Enum.sum(boards)
          gp_b = @boards - gp_w

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
              game_points: t.game_points + @boards / 2,
              had_pab?: true,
              floated_last_round?: false
          }
        end)
      else
        state
      end

    paired = MapSet.new(Enum.flat_map(round.pairs, &[&1.white, &1.black]) ++ List.wrap(round.bye))

    Map.new(state, fn {tpn, s} ->
      cond do
        MapSet.member?(paired, tpn) -> {tpn, %{s | arrived?: true}}
        tpn in sitting_out -> {tpn, %{s | team: %{s.team | floated_last_round?: false}}}
        true -> {tpn, s}
      end
    end)
  end

  defp update_team(state, tpn, fun), do: Map.update!(state, tpn, &%{&1 | team: fun.(&1.team)})

  def normalise(round) do
    %{bye: round.bye, pairs: round.pairs |> Enum.map(&{&1.white, &1.black}) |> Enum.sort()}
  end

  # The engine's recorded reasons, cut to what the reference can say
  # independently: the bye's passed-over teams and deciding tie-break, each
  # bracket's chosen set and deciding criterion, each pair's Article 4 rules.
  def reasons(explanation) do
    %{
      bye:
        explanation.bye &&
          %{
            tpn: explanation.bye.tpn,
            passed_over: Enum.map(explanation.bye.passed_over, & &1.tpn),
            decided_by: explanation.bye.decided_by
          },
      brackets:
        Enum.map(explanation.brackets, fn b ->
          %{upfloaters: b.selection.chosen.upfloaters, decided_by: b.selection.decided_by}
        end),
      rules:
        explanation.pairs
        |> Enum.map(&{&1.white, &1.black, &1.first_team_rule, &1.colour_rule})
        |> Enum.sort()
    }
  end

  # `mp:` is short for `match_points:`; every other key is a struct field.
  # `struct/2` drops unknown keys silently, so the alias is translated rather
  # than passed through.
  def team(tpn, fields \\ []) do
    {mp, fields} = Keyword.pop(fields, :mp, 0.0)
    struct(%Team{tpn: tpn, match_points: mp, game_points: 0.0}, fields)
  end

  def describe_team(t) do
    {t.tpn, t.match_points, t.game_points, Enum.sort(t.opponents), t.colours,
     if(t.had_pab?, do: :pab), if(t.won_by_forfeit?, do: :ff), if(t.floated_last_round?, do: :fl)}
  end
end

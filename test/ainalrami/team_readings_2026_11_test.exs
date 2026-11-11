defmodule Ainalrami.TeamReadings202611Test do
  @moduledoc """
  The four C.04.6 readings settled on 2026-11-11, each on a position worked
  by hand (docs/conformance-c0406-teams.md, "2026-11-11"):

    * A - [C6]'s following scoregroup is the next score level below the
      residents among the WHOLE round's field (the bye team counted, absent
      teams not). When no team of that level is still to be paired once the
      candidate set has floated, the excess is 0 - nobody looks further
      down.
    * B - 1.5: only a PLAYED match against a different score makes a
      floater. A forfeited one does not.
    * C - a match is played when a board was played over the board OR both
      teams scored on a board by forfeit. Then it has a colour, it is a
      meeting, and it is nobody's forfeit win.
    * D - TRF26 record 352 states the board count; without it the old
      inference stands.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{TeamPairing, TeamReplay, Trf}
  alias Ainalrami.TeamPairing.Team
  alias Ainalrami.Tiebreaks.Team, as: TeamTiebreaks

  defp team(tpn, opts) do
    %Team{
      tpn: tpn,
      match_points: Keyword.get(opts, :mp, 0.0),
      opponents: Keyword.get(opts, :opponents, []),
      had_pab?: Keyword.get(opts, :pab, false)
    }
  end

  defp pairs(round), do: round.pairs |> Enum.map(&Enum.sort([&1.white, &1.black])) |> Enum.sort()

  defp upfloaters_into(round, residents) do
    bracket = Enum.find(round.explanation.brackets, &(Enum.sort(&1.residents) == residents))
    bracket.selection.chosen.upfloaters
  end

  describe "A - [C6]'s following scoregroup" do
    test "emptied by an earlier bracket: [C6] does not look further down" do
      # 4 points: 1, who has met 2 and 3, so it takes the 2-pointer 4.
      # 3 points: 2 and 3, who have met, need two 1-pointers. The next level
      # below 3 points is 2 points - gone with 4 - so [C6] is 0 for every
      # set and 3.5.4 takes 5 and 6, although that leaves 7 and 8 (who have
      # met) needing two 0-pointers. Measuring 1 point instead would have
      # floated 5 and 7.
      teams = [
        team(1, mp: 4.0, opponents: [2, 3]),
        team(2, mp: 3.0, opponents: [1, 3]),
        team(3, mp: 3.0, opponents: [1, 2]),
        team(4, mp: 2.0),
        team(5, mp: 1.0),
        team(6, mp: 1.0),
        team(7, mp: 1.0, opponents: [8]),
        team(8, mp: 1.0, opponents: [7]),
        team(9, mp: 0.0),
        team(10, mp: 0.0),
        team(11, mp: 0.0),
        team(12, mp: 0.0)
      ]

      assert {:ok, round} = TeamPairing.pair_round(teams, explain: true)
      assert upfloaters_into(round, [1]) == [4]
      assert upfloaters_into(round, [2, 3]) == [5, 6]
      assert [1, 4] in pairs(round)
      assert upfloaters_into(round, [7, 8]) |> length() == 2
    end

    test "the next level's only team has the bye: [C6] is 0" do
      # Nine teams; everyone below 3 points has had a bye, so it goes to 3,
      # the only team on 3 points. 1 and 2 (4 points, met) need two
      # 2-pointers. The following scoregroup is 3 points - empty once the
      # bye is out - so 3.5.4 takes 4 and 5 and leaves 6 and 7, who have
      # met. Measuring 2 points would have floated 4 and 6.
      teams = [
        team(1, mp: 4.0, opponents: [2]),
        team(2, mp: 4.0, opponents: [1]),
        team(3, mp: 3.0),
        team(4, mp: 2.0, pab: true),
        team(5, mp: 2.0, pab: true),
        team(6, mp: 2.0, pab: true, opponents: [7]),
        team(7, mp: 2.0, pab: true, opponents: [6]),
        team(8, mp: 1.0, pab: true),
        team(9, mp: 1.0, pab: true)
      ]

      assert {:ok, round} = TeamPairing.pair_round(teams, explain: true)
      assert round.bye == 3
      assert upfloaters_into(round, [1, 2]) == [4, 5]

      assert pairs(round) |> Enum.filter(&(&1 in [[6, 8], [6, 9], [7, 8], [7, 9]])) |> length() ==
               2
    end

    test "emptied by the candidate set itself: 0, and nobody looks further down" do
      # 1, 2 and 3 (3 points) have all met and need three upfloaters; 4 is
      # the only 2-pointer, so every set takes it and empties 2 points.
      # [C6] is 0 for all of them and 3.5.4 takes 4, 5, 6 - leaving 7 and 8
      # (met) to the 0-pointers. Looking on to 1 point would take 4, 5, 7.
      teams = [
        team(1, mp: 3.0, opponents: [2, 3]),
        team(2, mp: 3.0, opponents: [1, 3]),
        team(3, mp: 3.0, opponents: [1, 2]),
        team(4, mp: 2.0),
        team(5, mp: 1.0),
        team(6, mp: 1.0),
        team(7, mp: 1.0, opponents: [8]),
        team(8, mp: 1.0, opponents: [7]),
        team(9, mp: 0.0),
        team(10, mp: 0.0)
      ]

      assert {:ok, round} = TeamPairing.pair_round(teams, explain: true)
      assert upfloaters_into(round, [1, 2, 3]) == [4, 5, 6]

      assert pairs(round) |> Enum.filter(&(&1 in [[7, 9], [8, 10], [7, 10], [8, 9]])) |> length() ==
               2
    end
  end

  # ---- B and C: positions written as TRF26 files ----------------------------

  # Four teams of two boards: team 1 = players 1, 2; team 2 = 3, 4;
  # team 3 = 5, 6; team 4 = 7, 8. `rounds` is a list, one per round, of
  # `{rank => {opponent_rank, colour, result}}`; `forfeits` are 330 records.
  defp file(rounds, forfeits \\ []) do
    players =
      for rank <- 1..8 do
        games =
          for r <- rounds do
            case r[rank] do
              {opp, colour, result} -> %{opponent_rank: opp, colour: colour, result: result}
              nil -> %{opponent_rank: nil, colour: "-", result: ""}
            end
          end

        %{rank: rank, name: "P#{rank}", points: 0.0, games: games}
      end

    %{
      tournament: %{
        name: "readings",
        type: "team-swiss",
        type_code: "FIDE_TEAM_TYPEA_MP_GP",
        number_of_rounds: length(rounds),
        team_point_system: %{win: 2.0, draw: 1.0, loss: 0.0, pab: 2.0},
        forfeited_matches: forfeits,
        board_colours: "WB"
      },
      players: players,
      teams:
        for t <- 1..4 do
          %{number: t, name: "T#{t}", player_ranks: [2 * t - 1, 2 * t]}
        end
    }
    |> Trf.serialize(dialect: :trf26)
    |> Trf.parse()
  end

  # A game on board `b` between players `p` (white on board 1's team) and
  # `q`: White on odd boards for the first team.
  defp game(p, q, colour, rp, rq) do
    other = if colour == "w", do: "b", else: "w"
    %{p => {q, colour, rp}, q => {p, other, rq}}
  end

  defp match(t1, t2, {r1, q1}, {r2, q2}) do
    Map.merge(game(2 * t1 - 1, 2 * t2 - 1, "w", r1, q1), game(2 * t1, 2 * t2, "b", r2, q2))
  end

  defp state(parsed, round) do
    history = TeamReplay.history(parsed)

    {teams, _absent} =
      TeamReplay.state_for(history, round, %{score_mode: :match_points}, [1, 2, 3, 4])

    Map.new(teams, &{&1.tpn, &1})
  end

  describe "B - 1.5: only a played match floats anyone" do
    # Round 1: 1 beats 2 2-0, 3 and 4 draw 1-1 - so 1 on 2, 2 on 0, 3 and 4
    # on 1. Round 2: 1 (2) against 3 (1), and 2 (0) against 4 (1): both on
    # different scores.
    defp round_one,
      do: Map.merge(match(1, 2, {"1", "0"}, {"1", "0"}), match(3, 4, {"1", "0"}, {"0", "1"}))

    test "a forfeited match on different scores is not a float; a played one is" do
      # 1-3 played; 2-4 forfeited as a whole, 4 the winner.
      round_two =
        Map.merge(
          match(1, 3, {"1", "0"}, {"=", "="}),
          match(2, 4, {"-", "+"}, {"-", "+"})
        )

      parsed = file([round_one(), round_two], [%{type: "-+", round: 2, white: 2, black: 4}])
      s = state(parsed, 3)

      assert s[1].floated_last_round? and s[3].floated_last_round?
      refute s[2].floated_last_round? or s[4].floated_last_round?
      assert s[4].won_by_forfeit?
      refute 2 in s[4].opponents
    end

    test "both teams scoring by forfeit, nothing played, on different scores: a float" do
      round_two =
        Map.merge(
          match(1, 3, {"1", "0"}, {"=", "="}),
          match(2, 4, {"+", "-"}, {"-", "+"})
        )

      s = state(file([round_one(), round_two]), 3)
      assert s[2].floated_last_round? and s[4].floated_last_round?
    end
  end

  describe "C - a played match" do
    # Round 1: 1-2 with nothing played but a forfeit each way (1 wins board
    # 1, 2 wins board 2); 3-4 with only 3 scoring by forfeit.
    defp forfeits_round do
      Map.merge(match(1, 2, {"+", "-"}, {"-", "+"}), match(3, 4, {"+", "-"}, {"+", "-"}))
    end

    test "both sides scoring by forfeit with none played: played, a colour, a meeting, bars nothing" do
      parsed = file([forfeits_round()], [%{type: "+-", round: 1, white: 3, black: 4}])
      event = TeamTiebreaks.from_trf(parsed)

      assert event.teams[1].rounds[1].kind == :played
      assert event.teams[2].rounds[1].kind == :played
      assert {event.teams[1].rounds[1].mp, event.teams[2].rounds[1].mp} == {1.0, 1.0}

      s = state(parsed, 2)
      assert s[1].colours == [:white] and s[2].colours == [:black]
      assert s[1].opponents == [2] and s[2].opponents == [1]
      refute s[1].won_by_forfeit? or s[2].won_by_forfeit?
      assert s[1].matches_played == 1
    end

    test "one side only scoring: a forfeit - no colour, no meeting, a forfeit win" do
      parsed = file([forfeits_round()], [%{type: "+-", round: 1, white: 3, black: 4}])
      event = TeamTiebreaks.from_trf(parsed)

      assert event.teams[3].rounds[1].kind == :forfeit_win
      assert event.teams[4].rounds[1].kind == :forfeit_loss

      s = state(parsed, 2)
      assert s[3].colours == [] and s[4].colours == []
      assert s[3].opponents == [] and s[4].opponents == []
      assert s[3].won_by_forfeit?
      refute s[4].won_by_forfeit?
    end
  end

  describe "D - TRF26 record 352" do
    @allforfeit "test/fixtures/team_readings_2026_11/case_allforfeit.trf"

    test "the writer emits W on the odd boards" do
      assert Trf.board_colours(4) == "WBWB"
      assert Trf.board_colours(1) == "W"
      assert Trf.board_colours(5) == "WBWBW"
    end

    test "352 round-trips and gives the board count" do
      parsed = file([forfeits_round()])
      assert parsed.tournament.board_colours == "WB"
      assert TeamTiebreaks.board_count(parsed.tournament) == 2

      text = Trf.serialize(parsed, dialect: :trf26)
      assert text =~ ~r/^352 WB\r?$/m
      assert Trf.parse(text).tournament.board_colours == "WB"
    end

    test "an all-forfeit round: with 352 the winners get 4.0 game points" do
      parsed = @allforfeit |> File.read!() |> Trf.parse()
      event = TeamTiebreaks.from_trf(parsed)
      assert TeamReplay.boards(parsed) == 4

      for winner <- [1, 2] do
        assert %{kind: :forfeit_win, gp: 4.0} = event.teams[winner].rounds[1]
      end

      for loser <- [3, 4], do: assert(event.teams[loser].rounds[1].gp == 0.0)
    end

    test "without 352 nothing says how many boards there were" do
      text = @allforfeit |> File.read!() |> String.replace(~r/^352[^\n]*\n/m, "")
      parsed = Trf.parse(text)
      assert TeamReplay.boards(parsed) == nil
      refute TeamTiebreaks.from_trf(parsed).teams[1].rounds[1].gp == 4.0
    end

    test "a malformed 352 is ignored" do
      text = @allforfeit |> File.read!() |> String.replace("352 WBWB", "352 WBXB")
      assert Trf.parse(text).tournament[:board_colours] == nil
    end
  end
end

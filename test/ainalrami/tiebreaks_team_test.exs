defmodule Ainalrami.TiebreaksTeamTest do
  @moduledoc """
  C.07's team tie-breaks (Articles 11-13) against hand-worked events. Each
  expected value is worked out in the comment beside it.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Tiebreaks
  alias Ainalrami.Tiebreaks.Team
  alias Ainalrami.Tiebreaks.Team.{Entry, Match}

  # A match from one team's side: opponent and its game points per board.
  # Match points follow from the game points (2/1/0 for a win/draw/loss).
  defp match(opponent, boards) do
    board_map = boards |> Enum.with_index(1) |> Map.new(fn {gp, b} -> {b, gp} end)
    gp = Enum.sum(boards)
    theirs = length(boards) - gp

    mp =
      cond do
        gp > theirs -> 2.0
        gp == theirs -> 1.0
        true -> 0.0
      end

    %Match{kind: :played, opponent: opponent, mp: mp, gp: gp * 1.0, boards: board_map}
  end

  defp event(spec, opts) do
    rounds = spec |> Map.values() |> Enum.map(&length/1) |> Enum.max()

    entries =
      for {id, rounds_list} <- spec do
        %Entry{
          id: id,
          tpn: id,
          rounds: rounds_list |> Enum.with_index(1) |> Map.new(fn {m, r} -> {r, m} end)
        }
      end

    Team.new(entries, rounds, opts)
  end

  defp values(event, code) do
    {:ok, all} = Tiebreaks.compute(event, [code])
    all[code]
  end

  # ------------------------------------------------------------------
  # Four teams, four boards, three rounds of a Swiss.
  #
  #   R1: 1 3-1 2  (1: 1 1 ½ ½)        3 2-2 4  (3: 1 0 1 0)
  #   R2: 1 2-2 3  (all boards ½)      2 2½-1½ 4 (2: 1 ½ ½ ½)
  #   R3: 1 4-0 4                       3 3-1 2  (3: 1 1 ½ ½)
  #
  #   MP: 1 = 5, 2 = 2, 3 = 4, 4 = 1       GP: 1 = 9, 2 = 4.5, 3 = 7, 4 = 3.5
  # ------------------------------------------------------------------
  defp swiss do
    event(
      %{
        1 => [match(2, [1, 1, 0.5, 0.5]), match(3, [0.5, 0.5, 0.5, 0.5]), match(4, [1, 1, 1, 1])],
        2 => [
          match(1, [0, 0, 0.5, 0.5]),
          match(4, [1, 0.5, 0.5, 0.5]),
          match(3, [0, 0, 0.5, 0.5])
        ],
        3 => [match(4, [1, 0, 1, 0]), match(1, [0.5, 0.5, 0.5, 0.5]), match(2, [1, 1, 0.5, 0.5])],
        4 => [match(3, [0, 1, 0, 1]), match(2, [0, 0.5, 0.5, 0.5]), match(1, [0, 0, 0, 0])]
      },
      boards: 4
    )
  end

  describe "the scores (11.1, 13.1)" do
    test "MPTS, GPTS, and PTS as the primary (match points by default)" do
      assert values(swiss(), "MPTS") == %{1 => 5.0, 2 => 2.0, 3 => 4.0, 4 => 1.0}
      assert values(swiss(), "GPTS") == %{1 => 9.0, 2 => 4.5, 3 => 7.0, 4 => 3.5}
      assert values(swiss(), "PTS") == values(swiss(), "MPTS")
    end

    test "MPvGP is the secondary score" do
      assert values(swiss(), "MPVGP") == values(swiss(), "GPTS")
    end
  end

  describe "individual tie-breaks through a score (Article 13)" do
    test "BH:MP sums the opponents' match points" do
      # 1: 2 + 4 + 1   2: 5 + 1 + 4   3: 1 + 5 + 2   4: 4 + 2 + 5
      assert values(swiss(), "BH:MP") == %{1 => 7.0, 2 => 10.0, 3 => 8.0, 4 => 11.0}
    end

    test "BH:GP sums their game points" do
      # 1: 4.5 + 7 + 3.5
      assert values(swiss(), "BH:GP")[1] == 15.0
    end

    test "a code without a score uses the primary" do
      assert values(swiss(), "BH") == values(swiss(), "BH:MP")
    end
  end

  describe "extended Sonneborn-Berger (13.2)" do
    test "EMGSB: opponent's match points times game points scored" do
      # 1: 2x3 + 4x2 + 1x4 = 18         2: 5x1 + 1x2.5 + 4x1 = 11.5
      # 3: 1x2 + 5x2 + 2x3 = 18         4: 4x2 + 2x1.5 + 5x0 = 11
      assert values(swiss(), "EMGSB") == %{1 => 18.0, 2 => 11.5, 3 => 18.0, 4 => 11.0}
    end

    test "EMMSB: match points both ways" do
      # 1: 2x2 + 4x1 + 1x2 = 10         3: 1x1 + 5x1 + 2x2 = 10
      emmsb = values(swiss(), "EMMSB")
      assert emmsb[1] == 10.0
      assert emmsb[3] == 10.0
    end

    test "EGGSB: game points both ways" do
      # 1: 4.5x3 + 7x2 + 3.5x4 = 41.5
      assert values(swiss(), "EGGSB")[1] == 41.5
    end

    test "EMGSB/C1 cuts the opponent lowest in match points" do
      # 1's opponents: 2 (MP 2), 3 (MP 4), 4 (MP 1) - cut 4's 1x4.
      assert values(swiss(), "EMGSB/C1")[1] == 14.0
    end

    test "TieBreakServer's ESB:MG spelling is EMGSB" do
      # Results are keyed by the canonical spelling.
      {:ok, all} = Tiebreaks.compute(swiss(), ["ESB:MG"])
      assert all["EMGSB"] == values(swiss(), "EMGSB")
    end
  end

  describe "scores and schedule strength (13.4)" do
    test "is the secondary score plus Buchholz over the normalising factor" do
      # highest primary: 3 rounds x 2 = 6; highest secondary in one match:
      # 4 boards x 1 = 4; 6 / 4 = 1.5 -> 1 (towards zero).
      # 1: 9 + 7   2: 4.5 + 10   3: 7 + 8   4: 3.5 + 11
      assert values(swiss(), "SSSC") == %{1 => 16.0, 2 => 14.5, 3 => 15.0, 4 => 14.5}
    end
  end

  describe "ranking" do
    test "the primary score first, then the list" do
      {:ok, rows} = Tiebreaks.rank(swiss(), ~w(EMGSB))
      assert Enum.map(rows, & &1.id) == [1, 3, 2, 4]
    end

    test "a game-point primary ranks by game points" do
      gp_event = %{swiss() | primary: :gp}
      {:ok, rows} = Tiebreaks.rank(gp_event, ~w(BH))
      assert Enum.map(rows, & &1.id) == [1, 3, 2, 4]
    end

    # Reading T5: a list that starts with GPTS makes game points the
    # primary, as TieBreakServer reads it - found by the random-list run
    # (seed 20016, `GPTS SSSC`), where our SSSC was still on match points.
    test "a list led by GPTS makes game points the primary" do
      assert {:ok, %{"MPVGP" => mpvgp, "SSSC" => sssc, "BH" => bh}} =
               Tiebreaks.compute(swiss(), ~w(GPTS MPVGP SSSC BH))

      # MPvGP is now the match points; BH is on game points; SSSC is the
      # match points + BH:GP / (3 x 4 / 2 = 6).
      assert mpvgp == values(swiss(), "MPTS")
      assert bh == values(swiss(), "BH:GP")
      # 1: 5 + 15 / 6 = 7.5
      assert sssc[1] == 7.5

      {:ok, rows} = Tiebreaks.rank(swiss(), ~w(GPTS MPVGP))
      assert Enum.map(rows, & &1.values["MPVGP"]) == [5.0, 4.0, 2.0, 1.0]
    end

    test "a list led by MPTS keeps match points, whatever the event says" do
      gp_event = %{swiss() | primary: :gp}
      {:ok, %{"MPVGP" => mpvgp}} = Tiebreaks.compute(gp_event, ~w(MPTS MPVGP))
      assert mpvgp == values(swiss(), "GPTS")
    end
  end

  # ------------------------------------------------------------------
  # Two teams level in everything but their boards: a double round robin,
  # two boards, both matches drawn.
  #
  #   R1: 1 1-1 2   (1 won board 1, 2 won board 2)
  #   R2: 1 1-1 2   (both boards drawn)
  #
  # MP 2 each, GP 2 each, and direct encounter can separate nothing.
  #   BC  (lower better): 1 = 1x1 + 2x0 + 1x0.5 + 2x0.5 = 2.5
  #                       2 = 1x0 + 2x1 + 1x0.5 + 2x0.5 = 3.5
  #   TBR board 1:        1 = 1.5, 2 = 0.5
  #   BBE (without board 2): the same as board 1
  # ------------------------------------------------------------------
  defp level do
    event(
      %{
        1 => [match(2, [1, 0]), match(2, [0.5, 0.5])],
        2 => [match(1, [0, 1]), match(1, [0.5, 0.5])]
      },
      boards: 2,
      predetermined?: true
    )
  end

  describe "board tie-breaks (Article 12) and EDE (13.3)" do
    test "EDE cannot separate two teams level in both scores" do
      {:ok, rows} = Tiebreaks.rank(level(), ~w(EDE))
      assert Enum.map(rows, & &1.rank) == [1, 1]
    end

    test "EDEBT, EDEBB, EDET and EDEB each go on to the board tie-breaks" do
      for code <- ~w(EDEBT EDEBB EDET EDEB) do
        {:ok, rows} = Tiebreaks.rank(level(), [code])
        assert Enum.map(rows, &{&1.id, &1.rank}) == [{1, 1}, {2, 2}], code
      end
    end

    test "BC ranks lower first" do
      {:ok, rows} = Tiebreaks.rank(level(), ~w(BC))
      assert Enum.map(rows, & &1.id) == [1, 2]
    end

    test "TBR and BBE rank by the top boards" do
      for code <- ~w(TBR BBE) do
        {:ok, rows} = Tiebreaks.rank(level(), [code])
        assert Enum.map(rows, & &1.id) == [1, 2], code
      end
    end

    test "BC leaves teams with different game points alone (12.1)" do
      # Three matches between the same two teams, two boards:
      #   R1 drawn 1-1, R2 won by 1 1½-½, R3 won by 2 2-0
      # MP 3 each, GP 2.5 and 3.5 - level on the primary score, so BC is
      # reached, but "it can only be used when all tied teams have the same
      # number of game points", and they do not.
      e =
        event(
          %{
            1 => [match(2, [1, 0]), match(2, [1, 0.5]), match(2, [0, 0])],
            2 => [match(1, [0, 1]), match(1, [0, 0.5]), match(1, [1, 1])]
          },
          boards: 2,
          predetermined?: true
        )

      {:ok, rows} = Tiebreaks.rank(e, ~w(BC))
      assert Enum.map(rows, & &1.rank) == [1, 1]
    end
  end

  describe "a pairing-allocated bye (Article 12)" do
    test "counts as a win on every board" do
      # 3 teams, 1 board... one round: 1 beats 2, 3 has the bye.
      e =
        event(
          %{
            1 => [match(2, [1])],
            2 => [match(1, [0])],
            3 => [%Match{kind: :pab, mp: 2.0, gp: 1.0}]
          },
          boards: 1
        )

      {:ok, rows} = Tiebreaks.rank(e, ~w(TBR))
      # 1 and 3 are level on MP (2); TBR board 1: both 1 - still level.
      assert Enum.find(rows, &(&1.id == 1)).rank == Enum.find(rows, &(&1.id == 3)).rank
    end

    # Reading Q3: the text names only the pairing-allocated bye; other
    # unplayed matches score their result on every board, as FIDE's
    # TieBreakServer counts them.
    test "a half-point bye is a draw on every board, a full-point bye a win" do
      # One round, two boards: 2 and 3 draw (2 wins board 1), 1 has a
      # half-point bye. MP 1 each. TBR board 1: 2 = 1, 1 = 0.5, 3 = 0.
      e =
        event(
          %{
            1 => [%Match{kind: :half_bye, mp: 1.0, gp: 1.0}],
            2 => [match(3, [1, 0])],
            3 => [match(2, [0, 1])]
          },
          boards: 2
        )

      {:ok, rows} = Tiebreaks.rank(e, ~w(TBR))
      assert Enum.map(rows, & &1.id) == [2, 1, 3]

      # A full-point bye beside a won match 2-0 on boards 1-2: BC 1+2 = 3
      # for both, level.
      f =
        event(
          %{
            1 => [%Match{kind: :full_bye, mp: 2.0, gp: 2.0}],
            2 => [match(3, [1, 1])],
            3 => [match(2, [0, 0])]
          },
          boards: 2
        )

      {:ok, rows} = Tiebreaks.rank(f, ~w(BC))
      assert Enum.find(rows, &(&1.id == 1)).rank == Enum.find(rows, &(&1.id == 2)).rank
    end
  end

  describe "from_trf/2" do
    # Three teams, two boards, one round. Team 1 (players 1, 2 and reserve
    # 3) meets team 2 (4, 5); team 3 (6, 7) has the pairing-allocated bye.
    # Team 1 rests player 1 and fields 2 and 3 - so 2 plays board 1.
    defp team_trf do
      g = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end
      none = %{opponent_rank: nil, colour: "-", result: ""}
      bye = %{opponent_rank: nil, colour: "-", result: "U"}

      players = [
        {1, [none]},
        {2, [g.(4, "w", "1")]},
        {3, [g.(5, "b", "=")]},
        {4, [g.(2, "b", "0")]},
        {5, [g.(3, "w", "=")]},
        {6, [bye]},
        {7, [bye]}
      ]

      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "from_trf", type: "swiss", number_of_rounds: 1},
          players:
            for {rank, games} <- players do
              %{rank: rank, name: "P#{rank}", points: 0.0, games: games}
            end,
          teams: [
            %{name: "One", player_ranks: [1, 2, 3]},
            %{name: "Two", player_ranks: [4, 5]},
            %{name: "Three", player_ranks: [6, 7]}
          ]
        })

      trf = Ainalrami.Trf.parse(text)
      Team.from_trf(trf)
    end

    test "reads the match, its boards in roster order, and the match points" do
      event = team_trf()

      assert event.boards == 2
      one = event.teams[1].rounds[1]

      # Board 1 is player 2 (the first of the roster who played): a win;
      # board 2 player 3: a draw. 1.5 - 0.5, a match win.
      assert one.kind == :played
      assert one.opponent == 2
      assert one.boards == %{1 => 1.0, 2 => 0.5}
      assert one.gp == 1.5
      assert one.mp == 2.0
      assert event.teams[2].rounds[1].mp == 0.0
    end

    test "a team whose players all had the pairing-allocated bye has the team's" do
      three = team_trf().teams[3].rounds[1]

      # Article 12: a bye's boards count as wins.
      assert three.kind == :pab
      assert three.mp == 2.0
      assert three.gp == 2.0
      assert three.boards == %{1 => 1.0, 2 => 1.0}
    end

    test "the working's counted parts add up to every value" do
      event = team_trf()
      codes = ~w(BH:MP BH:GP SB:MP SB:GP EMMSB EMGSB EGMSB EGGSB BH:MP/C1 PS:MP)
      {:ok, values} = Tiebreaks.compute(event, codes)
      {:ok, working} = Tiebreaks.working(event, codes)

      for code <- codes, {id, value} <- values[code] do
        total =
          working[code][id]
          |> Enum.filter(&(&1.kind in [:played, :virtual]))
          |> Enum.map(& &1.value)
          |> Enum.sum()

        assert_in_delta total, value, 1.0e-9, "#{code} team #{id}"
      end
    end

    test "Buchholz is refused when the pairings were fixed in advance (Article 8)" do
      event = %{team_trf() | predetermined?: true}

      assert {:error, _} = Tiebreaks.compute(event, ~w(BH:MP))
      assert {:error, _} = Tiebreaks.rank(event, ~w(MPTS BH:MP))
      assert {:error, _} = Tiebreaks.working(event, ~w(BH:MP))
      assert {:ok, _} = Tiebreaks.compute(event, ~w(SB:MP))
    end

    test "the standings rank from it" do
      {:ok, rows} = Tiebreaks.rank(team_trf(), ~w(MPTS GPTS))

      # One and Three on 2 MP; Three has more game points (2.0 to 1.5).
      assert Enum.map(rows, & &1.id) == [3, 1, 2]
    end
  end

  describe "from_trf/2: TRF26 team records and forfeited matches" do
    # Four teams of two boards, two rounds. Round 1: team 1 beats 2 over the
    # board (1.5-0.5); team 3 wins against 4 by forfeit on both boards.
    # Round 2: 1 and 3 play a 1-1 draw; 2 and 4 both forfeit both boards (a
    # double forfeit). `extra` is appended to the file (362/330 records).
    defp forfeit_trf(extra, round2 \\ :double) do
      g = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end
      none = %{opponent_rank: nil, colour: "-", result: ""}

      # Round 2 modes besides :double and :absent: team Two's players
      # credited for a forfeited match with no opponent (`{:credited, "+"}`
      # is TRF-2026 330 Note 1, `"F"` the older spelling), and :lone - Two
      # credited `+`, Four with one seat present and written `0000 - -`.
      r2 = fn
        :double, _rank, opp, colour -> g.(opp, colour, "-")
        {:credited, code}, rank, _opp, _colour when rank in [3, 4] -> g.(nil, "-", writable(code))
        :lone, rank, _opp, _colour when rank in [3, 4] -> g.(nil, "-", writable("+"))
        :lone, 7, _opp, _colour -> g.(nil, "-", writable("-"))
        _, _rank, _opp, _colour -> none
      end

      players = [
        {1, [g.(3, "w", "1"), g.(5, "w", "1")]},
        {2, [g.(4, "b", "="), g.(6, "b", "0")]},
        {3, [g.(1, "b", "0"), r2.(round2, 3, 7, "w")]},
        {4, [g.(2, "w", "="), r2.(round2, 4, 8, "b")]},
        {5, [g.(7, "w", "+"), g.(1, "b", "0")]},
        {6, [g.(8, "b", "+"), g.(2, "w", "1")]},
        {7, [g.(5, "b", "-"), r2.(round2, 7, 3, "b")]},
        {8, [g.(6, "w", "-"), r2.(round2, 8, 4, "w")]}
      ]

      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "forfeits", type: "swiss", number_of_rounds: 2},
          players:
            for {rank, games} <- players do
              %{rank: rank, name: "P#{rank}", points: 0.0, games: games}
            end,
          teams: [
            %{name: "One", player_ranks: [1, 2]},
            %{name: "Two", player_ranks: [3, 4]},
            %{name: "Three", player_ranks: [5, 6]},
            %{name: "Four", player_ranks: [7, 8]}
          ]
        })
        # The writer refuses `+`/`-` against 0000; the reader takes them.
        |> String.replace("0000 - U", "0000 - +")
        |> String.replace("0000 - Z", "0000 - -")
        |> Kernel.<>(extra)

      Ainalrami.Trf.parse(text)
    end

    defp writable("+"), do: "U"
    defp writable("-"), do: "Z"
    defp writable(code), do: code

    test "Trf.parse reads the 362 match points and the 330 forfeited matches" do
      trf = forfeit_trf("362  W 3.0    D 1.0    L 0.0    P 3.0    A 0.0\r\n330 -- 2   2   4\r\n")

      assert trf.tournament.team_point_system ==
               %{win: 3.0, draw: 1.0, loss: 0.0, pab: 3.0, absent: 0.0}

      assert trf.tournament.forfeited_matches == [%{type: "--", round: 2, white: 2, black: 4}]
    end

    test "the 362 record sets the match points" do
      event = Team.from_trf(forfeit_trf("362  W 3.0    D 1.0    L 0.0\r\n"))

      assert event.match_points == %{win: 3.0, draw: 1.0, loss: 0.0}
      assert event.teams[1].rounds[1].mp == 3.0
      assert event.teams[1].rounds[2].mp == 1.0
      # An option still overrides the file.
      assert Team.from_trf(forfeit_trf("362  W 3.0    D 1.0    L 0.0\r\n"),
               match_points: %{win: 2.0}
             ).teams[1].rounds[1].mp == 2.0
    end

    test "a match forfeited on every board is a forfeited match, not a game" do
      event = Team.from_trf(forfeit_trf(""))

      three = event.teams[3].rounds[1]
      four = event.teams[4].rounds[1]
      assert {three.kind, three.opponent, three.mp, three.gp} == {:forfeit_win, 4, 2.0, 2.0}
      assert {four.kind, four.opponent, four.mp, four.gp} == {:forfeit_loss, 3, 0.0, 0.0}

      # Round 2: both sides forfeited everything - a double forfeit, no
      # match points to either (it used to be read as a drawn match).
      assert event.teams[2].rounds[2].kind == :forfeit_loss
      assert event.teams[4].rounds[2].kind == :forfeit_loss
      assert event.teams[2].rounds[2].mp == 0.0
      assert event.teams[4].rounds[2].mp == 0.0

      # Article 16: the forfeit win is not a game for Buchholz - team 3's
      # opponent in round 1 counts as a virtual opponent.
      {:ok, working} = Tiebreaks.working(event, ~w(BH:MP))
      assert Enum.any?(working["BH:MP"][3], &(&1.round == 1 and &1.kind != :played))
    end

    test "a 330 record forfeits a match neither team has games for" do
      event = Team.from_trf(forfeit_trf("330 +- 2   2   4\r\n", :absent))

      two = event.teams[2].rounds[2]
      four = event.teams[4].rounds[2]
      assert {two.kind, two.opponent, two.mp, two.gp} == {:forfeit_win, 4, 2.0, 2.0}
      assert {four.kind, four.opponent, four.mp} == {:forfeit_loss, 2, 0.0}

      # Without the record the two teams simply had no match.
      plain = Team.from_trf(forfeit_trf("", :absent))
      assert plain.teams[2].rounds[2].kind == :zero_bye
    end

    test "a 330 record outranks the winners' 0000 + (330 Note 1) and the older 0000 F" do
      for round2 <- [{:credited, "+"}, {:credited, "F"}, :lone] do
        trf = forfeit_trf("330 +- 2   2   4\r\n", round2)
        line = trf.players |> Enum.find(&(&1.rank == 3)) |> Map.get(:games) |> Enum.at(1)
        assert line.opponent_rank == nil
        assert line.result == if(round2 == {:credited, "F"}, do: "F", else: "+")

        event = Team.from_trf(trf)
        two = event.teams[2].rounds[2]
        four = event.teams[4].rounds[2]

        assert {two.kind, two.opponent, two.mp, two.gp} == {:forfeit_win, 4, 2.0, 2.0},
               inspect(round2)

        assert {four.kind, four.opponent, four.mp, four.gp} == {:forfeit_loss, 2, 0.0, 0.0},
               inspect(round2)
      end

      # Without the record, `0000 +` is what it says: a pairing-allocated bye.
      assert Team.from_trf(forfeit_trf("", {:credited, "+"})).teams[2].rounds[2].kind == :pab
    end

    test "the reference reads the same files the same way" do
      for {extra, round2} <- [
            {"", :double},
            {"362  W 3.0    D 1.0    L 0.0\r\n", :double},
            {"330 -+ 2   2   4\r\n", :absent},
            {"330 -- 2   2   4\r\n", :absent},
            {"330 +- 2   2   4\r\n", {:credited, "+"}},
            {"330 +- 2   2   4\r\n", {:credited, "F"}},
            {"330 +- 2   2   4\r\n", :lone}
          ] do
        trf = forfeit_trf(extra, round2)

        result =
          Ainalrami.TiebreakReference.Proof.compare_team_trf(
            trf,
            ~w(MPTS GPTS BH:MP BH:GP SB:MP EMGSB WIN:MP KS:MP SSSC),
            [~w(MPTS BC), ~w(MPTS GPTS EDEBT)],
            "hand #{inspect(extra)}"
          )

        assert result.bad == [], Enum.join(result.bad, "\n")
      end
    end
  end
end

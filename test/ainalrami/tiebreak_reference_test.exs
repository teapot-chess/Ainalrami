defmodule Ainalrami.TiebreakReferenceTest do
  @moduledoc """
  C.07 tie-breaks, engine against an independent reference.

  `Ainalrami.TiebreakReference` is a naive second implementation written
  from `docs/c07-regulation-text.md`, sharing no code with
  `lib/ainalrami/tiebreaks*`. Every value of every code, and the final ranks
  under several tie-break lists, must agree. Method, readings and results:
  `docs/tiebreak-reference.md`.

  ## Scale mode

      TIEBREAK_REF_SEEDS="1..5000" mix test test/ainalrami/tiebreak_reference_test.exs --only tiebreak_reference_scale

  prints `TBREF seeds=N events=N values=N disagreements=N`. With
  `TIEBREAK_REF_KIND=team_trf` every seed is a board-level team event (the
  format by `rem(seed, 10)`, see `Ainalrami.TeamTrfGenerator`). A failure
  message starts with the seed (`seed N ...`).
  """
  use ExUnit.Case, async: true

  alias Ainalrami.TiebreakReference, as: Ref
  alias Ainalrami.TiebreakReference.Proof
  alias Ainalrami.Tiebreaks
  alias Ainalrami.Tiebreaks.{Event, Team}
  alias Ainalrami.Tiebreaks.Team.{Entry, Match}

  @swiss_codes ~w(PTS WIN WON BPG BWG PS PS/C1 REP STD TPN BH BH/C1 BH/C2 BH/M1 FB FB/C1
                  AOB AOB/F SB SB/C1 SB/C2 KS KS/L1 KS/L-1 ARO ARO/C1 TPR PTP APRO APPO RTNG)

  defp run(seeds, kind \\ :all) do
    Enum.reduce(seeds, Proof.zero(), fn seed, acc -> Proof.add(acc, Proof.run(seed, kind)) end)
  end

  defp seeds_from_env(default) do
    case System.get_env("TIEBREAK_REF_SEEDS") do
      nil ->
        default

      text ->
        case String.split(text, "..") do
          [a, b] -> String.to_integer(a)..String.to_integer(b)
          [a] -> String.to_integer(a)..String.to_integer(a)
        end
    end
  end

  describe "engine and reference agree on generated events" do
    @tag timeout: :infinity
    test "a few hundred small events: Swiss, round robins, team events" do
      result = run(1..300)

      assert result.bad == [], Enum.join(Enum.take(result.bad, 20), "\n")
      assert result.events == 300
      assert result.values > 100_000
    end

    @tag :tiebreak_reference_scale
    @tag timeout: :infinity
    test "scale mode" do
      seeds = seeds_from_env(1..5000)
      kind = if System.get_env("TIEBREAK_REF_KIND") == "team_trf", do: :team_trf, else: :all
      result = run(seeds, kind)

      IO.puts(
        "TBREF seeds=#{Enum.count(seeds)} events=#{result.events} values=#{result.values} " <>
          "disagreements=#{length(result.bad)}"
      )

      assert result.bad == [], Enum.join(Enum.take(result.bad, 20), "\n")
    end
  end

  # ======================================================================
  # Hand-built events aimed at the points the TieBreakServer comparison
  # set aside as "known" - where our answer rests on our own reading.
  # ======================================================================

  # A crosstable as a parsed TRF: %{id => {rating, [round]}}, a round being
  # {opponent, "w" | "b", result} or a bye code ("U" "F" "H" "Z").
  defp trf(spec, opts \\ []) do
    rounds = spec |> Map.values() |> Enum.map(fn {_, rs} -> length(rs) end) |> Enum.max()

    %{
      tournament:
        Map.merge(
          %{name: "hand-built", number_of_rounds: Keyword.get(opts, :total, rounds)},
          if(opts[:rr], do: %{type_code: "FIDE_ROUNDROBIN"}, else: %{})
        ),
      teams: [],
      players:
        for {id, {rating, rs}} <- Enum.sort(spec) do
          %{
            rank: id,
            fide_rating: rating,
            games:
              Enum.map(rs, fn
                {opp, colour, result} -> %{opponent_rank: opp, colour: colour, result: result}
                bye -> %{opponent_rank: nil, colour: nil, result: bye}
              end)
          }
        end
    }
  end

  # Engine and reference agree on every code and list, and both give `expected`.
  defp both(trf, code, expected, opts \\ []) do
    agree(trf, opts)
    engine = trf |> Event.from_trf(opts) |> Tiebreaks.compute([code]) |> elem(1)
    reference = trf |> Ref.from_trf(opts) |> Ref.values(code)

    for {id, value} <- expected do
      assert_in_delta engine[code][id], value, 1.0e-9, "engine #{code} of #{id}"
      assert_in_delta reference[id], value, 1.0e-9, "reference #{code} of #{id}"
    end
  end

  defp agree(trf, opts \\ []) do
    codes =
      if opts[:rr] || match?(%{type_code: _}, trf.tournament),
        do: @swiss_codes -- ~w(BH BH/C1 BH/C2 BH/M1 FB FB/C1 AOB AOB/F),
        else: @swiss_codes

    result =
      Proof.compare_individual(
        trf,
        Keyword.take(opts, [:rounds]),
        codes,
        [~w(DE), ~w(DE/P SB)],
        "hand"
      )

    assert result.bad == [], Enum.join(result.bad, "\n")
  end

  defp ranks(event_or_team, list) do
    {:ok, rows} = Tiebreaks.rank(event_or_team, list)
    Map.new(rows, &{&1.id, &1.rank})
  end

  test "STD scores against the scheduled opponent (reading 8)" do
    # r1: 1 and 2 double forfeit; r2: 2 takes ½ from 4's 0 (an odd result).
    t =
      trf(%{
        1 => {2000, [{2, "w", "-"}, {3, "w", "="}]},
        2 => {2000, [{1, "b", "-"}, {4, "w", "="}]},
        3 => {2000, [{4, "w", "1"}, {1, "b", "="}]},
        4 => {2000, [{3, "b", "0"}, {2, "b", "0"}]}
      })

    # Against a draw's value (TieBreakServer) 1 and 2 would get 0.5 and 1.0.
    both(t, "STD", %{1 => 1.0, 2 => 1.5, 3 => 1.5, 4 => 0.0})
  end

  # Player 1 (2.5 of 4): a half-point bye (dummy min(2.5, 0.5 x 4) = 2.0,
  # contribution 1.0), a forfeit loss to 2 (dummy min(2.5, 3.0) = 2.5,
  # contribution 0), a win over the lowest scorer 3 (0.5) and one over 6 (1.5).
  defp vur_event do
    trf(%{
      1 => {2100, ["H", {2, "w", "-"}, {3, "w", "1"}, {6, "b", "1"}]},
      2 => {2100, [{3, "w", "1"}, {1, "b", "+"}, {5, "w", "="}, {4, "w", "="}]},
      3 => {2100, [{2, "b", "0"}, {4, "w", "="}, {1, "b", "0"}, {5, "w", "0"}]},
      4 => {2100, [{5, "w", "="}, {3, "b", "="}, {6, "w", "="}, {2, "b", "="}]},
      5 => {2100, [{4, "b", "="}, {6, "w", "1"}, {2, "b", "="}, {3, "b", "1"}]},
      6 => {2100, ["U", {5, "b", "0"}, {4, "b", "="}, {1, "w", "0"}]}
    })
  end

  test "SB/C1 cuts the higher of the lowest VUR contribution and the least significant value (finding B)" do
    # SB = 1.0 + 0 + 0.5 + 1.5 = 3.0. Lowest VUR contribution 0 (round 2);
    # least significant value 0.5 (round 3, the lowest opponent); the
    # higher, 0.5, goes: 2.5. Choosing the VUR by its dummy's score (round
    # 1, dummy 2.0 against round 2's 2.5) would cut 1.0 and give 2.0.
    both(vur_event(), "SB", %{1 => 3.0})
    both(vur_event(), "SB/C1", %{1 => 2.5})
  end

  test "BH/C1 with VURs cuts the lowest VUR contribution (16.5.2)" do
    # 2.0 (half-point bye) + 2.5 (forfeit loss) + 0.5 + 1.5 = 6.5; the
    # lowest VUR contribution, 2.0, goes - not the least value 0.5.
    both(vur_event(), "BH", %{1 => 6.5})
    both(vur_event(), "BH/C1", %{1 => 4.5})
  end

  test "a value does not depend on the codes listed before it (finding A)" do
    event = Event.from_trf(vur_event())
    {:ok, alone} = Tiebreaks.compute(event, ~w(SB BH))
    {:ok, after_fb} = Tiebreaks.compute(event, ~w(FB SB BH))
    assert alone["SB"] == after_fb["SB"]
    assert alone["BH"] == after_fb["BH"]
    assert ranks(event, ~w(FB SB)) == Ref.rank(Ref.from_trf(vur_event()), ~w(FB SB))
  end

  test "direct encounter averages repeated meetings (6.1.2, finding C)" do
    # 1, 2 and 3 finish on 3.5. Among them: 1 drew 3 and beat 2; 2 beat 3
    # twice. Encounter points 1.5, 1 (the average of two wins), 0.5. Summed
    # instead, 2 would lead with 2.
    t =
      trf(%{
        1 =>
          {2000,
           [
             {3, "w", "="},
             {2, "w", "1"},
             {4, "b", "="},
             {5, "w", "="},
             {6, "b", "="},
             {4, "w", "="}
           ]},
        2 =>
          {2000,
           [
             {4, "w", "="},
             {1, "b", "0"},
             {3, "w", "1"},
             {3, "b", "1"},
             {5, "b", "="},
             {6, "w", "="}
           ]},
        3 =>
          {2000,
           [
             {1, "b", "="},
             {4, "w", "1"},
             {2, "b", "0"},
             {2, "w", "0"},
             {4, "b", "1"},
             {5, "w", "1"}
           ]},
        4 =>
          {2000,
           [
             {2, "b", "="},
             {3, "b", "0"},
             {1, "w", "="},
             {6, "w", "="},
             {3, "w", "0"},
             {1, "b", "="}
           ]},
        5 =>
          {2000,
           [
             {6, "w", "="},
             {6, "b", "1"},
             {6, "w", "="},
             {1, "b", "="},
             {2, "w", "="},
             {3, "b", "0"}
           ]},
        6 =>
          {2000,
           [
             {5, "b", "="},
             {5, "w", "0"},
             {5, "b", "="},
             {4, "b", "="},
             {1, "w", "="},
             {2, "b", "="}
           ]}
      })

    agree(t)
    expected = %{1 => 1, 2 => 2, 3 => 3}
    assert Map.take(ranks(Event.from_trf(t), ~w(DE)), [1, 2, 3]) == expected
    assert Map.take(Ref.rank(Ref.from_trf(t), ~w(DE)), [1, 2, 3]) == expected
  end

  test "Koya's maximum in an odd round robin leaves out the free round (reading 10)" do
    # Five players, all games drawn: 2.0 each out of a possible 4 (not 5),
    # so everybody is on the 50% line and counts; L1 moves it to 2.5.
    ids = 1..5
    field = 6

    schedule =
      for r <- 1..5 do
        circle = [
          field | Enum.drop(Enum.to_list(1..5), r - 1) ++ Enum.take(Enum.to_list(1..5), r - 1)
        ]

        for i <- 0..2, do: {Enum.at(circle, i), Enum.at(circle, 5 - i)}
      end

    spec =
      Map.new(ids, fn id ->
        rounds =
          for pairs <- schedule do
            case Enum.find(pairs, fn {a, b} -> a == id or b == id end) do
              {a, b} when a == field or b == field -> "Z"
              {^id, b} -> {b, "w", "="}
              {a, ^id} -> {a, "b", "="}
            end
          end

        {id, {2000, rounds}}
      end)

    t = trf(spec, rr: true)
    both(t, "KS", Map.new(ids, &{&1, 2.0}), rr: true)
    both(t, "KS/L1", Map.new(ids, &{&1, 0.0}), rr: true)
    both(t, "KS/L-1", Map.new(ids, &{&1, 2.0}), rr: true)
  end

  test "a forfeit win is not a game won over the board, even in a round robin (reading 9)" do
    t =
      trf(
        %{
          1 => {2000, [{2, "w", "+"}, {3, "b", "1"}, {4, "w", "="}]},
          2 => {2000, [{1, "b", "-"}, {4, "w", "1"}, {3, "b", "="}]},
          3 => {2000, [{4, "w", "0"}, {1, "w", "0"}, {2, "w", "="}]},
          4 => {2000, [{3, "b", "1"}, {2, "b", "0"}, {1, "b", "="}]}
        },
        rr: true
      )

    both(t, "WON", %{1 => 1, 2 => 1}, rr: true)
    both(t, "WIN", %{1 => 2, 2 => 1}, rr: true)
    both(t, "REP", %{1 => 3, 2 => 2}, rr: true)
    # 15.2: in a round robin the forfeit is a game for SB - 2's 1.5 x 1.
    both(t, "SB", %{1 => 1.5 * 1 + 0.5 * 1 + 1.5 * 0.5}, rr: true)
  end

  # Player 1 has a pairing-allocated bye and wins everything else (4.0);
  # player 5 ends with a zero-point bye in the last round (16.2.5).
  defp cap_event do
    trf(%{
      1 => {2000, ["U", {2, "w", "1"}, {4, "b", "1"}, {3, "w", "1"}]},
      2 => {2000, [{3, "w", "1"}, {1, "b", "0"}, {5, "w", "1"}, {4, "b", "="}]},
      3 => {2000, [{2, "b", "0"}, {4, "w", "="}, "U", {1, "b", "0"}]},
      4 => {2000, [{5, "w", "1"}, {3, "b", "="}, {1, "w", "0"}, {2, "w", "="}]},
      5 => {2000, [{4, "b", "0"}, "U", {2, "b", "0"}, "Z"]}
    })
  end

  test "16.4.2 caps the dummy at a draw per round; 16.3.2 counts a trailing bye as a draw" do
    # 1: dummy min(4.0, 0.5 x 4) = 2.0, then 2.5 + 2.0 + 1.5 = 8.0.
    # 2: 1.5 + 4.0 + 5's adjusted 1.5 (its round-4 bye as a draw) + 2.0.
    both(cap_event(), "BH", %{1 => 8.0, 2 => 9.0})
  end

  test "part-way standings: the cap counts the rounds played, FB is BH (readings 11, 8.3)" do
    # After round 2 of 4: 1 has 2.0; the dummy is min(2.0, 0.5 x 2) = 1.0,
    # and 2 has 1.0 - so BH 2.0 (the announced-rounds cap would give 3.0).
    both(cap_event(), "BH", %{1 => 2.0}, rounds: 2)
    both(cap_event(), "FB", %{1 => 2.0}, rounds: 2)
  end

  test "a requested bye followed only by VURs is a draw to the opponents; followed by a forfeit win it is not (16.2)" do
    # 2: zero-point bye, then a forfeit loss - 16.2.5, adjusted 0.5.
    # 4: zero-point bye, then a forfeit WIN (not a VUR) - 16.2.3, adjusted 1.0.
    t =
      trf(%{
        1 => {2000, [{2, "w", "1"}, {6, "b", "="}, {3, "w", "="}]},
        2 => {2000, [{1, "b", "0"}, "Z", {5, "w", "-"}]},
        3 => {2000, [{4, "w", "1"}, {5, "w", "1"}, {1, "b", "="}]},
        4 => {2000, [{3, "b", "0"}, "Z", {6, "b", "+"}]},
        5 => {2000, [{6, "w", "="}, {3, "b", "0"}, {2, "b", "+"}]},
        6 => {2000, [{5, "b", "="}, {1, "w", "="}, {4, "w", "-"}]}
      })

    both(t, "BH", %{1 => 0.5 + 1.0 + 2.5, 3 => 1.0 + 1.5 + 2.0})
  end

  # Four teams of four boards, two rounds. 1 and 2 never meet and finish
  # level on 3 MP and 4.5 GP, with different boards.
  defp board_team do
    m = fn opp, mp, boards ->
      %Match{
        kind: :played,
        opponent: opp,
        mp: mp,
        gp: boards |> Enum.sum(),
        boards: boards |> Enum.with_index(1) |> Map.new(fn {g, b} -> {b, g} end)
      }
    end

    Team.new(
      [
        %Entry{
          id: 1,
          tpn: 1,
          rounds: %{1 => m.(3, 2.0, [1, 1, 0, 0.5]), 2 => m.(4, 1.0, [0.5, 0.5, 0.5, 0.5])}
        },
        %Entry{
          id: 2,
          tpn: 2,
          rounds: %{1 => m.(4, 2.0, [0, 0.5, 1, 1]), 2 => m.(3, 1.0, [0.5, 0.5, 0.5, 0.5])}
        },
        %Entry{
          id: 3,
          tpn: 3,
          rounds: %{1 => m.(1, 0.0, [0, 0, 1, 0.5]), 2 => m.(2, 1.0, [0.5, 0.5, 0.5, 0.5])}
        },
        %Entry{
          id: 4,
          tpn: 4,
          rounds: %{1 => m.(2, 0.0, [1, 0.5, 0, 0]), 2 => m.(1, 1.0, [0.5, 0.5, 0.5, 0.5])}
        }
      ],
      2,
      boards: 4
    )
  end

  test "EDEBT: two level teams that never met are separated by Board Count over the tournament, lower first (finding D, reading T4)" do
    t = board_team()
    # BC: 1 has 5 + 5 = 10, 2 has 8 + 5 = 13; 4 has 7, 3 has 10.
    expected = %{1 => 1, 2 => 2, 4 => 3, 3 => 4}

    for list <- [~w(MPTS GPTS EDEBT), ~w(MPTS GPTS EDEBB), ~w(MPTS BC)] do
      assert ranks(t, list) == expected, inspect(list)
      assert Ref.rank(Ref.from_team(t), list) == expected, inspect(list)
    end

    result =
      Proof.compare_team(
        t,
        ~w(MPTS GPTS SB:MP EMGSB BH:GP),
        [~w(MPTS EDET), ~w(GPTS EDEB)],
        "board team"
      )

    assert result.bad == []
  end

  test "EDE between exactly two teams tied after a drawn match goes to the knockout tie-breaks" do
    # 1 and 2 drew 2-2 and are level; the match cannot separate them in
    # either score, so EDET falls to the top board (1 took board 1) and EDEB
    # to boards 1-3 (level), 1-2 (level), then board 1.
    m = fn opp, mp, boards ->
      %Match{
        kind: :played,
        opponent: opp,
        mp: mp,
        gp: Enum.sum(boards),
        boards: boards |> Enum.with_index(1) |> Map.new(fn {g, b} -> {b, g} end)
      }
    end

    t =
      Team.new(
        [
          %Entry{id: 1, rounds: %{1 => m.(2, 1.0, [1, 0, 0.5, 0.5])}},
          %Entry{id: 2, rounds: %{1 => m.(1, 1.0, [0, 1, 0.5, 0.5])}}
        ],
        1,
        boards: 4
      )

    for {list, expected} <- [
          {~w(MPTS GPTS EDET), %{1 => 1, 2 => 2}},
          {~w(MPTS GPTS EDEB), %{1 => 1, 2 => 2}},
          {~w(MPTS GPTS EDE), %{1 => 1, 2 => 1}}
        ] do
      assert ranks(t, list) == expected, inspect(list)
      assert Ref.rank(Ref.from_team(t), list) == expected, inspect(list)
    end
  end

  # Four teams of three boards, two rounds. Round 1: One and Two forfeit
  # crosswise - One scores boards 1 and 2 by forfeit, Two board 3 - with no
  # game played; Three beats Four 2-1 over the board. Round 2: One and Three
  # draw 1.5-1.5, Two beats Four 2-1.
  defp crosswise_forfeit_trf do
    g = fn opp, colour, result -> %{opponent_rank: opp, colour: colour, result: result} end

    players = [
      {1, [g.(4, "w", "+"), g.(7, "w", "=")]},
      {2, [g.(5, "b", "+"), g.(8, "b", "=")]},
      {3, [g.(6, "w", "-"), g.(9, "w", "=")]},
      {4, [g.(1, "b", "-"), g.(10, "w", "1")]},
      {5, [g.(2, "w", "-"), g.(11, "b", "1")]},
      {6, [g.(3, "b", "+"), g.(12, "w", "0")]},
      {7, [g.(10, "w", "1"), g.(1, "b", "=")]},
      {8, [g.(11, "b", "1"), g.(2, "w", "=")]},
      {9, [g.(12, "w", "0"), g.(3, "b", "=")]},
      {10, [g.(7, "b", "0"), g.(4, "b", "0")]},
      {11, [g.(8, "w", "0"), g.(5, "w", "0")]},
      {12, [g.(9, "b", "1"), g.(6, "b", "1")]}
    ]

    Ainalrami.Trf.serialize(%{
      tournament: %{name: "crosswise forfeits", type: "swiss", number_of_rounds: 2},
      players:
        for(
          {rank, games} <- players,
          do: %{rank: rank, name: "P#{rank}", points: 0.0, games: games}
        ),
      teams: [
        %{name: "One", player_ranks: [1, 2, 3]},
        %{name: "Two", player_ranks: [4, 5, 6]},
        %{name: "Three", player_ranks: [7, 8, 9]},
        %{name: "Four", player_ranks: [10, 11, 12]}
      ]
    })
    |> Ainalrami.Trf.parse()
  end

  test "a match forfeited crosswise, 2-1 with no game played, is a played match for both (seed 1042637)" do
    # Both teams turned up, so round 1 is a played match One won on game
    # points (reading C of 2026-11-11, T8), and Article 16 has nothing to
    # adjust: One's BH:MP is Two's 2 + Three's 3 = 5, Two's is One's 3 +
    # Four's 0 = 3. The reference used to call it a forfeit win and loss -
    # a dummy on the team's own score, 6 and 2 - and seed 1042637 of the
    # scale run tripped over exactly that (team 13, BH:MP 39 against 37).
    trf = crosswise_forfeit_trf()
    event = Team.from_trf(trf)
    assert event.teams[1].rounds[1].kind == :played
    assert event.teams[2].rounds[1].kind == :played

    {:ok, engine} = Tiebreaks.compute(event, ~w(MPTS BH:MP REP))
    reference = Ref.from_team_trf(trf, [])

    for {code, expected} <- [
          {"MPTS", %{1 => 3.0, 2 => 2.0, 3 => 3.0, 4 => 0.0}},
          {"BH:MP", %{1 => 5.0, 2 => 3.0}},
          {"REP", %{1 => 2, 2 => 2}}
        ],
        {id, value} <- expected do
      assert engine[code][id] == value, "engine #{code} of #{id}"
      assert Ref.values(reference, code)[id] == value, "reference #{code} of #{id}"
    end

    result =
      Proof.compare_team_trf(
        trf,
        ~w(MPTS GPTS BH:MP BH:GP BH:MP/C1 FB:MP AOB:MP SB:MP SB:GP EMGSB EGGSB WIN:MP WON:GP REP SSSC),
        [~w(MPTS GPTS EDE BH:MP EMGSB), ~w(MPTS BC TBR BBE)],
        "crosswise"
      )

    assert result.bad == [], Enum.join(result.bad, "\n")
    assert Proof.team_trf(1_042_637).bad == []
  end

  test "team events built match by match, with rematches and every unplayed round" do
    # The first five match-by-match events with both a rematch and a
    # forfeited match.
    seeds =
      8..3000//10
      |> Stream.filter(fn seed ->
        matches =
          for {id, team} <- Proof.direct_team(seed).teams, {_r, m} <- team.rounds, do: {id, m}

        forfeit? = Enum.any?(matches, fn {_, m} -> m.kind == :forfeit_loss end)

        rematch? =
          matches
          |> Enum.filter(fn {_, m} -> m.kind == :played end)
          |> Enum.frequencies_by(fn {id, m} -> {id, m.opponent} end)
          |> Enum.any?(fn {_, n} -> n > 1 end)

        forfeit? and rematch?
      end)
      |> Enum.take(5)

    assert length(seeds) == 5

    for seed <- seeds, do: assert(Proof.team_direct(seed).bad == [], "seed #{seed}")
  end
end

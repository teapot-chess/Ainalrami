defmodule Ainalrami.TeamPairingValidationTest do
  @moduledoc """
  C.04.6 validation beyond the single bracket: whole rounds against a
  brute-force reading of the text, the absolute criteria on large fields, and
  hand-worked positions for each criterion of Article 3.5.

  ## The reference is written from the regulation, not from the engine

  `ref_round/2` below is a second implementation of Articles 3.4-3.6 and 4,
  deliberately naive: it enumerates EVERY subset of the lower teams as an
  upfloater set and EVERY pairing of a bracket, decides pairability by
  trying every partner, and ranks by the criteria in 2.3's priority order.
  It shares no code with `Ainalrami.TeamPairing` beyond the `%Team{}`
  struct. Where the two agree on hundreds of reachable rounds, what is left
  to argue about is the reading - which the reference states in the open -
  not the search.

  Its readings, identical to the engine's by design (each is isolated there
  in a named function):

    * [C4] then [C5] are judged over LEGAL sets (bracket pairable and the
      rest pairable - [C1] and [C3]);
    * [C5] maximises the upfloaters' scores taken in ascending order
      (open question 5 - the article, not the 3.5.4 example);
    * [C6] minimises how many more upfloaters than the parity minimum the
      following scoregroup's bracket would need;
    * [C7] minimises the upfloaters that floated last round, before 3.5.4's
      order (open question 7);
    * 3.6: least {C8, C10}, then the smallest identifier. Type A, and
      1.7's "not to be used at all" (`type: :none`: nobody has a
      preference, so [C8] is zero and Article 4 runs without its preference
      rules); Type B's [C9] is proven at bracket level in
      `team_pairing_test.exs`.

  ## Histories are reachable

  Random `%Team{}` structs can describe tournaments no event produces (a
  team on 4 match points after one round). So every history here is PLAYED:
  a field starts empty and each round is paired by the engine and then given
  random results - including matches forfeited as a whole, pairing-allocated
  byes, and teams sitting a round out - and the next round is paired from
  that. Every round along the way is checked.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamPairing.{Bracket, Team}

  import Ainalrami.TeamProof.Events
  import Ainalrami.TeamProof.NaiveReference, only: [ref_round: 2, ref_numbers: 2, ref_colours: 4]

  # ==================================================================
  # Whole rounds against the brute-force reference
  # ==================================================================

  describe "whole rounds against the brute-force reference (4-10 teams)" do
    # The same test is the long validation run. `tools/team_validation_run.exs`
    # starts many copies of it, each on its own seed range through
    # TEAM_VALIDATION_SEEDS ("first..last"); without the variable it is the
    # ordinary 90-seed test. In a run the per-round statistics are not kept -
    # a mailbox of millions of them would cost gigabytes - and the coverage
    # guards below, which were written for the 90 seeds, are skipped: the run
    # reports its count instead.
    @tag :whole_rounds
    @tag timeout: :infinity
    test "every round of every generated event matches the reference" do
      {seeds, run?} = validation_seeds("TEAM_VALIDATION_SEEDS", 1..90)
      checked = whole_rounds(seeds, run?, :a)

      if run? do
        IO.puts("TEAMRUN seeds=#{Enum.count(seeds)} rounds=#{checked}")
      else
        whole_round_coverage(checked)
      end
    end

    # 1.7's third option, "colour preferences are not to be used at all"
    # (TRF26's FIDE_TEAM_MP_GP and the other codes without TYPEA/TYPEB):
    # the same events and the same reference, with no team ever holding a
    # preference. TEAM_VALIDATION_NONE_SEEDS runs a longer range.
    @tag :whole_rounds
    @tag timeout: :infinity
    test "with no colour preferences, every round matches the reference" do
      {seeds, run?} = validation_seeds("TEAM_VALIDATION_NONE_SEEDS", 1..120)
      checked = whole_rounds(seeds, run?, :none)

      if run? do
        IO.puts("TEAMRUN none seeds=#{Enum.count(seeds)} rounds=#{checked}")
      else
        assert checked > 300
        seen = collect_reasons(%{})
        _ = collect_stats([])

        # Colours by the rules that do not mention a preference, and never by
        # one that does.
        for reason <- ~w(4.3.1 4.3.5 4.3.6 4.3.8 C4 C5 3.4.2 3.4.4) do
          assert Map.get(seen, reason, 0) > 0, "no generated round was decided by #{reason}"
        end

        for reason <- ~w(4.3.2 4.3.3 4.3.4 4.3.7) do
          assert Map.get(seen, reason, 0) == 0, "#{reason} decided a round with no preferences"
        end
      end
    end
  end

  defp whole_rounds(seeds, run?, type) do
    for seed <- seeds, reduce: 0 do
      acc ->
        :rand.seed(:exsss, {seed, 2 * seed + 1, 7 * seed + 3})
        size = Enum.random(4..10)
        rounds = Enum.random(3..6)
        initial = Enum.random([:white, :black])

        acc +
          play_event(size, rounds, initial, fn round_no, field, absent, opts ->
            opts = if type == :a, do: opts, else: [type: type] ++ opts
            reference = ref_round(field, absent: absent, initial: initial, opts: opts)

            where =
              "seed #{seed} (type #{type}), round #{round_no}, #{length(field)} teams, " <>
                "absent #{inspect(absent)}"

            case TeamPairing.pair_round(field, opts) do
              {:ok, engine} ->
                run? ||
                  send(
                    self(),
                    {:stat,
                     %{
                       upfloaters?: Enum.any?(engine.brackets, &(&1.upfloaters != [])),
                       bye?: engine.bye != nil,
                       absent?: absent != []
                     }}
                  )

                assert normalise(engine) == Map.take(reference, [:bye, :pairs]),
                       """
                       #{where}
                         engine:    #{inspect(normalise(engine))}
                         reference: #{inspect(reference)}
                         field:     #{inspect(Enum.map(field, &describe_team/1))}
                       """

                # Recording the reasons changes nothing, and the reasons
                # recorded are the reference's.
                assert {:ok, explained} =
                         TeamPairing.pair_round(field, [explain: true] ++ opts)

                assert Map.delete(explained, :explanation) == engine,
                       "#{where}: explain changed the round"

                run? ||
                  send(
                    self(),
                    {:reasons,
                     Enum.map(reference.reasons.brackets, & &1.decided_by) ++
                       Enum.map(reference.reasons.rules, &elem(&1, 3)) ++
                       Enum.map(reference.reasons.rules, &elem(&1, 2)) ++
                       List.wrap(reference.reasons.bye && reference.reasons.bye.decided_by) ++
                       if(reference.reasons.bye && reference.reasons.bye.passed_over != [],
                         do: ["3.4.1"],
                         else: []
                       )}
                  )

                assert reasons(explained.explanation) == reference.reasons,
                       """
                       #{where}: the recorded reasons are not the reference's
                         engine:    #{inspect(reasons(explained.explanation))}
                         reference: #{inspect(reference.reasons)}
                         field:     #{inspect(Enum.map(field, &describe_team/1))}
                       """

                engine

              # 3.3.3 - small fields run out of legal pairings (every
              # eligible team has had its bye, or everyone has met). The
              # engine may say so only when the definition agrees, and
              # the event ends there.
              {:error, reason} ->
                assert reference == :impossible,
                       "#{where}: engine refused (#{inspect(reason)}) but the reference paired #{inspect(reference)}"

                :stop
            end
          end)
    end
  end

  defp validation_seeds(variable, default) do
    case System.get_env(variable) do
      nil ->
        {default, false}

      range ->
        [first, last] = range |> String.split("..") |> Enum.map(&String.to_integer/1)
        {first..last, true}
    end
  end

  defp whole_round_coverage(checked) do
    # A guard against the generator quietly producing nothing to check.
    assert checked > 250

    # And against it producing only the easy shapes. Measured when written
    # (seeds 1..90): 371 rounds, 259 with an upfloater bracket, 192 with a
    # bye, 105 with a team sitting out.
    stats = collect_stats([])
    assert Enum.count(stats, & &1.upfloaters?) > 150
    assert Enum.count(stats, & &1.bye?) > 100
    assert Enum.count(stats, & &1.absent?) > 50

    # And the recorded reasons it compared cover more than the easy ones.
    # Measured when written: C4 550, C5 95, C7 10, C6 2, 3.5.4 117; bye
    # 3.4.1 12, 3.4.2 79, 3.4.3 8, 3.4.4 92; 4.2.1-4.2.3 498/202/400;
    # 4.3.1 281, 4.3.2 195, 4.3.3 18, 4.3.5 346, 4.3.6 59, 4.3.8 199, 4.3.9
    # 2. 4.3.4 is Type B, which the reference does not play; 4.3.7 and the
    # rest are pinned by hand in `team_pairing_test.exs`.
    seen = collect_reasons(%{})

    for reason <-
          ~w(C4 C5 C6 C7 3.5.4 3.4.1 3.4.2 3.4.3 3.4.4 4.2.1 4.2.2 4.2.3) ++
            ~w(4.3.1 4.3.2 4.3.3 4.3.5 4.3.6 4.3.8) do
      assert Map.get(seen, reason, 0) > 0, "no generated round was decided by #{reason}"
    end
  end

  # ==================================================================
  # Absolute criteria on large fields
  # ==================================================================

  describe "absolute criteria always hold (up to 60 teams)" do
    @tag timeout: 300_000
    test "[C1], [C2], [C3] and Article 4's colours, every round" do
      for {seed, size} <- [{101, 12}, {102, 17}, {103, 24}, {104, 31}, {105, 40}, {106, 60}] do
        :rand.seed(:exsss, {seed, seed + 5, seed * 3})
        rounds = if size > 40, do: 7, else: 9
        initial = Enum.random([:white, :black])

        paired =
          play_event(size, rounds, initial, fn round_no, field, absent, opts ->
            assert {:ok, round} = TeamPairing.pair_round(field, opts),
                   "seed #{seed}, #{size} teams, round #{round_no}: no pairing"

            assert_absolute(round, field, "seed #{seed}, #{size} teams, round #{round_no}")
            assert_colours(round, field, absent, initial)

            # The same round explained: identical, and its record bounded.
            assert {:ok, explained} = TeamPairing.pair_round(field, [explain: true] ++ opts)

            assert Map.delete(explained, :explanation) == round,
                   "seed #{seed}, #{size} teams, round #{round_no}: explain changed the round"

            assert_bounded(explained.explanation, round)
            round
          end)

        assert paired == rounds
      end
    end
  end

  # ==================================================================
  # Hand-worked positions
  # ==================================================================

  describe "hand-worked positions from the text" do
    test "3.6.3 - with no history the smallest identifier is paired" do
      # The TPNs of 3.6.2's example. Tops 4 6 8 9, bottoms 10 11 16 24 in
      # order: identifier 4 6 8 9 10 11 16 24 is the smallest there is.
      teams = for tpn <- [4, 6, 8, 9, 10, 11, 16, 24], do: team(tpn)

      {:ok, result} = Bracket.pair(teams)
      assert result.pairs == [{4, 10}, {6, 11}, {8, 16}, {9, 24}]
    end

    test "3.6.3 - a rematch moves to the next identifier, not to any legal one" do
      # 4 has met 10. The next identifier in order keeps the tops and swaps
      # the first two bottoms: 4 6 8 9 11 10 16 24.
      teams =
        for tpn <- [4, 6, 8, 9, 10, 11, 16, 24] do
          case tpn do
            4 -> team(4, opponents: [10])
            10 -> team(10, opponents: [4])
            n -> team(n)
          end
        end

      {:ok, result} = Bracket.pair(teams)
      assert result.pairs == [{4, 11}, {6, 10}, {8, 16}, {9, 24}]
    end

    test "[C10] counts upfloaters' opponents per team, so two upfloaters meeting count twice" do
      # Upfloaters 1 and 2 and residents 3 and 4 all floated last round.
      # Every pairing puts two floated teams opposite an upfloater: 1-3 2-4
      # and 1-4 2-3 count 3 and 4, and 1-2 3-4 counts 1 and 2. All tie at
      # two, so 3.6.3 takes the smallest identifier, 1 2 3 4. Counting once
      # per PAIR made 1-2 3-4 a one and picked it.
      teams = for tpn <- 1..4, do: team(tpn, floated_last_round?: true)

      {:ok, result} = Bracket.pair(teams, upfloater_tpns: [1, 2])
      assert result.pairs == [{1, 3}, {2, 4}]
      assert result.scores == {0, 0, 2}
    end

    test "[C4] - an even scoregroup whose residents have met takes two upfloaters" do
      residents = [team(1, mp: 2.0, opponents: [2]), team(2, mp: 2.0, opponents: [1])]
      lower = [team(3, mp: 1.0), team(4, mp: 1.0)]

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [3, 4]
    end

    test "[C3] - a bracket that pairs but strands the teams below it is not taken" do
      # 1 and 2 could pair each other, but 3 has met 4, 5 and 6, so the four
      # lower teams cannot be paired among themselves. 3 must float up.
      residents = [team(1, mp: 2.0), team(2, mp: 2.0)]

      lower = [
        team(3, mp: 1.0, opponents: [4, 5, 6]),
        team(4, mp: 1.0, opponents: [3]),
        team(5, mp: 1.0, opponents: [3]),
        team(6, mp: 1.0, opponents: [3])
      ]

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [3, 4]
    end

    test "[C4] outranks [C5]: a lower-scoring single upfloater beats three" do
      # Residents 1, 2, 3 on 3 points. The only 2-pointer, 4, has met all of
      # them, so no bracket with it as the one upfloater pairs. [C4] (the
      # count) is above [C5] (the scores), so one 1-pointer is taken rather
      # than growing the set to keep a 2-pointer in it.
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0, opponents: [1, 2, 3]),
        team(5, mp: 1.0),
        team(6, mp: 1.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      residents = Enum.map(residents, &%{&1 | opponents: [4]})

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [5]
    end

    test "[C6] - the set that leaves the following scoregroup pairable wins over 3.5.4's first" do
      # One upfloater from the 2-point group {4, 5, 6}. 3.5.4 alone would take
      # 4, but 5 and 6 have met, so 4 floating leaves a following scoregroup
      # that needs two upfloaters of its own. 5 floating leaves {4, 6}, which
      # pairs as it is.
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0, opponents: [6]),
        team(6, mp: 2.0, opponents: [5]),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [5]
    end

    test "[C6] - switched off when the following scoregroup is emptied" do
      # The 3.5.4 example's shape: residents who have all met need three
      # upfloaters, and all three 2-pointers go, so there is no following
      # scoregroup left to protect.
      residents = [
        team(1, mp: 3.0, opponents: [2, 3]),
        team(2, mp: 3.0, opponents: [1, 3]),
        team(3, mp: 3.0, opponents: [1, 2])
      ]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0),
        team(6, mp: 2.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0),
        team(9, mp: 1.0),
        team(10, mp: 1.0),
        team(11, mp: 1.0),
        team(12, mp: 1.0)
      ]

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [4, 5, 6]
    end

    test "[C7] - a team that floated last round is not floated again when another can be" do
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0, floated_last_round?: true),
        team(5, mp: 2.0),
        team(6, mp: 2.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      assert {:ok, [%Team{tpn: 5}]} =
               TeamPairing.select_upfloaters(residents, lower, :match_points, [])

      # "With the exception of the last two rounds" - then 3.5.4 decides.
      assert {:ok, [%Team{tpn: 4}]} =
               TeamPairing.select_upfloaters(residents, lower, :match_points,
                 last_two_rounds?: true
               )
    end

    test "[C6] outranks [C7]" do
      # 5 and 6 floated last round, 4 did not. But 4 floating would strand 5
      # and 6, who have met. [C6] is above [C7], so one of them floats again,
      # and 3.5.4's order makes it 5.
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0, opponents: [6], floated_last_round?: true),
        team(6, mp: 2.0, opponents: [5], floated_last_round?: true),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      assert {:ok, [%Team{tpn: 5}]} =
               TeamPairing.select_upfloaters(residents, lower, :match_points)
    end

    test "an odd field handed to the selection is refused, not guessed at" do
      assert {:error, :odd_field} =
               TeamPairing.select_upfloaters(
                 [team(1, mp: 1.0)],
                 [team(2), team(3)],
                 :match_points
               )
    end

    test "3.4 - the bye goes to the lowest score, then most matches, then largest TPN, [C2] first" do
      teams = [
        team(1, mp: 2.0, colours: [:white], opponents: [2]),
        team(2, mp: 0.0, colours: [:black], opponents: [1]),
        team(3, mp: 1.0, had_pab?: true),
        team(4, mp: 0.0, won_by_forfeit?: false),
        team(5, mp: 0.0, won_by_forfeit?: true)
      ]

      # 2 and 4 are on the lowest eligible score (5 won a match by forfeit,
      # [C2]); 2 has played more matches (3.4.3).
      {:ok, round} = TeamPairing.pair_round(teams, round: 2, expected_rounds: 5)
      assert round.bye == 2
    end
  end

  # ==================================================================
  # No colour preferences (1.7's third option)
  # ==================================================================

  describe "no colour preferences (type: :none)" do
    # 1 and 3 had White twice, 2 and 4 Black twice: under Type A 1 and 3
    # want Black and 2 and 4 White, so the first identifier (1-3 2-4)
    # refuses two preferences and [C8] moves the bracket on to 1-4 2-3.
    # With no preferences nothing is refused and 3.6.3's first identifier
    # stands; the colours then come from 4.3.8 (alternate the first-team's
    # last colour), since the colour differences are equal and the two
    # histories never split.
    defp preference_clash_field do
      [
        team(1, colours: [:white, :white]),
        team(2, colours: [:black, :black]),
        team(3, colours: [:white, :white]),
        team(4, colours: [:black, :black])
      ]
    end

    test "nobody has a preference, whatever the colour history" do
      for t <- preference_clash_field(), type <- [:a, :b] do
        assert Team.preference(t, type) != :none
        assert Team.preference(t, :none) == :none
        assert Team.preference(t, :none, true) == :none
      end
    end

    test "[C8] counts nothing, so 3.6.3's first identifier is paired" do
      field = preference_clash_field()
      opts = [round: 3, expected_rounds: 9, explain: true]

      assert {:ok, a} = TeamPairing.pair_round(field, opts)
      assert normalise(a).pairs == [{2, 3}, {4, 1}]

      assert {:ok, none} = TeamPairing.pair_round(field, [type: :none] ++ opts)
      assert normalise(none).pairs == [{2, 4}, {3, 1}]
      assert [%{criteria: {0, 0, 0}}] = none.brackets
      assert Enum.all?(none.explanation.pairs, &(&1.colour_rule == "4.3.8"))
    end

    test "Article 4 without preferences: 4.3.5, then 4.3.6, then 4.3.8/4.3.9" do
      numbers = %{1 => 1, 2 => 2}

      # CD +2 against 0: under Type A 1 wants Black and 4.3.2 grants it;
      # with no preferences 4.3.5 gives White to the lower CD - the same
      # colours by another rule.
      one = team(1, colours: [:white, :white])
      two = team(2, colours: [:white, :black])

      assert {2, 1, %{colour_rule: "4.3.2"}} =
               engine_colours(one, two, numbers, :a)

      assert {2, 1, %{colour_rule: "4.3.5"}} =
               engine_colours(one, two, numbers, :none)

      # Equal CDs, histories that split last round: 4.3.6 alternates it.
      one = team(1, colours: [:black, :white])
      two = team(2, colours: [:white, :black])
      assert {2, 1, %{colour_rule: "4.3.6"}} = engine_colours(one, two, numbers, :none)

      # Only the other team has played, to a CD of zero: 4.3.9.
      one = team(1)
      two = team(2, colours: [:white, :black])
      assert {2, 1, %{colour_rule: "4.3.9"}} = engine_colours(one, two, numbers, :none)
    end

    test "any other :type is refused rather than read as Type A" do
      for bad <- [:c, nil, "none", :typea] do
        assert {:error, {:invalid_option, :type, ^bad}} =
                 TeamPairing.pair_round([team(1), team(2)], type: bad)
      end
    end
  end

  defp engine_colours(a, b, numbers, type) do
    {white, black, rules} =
      Ainalrami.TeamPairing.Colour.allocate_explained(a, b,
        parity_numbers: numbers,
        type: type
      )

    {white.tpn, black.tpn, rules}
  end

  # ==================================================================
  # The recorded reasons, on the same hand-worked positions
  # ==================================================================

  describe "the reasons recorded with explain: true, on the hand-worked positions" do
    # The first bracket's selection account when `residents ++ lower` is
    # paired as a whole round. Every position here is an even field whose
    # residents are its top scoregroup, so the first bracket is exactly the
    # `select_upfloaters/4` call the position above makes.
    defp first_selection(residents, lower, opts \\ []) do
      assert {:ok, round} = TeamPairing.pair_round(residents ++ lower, [explain: true] ++ opts)
      assert {:ok, plain} = TeamPairing.pair_round(residents ++ lower, opts)
      assert Map.delete(round, :explanation) == plain
      hd(round.explanation.brackets).selection
    end

    defp set(ups, c5, c6, c7), do: %{upfloaters: ups, c4: length(ups), c5: c5, c6: c6, c7: c7}

    test "[C6] - 4 lost on [C6]; 5 beat 6, equal on everything, on 3.5.4's order" do
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0, opponents: [6]),
        team(6, mp: 2.0, opponents: [5]),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)

      assert s.chosen == set([5], [2.0], 0, 0)
      assert s.runner_up == set([6], [2.0], 0, 0)
      assert s.decided_by == "3.5.4"
      assert s.considered == [set([4], [2.0], 1, 0), set([5], [2.0], 0, 0), set([6], [2.0], 0, 0)]
      assert s.rejected == [] and s.sizes_without_legal_set == [] and s.c4 == 1
    end

    test "[C6] outranks [C7]: the position as worked above, and with the tie removed" do
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0),
        team(5, mp: 2.0, opponents: [6], floated_last_round?: true),
        team(6, mp: 2.0, opponents: [5], floated_last_round?: true),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)
      assert s.considered == [set([4], [2.0], 1, 0), set([5], [2.0], 0, 1), set([6], [2.0], 0, 1)]
      assert {s.chosen.upfloaters, s.runner_up.upfloaters, s.decided_by} == {[5], [6], "3.5.4"}

      # 4 has met 5 and 6 too, so only 6 floating leaves a pairable 4-5.
      # 6 floated last round and 4 did not: 6 is worse on [C7] and better on
      # [C6], and [C6] is the one that decides.
      lower = [
        team(4, mp: 2.0, opponents: [6]),
        team(5, mp: 2.0, opponents: [6], floated_last_round?: true),
        team(6, mp: 2.0, opponents: [4, 5], floated_last_round?: true),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)
      assert s.chosen == set([6], [2.0], 0, 1)
      assert s.runner_up == set([4], [2.0], 1, 0)
      assert s.decided_by == "C6"
    end

    test "[C7] - decided by [C7] only when the runner-up floated; otherwise by 3.5.4" do
      residents = [team(1, mp: 3.0), team(2, mp: 3.0), team(3, mp: 3.0)]

      lower = [
        team(4, mp: 2.0, floated_last_round?: true),
        team(5, mp: 2.0),
        team(6, mp: 2.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)

      assert {s.chosen, s.runner_up, s.decided_by} ==
               {set([5], [2.0], 0, 0), set([6], [2.0], 0, 0), "3.5.4"}

      assert hd(s.considered) == set([4], [2.0], 0, 1)

      # 6 floated too: the best other set is now 4, which lost on [C7].
      lower = List.replace_at(lower, 2, team(6, mp: 2.0, floated_last_round?: true))
      s = first_selection(residents, lower)

      assert {s.chosen.upfloaters, s.runner_up, s.decided_by} ==
               {[5], set([4], [2.0], 0, 1), "C7"}

      # The last two rounds: [C7] is off, every set scores 0 on it, and 4 wins
      # on 3.5.4's order.
      s = first_selection(residents, lower, round: 4, expected_rounds: 5)
      assert {s.chosen, s.decided_by} == {set([4], [2.0], 0, 0), "3.5.4"}
    end

    test "[C6] switched off when the following scoregroup is emptied: [C5] decides" do
      residents = [
        team(1, mp: 3.0, opponents: [2, 3]),
        team(2, mp: 3.0, opponents: [1, 3]),
        team(3, mp: 3.0, opponents: [1, 2])
      ]

      lower =
        [team(4, mp: 2.0), team(5, mp: 2.0), team(6, mp: 2.0)] ++
          for(tpn <- 7..12, do: team(tpn, mp: 1.0))

      s = first_selection(residents, lower)

      assert s.chosen == set([4, 5, 6], [2.0, 2.0, 2.0], 0, 0)
      # The next set that can be paired has a 1-pointer in it; its [C6] and
      # [C7] are never worked out because [C5] already lost.
      assert s.runner_up == set([4, 5, 7], [1.0, 2.0, 2.0], nil, nil)
      assert s.decided_by == "C5"

      # One upfloater cannot make a bracket of residents who have all met:
      # all nine single sets are rejected on [C1].
      assert s.sizes_without_legal_set == [1]
      assert length(s.rejected) == 9 and Enum.all?(s.rejected, &(&1.failed == "C1"))
    end

    test "[C4] - an even scoregroup whose residents have met: no other set, so [C4]" do
      residents = [team(1, mp: 2.0, opponents: [2]), team(2, mp: 2.0, opponents: [1])]
      lower = [team(3, mp: 1.0), team(4, mp: 1.0)]

      s = first_selection(residents, lower)

      assert s.c4 == 2 and s.sizes_without_legal_set == [0]
      assert s.rejected == [%{upfloaters: [], c4: 0, c5: [], failed: "C1"}]
      assert {s.chosen.upfloaters, s.runner_up, s.decided_by} == {[3, 4], nil, "C4"}
    end

    test "[C3] - no upfloaters would strand the teams below: rejected on [C3]" do
      residents = [team(1, mp: 2.0), team(2, mp: 2.0)]

      lower = [
        team(3, mp: 1.0, opponents: [4, 5, 6]),
        team(4, mp: 1.0, opponents: [3]),
        team(5, mp: 1.0, opponents: [3]),
        team(6, mp: 1.0, opponents: [3])
      ]

      s = first_selection(residents, lower)

      assert s.rejected == [%{upfloaters: [], c4: 0, c5: [], failed: "C3"}]

      assert {s.chosen.upfloaters, s.runner_up.upfloaters, s.decided_by} ==
               {[3, 4], [3, 5], "3.5.4"}
    end

    test "[C4] outranks [C5]: the 2-pointer is rejected on [C1], a 1-pointer taken" do
      residents = [
        team(1, mp: 3.0, opponents: [4]),
        team(2, mp: 3.0, opponents: [4]),
        team(3, mp: 3.0, opponents: [4])
      ]

      lower = [
        team(4, mp: 2.0, opponents: [1, 2, 3]),
        team(5, mp: 1.0),
        team(6, mp: 1.0),
        team(7, mp: 1.0),
        team(8, mp: 1.0)
      ]

      s = first_selection(residents, lower)

      assert s.rejected == [%{upfloaters: [4], c4: 1, c5: [2.0], failed: "C1"}]
      assert {s.chosen.upfloaters, s.runner_up.upfloaters, s.decided_by} == {[5], [6], "3.5.4"}
    end

    test "3.6.3 and [C10] - a bracket that needs no upfloaters, and one that needs two" do
      # 3.6.3's position as a whole round: one scoregroup, nothing floats, so
      # the empty set is the only set of its size.
      teams =
        for tpn <- [4, 6, 8, 9, 10, 11, 16, 24] do
          case tpn do
            4 -> team(4, opponents: [10])
            10 -> team(10, opponents: [4])
            n -> team(n)
          end
        end

      assert {:ok, round} = TeamPairing.pair_round(teams, explain: true)
      assert [%{selection: s}] = round.explanation.brackets
      assert {s.c4, s.chosen.upfloaters, s.runner_up, s.decided_by} == {0, [], nil, "C4"}

      assert round.pairs |> Enum.map(&Enum.sort([&1.white, &1.black])) |> Enum.sort() ==
               [[4, 11], [6, 10], [8, 16], [9, 24]]

      assert Enum.all?(
               round.explanation.pairs,
               &(&1.colour_rule == "4.3.1" and &1.first_team_rule == "4.2.3")
             )

      # [C10]'s shape: residents 3 and 4 have met, so both upfloaters come up
      # and every pairing puts two floated teams against an upfloater.
      teams = [
        team(1, floated_last_round?: true),
        team(2, floated_last_round?: true),
        team(3, mp: 1.0, opponents: [4], floated_last_round?: true),
        team(4, mp: 1.0, opponents: [3], floated_last_round?: true)
      ]

      assert {:ok, round} = TeamPairing.pair_round(teams, explain: true)
      assert [%{criteria: {0, 0, 2}}] = round.brackets
      assert [%{selection: s}] = round.explanation.brackets
      assert s.rejected == [%{upfloaters: [], c4: 0, c5: [], failed: "C1"}]
      assert {s.chosen.upfloaters, s.decided_by} == {[1, 2], "C4"}
    end
  end

  # Events are played by `Ainalrami.TeamProof.Events.play_event/4`, and the
  # brute-force reference is `Ainalrami.TeamProof.NaiveReference.ref_round/2`;
  # both were moved to test/support so the exact large-field proof shares them.

  defp collect_stats(acc) do
    receive do
      {:stat, stat} -> collect_stats([stat | acc])
    after
      0 -> acc
    end
  end

  defp collect_reasons(acc) do
    receive do
      {:reasons, reasons} ->
        reasons
        |> Enum.reduce(acc, fn r, acc -> Map.update(acc, r, 1, &(&1 + 1)) end)
        |> collect_reasons()
    after
      0 -> acc
    end
  end

  # ==================================================================
  # Property assertions
  # ==================================================================

  defp assert_absolute(round, field, where) do
    by_tpn = Map.new(field, &{&1.tpn, &1})
    seated = Enum.flat_map(round.pairs, &[&1.white, &1.black])

    # [C3] / 3.3.1 - everyone paired except at most one, who has the bye.
    assert Enum.sort(seated ++ List.wrap(round.bye)) == Enum.sort(Map.keys(by_tpn)),
           "#{where}: not every team paired exactly once"

    assert round.bye != nil == (rem(length(field), 2) == 1),
           "#{where}: a bye exactly when the field is odd"

    for %{white: w, black: b} <- round.pairs do
      assert w != b
      # [C1]
      refute Team.met?(by_tpn[w], b), "#{where}: [C1] - #{w} and #{b} have met"
    end

    # [C2]
    if round.bye do
      refute Team.pab_ineligible?(by_tpn[round.bye]),
             "#{where}: [C2] - #{round.bye} may not receive the bye"
    end
  end

  defp assert_colours(round, field, absent, initial) do
    by_tpn = Map.new(field, &{&1.tpn, &1})
    numbers = ref_numbers(field, absent)

    for %{white: w, black: b} <- round.pairs do
      assert match?({^w, ^b, _rules}, ref_colours(by_tpn[w], by_tpn[b], numbers, initial)),
             "Article 4 disagrees on #{w}-#{b}"
    end
  end

  # Every explanation is bounded, whatever the field: no recorded list longer
  # than the limit, the omitted counts never negative, one entry per pair, and
  # the chosen set is the bracket's upfloaters.
  defp assert_bounded(explanation, round) do
    limit = explanation.limit
    assert length(explanation.pairs) == length(round.pairs)
    assert length(explanation.brackets) == length(round.brackets)

    if explanation.bye do
      assert length(explanation.bye.ineligible) <= limit
      assert length(explanation.bye.passed_over) <= limit
      assert explanation.bye.ineligible_omitted >= 0 and explanation.bye.passed_over_omitted >= 0
    end

    for {account, bracket} <- Enum.zip(explanation.brackets, round.brackets) do
      s = account.selection
      assert length(s.considered) <= limit and length(s.rejected) <= limit
      assert s.considered_omitted >= 0 and s.rejected_omitted >= 0
      assert Enum.sort(s.chosen.upfloaters) == Enum.sort(bracket.upfloaters)
      assert s.decided_by in [nil, "C4", "C5", "C6", "C7", "3.5.4"]
    end
  end
end

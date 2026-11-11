defmodule Ainalrami.TeamPairingScaleTest do
  @moduledoc """
  The 2026-09-16 speed-up of the team engine, checked against what it
  replaced.

  A 2026-09-14 run of 150 generated events of 100-500 teams found six
  refused with `:budget_exhausted` and 30% of the rounds at 300-500 teams
  over ten seconds. The fix changed HOW three questions are answered - is
  this set of teams pairable, which upfloater sets come in which order, and
  how many upfloaters the next bracket needs - and precomputed what the 3.6
  walk asks. None of it may change WHAT is answered. Each test below pins one
  of those invariants against an independent answer: the pre-change walk kept
  verbatim (`Ainalrami.Test.TeamBracketReference`), brute force, or the
  engine's own older path (`field: nil`), which still exists for histories
  the fast paths refuse.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamPairing.{Bracket, Field, Matching, Team}
  alias Ainalrami.Test.TeamBracketReference

  # Since 2026-09-25 3.6 is exact (a fast path through the walk's first
  # candidate, then two minimum-cost matchings), so the pre-change walk is the
  # reference only where it was EXHAUSTIVE - which, at up to fourteen teams
  # and the old default budgets, is nearly always.
  describe "Bracket.pair/2 is the pre-change walk wherever that walk was exhaustive" do
    # 600 brackets against the old walk: about 20 s on a desk, over a minute
    # on a loaded runner, where the default 60 s made it fail for no reason
    # of its own.
    @tag timeout: 300_000
    test "same pairs and criteria on generated brackets; the budgets are ignored" do
      :rand.seed(:exsss, {2026, 9, 16})

      compared =
        for _ <- 1..600, reduce: 0 do
          compared ->
            size = Enum.random([2, 4, 6, 8, 10, 12, 14])
            teams = random_bracket(size)
            tpns = Enum.map(teams, & &1.tpn)

            opts = [
              type: Enum.random([:a, :b]),
              last_round?: Enum.random([true, false]),
              last_two_rounds?: Enum.random([true, false, false]),
              upfloater_tpns: Enum.take_random(tpns, Enum.random(0..3))
            ]

            budgets = [
              max_candidates: Enum.random([1, 2, 7, 60, 200_000]),
              max_steps: Enum.random([5, 40, 300, 5_000, 10_000_000])
            ]

            ours = Bracket.pair(teams, opts)
            where = "#{inspect(opts)}\n#{inspect(teams)}"

            assert Bracket.pair(teams, opts ++ budgets) == ours, where
            assert_matching_path(teams, opts, ours, where)

            case TeamBracketReference.pair(teams, opts) do
              {:ok, %{exhaustive?: true} = ref} ->
                assert {:ok, %{exhaustive?: true} = mine} = ours, where
                assert {mine.pairs, mine.scores} == {ref.pairs, ref.scores}, where
                compared + 1

              {:error, :no_legal_pairing} ->
                assert ours == {:error, :no_legal_pairing}, where
                compared + 1

              _cut ->
                compared
            end
        end

      assert compared >= 590
    end

    test "on larger brackets: never worse than the budgeted walk, equal when it finished" do
      :rand.seed(:exsss, {2026, 9, 17})

      for _ <- 1..12 do
        teams = random_bracket(Enum.random([20, 24, 30]))
        opts = [upfloater_tpns: []]
        budget = [max_candidates: Enum.random([50, 2_000]), max_steps: 400_000]
        ours = Bracket.pair(teams, opts)
        assert_matching_path(teams, opts, ours, inspect(teams))

        case TeamBracketReference.pair(teams, opts ++ budget) do
          {:ok, %{exhaustive?: true} = ref} ->
            assert {:ok, mine} = ours
            assert {mine.pairs, mine.scores} == {ref.pairs, ref.scores}

          {:ok, ref} ->
            assert {:ok, mine} = ours
            assert mine.scores <= ref.scores

          {:error, :no_legal_pairing} ->
            assert ours == {:error, :no_legal_pairing}

          {:error, :budget_exhausted} ->
            :ok
        end
      end
    end
  end

  # The matching path on its own gives the same answer as the fast path
  # wherever the fast path answered: the fast path is a shortcut, not a
  # second definition.
  defp assert_matching_path(teams, opts, ours, where) do
    case {ours, Bracket.__exact_for_test__(teams, opts)} do
      {{:ok, mine}, {:ok, exact}} ->
        assert {mine.pairs, mine.scores} == {exact.pairs, exact.scores}, where

      {theirs, exact} ->
        assert theirs == exact, where
    end
  end

  describe "the matching questions answer what exhaustive search answers" do
    test "Matching.bipartite_perfect?/3 against trying every assignment" do
      :rand.seed(:exsss, {7, 7, 7})

      for _ <- 1..800 do
        k = Enum.random(0..6)
        tops = Enum.to_list(0..(k - 1)//1)
        bottoms = Enum.to_list(k..(2 * k - 1)//1)
        density = :rand.uniform()

        # Noise bits outside the bottoms must be ignored.
        allowed =
          for _ <- 0..(2 * k + 2) do
            Enum.reduce(0..(2 * k + 2), 0, fn j, m ->
              if :rand.uniform() < density, do: m ||| 1 <<< j, else: m
            end)
          end
          |> List.to_tuple()

        bottom_mask = Enum.reduce(bottoms, 0, &(&2 ||| 1 <<< &1))

        brute =
          bottoms
          |> permutations()
          |> Enum.any?(fn perm ->
            tops
            |> Enum.zip(perm)
            |> Enum.all?(fn {t, b} -> (elem(allowed, t) >>> b &&& 1) == 1 end)
          end)

        assert Matching.bipartite_perfect?(tops, bottom_mask, allowed) == brute
      end
    end

    test "Field.feasible?/2 equals the per-question oracle, and greedy never claims a false yes" do
      :rand.seed(:exsss, {8, 8, 8})

      for _ <- 1..300 do
        # Past sixteen teams the exact answer comes from a maximum matching
        # rather than the memoised search, so both sides of that line.
        field_teams = random_field(Enum.random(0..26), :rand.uniform() * 0.6)
        field = Field.new(field_teams)
        assert field != nil

        for _ <- 1..6 do
          subset = Enum.filter(field_teams, fn _ -> :rand.uniform() < 0.7 end)

          assert Field.feasible?(subset, field) == Field.feasible?(subset, nil)

          if length(subset) <= 12,
            do: assert(Field.feasible?(subset, nil) == brute_pairable?(subset))

          mask = Enum.reduce(subset, 0, &(&2 ||| 1 <<< Map.fetch!(field.index, &1.tpn)))
          if Matching.greedy_cover?(mask, field.allowed), do: assert(brute_pairable?(subset))
        end
      end
    end

    test "Field.min_cross/3 is the fewest upfloaters that leave a legal set" do
      :rand.seed(:exsss, {9, 9, 9})

      for _ <- 1..400 do
        teams = random_field(Enum.random(1..12), :rand.uniform() * 0.8)
        {first, second} = Enum.split(teams, Enum.random(1..min(5, length(teams))))

        brute =
          second
          |> subsets()
          |> Enum.filter(fn up ->
            brute_pairable?(first ++ up) and brute_pairable?(second -- up)
          end)
          |> Enum.map(&length/1)
          |> Enum.min(fn -> nil end)

        assert Field.min_cross(first, second, Field.new(teams)) == brute
      end
    end

    test "Field.new/1 refuses a one-sided history and duplicate TPNs, so the older path is taken" do
      assert Field.new([team(1, opponents: [2]), team(2)]) == nil
      assert Field.new([team(1), team(1)]) == nil
      assert Field.new([team(1, opponents: [2, 99]), team(2, opponents: [1])]) != nil
    end
  end

  describe "the upfloater sets of one size come in the order they were sorted into" do
    test "generated scoregroups, mixed integer and float scores, and skipping" do
      :rand.seed(:exsss, {10, 10, 10})

      for _ <- 1..500 do
        lower =
          for tpn <- Enum.take_random(1..60, Enum.random(0..10)) do
            team(tpn, mp: Enum.random([0.0, 1, 1.0, 2.0, 2, 3.5]))
          end

        count = Enum.random(0..5)

        sorted =
          lower
          |> combinations(count)
          |> Enum.map(fn set ->
            ordered = Enum.sort_by(set, fn t -> {0 - t.match_points, t.tpn} end)
            profile = ordered |> Enum.map(& &1.match_points) |> Enum.sort() |> Enum.map(&(0 - &1))
            {profile, Enum.map(ordered, & &1.tpn), ordered}
          end)
          |> Enum.sort_by(fn {profile, tpns, _} -> {profile, tpns} end)

        generated = TeamPairing.__sets_for_test__(lower, count, :match_points)

        assert Enum.map(generated, &Tuple.delete_at(&1, 0)) ===
                 Enum.map(sorted, &Tuple.delete_at(&1, 0))

        assert Enum.map(generated, &elem(&1, 0)) == Enum.map(sorted, &elem(&1, 0))

        skip = Enum.random(0..(length(sorted) + 1))

        assert TeamPairing.__sets_for_test__(lower, count, :match_points, skip) ==
                 Enum.drop(generated, skip)
      end
    end
  end

  describe "upfloater selection with a Field is the selection without one" do
    test "generated positions: the set, and the whole recorded account" do
      :rand.seed(:exsss, {11, 11, 11})

      for _ <- 1..400 do
        {residents, lower} = random_selection_position()
        base = [last_two_rounds?: Enum.random([true, false])]
        limit = Enum.random([nil, 1, 3, 10])

        fast = TeamPairing.__select_for_test__(residents, lower, :match_points, base, limit)

        slow =
          TeamPairing.__select_for_test__(
            residents,
            lower,
            :match_points,
            [field: nil] ++ base,
            limit
          )

        assert fast == slow, "#{inspect(residents)}\n#{inspect(lower)}"
      end
    end

    test "three residents who have all met, above 183 teams, are paired rather than refused" do
      # The shape of 2026-09-14's seed 3, round 11: no one upfloater can make
      # the bracket pairable, and there are C(183, 3) = 1,004,731 sets of
      # three - over the budget, so the round was refused before any was
      # looked at. The first set in order is the whole 15-point group.
      residents = [
        team(1, mp: 16.0, opponents: [2, 3]),
        team(2, mp: 16.0, opponents: [1, 3]),
        team(3, mp: 16.0, opponents: [1, 2])
      ]

      lower =
        for(tpn <- 4..6, do: team(tpn, mp: 15.0)) ++
          for(tpn <- 7..186, do: team(tpn, mp: 10.0))

      assert {:ok, set} = TeamPairing.select_upfloaters(residents, lower, :match_points)
      assert Enum.map(set, & &1.tpn) == [4, 5, 6]

      {:ok, round} = TeamPairing.pair_round(residents ++ lower, explain: true)
      [top | _] = round.explanation.brackets

      assert top.upfloaters == [4, 5, 6]
      assert top.selection.sizes_without_legal_set == [1]
      assert length(top.selection.rejected) == 10
      assert top.selection.rejected_omitted == 183 - 10
      assert Enum.all?(top.selection.rejected, &(&1.failed == "C1"))
    end

    test "a size skipped without walking is recorded as walking it would have recorded it" do
      # Five residents who have all met need five upfloaters: sizes 1 and 3
      # are rejected set by set on the slow path, skipped on the fast one.
      :rand.seed(:exsss, {12, 12, 12})
      residents = for tpn <- 1..5, do: team(tpn, mp: 4.0, opponents: Enum.to_list(1..5) -- [tpn])
      lower = for tpn <- 6..16, do: team(tpn, mp: Enum.random([1.0, 2.0, 3.0]))

      for limit <- [1, 10, 30, 200] do
        fast = TeamPairing.__select_for_test__(residents, lower, :match_points, [], limit)

        slow =
          TeamPairing.__select_for_test__(residents, lower, :match_points, [field: nil], limit)

        assert {:ok, set, selection} = fast
        assert length(set) == 5
        assert selection.sizes_without_legal_set == [1, 3]
        assert fast == slow
      end
    end
  end

  # ==================================================================
  # Generators and brute force
  # ==================================================================

  defp team(tpn, fields \\ []) do
    {mp, fields} = Keyword.pop(fields, :mp, 0.0)
    struct(%Team{tpn: tpn, match_points: mp, game_points: 0.0}, fields)
  end

  # A bracket with scattered TPNs, colour histories long enough for strong
  # preferences, floaters, and opponents both inside and outside it - some
  # one-sided, which the walk must read from the top member's side as it
  # always did.
  defp random_bracket(size) do
    tpns = Enum.take_random(1..(size * 3), size)
    density = :rand.uniform() * 0.5

    for tpn <- Enum.shuffle(tpns) do
      opponents =
        for other <- tpns ++ [999], other != tpn, :rand.uniform() < density, do: other

      %Team{
        tpn: tpn,
        colours: for(_ <- 1..Enum.random(0..5)//1, do: Enum.random([:white, :black])),
        opponents: opponents,
        floated_last_round?: :rand.uniform(3) == 1
      }
    end
  end

  # Teams with a symmetric history of the given density.
  defp random_field(size, density) do
    tpns = Enum.take_random(1..(size * 2 + 1), size)

    met =
      for a <- tpns, b <- tpns, a < b, :rand.uniform() < density, into: MapSet.new(), do: {a, b}

    for tpn <- tpns do
      opponents = for {a, b} <- met, a == tpn or b == tpn, do: if(a == tpn, do: b, else: a)
      team(tpn, opponents: opponents)
    end
  end

  # Residents on one score over lower teams on a few; histories dense at the
  # top, where they are in a real event; the field even.
  defp random_selection_position do
    n_res = Enum.random(1..6)
    n_low = Enum.random(0..11)
    n_low = if rem(n_res + n_low, 2) == 1, do: n_low + 1, else: n_low
    top = 5.0

    teams =
      for i <- 1..(n_res + n_low) do
        mp = if i <= n_res, do: top, else: Enum.random([1.0, 2.0, 3.0, 4.0])
        team(i, mp: mp, floated_last_round?: :rand.uniform(3) == 1)
      end

    met =
      for a <- teams, b <- teams, a.tpn < b.tpn, into: MapSet.new() do
        p = if a.match_points == top and b.match_points == top, do: 0.7, else: 0.2
        if :rand.uniform() < p, do: {a.tpn, b.tpn}, else: nil
      end
      |> MapSet.delete(nil)

    teams =
      Enum.map(teams, fn t ->
        %{
          t
          | opponents:
              for({a, b} <- met, a == t.tpn or b == t.tpn, do: if(a == t.tpn, do: b, else: a))
        }
      end)

    Enum.split(teams, n_res)
  end

  defp brute_pairable?([]), do: true

  defp brute_pairable?([t | rest]) do
    Enum.any?(rest, fn o -> not Team.met?(t, o.tpn) and brute_pairable?(List.delete(rest, o)) end)
  end

  defp subsets([]), do: [[]]

  defp subsets([h | t]) do
    rest = subsets(t)
    rest ++ Enum.map(rest, &[h | &1])
  end

  defp combinations(_list, 0), do: [[]]
  defp combinations([], _n), do: []

  defp combinations([h | t], n),
    do: Enum.map(combinations(t, n - 1), &[h | &1]) ++ combinations(t, n)

  defp permutations([]), do: [[]]

  defp permutations(list),
    do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])
end

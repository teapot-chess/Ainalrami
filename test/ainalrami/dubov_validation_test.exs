defmodule Ainalrami.DubovValidationTest do
  @moduledoc """
  C.04.4.1 (Dubov) whole rounds against `Ainalrami.Test.DubovReference`,
  a brute-force reading of the text that shares no code with the engine,
  on reachable tournaments (`Ainalrami.Test.DubovEvents`).

  Every round is paired four ways - the engine under reading D2 (a) and
  (b), the reference under both - and all four must agree on the pairs,
  their colours and the bye, or all four refuse the round the same way.

  The same test is the long run: `tools/dubov_validation_run.exs` starts
  copies of it on seed ranges through DUBOV_VALIDATION_SEEDS ("a..b");
  without the variable it is the ordinary 150-seed test.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Dubov
  alias Ainalrami.Test.{DubovEvents, DubovReference}

  defp seeds do
    case System.get_env("DUBOV_VALIDATION_SEEDS") do
      nil ->
        1..150

      text ->
        [a, b] = text |> String.split("..") |> Enum.map(&String.to_integer/1)
        a..b
    end
  end

  # DUBOV_VALIDATION_SIZES ("a..b", default 4..10): the roster sizes drawn.
  defp sizes do
    case System.get_env("DUBOV_VALIDATION_SIZES") do
      nil ->
        4..10

      text ->
        [a, b] = text |> String.split("..") |> Enum.map(&String.to_integer/1)
        a..b
    end
  end

  @tag :dubov_whole_rounds
  @tag timeout: :infinity
  test "every round of every generated event matches the brute-force reference" do
    stats =
      Enum.reduce(seeds(), %{rounds: 0, refused: 0, splits: 0, byes: 0, seeds: 0}, fn seed,
                                                                                      stats ->
        rounds_here = :counters.new(4, [])

        DubovEvents.play(seed, sizes(), fn players, opts, round ->
          engine_a = Dubov.pair_round(players, opts)
          engine_b = Dubov.pair_round(players, opts ++ [transposition_rule: :first_reaching_c7])
          ref_a = DubovReference.ref_round(players, opts ++ [d2: :literal])
          ref_b = DubovReference.ref_round(players, opts ++ [d2: :c7])

          :counters.add(rounds_here, 1, 1)

          case {engine_a, ref_a} do
            {{:ok, e}, {:ok, r}} ->
              same = MapSet.new(e.pairs) == r.pairs and e.bye == r.bye

              assert same,
                     """
                     seed #{seed}, round #{round}: engine and reference differ
                       engine:    #{inspect(Enum.sort(e.pairs))} bye #{inspect(e.bye)}
                       reference: #{inspect(Enum.sort(r.pairs))} bye #{inspect(r.bye)}
                       brackets:  #{inspect(e.brackets, limit: :infinity)}
                     """

              assert engine_b == engine_a,
                     "seed #{seed}, round #{round}: D2 (b) differs in the engine"

              assert {:ok, rb} = ref_b

              assert rb.pairs == r.pairs,
                     "seed #{seed}, round #{round}: D2 (b) differs in the reference"

              :counters.add(rounds_here, 3, r.d2_splits)
              if e.bye, do: :counters.add(rounds_here, 4, 1)

              e.pairs ++ if(e.bye, do: [{e.bye, nil}], else: [])

            {{:error, reason}, {:error, ref_reason}} ->
              assert reason == ref_reason,
                     "seed #{seed}, round #{round}: refused as #{inspect(reason)} / #{inspect(ref_reason)}"

              :counters.add(rounds_here, 2, 1)
              :stop

            other ->
              flunk("seed #{seed}, round #{round}: engine vs reference #{inspect(other)}")
          end
        end)

        %{
          stats
          | rounds: stats.rounds + :counters.get(rounds_here, 1),
            refused: stats.refused + :counters.get(rounds_here, 2),
            splits: stats.splits + :counters.get(rounds_here, 3),
            byes: stats.byes + :counters.get(rounds_here, 4),
            seeds: stats.seeds + 1
        }
      end)

    IO.puts(
      "\nDUBOVRUN seeds=#{stats.seeds} rounds=#{stats.rounds} refused=#{stats.refused} " <>
        "byes=#{stats.byes} d2_splits=#{stats.splits}"
    )

    assert stats.rounds > 0
    # Reading D2: the literal and the C7-reaching rule never part (the
    # Bracket moduledoc's t = 0 argument). A split here retires the proof.
    assert stats.splits == 0
  end

  # Larger fields, beyond the reference: the absolute criteria and the
  # round's completeness, every round, and the two D2 readings equal.
  @tag timeout: 600_000
  test "absolute criteria hold on fields of 12-40 players" do
    for seed <- 1..25 do
      DubovEvents.play(seed, 12..40, fn players, opts, round ->
        case Dubov.pair_round(players, opts) do
          {:ok, r} ->
            assert {:ok, r} ==
                     Dubov.pair_round(players, opts ++ [transposition_rule: :first_reaching_c7])

            check_absolute(players, opts, r, "seed #{seed} round #{round}")
            r.pairs ++ if(r.bye, do: [{r.bye, nil}], else: [])

          {:error, _} ->
            :stop
        end
      end)
    end
  end

  defp check_absolute(players, opts, r, label) do
    active = Enum.filter(players, &(length(&1.games) < r.round))
    by_rank = Map.new(players, &{&1.rank, &1})
    paired = Enum.flat_map(r.pairs, &Tuple.to_list/1) ++ List.wrap(r.bye)

    assert Enum.sort(paired) == Enum.sort(Enum.map(active, & &1.rank)), "#{label}: not complete"
    assert r.bye != nil == (rem(length(active), 2) == 1), "#{label}: bye count"

    for {w, b} <- r.pairs do
      refute Enum.any?(
               by_rank[w].games,
               &(&1.opponent_rank == b and Ainalrami.Dubov.Player.played?(&1))
             ),
             "#{label}: [C1] #{w}-#{b}"

      cols = fn p -> for g <- p.games, Ainalrami.Dubov.Player.played?(g), do: g.colour end
      wc = cols.(by_rank[w]) ++ ["w"]
      bc = cols.(by_rank[b]) ++ ["b"]

      for c <- [wc, bc] do
        diff = Enum.count(c, &(&1 == "w")) - Enum.count(c, &(&1 == "b"))
        assert abs(diff) <= 2, "#{label}: colour difference #{inspect(c)}"
        refute match?([x, x, x], Enum.take(c, -3)), "#{label}: three in a row #{inspect(c)}"
      end
    end

    if r.bye do
      refute Enum.any?(by_rank[r.bye].games, &(&1.result in ["U", "+", "F"])),
             "#{label}: [C2] #{r.bye}"
    end

    _ = opts
  end
end

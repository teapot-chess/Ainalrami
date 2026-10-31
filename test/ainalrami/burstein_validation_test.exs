defmodule Ainalrami.BursteinValidationTest do
  @moduledoc """
  C.04.4.2 (Burstein) whole rounds against `Ainalrami.Test.BursteinReference`,
  a brute-force reading of the text that shares no code with the engine,
  on reachable tournaments (`Ainalrami.Test.BursteinEvents`). The seeding
  rounds are the Dutch engine's and are checked against bbpPairings
  (`burstein_bbp_test.exs`), not here.

  The same test is the long run: `tools/burstein_validation_run.exs` starts
  copies of it on seed ranges through BURSTEIN_VALIDATION_SEEDS ("a..b");
  without the variable it is the ordinary 150-seed test.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Burstein
  alias Ainalrami.Test.{BursteinEvents, BursteinReference}

  defp range(var, default) do
    case System.get_env(var) do
      nil ->
        default

      text ->
        [a, b] = text |> String.split("..") |> Enum.map(&String.to_integer/1)
        a..b
    end
  end

  @tag :burstein_whole_rounds
  @tag timeout: :infinity
  test "every round after the seeding rounds matches the brute-force reference" do
    stats =
      Enum.reduce(
        range("BURSTEIN_VALIDATION_SEEDS", 1..150),
        %{rounds: 0, seeding: 0, refused: 0, byes: 0, seeds: 0},
        fn seed, stats ->
          c = :counters.new(4, [])

          BursteinEvents.play(seed, range("BURSTEIN_VALIDATION_SIZES", 4..10), fn players,
                                                                                  opts,
                                                                                  round ->
            engine = Burstein.pair_round(players, opts)

            if round <= Burstein.seeding_rounds(opts[:expected_rounds]) do
              :counters.add(c, 2, 1)

              case engine do
                {:ok, e} -> e.pairs ++ if(e.bye, do: [{e.bye, nil}], else: [])
                {:error, _} -> :stop
              end
            else
              :counters.add(c, 1, 1)
              ref = BursteinReference.ref_round(players, opts)

              case {engine, ref} do
                {{:ok, e}, {:ok, r}} ->
                  assert MapSet.new(e.pairs) == r.pairs and e.bye == r.bye,
                         """
                         seed #{seed}, round #{round}: engine and reference differ
                           engine:    #{inspect(Enum.sort(e.pairs))} bye #{inspect(e.bye)}
                           reference: #{inspect(Enum.sort(r.pairs))} bye #{inspect(r.bye)}
                           brackets:  #{inspect(e.brackets, limit: :infinity)}
                         """

                  if e.bye, do: :counters.add(c, 4, 1)
                  e.pairs ++ if(e.bye, do: [{e.bye, nil}], else: [])

                {{:error, reason}, {:error, ref_reason}} ->
                  assert reason == ref_reason,
                         "seed #{seed}, round #{round}: refused as #{inspect(reason)} / #{inspect(ref_reason)}"

                  :counters.add(c, 3, 1)
                  :stop

                other ->
                  flunk("seed #{seed}, round #{round}: engine vs reference #{inspect(other)}")
              end
            end
          end)

          %{
            stats
            | rounds: stats.rounds + :counters.get(c, 1),
              seeding: stats.seeding + :counters.get(c, 2),
              refused: stats.refused + :counters.get(c, 3),
              byes: stats.byes + :counters.get(c, 4),
              seeds: stats.seeds + 1
          }
        end
      )

    IO.puts(
      "\nBURSTEINRUN seeds=#{stats.seeds} rounds=#{stats.rounds} seeding=#{stats.seeding} " <>
        "refused=#{stats.refused} byes=#{stats.byes}"
    )

    assert stats.rounds > 0
  end

  # Larger fields, beyond the reference: completeness and the absolute
  # criteria, every round.
  @tag timeout: 600_000
  test "absolute criteria hold on fields of 12-40 players" do
    for seed <- 1..20 do
      BursteinEvents.play(seed, 12..40, fn players, opts, round ->
        case Burstein.pair_round(players, opts) do
          {:ok, r} ->
            check_absolute(players, r, "seed #{seed} round #{round}")
            r.pairs ++ if(r.bye, do: [{r.bye, nil}], else: [])

          {:error, _} ->
            :stop
        end
      end)
    end
  end

  defp check_absolute(players, r, label) do
    active = Enum.filter(players, &(length(&1.games) < r.round))
    by_rank = Map.new(players, &{&1.rank, &1})
    paired = Enum.flat_map(r.pairs, &Tuple.to_list/1) ++ List.wrap(r.bye)
    played? = &Ainalrami.Burstein.Player.played?/1

    assert Enum.sort(paired) == Enum.sort(Enum.map(active, & &1.rank)), "#{label}: not complete"
    assert r.bye != nil == (rem(length(active), 2) == 1), "#{label}: bye count"

    for {w, b} <- r.pairs do
      refute Enum.any?(by_rank[w].games, &(&1.opponent_rank == b and played?.(&1))),
             "#{label}: [C1] #{w}-#{b}"

      cols = fn p -> for g <- p.games, played?.(g), do: g.colour end

      for c <- [cols.(by_rank[w]) ++ ["w"], cols.(by_rank[b]) ++ ["b"]] do
        diff = Enum.count(c, &(&1 == "w")) - Enum.count(c, &(&1 == "b"))
        assert abs(diff) <= 2, "#{label}: colour difference #{inspect(c)}"
        refute match?([x, x, x], Enum.take(c, -3)), "#{label}: three in a row #{inspect(c)}"
      end
    end
  end
end

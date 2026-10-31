defmodule Ainalrami.LimValidationTest do
  @moduledoc """
  C.04.4.3 (Lim) whole rounds against `Ainalrami.Test.LimReference`, a
  brute-force reading of the text that shares no code with the engine, on
  reachable tournaments (`Ainalrami.Test.LimEvents`). Every round is
  compared, round 1 included.

  The same test is the long run: `tools/lim_validation_run.exs` starts
  copies of it on seed ranges through LIM_VALIDATION_SEEDS ("a..b");
  without the variable it is the ordinary 150-seed test.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.Lim
  alias Ainalrami.Test.{LimEvents, LimReference}

  defp range(var, default) do
    case System.get_env(var) do
      nil ->
        default

      text ->
        [a, b] = text |> String.split("..") |> Enum.map(&String.to_integer/1)
        a..b
    end
  end

  @tag :lim_whole_rounds
  @tag timeout: :infinity
  test "every round matches the brute-force reference" do
    stats =
      Enum.reduce(
        range("LIM_VALIDATION_SEEDS", 1..150),
        %{rounds: 0, refused: 0, byes: 0, seeds: 0},
        fn seed, stats ->
          c = :counters.new(3, [])

          LimEvents.play(seed, range("LIM_VALIDATION_SIZES", 4..10), fn players, opts, round ->
            :counters.add(c, 1, 1)

            case {Lim.pair_round(players, opts), LimReference.ref_round(players, opts)} do
              {{:ok, e}, {:ok, r}} ->
                assert Enum.sort(e.pairs) == r.pairs and e.bye == r.bye,
                       """
                       seed #{seed}, round #{round}: engine and reference differ
                         engine:    #{inspect(Enum.sort(e.pairs))} bye #{inspect(e.bye)}
                         reference: #{inspect(r.pairs)} bye #{inspect(r.bye)}
                         groups:    #{inspect(e.groups, limit: :infinity)}
                       """

                if e.bye, do: :counters.add(c, 3, 1)
                e.pairs ++ if(e.bye, do: [{e.bye, nil}], else: [])

              {{:error, reason}, {:error, ref_reason}} ->
                assert reason == ref_reason,
                       "seed #{seed}, round #{round}: refused as #{inspect(reason)} / #{inspect(ref_reason)}"

                :counters.add(c, 2, 1)
                :stop

              other ->
                flunk("seed #{seed}, round #{round}: engine vs reference #{inspect(other)}")
            end
          end)

          %{
            stats
            | rounds: stats.rounds + :counters.get(c, 1),
              refused: stats.refused + :counters.get(c, 2),
              byes: stats.byes + :counters.get(c, 3),
              seeds: stats.seeds + 1
          }
        end
      )

    IO.puts(
      "\nLIMRUN seeds=#{stats.seeds} rounds=#{stats.rounds} " <>
        "refused=#{stats.refused} byes=#{stats.byes}"
    )

    assert stats.rounds > 0
  end

  # Larger fields, beyond the reference: completeness, 2.1 and the
  # pairing's own shape, every round.
  @tag timeout: 600_000
  test "every round of 12-40 players is complete and compatible" do
    for seed <- 1..20 do
      LimEvents.play(seed, 12..40, fn players, opts, round ->
        case Lim.pair_round(players, opts) do
          {:ok, r} ->
            check(players, opts, r, "seed #{seed} round #{round}")
            r.pairs ++ if(r.bye, do: [{r.bye, nil}], else: [])

          {:error, _} ->
            :stop
        end
      end)
    end
  end

  defp check(players, opts, r, label) do
    active = players |> Enum.filter(&(length(&1.games) < r.round)) |> Enum.map(& &1.rank)
    seated = Enum.flat_map(r.pairs, fn {w, b} -> [w, b] end) ++ List.wrap(r.bye)
    assert Enum.sort(seated) == Enum.sort(active), "#{label}: not everybody is seated once"

    by_rank = Map.new(players, &{&1.rank, &1})
    last? = r.round == opts[:expected_rounds]

    for {w, b} <- r.pairs do
      met =
        Enum.any?(by_rank[w].games, fn g ->
          g.opponent_rank == b and Ainalrami.Trf.game_was_played?(g.result) and
            g.colour in ["w", "b"]
        end)

      refute met, "#{label}: #{w} and #{b} have met"

      unless last? do
        assert legal?(by_rank[w], :w, r.round), "#{label}: #{w} cannot have White"
        assert legal?(by_rank[b], :b, r.round), "#{label}: #{b} cannot have Black"
      end
    end
  end

  defp legal?(player, colour, round) do
    colours =
      player.games
      |> Enum.take(round - 1)
      |> Enum.filter(
        &(is_integer(&1.opponent_rank) and Ainalrami.Trf.game_was_played?(&1.result))
      )
      |> Enum.map(&if(&1.colour == "w", do: :w, else: :b))

    after_ = colours ++ [colour]
    w = Enum.count(after_, &(&1 == :w))

    abs(2 * w - length(after_)) <= 2 and
      not match?([^colour, ^colour, ^colour | _], Enum.reverse(after_))
  end
end

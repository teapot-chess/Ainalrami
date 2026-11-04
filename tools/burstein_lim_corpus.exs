# The proof run for the Burstein/Lim speed work
# (`docs/perf-burstein-lim-2026-11.md`): both walks in one build
# (`Ainalrami.MatchingWalk`), every round paired twice - `:old` and `:new` -
# and the two whole answers compared as terms: pairs with colours, the bye,
# every bracket's or group's residents, incoming players, floaters, BSN list
# and pairs, or the refusal and its reason, or the exception raised. Any
# difference is written down with the round's input and localised by a
# third run in `:check` mode, which names the bracket or group.
#
#   MIX_ENV=prod mix run tools/burstein_lim_corpus.exs run \
#     --system burstein --tier small --from 1 --count 100000 --out DIR
#   MIX_ENV=prod mix run tools/burstein_lim_corpus.exs summary DIR
#
# Tiers (players; which rounds are compared):
#
#   small   4-40     every round
#   medium  41-120   every round
#   large   121-300  every round
#   huge    301-1000 played forward on `:new`; ONE round compared per
#                    tournament (`--compare` picks it: a random round after
#                    the seeding rounds), since the old walk takes minutes
#
# Each seed is one tournament, its shape drawn from the seed: results
# (uniform, draw-heavy, ALL draws - one scoregroup when nobody is absent -
# or by rating), forbidden pairs (none, one, or 10-40% of the field given
# one each), withdrawals and returns, a late entrant, half- and zero-point
# byes, forfeits, odd and even fields, 3-1-0 scoring, both initial colours,
# and Baku acceleration for Burstein (Lim refuses acceleration). An
# "all draws, pure" shape switches every absence off, so the whole field is
# one scoregroup round after round.
#
# Output: one line per tournament in DIR/<system>-<tier>-<from>.log
# (resumable: a rerun skips seeds already there), and every difference in
# DIR/<system>-<tier>-<from>.diff. `--sabotage prune|floater_check|
# floater_feasible` runs the sensitivity arm: a deliberately broken new
# path the comparison must catch. `--workers` defaults to the schedulers.

defmodule Corpus do
  alias Ainalrami.{Acceleration, Burstein, Lim, MatchingWalk, Trf}

  def tier(:small), do: {4..40, :all}
  def tier(:medium), do: {41..120, :all}
  def tier(:large), do: {121..300, :all}
  def tier(:huge), do: {301..1000, :one}

  # ---- the tournament ---------------------------------------------------

  def shape(seed, system, sizes) do
    :rand.seed(:exsss, {seed, seed * 7_919 + 3, seed * 104_729 + 11})
    n = Enum.random(sizes)
    rounds = if n <= 6, do: Enum.random(3..max(3, n - 1)), else: Enum.random(5..min(n - 1, 11))

    results = pick([{35, :uniform}, {20, :draw_heavy}, {25, :all_draws}, {20, :rated}])
    pure? = results == :all_draws and chance(50)

    players =
      for r <- 1..n do
        rating = 2600 - r * Enum.random(1..max(1, div(1800, n))) + Enum.random(-40..40)
        %{rank: r, points: 0.0, games: [], fide_rating: max(rating, 1001)}
      end

    baku? = system == :burstein and not pure? and chance(15)
    players = if baku?, do: Acceleration.baku(players, rounds), else: players

    point_system =
      if chance(15),
        do: %{Trf.default_point_system() | win: 3.0, draw: 1.0, pairing_allocated_bye: 3.0}

    forbidden =
      case pick([{50, :none}, {20, :one}, {30, :dense}]) do
        :none ->
          []

        :one ->
          [Enum.take_random(1..n, 2)]

        :dense ->
          pct = Enum.random(10..40)

          for a <- Enum.take_random(1..n, max(1, div(n * pct, 100))),
              b = Enum.random(1..n),
              a != b,
              do: [a, b]
      end

    absences? = not pure?

    late = if absences? and chance(15) and n >= 6, do: Enum.random(1..n)

    withdrawn =
      if absences? and chance(30) do
        for r <- Enum.take_random(1..n, Enum.random(1..max(1, div(n, 20) + 1))),
            into: %{},
            do: {r, {Enum.random(2..rounds), if(chance(40), do: Enum.random(1..2))}}
      else
        %{}
      end

    opts =
      [expected_rounds: rounds, initial_colour: Enum.random(["w", "b"])] ++
        if(point_system, do: [point_system: point_system], else: []) ++
        if(forbidden != [], do: [forbidden_pairs: forbidden], else: [])

    %{
      seed: seed,
      n: n,
      rounds: rounds,
      players: players,
      opts: opts,
      results: results,
      pure?: pure?,
      baku?: baku?,
      dense?: length(forbidden) > 1,
      late: late,
      withdrawn: withdrawn,
      ps: point_system || Trf.default_point_system(),
      bye_pct: if(absences? and chance(40), do: Enum.random(3..12), else: 0),
      forfeit_pct:
        if(absences? and results != :all_draws and chance(40), do: Enum.random(3..15), else: 0)
    }
  end

  defp chance(pct), do: :rand.uniform(100) <= pct

  defp pick(weighted) do
    roll = :rand.uniform(Enum.sum(Enum.map(weighted, &elem(&1, 0))))

    Enum.reduce_while(weighted, roll, fn {w, v}, left ->
      if left <= w, do: {:halt, v}, else: {:cont, left - w}
    end)
  end

  defp pre_record(players, round, t) do
    Enum.map(players, fn p ->
      away? =
        case t.withdrawn[p.rank] do
          {from, nil} -> round >= from
          {from, gone} -> round >= from and round < from + gone
          nil -> false
        end

      cond do
        p.rank == t.late and round <= 2 -> record(p, "Z", t.ps)
        away? -> record(p, "Z", t.ps)
        t.bye_pct > 0 and round > 1 and :rand.uniform(100) <= t.bye_pct -> record(p, "H", t.ps)
        t.bye_pct > 0 and round > 1 and :rand.uniform(200) <= t.bye_pct -> record(p, "Z", t.ps)
        true -> p
      end
    end)
  end

  defp record(p, code, ps) do
    game = %{opponent_rank: nil, colour: nil, result: code}
    %{p | points: p.points + Trf.points_for_game(game, ps), games: p.games ++ [game]}
  end

  defp play_round(players, pairs, t) do
    rating = Map.new(players, &{&1.rank, &1.fide_rating})

    results =
      pairs
      |> Enum.flat_map(fn
        {w, nil} ->
          [{w, %{opponent_rank: nil, colour: nil, result: "U"}}]

        {w, b} ->
          {rw, rb} =
            if t.forfeit_pct > 0 and :rand.uniform(100) <= t.forfeit_pct,
              do: Enum.random([{"+", "-"}, {"-", "+"}, {"-", "-"}]),
              else: result(t.results, rating[w], rating[b])

          [
            {w, %{opponent_rank: b, colour: "w", result: rw}},
            {b, %{opponent_rank: w, colour: "b", result: rb}}
          ]
      end)
      |> Map.new()

    Enum.map(players, fn p ->
      case Map.fetch(results, p.rank) do
        {:ok, g} -> %{p | points: p.points + Trf.points_for_game(g, t.ps), games: p.games ++ [g]}
        _ -> p
      end
    end)
  end

  defp result(:all_draws, _, _), do: {"=", "="}

  defp result(:draw_heavy, _, _),
    do: if(chance(70), do: {"=", "="}, else: Enum.random([{"1", "0"}, {"0", "1"}]))

  defp result(:uniform, _, _), do: Enum.random([{"1", "0"}, {"0", "1"}, {"=", "="}])

  defp result(:rated, rw, rb) do
    p = 1 / (1 + :math.pow(10, (rb - rw) / 400))
    roll = :rand.uniform()

    cond do
      roll < p * 0.8 -> {"1", "0"}
      roll < p * 0.8 + 0.2 -> {"=", "="}
      true -> {"0", "1"}
    end
  end

  # ---- one tournament ----------------------------------------------------

  def run_one(seed, system, tier_name, sabotage) do
    {sizes, which} = tier(tier_name)
    t = shape(seed, system, sizes)
    mod = if system == :burstein, do: Burstein, else: Lim
    seeding = if system == :burstein, do: Burstein.seeding_rounds(t.rounds), else: 0

    compare_at =
      case which do
        :all -> :all
        :one -> Enum.random((seeding + 1)..t.rounds)
      end

    acc = %{
      compared: 0,
      seeding: 0,
      refused: 0,
      byes: 0,
      diffs: [],
      old_us: 0,
      new_us: 0,
      stats: %{},
      rounds: 0,
      single_group: 0
    }

    Process.delete({MatchingWalk, :sabotage})

    1..t.rounds
    |> Enum.reduce_while({t.players, acc}, fn round, {players, acc} ->
      players = pre_record(players, round, t)

      if Enum.all?(players, &(length(&1.games) >= round)) do
        {:cont, {players, acc}}
      else
        compare? = compare_at == :all or compare_at == round
        {new, new_us, stats} = pair(mod, players, t.opts, :new, sabotage)
        acc = %{acc | rounds: acc.rounds + 1}

        acc =
          if compare? do
            {old, old_us, _} = pair(mod, players, t.opts, :old, nil)

            acc = %{
              acc
              | compared: acc.compared + 1,
                seeding: acc.seeding + if(round <= seeding, do: 1, else: 0),
                refused: acc.refused + if(match?({:ok, _}, old), do: 0, else: 1),
                byes: acc.byes + if(match?({:ok, %{bye: b}} when b != nil, old), do: 1, else: 0),
                single_group: acc.single_group + single_group(old, round, seeding),
                old_us: acc.old_us + old_us,
                new_us: acc.new_us + new_us,
                stats: Map.merge(acc.stats, stats, fn _, a, b -> a + b end)
            }

            if old == new do
              acc
            else
              where = localise(mod, players, t.opts, sabotage)
              %{acc | diffs: [{round, old, new, where, players} | acc.diffs]}
            end
          else
            acc
          end

        case new do
          {:ok, r} when acc.diffs == [] ->
            pairs = r.pairs ++ if(r.bye, do: [{r.bye, nil}], else: [])
            {:cont, {play_round(players, pairs, t), acc}}

          _ ->
            {:halt, {players, acc}}
        end
      end
    end)
    |> elem(1)
    |> Map.put(:t, t)
  end

  defp single_group({:ok, %{brackets: [_ | _] = b}}, round, seeding) when round > seeding,
    do: if(length(b) == 1, do: 1, else: 0)

  defp single_group({:ok, %{groups: [_]}}, _round, _seeding), do: 1
  defp single_group(_, _, _), do: 0

  defp pair(mod, players, opts, mode, sabotage) do
    MatchingWalk.with_mode(mode, fn ->
      if sabotage && mode == :new, do: Process.put({MatchingWalk, :sabotage}, sabotage)
      MatchingWalk.stats_on()
      t0 = System.monotonic_time(:microsecond)

      answer =
        try do
          mod.pair_round(players, opts)
        rescue
          e -> {:raised, e.__struct__, Exception.message(e)}
        end

      us = System.monotonic_time(:microsecond) - t0
      Process.delete({MatchingWalk, :sabotage})
      {answer, us, MatchingWalk.take_stats()}
    end)
  end

  defp localise(mod, players, opts, sabotage) do
    MatchingWalk.with_mode(:check, fn ->
      if sabotage, do: Process.put({MatchingWalk, :sabotage}, sabotage)

      try do
        mod.pair_round(players, opts)
        "check mode saw no difference"
      rescue
        e -> Exception.message(e)
      after
        Process.delete({MatchingWalk, :sabotage})
      end
    end)
  end

  # ---- the run -----------------------------------------------------------

  def run(system, tier, from, count, dir, workers, sabotage) do
    File.mkdir_p!(dir)
    base = Path.join(dir, "#{system}-#{tier}-#{from}#{if sabotage, do: "-sab-#{sabotage}"}")
    log = base <> ".log"
    diff = base <> ".diff"

    done =
      if File.exists?(log) do
        log
        |> File.stream!()
        |> Enum.map(&(&1 |> String.split("\t") |> hd() |> String.to_integer()))
        |> MapSet.new()
      else
        MapSet.new()
      end

    seeds = Enum.reject(from..(from + count - 1), &MapSet.member?(done, &1))

    IO.puts(
      "#{system} #{tier}: #{length(seeds)} tournaments to run, #{workers} workers -> #{log}"
    )

    {:ok, log_io} = File.open(log, [:append, :utf8])
    {:ok, diff_io} = File.open(diff, [:append, :utf8])

    seeds
    |> Task.async_stream(&{&1, run_one(&1, system, tier, sabotage)},
      max_concurrency: workers,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.each(fn {:ok, {seed, r}} ->
      t = r.t

      flags =
        [
          t.results,
          t.pure? && :pure,
          t.baku? && :baku,
          t.dense? && :dense,
          rem(t.n, 2) == 1 && :odd
        ]
        |> Enum.filter(& &1)
        |> Enum.join(",")

      stats = r.stats |> Enum.sort() |> Enum.map_join(",", fn {k, v} -> "#{k}=#{v}" end)

      line =
        Enum.join(
          [
            seed,
            t.n,
            r.rounds,
            r.compared,
            r.seeding,
            r.refused,
            r.byes,
            r.single_group,
            length(r.diffs),
            div(r.old_us, 1000),
            div(r.new_us, 1000),
            flags,
            stats
          ],
          "\t"
        )

      IO.write(log_io, line <> "\n")

      for {round, old, new, where, players} <- r.diffs do
        IO.write(
          diff_io,
          inspect(
            %{
              seed: seed,
              system: system,
              tier: tier,
              round: round,
              where: where,
              opts: t.opts,
              old: old,
              new: new,
              players: players
            },
            limit: :infinity,
            printable_limit: :infinity
          ) <> "\n\n"
        )

        IO.puts("DIFF seed #{seed} round #{round}: #{String.slice(where, 0, 300)}")
      end
    end)

    File.close(log_io)
    File.close(diff_io)
    IO.puts("done #{log}")
  end

  def summary(dir) do
    rows =
      dir
      |> Path.join("*.log")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn path ->
        lines = path |> File.read!() |> String.split("\n", trim: true)

        cols =
          Enum.map(lines, fn l ->
            [_seed, n, rounds, compared, seeding, refused, byes, single, diffs, old, new | rest] =
              String.split(l, "\t")

            nums =
              Enum.map(
                [n, rounds, compared, seeding, refused, byes, single, diffs, old, new],
                &String.to_integer/1
              )

            stats =
              case rest do
                [_flags, s] when s != "" ->
                  s
                  |> String.split(",")
                  |> Map.new(fn kv ->
                    [k, v] = String.split(kv, "=")
                    {k, String.to_integer(v)}
                  end)

                _ ->
                  %{}
              end

            {nums, stats}
          end)

        sum = fn i -> cols |> Enum.map(&Enum.at(elem(&1, 0), i)) |> Enum.sum() end
        sizes = Enum.map(cols, &hd(elem(&1, 0)))
        stats = Enum.reduce(cols, %{}, &Map.merge(&2, elem(&1, 1), fn _, a, b -> a + b end))

        IO.puts(
          "#{Path.basename(path)}: #{length(lines)} tournaments, sizes #{Enum.min(sizes, fn -> 0 end)}-#{Enum.max(sizes, fn -> 0 end)}, " <>
            "rounds compared #{sum.(2)} (seeding #{sum.(3)}, refused #{sum.(4)}, byes #{sum.(5)}, one group #{sum.(6)}), " <>
            "DIFFS #{sum.(7)}, old #{div(sum.(8), 1000)} s, new #{div(sum.(9), 1000)} s, #{inspect(stats)}"
        )

        {sum.(2), sum.(3), sum.(7)}
      end)

    {c, s, d} =
      Enum.reduce(rows, {0, 0, 0}, fn {a, b, c}, {x, y, z} -> {x + a, y + b, z + c} end)

    IO.puts("TOTAL rounds compared #{c} (of which seeding #{s}), diffs #{d}")
  end
end

case System.argv() do
  ["summary", dir] ->
    Corpus.summary(dir)

  ["run" | rest] ->
    {o, _, _} =
      OptionParser.parse(rest,
        strict: [
          system: :string,
          tier: :string,
          from: :integer,
          count: :integer,
          out: :string,
          workers: :integer,
          sabotage: :string
        ]
      )

    system = String.to_existing_atom(o[:system] || "burstein")
    tier = String.to_existing_atom(o[:tier] || "small")
    sabotage = if s = o[:sabotage], do: String.to_existing_atom(s)
    true = system in [:burstein, :lim] and tier in [:small, :medium, :large, :huge]
    true = sabotage in [nil, :prune, :floater_check, :floater_feasible]

    Corpus.run(
      system,
      tier,
      o[:from] || 1,
      o[:count] || 100,
      o[:out] || "corpus",
      o[:workers] || System.schedulers_online(),
      sabotage
    )

  _ ->
    IO.puts("usage: run --system burstein|lim --tier small|medium|large|huge ... | summary DIR")
end

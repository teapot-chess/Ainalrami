# Large-field scale benchmark: how long one round takes at 1,000 to 10,000
# players, and where that time goes.
#
#   mix run bench/scale.exs                                # 1k,2k,5k,10k
#   SCALE_SIZES=1000,5000 SCALE_ROUNDS=11 mix run bench/scale.exs
#   SCALE_PROFILE=5000:6 mix run bench/scale.exs           # tprof one round
#   SCALE_DIGESTS=new.txt mix run bench/scale.exs          # fingerprint every round
#   SCALE_GEN=1 SCALE_COUNT=200 SCALE_SIZES=40,150,600 SCALE_DIGESTS=d.txt \
#     mix run bench/scale.exs                              # many generated, no timing
#
# ## The tournaments
#
# Not `Ainalrami.Generator`'s uniform field and not the fuzz harness's: a
# big weekend open, the kind that actually gets to thousands of players.
#
#   * ratings roughly normal around 1750 (sd 330, clamped to 1000-2750),
#     about 8% unrated at the bottom of the list; TPNs by rating;
#   * results drawn from the Elo expectation with a 35-point White edge and
#     a draw rate that falls as the rating gap grows;
#   * 2% forfeits, requested half- and zero-point byes (2% and 0.5% a
#     round), a slow trickle of withdrawals from round 3 on;
#   * 3% late entrants arriving in round 2 or 3 with `0000 - Z` for the
#     rounds they missed, numbered after everyone else (the shape
#     `Ainalrami.Test.FuzzTournament` documents and the references accept);
#   * one forbidden pair per 500 players (the siblings and clubmates an
#     arbiter keeps apart);
#   * with `SCALE_ACCEL=baku`, Baku acceleration (FIDE C.04.7): virtual
#     points for the top half's first rounds.
#   * with `SCALE_SOFT=strong` or `weak`, club protection: the field dealt
#     into clubs of 4 to 10 players and every same-club pair declared soft,
#     the way an arbiter keeps clubmates apart without forbidding it.
#
# The tournament is played forward by the engine in THIS tree, and the
# finished field is cached under `bench_corpus/scale/` (gitignored), so a
# baseline checkout pointed at the same directory (`SCALE_CORPUS`) times
# exactly the same inputs. Delete the directory to regenerate.
#
# ## What is timed
#
# Every round re-paired from the state just before it - the field as it
# stood, that round's byes already on record - with `pair_next_round/2`,
# best of `SCALE_REPEAT` runs.
#
# ## Environment
#
#   SCALE_SIZES     field sizes (default 1000,2000,5000,10000)
#   SCALE_ROUNDS    rounds (default 11)
#   SCALE_SEEDS     tournaments per size (default 1)
#   SCALE_REPEAT    timing runs per round, the best kept (default 5 up to
#                   2,000 players, 3 above)
#   SCALE_REF       a git ref (e.g. v0.51.1): compile that release's engine
#                   beside this one, time the two alternately run by run,
#                   and check every round's answer is the same
#   SCALE_CORPUS    cache directory (default bench_corpus/scale)
#   SCALE_DIGESTS   write `size seed round sha256` of every round's answer
#   SCALE_SAMPLE    SIZE:ROUND - run that round once under a 1 ms stack
#                   sampler and print inclusive and own shares (cheap)
#   SCALE_PROFILE   SIZE:ROUND - run that round once under :tprof (time)
#                   and print the top functions instead of the grid
#   SCALE_GEN=1     generation only (with SCALE_COUNT seeds per size and
#                   SCALE_DIGESTS), for differential runs over many
#                   tournaments; nothing is cached or timed
#   SCALE_COUNT     tournaments per size in SCALE_GEN mode (default 100)
#   SCALE_SEED_FROM first seed in SCALE_GEN mode (default 1)
#   SCALE_ACCEL     baku: Baku acceleration (C.04.7) on every tournament
#   SCALE_SOFT      strong | weak: soft pairs (an OpenPairings opt-in, not
#                   FIDE) at that position on the ladder - the field split
#                   into clubs of 4 to 10 players, every same-club pair soft

defmodule ScaleBench.Tournament do
  @moduledoc false
  alias Ainalrami.Pairing

  # A big open's field, ranked. Late entrants come after everyone else, as
  # the active set must stay the gap-free prefix of the TPN list.
  def roster(n, rounds, rng) do
    {players, rng} =
      Enum.map_reduce(1..n, rng, fn i, rng ->
        {u, rng} = :rand.uniform_s(rng)

        if u < 0.08 do
          {%{key: i, rating: 0}, rng}
        else
          {z, rng} = :rand.normal_s(rng)
          {%{key: i, rating: (1750 + 330 * z) |> round() |> max(1000) |> min(2750)}, rng}
        end
      end)

    {late, rng} =
      Enum.map_reduce(players, rng, fn p, rng ->
        {u, rng} = :rand.uniform_s(rng)
        {e, rng} = :rand.uniform_s(rng)
        entry = if rounds >= 3 and u < 0.03, do: 2 + trunc(e * 2), else: 1
        {Map.put(p, :entry, entry), rng}
      end)

    ranked =
      Enum.sort_by(late, fn p -> {p.entry, -p.rating, p.key} end)
      |> Enum.with_index(1)
      |> Enum.map(fn {p, rank} ->
        %{
          rank: rank,
          name: "Player #{p.key}",
          fide_rating: p.rating,
          points: 0.0,
          games: [],
          entry: p.entry
        }
      end)

    {pairs, rng} =
      Enum.map_reduce(1..max(1, div(n, 500)), rng, fn _, rng ->
        {a, rng} = :rand.uniform_s(n, rng)
        {b, rng} = :rand.uniform_s(n, rng)
        {Enum.sort([a, b]), rng}
      end)

    forbidden = pairs |> Enum.reject(fn [a, b] -> a == b end) |> Enum.uniq()
    {ranked, forbidden, rng}
  end

  def points("1"), do: 1.0
  def points("+"), do: 1.0
  def points("U"), do: 1.0
  def points("="), do: 0.5
  def points("H"), do: 0.5
  def points(_), do: 0.0

  defp add_game(p, game), do: %{p | games: p.games ++ [game], points: p.points + points(game.result)}

  defp bye(result), do: %{opponent_rank: nil, colour: nil, result: result}

  # Plays the whole tournament on this tree's engine. `on_round` is called
  # with `{round, active, opts, pairs}` for every round paired. Returns the
  # finished field (late entrants' missed rounds and every bye in place) and
  # the options, or stops early on a round nobody can pair.
  # `SCALE_ACCEL=baku`: FIDE C.04.7 Baku acceleration, as the fuzz harness
  # draws it - the top half of the list (rounded up to an even number) a
  # virtual point for the first quarter of the rounds and half a point for
  # the second.
  def accelerate(players, _rounds, nil), do: players

  def accelerate(players, rounds, "baku") do
    group_a = 2 * div(length(players) + 3, 4)
    accelerated = div(rounds + 1, 2)
    full = div(accelerated + 1, 2)

    values =
      for round <- 1..rounds//1 do
        cond do
          round <= full -> 1.0
          round <= accelerated -> 0.5
          true -> 0.0
        end
      end

    Enum.map(players, fn p ->
      if p.rank <= group_a, do: Map.put(p, :accelerations, values), else: p
    end)
  end

  # `SCALE_SOFT=strong|weak`: the field dealt into clubs of 4 to 10 players,
  # every same-club pair soft. Its own generator, so the roster, results and
  # forbidden pairs are the same draw as without it.
  def soft(_n, _seed, nil), do: []

  def soft(n, seed, position) when position in ["strong", "weak"] do
    rng = :rand.seed_s(:exsss, {seed, n, 104_729})
    {order, rng} =
      Enum.map_reduce(1..n, rng, fn r, rng ->
        {u, rng} = :rand.uniform_s(rng)
        {{u, r}, rng}
      end)

    {clubs, _} = deal(order |> Enum.sort() |> Enum.map(&elem(&1, 1)), rng, [])
    [soft_pairs: clubs, soft_position: String.to_existing_atom(position)]
  end

  defp deal([], rng, acc), do: {acc, rng}

  defp deal(ranks, rng, acc) do
    {size, rng} = :rand.uniform_s(7, rng)
    {club, rest} = Enum.split(ranks, size + 3)
    deal(rest, rng, if(length(club) >= 2, do: [club | acc], else: acc))
  end

  def play(n, rounds, seed, on_round \\ fn _ -> :ok end) do
    rng = :rand.seed_s(:exsss, {seed, n, 7919})
    {roster, forbidden, rng} = roster(n, rounds, rng)
    roster = accelerate(roster, rounds, System.get_env("SCALE_ACCEL"))
    opts = [expected_rounds: rounds, forbidden_pairs: forbidden, initial_colour: "w"]
    opts = opts ++ soft(n, seed, System.get_env("SCALE_SOFT"))

    {field, _withdrawn, _rng} =
      Enum.reduce_while(1..rounds, {roster, MapSet.new(), rng}, fn round, {field, gone, rng} ->
        # Withdrawals from round 3: once gone, gone.
        {gone, rng} =
          if round >= 3 do
            Enum.reduce(field, {gone, rng}, fn p, {gone, rng} ->
              {u, rng} = :rand.uniform_s(rng)
              if u < 0.004 and p.entry <= round, do: {MapSet.put(gone, p.rank), rng}, else: {gone, rng}
            end)
          else
            {gone, rng}
          end

        {field, rng} =
          Enum.map_reduce(field, rng, fn p, rng ->
            cond do
              p.entry > round ->
                {p, rng}

              p.entry == round and p.games == [] and round > 1 ->
                # The late entrant arrives: Z for every round missed.
                {Enum.reduce(1..(round - 1), p, fn _, p -> add_game(p, bye("Z")) end), rng}

              MapSet.member?(gone, p.rank) ->
                {add_game(p, bye("Z")), rng}

              true ->
                {u, rng} = :rand.uniform_s(rng)

                cond do
                  u < 0.02 -> {add_game(p, bye("H")), rng}
                  u < 0.025 -> {add_game(p, bye("Z")), rng}
                  true -> {p, rng}
                end
            end
          end)

        active = Enum.filter(field, &(&1.entry <= round)) |> Enum.map(&Map.delete(&1, :entry))

        case pair(active, opts) do
          {:ok, pairs} ->
            on_round.({round, active, opts, pairs})
            {results, rng} = results(pairs, Map.new(active, &{&1.rank, &1}), rng)
            {:cont, {Enum.map(field, &play_out(&1, results)), gone, rng}}

          {:error, _} ->
            on_round.({round, active, opts, :no_valid_pairing})
            {:halt, {field, gone, rng}}
        end
      end)

    {field, opts}
  end

  defp pair(active, opts) do
    {:ok, Pairing.pair_next_round(active, opts)}
  rescue
    e in Pairing.NoValidPairingError -> {:error, e}
  end

  defp play_out(p, results) do
    case Map.fetch(results, p.rank) do
      {:ok, game} -> add_game(p, game)
      :error -> p
    end
  end

  defp rating(%{fide_rating: 0}), do: 1400
  defp rating(%{fide_rating: r}), do: r

  defp results(pairs, by_rank, rng) do
    Enum.reduce(pairs, {%{}, rng}, fn
      {w, nil}, {acc, rng} ->
        {Map.put(acc, w, bye("U")), rng}

      {w, b}, {acc, rng} ->
        {u, rng} = :rand.uniform_s(rng)
        {v, rng} = :rand.uniform_s(rng)
        diff = rating(by_rank[w]) + 35 - rating(by_rank[b])
        expected = 1 / (1 + :math.pow(10, -diff / 400))
        draw = 0.34 * :math.exp(-abs(diff) / 300)

        {rw, rb} =
          cond do
            u < 0.02 -> if v < 0.5, do: {"+", "-"}, else: {"-", "+"}
            v < draw -> {"=", "="}
            v < draw + (1 - draw) * expected -> {"1", "0"}
            true -> {"0", "1"}
          end

        acc =
          acc
          |> Map.put(w, %{opponent_rank: b, colour: "w", result: rw})
          |> Map.put(b, %{opponent_rank: w, colour: "b", result: rb})

        {acc, rng}
    end)
  end

  # The field as it stood before `round` was paired: entered players only,
  # games up to the round before, plus this round's bye if it was on record
  # before the pairing (a requested bye, a withdrawal, a late entrant's Z).
  def state_before(field, round) do
    field
    |> Enum.filter(&(&1.entry <= round))
    |> Enum.map(fn p ->
      earlier = Enum.take(p.games, round - 1)

      games =
        case Enum.at(p.games, round - 1) do
          %{opponent_rank: nil, result: r} = g when r in ["H", "Z"] -> earlier ++ [g]
          _ -> earlier
        end

      %{
        rank: p.rank,
        name: p.name,
        fide_rating: p.fide_rating,
        games: games,
        points: games |> Enum.map(&points(&1.result)) |> Enum.sum()
      }
      |> Map.merge(Map.take(p, [:accelerations]))
    end)
  end
end

defmodule ScaleBench do
  @moduledoc false
  alias Ainalrami.Pairing
  alias ScaleBench.Tournament

  def env_list(name, default) do
    name
    |> System.get_env(default)
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_integer(String.trim(&1)))
  end

  def env_int(name, default), do: String.to_integer(System.get_env(name, to_string(default)))

  def tournament(size, rounds, seed) do
    dir = System.get_env("SCALE_CORPUS", "bench_corpus/scale")
    File.mkdir_p!(dir)
    accel = if a = System.get_env("SCALE_ACCEL"), do: "_#{a}", else: ""
    accel = if s = System.get_env("SCALE_SOFT"), do: "#{accel}_soft#{s}", else: accel
    path = Path.join(dir, "p#{size}_r#{rounds}_s#{seed}#{accel}.bin")

    if File.exists?(path) do
      :erlang.binary_to_term(File.read!(path))
    else
      {us, value} = :timer.tc(fn -> Tournament.play(size, rounds, seed) end)
      File.write!(path, :erlang.term_to_binary(value, compressed: 6))
      IO.puts("  generated #{path} in #{Float.round(us / 1_000_000, 1)} s")
      value
    end
  end

  def digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  def answer(players, opts), do: answer(Pairing, players, opts)

  # A refusal is part of the answer; compared without its struct name, so
  # that the reference build's (`AinalramiRef.…`) compares equal.
  def answer(pairing, players, opts) do
    {:ok, pairing.pair_next_round(players, opts)}
  rescue
    e ->
      if String.ends_with?(inspect(e.__struct__), "Pairing.NoValidPairingError"),
        do: {:error, Map.from_struct(e)},
        else: reraise(e, __STACKTRACE__)
  end

  def median(values), do: values |> Enum.sort() |> Enum.at(div(length(values), 2))

  def fmt(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 2)} s"
  def fmt(ms), do: "#{round(ms)} ms"

  def played(field), do: field |> Enum.map(&length(&1.games)) |> Enum.max()

  # A wall-clock sampler: every millisecond, the pairing process's stack.
  # Each function is charged for every sample it is on the stack in
  # (inclusive) and for every sample it is on top of (own). Costs almost
  # nothing, so the numbers are the real ones; tprof's call counting slows a
  # 10,000-player round down by two orders of magnitude.
  def sample(spec, rounds) do
    [size, round] = spec |> String.split(":") |> Enum.map(&String.to_integer/1)
    {field, opts} = tournament(size, rounds, 1)
    players = Tournament.state_before(field, round)
    parent = self()

    worker =
      spawn(fn ->
        receive do: (:go -> :ok)
        {us, _} = :timer.tc(fn -> answer(players, opts) end)
        send(parent, {:done, us})
      end)

    # Stacks are cut at 8 frames by default, which hides every caller.
    :erlang.system_flag(:backtrace_depth, 64)
    send(worker, :go)
    {samples, us} = sample_loop(worker, [])
    n = length(samples)
    IO.puts("sampled #{size} players, round #{round}: #{div(us, 1000)} ms, #{n} samples")

    frames = fn stack ->
      Enum.map(stack, fn {m, f, a, _} -> "#{inspect(m)}.#{f}/#{if is_list(a), do: length(a), else: a}" end)
    end

    incl =
      samples
      |> Enum.flat_map(&Enum.uniq(frames.(&1)))
      |> Enum.frequencies()

    own = samples |> Enum.map(&List.first(frames.(&1), "?")) |> Enum.frequencies()

    IO.puts("\n  incl%   own%  function")

    incl
    |> Enum.sort_by(fn {_, c} -> -c end)
    |> Enum.take(String.to_integer(System.get_env("SCALE_TOP", "60")))
    |> Enum.each(fn {name, c} ->
      pct = fn x -> :erlang.float_to_binary(100 * x / max(n, 1), decimals: 1) end
      IO.puts(String.pad_leading(pct.(c), 7) <> String.pad_leading(pct.(Map.get(own, name, 0)), 7) <> "  " <> name)
    end)
  end

  defp sample_loop(worker, acc) do
    receive do
      {:done, us} -> {acc, us}
    after
      1 ->
        case Process.info(worker, :current_stacktrace) do
          {:current_stacktrace, stack} -> sample_loop(worker, [stack | acc])
          nil -> sample_loop(worker, acc)
        end
    end
  end

  def profile(spec, rounds) do
    [size, round] = spec |> String.split(":") |> Enum.map(&String.to_integer/1)
    {field, opts} = tournament(size, rounds, 1)
    players = Tournament.state_before(field, round)
    Mix.ensure_application!(:tools)
    IO.puts("tprof (time), #{size} players, round #{round}")
    # :tprof lives in the tools application, which this project does not
    # list; apply/3 keeps the compiler quiet about it. Own time per
    # function, the 45 most expensive (tprof sorts ascending).
    raw =
      apply(:tprof, :profile, [
        fn -> Pairing.pair_next_round(players, opts) end,
        %{type: :call_time, report: :return}
      ])

    # `report: :return` hands back the function's own result beside the
    # profile on this OTP; take the profile wherever it is.
    entries = call_time_entries(raw)

    rows =
      for {m, f, a, per_pid} <- entries do
        {calls, us} =
          Enum.reduce(per_pid, {0, 0}, fn {_pid, c, t}, {cs, ts} -> {cs + c, ts + t} end)

        {us, calls, "#{inspect(m)}.#{f}/#{a}"}
      end

    total = rows |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    IO.puts("total own time #{div(total, 1000)} ms (profiled; overhead included)")
    IO.puts("   own %       ms       calls  function")

    rows
    |> Enum.sort(:desc)
    |> Enum.take(45)
    |> Enum.each(fn {us, calls, name} ->
      pct = :erlang.float_to_binary(100 * us / max(total, 1), decimals: 1)

      IO.puts(
        String.pad_leading(pct, 8) <>
          String.pad_leading("#{div(us, 1000)}", 9) <>
          String.pad_leading("#{calls}", 12) <> "  " <> name
      )
    end)
  end

  defp call_time_entries({:call_time, entries}) when is_list(entries), do: entries
  defp call_time_entries([{:call_time, _} | _] = list), do: Enum.flat_map(list, &call_time_entries/1)
  defp call_time_entries({_result, profile}), do: call_time_entries(profile)

  def generate_only(sizes, rounds, out) do
    from = env_int("SCALE_SEED_FROM", 1)
    count = env_int("SCALE_COUNT", 100)

    jobs = for size <- sizes, seed <- from..(from + count - 1), do: {size, seed}

    lines =
      jobs
      |> Task.async_stream(
        fn {size, seed} ->
          Process.put(:lines, [])

          Tournament.play(size, rounds, seed, fn {round, active, _opts, pairs} ->
            Process.put(:lines, ["#{size} #{seed} #{round} #{length(active)} #{digest(pairs)}\n" | Process.get(:lines)])
          end)

          Enum.reverse(Process.get(:lines))
        end,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.flat_map(fn {:ok, l} -> l end)

    File.write!(out, lines)
    IO.puts("#{length(jobs)} tournaments, #{length(lines)} rounds -> #{out}")
  end

  def run do
    sizes = env_list("SCALE_SIZES", "1000,2000,5000,10000")
    rounds = env_int("SCALE_ROUNDS", 11)
    seeds = env_int("SCALE_SEEDS", 1)
    digests = System.get_env("SCALE_DIGESTS")

    cond do
      System.get_env("SCALE_GEN") == "1" ->
        generate_only(sizes, rounds, digests || "scale_digests.txt")

      spec = System.get_env("SCALE_SAMPLE") ->
        sample(spec, rounds)

      spec = System.get_env("SCALE_PROFILE") ->
        profile(spec, rounds)

      true ->
        grid(sizes, rounds, seeds, digests)
    end
  end

  # Each round is timed `repeat` times and the BEST time kept: on a shared
  # machine the slowest runs measure the neighbours, the fastest the code.
  # With a reference build the two are timed alternately, run by run, and
  # their answers compared as they go.
  def grid(sizes, rounds, seeds, digests) do
    ref_name = System.get_env("SCALE_REF")
    ref = ScaleBench.Reference.load(ref_name)

    IO.puts(
      "schedulers online: #{System.schedulers_online()}, OTP #{System.otp_release()}" <>
        if(ref, do: ", against #{ref_name}", else: "")
    )

    rows =
      for size <- sizes, seed <- 1..seeds do
        {field, opts} = tournament(size, rounds, seed)
        repeat = env_int("SCALE_REPEAT", if(size <= 2000, do: 5, else: 3))

        for round <- 1..played(field) do
          players = Tournament.state_before(field, round)

          runs =
            for _ <- 1..repeat do
              r = if ref, do: timed(ref, players, opts)
              {r, timed(Pairing, players, opts)}
            end

          {ref_runs, new_runs} = Enum.unzip(runs)
          {ms, a} = Enum.min_by(new_runs, &elem(&1, 0))
          answers = Enum.map(new_runs, &elem(&1, 1))
          if Enum.uniq(answers) != [a], do: raise("the build answered differently run to run")

          {ref_ms, same} =
            if ref do
              {rms, ra} = Enum.min_by(ref_runs, &elem(&1, 0))
              same = ra == a
              unless same, do: IO.puts("  ** #{size} s#{seed} r#{round}: ANSWERS DIFFER FROM #{ref_name} **")
              {rms, same}
            else
              {nil, nil}
            end

          IO.puts(
            "  #{size} s#{seed} r#{round} active=#{length(players)}: " <>
              if(ref, do: "#{fmt(ref_ms)} -> #{fmt(ms)}#{if same, do: " (identical)"}", else: fmt(ms))
          )

          %{size: size, seed: seed, round: round, ms: ms, ref_ms: ref_ms, same: same, digest: digest(a)}
        end
      end
      |> List.flatten()

    summary(rows, rounds, ref != nil)

    if ref do
      differ = Enum.count(rows, &(&1.same == false))
      IO.puts("\n#{length(rows) - differ} of #{length(rows)} rounds identical to #{ref_name}")
    end

    if digests do
      File.write!(digests, Enum.map(rows, &"#{&1.size} #{&1.seed} #{&1.round} #{&1.digest}\n"))
    end
  end

  defp timed(pairing, players, opts) do
    :erlang.garbage_collect()
    {us, a} = :timer.tc(fn -> answer(pairing, players, opts) end)
    {us / 1000, a}
  end

  defp stats(values) do
    ms = Enum.sort(values)
    p95 = Enum.at(ms, min(length(ms) - 1, round(0.95 * (length(ms) - 1))))
    {median(ms), p95, List.last(ms), Enum.sum(ms)}
  end

  defp summary(rows, rounds, ref?) do
    if ref? do
      IO.puts(
        "\n| field | rounds | median before | after | max before | after | total before | after | speed-up |\n" <>
          "|---|---|---|---|---|---|---|---|---|"
      )
    else
      IO.puts("\n| field | rounds | median | p95 | max | total |\n|---|---|---|---|---|---|")
    end

    for {size, rs} <- Enum.group_by(rows, & &1.size) |> Enum.sort() do
      {med, p95, max, total} = stats(Enum.map(rs, & &1.ms))

      if ref? do
        {rmed, _, rmax, rtotal} = stats(Enum.map(rs, & &1.ref_ms))

        IO.puts(
          "| #{size} | #{length(rs)} | #{fmt(rmed)} | #{fmt(med)} | #{fmt(rmax)} | #{fmt(max)} | " <>
            "#{fmt(rtotal)} | #{fmt(total)} | #{Float.round(rtotal / max(total, 0.001), 1)}x |"
        )
      else
        IO.puts("| #{size} | #{length(rs)} | #{fmt(med)} | #{fmt(p95)} | #{fmt(max)} | #{fmt(total)} |")
      end
    end

    IO.puts("\n| field | " <> Enum.map_join(1..rounds, " | ", &"r#{&1}") <> " |")
    IO.puts("|---|" <> String.duplicate("---|", rounds))

    for {size, rs} <- Enum.group_by(rows, & &1.size) |> Enum.sort() do
      by_round = Enum.group_by(rs, & &1.round)

      cell = fn r, key ->
        case by_round[r] do
          nil -> ""
          list -> list |> Enum.map(&Map.fetch!(&1, key)) |> Enum.max() |> fmt()
        end
      end

      if ref? do
        IO.puts("| #{size} before | " <> Enum.map_join(1..rounds, " | ", &cell.(&1, :ref_ms)) <> " |")
      end

      IO.puts("| #{size}#{if ref?, do: " after"} | " <> Enum.map_join(1..rounds, " | ", &cell.(&1, :ms)) <> " |")
    end
  end
end

defmodule ScaleBench.Reference do
  @moduledoc false
  # The engine as it stood at a git ref, every file under lib/ compiled
  # beside this tree's with `Ainalrami` renamed `AinalramiRef`, so the two
  # are timed in one VM, alternately, under the same load - the only fair
  # comparison on a machine that is doing anything else.
  def load(nil), do: nil

  def load(ref) do
    dir = Path.join(System.tmp_dir!(), "ainalrami_ref_#{:erlang.phash2(ref)}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    {list, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", ref, "lib/"])

    files =
      for path <- String.split(list, "\n", trim: true), String.ends_with?(path, ".ex") do
        {source, 0} = System.cmd("git", ["show", "#{ref}:#{path}"])
        out = Path.join(dir, String.replace(path, "/", "__"))

        File.write!(
          out,
          source
          |> String.replace(~r/\bAinalrami\b(?=\.|\s+do\b)/, "AinalramiRef")
        )

        out
      end

    {:ok, _modules, _warnings} =
      Kernel.ParallelCompiler.compile(files, return_diagnostics: true)

    AinalramiRef.Pairing
  end
end

# Loaded as a library by other scripts with SCALE_LIB_ONLY=1.
unless System.get_env("SCALE_LIB_ONLY"), do: ScaleBench.run()

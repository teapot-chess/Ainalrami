# The differential net for performance work: records a fingerprint of
# everything the engine answers, round by round, so two builds can be held
# to BYTE-IDENTICAL output rather than to "the same agreement rate".
#
#   MIX_ENV=test mix run tools/perf_diff.exs            # one axis -> DIFF_OUT
#   MIX_ENV=test mix run tools/perf_diff.exs corpus small DIR   # a named set
#   (the same in a checkout of the release being compared against)
#   mix run tools/perf_diff.exs compare A B    # two logs, or two directories
#
# The named sets - `small`, `flags`, `large`, and `early` (large fields,
# opening rounds) - are the standing corpus; see `PerfDiff.Corpus` below for
# their axes. AINALRAMI_CERT=force exercises the certified shortcuts on
# every field size; AINALRAMI_CERT_STATS=1 writes their counters next to
# each log (`<axis>.log.stats`).
#
# ## What is fingerprinted
#
# Every round of every tournament, a SHA-256 over the canonical external
# form (`:erlang.term_to_binary(term, [:deterministic])`) of:
#
#   * `pair`    - `Pairing.pair_next_round/2`'s pairs, in order, colours
#                 included; or the exception it raised, with its reason,
#                 excluded ranks and override
#   * `explain` - `Pairing.explain_round/3` on those pairs, with the
#                 organiser's bye exclusions' passed-over chain switched on
#                 whenever there is one to compute
#   * `other`   - `explain_round/3` and `Alternatives.judge/4` on a
#                 PERTURBED pairing (two boards' Black players swapped),
#                 because OpenPairings also explains boards the engine did
#                 not choose: hand-edited rounds and JaVaFo's
#   * `alts`    - on a sampled share of rounds, `float_alternatives/3` and
#                 `bye_alternatives/3` at the default cap (and at `:all` on
#                 small fields), plus `force_pair/5` and `no_show/4` on a
#                 random board - every forced search the Alternatives
#                 module runs
#
# ## The tournaments
#
# `Ainalrami.Test.FuzzTournament` - the generator every comparison corpus
# in this project uses - played forward on the engine UNDER TEST. That is
# sound for a differential: identical answers consume the result draws
# identically, so two builds see identical inputs round after round until
# the first round they answer differently, and that round is the finding.
# Its knobs (`PAIRING_FUZZ_*`) choose the axis. On top of them, drawn from a
# separate random stream so the fuzz generator's own draws are untouched:
# soft pairs (either position) on a third of tournaments, and organiser bye
# exclusions on a third of rounds.
#
# ## Environment
#
#   DIFF_AXIS        label written on every line (default "axis")
#   DIFF_SEED_FROM   first seed (default 1)
#   DIFF_COUNT       tournaments (default 200)
#   DIFF_ROUNDS      rounds per tournament, before PAIRING_FUZZ_ROUNDS_MAX
#   DIFF_ALTS        percent of rounds that also run the alternatives
#                    (default 25)
#   DIFF_OUT         log path (default perf_diff.log)
#   DIFF_EXTRAS      "0" turns the soft-pair / bye-exclusion extras off
#
# For `corpus` runs, which take hours on the small set:
#
#   DIFF_CHUNK       tournaments per chunk: each axis is run as consecutive
#                    slices of this many seeds, each written to its own
#                    `<axis>.<first seed>.log` (via a `.tmp` renamed on
#                    completion), and a slice whose log already exists is
#                    skipped - so an interrupted run resumes where it
#                    stopped. `compare` reads every `.log` in a directory.
#   DIFF_AXES        comma-separated axis names: run only these
#   DIFF_LIMIT       at most this many tournaments of each axis (its first)
#   DIFF_SUBSET      "1": `compare` checks only the rounds the SECOND
#                    directory has (a partial run against a full baseline)

alias Ainalrami.{Alternatives, Pairing}
alias Ainalrami.Test.FuzzTournament, as: Fuzz

defmodule PerfDiff do
  alias Ainalrami.{Alternatives, Pairing}
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  def int(name, default), do: name |> System.get_env(to_string(default)) |> String.to_integer()

  def digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def run(seed, rounds_asked, range, alts_pct, extras?) do
    {rounds, player_count, forbidden, roster} = Fuzz.begin!(seed, rounds_asked, range)
    rng = :rand.seed_s(:exsss, {seed, 4242, 99_991})

    {soft, rng} = soft_pairs(rng, player_count, extras?)
    {position, rng} = pick(rng, [:strong, :weak])

    {lines, _, _} =
      Enum.reduce_while(1..rounds, {[], roster, rng}, fn round, {acc, players, rng} ->
        Fuzz.withdraw_some(round, player_count)
        {active, pending} = Fuzz.reveal_late_entrants(players, round)
        active = Fuzz.assign_requested_byes(active)

        {exclusions, rng} = bye_exclusions(rng, active, extras?)

        opts =
          [
            expected_rounds: rounds,
            forbidden_pairs: forbidden,
            initial_colour: String.downcase(Fuzz.initial_colour()),
            point_system: Fuzz.point_system()
          ]
          |> then(&if(soft == [], do: &1, else: &1 ++ [soft_pairs: soft, soft_position: position]))
          |> then(&if(exclusions == [], do: &1, else: &1 ++ [bye_exclusions: exclusions]))

        {pair_result, pairs, opts} = pair(active, opts)

        case pairs do
          nil ->
            line = [round, length(active), digest(pair_result), "-", "-", "-"]
            {:halt, {[line | acc], players, rng}}

          pairs ->
            explain = safely(fn -> Pairing.explain_round(active, pairs, opts) end)
            {other, rng} = perturbed(rng, active, pairs, opts)
            {alts, rng} = alternatives(rng, active, pairs, opts, alts_pct)

            line = [
              round,
              length(active),
              digest(pair_result),
              digest(explain),
              digest(other),
              if(alts == :skipped, do: "-", else: digest(alts))
            ]

            next = Fuzz.apply_round(active, pairs, Fuzz.simulate_results(pairs))
            {:cont, {[line | acc], next ++ pending, rng}}
        end
      end)

    lines
    |> Enum.reverse()
    |> Enum.map(fn [round | rest] -> [seed, round | rest] end)
    |> then(fn lines -> {lines, cert_stats()} end)
  end

  # Absent from releases before the certified shortcuts, which this tool is
  # also run against.
  defp cert_stats do
    if function_exported?(Pairing, :take_cert_stats, 0),
      do: apply(Pairing, :take_cert_stats, []),
      else: %{}
  end

  # The pairing, or the refusal. A refusal the organiser's exclusions
  # caused is answered the way OpenPairings answers it - "pair anyway,
  # ignoring the exclusion for" the override - so the tournament goes on.
  defp pair(players, opts) do
    pairs = Pairing.pair_next_round(players, opts)
    {{:ok, pairs}, pairs, opts}
  rescue
    e in Pairing.NoValidPairingError ->
      refusal = {:raised, e.reason, e.excluded, e.override, e.message}

      if e.reason == :bye_exclusions and e.override do
        opts = Keyword.update!(opts, :bye_exclusions, &List.delete(&1, e.override))
        {retry, pairs, opts} = pair(players, opts)
        {{refusal, retry}, pairs, opts}
      else
        {refusal, nil, opts}
      end
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  end

  defp perturbed(rng, players, pairs, opts) do
    boards = Enum.filter(pairs, fn {_w, b} -> b != nil end)

    if length(boards) < 2 do
      {:none, rng}
    else
      {i, rng} = :rand.uniform_s(length(boards), rng)
      {j, rng} = :rand.uniform_s(length(boards), rng)
      {w1, b1} = Enum.at(boards, i - 1)
      {w2, b2} = Enum.at(boards, j - 1)

      swapped =
        Enum.map(pairs, fn
          {^w1, ^b1} -> {w1, b2}
          {^w2, ^b2} -> {w2, b1}
          other -> other
        end)

      {{safely(fn -> Pairing.explain_round(players, swapped, opts) end),
        safely(fn -> Alternatives.judge(players, pairs, swapped, opts) end)}, rng}
    end
  end

  defp alternatives(rng, players, pairs, opts, pct) do
    {roll, rng} = :rand.uniform_s(100, rng)

    if roll > pct do
      {:skipped, rng}
    else
      cap = if length(players) <= 24, do: :all, else: nil
      alt_opts = if cap, do: Keyword.put(opts, :max_candidates, cap), else: opts
      ranks = Enum.map(pairs, &elem(&1, 0))
      {a, rng} = pick(rng, ranks)
      {b, rng} = pick(rng, ranks)

      boards = Enum.filter(pairs, fn {_w, b} -> b != nil end)

      {absent, rng} =
        case boards do
          [] -> {nil, rng}
          _ -> pick(rng, Enum.map(boards, &elem(&1, 1)))
        end

      result = {
        safely(fn -> Alternatives.float_alternatives(players, pairs, opts) end),
        safely(fn -> Alternatives.bye_alternatives(players, pairs, opts) end),
        cap && safely(fn -> Alternatives.float_alternatives(players, pairs, alt_opts) end),
        cap && safely(fn -> Alternatives.bye_alternatives(players, pairs, alt_opts) end),
        a != b && safely(fn -> Alternatives.force_pair(players, pairs, a, b, opts) end),
        absent && safely(fn -> Alternatives.no_show(players, pairs, absent, opts) end)
      }

      {result, rng}
    end
  end

  # A third of tournaments carry the arbiter's "rather not" pairs: about one
  # player in eight in a pair or a trio, as a club-protection list looks.
  defp soft_pairs(rng, _n, false), do: {[], rng}

  defp soft_pairs(rng, n, true) do
    {roll, rng} = :rand.uniform_s(3, rng)

    if roll != 1 or n < 4 do
      {[], rng}
    else
      groups = max(1, div(n, 8))

      Enum.reduce(1..groups, {[], rng}, fn _, {acc, rng} ->
        {size, rng} = :rand.uniform_s(3, rng)
        size = if size == 3, do: 3, else: 2

        {members, rng} =
          Enum.reduce(1..size, {[], rng}, fn _, {m, rng} ->
            {r, rng} = :rand.uniform_s(n, rng)
            {[r | m], rng}
          end)

        members = Enum.uniq(members)
        {if(length(members) >= 2, do: [members | acc], else: acc), rng}
      end)
    end
  end

  # A third of rounds exclude one to three random active players from the
  # pairing-allocated bye.
  defp bye_exclusions(rng, _active, false), do: {[], rng}

  defp bye_exclusions(rng, active, true) do
    {roll, rng} = :rand.uniform_s(3, rng)

    if roll != 1 or active == [] do
      {[], rng}
    else
      {k, rng} = :rand.uniform_s(3, rng)

      {ranks, rng} =
        Enum.reduce(1..k, {[], rng}, fn _, {acc, rng} ->
          {p, rng} = pick(rng, active)
          {[p.rank | acc], rng}
        end)

      {Enum.sort(Enum.uniq(ranks)), rng}
    end
  end

  # A round with nobody paired - everyone withdrawn or on a requested bye -
  # still rolls for the alternatives, and `:rand.uniform_s(0, _)` has no
  # answer. Nothing to pick, no draw taken, so every other round's stream
  # is untouched.
  defp pick(rng, []), do: {nil, rng}

  defp pick(rng, list) do
    {i, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, i - 1), rng}
  end
end

defmodule PerfDiff.Corpus do
  @moduledoc false

  # The standing corpus, one axis per line: a label, the tournaments, the
  # seed range and the knobs. Seeds never overlap between axes. Run with
  #
  #   MIX_ENV=test mix run tools/perf_diff.exs corpus small DIR
  #
  # which writes DIR/<axis>.log for every axis of the set, in turn - the
  # `PAIRING_FUZZ_*` knobs are read from the environment while a tournament
  # is being generated, so the axes cannot share a VM concurrently.
  @base %{"DIFF_ROUNDS" => "9", "DIFF_ALTS" => "25"}

  @small [
    {"s_plain", 6000, %{}},
    {"s_byes", 6000,
     %{
       "PAIRING_FUZZ_BYE_PCT" => "10",
       "PAIRING_FUZZ_FORFEIT_PCT" => "6",
       "PAIRING_FUZZ_WITHDRAW_PCT" => "2"
     }},
    {"s_forbid_accel", 6000,
     %{"PAIRING_FUZZ_FORBIDDEN_PCT" => "10", "PAIRING_FUZZ_ACCEL" => "mixed"}},
    {"s_late", 5000,
     %{
       "PAIRING_FUZZ_LATE_PCT" => "15",
       "PAIRING_FUZZ_BYE_PCT" => "5",
       "PAIRING_FUZZ_FORFEIT_PCT" => "3"
     }},
    {"s_points", 5000,
     %{
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
       "PAIRING_FUZZ_INITIAL_COLOUR" => "mixed",
       "PAIRING_FUZZ_RATING_MODE" => "mixed",
       "PAIRING_FUZZ_BYE_PCT" => "5"
     }},
    {"s_combined", 8000,
     %{
       "PAIRING_FUZZ_ROUNDS_MAX" => "13",
       "DIFF_ROUNDS" => "5",
       "PAIRING_FUZZ_BYE_PCT" => "8",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "5",
       "PAIRING_FUZZ_ACCEL" => "mixed",
       "PAIRING_FUZZ_WITHDRAW_PCT" => "2",
       "PAIRING_FUZZ_LATE_PCT" => "5",
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
       "PAIRING_FUZZ_INITIAL_COLOUR" => "mixed",
       "PAIRING_FUZZ_RATING_MODE" => "mixed"
     }},
    {"s_tiny_deep", 6000,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "4",
       "PAIRING_FUZZ_MAX_PLAYERS" => "12",
       "DIFF_ROUNDS" => "5",
       "PAIRING_FUZZ_ROUNDS_MAX" => "11",
       "PAIRING_FUZZ_BYE_PCT" => "10",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "8"
     }},
    {"s_late_half", 3000,
     %{
       "PAIRING_FUZZ_LATE_PCT" => "20",
       "PAIRING_FUZZ_LATE_BYE_TYPE" => "H",
       "PAIRING_FUZZ_ACCEL" => "baku"
     }}
  ]

  # Every bracket on the field graph, and the completion repair forced.
  @flags [
    {"f_nofast", 3000,
     %{
       "AINALRAMI_NOFAST" => "1",
       "PAIRING_FUZZ_MAX_PLAYERS" => "60",
       "PAIRING_FUZZ_BYE_PCT" => "8",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "5",
       "PAIRING_FUZZ_ACCEL" => "mixed"
     }},
    {"f_strand", 3000,
     %{
       "AINALRAMI_FORCE_STRAND" => "1",
       "PAIRING_FUZZ_BYE_PCT" => "8",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5"
     }},
    {"f_completion", 2000,
     %{"AINALRAMI_COMPLETION" => "eligibility", "PAIRING_FUZZ_BYE_PCT" => "8"}}
  ]

  @large [
    {"l_60_120", 400,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "60",
       "PAIRING_FUZZ_MAX_PLAYERS" => "120",
       "DIFF_ALTS" => "10",
       "PAIRING_FUZZ_BYE_PCT" => "5",
       "PAIRING_FUZZ_FORFEIT_PCT" => "4",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "2",
       "PAIRING_FUZZ_ACCEL" => "mixed",
       "PAIRING_FUZZ_WITHDRAW_PCT" => "1"
     }},
    {"l_150_250", 150,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "150",
       "PAIRING_FUZZ_MAX_PLAYERS" => "250",
       "DIFF_ROUNDS" => "9",
       "PAIRING_FUZZ_ROUNDS_MAX" => "11",
       "DIFF_ALTS" => "5",
       "PAIRING_FUZZ_BYE_PCT" => "4",
       "PAIRING_FUZZ_FORFEIT_PCT" => "3",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "1",
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
       "PAIRING_FUZZ_LATE_PCT" => "3"
     }},
    {"l_300_600", 36,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "300",
       "PAIRING_FUZZ_MAX_PLAYERS" => "600",
       "DIFF_ROUNDS" => "11",
       "DIFF_ALTS" => "3",
       "PAIRING_FUZZ_BYE_PCT" => "3",
       "PAIRING_FUZZ_FORFEIT_PCT" => "2",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "1",
       "PAIRING_FUZZ_ACCEL" => "mixed"
     }}
  ]

  # The certified shortcuts' own ground: large fields, weighted towards the
  # opening rounds where whole-field brackets and windows over a large field
  # below occur, with byes, forfeits, forbidden pairs and accelerations.
  @early [
    {"e_100_200_r9", 120,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "100",
       "PAIRING_FUZZ_MAX_PLAYERS" => "200",
       "DIFF_ROUNDS" => "9",
       "DIFF_ALTS" => "4",
       "PAIRING_FUZZ_BYE_PCT" => "4",
       "PAIRING_FUZZ_FORFEIT_PCT" => "3",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "2",
       "PAIRING_FUZZ_ACCEL" => "mixed",
       "PAIRING_FUZZ_LATE_PCT" => "3"
     }},
    {"e_150_350_r3", 240,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "150",
       "PAIRING_FUZZ_MAX_PLAYERS" => "350",
       "DIFF_ROUNDS" => "3",
       "DIFF_ALTS" => "3",
       "PAIRING_FUZZ_BYE_PCT" => "3",
       "PAIRING_FUZZ_FORFEIT_PCT" => "2",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "1",
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed"
     }},
    {"e_350_600_r2", 90,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "350",
       "PAIRING_FUZZ_MAX_PLAYERS" => "600",
       "DIFF_ROUNDS" => "2",
       "DIFF_ALTS" => "2",
       "PAIRING_FUZZ_BYE_PCT" => "3",
       "PAIRING_FUZZ_FORFEIT_PCT" => "2",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "1",
       "PAIRING_FUZZ_ACCEL" => "mixed"
     }}
  ]

  def set("small"), do: @small
  def set("flags"), do: @flags
  def set("large"), do: @large
  def set("early"), do: @early

  def run(name, dir, run_axis) do
    File.mkdir_p!(dir)

    only =
      case System.get_env("DIFF_AXES") do
        nil -> nil
        list -> String.split(list, ",", trim: true)
      end

    set(name)
    |> Enum.with_index()
    |> Enum.filter(fn {{axis, _, _}, _} -> only == nil or axis in only end)
    |> Enum.each(fn {{axis, count, env}, index} ->
      env = Map.merge(@base, env)
      previous = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)
      Enum.each(env, fn {k, v} -> System.put_env(k, v) end)
      # Seeds are disjoint between axes and between sets.
      offset =
        %{"small" => 0, "flags" => 5_000_000, "large" => 9_000_000, "early" => 12_000_000}[name]
      seed_from = offset + index * 100_000 + 1
      count = min(count, PerfDiff.int("DIFF_LIMIT", count))

      try do
        case PerfDiff.int("DIFF_CHUNK", 0) do
          0 ->
            run_axis.(axis, seed_from, count, Path.join(dir, axis <> ".log"))

          chunk ->
            for first <- seed_from..(seed_from + count - 1)//chunk do
              out = Path.join(dir, "#{axis}.#{first}.log")
              n = min(chunk, seed_from + count - first)

              unless File.exists?(out) do
                run_axis.(axis, first, n, out <> ".tmp")
                File.rename!(out <> ".tmp", out)
                if File.exists?(out <> ".tmp.stats"), do: File.rename!(out <> ".tmp.stats", out <> ".stats")
              end
            end
        end
      after
        Enum.each(previous, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end
    end)
  end
end

run_axis = fn axis, seed_from, count, out ->
  rounds = PerfDiff.int("DIFF_ROUNDS", 9)
  alts_pct = PerfDiff.int("DIFF_ALTS", 25)
  extras? = System.get_env("DIFF_EXTRAS", "1") != "0"

  range =
    PerfDiff.int("PAIRING_FUZZ_MIN_PLAYERS", 4)..PerfDiff.int("PAIRING_FUZZ_MAX_PLAYERS", 40)

  Ainalrami.Log.set_level(:quiet)
  Application.put_env(:ainalrami, :log_level, :quiet)
  File.rm(out)
  file = File.open!(out, [:append, :utf8])
  started = System.monotonic_time(:millisecond)

  {total, stats} =
    seed_from..(seed_from + count - 1)
    |> Task.async_stream(
      fn seed -> PerfDiff.run(seed, rounds, range, alts_pct, extras?) end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce({0, %{}}, fn {:ok, {lines, stats}}, {n, acc} ->
      for line <- lines, do: IO.write(file, Enum.join([axis | line], "\t") <> "\n")
      {n + length(lines), Map.merge(acc, stats, fn _k, a, b -> a + b end)}
    end)

  File.close(file)
  secs = (System.monotonic_time(:millisecond) - started) / 1000
  IO.puts("#{axis}: #{count} tournaments, #{total} rounds in #{Float.round(secs, 1)} s -> #{out}")

  # AINALRAMI_CERT_STATS=1: the certified-shortcut counters of the pairing
  # calls made in the tournament workers (alternatives run in tasks of their
  # own and are not counted), next to the log.
  if stats != %{} do
    File.write!(out <> ".stats", inspect(Enum.sort(stats), limit: :infinity, pretty: true) <> "\n")
  end
end

case System.argv() do
  ["corpus", name, dir] ->
    PerfDiff.Corpus.run(name, dir, run_axis)

  ["compare", a, b] ->
    # Two log files, or two directories of them (matched by file name).
    files = fn path ->
      if File.dir?(path),
        do: path |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".log")) |> Enum.sort(),
        else: [nil]
    end

    join = fn dir, nil -> dir; dir, name -> Path.join(dir, name) end

    read = fn path ->
      files.(path)
      |> Enum.map(&join.(path, &1))
      |> Enum.flat_map(&File.stream!/1)
      |> Stream.map(&String.trim_trailing/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        [axis, seed, round | rest] = String.split(line, "\t")
        {{axis, String.to_integer(seed), String.to_integer(round)}, rest}
      end)
      |> Map.new()
    end

    right = read.(b)

    left =
      if System.get_env("DIFF_SUBSET") == "1",
        do: Map.take(read.(a), Map.keys(right)),
        else: read.(a)

    keys = Map.keys(left) |> MapSet.new() |> MapSet.union(MapSet.new(Map.keys(right)))

    {same, differ, missing} =
      Enum.reduce(keys, {0, [], []}, fn key, {same, differ, missing} ->
        case {Map.get(left, key), Map.get(right, key)} do
          {x, x} -> {same + 1, differ, missing}
          {nil, _} -> {same, differ, [key | missing]}
          {_, nil} -> {same, differ, [key | missing]}
          {x, y} -> {same, [{key, x, y} | differ], missing}
        end
      end)

    rounds_with_alts = Enum.count(left, fn {_k, v} -> List.last(v) != "-" end)
    by_axis = left |> Map.keys() |> Enum.frequencies_by(&elem(&1, 0))

    IO.puts("rounds identical: #{same}")
    IO.puts("rounds with alternatives fingerprinted: #{rounds_with_alts}")
    IO.puts("rounds per axis: #{inspect(Enum.sort(by_axis))}")
    IO.puts("rounds differing: #{length(differ)}")
    IO.puts("rounds missing on one side: #{length(missing)}")

    for {key, x, y} <- differ |> Enum.sort() |> Enum.take(30) do
      IO.puts("  DIFF #{inspect(key)}\n    #{Enum.join(x, " ")}\n    #{Enum.join(y, " ")}")
    end

    for key <- missing |> Enum.sort() |> Enum.take(30), do: IO.puts("  MISSING #{inspect(key)}")
    if differ != [] or missing != [], do: System.halt(1)

  _ ->
    run_axis.(
      System.get_env("DIFF_AXIS", "axis"),
      PerfDiff.int("DIFF_SEED_FROM", 1),
      PerfDiff.int("DIFF_COUNT", 200),
      System.get_env("DIFF_OUT", "perf_diff.log")
    )
end

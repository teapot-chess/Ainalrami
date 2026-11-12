# Where the weighted matcher's time goes, by call site
# (`Ainalrami.WeightedMatching.Profile`; docs/performance.md, "The blossom
# fallback").
#
#   # the timing study's positions (tools/timing_study.exs), second call of each
#   MIX_ENV=test elixir --erl "+S 1" -S mix run tools/matching_profile.exs positions 1:3
#   MIX_ENV=test elixir --erl "+S 1" -S mix run tools/matching_profile.exs positions 1000:9:8971000,600:9:8070600
#
#   # a corpus set of tools/perf_diff.exs (DIFF_LIMIT etc. as there), every call
#   DIFF_LIMIT=30 MIX_ENV=test elixir --erl "+S 1" -S mix run tools/matching_profile.exs corpus small DIR
#
# One scheduler keeps the per-call times honest: with more, a call's wall
# time includes whatever else ran on its scheduler. Prints the share of the
# measured time spent in `new/3` and `solve/1`, then each call site's
# calls and milliseconds, then the same by site and size bucket with the
# graph sizes, stages, grow steps and blossoms. AINALRAMI_WM_CAPTURE=<file>
# also writes every call's inputs, for replaying the matcher offline.

alias Ainalrami.WeightedMatching.Profile

defmodule MatchingProfile do
  alias Ainalrami.WeightedMatching.Profile

  def report(total_us) do
    rows = Profile.dump()
    maxes = for {{:max_n, k}, m} <- rows, into: %{}, do: {k, m}

    main =
      for {{what, _, _} = k, c, us, sn, se, st, gr, fo, ex, big} <- rows,
          what in [:new, :solve],
          do: {k, c, us, sn, se, st, gr, fo, ex, big, Map.get(maxes, k)}

    wm_us = main |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    IO.puts(
      "measured: #{div(total_us, 1000)} ms; in WeightedMatching new/3 + solve/1: " <>
        "#{div(wm_us, 1000)} ms (#{Float.round(100 * wm_us / max(total_us, 1), 1)}%)"
    )

    main
    |> Enum.group_by(fn {{what, site, _}, _, _, _, _, _, _, _, _, _, _} -> {what, site} end)
    |> Enum.map(fn {k, rs} ->
      {k, rs |> Enum.map(&elem(&1, 1)) |> Enum.sum(), rs |> Enum.map(&elem(&1, 2)) |> Enum.sum()}
    end)
    |> Enum.sort_by(&(-elem(&1, 2)))
    |> Enum.each(fn {{what, {ctx, {m, f, a}}}, c, us} ->
      IO.puts(
        String.pad_leading("#{div(us, 1000)}", 9) <>
          " ms " <>
          String.pad_leading("#{c}", 9) <>
          " calls  #{what} #{ctx} #{m |> inspect() |> String.replace("Ainalrami.", "")}.#{f}/#{a}"
      )
    end)

    IO.puts(
      "\nby site and size: ms, calls, mean and largest n, mean edges, stages, grow " <>
        "steps, blossoms formed and expanded per call, calls on weights past 60 bits"
    )

    main
    |> Enum.sort_by(&(-elem(&1, 2)))
    |> Enum.take(40)
    |> Enum.each(fn {{what, {ctx, {_m, f, _a}}, b}, c, us, sn, se, st, gr, fo, ex, big, mx} ->
      IO.puts(
        Enum.join(
          [
            String.pad_leading("#{div(us, 1000)}", 8),
            String.pad_leading("#{c}", 8),
            "#{what}/#{ctx}/#{f} n<=#{b}",
            "n=#{div(sn, c)}",
            "max=#{mx}",
            "e=#{div(se, c)}",
            "st=#{Float.round(st / c, 1)}",
            "gr=#{Float.round(gr / c, 1)}",
            "fo=#{Float.round(fo / c, 1)}",
            "ex=#{Float.round(ex / c, 2)}",
            "big=#{big}"
          ],
          " "
        )
      )
    end)
  end

  def cases(spec) do
    case String.split(spec, ":") do
      [a, b] ->
        sizes = [100, 101, 200, 201, 400, 401, 600, 601, 1000, 1001]

        for s <- String.to_integer(a)..String.to_integer(b),
            n <- sizes,
            r <- [2, 5, 9],
            do: {n, r, 8_000_000 + s * 10_000 + n}

      _ ->
        spec
        |> String.split(",", trim: true)
        |> Enum.map(fn c ->
          c |> String.split(":") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
        end)
    end
  end
end

Ainalrami.Log.set_level(:quiet)
Application.put_env(:ainalrami, :log_level, :quiet)

case System.argv() do
  ["positions", spec] ->
    import Ainalrami.Test.FuzzTournament
    alias Ainalrami.Pairing

    pair = fn ps, rounds, forbidden ->
      Pairing.pair_next_round(ps,
        expected_rounds: rounds,
        forbidden_pairs: forbidden,
        initial_colour: String.downcase(initial_colour()),
        point_system: point_system()
      )
    end

    position = fn n, target, seed ->
      {rounds, pc, forbidden, roster} = begin!(seed, 9, n..n)

      ps =
        Enum.reduce(1..(target - 1)//1, roster, fn round, ps ->
          withdraw_some(round, pc)
          ps = assign_requested_byes(ps)
          p = pair.(ps, rounds, forbidden)
          apply_round(ps, p, simulate_results(p))
        end)

      withdraw_some(target, pc)
      {assign_requested_byes(ps), rounds, forbidden}
    end

    Profile.set(false)
    cases = MatchingProfile.cases(spec)

    total =
      Enum.reduce(cases, 0, fn {n, r, seed}, acc ->
        {ps, rounds, forbidden} = position.(n, r, seed)
        _ = pair.(ps, rounds, forbidden)
        Profile.set(true)
        {us, _} = :timer.tc(fn -> pair.(ps, rounds, forbidden) end)
        Profile.set(false)
        acc + us
      end)

    IO.puts("positions: #{length(cases)}")
    MatchingProfile.report(total)
    Profile.flush()

  ["corpus", set, dir] ->
    Profile.set(true)
    {rt0, _} = :erlang.statistics(:runtime)
    System.argv(["corpus", set, dir])
    Code.require_file("tools/perf_diff.exs")
    {rt1, _} = :erlang.statistics(:runtime)
    MatchingProfile.report((rt1 - rt0) * 1000)
    Profile.flush()

  _ ->
    IO.puts("usage: see the header of tools/matching_profile.exs")
end

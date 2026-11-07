defmodule AinalramiLab.Simulate do
  @moduledoc """
  Replay a corpus under a baseline and a variant and measure the
  difference.

  Two kinds of corpus:

    * **generated** (`AinalramiLab.Tournament`): each tournament is played
      twice from the same seed, once per arm, and measured with
      `AinalramiLab.Metrics`. Along the baseline's trajectory every
      position is also paired under the variant, which counts how often
      the variant changes a round *in the same position* and supplies
      the example diffs.
    * **TRF files**: every recorded round of every file is a position
      (the history before it, plus any requested byes already entered for
      it). Each is paired under both arms and compared. A file has only
      one history, so there are no trajectory metrics for it, only
      position-level ones.

  Both arms always use the same pairer, so a difference is the rule
  change's and not the pairer's.
  """

  alias AinalramiLab.{Metrics, Pairer, Stats, Tournament, Variant}
  alias AinalramiVerify.{Position, Trf, TrfWriter}

  @doc """
  Options: `:variant` and `:baseline` (`AinalramiLab.Variant`),
  `:corpus` (`{:generated, %Tournament{}, count}` or `{:trf, [path]}`),
  `:pairer`, `:seed`, `:workers`, `:examples` (how many to keep).
  Returns the report map (`AinalramiLab.Report` prints it).
  """
  def run(opts) do
    v = Keyword.fetch!(opts, :variant)
    base = Keyword.get(opts, :baseline, Variant.baseline())
    pairer = Keyword.get(opts, :pairer, :auto)
    seed = Keyword.get(opts, :seed, 1)
    workers = Keyword.get(opts, :workers, System.schedulers_online())
    keep = Keyword.get(opts, :examples, 5)
    t0 = System.monotonic_time(:millisecond)

    report =
      case Keyword.fetch!(opts, :corpus) do
        {:generated, spec, count} ->
          generated(spec, count, base, v, pairer, seed, workers, keep)

        {:trf, paths} ->
          trf_corpus(paths, base, v, pairer, workers, keep)
      end

    Map.merge(report, %{
      variant: v.name,
      variant_described: Variant.describe(v),
      baseline: base.name,
      pairer: pairer,
      seed: seed,
      seconds: div(System.monotonic_time(:millisecond) - t0, 1000),
      engine: AinalramiVerify.Engine.version()
    })
  end

  # ---------------------------------------------------------------------------
  # Generated tournaments

  defp generated(spec, count, base, v, pairer, seed, workers, keep) do
    per =
      1..count
      |> Task.async_stream(fn i -> one(spec, {seed, i}, base, v, pairer, keep) end,
        max_concurrency: workers,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, r} -> r end)

    both = Enum.filter(per, &(&1.base_ended == :complete and &1.var_ended == :complete))

    metrics =
      Map.new(Metrics.names(), fn name ->
        a = Enum.map(both, & &1.base_metrics[name])
        b = Enum.map(both, & &1.var_metrics[name])

        {name,
         %{baseline: Stats.mean_ci(a), variant: Stats.mean_ci(b), diff: Stats.paired_diff(a, b)}}
      end)

    positions = Enum.sum(Enum.map(per, & &1.positions))
    differ = Enum.sum(Enum.map(per, & &1.differ_pairs))
    colours = Enum.sum(Enum.map(per, & &1.differ_colours))
    boards_changed = Enum.sum(Enum.map(per, & &1.boards_changed))

    %{
      corpus: %{
        kind: :generated,
        players: spec.players,
        rounds: spec.rounds,
        absent: spec.absent,
        forfeit: spec.forfeit,
        late: spec.late,
        tournaments: count
      },
      tournaments: count,
      compared: length(both),
      ended_early: %{
        baseline: Enum.count(per, &(&1.base_ended != :complete)),
        variant: Enum.count(per, &(&1.var_ended != :complete))
      },
      metrics: metrics,
      positions: %{
        compared: positions,
        pairs_differ: Stats.wilson(differ, positions),
        colours_only_differ: Stats.wilson(colours, positions),
        boards_changed_per_differing_round:
          if(differ > 0, do: boards_changed / differ, else: 0.0),
        refused: %{
          baseline_only: Enum.sum(Enum.map(per, & &1.refused_base_only)),
          variant_only: Enum.sum(Enum.map(per, & &1.refused_var_only))
        }
      },
      examples: per |> Enum.flat_map(& &1.examples) |> Enum.take(keep)
    }
  end

  defp one(spec, seed, base, v, pairer, keep) do
    b = Tournament.play(spec, pairer, base, seed)

    # The variant on the baseline's own positions.
    side =
      Enum.map(b.rounds, fn rec ->
        r =
          if length(rec.pos.pool) < 2,
            do: {:error, :no_legal_pairing},
            else: Pairer.pair(pairer, rec.pos, rec.trf, v)

        {rec, r}
      end)

    cache = Map.new(side, fn {rec, r} -> {rec.trf, r} end)
    w = Tournament.play(spec, pairer, v, seed, cache)

    cmp = Enum.map(side, fn {rec, r} -> {rec, compare(rec.result, r)} end)

    examples =
      cmp
      |> Enum.filter(fn {_, c} -> c in [:pairs, :colours] end)
      |> Enum.take(keep)
      |> Enum.map(fn {rec, kind} ->
        {_, vr} = Enum.find(side, fn {r2, _} -> r2 == rec end)
        example(rec.trf, rec.round, kind, rec.result, vr)
      end)

    %{
      base_ended: b.ended,
      var_ended: w.ended,
      base_metrics: Metrics.tournament(spec, b),
      var_metrics: Metrics.tournament(spec, w),
      positions: Enum.count(cmp, fn {_, c} -> c != :both_refused end),
      differ_pairs: Enum.count(cmp, fn {_, c} -> c == :pairs end),
      differ_colours: Enum.count(cmp, fn {_, c} -> c == :colours end),
      boards_changed:
        Enum.sum(
          for {{rec, c}, {_, vr}} <- Enum.zip(cmp, side), c == :pairs do
            boards_changed(rec.result, vr)
          end
        ),
      refused_base_only: Enum.count(cmp, fn {_, c} -> c == :base_refused end),
      refused_var_only: Enum.count(cmp, fn {_, c} -> c == :var_refused end),
      examples: examples
    }
  end

  @doc "Compare two answers for one position."
  def compare({:ok, a}, {:ok, b}) do
    cond do
      boards(a) != boards(b) -> :pairs
      Enum.sort(a.pairs) != Enum.sort(b.pairs) -> :colours
      true -> :same
    end
  end

  def compare({:error, _}, {:error, _}), do: :both_refused
  def compare({:error, _}, {:ok, _}), do: :base_refused
  def compare({:ok, _}, {:error, _}), do: :var_refused

  defp boards(%{pairs: pairs, bye: bye}),
    do: {pairs |> Enum.map(fn {a, b} -> Enum.sort([a, b]) end) |> Enum.sort(), bye}

  defp boards_changed({:ok, a}, {:ok, b}) do
    {pa, _} = boards(a)
    {pb, _} = boards(b)
    length(pa -- pb)
  end

  defp boards_changed(_, _), do: 0

  defp example(trf, round, kind, {:ok, a}, {:ok, b}) do
    %{
      round: round,
      kind: kind,
      trf: trf,
      baseline: %{pairs: a.pairs, bye: a.bye},
      variant: %{pairs: b.pairs, bye: b.bye}
    }
  end

  # ---------------------------------------------------------------------------
  # TRF files

  defp trf_corpus(paths, base, v, pairer, workers, keep) do
    positions =
      paths
      |> Enum.flat_map(fn path ->
        try do
          positions_of(File.read!(path)) |> Enum.map(&Map.put(&1, :file, path))
        rescue
          _ in [Trf.Error, ArgumentError, KeyError, MatchError] -> []
        end
      end)

    per =
      positions
      |> Task.async_stream(
        fn p ->
          a = Pairer.pair(pairer, p.pos, p.trf, base)
          b = Pairer.pair(pairer, p.pos, p.trf, v)
          {p, a, b, compare(a, b)}
        end,
        max_concurrency: workers,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, r} -> r end)

    n = Enum.count(per, fn {_, _, _, c} -> c != :both_refused end)
    differ = Enum.count(per, fn {_, _, _, c} -> c == :pairs end)
    colours = Enum.count(per, fn {_, _, _, c} -> c == :colours end)

    %{
      corpus: %{
        kind: :trf,
        files: length(paths),
        files_read: positions |> Enum.map(& &1.file) |> Enum.uniq() |> length()
      },
      positions: %{
        compared: n,
        pairs_differ: Stats.wilson(differ, n),
        colours_only_differ: Stats.wilson(colours, n),
        boards_changed_per_differing_round:
          if(differ > 0,
            do: Enum.sum(for {_, a, b, :pairs} <- per, do: boards_changed(a, b)) / differ,
            else: 0.0
          ),
        refused: %{
          baseline_only: Enum.count(per, fn {_, _, _, c} -> c == :base_refused end),
          variant_only: Enum.count(per, fn {_, _, _, c} -> c == :var_refused end)
        }
      },
      examples:
        per
        |> Enum.filter(fn {_, _, _, c} -> c in [:pairs, :colours] end)
        |> Enum.take(keep)
        |> Enum.map(fn {p, a, b, c} ->
          example(p.trf, p.round, c, a, b) |> Map.put(:file, p.file)
        end)
    }
  end

  @doc """
  Every recorded round of a TRF as a position to pair: `[%{round:, trf:,
  pos:}]`, the TRF rewritten with only the history before the round (and
  any requested byes entered for it).
  """
  def positions_of(text) do
    trf = Trf.parse(text)
    ranks = trf.players |> Map.keys() |> Enum.sort()
    n = List.last(ranks)

    if ranks != Enum.to_list(1..n), do: raise(ArgumentError, "starting ranks are not 1..n")

    last =
      trf.players
      |> Map.values()
      |> Enum.flat_map(fn p -> for {r, g} <- p.games, g.opponent != nil, do: r end)
      |> Enum.max(fn -> 0 end)

    rounds = max(trf.rounds || last, last)
    initial = Position.build(trf, max(last, 1) + 1).initial_colour

    for t <- 1..last//1 do
      hist =
        for r <- 1..t//1 do
          for {rank, p} <- trf.players,
              g = p.games[r],
              g != nil,
              r < t or (g.opponent == nil and g.code in ["H", "Z", "F", "-"]),
              into: %{} do
            {rank, {g.opponent, g.colour, g.code}}
          end
        end

      hist = if List.last(hist) == %{}, do: Enum.drop(hist, -1), else: hist
      out = TrfWriter.write(n, hist, rounds, initial_colour: initial)
      %{round: t, trf: out, pos: out |> Trf.parse() |> Position.build(t)}
    end
  end
end

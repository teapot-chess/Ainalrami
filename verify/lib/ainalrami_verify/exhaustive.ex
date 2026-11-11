defmodule AinalramiVerify.Exhaustive do
  @moduledoc """
  Part 3: every reachable tournament, up to `n` players and `r` rounds.

  The tree: round 1 of `n` players is paired; every combination of results
  (`1-0`, `½-½`, `0-1` on each board; the bye scores its point) is a child
  history; each child's next round is paired, and so on to round `r`,
  which is the final round (`XXR r`, so 1.8's topscorers and [C10]/[C11]
  are in play there). At every node the engine's round and the reference's
  (`AinalramiVerify.Bracket.pair/1`, brute force by the rules) are
  compared: boards, the bye, and colours. The walk follows the engine's
  pairing, so it covers exactly the positions the engine can reach.

  ## Symmetry reduction

    * Colours: the initial colour is fixed to White (`152 W`). Black is
      the mirror image: every colour flips, nothing else changes.
    * Positions: two histories that agree on everything C.04.3 reads -
      every player's score, colour sequence, opponents, [C2] status,
      unplayed rounds and floats in the last two rounds - pair the same
      way and have the same subtree, so a position is visited once per
      job (see below). The count of positions reached *before* this
      merging is reported too.
    * Results: `--results=wl` leaves draws out, for a decisive-only run.

  ## Jobs, resuming, parallelism

  The tree is cut at round `split` (default 2): each history of that length
  is a job, the jobs are walked in parallel (`Task.async_stream/3`), and
  each finished job is appended to `DIR/done.log`. A run restarted on the
  same directory with the same parameters skips the jobs in the log.
  Disagreements are written to `DIR/disagreements/` as TRF plus a text
  file with both rounds.
  """

  alias AinalramiVerify.{Bracket, Engine, Position, RuleCheck, Trf, TrfWriter}

  @doc """
  Run. Options: `:players`, `:rounds`, `:dir`, `:workers`
  (default: schedulers online), `:split` (default 2), `:results` (`"wdl"`
  or `"wl"`), `:max_jobs` (stop after this many new jobs; for timing).
  Returns the summary map, also written to `DIR/summary.json`.
  """
  def run(opts) do
    n = Keyword.fetch!(opts, :players)
    rounds = Keyword.fetch!(opts, :rounds)
    dir = Keyword.fetch!(opts, :dir)
    split = min(Keyword.get(opts, :split, 2), rounds - 1) |> max(0)
    workers = Keyword.get(opts, :workers, System.schedulers_online())
    results = results_alphabet(Keyword.get(opts, :results, "wdl"))
    log = Keyword.get(opts, :log, &IO.puts/1)

    File.mkdir_p!(Path.join(dir, "disagreements"))

    params = %{
      "players" => n,
      "rounds" => rounds,
      "split" => split,
      "results" => Keyword.get(opts, :results, "wdl")
    }

    check_params!(dir, params)

    t0 = System.monotonic_time(:millisecond)
    # The prefix: every node above the split, compared here, and the
    # histories at the split, which are the jobs.
    {jobs, prefix} = expand_prefix(n, rounds, split, results, dir)
    done = read_done(dir)
    todo = jobs |> Enum.with_index() |> Enum.reject(fn {_, i} -> Map.has_key?(done, i) end)
    todo = if m = opts[:max_jobs], do: Enum.take(todo, m), else: todo

    log.(
      "#{n} players, #{rounds} rounds: #{length(jobs)} jobs, #{map_size(done)} already done, #{length(todo)} to run on #{workers} workers"
    )

    done_log = File.open!(Path.join(dir, "done.log"), [:append, :binary])

    new =
      todo
      |> Task.async_stream(fn {hist, i} -> {i, walk_job(n, rounds, hist, results, dir, i)} end,
        max_concurrency: workers,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce(%{}, fn {:ok, {i, c}}, acc ->
        IO.binwrite(done_log, encode_done(i, c))
        k = map_size(acc) + 1
        if rem(k, max(div(length(todo), 20), 1)) == 0, do: log.("  #{k}/#{length(todo)} jobs")
        Map.put(acc, i, c)
      end)

    File.close(done_log)
    all = Map.merge(done, new)
    total = Enum.reduce(Map.values(all), prefix, &add/2)

    summary =
      Map.merge(params, %{
        "jobs" => length(jobs),
        "jobs_done" => map_size(all),
        "complete" => map_size(all) == length(jobs),
        "positions" => total.positions,
        "reached" => total.reached,
        "agree" => total.agree,
        "disagree" => total.disagree,
        "refused_both" => total.refused_both,
        "seconds_this_run" => div(System.monotonic_time(:millisecond) - t0, 1000),
        "engine" => Engine.version()
      })

    File.write!(Path.join(dir, "summary.json"), JSON.encode!(summary))
    summary
  end

  defp results_alphabet("wdl"), do: ["1", "=", "0"]
  defp results_alphabet("wl"), do: ["1", "0"]

  defp check_params!(dir, params) do
    path = Path.join(dir, "params.json")

    case File.read(path) do
      {:ok, text} ->
        if JSON.decode!(text) != params,
          do: raise(ArgumentError, "#{dir} holds a run with other parameters: #{text}")

      _ ->
        File.write!(path, JSON.encode!(params))
    end
  end

  defp zero, do: %{positions: 0, reached: 0, agree: 0, disagree: 0, refused_both: 0}

  defp add(a, b), do: Map.merge(a, b, fn _, x, y -> x + y end)

  defp expand_prefix(n, rounds, split, results, dir) do
    Enum.reduce(0..(split - 1)//1, {[[]], zero()}, fn _depth, {hists, counts} ->
      Enum.reduce(hists, {[], counts}, fn hist, {next, counts} ->
        {c, children} = visit(n, rounds, hist, results, dir, "prefix")
        {next ++ children, add(counts, c)}
      end)
    end)
  end

  # Depth-first under one job, merging positions seen before in this job.
  defp walk_job(n, rounds, hist, results, dir, id) do
    {counts, _seen} = walk(n, rounds, hist, results, dir, "job#{id}", MapSet.new(), zero())
    counts
  end

  defp walk(n, rounds, hist, results, dir, tag, seen, counts) do
    if length(hist) >= rounds do
      {counts, seen}
    else
      trf = TrfWriter.write(n, hist, rounds)
      key = position_key(trf)
      counts = %{counts | reached: counts.reached + 1}

      if MapSet.member?(seen, key) do
        {counts, seen}
      else
        seen = MapSet.put(seen, key)
        {c, children} = visit(n, rounds, hist, results, dir, tag, trf)
        counts = add(counts, %{c | reached: 0})

        Enum.reduce(children, {counts, seen}, fn child, {counts, seen} ->
          walk(n, rounds, child, results, dir, tag, seen, counts)
        end)
      end
    end
  end

  defp visit(n, rounds, hist, results, dir, tag, trf \\ nil) do
    trf = trf || TrfWriter.write(n, hist, rounds)
    {verdict, engine} = compare(trf)

    counts =
      case verdict do
        :agree -> %{zero() | positions: 1, reached: 1, agree: 1}
        :refused_both -> %{zero() | positions: 1, reached: 1, refused_both: 1}
        {:disagree, _} -> %{zero() | positions: 1, reached: 1, disagree: 1}
      end

    if match?({:disagree, _}, verdict), do: dump(dir, tag, trf, verdict)

    children =
      case engine do
        {:ok, round} when length(hist) + 1 < rounds -> children(hist, round, results)
        _ -> []
      end

    {counts, children}
  end

  @doc """
  Compare the engine and the reference on one TRF. Returns
  `{:agree | :refused_both | {:disagree, detail}, engine_result}`.
  """
  def compare(trf) do
    engine = Engine.pair(trf)
    pos = trf |> Trf.parse() |> Position.build()
    ref = Bracket.pair(pos)

    verdict =
      case {engine, ref} do
        {{:error, _}, {:error, _}} ->
          :refused_both

        {{:ok, e}, {:ok, r}} ->
          cond do
            boards(e) != boards(r) ->
              {:disagree, %{kind: :pairs, engine: e, reference: r}}

            Enum.sort(e.pairs) != Enum.sort(r.pairs) ->
              {:disagree, %{kind: :colours, engine: e, reference: r}}

            true ->
              :agree
          end

        _ ->
          {:disagree, %{kind: :refusal, engine: engine, reference: ref}}
      end

    {verdict, engine}
  end

  defp boards(%{pairs: pairs, bye: bye}),
    do: {pairs |> Enum.map(fn {a, b} -> Enum.sort([a, b]) end) |> Enum.sort(), bye}

  defp children(hist, %{pairs: pairs, bye: bye}, results) do
    boards = pairs

    combos =
      Enum.reduce(boards, [%{}], fn {w, b}, acc ->
        for m <- acc, res <- results do
          m
          |> Map.put(w, {b, :w, res})
          |> Map.put(b, {w, :b, invert(res)})
        end
      end)

    combos =
      if bye,
        do: Enum.map(combos, &Map.put(&1, bye, {nil, nil, "U"})),
        else: combos

    Enum.map(combos, &(hist ++ [&1]))
  end

  defp invert("1"), do: "0"
  defp invert("0"), do: "1"
  defp invert("="), do: "="

  @doc """
  What C.04.3 reads of a position, for merging: per player the score,
  colour sequence, opponents, [C2] status, unplayed rounds and the floats
  of the last two rounds, plus the round number.
  """
  def position_key(trf) do
    pos = trf |> Trf.parse() |> Position.build()

    players =
      for rank <- Enum.sort(Map.keys(pos.players)) do
        p = pos.players[rank]

        {p.score, p.colours, Enum.sort(MapSet.to_list(p.opponents)), p.bye_ineligible?,
         p.unplayed, Map.get(p.float, pos.round - 1), Map.get(p.float, pos.round - 2)}
      end

    :erlang.md5(:erlang.term_to_binary({pos.round, pos.pool, players}))
  end

  defp dump(dir, tag, trf, {:disagree, detail}) do
    d = Path.join(dir, "disagreements")
    existing = d |> File.ls!() |> length()

    if existing < 400 do
      name = "#{tag}-#{:erlang.phash2(trf)}"
      File.write!(Path.join(d, name <> ".trf"), trf)

      pos = trf |> Trf.parse() |> Position.build()

      verdicts =
        case detail.engine do
          {:ok, e} -> RuleCheck.check(pos, e) |> RuleCheck.format()
          %{pairs: _} = e -> RuleCheck.check(pos, e) |> RuleCheck.format()
          other -> inspect(other)
        end

      File.write!(
        Path.join(d, name <> ".txt"),
        "kind: #{detail.kind}\nengine:    #{inspect(detail.engine)}\nreference: #{inspect(detail.reference)}\n\n" <>
          "rule check of the engine's round:\n#{verdicts}\n"
      )
    end
  end

  defp read_done(dir) do
    case File.read(Path.join(dir, "done.log")) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line) do
            [i, p, r, a, d, rb] ->
              [
                {String.to_integer(i),
                 %{
                   positions: int(p),
                   reached: int(r),
                   agree: int(a),
                   disagree: int(d),
                   refused_both: int(rb)
                 }}
              ]

            _ ->
              []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp int(s), do: String.to_integer(s)

  defp encode_done(i, c),
    do: "#{i} #{c.positions} #{c.reached} #{c.agree} #{c.disagree} #{c.refused_both}\n"

  @doc """
  Random walks instead of the whole tree, for sizes the tree is too big
  for: `walks` paths from round 1 to round `rounds`, results drawn
  uniformly, every node compared. Options as `run/1` plus `:walks` and
  `:seed`.
  """
  def sample(opts) do
    n = Keyword.fetch!(opts, :players)
    rounds = Keyword.fetch!(opts, :rounds)
    dir = Keyword.fetch!(opts, :dir)
    walks = Keyword.fetch!(opts, :walks)
    seed = Keyword.get(opts, :seed, 1)
    workers = Keyword.get(opts, :workers, System.schedulers_online())
    results = results_alphabet(Keyword.get(opts, :results, "wdl"))
    File.mkdir_p!(Path.join(dir, "disagreements"))

    total =
      1..walks
      |> Task.async_stream(
        fn w ->
          :rand.seed(:exsss, {seed, w, 7})

          Enum.reduce_while(1..rounds, {[], zero()}, fn _, {hist, counts} ->
            {c, children} = visit(n, rounds, hist, results, dir, "walk#{seed}-#{w}")
            counts = add(counts, c)

            case children do
              [] -> {:halt, {hist, counts}}
              list -> {:cont, {Enum.random(list), counts}}
            end
          end)
          |> elem(1)
        end,
        max_concurrency: workers,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce(zero(), fn {:ok, c}, acc -> add(acc, c) end)

    summary =
      %{
        "players" => n,
        "rounds" => rounds,
        "walks" => walks,
        "seed" => seed,
        "positions" => total.positions,
        "agree" => total.agree,
        "disagree" => total.disagree,
        "refused_both" => total.refused_both,
        "engine" => Engine.version()
      }

    File.write!(Path.join(dir, "sample-summary.json"), JSON.encode!(summary))
    summary
  end
end

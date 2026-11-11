defmodule AinalramiVerify.RuleCheck do
  @moduledoc """
  Part 2: the rules as a test. Given a position and a proposed round -
  any program's - list every article of C.04.3 (2026) the round breaks.

  In order:

    1. **Completeness** (1.9.1): every player of the pool on exactly one
       board, nobody else, at most one bye and only for an odd pool.
    2. **Absolute criteria**: [C1] and [C3] per board, [C2] for the bye.
    3. **Quality** (only for a complete, legal round): the brackets the
       round implies are rebuilt top down (1.3.2: a pair belongs to the
       bracket of its lower-scored player; whoever a bracket leaves
       unpaired is an MDP of the next). For each, every candidate is
       listed and scored (`AinalramiVerify.Bracket`), and the round's own
       candidate is compared with the best. The verdict names the FIRST
       criterion, in priority order, on which the round's candidate is
       worse - the one 3.8.1 decides on; lower criteria are moot. All
       criteria equal, a candidate Article 4 generates earlier is reported
       against 3.8.1 and Article 4. [C4] is implied by a complete legal
       round and is never reported for one.
    4. **Colours** (Article 5.2), per board, when the round says who has
       White.

  A bracket is judged with the MDPs the round itself gives it. After a
  wrong bracket, later brackets are judged on the round's own terms:
  "given that, was this bracket right?".

  Independent of the engine: the position, the legality, the criteria and
  the search are this suite's own (`AinalramiVerify.Position`, `Rules`,
  `Bracket`).
  """

  alias AinalramiVerify.{Bracket, Position, Rules}

  @type violation :: %{
          article: String.t(),
          criterion: String.t() | nil,
          bracket: integer() | nil,
          players: [pos_integer()],
          message: String.t()
        }

  @doc "The violations of `round` (`%{pairs: [{white, black}], bye: rank | nil}`) in `pos`."
  @spec check(Position.t(), map(), keyword()) :: [violation()]
  def check(%Position{} = pos, round, opts \\ []) do
    round = Map.put_new(round, :extra_byes, [])
    complete = completeness(pos, round)
    absolute = absolute(pos, round)

    quality =
      if complete == [] and absolute == [], do: quality(pos, round), else: []

    colours =
      if Keyword.get(opts, :colours, true) and complete == [] and absolute == [],
        do: colours(pos, round),
        else: []

    complete ++ absolute ++ quality ++ colours
  end

  @doc "1.9.1 and the absolute criteria only: `[]` for a complete, legal round."
  def legality(%Position{} = pos, round) do
    round = Map.put_new(round, :extra_byes, [])
    completeness(pos, round) ++ absolute(pos, round)
  end

  # 1.9.1
  defp completeness(pos, round) do
    seated =
      Enum.flat_map(round.pairs, fn {a, b} -> [a, b] end) ++
        List.wrap(round.bye) ++ round.extra_byes

    pool = MapSet.new(pos.pool)
    counts = Enum.frequencies(seated)

    twice = for {r, c} <- counts, c > 1, do: r
    missing = Enum.reject(pos.pool, &Map.has_key?(counts, &1))
    outsiders = Enum.reject(Map.keys(counts), &MapSet.member?(pool, &1))
    odd? = rem(length(pos.pool), 2) == 1

    [
      twice != [] && v("1.9.1", nil, nil, Enum.sort(twice), "on more than one board"),
      missing != [] && v("1.9.1", nil, nil, missing, "in the pool and not paired"),
      outsiders != [] &&
        v(
          "1.9.1",
          nil,
          nil,
          Enum.sort(outsiders),
          "paired but not in the pool (absent, or a bye already recorded)"
        ),
      round.extra_byes != [] &&
        v(
          "1.9.1",
          nil,
          nil,
          [round.bye | round.extra_byes],
          "more than one pairing-allocated bye"
        ),
      (odd? and round.bye == nil and missing == []) &&
        v("1.9.1", nil, nil, [], "an odd pool and no bye"),
      (not odd? and round.bye != nil) &&
        v("1.9.1", nil, nil, [round.bye], "a bye in an even pool")
    ]
    |> Enum.filter(& &1)
  end

  defp absolute(pos, round) do
    pairs =
      for {a, b} <- round.pairs,
          Map.has_key?(pos.players, a) and Map.has_key?(pos.players, b),
          {:error, c} <- [Rules.pair_check(pos, a, b)] do
        msg =
          case c do
            "C1" -> "have already played each other"
            "C3" -> "non-topscorers with the same absolute colour preference"
          end

        v(Bracket.article(c), c, nil, [a, b], msg)
      end

    bye =
      case round.bye do
        nil ->
          []

        x ->
          if Map.has_key?(pos.players, x) and not Rules.bye_eligible?(pos, x),
            do: [
              v(
                "2.1.2",
                "C2",
                nil,
                [x],
                "already had a pairing-allocated bye, or a win's points without playing"
              )
            ],
            else: []
      end

    pairs ++ bye
  end

  defp quality(pos, round) do
    ctx = Bracket.context(pos)

    try do
      ctx
      |> Bracket.structure(round.pairs)
      |> Enum.flat_map(fn {b, cand} -> judge(ctx, b, cand) end)
    after
      Bracket.cleanup(ctx)
    end
  end

  defp judge(ctx, b, cand) do
    case Bracket.evaluate(ctx, b, cand) do
      {:error, "C4"} ->
        [
          v(
            "2.2.1",
            "C4",
            b.score,
            elem(cand, 1),
            "this bracket's downfloaters leave the rest unpairable"
          )
        ]

      {:ok, mine} ->
        best = Bracket.best(ctx, b)
        my_key = Bracket.key(mine)

        cond do
          my_key > best.key ->
            c = Enum.find(Bracket.criteria(), &(mine[&1] != best.vector[&1]))
            [worse(ctx, b, cand, best, c, mine)]

          my_key == best.key and
              Bracket.sequence_key(ctx, b, cand) > Bracket.sequence_key(ctx, b, best.candidate) ->
            [
              v(
                "3.8.1 / 4",
                "order",
                b.score,
                changed(cand, best.candidate),
                "equally good on [C5]-[C21], but Article 4 generates #{show(best.candidate)} first; this round has #{show(cand)}"
              )
            ]

          true ->
            []
        end
    end
  end

  defp worse(_ctx, b, cand, best, c, mine) do
    v(
      Bracket.article(c),
      c,
      b.score,
      changed(cand, best.candidate),
      "#{c} is #{inspect(mine[c])} here and #{inspect(best.vector[c])} with #{show(best.candidate)}; this round has #{show(cand)}"
    )
  end

  # The players whose board differs between the two candidates.
  defp changed({p1, d1}, {p2, d2}) do
    s1 = MapSet.new(Enum.map(p1, &norm/1) ++ Enum.map(d1, &{:df, &1}))
    s2 = MapSet.new(Enum.map(p2, &norm/1) ++ Enum.map(d2, &{:df, &1}))

    MapSet.symmetric_difference(s1, s2)
    |> Enum.flat_map(fn
      {:df, x} -> [x]
      {a, b} -> [a, b]
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp norm({a, b}), do: if(a < b, do: {a, b}, else: {b, a})

  defp show({pairs, df}) do
    ps = Enum.map_join(pairs, " ", fn {a, b} -> "#{a}-#{b}" end)
    if df == [], do: "[#{ps}]", else: "[#{ps}; down: #{Enum.join(df, ",")}]"
  end

  defp colours(pos, round) do
    for {w, b} <- round.pairs,
        {ww, bb, art} = Rules.colours(pos, w, b),
        {ww, bb} != {w, b} do
      v(
        art,
        "colour",
        nil,
        [w, b],
        "#{ww} should have White against #{bb} (#{art}); the round gives White to #{w}"
      )
    end
  end

  defp v(article, criterion, bracket, players, message),
    do: %{
      article: article,
      criterion: criterion,
      bracket: bracket,
      players: players,
      message: message
    }

  @doc "One line per violation, or `OK`."
  def format([]), do: "OK: no article of C.04.3 is broken"

  def format(violations) do
    Enum.map_join(violations, "\n", fn x ->
      where = if x.bracket, do: " bracket #{score(x.bracket)}:", else: ""
      crit = if x.criterion, do: "[#{x.criterion}] ", else: ""
      "#{crit}#{x.article}#{where} players #{Enum.join(x.players, ",")}: #{x.message}"
    end)
  end

  defp score(half) when rem(half, 2) == 0, do: "#{div(half, 2)}.0"
  defp score(half), do: "#{div(half, 2)}.5"

  @doc "Convenience: the position of a TRF's next round."
  def position(trf_text), do: trf_text |> AinalramiVerify.Trf.parse() |> Position.build()
end

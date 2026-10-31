defmodule Ainalrami.Test.BursteinReference do
  @moduledoc """
  A brute-force reading of C.04.4.2 (Burstein, 2026) for the rounds after
  the seeding rounds, written from the rule text and sharing no code with
  `Ainalrami.Burstein`. It reads results through `Ainalrami.Trf`'s helpers
  (what a result is worth, whether it was played, how many rounds a file
  holds), which are the file format, not the pairing.

  Deliberately naive: every way of pairing a bracket - every set of pairs,
  the rest floating - is listed; [C4] is asked by trying every way of
  pairing the players left; [C7] by listing every pairing of the next
  bracket; the criteria are compared as tuples and the article's order is
  applied by sorting. Small fields only.

  Readings (`docs/conformance-c0442-burstein.md`), stated here in the open
  rather than inherited from the engine:

    * B3 - an unplayed round is a game against an opponent holding the
      player's own current score, worth the points the player was given;
    * B4 - a run of zero-point byes reaching the last round paired is seen
      by the player's real opponents as that many draws;
    * B5 - [C7] compares the next bracket's best pair count, then its best
      floater score list;
    * B6 - "higher ranked" in 5.2 is 1.8's ranking (index, then TPN);
    * B8 - "score" includes virtual points, the index does not;
    * B9 - 5.2.1's parity on the arrival numbering.
  """

  alias Ainalrami.Trf

  @doc """
  `{:ok, %{pairs: MapSet of {w, b}, bye: rank | nil}}` or
  `{:error, :no_legal_pairing | :no_legal_bye}`, for a round after the
  seeding rounds. `opts` as `Ainalrami.Burstein.pair_round/2` takes them.
  """
  def ref_round(players, opts) do
    ps = opts[:point_system] || Trf.default_point_system()
    round = Trf.rounds_played(players) + 1
    by_rank = Map.new(players, &{&1.rank, &1})
    active = Enum.filter(players, &(length(&1.games) < round))

    # Scores of the rounds before this one, real points only.
    real = fn p ->
      Enum.take(p.games, round - 1) |> Enum.map(&Trf.points_for_game(&1, ps)) |> Enum.sum()
    end

    seen =
      Map.new(players, fn p ->
        zero_run =
          p.games
          |> Enum.take(round - 1)
          |> pad(round - 1)
          |> Enum.reverse()
          |> Enum.take_while(fn g ->
            g == nil or
              (g.opponent_rank == nil and not Trf.game_was_played?(g.result) and
                 Trf.points_for_game(g, ps) == 0)
          end)
          |> length()

        {p.rank, real.(p) + zero_run * ps.draw}
      end)

    info = Map.new(active, &{&1.rank, describe(&1, round, ps, real, seen, opts)})
    forbidden = forbidden_set(opts[:forbidden_pairs], round)

    legal? = fn a, b ->
      ia = info[a]
      ib = info[b]

      a != b and not MapSet.member?(forbidden, {min(a, b), max(a, b)}) and
        not Enum.any?(by_rank[a].games, &(&1.opponent_rank == b and played?(&1))) and
        not (ia.abs? and ib.abs? and ia.pref == ib.pref)
    end

    Process.put(:burstein_ref_memo, %{})
    st = %{info: info, legal?: legal?}
    ranks = Enum.map(active, & &1.rank)

    with {:ok, bye, rest} <- ref_bye(ranks, st),
         {:ok, pairs} <- ref_brackets([], rest, st, []) do
      numbers = numbers(players, round)
      initial = if opts[:initial_colour] == "b", do: :b, else: :w
      {:ok, %{pairs: MapSet.new(pairs, &colour(info, &1, numbers, initial)), bye: bye}}
    end
  end

  defp pad(list, n), do: list ++ List.duplicate(nil, max(n - length(list), 0))

  defp played?(g),
    do: is_integer(g.opponent_rank) and Trf.game_was_played?(g.result) and g.colour in ["w", "b"]

  defp describe(p, round, ps, real, seen, _opts) do
    games = p.games |> Enum.take(round - 1) |> Enum.filter(&played?/1)
    cols = Enum.map(games, & &1.colour)
    cd = Enum.count(cols, &(&1 == "w")) - Enum.count(cols, &(&1 == "b"))
    last2 = Enum.take(cols, -2)

    {pref, strength} =
      cond do
        cols == [] -> {nil, 0}
        cd > 1 -> {"b", 3}
        cd < -1 -> {"w", 3}
        last2 == ["w", "w"] -> {"b", 3}
        last2 == ["b", "b"] -> {"w", 3}
        cd == 1 -> {"b", 2}
        cd == -1 -> {"w", 2}
        true -> {if(List.last(cols) == "w", do: "b", else: "w"), 1}
      end

    own = real.(p)

    # 1.7.1 with 1.7.2: one term per round before this one.
    terms =
      for r <- 1..(round - 1)//1 do
        g = Enum.at(p.games, r - 1)
        pts = if g, do: Trf.points_for_game(g, ps), else: 0.0
        opp = if g && played?(g), do: seen[g.opponent_rank], else: own
        {opp, pts * opp}
      end

    bh = terms |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    sb = terms |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    virtual = Enum.at(Map.get(p, :accelerations, []), round - 1) || 0.0

    c2 =
      p.games
      |> Enum.take(round - 1)
      |> Enum.any?(fn g ->
        (g.result == "U" and is_nil(g.opponent_rank)) or
          (not Trf.game_was_played?(g.result) and Trf.points_for_game(g, ps) >= ps.win)
      end)

    %{
      rank: p.rank,
      score: p.points + virtual,
      bh: bh,
      sb: sb,
      pref: pref,
      strength: strength,
      abs?: strength == 3,
      cols: cols,
      played: length(games),
      c2?: c2
    }
  end

  defp forbidden_set(nil, _round), do: MapSet.new()

  defp forbidden_set(groups, round) do
    for g <- groups,
        rs =
          (case g do
             {rs, a, b} -> if round >= a and round <= b, do: rs, else: []
             rs -> rs
           end),
        a <- rs,
        b <- rs,
        a < b,
        into: MapSet.new(),
        do: {a, b}
  end

  # 1.8: highest ranked first.
  defp rank_sort(ranks, st),
    do: Enum.sort_by(ranks, fn r -> {-st.info[r].bh, -st.info[r].sb, r} end)

  # ---- enumeration --------------------------------------------------------

  defp pairable?(ranks, legal?) do
    key = Enum.sort(ranks)
    memo = Process.get(:burstein_ref_memo)

    case Map.fetch(memo, key) do
      {:ok, v} ->
        v

      :error ->
        v = try_pair(key, legal?)
        Process.put(:burstein_ref_memo, Map.put(Process.get(:burstein_ref_memo), key, v))
        v
    end
  end

  defp try_pair([], _legal?), do: true

  defp try_pair([a | rest], legal?) do
    Enum.any?(rest, fn b -> legal?.(a, b) and try_pair(List.delete(rest, b), legal?) end)
  end

  # Every way to pair some of `ranks`, the others floating:
  # `[{pairs, floaters}]`.
  defp partials([], _legal?), do: [{[], []}]

  defp partials([a | rest], legal?) do
    floated = for {ps, fs} <- partials(rest, legal?), do: {ps, [a | fs]}

    paired =
      for b <- rest,
          legal?.(a, b),
          {ps, fs} <- partials(List.delete(rest, b), legal?),
          do: {[{a, b} | ps], fs}

    paired ++ floated
  end

  # ---- 3.1 ----------------------------------------------------------------

  defp ref_bye(ranks, st) do
    if rem(length(ranks), 2) == 0 do
      if pairable?(ranks, st.legal?), do: {:ok, nil, ranks}, else: {:error, :no_legal_pairing}
    else
      ranks
      |> Enum.reject(&st.info[&1].c2?)
      |> Enum.filter(&pairable?(List.delete(ranks, &1), st.legal?))
      |> Enum.sort_by(fn r ->
        i = st.info[r]
        # lowest score, most games, lowest ranking (smallest index, largest TPN)
        {i.score, -i.played, i.bh, i.sb, -r}
      end)
      |> case do
        [] -> {:error, :no_legal_bye}
        [b | _] -> {:ok, b, List.delete(ranks, b)}
      end
    end
  end

  # ---- 3.2 ----------------------------------------------------------------

  defp ref_brackets([], [], _st, acc), do: {:ok, acc}

  defp ref_brackets(incoming, rest, st, acc) do
    top = rest |> Enum.map(&st.info[&1].score) |> Enum.max(fn -> nil end)
    {res, lower} = Enum.split_with(rest, &(st.info[&1].score == top))
    bracket = rank_sort(incoming ++ res, st)
    next_top = lower |> Enum.map(&st.info[&1].score) |> Enum.max(fn -> nil end)
    {r2, l2} = Enum.split_with(lower, &(st.info[&1].score == next_top))

    # [C1]-[C4]: every candidate; the absolute ones are in `partials`.
    candidates =
      bracket
      |> partials(st.legal?)
      |> Enum.filter(fn {_ps, fs} -> pairable?(fs ++ lower, st.legal?) end)

    if candidates == [] do
      {:error, :no_legal_pairing}
    else
      bsn = bracket |> Enum.with_index(1) |> Map.new()
      n = length(bracket)

      scored =
        Enum.map(candidates, fn {ps, fs} = cand ->
          c5 = length(ps)
          c6 = fs |> Enum.map(&st.info[&1].score) |> Enum.sort(:desc)
          c7 = next_bracket(fs, r2, l2, st)
          c8 = Enum.count(ps, fn {a, b} -> denied?(st.info[a], st.info[b]) end)
          # smaller is better, component by component
          {{-c5, c6, c7, c8}, order_key(cand, bsn, n), cand}
        end)

      best = scored |> Enum.map(&elem(&1, 0)) |> Enum.min()

      {_q, _k, {pairs, floaters}} =
        scored
        |> Enum.filter(&(elem(&1, 0) == best))
        |> Enum.max_by(&elem(&1, 1))

      ref_brackets(floaters, lower, st, acc ++ pairs)
    end
  end

  # [C7]: how well the next bracket (the floaters and the next scoregroup)
  # can be paired - its pairs, as many as possible, then its floaters'
  # scores in descending order, as low as possible. `{-pairs, scores}`.
  defp next_bracket([], _r2, _l2, _st), do: {0, []}

  defp next_bracket(floaters, r2, l2, st) do
    (floaters ++ r2)
    |> partials(st.legal?)
    |> Enum.filter(fn {_ps, fs} -> pairable?(fs ++ l2, st.legal?) end)
    |> Enum.map(fn {ps, fs} ->
      {-length(ps), fs |> Enum.map(&st.info[&1].score) |> Enum.sort(:desc)}
    end)
    |> Enum.min()
  end

  defp denied?(a, b), do: a.pref != nil and a.pref == b.pref

  # 4.3: each BSN's opponent, BSN 1 first, 0 for a floater; larger first.
  defp order_key({pairs, _floaters}, bsn, n) do
    opp =
      Enum.reduce(pairs, %{}, fn {a, b}, m ->
        m |> Map.put(bsn[a], bsn[b]) |> Map.put(bsn[b], bsn[a])
      end)

    for i <- 1..n, do: Map.get(opp, i, 0)
  end

  # ---- 5 ------------------------------------------------------------------

  defp numbers(players, round) do
    players
    |> Enum.filter(fn p ->
      length(p.games) < round or
        p.games |> Enum.take(round - 1) |> Enum.any?(&Trf.participated_in_pairing?/1)
    end)
    |> Enum.map(& &1.rank)
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Map.new()
  end

  defp colour(info, {x, y}, numbers, initial) do
    a = info[x]
    b = info[y]
    {hi, lo} = if {-a.bh, -a.sb, a.rank} < {-b.bh, -b.sb, b.rank}, do: {a, b}, else: {b, a}

    white =
      cond do
        a.played == 0 and b.played == 0 ->
          odd = rem(numbers[hi.rank], 2) == 1
          if odd == (initial == :w), do: hi, else: lo

        a.pref == nil ->
          if b.pref == "w", do: b, else: a

        b.pref == nil ->
          if a.pref == "w", do: a, else: b

        a.pref != b.pref ->
          if a.pref == "w", do: a, else: b

        a.strength != b.strength ->
          s = if a.strength > b.strength, do: a, else: b
          if s.pref == "w", do: s, else: if(s == a, do: b, else: a)

        d =
            Enum.find(Enum.zip(Enum.reverse(a.cols), Enum.reverse(b.cols)), fn {p, q} ->
              p != q
            end) ->
          if elem(d, 0) == "b", do: a, else: b

        true ->
          if hi.pref == "w", do: hi, else: lo
      end

    if white == a, do: {a.rank, b.rank}, else: {b.rank, a.rank}
  end
end

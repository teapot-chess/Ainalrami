defmodule Ainalrami.Test.DubovReference do
  @moduledoc """
  A brute-force reading of C.04.4.1 (Dubov, 2026), written from the rule
  text and sharing no code with `Ainalrami.Dubov`. It reads results through
  `Ainalrami.Trf`'s helpers (what a result is worth, whether it was played,
  how many rounds a file holds), which are the file format, not the
  pairing.

  Deliberately naive: every subset of the lower players is a candidate
  upfloater set, every pairing of a bracket is enumerated to decide
  legality and [C7], every shift set and every transposition of G2 is
  generated and the article's order applied by sorting. Small fields only
  (brackets up to twelve players).

  The readings are the conformance document's (D1-D9) and are stated here
  in the open rather than inherited from the engine:

    * D2 - `:d2` is `:literal` (3.2.6: the first legal transposition) or
      `:c7` (the first legal transposition reaching 3.2.2's [C7]);
    * D3 - 3.2.4's second step moves players of the larger subgroup's own
      colour, not the ones the first step moved there;
    * D4 - an upfloat is a played game against a higher-scored opponent;
    * D5 - the ratings as the file holds them now;
    * D6 - [C6] is judged over legal sets of the minimal size;
    * D7 - "score" includes virtual points;
    * D9 - 5.2.1's parity on the arrival numbering.

  3.2.4's "best" shift sets are taken literally: the first set in 4.3's
  order that can be completed (second shift, transposition) to a legal
  pairing with the least [C7] any completion reaches. `ref_round/2` reports
  in `:d2_splits` how often that least [C7] - or reading (a)'s
  transposition - falls short of 3.2.2's value, which is where the two
  readings of D2 could part.
  """

  alias Ainalrami.Trf

  @doc """
  `{:ok, %{pairs: MapSet of {w, b}, bye: rank | nil, d2_splits: n}}` or
  `{:error, :no_legal_pairing | :no_legal_bye}`.
  """
  def ref_round(players, opts) do
    rounds = Keyword.fetch!(opts, :expected_rounds)
    d2 = Keyword.get(opts, :d2, :literal)
    ps = opts[:point_system] || Trf.default_point_system()
    round = Trf.rounds_played(players) + 1
    by_rank = Map.new(players, &{&1.rank, &1})
    rating = fn r -> rating(by_rank[r], opts[:provisional_ratings]) end
    active = Enum.filter(players, &(length(&1.games) < round))

    info =
      Map.new(active, fn p ->
        {p.rank, describe(p, round, by_rank, ps, rating)}
      end)

    forbidden = forbidden_set(opts[:forbidden_pairs], round)

    legal? = fn a, b ->
      ia = info[a]
      ib = info[b]

      a != b and not MapSet.member?(forbidden, {min(a, b), max(a, b)}) and
        not Enum.any?(by_rank[a].games, &(&1.opponent_rank == b and played?(&1))) and
        not (ia.abs? and ib.abs? and ia.pref == ib.pref)
    end

    st = %{
      info: info,
      legal?: legal?,
      last?: round == rounds,
      max_t: 2 + div(rounds, 5),
      d2: d2
    }

    ranks = Enum.map(active, & &1.rank)

    with {:ok, bye, rest} <- ref_bye(ranks, st) do
      case ref_brackets(rest, st, [], 0) do
        {:ok, pairs, splits} ->
          numbers = numbers(players, round)
          initial = if opts[:initial_colour] == "b", do: :b, else: :w

          coloured =
            MapSet.new(pairs, fn {x, y} -> colour(info[x], info[y], numbers, initial) end)

          {:ok, %{pairs: coloured, bye: bye, d2_splits: splits}}

        error ->
          error
      end
    end
  end

  # ---- the player ---------------------------------------------------------

  defp rating(p, provisional) do
    case p[:fide_rating] do
      r when is_integer(r) and r > 0 -> r
      _ -> Map.fetch!(provisional || %{}, p.rank)
    end
  end

  defp played?(g),
    do: is_integer(g.opponent_rank) and Trf.game_was_played?(g.result) and g.colour in ["w", "b"]

  defp accel(p, round), do: Enum.at(Map.get(p, :accelerations, []), round - 1) || 0.0

  defp before(p, round, ps) do
    (p.games |> Enum.take(round - 1) |> Enum.map(&Trf.points_for_game(&1, ps)) |> Enum.sum()) +
      accel(p, round)
  end

  defp describe(p, round, by_rank, ps, rating) do
    games = Enum.filter(p.games, &played?/1)
    cols = Enum.map(games, & &1.colour)
    cd = Enum.count(cols, &(&1 == "w")) - Enum.count(cols, &(&1 == "b"))
    last2 = Enum.take(cols, -2)

    {pref, strength} =
      cond do
        cols == [] -> {"b", 1}
        cd > 1 -> {"b", 3}
        cd < -1 -> {"w", 3}
        last2 == ["w", "w"] -> {"b", 3}
        last2 == ["b", "b"] -> {"w", 3}
        cd == 1 -> {"b", 2}
        cd == -1 -> {"w", 2}
        true -> {if(List.last(cols) == "w", do: "b", else: "w"), 1}
      end

    aro =
      case games do
        [] ->
          0

        _ ->
          total = games |> Enum.map(&rating.(&1.opponent_rank)) |> Enum.sum()
          n = length(games)
          # nearest integer, .5 up
          floor(total / n + 0.5)
      end

    upfloated = fn r ->
      g = Enum.at(p.games, r - 1)

      g != nil and played?(g) and
        before(p, r, ps) < before(by_rank[g.opponent_rank], r, ps)
    end

    pw = p.games |> Enum.take(round - 1)

    c2 =
      Enum.any?(pw, fn g ->
        (g.result == "U" and is_nil(g.opponent_rank)) or
          (not Trf.game_was_played?(g.result) and Trf.points_for_game(g, ps) >= ps.win)
      end)

    %{
      rank: p.rank,
      score: p.points + accel(p, round),
      pref: pref,
      strength: strength,
      abs?: strength == 3,
      cols: cols,
      played: length(games),
      aro: aro,
      ups: Enum.count(1..(round - 1)//1, upfloated),
      up_last?: round > 1 and upfloated.(round - 1),
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

  # ---- enumeration --------------------------------------------------------

  # Every perfect matching of `ranks` using legal pairs.
  defp matchings([], _legal?), do: [[]]

  defp matchings([a | rest], legal?) do
    for b <- rest, legal?.(a, b), m <- matchings(List.delete(rest, b), legal?), do: [{a, b} | m]
  end

  defp pairable?([], _legal?), do: true

  defp pairable?([a | rest], legal?) do
    Enum.any?(rest, fn b -> legal?.(a, b) and pairable?(List.delete(rest, b), legal?) end)
  end

  defp subsets(_list, 0), do: [[]]
  defp subsets([], _k), do: []
  defp subsets([h | t], k), do: for(s <- subsets(t, k - 1), do: [h | s]) ++ subsets(t, k)

  defp perms([]), do: [[]]
  defp perms(list), do: for(x <- Enum.sort(list), r <- perms(List.delete(list, x)), do: [x | r])

  # 4.1.3: sets ordered by the smallest differing sequence number.
  defp in_order(sets, numbering) do
    Enum.sort_by(sets, fn s -> s |> Enum.map(&numbering[&1]) |> Enum.sort() end)
  end

  # ---- 3.1 ----------------------------------------------------------------

  defp ref_bye(ranks, st) do
    if rem(length(ranks), 2) == 0 do
      if pairable?(ranks, st.legal?), do: {:ok, nil, ranks}, else: {:error, :no_legal_pairing}
    else
      ranks
      |> Enum.reject(&st.info[&1].c2?)
      |> Enum.filter(&pairable?(List.delete(ranks, &1), st.legal?))
      |> Enum.sort_by(&{st.info[&1].score, -st.info[&1].played, -&1})
      |> case do
        [] -> {:error, :no_legal_bye}
        [b | _] -> {:ok, b, List.delete(ranks, b)}
      end
    end
  end

  # ---- 3.2 ----------------------------------------------------------------

  defp ref_brackets([], _st, acc, splits), do: {:ok, acc, splits}

  defp ref_brackets(unpaired, st, acc, splits) do
    top = unpaired |> Enum.map(&st.info[&1].score) |> Enum.max()
    {res, lower} = Enum.split_with(unpaired, &(st.info[&1].score == top))

    legal_set? = fn set ->
      pairable?(res ++ set, st.legal?) and pairable?(lower -- set, st.legal?)
    end

    case Enum.find(0..length(lower), fn k -> Enum.any?(subsets(lower, k), legal_set?) end) do
      nil ->
        {:error, :no_legal_pairing}

      k ->
        legal_sets = lower |> subsets(k) |> Enum.filter(legal_set?)
        # 4.2: descending score, ascending TPN
        upfloat_numbering =
          lower
          |> Enum.sort_by(&{-st.info[&1].score, &1})
          |> Enum.with_index(1)
          |> Map.new()

        # [C6]: the ascending score list, as high as possible
        best_profile =
          legal_sets |> Enum.map(&profile(&1, st)) |> Enum.max()

        candidates = Enum.filter(legal_sets, &(profile(&1, st) == best_profile))

        keyed =
          Enum.map(candidates, fn set -> {quality(res ++ set, set, st), set} end)

        best_key = keyed |> Enum.map(&elem(&1, 0)) |> Enum.min()

        set =
          keyed
          |> Enum.filter(&(elem(&1, 0) == best_key))
          |> Enum.map(&elem(&1, 1))
          |> in_order(upfloat_numbering)
          |> hd()

        {c7_322, _, _, _} = best_key
        {pairs, split?} = pair_bracket(res ++ set, c7_322, st)
        ref_brackets(lower -- set, st, acc ++ pairs, splits + if(split?, do: 1, else: 0))
    end
  end

  defp profile(set, st), do: set |> Enum.map(&st.info[&1].score) |> Enum.sort()

  defp denied(pairs, st),
    do: Enum.count(pairs, fn {a, b} -> st.info[a].pref == st.info[b].pref end)

  defp quality(bracket, set, st) do
    c7 = bracket |> matchings(st.legal?) |> Enum.map(&denied(&1, st)) |> Enum.min()

    if st.last? do
      {c7, 0, 0, 0}
    else
      maxed = Enum.filter(set, &(st.info[&1].ups >= st.max_t))

      {c7, length(maxed), maxed |> Enum.map(&st.info[&1].ups) |> Enum.sum(),
       Enum.count(set, &st.info[&1].up_last?)}
    end
  end

  # 4.3: the shifter numbering of a pool.
  defp shifter_numbering(pool, st) do
    sorted =
      Enum.sort_by(pool, fn r ->
        i = st.info[r]
        if i.pref == "w", do: {i.aro, r}, else: {0, r}
      end)

    sorted |> middle() |> Enum.with_index(1) |> Map.new()
  end

  defp middle([]), do: []

  defp middle(list) do
    n = length(list)
    i = if rem(n, 2) == 1, do: div(n - 1, 2), else: div(n, 2) - 1
    [Enum.at(list, i) | middle(List.delete_at(list, i))]
  end

  defp pair_bracket(bracket, c7_322, st) do
    {g1, g2} =
      if Enum.all?(bracket, &(st.info[&1].played == 0)) do
        bracket |> Enum.sort() |> Enum.split(div(length(bracket), 2))
      else
        Enum.split_with(bracket, &(st.info[&1].pref == "w"))
      end

    {small, large, g1_small?} =
      if length(g1) <= length(g2), do: {g1, g2, true}, else: {g2, g1, false}

    in_small = MapSet.new(small)

    p =
      bracket
      |> matchings(st.legal?)
      |> Enum.map(fn m ->
        Enum.count(m, fn {a, b} -> MapSet.member?(in_small, a) and MapSet.member?(in_small, b) end)
      end)
      |> Enum.min()

    q = div(length(large) - length(small), 2) + p

    as = small |> subsets(p) |> in_order(shifter_numbering(small, st))
    bs = large |> subsets(q) |> in_order(shifter_numbering(large, st))

    # Every completion of a first shift: {b, t2, c7} over legal transpositions.
    completions = fn a ->
      for b <- bs,
          {f1, f2} =
            (
              s2 = (small -- a) ++ b
              l2 = (large ++ a) -- b
              if g1_small?, do: {s2, l2}, else: {l2, s2}
            ),
          s1 = Enum.sort_by(f1, &{st.info[&1].aro, &1}),
          t2 <- perms(f2),
          pairs = Enum.zip(s1, t2),
          Enum.all?(pairs, fn {x, y} -> st.legal?.(x, y) end),
          do: {b, pairs, denied(pairs, st)}
    end

    all = Enum.flat_map(as, fn a -> Enum.map(completions.(a), &{a, &1}) end)
    best = all |> Enum.map(fn {_a, {_b, _p, c}} -> c end) |> Enum.min()

    a = Enum.find(as, fn a -> Enum.any?(completions.(a), &(elem(&1, 2) == best)) end)
    done = completions.(a)
    b = Enum.find(bs, fn b -> Enum.any?(done, &(elem(&1, 0) == b and elem(&1, 2) == best)) end)
    legal = for {^b, pairs, c} <- done, do: {pairs, c}

    {literal, literal_c7} = hd(legal)

    chosen =
      case st.d2 do
        :literal -> literal
        :c7 -> legal |> Enum.find(fn {_p, c} -> c == c7_322 end) |> elem(0)
      end

    {chosen, best != c7_322 or literal_c7 != c7_322}
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

  defp colour(a, b, numbers, initial) do
    {hi, lo} = if {-a.score, a.rank} < {-b.score, b.rank}, do: {a, b}, else: {b, a}

    white =
      cond do
        a.played == 0 and b.played == 0 ->
          odd = rem(numbers[hi.rank], 2) == 1
          if odd == (initial == :w), do: hi, else: lo

        a.pref != b.pref ->
          if a.pref == "w", do: a, else: b

        a.strength != b.strength ->
          s = if a.strength > b.strength, do: a, else: b
          if s.pref == "w", do: s, else: if(s == a, do: b, else: a)

        d =
            Enum.find(Enum.zip(Enum.reverse(a.cols), Enum.reverse(b.cols)), fn {x, y} ->
              x != y
            end) ->
          if elem(d, 0) == "b", do: a, else: b

        true ->
          if hi.pref == "w", do: hi, else: lo
      end

    if white == a, do: {a.rank, b.rank}, else: {b.rank, a.rank}
  end
end

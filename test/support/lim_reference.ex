defmodule Ainalrami.Test.LimReference do
  @moduledoc """
  A brute-force reading of C.04.4.3 (Lim), written from the rule text and
  `docs/conformance-c0443-lim.md`, sharing no code with `Ainalrami.Lim`
  but the TRF helpers and C.04.1's bye eligibility.

  Where the engine runs weighted matchings and fixes a pairing choice by
  choice, this enumerates: every split of a group into paired players and
  floaters, compared as a tuple of the criteria in reading L4's order;
  every pairing of the paired players, compared by the due colours it
  denies and then by its key in the scrutiny order (reading L5), found by
  replaying the scrutiny against the pairing. "Can these players still be
  paired" is a memoised search, not a matching. The colour rules and the
  compatibility of 2.1 are derived again from the colour histories here.

  Meant for fields of up to 12 players.

  Switches, one per reading whose alternative is measured
  (`tools/lim_readings.exs`): `l4: :types_first | :colour_first`,
  `l6: :colour_first | :order_first`, `l12: :equal_scores | :every_pair`.
  """

  alias Ainalrami.{Pairing, Trf}

  @doc "`{:ok, %{pairs: [{w, b}] sorted, bye: rank | nil}}` or `{:error, reason}`."
  def ref_round(players, opts) do
    Process.put(:lim_ref_memo, %{})
    round = Trf.rounds_played(players) + 1
    ps = opts[:point_system] || Trf.default_point_system()
    last? = round == opts[:expected_rounds]
    eligible = Pairing.bye_eligibility(players, point_system: ps)

    active =
      players
      |> Enum.filter(&(length(&1.games) < round))
      |> Map.new(fn p -> {p.rank, view(p, players, round, ps, eligible)} end)

    forbidden =
      for g <- opts[:forbidden_pairs] || [],
          ranks = forbidden_ranks(g, round),
          a <- ranks,
          b <- ranks,
          a != b,
          into: MapSet.new(),
          do: {a, b}

    compat = fn a, b ->
      x = active[a]
      y = active[b]

      a != b and not MapSet.member?(forbidden, {a, b}) and b not in x.met and
        ((last? and (x.score == y.score or opts[:l12] == :every_pair)) or
           (:white in x.allowed and :black in y.allowed) or
           (:black in x.allowed and :white in y.allowed))
    end

    initial = initial(opts[:initial_colour], players)
    median = (round - 1) * ps.win / 2
    env = %{p: active, compat: compat, median: median, initial: initial, opts: opts}
    ranks = Map.keys(active) |> Enum.sort()

    with {:ok, bye, rest} <- bye(ranks, env) do
      {:ok, %{pairs: Enum.sort(groups(rest, env)), bye: bye}}
    end
  end

  defp forbidden_ranks({ranks, first, last}, round),
    do: if(round >= first and round <= last, do: ranks, else: [])

  defp forbidden_ranks(ranks, _round), do: ranks

  # What the reference needs to know of one player.
  defp view(p, players, round, ps, eligible) do
    before = fn player, r ->
      player.games |> Enum.take(r - 1) |> Enum.map(&Trf.points_for_game(&1, ps)) |> Enum.sum()
    end

    played =
      p.games
      |> Enum.take(round - 1)
      |> Enum.filter(
        &(is_integer(&1.opponent_rank) and Trf.game_was_played?(&1.result) and
            &1.colour in ["w", "b"])
      )

    colours = Enum.map(played, &if(&1.colour == "w", do: :w, else: :b))
    w = Enum.count(colours, &(&1 == :w))
    cd = w - (length(colours) - w)
    tail = colours |> Enum.reverse() |> Enum.take(2)

    allowed =
      for c <- [:white, :black],
          step = if(c == :white, do: 1, else: -1),
          abs(cd + step) <= 2,
          tail != [short(c), short(c)],
          do: c

    {due, must?} =
      cond do
        colours == [] -> {nil, false}
        cd >= 2 -> {:black, true}
        cd <= -2 -> {:white, true}
        match?([c, c], tail) -> {long(other(hd(tail))), true}
        cd == 1 -> {:black, false}
        cd == -1 -> {:white, false}
        true -> {long(other(hd(tail))), false}
      end

    prev =
      round >= 2 and
        case Enum.at(p.games, round - 2) do
          %{opponent_rank: o} = g when is_integer(o) ->
            opp = Enum.find(players, &(&1.rank == o))

            Trf.participated_in_pairing?(g) and opp != nil and
              before.(opp, round - 1) != before.(p, round - 1)

          _ ->
            false
        end

    %{
      rank: p.rank,
      score: before.(p, round),
      colours: colours,
      due: due,
      must?: must?,
      allowed: allowed,
      met: for(g <- played, do: g.opponent_rank),
      prev: prev,
      eligible: is_nil(Map.get(eligible, p.rank))
    }
  end

  defp short(:white), do: :w
  defp short(:black), do: :b
  defp long(:w), do: :white
  defp long(:b), do: :black
  defp other(:w), do: :b
  defp other(:b), do: :w

  defp initial("w", _), do: :white
  defp initial("b", _), do: :black

  defp initial(nil, players) do
    players
    |> Enum.sort_by(& &1.rank)
    |> Enum.find_value(:white, fn p ->
      case p.games do
        [%{colour: c, opponent_rank: o} | _] when c in ["w", "b"] and is_integer(o) ->
          mine = if c == "w", do: :white, else: :black
          if rem(p.rank, 2) == 1, do: mine, else: flip(mine)

        _ ->
          nil
      end
    end)
  end

  defp flip(:white), do: :black
  defp flip(:black), do: :white

  # ---- can these players all be paired ------------------------------------

  defp pairable?([], _env), do: true

  defp pairable?(ranks, env) do
    key = Enum.sort(ranks)
    memo = Process.get(:lim_ref_memo)

    case Map.fetch(memo, key) do
      {:ok, v} ->
        v

      :error ->
        v =
          rem(length(key), 2) == 0 and
            (fn [a | rest] ->
               Enum.any?(rest, &(env.compat.(a, &1) and pairable?(List.delete(rest, &1), env)))
             end).(key)

        Process.put(:lim_ref_memo, Map.put(Process.get(:lim_ref_memo), key, v))
        v
    end
  end

  defp bye(ranks, env) do
    if rem(length(ranks), 2) == 0 do
      if pairable?(ranks, env), do: {:ok, nil, ranks}, else: {:error, :no_legal_pairing}
    else
      ranks
      |> Enum.filter(&env.p[&1].eligible)
      |> Enum.sort_by(&{env.p[&1].score, -&1})
      |> Enum.find(&pairable?(List.delete(ranks, &1), env))
      |> case do
        nil -> {:error, :no_legal_bye}
        r -> {:ok, r, List.delete(ranks, r)}
      end
    end
  end

  # ---- the groups -----------------------------------------------------------

  defp groups(rest, env) do
    score = &env.p[&1].score
    scores = rest |> Enum.map(score) |> Enum.uniq()
    m = env.median
    above = scores |> Enum.filter(&(&1 > m)) |> Enum.sort(:desc)
    below = scores |> Enum.filter(&(&1 < m)) |> Enum.sort()
    at = Enum.filter(rest, &(score.(&1) == m))
    of = fn s -> Enum.filter(rest, &(score.(&1) == s)) end

    {pairs, unpaired, downs} = sweep(above, :down, of, at, rest, env, [])
    {pairs, unpaired, ups} = sweep(below, :up, of, at, unpaired, env, pairs)
    members = downs ++ ups ++ at
    {[], paired} = choose(members, m, :median, [], unpaired, env)
    pairs ++ pair_up(paired, m, :median, env)
  end

  defp sweep(scores, dir, of, at, unpaired, env, pairs) do
    scores
    |> Enum.with_index()
    |> Enum.reduce({pairs, unpaired, []}, fn {s, i}, {pairs, unpaired, incoming} ->
      members = incoming ++ of.(s)

      adjacent =
        case Enum.at(scores, i + 1),
          do: (
            nil -> at
            t -> of.(t)
          )

      {floaters, paired} = choose(members, s, dir, adjacent, unpaired, env)
      {pairs ++ pair_up(paired, s, dir, env), unpaired -- paired, floaters}
    end)
  end

  # Every split of the group, the best by reading L4's criteria.
  defp choose(members, s, dir, adjacent, unpaired, env) do
    n = length(members)
    w = Enum.count(members, &(env.p[&1].due == :white))
    b = Enum.count(members, &(env.p[&1].due == :black))

    major =
      cond do: (
             w > b -> :white
             b > w -> :black
             true -> nil
           )

    0..(Integer.pow(2, n) - 1)
    |> Enum.map(fn mask ->
      floaters =
        for {r, i} <- Enum.with_index(members), Bitwise.band(mask, Bitwise.bsl(1, i)) != 0, do: r

      {floaters, members -- floaters}
    end)
    |> Enum.filter(fn {floaters, paired} ->
      (dir != :median or floaters == []) and pairable?(paired, env) and
        pairable?(unpaired -- paired, env)
    end)
    |> Enum.min_by(
      fn {floaters, _} ->
        count = fn f -> Enum.count(floaters, f) end
        incoming? = &(env.p[&1].score != s)
        reach? = fn r -> Enum.any?(adjacent, &env.compat.(r, &1)) end

        types =
          {count.(&(incoming?.(&1) and not reach?.(&1))),
           count.(&(incoming?.(&1) and reach?.(&1))),
           count.(&(not incoming?.(&1) and not reach?.(&1)))}

        prev = count.(&env.p[&1].prev)
        colour = count.(&(major != nil and env.p[&1].due != major))

        tpn =
          if dir == :up,
            do: Enum.sort(floaters),
            else: floaters |> Enum.sort(:desc) |> Enum.map(&(-&1))

        case env.opts[:l4] do
          :colour_first -> {length(floaters), colour, types, prev, tpn}
          _ -> {length(floaters), types, prev, colour, tpn}
        end
      end,
      fn -> raise "Lim reference: no split for group #{s}" end
    )
  end

  # ---- the pairs of a group -------------------------------------------------

  defp pair_up([], _s, _dir, _env), do: []

  defp pair_up(paired, s, dir, env) do
    matchings(Enum.sort(paired), env)
    |> Enum.min_by(fn pairs ->
      denied = pairs |> Enum.map(fn {x, y} -> elem(colours(x, y, s, env), 2) end) |> Enum.sum()
      key = scrutiny_key(pairs, paired, s, dir, env)
      if env.opts[:l6] == :order_first, do: {key, denied}, else: {denied, key}
    end)
    |> Enum.map(fn {x, y} ->
      {w, b, _} = colours(x, y, s, env)
      {w, b}
    end)
  end

  defp matchings([], _env), do: [[]]

  defp matchings([a | rest], env) do
    for b <- rest, env.compat.(a, b), m <- matchings(List.delete(rest, b), env), do: [{a, b} | m]
  end

  # The pairing replayed against the scrutiny: at each step, where the
  # chooser's partner in this pairing stands in the chooser's list.
  defp scrutiny_key(pairs, paired, s, dir, env) do
    partner_of = Map.new(Enum.flat_map(pairs, fn {a, b} -> [{a, b}, {b, a}] end))
    sc = &env.p[&1].score
    downs = paired |> Enum.filter(&(sc.(&1) > s)) |> Enum.sort_by(&{-sc.(&1), &1})
    ups = paired |> Enum.filter(&(sc.(&1) < s)) |> Enum.sort_by(&{sc.(&1), -&1})
    floaters = if dir == :up, do: ups ++ downs, else: downs ++ ups
    residents = paired |> Enum.filter(&(sc.(&1) == s)) |> Enum.sort()
    residents = if dir == :up, do: Enum.reverse(residents), else: residents
    step(floaters, residents, floaters, partner_of, %{}, s, env, [])
  end

  defp step(floaters, residents, all_floaters, partner_of, done, s, env, key) do
    free = &(not Map.has_key?(done, &1))

    {chooser, list} =
      case Enum.filter(floaters, free) do
        [f | _] ->
          down? = env.p[f].score > s
          sorted = &Enum.sort(&1, if(down?, do: :asc, else: :desc))
          res = residents |> Enum.filter(free) |> sorted.()
          due = env.p[f].due
          alt = Enum.filter(res, &(due != nil and env.p[&1].due != nil and env.p[&1].due != due))
          others = all_floaters |> Enum.filter(free) |> Enum.reject(&(&1 == f)) |> sorted.()
          {f, alt ++ (res -- alt) ++ others}

        [] ->
          left = Enum.reject(residents, &(Map.get(done, &1) in all_floaters))
          h = div(length(left), 2)
          top = Enum.take(left, h)
          bottom = Enum.drop(left, h)

          case Enum.filter(left, free) do
            [] ->
              {nil, []}

            [c | _] ->
              {c, (Enum.filter(bottom, free) ++ Enum.reverse(Enum.filter(top, free))) -- [c]}
          end
      end

    if chooser == nil do
      Enum.reverse(key)
    else
      p = partner_of[chooser]
      i = Enum.find_index(list, &(&1 == p)) || raise "Lim reference: partner off the list"
      done = done |> Map.put(chooser, p) |> Map.put(p, chooser)
      step(floaters, residents, all_floaters, partner_of, done, s, env, [i | key])
    end
  end

  # ---- colours (5) -----------------------------------------------------------

  # {white, black, denied}
  defp colours(a, b, s, env) do
    x = env.p[a]
    y = env.p[b]

    {gets, colour} =
      cond do
        x.due == nil and y.due == nil ->
          h = min(a, b)
          {h, if(rem(h, 2) == 1, do: env.initial, else: flip(env.initial))}

        x.due == nil ->
          {b, y.due}

        y.due == nil ->
          {a, x.due}

        x.due != y.due ->
          {a, x.due}

        x.must? and not y.must? ->
          {a, x.due}

        y.must? and not x.must? ->
          {b, y.due}

        true ->
          {back(x, y, s, env), x.due}
      end

    other = if gets == a, do: b, else: a
    {w, bl} = if colour == :white, do: {gets, other}, else: {other, gets}

    denied =
      Enum.count([{a, x}, {b, y}], fn {r, v} ->
        v.due != nil and v.due != if(r == w, do: :white, else: :black)
      end)

    {w, bl, denied}
  end

  # 5.4: back through the histories to the most recent difference.
  defp back(x, y, s, env) do
    due = short(x.due)

    diff =
      Enum.zip(Enum.reverse(x.colours), Enum.reverse(y.colours))
      |> Enum.find(fn {c, d} -> c != d end)

    case diff do
      {c, _} -> if c != due, do: x.rank, else: y.rank
      nil -> if s >= env.median, do: min(x.rank, y.rank), else: max(x.rank, y.rank)
    end
  end
end

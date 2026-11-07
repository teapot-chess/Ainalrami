defmodule AinalramiVerify.Bracket do
  @moduledoc """
  A brute-force reading of C.04.3 (2026) Articles 2-4, bracket by bracket.

  For one bracket - its moved-down players (MDPs) and residents fixed by
  the brackets above - every candidate is listed: every set of legal pairs
  inside the bracket, the players left over being its downfloaters. Each
  candidate that keeps the rest of the round pairable ([C4]) is scored on
  [C5]-[C21], and the best is chosen by 3.8.1: the better value on the
  highest criterion that differs, and, all criteria equal, the candidate
  Article 4's sequence generates first.

  Nothing here is a matching algorithm. "Can the rest still be paired"
  and "the lowest score the bye can go to" are answered by exhaustive
  recursion over subsets (memoised on a bitmask), and the next bracket's
  outlook for [C8] by listing that bracket's candidates too. That is what
  limits this module to small fields - about 16 players - and what makes
  it independent of the engine, whose brackets are maximum-weight
  matchings.

  ## Readings

  Where the text leaves a choice, the choice is written here and in
  `README.md`:

    * A candidate may pair two MDPs with each other. Article 3 seats MDPs
      only against residents; a field where two MDPs can only be paired
      together is rare, and the engine (like bbpPairings) builds its
      brackets as matchings over everyone present. Such a candidate has no
      place in Article 4's sequence and sorts after every candidate that
      has one.
    * [C8] "every criterion from [C1] to [C7] is complied with in the
      following bracket" is measured as the best [C5], [C6] and [C7] the
      following bracket can then reach, in that order.
    * [C9] applies to a candidate with exactly one downfloater when the
      lowest score the bye can go to (its [C5] value) is that player's
      score: then that player is the one who ends up with the bye.
    * [C15], [C17], [C19], [C21]: in a pair of players with different
      scores the lower one is "the MDP opponent".
    * [C18], [C20]: an MDP the bracket leaves in the Limbo still has a
      score difference - it will float on and meet someone lower still -
      and it counts as larger than any this bracket could give it (its
      difference with the bracket's score plus a quarter-point). Read
      the other way (only MDPs paired in the bracket count), the brute
      force preferred to send a twice-floated MDP further down in 155 of
      40,880 positions of the 6- and 7-player, 4-round trees, where the
      engine (and bbpPairings, whose weights the engine ports) pays the
      MDP to stay; the text's "MDPs who received a downfloat" does not
      exclude the ones that float again, so this reading was adopted.
    * MaxPairs (3.1.2) is the number of pairs of the best candidates, and
      the remainder's S1R is sized the same way.
  """

  import Bitwise

  alias AinalramiVerify.{Position, Rules}

  @criteria ~w(C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C16 C17 C18 C19 C20 C21)

  @articles %{
    "C1" => "2.1.1",
    "C2" => "2.1.2",
    "C3" => "2.1.3",
    "C4" => "2.2.1",
    "C5" => "2.3.1",
    "C6" => "2.4.1",
    "C7" => "2.4.2",
    "C8" => "2.4.3",
    "C9" => "2.4.4",
    "C10" => "2.4.5",
    "C11" => "2.4.6",
    "C12" => "2.4.7",
    "C13" => "2.4.8",
    "C14" => "2.4.9",
    "C15" => "2.4.10",
    "C16" => "2.4.11",
    "C17" => "2.4.12",
    "C18" => "2.4.13",
    "C19" => "2.4.14",
    "C20" => "2.4.15",
    "C21" => "2.4.16"
  }

  def criteria, do: @criteria
  def article(c), do: Map.fetch!(@articles, c)

  # ---------------------------------------------------------------------------
  # Context: the pool as bit positions, legality as bitmasks, a memo.

  defmodule Ctx do
    @moduledoc false
    defstruct [:pos, :ranks, :index, :adj, :memo, :bend]
  end

  @doc "A context for searching one position."
  def context(%Position{} = pos) do
    ranks = Position.sort(pos, pos.pool) |> List.to_tuple()
    n = tuple_size(ranks)
    index = for i <- 0..(n - 1)//1, into: %{}, do: {elem(ranks, i), i}

    adj =
      for i <- 0..(n - 1)//1, into: %{} do
        a = elem(ranks, i)

        {i,
         Enum.reduce(0..(n - 1)//1, 0, fn j, acc ->
           if i != j and Rules.legal?(pos, a, elem(ranks, j)), do: acc ||| 1 <<< j, else: acc
         end)}
      end

    %Ctx{
      pos: pos,
      ranks: ranks,
      index: index,
      adj: adj,
      memo: make_ref(),
      bend: Application.get_env(:ainalrami_verify, :bend)
    }
  end

  def mask(ctx, ranks),
    do: Enum.reduce(ranks, 0, fn r, acc -> acc ||| 1 <<< Map.fetch!(ctx.index, r) end)

  def members(ctx, mask), do: for(i <- bits(mask), do: elem(ctx.ranks, i))

  defp bits(0), do: []

  defp bits(mask) do
    low = mask &&& -mask
    [trailing(low, 0) | bits(bxor(mask, low))]
  end

  defp trailing(1, n), do: n
  defp trailing(x, n), do: trailing(x >>> 1, n + 1)

  defp popcount(0), do: 0
  defp popcount(m), do: 1 + popcount(m &&& m - 1)

  @doc """
  [C4] with [C2]: can the players in `mask` all be paired, with at most one
  of them (an eligible one) left for the bye? Returns `:none`, or
  `{:ok, bye}` with `bye` the lowest score ([C5]) any such pairing leaves
  the bye to (`nil` for an even set).
  """
  def completion(ctx, mask) do
    key = {ctx.memo, :c, mask}

    case Process.get(key) do
      nil ->
        v = do_completion(ctx, mask)
        Process.put(key, v)
        v

      v ->
        v
    end
  end

  defp do_completion(_ctx, 0), do: {:ok, nil}

  defp do_completion(ctx, mask) do
    low = mask &&& -mask
    v = trailing(low, 0)
    rest = bxor(mask, low)
    odd? = rem(popcount(mask), 2) == 1

    as_bye =
      if odd? and Rules.bye_eligible?(ctx.pos, elem(ctx.ranks, v)) do
        case completion(ctx, rest) do
          {:ok, nil} -> [ctx.pos.players[elem(ctx.ranks, v)].score]
          _ -> []
        end
      else
        []
      end

    paired =
      for u <- bits(rest &&& ctx.adj[v]),
          {:ok, s} <- [completion(ctx, bxor(rest, 1 <<< u))],
          do: s

    case as_bye ++ paired do
      [] -> :none
      list -> {:ok, if(odd?, do: Enum.min(list), else: nil)}
    end
  end

  # ---------------------------------------------------------------------------
  # Candidates

  @doc """
  Every candidate of a bracket: `{pairs, downfloaters}` with `pairs` as
  `[{a, b}]` (a ahead of b in Article 1.2's order) over legal pairs, every
  player of the bracket in exactly one pair or among the downfloaters.
  """
  def candidates(ctx, bracket_ranks) do
    ordered = Position.sort(ctx.pos, bracket_ranks)
    gen(ctx, ordered, [], [])
  end

  defp gen(_ctx, [], pairs, df), do: [{Enum.reverse(pairs), Enum.reverse(df)}]

  defp gen(ctx, [v | rest], pairs, df) do
    vi = ctx.index[v]
    floated = gen(ctx, rest, pairs, [v | df])

    paired =
      Enum.flat_map(rest, fn u ->
        if (ctx.adj[vi] &&& 1 <<< ctx.index[u]) != 0 do
          gen(ctx, List.delete(rest, u), [{v, u} | pairs], df)
        else
          []
        end
      end)

    floated ++ paired
  end

  # ---------------------------------------------------------------------------
  # Brackets

  defmodule B do
    @moduledoc false
    # mdps/residents: ranks; below: mask of every resident under this
    # bracket's score; next: ranks of the next scoregroup (or []).
    defstruct [:score, :mdps, :residents, :below, :next, :players]
  end

  @doc "The scoregroups of the pool, highest first: `[{score, [ranks]}]`."
  def scoregroups(ctx) do
    ctx.ranks
    |> Tuple.to_list()
    |> Enum.group_by(&ctx.pos.players[&1].score)
    |> Enum.sort_by(fn {s, _} -> -s end)
    |> Enum.map(fn {s, rs} -> {s, Position.sort(ctx.pos, rs)} end)
  end

  @doc "The bracket at scoregroup `k` (0-based) given the MDPs it receives."
  def bracket(ctx, groups, k, mdps) do
    {score, residents} = Enum.at(groups, k)
    below = groups |> Enum.drop(k + 1) |> Enum.flat_map(&elem(&1, 1))

    next =
      case Enum.at(groups, k + 1) do
        nil -> []
        {_, rs} -> rs
      end

    %B{
      score: score,
      mdps: Position.sort(ctx.pos, mdps),
      residents: residents,
      below: mask(ctx, below),
      next: next,
      players: Position.sort(ctx.pos, mdps ++ residents)
    }
  end

  @doc """
  Score a candidate: `{:ok, vector}` (a map from criterion to value; lower
  is better on every criterion, compared in `@criteria` order) or
  `{:error, "C4"}` when it leaves the rest of the round unpairable.
  """
  def evaluate(ctx, %B{} = b, {pairs, df}) do
    pos = ctx.pos
    rest = mask(ctx, df) ||| b.below

    case completion(ctx, rest) do
      :none ->
        {:error, "C4"}

      {:ok, bye} ->
        p = pos.players
        scores = df |> Enum.map(&p[&1].score) |> Enum.sort(:desc)
        colour = Enum.map(pairs, fn {x, y} -> Rules.colour_costs(pos, x, y) end)
        csum = fn k -> colour |> Enum.map(& &1[k]) |> Enum.sum() end
        residents = MapSet.new(b.residents)
        res_df = Enum.filter(df, &MapSet.member?(residents, &1))
        # pairs across scores: {higher, lower}
        cross =
          for {x, y} <- pairs, p[x].score != p[y].score do
            if p[x].score > p[y].score, do: {x, y}, else: {y, x}
          end

        # C19/C21: the score difference of each pair across scores whose
        # lower player (the MDP opponent) matches `pred`, in quarter-points
        # (twice the half-point difference) to share a scale with mdp_diffs.
        diffs = fn pred ->
          cross
          |> Enum.filter(pred)
          |> Enum.map(fn {h, l} -> 2 * (p[h].score - p[l].score) end)
          |> Enum.sort(:desc)
          |> pad(length(b.players))
        end

        # C18/C20: the score difference of each MDP that floated down
        # `back` rounds ago. Paired here, it is the difference with its
        # opponent; left in the Limbo it floats on and its difference can
        # only grow, so it counts as the difference with this bracket plus
        # a quarter-point - more than any opponent here would give it.
        partner = Map.new(Enum.flat_map(pairs, fn {x, y} -> [{x, y}, {y, x}] end))

        mdp_diffs = fn back ->
          b.mdps
          |> Enum.filter(&Rules.floated?(pos, &1, :down, back))
          |> Enum.map(fn m ->
            case partner do
              %{^m => o} -> 2 * max(p[m].score - p[o].score, 0)
              _ -> 2 * (p[m].score - b.score) + 1
            end
          end)
          |> Enum.sort(:desc)
          |> pad(length(b.players))
        end

        c9 =
          case df do
            [d] when bye != nil -> if bye == p[d].score, do: p[d].unplayed, else: 0
            _ -> 0
          end

        {:ok,
         bend(ctx.bend, %{
           "C5" => bye || 0,
           "C6" => length(df),
           "C7" => scores,
           "C8" => outlook(ctx, b, df),
           "C9" => c9,
           "C10" => csum.(:c10),
           "C11" => csum.(:c11),
           "C12" => csum.(:c12),
           "C13" => csum.(:c13),
           "C14" => Enum.count(res_df, &Rules.floated?(pos, &1, :down, 1)),
           "C15" => Enum.count(cross, fn {_, l} -> Rules.floated?(pos, l, :up, 1) end),
           "C16" => Enum.count(res_df, &Rules.floated?(pos, &1, :down, 2)),
           "C17" => Enum.count(cross, fn {_, l} -> Rules.floated?(pos, l, :up, 2) end),
           "C18" => mdp_diffs.(1),
           "C19" => diffs.(fn {_, l} -> Rules.floated?(pos, l, :up, 1) end),
           "C20" => mdp_diffs.(2),
           "C21" => diffs.(fn {_, l} -> Rules.floated?(pos, l, :up, 2) end)
         })}
    end
  end

  # Positive controls only (`config :ainalrami_verify, bend: ...`, set by
  # the tests): a deliberately wrong reading, to show the comparison
  # notices one. Never set in a real run.
  defp bend(nil, v), do: v
  defp bend(:no_c7, v), do: %{v | "C7" => []}
  defp bend(:no_c8, v), do: %{v | "C8" => {}}
  defp bend(:no_c12, v), do: %{v | "C12" => 0}
  defp bend(:no_c14, v), do: %{v | "C14" => 0}
  defp bend(_, v), do: v

  defp pad(list, n), do: list ++ List.duplicate(0, max(n - length(list), 0))

  @doc "A vector as a comparable tuple, in priority order."
  def key(vector), do: @criteria |> Enum.map(&Map.fetch!(vector, &1)) |> List.to_tuple()

  # [C8]: the best [C5], [C6], [C7] the following bracket can reach with
  # these downfloaters as its MDPs.
  defp outlook(_ctx, %B{next: []}, _df), do: {}

  defp outlook(ctx, %B{} = b, df) do
    memo = {ctx.memo, :c8, b.score, mask(ctx, df)}

    case Process.get(memo) do
      nil ->
        nb_players = Position.sort(ctx.pos, df ++ b.next)
        below = b.below &&& Bitwise.bnot(mask(ctx, b.next))

        v =
          ctx
          |> candidates(nb_players)
          |> Enum.flat_map(fn {pairs, ndf} ->
            case completion(ctx, mask(ctx, ndf) ||| below) do
              :none ->
                []

              {:ok, bye} ->
                _ = pairs

                [
                  {bye || 0, length(ndf),
                   ndf |> Enum.map(&ctx.pos.players[&1].score) |> Enum.sort(:desc)}
                ]
            end
          end)
          |> Enum.min(fn -> {1_000_000, 1_000_000, []} end)

        Process.put(memo, v)
        v

      v ->
        v
    end
  end

  # ---------------------------------------------------------------------------
  # Article 4: the position of a candidate in the sequence.

  @doc """
  Where Article 4's sequence first generates the candidate: a term that
  sorts earlier for an earlier candidate. A candidate the sequence cannot
  generate (two MDPs paired together) gets `{:unordered, ...}`, which sorts
  after every ordered one.
  """
  def sequence_key(ctx, %B{} = b, {pairs, _df}) do
    pos = ctx.pos
    bsn = b.players |> Enum.with_index(1) |> Map.new()
    mdps = MapSet.new(b.mdps)
    partner = Enum.flat_map(pairs, fn {x, y} -> [{x, y}, {y, x}] end) |> Map.new()

    mdp_pairs =
      Enum.filter(pairs, fn {x, y} -> MapSet.member?(mdps, x) or MapSet.member?(mdps, y) end)

    if Enum.any?(mdp_pairs, fn {x, y} -> MapSet.member?(mdps, x) and MapSet.member?(mdps, y) end) do
      {:unordered, Enum.map(pairs, fn {x, y} -> {bsn[x], bsn[y]} end) |> Enum.sort()}
    else
      paired_mdps = b.mdps |> Enum.filter(&Map.has_key?(partner, &1))
      mdp_set = Enum.map(paired_mdps, &bsn[&1])
      mdp_tuple = Enum.map(paired_mdps, &bsn[partner[&1]])
      seated = MapSet.new(Enum.map(paired_mdps, &partner[&1]))
      remainder = Enum.reject(b.residents, &MapSet.member?(seated, &1))

      rem_pairs =
        Enum.reject(pairs, fn {x, y} -> MapSet.member?(mdps, x) or MapSet.member?(mdps, y) end)

      _ = pos
      {:ordered, mdp_set, mdp_tuple, homogeneous_key(remainder, rem_pairs)}
    end
  end

  # 3.6 and 4.2-4.3 for a homogeneous bracket or a remainder: the
  # earliest (exchange, transposition) that generates these pairs.
  defp homogeneous_key(players, pairs) do
    bsn = players |> Enum.with_index(1) |> Map.new()
    n1 = length(pairs)
    s1 = MapSet.new(1..n1//1)
    bp = Enum.map(pairs, fn {x, y} -> {bsn[x], bsn[y]} end)

    choices(bp)
    |> Enum.map(fn chosen ->
      # chosen: [{in_s1, partner}] - one end of each pair goes to S1
      s1p = chosen |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      out = MapSet.difference(s1, s1p) |> Enum.sort(:desc)
      inn = MapSet.difference(s1p, s1) |> Enum.sort()
      tuple = chosen |> Enum.sort() |> Enum.map(&elem(&1, 1))
      {{length(out), Enum.sum(inn) - Enum.sum(out), Enum.map(out, &(-&1)), inn}, tuple}
    end)
    |> Enum.min(fn -> {{0, 0, [], []}, []} end)
  end

  defp choices([]), do: [[]]

  defp choices([{x, y} | rest]) do
    tails = choices(rest)
    for pick <- [{x, y}, {y, x}], t <- tails, do: [pick | t]
  end

  # ---------------------------------------------------------------------------
  # The best candidate of a bracket

  @doc """
  All candidates of the bracket that satisfy [C4], scored:
  `[{candidate, vector_key}]`.
  """
  def scored(ctx, %B{} = b) do
    ctx
    |> candidates(b.players)
    |> Enum.flat_map(fn cand ->
      case evaluate(ctx, b, cand) do
        {:ok, v} -> [{cand, key(v), v}]
        {:error, _} -> []
      end
    end)
  end

  @doc "3.8.1: the best candidate, or `nil` when none satisfies [C4]."
  def best(ctx, %B{} = b) do
    case scored(ctx, b) do
      [] ->
        nil

      list ->
        top = list |> Enum.map(&elem(&1, 1)) |> Enum.min()
        tied = Enum.filter(list, &(elem(&1, 1) == top))
        pick = if ctx.bend == :order_last, do: &Enum.max_by/2, else: &Enum.min_by/2
        {cand, k, v} = pick.(tied, fn {c, _, _} -> sequence_key(ctx, b, c) end)
        %{candidate: cand, key: k, vector: v, tied: length(tied)}
    end
  end

  # ---------------------------------------------------------------------------
  # The round

  @doc """
  The reference pairing of a position: `{:ok, %{pairs: [{white, black}],
  bye: rank | nil}}` or `{:error, :no_legal_pairing}` (1.9.3).
  """
  def pair(%Position{} = pos) do
    ctx = context(pos)

    try do
      if completion(ctx, mask(ctx, pos.pool)) == :none do
        {:error, :no_legal_pairing}
      else
        groups = scoregroups(ctx)

        {pairs, left} =
          Enum.reduce(0..(length(groups) - 1)//1, {[], []}, fn k, {acc, mdps} ->
            b = bracket(ctx, groups, k, mdps)

            %{candidate: {ps, df}} =
              best(ctx, b) || raise "C4 failed in a bracket of a completable round"

            {acc ++ ps, df}
          end)

        bye =
          case left do
            [] -> nil
            [x] -> x
          end

        {:ok, %{pairs: Enum.map(pairs, fn {a, b} -> colour(pos, a, b) end), bye: bye}}
      end
    after
      cleanup(ctx)
    end
  end

  defp colour(pos, a, b) do
    {w, bl, _} = Rules.colours(pos, a, b)
    {w, bl}
  end

  @doc "Drop a context's memo from the process dictionary."
  def cleanup(ctx) do
    for {{ref, _, _} = k, _} <- Process.get(), ref == ctx.memo, do: Process.delete(k)
    for {{ref, _, _, _} = k, _} <- Process.get(), ref == ctx.memo, do: Process.delete(k)
    :ok
  end

  @doc """
  The brackets a complete round implies, top down (1.3.2, 1.4.1): each
  pair belongs to the bracket of its lower-scored player, and whoever a
  bracket leaves unpaired is an MDP of the next. Returns
  `[{bracket, {pairs, downfloaters}}]`.
  """
  def structure(ctx, pairs) do
    groups = scoregroups(ctx)
    norm = Enum.map(pairs, fn {a, b} -> order(ctx.pos, a, b) end)

    {out, _} =
      Enum.map_reduce(0..(length(groups) - 1)//1, [], fn k, mdps ->
        b = bracket(ctx, groups, k, mdps)
        inside = MapSet.new(b.players)

        ps =
          Enum.filter(norm, fn {x, y} ->
            MapSet.member?(inside, x) and MapSet.member?(inside, y)
          end)

        seated = MapSet.new(Enum.flat_map(ps, fn {x, y} -> [x, y] end))
        df = Enum.reject(b.players, &MapSet.member?(seated, &1))
        {{b, {Enum.sort_by(ps, fn {x, _} -> Position.order_key(ctx.pos, x) end), df}}, df}
      end)

    out
  end

  defp order(pos, a, b),
    do: if(Position.order_key(pos, a) <= Position.order_key(pos, b), do: {a, b}, else: {b, a})
end

defmodule AinalramiLab.Hybrid do
  @moduledoc """
  The pairer for fields the brute force cannot reach: one maximum-weight
  matching per bracket stage, on weights built from the variant.

  Where it comes from. The engine's own weight function is internal to
  `Ainalrami.Pairing` and not exposed, read-only or otherwise, so it
  cannot be made pluggable without changing the engine, which the lab is
  not allowed to do. What is exposed is the engine's matcher
  (`Ainalrami.WeightedMatching`, through `AinalramiVerify.Engine`), and
  `verify/` already has a second, independent encoding of C.04.3 as
  matching weights (`AinalramiVerify.Weights`, the one certificates are
  checked against). This module is that encoding with the variant
  plugged in:

    * one mixed-radix digit (or two, for [C8]) per criterion, in the
      variant's order, so dropping a criterion removes its digit and
      reordering criteria reorders digits;
    * legality and colours from `AinalramiLab.Rules` with the variant's
      parameters;
    * below every criterion, digits for Article 4's order (below).

  The stage of bracket `b` is `b` plus every resident below it; its
  maximum-weight matching, restricted to `b`, is `b`'s pairs, and `b`'s
  unpaired players are the next bracket's MDPs. [C9]'s gate ("exactly
  one downfloater") is decided by solving without it first and again
  with it when the first answer floats exactly one player.

  ## What is not proved, and what was measured

  Article 4's sequence is an order on whole candidates, not a sum over
  pairs. `order_digits/4` encodes each term of
  `AinalramiVerify.Bracket.sequence_key/3` as its own digit (which MDPs
  are paired and to whom, then the remainder's exchanges, the sums, the
  exchanged players and the S1 partners), in a second pass once the
  first has fixed who the MDPs take. That the resulting sums order every
  pair of tied candidates exactly as the key does is not proved. It was
  measured: equal to the brute force on every round tried, under the
  baseline and under eight variants, and equal to the engine on every
  round tried from 24 to 100 players (`README.md` has the counts). If it
  is ever wrong, it is wrong for both arms of a comparison alike, since
  both use the same pairer.
  """

  alias AinalramiLab.{Rules, Variant}
  alias AinalramiVerify.{Bracket, Engine, Position}

  @doc "Pair the position under the variant. Same shape as `AinalramiLab.Brute.pair/2`."
  def pair(%Position{} = pos0, %Variant{} = v) do
    pos = Rules.position(pos0, v)
    ranks = Position.sort(pos, pos.pool) |> List.to_tuple()
    n = tuple_size(ranks)
    index = for i <- 0..(n - 1)//1, into: %{}, do: {elem(ranks, i), i}
    ctx = %Bracket.Ctx{pos: pos, ranks: ranks, index: index, adj: %{}, memo: make_ref()}
    groups = Bracket.scoregroups(ctx)

    result =
      Enum.reduce_while(0..(length(groups) - 1)//1, {:ok, [], []}, fn k, {:ok, acc, mdps} ->
        b = Bracket.bracket(ctx, groups, k, mdps)
        below = groups |> Enum.drop(k + 1) |> Enum.flat_map(&elem(&1, 1))

        next =
          case Enum.at(groups, k + 1) do
            nil -> []
            {_, rs} -> rs
          end

        case solve_bracket(pos, b, below, next, v, k == 0) do
          {:ok, ps, df} -> {:cont, {:ok, acc ++ ps, df}}
          :none -> {:halt, :none}
        end
      end)

    case result do
      :none ->
        {:error, :no_legal_pairing}

      {:ok, pairs, left} ->
        case left do
          l when length(l) > 1 ->
            {:error, :no_legal_pairing}

          _ ->
            coloured = Enum.map(pairs, fn {a, b} -> Rules.colours(pos, a, b, v) end)

            {:ok,
             %{
               pairs: Enum.map(coloured, fn {w, b, _} -> {w, b} end),
               bye: List.first(left),
               articles: Enum.map(coloured, &elem(&1, 2))
             }}
        end
    end
  end

  defp solve_bracket(pos, b, below, next, v, first?) do
    with {:ok, ps, df} <- solve_stage(pos, b, below, next, v, false, first?) do
      if length(df) == 1 and "C9" in v.order do
        case solve_stage(pos, b, below, next, v, true, first?) do
          {:ok, ps2, [_] = df2} -> {:ok, ps2, df2}
          _ -> {:ok, ps, df}
        end
      else
        {:ok, ps, df}
      end
    end
  end

  # Two passes: the first fixes the criteria and who the MDPs take, the
  # second orders the remainder Article 4's way (see `order_digits/4`).
  defp solve_stage(pos, b, below, next, v, single_df?, first?) do
    with {:ok, ps, _df} <- solve_once(pos, b, below, next, v, single_df?, first?, nil) do
      mdps = MapSet.new(b.mdps)

      seated =
        for {x, y} <- ps,
            MapSet.member?(mdps, x) or MapSet.member?(mdps, y),
            z <- [x, y],
            into: MapSet.new(),
            do: z

      remainder = Enum.reject(b.residents, &MapSet.member?(seated, &1))
      rset = MapSet.new(remainder)
      n1 = Enum.count(ps, fn {x, y} -> MapSet.member?(rset, x) and MapSet.member?(rset, y) end)
      solve_once(pos, b, below, next, v, single_df?, first?, {remainder, n1})
    end
  end

  defp solve_once(pos, b, below, next, v, single_df?, first?, remainder) do
    w = stage(pos, b, below, next, single_df?, v, remainder)
    vertices = w.vertices
    idx = vertices |> Enum.with_index() |> Map.new()
    back = vertices |> Enum.with_index() |> Map.new(fn {r, i} -> {i, r} end)
    edges = for {{x, y}, wt} <- w.edges, do: {idx[x], idx[y], wt}

    mate =
      if edges == [] do
        %{}
      else
        Engine.max_weight_matching(length(vertices), edges).mate
      end

    matched = for {i, j} <- mate, i < j, do: {back[i], back[j]}
    seated = MapSet.new(Enum.flat_map(matched, fn {x, y} -> [x, y] end))
    unmatched = Enum.reject(vertices, &MapSet.member?(seated, &1))

    feasible? =
      not first? or
        (length(unmatched) <= 1 and
           Enum.all?(unmatched, &AinalramiVerify.Rules.bye_eligible?(pos, &1)))

    if feasible? do
      in_b = MapSet.new(b.players)

      ps =
        for {x, y} <- matched, MapSet.member?(in_b, x) and MapSet.member?(in_b, y) do
          if Position.order_key(pos, x) <= Position.order_key(pos, y), do: {x, y}, else: {y, x}
        end

      paired = MapSet.new(Enum.flat_map(ps, fn {x, y} -> [x, y] end))
      df = Enum.reject(b.players, &MapSet.member?(paired, &1))
      {:ok, Enum.sort_by(ps, fn {x, _} -> Position.order_key(pos, x) end), df}
    else
      :none
    end
  end

  @doc """
  The weights of one stage under the variant: `%{vertices:, edges: %{{u,
  v} => weight}, digits: [name]}`. Under the baseline, digits for
  `pairs`, `bye`, and [C5]-[C21] equal `AinalramiVerify.Weights.stage/5`'s,
  followed by the order digits (`order_digits/4`).
  """
  def stage(pos, b, below_ranks, next_ranks, single_df?, v, remainder \\ nil)

  def stage(%Position{} = pos, b, below_ranks, next_ranks, single_df?, %Variant{} = v, remainder) do
    vertices = Enum.sort(b.players ++ below_ranks)
    in_b = MapSet.new(b.players)
    in_next = MapSet.new(next_ranks)
    nb = MapSet.union(in_b, in_next)
    residents = MapSet.new(b.residents)
    mdps = MapSet.new(b.mdps)
    p = pos.players
    nr = length(vertices)

    level = fn set ->
      set
      |> Enum.map(&p[&1].score)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index()
      |> Map.new()
    end

    lv_all = level.(vertices)
    lv_b = level.(b.players)
    lv_nb = level.(MapSet.to_list(nb))
    base_all = nr + 1
    base_b = length(b.players) + 1
    base_nb = MapSet.size(nb) + 1

    p5 = fn x -> pow(base_all, lv_all[p[x].score]) end
    p7 = fn x -> pow(base_b, lv_b[p[x].score]) end
    p8 = fn x -> pow(base_nb, lv_nb[p[x].score]) end
    p9 = fn x -> if single_df? and MapSet.member?(in_b, x), do: p[x].unplayed, else: 0 end
    inel = fn x -> if AinalramiVerify.Rules.bye_eligible?(pos, x), do: 0, else: 1 end

    base_d = length(b.players) + 1
    pd = fn e -> if e <= 0, do: 0, else: pow(base_d, e) end
    max_e = 2 * (Enum.max(Enum.map(b.players, &p[&1].score), fn -> 0 end) - b.score) + 1
    pd_max = pd.(max_e)

    limbo = fn m -> if v.c18 == :limbo, do: pd.(2 * (p[m].score - b.score) + 1), else: 0 end
    paired_pen = fn m, o -> pd.(2 * max(p[m].score - p[o].score, 0)) end

    # limbo (the baseline): a seated MDP earns its Limbo penalty minus its
    # cost here, so an unseated one costs its Limbo penalty.
    mdp_reward = fn back, m, o ->
      if MapSet.member?(mdps, m) and Rules.floated?(pos, m, :down, back),
        do: limbo.(m) - paired_pen.(m, o),
        else: 0
    end

    # c18=paired: only seated MDPs cost anything. That is a negative
    # reward, so every pair of the bracket gets 2 * pd_max and pays its
    # MDPs' costs out of it; the number of pairs in the bracket is fixed
    # by [C6] above, so the constant cancels. (Exact only while C6
    # precedes C18/C20 in the order.)
    mdp_cost = fn back, m, o ->
      if MapSet.member?(mdps, m) and Rules.floated?(pos, m, :down, back),
        do: paired_pen.(m, o),
        else: 0
    end

    cross = fn x, y ->
      cond do
        p[x].score > p[y].score -> {x, y}
        p[y].score > p[x].score -> {y, x}
        true -> nil
      end
    end

    up_pen = fn back, x, y ->
      case cross.(x, y) do
        {h, l} ->
          if Rules.floated?(pos, l, :up, back),
            do: {1, pd.(2 * (p[h].score - p[l].score))},
            else: {0, 0}

        nil ->
          {0, 0}
      end
    end

    half_b = div(length(b.players), 2)
    half_r = div(nr, 2)
    sum = fn f, set -> set |> Enum.map(f) |> Enum.sum() end
    b_list = b.players
    bsn = b.players |> Enum.with_index(1) |> Map.new()
    mdp_bound = sum.(fn m -> if MapSet.member?(mdps, m), do: limbo.(m), else: 0 end, b_list)

    f14 = fn x, back ->
      if MapSet.member?(residents, x) and Rules.floated?(pos, x, :down, back), do: 1, else: 0
    end

    # {digit, bound, fn(u, v, both_b?, nb_edge?, costs) -> value}
    family = fn
      "C5" ->
        [{:c5, sum.(p5, vertices), fn x, y, _, _, _ -> p5.(x) + p5.(y) end}]

      "C6" ->
        [{:c6, half_b, fn _, _, bb, _, _ -> if(bb, do: 1, else: 0) end}]

      "C7" ->
        [{:c7, sum.(p7, b_list), fn x, y, bb, _, _ -> if(bb, do: p7.(x) + p7.(y), else: 0) end}]

      "C8" ->
        [
          {:c8_pairs, div(MapSet.size(nb), 2), fn _, _, _, ne, _ -> if(ne, do: 1, else: 0) end},
          {:c8_scores, sum.(p8, MapSet.to_list(nb)),
           fn x, y, _, ne, _ -> if(ne, do: p8.(x) + p8.(y), else: 0) end}
        ]

      "C9" ->
        [{:c9, sum.(p9, b_list), fn x, y, _, _, _ -> p9.(x) + p9.(y) end}]

      c when c in ["C10", "C11", "C12", "C13"] ->
        k = c |> String.downcase() |> String.to_existing_atom()
        [{k, 2 * half_b, fn _, _, bb, _, cs -> if(bb, do: 2 - cs[k], else: 0) end}]

      c when c in ["C14", "C16", "C16@3"] ->
        back = back(c)

        [
          {c, length(b_list),
           fn x, y, bb, _, _ -> if(bb, do: f14.(x, back) + f14.(y, back), else: 0) end}
        ]

      c when c in ["C15", "C17", "C17@3"] ->
        back = back(c)

        [
          {c, half_b,
           fn x, y, bb, _, _ -> if(bb, do: 1 - elem(up_pen.(back, x, y), 0), else: 0) end}
        ]

      c when c in ["C18", "C20", "C20@3"] ->
        back = back(c)

        case v.c18 do
          :limbo ->
            [
              {c, mdp_bound,
               fn x, y, bb, _, _ ->
                 if(bb, do: mdp_reward.(back, x, y) + mdp_reward.(back, y, x), else: 0)
               end}
            ]

          :paired ->
            [
              {c, half_b * 2 * pd_max,
               fn x, y, bb, _, _ ->
                 if(bb,
                   do: 2 * pd_max - mdp_cost.(back, x, y) - mdp_cost.(back, y, x),
                   else: 0
                 )
               end}
            ]
        end

      c when c in ["C19", "C21", "C21@3"] ->
        back = back(c)

        [
          {c, half_b * pd_max,
           fn x, y, bb, _, _ -> if(bb, do: pd_max - elem(up_pen.(back, x, y), 1), else: 0) end}
        ]
    end

    digits =
      [
        {:pairs, half_r, fn _, _, _, _, _ -> 1 end},
        {:bye, sum.(inel, vertices), fn x, y, _, _, _ -> inel.(x) + inel.(y) end}
      ] ++ Enum.flat_map(v.order, family) ++ order_digits(b, bsn, mdps, remainder)

    radices = Enum.map(digits, fn {_, bound, _} -> bound + 1 end)
    need_colour? = Enum.any?(v.order, &(&1 in ["C10", "C11", "C12", "C13"]))

    edges =
      for x <- vertices,
          y <- vertices,
          x < y,
          Rules.legal?(pos, x, y, v),
          into: %{} do
        bb = MapSet.member?(in_b, x) and MapSet.member?(in_b, y)

        ne =
          (MapSet.member?(in_next, x) or MapSet.member?(in_next, y)) and
            MapSet.member?(nb, x) and MapSet.member?(nb, y)

        costs = if bb and need_colour?, do: Rules.colour_costs(pos, x, y, v), else: nil
        values = Enum.map(digits, fn {_, _, f} -> f.(x, y, bb, ne, costs) end)
        {{x, y}, pack(values, radices)}
      end

    %{vertices: vertices, edges: edges, digits: Enum.map(digits, &elem(&1, 0))}
  end

  # Article 4's order as digits below every criterion, following
  # `AinalramiVerify.Bracket.sequence_key/3`'s terms one by one:
  #
  #   * MDPs: which MDPs are paired, earliest MDP first (one digit per
  #     MDP), then each MDP's resident partner, as high-ranked as
  #     possible (one digit per MDP). An MDP-MDP pair earns neither,
  #     which is how such candidates sort last.
  #   * the remainder (second pass only, once the first pass has said who
  #     the MDPs take): the fewest exchanges (players of S1 who are not
  #     the higher end of a pair), then the smallest sum of the higher
  #     ends' numbers, then, for each S1 position in turn, the
  #     highest-ranked partner.
  #
  # Each term is encoded as its own digit, so the comparison is
  # lexicographic in the same order as the key. What is not proved is that
  # the sum over pairs of these digits orders every pair of candidates as
  # the key does; it is measured instead (lab/README.md).
  defp order_digits(b, bsn, mdps, remainder) do
    len = length(b.players)
    is_mdp = fn x -> MapSet.member?(mdps, x) end

    mdp_res = fn m, x, y ->
      cond do
        x == m and not is_mdp.(y) -> y
        y == m and not is_mdp.(x) -> x
        true -> nil
      end
    end

    mdp_digits =
      Enum.flat_map(Enum.with_index(b.mdps), fn {m, i} ->
        [
          {{:mdp_set, i}, 1,
           fn x, y, bb, _, _ -> if(bb and mdp_res.(m, x, y) != nil, do: 1, else: 0) end}
        ]
      end) ++
        Enum.map(Enum.with_index(b.mdps), fn {m, i} ->
          {{:mdp_partner, i}, len,
           fn x, y, bb, _, _ ->
             case bb and mdp_res.(m, x, y) do
               r when is_integer(r) -> len + 1 - bsn[r]
               _ -> 0
             end
           end}
        end)

    rem_digits =
      case remainder do
        nil ->
          []

        {players, n1} ->
          rb = players |> Enum.with_index(1) |> Map.new()
          size = length(players)

          ends = fn x, y ->
            case {rb[x], rb[y]} do
              {nil, _} -> nil
              {_, nil} -> nil
              {a, c} -> {min(a, c), max(a, c)}
            end
          end

          [
            {:exchanges, max(div(size, 2), 1),
             fn x, y, bb, _, _ ->
               case bb and ends.(x, y) do
                 {lo, _} when lo <= n1 -> 1
                 _ -> 0
               end
             end},
            {:s1_sum, max(div(size, 2), 1) * (size + 1),
             fn x, y, bb, _, _ ->
               case bb and ends.(x, y) do
                 {lo, _} -> size + 1 - lo
                 _ -> 0
               end
             end},
            # 3.6's `-out`: the S1 players exchanged out, highest number
            # first. With the count of S1 players kept fixed by
            # :exchanges, maximising sum(out 2^i) is paying each kept S1
            # player 2^(n1+1) - 2^i.
            {:out_high, max(div(size, 2), 1) * pow(2, n1 + 1),
             fn x, y, bb, _, _ ->
               case bb and ends.(x, y) do
                 {lo, _} when lo <= n1 -> pow(2, n1 + 1) - pow(2, lo)
                 _ -> 0
               end
             end},
            # 3.6's `inn`: the S2 players exchanged in, lowest number first.
            {:inn_low, pow(2, size + 1),
             fn x, y, bb, _, _ ->
               case bb and ends.(x, y) do
                 {lo, _} when lo > n1 -> pow(2, size - lo)
                 _ -> 0
               end
             end}
          ] ++
            Enum.map(1..max(size, 1)//1, fn i ->
              {{:s1_partner, i}, size,
               fn x, y, bb, _, _ ->
                 case bb and ends.(x, y) do
                   {^i, hi} -> size + 1 - hi
                   _ -> 0
                 end
               end}
            end)
      end

    mdp_digits ++ rem_digits
  end

  defp back(c) do
    cond do
      String.ends_with?(c, "@3") -> 3
      c in ["C14", "C15", "C18", "C19"] -> 1
      true -> 2
    end
  end

  defp pack(values, radices) do
    Enum.zip(values, radices)
    |> Enum.reduce(0, fn {val, r}, acc ->
      if val < 0 or val >= r, do: raise("digit #{val} outside radix #{r}")
      acc * r + val
    end)
  end

  defp pow(_b, 0), do: 1
  defp pow(b, e) when e > 0, do: b * pow(b, e - 1)
end

defmodule AinalramiVerify.Weights do
  @moduledoc """
  The edge weights of one bracket stage, recomputed from the rules.

  A stage is one bracket `b` of the round (as the published round implies
  it, `AinalramiVerify.Bracket.structure/2`) together with everyone still
  unpaired below it: the vertices are `R` = the bracket's players plus all
  residents of lower scoregroups, the edges every legal pair ([C1], [C3])
  of `R`. A matching of `R` is a candidate for `b` plus a completion of
  the round below it.

  The weight of an edge is a number in mixed radix: one digit per
  criterion, highest priority first, each digit's radix larger than the
  most that digit can sum to over any matching (`bound`). So a heavier
  matching is exactly a lexicographically better vector, and a
  maximum-weight matching of `R` is a best candidate for `b` by 3.8.1's
  comparison - on criteria. (3.8.1's last resort, the generation order of
  Article 4, is not a weight; `AinalramiVerify.RuleCheck` checks it.)

  Every criterion is a sum over the matching. A per-player criterion
  ("minimise the scores of the downfloaters") becomes a per-edge reward:
  a player's penalty for being left over is paid to every edge that seats
  them, so the matching's total is a constant minus the penalties of those
  it leaves over. The digits, highest first:

  | digit | rule | per edge `u`-`v` |
  |---|---|---|
  | pairs | [C4], 1.9.1: everyone paired but at most one | 1 |
  | bye | [C2]: the one left over may take the bye | 1 for each end that may not |
  | C5 | lowest score for the bye | `B^level(score)` for each end |
  | C6 | most pairs in `b` | 1 if both ends in `b` |
  | C7 | lowest downfloater scores, highest first | for each end, `B^level(score)` if both ends in `b` |
  | C8 pairs | the next bracket's pairs ([C8] on [C6]) | 1 if an end is in the next scoregroup and the other in `b` or there |
  | C8 scores | its downfloaters' scores ([C8] on [C7]) | `B^level` for each end, on those edges |
  | C9 | fewest unplayed games for a lone downfloater that takes the bye | each end in `b`: its unplayed games (only when `b` downfloats exactly one player) |
  | C10-C13 | colour criteria of the pair after Article 5 | `2 - cost` if both ends in `b` |
  | C14, C16 | resident downfloaters who floated down 1 / 2 rounds ago | for each such end, 1 if both ends in `b` |
  | C15, C17 | MDP opponents who floated up 1 / 2 rounds ago | `1 - cost` if both ends in `b` |
  | C18, C20 | score differences of MDPs who floated down | for each such MDP end: its Limbo penalty minus its penalty paired here |
  | C19, C21 | score differences of MDP opponents who floated up | `max - penalty` if both ends in `b` |

  The readings are `AinalramiVerify.Bracket`'s, so the brute force and
  the weights answer the same question; the test suite holds them to each
  other.
  """

  alias AinalramiVerify.{Position, Rules}

  @version "c0403-2026-tiers-1"
  def version, do: @version

  @doc """
  The stage of bracket `b` (a `Bracket.B`): `%{vertices: [rank], edges:
  %{{u, v} => weight}}` with `u < v`. `single_df?` says whether the
  published round downfloats exactly one player from `b` ([C9]'s gate).
  """
  def stage(%Position{} = pos, b, below_ranks, next_ranks, single_df?) do
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

    p5 = fn v -> pow(base_all, lv_all[p[v].score]) end
    p7 = fn v -> pow(base_b, lv_b[p[v].score]) end
    p8 = fn v -> pow(base_nb, lv_nb[p[v].score]) end
    p9 = fn v -> if single_df? and MapSet.member?(in_b, v), do: p[v].unplayed, else: 0 end
    inel = fn v -> if Rules.bye_eligible?(pos, v), do: 0, else: 1 end

    # C18-C21: exponents are quarter-point differences (see Bracket).
    base_d = length(b.players) + 1
    pd = fn e -> if e <= 0, do: 0, else: pow(base_d, e) end
    max_e = 2 * (Enum.max(Enum.map(b.players, &p[&1].score), fn -> 0 end) - b.score) + 1
    pd_max = pd.(max_e)

    limbo = fn m -> pd.(2 * (p[m].score - b.score) + 1) end
    paired = fn m, o -> pd.(2 * max(p[m].score - p[o].score, 0)) end

    mdp_reward = fn back, m, o ->
      if MapSet.member?(mdps, m) and Rules.floated?(pos, m, :down, back),
        do: limbo.(m) - paired.(m, o),
        else: 0
    end

    cross = fn u, v ->
      cond do
        p[u].score > p[v].score -> {u, v}
        p[v].score > p[u].score -> {v, u}
        true -> nil
      end
    end

    up_pen = fn back, u, v ->
      case cross.(u, v) do
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

    digits = [
      {:pairs, half_r},
      {:bye, sum.(inel, vertices)},
      {:c5, sum.(p5, vertices)},
      {:c6, half_b},
      {:c7, sum.(p7, b_list)},
      {:c8_pairs, div(MapSet.size(nb), 2)},
      {:c8_scores, sum.(p8, MapSet.to_list(nb))},
      {:c9, sum.(p9, b_list)},
      {:c10, 2 * half_b},
      {:c11, 2 * half_b},
      {:c12, 2 * half_b},
      {:c13, 2 * half_b},
      {:c14, length(b_list)},
      {:c15, half_b},
      {:c16, length(b_list)},
      {:c17, half_b},
      {:c18, sum.(fn m -> if MapSet.member?(mdps, m), do: limbo.(m), else: 0 end, b_list)},
      {:c19, half_b * pd_max},
      {:c20, sum.(fn m -> if MapSet.member?(mdps, m), do: limbo.(m), else: 0 end, b_list)},
      {:c21, half_b * pd_max}
    ]

    radices = digits |> Enum.map(fn {_, bound} -> bound + 1 end)

    edges =
      for u <- vertices,
          v <- vertices,
          u < v,
          Rules.legal?(pos, u, v),
          into: %{} do
        both_b = MapSet.member?(in_b, u) and MapSet.member?(in_b, v)

        nb_edge =
          (MapSet.member?(in_next, u) or MapSet.member?(in_next, v)) and MapSet.member?(nb, u) and
            MapSet.member?(nb, v)

        costs = if both_b, do: Rules.colour_costs(pos, u, v), else: nil

        f14 = fn x, back ->
          if MapSet.member?(residents, x) and Rules.floated?(pos, x, :down, back), do: 1, else: 0
        end

        {u15, u19} = if both_b, do: up_pen.(1, u, v), else: {0, 0}
        {u17, u21} = if both_b, do: up_pen.(2, u, v), else: {0, 0}

        values = [
          1,
          inel.(u) + inel.(v),
          p5.(u) + p5.(v),
          if(both_b, do: 1, else: 0),
          if(both_b, do: p7.(u) + p7.(v), else: 0),
          if(nb_edge, do: 1, else: 0),
          if(nb_edge, do: p8.(u) + p8.(v), else: 0),
          p9.(u) + p9.(v),
          if(both_b, do: 2 - costs.c10, else: 0),
          if(both_b, do: 2 - costs.c11, else: 0),
          if(both_b, do: 2 - costs.c12, else: 0),
          if(both_b, do: 2 - costs.c13, else: 0),
          if(both_b, do: f14.(u, 1) + f14.(v, 1), else: 0),
          if(both_b, do: 1 - u15, else: 0),
          if(both_b, do: f14.(u, 2) + f14.(v, 2), else: 0),
          if(both_b, do: 1 - u17, else: 0),
          if(both_b, do: mdp_reward.(1, u, v) + mdp_reward.(1, v, u), else: 0),
          if(both_b, do: pd_max - u19, else: 0),
          if(both_b, do: mdp_reward.(2, u, v) + mdp_reward.(2, v, u), else: 0),
          if(both_b, do: pd_max - u21, else: 0)
        ]

        {{u, v}, pack(values, radices)}
      end

    %{vertices: vertices, edges: edges, digits: Enum.map(digits, &elem(&1, 0))}
  end

  defp pack(values, radices) do
    Enum.zip(values, radices)
    |> Enum.reduce(0, fn {v, r}, acc ->
      if v < 0 or v >= r, do: raise("digit #{v} outside radix #{r}")
      acc * r + v
    end)
  end

  defp pow(_b, 0), do: 1
  defp pow(b, e) when e > 0, do: b * pow(b, e - 1)

  @doc "The total weight of a matching (`[{u, v}]`)."
  def weight(%{edges: edges}, matching) do
    Enum.reduce(matching, 0, fn {u, v}, acc -> acc + Map.fetch!(edges, norm(u, v)) end)
  end

  def norm(u, v) when u < v, do: {u, v}
  def norm(u, v), do: {v, u}
end

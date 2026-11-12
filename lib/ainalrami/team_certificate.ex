defmodule Ainalrami.TeamCertificate do
  @moduledoc """
  A C.04.6 team round's input record and its optimality certificate.

  This module pairs nothing. `Ainalrami.TeamPairing` pairs the round; this
  writes down what it was given and what it answered, and then builds a
  certificate that the answer is the round C.04.6 defines - the dual
  solutions of the matchings that define it, so that a checker holding
  nothing but the input can confirm the round with integer arithmetic.
  The checker is `ainalrami-verify team-check` (`verify/`), which shares no
  code with this module or with the engine: it recomputes every weight from
  the input on its own and refuses duals that do not fit them, so a wrong
  certificate fails rather than lies.

  ## The input record (`input/2`, `decode_input/1`)

  `%{"format" => "ainalrami-team-input", "version" => 1, ...}`: the round,
  the settings and, per team, exactly the fields of
  `Ainalrami.TeamPairing.Team` - a JSON-ready map with string keys. A host
  that stores it (as text, so its SHA-256 never moves) can hand it back to
  `decode_input/1` and `Ainalrami.TeamPairing.pair_round/2` to reproduce
  the round.

  ## What the certificate proves

  The readings are `docs/team-proof-large-fields.md`'s, which the exact
  reference and the naive enumeration agree on; the method is that
  document's sections 2-4, with each matching's optimum carried as a dual:

    * **3.4** - for every eligible team ahead of the bye in 3.4.2-3.4.4's
      order, a dual bound showing the rest has no perfect matching without
      a rematch (so 3.4.1 passes it over); the bye's own rest is paired by
      the round itself.
    * **3.5** - per bracket, the round restricted to everything not yet
      paired is a cheapest perfect matching under the digits [C4], [C5]
      (one per score level, lowest first), [C6], [C7] and 3.5.4's order.
      The upfloaters are the lower teams it seats against residents, and
      the cheapest cost fixes that set uniquely.
    * **3.6** - per bracket, two duals: the round's pairing of the bracket
      is a cheapest perfect matching under [C8], [C10], the soft pairs and
      the top set's place in identifier order, and then, confined to that
      top set, under the same criteria and the bottom sequence. So no
      pairing is better on the criteria, and none that ties comes earlier.

  Article 4 needs no dual: the checker allocates each pair's colours itself
  and compares. Type B colour preferences are not certified (the input
  record is written, the certificate refuses with `{:unsupported, :type_b}`).

  ## Weights (`c0406-2026-2`)

  Every digit is a non-negative count per edge; a digit's base is one more
  than the sum, over the vertices, of the largest value it takes on an edge
  at that vertex, so the packed integer orders lexicographically. With
  `cost` packed and `C = (n / 2) * max_cost + 1`, an edge weighs `C - cost`:
  the maximum-weight matching is then perfect when one exists and, among
  perfect matchings, the cheapest. Duals are textbook (`y >= 0` per team,
  `z >= 0` per odd set) on the matcher's scale `f`:
  `f * (y_u + y_v + sum z) >= 2 * w`. The full statement of every digit is
  in `verify/README.md`, "Part 4".
  """

  import Bitwise

  alias Ainalrami.TeamPairing.Team
  alias Ainalrami.WeightedMatching

  @input_format "ainalrami-team-input"
  @format "ainalrami-team-certificate"
  @weights "c0406-2026-2"

  @doc "The weight model this module writes duals for."
  def weights_version, do: @weights

  # ---------------------------------------------------------------------
  # The input record
  # ---------------------------------------------------------------------

  @doc """
  The input record of a round: `teams` and `opts` exactly as handed to
  `Ainalrami.TeamPairing.pair_round/2`. Options that do not change a
  pairing (`:explain`, budgets) are left out.
  """
  def input(teams, opts) when is_list(teams) and is_list(opts) do
    %{
      "format" => @input_format,
      "version" => 1,
      "round" => Keyword.get(opts, :round),
      "expected_rounds" => Keyword.get(opts, :expected_rounds),
      "score_mode" => Atom.to_string(Keyword.get(opts, :score_mode, :match_points)),
      "use_secondary" => Keyword.get(opts, :use_secondary?, true),
      "type" => Atom.to_string(Keyword.get(opts, :type, :a)),
      "initial_colour" => Atom.to_string(Keyword.get(opts, :initial_colour, :white)),
      "absent" => opts |> Keyword.get(:absent, []) |> Enum.sort(),
      "forbidden_pairs" => groups_out(Keyword.get(opts, :forbidden_pairs)),
      "soft_pairs" => groups_out(Keyword.get(opts, :soft_pairs)),
      "teams" => teams |> Enum.sort_by(& &1.tpn) |> Enum.map(&team_out/1)
    }
  end

  defp team_out(%Team{} = t) do
    base = %{
      "tpn" => t.tpn,
      "match_points" => t.match_points,
      "game_points" => t.game_points,
      "opponents" => t.opponents,
      "colours" => Enum.map(t.colours, &Atom.to_string/1),
      "had_pab" => t.had_pab?,
      "won_by_forfeit" => t.won_by_forfeit?,
      "floated_last_round" => t.floated_last_round?
    }

    base =
      if is_integer(t.matches_played),
        do: Map.put(base, "matches_played", t.matches_played),
        else: base

    # C.04.7's virtual points, only when there are any: a record of a round
    # without them is byte for byte what it was before they existed.
    base
    |> put_nonzero("virtual_match_points", t.virtual_match_points)
    |> put_nonzero("virtual_game_points", t.virtual_game_points)
  end

  defp put_nonzero(map, key, value) do
    if value in [nil, 0, +0.0], do: map, else: Map.put(map, key, value)
  end

  defp groups_out(nil), do: []

  defp groups_out(groups) do
    Enum.map(groups, fn
      {tpns, first, last} -> %{"teams" => tpns, "from" => first, "to" => last}
      tpns -> %{"teams" => tpns}
    end)
  end

  @doc """
  `{:ok, teams, opts}` from an input record (string or atom-free JSON
  map), ready for `Ainalrami.TeamPairing.pair_round/2`, or `{:error,
  reason}`.
  """
  def decode_input(%{"format" => @input_format, "version" => 1, "teams" => teams} = m)
      when is_list(teams) do
    opts =
      [
        score_mode: mode(m["score_mode"]),
        use_secondary?: m["use_secondary"] != false,
        type: type(m["type"]),
        initial_colour: colour(m["initial_colour"] || "white"),
        absent: m["absent"] || [],
        round: m["round"],
        expected_rounds: m["expected_rounds"]
      ] ++
        groups_in(:forbidden_pairs, m["forbidden_pairs"]) ++
        groups_in(:soft_pairs, m["soft_pairs"])

    {:ok, Enum.map(teams, &team_in/1), opts}
  rescue
    e -> {:error, {:bad_input, Exception.message(e)}}
  end

  def decode_input(_), do: {:error, {:bad_input, "not an #{@input_format} version 1 record"}}

  defp team_in(t) do
    %Team{
      tpn: t["tpn"],
      match_points: t["match_points"],
      game_points: t["game_points"],
      opponents: t["opponents"] || [],
      colours: Enum.map(t["colours"] || [], &colour/1),
      had_pab?: t["had_pab"] == true,
      won_by_forfeit?: t["won_by_forfeit"] == true,
      floated_last_round?: t["floated_last_round"] == true,
      matches_played: t["matches_played"],
      virtual_match_points: t["virtual_match_points"] || 0.0,
      virtual_game_points: t["virtual_game_points"] || 0.0
    }
  end

  defp groups_in(_key, nil), do: []
  defp groups_in(_key, []), do: []

  defp groups_in(key, groups) do
    [
      {key,
       Enum.map(groups, fn
         %{"teams" => tpns, "from" => a, "to" => b} -> {tpns, a, b}
         %{"teams" => tpns} -> tpns
       end)}
    ]
  end

  defp mode("game_points"), do: :game_points
  defp mode(_), do: :match_points
  defp type("b"), do: :b
  defp type("none"), do: :none
  defp type(_), do: :a
  defp colour("white"), do: :white
  defp colour("black"), do: :black

  @doc """
  The round as a pairing list: the number of lines, then `white black` per
  match in the engine's order, then `tpn 0` for the pairing-allocated bye.
  """
  def output_text(%{pairs: pairs, bye: bye}) do
    lines = for p <- pairs, do: "#{p.white} #{p.black}"
    lines = if bye, do: lines ++ ["#{bye} 0"], else: lines
    Enum.join([Integer.to_string(length(lines)) | lines], "\n") <> "\n"
  end

  # ---------------------------------------------------------------------
  # The certificate
  # ---------------------------------------------------------------------

  @doc """
  The certificate of `result` (`Ainalrami.TeamPairing.pair_round/2`'s
  `{:ok, result}` map, or any `%{pairs: [%{white:, black:}], bye:}`) for
  the input record `input`. `input_sha256` is the SHA-256 of the record's
  text as stored, which the checker compares.

  Returns `{:ok, certificate_map}` or `{:error, reason}`: `{:not_optimal,
  step}` when the round is not the one the readings define (a finding),
  `{:unsupported, :type_b}`, or `{:bad_round, message}`.
  """
  def certify(input, result, input_sha256) when is_map(input) and is_binary(input_sha256) do
    with {:ok, ctx} <- context(input),
         {:ok, round} <- round_of(ctx, result),
         {:ok, bye_proof} <- bye_proof(ctx, round),
         {:ok, brackets} <- bracket_proofs(ctx, round) do
      {:ok,
       %{
         "format" => @format,
         "version" => 1,
         "weights" => @weights,
         "engine" => "ainalrami #{engine_version()}",
         "input_sha256" => input_sha256,
         "round" => ctx.round,
         "pairs" => Enum.map(round.pairs, fn {w, b} -> [w, b] end),
         "bye" => round.bye,
         "bye_passed_over" => bye_proof,
         "brackets" => brackets
       }}
    end
  rescue
    e -> {:error, {:bad_round, Exception.message(e)}}
  end

  defp engine_version do
    Application.load(:ainalrami)

    case Application.spec(:ainalrami, :vsn) do
      nil -> "unknown"
      v -> to_string(v)
    end
  end

  # Everything the weights read, per team, in halves of a point so scores
  # compare exactly.
  defp context(input) do
    case input["type"] do
      "b" ->
        {:error, {:unsupported, :type_b}}

      type ->
        primary = if input["score_mode"] == "game_points", do: "game_points", else: "match_points"
        round = input["round"]
        expected = input["expected_rounds"]
        last_two? = is_integer(round) and is_integer(expected) and round >= expected - 1

        teams =
          Map.new(input["teams"], fn t ->
            colours = Enum.map(t["colours"] || [], &colour/1)

            {t["tpn"],
             %{
               tpn: t["tpn"],
               score: halves(t[primary]) + halves(t["virtual_" <> primary] || 0),
               opponents: MapSet.new(t["opponents"] || []),
               colours: colours,
               played: t["matches_played"] || length(colours),
               eligible?: not (t["had_pab"] == true or t["won_by_forfeit"] == true),
               floated?: t["floated_last_round"] == true,
               preference: if(type == "none", do: nil, else: preference(colours))
             }}
          end)

        {:ok,
         %{
           round: round,
           last_two?: last_two?,
           teams: teams,
           forbidden: pairs_in_force(input["forbidden_pairs"], round),
           soft: pairs_in_force(input["soft_pairs"], round)
         }}
    end
  end

  defp halves(x) when is_integer(x), do: 2 * x
  defp halves(x) when is_float(x), do: round(x * 2)

  defp pairs_in_force(nil, _round), do: MapSet.new()

  defp pairs_in_force(groups, round) do
    for g <- groups,
        g["from"] == nil or (is_integer(round) and round >= g["from"] and round <= g["to"]),
        a <- g["teams"],
        b <- g["teams"],
        a < b,
        into: MapSet.new(),
        do: {a, b}
  end

  # 1.7.1, Type A - Type B's strong half is the same sentence.
  defp preference(colours) do
    cd = Enum.count(colours, &(&1 == :white)) - Enum.count(colours, &(&1 == :black))

    last_two =
      case Enum.reverse(colours) do
        [a, b | _] -> [a, b]
        _ -> nil
      end

    cond do
      cd < -1 -> :white
      cd > 1 -> :black
      cd in [0, -1] and last_two == [:black, :black] -> :white
      cd in [0, 1] and last_two == [:white, :white] -> :black
      true -> nil
    end
  end

  defp met?(ctx, a, b) do
    {x, y} = {min(a, b), max(a, b)}

    MapSet.member?(ctx.teams[a].opponents, b) or MapSet.member?(ctx.teams[b].opponents, a) or
      MapSet.member?(ctx.forbidden, {x, y})
  end

  defp round_of(ctx, %{pairs: pairs, bye: bye}) do
    pairs =
      Enum.map(pairs, fn
        %{white: w, black: b} -> {w, b}
        {w, b} -> {w, b}
      end)

    seated = Enum.flat_map(pairs, fn {w, b} -> [w, b] end) ++ List.wrap(bye)

    cond do
      Enum.sort(seated) != ctx.teams |> Map.keys() |> Enum.sort() ->
        {:error, {:bad_round, "the round does not seat every team of the input exactly once"}}

      true ->
        partner = Map.new(Enum.flat_map(pairs, fn {a, b} -> [{a, b}, {b, a}] end))
        {:ok, %{pairs: pairs, bye: bye, partner: partner}}
    end
  end

  # 3.4: every eligible team ahead of the bye in the order strands the rest.
  defp bye_proof(_ctx, %{bye: nil}), do: {:ok, []}

  defp bye_proof(ctx, %{bye: bye}) do
    ordered =
      ctx.teams
      |> Map.values()
      |> Enum.filter(& &1.eligible?)
      |> Enum.sort_by(&{&1.score, -&1.played, -&1.tpn})
      |> Enum.map(& &1.tpn)

    case Enum.find_index(ordered, &(&1 == bye)) do
      nil ->
        {:error, {:not_optimal, "3.4: the bye is not eligible ([C2])"}}

      i ->
        all = Map.keys(ctx.teams)

        Enum.take(ordered, i)
        |> Enum.reduce_while({:ok, []}, fn t, {:ok, acc} ->
          vertices = Enum.sort(all -- [t])

          edges =
            for a <- vertices,
                b <- vertices,
                a < b,
                not met?(ctx, a, b),
                into: %{},
                do: {{a, b}, 1}

          case unpairable_dual(vertices, edges) do
            {:ok, dual} -> {:cont, {:ok, [Map.put(dual, "team", t) | acc]}}
            :error -> {:halt, {:error, {:not_optimal, "3.4: team #{t} leaves the rest pairable"}}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          e -> e
        end
    end
  end

  # 3.3.2's loop over the round's own pairs.
  defp bracket_proofs(ctx, round) do
    remaining = ctx.teams |> Map.keys() |> List.delete(round.bye) |> Enum.sort()
    brackets(ctx, round, remaining, [])
  end

  defp brackets(_ctx, _round, [], acc), do: {:ok, Enum.reverse(acc)}

  defp brackets(ctx, round, remaining, acc) do
    top = remaining |> Enum.map(&ctx.teams[&1].score) |> Enum.max()
    {residents, lower} = Enum.split_with(remaining, &(ctx.teams[&1].score == top))
    resident? = MapSet.new(residents)

    ups = Enum.filter(lower, &MapSet.member?(resident?, round.partner[&1]))
    bracket = Enum.sort(residents ++ ups)
    in_bracket = MapSet.new(bracket)

    inside = fn set ->
      for {a, b} <- round.pairs,
          MapSet.member?(set, a) and MapSet.member?(set, b),
          do: {min(a, b), max(a, b)}
    end

    remaining_set = MapSet.new(remaining)

    upfloat_w = upfloat_weights(ctx, residents, lower)
    tops_w = tops_weights(ctx, bracket, MapSet.new(ups))
    tops = for {a, _b} <- inside.(in_bracket), do: a
    bottoms_w = bottoms_weights(ctx, bracket, MapSet.new(ups), tops)

    with {:ok, upfloat} <- optimal_dual(upfloat_w, inside.(remaining_set), "3.5"),
         {:ok, tops_d} <- optimal_dual(tops_w, inside.(in_bracket), "3.6 top set"),
         {:ok, bottoms_d} <- optimal_dual(bottoms_w, inside.(in_bracket), "3.6 bottoms") do
      entry = %{
        "score" => top / 2,
        "residents" => residents,
        "upfloaters" => Enum.sort(ups),
        "upfloat" => upfloat,
        "tops" => tops_d,
        "bottoms" => bottoms_d
      }

      brackets(ctx, round, Enum.sort(lower -- ups), [entry | acc])
    end
  end

  # ---------------------------------------------------------------------
  # Weights - see the moduledoc and verify/README.md, "Part 4"
  # ---------------------------------------------------------------------

  # 3.5 over everything not yet paired: [C4], [C5] per level (lowest
  # first), [C6], [C7], 3.5.4.
  defp upfloat_weights(ctx, residents, lower) do
    resident? = MapSet.new(residents)
    nl = length(lower)
    levels = lower |> Enum.map(&ctx.teams[&1].score) |> Enum.uniq() |> Enum.sort()
    level = levels |> Enum.with_index() |> Map.new()

    # [C6]'s following scoregroup: the next score below the residents' among
    # EVERY team of the round (the bye's included), not among those left -
    # when no team of it is left, no edge carries `u` and [C6] is met.
    top = ctx.teams[hd(residents)].score

    following =
      ctx.teams
      |> Map.values()
      |> Enum.map(& &1.score)
      |> Enum.filter(&(&1 < top))
      |> Enum.max(fn -> nil end)

    place =
      lower
      |> Enum.sort_by(&{-ctx.teams[&1].score, &1})
      |> Enum.with_index()
      |> Map.new()

    names = [:k] ++ Enum.map(0..(length(levels) - 1)//1, &{:c5, &1}) ++ [:u, :c7, :pos]
    vertices = Enum.sort(residents ++ lower)

    digits = fn a, b ->
      case {MapSet.member?(resident?, a), MapSet.member?(resident?, b)} do
        {true, true} ->
          %{}

        {false, false} ->
          sa = ctx.teams[a].score == following
          sb = ctx.teams[b].score == following
          if sa != sb, do: %{u: 1}, else: %{}

        {ra, _} ->
          l = if ra, do: b, else: a

          %{
            :k => 1,
            {:c5, level[ctx.teams[l].score]} => 1,
            :c7 => if(not ctx.last_two? and ctx.teams[l].floated?, do: 1, else: 0),
            :pos => (1 <<< nl) - (1 <<< (nl - place[l]))
          }
      end
    end

    weigh(ctx, vertices, names, digits, fn _a, _b -> true end)
  end

  defp criteria(ctx, ups) do
    fn a, b ->
      ta = ctx.teams[a]
      tb = ctx.teams[b]

      c10 =
        if ctx.last_two?,
          do: 0,
          else:
            if(MapSet.member?(ups, b) and ta.floated?, do: 1, else: 0) +
              if(MapSet.member?(ups, a) and tb.floated?, do: 1, else: 0)

      %{
        c8: if(ta.preference != nil and ta.preference == tb.preference, do: 1, else: 0),
        c10: c10,
        soft: if(MapSet.member?(ctx.soft, {min(a, b), max(a, b)}), do: 1, else: 0)
      }
    end
  end

  defp tops_weights(ctx, bracket, ups) do
    m = length(bracket)
    index = bracket |> Enum.with_index() |> Map.new()
    crit = criteria(ctx, ups)

    digits = fn a, b ->
      Map.put(crit.(a, b), :tops, (1 <<< m) - (1 <<< (m - index[min(a, b)])))
    end

    weigh(ctx, bracket, [:c8, :c10, :soft, :tops], digits, fn _a, _b -> true end)
  end

  defp bottoms_weights(ctx, bracket, ups, tops) do
    h = length(tops)
    top_rank = tops |> Enum.sort() |> Enum.with_index() |> Map.new()
    bottom_rank = (bracket -- tops) |> Enum.sort() |> Enum.with_index() |> Map.new()
    crit = criteria(ctx, ups)

    digits = fn a, b ->
      Map.put(crit.(a, b), :bottoms, bottom_rank[b] * Integer.pow(h, h - 1 - top_rank[a]))
    end

    allowed = fn a, b -> Map.has_key?(top_rank, a) and Map.has_key?(bottom_rank, b) end
    weigh(ctx, bracket, [:c8, :c10, :soft, :bottoms], digits, allowed)
  end

  # `%{vertices:, edges: %{{a, b} => weight}}`, a < b, over the legal pairs
  # `allowed` keeps.
  defp weigh(ctx, vertices, names, digits, allowed) do
    valued =
      for a <- vertices,
          b <- vertices,
          a < b,
          not met?(ctx, a, b),
          allowed.(a, b),
          do: {a, b, digits.(a, b)}

    bases =
      Enum.map(names, fn name ->
        per_vertex =
          Enum.reduce(valued, %{}, fn {a, b, d}, acc ->
            v = Map.get(d, name, 0)
            acc |> Map.update(a, v, &max(&1, v)) |> Map.update(b, v, &max(&1, v))
          end)

        1 + (per_vertex |> Map.values() |> Enum.sum())
      end)

    costs =
      for {a, b, d} <- valued do
        {{a, b},
         names
         |> Enum.map(&Map.get(d, &1, 0))
         |> Enum.zip(bases)
         |> Enum.reduce(0, fn {v, base}, acc -> acc * base + v end)}
      end

    max_cost = costs |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    ceiling = div(length(vertices), 2) * max_cost + 1

    %{vertices: vertices, edges: Map.new(costs, fn {e, c} -> {e, ceiling - c} end)}
  end

  # ---------------------------------------------------------------------
  # Duals
  # ---------------------------------------------------------------------

  defp optimal_dual(w, matching, step) do
    dual = solve(w)

    if optimal?(w, matching, dual),
      do: {:ok, dual_out(dual)},
      else: {:error, {:not_optimal, step}}
  end

  defp unpairable_dual(vertices, edges) do
    dual = solve(%{vertices: vertices, edges: edges})

    if feasible?(%{edges: edges}, dual) and dual.factor * objective(dual) < length(vertices),
      do: {:ok, dual_out(dual)},
      else: :error
  end

  # The engine's matcher finds the duals; whether they prove anything is
  # checked here and, independently, by the checker.
  defp solve(%{vertices: vertices, edges: edges}) when map_size(edges) == 0 do
    _ = vertices
    %{y: %{}, sets: [], factor: 1}
  end

  defp solve(%{vertices: vertices, edges: edges}) do
    index = vertices |> Enum.with_index() |> Map.new()
    back = vertices |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)
    n = length(vertices)
    list = for {{a, b}, w} <- edges, do: {index[a], index[b], w}

    {state, _} = n |> WeightedMatching.new(list) |> WeightedMatching.solve()
    ex = WeightedMatching.proof_export(state)

    live =
      ex.weight |> Enum.filter(fn {_, row} -> map_size(row) > 0 end) |> Enum.map(&elem(&1, 0))

    exposed = Enum.reject(live, &Map.has_key?(ex.mate, &1))

    {y, sets} =
      case exposed do
        [x] ->
          xi = Map.fetch!(ex.dual, x)

          if xi > 0 and rem(length(live), 2) == 1,
            do:
              {Map.new(live, &{&1, ex.dual[&1] - xi}), [{Enum.sort(live), 2 * xi} | ex.blossoms]},
            else: {Map.new(live, &{&1, ex.dual[&1]}), ex.blossoms}

        _ ->
          {Map.new(live, &{&1, ex.dual[&1]}), ex.blossoms}
      end

    %{
      y: Map.new(y, fn {i, d} -> {back[i], d} end),
      sets: Enum.map(sets, fn {vs, z} -> {vs |> Enum.map(&back[&1]) |> Enum.sort(), z} end),
      factor: ex.gcd
    }
  end

  defp rc(w, %{y: y, sets: sets, factor: f}, a, b) do
    z = for {vs, z} <- sets, a in vs and b in vs, reduce: 0, do: (acc -> acc + z)
    f * (Map.get(y, a, 0) + Map.get(y, b, 0) + z) - 2 * Map.fetch!(w.edges, {a, b})
  end

  defp feasible?(w, dual) do
    Enum.all?(dual.y, fn {_, d} -> d >= 0 end) and Enum.all?(dual.sets, fn {_, z} -> z >= 0 end) and
      Enum.all?(w.edges, fn {{a, b}, _} -> rc(w, dual, a, b) >= 0 end)
  end

  defp optimal?(w, matching, dual) do
    weight = matching |> Enum.map(&Map.get(w.edges, &1))

    not Enum.any?(weight, &is_nil/1) and feasible?(w, dual) and
      dual.factor * objective(dual) == 2 * Enum.sum(weight)
  end

  defp objective(%{y: y, sets: sets}) do
    Enum.sum(Map.values(y)) + Enum.sum(for {vs, z} <- sets, do: z * div(length(vs) - 1, 2))
  end

  defp dual_out(%{y: y, sets: sets, factor: f}) do
    %{
      "dual_factor" => Integer.to_string(f),
      "duals" => for({v, d} <- Enum.sort(y), d != 0, do: [v, Integer.to_string(d)]),
      "sets" => for({vs, z} <- sets, z != 0, do: %{"vertices" => vs, "z" => Integer.to_string(z)})
    }
  end
end

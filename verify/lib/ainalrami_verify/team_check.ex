defmodule AinalramiVerify.TeamCheck do
  @moduledoc """
  Part 4: team rounds (C.04.6), checked from a certificate.

  `check/3` takes a team round's input record (`ainalrami-team-input`, the
  file a host stores when the engine pairs the round), the certificate
  `Ainalrami.TeamCertificate` wrote for it, and optionally the round's
  pairing list, and confirms with integer arithmetic that the round is the
  one C.04.6 defines under the readings of the engine's
  `docs/team-proof-large-fields.md`:

    1. the input is the one certified (SHA-256) and the round its round;
    2. the round is legal: every team of the input placed once, no
       rematch and no forbidden pair ([C1]), a bye exactly when the field
       is odd and only for a team [C2] allows;
    3. 3.4: the eligible teams ahead of the bye in 3.4.2-3.4.4's order are
       exactly the ones the certificate passes over, and for each a dual
       bound shows the rest has no perfect matching (3.4.1);
    4. 3.5, per bracket: on everything not yet paired, the round is a
       cheapest perfect matching under [C4], [C5], [C6], [C7] and 3.5.4's
       order - so its upfloaters (the lower teams it seats against
       residents) are the set 3.5 chooses;
    5. 3.6, per bracket: the round's pairing of the bracket is a cheapest
       perfect matching under [C8], [C10], the soft pairs and the top set's
       place in identifier order, and, confined to its top set, under the
       same criteria and the bottom sequence;
    6. Article 4: every match's colours, allocated here and compared.

  Every weight is recomputed here from the input record; nothing is taken
  from the certificate but the dual values. The LP conditions are
  `AinalramiVerify.Certificate.verify_stage/3`'s. This module calls no
  engine code and runs no matching algorithm.

  Not covered: Type B colour preferences (refused), and the readings
  themselves - the checker proves the round follows them, and
  `docs/conformance-c0406-teams.md` argues they are FIDE's.
  """

  import Bitwise

  alias AinalramiVerify.Certificate

  @format "ainalrami-team-certificate"
  @weights "c0406-2026-1"

  @doc "The weight model this checker computes."
  def weights_version, do: @weights

  @doc """
  Checks `cert` (a decoded certificate) against `input_text` (the input
  record's text, as stored) and, when given, `output_text` (the pairing
  list). Returns `:ok` or `{:error, message}` naming the first failure.
  """
  def check(input_text, cert, output_text \\ nil) when is_binary(input_text) and is_map(cert) do
    with :ok <- expect(cert["format"] == @format, "not an #{@format}"),
         :ok <- expect(cert["version"] == 1, "certificate version #{inspect(cert["version"])}"),
         :ok <-
           expect(
             cert["weights"] == @weights,
             "weights #{inspect(cert["weights"])}, this checker computes #{@weights}"
           ),
         :ok <-
           expect(
             cert["input_sha256"] == Certificate.sha256(input_text),
             "the input is not the one certified (SHA-256 differs)"
           ),
         {:ok, ctx} <- context(JSON.decode!(input_text)),
         :ok <-
           expect(
             cert["round"] == ctx.round,
             "certificate is for round #{inspect(cert["round"])}, the input is round #{inspect(ctx.round)}"
           ),
         {:ok, round} <- round_of(cert),
         :ok <- same_output(round, output_text),
         :ok <- legal(ctx, round),
         :ok <- colours(ctx, round),
         :ok <- bye(ctx, round, cert["bye_passed_over"] || []) do
      remaining = ctx.teams |> Map.keys() |> List.delete(round.bye) |> Enum.sort()
      brackets(ctx, round, remaining, cert["brackets"] || [])
    end
  rescue
    e in [JSON.DecodeError, KeyError, ArgumentError, MatchError, FunctionClauseError] ->
      {:error, "malformed input or certificate: " <> Exception.message(e)}
  end

  # ---------------------------------------------------------------------
  # Reading the input record
  # ---------------------------------------------------------------------

  defp context(%{"format" => "ainalrami-team-input", "version" => 1} = m) do
    type = m["type"] || "a"

    cond do
      type == "b" ->
        {:error, "Type B colour preferences are not certified"}

      type not in ["a", "none"] ->
        {:error, "unknown colour preference type #{inspect(type)}"}

      true ->
        primary = if m["score_mode"] == "game_points", do: "game_points", else: "match_points"
        secondary = if primary == "game_points", do: "match_points", else: "game_points"
        round = m["round"]
        expected = m["expected_rounds"]

        teams =
          Map.new(m["teams"], fn t ->
            colours = Enum.map(t["colours"] || [], &colour!/1)

            {t["tpn"],
             %{
               tpn: t["tpn"],
               primary: halves(t[primary]),
               secondary: halves(t[secondary]),
               opponents: MapSet.new(t["opponents"] || []),
               colours: colours,
               played: t["matches_played"] || length(colours),
               eligible?: t["had_pab"] != true and t["won_by_forfeit"] != true,
               floated?: t["floated_last_round"] == true,
               preference: if(type == "none", do: nil, else: type_a(colours))
             }}
          end)

        {:ok,
         %{
           round: round,
           last_two?: is_integer(round) and is_integer(expected) and round >= expected - 1,
           teams: teams,
           use_secondary?: m["use_secondary"] != false,
           initial: colour!(m["initial_colour"] || "white"),
           numbers:
             (Map.keys(teams) ++ (m["absent"] || []))
             |> Enum.uniq()
             |> Enum.sort()
             |> Enum.with_index(1)
             |> Map.new(),
           forbidden: in_force(m["forbidden_pairs"], round),
           soft: in_force(m["soft_pairs"], round)
         }}
    end
  end

  defp context(_), do: {:error, "the input is not an ainalrami-team-input version 1 record"}

  defp colour!("white"), do: :white
  defp colour!("black"), do: :black

  defp halves(x) when is_integer(x), do: 2 * x
  defp halves(x) when is_float(x), do: round(x * 2)

  defp in_force(nil, _round), do: MapSet.new()

  defp in_force(groups, round) do
    Enum.reduce(groups, MapSet.new(), fn g, acc ->
      on? =
        case g do
          %{"from" => a, "to" => b} -> is_integer(round) and round >= a and round <= b
          _ -> true
        end

      if on?,
        do: Enum.reduce(pairs_of(g["teams"]), acc, &MapSet.put(&2, &1)),
        else: acc
    end)
  end

  defp pairs_of(tpns), do: for(a <- tpns, b <- tpns, a < b, do: {a, b})

  # 1.7.1: White when CD < -1, or CD in {0, -1} after Black in the last two
  # played matches; Black the mirror.
  defp type_a(colours) do
    whites = Enum.count(colours, &(&1 == :white))
    cd = whites - (length(colours) - whites)
    last_two = colours |> Enum.reverse() |> Enum.take(2)

    cond do
      cd < -1 -> :white
      cd > 1 -> :black
      cd in [0, -1] and last_two == [:black, :black] -> :white
      cd in [0, 1] and last_two == [:white, :white] -> :black
      true -> nil
    end
  end

  # [C1]: met when either lists the other, or kept apart for this round.
  defp met?(ctx, a, b) do
    MapSet.member?(ctx.teams[a].opponents, b) or MapSet.member?(ctx.teams[b].opponents, a) or
      MapSet.member?(ctx.forbidden, {min(a, b), max(a, b)})
  end

  # ---------------------------------------------------------------------
  # The round
  # ---------------------------------------------------------------------

  defp round_of(cert) do
    pairs = Enum.map(cert["pairs"], fn [w, b] -> {w, b} end)
    {:ok, %{pairs: pairs, bye: cert["bye"]}}
  end

  defp same_output(_round, nil), do: :ok

  defp same_output(round, text) do
    given = parse_output(text)

    expect(
      Enum.sort(Enum.map(given.pairs, &{&1.white, &1.black})) == Enum.sort(round.pairs) and
        given.bye == round.bye,
      "the pairing list is not the certified round"
    )
  end

  @doc """
  A pairing list (a count line, `white black` per match, `tpn 0` for the
  bye) as `%{pairs: [%{white:, black:}], bye:}`.
  """
  def parse_output(text) do
    [_count | lines] = String.split(text, ["\r\n", "\n"], trim: true)

    parsed =
      Enum.map(lines, fn line ->
        [a, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
        {a, b}
      end)

    {byes, pairs} = Enum.split_with(parsed, fn {_, b} -> b == 0 end)

    bye =
      case byes do
        [] -> nil
        [{x, 0}] -> x
        _ -> raise ArgumentError, "more than one bye in the pairing list"
      end

    %{pairs: Enum.map(pairs, fn {w, b} -> %{white: w, black: b} end), bye: bye}
  end

  defp legal(ctx, round) do
    seated = Enum.flat_map(round.pairs, fn {a, b} -> [a, b] end) ++ List.wrap(round.bye)
    field = ctx.teams |> Map.keys() |> Enum.sort()
    odd? = rem(length(field), 2) == 1

    cond do
      Enum.sort(seated) != field ->
        {:error, "the round does not place every team of the input exactly once"}

      odd? != (round.bye != nil) ->
        {:error,
         "a bye exactly when the field is odd: #{length(field)} teams, bye #{inspect(round.bye)}"}

      round.bye != nil and not ctx.teams[round.bye].eligible? ->
        {:error, "[C2]: team #{round.bye} may not receive the pairing-allocated bye"}

      (bad = Enum.find(round.pairs, fn {a, b} -> met?(ctx, a, b) end)) != nil ->
        {a, b} = bad
        {:error, "[C1]: teams #{a} and #{b} have met, or are kept apart"}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------
  # Article 4
  # ---------------------------------------------------------------------

  defp colours(ctx, round) do
    case Enum.find(round.pairs, fn {w, b} -> white(ctx, w, b) != w end) do
      nil -> :ok
      {w, b} -> {:error, "Article 4: #{b} should have White against #{w}"}
    end
  end

  # The team with White on board 1.
  defp white(ctx, x, y) do
    a = ctx.teams[x]
    b = ctx.teams[y]

    # 4.2: higher primary, then (when the rules say so) higher secondary,
    # then the smaller TPN.
    {first, other} =
      cond do
        a.primary != b.primary ->
          if a.primary > b.primary, do: {a, b}, else: {b, a}

        ctx.use_secondary? and a.secondary != b.secondary ->
          if a.secondary > b.secondary, do: {a, b}, else: {b, a}

        true ->
          if a.tpn < b.tpn, do: {a, b}, else: {b, a}
      end

    fp = first.preference
    op = other.preference
    cd = fn t -> Enum.count(t.colours, &(&1 == :white)) * 2 - length(t.colours) end

    colour =
      cond do
        # 4.3.1, by the round's arrival numbering.
        first.played == 0 and other.played == 0 ->
          if rem(ctx.numbers[first.tpn], 2) == 1, do: ctx.initial, else: flip(ctx.initial)

        fp != nil and op == nil ->
          fp

        fp == nil and op != nil ->
          flip(op)

        fp != nil and op != nil and fp != op ->
          fp

        cd.(first) != cd.(other) ->
          if cd.(first) < cd.(other), do: :white, else: :black

        true ->
          split =
            Enum.zip(Enum.reverse(first.colours), Enum.reverse(other.colours))
            |> Enum.find(fn {p, q} -> p != q end)

          cond do
            split != nil -> flip(elem(split, 0))
            fp != nil -> fp
            first.colours != [] -> flip(List.last(first.colours))
            other.colours != [] -> List.last(other.colours)
            true -> ctx.initial
          end
      end

    if colour == :white, do: first.tpn, else: other.tpn
  end

  defp flip(:white), do: :black
  defp flip(:black), do: :white

  # ---------------------------------------------------------------------
  # 3.4
  # ---------------------------------------------------------------------

  defp bye(_ctx, %{bye: nil}, []), do: :ok
  defp bye(_ctx, %{bye: nil}, _), do: {:error, "3.4: proofs for a bye the round does not have"}

  defp bye(ctx, %{bye: bye}, proofs) do
    ahead =
      ctx.teams
      |> Map.values()
      |> Enum.filter(& &1.eligible?)
      |> Enum.sort_by(&{&1.primary, -&1.played, -&1.tpn})
      |> Enum.map(& &1.tpn)
      |> Enum.take_while(&(&1 != bye))

    if Enum.map(proofs, & &1["team"]) != ahead do
      {:error,
       "3.4: the teams ahead of the bye are #{inspect(ahead)}, the certificate passes over " <>
         inspect(Enum.map(proofs, & &1["team"]))}
    else
      Enum.reduce_while(proofs, :ok, fn p, :ok ->
        vertices = ctx.teams |> Map.keys() |> List.delete(p["team"]) |> Enum.sort()

        edges =
          for a <- vertices, b <- vertices, a < b, not met?(ctx, a, b), into: %{}, do: {{a, b}, 1}

        case unpairable(vertices, edges, dual_in(p)) do
          :ok -> {:cont, :ok}
          {:error, m} -> {:halt, {:error, "3.4.1, team #{p["team"]}: #{m}"}}
        end
      end)
    end
  end

  # Weak duality: every matching M has 2|M| <= f * (sum y + sum z (|S|-1)/2),
  # so a bound below the number of teams leaves one of them unpaired.
  defp unpairable(vertices, edges, %{y: y, sets: sets, factor: f}) do
    inside = MapSet.new(vertices)
    yv = &Map.get(y, &1, 0)

    rc = fn a, b ->
      z = for {vs, z} <- sets, a in vs and b in vs, reduce: 0, do: (acc -> acc + z)
      f * (yv.(a) + yv.(b) + z) - 2 * Map.fetch!(edges, {a, b})
    end

    bound =
      Enum.sum(Map.values(y)) + Enum.sum(for {vs, z} <- sets, do: z * div(length(vs) - 1, 2))

    cond do
      f < 1 ->
        {:error, "dual factor #{f} is not positive"}

      Enum.any?(y, fn {v, d} -> d < 0 or not MapSet.member?(inside, v) end) ->
        {:error, "a dual is negative or not a team of the graph"}

      Enum.any?(sets, fn {vs, z} ->
        z < 0 or rem(length(vs), 2) == 0 or length(Enum.uniq(vs)) != length(vs) or
            not Enum.all?(vs, &MapSet.member?(inside, &1))
      end) ->
        {:error, "a set is negative, even, repeated or outside the graph"}

      Enum.any?(edges, fn {{a, b}, _} -> rc.(a, b) < 0 end) ->
        {:error, "the dual is infeasible"}

      f * bound >= length(vertices) ->
        {:error, "the dual bound #{f * bound}/2 does not rule out a perfect matching"}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------
  # 3.3.2's loop: 3.5 then 3.6, per bracket
  # ---------------------------------------------------------------------

  defp brackets(_ctx, _round, [], []), do: :ok

  defp brackets(_ctx, _round, [], extra),
    do: {:error, "the certificate has #{length(extra)} bracket(s) more than the round"}

  defp brackets(_ctx, _round, remaining, []),
    do: {:error, "no proof for the bracket of #{inspect(remaining)}"}

  defp brackets(ctx, round, remaining, [given | rest]) do
    top = remaining |> Enum.map(&ctx.teams[&1].primary) |> Enum.max()
    {residents, lower} = Enum.split_with(remaining, &(ctx.teams[&1].primary == top))
    is_resident = MapSet.new(residents)

    partner = Map.new(Enum.flat_map(round.pairs, fn {a, b} -> [{a, b}, {b, a}] end))
    ups = Enum.filter(lower, &MapSet.member?(is_resident, partner[&1]))
    bracket = Enum.sort(residents ++ ups)
    label = "bracket #{show(top)}"

    boards = fn set ->
      for {a, b} <- round.pairs, a in set and b in set, do: {min(a, b), max(a, b)}
    end

    in_bracket = boards.(bracket)
    tops = Enum.map(in_bracket, &elem(&1, 0))

    steps = [
      {"3.5", upfloat_weights(ctx, residents, lower), boards.(remaining), given["upfloat"]},
      {"3.6 top set", tops_weights(ctx, bracket, MapSet.new(ups)), in_bracket, given["tops"]},
      {"3.6 bottoms", bottoms_weights(ctx, bracket, MapSet.new(ups), tops), in_bracket,
       given["bottoms"]}
    ]

    cond do
      Enum.sort(given["residents"] || []) != Enum.sort(residents) or
          Enum.sort(given["upfloaters"] || []) != Enum.sort(ups) ->
        {:error, "#{label}: the certificate's teams are not the round's"}

      true ->
        Enum.reduce_while(steps, :ok, fn {name, w, matching, dual}, :ok ->
          case dual && Certificate.verify_stage(w, matching, dual_in(dual)) do
            :ok -> {:cont, :ok}
            nil -> {:halt, {:error, "#{label}, #{name}: no proof"}}
            {:error, m} -> {:halt, {:error, "#{label}, #{name}: #{m}"}}
          end
        end)
        |> case do
          :ok -> brackets(ctx, round, Enum.sort(lower -- ups), rest)
          e -> e
        end
    end
  end

  defp show(half) when rem(half, 2) == 0, do: "#{div(half, 2)}"
  defp show(half), do: "#{div(half, 2)}.5"

  defp dual_in(d) do
    %{
      factor: String.to_integer(d["dual_factor"]),
      y: Map.new(d["duals"], fn [v, y] -> {v, String.to_integer(y)} end),
      sets:
        Enum.map(d["sets"], fn %{"vertices" => vs, "z" => z} -> {vs, String.to_integer(z)} end)
    }
  end

  # ---------------------------------------------------------------------
  # Weights (c0406-2026-1) - README, "Part 4"
  # ---------------------------------------------------------------------

  defp upfloat_weights(ctx, residents, lower) do
    is_resident = MapSet.new(residents)
    nl = length(lower)
    levels = lower |> Enum.map(&ctx.teams[&1].primary) |> Enum.uniq() |> Enum.sort()
    level = levels |> Enum.with_index() |> Map.new()
    following = List.last(levels)

    place =
      lower
      |> Enum.sort_by(&{-ctx.teams[&1].primary, &1})
      |> Enum.with_index()
      |> Map.new()

    names = [:k] ++ for(i <- 0..(length(levels) - 1)//1, do: {:c5, i}) ++ [:u, :c7, :pos]

    digits = fn a, b ->
      ra = MapSet.member?(is_resident, a)
      rb = MapSet.member?(is_resident, b)

      cond do
        ra and rb ->
          %{}

        ra or rb ->
          # A lower team seated against a resident floats up.
          l = if ra, do: b, else: a

          %{
            :k => 1,
            {:c5, level[ctx.teams[l].primary]} => 1,
            :c7 => if(ctx.teams[l].floated? and not ctx.last_two?, do: 1, else: 0),
            :pos => (1 <<< nl) - (1 <<< (nl - place[l]))
          }

        ctx.teams[a].primary == following != (ctx.teams[b].primary == following) ->
          %{u: 1}

        true ->
          %{}
      end
    end

    weigh(ctx, Enum.sort(residents ++ lower), names, digits, fn _, _ -> true end)
  end

  defp criteria(ctx, ups, a, b) do
    ta = ctx.teams[a]
    tb = ctx.teams[b]

    c10 =
      if ctx.last_two? do
        0
      else
        Enum.count([{ta, b}, {tb, a}], fn {team, opponent} ->
          team.floated? and MapSet.member?(ups, opponent)
        end)
      end

    %{
      c8: if(ta.preference != nil and ta.preference == tb.preference, do: 1, else: 0),
      c10: c10,
      soft: if(MapSet.member?(ctx.soft, {min(a, b), max(a, b)}), do: 1, else: 0)
    }
  end

  defp tops_weights(ctx, bracket, ups) do
    m = length(bracket)
    index = bracket |> Enum.with_index() |> Map.new()

    weigh(
      ctx,
      bracket,
      [:c8, :c10, :soft, :tops],
      fn a, b ->
        criteria(ctx, ups, a, b) |> Map.put(:tops, (1 <<< m) - (1 <<< (m - index[min(a, b)])))
      end,
      fn _, _ -> true end
    )
  end

  defp bottoms_weights(ctx, bracket, ups, tops) do
    h = length(tops)
    top_rank = tops |> Enum.sort() |> Enum.with_index() |> Map.new()
    bottom_rank = (bracket -- tops) |> Enum.sort() |> Enum.with_index() |> Map.new()

    weigh(
      ctx,
      bracket,
      [:c8, :c10, :soft, :bottoms],
      fn a, b ->
        criteria(ctx, ups, a, b)
        |> Map.put(:bottoms, bottom_rank[b] * Integer.pow(h, h - 1 - top_rank[a]))
      end,
      fn a, b -> Map.has_key?(top_rank, a) and Map.has_key?(bottom_rank, b) end
    )
  end

  # Digits packed most significant first, each base one more than the sum
  # over the vertices of its largest value at that vertex; weight
  # `(n / 2) * max_cost + 1 - cost`.
  defp weigh(ctx, vertices, names, digits, keep?) do
    valued =
      for a <- vertices,
          b <- vertices,
          a < b,
          not met?(ctx, a, b),
          keep?.(a, b),
          do: {{a, b}, digits.(a, b)}

    bases =
      for name <- names do
        valued
        |> Enum.flat_map(fn {{a, b}, d} ->
          [{a, Map.get(d, name, 0)}, {b, Map.get(d, name, 0)}]
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.map(fn {_, vs} -> Enum.max(vs) end)
        |> Enum.sum()
        |> Kernel.+(1)
      end

    costs =
      Map.new(valued, fn {e, d} ->
        {e,
         Enum.zip(names, bases)
         |> Enum.reduce(0, fn {name, base}, acc -> acc * base + Map.get(d, name, 0) end)}
      end)

    ceiling = div(length(vertices), 2) * Enum.max(Map.values(costs), fn -> 0 end) + 1
    %{vertices: vertices, edges: Map.new(costs, fn {e, c} -> {e, ceiling - c} end)}
  end

  defp expect(true, _), do: :ok
  defp expect(_, m), do: {:error, m}
end

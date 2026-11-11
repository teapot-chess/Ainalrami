defmodule Ainalrami.TeamProof.NaiveReference do
  @moduledoc """
  The brute-force reading of C.04.6 Articles 3.4-3.6 and 4, moved unchanged
  from `test/ainalrami/team_pairing_validation_test.exs` (whose moduledoc
  states its readings) so the exact reference can be checked against it.

  Deliberately naive: EVERY subset of the lower teams as an upfloater set,
  EVERY pairing of a bracket, pairability by trying every partner. It shares
  no code with `Ainalrami.TeamPairing` beyond the `%Team{}` struct, and is
  feasible to about ten teams.

  It plays Type A, or no colour preferences at all when the engine options
  it is handed say `type: :none` (1.7's third option: `ref_preference/2`
  is nil for everyone). Type B is not played here.

  It also reads the engine options' `:forbidden_pairs` and `:soft_pairs`
  (`Ainalrami.TeamPairing`, "Keeping teams apart"), written from that
  description rather than from the code: a forbidden pair is a pair that
  has met, for every question [C1] answers; a soft pair is counted per
  bracket pairing, after [C10] and before the identifier.
  """

  def ref_round(field, opts) do
    absent = Keyword.fetch!(opts, :absent)
    initial = Keyword.fetch!(opts, :initial)
    engine_opts = Keyword.fetch!(opts, :opts)
    round = engine_opts[:round]
    expected = engine_opts[:expected_rounds]
    last_two? = round >= expected - 1
    type = ref_type(engine_opts[:type])
    soft = ref_pairs(engine_opts[:soft_pairs], round)

    numbers = ref_numbers(field, absent)
    by_tpn = Map.new(field, &{&1.tpn, &1})
    field = ref_forbid(field, ref_pairs(engine_opts[:forbidden_pairs], round))

    with {bye, rest, bye_reasons} <- ref_bye(field),
         true <- ref_pairable?(rest) do
      {bracket_pairs, bracket_reasons} =
        rest
        |> ref_brackets(
          {last_two?, type, soft, field |> Enum.map(& &1.match_points) |> Enum.uniq()},
          []
        )
        |> Enum.unzip()

      allocated =
        bracket_pairs
        |> Enum.concat()
        |> Enum.map(fn {a, b} -> ref_colours(by_tpn[a], by_tpn[b], numbers, initial, type) end)

      %{
        bye: bye,
        pairs: allocated |> Enum.map(fn {w, b, _rules} -> {w, b} end) |> Enum.sort(),
        reasons: %{
          bye: bye_reasons,
          brackets: bracket_reasons,
          rules:
            allocated
            |> Enum.map(fn {w, b, {first, colour}} -> {w, b, first, colour} end)
            |> Enum.sort()
        }
      }
    else
      _ -> :impossible
    end
  end

  # Every pair `{low, high}` inside the groups that apply in `round`.
  defp ref_pairs(nil, _round), do: MapSet.new()

  defp ref_pairs(groups, round) do
    for group <- groups,
        tpns =
          (case group do
             {tpns, first, last} -> if round >= first and round <= last, do: tpns, else: []
             tpns -> tpns
           end),
        a <- tpns,
        b <- tpns,
        a < b,
        into: MapSet.new(),
        do: {a, b}
  end

  # A forbidden pair has, for pairing purposes, already met.
  # Without any the field is returned untouched.
  defp ref_forbid(field, forbidden) do
    Enum.map(field, fn t ->
      extra =
        for {a, b} <- forbidden,
            t.tpn in [a, b],
            other = if(a == t.tpn, do: b, else: a),
            other not in t.opponents,
            do: other

      %{t | opponents: t.opponents ++ extra}
    end)
  end

  # 4.3.1's numbering: everyone arrived, in TPN order, from 1.
  def ref_numbers(field, absent) do
    (Enum.map(field, & &1.tpn) ++ absent) |> Enum.sort() |> Enum.with_index(1) |> Map.new()
  end

  # 3.4: [C2] first, then the first team by lowest score, most matches
  # played, largest TPN, that leaves the rest pairable (3.4.1).
  #
  # Also the reasons: the teams before the bye in that order (each strands
  # the rest), and the first of 3.4.2-3.4.4 on which the bye ranks ahead of
  # the next eligible team.
  defp ref_bye(field) when rem(length(field), 2) == 0, do: {nil, field, nil}

  defp ref_bye(field) do
    ordered =
      field
      |> Enum.reject(&(&1.had_pab? or &1.won_by_forfeit?))
      |> Enum.sort_by(&{&1.match_points, -length(&1.colours), -&1.tpn})

    case Enum.find_index(ordered, fn t -> ref_pairable?(List.delete(field, t)) end) do
      nil ->
        :impossible

      i ->
        t = Enum.at(ordered, i)
        next = Enum.at(ordered, i + 1)

        decided_by =
          cond do
            next == nil -> nil
            t.match_points != next.match_points -> "3.4.2"
            length(t.colours) != length(next.colours) -> "3.4.3"
            true -> "3.4.4"
          end

        reasons = %{
          tpn: t.tpn,
          passed_over: ordered |> Enum.take(i) |> Enum.map(& &1.tpn),
          decided_by: decided_by
        }

        {t.tpn, List.delete(field, t), reasons}
    end
  end

  # Pairable without a rematch: somebody must partner the first team.
  defp ref_pairable?([]), do: true

  defp ref_pairable?([t | rest]) do
    Enum.any?(rest, fn o -> o.tpn not in t.opponents and ref_pairable?(List.delete(rest, o)) end)
  end

  defp ref_brackets([], _settings, acc), do: Enum.reverse(acc)

  defp ref_brackets(remaining, {last_two?, type, soft, levels} = settings, acc) do
    top = remaining |> Enum.map(& &1.match_points) |> Enum.max()
    {residents, lower} = Enum.split_with(remaining, &(&1.match_points == top))

    legal =
      for set <- subsets(lower),
          rem(length(residents) + length(set), 2) == 0,
          ref_pairable?(residents ++ set),
          ref_pairable?(lower -- set),
          do: set

    # [C4] then [C5]: fewest teams, then the scores ascending, the larger
    # list the better.
    best_c4_c5 = legal |> Enum.map(&{length(&1), c5(&1)}) |> Enum.min()

    ranked =
      legal
      |> Enum.filter(&({length(&1), c5(&1)} == best_c4_c5))
      |> Enum.map(fn set ->
        {{c6(set, lower, next_level(levels, top)), c7(set, last_two?),
          set |> sort_353() |> Enum.map(& &1.tpn)}, set}
      end)
      |> Enum.sort()

    [{{c6, c7, tpns}, set} | others] = ranked

    # The first criterion in 2.3's order on which the chosen set beats the
    # best other legal set: within its [C4]/[C5] group [C6], [C7] or 3.5.4's
    # order; otherwise the best set outside the group, which is worse on [C5]
    # when it has the same size and on [C4] when it is larger - or no other
    # legal set at all, which is [C4] too.
    decided_by =
      case others do
        [{{o6, o7, _}, _} | _] ->
          cond do
            o6 != c6 -> "C6"
            o7 != c7 -> "C7"
            true -> "3.5.4"
          end

        [] ->
          case legal |> Enum.reject(&({length(&1), c5(&1)} == best_c4_c5)) do
            [] ->
              "C4"

            rest ->
              {size, _} = rest |> Enum.map(&{length(&1), c5(&1)}) |> Enum.min()
              if size == length(set), do: "C5", else: "C4"
          end
      end

    ups = MapSet.new(set, & &1.tpn)
    pairs = ref_bracket_pairing(residents ++ set, ups, last_two?, type, soft)
    reasons = %{upfloaters: tpns, decided_by: decided_by}
    ref_brackets(lower -- set, settings, [{pairs, reasons} | acc])
  end

  defp c5(set), do: set |> Enum.map(& &1.match_points) |> Enum.sort() |> Enum.map(&(0 - &1))

  # [C6]: extra upfloaters (beyond parity) the following scoregroup needs.
  # The following scoregroup is the next score below the residents' among
  # every team handed in for the round (the bye's included): 2.3.3's
  # "became or are upfloaters" counts the teams earlier brackets took as
  # still belonging to it, so when none of that score is left it is empty
  # and [C6] is met - the look does not go one level further down.
  defp next_level(levels, top), do: levels |> Enum.filter(&(&1 < top)) |> Enum.max(fn -> nil end)

  defp c6(_set, [], _following_score), do: 0

  defp c6(set, lower, following_score) do
    {following, below} = Enum.split_with(lower -- set, &(&1.match_points == following_score))

    if following == [] do
      0
    else
      needed =
        for up <- subsets(below),
            rem(length(following) + length(up), 2) == 0,
            ref_pairable?(following ++ up),
            ref_pairable?(below -- up),
            do: length(up)

      div(Enum.min(needed) - rem(length(following), 2), 2)
    end
  end

  defp c7(_set, true), do: 0
  defp c7(set, false), do: Enum.count(set, & &1.floated_last_round?)

  defp sort_353(set), do: Enum.sort_by(set, &{0 - &1.match_points, &1.tpn})

  # 3.6: every pairing, legal under [C1]; least {C8, C10}; then (only ever
  # non-zero with soft pairs) the fewest soft pairs; smallest identifier.
  defp ref_bracket_pairing(bracket, ups, last_two?, type, soft) do
    bracket
    |> Enum.sort_by(& &1.tpn)
    |> all_pairings()
    |> Enum.filter(fn pairs -> Enum.all?(pairs, fn {a, b} -> a.tpn not in b.opponents end) end)
    |> Enum.min_by(fn pairs ->
      tops = Enum.map(pairs, fn {a, b} -> min(a.tpn, b.tpn) end)
      order = Enum.sort_by(pairs, fn {a, b} -> min(a.tpn, b.tpn) end)
      bottoms = Enum.map(order, fn {a, b} -> max(a.tpn, b.tpn) end)

      soft_count =
        Enum.count(pairs, fn {a, b} ->
          MapSet.member?(soft, {min(a.tpn, b.tpn), max(a.tpn, b.tpn)})
        end)

      {c8(pairs, type), c10(pairs, ups, last_two?), soft_count, Enum.sort(tops) ++ bottoms}
    end)
    |> Enum.map(fn {a, b} -> {a.tpn, b.tpn} end)
  end

  defp c8(pairs, type) do
    Enum.count(pairs, fn {a, b} ->
      pa = ref_preference(a, type)
      pa != nil and pa == ref_preference(b, type)
    end)
  end

  # "the number of upfloaters' opponents that were floaters in the previous
  # round" - counted per TEAM, as the text reads.
  defp c10(_pairs, _ups, true), do: 0

  defp c10(pairs, ups, false) do
    pairs
    |> Enum.flat_map(fn {a, b} -> [{a, b}, {b, a}] end)
    |> Enum.count(fn {team, opponent} ->
      MapSet.member?(ups, opponent.tpn) and team.floated_last_round?
    end)
  end

  defp all_pairings([]), do: [[]]

  defp all_pairings([h | t]) do
    Enum.flat_map(t, fn partner ->
      Enum.map(all_pairings(List.delete(t, partner)), &[{h, partner} | &1])
    end)
  end

  defp subsets([]), do: [[]]

  defp subsets([h | t]) do
    rest = subsets(t)
    rest ++ Enum.map(rest, &[h | &1])
  end

  # The types this reference plays: Type A and 1.7's "not to be used at
  # all". Type B's [C9] is proven at bracket level elsewhere; asking for it
  # here is a test bug, not a round to compare.
  defp ref_type(nil), do: :a
  defp ref_type(type) when type in [:a, :none], do: type

  # 1.7.1, Type A; under `:none` nobody has a preference (1.7).
  def ref_preference(team, type \\ :a)

  def ref_preference(_team, :none), do: nil

  def ref_preference(team, :a) do
    cd = Enum.count(team.colours, &(&1 == :white)) - Enum.count(team.colours, &(&1 == :black))
    last_two = team.colours |> Enum.reverse() |> Enum.take(2)

    cond do
      cd < -1 -> :white
      cd > 1 -> :black
      cd in [0, -1] and last_two == [:black, :black] -> :white
      cd in [0, 1] and last_two == [:white, :white] -> :black
      true -> nil
    end
  end

  # Article 4 for one pair, returning {white_tpn, black_tpn, {4.2 rule, 4.3
  # rule}} - the clause that named the first-team and the one that gave it
  # its colour.
  def ref_colours(a, b, numbers, initial, type \\ :a) do
    {first, other, first_rule} =
      cond do
        a.match_points != b.match_points ->
          if a.match_points > b.match_points, do: {a, b, "4.2.1"}, else: {b, a, "4.2.1"}

        a.game_points != b.game_points ->
          if a.game_points > b.game_points, do: {a, b, "4.2.2"}, else: {b, a, "4.2.2"}

        true ->
          if a.tpn < b.tpn, do: {a, b, "4.2.3"}, else: {b, a, "4.2.3"}
      end

    fp = ref_preference(first, type)
    op = ref_preference(other, type)

    cd = fn t ->
      Enum.count(t.colours, &(&1 == :white)) - Enum.count(t.colours, &(&1 == :black))
    end

    {colour, rule} =
      cond do
        first.colours == [] and other.colours == [] ->
          {if(rem(numbers[first.tpn], 2) == 1, do: initial, else: flip(initial)), "4.3.1"}

        fp != nil and op == nil ->
          {fp, "4.3.2"}

        fp == nil and op != nil ->
          {flip(op), "4.3.2"}

        fp != nil and op != nil and fp != op ->
          {fp, "4.3.3"}

        cd.(first) != cd.(other) ->
          {if(cd.(first) < cd.(other), do: :white, else: :black), "4.3.5"}

        true ->
          # 4.3.6, counting played matches only, from the latest (C.04.2 3.4).
          split =
            Enum.zip(Enum.reverse(first.colours), Enum.reverse(other.colours))
            |> Enum.find(fn {x, y} -> x != y end)

          cond do
            split != nil -> {flip(elem(split, 0)), "4.3.6"}
            fp != nil -> {fp, "4.3.7"}
            first.colours != [] -> {flip(List.last(first.colours)), "4.3.8"}
            other.colours != [] -> {List.last(other.colours), "4.3.9"}
            true -> {initial, "initial"}
          end
      end

    if colour == :white,
      do: {first.tpn, other.tpn, {first_rule, rule}},
      else: {other.tpn, first.tpn, {first_rule, rule}}
  end

  defp flip(:white), do: :black
  defp flip(:black), do: :white
end

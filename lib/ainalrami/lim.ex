defmodule Ainalrami.Lim do
  @moduledoc """
  The FIDE Lim System, C.04.4.3, approved by the Council on 28/10/2025 and
  applied from 1 February 2026.

  The text is a procedure for an arbiter with pairing cards, written in
  1987 and amended to 1999, and it says what to try rather than what to
  reach. Where it ran out, a reading was chosen and written down in
  `docs/conformance-c0443-lim.md` (L1-L16); article numbers below are
  C.04.4.3's. This is the first engine for the 2026 text that this
  project knows of, and it is labelled as a reading, not as conformance.

  ## The round

      1. the pairing-allocated bye, if the field is odd:      (1.1, 7.1)
         the lowest-ranked player of the lowest scoregroup
         who can take it and leave the rest pairable
      2. the scoregroups above the median, top down;          (2.2)
         then those below it, bottom up; the median group
         (score = half the rounds played) last, downward
      3. in each: who floats on, then the pairs               (2-4)
      4. colours, pair by pair                                (5)

  Round 1 needs no rule of its own: everybody is in the median group,
  2.4's halves give 1 v n/2+1, and 7.2's colours are what `Lim.Colour`
  gives two players without a history. The last round (6) lets players of
  equal score meet whatever their colours.

  The pieces: `Ainalrami.Lim.Player`, `Ainalrami.Lim.Group` (2.3-4.4),
  `Ainalrami.Lim.Order` (the scrutiny order) and `Ainalrami.Lim.Colour`
  (5). The compatibility graph (2.1) is the Dubov system's
  `Ainalrami.Dubov.Graph`: Lim's "three more of one colour" and "three in
  succession" are the absolute colour criteria the other systems share.

  ## Usage

      {:ok, round} = Ainalrami.Lim.pair_round(players, expected_rounds: 9)

  Options: `:expected_rounds` (required: the last round is different, 6),
  `:initial_colour` (`"w"`/`"b"`; absent, read off round 1, White before
  it), `:point_system`, `:forbidden_pairs`. The Dutch engine's organiser
  options, an acceleration and the Maxi-tournament rules are refused.

  ## Answers

  `{:ok, %{pairs:, bye:, round:, groups:}}` or `{:error, reason}`:
  `:no_legal_pairing`, `:no_legal_bye`, `:expected_rounds_required`,
  `{:beyond_expected_rounds, round}`, `{:unsupported_option, key}`,
  `{:invalid_option, key, value}`.
  """

  alias Ainalrami.{Pairing, Trf}
  alias Ainalrami.Dubov.Graph
  alias Ainalrami.Lim.{Colour, Group, Player}

  @unsupported [:bye_exclusions, :bye_preferences, :soft_pairs, :groups, :match_format, :maxi]

  @doc "The round as `Ainalrami.Pairing.pair_next_round/2` gives it: the bye last as `{rank, nil}`."
  def pair_next_round(players, opts \\ []) do
    with {:ok, round} <- pair_round(players, opts) do
      bye = if round.bye, do: [{round.bye, nil}], else: []
      {:ok, round.pairs ++ bye}
    end
  end

  @doc "Pairs the next round. See the moduledoc."
  def pair_round(players, opts \\ []) do
    with :ok <- check_options(opts, players) do
      _ = Pairing.check_input!(players, Keyword.take(opts, dutch_keys()))
      round = Trf.rounds_played(players) + 1

      if round > opts[:expected_rounds],
        do: {:error, {:beyond_expected_rounds, round}},
        else: pair(players, round, opts)
    end
  end

  defp dutch_keys, do: [:expected_rounds, :initial_colour, :point_system, :forbidden_pairs]

  defp check_options(opts, players) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_option, :opts, opts}}

      key = Enum.find(@unsupported, &(opts[&1] not in [nil, [], false])) ->
        {:error, {:unsupported_option, key}}

      Enum.any?(players, &accelerated?/1) ->
        {:error, {:unsupported_option, :acceleration}}

      not is_integer(opts[:expected_rounds]) ->
        {:error, :expected_rounds_required}

      opts[:expected_rounds] < 1 ->
        {:error, {:invalid_option, :expected_rounds, opts[:expected_rounds]}}

      true ->
        :ok
    end
  end

  defp accelerated?(%{accelerations: values}) when is_list(values),
    do: Enum.any?(values, &(&1 not in [0, 0.0]))

  defp accelerated?(_), do: false

  defp pair(players, round, opts) do
    point_system = opts[:point_system] || Trf.default_point_system()
    by_rank = Map.new(players, &{&1.rank, &1})
    last? = round == opts[:expected_rounds]

    context = %{
      eligible: Pairing.bye_eligibility(players, point_system: point_system),
      before: Player.scores_before(players, round, point_system)
    }

    active =
      players
      |> Enum.filter(&(length(&1.games) < round))
      |> Enum.map(&Player.build(&1, round, context))

    forbidden = forbidden(opts[:forbidden_pairs], round)

    # 2.1, and 6: in the last round players of equal score may meet
    # whatever their colours.
    field =
      Graph.new(active, fn a, b ->
        MapSet.member?(forbidden, {min(a.rank, b.rank), max(a.rank, b.rank)}) or
          met?(by_rank[a.rank], b.rank) or
          (not (last? and a.score == b.score) and
             not ((:white in a.allowed and :black in b.allowed) or
                    (:black in a.allowed and :white in b.allowed)))
      end)

    median = (round - 1) * point_system.win / 2
    initial = initial_colour(opts[:initial_colour], players)

    with {:ok, bye, rest} <- assign_bye(active, field),
         {:ok, groups} <- pair_groups(rest, median, field, initial) do
      pairs =
        groups
        |> Enum.flat_map(fn g -> Enum.map(g.pairs, &{&1, g}) end)
        |> Enum.sort_by(fn {{w, b}, _g} ->
          {-max(score(rest, w), score(rest, b)), -min(score(rest, w), score(rest, b)), min(w, b)}
        end)
        |> Enum.map(&elem(&1, 0))

      {:ok, %{round: round, pairs: pairs, bye: bye && bye.rank, groups: groups}}
    end
  end

  defp score(players, rank), do: Enum.find(players, &(&1.rank == rank)).score

  # C.04.2 3.5: a forfeit is no meeting.
  defp met?(player, rank) do
    Enum.any?(player.games, fn g ->
      g.opponent_rank == rank and Trf.game_was_played?(g.result) and g.colour in ["w", "b"]
    end)
  end

  defp forbidden(nil, _round), do: MapSet.new()

  defp forbidden(groups, round) do
    for group <- groups,
        ranks = in_force(group, round),
        a <- ranks,
        b <- ranks,
        a < b,
        into: MapSet.new(),
        do: {a, b}
  end

  defp in_force({ranks, first, last}, round) when round >= first and round <= last, do: ranks
  defp in_force({_ranks, _first, _last}, _round), do: []
  defp in_force(ranks, _round) when is_list(ranks), do: ranks

  # 1.1: the lowest-ranked player of the lowest scoregroup, among those
  # C.04.1 Article 3 allows, who leaves the rest pairable (reading L9).
  defp assign_bye(active, field) do
    ranks = Enum.map(active, & &1.rank)

    if rem(length(active), 2) == 0 do
      if Graph.feasible?(ranks, field), do: {:ok, nil, active}, else: {:error, :no_legal_pairing}
    else
      active
      |> Enum.filter(& &1.bye_eligible?)
      |> Enum.sort_by(&{&1.score, -&1.rank})
      |> Enum.find(&Graph.feasible?(List.delete(ranks, &1.rank), field))
      |> case do
        nil -> {:error, :no_legal_bye}
        bye -> {:ok, bye, List.delete(active, bye)}
      end
    end
  end

  # 2.2: down to just above the median, then up from the bottom to just
  # below it, then the median group, downward. The median group is the
  # players on exactly half the possible score - possibly nobody but the
  # floaters (reading L3).
  defp pair_groups(rest, median, field, initial) do
    scores = rest |> Enum.map(& &1.score) |> Enum.uniq()
    upper = scores |> Enum.filter(&(&1 > median)) |> Enum.sort(:desc)
    lower = scores |> Enum.filter(&(&1 < median)) |> Enum.sort(:asc)
    residents = fn s -> Enum.filter(rest, &(&1.score == s)) end
    median_residents = residents.(median)

    ctx = %{field: field, median: median, initial: initial}

    with {:ok, downs, acc, left} <- run(upper, :down, residents, median_residents, rest, ctx, []),
         {:ok, ups, acc, left} <- run(lower, :up, residents, median_residents, left, ctx, acc) do
      members = downs ++ ups ++ median_residents
      outside = Enum.reject(left, &(&1 in members))

      case group(members, median, :median, [], outside, ctx) do
        {:ok, g, _floaters} -> {:ok, Enum.reverse([g | acc])}
        :error -> {:error, :no_legal_pairing}
      end
    end
  end

  defp run(scores, direction, residents, median_residents, left, ctx, acc) do
    scores
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], acc, left}, fn {s, i}, {:ok, incoming, acc, left} ->
      members = incoming ++ residents.(s)
      adjacent = if next = Enum.at(scores, i + 1), do: residents.(next), else: median_residents
      outside = Enum.reject(left, &(&1 in members))

      case group(members, s, direction, adjacent, outside, ctx) do
        {:ok, g, floaters} ->
          paired =
            MapSet.new(g.pairs, fn {w, _} -> w end)
            |> MapSet.union(MapSet.new(g.pairs, fn {_, b} -> b end))

          {:cont, {:ok, floaters, [g | acc], Enum.reject(left, &MapSet.member?(paired, &1.rank))}}

        :error ->
          {:halt, {:error, :no_legal_pairing}}
      end
    end)
  end

  defp group(members, score, direction, adjacent, outside, ctx) do
    case Group.floaters(members, score, direction, adjacent, outside, ctx.field) do
      {:ok, paired, floaters} ->
        pairs =
          paired
          |> Group.pairs(score, direction, ctx.field, {ctx.median, ctx.initial})
          |> Enum.map(fn {x, y} ->
            {w, b, _article} = Colour.allocate(x, y, score, ctx.median, ctx.initial)
            {w, b}
          end)

        g = %{
          score: score,
          direction: direction,
          residents: members |> Enum.filter(&(&1.score == score)) |> Enum.map(& &1.rank),
          incoming: members |> Enum.reject(&(&1.score == score)) |> Enum.map(& &1.rank),
          floaters: Enum.map(floaters, & &1.rank),
          pairs: pairs
        }

        {:ok, g, floaters}

      :error ->
        :error
    end
  end

  @doc """
  The initial colour as `"w"` or `"b"`: given, or read off round 1, where
  the best-ranked player paired held it on an odd pairing number (7.2).
  White before round 1.
  """
  def infer_initial_colour(players) do
    case initial_colour(nil, players) do
      :white -> "w"
      :black -> "b"
    end
  end

  defp initial_colour("w", _players), do: :white
  defp initial_colour("b", _players), do: :black

  defp initial_colour(nil, players) do
    players
    |> Enum.sort_by(& &1.rank)
    |> Enum.find_value(:white, fn p ->
      case p.games do
        [%{colour: c, opponent_rank: o} | _] when c in ["w", "b"] and is_integer(o) ->
          given = if c == "w", do: :white, else: :black
          if rem(p.rank, 2) == 1, do: given, else: opposite(given)

        _ ->
          nil
      end
    end)
  end

  defp opposite(:white), do: :black
  defp opposite(:black), do: :white
end

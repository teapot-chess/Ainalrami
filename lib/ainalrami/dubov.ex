defmodule Ainalrami.Dubov do
  @moduledoc """
  The FIDE Dubov System, C.04.4.1, approved by the Council on 28/10/2025
  and applied from 1 February 2026.

  The reading - every place the text ran out and what was decided there -
  is `docs/conformance-c0441-dubov.md`; the plan it was built to is
  `docs/design-other-swiss-systems.md`. Article numbers below are C.04.4.1's.

  ## Not the Dutch system with different weights

  The Dubov system is built the way C.04.6 (teams) is, not the way C.04.3
  is: every choice is "the first" element of an order defined in Article 4
  that meets a predicate, so there is no weight ladder to maximise. And
  there are no downfloaters: a scoregroup's residents are all paired in
  their own bracket, with as few upfloaters from below as a legal pairing
  needs.

      1. the pairing-allocated bye, if the field is odd       (3.1)
      2. scoregroups top down; for each:                     (1.9.2)
         - how many upfloaters                               (3.2.1)
         - which upfloaters                                  (3.2.2, 4.2)
         - G1 / G2 and their re-composition                  (3.2.3-3.2.4, 4.3)
         - S1 against the first legal transposition of G2    (3.2.5-3.2.6, 4.4)
      3. colours, pair by pair                               (5.2)

  The pieces: `Ainalrami.Dubov.Player` (ratings, ARO, colour preferences,
  upfloat history), `Ainalrami.Dubov.Order` (Article 4),
  `Ainalrami.Dubov.Bracket` (Article 3.2), `Ainalrami.Dubov.Colour`
  (Article 5) and `Ainalrami.Dubov.Graph` (the matching questions, over the
  team engine's `TeamPairing.Field`). `Ainalrami.Pairing` - the Dutch
  engine - is not called to pair anything; four of its public helpers are
  read for what the two systems share by definition: the input checks,
  [C2] (`bye_eligibility/2`), the arrival numbering (`arrival_numbers/2`)
  and the round count (`Ainalrami.Trf.rounds_played/1`).

  ## Usage

      {:ok, round} = Ainalrami.Dubov.pair_round(players, expected_rounds: 9)
      round.pairs  # [{white, black}, ...]
      round.bye    # the rank given the pairing-allocated bye, or nil

  `players` is the whole roster in `Ainalrami.Trf.parse/1`'s shape (players
  sitting the round out included - their ratings feed their opponents'
  AROs); each needs `:fide_rating`, or a provisional rating.

  Options:

    * `:expected_rounds` - required. MaxT (1.8.2) and [C8]-[C10]'s "unless
      it is the last round" both depend on it.
    * `:initial_colour` - `"w"` or `"b"` (5.1). Absent: read off round 1
      the way 5.2.1 must have given it, or White before round 1.
    * `:provisional_ratings` - `%{rank => rating}` for unrated players
      (1.1.2). A player with neither a rating nor one of these is refused
      (1.1.1).
    * `:point_system`, `:forbidden_pairs` - as `Ainalrami.Pairing` takes
      them. A forbidden pair counts as a pair that has met ([C1]).
    * `:transposition_rule` - reading D2 of 3.2.6: `:first_legal` (the
      default, the text) or `:first_reaching_c7`. See
      `Ainalrami.Dubov.Bracket`'s moduledoc for why the two agree.

  The Dutch engine's organiser options - bye exclusions and preferences,
  soft pairs, pairing groups, the match format - are not FIDE's and are
  not Dubov's either; given one, the round is refused rather than paired
  as if it had been honoured.

  ## Answers

  `{:ok, %{pairs:, bye:, round:, brackets:}}`, or `{:error, reason}`:

    * `:no_legal_pairing` - no complete round-pairing exists (1.9.3: the
      Chief Arbiter decides). [C3] has no topscorer exception here, so this
      happens where the Dutch system would pair (reading D8);
    * `:no_legal_bye` - nobody can take the bye and leave the rest pairable;
    * `{:unrated, ranks}`, `{:provisional_for_rated, ranks}` - 1.1;
    * `:expected_rounds_required`, `{:beyond_expected_rounds, round}`;
    * `{:unsupported_option, key}`, `{:invalid_option, key, value}`.
  """

  alias Ainalrami.{Pairing, Trf}
  alias Ainalrami.Dubov.{Bracket, Colour, Graph, Player}

  # Reading D2 (3.2.6), pending the SPP's answer to the question of
  # 2026-10-31. The one line to change to read it the other way.
  @default_transposition_rule :first_legal

  @rules [:first_legal, :first_reaching_c7]
  @unsupported [:bye_exclusions, :bye_preferences, :soft_pairs, :groups, :match_format]

  @doc "The reading of 3.2.6 used when `:transposition_rule` is not given."
  def default_transposition_rule, do: @default_transposition_rule

  @doc """
  The round as `Ainalrami.Pairing.pair_next_round/2` gives it: pairs in
  board order, the bye last as `{rank, nil}`. `{:ok, pairs}` or
  `{:error, reason}` (`pair_round/2`'s).
  """
  def pair_next_round(players, opts \\ []) do
    with {:ok, round} <- pair_round(players, opts) do
      bye = if round.bye, do: [{round.bye, nil}], else: []
      {:ok, round.pairs ++ bye}
    end
  end

  @doc "Pairs the next round. See the moduledoc for options and answers."
  def pair_round(players, opts \\ []) do
    with :ok <- check_options(opts) do
      _ = Pairing.check_input!(players, Keyword.take(opts, dutch_keys()))
      played = Trf.rounds_played(players)
      round = played + 1
      rounds = opts[:expected_rounds]

      if round > rounds,
        do: {:error, {:beyond_expected_rounds, round}},
        else: pair(players, round, rounds, opts)
    end
  end

  defp dutch_keys, do: [:expected_rounds, :initial_colour, :point_system, :forbidden_pairs]

  defp check_options(opts) do
    rule = Keyword.get(opts, :transposition_rule, @default_transposition_rule)
    provisional = Keyword.get(opts, :provisional_ratings, %{})

    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_option, :opts, opts}}

      key = Enum.find(@unsupported, &(opts[&1] not in [nil, [], false])) ->
        {:error, {:unsupported_option, key}}

      not is_integer(opts[:expected_rounds]) ->
        {:error, :expected_rounds_required}

      opts[:expected_rounds] < 1 ->
        {:error, {:invalid_option, :expected_rounds, opts[:expected_rounds]}}

      rule not in @rules ->
        {:error, {:invalid_option, :transposition_rule, rule}}

      not (is_map(provisional) and
               Enum.all?(provisional, fn {k, v} -> is_integer(k) and is_integer(v) and v > 0 end)) ->
        {:error, {:invalid_option, :provisional_ratings, provisional}}

      true ->
        :ok
    end
  end

  defp pair(players, round, rounds, opts) do
    point_system = opts[:point_system] || Trf.default_point_system()

    with {:ok, ratings} <- Player.ratings(players, opts[:provisional_ratings]) do
      context = %{
        ratings: ratings,
        by_rank: Map.new(players, &{&1.rank, &1}),
        point_system: point_system,
        eligible: Pairing.bye_eligibility(players, point_system: point_system)
      }

      active =
        players
        |> Enum.filter(&(length(&1.games) < round))
        |> Enum.map(&Player.build(&1, round, context))

      forbidden = forbidden(opts[:forbidden_pairs], round)

      field =
        Graph.new(active, fn a, b ->
          MapSet.member?(forbidden, {min(a.rank, b.rank), max(a.rank, b.rank)}) or
            met?(context.by_rank[a.rank], b.rank) or
            (a.strength == :absolute and b.strength == :absolute and a.colour == b.colour)
        end)

      ctx = %{
        field: field,
        last_round?: round == rounds,
        max_t: 2 + div(rounds, 5),
        rule: Keyword.get(opts, :transposition_rule, @default_transposition_rule)
      }

      with {:ok, bye, rest} <- assign_bye(active, field),
           {:ok, brackets} <- pair_brackets(rest, ctx, []) do
        numbers = Pairing.arrival_numbers(players, round)
        initial = initial_colour(opts[:initial_colour], players, point_system)

        brackets =
          Enum.map(brackets, fn b ->
            pairs =
              Enum.map(b.pairs, fn {x, y} ->
                {w, bl, article} = Colour.allocate(x, y, numbers, initial)
                %{white: w, black: bl, article: article}
              end)

            %{b | pairs: pairs}
          end)

        {:ok,
         %{
           round: round,
           pairs: for(b <- brackets, p <- b.pairs, do: {p.white, p.black}),
           bye: bye && bye.rank,
           brackets: brackets
         }}
      end
    end
  end

  # [C1] is about games PLAYED: a forfeited game is not a meeting (C.04.2
  # Article 3.5), so its players may be paired again.
  defp met?(player, rank) do
    Enum.any?(player.games, &(&1.opponent_rank == rank and Player.played?(&1)))
  end

  # `XXP` groups as `Ainalrami.Pairing` takes them: a list of ranks, or
  # `{ranks, first_round, last_round}` for a group in force in those rounds.
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

  # 3.1: [C2], leaves the rest pairable ([C4]), lowest score, most games
  # played, largest TPN.
  defp assign_bye(active, field) do
    ranks = Enum.map(active, & &1.rank)

    cond do
      rem(length(active), 2) == 0 ->
        if Graph.feasible?(ranks, field),
          do: {:ok, nil, active},
          else: {:error, :no_legal_pairing}

      true ->
        active
        |> Enum.filter(& &1.bye_eligible?)
        |> Enum.sort_by(&{&1.score, -&1.played, -&1.rank})
        |> Enum.find(&Graph.feasible?(List.delete(ranks, &1.rank), field))
        |> case do
          nil -> {:error, :no_legal_bye}
          bye -> {:ok, bye, List.delete(active, bye)}
        end
    end
  end

  # 1.9.2: the scoregroups in descending order of score. A scoregroup that
  # upfloating has emptied is simply gone; one that it has thinned is the
  # (remaining) residents 3.2.1 speaks of.
  defp pair_brackets([], _ctx, acc), do: {:ok, Enum.reverse(acc)}

  defp pair_brackets(unpaired, ctx, acc) do
    top = unpaired |> Enum.map(& &1.score) |> Enum.max()
    {residents, lower} = Enum.split_with(unpaired, &(&1.score == top))

    with k when is_integer(k) <-
           Graph.min_upfloaters(ranks(residents), ranks(lower), ctx.field),
         set when is_list(set) <- Bracket.select(residents, lower, k, ctx) do
      players = residents ++ set
      target = Bracket.c7(players, ctx.field)
      {g1, g2, moved} = Bracket.subgroups(players, ctx.field)
      pairs = Bracket.transposition(g1, g2, ctx.field, ctx.rule, target)

      bracket = %{
        score: top,
        residents: ranks(residents),
        upfloaters: ranks(set),
        g1: ranks(g1),
        g2: ranks(g2),
        shifted: moved,
        c7: target,
        pairs: pairs
      }

      pair_brackets(lower -- set, ctx, [bracket | acc])
    else
      _ -> {:error, :no_legal_pairing}
    end
  end

  defp ranks(players), do: Enum.map(players, & &1.rank)

  # 5.1's initial colour. A file that does not record the draw (no 152)
  # shows it in round 1, where 5.2.1 decided every board: the higher ranked
  # player of the first board got the initial colour if their number was
  # odd. With no round 1 yet, White - the Dutch engine's default too.
  defp initial_colour("w", _players, _ps), do: :white
  defp initial_colour("b", _players, _ps), do: :black

  defp initial_colour(nil, players, point_system) do
    by_rank = Map.new(players, &{&1.rank, &1})
    numbers = round_one_numbers(players)

    players
    |> Enum.sort_by(& &1.rank)
    |> Enum.find_value(:white, fn p ->
      with [game | _] <- p.games,
           true <- is_integer(game.opponent_rank) and game.colour in ["w", "b"],
           %{} = opp <- by_rank[game.opponent_rank] do
        own = Player.score_before(p, 1, point_system)
        theirs = Player.score_before(opp, 1, point_system)
        high? = own > theirs or (own == theirs and p.rank < opp.rank)
        {high, colour} = if high?, do: {p, game.colour}, else: {opp, flip(game.colour)}
        number = Map.get(numbers, high.rank, high.rank)
        given = if colour == "w", do: :white, else: :black
        if rem(number, 2) == 1, do: given, else: opposite(given)
      else
        _ -> nil
      end
    end)
  end

  # Round 1's arrival numbering: the players who took part in its pairing,
  # numbered in TPN order.
  defp round_one_numbers(players) do
    players
    |> Enum.filter(fn p ->
      match?([g | _] when g != nil, p.games) and Trf.participated_in_pairing?(hd(p.games))
    end)
    |> Enum.sort_by(& &1.rank)
    |> Enum.with_index(1)
    |> Map.new(fn {p, i} -> {p.rank, i} end)
  end

  defp flip("w"), do: "b"
  defp flip("b"), do: "w"

  defp opposite(:white), do: :black
  defp opposite(:black), do: :white
end

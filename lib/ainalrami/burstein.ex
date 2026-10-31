defmodule Ainalrami.Burstein do
  @moduledoc """
  The FIDE Burstein System, C.04.4.2, approved by the Council on
  28/10/2025 and applied from 1 February 2026.

  The reading - every place the text ran out and what was decided there -
  is `docs/conformance-c0442-burstein.md`; the plan it was built to is
  `docs/design-other-swiss-systems.md` §1.2. Article numbers below are
  C.04.4.2's.

  ## Two systems in one

  The first min(floor(rounds / 2), 4) rounds are the **seeding rounds**
  (1.6), "paired following the rules of the FIDE (Dutch) System": they are
  handed to `Ainalrami.Pairing` unchanged, colours included. From the next
  round on the Burstein procedure pairs:

      1. the pairing-allocated bye, if the field is odd       (3.1)
      2. brackets top down: the residents of the highest      (1.9.2)
         scoregroup left plus the incoming floaters; for each,
         the first pairing in 4.3's order that complies        (3.2, 4)
         best with [C1]-[C8]
      3. colours, pair by pair                                (5.2)

  Inside a bracket the players are ranked by an **index** - Buchholz, then
  Sonneborn-Berger, then TPN (1.8) - and never by score. The pieces:
  `Ainalrami.Burstein.Player` (the index, colour preferences),
  `Ainalrami.Burstein.Bracket` (3.2 over one weighted matching),
  `Ainalrami.Burstein.Order` (4.3) and `Ainalrami.Burstein.Colour` (5.2).
  The compatibility graph and its [C4] oracle are the Dubov system's
  (`Ainalrami.Dubov.Graph`): both systems have the same [C1] and [C3].

  ## Usage

      {:ok, round} = Ainalrami.Burstein.pair_round(players, expected_rounds: 9)
      round.pairs  # [{white, black}, ...]
      round.bye    # the rank given the pairing-allocated bye, or nil

  Options:

    * `:expected_rounds` - required: the seeding rounds are counted from it.
    * `:initial_colour` - `"w"` or `"b"` (5.1). Absent: what round 1 shows,
      the way the Dutch engine infers it, or White before round 1.
    * `:point_system`, `:forbidden_pairs` - as `Ainalrami.Pairing` takes
      them. A forbidden pair counts as a pair that has met ([C1]).

  The Dutch engine's organiser options - bye exclusions and preferences,
  soft pairs, pairing groups, the match format - are not FIDE's, so not
  Burstein's either; given one, the round is refused.

  ## Answers

  `{:ok, %{pairs:, bye:, round:, seeding?:, brackets:}}`, or
  `{:error, reason}`:

    * `:no_legal_pairing` - no complete round-pairing exists (1.9.3: the
      Chief Arbiter decides). Burstein's [C3] has no topscorer exception
      (reading B10). In a seeding round, the Dutch engine's refusal;
    * `:no_legal_bye` - nobody can take the bye and leave the rest pairable;
    * `:expected_rounds_required`, `{:beyond_expected_rounds, round}`;
    * `{:unsupported_option, key}`, `{:invalid_option, key, value}`.
  """

  alias Ainalrami.{Pairing, Trf}
  alias Ainalrami.Burstein.{Bracket, Colour, Player}
  alias Ainalrami.Dubov.Graph

  @unsupported [:bye_exclusions, :bye_preferences, :soft_pairs, :groups, :match_format]

  @doc "1.6.2: the number of seeding rounds of a tournament of `rounds` rounds."
  def seeding_rounds(rounds), do: min(div(rounds, 2), 4)

  @doc """
  The round as `Ainalrami.Pairing.pair_next_round/2` gives it: pairs in
  board order, the bye last as `{rank, nil}`.
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
      round = Trf.rounds_played(players) + 1
      rounds = opts[:expected_rounds]

      cond do
        round > rounds -> {:error, {:beyond_expected_rounds, round}}
        round <= seeding_rounds(rounds) -> seeding(players, round, opts)
        true -> pair(players, round, opts)
      end
    end
  end

  defp dutch_keys, do: [:expected_rounds, :initial_colour, :point_system, :forbidden_pairs]

  defp check_options(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_option, :opts, opts}}

      key = Enum.find(@unsupported, &(opts[&1] not in [nil, [], false])) ->
        {:error, {:unsupported_option, key}}

      not is_integer(opts[:expected_rounds]) ->
        {:error, :expected_rounds_required}

      opts[:expected_rounds] < 1 ->
        {:error, {:invalid_option, :expected_rounds, opts[:expected_rounds]}}

      true ->
        :ok
    end
  end

  # 1.6.1: the Dutch system, as it stands. Its pairs come back in its board
  # order with the bye last.
  defp seeding(players, round, opts) do
    pairs = Pairing.pair_next_round(players, Keyword.take(opts, dutch_keys()))
    {byes, games} = Enum.split_with(pairs, fn {_w, b} -> is_nil(b) end)

    {:ok,
     %{
       round: round,
       seeding?: true,
       pairs: games,
       bye: Enum.find_value(byes, fn {w, nil} -> w end),
       brackets: []
     }}
  rescue
    _e in Pairing.NoValidPairingError -> {:error, :no_legal_pairing}
  end

  defp pair(players, round, opts) do
    point_system = opts[:point_system] || Trf.default_point_system()
    by_rank = Map.new(players, &{&1.rank, &1})

    context = %{
      index: Player.index(players, round, point_system),
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
          met?(by_rank[a.rank], b.rank) or
          (a.strength == :absolute and b.strength == :absolute and a.colour == b.colour)
      end)

    with {:ok, bye, rest} <- assign_bye(active, field),
         {:ok, brackets} <- pair_brackets([], rest, field, []) do
      numbers = Pairing.arrival_numbers(players, round)
      initial = initial_colour(opts[:initial_colour], players)

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
         seeding?: false,
         pairs: for(b <- brackets, p <- b.pairs, do: {p.white, p.black}),
         bye: bye && bye.rank,
         brackets: brackets
       }}
    end
  end

  # [C1] is about games PLAYED (C.04.2 Article 3.5): a forfeit is no meeting.
  defp met?(player, rank) do
    Enum.any?(player.games, &(&1.opponent_rank == rank and Player.played?(&1)))
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

  # 3.1: [C2], leaves the rest pairable ([C4]), lowest score, most games
  # played, lowest ranking by 1.8 (the smallest index, then the largest TPN).
  defp assign_bye(active, field) do
    ranks = Enum.map(active, & &1.rank)

    if rem(length(active), 2) == 0 do
      if Graph.feasible?(ranks, field), do: {:ok, nil, active}, else: {:error, :no_legal_pairing}
    else
      active
      |> Enum.filter(& &1.bye_eligible?)
      |> Enum.sort_by(&{&1.score, -&1.played, &1.buchholz, &1.sonneborn, -&1.rank})
      |> Enum.find(&Graph.feasible?(List.delete(ranks, &1.rank), field))
      |> case do
        nil -> {:error, :no_legal_bye}
        bye -> {:ok, bye, List.delete(active, bye)}
      end
    end
  end

  # 1.9.2: bracket by bracket, the incoming floaters joining the highest
  # scoregroup left.
  defp pair_brackets([], [], _field, acc), do: {:ok, Enum.reverse(acc)}

  defp pair_brackets(incoming, rest, field, acc) do
    top = rest |> Enum.map(& &1.score) |> Enum.max(fn -> nil end)
    {residents, lower} = Enum.split_with(rest, &(&1.score == top))

    case Bracket.pair(incoming ++ residents, lower, field) do
      {:ok, result} ->
        bracket = %{
          score: top,
          residents: Enum.map(residents, & &1.rank),
          incoming: Enum.map(incoming, & &1.rank),
          bsn: result.bsn,
          floaters: Enum.map(result.floaters, & &1.rank),
          pairs: result.pairs
        }

        pair_brackets(result.floaters, lower, field, [bracket | acc])

      :error ->
        {:error, :no_legal_pairing}
    end
  end

  @doc """
  The initial colour (5.1) as `"w"` or `"b"`: given, or read off round 1 -
  a seeding round, paired by the Dutch system, whose rank-1 player (by
  arrival number) held the initial colour on an odd number. White before
  round 1.
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
    # Round 1's numbering: the players who took part in its pairing.
    numbers =
      players
      |> Enum.filter(&match?([g | _] when g != nil, &1.games))
      |> Enum.filter(&Trf.participated_in_pairing?(hd(&1.games)))
      |> Enum.sort_by(& &1.rank)
      |> Enum.with_index(1)
      |> Map.new(fn {p, i} -> {p.rank, i} end)

    players
    |> Enum.sort_by(& &1.rank)
    |> Enum.find_value(:white, fn p ->
      with [%{colour: c} | _] when c in ["w", "b"] <- p.games,
           n when is_integer(n) <- Map.get(numbers, p.rank) do
        given = if c == "w", do: :white, else: :black
        if rem(n, 2) == 1, do: given, else: opposite(given)
      else
        _ -> nil
      end
    end)
  end

  defp opposite(:white), do: :black
  defp opposite(:black), do: :white
end

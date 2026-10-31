defmodule Ainalrami.DubovCLI do
  @moduledoc """
  The command line's other FIDE Swiss systems - Dubov (C.04.4.1) and
  Burstein (C.04.4.2) and Lim (C.04.4.3): which system a file is paired by, the options
  `Ainalrami.Dubov` and `Ainalrami.Burstein` take from a parsed file and
  the flags, and the words for their refusals. `Ainalrami.CLI` does the
  reading, writing and replaying, exactly as for the Dutch system. (The
  module kept the name of the first system it served.)

  ## Which system

  `192 FIDE_DUBOV`/`FIDE_DUBOV_BAKU` or `192 FIDE_BURSTEIN`/`FIDE_BURSTEIN_BAKU`
  in the file, or `--system=dubov|burstein` on the command line. The Baku
  codes add nothing of their own: virtual points ride on the players
  (`XXA`/`250`, or `--acceleration=baku`), as they do for the Dutch system.
  A flag that contradicts the file's `192` is refused with exit 2 rather
  than either one winning quietly.

  ## What the Dubov system takes

    * the round count (`142`/`XXR`, `--rounds`) - required;
    * every player's rating (`001`), and for an unrated player a provisional
      one (`XXO provisional-rating RANK RATING`, `--provisional-rating=12:1500/17:1400`;
      the flag wins per player);
    * the initial colour, the point system, `XXP` pairs, pre-recorded byes,
      as the Dutch system does.

  ## What the Burstein system takes

    * the round count - required: the seeding rounds (1.6.2) are counted
      from it;
    * the initial colour, the point system, `XXP` pairs, pre-recorded byes.
      No ratings: the index is made of the tournament's own results.

  ## What the Lim system takes

  `192 CUSTOM_SWISS` with `XXO system lim` (TRF26 has no Lim code; reading
  L11), or the record alone, or `--system=lim`; the round count (the last
  round differs, Article 6); the initial colour, the point system, `XXP`
  pairs, pre-recorded byes. No ratings, no acceleration, no Maxi rules.

  The organiser's own options (soft pairs, bye preferences and exclusions,
  pairing groups, the match format), `-x`, `--proof` and the explain
  alternatives belong to the Dutch engine and are refused for either.
  """

  alias Ainalrami.{Burstein, Dubov, Lim, TypeCode}

  @systems %{"dutch" => :dutch, "dubov" => :dubov, "burstein" => :burstein, "lim" => :lim}
  @others [:dubov, :burstein]

  # Flags the Dubov and Burstein routes do not have.
  @refused ~w(proof cascade-order soft-pairs soft-position bye-exclude bye-want bye-want-soft
              bye-avoid bye-avoid-soft judge bye-alternatives float-alternatives
              alternative-pairs max-candidates force absent)

  @doc "The flags a Dubov or Burstein file refuses."
  def refused_flags, do: @refused

  @doc "The system's name in a sentence."
  def name(:dubov), do: "Dubov system"
  def name(:burstein), do: "Burstein system"
  def name(:lim), do: "Lim system"

  @doc "The system's name with its article number."
  def title(:dubov), do: "the Dubov system (C.04.4.1)"
  def title(:burstein), do: "the Burstein system (C.04.4.2)"
  def title(:lim), do: "the Lim system (C.04.4.3)"

  @doc """
  `:dutch`, `:dubov`, `:burstein`, or `{:refuse, exit_code, message}` for a
  parsed file and the value of `--system` (nil when not given).
  """
  def system(parsed, flag) do
    code = parsed.tournament[:type_code]

    from_file =
      case is_binary(code) and code != "" and TypeCode.parse(code) do
        {:ok, %{system: system, code: code}} -> {system, code}
        _ -> nil
      end

    lim? = parsed.tournament[:pairing_system] == "lim"

    file_system =
      case from_file do
        {system, _code} when system in @others -> system
        _ when lim? -> :lim
        _ -> :dutch
      end

    cond do
      lim? and from_file != nil and elem(from_file, 1) != "CUSTOM_SWISS" ->
        {:refuse, 2,
         "XXO system lim contradicts the file's 192 #{elem(from_file, 1)} - " <>
           "a Lim file says 192 CUSTOM_SWISS or nothing"}

      flag != nil and not Map.has_key?(@systems, flag) ->
        {:refuse, 1, "unknown --system \"#{flag}\" - dutch, dubov, burstein or lim"}

      flag == nil ->
        file_system

      from_file == nil and not lim? ->
        @systems[flag]

      flag == "lim" and from_file != nil and elem(from_file, 1) == "CUSTOM_SWISS" ->
        :lim

      @systems[flag] == file_system ->
        file_system

      true ->
        code = if lim?, do: "CUSTOM_SWISS + XXO system lim", else: elem(from_file, 1)

        {:refuse, 2,
         "--system=#{flag} contradicts the file's 192 #{code} - " <>
           "correct one of them rather than have either win"}
    end
  end

  @doc """
  `--provisional-rating=12:1500/17:1400`: `%{rank => rating}`, `{:error,
  message}` when malformed, `%{}` when absent.
  """
  def provisional_flag(nil), do: %{}

  def provisional_flag(text) do
    text
    |> String.split(["/", ","], trim: true)
    |> Enum.reduce_while(%{}, fn item, acc ->
      with [rank, rating] <- String.split(item, ":"),
           {rank, ""} when rank > 0 <- Integer.parse(rank),
           {rating, ""} when rating > 0 <- Integer.parse(rating) do
        {:cont, Map.put(acc, rank, rating)}
      else
        _ ->
          {:halt,
           {:error,
            "--provisional-rating takes RANK:RATING pairs separated by / " <>
              "(e.g. 12:1500/17:1400), not \"#{item}\""}}
      end
    end)
  end

  @doc "The options `Ainalrami.Dubov` pairs a parsed file with."
  def opts(tournament, provisional) do
    [
      expected_rounds: tournament[:number_of_rounds],
      initial_colour: tournament[:initial_colour],
      point_system: tournament[:point_system],
      forbidden_pairs: tournament[:forbidden_pairs],
      provisional_ratings: Map.merge(tournament[:provisional_ratings] || %{}, provisional)
    ]
  end

  @doc "The options `Ainalrami.Lim` pairs a parsed file with: Burstein's."
  def lim_opts(tournament), do: burstein_opts(tournament)

  @doc "The options `Ainalrami.Burstein` pairs a parsed file with."
  def burstein_opts(tournament) do
    [
      expected_rounds: tournament[:number_of_rounds],
      initial_colour: tournament[:initial_colour],
      point_system: tournament[:point_system],
      forbidden_pairs: tournament[:forbidden_pairs]
    ]
  end

  @doc """
  Pairs the next round by `system`: `{:ok, pairs}` (the bye last, as
  `{rank, nil}`) or `{:error, message}`.
  """
  def pair(:dubov, players, opts) do
    case Dubov.pair_next_round(players, opts) do
      {:ok, pairs} -> {:ok, pairs}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  def pair(:burstein, players, opts) do
    case Burstein.pair_next_round(players, opts) do
      {:ok, pairs} -> {:ok, pairs}
      {:error, reason} -> {:error, describe_burstein(reason)}
    end
  end

  def pair(:lim, players, opts) do
    case Lim.pair_next_round(players, opts) do
      {:ok, pairs} -> {:ok, pairs}
      {:error, reason} -> {:error, describe_lim(reason)}
    end
  end

  @doc "What a refusal of `Ainalrami.Lim.pair_round/2` means, in words."
  def describe_lim(:no_legal_pairing),
    do:
      "no legal pairing exists for this round under the Lim system's compatibility rule " <>
        "(2.1: no rematch, no third colour in succession, no three more of one colour); " <>
        "the Chief Arbiter decides"

  def describe_lim(:expected_rounds_required),
    do:
      "the Lim system needs the tournament's round count (142/XXR or --rounds): " <>
        "the last round is paired differently (Article 6)"

  def describe_lim({:unsupported_option, :acceleration}),
    do: "the Lim system has no acceleration - the file's virtual points (XXA/250) are refused"

  def describe_lim({:unsupported_option, key}),
    do: "#{key} is not part of the Lim system"

  def describe_lim(other), do: describe(other)

  @doc "What a refusal of `Ainalrami.Burstein.pair_round/2` means, in words."
  def describe_burstein(:no_legal_pairing),
    do:
      "no legal pairing exists for this round under the Burstein system's absolute criteria " <>
        "([C1] no rematch, [C3] no two players with the same absolute colour preference - " <>
        "no topscorer exception); C.04.4.2 1.9.3 leaves the round to the Chief Arbiter"

  def describe_burstein(:expected_rounds_required),
    do:
      "the Burstein system needs the tournament's round count (142/XXR or --rounds): " <>
        "the seeding rounds (1.6.2) are counted from it"

  def describe_burstein({:unsupported_option, key}),
    do: "#{key} is not part of the Burstein system"

  def describe_burstein(other), do: describe(other)
  @doc "What a refusal of `Ainalrami.Dubov.pair_round/2` means, in words."
  def describe(:no_legal_pairing),
    do:
      "no legal pairing exists for this round under the Dubov system's absolute criteria " <>
        "([C1] no rematch, [C3] no two players with the same absolute colour preference - " <>
        "no topscorer exception); C.04.4.1 1.9.3 leaves the round to the Chief Arbiter"

  def describe(:no_legal_bye),
    do: "no player may take the pairing-allocated bye and leave the rest pairable (3.1)"

  def describe({:unrated, ranks}),
    do:
      "the Dubov system pairs by rating and every player must have one (1.1.1): " <>
        "unrated #{Enum.join(ranks, ", ")} - give a provisional rating " <>
        "(--provisional-rating=RANK:RATING or XXO provisional-rating RANK RATING, 1.1.2)"

  def describe({:provisional_for_rated, ranks}),
    do:
      "a provisional rating is for an unrated player (1.1.2), and " <>
        "#{Enum.join(ranks, ", ")} already have one"

  def describe(:expected_rounds_required),
    do:
      "the Dubov system needs the tournament's round count (142/XXR or --rounds): " <>
        "MaxT (1.8.2) and the last-round exceptions of [C8]-[C10] depend on it"

  def describe({:beyond_expected_rounds, round}),
    do: "round #{round} is past the tournament's declared round count"

  def describe({:unsupported_option, key}),
    do: "#{key} is not part of the Dubov system"

  def describe(other), do: "not paired: #{inspect(other)}"
end

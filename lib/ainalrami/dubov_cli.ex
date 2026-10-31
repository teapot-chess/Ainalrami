defmodule Ainalrami.DubovCLI do
  @moduledoc """
  The command line's Dubov system (C.04.4.1): which system a file is paired
  by, the options `Ainalrami.Dubov` takes from a parsed file and the flags,
  and the words for its refusals. `Ainalrami.CLI` does the reading,
  writing and replaying, exactly as for the Dutch system.

  ## Which system

  `192 FIDE_DUBOV` or `192 FIDE_DUBOV_BAKU` in the file, or
  `--system=dubov` on the command line. The Baku code adds nothing of its
  own: virtual points ride on the players (`XXA`/`250`, or
  `--acceleration=baku`), as they do for the Dutch system. A flag that
  contradicts the file's `192` is refused with exit 2 rather than either
  one winning quietly.

  ## What the Dubov system takes

    * the round count (`142`/`XXR`, `--rounds`) - required;
    * every player's rating (`001`), and for an unrated player a provisional
      one (`XXO provisional-rating RANK RATING`, `--provisional-rating=12:1500/17:1400`;
      the flag wins per player);
    * the initial colour, the point system, `XXP` pairs, pre-recorded byes,
      as the Dutch system does.

  The organiser's own options (soft pairs, bye preferences and exclusions,
  pairing groups, the match format), `-x`, `--proof` and the explain
  alternatives belong to the Dutch engine and are refused for a Dubov file.
  """

  alias Ainalrami.{Dubov, TypeCode}

  @systems %{"dutch" => :dutch, "dubov" => :dubov}
  @not_built ~w(burstein lim)

  # Flags the Dubov route does not have.
  @refused ~w(proof cascade-order soft-pairs soft-position bye-exclude bye-want bye-want-soft
              bye-avoid bye-avoid-soft judge bye-alternatives float-alternatives
              alternative-pairs max-candidates force absent)

  @doc "The flags a Dubov file refuses."
  def refused_flags, do: @refused

  @doc """
  `:dutch`, `:dubov`, or `{:refuse, exit_code, message}` for a parsed file
  and the value of `--system` (nil when not given).
  """
  def system(parsed, flag) do
    code = parsed.tournament[:type_code]

    from_file =
      case is_binary(code) and code != "" and TypeCode.parse(code) do
        {:ok, %{system: system, code: code}} -> {system, code}
        _ -> nil
      end

    cond do
      flag in @not_built ->
        {:refuse, 2, "--system=#{flag}: not built yet - this program pairs dutch and dubov"}

      flag != nil and not Map.has_key?(@systems, flag) ->
        {:refuse, 1, "unknown --system \"#{flag}\" - dutch or dubov"}

      flag == nil ->
        if match?({:dubov, _}, from_file), do: :dubov, else: :dutch

      flag == "dubov" and from_file in [nil] ->
        :dubov

      flag == "dubov" and match?({:dubov, _}, from_file) ->
        :dubov

      flag == "dutch" and not match?({:dubov, _}, from_file) ->
        :dutch

      true ->
        {_system, code} = from_file

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

  @doc "Pairs the next round: `{:ok, pairs}` (the bye last, as `{rank, nil}`) or `{:error, message}`."
  def pair(players, opts) do
    case Dubov.pair_next_round(players, opts) do
      {:ok, pairs} -> {:ok, pairs}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

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

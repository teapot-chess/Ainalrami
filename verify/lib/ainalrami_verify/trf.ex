defmodule AinalramiVerify.Trf do
  @moduledoc """
  A deliberately small TRF reader, written for this suite and sharing no
  code with `Ainalrami.Trf`.

  It reads what a Dutch round needs and refuses, by name, what it does not
  understand well enough to judge: acceleration, forbidden pairs, a point
  system other than 1 / ½ / 0, other pairing systems, team records. A
  checker that silently ignored an acceleration would report the engine
  wrong on every accelerated file, and be wrong itself.

  Player records (`001`), columns 1-based as the TRF specification lays
  them out: starting rank 5-8, rating 49-52, then one 10-column block per
  round from column 92: opponent 92-95, colour 97, result 99.

  Scores are kept in HALF-POINTS (a win is 2), so every comparison is on
  integers.
  """

  defmodule Error do
    defexception [:message]
  end

  @type game :: %{opponent: pos_integer() | nil, colour: :w | :b | nil, code: String.t()}
  @type t :: %{
          players: %{
            pos_integer() => %{
              rank: pos_integer(),
              rating: integer(),
              games: %{pos_integer() => game}
            }
          },
          rounds: pos_integer() | nil,
          initial_colour: :w | :b | nil
        }

  # Results a TRF may carry, with their value in half-points and whether
  # the game was played over the board.
  @codes %{
    "1" => {2, true},
    "W" => {2, true},
    "=" => {1, true},
    "D" => {1, true},
    "0" => {0, true},
    "L" => {0, true},
    "+" => {2, false},
    "-" => {0, false},
    "U" => {2, false},
    "F" => {2, false},
    "H" => {1, false},
    "Z" => {0, false}
  }

  @refused %{
    "XXA" => "acceleration (XXA)",
    "250" => "acceleration (250)",
    "XXP" => "forbidden pairs (XXP)",
    "260" => "forbidden pairs (260)",
    "BBW" => "a point system (BBW)",
    "BBD" => "a point system (BBD)",
    "BBL" => "a point system (BBL)",
    "BBZ" => "a point system (BBZ)",
    "BBF" => "a point system (BBF)",
    "BBU" => "a point system (BBU)",
    "162" => "a point system (162)",
    "310" => "team records (310)",
    "XXG" => "pairing groups (XXG)",
    "XXM" => "match format (XXM)"
  }

  @doc "Value of a result code in half-points."
  def points(code), do: code |> lookup() |> elem(0)

  @doc "Whether a result code is a game played over the board."
  def played?(code), do: code |> lookup() |> elem(1)

  defp lookup(code) do
    case Map.fetch(@codes, code) do
      {:ok, v} -> v
      :error -> raise Error, "unknown result code #{inspect(code)}"
    end
  end

  @doc "Parses TRF text. Raises `AinalramiVerify.Trf.Error` on anything it will not judge."
  @spec parse(String.t()) :: t()
  def parse(text) do
    lines =
      text
      |> String.replace_prefix("﻿", "")
      |> String.split(~r/\r\n|\r|\n/)

    acc = %{players: %{}, rounds: nil, initial_colour: nil, absent: []}

    acc =
      Enum.reduce(lines, acc, fn line, acc ->
        code = line |> String.slice(0, 3)

        cond do
          code == "001" -> add_player(acc, line)
          Map.has_key?(@refused, code) -> raise Error, "not supported: #{@refused[code]}"
          code in ["XXR", "142"] -> %{acc | rounds: int(String.slice(line, 3..-1//1))}
          code == "152" -> %{acc | initial_colour: colour_word(String.slice(line, 3..-1//1))}
          code == "XXC" -> xxc(acc, line)
          code == "XXZ" -> %{acc | absent: acc.absent ++ ints(String.slice(line, 3..-1//1))}
          code == "192" -> system(acc, line)
          true -> acc
        end
      end)

    if acc.players == %{}, do: raise(Error, "no player records (001)")
    apply_absent(acc)
  end

  defp system(acc, line) do
    case line |> String.slice(3..-1//1) |> String.trim() |> String.upcase() do
      s when s in ["", "FIDE_DUTCH", "FIDE_DUTCH_BAKU"] ->
        if String.ends_with?(s, "BAKU"), do: raise(Error, "not supported: Baku acceleration")
        acc

      s ->
        raise Error, "not supported: pairing system #{s} (Dutch only)"
    end
  end

  defp xxc(acc, line) do
    words = line |> String.slice(3..-1//1) |> String.downcase() |> String.split()

    cond do
      "white1" in words -> %{acc | initial_colour: :w}
      "black1" in words -> %{acc | initial_colour: :b}
      true -> acc
    end
  end

  defp colour_word(s) do
    case s |> String.trim() |> String.downcase() |> String.first() do
      "w" -> :w
      "b" -> :b
      _ -> nil
    end
  end

  defp add_player(acc, line) do
    line = String.pad_trailing(line, 91)
    rank = int(String.slice(line, 4, 4)) || raise(Error, "a 001 record without a starting rank")
    rating = int(String.slice(line, 48, 4)) || 0
    if Map.has_key?(acc.players, rank), do: raise(Error, "starting rank #{rank} twice")
    games = parse_rounds(String.slice(line, 91..-1//1), 1, %{}, rank)
    put_in(acc, [:players, rank], %{rank: rank, rating: rating, games: games})
  end

  defp parse_rounds(rest, r, acc, rank) do
    if String.trim(rest) == "" do
      acc
    else
      block = String.pad_trailing(String.slice(rest, 0, 8), 8)
      opp = String.slice(block, 0, 4) |> String.trim()
      colour = String.slice(block, 5, 1) |> String.trim()
      code = String.slice(block, 7, 1) |> String.trim()
      next = String.slice(rest, 10..-1//1)

      if opp == "" and colour == "" and code == "" do
        parse_rounds(next, r + 1, acc, rank)
      else
        opponent =
          case int(opp) do
            nil -> nil
            0 -> nil
            n -> n
          end

        colour =
          case String.downcase(colour) do
            "w" -> :w
            "b" -> :b
            _ -> nil
          end

        code = if code == "", do: "Z", else: String.upcase(code)
        _ = lookup(code)

        if played?(code) and (opponent == nil or colour == nil),
          do:
            raise(Error, "rank #{rank}, round #{r}: a played game needs an opponent and a colour")

        parse_rounds(
          next,
          r + 1,
          Map.put(acc, r, %{opponent: opponent, colour: colour, code: code}),
          rank
        )
      end
    end
  end

  # XXZ: absent from the round being paired - read as a zero-point bye in
  # the first round no player has a game for.
  defp apply_absent(%{absent: []} = acc), do: Map.delete(acc, :absent)

  defp apply_absent(acc) do
    r = next_round(acc.players)

    players =
      Enum.reduce(acc.absent, acc.players, fn rank, players ->
        case players do
          %{^rank => p} ->
            Map.put(players, rank, %{
              p
              | games: Map.put_new(p.games, r, %{opponent: nil, colour: nil, code: "Z"})
            })

          _ ->
            raise Error, "XXZ names rank #{rank}, which has no 001 record"
        end
      end)

    acc |> Map.put(:players, players) |> Map.delete(:absent)
  end

  @doc """
  The round a file asks to be paired: one after the last round in which
  any player has a game with an opponent, or a pairing-allocated bye.
  Entries already present in that round (a requested bye, an absence) take
  their player out of the pool.
  """
  def next_round(%{players: players}), do: next_round(players)

  def next_round(players) when is_map(players) do
    base =
      players
      |> Map.values()
      |> Enum.flat_map(fn p ->
        for {r, g} <- p.games, g.opponent != nil or g.code in ["U", "+"], do: r
      end)
      |> Enum.max(fn -> 0 end)

    # A column every player has an entry in is a round already decided,
    # byes and all: it counts as played (the TRF convention the engine and
    # bbpPairings share).
    if Enum.all?(Map.values(players), &Map.has_key?(&1.games, base + 1)),
      do: base + 2,
      else: base + 1
  end

  defp int(s) do
    case s |> String.trim() |> Integer.parse() do
      {n, _} -> n
      :error -> nil
    end
  end

  defp ints(s), do: s |> String.split() |> Enum.map(&int/1) |> Enum.reject(&is_nil/1)
end

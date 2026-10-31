defmodule Ainalrami.Lim.Colour do
  @moduledoc """
  C.04.4.3 Article 5: the colours of one pair, decided pair by pair.

    1. Neither player has a colour history (round 1, two late entrants):
       7.2 - the higher ranked takes the initial colour on an odd pairing
       number and the other one on an even number (reading L13).
    2. One has a history: they get their due colour.
    3. The due colours differ: both get them.
    4. Both are due the same colour:
       a. one must have it (5.3 - twice the same colour, or 5.1.2's
          limit) and the other need not: the one who must;
       b. otherwise 5.4 - "the colours they had in earlier rounds, going
          back in sequence": at the most recent round where their colours
          differ, the player who had the colour opposite to the one both
          are due gets it;
       c. identical histories: at or above the median scoregroup the
          higher ranked, below it the lower ranked (5.4).

  "Higher ranked" is the smaller pairing number (2.4; reading L1).
  """

  alias Ainalrami.Lim.Player

  @doc """
  `{white_rank, black_rank, article}` for the pair `x`, `y` of a group
  whose score is `score`, with `median` the median score and `initial`
  `:white` or `:black`.
  """
  def allocate(%Player{} = x, %Player{} = y, score, median, initial) do
    {first, article} = first_choice(x, y, score, median, initial)
    {gets, other} = if first == :x, do: {x, y}, else: {y, x}
    colour = wanted(gets, other, initial)

    if colour == :white,
      do: {gets.rank, other.rank, article},
      else: {other.rank, gets.rank, article}
  end

  @doc "How many of the two players do not get the colour they are due."
  def denied(%Player{} = x, %Player{} = y, score, median, initial) do
    {w, _b, _} = allocate(x, y, score, median, initial)

    Enum.count([x, y], fn p ->
      got = if p.rank == w, do: :white, else: :black
      p.colour != nil and p.colour != got
    end)
  end

  # Which of the two players is served first, and the colour they get
  # (their due colour, or 7.2's for a player without one).
  defp first_choice(x, y, score, median, _initial) do
    cond do
      is_nil(x.colour) and is_nil(y.colour) -> {higher(x, y), "7.2"}
      is_nil(x.colour) -> {:y, "5.1"}
      is_nil(y.colour) -> {:x, "5.1"}
      x.colour != y.colour -> {:x, "5.1"}
      x.strength == :absolute and y.strength != :absolute -> {:x, "5.3"}
      y.strength == :absolute and x.strength != :absolute -> {:y, "5.3"}
      true -> history(x, y, score, median)
    end
  end

  defp wanted(%Player{colour: nil} = p, _other, initial) do
    if rem(p.rank, 2) == 1, do: initial, else: opposite(initial)
  end

  defp wanted(%Player{colour: c}, _other, _initial), do: c

  defp history(x, y, score, median) do
    due = x.colour

    Enum.zip(Enum.reverse(x.colours), Enum.reverse(y.colours))
    |> Enum.find(fn {a, b} -> a != b end)
    |> case do
      {a, _b} -> {if(a == opposite(due), do: :x, else: :y), "5.4"}
      nil when score >= median -> {higher(x, y), "5.4 rank"}
      nil -> {lower(x, y), "5.4 rank"}
    end
  end

  defp higher(x, y), do: if(x.rank < y.rank, do: :x, else: :y)
  defp lower(x, y), do: if(x.rank > y.rank, do: :x, else: :y)

  defp opposite(:white), do: :black
  defp opposite(:black), do: :white
end

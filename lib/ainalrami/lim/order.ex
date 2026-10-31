defmodule Ainalrami.Lim.Order do
  @moduledoc """
  C.04.4.3's scrutiny order inside a group (reading L5): who chooses next
  and in which order their possible partners are tried.

    1. **Incoming floaters first.** Pairing downward (and in the median
       group): the down-floaters, highest score first, then the best
       ranked (3.6, 3.6.1, 3.6.2), then the up-floaters (3.6.3). Pairing
       upward: the up-floaters, lowest score first, then the lowest ranked
       (3.7, 3.7.1, 3.7.2). A down-floater tries the residents best ranked
       first, an up-floater worst ranked first, those due the colour
       opposite to the floater's own first (3.8); then the other floaters
       in the same order.
    2. **Then the residents left**, in pairing-number order - from the top
       pairing downward, from the bottom pairing upward (4.1.1, 4.1.2) -
       split into a first and a second half (2.4). The first unpaired
       player in that order tries the second half's unpaired players in
       order, then the first half's from its far end back: for #1 of six,
       4, 5, 6, 3, 2 (4.2); for #2 with #1 v #6 fixed, 4, 5, 3 (4.3).

  "Highest numbered" in the text is the best ranked, #1 (4.2: "Player #1,
  the highest numbered player in the scoregroup"; reading L1).
  """

  defstruct [:score, :floaters, :residents]

  @doc "The order for the players `paired` of a group of score `score`."
  def new(paired, score, direction) do
    downs = paired |> Enum.filter(&(&1.score > score)) |> Enum.sort_by(&{-&1.score, &1.rank})
    ups = paired |> Enum.filter(&(&1.score < score)) |> Enum.sort_by(&{&1.score, -&1.rank})
    residents = Enum.filter(paired, &(&1.score == score))

    %__MODULE__{
      score: score,
      floaters: if(direction == :up, do: ups ++ downs, else: downs ++ ups),
      residents: Enum.sort_by(residents, & &1.rank, if(direction == :up, do: :desc, else: :asc))
    }
  end

  @doc """
  The next choice given `partner` (`%{rank => rank}`, both directions, of
  the pairs fixed so far): `{picker, candidates}` or `:done`.
  """
  def next(%__MODULE__{} = order, partner) do
    case Enum.find(order.floaters, &(not Map.has_key?(partner, &1.rank))) do
      nil -> next_resident(order, partner)
      floater -> {floater, floater_candidates(order, floater, partner)}
    end
  end

  defp floater_candidates(order, floater, partner) do
    direction = if floater.score > order.score, do: :asc, else: :desc
    free = &(not Map.has_key?(partner, &1.rank) and &1.rank != floater.rank)

    residents = order.residents |> Enum.filter(free) |> Enum.sort_by(& &1.rank, direction)
    others = order.floaters |> Enum.filter(free) |> Enum.sort_by(& &1.rank, direction)
    {alternate, rest} = Enum.split_with(residents, &alternate?(floater, &1))
    alternate ++ rest ++ others
  end

  defp alternate?(%{colour: nil}, _), do: false
  defp alternate?(floater, other), do: other.colour != nil and other.colour != floater.colour

  defp next_resident(order, partner) do
    floater_ranks = MapSet.new(order.floaters, & &1.rank)

    left =
      Enum.reject(order.residents, fn p ->
        MapSet.member?(floater_ranks, Map.get(partner, p.rank))
      end)

    {first, second} = Enum.split(left, div(length(left), 2))
    free = &(not Map.has_key?(partner, &1.rank))

    case Enum.find(left, free) do
      nil ->
        :done

      picker ->
        candidates =
          (Enum.filter(second, free) ++ Enum.reverse(Enum.filter(first, free)))
          |> Enum.reject(&(&1.rank == picker.rank))

        {picker, candidates}
    end
  end
end

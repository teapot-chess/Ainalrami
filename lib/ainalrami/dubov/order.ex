defmodule Ainalrami.Dubov.Order do
  @moduledoc """
  The sorting criteria of C.04.4.1 Article 4: the orders every choice in the
  Dubov system is "the first" of.

    * 4.1.3 - sets of K players from a numbered pool, ordered by the
      smallest differing sequence number: `sets/2`, `reduce_sets/4`.
    * 4.2 - the possible upfloaters, numbered by descending score and then
      ascending TPN: `upfloater_pool/1`.
    * 4.3 - the possible shifters. White seekers sorted by ascending ARO
      then TPN, Black seekers by TPN, and the sequence numbers handed out
      from the middle of the list outwards: `shifter_pool/1`,
      `middle_out/1`.
    * 4.4 - transpositions of G2: the permutations of the G2 players taken
      in lexicographic order of their TPNs: `transpositions/1`.

  Kept apart from the bracket procedure so the worked examples in the text
  (4.3.3's seven players, 4.4.2's three) pin it on their own.

  A pool here is always a list already in sequence-number order: element 0
  holds #1. A set is a list of pool members in that same order, so two sets
  compare by 4.1.3 exactly as Elixir compares the lists of their sequence
  numbers.
  """

  @doc """
  4.3.3: reorders a sorted list so element `i` is the player receiving
  sequence number `i + 1`. Each number goes to the player in the middle of
  what is left, or - two players being in the middle - to the one higher in
  the list.

      iex> Ainalrami.Dubov.Order.middle_out(~w(A B C D E F G))
      ~w(D C E B F A G)
  """
  def middle_out([]), do: []

  def middle_out(list) do
    n = length(list)
    at = if rem(n, 2) == 1, do: div(n, 2), else: div(n, 2) - 1
    {picked, rest} = List.pop_at(list, at)
    [picked | middle_out(rest)]
  end

  @doc """
  4.2: the possible upfloaters in sequence-number order - descending score,
  then ascending TPN. `players` carry `:score` and `:rank`.
  """
  def upfloater_pool(players), do: Enum.sort_by(players, &{-&1.score, &1.rank})

  @doc """
  4.3.1-4.3.3: possible shifters in sequence-number order. A White seeker
  is sorted by ascending ARO, then TPN; a Black seeker by TPN; then the
  numbers run from the middle outwards. `players` carry `:colour`
  (`:white` or `:black`, the preference), `:aro` and `:rank`.

  A pool is one subgroup's own players, and those all seek one colour, so
  the two sort keys never meet in one list.
  """
  def shifter_pool(players) do
    players
    |> Enum.sort_by(fn p -> if p.colour == :white, do: {p.aro, p.rank}, else: {0, p.rank} end)
    |> middle_out()
  end

  @doc """
  4.1.3: every set of `k` members of `pool` (already in sequence-number
  order), in the article's order. Eager; for a small pool or a test. The
  bracket walks the same order lazily with `reduce_sets/4`.
  """
  def sets(pool, k) do
    pool
    |> reduce_sets(k, [], fn set, acc -> {:cont, [set | acc]} end)
    |> Enum.reverse()
  end

  @doc """
  Walks the sets of `sets/2` in order without building them all:
  `fun.(set, acc)` returns `{:cont, acc}` or `{:halt, acc}`. Returns the
  final accumulator.
  """
  def reduce_sets(pool, k, acc, fun) do
    {_, acc} = walk(pool, length(pool), k, [], acc, fun)
    acc
  end

  defp walk(_pool, _n, 0, chosen, acc, fun) do
    case fun.(Enum.reverse(chosen), acc) do
      {:cont, acc} -> {:cont, acc}
      {:halt, acc} -> {:halt, acc}
    end
  end

  defp walk(_pool, n, k, _chosen, acc, _fun) when n < k, do: {:cont, acc}

  defp walk([x | rest], n, k, chosen, acc, fun) do
    case walk(rest, n - 1, k - 1, [x | chosen], acc, fun) do
      {:halt, acc} -> {:halt, acc}
      {:cont, acc} -> walk(rest, n - 1, k, chosen, acc, fun)
    end
  end

  @doc """
  4.4.2: the transpositions of `players`, which must already be in
  ascending TPN order - every permutation, lexicographically. Eager; the
  bracket never enumerates them (it builds the first legal one directly),
  this is the text's order for tests.

      iex> Ainalrami.Dubov.Order.transpositions(~w(A B C))
      [~w(A B C), ~w(A C B), ~w(B A C), ~w(B C A), ~w(C A B), ~w(C B A)]
  """
  def transpositions([]), do: [[]]

  def transpositions(players) do
    for x <- players, rest <- transpositions(List.delete(players, x)), do: [x | rest]
  end
end

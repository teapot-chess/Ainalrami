defmodule Ainalrami.Matching do
  @moduledoc """
  Maximum-weight matching over a bracket, allowing some players to go
  unmatched (floaters) - via memoized bitmask dynamic programming over
  the *whole* bracket, not restricted to any bipartite split.

  An earlier version restricted pairing to a strict "better half (S1) vs
  worse half (S2)" bipartite split, on the theory that this is the real
  FIDE structure (it's what round 1 empirically does).
  A real `javafo.jar` round-2 comparison run at scale (2000 random
  histories) proved that wrong: only 10.7% matched, including a
  regression on a case that matched exactly before the bipartite
  restriction was introduced. The rules say why: C.04.3 never forbids a
  pair for crossing a bracket or the S1/S2 split - bracket membership is
  a quality criterion (C6-C8), a weighted preference, not a hard
  exclusion. The genuinely correct
  shape is general (non-bipartite) matching with a strong preference for
  the natural structure, not a hard restriction to it.

  General maximum-weight matching (Edmonds' Blossom algorithm) is the
  textbook polynomial-time answer; this project uses a memoized subset-DP
  instead, for the same implementation-correctness-confidence reason the
  bipartite version was chosen over Blossom originally: O(2^n) states
  where n is the WHOLE bracket size (not half, unlike the bipartite
  version) is worse in the worst case, but real tournament brackets after
  round 1 split into multiple score groups (not one giant tied bracket),
  keeping n small in practice - see `max_weight_matching/3`'s doc for the
  actual complexity trade-off and where this could still be too slow.
  """

  import Bitwise

  @doc """
  `players` is the bracket (a list, any order). `pair_weight_fun.(a, b)`
  returns an integer weight for pairing `a` with `b`, or `nil` if they can
  never be paired (an absolute-criterion violation, e.g. a rematch).
  `float_weight_fun.(player)` returns the (typically deeply negative)
  weight of leaving `player` unmatched instead - see
  the note below for how a caller makes floating
  always cost less than any legal pairing.

  **`Ainalrami.Pairing` no longer calls this module.** It pairs through
  `Ainalrami.WeightedMatching.solve/2`; this subset-DP survives as the
  brute-force oracle `weighted_matching_test.exs` checks that solver
  against, which is the only thing that still uses it.

  Returns `{pairs, floaters}` for the maximum-total-weight matching:
  `pairs` is `[{a, b}, ...]`, `floaters` is the unmatched players.

  O(2^n * n) time/space, n = bracket size - exponential in the WHOLE
  bracket (unlike a bipartite formulation's O(k * 2^k) in half of it),
  because pairing is no longer restricted to a bipartite split at all.
  Fine for realistic tournament brackets (a score group rarely exceeds a
  few dozen players even in a large field, since round 1 already spread
  the roster across multiple scores); a bracket approaching the whole
  field (everyone still tied) would be genuinely slow - not yet capped or
  guarded against here.
  """
  def max_weight_matching(players, pair_weight_fun, float_weight_fun) do
    {_weight, pairs, floaters} =
      players
      |> max_weight_matchings(pair_weight_fun, float_weight_fun)
      |> Enum.flat_map(fn {_count, candidates} -> candidates end)
      |> Enum.max_by(fn {weight, _pairs, _floaters} -> weight end)

    {pairs, floaters}
  end

  # How many alternative matchings to carry per floater count. One is
  # enough to find the optimum, but not enough to recover from a bracket
  # whose optimum strands the rest of the round: what the cascade needs
  # to vary is WHICH players float, and two arrangements with the same
  # float count can float completely different people.
  #
  # Traced on seed 73, round 4. The 1.0 bracket's best two-pair matching
  # floats player 12, who has already played the only player below them,
  # so the round cannot finish. javafo takes a different two-pair matching
  # that floats player 10 instead. With one candidate per count, the
  # cascade could only fall back to a strictly worse ONE-pair matching,
  # and did.
  # One per floater count, which is exactly what `max_weight_matchings/3`'s
  # doc promises. This was 6 -- several candidates AT the same count -- for
  # the per-bracket cascade's alternative search, which is deleted. Nothing
  # has read a second candidate since: `max_weight_matching/3` takes the
  # maximum and is this module's only caller, and the module itself is now
  # the brute-force oracle for `WeightedMatching`. Keeping 6 multiplied the
  # DP's retained state sixfold to produce alternatives nobody looked at.
  @candidates_per_count 1

  # Above this bracket size the DP is already expensive enough that
  # multiplying its state by @candidates_per_count is not worth it; large
  # brackets are also the least likely to strand, having far more ways to
  # pair.
  @max_bracket_for_alternatives 16

  @doc """
  The best matching for EACH possible number of floaters, as
  `%{float_count => {weight, pairs, floaters}}`.

  Maximising a single bracket in isolation is not the same as maximising
  the round. A bracket that pairs as many of its own players as possible
  can strand a later one - two players left holding nothing but a rematch
  with each other - and the cascade then has no way to produce a legal
  round at all. Traced on a real 10-player case (seed 14, round 5): this
  engine emitted TWO pairing-allocated byes in an even field, which is not
  a legal pairing under any reading, while javafo floated an extra pair of
  players down so the last bracket could complete.

  Recovering from that needs alternatives, not just the optimum, so the
  caller can trade a worse bracket for a round that finishes. Same
  memoised subset DP as before, keeping the best weight per floater count
  instead of the single best overall.
  """
  def max_weight_matchings(players, pair_weight_fun, float_weight_fun) do
    n = length(players)
    arr = List.to_tuple(players)
    full_mask = (1 <<< n) - 1
    memo_key = make_ref()
    keep = if n > @max_bracket_for_alternatives, do: 1, else: @candidates_per_count
    Process.put(memo_key, %{})

    try do
      solve(full_mask, arr, n, pair_weight_fun, float_weight_fun, memo_key, keep)
    after
      Process.delete(memo_key)
    end
  end

  defp solve(0, _arr, _n, _pair_weight_fun, _float_weight_fun, _memo_key, _keep),
    do: %{0 => [{0, [], []}]}

  defp solve(mask, arr, n, pair_weight_fun, float_weight_fun, memo_key, keep) do
    cache = Process.get(memo_key)

    case Map.fetch(cache, mask) do
      {:ok, result} ->
        result

      :error ->
        result = compute_solve(mask, arr, n, pair_weight_fun, float_weight_fun, memo_key, keep)
        Process.put(memo_key, Map.put(Process.get(memo_key), mask, result))
        result
    end
  end

  defp compute_solve(mask, arr, n, pair_weight_fun, float_weight_fun, memo_key, keep) do
    i = lowest_set_bit_index(mask, 0)
    p = elem(arr, i)
    rest_mask = mask &&& bnot(1 <<< i)
    float_weight = float_weight_fun.(p)

    float_options =
      rest_mask
      |> solve(arr, n, pair_weight_fun, float_weight_fun, memo_key, keep)
      |> Enum.reduce(%{}, fn {count, candidates}, acc ->
        Enum.reduce(candidates, acc, fn {weight, pairs, floaters}, inner ->
          put_candidate(inner, count + 1, {weight + float_weight, pairs, [p | floaters]}, keep)
        end)
      end)

    Enum.reduce(0..(n - 1), float_options, fn j, acc ->
      if bit_set?(rest_mask, j) do
        q = elem(arr, j)

        case pair_weight_fun.(p, q) do
          nil ->
            acc

          weight ->
            rest_mask
            |> bandnot(j)
            |> solve(arr, n, pair_weight_fun, float_weight_fun, memo_key, keep)
            |> Enum.reduce(acc, fn {count, candidates}, inner ->
              Enum.reduce(candidates, inner, fn {rest_weight, pairs, floaters}, innermost ->
                put_candidate(
                  innermost,
                  count,
                  {weight + rest_weight, [{p, q} | pairs], floaters},
                  keep
                )
              end)
            end)
        end
      else
        acc
      end
    end)
  end

  defp bandnot(mask, j), do: mask &&& bnot(1 <<< j)

  # Keep the `keep` best candidates for this floater count, best first.
  defp put_candidate(acc, count, {weight, _, _} = candidate, keep) do
    existing = Map.get(acc, count, [])

    if length(existing) >= keep and weight <= elem(List.last(existing), 0) do
      acc
    else
      # Appended, NOT prepended. `Enum.sort_by/2` is stable, so a
      # prepended candidate would overtake an equal-weight incumbent and
      # silently invert the tie-break the single-candidate version had -
      # which is exactly what happened: ties are everywhere in this weight
      # scheme, and flipping them cost round 2 forty points while leaving
      # the reported weights identical.
      merged =
        (existing ++ [candidate])
        |> Enum.sort_by(fn {w, _, _} -> -w end)
        |> Enum.take(keep)

      Map.put(acc, count, merged)
    end
  end

  defp lowest_set_bit_index(mask, i) do
    if bit_set?(mask, i), do: i, else: lowest_set_bit_index(mask, i + 1)
  end

  defp bit_set?(mask, i), do: (mask >>> i &&& 1) == 1
end

defmodule Ainalrami.WeightedMatchingOpsTest do
  @moduledoc """
  The matcher's exposed operations driven in random short sequences, each
  step held to an INDEPENDENT exact solve (`Ainalrami.Matching`'s subset DP)
  and to the invariants the operation claims to preserve.

  `tools/matching_lockstep.exs` holds every call to the previous release,
  which proves nothing changed and nothing more: a defect both versions
  share passes it. This is the other half - after `solve/1`,
  `shift_and_set/3`, `finalize_pair/3`, `scale/2` and `install/3` the state
  must be dual feasible on EVERY edge (blossom duals included), tight on
  every matched edge and inside every blossom with a positive dual, and
  read as optimal by `dual_context/1`; the weight a solve returns must be
  the DP's; and where `Ainalrami.Pairing` relies on the matcher keeping
  the mates it had (a successful shift, a finalised pair, a scaled state),
  the next solve must return exactly those mates. Ties are otherwise free
  to land on a different optimum of the same weight, so mates are not
  compared to the DP's.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{MatchCertificate, WeightedMatching}

  @sessions 1000
  @steps 14

  test "random operation sequences keep every claimed invariant and reach the exact optimum" do
    counts =
      Enum.reduce(1..@sessions, %{}, fn seed, counts ->
        {_state, _current, session_counts} = session(seed)
        Map.merge(counts, session_counts, fn _k, a, b -> a + b end)
      end)

    # The run has to have exercised the operations it claims to test, and
    # both answers of the ones that can refuse.
    for key <- [
          :solve,
          :set_weight,
          :shift_ok,
          :shift_error,
          :finalize_ok,
          :scale,
          :install
        ] do
      assert Map.get(counts, key, 0) > 0, "the sessions never reached #{key}: #{inspect(counts)}"
    end
  end

  test "the same session is the same, call for call" do
    for seed <- 1..40 do
      {a, ca, _} = session(seed)
      {b, cb, _} = session(seed)
      assert ca == cb
      assert observable(a) == observable(b), "seed #{seed}: two runs of one session differ"
    end
  end

  # ---------------------------------------------------------------- session

  defp session(seed) do
    :rand.seed(:exsss, {seed, 1013, 7919})
    n = Enum.random(2..10)
    g = Enum.random([1, 1, 2, 3, 6])
    top = 20

    current =
      for a <- 0..(n - 1)//1, b <- 0..(n - 1)//1, a < b, :rand.uniform() < 0.5, into: %{} do
        {{a, b}, g * Enum.random(1..top)}
      end

    edges = for {{a, b}, w} <- current, do: {a, b, w}

    # The engine builds persistent matchers both ways: with the gcd and the
    # ceiling stated (the round matcher, `gcd: 1`), and with both left to
    # `new/3` (one-shot and local solves). A stated gcd above 1 has to read
    # back on the caller's scale exactly as a derived one does.
    opts =
      Enum.random([
        [],
        [gcd: 1, max_weight: g * top],
        [gcd: g, max_weight: g * top]
      ])

    state = WeightedMatching.new(n, edges, opts)
    assert_reads!(state, current, n, seed)

    {state, current, counts} =
      Enum.reduce(1..@steps, {state, current, %{}}, fn step, {state, current, counts} ->
        op = Enum.random([:solve, :set_weight, :shift, :shift, :finalize, :scale, :install])
        where = "seed #{seed} step #{step} #{op}"
        {state, current, tag} = step(op, state, current, n, where)
        {state, current, Map.update(counts, tag, 1, &(&1 + 1))}
      end)

    {state, _} = solved!(state, current, n, "seed #{seed} final")
    {state, current, counts}
  end

  defp step(:solve, state, current, n, where) do
    {state, _} = solved!(state, current, n, where)
    {state, current, :solve}
  end

  defp step(:set_weight, state, current, n, where) do
    {u, v} = two_vertices(n)
    w = on_scale(state, Enum.random(0..ceiling(state)))
    state = WeightedMatching.set_weight(state, u, v, w)
    current = put_current(current, u, v, w)

    # A prepared state is not optimal, but it is still dual feasible:
    # `prepare_vertex/2` puts the modified end back at the ceiling.
    feasible!(state, where)
    assert_reads!(state, current, n, where)
    {state, current, :set_weight}
  end

  defp step(:shift, state, current, n, where) do
    {state, _} = solved!(state, current, n, where <> " (before)")
    mates = mates(state, n)

    case Enum.filter(mates, fn {u, v} -> u < v end) do
      [] ->
        {state, current, :shift_none}

      pairs ->
        # Shaped like the engine's: one end of a matched pair moves by what
        # its matched edge changed, so that edge stays tight - plus, half
        # the time, other edges at that end rewritten too. Whether the rest
        # stays feasible is the matcher's question to answer.
        {u, v} = Enum.random(pairs)
        k = Enum.random(-2..2)
        w = Map.fetch!(current, {u, v}) + k * state.gcd
        w = if w <= 0 or w > ceiling(state), do: Map.fetch!(current, {u, v}), else: w
        shift = 2 * div(w - Map.fetch!(current, {u, v}), state.gcd)

        extra =
          if :rand.uniform() < 0.5 do
            for x <- Enum.take_random(0..(n - 1)//1, 2), x != u, x != v do
              {min(u, x), max(u, x), on_scale(state, Enum.random(0..ceiling(state)))}
            end
          else
            []
          end

        listed = [{min(u, v), max(u, v), w} | extra]

        case WeightedMatching.shift_and_set(state, %{u => shift}, listed) do
          {:ok, shifted} ->
            current =
              Enum.reduce(listed, current, fn {a, b, w}, acc -> put_current(acc, a, b, w) end)

            optimal!(shifted, where)
            assert_reads!(shifted, current, n, where)

            # Nothing is unmatched by a shift, and the solve after it finds
            # the matching already optimal: `Ainalrami.Pairing`'s stage 4
            # and stage 8 read the partner off the shifted state without
            # solving.
            {resolved, _} = solved!(shifted, current, n, where <> " (after)")
            assert mates(resolved, n) == mates, "#{where}: the solve after a shift moved a mate"
            {resolved, current, :shift_ok}

          :error ->
            {state, current, :shift_error}
        end
    end
  end

  defp step(:finalize, state, current, n, where) do
    {state, _} = solved!(state, current, n, where <> " (before)")
    mates = mates(state, n)

    case Enum.filter(mates, fn {u, v} -> u < v end) do
      [] ->
        {state, current, :finalize_none}

      pairs ->
        {u, v} = Enum.random(pairs)

        case WeightedMatching.finalize_pair(state, u, v) do
          {:ok, final} ->
            current =
              current
              |> Enum.reject(fn {{a, b}, _} ->
                {a, b} != {u, v} and (a in [u, v] or b in [u, v])
              end)
              |> Map.new()

            optimal!(final, where)
            assert_reads!(final, current, n, where)
            {resolved, _} = solved!(final, current, n, where <> " (after)")
            assert mates(resolved, n) == mates, "#{where}: the solve after finalize moved a mate"
            {resolved, current, :finalize_ok}

          :error ->
            {state, current, :finalize_error}
        end
    end
  end

  defp step(:scale, state, current, n, where) do
    {state, _} = solved!(state, current, n, where <> " (before)")
    mates = mates(state, n)
    k = Enum.random(1..3)
    scaled = WeightedMatching.scale(state, k)
    current = Map.new(current, fn {e, w} -> {e, k * w} end)

    optimal!(scaled, where)
    assert_reads!(scaled, current, n, where)
    {resolved, _} = solved!(scaled, current, n, where <> " (after)")
    assert mates(resolved, n) == mates, "#{where}: the solve after scale moved a mate"
    {resolved, current, :scale}
  end

  defp step(:install, state, current, n, where) do
    {state, _} = solved!(state, current, n, where <> " (before)")
    mate = state.mate
    {hint, family} = WeightedMatching.certificate_hint(state)

    # The certificate the matcher's own hint leads to, with its blossoms as
    # the fixed family: the far-field certificate `Ainalrami.Pairing` builds.
    # The search may give up (`{:error, :cycle}` is a tie it cannot express,
    # and the engine then takes the reference path); what it may never do is
    # certify a matching that is not maximum, and `solved!/4` has already
    # held this one to the DP.
    case MatchCertificate.certify(state.weight, mate, fn _ -> false end, hint,
           strict: false,
           family: family
         ) do
      {:ok, cert} -> assert is_map(cert.dual)
      {:error, reason} -> assert is_atom(reason) or is_tuple(reason)
    end

    # And the blossom-free one `install/3` takes, as the engine searches it.
    case MatchCertificate.certify(
           state.weight,
           mate,
           fn _ -> false end,
           WeightedMatching.vertex_duals(state),
           strict: false
         ) do
      {:ok, cert} ->
        installed = WeightedMatching.install(state, mate, cert.dual)
        optimal!(installed, where)
        assert mates(installed, n) == mates(state, n)
        {resolved, _} = solved!(installed, current, n, where <> " (after)")
        {resolved, current, :install}

      {:error, _} ->
        {state, current, :install_refused}
    end
  end

  # -------------------------------------------------------------- checks

  # `solve/1`, held to the DP: a valid matching on the current edges, of
  # the DP's weight, from a state that satisfies every invariant - and
  # whose duals say every candidate partner the DP's optimum uses is one.
  defp solved!(state, current, n, where) do
    {state, matching} = WeightedMatching.solve(state)

    assert valid_matching?(matching, current), "#{where}: invalid matching #{inspect(matching)}"

    {expected, oracle_pairs} = oracle(n, current)
    got = total(matching, current)
    assert got == expected, "#{where}: weight #{got}, exact optimum #{expected}"

    optimal!(state, where)
    partners!(state, oracle_pairs, n, where)
    {state, matching}
  end

  # `possible_partners/3` is a superset of every optimum's partners.
  defp partners!(state, oracle_pairs, n, where) do
    ctx = WeightedMatching.dual_context(state)
    refute ctx == :invalid, "#{where}: dual_context/1 refused a solved state"

    oracle_mate =
      Enum.reduce(oracle_pairs, %{}, fn {a, b}, m -> m |> Map.put(a, b) |> Map.put(b, a) end)

    for v <- 0..(n - 1)//1, Map.get(state.weight, v, %{}) != %{} do
      {tight, can_expose?} = WeightedMatching.possible_partners(state, ctx, v)

      for {label, partner} <- [
            {:held, Map.get(state.mate, v)},
            {:oracle, Map.get(oracle_mate, v)}
          ] do
        case partner do
          nil ->
            assert can_expose?, "#{where}: #{label} leaves #{v} exposed, duals say it cannot be"

          u ->
            assert u in tight, "#{where}: #{label} pairs #{v}-#{u}, not among #{inspect(tight)}"
        end
      end
    end
  end

  # Dual feasible on every edge, every vertex and blossom dual non-negative.
  defp feasible!(state, where) do
    chains = chains(state)

    for {u, row} <- state.weight, {v, w2} <- row, u < v do
      assert reduced_cost(state, chains, u, v, w2) >= 0,
             "#{where}: edge #{u}-#{v} infeasible (reduced cost " <>
               "#{reduced_cost(state, chains, u, v, w2)})"
    end

    for v <- 0..(state.n - 1)//1 do
      assert Map.fetch!(state.dual, v) >= 0, "#{where}: vertex #{v} has a negative dual"
    end

    for {b, _} <- state.children do
      assert Map.get(state.dual, b, 0) >= 0, "#{where}: blossom #{b} has a negative dual"
    end
  end

  # Feasible, and complementary slackness: every matched edge tight, every
  # blossom with a positive dual holding (size - 1) / 2 matched edges, and
  # the exposed vertices' duals in the shape `dual_context/1` accepts.
  defp optimal!(state, where) do
    feasible!(state, where)
    chains = chains(state)

    for {u, v} <- state.mate, u < v do
      w2 = state.weight |> Map.get(u, %{}) |> Map.get(v, 0)
      assert w2 > 0, "#{where}: matched pair #{u}-#{v} has no edge"
      assert reduced_cost(state, chains, u, v, w2) == 0, "#{where}: matched #{u}-#{v} not tight"
    end

    for {b, _} <- state.children, Map.get(state.dual, b, 0) > 0 do
      vs = blossom_vertices(state, b)
      inside = Enum.count(vs, fn v -> Map.get(state.mate, v) in vs end)
      assert inside == length(vs) - 1, "#{where}: blossom #{b} (dual > 0) is not full"
    end

    refute WeightedMatching.dual_context(state) == :invalid,
           "#{where}: exposed duals not in an optimal shape"
  end

  # `edge_weight/3` and `neighbours/2` read every edge back on the caller's
  # scale, whatever gcd the state reduced by.
  defp assert_reads!(state, current, n, where) do
    for u <- 0..(n - 1)//1, v <- 0..(n - 1)//1, u < v do
      assert WeightedMatching.edge_weight(state, u, v) == Map.get(current, {u, v}, 0),
             "#{where}: edge_weight(#{u}, #{v})"
    end

    for u <- 0..(n - 1)//1 do
      expected =
        for {{a, b}, w} <- current, u in [a, b], do: {if(a == u, do: b, else: a), w}

      assert Enum.sort(WeightedMatching.neighbours(state, u)) == Enum.sort(expected),
             "#{where}: neighbours(#{u})"
    end
  end

  defp reduced_cost(state, chains, u, v, w2) do
    Map.fetch!(state.dual, u) + Map.fetch!(state.dual, v) +
      common_z(state, Map.get(chains, u, []), Map.get(chains, v, [])) - w2
  end

  defp common_z(state, [b | cu], [b | cv]),
    do: Map.get(state.dual, b, 0) + common_z(state, cu, cv)

  defp common_z(_state, _, _), do: 0

  # Each vertex's enclosing blossoms, outermost first.
  defp chains(state) do
    Map.new(0..(state.n - 1)//1, fn v -> {v, chain(state, v, [])} end)
  end

  defp chain(state, v, acc) do
    case Map.get(state.parent_of, v) do
      nil -> acc
      b -> chain(state, b, [b | acc])
    end
  end

  defp blossom_vertices(state, b) do
    case Map.get(state.children, b) do
      nil -> [b]
      children -> Enum.flat_map(children, &blossom_vertices(state, &1))
    end
  end

  defp oracle(n, current) do
    weight = fn a, b ->
      case Map.get(current, {min(a, b), max(a, b)}) do
        w when is_integer(w) and w > 0 -> w
        _ -> nil
      end
    end

    {pairs, _} =
      Ainalrami.Matching.max_weight_matching(Enum.to_list(0..(n - 1)//1), weight, fn _ -> 0 end)

    {Enum.reduce(pairs, 0, fn {a, b}, acc -> acc + weight.(a, b) end), pairs}
  end

  # ------------------------------------------------------------- helpers

  defp mates(state, n) do
    for v <- 0..(n - 1)//1,
        u = WeightedMatching.mate_of(state, v),
        u != nil,
        into: %{},
        do: {v, u}
  end

  defp observable(state),
    do:
      Map.take(state, [
        :n,
        :max_w,
        :gcd,
        :weight,
        :dual,
        :mate,
        :in_blossom,
        :children,
        :parent_of
      ])

  # The largest weight a later write may carry, on the caller's scale.
  defp ceiling(state), do: div(state.max_w * state.gcd, 2)

  defp on_scale(state, w), do: div(w, state.gcd) * state.gcd

  defp two_vertices(n) do
    [u, v] = Enum.take_random(0..(n - 1)//1, 2)
    {u, v}
  end

  defp put_current(current, u, v, w) do
    key = {min(u, v), max(u, v)}
    if w > 0, do: Map.put(current, key, w), else: Map.delete(current, key)
  end

  defp valid_matching?(matching, current) do
    Enum.all?(matching, fn {a, b} ->
      Map.get(matching, b) == a and Map.has_key?(current, {min(a, b), max(a, b)})
    end)
  end

  defp total(matching, current) do
    matching
    |> Enum.filter(fn {a, b} -> a < b end)
    |> Enum.reduce(0, fn {a, b}, acc -> acc + Map.fetch!(current, {a, b}) end)
  end
end

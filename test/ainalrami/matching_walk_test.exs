defmodule Ainalrami.MatchingWalkTest do
  @moduledoc """
  The persistent walk of `Ainalrami.MatchingWalk` and the two speed paths
  built on it (Burstein's `first_in_order`, Lim's pairs walk and floater
  split), each held to an independent answer: a brute-force maximum-weight
  perfect matching on small random graphs, and the old walks themselves in
  `:check` mode on whole tournaments.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{Burstein, Lim, MatchingWalk}
  alias Ainalrami.Test.{BursteinEvents, LimEvents}

  describe "the switch" do
    test "with_mode/2 sets the walk for the call and restores it after" do
      outer = MatchingWalk.mode()
      assert MatchingWalk.with_mode(:check, &MatchingWalk.mode/0) == :check

      assert MatchingWalk.with_mode(:old, fn ->
               MatchingWalk.with_mode(:new, &MatchingWalk.mode/0)
             end) == :new

      assert MatchingWalk.mode() == outer
    end

    test "same!/3 passes equal answers and raises on different ones" do
      assert MatchingWalk.same!("x", [1], [1]) == [1]

      assert_raise MatchingWalk.Mismatch, ~r/x: the old and the new walk differ/, fn ->
        MatchingWalk.same!("x", [1], [2])
      end
    end
  end

  describe "the primitives, against brute force" do
    test "a trial on the persistent matcher reaches the optimum exactly when the restricted graph does, and pruning never skips a feasible choice" do
      for seed <- 1..300 do
        :rand.seed(:exsss, {seed, 17, 29})
        n = Enum.random([4, 6, 8, 10])

        edges =
          for i <- 0..(n - 2),
              j <- (i + 1)..(n - 1),
              :rand.uniform(100) <= 70,
              do: {i, j, 50 + Enum.random(1..6)}

        best = brute(n, edges)

        if best do
          {state, weight, true} = MatchingWalk.start(n, edges)
          assert weight == best

          for v <- 0..(n - 1), {u, _} <- Ainalrami.WeightedMatching.neighbours(state, v) do
            forced = brute(n, only(edges, v, u))
            reaches? = forced == best

            # Warm trial = cold truth.
            warm = MatchingWalk.settle(MatchingWalk.restrict_pair(state, v, u), n, best)
            assert match?({:ok, _}, warm) == reaches?, "seed #{seed}: {#{v}, #{u}}"

            # Pruning is sound: a choice that reaches the optimum is tight.
            tight = MatchingWalk.tight(state, v)
            if reaches? and tight, do: assert(MapSet.member?(tight, u))
          end
        end
      end
    end

    test "lock_pair/5 keeps the optimum and leaves the pair as the only edge of both" do
      for seed <- 1..200 do
        :rand.seed(:exsss, {seed, 5, 7})
        n = Enum.random([4, 6, 8, 10])

        edges =
          for i <- 0..(n - 2),
              j <- (i + 1)..(n - 1),
              :rand.uniform(100) <= 80,
              do: {i, j, 30 + Enum.random(1..9)}

        with best when best != nil <- brute(n, edges) do
          {state, ^best, true} = MatchingWalk.start(n, edges)
          v = 0
          u = MatchingWalk.mate_of(state, v)
          state = MatchingWalk.lock_pair(state, v, u, n, best)

          assert MatchingWalk.mate_of(state, v) == u
          assert Enum.map(Ainalrami.WeightedMatching.neighbours(state, v), &elem(&1, 0)) == [u]
          assert Enum.map(Ainalrami.WeightedMatching.neighbours(state, u), &elem(&1, 0)) == [v]
          assert {:ok, _} = MatchingWalk.settle(state, n, best)
        end
      end
    end
  end

  describe "whole rounds, old walk against new" do
    test "Burstein: every round of a thousand small events is identical" do
      rounds = check_events(&BursteinEvents.play/3, Burstein, 1..1000)
      assert rounds > 2000
    end

    test "Lim: every round of a thousand small events is identical" do
      rounds = check_events(&LimEvents.play/3, Lim, 1..1000)
      assert rounds > 4000
    end

    test "one scoregroup of 40 (all draws): the same pairing by either walk" do
      players =
        for r <- 1..40 do
          games =
            for k <- 1..4 do
              x = r - 1
              y = Bitwise.bxor(x, k)
              white? = x < y == (rem(k, 2) == 1)
              %{opponent_rank: y + 1, colour: if(white?, do: "w", else: "b"), result: "="}
            end

          %{rank: r, points: 2.0, games: games, fide_rating: 2500 - r}
        end

      for mod <- [Burstein, Lim] do
        old = MatchingWalk.with_mode(:old, fn -> mod.pair_round(players, expected_rounds: 9) end)
        new = MatchingWalk.with_mode(:new, fn -> mod.pair_round(players, expected_rounds: 9) end)
        assert {:ok, _} = old
        assert old == new
      end
    end
  end

  defp check_events(play, mod, seeds) do
    MatchingWalk.with_mode(:check, fn ->
      Enum.reduce(seeds, 0, fn seed, total ->
        total +
          play.(seed, 4..14, fn players, opts, _round ->
            case mod.pair_next_round(players, opts) do
              {:ok, pairs} -> pairs
              {:error, _} -> :stop
            end
          end)
      end)
    end)
  end

  # Edges at v or u other than {v, u} removed.
  defp only(edges, v, u) do
    Enum.reject(edges, fn {i, j, _} ->
      (i in [v, u] or j in [v, u]) and {min(i, j), max(i, j)} != {min(v, u), max(v, u)}
    end)
  end

  # The maximum weight of a perfect matching, or nil.
  defp brute(n, edges) do
    w = Map.new(edges, fn {i, j, x} -> {{i, j}, x} end)
    go(Enum.to_list(0..(n - 1)), w)
  end

  defp go([], _w), do: 0

  defp go([a | rest], w) do
    rest
    |> Enum.flat_map(fn b ->
      with x when x != nil <- Map.get(w, {a, b}),
           sub when sub != nil <- go(List.delete(rest, b), w) do
        [x + sub]
      else
        _ -> []
      end
    end)
    |> Enum.max(fn -> nil end)
  end
end

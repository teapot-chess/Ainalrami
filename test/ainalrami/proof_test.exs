defmodule Ainalrami.ProofTest do
  @moduledoc """
  Pairing proofs (`Ainalrami.Proof`, `docs/pairing-proofs.md`): the option
  leaves the pairing alone, every proof the engine writes passes the
  independent verifier (`tools/verify-proof/verify.exs`, loaded as a
  script - it shares no code with the engine) with every published pair
  read off a proven matching and nothing left uncovered, and the verifier
  fails a proof with one weight, dual, matched edge, witness, read or
  published pair changed.
  """

  use ExUnit.Case, async: false

  alias Ainalrami.Pairing
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  setup_all do
    Process.put(:verify_proof_as_library, true)
    Process.put(:tamper_proof_as_library, true)
    root = Path.expand("../..", __DIR__)
    Code.require_file(Path.join([root, "tools", "verify-proof", "verify.exs"]))
    Code.require_file(Path.join([root, "tools", "verify-proof", "tamper.exs"]))
    :ok
  end

  # Every round of a few small tournaments, with the option off and on.
  defp rounds(seeds, range) do
    Enum.flat_map(seeds, fn seed ->
      {rounds, _count, forbidden, roster} = Fuzz.begin!(seed, 7, range)

      {texts, _} =
        Enum.reduce_while(1..rounds, {[], roster}, fn _round, {acc, players} ->
          opts = [expected_rounds: rounds, forbidden_pairs: forbidden]

          off = pair(players, opts)
          on = pair(players, opts ++ [proof: &Process.put(:proof_text, &1)])
          text = Process.delete(:proof_text)

          case off do
            {:ok, pairs} ->
              next = Fuzz.apply_round(players, pairs, Fuzz.simulate_results(pairs))
              {:cont, {[{off, on, text} | acc], next}}

            _ ->
              {:halt, {[{off, on, text} | acc], players}}
          end
        end)

      Enum.reverse(texts)
    end)
  end

  defp pair(players, opts) do
    {:ok, Pairing.pair_next_round(players, opts)}
  rescue
    e in Pairing.NoValidPairingError -> {:refused, e.reason}
  end

  # The scripts' modules exist only once `setup_all` has loaded them, so
  # they are called by name at run time.
  defp verify(text), do: apply(VerifyProof, :verify_text, [text])
  defp tamper_failed?(text), do: apply(TamperProof, :failed?, [text])
  defp tampers(text), do: apply(TamperProof, :tampers, [text])

  defp records(text) do
    text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  # A round of hand-made records, as text.
  defp round_text(records, pairs \\ nil) do
    head = %{
      "type" => "round",
      "format" => "ainalrami-pairing-proof",
      "version" => 2,
      "round" => %{"players" => 0, "pairs" => pairs}
    }

    ([head | records] ++ [%{"type" => "end", "uncertified" => %{}}])
    |> Enum.map_join("\n", &JSON.encode!/1)
  end

  defp verdict(text) do
    [round] = verify(text)
    if round.verdict == :pass, do: :pass, else: {:fail, Enum.join(round.failures, "; ")}
  end

  @tag timeout: 300_000
  test "the option changes no pairing, and every proof verifies in full" do
    results = rounds(1..12, 6..60)
    assert length(results) > 40

    for {off, on, text} <- results do
      assert off == on
      assert is_binary(text)
      [round] = verify(text)
      assert round.verdict == :pass, Enum.join(round.failures, "; ")

      # Nothing left to trust that a record could have covered.
      assert round.uncertified == %{}

      # Every published pair of two players was read off a proven matching.
      case off do
        {:ok, pairs} ->
          boards = Enum.count(pairs, fn {_, b} -> b != nil end)
          assert round.pairs.published == boards
          assert round.pairs.read == boards

        _ ->
          :ok
      end
    end

    # Not vacuous: the rounds above really were proved record by record,
    # the completability questions with them.
    all = Enum.flat_map(results, fn {_, _, t} -> records(t) end)
    assert Enum.count(all, &(&1["type"] == "weighted")) > 200
    assert Enum.any?(all, &(&1["type"] == "cardinality"))
    assert Enum.any?(all, &(&1["type"] == "read"))
  end

  @tag timeout: 300_000
  test "one changed weight, dual, matched edge, witness, read or pair fails the verifier" do
    texts =
      rounds(1..6, 20..40)
      |> Enum.map(fn {_, _, t} -> t end)
      |> Enum.filter(&String.contains?(&1, ~s("edges":)))
      |> Enum.take(10)

    assert length(texts) >= 5

    for text <- texts do
      refute tamper_failed?(text)
      tampers = tampers(text)
      names = Enum.map(tampers, &elem(&1, 0))

      for name <- ~w(weight dual unmatch read published dropped),
          do: assert(name in names, "#{name} did not apply")

      for {name, tampered} <- tampers, name != "rematch" do
        assert tamper_failed?(tampered), "#{name} was not caught"
      end
    end
  end

  # The certified shortcuts' own certificates (`Ainalrami.MatchCertificate`)
  # are recorded too, as "window" claims, when a round is recorded on the
  # path it was paired on rather than the reference path. Not what the
  # option does, but the claims are the verifier's to check all the same.
  @tag timeout: 300_000
  test "the certified shortcuts' window certificates verify" do
    saved = System.get_env("AINALRAMI_CERT")
    System.put_env("AINALRAMI_CERT", "force")

    on_exit(fn ->
      if saved,
        do: System.put_env("AINALRAMI_CERT", saved),
        else: System.delete_env("AINALRAMI_CERT")
    end)

    texts =
      Enum.flat_map(1..15, fn seed ->
        {rounds, _count, forbidden, roster} = Fuzz.begin!(seed, 7, 40..120)

        {acc, _} =
          Enum.reduce(1..rounds, {[], roster}, fn _round, {acc, players} ->
            opts = [expected_rounds: rounds, forbidden_pairs: forbidden]

            {result, rec} =
              Ainalrami.Proof.capture(
                fn -> Pairing.pair_next_round(players, opts) end,
                :as_paired,
                %{"players" => length(players)}
              )

            acc = [Ainalrami.Proof.finish(rec) | acc]

            case result do
              {:ok, pairs} ->
                {acc, Fuzz.apply_round(players, pairs, Fuzz.simulate_results(pairs))}

              _ ->
                {acc, players}
            end
          end)

        acc
      end)

    assert Enum.any?(texts, &String.contains?(&1, ~s("kind":"window")))

    for text <- texts,
        do: assert(verdict(text) == :pass, inspect(verdict(text)))
  end

  test "the verifier refuses what is not a proof" do
    assert [%{verdict: :fail}] = verify("not json")
    assert [%{verdict: :fail}] = verify(~s({"type": "round", "format": "else", "version": 2}))

    # A round that never ends.
    assert [%{verdict: :fail}] =
             verify(round_text([]) |> String.split("\n") |> hd())

    # A graph naming a base that is not an earlier record.
    weighted = %{
      "type" => "weighted",
      "id" => 0,
      "kind" => "solve",
      "n" => 2,
      "graph" => %{"base" => 7, "set" => []},
      "matching" => [],
      "duals" => [],
      "sets" => []
    }

    assert {:fail, reason} = verdict(round_text([weighted]))
    assert reason =~ "base"
  end

  test "a hand-made certificate: a triangle needs its odd-set dual" do
    # Weights 2, 2, 2 on a triangle: one edge is optimal (weight 2, on the
    # doubled scale 4). Vertex duals alone would need 4 on the three
    # vertices (objective 6 > 4); the odd set {0, 1, 2} with z = 4 and every
    # vertex at 0 closes the gap.
    solve = %{
      "type" => "weighted",
      "id" => 0,
      "kind" => "solve",
      "n" => 3,
      "graph" => %{"edges" => [[0, 1, "4"], [0, 2, "4"], [1, 2, "4"]]},
      "matching" => [[0, 1]],
      "duals" => [],
      "sets" => [%{"vertices" => [0, 1, 2], "z" => "4"}]
    }

    assert :pass = verdict(round_text([solve]))

    # Without the set: no dual at all is not feasible.
    assert {:fail, reason} = verdict(round_text([%{solve | "sets" => []}]))
    assert reason =~ "violates"

    # An even set is not an odd-set constraint.
    even = %{solve | "sets" => [%{"vertices" => [0, 1], "z" => "4"}]}
    assert {:fail, reason} = verdict(round_text([even]))
    assert reason =~ "even"
  end

  test "a window certificate: a tight unmatched edge at a window vertex is refused" do
    # A 4-cycle 0-1-2-3-0 with every weight 2 (doubled 4): two perfect
    # matchings tie, so no window vertex has a forced partner.
    solve = %{
      "type" => "weighted",
      "id" => 0,
      "kind" => "window",
      "n" => 4,
      "graph" => %{"edges" => [[0, 1, "4"], [1, 2, "4"], [2, 3, "4"], [0, 3, "4"]]},
      "matching" => [[0, 1], [2, 3]],
      "duals" => [[0, "2"], [1, "2"], [2, "2"], [3, "2"]],
      "sets" => []
    }

    assert :pass = verdict(round_text([solve]))
    assert {:fail, reason} = verdict(round_text([Map.put(solve, "window", [0])]))
    assert reason =~ "window"
  end

  test "a published pair must be read off a proven matching, and ties are told apart" do
    # The 4-cycle again: the matching (0, 1) (2, 3) is optimal but so is
    # (1, 2) (3, 0), so its pairs are read, not forced. Players 10-13.
    cycle = %{
      "type" => "weighted",
      "id" => 0,
      "kind" => "solve",
      "n" => 4,
      "graph" => %{"edges" => [[0, 1, "4"], [1, 2, "4"], [2, 3, "4"], [0, 3, "4"]]},
      "matching" => [[0, 1], [2, 3]],
      "duals" => [[0, "2"], [1, "2"], [2, "2"], [3, "2"]],
      "sets" => []
    }

    read = %{"type" => "read", "solve" => 0, "pairs" => [[0, 1, 10, 11], [2, 3, 12, 13]]}
    text = round_text([cycle, read], [[10, 11], [13, 12]])
    assert [%{verdict: :pass, pairs: %{published: 2, read: 2, forced: 0}}] = verify(text)

    # A pair nobody read.
    assert {:fail, reason} = verdict(round_text([cycle, read], [[10, 12], [11, 13]]))
    assert reason =~ "not read"

    # A pair read and not published: the boards are not the pairs read.
    assert {:fail, reason} = verdict(round_text([cycle, read], [[10, 11], [12, nil], [13, nil]]))
    assert reason =~ "not published"

    # A player at two boards.
    assert {:fail, reason} = verdict(round_text([cycle, read], [[10, 11], [12, 13], [10, nil]]))
    assert reason =~ "two boards"

    # A read the matching does not hold.
    bad = %{read | "pairs" => [[1, 2, 10, 11]]}
    assert {:fail, reason} = verdict(round_text([cycle, bad], [[10, 11]]))
    assert reason =~ "not a pair"

    # A path 0-1-2-3 weighted 1, 3, 1 (doubled 2, 6, 2): (1, 2) is the only
    # optimum, and its duals say so - y = 3 at both ends, the rest slack.
    path = %{
      cycle
      | "graph" => %{"edges" => [[0, 1, "2"], [1, 2, "6"], [2, 3, "2"]]},
        "matching" => [[1, 2]],
        "duals" => [[1, "3"], [2, "3"]]
    }

    read = %{"type" => "read", "solve" => 0, "pairs" => [[1, 2, 11, 12]]}
    text = round_text([path, read], [[11, 12], [10, nil]])
    assert [%{verdict: :pass, pairs: %{published: 1, read: 1, forced: 1}}] = verify(text)
  end

  # Cardinality witnesses, by hand. Graphs on 0..n-1 as edge lists.
  defp card(claim, n, edges, fields) do
    Map.merge(
      %{
        "type" => "cardinality",
        "id" => 0,
        "claim" => claim,
        "n" => n,
        "graph" => %{"edges" => edges}
      },
      fields
    )
  end

  test "cardinality: a maximum matching and its Tutte-Berge barrier" do
    # A triangle: one pair, one vertex over, and the barrier is empty (the
    # triangle is one odd piece).
    tri = [[0, 1], [0, 2], [1, 2]]
    ok = card("maximum", 3, tri, %{"matching" => [[0, 1]], "barrier" => []})
    assert :pass = verdict(round_text([ok]))

    # The wrong barrier shows nothing.
    assert {:fail, _} = verdict(round_text([%{ok | "barrier" => [2]}]))

    # A star with three leaves: one pair is all there is, and the centre
    # is the barrier (three odd leaves, one centre: two left over).
    star = [[0, 1], [0, 2], [0, 3]]

    assert :pass =
             verdict(
               round_text([card("maximum", 4, star, %{"matching" => [[0, 1]], "barrier" => [0]})])
             )

    # A path 0-1-2-3 matched (1, 2) is not maximum, whatever the barrier.
    path = [[0, 1], [1, 2], [2, 3]]

    for barrier <- [[], [1], [2], [1, 2]] do
      assert {:fail, _} =
               verdict(
                 round_text([
                   card("maximum", 4, path, %{"matching" => [[1, 2]], "barrier" => barrier})
                 ])
               )
    end

    # "Not exposable": a perfect matching leaves no vertex over, not one.
    assert :pass =
             verdict(
               round_text([
                 card("not_exposable", 4, path, %{
                   "matching" => [[0, 1], [2, 3]],
                   "barrier" => []
                 })
               ])
             )

    assert {:fail, _} =
             verdict(
               round_text([
                 card("not_exposable", 3, tri, %{"matching" => [[0, 1]], "barrier" => []})
               ])
             )
  end

  test "cardinality: an augmenting path, and a barrier where there is none" do
    path = [[0, 1], [1, 2], [2, 3]]

    # From 0 against (1, 2): 0-1-2-3 augments.
    aug =
      card("augment", 4, path, %{"matching" => [[1, 2]], "root" => 0, "path" => [0, 1, 2, 3]})

    assert :pass = verdict(round_text([aug]))
    assert {:fail, _} = verdict(round_text([%{aug | "path" => [0, 1, 2]}]))

    # And so no barrier can say it does not.
    for barrier <- [[], [1], [2], [1, 2]] do
      blocked = Map.merge(aug, %{"claim" => "blocked", "barrier" => barrier})
      assert {:fail, _} = verdict(round_text([blocked]))
    end

    # From 0 on the path 0-1-2 matched (1, 2): nowhere to go. The barrier
    # {1} leaves {0} and {2}, two odd pieces for one vertex.
    short = [[0, 1], [1, 2]]

    blocked =
      card("blocked", 3, short, %{"matching" => [[1, 2]], "root" => 0, "barrier" => [1]})

    assert :pass = verdict(round_text([blocked]))

    # The empty barrier would do as well (three vertices, one odd piece,
    # one pair at most), but {0} shows nothing: {1, 2} is even.
    assert {:fail, _} = verdict(round_text([%{blocked | "barrier" => [0]}]))

    # A dead vertex is not there: with 3 dead, 0-1-2-3 cannot augment.
    dead =
      card("blocked", 4, path, %{
        "matching" => [[1, 2]],
        "root" => 0,
        "dead" => [3],
        "barrier" => [1]
      })

    assert :pass = verdict(round_text([dead]))
  end

  test "cardinality: the exposable set, with a path to each" do
    # The path 0-1-2 matched (0, 1): 2 is exposed, and flipping 2-1-0
    # exposes 0 instead; 1 is never exposed. Barrier {1}.
    short = [[0, 1], [1, 2]]

    exp =
      card("exposable", 3, short, %{
        "matching" => [[0, 1]],
        "root" => 2,
        "exposable" => [0, 2],
        "barrier" => [1],
        "parent" => [[1, 2]]
      })

    assert :pass = verdict(round_text([exp]))
    assert {:fail, _} = verdict(round_text([%{exp | "exposable" => [0, 1, 2]}]))
    assert {:fail, _} = verdict(round_text([%{exp | "exposable" => [2]}]))
    assert {:fail, _} = verdict(round_text([%{exp | "parent" => []}]))

    # A triangle: every vertex can be the one over.
    tri =
      card("exposable", 3, [[0, 1], [0, 2], [1, 2]], %{
        "matching" => [[1, 2]],
        "root" => 0,
        "exposable" => [0, 1, 2],
        "barrier" => [],
        "parent" => [[1, 0], [2, 0]]
      })

    assert :pass = verdict(round_text([tri]))
  end

  test "--proof writes one round per pairing, and the pairing file is unchanged" do
    dir = Path.join(System.tmp_dir!(), "ainalrami-proof-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    trf = Path.join(dir, "t.trf")

    assert 0 ==
             Ainalrami.CLI.run(["-g", trf, "--seed=11", "--players=24", "--rounds=4", "-q"])

    plain = Path.join(dir, "plain.txt")
    proved = Path.join(dir, "proved.txt")

    assert 0 == Ainalrami.CLI.run([trf, "-p", plain, "--rounds=7", "-q"])

    for proof <- [Path.join(dir, "proof.jsonl"), Path.join(dir, "proof.jsonl.gz")] do
      assert 0 ==
               Ainalrami.CLI.run([trf, "-p", proved, "--rounds=7", "-q", "--proof=" <> proof])

      assert File.read!(plain) == File.read!(proved)

      text =
        proof
        |> File.read!()
        |> then(&if(String.ends_with?(proof, ".gz"), do: :zlib.gunzip(&1), else: &1))

      assert [%{verdict: :pass}] = verify(text)
    end
  end
end

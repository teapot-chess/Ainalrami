defmodule Ainalrami.ProofTest do
  @moduledoc """
  Pairing proofs (`Ainalrami.Proof`, `docs/pairing-proofs.md`): the option
  leaves the pairing alone, every certificate the engine writes passes the
  independent verifier (`tools/verify-proof/verify.exs`, loaded as a
  script - it shares no code with the engine), and the verifier fails a
  certificate with one weight, one dual or one matched edge changed.
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

      {lines, _} =
        Enum.reduce_while(1..rounds, {[], roster}, fn _round, {acc, players} ->
          opts = [expected_rounds: rounds, forbidden_pairs: forbidden]
          {active, pending} = {players, []}

          off = pair(active, opts)
          on = pair(active, opts ++ [proof: &Process.put(:proof_line, &1)])
          line = Process.delete(:proof_line)

          case off do
            {:ok, pairs} ->
              next = Fuzz.apply_round(active, pairs, Fuzz.simulate_results(pairs))
              {:cont, {[{off, on, line} | acc], next ++ pending}}

            _ ->
              {:halt, {[{off, on, line} | acc], players}}
          end
        end)

      Enum.reverse(lines)
    end)
  end

  defp pair(players, opts) do
    {:ok, Pairing.pair_next_round(players, opts)}
  rescue
    e in Pairing.NoValidPairingError -> {:refused, e.reason}
  end

  # The scripts' modules exist only once `setup_all` has loaded them, so
  # they are called by name at run time.
  defp verify_line(line), do: apply(VerifyProof, :verify_line, [line])
  defp tamper_failed?(line), do: apply(TamperProof, :failed?, [line])
  defp tampers(line), do: apply(TamperProof, :tampers, [line])

  defp verdicts(line) do
    {:ok, r} = verify_line(line)
    Enum.map(r.solves, fn {_, _, v} -> v end)
  end

  @tag timeout: 300_000
  test "the option changes no pairing, and every certificate verifies" do
    results = rounds(1..12, 6..60)
    assert length(results) > 40

    for {off, on, line} <- results do
      assert off == on
      assert is_binary(line)
      doc = JSON.decode!(line)
      assert doc["format"] == "ainalrami-pairing-proof"
      assert doc["version"] == 1
      assert doc["round"]["agrees"] == true

      assert Enum.all?(verdicts(line), &(&1 == :pass)),
             "a certificate failed: #{inspect(verdicts(line))}"
    end

    # Not vacuous: the rounds above really were proved solve by solve.
    solves =
      results |> Enum.map(fn {_, _, l} -> length(JSON.decode!(l)["solves"]) end) |> Enum.sum()

    assert solves > 200
  end

  @tag timeout: 300_000
  test "one changed weight, dual or matched edge fails the verifier" do
    lines =
      rounds(1..6, 20..40)
      |> Enum.map(fn {_, _, l} -> l end)
      |> Enum.filter(fn l ->
        Enum.any?(
          JSON.decode!(l)["solves"],
          &(&1["matching"] != [] and Map.has_key?(&1["graph"], "edges"))
        )
      end)
      |> Enum.take(10)

    assert length(lines) >= 5

    for line <- lines do
      refute tamper_failed?(line)
      tampers = tampers(line)
      names = Enum.map(tampers, &elem(&1, 0))
      assert "weight" in names and "dual" in names and "unmatch" in names

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

    verdicts =
      Enum.flat_map(1..15, fn seed ->
        {rounds, _count, forbidden, roster} = Fuzz.begin!(seed, 7, 40..120)

        {acc, _} =
          Enum.reduce(1..rounds, {[], roster}, fn _round, {acc, players} ->
            opts = [expected_rounds: rounds, forbidden_pairs: forbidden]

            {result, rec} =
              Ainalrami.Proof.capture(
                fn -> Pairing.pair_next_round(players, opts) end,
                :as_paired
              )

            line = Ainalrami.Proof.certificate(rec, %{"players" => length(players)})
            {:ok, r} = verify_line(line)
            acc = r.solves ++ acc

            case result do
              {:ok, pairs} ->
                {acc, Fuzz.apply_round(players, pairs, Fuzz.simulate_results(pairs))}

              _ ->
                {acc, players}
            end
          end)

        acc
      end)

    assert Enum.any?(verdicts, fn {_, kind, _} -> kind == "window" end)
    assert Enum.all?(verdicts, fn {_, _, v} -> v == :pass end)
  end

  test "the verifier refuses what is not a proof" do
    assert {:error, _} = verify_line("not json")
    assert {:error, _} = verify_line(~s({"format": "something else", "version": 1}))

    # A graph naming a base that is not an earlier solve.
    line =
      JSON.encode!(%{
        "format" => "ainalrami-pairing-proof",
        "version" => 1,
        "round" => %{"players" => 2},
        "solves" => [
          %{
            "id" => 0,
            "kind" => "solve",
            "n" => 2,
            "graph" => %{"base" => 7, "set" => []},
            "matching" => [],
            "duals" => [],
            "sets" => []
          }
        ]
      })

    assert [{:fail, _}] = verdicts(line)
  end

  test "a hand-made certificate: a triangle needs its odd-set dual" do
    # Weights 2, 2, 2 on a triangle: one edge is optimal (weight 2, on the
    # doubled scale 4). Vertex duals alone would need 4 on the three
    # vertices (objective 6 > 4); the odd set {0, 1, 2} with z = 4 and every
    # vertex at 0 closes the gap.
    base = %{
      "format" => "ainalrami-pairing-proof",
      "version" => 1,
      "round" => %{"players" => 3},
      "solves" => [
        %{
          "id" => 0,
          "kind" => "solve",
          "n" => 3,
          "graph" => %{"edges" => [[0, 1, "4"], [0, 2, "4"], [1, 2, "4"]]},
          "matching" => [[0, 1]],
          "duals" => [],
          "sets" => [%{"vertices" => [0, 1, 2], "z" => "4"}]
        }
      ]
    }

    assert [:pass] = verdicts(JSON.encode!(base))

    # Without the set: no dual at all is not feasible.
    no_set = put_in(base, ["solves"], [Map.put(hd(base["solves"]), "sets", [])])
    assert [{:fail, reason}] = verdicts(JSON.encode!(no_set))
    assert reason =~ "violates"

    # An even set is not an odd-set constraint.
    even =
      put_in(base, ["solves"], [
        Map.put(hd(base["solves"]), "sets", [%{"vertices" => [0, 1], "z" => "4"}])
      ])

    assert [{:fail, reason}] = verdicts(JSON.encode!(even))
    assert reason =~ "even"
  end

  test "a window certificate: a tight unmatched edge at a window vertex is refused" do
    # A 4-cycle 0-1-2-3-0 with every weight 2 (doubled 4): two perfect
    # matchings tie, so no window vertex has a forced partner.
    solve = %{
      "id" => 0,
      "kind" => "window",
      "n" => 4,
      "graph" => %{"edges" => [[0, 1, "4"], [1, 2, "4"], [2, 3, "4"], [0, 3, "4"]]},
      "matching" => [[0, 1], [2, 3]],
      "duals" => [[0, "2"], [1, "2"], [2, "2"], [3, "2"]],
      "sets" => []
    }

    doc = %{
      "format" => "ainalrami-pairing-proof",
      "version" => 1,
      "round" => %{"players" => 4},
      "solves" => [solve]
    }

    assert [:pass] = verdicts(JSON.encode!(doc))

    windowed = put_in(doc, ["solves"], [Map.put(solve, "window", [0])])
    assert [{:fail, reason}] = verdicts(JSON.encode!(windowed))
    assert reason =~ "window"
  end

  test "--proof writes one certificate per round, and the pairing file is unchanged" do
    dir = Path.join(System.tmp_dir!(), "ainalrami-proof-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    trf = Path.join(dir, "t.trf")

    assert 0 ==
             Ainalrami.CLI.run(["-g", trf, "--seed=11", "--players=24", "--rounds=4", "-q"])

    plain = Path.join(dir, "plain.txt")
    proved = Path.join(dir, "proved.txt")
    proof = Path.join(dir, "proof.jsonl")

    assert 0 == Ainalrami.CLI.run([trf, "-p", plain, "--rounds=7", "-q"])
    assert 0 == Ainalrami.CLI.run([trf, "-p", proved, "--rounds=7", "-q", "--proof=" <> proof])

    assert File.read!(plain) == File.read!(proved)
    [line] = proof |> File.read!() |> String.split("\n", trim: true)
    assert Enum.all?(verdicts(line), &(&1 == :pass))
  end
end

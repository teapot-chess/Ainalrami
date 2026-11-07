defmodule AinalramiVerify.CertificateTest do
  use ExUnit.Case, async: true

  alias AinalramiVerify.{Bracket, Certificate, Engine, PairsFile, Position, Trf, Walk}

  @articles "test/fixtures/articles"
  @disputes "test/fixtures/disputes"

  defp roundtrip(cert), do: cert |> Certificate.encode() |> Certificate.decode()

  test "the engine's rounds certify and check, fixtures and random walks" do
    trfs =
      Path.wildcard(Path.join(@disputes, "*.trf")) |> Enum.map(&File.read!/1)

    walks =
      for seed <- 1..25,
          t <- Walk.positions(players: 5 + rem(seed, 6), rounds: 5, seed: seed, absences: 0.1),
          do: t

    for trf <- trfs ++ walks, match?({:ok, _}, Engine.pair(trf)) do
      assert {:ok, cert} = Certificate.certify(trf), trf
      assert Certificate.check(trf, roundtrip(cert)) == :ok
    end
  end

  test "a round worse on any criterion cannot be certified" do
    for name <- ~w(C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C16 C17 C18 C19 C20 C21) do
      trf = File.read!(Path.join(@articles, name <> ".trf"))
      round = PairsFile.parse(File.read!(Path.join(@articles, name <> ".pairs")))

      assert {:error, {:not_optimal, _bracket, published, optimum}} =
               Certificate.certify_round(trf, round),
             name

      assert optimum > published
    end
  end

  test "a round that differs from the best only in Article 4's order certifies: the order is not a weight" do
    trf = File.read!(Path.join(@articles, "order.trf"))
    round = PairsFile.parse(File.read!(Path.join(@articles, "order.pairs")))
    assert {:ok, cert} = Certificate.certify_round(trf, round)
    assert Certificate.check(trf, roundtrip(cert)) == :ok
  end

  describe "the checker is not a rubber stamp" do
    setup do
      trf = File.read!(Path.join(@disputes, "seed735265-r7-p10.trf"))
      {:ok, cert} = Certificate.certify(trf)
      %{trf: trf, cert: roundtrip(cert)}
    end

    test "another TRF", %{trf: trf, cert: cert} do
      assert {:error, "the TRF is not the one certified" <> _} =
               Certificate.check(trf <> "\n", cert)
    end

    test "a board swapped for another legal one", %{trf: trf, cert: cert} do
      pairs = cert["pairs"]
      [[a, b], [c, d] | rest] = pairs
      tampered = %{cert | "pairs" => [[a, d], [c, b] | rest]}
      assert {:error, _} = Certificate.check(trf, tampered)
    end

    test "a dual lowered", %{trf: trf, cert: cert} do
      stages = cert["stages"]
      i = Enum.find_index(stages, &(&1["duals"] != []))
      stage = Enum.at(stages, i)
      [[v, y] | more] = stage["duals"]
      low = Integer.to_string(String.to_integer(y) - 1)

      tampered = %{
        cert
        | "stages" => List.replace_at(stages, i, %{stage | "duals" => [[v, low] | more]})
      }

      assert {:error, _} = Certificate.check(trf, tampered)
    end

    test "a dual raised", %{trf: trf, cert: cert} do
      stages = cert["stages"]
      i = Enum.find_index(stages, &(&1["duals"] != []))
      stage = Enum.at(stages, i)
      [[v, y] | more] = stage["duals"]
      high = Integer.to_string(String.to_integer(y) + 1)

      tampered = %{
        cert
        | "stages" => List.replace_at(stages, i, %{stage | "duals" => [[v, high] | more]})
      }

      assert {:error, _} = Certificate.check(trf, tampered)
    end

    test "the bye moved", %{trf: trf, cert: cert} do
      assert {:error, _} = Certificate.check(trf, %{cert | "bye" => 3})
    end

    test "a stage dropped", %{trf: trf, cert: cert} do
      assert {:error, _} = Certificate.check(trf, %{cert | "stages" => tl(cert["stages"])})
    end
  end

  test "an odd set is needed and accepted: a triangle of equal weights" do
    # Not from a round: the LP checker on a hand-built stage, where only an
    # odd-set dual proves the matching of one edge in a triangle optimal.
    w = %{vertices: [1, 2, 3], edges: %{{1, 2} => 2, {1, 3} => 2, {2, 3} => 2}}
    vertex_only = %{y: %{1 => 1, 2 => 1, 3 => 1}, sets: [], factor: 2}
    # vertex duals 1 each cover every edge (2*(1+1) >= 2*2) but the dual
    # objective 3 exceeds the matching's 2: complementary slackness fails
    assert {:error, _} = Certificate.verify_stage(w, [{1, 2}], vertex_only)
    with_set = %{y: %{}, sets: [{[1, 2, 3], 2}], factor: 2}
    assert Certificate.verify_stage(w, [{1, 2}], with_set) == :ok
  end

  test "the reference's own rounds certify: the weights and the brute force pick the same best" do
    for seed <- 1..12,
        trf <-
          Walk.positions(players: 6 + rem(seed, 3), rounds: 4, seed: 100 + seed, absences: 0.1) do
      pos = trf |> Trf.parse() |> Position.build()

      case Bracket.pair(pos) do
        {:ok, round} -> assert {:ok, _} = Certificate.certify_round(trf, round), trf
        {:error, :no_legal_pairing} -> :ok
      end
    end
  end
end

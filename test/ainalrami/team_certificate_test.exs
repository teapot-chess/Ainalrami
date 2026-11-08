defmodule Ainalrami.TeamCertificateTest do
  use ExUnit.Case, async: true

  alias Ainalrami.{TeamCertificate, TeamPairing}
  alias Ainalrami.TeamProof.Events

  @sha String.duplicate("0", 64)

  # Plays seeded events and certifies every round the engine pairs.
  defp each_round(seeds, extra_opts, fun) do
    for seed <- seeds do
      :rand.seed(:exsss, {seed, 17, 4242})
      size = 5 + rem(seed * 7, 30)
      rounds = 3 + rem(seed, 6)

      Events.play_event(size, rounds, Enum.random([:white, :black]), fn _no,
                                                                        field,
                                                                        _absent,
                                                                        opts ->
        opts = opts ++ extra_opts.(field)

        case TeamPairing.pair_round(field, opts) do
          {:ok, result} ->
            fun.(seed, field, opts, result)
            result

          {:error, _} ->
            :stop
        end
      end)
    end
  end

  test "every round the engine pairs certifies (match points)" do
    each_round(1..25, fn _ -> [] end, fn seed, field, opts, result ->
      input = TeamCertificate.input(field, opts)
      assert {:ok, cert} = TeamCertificate.certify(input, result, @sha), "seed #{seed}"
      assert cert["bye"] == result.bye
      assert length(cert["pairs"]) == length(result.pairs)

      send(
        self(),
        {:checked,
         {cert["bye_passed_over"] != [], Enum.any?(cert["brackets"], &(&1["upfloaters"] != []))}}
      )
    end)

    seen = collect([])
    # The proofs that are not trivially empty were exercised.
    assert Enum.any?(seen, &elem(&1, 1))
  end

  test "game points as primary score, and teams kept apart" do
    each_round(
      61..75,
      fn field ->
        tpns = field |> Enum.map(& &1.tpn) |> Enum.take(4)

        [
          score_mode: :game_points,
          forbidden_pairs: [Enum.take(tpns, 2)],
          soft_pairs: [Enum.drop(tpns, 2)]
        ]
      end,
      fn seed, field, opts, result ->
        input = TeamCertificate.input(field, opts)
        assert {:ok, _} = TeamCertificate.certify(input, result, @sha), "seed #{seed}"
      end
    )
  end

  test "a round re-partnered inside a bracket does not certify" do
    refused =
      each_round(101..115, fn _ -> [] end, fn _seed, field, opts, result ->
        case result.pairs do
          [p, q | rest] ->
            swapped = [
              %{white: p.white, black: q.black},
              %{white: q.white, black: p.black} | rest
            ]

            input = TeamCertificate.input(field, opts)

            send(
              self(),
              {:checked, TeamCertificate.certify(input, %{result | pairs: swapped}, @sha)}
            )

          _ ->
            :ok
        end
      end)

    _ = refused
    results = collect([])
    assert results != []
    # A swap may by chance give the same round (or one equally first); it
    # must never give a different certified round that the engine did not
    # choose.
    assert Enum.all?(results, fn
             {:ok, _} -> false
             {:error, _} -> true
           end)
  end

  defp collect(acc) do
    receive do
      {:checked, r} -> collect([r | acc])
    after
      0 -> acc
    end
  end

  test "the input record round-trips to the same round" do
    each_round(141..148, fn _ -> [] end, fn _seed, field, opts, result ->
      input = TeamCertificate.input(field, opts)
      {:ok, teams, opts2} = TeamCertificate.decode_input(input)
      {:ok, again} = TeamPairing.pair_round(teams, opts2)
      assert again.pairs == result.pairs
      assert again.bye == result.bye
    end)
  end

  test "Type B is refused, not certified" do
    teams = for tpn <- 1..4, do: %TeamPairing.Team{tpn: tpn}
    {:ok, result} = TeamPairing.pair_round(teams, type: :b)
    input = TeamCertificate.input(teams, type: :b)
    assert {:error, {:unsupported, :type_b}} = TeamCertificate.certify(input, result, @sha)
  end

  test "output text" do
    assert TeamCertificate.output_text(%{pairs: [%{white: 1, black: 4}], bye: 3}) ==
             "2\n1 4\n3 0\n"
  end
end

defmodule Ainalrami.TeamCertificateByeTest do
  use ExUnit.Case, async: true

  alias Ainalrami.{TeamCertificate, TeamPairing}
  alias Ainalrami.TeamPairing.Team

  # Team 1 has met 2, 3 and 4: without team 5 nobody is left for it, so
  # 3.4.1 passes the lowest team over and the bye goes to team 4.
  test "a team 3.4.1 passes over carries an unpairability proof" do
    teams = [
      %Team{tpn: 1, match_points: 6.0, opponents: [2, 3, 4], colours: [:white, :black, :white]},
      %Team{tpn: 2, match_points: 3.0, opponents: [1], colours: [:black]},
      %Team{tpn: 3, match_points: 2.0, opponents: [1], colours: [:white]},
      %Team{tpn: 4, match_points: 1.0, opponents: [1], colours: [:black]},
      %Team{tpn: 5, match_points: 0.0}
    ]

    opts = [round: 4, expected_rounds: 7]
    {:ok, result} = TeamPairing.pair_round(teams, opts)
    assert result.bye == 4

    input = TeamCertificate.input(teams, opts)
    assert {:ok, cert} = TeamCertificate.certify(input, result, String.duplicate("0", 64))
    assert [%{"team" => 5}] = cert["bye_passed_over"]

    # The bye handed to the lowest team instead is refused.
    wrong = %{pairs: [%{white: 1, black: 4}, %{white: 2, black: 3}], bye: 5}

    assert {:error, {:not_optimal, _}} =
             TeamCertificate.certify(input, wrong, String.duplicate("0", 64))
  end
end

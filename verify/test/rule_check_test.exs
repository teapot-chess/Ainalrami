defmodule AinalramiVerify.RuleCheckTest do
  use ExUnit.Case, async: true

  alias AinalramiVerify.{Engine, PairsFile, Position, RuleCheck, Trf, Walk}

  @articles "test/fixtures/articles"
  @disputes "test/fixtures/disputes"

  defp position(path), do: path |> File.read!() |> Trf.parse() |> Position.build()

  describe "a deliberately wrong round is caught on its own article" do
    # Each fixture is a position and a round that is worse than the best
    # first on the criterion it is named after (tools/article_examples.exs
    # built them from the reference). "order" is a round equal to the best
    # on every criterion that Article 4 generates later.
    for name <- ~w(C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C16 C17 C18 C19 C20 C21 order) do
      test name do
        name = unquote(name)
        pos = position(Path.join(@articles, name <> ".trf"))
        round = PairsFile.parse(File.read!(Path.join(@articles, name <> ".pairs")))
        [first | _] = RuleCheck.check(pos, round, colours: false)
        assert first.criterion == name, RuleCheck.format(RuleCheck.check(pos, round))
      end
    end
  end

  describe "absolute criteria and completeness" do
    setup do
      pos = position(Path.join(@disputes, "seed735265-r7-p10.trf"))
      {:ok, engine} = Engine.pair(File.read!(Path.join(@disputes, "seed735265-r7-p10.trf")))
      %{pos: pos, engine: engine}
    end

    test "the engine's round is clean", %{pos: pos, engine: engine} do
      assert RuleCheck.check(pos, engine) == []
    end

    test "C1: a rematch", %{pos: pos} do
      # 5 and 2 met in round 2
      round = %{pairs: [{5, 2}, {8, 1}, {3, 9}], bye: 7}

      assert Enum.any?(
               RuleCheck.check(pos, round),
               &(&1.criterion == "C1" and &1.players == [5, 2])
             )
    end

    test "C2: a second bye", %{pos: pos} do
      # 3 had the pairing-allocated bye in round 2
      round = %{pairs: [{5, 1}, {8, 2}, {7, 9}], bye: 3}
      assert Enum.any?(RuleCheck.check(pos, round), &(&1.criterion == "C2" and &1.players == [3]))
    end

    test "1.9.1: a player left out, and one paired twice", %{pos: pos} do
      v = RuleCheck.check(pos, %{pairs: [{5, 1}, {8, 2}], bye: 7})
      assert Enum.any?(v, &(&1.article == "1.9.1" and &1.players == [3, 9]))
      v = RuleCheck.check(pos, %{pairs: [{5, 1}, {8, 2}, {3, 9}, {7, 1}], bye: nil})
      assert Enum.any?(v, &(&1.article == "1.9.1" and &1.players == [1]))
    end

    test "1.9.1: a player sitting the round out cannot be paired", %{pos: pos} do
      # 4 has a requested bye for round 7
      v = RuleCheck.check(pos, %{pairs: [{5, 1}, {8, 2}, {3, 9}, {7, 4}], bye: nil})
      assert Enum.any?(v, &(&1.article == "1.9.1" and &1.players == [4]))
    end

    test "Article 5: colours the wrong way round", %{pos: pos, engine: engine} do
      [{w, b} | rest] = engine.pairs
      v = RuleCheck.check(pos, %{engine | pairs: [{b, w} | rest]})
      assert [%{criterion: "colour", players: [^b, ^w], article: "5.2." <> _}] = v
    end
  end

  test "C3: two non-topscorers with the same absolute preference" do
    # 2 and 3 had Black twice, 1 and 4 White twice; round 3 of 5, so
    # nobody is a topscorer.
    r1 = %{1 => {3, :w, "1"}, 3 => {1, :b, "0"}, 4 => {2, :w, "="}, 2 => {4, :b, "="}}
    r2 = %{1 => {2, :w, "0"}, 2 => {1, :b, "1"}, 4 => {3, :w, "1"}, 3 => {4, :b, "0"}}
    pos = AinalramiVerify.TrfWriter.write(4, [r1, r2], 5) |> Trf.parse() |> Position.build()
    assert pos.players[2].pref == {:w, :absolute}
    assert pos.players[3].pref == {:w, :absolute}
    v = RuleCheck.check(pos, %{pairs: [{2, 3}, {1, 4}], bye: nil})
    assert Enum.count(v, &(&1.criterion == "C3")) == 2
  end

  describe "the known bbpPairings disagreements" do
    # docs/dispute-seed735265.md and test/fixtures/fe1_disputes/README.md
    # in the engine: bbpPairings gave a second bye in both. Gacrux and
    # Ainalrami did not.
    test "seed735265-r7-p10: bbpPairings breaks C2, the engine's round is clean" do
      pos = position(Path.join(@disputes, "seed735265-r7-p10.trf"))
      bbp = PairsFile.parse(File.read!(Path.join(@disputes, "seed735265-r7-p10.bbp.pairs")))
      assert [%{criterion: "C2", players: [3]}] = RuleCheck.check(pos, bbp)
    end

    test "seed8848759-r9-p10: bbpPairings breaks C2, the engine's round is clean" do
      path = Path.join(@disputes, "seed8848759-r9-p10.trf")
      pos = position(path)
      bbp = PairsFile.parse(File.read!(Path.join(@disputes, "seed8848759-r9-p10.bbp.pairs")))
      assert [%{criterion: "C2", players: [4]}] = RuleCheck.check(pos, bbp)
      {:ok, engine} = Engine.pair(File.read!(path))
      assert RuleCheck.check(pos, engine) == []
    end

    test "every dispute and open-question fixture: the engine's round is clean" do
      for path <- Path.wildcard(Path.join(@disputes, "*.trf")) do
        {:ok, engine} = Engine.pair(File.read!(path))
        assert RuleCheck.check(position(path), engine) == [], path
      end
    end
  end

  test "the engine's own rounds are clean, absences and byes included" do
    for seed <- 1..40,
        trf <- Walk.positions(players: 5 + rem(seed, 6), rounds: 5, seed: seed, absences: 0.1) do
      pos = trf |> Trf.parse() |> Position.build()

      case Engine.pair(trf) do
        {:ok, round} -> assert RuleCheck.check(pos, round) == [], trf
        {:error, _} -> :ok
      end
    end
  end

  test "a round read from a TRF that holds it" do
    text = File.read!(Path.join(@disputes, "seed735265-r7-p10.trf"))
    pos = text |> Trf.parse() |> Position.build()
    {:ok, engine} = Engine.pair(text)
    # write the engine's round into the file's round-7 column
    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.map(fn
        "001" <> _ = line ->
          rank = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()

          entry =
            Enum.find_value(engine.pairs, fn
              {^rank, b} -> "  #{String.pad_leading("#{b}", 4)} w 1"
              {w, ^rank} -> "  #{String.pad_leading("#{w}", 4)} b 0"
              _ -> nil
            end) || if(engine.bye == rank, do: "  0000 - U", else: "")

          if Map.has_key?(pos.trf.players[rank].games, 7),
            do: line,
            else: String.pad_trailing(line, 89 + 10 * 6) <> entry

        line ->
          line
      end)
      |> Enum.join("\n")

    assert AinalramiVerify.PairsFile.from_trf(lines, 7) |> Map.delete(:extra_byes) ==
             %{pairs: Enum.sort(engine.pairs), bye: engine.bye}
  end
end

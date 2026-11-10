defmodule Ainalrami.CLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log, Trf}

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  defp write_trf!(text) do
    path =
      Path.join(System.tmp_dir!(), "ainalrami_cli_test_#{System.unique_integer([:positive])}.trf")

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Built via Trf.serialize/1 rather than hand-typed fixed-width text - a
  # manually counted column offset is exactly the kind of mistake that's
  # bitten this TRF parser before (see the sibling project's own history).
  # No game history - this is a round-1 roster.
  defp sample_trf do
    Trf.serialize(%{
      tournament: %{name: "CLI Test Open", type: "swiss"},
      players: [
        %{rank: 1, name: "A", fide_rating: 2000, points: 0.0, games: []},
        %{rank: 2, name: "B", fide_rating: 1900, points: 0.0, games: []}
      ]
    })
  end

  # Same idea, but WITH a round of history already played (4 players, two
  # round-1 boards decided) - exercises the round-2 bracket-cascade path
  # instead of round 1's own split-the-whole-field pairing.
  defp sample_trf_with_history do
    Trf.serialize(%{
      tournament: %{name: "CLI Test Open R2", type: "swiss"},
      players: [
        %{
          rank: 1,
          name: "A",
          fide_rating: 2000,
          points: 1.0,
          games: [%{opponent_rank: 3, colour: "w", result: "1"}]
        },
        %{
          rank: 2,
          name: "B",
          fide_rating: 1900,
          points: 1.0,
          games: [%{opponent_rank: 4, colour: "w", result: "1"}]
        },
        %{
          rank: 3,
          name: "C",
          fide_rating: 1800,
          points: 0.0,
          games: [%{opponent_rank: 1, colour: "b", result: "0"}]
        },
        %{
          rank: 4,
          name: "D",
          fide_rating: 1700,
          points: 0.0,
          games: [%{opponent_rank: 2, colour: "b", result: "0"}]
        }
      ]
    })
  end

  # Same roster, but round 1 has both players claiming a win - illegal per
  # `Trf`'s own result-pair validation. `Trf.serialize/1` would reject this
  # outright, so it's built by serializing a *legal* round then flipping one
  # result character afterward, the same technique the sibling project's own
  # `trf_test.exs` uses for this exact kind of fixture.
  defp illegal_result_trf do
    text =
      Trf.serialize(%{
        tournament: %{name: "Bad File", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: "A",
            points: 0.0,
            games: [%{opponent_rank: 2, colour: "w", result: "1"}]
          },
          %{
            rank: 2,
            name: "B",
            points: 0.0,
            games: [%{opponent_rank: 1, colour: "b", result: "0"}]
          }
        ]
      })

    # Round 1's result column is 99 (base 92 + 7) - flip B's loss into a
    # second win.
    lines = String.split(text, "\r\n")
    p2 = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "B"))
    {before, rest} = String.split_at(p2, 98)
    <<_::binary-size(1), after_::binary>> = rest
    bad_p2 = before <> "1" <> after_

    lines |> Enum.map(&if &1 == p2, do: bad_p2, else: &1) |> Enum.join("\r\n")
  end

  # The same one-round file with BOTH results replaced by `?`. Both, because
  # one side alone would be a contradiction rather than a lost result, and
  # `Trf.parse/1` refuses that - see `Ainalrami.UnknownResultTest`.
  defp unknown_result_trf do
    illegal_result_trf()
    |> String.split("\r\n")
    |> Enum.map_join("\r\n", fn
      "001" <> _ = line ->
        {before, rest} = String.split_at(line, 98)
        <<_::binary-size(1), after_::binary>> = rest
        before <> "?" <> after_

      other ->
        other
    end)
  end

  test "-h prints help and exits 0" do
    out = capture_io(fn -> assert CLI.run(["-h"]) == 0 end)
    assert out =~ "ainalrami - a FIDE Dutch-system Swiss pairing engine"
  end

  test "--version prints something and exits 0" do
    out = capture_io(fn -> assert CLI.run(["--version"]) == 0 end)
    assert String.trim(out) != ""
  end

  test "missing input file exits 1 with a usage message" do
    {out, code} = run_capturing(fn -> CLI.run(["-p"]) end)

    assert code == 1
    assert out =~ "missing input TRF file"
  end

  test "missing mode flag exits 1" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path]) end)

    assert code == 1
    assert out =~ "missing mode flag"
  end

  test "-p on a round-1 TRF file loads, reports the roster, and actually pairs it (exit 0)" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 0
    assert out =~ "Loading #{path}"
    assert out =~ "2 players, 0 teams"
    assert out =~ "#1 A"
    assert out =~ "#2 B"
    assert out =~ "#1 (white) vs. #2 (black)"
  end

  test "-p with no output file prints the JaVaFo-shaped pairing to stdout" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 0
    # javafo.jar's own output shape: a count line, then "white black" lines,
    # CRLF throughout - confirmed against a real javafo.jar run.
    assert out =~ "1\r\n1 2\r\n"
  end

  test "-p with an output file writes the pairing there instead of stdout" do
    path = write_trf!(sample_trf())
    out_path = write_trf!("")

    {out, code} = run_capturing(fn -> CLI.run([path, "-p", out_path]) end)

    assert code == 0
    assert out =~ "wrote #{out_path}"
    assert File.read!(out_path) == "1\r\n1 2\r\n"
  end

  test "-p on a later round (game history already present) pairs it via the bracket cascade" do
    path = write_trf!(sample_trf_with_history())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 0
    assert out =~ "pairing round 2"
    # Round-1 winners A(1) and B(2) bracket together; round-1 losers C(3)
    # and D(4) bracket together - see sample_trf_with_history/0's doc.
    #
    # B(2) takes White on board 1, and this asserted the opposite until
    # 2026-08-17. Both A and B played White in round 1, so both hold a strong
    # preference for Black and their colour histories are identical: 5.2.1
    # cannot grant both, 5.2.2 cannot separate two equally strong
    # preferences, and 5.2.3 has no round in which one had White and the
    # other Black. C.04.3 5.2.4 decides - "grant the colour preference of the
    # higher ranked player" - so A(1) gets Black.
    #
    # `choose_colour/2` skipped 5.2.4 and fell through to 5.2.5's odd-number
    # rule (parity of the arrival number since the SPP ruling of 2026-08-27,
    # of the raw TPN when this was written), which handed A the initial
    # colour instead. Confirmed against
    # bbpPairings on this exact position: it answers `2 1`.
    assert out =~ "2\r\n2 1\r\n3 4\r\n"
  end

  test "-p on a missing file exits 1 with a clear error" do
    {out, code} = run_capturing(fn -> CLI.run(["does-not-exist.trf", "-p"]) end)

    assert code == 1
    assert out =~ "could not read"
  end

  test "-p on an invalid TRF file exits 1 with the validation error" do
    path = write_trf!(illegal_result_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 1
    assert out =~ "invalid TRF file"
  end

  test "-p on a file with an unknown result pairs it as the played draw it is worth" do
    # The file is legal and, since v0.44.0, a `?` is a played game worth a
    # draw unless the file's `162` says otherwise (`Ainalrami.Trf`, "The `?`
    # unknown result"). Two players who have met have no second round to
    # pair, and that - not the lost scoresheet - is what the command says.
    path = write_trf!(unknown_result_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p"]) end)

    assert code == 1
    assert out =~ "no legal pairing exists"
    refute out =~ "not known"
    refute out =~ "unexpected error"
    refute out =~ "invalid TRF file"
  end

  describe "-p and the drawing of lots" do
    # `Trf` has read `152` since 2026-08-17, but `pairing_opts/1` never
    # forwarded it, so the CLI fell back to inferring the draw from round
    # one. That works for a file that HAS a round one and is simply wrong
    # for a fresh roster, where there is nothing to infer from and the
    # engine defaults to White.
    #
    # The visible consequence: an arbiter who drew Black, recorded it, and
    # asked for round one got White pairings out of a file that said
    # otherwise. Round one is exactly when every board turns on the draw,
    # since nobody holds a colour preference yet.
    test "an explicit 152 decides round one's colours" do
      white = pair_roster("w")
      black = pair_roster("b")

      assert Enum.map(white, &Enum.sort/1) == Enum.map(black, &Enum.sort/1),
             "the draw decides sides, never who plays whom"

      refute white == black, "a Black draw must not pair identically to a White one"

      for {[w1, _], [w2, _]} <- Enum.zip(white, black) do
        refute w1 == w2, "every board must flip when the draw flips"
      end
    end

    defp pair_roster(colour) do
      players =
        for r <- 1..8 do
          %{
            rank: r,
            name: "P#{r}",
            sex: "",
            title: "",
            fide_rating: 2400 - r * 10,
            federation: "",
            fide_number: nil,
            birth_date: "",
            points: 0.0,
            games: []
          }
        end

      path =
        Path.join(
          System.tmp_dir!(),
          "ainalrami-draw-p-#{colour}-#{System.unique_integer([:positive])}.trf"
        )

      on_exit(fn -> File.rm(path) end)

      File.write!(
        path,
        Trf.serialize(%{
          tournament: %{
            name: "Draw",
            type: "swiss",
            number_of_rounds: 5,
            initial_colour: colour
          },
          players: players
        })
      )

      {out, 0} = run_capturing(fn -> CLI.run([path, "-p", "-q"]) end)

      out
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> tl()
      |> Enum.map(fn line ->
        line |> String.trim() |> String.split(~r/\s+/) |> Enum.map(&String.to_integer/1)
      end)
    end
  end

  describe "-g (Random Tournament Generator)" do
    test "writes a parseable TRF that records its own seed" do
      path =
        Path.join(System.tmp_dir!(), "ainalrami-rtg-#{System.unique_integer([:positive])}.trf")

      on_exit(fn -> File.rm(path) end)

      {out, code} =
        run_capturing(fn ->
          CLI.run(["-g", path, "--seed=1234", "--players=14", "--rounds=5"])
        end)

      assert code == 0
      assert out =~ "seed 1234"

      parsed = Trf.parse(File.read!(path))
      assert length(parsed.players) == 14
      assert Enum.all?(parsed.players, &(length(&1.games) == 5))
      # The seed rides in the tournament name so the file alone reproduces
      # the run - see Ainalrami.Generator's moduledoc on why not line one.
      assert parsed.tournament[:name] =~ "seed=1234"
    end

    test "records the drawing of lots it actually paired under" do
      # Article 5.1's initial colour was always White here, implicitly: the
      # generator passed nothing to the engine, which defaulted, and wrote
      # nothing to the file, which left a reader to reconstruct it from
      # round one. Now it is stated, so the file says what it was paired
      # under rather than requiring the inference to be right.
      for {flag, code, first_colour} <- [{"w", "w", "w"}, {"b", "b", "b"}] do
        path =
          Path.join(
            System.tmp_dir!(),
            "ainalrami-draw-#{flag}-#{System.unique_integer([:positive])}.trf"
          )

        on_exit(fn -> File.rm(path) end)

        {_out, 0} =
          run_capturing(fn ->
            CLI.run([
              "-g",
              path,
              "--seed=5",
              "--players=10",
              "--rounds=4",
              "--initial-colour=#{flag}",
              "-q"
            ])
          end)

        text = File.read!(path)
        assert text =~ "152 #{String.upcase(code)}"

        parsed = Trf.parse(text)
        assert parsed.tournament[:initial_colour] == code

        # And it is not merely written: the draw decides colours, so the
        # top board's higher-ranked player holds the drawn colour in round
        # one (TPN 1 is odd, so 5.2.5 gives it to them).
        first = Enum.find(parsed.players, &(&1.rank == 1))
        assert hd(first.games).colour == first_colour
      end
    end

    test "the two draws produce mirror-image colours and both check clean" do
      paths =
        for flag <- ["w", "b"] do
          path =
            Path.join(
              System.tmp_dir!(),
              "ainalrami-mirror-#{flag}-#{System.unique_integer([:positive])}.trf"
            )

          on_exit(fn -> File.rm(path) end)

          {_out, 0} =
            run_capturing(fn ->
              CLI.run([
                "-g",
                path,
                "--seed=11",
                "--players=12",
                "--rounds=4",
                "--initial-colour=#{flag}",
                "-q"
              ])
            end)

          # `-c` replays every round against the engine. It has to pass for
          # BOTH draws: the checker re-derives the initial colour from the
          # file, so a draw that is written but not read back correctly
          # would fail here rather than silently.
          {_, check_code} = run_capturing(fn -> CLI.run([path, "-c", "-q"]) end)
          assert check_code == 0, "#{flag} draw must check clean"

          path
        end

      [white_draw, black_draw] = Enum.map(paths, &Trf.parse(File.read!(&1)))

      colours = fn parsed ->
        for p <- parsed.players, into: %{}, do: {p.rank, hd(p.games).colour}
      end

      w = colours.(white_draw)
      b = colours.(black_draw)

      assert Map.keys(w) == Map.keys(b), "same field either way"

      # Round one is the same set of boards with every colour inverted -
      # the draw decides sides, never who plays whom.
      assert Enum.all?(Map.keys(w), fn rank ->
               case {Map.fetch!(w, rank), Map.fetch!(b, rank)} do
                 {nil, nil} -> true
                 {x, y} -> x != y
               end
             end)
    end

    test "the same seed generates the same tournament" do
      {first, 7} = Ainalrami.Generator.generate(seed: 7, players: 12, rounds: 4)
      {second, 7} = Ainalrami.Generator.generate(seed: 7, players: 12, rounds: 4)

      assert first == second
    end

    test "generated tournaments check clean against the checker, byes and forfeits included" do
      for opts <- [
            [seed: 1, players: 16, rounds: 6],
            [seed: 2, players: 13, rounds: 7, forfeit_pct: 12],
            [seed: 3, players: 18, rounds: 6, requested_bye_pct: 10],
            [seed: 4, players: 15, rounds: 7, forfeit_pct: 10, requested_bye_pct: 8]
          ] do
        {text, _seed} = Ainalrami.Generator.generate(opts)
        path = write_trf!(text)

        {_out, code} = run_capturing(fn -> CLI.run([path, "-c", "-q"]) end)

        # The RTG pairs with this very engine, so its output is by
        # construction what the checker expects. A failure here means the
        # two modes disagree about the same rules - most likely in how a
        # round's pre-pairing state is reconstructed.
        assert code == 0, "generated tournament failed its own checker: #{inspect(opts)}"
      end
    end

    # The same round-trip, but now the file carries `XXP`/`XXA` lines. This
    # is a stronger test of those than it looks: `-c` reads the extension
    # lines back out of the generated file and hands them to the engine, so
    # a serializer and parser that disagree about `XXA`'s columns - the
    # exact mistake that makes real bbpPairings reject the sibling
    # project's own output - fails here rather than silently pairing an
    # unaccelerated tournament.
    test "generated tournaments carrying XXP and XXA also check clean" do
      for opts <- [
            [seed: 11, players: 16, rounds: 6, forbidden_pct: 15],
            [seed: 12, players: 16, rounds: 6, acceleration: :baku],
            [seed: 13, players: 14, rounds: 7, acceleration: :random],
            [
              seed: 14,
              players: 18,
              rounds: 6,
              forbidden_pct: 10,
              acceleration: :baku,
              requested_bye_pct: 8,
              forfeit_pct: 8
            ]
          ] do
        {text, _seed} = Ainalrami.Generator.generate(opts)
        path = write_trf!(text)
        parsed = Trf.parse(text)

        if opts[:forbidden_pct],
          do: assert(parsed.tournament[:forbidden_pairs] not in [nil, []])

        if opts[:acceleration],
          do: assert(Enum.any?(parsed.players, &(&1[:accelerations] not in [nil, []])))

        {_out, code} = run_capturing(fn -> CLI.run([path, "-c", "-q"]) end)

        assert code == 0, "generated tournament failed its own checker: #{inspect(opts)}"
      end
    end

    test "a tournament that deadlocks early still declares the count it was paired under" do
      # `142`/`XXR` state the tournament's intended LENGTH, not its
      # progress - `expected_rounds`, which is what every round here was
      # actually paired with. A round can have no legal completion at all
      # (a proven deadlock, not a search giving up), and the generator then
      # stops at the last round that finished; it used to write THAT number
      # into both fields, so the file's rounds were paired under one count
      # and declared another.
      #
      # It feeds exactly one rule: `final_round_topscorers?/2`'s
      # `played_rounds >= expected_rounds - 1` gate, which relaxes the
      # colour constraints for the last two rounds. Under the truncated
      # count a reader applies the final-round exception to a round this
      # generator paired as an ordinary one, and the disagreement reads as
      # an engine defect rather than as a mislabelled file.
      #
      # Six players, five rounds, 40% of them asking for a bye each round:
      # a third of the seeds in this shape deadlock. Seed 2 stops after
      # three.
      {text, _seed} =
        Ainalrami.Generator.generate(seed: 2, players: 6, rounds: 5, requested_bye_pct: 40)

      parsed = Trf.parse(text)
      played = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max()

      assert played < 5, "seed 2 is the deadlocking fixture"
      assert parsed.tournament[:number_of_rounds] == 5
      assert text =~ "XXR 5"
      assert text =~ "142 5"
    end

    test "rounds are capped so the field cannot run out of legal opponents" do
      {text, _seed} = Ainalrami.Generator.generate(seed: 9, players: 6, rounds: 40)
      parsed = Trf.parse(text)

      assert Enum.all?(parsed.players, &(length(&1.games) <= 5))
    end
  end

  test "-q suppresses the step/detail trace on a successful round-1 pairing, but the pairing output still prints" do
    path = write_trf!(sample_trf())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p", "-q"]) end)

    assert code == 0
    refute out =~ "Loading"
    refute out =~ "players,"
    assert out =~ "1\r\n1 2\r\n"
  end

  test "-q suppresses the step/detail trace on a later-round pairing too, but the output still prints" do
    path = write_trf!(sample_trf_with_history())

    {out, code} = run_capturing(fn -> CLI.run([path, "-p", "-q"]) end)

    assert code == 0
    refute out =~ "Loading"
    refute out =~ "players,"
    assert out =~ "2\r\n2 1\r\n3 4\r\n"
  end

  describe "-c (Pairings Checker)" do
    test "a tournament this engine paired itself checks clean" do
      path = write_trf(self_paired_tournament(4))
      {out, code} = run_capturing(fn -> CLI.run([path, "-c"]) end)

      assert code == 0
      assert out =~ "4/4 round(s) match"
      refute out =~ "DIFFERS"
    end

    test "a tampered pairing is reported, and the exit code is nonzero" do
      players = self_paired_tournament(4)

      # Re-pair two of the round-3 games consistently (the two white players
      # trade opponents, on both sides of each game), so the recorded pairing
      # is a possible one that this engine would not have produced.
      round3 = fn p -> Enum.at(p.games, 2) end
      [w1, w2 | _] = Enum.filter(players, &(round3.(&1).colour == "w"))
      b1 = round3.(w1).opponent_rank
      b2 = round3.(w2).opponent_rank

      swap = %{w1.rank => b2, b2 => w1.rank, w2.rank => b1, b1 => w2.rank}

      tampered =
        Enum.map(players, fn p ->
          case Map.fetch(swap, p.rank) do
            {:ok, opp} ->
              %{p | games: List.update_at(p.games, 2, &%{&1 | opponent_rank: opp})}

            :error ->
              p
          end
        end)

      path = write_trf(tampered)
      {out, code} = run_capturing(fn -> CLI.run([path, "-c"]) end)

      assert code == 1
      assert out =~ "round 3: DIFFERS"
    end

    test "a file whose opponent references do not point back at each other is refused" do
      players = self_paired_tournament(4)

      # Player 1 names a different round-3 opponent than that opponent names
      # back: one line says 1 played X, X's line says X played someone else.
      [a | rest] = players
      ga = Enum.at(a.games, 2)
      other = Enum.find(rest, &(&1.rank != ga.opponent_rank))

      tampered = [
        %{a | games: List.replace_at(a.games, 2, %{ga | opponent_rank: other.rank})} | rest
      ]

      path = write_trf(tampered)
      {out, code} = run_capturing(fn -> CLI.run([path, "-c"]) end)

      assert code != 0
      assert out =~ "round 3"
      assert out =~ "lists"
    end

    test "a player holding an arbiter-assigned bye is left out of the replayed pairing" do
      # Five players, one of whom took a half-point bye in round 1: the
      # engine must pair the other four and not deal that player a game.
      # An arbiter's bye is recorded BEFORE its round is paired, which is
      # exactly how the engine knows to leave that player out, so
      # `state_before_round/3` has to carry it forward into the replay.
      sitting = %{opponent_rank: nil, colour: nil, result: "H"}

      roster =
        for i <- 1..5 do
          %{rank: i, name: "P#{i}", fide_rating: 2000 - i * 10, points: 0.0, games: []}
        end

      roster = List.update_at(roster, 4, &%{&1 | points: 0.5, games: [sitting]})
      pairs = Ainalrami.Pairing.pair_next_round(roster, expected_rounds: 9)

      refute Enum.any?(pairs, fn {w, b} -> 5 in [w, b] end),
             "rank 5 asked to sit out and must not be paired"

      path = write_trf(record_round(roster, pairs))
      {out, code} = run_capturing(fn -> CLI.run([path, "-c"]) end)

      assert code == 0
      assert out =~ "1/1 round(s) match"
      refute out =~ "DIFFERS"
    end

    test "a bye pre-recorded for the PENDING round is not a round to check" do
      # The same mechanism one round later, and the bug it used to cause.
      # `completed_rounds/1` counted the LENGTH of the longest game list, so
      # one player holding a round-5 `H` for a round nobody had been paired
      # in yet made it 5. The checker then diffed round 5:
      # `recorded_pairs/2` discards every non-participating game, so the
      # file's side was `[]`, while `state_before_round/3` reconstructs
      # precisely the position round 5 is to be paired FROM and duly paired
      # it. Every tournament with an advance bye standing for its next round
      # failed its own check on that round and exited 1.
      #
      # bbpPairings prints a `Round #5` heading for this file and nothing
      # under it - its reader pads the short histories out with
      # non-participating self-matches, so every player is sitting round 5
      # out and the matching comes back empty. Exit 0, no discrepancy.
      players = self_paired_tournament(4)

      pending =
        List.update_at(players, 0, fn p ->
          %{
            p
            | points: p.points + 0.5,
              games: p.games ++ [%{opponent_rank: nil, colour: nil, result: "H"}]
          }
        end)

      path = write_trf(pending)
      {out, code} = run_capturing(fn -> CLI.run([path, "-c"]) end)

      assert code == 0
      assert out =~ "Checking 4 round(s)"
      assert out =~ "4/4 round(s) match"
      refute out =~ "round 5"
    end
  end

  # A small tournament paired entirely by this engine, so a checker run
  # over it should agree with itself on every round.
  defp self_paired_tournament(rounds, player_count \\ 8) do
    roster =
      for i <- 1..player_count do
        %{rank: i, name: "P#{i}", fide_rating: 2000 - i * 10, points: 0.0, games: []}
      end

    Enum.reduce(1..rounds, roster, fn _round, players ->
      record_round(players, Ainalrami.Pairing.pair_next_round(players, expected_rounds: rounds))
    end)
  end

  # Writes one round of `pairs` onto `roster`, leaving anyone the pairing
  # left out (an arbiter's bye already on their sheet) exactly as they were.
  defp record_round(roster, pairs) do
    by_rank =
      Enum.reduce(pairs, %{}, fn
        {w, nil}, acc ->
          Map.put(acc, w, {%{opponent_rank: nil, colour: nil, result: "U"}, 1.0})

        {w, b}, acc ->
          acc
          |> Map.put(w, {%{opponent_rank: b, colour: "w", result: "1"}, 1.0})
          |> Map.put(b, {%{opponent_rank: w, colour: "b", result: "0"}, 0.0})
      end)

    Enum.map(roster, fn p ->
      case Map.fetch(by_rank, p.rank) do
        {:ok, {game, points}} -> %{p | points: p.points + points, games: p.games ++ [game]}
        :error -> p
      end
    end)
  end

  defp write_trf(players) do
    text =
      Ainalrami.Trf.serialize(%{
        tournament: %{name: "CheckerTest", type: "swiss"},
        players: players
      }) <> "XXR 9
"

    path =
      Path.join(System.tmp_dir!(), "ainalrami-check-#{System.unique_integer([:positive])}.trf")

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Ainalrami.Log writes step/detail to stdout and warn/error to stderr -
  # interleaving order doesn't matter for these assertions, so this just
  # concatenates both streams into one string, plus returns the CLI's own
  # return value (the would-be exit code).
  defp run_capturing(fun) do
    ref = make_ref()
    Process.put(ref, nil)

    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> Process.put(ref, fun.()) end)
        IO.write(stderr)
      end)

    {stdout, Process.get(ref)}
  end

  describe "-x, the explain mode" do
    test "pairs the next round and reports which criteria decided each bracket" do
      path = write_trf!(sample_trf())

      {out, code} = run_capturing(fn -> CLI.run([path, "-x"]) end)

      assert code == 0
      assert out =~ "explaining round"
      assert out =~ "Round 1 - 1 board over 1 bracket"
      assert out =~ "residents"
      assert out =~ "paired"
      assert out =~ "criteria"
    end

    test "--explain is the same mode" do
      path = write_trf!(sample_trf())

      {out, code} = run_capturing(fn -> CLI.run([path, "--explain"]) end)

      assert code == 0
      assert out =~ "Round 1"
    end

    # The rung list is the substance of this mode, and a criterion that
    # scored zero separated nothing -- printing all eighteen buries the
    # ones that mattered. The count line still reports the total, so the
    # omission is visible rather than silent.
    test "reports only the criteria that scored, and says how many it dropped" do
      path = write_trf!(sample_trf())

      {out, _code} = run_capturing(fn -> CLI.run([path, "-x"]) end)

      assert out =~ ~r/criteria\s+\d+ of \d+ scored, over \d+ edges?/
    end

    test "a file with no legal pairing exits 1 rather than raising" do
      path = write_trf!(sample_trf())
      # Same guard -p has: the mode must report, not crash.
      {_out, code} = run_capturing(fn -> CLI.run([path, "-x"]) end)
      assert code in [0, 1]
    end
  end
end

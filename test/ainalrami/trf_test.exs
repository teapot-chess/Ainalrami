defmodule Ainalrami.TrfTest do
  use ExUnit.Case, async: true

  alias Ainalrami.Trf

  # Column numbers are 1-indexed inclusive, straight from the FIDE spec.
  defp col(line, start, stop), do: String.slice(line, start - 1, stop - start + 1)

  defp sample do
    %{
      tournament: %{
        name: "Test Open 2026",
        city: "Ghent",
        federation: "BEL",
        start_date: "2026-07-01",
        end_date: "2026-07-05",
        type: "swiss",
        chief_arbiter: "Jorian Burssens",
        deputy_arbiters: ["Assistant One"],
        time_control: "90+30",
        round_dates: ["2026-07-01", "2026-07-02", "2026-07-03"]
      },
      players: [
        %{
          rank: 1,
          sex: "m",
          title: "GM",
          name: "Carlsen, Magnus",
          fide_rating: 2823,
          federation: "NOR",
          fide_number: 1_503_014,
          birth_date: "1990-11-30",
          points: 2.5,
          games: [
            %{opponent_rank: 2, colour: "w", result: "1"},
            %{opponent_rank: 3, colour: "b", result: "="},
            %{opponent_rank: nil, colour: nil, result: "U"}
          ]
        },
        %{
          rank: 2,
          sex: "w",
          title: "",
          name: "Vandekerckhove, Ava",
          fide_rating: 1674,
          federation: "BEL",
          fide_number: 207_918,
          birth_date: "1990-01-01",
          points: 0.0,
          games: [
            %{opponent_rank: 1, colour: "b", result: "0"},
            %{opponent_rank: 3, colour: "w", result: "0"},
            %{opponent_rank: 2, colour: nil, result: "Z"}
          ]
        }
      ]
    }
  end

  test "header lines use the code + free-text layout" do
    lines = sample() |> Trf.serialize() |> String.split("\r\n")

    assert Enum.at(lines, 0) == "012 Test Open 2026"
    assert Enum.at(lines, 1) == "022 Ghent"
    assert Enum.at(lines, 2) == "032 BEL"
    assert Enum.at(lines, 3) == "042 2026/07/01"
    assert Enum.at(lines, 4) == "052 2026/07/05"
  end

  test "player line matches the exact FIDE TRF16 column positions" do
    line =
      sample()
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&(String.starts_with?(&1, "001") and &1 =~ "Carlsen"))

    assert col(line, 1, 3) == "001"
    assert col(line, 5, 8) |> String.trim() == "1"
    assert col(line, 10, 10) == "m"
    assert col(line, 11, 13) |> String.trim() == "GM"
    assert col(line, 15, 47) |> String.trim() == "Carlsen, Magnus"
    assert col(line, 49, 52) |> String.trim() == "2823"
    assert col(line, 54, 56) == "NOR"
    assert col(line, 58, 68) |> String.trim() == "1503014"
    assert col(line, 70, 79) == "1990/11/30"
    assert col(line, 81, 84) == " 2.5"
    assert col(line, 86, 89) |> String.trim() == "1"

    # Round 1: opponent 2, colour w, result 1 (win)
    assert col(line, 92, 95) |> String.trim() == "2"
    assert col(line, 97, 97) == "w"
    assert col(line, 99, 99) == "1"

    # Round 2: opponent 3, colour b, result = (draw)
    assert col(line, 102, 105) |> String.trim() == "3"
    assert col(line, 107, 107) == "b"
    assert col(line, 109, 109) == "="

    # Round 3: pairing-allocated bye -> opponent 0000, colour '-', result U
    assert col(line, 112, 115) == "0000"
    assert col(line, 117, 117) == "-"
    assert col(line, 119, 119) == "U"
  end

  test "a control character in a name can't split or inject a TRF line" do
    # A player name has no format check beyond length, so it can carry a
    # newline/CR/tab. TRF is line- and column-oriented and this text is
    # written to a pairing engine's input file, so an unstripped newline
    # would break the row into two - corrupting the parse or injecting a
    # line.
    data = put_in(sample(), [:players, Access.at(0), :name], "Ev\r\nil\t001 injected")

    lines = Trf.serialize(data) |> String.split("\r\n")
    player_lines = Enum.filter(lines, &String.starts_with?(&1, "001"))

    # Still exactly one 001 line per player (2 in the sample), none injected.
    assert length(player_lines) == 2

    carlsen_replacement = Enum.find(player_lines, &(&1 =~ "Ev"))
    refute carlsen_replacement =~ "\n"
    refute carlsen_replacement =~ "\t"
    # The controls became spaces, so the name field stays inside its columns.
    assert col(carlsen_replacement, 15, 47) |> String.trim() =~ ~r/^Ev  il 001 injected$/
  end

  test "control bytes are flattened exactly as the old per-field regex did" do
    # The writer used to run `String.replace(v, ~r/[\x00-\x1F\x7F]/, " ")`
    # on every field and now scans bytes instead. Byte for byte the same:
    # a name already flattened by that regex must serialize to the same
    # file as the raw name, for every byte value, alone and next to
    # multibyte characters.
    flatten = &String.replace(&1, ~r/[\x00-\x1F\x7F]/, " ")
    :rand.seed(:exsss, {7, 8, 9})

    names =
      [for(b <- 0..255, into: <<>>, do: <<b>>), "Đurić\u0007x", "\x7F", "", "plain"] ++
        for _ <- 1..200 do
          for _ <- 1..Enum.random(0..40)//1, into: <<>> do
            Enum.random([<<Enum.random(0..255)>>, "é", "Ł", <<Enum.random(0..31)>>, "\x7F"])
          end
        end

    for name <- names do
      raw = put_in(sample(), [:players, Access.at(0), :name], name)
      flat = put_in(sample(), [:players, Access.at(0), :name], flatten.(name))
      assert Trf.serialize(raw) == Trf.serialize(flat), inspect(name)
    end
  end

  test "a blank result still occupies its column, so the round block is whole" do
    # `render/1` trims trailing whitespace, which every other line here
    # wants and a `001` line with games does not. A blank result column
    # takes the separator at `base + 6` down with it and the line ends two
    # columns short of the round block.
    #
    # bbpPairings refuses the whole FILE for it, not just the round.
    # `trf.cpp:189-191` only enters a round block while
    # `startIndex <= line.size() - 8`, so the short block is never read, and
    # `trf.cpp:352-355` then finds the leftover non-space characters and
    # throws `InvalidLineException`. Verified by direct invocation: the
    # trimmed file exits 3 with `Invalid line`, the padded one exits 0 and
    # pairs the round.
    data = %{
      tournament: %{name: "Blank", type: "swiss"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 1.0,
          games: [
            %{opponent_rank: 2, colour: "w", result: "1"},
            %{opponent_rank: nil, colour: nil, result: nil}
          ]
        },
        %{
          rank: 2,
          name: "B",
          points: 0.0,
          games: [
            %{opponent_rank: 1, colour: "b", result: "0"},
            %{opponent_rank: nil, colour: nil, result: "H"}
          ]
        }
      ]
    }

    [blank_line, filled_line] =
      Trf.serialize(data)
      |> String.split("\r\n")
      |> Enum.filter(&String.starts_with?(&1, "001"))

    # Round 2 is columns 102-109: id 102-105, colour 107, result 109.
    assert String.length(blank_line) == 109
    assert String.length(filled_line) == 109
    assert col(blank_line, 102, 105) == "0000"
    assert col(blank_line, 107, 107) == "-"
    assert col(blank_line, 109, 109) == " "
    assert col(filled_line, 109, 109) == "H"
  end

  # The pad above is only worth writing if it survives being read back.
  # `parse_games/1` measured the line AFTER trimming trailing whitespace,
  # which deleted exactly that pad, so a round already paired but not yet
  # played measured short and was dropped. A caller that writes a round's
  # pairings to a TRF and parses them again - which is how the sibling app
  # talks to this engine - then saw the round as still open and paired it a
  # SECOND time, producing different boards for a round already published.
  test "a round that is paired but not yet played survives a round trip" do
    data = %{
      tournament: %{name: "Paired", type: "swiss"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 1.0,
          games: [
            %{opponent_rank: 2, colour: "w", result: "1"},
            %{opponent_rank: 2, colour: "b", result: nil}
          ]
        },
        %{
          rank: 2,
          name: "B",
          points: 0.0,
          games: [
            %{opponent_rank: 1, colour: "b", result: "0"},
            %{opponent_rank: 1, colour: "w", result: nil}
          ]
        }
      ]
    }

    parsed = Trf.parse(Trf.serialize(data))

    assert Enum.map(parsed.players, &length(&1.games)) == [2, 2]

    assert Enum.at(Enum.at(parsed.players, 0).games, 1) ==
             %{opponent_rank: 2, colour: "b", result: nil}
  end

  # The other half of the same rule: dropping the trim must not turn a
  # ragged tail into a phantom round. A block with no opponent, no colour
  # and no result says nothing, so it is not a round.
  test "a wholly blank trailing block is not read as a round" do
    data = %{
      tournament: %{name: "Ragged", type: "swiss"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 1.0,
          games: [
            %{opponent_rank: 2, colour: "w", result: "1"},
            %{opponent_rank: nil, colour: nil, result: nil}
          ]
        },
        %{
          rank: 2,
          name: "B",
          points: 0.0,
          games: [
            %{opponent_rank: 1, colour: "b", result: "0"},
            %{opponent_rank: nil, colour: nil, result: "H"}
          ]
        }
      ]
    }

    parsed = Trf.parse(Trf.serialize(data))

    # B's round 2 is a recorded half-point bye and stays; A's is empty.
    assert Enum.map(parsed.players, &length(&1.games)) == [1, 2]
  end

  test "a player with no games at all is not padded out to a round block" do
    # The trim is right for every OTHER line, and for a `001` line that
    # carries no games: a round-one roster ends at the rank column.
    data = put_in(sample(), [:players, Access.at(0), :games], [])
    data = put_in(data, [:players, Access.at(1), :games], [])

    for line <- Trf.serialize(data) |> String.split("\r\n"),
        String.starts_with?(line, "001") do
      assert String.length(line) == 89
    end
  end

  test "082 (number of teams) is always emitted, even 0 for an individual tournament" do
    lines = sample() |> Trf.serialize() |> String.split("\r\n")
    assert Enum.any?(lines, &(&1 == "082 0"))
  end

  test "082 reflects the real team count when teams are present" do
    data =
      sample()
      |> Map.put(:teams, [%{name: "A", player_ranks: [1]}, %{name: "B", player_ranks: [2]}])

    lines = Trf.serialize(data) |> String.split("\r\n")
    assert Enum.any?(lines, &(&1 == "082 2"))
  end

  test "132 (round dates) is omitted when every round in the list is blank/nil" do
    data = put_in(sample(), [:tournament, :round_dates], [nil, "", nil])
    lines = Trf.serialize(data) |> String.split("\r\n")
    refute Enum.any?(lines, &String.starts_with?(&1, "132"))
  end

  test "132 (round dates) is still emitted, with blanks for missing rounds, when at least one date is set" do
    data = put_in(sample(), [:tournament, :round_dates], [nil, "2026-07-02", nil])

    line =
      Trf.serialize(data) |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "132"))

    assert col(line, 92, 99) == "        "
    assert col(line, 102, 109) == "26/07/02"
  end

  test "round-dates (132) line places YY/MM/DD at the round-block columns" do
    line =
      sample()
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&String.starts_with?(&1, "132"))

    assert col(line, 92, 99) == "26/07/01"
    assert col(line, 102, 109) == "26/07/02"
    assert col(line, 112, 119) == "26/07/03"
  end

  test "parse/1 is the inverse of serialize/1 for header + player data" do
    parsed = sample() |> Trf.serialize() |> Trf.parse()

    assert parsed.tournament[:name] == "Test Open 2026"
    assert parsed.tournament[:city] == "Ghent"
    assert parsed.tournament[:federation] == "BEL"
    assert parsed.tournament[:start_date] == "2026-07-01"
    assert parsed.tournament[:end_date] == "2026-07-05"
    assert parsed.tournament.deputy_arbiters == ["Assistant One"]
    assert parsed.tournament[:time_control] == "90+30"
    assert parsed.tournament[:round_dates] == ["2026-07-01", "2026-07-02", "2026-07-03"]

    assert length(parsed.players) == 2
    [magnus | _] = parsed.players
    assert magnus.rank == 1
    assert magnus.sex == "m"
    assert magnus.title == "GM"
    assert magnus.name == "Carlsen, Magnus"
    assert magnus.fide_rating == 2823
    assert magnus.federation == "NOR"
    assert magnus.fide_number == 1_503_014
    assert magnus.birth_date == "1990-11-30"
    assert magnus.points == 2.5

    assert magnus.games == [
             %{opponent_rank: 2, colour: "w", result: "1"},
             %{opponent_rank: 3, colour: "b", result: "="},
             %{opponent_rank: nil, colour: nil, result: "U"}
           ]
  end

  test "teams are serialized and parsed with correct player-slot columns" do
    data = sample() |> Map.put(:teams, [%{name: "KGSRL Gent", player_ranks: [1, 2]}])
    trf = Trf.serialize(data)
    line = trf |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "013"))

    assert col(line, 1, 3) == "013"
    assert col(line, 5, 36) |> String.trim() == "KGSRL Gent"
    assert col(line, 37, 40) |> String.trim() == "1"
    assert col(line, 42, 45) |> String.trim() == "2"

    parsed = Trf.parse(trf)
    assert parsed.teams == [%{name: "KGSRL Gent", player_ranks: [1, 2]}]
  end

  test "a name longer than 33 characters is truncated, not overflowed into the rating field" do
    data = %{
      tournament: %{name: "T"},
      players: [%{rank: 1, name: String.duplicate("A", 50), points: 0.0, games: []}]
    }

    line =
      data
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&String.starts_with?(&1, "001"))

    assert col(line, 15, 47) == String.duplicate("A", 33)
    assert col(line, 48, 48) == " "
  end

  ## ---------- result validation ----------

  # Two players paired against each other for round 1, with the given TRF
  # result codes on each side.
  defp two_player_round(result_a, result_b) do
    %{
      tournament: %{name: "T"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 0.0,
          games: [%{opponent_rank: 2, colour: "w", result: result_a}]
        },
        %{
          rank: 2,
          name: "B",
          points: 0.0,
          games: [%{opponent_rank: 1, colour: "b", result: result_b}]
        }
      ]
    }
  end

  defp set_char(line, col, char) do
    {a, rest} = String.split_at(line, col - 1)
    <<_::binary-size(1), b::binary>> = rest
    a <> char <> b
  end

  test "serialize/1 raises when both players claim a win" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("1", "1") |> Trf.serialize()
    end
  end

  test "serialize/1 raises when both players are marked forfeit-win" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("+", "+") |> Trf.serialize()
    end
  end

  test "serialize/1 raises when a played result is paired with a mismatched score (win vs draw)" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("1", "=") |> Trf.serialize()
    end
  end

  test "serialize/1 raises on a result code that isn't in the TRF16 spec" do
    assert_raise Trf.ValidationError, ~r/unrecognized TRF result code/, fn ->
      two_player_round("X", "0") |> Trf.serialize()
    end
  end

  test "serialize/1 accepts a played 0-0 (both players score a loss, code '0' for both)" do
    trf = two_player_round("0", "0") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 accepts the VCL.13 asymmetric result ('=' vs '0', an arbiter's disciplinary point adjustment)" do
    trf = two_player_round("=", "0") |> Trf.serialize()
    assert trf =~ "001"

    # And the mirror image - the other side gets the ½.
    trf2 = two_player_round("0", "=") |> Trf.serialize()
    assert trf2 =~ "001"
  end

  test "serialize/1 still rejects '=' paired with anything other than '=' or '0'" do
    assert_raise Trf.ValidationError, fn -> two_player_round("=", "1") |> Trf.serialize() end
    assert_raise Trf.ValidationError, fn -> two_player_round("=", "+") |> Trf.serialize() end
  end

  test "serialize/1 accepts a double forfeit ('-' for both sides)" do
    trf = two_player_round("-", "-") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 accepts a single forfeit ('+' vs '-')" do
    trf = two_player_round("+", "-") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 does not flag a dangling/unresolvable opponent reference as illegal" do
    # Round 1's opponent (rank 2) doesn't exist in this single-player roster -
    # that's a caller concern (e.g. a partial player card), not a result
    # validation error.
    data = %{
      tournament: %{name: "T"},
      players: [
        %{rank: 1, name: "A", points: 0.0, games: [%{opponent_rank: 2, colour: "w", result: "1"}]}
      ]
    }

    assert Trf.serialize(data) =~ "001"
  end

  test "parse/1 also raises on an illegal result combination" do
    text = two_player_round("1", "0") |> Trf.serialize()
    lines = String.split(text, "\r\n")
    p2 = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "B"))

    # Round 1's result column is 99 (base 92 + 7) - see round_cols/1. Flip
    # player B's loss into a second win, making the round illegal.
    bad_p2 = set_char(p2, 99, "1")
    bad_text = lines |> Enum.map(&if &1 == p2, do: bad_p2, else: &1) |> Enum.join("\r\n")

    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      Trf.parse(bad_text)
    end
  end

  test "serialize/1 raises when opponent 0000 carries a played-game result code" do
    data = %{
      tournament: %{name: "T"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 1.0,
          games: [%{opponent_rank: nil, colour: nil, result: "1"}]
        }
      ]
    }

    assert_raise Trf.ValidationError, ~r/opponent 0000 cannot carry played-game result/, fn ->
      Trf.serialize(data)
    end
  end

  test "serialize/1 accepts a legitimate bye code (F/H/Z/U) with no opponent" do
    for code <- ["F", "H", "Z", "U"] do
      data = %{
        tournament: %{name: "T"},
        players: [
          %{
            rank: 1,
            name: "A",
            points: 1.0,
            games: [%{opponent_rank: nil, colour: nil, result: code}]
          }
        ]
      }

      assert Trf.serialize(data) =~ "001"
    end
  end

  test "parse/1 succeeds on a legal round-trip" do
    text = two_player_round("+", "-") |> Trf.serialize()
    parsed = Trf.parse(text)
    [a, b] = parsed.players
    assert a.games == [%{opponent_rank: 2, colour: "w", result: "+"}]
    assert b.games == [%{opponent_rank: 1, colour: "b", result: "-"}]
  end

  # ---------------------------------------------------------------------
  # TRF06 (FIDE's Annexure-B, 2006) - column-identical to TRF16, but
  # predates the F/H/U/Z bye codes: a bye is a dangling playing code
  # against opponent 0000, and a "not paired" round is left fully blank
  # rather than carrying any code at all (VCL.11 recommends, not requires,
  # supporting this older version).
  # ---------------------------------------------------------------------

  # Places `text` at 1-indexed `col` in `line`, padding with spaces as
  # needed - exact column math, so these fixtures can't suffer the same
  # off-by-a-few-spaces mistake a hand-typed fixed-width string risks.
  defp place_col(line, position, text) do
    text = to_string(text)
    needed = position - 1 + String.length(text)
    line = if String.length(line) < needed, do: String.pad_trailing(line, needed), else: line
    {before, rest} = String.split_at(line, position - 1)
    {_, after_} = String.split_at(rest, String.length(text))
    before <> text <> after_
  end

  defp round_block(line, round_number, opponent, colour, result) do
    base = 92 + (round_number - 1) * 10

    line
    |> place_col(base, (opponent && String.pad_leading(to_string(opponent), 4)) || "0000")
    |> place_col(base + 5, colour || "-")
    |> place_col(base + 7, result || "")
  end

  test "parse/1 tolerates a TRF06-vintage dangling playing code (bye with no F/H/U/Z code) that serialize/1 rejects" do
    line =
      ""
      |> place_col(1, "001")
      |> place_col(5, "   1")
      |> place_col(15, "Solo, Player")
      |> place_col(81, " 1.0")
      |> place_col(86, "   1")
      |> round_block(1, nil, nil, "1")

    parsed = Trf.parse(line <> "\r\n")
    assert [%{games: [%{opponent_rank: nil, colour: nil, result: "1"}]}] = parsed.players

    # The exact same shape is still correctly rejected on the way OUT - our
    # own pairing-input construction must never write this.
    assert_raise Trf.ValidationError, fn ->
      Trf.serialize(%{
        tournament: %{name: "T"},
        players: [
          %{
            rank: 1,
            name: "A",
            points: 1.0,
            games: [%{opponent_rank: nil, colour: nil, result: "1"}]
          }
        ]
      })
    end
  end

  test "parse/1 doesn't stop at a genuinely blank round when real rounds follow (a late entrant's TRF06-style gap)" do
    # Round 1 is entirely blank ("not paired", TRF06's own convention for a
    # late entrant) - round 2 is a real game. Not a hypothetical: the
    # sibling project's parser, which this one was taken from, stopped at
    # the first blank round and silently dropped round 2, and this is the
    # test that found it.
    line =
      ""
      |> place_col(1, "001")
      |> place_col(5, "   1")
      |> place_col(15, "Late, Entrant")
      |> place_col(81, " 1.0")
      |> place_col(86, "   1")
      |> round_block(2, 2, "b", "1")

    parsed = Trf.parse(line <> "\r\n")

    assert [%{games: [blank, real]}] = parsed.players
    assert blank == %{opponent_rank: nil, colour: nil, result: nil}
    assert real == %{opponent_rank: 2, colour: "b", result: "1"}
  end

  describe "line endings" do
    # Real bbpPairings writes its generated TRFs with a BARE `\r` and no
    # `\n` at all - 212 of them in a 209-player file, zero newlines. The
    # splitter was `~r/\r?\n/`, which matches neither, so the whole file
    # parsed as ONE line and `parse/1` returned zero players without
    # complaint.
    #
    # So this engine could not read the reference implementation's own
    # output, and no test could have seen it: the comparison harness only
    # ever feeds OUR files to THEM. Found by generating a tournament with
    # `bbpPairings --dutch -g -o` and reading it back - on which, once
    # fixed, the two engines agree on all 105 boards including colour.
    for {label, ending} <- [{"CRLF", "\r\n"}, {"LF", "\n"}, {"bare CR", "\r"}] do
      test "a file terminated with #{label} parses" do
        ending = unquote(ending)

        text =
          Enum.join(
            [
              "012 Endings",
              "062 2",
              "142 5",
              "001    1 m  gm Alpha                            2400 BEL     1000001 1990/01/01  1.0    1     2 w 1",
              "001    2 m  gm Beta                             2300 BEL     1000002 1990/01/01  0.0    2     1 b 0"
            ],
            ending
          ) <> ending

        parsed = Ainalrami.Trf.parse(text)

        assert length(parsed.players) == 2
        assert parsed.tournament[:number_of_rounds] == 5

        first = Enum.find(parsed.players, &(&1[:rank] == 1))
        assert first[:points] == 1.0
        assert [%{opponent_rank: 2, colour: "w", result: "1"}] = first[:games]
      end
    end

    test "a mixture of endings in one file still parses" do
      # Not merely tidiness: a file written by one tool and appended to by
      # another carries both, which is exactly how the interop case above
      # was reproduced (an `XXR` line added to a bare-CR file).
      text =
        "012 Mixed\r" <>
          "062 2\n" <>
          "001    1 m  gm Alpha                            2400 BEL     1000001 1990/01/01  0.0    1\r\n" <>
          "001    2 m  gm Beta                             2300 BEL     1000002 1990/01/01  0.0    2\r" <>
          "142 5\n"

      parsed = Ainalrami.Trf.parse(text)

      assert length(parsed.players) == 2
      assert parsed.tournament[:number_of_rounds] == 5
    end
  end

  describe "mutual opponent references" do
    @asym """
    012 Probe
    XXR 5
    001    1      A                                2000                             0.0    1      2 w 1
    001    2      B                                1900                             0.0    2      3 b 0
    001    3      C                                1800                             0.0    3      2 w 1
    001    4      D                                1700                             0.0    4      0 - U
    """

    test "a game that the opponent's line does not return is refused" do
      assert_raise Ainalrami.Trf.ValidationError,
                   ~r/round 1: A lists 2 as opponent, but 2 lists 3/,
                   fn -> Ainalrami.Trf.parse(@asym) end
    end

    test "a consistent history parses" do
      text =
        @asym
        |> String.replace("2      3 b 0", "2      1 b 0")
        |> String.replace("3      2 w 1", "3      4 w 1")
        |> String.replace("4      0 - U", "4      3 b 0")

      assert %{players: [_, _, _, _]} = Ainalrami.Trf.parse(text)
    end
  end

  describe "XXR (JaVaFo's round-count extension)" do
    # A two-player roster plus whatever extension lines the test wants.
    defp roster_trf(extra) do
      Ainalrami.Trf.serialize(%{
        tournament: %{name: "XXR Test", type: "swiss"},
        players: [
          %{rank: 1, name: "A", fide_rating: 2000, points: 0.0, games: []},
          %{rank: 2, name: "B", fide_rating: 1900, points: 0.0, games: []}
        ]
      }) <> extra
    end

    test "supplies the round count when the file carries no 142 line" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXR 9\r\n"))

      assert parsed.tournament[:number_of_rounds] == 9
    end

    test "142 and XXR agreeing is ordinary" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "XXR Test", type: "swiss", number_of_rounds: 5},
          players: [
            %{rank: 1, name: "A", fide_rating: 2000, points: 0.0, games: []},
            %{rank: 2, name: "B", fide_rating: 1900, points: 0.0, games: []}
          ]
        }) <> "XXR 5\r\n"

      assert Ainalrami.Trf.parse(text).tournament[:number_of_rounds] == 5
    end

    # This used to assert `142` silently won, which was deliberate and
    # documented - and wrong. Every implementation picks a winner and they
    # do not agree on which: bbpPairings takes whichever line comes LAST
    # (`trf.cpp:1117-1124` assigns `expectedRounds` from either prefix), so
    # `142 5` plus `XXR 9` was read here as 5 and there as 9.
    #
    # The round count feeds the final-round exception in
    # `colour_compatible?/2` and the topscorer threshold, so the loser of
    # that silent choice is a complete, perfectly legal-LOOKING final round
    # paired under the wrong rules, which nothing downstream can detect.
    # Same argument as `XXP`: a self-contradictory file has no correct
    # pairing, only two plausible ones, so it is refused.
    test "142 and XXR disagreeing is refused rather than silently resolved" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "XXR Test", type: "swiss", number_of_rounds: 5},
          players: [
            %{rank: 1, name: "A", fide_rating: 2000, points: 0.0, games: []},
            %{rank: 2, name: "B", fide_rating: 1900, points: 0.0, games: []}
          ]
        }) <> "XXR 9\r\n"

      assert_raise Ainalrami.Trf.ValidationError, ~r/two different round counts/, fn ->
        Ainalrami.Trf.parse(text)
      end
    end

    test "a malformed XXR is ignored rather than failing the parse" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXR banana\r\n"))

      assert parsed.tournament[:number_of_rounds] == nil
      assert length(parsed.players) == 2
    end
  end

  describe "XXP (JaVaFo's forbidden-pairings extension)" do
    test "reads one line as a group of starting ranks" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXP 1 2\r\n"))

      assert parsed.tournament[:forbidden_pairs] == [[1, 2]]
    end

    # `readForbiddenPairsXxp` (`trf.cpp:554-568`) tokenizes the whole rest
    # of the line, so one line can name any number of players and forbids
    # every pair within the group. Tab is a separator too.
    test "reads an N-player group, space- or tab-separated" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXP 1\t2  1\r\n"))

      assert parsed.tournament[:forbidden_pairs] == [[1, 2, 1]]
    end

    test "collects several lines" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXP 1 2\r\nXXP 2 1\r\n"))

      assert parsed.tournament[:forbidden_pairs] == [[1, 2], [2, 1]]
    end

    test "a file with no XXP line has no forbidden_pairs key at all" do
      refute Map.has_key?(Ainalrami.Trf.parse(roster_trf("")).tournament, :forbidden_pairs)
    end

    # Unlike XXR next door, this RAISES. An unreadable exclusion has no
    # safe fallback: silently dropping it yields a complete, legal-looking
    # pairing that seats two players an arbiter said must never meet.
    test "a malformed XXP raises rather than being skipped" do
      assert_raise Ainalrami.Trf.ValidationError, ~r/not a starting rank/, fn ->
        Ainalrami.Trf.parse(roster_trf("XXP 1 banana\r\n"))
      end
    end

    # "banana" was caught only because it has no leading digit. The token
    # parser threw its remainder away, so every SEPARATOR an arbiter might
    # reasonably reach for read as a single id, the line then failed the
    # "names fewer than two players" test one line down, and the exclusion
    # was discarded in silence - the one outcome the test above exists to
    # make impossible.
    test "a separator that is not a space raises rather than dropping the pair" do
      for line <- ["XXP 1,2\r\n", "XXP 1;2\r\n", "XXP 1-2\r\n", "XXP 1/2\r\n", "XXP 3x 4\r\n"] do
        assert_raise Ainalrami.Trf.ValidationError, ~r/not a starting rank/, fn ->
          Ainalrami.Trf.parse(roster_trf(line))
        end
      end
    end

    test "round-trips through serialize" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "T", type: "swiss", forbidden_pairs: [[1, 2], [1, 2, 3]]},
          players: [%{rank: 1, name: "A", points: 0.0, games: []}]
        })

      assert Ainalrami.Trf.parse(text).tournament[:forbidden_pairs] == [[1, 2], [1, 2, 3]]
    end
  end

  describe "XXA (JaVaFo's acceleration extension)" do
    # The columns are the whole story here - see `@xxa_rank_cols`. Asserted
    # explicitly because a one-column drift is invisible to a round-trip
    # test (this parser and this serializer would simply agree on the wrong
    # answer) and is exactly the mistake the sibling project made.
    test "emits the fixed columns the spec and bbpPairings both require" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "T", type: "swiss"},
          players: [
            %{rank: 12, name: "A", points: 0.0, games: [], accelerations: [1.0, 0.5, 0.0]}
          ]
        })

      line = text |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "XXA"))

      assert col(line, 1, 3) == "XXA"
      assert col(line, 5, 8) == "  12"
      assert col(line, 10, 13) == " 1.0"
      assert col(line, 15, 18) == " 0.5"
      assert col(line, 20, 23) == " 0.0"
    end

    test "attaches the values to the player it names" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXA    2  1.0  0.5\r\n"))

      assert [%{rank: 1} = first, %{rank: 2} = second] = parsed.players
      refute Map.has_key?(first, :accelerations)
      assert second[:accelerations] == [1.0, 0.5]
    end

    # bbpPairings pre-sizes `tournament.players` from the XXA line and
    # moves the accelerations onto the real record when the 001 line
    # arrives (`trf.cpp:369-372`), so order cannot matter.
    test "an XXA line before the player's own 001 line still lands" do
      text = "012 T\r\nXXA    1  1.0\r\n" <> roster_trf("")

      assert [%{accelerations: [1.0]}, _] = Ainalrami.Trf.parse(text).players
    end

    # `startIndex + 4 <= line.size()` (`trf.cpp:501`): a blank slot that is
    # fully present reads as zero rather than ending the record.
    test "a blank but present slot reads as zero" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXA    1  1.0       0.5\r\n"))

      assert [first, _second] = parsed.players
      assert first[:accelerations] == [1.0, 0.0, 0.5]
    end

    # `push_back` onto the player's existing record (`trf.cpp:510`), and
    # `tournament.players[id]` persists between lines - so a second line
    # for the same player CONTINUES the record rather than replacing it.
    test "two XXA lines for one player append rather than the second winning" do
      parsed = Ainalrami.Trf.parse(roster_trf("XXA    1  1.0\r\nXXA    1  0.5\r\n"))

      assert [first, _second] = parsed.players
      assert first[:accelerations] == [1.0, 0.5]
    end

    test "a file with no XXA line leaves every player without the key" do
      assert Enum.all?(
               Ainalrami.Trf.parse(roster_trf("")).players,
               &(not Map.has_key?(&1, :accelerations))
             )
    end

    # The sibling project's own emitter right-aligns the rank in a
    # FIVE-column field, which puts it in columns 5-9 rather than 5-8. Real
    # bbpPairings rejects such a line outright (`Invalid line "XXA     1
    # ..."`, exit code 3, reproduced directly against the vendored binary),
    # and this must not quietly pair an unaccelerated tournament instead.
    test "the sibling project's one-column-wide layout raises rather than being ignored" do
      assert_raise Ainalrami.Trf.ValidationError, ~r/columns 5-8/, fn ->
        Ainalrami.Trf.parse(roster_trf("XXA     1  1.0  1.0\r\n"))
      end
    end

    test "round-trips through serialize" do
      text =
        Ainalrami.Trf.serialize(%{
          tournament: %{name: "T", type: "swiss"},
          players: [%{rank: 3, name: "A", points: 0.0, games: [], accelerations: [1.0, 0.5, 0.0]}]
        })

      assert [player] = Ainalrami.Trf.parse(text).players
      assert player[:accelerations] == [1.0, 0.5, 0.0]
    end
  end

  describe "numeric_extensions: bbpPairings' fixed-column 250/260" do
    defp numeric(data), do: Ainalrami.Trf.serialize(data, numeric_extensions: true)

    defp sample_data do
      %{
        tournament: %{
          name: "T",
          number_of_rounds: 5,
          forbidden_pairs: [[1, 4]]
        },
        players:
          for r <- 1..4 do
            %{
              rank: r,
              name: "P#{r}",
              points: 0.0,
              games: [],
              accelerations: if(r == 2, do: [1.0], else: [])
            }
          end
      }
    end

    # The widths are bbpPairings' own, from readAccelerations250
    # (trf.cpp:418), which reads HALF-OPEN 0-based ranges with a blank
    # separator column between every field. The parser below reads each
    # field one column wider and trims, which is harmless on the way in and
    # was fatal on the way out: right-aligning into the wider field puts the
    # digit in the separator, and the real binary reads a blank round and
    # rejects the line. Same shape as the XXA column bug.
    test "a 250 line puts each field in bbpPairings' columns, not one wider" do
      line =
        sample_data()
        |> numeric()
        |> String.split("\r\n")
        |> Enum.find(&String.starts_with?(&1, "250"))

      assert String.slice(line, 4, 4) == "    ", "cols 5-8 are MATCH points and must be blank"
      assert String.slice(line, 9, 4) == " 1.0", "cols 10-13 are game points"
      assert String.slice(line, 14, 3) == "  1", "cols 15-17 are the first round"
      assert String.slice(line, 18, 3) == "  1", "cols 19-21 are the last round"
      assert String.slice(line, 22, 4) == "   2", "cols 23-26 are the first player"
      assert String.slice(line, 27, 4) == "   2", "cols 28-31 are the last player"
    end

    # XXP means "never pair these" and carries no round limit at all, so a
    # 260 bounded at number_of_rounds lets the ban EXPIRE on the round being
    # paired. Both files parse cleanly either way; the only symptom is that
    # the two spellings pair differently.
    test "a 260 line outlives the declared round count" do
      line =
        sample_data()
        |> numeric()
        |> String.split("\r\n")
        |> Enum.find(&String.starts_with?(&1, "260"))

      assert String.slice(line, 4, 3) == "  1"
      last = line |> String.slice(8, 3) |> String.trim() |> String.to_integer()
      assert last >= 5, "a forbidden pair must still be forbidden in the round being paired"
      assert String.slice(line, 12, 4) == "   1"
      assert String.slice(line, 17, 4) == "   4"
    end

    test "round-trips: what 250/260 write, parse/1 reads back" do
      parsed = sample_data() |> numeric() |> Ainalrami.Trf.parse()

      assert [{[1, 4], 1, _last}] = parsed.tournament[:forbidden_pairs]

      assert parsed.players |> Enum.map(& &1[:accelerations]) |> Enum.reject(&(&1 in [nil, []])) ==
               [[1.0]]
    end

    test "the XX spelling is still the default" do
      text = Ainalrami.Trf.serialize(sample_data())

      assert text =~ "XXP"
      assert text =~ "XXA"
      refute text =~ ~r/^250/m
      refute text =~ ~r/^260/m
    end
  end

  describe "ascii: true keeps the byte columns where the spec puts them" do
    # Deliberately NOT `col/3` above: that one slices graphemes, which is the
    # very assumption under test. A submitted TRF is read by byte.
    defp byte_col(line, start, stop), do: :binary.part(line, start - 1, stop - start + 1)

    defp first_player_line(trf) do
      trf |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "001"))
    end

    defp byte_roster(name) do
      %{
        tournament: %{name: "Byte Test", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: name,
            sex: "m",
            title: "",
            fide_rating: 2400,
            federation: "BEL",
            fide_number: 1001,
            birth_date: "1985-01-01",
            points: 1.0,
            games: [%{opponent_rank: 2, colour: "w", result: "1"}]
          },
          %{
            rank: 2,
            name: "Bravo, Bob",
            sex: "m",
            title: "",
            fide_rating: 2300,
            federation: "BEL",
            fide_number: 1002,
            birth_date: "1986-01-01",
            points: 0.0,
            games: [%{opponent_rank: 1, colour: "b", result: "0"}]
          }
        ]
      }
    end

    test "an accented name occupies the same byte columns as a plain one" do
      plain = "Hendricks, Bjorn" |> byte_roster() |> Trf.serialize(ascii: true)
      accented = "Hendricks, Björn" |> byte_roster() |> Trf.serialize(ascii: true)

      assert first_player_line(accented) == first_player_line(plain)

      # Spelled out, so a future reader sees which fields were at stake: the
      # FIDE id is the one that turns into a different player.
      line = first_player_line(accented)
      assert byte_col(line, 49, 52) == "2400"
      assert byte_col(line, 58, 68) == "       1001"
      assert byte_col(line, 81, 84) == " 1.0"
      assert byte_col(line, 92, 95) == "   2"
      assert byte_col(line, 97, 97) == "w"
      assert byte_col(line, 99, 99) == "1"
    end

    test "without the option the row keeps its byte columns and its accents" do
      line = "Hendricks, Björn" |> byte_roster() |> Trf.serialize() |> first_player_line()

      # One byte longer than it has characters - which used to be the whole
      # cause, back when `place/4` padded by grapheme: the name field then
      # ran a byte short and rating 2400 read as 240, FIDE id 1001 as 100,
      # the round history blank. `place/4` pads by byte now, so the accent
      # survives AND every later field is where the spec puts it. Sweep
      # 2026-09-01, H1.
      assert byte_size(line) == String.length(line) + 1

      assert line |> byte_col(15, 47) |> String.trim() == "Hendricks, Björn"
      assert byte_col(line, 49, 52) == "2400"
      assert byte_col(line, 58, 68) == "       1001"
      assert byte_col(line, 81, 84) == " 1.0"
      assert byte_col(line, 92, 95) == "   2"
      assert byte_col(line, 97, 97) == "w"
      assert byte_col(line, 99, 99) == "1"
    end

    test "folds the letters NFD alone cannot decompose" do
      line =
        "Weiß, Jörg-Ømer" |> byte_roster() |> Trf.serialize(ascii: true) |> first_player_line()

      assert line |> byte_col(15, 47) |> String.trim() == "Weiss, Jorg-Omer"
    end

    test "a non-Latin script becomes ? rather than silently shrinking the row" do
      line =
        "Карпов, Анатолий" |> byte_roster() |> Trf.serialize(ascii: true) |> first_player_line()

      assert byte_col(line, 15, 47) == String.pad_trailing("??????, ????????", 33)
      assert byte_col(line, 49, 52) == "2400"
    end

    test "no byte of a folded file is above 0x7F - headers and extensions included" do
      data =
        "Hendricks, Björn"
        |> byte_roster()
        |> put_in([:tournament], %{
          name: "Åre Öppna",
          city: "Liège",
          type: "swiss",
          chief_arbiter: "Nguyễn, Hoàng"
        })

      trf = Trf.serialize(data, ascii: true)

      refute trf =~ ~r/[^\x00-\x7F]/u
      assert trf =~ "012 Are Oppna"
      assert trf =~ "022 Liege"
      # "ễ" is e plus two combining marks, so NFD reaches it and no "?" is
      # needed - the fallback table is only for the letters that decompose
      # to nothing.
      assert trf =~ "102 Nguyen, Hoang"
    end
  end

  describe "column_legend: true" do
    # The legend was written for the sibling app's arbiter-facing export and
    # had no test in THIS repo at all: the only thing pinning ~50 lines of
    # `legend_line/1`, `legend_games/2` and `ruler_line/2` was one
    # `String.starts_with?(&1, "DDD SSSS sTTT")` over in
    # `openpairings/test/pairings_engine/trf_export_test.exs`. That
    # assertion cannot see the thing the legend exists to be: a ruler is
    # only useful if it lines up, and a legend whose `RRRR` sits one column
    # left of the rating field is worse than no legend, because it is the
    # thing a human checks a suspect file against.
    #
    # So these assert the alignment, not the text.
    defp legend_roster do
      %{
        tournament: %{name: "Legend", type: "swiss"},
        players: [
          %{
            rank: 1,
            name: "Alpha, Ann",
            sex: "w",
            title: "IM",
            fide_rating: 2400,
            federation: "BEL",
            fide_number: 1001,
            birth_date: "1985-01-01",
            points: 1.0,
            games: [
              %{opponent_rank: 2, colour: "w", result: "1"},
              %{opponent_rank: nil, colour: nil, result: "U"}
            ]
          },
          %{
            rank: 2,
            name: "Bravo, Bob",
            sex: "m",
            title: "",
            fide_rating: 2300,
            federation: "BEL",
            fide_number: 1002,
            birth_date: "1986-01-01",
            points: 0.0,
            games: [
              %{opponent_rank: 1, colour: "b", result: "0"},
              %{opponent_rank: nil, colour: nil, result: "H"}
            ]
          }
        ]
      }
    end

    defp legend_lines_of(data) do
      lines = data |> Trf.serialize(column_legend: true) |> String.split("\r\n")
      legend = Enum.find(lines, &String.starts_with?(&1, "DDD"))
      i = Enum.find_index(lines, &(&1 == legend))

      # Blank separator, tens ruler, units ruler, legend - in that order,
      # immediately before the first player row.
      %{
        blank: Enum.at(lines, i - 3),
        tens: Enum.at(lines, i - 2),
        units: Enum.at(lines, i - 1),
        legend: legend,
        first_player: Enum.at(lines, i + 1)
      }
    end

    test "every field code sits in the columns the player row uses" do
      %{legend: legend} = legend_lines_of(legend_roster())

      # 1-indexed inclusive, straight from the FIDE spec - the same numbers
      # `player line matches the exact FIDE TRF16 column positions` above
      # asserts against the real row.
      assert col(legend, 1, 3) == "DDD"
      assert col(legend, 5, 8) == "SSSS"
      assert col(legend, 10, 10) == "s"
      assert col(legend, 11, 13) == "TTT"
      assert col(legend, 15, 47) == String.duplicate("N", 33)
      assert col(legend, 49, 52) == "RRRR"
      assert col(legend, 54, 56) == "FFF"
      assert col(legend, 58, 68) == String.duplicate("I", 11)
      assert col(legend, 70, 79) == "BBBB/BB/BB"
      assert col(legend, 81, 84) == "PPPP"
      assert col(legend, 86, 89) == "RRRR"

      # Every gap the spec leaves between two fields is blank in the legend
      # too, so a marker that grew a column would show up here rather than
      # merging into its neighbour.
      for gap <- [4, 9, 14, 48, 53, 57, 69, 80, 85] do
        assert col(legend, gap, gap) == " ",
               "column #{gap} separates two fields and must be blank"
      end
    end

    test "the round blocks are marked with the round's own last digit" do
      %{legend: legend} = legend_lines_of(legend_roster())

      # Round 1 at 92-99, round 2 at 102-109 - the same 10-column cadence
      # the player row uses, and the digit says WHICH round, which is the
      # only way to count along a 20-round line without a finger.
      assert col(legend, 92, 95) == "1111"
      assert col(legend, 97, 97) == "1"
      assert col(legend, 99, 99) == "1"
      assert col(legend, 102, 105) == "2222"
      assert col(legend, 107, 107) == "2"
      assert col(legend, 109, 109) == "2"
    end

    test "the legend is exactly as wide as the player rows it describes" do
      %{legend: legend, tens: tens, units: units, first_player: player} =
        legend_lines_of(legend_roster())

      assert String.length(legend) == String.length(player)
      assert String.length(units) == String.length(legend)
      assert String.length(tens) == String.length(legend)
    end

    test "the two rulers count the columns they sit above" do
      %{blank: blank, tens: tens, units: units} = legend_lines_of(legend_roster())

      assert blank == ""

      # The units ruler repeats 1234567890, so the character at column N is
      # N's own last digit - the property that makes it a ruler rather than
      # decoration.
      for n <- [1, 9, 10, 47, 92, 109] do
        assert col(units, n, n) == n |> rem(10) |> Integer.to_string()
      end

      # The tens ruler labels each decade, right-aligned so the label ENDS
      # on the column it names: "1" at column 10, "10" across 99-100.
      assert col(tens, 10, 10) == "1"
      assert col(tens, 20, 20) == "2"
      assert col(tens, 99, 100) == "10"
      assert col(tens, 1, 9) == String.duplicate(" ", 9)
    end

    test "a reader still sees the same tournament through it" do
      # The whole safety argument for emitting these lines at all: they
      # carry no 3-digit code, so `parse_header_line/3`'s `nil -> acc`
      # clause drops them, and the blank one is rejected before that. If
      # that ever stopped being true the legend would corrupt every file it
      # was meant to make readable.
      data = legend_roster()

      assert Trf.parse(Trf.serialize(data, column_legend: true)) ==
               Trf.parse(Trf.serialize(data))
    end

    test "off by default" do
      text = Trf.serialize(legend_roster())

      refute text =~ "DDD SSSS"
      refute text =~ ~r/^1234567890/m
    end

    test "a roster with no rounds yet still gets its legend" do
      # This used to be guarded `when max_round > 0`, on the reasoning that a
      # ruler over a row stopping at the rank column would point at nothing.
      # It does not: the row still carries name, rating, federation, FIDE id,
      # birth date, points and rank, and a registration list is exactly when
      # somebody squints at whether a name has overrun its 33 characters.
      #
      # The other half of that reasoning - that the leading blank line could
      # trip a stricter reader - is true, and unchanged by round count: the
      # with-rounds case has always emitted it. It was never a reason to treat
      # a round-less file differently.
      text =
        Trf.serialize(
          %{
            tournament: %{name: "L", type: "swiss"},
            players: [%{rank: 1, name: "Alpha, Ann", points: 0.0, games: []}]
          },
          column_legend: true
        )

      assert text =~ "DDD SSSS sTTT"
      assert text =~ ~r/^1234567890/m

      # ...and it stops at the rank column, with no game blocks invented for
      # rounds that do not exist.
      legend =
        text
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "DDD"))

      refute legend =~ "1111"
    end
  end
end

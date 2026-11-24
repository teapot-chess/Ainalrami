defmodule Ainalrami.TrfSweep0901Test do
  @moduledoc """
  Regressions for the `docs/sweep-2026-09-01.md` findings that live in
  `Ainalrami.Trf`: H1 (columns by grapheme), H4 (BOM), H5 (partial round
  block), M3 (`initial_colour`), M4 (blank `142`), L1 (`XXA` trailing
  space), L3 (the error message's line code).
  """

  use ExUnit.Case, async: true

  alias Ainalrami.Trf

  # Builds a line by BYTE column, the way Swiss-Manager and bbpPairings
  # build one: `{column, text}` pairs in ascending column order, gaps
  # filled with spaces. Deliberately not built through `Trf.serialize/2`,
  # since the point of most of these tests is what a foreign writer emits.
  defp row(pairs) do
    Enum.reduce(pairs, "", fn {col, text}, acc ->
      pad = max(col - 1 - byte_size(acc), 0)
      acc <> String.duplicate(" ", pad) <> text
    end)
  end

  # A row whose round 1 is a whole `   2 w 1` block, followed by player 2's
  # own line for that game, so every opponent number `Trf.parse/1` reads
  # has a 001 line behind it.
  defp with_partner(line) do
    partner =
      row([
        {1, "001"},
        {5, "   2"},
        {15, "Partner"},
        {81, " 0.0"},
        {86, "   2"},
        {92, "   1"},
        {97, "b"},
        {99, "0"}
      ])

    line <> "\n" <> partner <> "\n"
  end

  defp player_row(name, extra \\ []) do
    row(
      [
        {1, "001"},
        {5, "   1"},
        {10, "m"},
        {15, name},
        {49, "2200"},
        {54, "GER"},
        {58, "    1001001"},
        {70, "1990/01/01"},
        {81, " 1.0"},
        {86, "   1"}
      ] ++ extra
    )
  end

  # ---------- H1 · columns are byte offsets ----------

  describe "H1 fixed columns are byte offsets, not grapheme offsets" do
    test "a byte-padded row with an accented name reads its later columns" do
      # "Björn" is 5 graphemes but 6 bytes, so a byte-padded name field
      # takes one padding space fewer than a grapheme-counting reader expects.
      name = "Hendricks, Björn"
      line = player_row(name, [{92, "   2"}, {97, "w"}, {99, "1"}])

      assert byte_size(line) == 99
      assert String.length(line) == 98

      %{players: [p, _partner]} = Trf.parse(with_partner(line))

      assert p.name == name
      assert p.fide_rating == 2200
      assert p.federation == "GER"
      assert p.games == [%{opponent_rank: 2, colour: "w", result: "1"}]
    end

    test "serialize then parse is lossless for accented names" do
      data = %{
        tournament: %{name: "Tournoi de Liège", number_of_rounds: 1},
        players: [
          %{
            rank: 1,
            name: "Hendricks, Björn",
            fide_rating: 2200,
            federation: "GER",
            points: 1.0,
            games: [%{opponent_rank: 2, colour: "w", result: "1"}]
          },
          %{
            rank: 2,
            name: "Müller-Šarić, Zoë",
            fide_rating: 2100,
            federation: "CRO",
            points: 0.0,
            games: [%{opponent_rank: 1, colour: "b", result: "0"}]
          }
        ]
      }

      text = Trf.serialize(data)
      back = Trf.parse(text)

      assert Enum.map(back.players, & &1.name) == ["Hendricks, Björn", "Müller-Šarić, Zoë"]
      assert Enum.map(back.players, & &1.fide_rating) == [2200, 2100]
      assert Enum.map(back.players, & &1.federation) == ["GER", "CRO"]

      assert Enum.map(back.players, & &1.games) == [
               [%{opponent_rank: 2, colour: "w", result: "1"}],
               [%{opponent_rank: 1, colour: "b", result: "0"}]
             ]

      # And the round trip is byte-exact, which is what the host app relies on.
      assert Trf.serialize(back) == text
    end

    test "an over-long multibyte name truncates on a grapheme boundary" do
      long = String.duplicate("é", 40)

      text =
        Trf.serialize(%{
          tournament: %{},
          players: [%{rank: 1, name: long, points: 0.0, games: []}]
        })

      assert String.valid?(text)
      # The name field is 33 BYTES: 16 whole "é" fit, and the 33rd byte -
      # half of the 17th - must not be emitted.
      assert Trf.parse(text).players |> hd() |> Map.fetch!(:name) == String.duplicate("é", 16)
    end

    test "existing ASCII fixtures serialize byte-identically to the 2026-09-01 baseline" do
      golden =
        "test/fixtures/serialize_golden.txt"
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.chunk_every(2)
        |> Map.new(fn [file, digest] -> {file, digest} end)

      assert map_size(golden) > 0

      for {file, expected} <- golden do
        actual =
          try do
            s = file |> File.read!() |> Trf.parse() |> Trf.serialize()
            Base.encode16(:crypto.hash(:sha256, s)) <> " " <> Integer.to_string(byte_size(s))
          rescue
            e -> "ERROR " <> inspect(e.__struct__)
          end

        assert actual == expected, "serialize output changed for #{file}"
      end
    end
  end

  # ---------- H4 · a leading BOM ----------

  describe "H4 a UTF-8 BOM" do
    test "does not swallow the first player line" do
      text =
        "﻿" <>
          player_row("Alpha") <>
          "\n" <>
          String.replace(player_row("Beta"), ~r/^001    1/, "001    2") <> "\n"

      assert %{players: [_, _]} = Trf.parse(text)
    end

    test "before a 012 header keeps the tournament name" do
      assert Trf.parse("﻿012 Open Championship\n").tournament[:name] == "Open Championship"
    end
  end

  # ---------- H5 · a partial trailing round block ----------

  describe "H5 a round block that is not whole" do
    setup do
      # Round one occupies columns 92-99 (id 92-95, colour 97, result 99).
      %{full: player_row("Alpha", [{92, "   2"}, {97, "w"}, {99, "1"}])}
    end

    test "a complete block is one round", %{full: full} do
      assert byte_size(full) == 99

      assert Trf.parse(with_partner(full)).players |> hd() |> Map.fetch!(:games) == [
               %{opponent_rank: 2, colour: "w", result: "1"}
             ]
    end

    test "truncation inside the block yields no round at all", %{full: full} do
      for len <- [90, 92, 93, 98] do
        cut = binary_part(full, 0, len)

        assert Trf.parse(cut).players |> hd() |> Map.fetch!(:games) == [],
               "length #{len} should contribute no round"
      end
    end

    test "a partial second block is ignored, not read short", %{full: full} do
      # Round two's block runs to column 109; stop at 107 and it is partial.
      two = full <> "  " <> "   3" <> " " <> "b"
      assert byte_size(two) == 107

      assert Trf.parse(with_partner(two)).players |> hd() |> Map.fetch!(:games) == [
               %{opponent_rank: 2, colour: "w", result: "1"}
             ]
    end
  end

  # ---------- M3 · initial_colour ----------

  describe "M3 initial_colour on the write side" do
    defp with_colour(colour) do
      Trf.serialize(%{
        tournament: %{initial_colour: colour},
        players: [%{rank: 1, name: "Alpha", points: 0.0, games: []}]
      })
    end

    test "accepts the long and mixed-case spellings" do
      for c <- ["w", "W", "white", "White", "WHITE"], do: assert(with_colour(c) =~ "152 W")
      for c <- ["b", "B", "black", "Black", "BLACK"], do: assert(with_colour(c) =~ "152 B")
    end

    test "raises a ValidationError, not a FunctionClauseError, on anything else" do
      assert_raise Trf.ValidationError, ~r/initial colour/, fn -> with_colour("green") end
    end
  end

  describe "xxc: true - the initial colour spelled for JaVaFo" do
    defp with_xxc(colour, opts) do
      Trf.serialize(
        %{
          tournament: %{initial_colour: colour},
          players: [%{rank: 1, name: "Alpha", points: 0.0, games: []}]
        },
        opts
      )
    end

    test "writes XXC white1 / black1 instead of 152, never both" do
      white = with_xxc("w", xxc: true)
      black = with_xxc("black", xxc: true)

      assert white =~ ~r/^XXC white1\r$/m
      assert black =~ ~r/^XXC black1\r$/m
      refute white =~ ~r/^152/m
      refute black =~ ~r/^152/m
    end

    test "round-trips through parse/1 to the same colour" do
      assert Trf.parse(with_xxc("b", xxc: true)).tournament[:initial_colour] == "b"
      assert Trf.parse(with_xxc("w", xxc: true)).tournament[:initial_colour] == "w"
    end

    test "writes nothing without a colour, and 152 without the option" do
      refute with_xxc(nil, xxc: true) =~ "XXC"
      assert with_xxc("b", []) =~ ~r/^152 B\r$/m
    end

    test "a bad colour still raises" do
      assert_raise Trf.ValidationError, ~r/initial colour/, fn -> with_xxc("green", xxc: true) end
    end

    test "the trf26 dialect keeps 152" do
      assert with_xxc("b", xxc: true, dialect: :trf26) =~ ~r/^152 B\r$/m
    end
  end

  # ---------- M4 · a blank 142 ----------

  describe "M4 an unparsable 142 value" do
    test "alone, asserts nothing about the round count" do
      refute Map.has_key?(Trf.parse("142\n").tournament, :number_of_rounds)
      refute Map.has_key?(Trf.parse("142  \n").tournament, :number_of_rounds)
      refute Map.has_key?(Trf.parse("142 abc\n").tournament, :number_of_rounds)
    end

    test "beside XXR, leaves XXR's count standing without a false disagreement" do
      assert Trf.parse("XXR 9\n142\n").tournament[:number_of_rounds] == 9
      assert Trf.parse("142\nXXR 9\n").tournament[:number_of_rounds] == 9
    end

    test "a real disagreement still raises" do
      assert_raise Trf.ValidationError, fn -> Trf.parse("XXR 9\n142 7\n") end
    end
  end

  # ---------- L1 · XXA trailing whitespace ----------

  describe "L1 trailing spaces on an XXA line" do
    test "do not invent a phantom round" do
      player = player_row("Alpha") <> "\n"
      xxa = "XXA    1  1.0"

      assert Trf.parse(player <> xxa <> "\n").players |> hd() |> Map.fetch!(:accelerations) ==
               [1.0]

      assert Trf.parse(player <> xxa <> "     \n").players
             |> hd()
             |> Map.fetch!(:accelerations) == [1.0]
    end
  end

  # ---------- L3 · the error message names the line ----------

  describe "L3 an unreadable range field" do
    test "a 250 player range says 250 and says player" do
      # Columns: 5-9 match points, 10-14 points, 15-18 / 19-22 rounds,
      # 23-27 / 28-32 the player range - "x" in the first player field.
      line =
        row([{1, "250"}, {10, "  0.5"}, {15, "   1"}, {19, "   2"}, {23, "    x"}, {28, "   5"}])

      err = assert_raise Trf.ValidationError, fn -> Trf.parse(line <> "\n") end

      assert err.message =~ "250"
      assert err.message =~ "player"
      refute err.message =~ "260"
    end

    test "a 260 round range still says 260 and says round" do
      line = row([{1, "260"}, {5, "  x"}, {9, "  1"}, {13, "   1"}, {18, "   2"}])
      err = assert_raise Trf.ValidationError, fn -> Trf.parse(line <> "\n") end
      assert err.message =~ "260"
      assert err.message =~ "round"
    end
  end
end

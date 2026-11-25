defmodule Ainalrami.SameColourGameTest do
  # Sweep 2026-11c, AIN5-2: a played game whose two lines give the same
  # colour. bbpPairings refuses the file (`validatePairConsistency`); the
  # reader here reads it, warns naming the round and both players, and
  # refuses it only when asked to be strict.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Log, Trf}

  setup do
    on_exit(fn -> Log.set_quiet(false) end)
  end

  # Round 1 played in full; P3's line says White against P1's White.
  @clash """
  012 Same colour
  XXR 5
  001    1      P1                                2400                             1.0    1     3 w 1
  001    2      P2                                2300                             1.0    2     4 b 1
  001    3      P3                                2200                             0.0    3     1 w 0
  001    4      P4                                2100                             0.0    4     2 w 0
  """

  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        capture_io(:stderr, fn -> Process.put(ref, CLI.run(args)) end) |> IO.write()
      end)

    {out, Process.get(ref)}
  end

  defp write_clash! do
    dir = Path.join(System.tmp_dir!(), "ain5-2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "clash.trf")
    File.write!(path, @clash)
    path
  end

  test "is read, with one warning naming the round and both players" do
    parsed = Trf.parse(@clash)

    assert [%{type: :same_colour, round: 1, ranks: {1, 3}, colour: "w", message: message}] =
             parsed.warnings

    assert message =~ "round 1: 1 (P1) and 3 (P3) both have White"
    assert length(parsed.players) == 4
  end

  test "a clean file has no :warnings key at all" do
    clean = String.replace(@clash, "3     1 w 0", "3     1 b 0")
    refute Map.has_key?(Trf.parse(clean), :warnings)
  end

  test "an unplayed game (a forfeit) is not the reader's concern" do
    forfeit =
      @clash
      |> String.replace("3 w 1", "3 w +")
      |> String.replace("1 w 0", "1 w -")

    refute Map.has_key?(Trf.parse(forfeit), :warnings)
  end

  test "strict: true refuses the file, naming the game" do
    assert_raise Trf.ValidationError, ~r/round 1: 1 \(P1\) and 3 \(P3\) both have White/, fn ->
      Trf.parse(@clash, strict: true)
    end
  end

  test "-p pairs it and says so on stderr" do
    {out, code} = cli([write_clash!(), "-p"])

    assert code == 0
    assert out =~ "warning: round 1: 1 (P1) and 3 (P3) both have White"
  end

  test "-p --strict refuses it, exit 1" do
    {out, code} = cli([write_clash!(), "-p", "--strict"])

    assert code == 1
    assert out =~ "invalid TRF file: round 1: 1 (P1) and 3 (P3) both have White"
  end

  test "--strict is refused where nothing reads a file" do
    {out, code} = cli(["-g", "--strict"])

    assert code == 1
    assert out =~ "--strict is for"
  end
end

defmodule AinalramiLab.VariantTest do
  use ExUnit.Case, async: true

  alias AinalramiLab.Variant

  test "the baseline is the 2026 order, C5 to C21" do
    v = Variant.parse("baseline")
    assert v.order == ~w(C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C16 C17 C18 C19 C20 C21)
    assert Variant.baseline?(v)
    assert Variant.describe(v) == "the 2026 text"
  end

  test "drop, move, swap" do
    assert Variant.parse("drop:C12,c13").order -- ~w(C5 C6 C7 C8 C9 C10 C11) ==
             ~w(C14 C15 C16 C17 C18 C19 C20 C21)

    moved = Variant.parse("move:C14:before:C10").order
    assert Enum.take(moved, 6) == ~w(C5 C6 C7 C8 C9 C14)
    assert Enum.at(Variant.parse("move:C5:after:C21").order, -1) == "C5"
    swapped = Variant.parse("swap:C10:C12").order
    assert Enum.at(swapped, 5) == "C12" and Enum.at(swapped, 7) == "C10"
    refute Variant.baseline?(Variant.parse("swap:C10:C12"))
  end

  test "float memory removes or adds the two-rounds-back families" do
    assert Variant.parse("float_memory=1").order ==
             ~w(C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C18 C19)

    assert Enum.take(Variant.parse("float_memory=3").order, -4) == ~w(C16@3 C17@3 C20@3 C21@3)
    assert Variant.baseline?(Variant.parse("float_memory=2"))
  end

  test "parameters and readings, combined with +" do
    v =
      Variant.parse(
        "absolute_cd=2+streak=3+c525=tpn+c18=paired+c13=strong_only+c3=off+rematches=allowed"
      )

    assert {v.absolute_cd, v.streak, v.c525, v.c18, v.c13, v.c3, v.rematches} ==
             {2, 3, :tpn, :paired, :strong_only, :off, :allowed}
  end

  test "nonsense is refused by name" do
    for bad <- [
          "drop:C99",
          "frobnicate",
          "streak=1",
          "c525=lottery",
          "move:C5:beside:C6",
          "drop:C12+drop:C12"
        ] do
      assert_raise ArgumentError, fn -> Variant.parse(bad) end
    end
  end
end

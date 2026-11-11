# javafo.jar and bbpPairings.exe are third-party binaries not vendored
# into this repo (see Ainalrami.Test.Javafo's and Ainalrami.Test.Bbppairings'
# moduledocs) - anywhere one isn't present (a fresh checkout without the
# sibling openpairings project, CI), its comparison tests are excluded
# rather than failing outright.
javafo_present? = Ainalrami.Test.Javafo.available?()
bbppairings_present? = Ainalrami.Test.Bbppairings.available?()

exclude_tags =
  if javafo_present? do
    []
  else
    IO.puts(
      "Skipping JaVaFo-comparison tests: #{Ainalrami.Test.Javafo.jar_path()} not present " <>
        "(set JAVAFO_JAR to override)"
    )

    [:javafo]
  end

exclude_tags =
  if bbppairings_present? do
    exclude_tags
  else
    IO.puts(
      "Skipping bbpPairings-comparison tests: #{Ainalrami.Test.Bbppairings.exe_path()} not " <>
        "present (set BBPPAIRINGS_EXE to override)"
    )

    [:bbppairings | exclude_tags]
  end

# The failure taxonomy is a diagnostic, not a regression test: it asserts
# nothing unless told what to expect, and its job is to print a breakdown
# of wherever the engine currently disagrees with bbpPairings. Run it on
# demand with `mix test --only taxonomy`.
exclude_tags = [:taxonomy | exclude_tags]

# The three-way comparison needs Gacrux (Otto Milvang's pairingchecker.py
# from the FIDE Tie Break Server, located via GACRUX_DIR) and is ~35x the
# cost of the two-way harness, since Gacrux is a Python script at roughly
# 750ms a round. Excluded by default and run on demand with
# `mix test --only three_way`.
unless Ainalrami.Test.Gacrux.available?() do
  IO.puts(
    "Three-way comparison unavailable: #{Ainalrami.Test.Gacrux.script_path()} not present " <>
      "(set GACRUX_DIR to override)"
  )
end

exclude_tags = [:three_way | exclude_tags]

# The C.04.6 team three-way (Ainalrami, Gacrux, chesspairing) needs both
# external engines and runs on the VM. Run on demand with
# `mix test --only team_three_way`.
exclude_tags = [:team_three_way | exclude_tags]

# The interop fixture is a 209-player tournament, and this engine's matcher
# is roughly O(n^4) in the field size (see `docs/validation.md`'s
# "Performance"): one round of it takes about eighty seconds, and the file
# has five to replay. That turned `mix test` from eleven seconds into nine
# minutes, which is the sort of thing that stops people running it.
#
# Excluded by default and run on demand:
#
#     mix test --only interop
#
# The cheap half of that file's coverage - that it parses at all, with its
# bare carriage returns - is deliberately NOT tagged, so a fresh `mix test`
# still catches the regression it was written for.
exclude_tags = [:interop | exclude_tags]

# The tie-break reference's scale mode (docs/tiebreak-reference.md): the
# default run covers 300 events; this one takes the seeds from
# TIEBREAK_REF_SEEDS and is run on demand with
# `mix test --only tiebreak_reference_scale`.
exclude_tags = [:tiebreak_reference_scale | exclude_tags]

ExUnit.start(exclude: exclude_tags)

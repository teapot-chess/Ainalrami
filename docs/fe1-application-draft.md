# FE1 application - draft

FIDE's endorsement application for a Swiss pairing program, C.04 Annex 1
([FE1](https://www.fide.com/FIDE/handbook/C04Annex1_FE1.pdf), the 2017
form, still the published one on 2026-10-20). Every field of the form is
below, in its order, filled from this repository's own evidence. Fields
marked **[maintainer]** are the maintainer's to fill; nothing in them is
guessed.

Not sent. FE1 reaches the SPP secretariat at least four months before a
Congress, and a new Acceptance Cycle under VCL4THP v13 may replace the
form before then - check the handbook page first, then this file.

---

**To:** FIDE Systems of Pairings and Programs Commission

| Field | Answer |
|---|---|
| Program name | Ainalrami |
| Application date | **[maintainer]** |

### Author

| Field | Answer |
|---|---|
| Name | **[maintainer]** |
| Country | **[maintainer]** |
| E-mail | **[maintainer]** |
| Website | https://github.com/teapot-chess/Ainalrami |
| Other contact | **[maintainer]** (or leave empty) |

### Program

| Field | Answer |
|---|---|
| Version | **[maintainer: the release being submitted]** (0.44.0 when this was drafted) |
| Previous endorsement | None |
| Platform or operating system(s) | Any system with Erlang/OTP 29 or newer: Windows, Linux, macOS. The release is one `ainalrami` escript file; Elixir is not needed to run it. |
| Pairing system | FIDE (Dutch) System, C.04.3 |

FE1 is per pairing system. Ainalrami also pairs team Swiss (C.04.6) and
round robins, but no second implementation of C.04.6 exists to run FE1's
auto-test against (see [validation.md](validation.md), "Team Swiss
pairings"), so this application is for the Dutch system only.

### Downloads

| Field | Answer |
|---|---|
| Download details | https://github.com/teapot-chess/Ainalrami/releases - each release has the built `ainalrami` file attached. Run it with `escript ainalrami ...` on Windows, `./ainalrami ...` elsewhere. Source: the same repository. |
| Free software | **YES** - Apache License 2.0 |
| Trial version limitations | None |

### Specifications

| Field | Answer |
|---|---|
| Internal engine | **YES** |
| FPC - pairing checker | `ainalrami input.trf -c` |
| RTG - tournament generator | `ainalrami -g output.trf [--seed=N] [--players=N] [--rounds=N] [--forfeit-pct=N] [--bye-pct=N] [--forbidden-pct=N] [--initial-colour=w\|b]` |

`-c` replays every round of the file from the state before it and reports
each round whose pairing differs from the engine's. `-g` generates a random
tournament and pairs it forward round by round. The two mirror JaVaFo's
FPC/RTG modes, which is what FE1's two fields were written around.

### Auto-test reports

> FE1: "an Endorsement Request can be received only if the error ratio is
> not worse than 1 difference every 500 test tournaments."

#### 1. Internal FPC, reference RTG

| Field | Answer |
|---|---|
| Reference RTG | bbpPairings 6.0.0 `-g` |
| Number of test tournaments | 50,045 |
| Rounds per test tournament (min/max/avg) | 5 / 15 / 9.99 (499,816 rounds) |
| Rounds with pairing differences detected by the internal checker | **0** |

Not counted above: 158 further generated files on which bbpPairings' own
generator found no legal pairing and stopped; there was no round to check.
Source: [validation.md](validation.md), "Pairings (VCL4THP Q33), both
directions", direction 2 (`tools/bbp_generator_reverse.exs`, cross-checked
against the real `-c`).

#### 2. Internal RTG, reference checker

| Field | Answer |
|---|---|
| Reference checker | bbpPairings 6.0.0 |
| Number of test tournaments | 5,993,000 (the 2026-08-20 corpus) |
| Rounds per test tournament (min/max/avg) | **[confirm min]** / 13 / 7.42 (44,486,465 rounds) |
| Rounds with pairing differences detected by the reference checker | **2** - both bbpPairings' own [C2] second-bye defect, not a difference in this engine's pairing |

The two differences are written up in
[bbp-differences-2026-10-18.md](bbp-differences-2026-10-18.md) and
[bbppairings-c2-bug-report.md](bbppairings-c2-bug-report.md): a build of
bbpPairings with the one-line bit-field fix returns this engine's pairing,
and Gacrux agrees with it on both. Even counted against us, 2 in 5,993,000
is far inside 1 in 500.

Rounds per tournament: the generator plans 8-13 rounds (9 unless the axis
says otherwise), and a tournament stops early when bbpPairings finds no
legal pairing - 45.5% of the corpus did, mostly 4-10 players - which is why
the average is below the planned length. The shortest played length was not
recorded per tournament; re-derive it from the corpus at
`VPS projects/ain_val_run_2026-08-29` before this goes out.

Larger figures exist (2,536,328,265 pairings over six corpora, 2
differences, the same two) - see [validation.md](validation.md),
"Summary". FE1 asks for one run per direction, so the single corpus with a
clean provenance is the one given; the rest can go in a covering letter.

---

**(Applicant's signature)** **[maintainer]**

## Before sending

- Fill the **[maintainer]** fields and the minimum round count.
- Decide the version: a release cut for the application, so the numbers
  above are re-run on exactly that build (an endorsement lapses on a major
  version, and the corpus above ran on an older one).
- Re-run both directions on that release at FIDE's production scale (5,000
  tournaments each is enough; the procedure page asks for that number).
- Covering letter: the larger corpora, the three-way runs with Gacrux, the
  Gacrux 5.2.4/5.2.5 findings, and the team Swiss evidence as a note on
  what the program also does.

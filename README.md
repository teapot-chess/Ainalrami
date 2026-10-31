# Ainalrami

A FIDE Swiss pairing engine - the Dutch system, and now Dubov, Burstein and Lim - written in
Elixir. No JVM, no external binary, no runtime dependencies.

> **Ainalrami** - ν¹ Sagittarii A, from the Arabic *Ain al Rami*, "the eye
> of the archer". A pairing engine's whole value is aiming exactly where
> the regulations point, rather than somewhere reasonable nearby.

Ainalrami implements **C.04.3, the FIDE (Dutch) System, effective
1 February 2026** - the current rules, not the 2017 edition most engines
still ship. It reads and writes TRF16 and FIDE's 2026 TRF format (TRF26),
mirrors JaVaFo's command-line shape, and is verified against two
independent reference implementations. It also pairs team Swiss events
(C.04.6), the Dubov system (C.04.4.1), the Burstein system (C.04.4.2) and,
as a documented reading, the Lim system (C.04.4.3), all 2026 editions, and
computes the
FIDE tie-breaks (C.07, effective 1 March 2026), individual and team.

**Status: beta.** The engine is functionally complete and reproduces
bbpPairings 6.0.0 exactly across 2.5 billion compared pairings, in six
separate corpora that between them vary every input the harness can vary.
Article 4's candidate ordering is verified against the regulations
directly. One point of Article 5 was settled *against this engine* on
2026-08-27 by the FIDE Systems of Pairings and Programs Commission, and
the engine now conforms. Both are documented rather than hidden - see
[What is not settled](#what-is-not-settled) and
[A dispute this engine lost](#a-dispute-this-engine-lost).

---

## Running it from the command line

If you downloaded `ainalrami` from a release (see [Install](#install)),
skip to the first command below. To build the tool yourself you need Erlang/OTP and Elixir. The project requires
Elixir `~> 1.17` (`mix.exs`); CI builds and tests on Elixir 1.20 with
OTP 29.0 (`.github/workflows/elixir.yml`). To run the built file you need
only Erlang/OTP; Elixir is not needed.

Build it from the project folder:

```bash
mix deps.get
mix escript.build
```

The project has no dependencies, so `mix deps.get` only confirms that.
`mix escript.build` leaves one file, `ainalrami`, in the project folder.
It is not committed to git.

On Windows, run it with Erlang's `escript`:

```bash
escript ainalrami input.trf -p
```

On Linux and macOS it is run as `./ainalrami input.trf -p`, which is the
standard escript behaviour. The examples below were run on Windows with
Elixir 1.20.3 on OTP 27, and the `escript` form was also checked with
Elixir removed from the `PATH`.

Pair the next round of a tournament file. The example file is one of the
repository's fixtures: six players, three rounds played, round 4 to pair.
`-q` leaves out the trace of each step:

```bash
escript ainalrami test/fixtures/forbidden_pairs/only-legal-pairing.trf -p -q
```

```
3
4 2
5 6
1 3
```

The first line is the number of boards, then one line per board: White's
starting number, then Black's. Leave out `-q` to see the trace first.
Give a file name after `-p` to write the boards there instead of to the
screen: `ainalrami input.trf -p round4.trf`.

Check a file against the engine. `-c` replays each round recorded in the
file and reports whether the engine would have paired it the same way:

```bash
escript ainalrami test/fixtures/forbidden_pairs/only-legal-pairing.trf -c
```

```
==> Checking 3 round(s)
    round 1: matches
    round 2: matches
    round 3: matches
==> 3/3 round(s) match this engine's own pairing
    standings: no tie-break list in the file (202/212) - not checked
```

The exit code is 0 when every round matches and 1 when one differs. See
[Command-line interface](#command-line-interface) for every mode and
option, and `escript ainalrami --help` for the short list.

`mix run` is not how the tool is used. `mix help` lists the Mix tasks.

Each release on GitHub has the ready-built `ainalrami` file attached,
together with a `SHA256SUMS` file. Running that file also needs only
Erlang/OTP. It is built with OTP 29, so run it with OTP 29 or newer; an
older Erlang will refuse it, and building it yourself is then the way.

## Validation at a glance

| area | compared against | size | result | detail |
|---|---|---|---|---|
| Individual pairings (C.04.3) | bbpPairings 6.0.0, on this engine's generated tournaments | 2,536,328,265 pairings, 217,470,056 rounds | 2 disagreements, both a bbpPairings defect | [below](#where-it-stands) |
| Individual pairings, three engines | bbpPairings and Gacrux | 649,207 rounds | never the odd one out | [validation](docs/validation.md#the-three-way-run-2026-08-27) |
| Individual pairings, Gacrux alone | Gacrux, on the timing study's VM | 3,219,728 rounds, 119,064,367 boards | 0 disagreements | [validation](docs/validation.md#against-gacrux-alone-32-million-rounds-2026-09-30) |
| Individual pairings, the other way | bbpPairings' own generator, checked here | 50,045 tournaments, 28,964,816 pairings | 0 disagreements, colours included | [validation](docs/validation.md#pairings-vcl4thp-q33-both-directions) |
| Team Swiss (C.04.6), 4-10 teams | brute-force reference written from the regulation | 1,032,949,115 rounds (seeds 1-250,000,000) | 0 failures | [validation](docs/validation.md#team-swiss-pairings-c046) |
| Team Swiss, 11-80 teams | exact engine-independent reference | 11,980 rounds | agrees (one budget defect found, fixed in 0.30.0) | [large fields](docs/team-proof-large-fields.md) |
| Team Swiss, no colour preferences | brute-force reference | 123,593 rounds | 0 disagreements | [conformance](docs/conformance-c0406-teams.md#no-colour-preferences-17-2026-09-27) |
| Tie-breaks (C.07), individual | FIDE's TieBreakServer, both directions | 50,060 and 50,000 tournaments | 0 unexplained | [validation](docs/validation.md#tie-breaks-c07-effective-1-march-2026-against-tiebreakserver) |
| Tie-breaks, team | TieBreakServer | 20,000 events, 1,643,308 values | 0 unexplained | [validation](docs/validation.md#team-events-extended-2026-09-26) |
| Tie-breaks, individual and team | independent reference written from C.07 | 8.3 million + 2,760,888 individual values, 3,975,739 team values | 0 disagreements | [reference](docs/tiebreak-reference.md) |
| Tie-breaks, real events | 43 SWAR tournaments re-ranked by OpenPairings | 43 tournaments | no Ainalrami bug found | [validation](docs/validation.md#real-tournaments) |

A nightly CI job repeats the tie-break checks on fresh seeds against a
pinned TieBreakServer. Team pairing has no outside program to compare
with, so its references are written here from the regulation and share no
code with the engine: they prove the computation, not the reading. The
differences TieBreakServer does not share are written up in
[docs/finding-tiebreakserver-2026-09.md](docs/finding-tiebreakserver-2026-09.md)
(findings A-H) and
[docs/conformance-c07-tiebreaks.md](docs/conformance-c07-tiebreaks.md).
Full table and method: [docs/validation.md](docs/validation.md#summary).

## Where it stands

Measured against **bbpPairings 6.0.0**, which implements the same 2026
rules.

**Cumulative to 2026-08-24: 2,536,328,265 individual pairings compared,
across 217,470,056 rounds, in 6 corpora over 99 axis-runs - 82 of them
distinct. Two disagreements, both a defect in bbpPairings that Gacrux
resolves this engine's way. Zero illegal rounds.**

| run | axes | rounds | individual pairings | disagreements |
|---|---|---|---|---|
| Round sweep, R=1..20 (08-23) | 20 | 59,966,505 | **684,901,202** | 0 |
| Cross-axis (08-23) | 25 | 35,436,044 | **474,685,328** | 0 |
| Rating shape / withdrawals / tiny fields (08-24) | 16 | 25,209,754 | **285,118,044** | 0 |
| Randomised corpus (08-23) | 4 | 7,898,024 | **116,251,032** | 0 |
| Six-million run (08-20) | 17 | 44,486,465 | 488,033,862 | 2 |
| Same axes, disjoint seeds (08-21) | 17 | 44,473,264 | 487,338,797 | 0 |
| **total** | **99** | **217,470,056** | **2,536,328,265** | **2** |

The four runs above the 08-20 corpus exist because size alone proves
little, and the last row is a replication rather than new coverage: the
same seventeen axes on a different build of this engine, which is why 99
axis-runs are only 82 distinct ones. It is evidence about the
optimisation, not about the rules. Every corpus
before 2026-08-17 held the round count at 9, and that one fixed parameter
hid a real defect that 2.55M tournaments could not produce and 2,000 at
eight rounds found immediately. The round sweep therefore varies rounds
from 1 to 20; the cross-axis run then crosses every parameter that sweep
held still - forfeits, forbidden pairs, acceleration, initial colour,
numeric extensions and field size - against short, classical and deep round
counts, including axes with all of them firing at once.

The randomised and rating runs go after the INPUT rather than the run
parameters. The randomised corpus draws rounds, colour, acceleration and
extension format per tournament instead of per axis, so it explores
combinations nobody wrote down. The rating run attacks the oldest assumption of all: every
corpus before it drew ratings uniformly from 1000..2800, making every
player rated and ties incidental - the inverse of real chess, where a
junior event is entirely unrated and a club field sits on a handful of
rounded numbers. Equal ratings put the initial ranking on a different
tiebreak path, and that ranking is the foundation of every bracket in every
round. It also covers withdrawals mid-event and fields as small as two
players, neither of which any corpus had ever generated.

The 2026-08-20 run's own table follows, seventeen axes:

| axis | tournaments | exact rounds | individual pairs | illegal |
|---|---|---|---|---|
| 300-500 players | 3,000 | **100.00%** | **100.00%** | 0 |
| 150-250 players | 40,000 | **100.00%** | **100.00%** | 0 |
| 60-120 players | 300,000 | **100.00%** | **100.00%** | 0 |
| plain | 800,000 | **100.00%** | **100.00%** | 0 |
| arbiter byes (15%) | 2,600,000 | **100.00%** (1 dispute) | **100.00%** | 0 |
| forfeits (10%) | 300,000 | **100.00%** | **100.00%** | 0 |
| forbidden pairs (`XXP`, 20%) | 300,000 | **100.00%** | **100.00%** | 0 |
| acceleration (`XXA`, Baku + random) | 300,000 | **100.00%** (1 dispute) | **100.00%** | 0 |
| all four combined | 510,000 | **100.00%** | **100.00%** | 0 |
| round counts 8, 10, 13 | 650,000 | **100.00%** | **100.00%** | 0 |
| Black drawn first | 300,000 | **100.00%** | **100.00%** | 0 |

FIDE's FE1 endorsement allows one difference per 500 tournaments. This is
one per 3 million - nearly four orders of magnitude inside the bar.

**What 2.5 billion pairings do not buy.** Almost all of them are measured
against ONE oracle, and agreement with a single reference cannot detect a
rule both engines read the same wrong way. The check on that is the
three-way harness, where Gacrux gives a genuinely independent third
opinion - and it has run 649,207 rounds, not 217 million, because it
is a Python implementation roughly 35x the cost per round. Those 649,207
bound the two references' mutual disagreement far more tightly than the
3,352 this sentence used to quote, which is
the real precision of the ruler every other number here is measured with.
Raising that bound is worth more now than another billion two-way
pairings.

The same seventeen axes were re-run on **2026-08-21** with disjoint seeds,
against the newer matching-layer optimisation (`finalize_pair` as a pure
edge removal): **5,993,000 tournaments, 487,338,797 individual pairings,
zero disagreements, zero illegal rounds.** Two independent corpora of
~488M pairings each, then - and the optimisation is correctness-neutral at
that scale, which is the whole reason for re-running it.

Zero disagreements the second time does not retire the two below: both
were bbpPairings defects on particular seeds, and fresh seeds simply did
not land on that configuration again. bbpPairings is unchanged and still
wrong there, so all three known disputes stay pinned as regression tests.

Both disagreements are **not defects here**: bbpPairings awards a second
pairing-allocated bye to a player who already has one, which absolute
criterion C2 forbids. Gacrux - a third, independent implementation -
pairs both the way this engine does. In one of them the round has exactly
one legal shape, reached by pure elimination, so there is no scoring
argument to be had. Written up in
[docs/dispute-seed735265.md](docs/dispute-seed735265.md) and
[test/fixtures/fe1_disputes/](test/fixtures/fe1_disputes/), with a
submittable report in
[docs/bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md).

Against **JaVaFo** the engine measures 83.68% to 100.00% of rounds exact,
depending on the axis, and it *should not* be 100%: JaVaFo implements the 2017 edition, superseded on 31 January 2026,
and differs from both 2026 references by roughly the same margin. That
gap is the control. An engine agreeing with all three at once would mean
the harness was measuring nothing.

Full methodology, per-axis detail and the reasoning behind each number:
[docs/validation.md](docs/validation.md).

**Speed**, measured 2026-09-30 on 3,000 random positions: the fuzz
generator at 100-1,001 players (ten sizes, odd and even), rounds 2, 5 and
9 of a nine-round event, 100 seeds per size and round. Each engine ran
single-threaded on the same 80-vCPU VM, 32 positions at a time: this
engine in-process on one scheduler (`+S 1`), timed on the second of two
calls; bbpPairings (C++, built from source) and Gacrux (Python) as
processes, wall time minus a start-up baseline. **All three returned the
identical pairing on all 3,000 positions.** The engine measured is commit
030bd28, before the slow-tail fix in 0.35.0 (below). Median / p90 / worst
of the 300 positions at each size:

| players | Ainalrami (030bd28) | Gacrux | bbpPairings |
|---|---|---|---|
| 100 | 6.8 ms / 20 ms / 0.13 s | 0.12 s / 0.38 s / 0.64 s | 39 ms / 66 ms / 79 ms |
| 101 | 6.0 ms / 23 ms / 0.12 s | 88 ms / 0.19 s / 0.31 s | 54 ms / 87 ms / 0.11 s |
| 200 | 10 ms / 23 ms / 0.26 s | 0.32 s / 2.10 s / 3.54 s | 0.29 s / 0.34 s / 0.42 s |
| 201 | 11 ms / 28 ms / 0.41 s | 0.27 s / 0.44 s / 1.23 s | 0.39 s / 0.45 s / 0.53 s |
| 400 | 17 ms / 30 ms / 0.75 s | 1.22 s / 16 s / 22 s | 2.36 s / 2.56 s / 2.76 s |
| 401 | 18 ms / 40 ms / 1.25 s | 1.09 s / 1.57 s / 2.69 s | 3.31 s / 3.64 s / 4.06 s |
| 600 | 28 ms / 49 ms / 3.52 s | 2.76 s / 52 s / 68 s | 8.64 s / 9.28 s / 11 s |
| 601 | 30 ms / 53 ms / 0.99 s | 2.33 s / 3.47 s / 8.05 s | 12 s / 13 s / 14 s |
| 1,000 | 48 ms / 0.12 s / 8.26 s | 8.02 s / 242 s / 328 s | 45 s / 51 s / 59 s |
| 1,001 | 50 ms / 0.13 s / 3.77 s | 6.72 s / 9.88 s / 30 s | 60 s / 72 s / 78 s |

Over all 3,000: medians 20 ms, 1.25 s and 2.55 s. Per position, Gacrux
took a median 63 times as long as this engine and bbpPairings 141 times;
this engine was the slower on 36 positions against Gacrux and 17 against
bbpPairings, all but one at 100-101 players, where the external engines'
figures are within the start-up subtraction's noise or a few tens of
milliseconds apart. This engine's figure excludes reading the file; the
others' include it.

Read with three notes. **A single position is noisy:** a size's worst is
about 170x its median for this engine and up to 41x for Gacrux, which is why
earlier one-file-per-row tables (and the "46x" quoted from one of them)
are not the comparison to quote. **Gacrux's round 2 on even fields is
its weak spot:** the median at 1,000 players round 2 is 109 s against
4.7 s at 1,001, and its p90 at 600 players round 2 is 60 s against a
median of 1.75 s. **This engine's worst case was the last round:** all
11 positions above 0.5 s were round 9, the worst 8.26 s at 1,000 players.
0.35.0 addresses that tail; on one core of an i7-10700 the 30 slowest
positions of the study went from 22.5 s in all to 4.2 s (the worst from
5.24 s to 1.04 s), the same pairings, while ordinary positions are
unchanged (median ~12 ms). The study itself has not been re-run on 0.35.0.

The answers were checked alongside: on the same VM, 030bd28 against
Gacrux over 373,500 nine-round tournaments of 4-1,000 players, 3,219,728
rounds and 119,064,367 boards, 0 disagreements (Gacrux's own Error 510 on
25,761 rounds and 5 Gacrux crashes are kept out of the rate); and 0.35.0
against 0.33.0 on the differential corpus, 447,152 rounds identical. Most
brackets are answered by walking Article 3's own order and proving the
result is the one the full weighted-matching refinement would return;
anything the proof does not cover is paired by the refinement. Method,
the per-round table, the raw data and the earlier passes:
[docs/performance.md](docs/performance.md#the-timing-study-2026-09-30);
how the engine got here from 90 s and 498 s:
[docs/engineering-log.md](docs/engineering-log.md).

## Install

Download from the
[latest release](https://github.com/teapot-chess/Ainalrami/releases/latest).
Every file there was built by CI from the tagged source, and `SHA256SUMS`
lists their checksums.

- **Windows: `ainalrami-windows-x86_64.zip`.** Unzip it anywhere and run
  `ainalrami.exe input.trf -p` from a terminal. Erlang is inside the folder;
  nothing is installed and nothing is written outside it. It is a plain
  console program, so redirects and pipes work, and its exit code is the
  command's. Keep the folder together: the exe starts the runtime beside it.
- **Linux: `ainalrami-linux-x86_64.tar.gz`** and **macOS (Apple Silicon):
  `ainalrami-macos-arm64.zip`.** The same folder with a shell script,
  `./ainalrami input.trf -p`. Also nothing to install, but the Linux one is
  built on Ubuntu 24.04 and the Mac one on macOS 15, so a much older system
  may not run it.
- **Any system with Erlang/OTP: `ainalrami`**, the escript. Run it as
  `escript ainalrami input.trf -p` on Windows, `./ainalrami input.trf -p`
  elsewhere. Elixir is not needed.

CI unpacks each archive, runs it with no Erlang on the `PATH`, and checks that
it prints the same bytes, writes the same files and exits with the same code
as the escript on the same inputs. The examples further down are written for
the escript; the packaged program takes the same arguments.

### Building from source

For development, or to run a commit that has no release yet:

```bash
git clone https://github.com/teapot-chess/Ainalrami
```

Then build the command-line file as described in
[Running it from the command line](#running-it-from-the-command-line).

As a dependency:

```elixir
{:ainalrami, github: "teapot-chess/Ainalrami"}
```

## Command-line interface

Deliberately mirrors JaVaFo's invocation shape, so a caller that already
drives JaVaFo only has to swap the executable name:

```bash
ainalrami input.trf -p output.trf
```

| invocation | mode |
|---|---|
| `ainalrami input.trf -p output.trf` | pair the next round (a team file: team against team) |
| `ainalrami input.trf -p` | same, printed to stdout |
| `ainalrami input.trf -x` | pair the next round and explain it |
| `ainalrami -g output.trf` | Random Tournament Generator (`--team=swiss` or `--team=roundrobin` for a team event) |
| `ainalrami input.trf -c` | Pairings Checker: replay and diff every round (team Swiss: team against team; team round robin: against the Berger tables) |
| `ainalrami input.trf -s [output]` | the standings by the file's tie-break list (`202`/`212`) or `--tie-breaks=` |

`-g` and `-c` mirror JaVaFo's own RTG/FPC modes, used for FIDE's FE1
endorsement auto-test.

**`-g`** generates a random tournament and plays it forward, pairing every
round with this engine. Every run is reproducible from its seed, and the
seed is written into the generated file's tournament name, so a file
always reproduces itself:

```bash
ainalrami -g out.trf --seed=42 --players=30 --rounds=9 --forfeit-pct=10 --bye-pct=5 --forbidden-pct=10 --acceleration=baku --initial-colour=b
```

Without `--seed` a fresh seed is drawn for every run from the operating
system's random source, so two runs with the same options give different
tournaments; the seed it drew is printed and
written into the file, and passing it back as `--seed` repeats the run
exactly.

Every option left out is chosen at random, not left off: each kind of bye
(`--full-bye-pct`, `--half-bye-pct`, `--zero-bye-pct`), forfeits
(`--forfeit-win-pct`, `--double-forfeit-pct`), unusual results
(`--odd-results-pct`), Baku acceleration and a tie-break list
(`--tie-breaks`, written as `202` with the final ranks it gives) is each
switched on with a 50% chance (`--unset-chance=N` changes it) at a random,
modest level. An option you give, an explicit `0` included, is kept.
Results follow the FIDE rating table (`--results=fide`, draw rate
`--draw-rate=0.3`), with a rating difference over 400 counted as 400 as
the rating calculation does, so over many tournaments a player's rating
change averages zero. `--unset=fixed` turns all of that off - unset options
off, results uniform - which is what the library's
`Ainalrami.Generator.generate/1` does by default, so the validated corpora
reproduce from their seeds.

`--dialect=trf26` writes the file in FIDE's 2026 spelling (`142`, `250`,
`260`, a bye still to come as `240`) instead of the engines' (`XXR`,
`XXA`, `XXP`); nothing random depends on it, so one seed is one
tournament either way.

`--initial-colour` is Article 5.1's drawing of lots, and it is written into
the file as `152`. It defaults to White - which is what the generator
always used, implicitly, before the option existed.

`--rounds` is capped at `players - 1`, past which a Swiss has no legal
opponents left. It can stop earlier still if some round turns out to have
no legal pairing at all - a real, if rare, possibility for a small field
deep into a Swiss (`Ainalrami.Pairing.NoValidPairingError`).

**`-c`** replays a completed tournament round by round, re-pairing each
from the state that preceded it and diffing against what the file records.
Exits 0 when every round matches, 1 otherwise (2 for a system it cannot
replay - see *Which files are replayed* below). Colour differences are
reported but never counted as errors: Article 5.1 leaves the first colour
to a drawing of lots, so this engine's convention is its own.

**Which files are replayed.** The file's `192` code decides, read as FIDE's
Tournament Type Code Table defines it (`Ainalrami.TypeCode`):

| `192` | `-c` |
|---|---|
| `FIDE_DUTCH_2025`, `FIDE_DUTCH` (and the draft's `FIDE_DUTCH_2026`) | replayed |
| `FIDE_DUTCH_2017`, or `FIDE_DUTCH` for an event that started (`042`) before 1 July 2025 | replayed, with a warning: the engine pairs the current C.04.3, not the 2017 edition |
| `FIDE_DUTCH*_BAKU` | replayed with the virtual points the file gives (`XXA`/`250`); exit 2 when it gives none - the engine does not derive C.04.7's groups itself |
| `FIDE_TEAM*` without `_BAKU` | replayed team against team (*Team events* below) |
| a team round robin (`BERGER_TEAM_ROUNDROBIN_Gn`, `FIDE_TEAM_ROUNDROBIN`, `FIDE_TEAM_DOUBLEROUNDROBIN`, ...) | compared with the Berger tables (C.05 Annex 1, `Ainalrami.Berger`), colours included, the table repeated `n` times with the colours reversed in every second cycle |
| an individual round robin (`BERGER_ROUNDROBIN_Gn`, `BERGER_ROUNDROBIN`, `FIDE_ROUNDROBIN`, `BERGER_DOUBLEROUNDROBIN`, `FIDE_DOUBLEROUNDROBIN`) | compared with the Berger tables, colours included, players numbered by starting rank (`Ainalrami.RoundRobin`); `FIDE_DOUBLEROUNDROBIN` plays the first cycle's last two rounds in reverse order |
| `CUSTOM_ROUNDROBIN`, `CUSTOM_TEAM_ROUNDROBIN` | exit 2: a round robin of the competition's own |
| `FIDE_SCHILLER_TxP`, `FIDE_SCHEVENINGEN_Gn` and their shorthands | exit 2: predetermined, by rules FIDE has not yet defined |
| `FIDE_DUBOV`, `FIDE_DUBOV_BAKU` | replayed by the Dubov system (*The Dubov system* below), colours included: 5.2 decides every colour from the initial colour, which `152` gives or round 1 shows |
| `FIDE_BURSTEIN`, `FIDE_BURSTEIN_BAKU` | replayed by the Burstein system (*The Burstein system* below): the seeding rounds by Dutch, as 1.6 says, the rest by C.04.4.2 |
| `FIDE_DOUBLESWISS` (with or without `_BAKU`) | exit 2: Ainalrami pairs the Dutch, Dubov, Burstein and Lim systems only |
| `CUSTOM_SWISS` with `XXO system lim` | replayed by the Lim system (*The Lim system* below); TRF26 has no code for Lim |
| `CUSTOM_*`, `FIDE_TEAM*_BAKU` | exit 2: a system of the competition's own; the team engine has no acceleration |
| none, or one off the table (said so) | the `092` type (a round robin - a team one when its games are team matches throughout, else individual - played as many times as its rounds need; a Scheveningen, Schiller or knockout exits 2), else the games: team matches throughout make a team Swiss, anything else the Dutch system |

When the file carries a tie-break list (`212`, or `202` after the score)
and final ranks, `-c` also ranks the field with `Ainalrami.Tiebreaks` and
reports every participant whose rank the list does not give (FIDE's
VCL4THP Q21); participants still level after the whole list may stand in
any order. For a team file the ranks are the teams' - TRF26 `310`, columns
69-71 - ranked with the team tie-breaks, match points from the file's `362`:

```
==> standings: 2 rank(s) do not follow MPTS GPTS
warning:   team 1: file says 2, tie-breaks give 1 (MPTS=3.0 GPTS=2.0)
warning:   team 2: file says 1, tie-breaks give 2 (MPTS=3.0 GPTS=1.5)
```

A team file with only `013` records has no team ranks, and the check is
skipped with a note saying so.

**Team events.** On a team Swiss the rounds are replayed team against team
with the C.04.6 engine (`Ainalrami.TeamPairing`), from the history the file
records - match and game points as the standings read them (`362`, `320`,
`330`), opponents and board-1 colours of the matches actually played, the
bye, forfeit wins and last round's floaters (`Ainalrami.TeamReplay` has the
full reading). Pairs are `{White team, Black team}`, White meaning White
on board 1, and the bye is `{team, nil}`:

```
==> Checking 7 team round(s) - C.04.6, Type A colour preferences, match points primary, game points for colours (192 FIDE_TEAM_TYPEA_MP_GP)
warning: round 2: DIFFERS
warning:   file:   [{1, 4}, {3, 2}, {5, 6}]
warning:   engine: [{1, 2}, {3, 4}, {5, 6}]
warning: round 3: DIFFERS in colours only - same pairing, board-1 colours differ in 1 match(es): [{4, 1}]
```

Unlike the individual replay, a colour difference counts: Article 4 decides
every team colour from the initial colour, which is the file's `152` or,
without one, whichever colour reproduces round 1. The settings come from
the `192` code as FIDE's table defines it: `TYPEA`/`TYPEB` for Type A/Type
B colour preferences and **neither for no colour preferences** (Article
1.7's third option, paired with `TeamPairing`'s `type: :none`), then the
primary score and, if named, the secondary one used for colours; `FIDE_TEAM`
alone is `FIDE_TEAM_TYPEA_MP_GP`. A file with team records and no `192` is
replayed as a team event with the C.04.6 defaults (Type A, match points,
game points for colours) when its games are team matches throughout; an
individual event listing club teams in `013` keeps the individual replay.

A file whose pairings this checker cannot replay is reported as such and
nothing is compared:

```
warning: rounds: not replayed - FIDE_SCHEVENINGEN is a Scheveningen event, whose pairings are predetermined (by rules FIDE has not yet defined). This checker replays the Dutch system (C.04.3), C.04.6 team Swiss events and team round robins, so no round was compared (exit code 2)
```

A team round robin is compared round by round with the Berger table for
its number of teams (numbered in the order of their `310` numbers), board
1's colour included. A scheduled match the file records nothing for - no
games and no `330` - is reported but is not a difference.

`-c` exit codes: **0** every round (and the standings, when checked)
match; **1** something differs, or the file cannot be read; **2** a system
that cannot be replayed, with the standings (if checked) in order.

> **A checker is not an independent verifier of the rules.** It re-runs the
> same engine and calls that the correct answer - exactly as bbpPairings'
> own `-c` does. A reported difference means "this engine would have paired
> it differently", not "the file is illegal".

The two modes are each other's test: `-g` output fed to `-c` checks clean
by construction.

**Bye preferences** (`-p` and `-x`; an organiser's wish, NOT a FIDE rule -
see *Organiser deviations* below). Four flags, each taking starting ranks
separated by commas, each optionally followed by `@` and the rounds it
applies to (single rounds and ranges joined by `+`), and each repeatable:

| flag | the player ... |
|---|---|
| `--bye-want=RANKS` | must get the pairing-allocated bye, if a legal round gives it to them |
| `--bye-want-soft=RANKS` | rather gets it: decides among the players on the bye score |
| `--bye-avoid=RANKS` | must not get it - the bye exclusion |
| `--bye-avoid-soft=RANKS` | rather not: someone else on the bye score takes it if anyone can |

```bash
ainalrami round5.trf -p --bye-want=12 --bye-avoid-soft=3,7@4-6+9
```

Whenever one is given, stderr says the round is not a pure FIDE pairing,
and each preference's outcome is reported (a preference that was not
applied, and why, as a warning). A `--bye-want` for a player who already
had the pairing-allocated bye (or a forfeit win or full-point bye, C2)
refuses the round: exit 1, with an error naming the player and that round.
The flags are refused with `-g` and `-c`. `--bye-exclude=RANKS` is the
library's plain `:bye_exclusions` - the same exclusion as `--bye-avoid`,
reported as the organiser's rather than as a preference.

A file can carry all five as `XXO` lines (see "TRF extension lines"), and
then `-p`, `-x` and `-c` read them: `-c` replays each round with the
settings that applied to it, and says on stderr that this is not a pure
FIDE check.

### Every other library option: flags for `-p`, `-x` and `-c`

Whatever OpenPairings hands the engine through the library, the command
line can now say too. [docs/cli-parity.md](docs/cli-parity.md) is the full
table - library option, flag, record - and the tests hold the CLI's answer
to the library's for each one. A flag is laid over what the file says:

| flag | library | what |
|---|---|---|
| `--rounds=N` | `expected_rounds:` | the round count, in place of `142`/`XXR` |
| `--initial-colour=white\|black` | `initial_colour:` | the drawing of lots, in place of `152`/`XXC` |
| `--points=3,1,0` or `--points=win:3,draw:1,bye:1` | `point_system:` | the point system, over `BB*`/`162`; names `win draw loss bye forfeit-loss zero-bye half-bye full-bye forfeit-win unknown` (`unknown` is what a `?` result is worth, `162`'s `X`; without it, and without an `X` in the file, a `?` is worth a draw). A win's value moves the bye's with it unless `bye:` is given, as `BBW` does, and the players' totals are re-added under it |
| `--forbidden=1,4/2,9,12@3-5` | `forbidden_pairs:` | forbidden groups, added to the file's `XXP`/`260`; `@ROUND` or `@FIRST-LAST` limits one to those rounds |
| `--soft-pairs=2,9,12@3-5` | `soft_pairs:` | a soft group can be limited to rounds the same way |
| `--acceleration=baku` | players' `:accelerations` | C.04.7's virtual points worked out here (`Ainalrami.Acceleration`): Group A the top `2 x ceil(n/4)`, `ceil(R/2)` accelerated rounds, the first half of them a point and the rest a half. For a file with no `XXA`/`250`; needs the round count |
| `--baku-group-a=N` | | Group A's last starting rank, for a field that grew after round 1 (the group does not) |
| `--virtual-points=1-10:1,1,0.5/11:0.5` | players' `:accelerations` | any other table: `RANKS:` one value per round. Not C.04.7, and stderr says so |
| `--half-bye=3,7` `--zero-bye=12` `--full-bye=20` | a bye in the player's games | (`-p`, `-x`) byes asked for in the round being paired, as a `240` record says them; a zero-point one is an absence |
| `--cascade-order` | `cascade_order: true` | (`-p`) boards in the order the brackets were paired instead of C.04.2 3.6's |
| `--proof=FILE` | `proof:` | (`-p`) a proof per round that every matching question the engine asked was answered correctly and the published boards are the pairs it read; see [pairing proofs](#pairing-proofs---proof) |
| `--judge=1-5,2-6,3-0` | `Alternatives.judge/4` | (`-x`) a whole other round, 0 for the bye, judged against the one paired: illegal pairs, then the first criterion that separates them |
| `--bye-alternatives` `--float-alternatives` | `Alternatives.bye_alternatives/3`, `float_alternatives/3` | (`-x`) had each other player of the bracket taken the bye, or floated, instead |
| `--alternative-pairs` | each candidate's `alternative` | (`-x`, with either of the two above) under each alternative, its boards that differ from the played round, the played boards they replace, how many boards are the same, and - for a tie, when the brackets leave no doubt - whether it is another order of S2 or an exchange between S1 and S2. Without it the two listings print what they always printed |
| `--max-candidates=N\|all` | `max_candidates:` | (`-x`, with either of the two above) how many candidates one question searches before it prints "not worked out" (12 by default); `all` is the whole bracket, one full pairing per candidate, which is what OpenPairings asks for when the arbiter wants it |

A flag in a mode that has no use for it is refused, not ignored
(`--cascade-order is for -p, not -c`), and so is one for another kind of
file. Without any of them, and without `XXO` lines, every run prints what
it printed before: `tools/cli_golden.exs` compares two checkouts' output,
and this one's 2,747 runs are byte for byte the release's.

### Pairing proofs: `--proof`

```bash
ainalrami round.trf -p pairs.txt --proof=round.proof.jsonl
elixir tools/verify-proof/verify.exs round.proof.jsonl
```

writes, next to the pairing, a proof of it: every weighted matching the
engine solved comes with an optimal dual solution (vertex and odd-set
duals) that shows no heavier matching exists, every "can the rest still
be paired" question with its witness (the path, or a Tutte-Berge
barrier), and every pair a bracket read off a matching is recorded, so
the verifier can insist the published boards are exactly those pairs.
`tools/verify-proof/verify.exs` is that check - one Elixir script,
standard library only, no code shared with the engine - and says PASS or
FAIL per round, and which boards are forced (in every optimum) rather
than chosen by the tie-break. The pairing written is byte for byte the
one without the option, and the proof is streamed to the file as it is
made. The weights are carried, not recomputed: their faithfulness to
C.04.3, the order the engine asks its questions in, and the tie-break
among equal optima are trusted. Exactly what is proven and trusted, the
format, and what it costs (seconds to minutes on large fields, and a big
file - name it `.gz`): [docs/pairing-proofs.md](docs/pairing-proofs.md).

### Standings: `-s`

```bash
ainalrami event.trf -s --tie-breaks=BH,SB
```

`Ainalrami.Tiebreaks.rank/3` on the file - what `-c` checks the file's own
ranks against - as a header line and one line per participant, CRLF:

```
RANK ID PTS BH SB
1 6 4.5 13.0 11.75
2 9 3.5 12.0 7.75
```

The list is the file's (`212`, or the score and then `202`) unless
`--tie-breaks=` gives one; a list starting with `PTS`, `MPTS` or `GPTS` is
the whole order. `--cap-rounds=played|announced` is C.07 16.4.2's round
count for a dummy opponent (`played` by default). A team file (TRF26 `310`)
is ranked with the team tie-breaks. `--tie-breaks=` and `--cap-rounds=`
work on `-c` too. Per-round ratings for the rating tie-breaks (VCL4THP
Q214) come from the file: `XXO round-ratings`, below.

### Round robins: `-p`, `-x`, `-c` and `-g --roundrobin`

On a round-robin file (the `192` codes above, or a `092` round robin) `-p`
gives the next round of the Berger table - the table OpenPairings plays,
board for board (`test/fixtures/round_robin/openpairings_berger.txt` holds
its boards for 3-16 players, one and two cycles): players numbered by
starting rank, the boards lowest number first, the free player of an odd
field last as `PLAYER 0`, in JaVaFo's list format. `-x` says the table
fixed the round; bye preferences, `--force` and `--absent` are refused.
`-g --roundrobin` writes a random one (`--players --rounds --cycles
--forfeit-pct --draw-rate --rating-range --tie-breaks --seed`) that `-c`
passes. A match-format round robin (`XXM` or `--match-format`; OpenPairings
writes it as `CUSTOM_ROUNDROBIN`) plays round `k` of one table as rounds
`2k - 1` and `2k`, the second with the colours reversed, and a round robin
by category (`XXG` or `--groups=`) plays one table per group, table after
table - both as OpenPairings schedules them; `-g --roundrobin` takes
`--match-format` and `--groups=N`.

### The Dubov system: `--system=dubov`

A file whose `192` is `FIDE_DUBOV` or `FIDE_DUBOV_BAKU` is paired (`-p`) and
replayed (`-c`) by C.04.4.1, the 2026 edition (`Ainalrami.Dubov`);
`--system=dubov` does the same for a file with no `192`, and `-g
--system=dubov` writes one. A `--system` that contradicts the file's `192`
exits 2 rather than either quietly winning.

What Dubov needs that Dutch does not: the round count (`142`/`XXR` or
`--rounds`; [C8]-[C10] stop in the last round) and a rating for every
player (1.1.1) - an unrated one takes a provisional rating from `XXO
provisional-rating` or `--provisional-rating=`, and a round with an unrated
player and neither is refused. Baku is the virtual points the file carries
(`XXA`/`250`, or `--acceleration=baku`), counted wherever the text says
"score". Forbidden pairs, pre-recorded byes, late entrants, the point system
and the initial colour work as for Dutch. With no `152` the initial colour
is read off round 1.

The Dutch engine's own tools are refused for a Dubov file, exit 1: bye
preferences and exclusions, soft pairs, pairing groups, the match format,
`--cascade-order` and `--proof`. `-x` and the alternatives exit 2: they
explain the Dutch criteria ladder, which Dubov does not have. A round with
no legal pairing (Dubov's [C3] has no topscorer exception) is refused,
exit 1: 1.9.3 hands it to the Chief Arbiter, and so does this program.

Every reading the text left open, and the validation behind it, is in
[docs/conformance-c0441-dubov.md](docs/conformance-c0441-dubov.md).

### The Burstein system: `--system=burstein`

A file whose `192` is `FIDE_BURSTEIN` or `FIDE_BURSTEIN_BAKU` is paired
(`-p`) and replayed (`-c`) by C.04.4.2, the 2026 edition
(`Ainalrami.Burstein`); `--system=burstein` does the same for a file with
no `192`, and `-g --system=burstein` writes one. The first
`min(rounds / 2, 4)` rounds are seeding rounds and 1.6 pairs them by the
Dutch system, so the Dutch engine pairs them, unchanged; `-p` says so.
After them the index is Buchholz, then Sonneborn-Berger, then the pairing
number - never the score, never a rating.

So the round count is required (`142`/`XXR` or `--rounds`), and
`--provisional-rating` is refused: Burstein reads no ratings. Forbidden
pairs, pre-recorded byes, late entrants, Baku, the point system and the
initial colour work as for Dutch; with no `152` the initial colour is read
off round 1. The Dutch engine's own tools are refused after the seeding
rounds exactly as for Dubov (exit 1; `-x` exits 2), and so is a round with
no legal pairing.

Readings and validation:
[docs/conformance-c0442-burstein.md](docs/conformance-c0442-burstein.md).

### The Lim system: `--system=lim`

C.04.4.3, the 2026 edition (`Ainalrami.Lim`), **as a documented reading**:
the text is a 1987 procedure for an arbiter with pairing cards, no other Lim
engine is known, and every place it was read is written down. TRF26 has no
`192` code for Lim, so a Lim file says `192 CUSTOM_SWISS` and this
program's own `XXO system lim`; either the record alone or `--system=lim`
chooses it, `-g --system=lim` writes both, and `XXO system lim` beside any
other `192` exits 2.

The scoregroups above the median are paired top down, those below it bottom
up, the median group last; floaters, exchanges and colours follow Articles
3-5. The round count is required (the last round lets equal scores meet
whatever their colours, Article 6). Ratings are not read, so
`--provisional-rating` is refused; so is an acceleration, which Lim does not
have, and the Maxi-tournament rules, which no 2026 text defines. Forbidden
pairs, pre-recorded byes, late entrants, the point system and the initial
colour work as for Dutch. The Dutch engine's own tools are refused as for
Dubov.

Readings, validation and the questions for FIDE:
[docs/conformance-c0443-lim.md](docs/conformance-c0443-lim.md).

### Match format, pairing groups and soft pairs

Three settings OpenPairings pairs with that no FIDE record carries. The
first two are read from the file (`XXM`, `XXG` - see "TRF extension lines")
or given as flags, which take their place; `-p`, `-x` and `-c` all pair by
them, and `-g` writes them:

| flag | record | what |
|---|---|---|
| `--match-format` | `XXM` | every match two games in a row, colours reversed in the second. A Swiss pairs the odd rounds by the Dutch system (from the whole history, both legs of every match) and copies each even round from the one before, boards turned round, a pairing-allocated bye given again; `-c` holds the second legs to exactly that, colours included. A round robin: round `k` of one Berger table as rounds `2k - 1` and `2k`. Files: `CUSTOM_SWISS` / `CUSTOM_ROUNDROBIN` / `CUSTOM_TEAM_ROUNDROBIN` with `XXM`. |
| `--groups=1-8/9-12,15` | `XXG 1 2 ...` (one line per group) | pairing by category: each group paired on its own - a Swiss group by the Dutch system with everybody else sitting the round out, one player alone in the round given the pairing-allocated bye, a round robin group by its own Berger table. Groups in the order given, boards following one another; ranks in no group form a last group. |
| `--soft-pairs=1,4/2,9,12`, `--soft-position=strong\|weak` | `XXO soft-pairs 1 4`, `XXO soft-position weak` | pairs to keep apart where the criteria allow it (the flags `-p`, `-x` only - an organiser's wish, see "Organiser deviations"). |

```
ainalrami event.trf -p --groups=1-12/13-20       # a Swiss paired by category
ainalrami event.trf -c --match-format             # check an OpenPairings match-format Swiss
ainalrami -g out.trf --roundrobin --match-format --groups=2
```

Match format and pairing groups together are refused, as OpenPairings
refuses them. A second leg that cannot be copied - a player seated in the
first leg with a result already recorded for the second, or one who sat
the first out and is in the second - is refused with the player named.
The library call is `Ainalrami.EventFormat.pair_next_round/2`
(`Ainalrami.Pairing`'s options plus `:match_format` and `:groups`), and the
CLI's answer is that call's, which the tests hold it to.

### Team events: `-p`, `-x` and `-g`

**`-p` on a team file** pairs the next round team against team. Which
system is `-c`'s choice (above): a C.04.6 team Swiss is paired by
`Ainalrami.TeamPairing` with the settings of its `192` code (colour
preferences, primary score, secondary score for colours), the initial
colour of `152` (else the one round 1 shows, else White), the round count
of `142`, the history the file records (match and game points as the team
standings read them - `362` with its `P` and `A`, `320`, `330` - opponents
and board-1 colours of the matches played, byes, forfeit wins, last
round's floaters) and the teams sitting the round out passed as absent; a
team round robin gets the next round of the Berger table. A team sits the
round out when every one of its players already has the round recorded -
a zero-, half- or full-point bye in the column or a TRF26 `240` record -
which is how an arbiter says so before the pairing. A fresh team event
needs its `192` code: with no games yet, nothing else says it is one.

The output is JaVaFo's pairing list one level up - a count line, then one
line per match with the team that has White on board 1 first, the bye
last as `TEAM 0` (a Swiss's pairing-allocated bye; a round robin's free
round), CRLF throughout. Team numbers are the `310` numbers. Matches come
in C.04.2 3.6's recommended order (Swiss) or by the lower team number
(round robin):

```
4
3 4
2 1
8 5
7 0
```

With `--lineups` the boards follow as a second block: a count line, then
`MATCH BOARD WHITE BLACK` per board - the match's line number above (from
1), the board, and the players' starting ranks, 0 for a board nobody
fills. A team seats the order of a `300` record for the round when the file
has one, otherwise its free players in roster (`310`) order, and the team
with White on board 1 has White on every odd board. The number of boards is
the most any match of the file had, or `--boards=N` (needed before the
first match is played).

```bash
ainalrami league.trf -p round6.txt --lineups
```

**`-x` on a team file** prints the engine's own account (C.04.6
`explain: true`): the teams going in (match and game points, colours,
colour preference, bye/forfeit/float flags), the pairing-allocated bye and
why it went where it did (3.4), every bracket with the upfloater sets
considered, the runner-up and the criterion that decided between them
([C4]-[C7], 3.5.4), and the Article 4 rule behind each match's colours. On
a round robin it says the table fixed the round. Bye preferences,
`--force` and `--absent` are for individual events and are refused on a
team file; `--lineups`/`--boards` on an individual one. A team system
nothing here pairs (Scheveningen, Schiller, an accelerated or custom team
Swiss) exits 2.

**Settings over the file's** (`-p`, `-x`, `-c` on a team Swiss), each
`Ainalrami.TeamPairing.pair_round/2`'s option of that meaning:

| flag | what |
|---|---|
| `--team-type=a\|b\|none --score=mp\|gp --secondary=yes\|no` | colour preferences, primary score, whether the secondary score allocates colours - in place of the `192` code's |
| `--initial-colour=white\|black`, `--rounds=N` | in place of `152` and `142` |
| `--absent-teams=2,5` | (`-p`, `-x`) these teams sit the round out: every free player a zero-point bye, which is how the file says it |
| `--max-upfloater-sets=N` | C.04.6 3.5's search budget (default 200,000) |
| `--explain-limit=N` | (`-x`) entries kept per list of the account (default 10) |
| `--team-forbidden=3,11,16/1,8@1-2` | (`-p`, `-x`, `-c`) teams that must not meet, by team number; added to the file's `XXO team-forbidden` records (**not FIDE**, see below) |
| `--team-soft-pairs=3,11,16` | (`-p`, `-x`) teams to keep apart where no C.04.6 criterion minds; added to `XXO team-soft-pairs` (**not FIDE**) |

**Keeping teams apart** (`Ainalrami.TeamPairing`'s `:forbidden_pairs` and
`:soft_pairs`, the individual engine's options of the same names and
shapes, by team number). The regional event that enters three teams from
one club would rather they did not meet in round one; with
`XXO team-forbidden 3 11 16` (or the flag) round one of a sixteen-team field
pairs 3-12 and 4-11 instead of 3-11 and 4-12. A forbidden pair is, to
C.04.6, a pair that has already met - [C1] refuses it everywhere, the bye's
3.4.1 included - and a round the groups alone make unpairable is refused
with the groups named and the ones that, lifted on their own, would let it
pair (`{:error, {:forbidden_pairs, %{reason:, groups:, lifting:}}}`). A
soft pair is one more criterion below [C10] and above 3.6's identifier,
inside the bracket: it only chooses among pairings C.04.6 ranks equal,
never moves the bye or a floater, and never fails a round. There is no
`--soft-position`: 3.5 picks the upfloaters before any bracket is paired,
and a soft rung above that choice would trade a FIDE criterion for a wish.
`XXP`/`260` name players, so a team Swiss refuses them instead of ignoring
them. `-c` replays with the records and says it is not a pure FIDE check.

```bash
ainalrami koppel.trf -p --team-forbidden=3,11,16/1,8,14/2,7,13
ainalrami koppel.trf -x --team-soft-pairs=3,11,16@1-2
```

**`-g --team=swiss` / `--team=roundrobin`** generates a random team event
(`Ainalrami.TeamGenerator`) as a TRF26 file: `310` teams with rosters,
board-level games in `001`, `362` (`W`/`D`/`L`, `P`, `A`), `320`, `330`,
`300`, `192`, `152`, `142` and, with a tie-break list, `212` and the team
ranks. A Swiss is paired by `Ainalrami.TeamPairing` round by round from the
generator's own record of the event, so `-c` on the file - and `-p` on any
copy of it cut back to before a round - re-reads that record from the
file. Options left out are drawn from the seed, which is printed and
written into the tournament name:

| option | meaning |
|---|---|
| `--seed --teams --rounds` | the event (a Swiss 4-16 teams and 3-9 rounds, never more than teams - 1; a round robin 3-10 teams and its whole table unless fewer rounds are asked for) |
| `--boards --reserves --cycles` | boards per match (2-6), at most this many reserves per team (0-2), a round robin's cycles (1 or 2) |
| `--team-type=a\|b\|none --score=mp\|gp --secondary=yes\|no` | C.04.6 colour preferences, primary score, and whether the secondary score allocates colours - written as the `192` code |
| `--initial-colour=white\|black` | the drawing of lots (4.1), `152` |
| `--match-points=2,1,0 --pab=draw\|win --forfeit-match-points=0` | match points; the pairing-allocated bye's (1.4: a draw's by default); a match lost by forfeit's |
| `--forfeit-pct --match-forfeit-pct` | boards forfeited; matches a team did not turn up for (board by board, or as a `330` with no boards) |
| `--absent-team-pct --absent-player-pct` | teams sitting a round out (every player a `Z`; in a round robin the match is forfeited, `330`); players announced absent (the players below move up, a reserve fills in) |
| `--out-of-order-pct` | lineups out of roster order, with a `300` record |
| `--draw-rate --tie-breaks=MPTS,GPTS,EDE` | draws; a team tie-break list (`212`) and the ranks it gives |

```bash
ainalrami -g league.trf --team=swiss --seed=7 --teams=12 --boards=4 --team-type=b --absent-team-pct=5
ainalrami league.trf -c
```

`tools/team_cli_corpus.exs SWISS RR` is the large run: generated events
through `-c`, and `-p --lineups` on every round of every one of them cut
back to before that round, compared with the generator's direct answer.

### Verbose by default

Unlike JaVaFo, which prints almost nothing beyond the result, Ainalrami
traces each step it takes. Pass `-q`/`--quiet` to suppress it. The intent
is that *"why did board 3 downfloat instead of board 5"* should be
answerable by reading the run's own output.

## TRF extension lines

Beyond TRF16 proper, Ainalrami reads and writes four of JaVaFo's `XX`
extension codes:

| line | meaning |
|---|---|
| `XXR n` | number of rounds - JaVaFo's spelling of TRF16's `142` |
| `XXP a b [c …]` | a mutually-forbidden **group**: no two of these players may ever meet |
| `XXA` | per-player acceleration ("virtual points"), round by round |
| `XXZ a b [c …]` | players absent from the round about to be paired - what Swar writes |
| `260` | forbidden pairs, limited to a range of rounds |
| `250` | acceleration for a range of players over a range of rounds |
| `XXM` | match format: every match two games in a row, colours reversed (Ainalrami's own) |
| `XXG a b [c …]` | one pairing group - a category paired on its own (Ainalrami's own) |
| `XXO keyword ...` | the organiser's options no TRF record carries (Ainalrami's own, below) |

`XXM` and `XXG` are this engine's own, for the two OpenPairings settings
neither TRF16 nor TRF26 can say; no other program reads them. `XXM` takes
no value. A malformed `XXG`, a rank the file does not have and a rank in
two groups are refused, as a malformed `XXP` is.

`XXO` is the third of this engine's own: one code, and after it the
command line's own name for the option.

| line | flag | meaning |
|---|---|---|
| `XXO soft-pairs 2 9 12 [@3-5]` | `--soft-pairs=` | a soft group, for every round or `@ROUND` / `@FIRST-LAST` (**not FIDE**) |
| `XXO soft-position strong\|weak` | `--soft-position=` | how hard to try (**not FIDE**) |
| `XXO bye-want 5 12@3-4+7` | `--bye-want=` | must get the pairing-allocated bye; likewise `bye-want-soft`, `bye-avoid`, `bye-avoid-soft` (**not FIDE**) |
| `XXO bye-exclude 3 7@4-6+9` | `--bye-exclude=` | the plain bye exclusion (**not FIDE**) |
| `XXO team-forbidden 3 11 16 [@1-2]` | `--team-forbidden=` | a team Swiss's `XXP`: these TEAMS (team numbers) never meet, for every round or the rounds named (**not FIDE**) |
| `XXO team-soft-pairs 3 11 16 [@1-2]` | `--team-soft-pairs=` | a team Swiss: these teams kept apart where no C.04.6 criterion minds (**not FIDE**) |
| `XXO round-ratings 12 2100 2150 - 2180` | none | the rating player 12 held in each round, `-` or `0` for none: the rating tie-breaks (ARO, TPR, PTP, APRO, APPO) then count each opponent at the rating of that round. C.07 Article 10 allows it when the event's regulations say so (VCL4THP Q214) |
| `XXO provisional-rating 12 1500` | `--provisional-rating=12:1500/17:1400` | the Dubov system: the rating the Chief Arbiter gives an unrated player (C.04.4.1 1.1.2). FIDE's own rule, so no warning; the Dutch engine has no use for it and ignores it. Two lines for one player are refused; one for a player who has a rating is refused when the round is paired |

A round paired from any of these but the last two is not a pure FIDE pairing, and `-p`,
`-x` and `-c` say so on stderr exactly as they do for the flags; flags and
lines together add up. bbpPairings 6.0.0 and JaVaFo both skip the lines
(ten mid-event files each, the same boards with and without them), so a
file with `XXO` lines still pairs elsewhere - by the FIDE rules alone,
which is the point of the warning. One code rather than one per option on
purpose: `XXS` was the obvious name for soft pairs and is JaVaFo's point
system. A malformed line, a keyword `XXO` does not have and a rank the
file does not have are refused. `Trf.serialize/2` writes the lines from
`tournament[:soft_pairs]`, `[:soft_position]`, `[:bye_preferences]`,
`[:bye_exclusions]`, `[:team_forbidden_pairs]`, `[:team_soft_pairs]` and
each player's `:round_ratings`, and writes nothing for a tournament with
none of them. The two team records are a team Swiss's: an individual file
or a round robin carrying them is refused, and their team numbers are
checked against the file's teams when a round is paired or replayed.

`XXZ` reads as a `0000 - Z` in the named players' column for the round
about to be paired: left out, no bye, no points beyond a zero-point bye's.
It is how Swar tells JaVaFo who is not there; until 0.44.1 this engine
ignored the line and paired them. A rank the file does not have, or one
whose column for that round already holds a bye, is refused; a `0000 - Z`
already there is the same thing said twice and is fine. `Trf.serialize/2`
writes the column by default (bbpPairings does not read `XXZ`) and the
`XXZ` line instead with `xxz: true`; TRF26 says it as `240 Z`. On the
command line `--zero-bye=` says the same.

Any other `XX` line is accepted and ignored, with a warning on stderr
naming it - an unread rule should at least be an announced one.

`XXR` and `142` are the same field: a file may carry both, but they must
**agree**, and two different counts are refused rather than silently
resolved. Every implementation resolves them differently, and the loser of
that choice is a final round paired under the wrong rules.

`260` and `250` are bbpPairings' fixed-column, round-limited siblings of
`XXP` and `XXA`. They were unimplemented until 2026-08-18, which meant
*silently discarded* - a file saying two players must never meet produced
a complete, legal-looking round that seated them together.

`XXP` carries exactly the standing of the no-rematch rule, which is how
bbpPairings expresses it too - one `forbiddenPairs` set, with no-rematch
inserted into it. One line names a group, not a pair, so `XXP 4 9 17`
forbids all three of 4-9, 4-17 and 9-17.

`XXA` is **fixed-column** and the columns are load-bearing: `XXA` at
column 1, starting rank right-aligned in columns 5-8, each round's `pp.p`
right-aligned at column `10 + 5*(r-1)`. A line one column off is rejected
outright by real bbpPairings (`Invalid line`, exit 3), and free-form `XXA`
crashes real JaVaFo with a bare `NullPointerException`.

A malformed `XXP` or `XXA` raises rather than being skipped. `XXR` is the
exception and can afford to be: a missing round count has a fallback,
while a dropped exclusion produces a complete, perfectly legal-*looking*
pairing that seats two players an arbiter said must never meet, with
nothing downstream able to detect it.

Both are validated by the same oracle as everything else: **1,789,554
rounds carrying at least one extension line, 100.00% agreement, zero
illegal rounds** across eleven axes.

## TRF26

FIDE's Tournament Report File Format Version 2026 (approved by Council on
12 May 2025, applied from 1 September 2025) is a second, complete
spelling of the same file - not an extension of TRF16 but a distinct
dialect, alongside the `:engine` dialect this document otherwise
describes. `Trf.serialize/2` writes it when called with
`dialect: :trf26`; `:engine` stays the default and is what the comparison
corpus is measured on. On the command line `-g --dialect=trf26` writes a
generated Swiss in it (the same seed is the same tournament in either
spelling; team and round-robin files are TRF26 already), and `-p`, `-x`,
`-c` and `-s` read either.

| line | meaning |
|---|---|
| `142` | number of rounds - written by both dialects; only `:engine` can swap it for `XXR` |
| `162` | a non-standard point system as one line - `:trf26` only, `:engine` uses `BB*` instead |
| `299` | free points and point-system overrides `162`/`BB*` cannot say - mostly written by both dialects; the forfeit-loss override is `:trf26` only, since `:engine` says it with `BBF` |
| `250` / `260` | acceleration and forbidden pairs (above) - written by both dialects; `:trf26` groups acceleration into ranges instead of one line per player per round |
| `240` | a bye for a round not yet paired, moved off the player's own row - `:trf26` only; `:engine` leaves it as an ordinary column |
| `192` / `202` / `212` / `222` | tournament type code, tie-breaks, standings order, time control code - written by both dialects whenever the data carries them |

The type code is checked against FIDE's own table
(`tournament_type_codes/0` and the parametrised `_Gn`/`_TxP` families;
the draft table's `FIDE_DUTCH_2026` is still accepted and means
`FIDE_DUTCH_2025`; `Ainalrami.TypeCode` says what each code means) and the
time control against its encoding
grammar (`encoded_time_control?/1`) before either line is written.

Reading does not depend on which dialect wrote the file: `parse/1` reads
all of the above unconditionally, to the same shape `XXR`/`BB*`/`XXA`/`XXP`
parse to, so a round paired from either spelling of one tournament is the
same round. Of TRF26's team records, `310` (teams with their numbers,
scores and final ranks; it takes precedence over `013`), `362` (match
points), `320` (the team pairing-allocated bye, its match and game
points), `330` (forfeited matches) and `300` (a team's board order in one
match: board 1's colour is read from it, and the team tie-breaks number
the boards by it) are read and written; `801`, `802` and national-rating
records are not read.

## Organiser deviations (not FIDE)

The options below change the pairing in ways the Dutch system (and, for
the team ones, C.04.6) does not allow. A
round paired with any of them is not a FIDE round in the homologation
sense, and a FIDE checker replaying the file will not reproduce it - no
FIDE record carries them, only this engine's own `XXO` lines, which no
other program reads. Without them the engine runs exactly the code it runs
without them, byte for byte.

- **Soft pairs** - `soft_pairs:` / `soft_position:` on `pair_next_round/2`
  and `explain_round/3`: pairs to avoid if the alternative is not worse
  (club protection, family). See the 0.20.0 changelog entry. On the CLI,
  `--soft-pairs=1,4/2,9,12 [--soft-position=weak]` with `-p` and `-x`
  (refused with `-g` and `-c`, like the bye preferences).
- **Teams kept apart** - `forbidden_pairs:` / `soft_pairs:` on
  `Ainalrami.TeamPairing.pair_round/2`, by team number, the same shapes:
  a forbidden pair is a pair that has met, a soft pair a criterion below
  [C10] that only breaks ties. See "Keeping teams apart" under the team
  events above.
- **Bye exclusions** - `bye_exclusions: [rank, ...]` on
  `pair_next_round/2`, `pair_later_round/2` and `explain_round/3`: players
  who must not receive the pairing-allocated bye this round (someone who
  travelled far, a junior with a long drive home). Each is treated exactly
  as [C2] treats a player who already had a pairing-allocated bye -
  ineligible for the bye, and for nothing else; score, colours, floats and
  every other criterion are untouched. Ranks not in the round are ignored,
  and so is the whole option on an even field.

  When the exclusions leave no legal round, `NoValidPairingError` is
  raised with `reason: :bye_exclusions`, the active excluded ranks in
  `excluded`, and in `override` one rank whose exclusion, lifted for this
  round, makes it pairable (the player who takes the bye with no
  exclusion) - so a program can offer "pair anyway, ignoring the exclusion
  for this player". A round that is impossible anyway keeps
  `reason: :no_legal_pairing`.

  `explain_round/3` puts `bye_passed_over: [%{rank:, reason:
  :organiser_exclusion}]` on the bracket holding the bye: the excluded
  players who would have had it, in the order they would have had it.
  `bye_eligibility/2` reports such a player as `:organiser_exclusion`, and
  so does `Ainalrami.Alternatives.bye_alternatives/3`.

  Validated against an exhaustive brute-force reference
  (`test/support/bye_exclusion_reference.ex`, sharing no code with the
  engine): 10,000 generated tournaments, 52,456 rounds, 0 disagreements on
  whether the round can be paired, its legality, [C5]'s bye score, the
  refusal and its override, and the passed-over account; and with no
  exclusion the engine's pairings and explanations are identical to the
  previous release's on 8,593 generated rounds. See `docs/validation.md`.

- **Bye preferences** - `bye_preferences: [{rank, preference} |
  {rank, preference, rounds}]` on `pair_next_round/2` and `explain_round/3`,
  resolved by `Ainalrami.ByePreference.pair/2`, which also returns an
  account of what each did. `preference` is `:want_hard` (must get the
  bye, if the rest can still be paired under the absolute criteria),
  `:want_soft` (rather gets it), `:avoid_hard` (must not - exactly a bye
  exclusion, refusal and override included) or `:avoid_soft` (rather not);
  `rounds` a list of round numbers, or `:all`.

  **Where the soft ones sit.** Where a `:strong` soft pair does: below the
  ladder's top rung - the absolute criteria, the round's completion, and
  the bye's own rules (C2; C4/C5, the bye to the lowest score that lets the
  rest be paired) - and above every quality criterion, C6-C21 (C9 included)
  and the ordering rule. They never move the bye to a higher score group,
  never give it to a player C2 rules out, and never make a round
  unpairable. There is no `:weak` position: below C21 there is practically
  never a choice of bye holder left.

  **How.** Every setting becomes bye exclusions, so the rule that decides
  who may take the bye stays `eligible_for_bye?/1` - which the certified
  and direct-bracket shortcuts are proved against. A want pairs the round
  with every other active player excluded; a soft want keeps that round
  only if its bye holder has the bye score of the round without it; a soft
  avoid excludes the holder while the holder is someone to avoid and keeps
  the last round still on that score.

  **Precedence and conflicts.** Per player: a hard avoid (including a
  `bye_exclusions` entry) beats any want, a hard want beats a soft avoid, a
  soft want and a soft avoid cancel out. Across players: hard wants first
  (with several, the FIDE criteria choose among them), then soft wants, then
  soft avoids. An even field and a player not in the round are skipped, as
  is a soft want for a player C2 rules out; a HARD want for a player C2
  rules out (a second pairing-allocated bye) refuses the round with
  `Ainalrami.ByePreference.RefusedError`, naming the player and the round
  of their earlier bye. Each other case is an outcome in the report (`:honoured`,
  `:no_bye_this_round`, `:not_in_round`, `:ineligible`, `:conflict`,
  `:unpairable`, `:other_player`, `:outranked`), with `moved` (whether the
  preferences changed the round), `fide_bye` (who had it without them) and
  `opts` (the options with the preferences resolved - what
  `explain_round/3` and `Ainalrami.Alternatives` must be given;
  `explain_context/3` refuses them unresolved). `explain_round/3` resolves
  them itself and puts the account on the bye's bracket as `bye_preference`.
  A player a preference kept from the bye is `:bye_preference`, not
  `:organiser_exclusion`, in `bye_eligibility/2` and "why not me"
  (`Alternatives.bye_alternatives/3`), through `:bye_preference_exclusions`
  in the resolved `opts`.

  Validated against the exhaustive bye reference: 5,000 generated
  tournaments with random preferences on every round, 0 disagreements on
  pairability, legality, who gets the bye and on which score, for each
  setting and each conflict (`test/ainalrami/bye_preference_validation_test.exs`);
  the direct-bracket and certified paths agree with the full path on large
  fields (`tools/bye_pref_direct.exs`); and without preferences the engine
  is byte-identical to before on the differential corpus. See
  `docs/validation.md`.

## What is not settled

Documented rather than hidden, because an engine claiming 100% owes an
account of where it could still be wrong:

- **Article 4 for a bracket in the middle of a round.** The regulations
  pair a bracket by generating candidates in a defined sequence and taking
  the best, with "generated earlier" as the final tie-break. This engine
  solves a maximum-weight matching instead, reaching the same optimum
  without enumerating.

  Most of this is now settled. 4.2's transposition order is proven
  identical to the engine's tie-break key; 4.3's exchange order is tested
  on a position where exchanges are the only route to a legal pairing and
  over forty random brackets enumerated in full Article 4 order; and 3.7's
  two-stage **heterogeneous** case - MDP-Pairing outside, remainder inside
  - is tested too. The engine returns the earliest-generated best candidate
  every time.

  Each of those holds the bracket fixed by making it the **last** one, so
  no candidate reaches an edge into a lower group and the scores stay
  comparable. A bracket that both inherits moved-down players *and* floats
  players onward is therefore still checked only through the corpus. That
  is a limit of the method, not a known divergence: comparing candidates
  that float different players needs an ordering the rules do not define.

This has never produced a measured disagreement. "Not observed" is not
"cannot happen", and it is the only place left in the pairing itself where
one could come from.

## A dispute this engine lost

Promoted out of "what is not settled" on 2026-08-27, because it is settled
now - against us.

**Article 5.2.5 - which number the parity is taken on.** This engine took
it on the TPN exactly as the file gives it. Both references take it on a
numbering that skips players who have never been paired. On 2026-08-27 the
FIDE Systems of Pairings and Programs Commission answered the question:
the references are right and Ainalrami was wrong. The engine has been
changed to match.

The crux is worth stating plainly, because both sides argued from the
**same sentence**. C.04.2:2.4 says a late entry is *"given an appropriate
TPN and paired only when they actually arrive."* This engine read that as:
the TPN exists before the arrival, and it is the pairing that waits. The
SPP reads the identical clause as *"players who have yet to arrive don't
have a TPN."* We read it the wrong way round.

The superseded argument, kept because it is why the engine behaved this
way for months: C.04.2 Article 2 fixes a TPN for the tournament, moving it
only for a ranking-data correction (barred after round four) or the
closing of the participant list, and nothing in either article renumbers
around players sitting a round out. That reading was rejected.

**There is a second retraction, and it is the worse one.** The other named
reason for not complying was a claim, published in
docs/dispute-initial-colour.md, that the two references renumber
differently *from each other* - "so agreeing with the references is not
even a well-defined target". They do not differ; they agree, as the next
paragraph says. That claim was false when written: a pre-probe hypothesis
printed as a finding, refuted by this project's own `tools/rip_probe.exs`
in the same document's own evidence section, and re-confirmed against the
local binary on 2026-08-27. It was load-bearing in three places - the
decision not to fix, this README, and a test harness's classifier, which it
weakened.

What was measured stands. The two references agree with each other -
Gacrux does not break this tie the way it breaks the other one - and they
skip players who have never participated, not players who have played and
are merely absent this round. On a full field all three engines always
agreed; they diverged only once somebody had been registered without ever
being paired. Colour is allocated *after* the pairing, so none of it ever
moved a player to a different board: every axis reports 100.00% pairing
agreement and zero illegal rounds.

Measured over 200 seven-round tournaments, **before the fix**. These are
boards where this engine was wrong, not boards where it was different:

| axis | boards differing (old engine) |
|---|---|
| plain, forfeits, `XXP`, Baku | **0** |
| 15% arbiter byes, `152 W` | 670 → **0** |
| 15% arbiter byes, `152 B` | 1175 → **0** |

Re-measured on 2026-08-28, on the same seeds: **750,449 rounds, 7,392,594
boards, zero colour differences** against bbpPairings. A second corpus on
different seeds agrees at larger scale. The two boards where the two
REFERENCES contradict each other survived the re-run on the same two axes,
which is the control that says the instrument still sees what it used to.
The full account, with the handbook text, the ruling and a reproducible
probe, is in
[docs/dispute-initial-colour.md](docs/dispute-initial-colour.md).

## Documentation

| document | what it is |
|---|---|
| [docs/architecture.md](docs/architecture.md) | how the engine is put together, module by module |
| [docs/validation.md](docs/validation.md) | the measurement record and how it was produced |
| [docs/conformance-c0403-2026.md](docs/conformance-c0403-2026.md) | article-by-article verification against the 2026 rules text |
| [docs/fide-criteria.md](docs/fide-criteria.md) | the maintained rules-to-code map (C1-C21) |
| [docs/dispute-seed735265.md](docs/dispute-seed735265.md) | the one disagreement, argued from the regulations |
| [docs/bbppairings-c2-bug-report.md](docs/bbppairings-c2-bug-report.md) | that dispute as a submittable upstream report |
| [docs/dispute-initial-colour.md](docs/dispute-initial-colour.md) | the Article 5.2.5 dispute this engine lost, and the SPP ruling that closed it |
| [docs/finding-gacrux-5-2-4.md](docs/finding-gacrux-5-2-4.md) | RETRACTED: the Gacrux 5.2.4 finding was a harness artefact (no `-n R`) |
| [docs/finding-gacrux-5-2-5.md](docs/finding-gacrux-5-2-5.md) | RETRACTED: the Gacrux 5.2.5 finding was the same artefact |
| [docs/conformance-c0406-teams.md](docs/conformance-c0406-teams.md) | team Swiss (C.04.6): readings, verification method, no colour preferences |
| [docs/team-proof-large-fields.md](docs/team-proof-large-fields.md) | the exact whole-round reference for team fields up to 80 teams |
| [docs/conformance-c07-tiebreaks.md](docs/conformance-c07-tiebreaks.md) | tie-breaks (C.07): every reading taken |
| [docs/tiebreak-reference.md](docs/tiebreak-reference.md) | the independent tie-break reference and its results |
| [docs/finding-tiebreakserver-2026-09.md](docs/finding-tiebreakserver-2026-09.md) | where TieBreakServer and C.07 part company (findings A-H) |
| [docs/engineering-log.md](docs/engineering-log.md) | the dated build history, including what measured worse |
| [docs/cli-parity.md](docs/cli-parity.md) | every library option against its flag and its record |
| [docs/pairing-proofs.md](docs/pairing-proofs.md) | per-round optimality certificates (`--proof`) and their independent verifier |
| [TODO.md](TODO.md) | open work |

## Development

```bash
mix test
```

About 1,130 tests. Comparison tests against JaVaFo and Gacrux are tagged and
excluded by default - neither is vendored, and both must be supplied
locally. See [docs/validation.md](docs/validation.md) for how to point the
harness at them and how to run the large fuzz axes.

## Relationship to OpenPairings

Ainalrami is the sibling project to
[OpenPairings](https://github.com/teapot-chess/openpairings), an
Elixir/Phoenix tournament manager, where it is the **default Swiss pairing
engine**, running in-process with nothing to install beside the app.
JaVaFo remains available there as an optional alternative, for organisers
who want the engine their federation or software vendor already
endorses, or who want a second opinion on a round.

Ainalrami is also meant to stand alone: experimentation with pairing
variants JaVaFo doesn't expose, and an independent data point for
cross-checking pairing correctness against any other engine.

## License

[Apache License 2.0](LICENSE) - deliberately the same licence as
[bbpPairings](https://github.com/BieremaBoyzProgramming/bbpPairings),
because parts of this engine are derived from it. `Ainalrami.Pairing`'s
bracket cascade is a stage-for-stage port of `dutch.cpp`, and
`Ainalrami.WeightedMatching`'s control flow was read directly from
bbpPairings' matching sources while writing the Elixir equivalent.

No bbpPairings code is reproduced here - it is C++ and this is Elixir -
but the algorithm and structure are theirs, originating file and line
numbers are cited inline throughout, and matching their licence is the
cleanest way to honour that rather than leaving it ambiguous.
[NOTICE](NOTICE) spells out exactly which files are derived and what
changed.

Deliberately permissive: a pairing engine is only worth anything if other
people can check it, run it against their own tournaments and disagree with
it in public. Use it, fork it, ship it in something commercial - the terms
ask only that you keep the notices. Copyright 2026 Jorian Burssens.

The vendored bbpPairings binaries and JaVaFo are covered separately; see
[NOTICE](NOTICE).

# ainalrami-lab

A rule-change simulator for the Dutch system (C.04.3, 2026 edition). It
takes the quality criteria apart into named pieces, lets you drop,
reorder or re-read them, replays a corpus of tournaments under the 2026
text and under the variant, and reports what changed, with 95%
intervals and example rounds.

    cd lab
    mix deps.get
    mix escript.build                         # ./ainalrami-lab

    ./ainalrami-lab criteria                  # the pieces, with their articles
    ./ainalrami-lab simulate --variant drop:C12 \
        --corpus generated:players=10,rounds=7,count=1000,absent=0.05,forfeit=0.03 \
        --out runs/drop-c12
    ./ainalrami-lab simulate --variant float_memory=1 --corpus trf:path/to/trfs
    ./ainalrami-lab pair round.trf --variant c525=tpn
    ./ainalrami-lab fidelity --corpus generated:players=60,rounds=9,count=50 --against engine

It answers questions about the **rules**, not about the engine. The
engine's conformance is `verify/`'s business.

## Where this lives, and why

A sibling Mix project next to `verify/`, not inside the engine and not
inside `verify/`.

* **Not in the engine.** The engine pairs by the 2026 text and nothing
  else; a pairing program with a "drop C12" switch is a pairing program
  that can be misconfigured. `../mix.exs` does not know `lab/` exists,
  compiles nothing from it and ships nothing from it. No engine code was
  added or changed for it.
* **Not in `verify/`.** `verify/` is the auditor: one fixed reading of the
  rules, against which the engine is judged. Giving the auditor a dial
  that changes its reading would make every verdict conditional on the
  dial's position, and a test that asks "is the dial at zero?" is a test
  nobody should have to write. The lab needs exactly the opposite: a
  reading that is meant to be changed. So `verify/` stays fixed and the
  lab depends on it.
* **What the lab reuses from `verify/`**: the TRF reader, the position
  model (`AinalramiVerify.Position`), the brute-force search primitives
  (`AinalramiVerify.Bracket`: candidate listing, completion, the Article
  4 sequence key), the TRF writer, and `AinalramiVerify.Engine`, the one
  module that calls the engine. **What it replaces**: the scoring
  (`AinalramiLab.Criteria`, one function per criterion), legality and
  colour allocation with the variant's parameters (`AinalramiLab.Rules`,
  kept line for line parallel to `AinalramiVerify.Rules`), and the
  weights of the hybrid pairer (`AinalramiLab.Hybrid`, parallel to
  `AinalramiVerify.Weights`).
* **Dependencies run one way**: `lab -> verify -> engine`, all by path, so
  a lab build always uses the engine and the reference in the same
  checkout.
* **Its own CI job and escript**, like `verify/`.

## Variants

Operations joined by `+`, applied left to right (`AinalramiLab.Variant`):

| operation | effect |
|---|---|
| `baseline` | the 2026 text, read as `verify/` reads it |
| `drop:C12`, `drop:C12,C13` | remove criteria from 3.8.1's comparison |
| `move:C14:before:C10`, `move:C12:after:C21`, `swap:C10:C12` | reorder |
| `absolute_cd=N` | 1.7.1: absolute when \|CD\| > N (text: 1) |
| `streak=N` | 1.7.1: absolute after the same colour N times running (text: 2) |
| `float_memory=N` | float history C14-C21 look back on: 1, 2 (text) or 3 rounds; 3 adds `C16@3`, `C17@3`, `C20@3`, `C21@3` after C21 |
| `c525=arrival\|tpn\|initial` | 5.2.5's number: the arrival numbering (the SPP's reading, baseline), the TPN, or none (the higher-ranked player always takes the initial colour) |
| `c18=limbo\|paired` | [C18]/[C20]: an MDP left in the Limbo counts (baseline) or only paired MDPs count |
| `c13=strong_or_absolute\|strong_only` | [C13]: which denied preferences count |
| `c3=on\|off` | [C3] |
| `rematches=forbidden\|allowed` | [C1]; not a proposal, a way to price [C1] |

[C8]'s look-ahead ("the following bracket can comply with [C1]-[C7]")
is always measured with [C5]-[C7] in their 2026 order, whatever the
variant does to them.

## The simulation

`AinalramiLab.Simulate`. For a **generated corpus**, each tournament is
played twice from the same seed, once per arm. Results come from a
rating model with **common random numbers**: a game's result depends only
on the seed, the round and the two players, so where the arms make the
same pairing they get the same result and part only where the rule
change parts them. The per-tournament differences are therefore paired,
and their interval is `mean ± 1.96·sd/√n`. Along the baseline's own
trajectory every position is also paired under the variant, which gives
"how often does the variant change a round in the same position"
(Wilson interval) and the example diffs.

Corpus parameters: `players`, `rounds`, `count`, `absent` (per player
and round from round 2, a requested `H` or `Z`), `forfeit` (per board,
`+`/`-`), `late` (that many players, spread through the ranking, arrive
in round 3 with `Z` in rounds 1-2), `initial` (`w`/`b`).

For a **TRF corpus**, every recorded round of every file is a position
(the history before it, plus requested byes already entered for it);
each is paired under both arms and compared. Files `verify/` refuses
(acceleration, forbidden pairs, other point systems, team records) are
skipped. A file has one history, so there are no trajectory metrics.

Metrics are measured on a fixed yardstick, the 2026 text's own
definitions, whatever the variant: `AinalramiLab.Metrics` has the table.
They include the third-same-colour rate, final colour imbalance,
denied preferences, floats per player, boards across a point or more,
repeated floats, the longest chain of consecutive brackets passing
downfloaters on, the score gaps of the boards, meetings among the top
seeds, rematches, and 5.2.5 boards and how many of them the numbering
decides.

## Pairers and their limits

| pairer | exact? | size | variants |
|---|---|---|---|
| `brute` (`AinalramiLab.Brute`) | `verify/`'s reference, exactly | about 10 players: round 1 of 10 takes 0.26 s, of 12 takes 6 s, of 14 takes 4.5 min (one bracket of n is the worst case) | all |
| `hybrid` (`AinalramiLab.Hybrid`) | criteria exact by construction; Article 4's order encoded term by term, measured not proved | tested to 100 players; a 40-player, 9-round tournament takes well under a second per round | all |
| `engine` | is the engine | any | baseline only |
| `auto` (default) | brute to 10 players in the pool, hybrid above | | all |

**Why a hybrid at all, and why this one.** The engine's weight function
is internal to `Ainalrami.Pairing` and exposes nothing read-only that a
variant could plug into; making it pluggable would change the engine.
What the engine does expose is its matcher, and `verify/` already has an
independent encoding of C.04.3 as matching weights (the one certificates
are checked against). The hybrid is that encoding with each criterion a
separate digit in the variant's order, plus digits for Article 4's order,
solved per bracket stage with the engine's matcher through
`AinalramiVerify.Engine`. So the large-field pairer is "the engine's
structure" in the sense that matters (maximum-weight matching per
bracket, as the engine pairs) without borrowing the engine's weights.

**Measured fidelity** (`fidelity`, local, 2026-11-08):

| hybrid compared with | corpus | variant | rounds | differing | 95% upper bound |
|---|---|---|---:|---:|---:|
| brute force | 10 x 7, 500 tournaments | baseline | 3,500 | 0 | 0.11% |
| brute force | 10 x 7, 300 | `drop:C12+streak=3` | 2,100 | 0 | 0.18% |
| brute force | 10 x 7, 300 | `move:C12:after:C21+float_memory=1` | 2,100 | 0 | 0.18% |
| brute force | 10 x 7, 300 | `c3=off+drop:C13` | 2,100 | 0 | 0.18% |
| brute force | 10 x 7, 300 | `move:C14:before:C10+float_memory=3` | 2,100 | 0 | 0.18% |
| brute force | 10 x 6, 300, late entries | `c525=tpn` | 1,800 | 0 | 0.21% |
| Ainalrami engine 0.51.1 | 40 x 9, 100 | baseline | 900 | 0 | 0.43% |
| Ainalrami engine 0.51.1 | 100 x 11, 40 | baseline | 440 | 0 | 0.87% |

Both arms of a comparison always use the same pairer, so an error of the
hybrid would be common to baseline and variant; but an error that
depends on the variant would not cancel, which is why it is measured
under variants too.

**What the lab cannot do.** It reads Dutch only, with 1/½/0 scoring, no
acceleration and no forbidden pairs (`verify/`'s reader refuses them).
Variants act on the quality criteria, the colour-preference thresholds,
5.2.5's number and three readings; the absolute criteria other than
[C1]/[C3] and Article 5.2.1-5.2.4 are fixed. The results model is a
simple rating model, good enough to produce realistic scoregroups and
no more. The brute force tops out at about 10 players, so variant effects
on large fields rest on the hybrid.

## Tests

    mix test

* the baseline equals `AinalramiVerify.Bracket.pair/1`, colours
  included, on every `verify/` fixture and on generated positions with
  byes, forfeits and late entries; its legality, colours, colour costs
  and full criteria vector equal `verify/`'s for every candidate tried;
* dropping a criterion changes the `verify/` article fixture built to
  need it (C7, C8, C13-C16, C18, C20, C21), and the eight where a lower
  criterion or Article 4 lands on the same round are pinned as such;
* `c525=tpn` changes colours and never pairs; the baseline against
  itself differs nowhere;
* the hybrid equals the brute force under the baseline and seven
  variants, and the engine on a 24-player field;
* the CLI, the reports, the statistics.

## Big runs (the 80-core VM)

    cd lab && MIX_ENV=prod mix escript.build
    tools/paper_runs.sh runs/paper-vm 20 78          # every variant in the paper, 20x the local corpora
    ./ainalrami-lab fidelity --corpus generated:players=10,rounds=7,count=20000,absent=0.05,forfeit=0.03 --against brute --workers 78
    ./ainalrami-lab fidelity --corpus generated:players=100,rounds=11,count=2000,absent=0.05,forfeit=0.03 --against engine --workers 78

`tools/paper_runs.sh` skips runs whose report exists, so a stopped run
resumes. Use `nohup` or `tmux`.

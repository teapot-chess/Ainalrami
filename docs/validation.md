# Validation

How Ainalrami is measured, what the numbers are, and - the part that
matters most - what the measurements could not have seen.

The headline is in the [README](../README.md). This document is the
methodology behind it and the reasoning that makes it worth anything.

## Summary

What each part of the engine is checked against, and how much of it. The
sections below and the linked documents have the method, the limits and
every known difference.

| area | compared against | size | result | detail |
|---|---|---|---|---|
| Individual pairings (C.04.3), our generator | bbpPairings 6.0.0 | 2,536,328,265 pairings, 217,470,056 rounds, 6 corpora | 2 disagreements, both a bbpPairings [C2] defect | [The corpora](#the-corpora) |
| Individual pairings, three engines | bbpPairings and Gacrux | 649,207 rounds | agrees with bbpPairings on every round; never the odd one out | [The three-way run](#the-three-way-run-2026-08-27) |
| Individual pairings, Gacrux alone (030bd28) | Gacrux | 373,500 tournaments, 3,219,728 rounds, 119,064,367 boards | 0 disagreements | [Against Gacrux alone](#against-gacrux-alone-32-million-rounds-2026-09-30) |
| Individual pairings, 0.36.0 release check (be3ae86), partial | Gacrux; bbpPairings | 1,014,700 rounds; 10,614,756 rounds | Gacrux: 258 disagreements judged by rule, this engine legal in every well-formed one, Gacrux illegal in 257 (1 ambiguous input); bbpPairings: 1, a bbpPairings C2 defect | [Release check for 0.36.0](#release-check-for-0360-2026-10-02) |
| Individual pairings, bbpPairings' generator (Q33 direction 2) | bbpPairings' own `-g` tournaments, checked here | 50,045 tournaments, 499,816 rounds, 28,964,816 pairings | 0 composition, 0 colour disagreements | [Pairings (Q33)](#pairings-vcl4thp-q33-both-directions) |
| bbpPairings' "no legal pairing" answers, 11-40 players | perfect-matching oracle (networkx blossom and Tutte rank), cross-checked against enumeration to 12 players | 3,839 refusals in 10,000 tournaments, 101,736 positions cross-checked | 0 disagreements; the full 46,052-refusal probe axis was not re-run | [Refusals above 12 players](#refusals-above-12-players-by-matching-2026-10-12) |
| Team Swiss whole rounds (C.04.6), 4-10 teams | brute-force reference written from the regulation | seeds 1-860,000,000, 3,553,445,286 rounds (two runs) | 0 failures, 0 errors | [Team Swiss pairings](#team-swiss-pairings-c046) |
| Team Swiss whole rounds, 11-80 teams | exact engine-independent reference | 2,000 seeds, 11,980 rounds | agrees; one 3.6 candidate-budget disagreement found and fixed (0.30.0) | [team-proof-large-fields.md](team-proof-large-fields.md) |
| Team Swiss, no colour preferences (1.7) | brute-force reference | 30,000 seeds, 123,593 rounds | 0 disagreements | [conformance-c0406-teams.md](conformance-c0406-teams.md#no-colour-preferences-17-2026-09-27) |
| Individual tie-breaks (C.07) | FIDE's TieBreakServer, both directions | 50,060 tournaments (~29 million values) and 50,000 (49,987,100 values); random lists 10,000 each way | 0 unexplained | [Tie-breaks](#tie-breaks-c07-effective-1-march-2026-against-tiebreakserver) |
| Individual tie-breaks | independent reference (`Ainalrami.TiebreakReference`) | 15,000 events, 8.3 million values; 5,000 events, 2,760,888 values after the team extension | 0 disagreements | [tiebreak-reference.md](tiebreak-reference.md) |
| Team tie-breaks | TieBreakServer | 20,000 events: fixed list 1,290,920 values, random lists 352,388 values; Swiss, round robin, Scheveningen, Schiller, 3-10 boards | 0 unexplained; TieBreakServer findings F, G, H | [Team events, extended](#team-events-extended-2026-09-26) |
| Team tie-breaks | independent reference | 10,000 team events, 3,975,739 values | 0 disagreements | [tiebreak-reference.md](tiebreak-reference.md) |
| Tie-breaks, every night | TieBreakServer (pinned) and the reference | fresh seeds each night | a failure names the seed | [The nightly check](#the-nightly-tie-break-check) |
| Tie-breaks on real events | 43 SWAR tournaments, re-ranked by OpenPairings | 43 tournaments | no Ainalrami bug; every difference attributed to SWAR | [Real tournaments](#real-tournaments) |
| Individual pairings, control | JaVaFo (2017 rules) | 2,000 + 1,600 tournaments over five axes | 83.68%-100.00% of rounds exact by axis, as expected for the older edition | [The references](#the-references) |

Team pairing has no automatable outside oracle (bbpPairings, JaVaFo, Gacrux
and SWAR do not pair teams; see
[conformance-c0406-teams.md](conformance-c0406-teams.md#verification-no-reference-we-can-automate-against)),
so its references are written here from the regulation text and share no
code with the engine. They prove the computation, not the reading.

## The references

Three external implementations, used for different purposes.

| engine | rules edition | role |
|---|---|---|
| **bbpPairings 6.0.0** | 2026 | the primary oracle; run directly, not read |
| **Gacrux / TieBreakServer** | 2026 | independent third opinion; Python, literal enumeration |
| **JaVaFo** | 2017 | a *control*, not a target |

None is vendored. Each is located at runtime:

```bash
BBPPAIRINGS_EXE=/path/to/bbpPairings   # required for --only bbppairings
JAVAFO_JAR=/path/to/javafo.jar         # required for --only javafo
GACRUX_DIR=/path/to/TieBreakServer     # required for --only three_way
GACRUX_PYTHON=python3
```

**Why bbpPairings is the primary oracle and JaVaFo is not.** JaVaFo is
FIDE's own reference implementation, which makes it the intuitive target
and the wrong one: it implements the 2017 edition, superseded on
31 January 2026. bbpPairings and Gacrux both implement the 2026 edition.
Over 3352 rounds those two agreed with each other on **every single
one**, which bounds their mutual
disagreement at ~0.09% and is what makes them usable as a ruler at all.

Ainalrami disagrees with JaVaFo, and that is the expected result rather
than a defect - it is the size of the rules change. An engine agreeing
with all three simultaneously would prove the harness was measuring
nothing.

**How much it disagrees depends entirely on the axis**, which one figure
cannot say. This page carried a bare "96.26%" for a while, unattached to
any axis; measured per axis on 2026-08-26, with the real jar and zero
process errors:

| axis | tournaments x rounds | exact rounds | individual pairs |
|---|---|---|---|
| round one only | 2000 x 1 | **100.00%** | 100.00% |
| plain | 400 x 5 | **98.82%** | 99.62% |
| 10% arbiter byes | 400 x 5 | **91.22%** | 97.68% |
| 10% forfeits | 400 x 5 | **89.60%** | 97.38% |
| both | 400 x 5 | **83.68%** | 95.19% |

Round one is identical, which is what you would expect of a rules change
that lives in the bracket cascade rather than the initial split. Every
axis that puts an UNPLAYED game on a scorecard - a bye, a forfeit - is
where the 2017 and 2026 texts part company, and it compounds with the
round count. The same axes measure 100.00% against bbpPairings, which is
the whole reason bbpPairings is the oracle here and JaVaFo is the control.

Note also that this harness reads only seven of the sixteen
`PAIRING_FUZZ_*` knobs (it predates `Ainalrami.Test.FuzzTournament` and
has its own generator); since 2026-08-26 it REFUSES the other nine rather
than reporting the default axis's rate under their name.

## The corpora

Six of them now, run between 2026-08-20 and 2026-08-24. The totals every
other number on this page sits inside:

| run | axes | rounds | individual pairings | disagreements |
|---|---|---|---|---|
| Round sweep, R=1..20 (08-23) | 20 | 59,966,505 | 684,901,202 | 0 |
| Cross-axis (08-23) | 25 | 35,436,044 | 474,685,328 | 0 |
| Rating shape / withdrawals / tiny fields (08-24) | 16 | 25,209,754 | 285,118,044 | 0 |
| Randomised corpus (08-23) | 4 | 7,898,024 | 116,251,032 | 0 |
| Six-million run (08-20) | 17 | 44,486,465 | 488,033,862 | 2 |
| Same axes, disjoint seeds (08-21) | 17 | 44,473,264 | 487,338,797 | 0 |
| **total** | **99** | **217,470,056** | **2,536,328,265** | **2** |

The last row is a replication, not new coverage: the same seventeen axes
on a different build of this engine - so the 99 axis-runs are 82 distinct
ones. It is evidence that the matching optimisation is correctness-neutral,
not evidence about the rules.

The 08-20 corpus is written up in full below. Per-axis detail for the four
later runs is in [engineering-log.md](engineering-log.md), under their own
dates.

**A seventh, on 2026-08-26**, re-measuring after the sweep's thirteen
fixes. Small next to the table above and deliberately so - its job is to
show the fixes cost nothing, not to add coverage:

| axis | rounds | individual pairings | refused | illegal | disagreements |
|---|---|---|---|---|---|
| everything on, 4-40, 6000x9 | 47,882 | 386,562 | 0 | 0 | 0 |
| small fields 4-10, 40000x9 | 245,952 | 863,316 | 0 | 0 | 0 |
| deep rounds 4-40, 2000x16 | 27,271 | 311,987 | 0 | 0 | 0 |
| **total** | **321,105** | **1,561,865** | **0** | **0** | **0** |

"Everything on" is every axis the harness has at once: mixed point
systems, mixed acceleration, mixed initial colour, 12% arbiter byes, 10%
forfeits, 8% withdrawals, 8% forbidden pairs and mixed rating shapes.

Worth saying plainly what that does and does not prove. Two of the thirteen
fixes are invisible to any corpus this generator can produce - the
`0000 - +` / `0000 - -` scoring split (the generator only ever writes `-`
against a real opponent) and the short serialized line (the corpus never
serializes a round in progress). A third, the negative blossom duals, was
happening 734 times per 800 nine-round tournaments while the engine agreed
with bbpPairings on all 800. A clean corpus after a fix is evidence the fix
broke nothing. It is not evidence the fix was unnecessary, and for these
three it could never have been the thing that found them.

**The limit of all of it.** Every one of those 2.5 billion pairings is
measured against a SINGLE oracle, and agreement with one reference cannot
detect a rule both engines read the same wrong way. The only instrument
that can is the three-way harness, and it has run 649,207 rounds - see
[The references](#the-references) for what that does and does not bound.

## The corpus

**5,993,000 tournaments, 44,486,465 rounds, 488,033,862 individual
pairings, two disagreements** - the 2026-08-20 run on a 36-core machine,
seventeen axes, ~15 hours. Neither disagreement is a defect here: both are
the bbpPairings [C2] second-bye defect, and Gacrux returns this engine's
answer on both (see below).

| axis | tournaments | rounds | individual pairs | disagreements |
|---|---|---|---|---|
| 300-500 players, byes | 3,000 | 27,000 | 4,871,001 | 0 |
| 150-250 players, byes | 30,000 | 270,000 | 24,357,105 | 0 |
| 150-250, byes+forfeits+`XXP`+Baku | 10,000 | 90,000 | 8,128,884 | 0 |
| 60-120 players, byes | 200,000 | 1,800,000 | 73,378,553 | 0 |
| 60-120, byes+forfeits+`XXP`+Baku | 100,000 | 900,000 | 36,689,898 | 0 |
| 4-40, byes+forfeits+`XXP`+Baku | 400,000 | 3,334,635 | 35,022,819 | 0 |
| 4-40, 15% byes | 600,000 | 5,037,730 | 50,883,196 | 0 |
| 4-40, 10% forfeits | 300,000 | 2,518,015 | 29,805,864 | 0 |
| 4-40, 20% forbidden (`XXP`) | 300,000 | 2,477,490 | 29,656,258 | 0 |
| 4-40, random acceleration | 300,000 | 2,516,311 | 26,897,840 | **1** |
| 4-40, Black drawn first | 300,000 | 2,526,740 | 25,473,925 | 0 |
| 4-40, plain | 300,000 | 2,529,979 | 29,866,857 | 0 |
| 4-40, 8 rounds | 300,000 | 2,270,382 | 22,727,208 | 0 |
| 4-40, 10 rounds, combined | 200,000 | 1,825,095 | 19,327,331 | 0 |
| 4-40, 13 rounds | 150,000 | 1,721,955 | 17,954,308 | 0 |
| 4-10, 15% byes | 2,000,000 | 11,644,432 | 40,827,511 | **1** |
| 4-10, plain | 500,000 | 2,996,701 | 12,165,304 | 0 |

**Zero illegal rounds across all seventeen.** Legality is checked
independently of agreement - it is the question with a right answer,
where "does bbpPairings pair it the same way" is not.

### Replication on fresh seeds, post-optimisation

**5,993,000 tournaments, 44,473,264 rounds, 487,338,797 individual
pairings, ZERO disagreements** - the 2026-08-21 run, same seventeen axes,
same machine, ~14.7 hours.

Two things differ from the run above, and both are the point of having
done it:

* **Different engine.** This ran on `adae426`, which makes `finalize_pair`
  a pure edge removal and skips `prepare_vertex` - a matching-layer
  optimisation, i.e. exactly the kind of change that can be correct on
  every test and still wrong on the millionth bracket. It is not.
* **Disjoint seeds** (from 9,000,001), so this is an independent corpus
  rather than a re-run of the same tournaments.

The round and pairing counts differ slightly from the first run for the
same reason the seeds do: how early a small field exhausts its legal
opponents is seed-dependent, so the same axis definition yields a
marginally different amount of work each time.

**Zero disagreements does not mean the [C2] defect is gone.** Both
disputes above were bbpPairings defects on specific seeds; fresh seeds
simply did not land on that configuration again. bbpPairings is unchanged
and still wrong there, which is why all three disputes stay pinned as
regression tests rather than being treated as resolved by this run.

One caveat on the headline count, which applies to both runs equally:
2,724,198 tournaments (45.5%) ended early because bbpPairings ran out of
legal pairings - overwhelmingly in the 4-10 player axes, where nine rounds
is arithmetically impossible without repeats (88.2% of `4-10, 15% byes`
and 78.2% of `4-10, plain` terminated early). Those tournaments are
excluded from the rates, so agreement is measured up to exhaustion and
not about it: if this engine were willing to pair a round bbpPairings
declines, these axes could not show it.

**That gap is now measured. See below.**

### The three-way run (2026-08-27)

The weakest number on this page was three-way agreement: 3,352 rounds
against 217 million two-way. Everything else rests on bbpPairings being
right, and this was the only instrument that could catch a rule both
engines read the same way wrong.

Eight axes, 649,207 rounds compared by all three engines - **194 times the
previous coverage**. A ninth axis was void: it was run alongside another
job on the same box and failed on reference processes not launching, which
is the resource-starvation failure this harness's own moduledoc warns
about. It is being re-run alone rather than quoted.

**Composition. Ainalrami agreed with bbpPairings on 649,207 of 649,207
rounds - 100.00% on every axis.** The two disagree nowhere.

The three engines are not unanimous, and the pattern is the point:

| axis | bbpPairings vs Gacrux | Ainalrami vs bbpPairings |
|---|---|---|
| 12% byes | 83,981/83,988 | 83,988/83,988 |
| 10% forfeits | 83,886/83,898 | 83,898/83,898 |
| everything Gacrux allows | 80,561/80,679 | 80,679/80,679 |
| the other five axes | 100% | 100% |

137 rounds where the references disagree with each other, and in every one
of them Ainalrami is on bbpPairings' side. There is no round in 649,207
where Ainalrami is the odd one out.

### Colour, measured three ways for the first time

`same?/2` compares through `normalize/1`, which sorts each pair's ranks, so
every number this harness had ever reported was colour-blind - the same gap
that hid a missing Article 5.2.4 through 195 million pairings in the
two-way harness. It now carries three pairwise colour rates over the boards
each PAIR of engines both formed.

**6,242,974 boards.** Ainalrami against bbpPairings: 6,178,843 agreed,
64,131 differing, every one of them falling under what was then the open
Article 5.2.5 dispute.

#### Those figures describe behaviour that has been removed

**They are the last actual measurement, and they are superseded.** On
2026-08-27 the FIDE Systems of Pairings and Programmes Commission answered
the question this project had put to it, and answered it against this
engine: Article 5.2.5's parity is taken on a numbering that skips players
who have never been paired, not on the TPN as C.04.2 Article 2 defines it.
Both references were right. Ainalrami was wrong.

The crux is that both sides argued from the same sentence. C.04.2:2.4 says
a late entry is *"given an appropriate TPN and paired only when they
actually arrive."* This project read that as: the TPN exists before the
arrival, and it is the PAIRING that waits. The SPP reads the identical
clause as: players who have yet to arrive don't have a TPN. We read it the
wrong way round. The reasoning is kept in full in
[dispute-initial-colour.md](dispute-initial-colour.md), marked as
superseded rather than deleted, because it is why the engine behaved this
way for months.

So the 64,131 are not 64,131 documented divergences. They are 64,131 boards
on which this engine was wrong. The claim that used to stand here - that
this was the strongest statement the project had about Article 5 - is
withdrawn outright.

#### Re-measured 2026-08-28: the 64,131 are zero

The corpus was re-run on the fixed engine, on **the same seeds**, and the
64,131 are gone.

| | rounds | boards | Ainalrami vs bbpPairings |
|---|---|---|---|
| `threeway_run`, pre-fix, 8 axes | 649,207 | 6,242,974 | 6,178,843 agreed, **64,131 differing** |
| `spp5225b`, post-fix, 9 axes | 750,449 | 7,392,594 | 7,392,594 agreed, **0 differing** |

Same nine axes, same parameters, seeds 95,000,001 onward in both. The
post-fix run covers more because it got all nine; the pre-fix one lost its
ninth axis to resource starvation, as recorded above. That axis is exactly
the difference - 101,242 rounds.

**Not a like-for-like board count, and it does not need to be.** Every axis
independently reports 100.0% with zero unexplained, so there is no residue
hiding in the extra coverage.

An independent run on different seeds (`spp5225`, seeds 32,000,001 onward,
seven axes) says the same thing at larger scale: **1,065,373 rounds and
11,164,952 boards, zero colour differences against bbpPairings.** Two
corpora, one paired and one independent, both flat.

##### What the run was required to show, and did

A re-run that only produced zeroes would be as consistent with a broken
instrument as with a fixed engine, so the script demanded two other things
of it.

**The no-bye control had to stay at zero.** It did. Those axes read zero
before the fix as well - the divergence was only ever the renumbering, so
an axis where the two numberings coincide had nothing to change.

**The two reference-against-reference boards had to survive.** They did,
on the same two axes: one on `forfeits10`, one on
`everything-gacrux-allows`, both labelled `0 within 5.2.5's reach` and so
outside the article entirely. If the ruling had somehow swallowed them, the
instrument would have changed rather than the engine.

A small-scale paired control makes the same point from the other end: on
400 identical bye-heavy tournaments, v0.12.0 reports **1,255 differing
boards** and v0.14.0 reports **0**, with pairing composition byte-identical
across both (33,419/33,419). The instrument reported a nonzero on the old
engine minutes before reporting zero on the new one, which is what makes
the zero a result rather than an absence.

**And the two references contradict each other.** On the forfeit axis and
on the combined axis, one board each where bbpPairings and Gacrux disagree
about who is White, outside 5.2.5's reach - so on Articles 5.2.1 to 5.2.4,
which nobody disputes. In both, Ainalrami agrees with bbpPairings and
Gacrux is alone.

**The ruling does not touch those two boards and does not resolve them.**
They fall outside 5.2.5 by construction, which is why they were reported
separately in the first place; they are still open and still unadjudicated.
The 2026-08-28 re-run found them again, on the same two axes, which is the
control that says the instrument still sees what it used to.

Two boards in 6.2 million is a rate of 3.2e-5%, and it is not zero. Nobody
had measured it before, because measuring it needs an instrument that
compares two references to each other rather than both to the engine under
test. Both positions are worth reading; see the note in TODO.md.

The rule-of-three bound on the references' true colour-disagreement rate is
now about **3e-4%** per axis, computed over boards rather than rounds. That
bound is also unaffected by the ruling: it is measured between the two
references, and neither of them changed.

### The exhaustion probe (2026-08-27)

The corpus halts a tournament the moment bbpPairings answers "no legal
pairing left", records it as exhausted, and never asks this engine. So the
one behaviour it was structurally blind to was this engine being MORE
permissive than the reference - willing to pair a round the reference
refuses.

`tools/exhaustion_probe.exs` asks. Same generator, same axes, same TRF; on
`{:no_valid_pairing, _}` it puts the identical position to
`Pairing.pair_next_round/2` and classifies what comes back.

| axis | tournaments | reached exhaustion | both refused | disagreements |
|---|---|---|---|---|
| 4-10, plain, 9 rounds | 200,000 | 156,290 (78.1%) | 156,290 | 0 |
| 4-10, 15% byes, 9 rounds | 200,000 | 177,608 (88.8%) | 177,608 | 0 |
| 4-10, 12% forfeits, 9 rounds | 150,000 | 136,408 (90.9%) | 136,408 | 0 |
| 4-6, 20 rounds | 150,000 | 150,000 (100%) | 150,000 | 0 |
| 4-10, every axis on, 9 rounds | 150,000 | 149,121 (99.4%) | 149,121 | 0 |
| 11-20, 16 rounds | 80,000 | 46,052 (57.6%) | 46,052 | 0 |
| **total** | **930,000** | **815,479** | **815,479** | **0** |

**815,479 positions where bbpPairings said no legal pairing exists, and
this engine said the same thing every time.** Three bbpPairings process
errors (0.0003%) are excluded.

The exhaustion rates reproduce the corpus's own: 78.1% against the recorded
78.2% for `4-10, plain`, 88.8% against 88.2% for `4-10, 15% byes`. That is
the probe confirming it recreated the same conditions, not a second
measurement of the same thing.

Had the engine returned a pairing, the probe checks it for a rematch, a
second pairing-allocated bye, a forbidden pair, and a correct partition of
the active field. The first three are checked against the recorded game
history alone and share nothing with the engine's own reasoning; the
partition and bye-count checks have to derive the active set from the game
lists, which IS circular, and are reported under their own names for that
reason. None of them fired, so the distinction did not end up mattering.

### The refusals are proved, not corroborated (2026-08-27)

Both engines refusing was not proof that a legal pairing does not exist -
it was the single-oracle limit again, moved from the pairing to the
refusal, and two engines can be wrong together.

`tools/exhaustion_bruteforce.exs` settles it by enumeration. On every
refusal it walks all `(n-1)!!` complete pairings of the active field, times
`n` for the bye on an odd field, and tests each against C1, C2, C3 and the
arbiter's own exclusions - written from the article text, sharing no code
with `Ainalrami.Pairing` and structurally its opposite.

| axis | tournaments | refusals | proved impossible | legal pairing found |
|---|---|---|---|---|
| 4-6, 20 rounds | 200,000 | 200,000 | 200,000 | 0 |
| 4-10, 9 rounds | 200,000 | 156,163 | 156,163 | 0 |
| 4-10, 15% byes | 150,000 | 133,337 | 133,337 | 0 |
| 4-10, 12% forfeits | 150,000 | 136,307 | 136,307 | 0 |
| 4-12, 14 rounds, every axis on | 100,000 | 100,000 | 100,000 | 0 |
| 7-12, 16 rounds | 80,000 | 80,000 | 80,000 | 0 |
| **total** | **880,000** | **805,807** | **805,807** | **0** |

**Every one of the 805,807 refusals is proved.** Not "the two engines
agree" - no complete pairing of that field satisfies the absolute criteria,
established by exhaustion.

**4,876,836 positive controls passed.** On every round bbpPairings DID
pair, the same oracle was asked whether a legal pairing exists and had to
answer yes. An oracle too strict would fail there and then "prove" every
refusal impossible for the same wrong reason, so without this the negative
result would be worth nothing. It also checked the ACTIVE SET against the
reference's own pairing, which names exactly who was in the round: zero
mismatches over all 4.8 million.

**The control earned its place immediately.** The first run of this tool
reported 11,013 false verdicts against the engine, and four separate
defects in the tool caused them - not one in the engine:

* The active set came from the loop counter. When the whole field holds a
  pre-recorded bye the round is entirely byes and the reference advances to
  pair the next one, so the counter and the reference disagreed about which
  round was being paired. Now derived from the data.
* An empty active field made `perfect_matching?([])` vacuously true, which
  reported an empty field as a legal pairing against the reference.
* C2 valued a half-point bye at `win / 2`, which is only right while a draw
  is worth half a win. `BBD 2.0` makes it worth MORE than a win, which
  disqualifies its holder from the bye - the tool said the opposite. This
  is the same defect, in the same shape, as the one fixed in the engine
  itself the previous day: a result scored from its code without the system
  that says what the code is worth.
* C3's topscorer exemption was written as AND where the article, and three
  independent implementations, have OR. Every one of those 11,013 landed in
  the final round, which is the only round where topscorer status exists -
  that signature is what identified it.

The `max(win, draw)` term in 1.8's threshold was wrong here because
`docs/conformance-c0403-2026.md` still documented the `win`-only form that
0.11.1 had already fixed. A conformance record is read as the
specification; when it lags the code it does not go quiet, it propagates.

**What is still not proved.** The enumeration is capped at 14 active
players, so it says nothing about refusals on larger fields - though those
are rarer, since a bigger field has more ways to be pairable. (Closed for
the sizes it reached by [the matching oracle](#refusals-above-12-players-by-matching-2026-10-12)
below.) And it tests the three ABSOLUTE criteria; a refusal driven by
something else would not be caught. Nothing in the corpus suggests one
exists.

### Refusals above 12 players, by matching (2026-10-12)

Enumeration cannot go past 12-14 players, so the probe's `11-20, 16 rounds`
axis (46,052 refusals) was only corroborated above 12. Whether a legal
complete pairing exists does not need enumeration: it is a perfect-matching
question. One vertex per active player, an edge for each pair that C1, C3 and
the arbiter's forbidden pairs allow; on an odd field a dummy vertex joined to
every bye-eligible player (C2) stands for the bye. A legal pairing exists iff
that graph has a perfect matching, which is polynomial in the field size.

`tools/exhaustion_matching.exs` builds the graph with the brute-force tool's
reading of the rules (copied, since the 4.8 million positive controls had
already validated it) and solves it. The solving shares no code with
`Ainalrami.Pairing`, `Ainalrami.Matching` or `Ainalrami.WeightedMatching`. The
2026-10-12 run used two unrelated algorithms that had to agree on the SIZE of
the maximum matching, not only on whether it is perfect:

* networkx 3.6.1 `max_weight_matching(maxcardinality=True)`, a third-party
  implementation of Edmonds' blossom algorithm. An independent library was
  chosen over a blossom written for this tool because a hand-written one
  would itself need an oracle.
* The rank of a random Tutte matrix over GF(2^61 - 1) (Lovasz), which is
  algebraic and contains no blossom code. It can only err by reporting a
  rank that is too low, with probability at most N/p (about 2e-17) per graph.

It was run on every refusal, and on every positive control up to 24 players.

*Tooling note (2026-10-31).* The solver was a Python script
(`tools/exhaustion_matching.py`, networkx and the Tutte rank). The repo has no
Python of its own any more, so the script was removed and the Tutte-rank half
was ported into `tools/exhaustion_matching.exs` itself. The networkx blossom
cross-check was not ported: a re-run now rests a "no legal pairing" verdict
above 12 players on the Tutte rank alone (a probabilistic "none", at most
2e-17 per graph, never a false "legal") and, up to 12 players, on enumeration
as well. A 40-seed re-run on the port (548 positions, 31 refusals, 170 compared
with enumeration) flagged nothing. The figures above are the two-solver run's.

**Cross-check against enumeration, 4-12 players.** Over the same graphs the
tool also enumerates every perfect matching (n <= 12). 101,736 positions
across four axes (plain; 15% byes; 12% forfeits with 10% forbidden pairs;
every axis on, with mixed point systems, acceleration, initial colour and
ratings), 14,000 refusals and 87,736 positive controls: the matching oracle,
the Tutte rank and the enumeration agreed on every position, 0 disagreements.
The original `tools/exhaustion_bruteforce.exs` was also run on seeds 1-1000
of the first axis: 1,000 refusals proved and 6,987 controls passed, the same
1,000 and 6,987 (7,987 positions) the new tool counted on those seeds.

**Positive controls.** On every round bbpPairings did pair, the solver must
find a legal pairing, AND the reference's own pairing must be a witness
against the graph: every pair an edge, the bye holder eligible, the seated set
exactly the active set. A graph that was too strict would fail there. 0
failures in 87,736 + 41,279 + 35,837 + 86,761 controls.

**Refusals, 11-40 players.** Fields are the number of active players in the
refused round.

| axis | tournaments | refusals | no perfect matching | legal pairing exists | controls passed |
|---|---|---|---|---|---|
| 11-20 players, 16 rounds, seeds 1-3,000 | 3,000 | 1,947 (64.9%) | 1,947 | 0 | 41,279 |
| 13-40 players, 16 rounds, seeds 1-2,300 | 2,300 | 373 (16.2%) | 373 | 0 | 35,837 |
| 13-40 players, 20 rounds, 12% byes, 12% forfeits, 25% forbidden, mixed acceleration and point systems, seeds 1-4,700 | 4,700 | 1,519 (32.3%) | 1,519 | 0 | 86,761 |
| **total** | **10,000** | **3,839** | **3,839** | **0** | **163,877** |

Of these, at least 2,364 are refusals on fields of 13 or more active players
(counted from the per-size histograms the tool prints; one run's histogram was
not kept, so the true figure is higher). Refusals above 12 players occur up to
37 active players in the harsh axis, but only up to 18 in the plain ones: on a
plain 13-40 axis a field over 18 players was never refused in 2,300
tournaments, which is the rate falling off that was expected, not a measured
bound. The harsh axis exists because refusals on large fields are rare enough
that the plain axis yields 0.16 per tournament.

**Disagreements: none**, between the matching oracle and the reference's
refusals, between the two solvers, between matching and enumeration, and
between the graph and the original tool.

**What this does and does not establish.**

* It proves, for these 3,839 positions, that no complete pairing satisfies
  the absolute criteria as this tool reads them. It does not cover the rest
  of the probe's 46,052: the full 80,000-tournament axis would take about
  4.5 hours on this machine, because every round is a `bbpPairings` process
  launch, and was not run. 3,000 tournaments is 3.75% of it.
* The refusal RATE on the 11-20 axis here (64.9%) is higher than the probe's
  57.6%. Sampling does not explain it (the standard error at 3,000
  tournaments is about 0.9 points). The probe's seed range is not recorded,
  and the generator has been extended since; the 46,052 was therefore not
  reproduced, and the difference is not explained. The two figures count
  different tournaments.
* It is not a new measurement of the engine. The refusals come from
  bbpPairings, so this proves "the reference's refusals are correct", not that
  this engine refuses them; the engine's side is still the probe's. The
  probe was not re-run here.
* The edge reading is the brute-force tool's, so an ambiguity in the
  regulation read the same way in both tools would survive. The positive
  controls bound that for the readings that matter (a too-strict graph fails
  them) but not for a too-LENIENT one, which could only make a refusal look
  legal and so would have shown as a disagreement.
* Tutte-rank and networkx are both run in the same Python process family and
  see the same graph; they are independent as algorithms, not as inputs.
* Runs used the engine at origin/main 471621c (0.43.0), generator at the same
  commit. Run time was dominated by launching `bbpPairings` (about 60-80
  positions per second on 13 threads); the solving took 1-6% of it.


#### Interim update (2026-10-14): the 11-20 axis, seeds 1-39,500 of 80,000

Stopped early at the owner's request; resume at seed 39,501. Same tools,
`MATCH_GEN=8`, 16 rounds, 11-20 players, default generator settings. Raw
per-chunk output, with per-size histograms, is `tmp/refusal_big/results.txt`.

| tournaments | refusals | no perfect matching | legal pairing exists | controls passed | of which refusals on 13+ active |
|---|---|---|---|---|---|
| 39,500 | 25,342 (64.2%) | 25,342 | 0 | 543,166 (0 failed) | 17,412 |

Disagreements: none (networkx and Tutte rank agreed everywhere, no flagged
positions, no harness errors). The 20,000 refusals on 13+ was not yet reached.
The harsh 13-40 axis was not run in this pass.

The rate (64.2%) again differs from the probe's 57.6%. Findings so far: the
generator draws are bit-identical between the probe's commit (30d2b36) and
now (seeds 1-20,000 default env, 1-3,000 with every knob on). Rating mode or
initial colour do not move it (65-66% on 300 seeds each). And the probe's
figure is below an arithmetic floor: with no byes or forfeits, a field of 16
or fewer cannot play 16 rounds, so every such tournament must be refused, and
48,100 of seeds 1-80,000 draw such a field (60.1%); 46,052 is under that. So
the probe's tournaments were not the described ones, or some refusals went
uncounted (a harness-error class the probe excludes). Not resolved further.

### What this run added over its predecessors

It is the first corpus measured on the local-graph engine (see
`docs/engineering-log.md`), and the speed is what bought the coverage:
60-120 players ran at ~22 tournaments/s against 0.36 before, so the large
axes stopped being unaffordable.

- **300-500 players had never been validated at any scale.** Neither had
  150-250 with forfeits and forbidden pairs on top.
- **The large-field axes are 3.1 million rounds** between them, against
  600 tournaments in the previous corpus - the dimension that was
  thinnest is now among the thickest, which matters because the local
  graph only engages on brackets big enough to qualify.
- **A Black-drawn-first axis**, exercising the half of Article 5.2.5 that
  hands out the *opposite* colour. (This bullet used to say the axis
  exercised "the 5.2.5 reading this engine settles against both
  references". There is no such reading: the SPP ruled on 2026-08-27 that
  the references were right. The axis is worth exactly as much as it always
  was - it is about which colour the draw hands out, not about which number
  the parity is taken on - but the justification was wrong.)

### The two disagreements

Both are the same bbpPairings defect, on different axes and seed ranges:
it allocates a second pairing-allocated bye to a player who already holds
one, which [C2] forbids absolutely. The adjudicator scores both
`incomparable` - neither is a case where bbpPairings' answer is better on
this engine's own ladder - and Gacrux, a third independent implementation,
returns this engine's answer board-for-board on both.

In `seed7073463-r8-p9` the round has exactly one legal shape, reached by
eliminating four players who each already hold a bye and are down to a
single legal opponent. There is no scoring argument to make about it.

Written up in `docs/bbppairings-c2-bug-report.md`, decoded position by
position in `test/fixtures/fe1_disputes/README.md`, and pinned by
`test/ainalrami/c2_second_bye_test.exs`.

## Re-validation after the 2026-08-18 changes

**11,000 tournaments / 69,038 rounds / 680,022 individual pairings, at
100.00% with zero illegal rounds, zero refusals and zero unexplained
colour differences.**

**Read "zero unexplained" with the 2026-08-27 ruling in mind.** That figure
was computed with a colour split that filed every Article 5.2.5 board under
a known dispute and counted only the remainder. The SPP has since ruled
that dispute against this engine, so boards the split absorbed as
*explained* are now known to have been defects. The pairing figure -
100.00%, zero illegal, zero refusals - is untouched; colour on this axis is
pending re-measurement like every other colour figure on this page.

| axis | rounds | individual pairs |
|---|---|---|
| byes + forfeits + `XXP` + `XXA`, 7 rounds | 16,605 | 165,629 |
| 15% byes, **8** rounds | 18,920 | 189,175 |
| plain, 4-10 players | 6,586 | 26,032 |
| **60-120 players** | 840 | 38,717 |
| 15% byes, **6** rounds | 6,990 | 68,567 |
| 15% byes, **10** rounds | 11,015 | 112,155 |
| **`152 B`** + byes + forfeits | 8,082 | 79,747 |

Two of those axes are new rather than repeats. The **Black draw** row
exercises the half of Article 5.2.5 that hands out the *opposite* colour,
which no axis ran until the `152` field was read at all; and the round
counts deliberately span 6, 7, 8 and 10, for the reason the next section
gives.

Re-running the full 4.3M corpus is a machine-hours job rather than a code
change, and is worth doing before any endorsement submission.

| axis | tournaments | exact rounds | individual pairs | illegal |
|---|---|---|---|---|
| plain, 4-40 players | 120,000 | 100.00% | 100.00% | 0 |
| plain, 4-10 players | 500,000 | 100.00% | 100.00% | 0 |
| 15% arbiter byes, 4-40 | 250,000 | 100.00% | 100.00% | 0 |
| 15% arbiter byes, 4-10 | 1,200,000 | 100.00% (1 dispute) | 100.00% | 0 |
| 10% forfeits, 4-40 | 120,000 | 100.00% | 100.00% | 0 |
| 20% forbidden (`XXP`) | 120,000 | 100.00% | 100.00% | 0 |
| Baku acceleration (`XXA`) | 120,000 | 100.00% | 100.00% | 0 |
| byes + forfeits + `XXP` + `XXA` | 120,000 | 100.00% | 100.00% | 0 |
| 60-120 players | 600 | 100.00% | 100.00% | 0 |
| **even round counts** (6, 8, 10) | 850,000 | 100.00% | 100.00% | 0 |
| odd-round controls (7, 9) | 350,000 | 100.00% | 100.00% | 0 |

FIDE's FE1 endorsement bar is one difference per 500 tournaments. This is
one per 3.0 million.

That one is `seed735265-r7-p10`, kept as a fixture at
`test/fixtures/fe1_disputes/`. It is a rules-interpretation dispute, not a
defect: bbpPairings awards a second pairing-allocated bye to a player who
already holds one, which absolute criterion C2 forbids, and Gacrux pairs
it as this engine does. Argued in full in
[dispute-seed735265.md](dispute-seed735265.md).

## Running it

The comparison suites are tagged and excluded from `mix test`:

```bash
mix test --only bbppairings
```

| tag | what it runs |
|---|---|
| `bbppairings` | the main fuzz harness against bbpPairings |
| `javafo` | composition against real JaVaFo, every round (seven axes only - see above) |
| `three_way` | Ainalrami vs bbpPairings vs Gacrux on identical positions |
| `taxonomy` | classify disagreements by first differing bracket |
| `rule_delta` | pinned cases where the 2017 and 2026 rules differ |

Every axis is a set of environment variables:

| variable | default | meaning |
|---|---|---|
| `PAIRING_FUZZ_COUNT` | small | tournaments to generate |
| `PAIRING_FUZZ_ROUNDS` | 9 | rounds per tournament - **vary this** |
| `PAIRING_FUZZ_ROUNDS_MAX` | unset | makes rounds a RANGE drawn per tournament, `ROUNDS..ROUNDS_MAX` |
| `PAIRING_FUZZ_ACCEL=mixed` | - | draws none/baku/random per tournament |
| `PAIRING_FUZZ_INITIAL_COLOUR=mixed` | - | draws W/B per tournament |
| `PAIRING_FUZZ_NUMERIC_EXT=mixed` | - | draws XXA/XXP vs 250/260 per tournament |
| `PAIRING_FUZZ_RATING_MODE` | `spread` | `spread`/`clustered`/`equal`/`unrated`/`all_unrated`/`mixed` - see below |
| `PAIRING_FUZZ_WITHDRAW_PCT` | 0 | chance per player per round of dropping out for good, from round 2 |
| `PAIRING_FUZZ_MIN_PLAYERS` / `MAX_PLAYERS` | 4 / 40 | field size range |
| `PAIRING_FUZZ_SEED_FROM` | 1 | start of the seed range |
| `PAIRING_FUZZ_BYE_PCT` | 0 | arbiter-assigned bye rate |
| `PAIRING_FUZZ_FORFEIT_PCT` | 0 | forfeit rate |
| `PAIRING_FUZZ_FORBIDDEN_PCT` | 0 | `XXP` density |
| `PAIRING_FUZZ_ACCEL` | none | `baku` or random `XXA` |
| `PAIRING_FUZZ_INITIAL_COLOUR` | `w` | TRF `152` header |
| `PAIRING_FUZZ_DUMP` | - | directory for failing cases |
| `COLOUR_DEBUG` | - | report colour mismatches per pair |

`overnight_run/run.sh` drives the long batches.

**Seeds are independent**, and `PAIRING_FUZZ_SEED_FROM` starts the range
anywhere - so any catalogued case regenerates in about a second rather
than requiring the 735,264 tournaments before it. That knob not existing
is a large part of why early catalogued cases were adjudicated once and
never revisited.

## What the corpus could not see

This is the section worth reading.

### 2.5 million tournaments held one parameter constant

**Rating shape** was held constant until 2026-08-23 at "uniform
1000..2800", which makes every player rated and rating ties incidental -
close to the opposite of real chess, where a junior event is entirely
unrated and a club field sits on a handful of rounded numbers. Equal
ratings put the INITIAL RANKING on a different path: not "sort by rating"
but whatever breaks the tie. That ranking is the foundation of every
bracket in every round, so two engines breaking it differently disagree
about everything afterwards. `PAIRING_FUZZ_RATING_MODE` varies it, and
`bbppairings_comparison_test.exs` carries a test asserting each mode really
does reshape the roster - a mode that went inert would still report 100%
agreement while testing nothing.

**Withdrawals** likewise: no corpus before that date ever generated one,
so the TRF construct expressing "this player has left" had never been read
by bbpPairings from a file this project produced.

**Closed as of 2026-08-23**: the round count has now been swept end to end,
R=1 through R=20, at ~3M rounds per axis - 10,793,215 tournaments,
684,901,202 pairings, zero disagreements, zero illegal rounds. See "The
round-count sweep" in docs/engineering-log.md. Round count is no longer an
untested dimension; what remains untested is that dimension CROSSED with the
others (forfeits, forbidden pairs, acceleration, large fields).

Every axis measured before 2026-08-17 ran `PAIRING_FUZZ_ROUNDS=9`. A
nine-round tournament pairs its final round with **eight** played, and
`div(8, 2) == 8 / 2`.

So a topscorer threshold that *floors* the half-point is invisible. It can
only differ when the played-round count is odd - that is, when the
tournament has an **even** number of rounds. `final_round_topscorers?/2`
had exactly that bug. Re-measured at 8 rounds, 2,000 tournaments:

| | exact rounds | individual pairs |
|---|---|---|
| before | 15051/15060 = 99.94% | 155831/155862 = 99.98% |
| after | **15060/15060 = 100.00%** | **155862/155862 = 100.00%** |

Nine wrong rounds that 2.5 million tournaments could not produce. Six-,
eight- and ten-round Swisses are ordinary events; this was never an exotic
corner.

**The same expression was wrong a second time, and the same lesson caught
it (2026-08-25).** The threshold reads
`playedRounds * std::max(pointsForWin, pointsForDraw) >> 1` in the
reference (`dutch.cpp:55`); this engine read `pointsForWin` alone. Every
point system the harness could generate had the win worth at least as much
as the draw, so the two factors were the same number and no axis could tell
them apart - the same shape as the floor bug above, one line lower.

`BBW` and `BBD` are free-form in the file, so a draw worth more than a win
parses even though FIDE would never publish one. A `draw_heavy` axis
(win 1.0, draw 2.0) was added and run in TWO ARMS over identical seeds -
one with the fix, one with that single line reverted - because a fix that
cannot be measured is a fix that has not been tested:

| axis | with `max` | with `pointsForWin` alone |
|---|---|---|
| 4-10, 9 rounds | 1,163,034/1,163,034 = **100.00%** | 1,162,583 = 99.96% |
| 4-40, 9 rounds | 1,006,012/1,006,012 = **100.00%** | 1,002,565 = 99.66% |
| 4-40, 8 rounds | 907,227/907,227 = **100.00%** | 904,339 = 99.68% |
| 4-40, 6 rounds | 698,901/698,901 = **100.00%** | 697,506 = 99.80% |
| **total** | **3,775,174 rounds / 31,184,698 pairings, 100.00%** | 8,181 wrong rounds |

Zero illegal rounds in either arm, which is the point: the control arm does
not crash or refuse, it quietly pairs 8,181 rounds differently from the
reference. Without the second arm the first arm's 100% would have been
indistinguishable from an axis that never reaches the exception at all.

The axis was also checked for inertness before being trusted - a generated
file carries a real `BBD 2.0` line, and bbpPairings reads it. An axis that
goes quietly inert reports 100% while testing nothing, which this project
has been bitten by before.

**Corpus size bought nothing here.** The axes varied field size, bye rate,
forfeit rate and extension lines - and held constant the one parameter the
bug was a function of.

> When adding an axis, ask what the existing ones hold **constant**, not
> what they vary.

The even-round axis is now first-class: 1,800,000 tournaments across
rounds 6/7/8/9/10, zero disagreements. The odd controls are the point -
had 7 and 9 also moved, the fix would have been wrong in a way the small
local run could not have shown.

### "Zero illegal rounds" was true until it was tested 100× harder

Legality is checked independently of any reference: every player paired
exactly once, no rematches, exactly one pairing-allocated bye in an odd
active field and none in an even one.

That held at every sample size up to ~5,500 rounds. At 839,776 rounds it
did not: the first 100,000-tournament bye-rate run found **102 illegal
rounds (0.012%)**. Ninety-five raised `ArgumentError` from a range
`0..-1` - Elixir's default step for a descending range walks `0, -1`, and
`elem(arr, -1)` is an invalid index - reachable only when exactly one
player was left needing a bye. Five returned the wrong bye count, two a
non-partition.

All are closed, each with a regression test that fails on the pre-fix
code. Re-running the identical configuration over 250,000 tournaments /
2,099,071 rounds now gives zero.

**The standing bar is the 100× sample, not the one that passed.**

### Four instruments were broken or blind

Found while chasing the above, and worth listing because three engine bugs
were found *by* fixing the instrument rather than by the instrument:

- **`explain_round/3` never stamped float history**, so C14-C21 scored a
  constant on both sides of every verdict the adjudicator ever printed. It
  could not invent a disagreement - both sides were scored blank, so a tie
  stayed a tie - but it could *misattribute* one. It had no test of any
  kind until `explain_round_test.exs`.
- **The legality oracle was a copy of the engine.** An enumerator that
  checks C1 but neither C2 nor C3 reports "legal pairings the engine
  refused" - it has admitted illegal ones. A weaker oracle accusing a
  stronger implementation is the expected result, not a finding.
- **Every axis pinned `ROUNDS=9`**, as above.
- **The harness never compared colours.** Colour agreement was simply not
  measured until `colour_mismatches/5` was added - 4.3 million tournaments
  and 195 million pairings had validated who plays whom and never once
  checked Article 5. Turning it on immediately found a missing 5.2.4 and
  then the 5.2.5 divergence below - which was argued as a dispute for ten
  days and then ruled a defect in this engine.

### Colour is measured separately, and is no longer split by cause

Colour differences are counted apart from pairing differences, because
they fail for different reasons: a colour difference on an otherwise
identical round is not the same finding as a different round. That part
stands.

**What has been removed is the second split**, wherever one of the two
answers being compared is this engine's. In the two-way harness
`colour_mismatches/5` no longer returns a `colour_disputed` count and
`report/4` no longer prints one; comparison against bbpPairings is flat
equality, and a board where this engine names a different White is a
mismatch, counted as one, with no bucket to fall into. In the three-way
harness the `:conformance` classification is gone from both comparisons
that have this engine on one side, so their report line reads
`expected (none are)` - the count is structurally zero rather than
observed to be zero.

**Why the split existed.** Until 2026-08-27 this engine took Article
5.2.5's parity on the TPN and both references took it on a numbering that
skips players who have never been paired, so every board 5.2.5 decided on
a field where somebody had sat out differed by construction - hundreds of
boards per few hundred bye-heavy tournaments, 64,131 across the six-million
run. That volume would have buried a real colour regression completely, so
boards were sorted into the known
[Article 5.2.5 divergence](dispute-initial-colour.md) and **unexplained**,
and only the second number was watched.

The predicate did the sorting by asking whether 5.2.5 was what decided the
board (neither player holds a colour preference) **and this engine's answer
was the one the article gives**. That was deliberately a conformance test
rather than a model of bbpPairings' internals - an earlier version did the
latter and mis-filed a genuine case.

**Why it no longer does.** The SPP ruled the numbering question against
this engine, the allocation now uses the references' numbering, and the
predicate inverts with it: "the answer the article gives" is now the
references' answer, so the old test would file correct boards as divergent
and incorrect ones as unexplained. Worse, once we implement the same rule the
bucket degenerates into "a board where we differ from the reference is
explained by our differing from the reference" - a tautology that would
swallow real regressions. A bucket labelled *expected* that nothing may
legitimately land in is a hiding place, so it is deleted rather than
zeroed.

**What survives, and only where neither side is this engine.** The
three-way harness still classifies one of its three comparisons -
bbpPairings against Gacrux - under a mode named `:reach`, and the claim it
makes is deliberately the weaker half of the old one. `:conformance` asked
whether 5.2.5 decided the board **and** this engine's answer was the
article's. `:reach` asks only the first: that neither player held a colour
preference, so 5.2.5 is what the board turned on. No conformance claim is
available on a board this engine formed neither answer to, and the report
prints the weaker word for it - those boards are "within 5.2.5's reach",
not a confirmed anything. That is the only surviving classification of a
colour difference anywhere in the harnesses.

**Retracted 2026-10-26.** The Gacrux differences this section classifies, and the two boards
below, were Gacrux pairing the wrong round: the harness did not pass `-n R`. With it, Gacrux
agrees with bbpPairings and Ainalrami, `:reach` is gone, and the finding docs are marked
retracted.

**`:reach` was kept for the wrong reason for ten days, and that is worth
recording.** The justification in the harness used to be that the two
references renumber differently from each other, so a field where somebody
who HAS played sits out could still split them - which would have made
`:reach` a real distinction. That claim was false when it was written. It
came from `docs/dispute-initial-colour.md`, where it was the pre-probe
hypothesis stated as a finding, and `tools/rip_probe.exs` refuted it in
that same document's own evidence section: when the absent player has
already played, all three engines answer alike and nobody renumbers.
Re-confirmed 2026-08-27 against the local binary. `:reach` survives on the
correct and much smaller ground above - that a reference-against-reference
board admits no claim about this engine's conformance - and not on a
difference between the references that does not exist.

**What that costs and what it buys.** It costs the historical figures on
this page their meaning: any "zero unexplained" computed with the bucket in
place excluded boards now known to be defects, and is annotated as such
wherever it appears above. It buys a colour number with nothing subtracted
from it. That number has not been measured yet - see "The re-measurement is
PENDING" above.

The axes without byes were the control that made the rest meaningful:
plain, forfeit, `XXP` and Baku runs report **zero** colour differences, so
the divergence was never a general disagreement about Article 5. That
measurement holds, and the control's job is over: if the fix is right, the
bye-heavy axes join the control at zero and it stops separating anything.
Whether they do is exactly what the pending re-run answers.

The adjudication tables in [engineering-log.md](engineering-log.md) were
produced with the blank float history and have **not** been re-run. They
are not wrong about *whether* the engines differed - that comes from the
harness, not the scorer - but their "first differing rung" column is only
trustworthy where the winning rung outranks C14.

## Legality, independent of any reference

When no legal pairing can exist at all - a genuine structural deadlock,
not a search failure - the engine raises
`Ainalrami.Pairing.NoValidPairingError` rather than emitting a
best-effort illegal result, matching bbpPairings' own
`NoValidPairingException`. bbpPairings has independently confirmed these
cases really are unpairable, via its own exit code 1 on byte-identical
input.

## Extension lines

`XXP` and `XXA` are validated by the same oracle as everything else,
because bbpPairings implements both and reads the same file: **1,789,554
rounds and 8,536,147 individual pairs carrying at least one extension
line, 100.00% agreement, zero illegal rounds**, across eleven axes.

Every previously-measured axis was byte-identical after that change - the
same numerators and denominators, not merely the same percentages.

What the old line-dropping behaviour actually cost, before they were
implemented: at 20% forbidden-pair density it seated a forbidden pair in
**27.72%** of rounds, and Baku acceleration paired **66.12%** of rounds on
the wrong scores.

## Bye exclusions (organiser deviation, 2026-09-27)

`bye_exclusions:` is not a FIDE rule, so no reference engine implements it
and none can be compared against. It is checked instead against
`Ainalrami.Test.ByeExclusionReference`, an exhaustive reference written
from the article text that shares no code with the engine: every complete
pairing of the active field is enumerated, the absolute criteria (C1, C3
with the topscorer exception, forbidden pairs) are applied per pair, and
the bye goes only to a player [C2] allows and the organiser did not
exclude - the exclusion enters the reference in exactly one place, beside
C2, which is the claim being tested.

`test/ainalrami/bye_exclusion_validation_test.exs` plays whole generated
tournaments (4-13 players, 3-9 rounds, requested `H`/`Z` byes,
withdrawals, forfeits, sometimes forbidden pairs) paired by the engine
WITH random exclusions, and on every round checks: that `[]` pairs as no
option does; that on an even field, or with nobody active excluded, the
option changes nothing; and on an odd field with someone excluded, that
the engine pairs exactly when the reference finds a legal round, that the
round is legal under the reference's rules, that its bye holder has
[C5]'s minimum score, that the round equals the unexcluded one whenever
the unexcluded bye holder was not excluded, that `explain_round/3`'s
passed-over list is right, and that a refusal carries `:bye_exclusions`
exactly when the round is pairable without the exclusions, with an
override that really does make it pairable.

**Seeds 1-10,000: 52,456 rounds - 15,949 paired with an exclusion in
force, 5,169 refused (4,038 with an override offered), 3,495 with someone
passed over - 0 disagreements.** A mutation that drops the exclusion from
the engine is caught on the first seeds. The ordinary suite runs 150 seeds;
`BYE_EXCL_SEEDS=1-10000` reruns the range.

With no exclusion the engine's pairings and `explain_round/3` rungs were
diffed against the previous `main` build on 1,500 generated tournaments of
4-24 players (8,593 rounds, forbidden pairs and `H` byes included):
byte-identical, so every corpus figure above still stands.

## Bye preferences (organiser deviation, 2026-09-30)

`bye_preferences:` (`Ainalrami.ByePreference` - must get / rather gets /
must not get / rather not the pairing-allocated bye) is not a FIDE rule
either, and is checked against the same exhaustive reference.
`test/ainalrami/bye_preference_validation_test.exs` plays whole generated
tournaments (4-13 players, 3-9 rounds, requested byes, withdrawals,
forfeits, sometimes forbidden pairs) paired WITH random preferences - one
to four players per round, every setting, some for other rounds, some on a
player not playing, and now and then two on one player - and on every round
resolves the settings by the documented precedence itself and checks: that
`[]` pairs as no option does and `pair_next_round/2` returns what
`ByePreference.pair/2` does; that the round is legal under the reference's
rules with the hard avoids as exclusions, and refused exactly when the
plain round with those exclusions is; that an even field or a round with no
preference that can act is the plain round; that a hard want gets the bye
exactly when the reference finds a legal round giving it to one of the
wanted players, and then on the lowest score such a round allows; that a
soft want gets it exactly when the reference finds such a round ON the
plain round's bye score, and a soft avoid is honoured exactly when the
reference finds a round giving the bye to someone not avoided on that
score; that the bye score never moves under a soft setting; and that the
report's `moved` is exactly "the pairs differ from the plain round"; and that
a round where a live hard want names a player C2 rules out is refused
with `RefusedError` - and no other round is.

**Seeds 1-5,000: 26,425 rounds - 3,386 with a hard want granted, 125 a
hard want no legal round allows, 1,260 refused because a hard want asked
for a second bye (each refusal naming exactly the right players and the
round of their first disqualifying game), 1,201 a soft want granted and 773
outranked, 197 a soft avoid honoured and 247 outranked, 12,045 even fields,
1,858 refused as the plain round is, 5,458 with nothing that could act - 0
disagreements.** The
ordinary suite runs 120 seeds; `BYE_PREF_SEEDS=1-5000` reruns the range.

The shortcuts. Every preference reaches the engine as bye exclusions, and
the certified and direct-bracket shortcuts are proved against the same
eligibility predicate the exclusions enter through, so none of them needed
a gate of its own. `tools/bye_pref_direct.exs` is the empirical side:
generated tournaments of 101-401 players, random preferences on every round,
each round paired three times - default, `AINALRAMI_DIRECT=off`, and
`AINALRAMI_DIRECT=check` (every direct answer held to the stages', raising
on a difference) - with the certified shortcuts forced: 40 tournaments, 280 rounds (133 odd, 86 of them moved by a preference), the three identical on every round and no check-mode difference raised.

Without preferences the engine runs the code it ran before: the
differential corpus (`tools/perf_diff.exs`, the four standing sets, default
configuration) against the standing baseline logs the direct-bracket work
was held to: 447,152 rounds (early 1,980, large 5,497, flags 68,898, small
370,777), 0 differing, 0 missing - pairs, explanations, perturbed-pairing
judgements and alternatives alike.

## Score variants (2026-10-07)

`Pairing.pair_variants/3` promises, for every variant, exactly what
`pair_next_round/2` returns for that variant alone. Nothing references it
but the engine itself, so that is what it is held to:
`tools/variants_check.exs` pairs every variant in the batch, then again on
its own with `pair_next_round/2` in a separate process, and compares the
two: the same pairs in the same order with the same colours and the same
bye, or the same refusal (exception, reason, excluded ranks, override,
message).

A position is the fuzz generator's tournament played forward by the
engine to a random round T, round T paired and its results drawn, and k of
its boards left open; the position is round T+1 with that round's
withdrawals, late entrants and requested byes applied, and the variants
are the 3^k ways the open games can end, in OpenPairings' order. On a
third of tournaments the arbiter's soft pairs, on a third of positions
organiser bye exclusions (a refusal they cause is answered as OpenPairings
answers it, with the override, while the tournament is played forward).
k is 1-6, uniform per position.

| axis | knobs | positions | variants compared | refused (both) |
|---|---|---|---|---|
| general | 6-300 players (bands 6-40 / 41-100 / 101-200 / 201-300 weighted 45 / 27 / 18 / 10), 5-11 rounds, 5% requested byes, 3% forfeits, 2% withdrawals, 5% late entrants, 2% `XXP`, acceleration, initial colour, rating shape and point system mixed | 6,771 | 1,119,147 | 2,058 |
| small and hard | 6-20 players, 7-11 rounds, 15% byes, 8% forfeits, 3% withdrawals, 5% late entrants, 5% `XXP`, the rest mixed | 38,469 | 3,830,061 | 50,725 |
| timing | 30 / 80 / 150 / 300 players, k = 4-8 (k = 7 and 8 compare 60 variants of each) | 247 | 71,037 | 0 |

**5,020,245 variants compared, 0 mismatches**; 52,783 of them refused by
both (the same `NoValidPairingError`, to the message). By field size (the
active roster, 3-300 once withdrawals have thinned the smallest): 6-40
players 4,310,091, 41-100 339,492, 101-200 240,777, 201-300 129,885. By k:
1: 23,139, 2: 85,914, 3: 278,154, 4: 696,600, 5: 1,413,045, 6: 2,520,153,
7 and 8: 3,240.

Every search mode the batch can choose was exercised: each batch of three
or more structured variants pairs at least one variant in each, and the
choice between them is made on time, so which variants got which differs
from run to run. `test/ainalrami/pair_variants_test.exs` pins each mode
in turn (`AINALRAMI_VARIANT_MODE`) on a fixed position, and covers the
plain fallback (a recoloured game), a forfeit kept on the fast path, the
refusal, the input checks and the process dictionary being left clean.

The run: one scheduler per worker on the shared 80-core VM, 2026-10-07,
24 then 16 workers (the first workers were stopped part-way to free cores
and the rest continued on fresh seeds; every line written is a whole
position). Usage and the summary are in the script's header.

## The Dubov system (2026-10-31)

C.04.4.1 has no outside reference for the 2026 edition, so `Ainalrami.Dubov`
is held to a brute-force reading of the rule text
(`test/support/dubov_reference.ex`, no code shared with the engine) and
to the absolute criteria, as the team engine was. 507,945 rounds over
4-12 player fields (seeds 1..100,000 at 4-10 players, 1..10,000 at 11-12),
every round paired by both under both readings of D2: **0 disagreements,
0 rounds where the two readings parted.** Method, readings and coverage:
[conformance-c0441-dubov.md](conformance-c0441-dubov.md).

## Not covered

Stated so the claim's boundary is explicit:

- ~~**`260` and `250`**~~ - **implemented 2026-08-18.** These are
  bbpPairings' round-limited siblings of `XXP` and `XXA`, and they were
  listed here as "deliberately absent rather than stubbed". That was wrong
  in a specific way: absent meant the lines fell through to the header
  parser and were *silently discarded*, so a file saying "1 and 3 must
  never meet in rounds 1-3" produced a complete, legal-looking round that
  seated 1 against 3. Verified happening before the fix. Both are now read,
  both raise on a malformed line, and every case was checked against the
  real binary - including a `260` whose range excludes the round being
  paired, which must do nothing.
- **bbpPairings' own Baku flag**, which sizes Group A as `ceil(n/2)` where
  FIDE C.04.7 uses `2 * ceil(n/4)`. Reached only through its own flag,
  never through `XXA`, so it cannot make the two engines disagree here -
  both read identical `XXA` lines from an identical file.
- ~~**Unrated players**~~ - **covered 2026-08-24.** The rating run varies
  the shape of the field's ratings across five modes, two of which put some
  or all players at 0. 285 million pairings, zero disagreements.
- ~~**Late entrants**~~ - **covered 2026-09-14.** See "Late entrants
  (2026-09-14)" below.
- **Team tournaments** in this harness, and files where `rounds_count`
  disagrees with `XXR`. The harness generates neither; see
  [TODO.md](../TODO.md). Team pairings are validated separately, against
  references written from C.04.6: see
  [Team Swiss pairings](#team-swiss-pairings-c046).
- ~~**Non-default point configuration**~~ - **covered, and it was worth
  it.** `PAIRING_FUZZ_POINT_SYSTEM` now generates `BB*` lines across seven
  named systems (half-point bye, doubled, football 3-1-0, paid loss, paid
  forfeit, draw-heavy). It found two real engine bugs that every
  standard-scored corpus was structurally incapable of seeing:

  * a **half-point loss** scored 87.46% on its first run, because
    `float_direction/4` treated "scored anything at all" as having
    downfloated - correct only when a loss is worth zero;
  * the final-round **topscorer threshold** read `pointsForWin` where
    `dutch.cpp:55` reads `max(pointsForWin, pointsForDraw)`, which no axis
    could see while every system had the win worth at least the draw.

  The second was measured rather than argued: a `draw_heavy` axis run in
  two arms over identical seeds gave **3,775,174 rounds at 100.00%** with
  the fix and **8,181 wrong rounds** without it, with zero illegal rounds
  either way. See "The same expression was wrong a second time" above.
- **Fields above 500 players and round counts above 20.** Both are
  boundaries of the harness rather than of the engine, but nothing has
  measured past them. This is now the most reachable gap on the list: the
  matcher rebuild took 60-120 players from 0.36 to ~12 tournaments/s, so
  the axis that was once unaffordable is affordable.
- ~~**Three-way agreement at scale**~~ - **raised 2026-08-27, from 3,352
  rounds to 649,207**, and given a colour instrument it never had. See
  "The three-way run" below. It is no longer the weakest number here.
- **The reverse pairings direction (VCL4THP Q33), at the required scale.**
  Reading a tournament bbpPairings' own generator produced, rather than
  one this project wrote, had exactly one fixture behind it until
  2026-09-27. Now 5,584 tournaments, zero disagreements - see "Pairings
  (VCL4THP Q33), both directions" below - which is real, new coverage and
  still short of the 50,000 Q33 asks for. Resumable; not yet closed.

## Late entrants (2026-09-14)

C.04.2 Article 2 ("Initial Order and Late Entries") governs this, not
C.04.3: **2.3** gives everyone a TPN from the pre-round-one ranking;
**2.4** says a late entry "is only taken into account for the pairing of
rounds after the first [round they missed]... receive[s] no points for
unplayed rounds (unless the rules of the tournament say otherwise), and
[is] given an appropriate TPN and paired only when [it] actually
arrive[s]"; **2.5** says the start-of-tournament TPNs are "provisional"
and reassigned as needed until the List of Participants closes.

**Representation, checked against a real file rather than assumed.** A
2026-08-30 TRF from a real Belgian event (the Tonoli Memorial, supplied by
the user) has a late entrant whose pre-entry rounds read `0000 - Z` -
opponent 0000, no colour, result code Z (zero points) - the same shape a
full withdrawal uses in that file. Confirmed as the only shape that works
here too: a genuinely blank result column is a different, and malformed,
one - bbpPairings refuses the whole file for a short mid-file column (see
`Ainalrami.Trf`'s `pad_to_last_round/2`). `PAIRING_FUZZ_LATE_BYE_TYPE=H`
switches every late entrant's missed rounds to a half-point bye instead;
off by default, matching C.04.2:2.4's own default.

**TPN, found the hard way.** The first version of the new
`PAIRING_FUZZ_LATE_PCT` knob kept each late entrant's ORIGINAL TPN and
simply left its `001` row out of the file until entry. bbpPairings
refused outright - "A pairing number is missing" - the moment the omitted
rank was not the field's highest one, since its own TPN sequence has to
be gap-free. A player who has not yet entered is also not invisible to
bbpPairings' own pairing decision: a 30-seed probe with the omission
approach still intact found it pairing every not-yet-entered player it
could see, round 1 included. So TPNs are now reassigned once, at
generation time - matching 2.5's "provisional... reassigned" wording -
so every late entrant sorts after every player who is never late. The
active roster at any round is then always the gap-free prefix
`1..(N-K+j)` bbpPairings requires, with no renumbering needed later: a
player's TPN, once assigned, never changes again.

**The corpus.** Six axes, sized to fit a single session rather than this
project's overnight runs:

| axis | tournaments | rounds | individual pairs | exact rounds | illegal | process errors |
|---|---|---|---|---|---|---|
| 10% late, W drawn, 9 rounds | 300 | 2,700 | 79,925 | 100.00% | 0 | 0 |
| 10% late, B drawn, 9 rounds | 300 | 2,700 | 79,925 | 100.00% | 0 | 0 |
| 25% late, W drawn, 9 rounds | 300 | 2,700 | 76,537 | 100.00% | 0 | 0 |
| 25% late, B drawn, 9 rounds | 300 | 2,700 | 76,537 | 100.00% | 0 | 0 |
| 20% late, 10% byes, 10% forfeits, 5% withdrawals, mixed colour | 300 | 2,700 | 58,156 | 100.00% | 0 | 0 |
| 10% late, 11 rounds | 250 | 2,750 | 81,712 | 100.00% | 0 | 0 |
| **total** | **1,750** | **16,250** | **452,792** | **100.00%** | **0** | **0** |

Zero disagreements, zero illegal rounds, zero bbpPairings process errors
across all six. This is a session-scale corpus, not a millions-of-rounds
one - proportionate to a single knob's first validation, not to the
project's largest axes - and every disagreement-finding run along the way
(before the TPN-reassignment fix) is recorded above as what it actually
was: a harness defect, not an engine one. No Ainalrami engine change was
made or was suggested by anything this run found.

**What this does not cover.** Every axis here draws entry between round 2
and about the middle of the event; a late entrant arriving in the LAST
few rounds, or a field where every player is a late entrant relative to
some other reference round, is untested. Team tournaments (validated
separately, see [Team Swiss pairings](#team-swiss-pairings-c046)) and the
`rounds_count`/`XXR` mismatch remain the harness's other two gaps (see
"Not covered" below).

## Performance

**Current figures are in [performance.md](performance.md)**: the direct
bracket, which put the pairing ahead of Gacrux on every benchmark file
(see [the re-run for it](#re-run-for-the-direct-bracket-2026-09-28-beat-gacrux)
below), and before it the 2026-09-28 pass over 150-600-player fields,
each held byte-identical to v0.33.0 on the differential corpus. What
follows is the history up to v0.33.0.

Correctness has never been the constraint here; field size is. One round
of a real 209-player tournament, cut down to size:

| players | one round | before 2026-08-18 |
|---|---|---|
| 40 | 0.15 s | 0.19 s |
| 80 | 1.2 s | 2.1 s |
| 120 | 4.4 s | 8.3 s |
| 160 | 13 s | 24 s |
| 209 | **38 s** | 90 s |

**2.4× overall, and the growth rate barely moved** - still somewhere
between n³ and n⁴. That is worth saying plainly, because the work was
undertaken to change the exponent and mostly did not. What it bought was
a large constant factor, three times over.

### What was done

**The delta scans are maintained rather than recomputed.** Finding the
least-resistance edge from the tree to a free vertex, and between two
outer blossoms, were 84% of a solve between them and rescanned every
relevant vertex pair on every step. They are now two per-vertex caches,
updated when the tree grows, when a blossom forms and when one expands.
`Ainalrami.WeightedMatching`'s "delta-scan caches" section sets out what
makes that sound: **within a stage the outer set only ever grows**, so a
cached entry can never go stale by pointing at something that stopped
being outer.

**Edge weights are divided by their greatest common divisor first.** This
turned out to matter more than the caches. `Ainalrami.Pairing` packs
C1-C21 into a single integer by giving each criterion its own band, and on
a 209-player field that produces weights of **103 digits** - so every
`dual + dual − weight`, the innermost operation in the algorithm, was
arbitrary-precision arithmetic. In one real solve, 21,221 edges carried
just **five distinct weights sharing a ninety-digit common factor**.
Dividing it out leaves values that fit in 64 bits. Exact rather than
approximate: every matching's total scales by 1/g, so the argmax cannot
move, and `solve/2` returns pairs rather than any weight.

**Two hoisting passes** removed repeated work from the scans while they
still existed: a recursive blossom walk running once per *pair* of
blossoms instead of once per blossom, and a flat `{u, v}` weight map
replaced by adjacency, so the innermost lookup stopped allocating a tuple.

### Why it is not more

Profiling the finished version on a real solve: the scans that were the
whole problem are down to 10% of the time, and cache *maintenance* is the
other 90% - 46% rebuilding at stage boundaries, 44% refreshing after
structural changes. The work moved rather than vanished. Getting past that
needs the maintenance itself to be incremental across stages, which the
labels being recomputed wholesale by `init_labels/1` currently prevents.

### How it is verified

This is the most delicate module in the engine, and the one place a subtle
error yields a wrong pairing rather than an obvious failure. Three
independent checks:

- **`tools/matching_baseline.exs`** replays `solve/2` over 460 random
  graphs - 400 small, where blossoms are easy to hit by chance, and 60 at
  40-90 vertices - across three densities and both weight scales. Every
  one is checked for **total weight** and matched count, not byte
  identity: 460/460 optimal.
- **Byte identity is deliberately not required.** 86% of delta steps have
  a *tied* minimum, so a cache that finds any minimum takes a different
  path through the search almost every step; 38 of the 460 land on a
  different matching of the same weight, which is correct when the optimum
  is not unique.
- **That this is safe was measured before the caches were written.**
  Inverting the tie-break of the old linear scans left the engine agreeing
  with bbpPairings on 1358/1358 rounds - so the pairing is determined by
  the weights, not by the order equal-slack edges happen to be visited in.
- **The corpus**, which is the check that actually matters. With the
  caches in place, **39,371 rounds and 435,294 individual pairings at
  100.00%**, zero illegal and zero refusals:

  | axis | rounds | individual pairs |
  |---|---|---|
  | byes + forfeits + `XXP` + Baku, 2,000 tournaments | 13,252 | 132,065 |
  | 15% byes, **10** rounds, 2,000 tournaments | 18,332 | 186,645 |
  | **60-120 players** | 1,050 | 48,132 |
  | plain / byes / combined / 8-round, 250 each | 6,737 | 68,452 |

  The large-field row is the one to look at. It is where a matcher change
  would show first, and where the differential corpus is thinnest.

### Against bbpPairings and Gacrux, on the same files

The reference is not instant either, which is worth knowing before
treating any target as obvious. Same tournaments, same machine -
bbpPairings' own generator produced every file, so no side is favoured.

**Cold process, start to finish**, which is how an arbiter's tool
actually invokes any of the three:

| players | bbpPairings (C++) | Gacrux (Python) | Ainalrami |
|---|---|---|---|
| 10 (start-up floor) | 0.18 s | 0.68 s | 0.63 s |
| 209 | **0.72 s** | 0.88 s | 0.86 s |
| 400 | 3.05 s | 1.22 s | **1.35 s** |
| 1,000 | 50.1 s | **5.14 s** | 7.12 s |

Each engine pays a fixed start-up it cannot avoid - a C++ binary 0.18 s,
CPython plus networkx 0.68 s, the BEAM 0.63 s. Subtracting each one's own
floor leaves the **pairing work**:

| players | bbpPairings | Gacrux | Ainalrami |
|---|---|---|---|
| 209 | 0.54 s | **0.20 s** | 0.23 s |
| 400 | 2.87 s | **0.54 s** | 0.72 s |
| 1,000 | 49.9 s | **4.46 s** | 6.45 s |

On every one of these rounds all three engines return the **identical
boards** - 105 of 105, 200 of 200, 500 of 500, colours included.

**Read honestly: this engine is faster than the C++ reference and a
little slower than the Python one.** Against bbpPairings the pairing work
is 2.3×, 4× and 7.7× quicker, though a cold 209-player invocation is
still within a rounding error of it, on start-up alone. Against Gacrux it
is 1.15×, 1.3× and 1.45× slower -- close enough at 209 players that the
difference is smaller than the run-to-run spread, and never more than
half again as slow.

That ordering is not about the languages, and the morning's numbers show
why: 209 players took 9.5 s here yesterday evening and 85 s at 1,000
players this morning, which is 24× and 11× behind Gacrux. What changed
was how much of the whole-field matcher each bracket has to run.
bbpPairings runs all of it, every bracket, eight refinement stages deep -
~n³ a round, and that is the 50 s. Gacrux runs almost none of it: its
`BI` path walks Article 3's transposition procedure directly and accepts
the first candidate that is legal and meets a counting bound on the
colour criteria, falling back to a bracket-sized networkx matching only
where that fails. This engine now solves a bracket on **its own graph**
whenever that is provably the whole-field answer (`Pairing.pair_bracket/6`:
every window member a non-candidate for the bye, a perfect internal
matching, and the rest of the field pairable without it, certified by a
sparse cardinality oracle), with a one-vertex stand-in for the next score
group on odd brackets, and on the whole field otherwise. Same destination
as Gacrux's, reached from the matcher side rather than the procedure
side - so the eight stages, and the 100.00% they carry, are unchanged.

**Correctness is not what degrades.** Every step was held to 100.00% on
seven corpus axes - 4-10, 4-40, 60-120 and 150-250 players, with byes,
forfeits, forbidden pairs, acceleration and round counts of 7, 8 and 13 -
and both differential nets before it was committed, and the large-field
axes are where the local graph does its work. The 5-million-tournament
run on the Photon box was restarted on the final engine and is the judge
of the one condition not certified term by term: that an odd bracket's
float choice does not depend on which member of a dense next group it
lands on (`@local_min_next_group`).

### What it means in practice

Club and national events - up to ~150 players - pair in well under a
second including start-up. A 200-player open is about a second, a
400-player open two, and a Moscow-Open-sized event of 1,000 players
seven - against the C++ reference's fifty. Inside a long-lived process
(the sibling OpenPairings app, or any server) the 0.63 s BEAM start-up is
paid once rather than per round, which is most of the small-field cost.

### Re-run for the large-field matcher rewrite (2026-09-28)

Same methodology, same three programs, run again to compare the matcher
rewrite (`perf-large-fields`, 083ec3d) against both the reference it is
built on (v0.33.0, fb7eecc, `origin/main`) and the external references.
209/400/1,000-player files generated exactly as before (`Ainalrami.Generator`,
seed `20260827 + players`, 5 of 9 rounds played, round 6 timed); 600
players added at three round shapes from the same generator - round 1
(no history), round 2 (one round of history, the shape that turns out to
matter most below) and round 9, a late round with `final_round_topscorers?/2`'s
relaxation live. Every file's declared round count was raised to 9 (a
header edit only - `142`/`XXR`, no player history touched) so a
5-of-9-rounds file asks for round 6, not "the tournament is over".

**Machine load.** This machine has 16 logical processors and another
agent's job (`python`, pid 28012) was running the whole time, `Get-Counter`
sampling 40-80% total processor time throughout. That inflates every
absolute number below relative to the original table's (which was not
taken under load) - the BEAM floor alone reads 0.87 s here against 0.63 s
before, and Gacrux's 1.18 s against 0.68 s. What stays meaningful is the
**relative** standing between engines, because all four ran back-to-back,
file by file, under the same load. 5 repeats per file (3 for 1,000
players, whose bbpPairings runs alone cost 50 s each); min and median of
each are reported. Identical boards were checked on every file across all
four engines (composition and colour) before any timing ran:
105/105 (209), 200/200 (400), 500/500 (1,000), 300/300 on each of the
three 600-player round shapes - zero disagreements, as before.

**Cold process, start to finish** (min / median):

| players | bbpPairings (C++) | Gacrux (Python) | Ainalrami v0.33.0 | Ainalrami perf-large-fields |
|---|---|---|---|---|
| 10 (start-up floor) | **0.16 / 0.17 s** | 1.14 / 1.18 s | 0.85 / 0.87 s | 0.84 / 0.87 s |
| 209 | **0.70 / 0.73 s** | 1.42 / 1.52 s | 1.33 / 1.42 s | 1.16 / 1.31 s |
| 400 | 2.84 / 2.92 s | **1.96 / 2.05 s** | 2.49 / 2.62 s | 1.96 / 2.13 s |
| 1,000 | 49.98 / 50.87 s | **6.86 / 6.87 s** | 10.22 / 10.26 s | 7.76 / 8.00 s |

(min / median; bold marks the fastest of the four on that row.)

Pairing work (each engine's own median floor above subtracted from its
own median cold number):

| players | bbpPairings | Gacrux | Ainalrami v0.33.0 | Ainalrami perf-large-fields |
|---|---|---|---|---|
| 209 | 0.57 s | **0.34 s** | 0.55 s | 0.44 s |
| 400 | 2.75 s | **0.87 s** | 1.75 s | 1.26 s |
| 1,000 | 50.71 s | **5.69 s** | 9.39 s | 7.13 s |

perf-large-fields over v0.33.0: **1.24×, 1.39×, 1.32×** faster on this
axis (209/400/1,000) - in the same range as `docs/performance.md`'s own
"pairing" part at 150-600 players (1.5-1.7×), on a very different
workload (cold CLI process vs. a click's worth of work timed in-VM).
Against Gacrux, pairing work is still **1.29×, 1.44×, 1.25×
slower** - the same "1.15-1.45×" band the original table found, not
narrowed by this rewrite, because the rewrite targets the matcher
perf-large-fields improves on both sides of. Against bbpPairings the
pairing work is **1.29×, 2.19×, 7.11×** quicker.

**The 600-player round shapes** (cold process, min / median) turn out to
matter more than the player count:

| round | bbpPairings | Gacrux | Ainalrami v0.33.0 | Ainalrami perf-large-fields |
|---|---|---|---|---|
| 1 (no history) | 9.46 / 9.87 s | 2.09 / 2.11 s | 0.82 / 0.86 s | **0.83 / 0.83 s** |
| 2 (one round played) | 8.16 / 8.19 s | **2.19 / 2.26 s** | 11.20 / 11.21 s | 7.20 / 7.30 s |
| 9 (late, relaxed colour) | 12.35 / 12.91 s | 3.79 / 3.99 s | 5.20 / 6.08 s | **3.27 / 3.40 s** |

Round 1 has no history for the local-graph fast path to worry about, so
both Ainalrami builds clear bbpPairings by ~11× and Gacrux by ~2.5×.
Round 9 - the shape that exercises `final_round_topscorers?/2`'s
last-two-rounds relaxation - is perf-large-fields's best result of this
whole pass: faster than Gacrux, not just bbpPairings. Round 2 is the
opposite: a field one round in has few, very large score-group brackets,
which is exactly the shape `local_eligible?/4`'s parity-dependent guard
turns away from the cheap path (documented in `tools/parity_bench.exs`'s
own moduledoc) - both Ainalrami builds fall back to the whole-field
matcher there, and even perf-large-fields lands behind bbpPairings and
more than 3× behind Gacrux on this one shape.

**Pinned, `+S 2:2`** (the production VPS's core count; bbpPairings and
Gacrux are single-threaded already, so only Ainalrami was re-measured -
min / median):

| file | Ainalrami v0.33.0 | Ainalrami perf-large-fields |
|---|---|---|
| 209 | 1.57 / 1.59 s | **1.37 / 1.38 s** |
| 400 | 2.78 / 3.81 s | **2.41 / 2.44 s** |
| 1,000 | 12.26 / 13.14 s | **9.32 / 9.54 s** |
| 600, round 1 | 1.01 / 1.04 s | **0.91 / 0.97 s** |
| 600, round 2 | 13.21 / 14.20 s | **8.57 / 9.37 s** |
| 600, round 9 | 5.23 / 5.36 s | **3.44 / 3.52 s** |

perf-large-fields is faster than v0.33.0 at every size and every round
shape, pinned or not - the round-2 gap is the widest of all of them
(v0.33.0 loses more of its two cores to the whole-field matcher than
perf-large-fields does).

**Read honestly: still behind Gacrux, not ahead of it.** The rewrite
narrows Ainalrami's own gap to its predecessor by roughly a third
(1.24-1.39×) without closing the gap to Gacrux, which sits essentially
where the original table left it (1.15-1.45× before, 1.25-1.44× now - the
difference is machine load, not the matcher). Where Ainalrami now wins
outright is round shape rather than field size: a fresh round 1 and a
late, colour-relaxed round both beat Gacrux under this load, and only the
one-round-of-history shape - large, thin score-group brackets - still
sends it to the slow path Gacrux's transposition procedure never needs.

### Re-run for the direct bracket (2026-09-28, `beat-gacrux`)

The same six files and the same cold-process method, on the branch that
answers most brackets without the refinement stages
([performance.md](performance.md#the-direct-bracket-2026-09-28)),
against perf-certify (the tree it builds on: v0.34.0 plus the certified
shortcuts) and both references. Boards identical across all four
programs on every file, colours included - 105/105, 200/200, 500/500 and
300/300 on each 600-player round shape. Median of 5 cold runs (3 at 1,000
players); one other job (`python`) ran throughout at ~15% of total CPU,
much less than the 40-80% of the re-run above, which is why every
absolute number here is lower than there.

**Cold process, start to finish:**

| file | bbpPairings (C++) | Gacrux (Python) | Ainalrami perf-certify | Ainalrami beat-gacrux |
|---|---|---|---|---|
| 10 players (start-up floor) | **0.05 s** | 1.08 s | 0.75 s | 0.75 s |
| 209, round 6 | **0.59 s** | 1.32 s | 1.07 s | 0.83 s |
| 400, round 6 | 2.81 s | 2.05 s | 1.99 s | **0.86 s** |
| 1,000, round 6 | 51.6 s | 7.47 s | 7.92 s | **0.89 s** |
| 600, round 1 | 9.59 s | 2.22 s | 0.74 s | **0.74 s** |
| 600, round 2 | 8.29 s | 2.37 s | 7.47 s | **0.82 s** |
| 600, round 9 | 10.8 s | 3.63 s | 3.33 s | **0.92 s** |

**Pairing work** (each program's own floor subtracted):

| file | bbpPairings | Gacrux | Ainalrami perf-certify | Ainalrami beat-gacrux |
|---|---|---|---|---|
| 209 | 0.54 s | 0.24 s | 0.32 s | **0.08 s** |
| 400 | 2.76 s | 0.97 s | 1.24 s | **0.11 s** |
| 1,000 | 51.6 s | 6.39 s | 7.17 s | **0.14 s** |
| 600, round 1 | 9.54 s | 1.14 s | 0.00 s | **0.00 s** |
| 600, round 2 | 8.24 s | 1.29 s | 6.72 s | **0.07 s** |
| 600, round 9 | 10.8 s | 2.55 s | 2.58 s | **0.17 s** |

> **SUPERSEDED as a comparison (2026-09-30).** The ratios below are one
> file per row, and one position can land on a shape slow for one engine
> only. The comparison to quote is the timing study's medians over 3,000
> positions ([performance.md](performance.md#the-timing-study-2026-09-30));
> the boards-identical result on these files stands.

**Read honestly: ahead of Gacrux now, on every file.** 3.0x at 209
players, 8.8x at 400, 46x at 1,000, 18x on the one-round-of-history shape
that was 5x behind, 15x on the late round. Against bbpPairings the pairing
work is 7-370x quicker. The one cold total this engine does not win is the
209-player file, where bbpPairings' 0.05 s start-up against the BEAM's 0.75
s decides it; from 400 players up this engine is the fastest of the three
cold as well. What closed the gap was not faster code but less matching -
Gacrux's own lesson: most brackets are now answered by walking Article 3's
order and proving the result is what the stages would return, and a
1,000-player round is cheaper to pair than to start the VM for. Pinned to
two schedulers (the production VPS) the beat-gacrux column is unchanged
within noise. Every answer is the one v0.33.0 gives: 892,324 rounds of the
differential corpus, 0 differences
([performance.md](performance.md#how-it-was-checked)).

The files and scripts: `Ainalrami.Generator` with
`--seed=<20260827 + players> --players=<n> --rounds=<played>`, every file's
`142` raised to 9 and no `XXR` line added (bbpPairings refuses a file whose
`XXR` disagrees with the rounds it holds); Gacrux
invoked as `pairingchecker.py -i FILE -o OUT -p -dT -m dutch`, bbpPairings
as `--dutch FILE -p OUT`, this engine as its escript's `FILE -p OUT`.

### Against Gacrux alone, 3.2 million rounds (2026-09-30)

On the 80-vCPU VM of the timing study, engine commit 030bd28 (the slow
spots pass) against Gacrux only, the `gacrux_only` harness
(`test/ainalrami/gacrux_only_test.exs`) over nine-round tournaments in
five size bands, seeds from 9,000,001 / 9,100,001 / 9,200,001 / 9,300,001
/ 9,400,001:

| players | tournaments | rounds identical / compared | boards, same colours / shared |
|---|---|---|---|
| 500-1,000 | 3,500 | 31,500 / 31,500 | 11,835,963 / 11,835,963 |
| 300-500 | 15,000 | 135,000 / 135,000 | 26,975,088 / 26,975,088 |
| 150-250 | 35,000 | 315,000 / 315,000 | 31,414,014 / 31,414,014 |
| 40-120 | 70,000 | 630,000 / 630,000 | 25,023,582 / 25,023,582 |
| 4-40 | 250,000 | 2,108,228 / 2,108,228 | 23,815,720 / 23,815,720 |
| **total** | **373,500** | **3,219,728 / 3,219,728** | **119,064,367 / 119,064,367** |

0 rounds for review, 0 colour reviews, 0 rounds where Gacrux breaks
Article 5.2.5. Everything else was on Gacrux's side: 25,761 rounds at 4-40
players where it returned Error 510 (an exception escaping the checker;
counted, dumped and kept out of every rate since 0.11.0) and 5 Gacrux
crashes, which the harness reports as test failures. A two-way run against
one reference; it adds coverage at large field sizes, where the three-way
run is thin, not a third opinion.

### Release check for 0.36.0 (2026-10-02)

On the same 80-vCPU VM, engine commit be3ae86 (0.36.0 differs from it in
tests only), two runs of eight- to eleven-round tournaments with byes,
forfeits, withdrawals, late entries, mixed ratings and initial colours.
**Figures as of 2026-10-02 18:48 UTC; both runs were still in progress,
so these are partial totals, not final ones.**

Against Gacrux 1.9.57 alone (`gacrux_only`):

| players | tournaments | rounds identical / compared | boards, same colours / shared |
|---|---|---|---|
| 500-1,000 (complete) | 1,500 | 14,260 / 14,260 | 4,516,973 / 4,516,973 |
| 300-500 (complete) | 7,500 | 71,377 / 71,377 | 12,067,266 / 12,067,266 |
| 150-250 (complete) | 20,000 | 189,981 / 189,981 | 16,014,440 / 16,014,440 |
| 40-120 (complete) | 30,000 | 285,209 / 285,209 | 9,570,000 / 9,570,000 |
| 40-120, Baku (complete) | 25,000 | 237,902 / 237,902 | 7,960,015 / 7,960,015 |
| 4-40 (running) | 25,000 | 215,714 / 215,971 | 2,083,809 / 2,083,812 |
| **total so far** | **109,000** | **1,014,443 / 1,014,700** | **52,212,503 / 52,212,506** |

Gacrux artefacts kept out of the rates as before: 1,276 Error 510 rounds
and 172 Gacrux crashes (exit 139).

Every dumped disagreement of the 4-40 axis - 256 rounds for review, 1
Article 5.2.5 round and 1 round this engine paired that Gacrux did not, 258
in all - was judged against the rules rather than against either engine:
each answer checked for every available player paired exactly once, at
most one bye and only on an odd field, no pre-assigned H/Z player paired,
C1 (no rematch), C2 (no second PAB or earlier unplayed full point), C3 and
forbidden pairs; claims that a round cannot be paired checked by
exhaustive search; bbpPairings re-run as a third answer. Results:

- This engine's answer breaks no rule on any well-formed file, and is the
  same as bbpPairings' wherever bbpPairings answered.
- Gacrux's answer breaks at least one rule in 257 of the 258. 100 are the
  first disputed round of a tournament; the rest follow from an earlier
  Gacrux round, because the harness continues each tournament on Gacrux's
  pairing. In 63 Gacrux pairs a round that exhaustive search shows has no
  legal pairing (this engine and bbpPairings both refuse it). Every Gacrux
  C2 violation involves an earlier `U` result, which Gacrux's TRF reader
  maps to a played game.
- 13 of the 258 are files that already reach the `XXR` round count
  (downstream of the above); bbpPairings refuses them, this engine pairs
  them. That is lenient input checking, not a pairing error.
- 1 is ambiguous input (the only present player already holds `H` for
  round 1): this engine and bbpPairings read round 1 as complete and give
  the round-2 bye, Gacrux does not pair. Not counted as a defect of
  either.

Against bbpPairings 6.0.0, with forbidden pairs and Baku acceleration:

| axis | tournaments | rounds identical / compared | pairs identical / total |
|---|---|---|---|
| forbidden pairs, 4-40 (complete) | 600,000 | 5,150,470 / 5,150,470 | 52,835,215 / 52,835,215 |
| forbidden pairs, 40-120 (complete) | 120,000 | 1,140,417 / 1,140,417 | 38,886,147 / 38,886,147 |
| Baku, 4-40 (running) | 500,000 | 4,323,868 / 4,323,869 | 44,112,938 / 44,112,940 |
| **total so far** | **1,220,000** | **10,614,755 / 10,614,756** | **135,834,300 / 135,834,302** |

0 rounds refused or paired illegally by this engine. The one mismatch
(seed 15122973, round 6, Baku acceleration) is a bbpPairings answer that
breaks C2, by the same rule check. 8 bbpPairings process errors, and
248,580 tournaments ended early when the reference ran out of legal
pairings (excluded, as in every corpus here).

Two-way runs against one reference each; the rule check covers only the
rounds where the engines disagreed.

## Pairings (VCL4THP Q33), both directions

VCL4THP v13 Q33 asks for at least 50,000 tournaments cross-checked each way
against another public program, pairings and tie-breaks both. Tie-breaks
are covered below. For pairings, "each way" means two different
generators:

| direction | generator, checked by | tournaments | rounds | individual pairs | disagreements |
|---|---|---|---|---|---|
| 1 | Ainalrami (`Ainalrami.Test.FuzzTournament`), checked by bbpPairings | 5,993,000 x2 + four smaller corpora | 217,470,056 | 2,536,328,265 | 2 (bbpPairings' own [C2] defect, see below) |
| 2 | bbpPairings' own `-g` generator, checked by Ainalrami | 50,045 (+158 where bbpPairings' own generator found no legal pairing) | 499,816 | 28,964,816 | 0 |

Direction 1 is "The corpora" and "The corpus" above - the number everything
else on this page rests on. Direction 2 did not exist at any real scale
until 2026-09-27: before it, this engine had read exactly one file it did
not write (`test/fixtures/interop/bbppairings-generated.trf`, 209 players,
five rounds) plus a handful of single-file performance benchmarks ("Against
bbpPairings and Gacrux, on the same files" below) - real coverage of
"can this engine read and correctly re-pair an arbitrary file from the
other implementation", but nowhere near the fuzzed-axis scale direction 1
has always had.

### Why direction 2 needed its own tool, not a bigger `PAIRING_FUZZ_COUNT`

bbpPairings ships its own random tournament generator (`-g`,
`src/tournament/generator.cpp`): it picks `PlayersNumber` (15-215),
`RoundsNumber` (5-15), forfeit/retirement/half-point-bye rates and a draw
percentage, then PAIRS THE WHOLE TOURNAMENT ITSELF, round by round, with
its own engine. `tools/bbp_generator_reverse.exs` generates one of these,
parses it, and replays every round through
`Ainalrami.Pairing.pair_next_round/2` from the state immediately before
that round - the same `state_before_round/3` / `recorded_pairs/2` logic
`Ainalrami.CLI`'s `-c` (Pairings Checker) uses internally, reimplemented
here (both are private in `lib/ainalrami/cli.ex`) so a whole corpus can run
without shelling out to the escript once per file. Cross-checked directly:
the real `-c`, run on one of this run's own generated files, reports
"10/10 round(s) match" (round 1 noted as "same pairing, different
colours" - see "Colour" below) - confirming the reimplementation agrees
with the project's own trusted checker rather than quietly checking
something else.

Two things make this a genuinely different axis from direction 1, not a
relabelled copy of it:

- **The generator writes no round-count header and no `152`.** Confirmed
  against `test/fixtures/interop/README.md` and by direct invocation, so
  `expected_rounds` is taken from the file itself (every player's games
  list is padded to the tournament's true length, `U` entries included),
  never supplied. Direction 1 states `initial_colour:` explicitly on every
  single comparison (see `bbppairings_comparison_test.exs`'s moduledoc), so
  `infer_initial_colour/1` is never reached by any of its 2.5 billion
  pairings. Direction 2 never states it from round 2 on -
  `pair_next_round/2` falls through to inference exactly as it would for
  any real silent TRF, which is the realistic case this project's own
  CHANGELOG describes running into first ("the comparison harness only
  ever fed this project's files to them, and nothing here had ever read a
  TRF written by anything other than this engine").
- **A seeding trap, found and fixed before it silently produced a
  degenerate corpus.** bbpPairings seeds a plain `std::minstd_rand` (a
  Park-Miller LCG) with `-s`, and `RoundsNumber` is the FIRST value drawn
  from it. Seeds 1..100, tried first, gave `RoundsNumber = 5` on every
  single one (20/20 sampled) - an LCG correlating badly on consecutive
  small seeds, not a property of the generator's intended 5-15 spread
  (confirmed: the same 20 indices, run through a multiplicative hash
  first, span 4-15 rounds instead). The tool hashes its running index
  (`rem(i * 2_654_435_761, 2_147_483_646) + 1`) before handing it to `-s`,
  keeping the seed-to-tournament mapping deterministic and resumable while
  actually sampling the generator's real distribution rather than one
  corner of it.

### Colour

Round 1 has nothing to infer colour from (no history, no `152`), so an
arbitrary `initial_colour: "w"` is passed and only composition (who plays
whom) is compared there - the same posture `test/ainalrami/interop_test.exs`
already takes on the single fixture, and the reason the real `-c` reports
round 1 as matching "with different colours" rather than as plain clean.
From round 2 on, no `initial_colour` is passed at all: inference runs for
real, against a genuine bbpPairings history it did not construct - a path
direction 1's 2.5 billion pairings never exercise, because every one of
them states the colour instead. **Result: 25,842,761 boards formed by both
engines from round 2 on, zero colour disagreements.**

### The numbers, and what they don't cover

50,203 tournaments attempted (seed indices 1-50,203, run 2026-09-27 on the
development PC: a first pass of 5,603 at 16-way concurrency, then resumed
at 12 schedulers for the rest, about nine hours in all); 158 excluded
because bbpPairings' OWN generator hit "no valid pairing exists" while
building the tournament - its generator calls its own pairing engine every
round exactly like a real event would, and can run out of legal pairings
the same way direction 1's corpus does (see
[what the corpus could not see](#what-the-corpus-could-not-see)). The
remaining **50,045 tournaments, 499,816 rounds, 28,964,816 individual
pairings, zero disagreements** - composition and colour both - and zero
Ainalrami refusals.

**Q33's 50,000 is met in this direction too.** The run is resumable:
`tools/bbp_generator_reverse.exs` skips any seed index already present in
its result log (kept locally, `tools/bbp_reverse_results.log`, gitignored
like the tie-break corpus logs below), so extending it is a matter of
re-running it with a higher `BBP_REVERSE_COUNT`. Zero composition
mismatches were dumped over the whole run.

## Team Swiss pairings (C.04.6)

No outside program can check a team Swiss pairing automatically: bbpPairings,
JaVaFo, Gacrux and SWAR do not pair teams, and Swiss-Manager is closed
Windows software
([conformance-c0406-teams.md](conformance-c0406-teams.md#verification-no-reference-we-can-automate-against)).
C.04.6 makes up for it: Article 3.6 defines the pairing as the first
element of an enumerable order, so a reference that enumerates it IS the
definition. The references below are written from the regulation text
and share no code with `Ainalrami.TeamPairing`. They share its readings
(listed in the conformance notes), so they prove the computation, not the
reading.

| run | reference | seeds | rounds | result |
|---|---|---|---|---|
| whole rounds, 4-10 teams, Type A (2026-09-26) | brute-force whole-round reference | 1-250,000,000 | 1,032,949,115 | 0 failures, 0 errors |
| whole rounds, 4-10 teams, Type A, 0.37.0 (2026-10-05) | the same reference | 250,000,001-860,000,000 | 2,520,496,171 | 0 failures, 0 errors |
| whole rounds, 4-10 teams, no colour preferences (2026-09-27) | the same reference, `type: :none` | 1-30,000 | 123,593 | 0 disagreements |
| whole rounds, 11-80 teams (2026-09-25) | exact reference (min-cost matchings) | 1-2,000 | 11,980 | every round agrees, reasons included |

### Whole rounds, 4-10 teams

`test/ainalrami/team_pairing_validation_test.exs` plays generated events
(4-10 teams, 3-6 rounds, random results, whole-match forfeits, byes and
teams sitting a round out, either initial colour) through the engine and
compares every round with the brute-force reference
(`test/support/team_proof/naive_reference.ex`): who meets whom, the bye,
and the colours. `mix test` runs 90 seeds; `tools/team_validation_run.exs`
runs the same test many times at once on separate seed ranges and is
resumable. The long run covered seeds 1-250,000,000 - 1,032,949,115 team
rounds - with no failure and no error, finishing 2026-09-26 on Ainalrami
commit `d0f16e8`. A second run on 0.37.0 (2026-10-05, an 80-vCPU VM, 72
workers, 10.8 hours) took the next 610,000,000 seeds, 250,000,001-860,000,000:
2,520,496,171 team rounds, again with no failure and no error. Together:
seeds 1-860,000,000, 3,553,445,286 team rounds.

### Large fields, 11-80 teams

Brute force stops at about ten teams. `docs/team-proof-large-fields.md`
describes an exact reference for whole rounds up to 80 teams, built on
minimum-cost matchings rather than enumeration and itself checked against
the brute-force one (2,000 seeds, 8,273 rounds, no disagreement). It found
one disagreement: the engine's 3.6 search stopped after a candidate budget
and could return a legal round C.04.6 does not choose (seed 126 at the
default budget, seed 480 at 10,000,000 candidates). 0.30.0 made 3.6 exact;
since then 2,000 seeds and 11,980 rounds agree, reasons included.

### No colour preferences

C.04.6 Article 1.7's third option, which FIDE's TRF-2026 code table gives
to `FIDE_TEAM_MP_GP` and the other codes without `TYPEA`/`TYPEB`: 30,000
seeds, 123,593 rounds against the same brute-force reference, 0
disagreements. Details in
[conformance-c0406-teams.md](conformance-c0406-teams.md#no-colour-preferences-17-2026-09-27).

### The checker on team files

`ainalrami -c` replays a team Swiss file team against team with the C.04.6
engine (`Ainalrami.TeamReplay`) and reads the `192` code per FIDE's
published TRF-2026 Tournament Type Code Table (`Ainalrami.TypeCode`); see
the README's command-line section. No real team TRF has been available to
run it on (see "Real team files" under the team tie-break run below).

## Tie-breaks (C.07, effective 1 March 2026), against TieBreakServer

VCL4THP v13 Q33 asks for at least 50,000 tournaments cross-checked each way
against another public program, tie-breaks included. The other program is
FIDE's TieBreakServer (Otto Milvang, MIT), run with every code at `/V2026`.
Each comparison covers every value of every player, and the final ranks
under a tie-break list (`BH/C1 BH SB DE` for Swiss, `DE SB KS` for round
robins).

| direction | generator | tournaments | values | unexplained | known |
|---|---|---|---|---|---|
| 1 | Ainalrami (`tools/tiebreak_corpus.exs`, `tools/tiebreak_direction1.exs`) | 50,060 | ~29 million | 0 | 147,873 in the last 38,000 |
| 2 | TieBreakServer's `tournamentgenerator.py` (`tools/tiebreak_direction2.exs`) | 50,000 | 49,987,100 | 0 | 2,039 |
| teams | board-level team events (`tools/team_tiebreak_compare.exs`) | 2,200 | ~405,000 | 0 | 11 |

Run 2026-09-23/24 on the development PC. Direction 2 used six setups in
rotation: Swiss 16x7, 40x9, 64x9 with raised unplayed-round rates, 100x11,
and round robins of 9 and 10. TieBreakServer's own generator fails with
`-a` (acceleration), so no accelerated setup is included.

"Known" differences are the ones explained in
`docs/finding-tiebreakserver-2026-09.md` and
`docs/conformance-c07-tiebreaks.md`, and the tools classify each one:
reading 8 (STD), finding B (SB/C1's VUR choice), and for teams finding C
(direct encounter after a rematch). Findings A and D and reading T4 were
found with targeted runs and are kept out of the default lists. Direction
1's known count is mostly STD, which the corpus lists for every player.

Direction 1 found one fault on our side, in the generator rather than the
tie-breaks. When every player held a bye before a round was paired, the
generator wrote two rounds in one step, so the file had one round more than
its `142` said, and Fore Buchholz's "last round" differed (seed 1002432).
It is fixed, with a test; the batch was rerun on the fixed generator.

### An independent reference (2026-09-25)

The "known" differences above are points where TieBreakServer could not
confirm our answer, so on them the engine was backed by its own reading
only. `Ainalrami.TiebreakReference` is a second, deliberately naive
implementation of C.07 written from the text, sharing no code with
`lib/ainalrami/tiebreaks*`, and `test/ainalrami/tiebreak_reference_test.exs`
compares the two on every value and on the final ranks: generated Swiss
events with every checklist option, round robins, board-level and
match-by-match team events, and hand-built events aimed at each disputed
point (STD, finding B's SB/C1, finding A's order, finding C's repeated
meetings, finding D and reading T4's Board Count, the Koya maximum, the
16.4.2 cap, reading 9, Article 16's categories). 15,000 events, 8.3 million
values, zero disagreements; five deliberate mutations of the reference were
each caught. It confirms the engine computes the recorded readings, not
that they are FIDE's, and it raised four reading questions the conformance
notes did not record. Details: `docs/tiebreak-reference.md`.
### Random tie-break lists (2026-09-25)

The run above ranked every tournament under one fixed list, so most codes
and modifiers were compared as values but never inside a full ranking, and
order-dependent behaviour (finding A) could not show. The comparison tools
now take `--random-lists SEED` (`tools/tiebreak_random_list.exs`): per
tournament, a list of one to six entries drawn from every code and modifier
the engine supports - DE and DE/P; BH, FB with C1/C2/M1/M2; AOB and AOB/F;
SB and PS with C1/C2; KS with L1/L2/L-1/L-2; WIN WON BPG BWG REP STD; TPN
and RTNG with and without R; ARO (all cuts), TPR, PTP, APRO, APPO with U1000,
U1400 or no floor - reproducible from (SEED, tournament number). No entry
twice, at most one direct-encounter code, no Buchholz family in round
robins (Article 8). Team lists start with MPTS (or GPTS one time in four)
and draw from EDE and its four variants, DE, MPVGP, BC, TBR, BBE, SSSC and
SSSC/F, the four ESBs with and without C1, and BH/FB/AOB/SB/PS/KS/WIN/WON
on either score. The values of every code in the list and the final ranks
under it are compared.

| run | tournaments | values | rank comparisons | rank differences known | unexplained |
|---|---|---|---|---|---|
| direction 1, seeds 2,000,000-2,009,999 | 10,000 | 750,765 | 10,000 | 3,620 players | 0 |
| direction 2, batches 2000-2099 (seeds 200,000-209,999) | 10,000 | 1,325,550 | 10,000 | 78 players | 0 |
| teams, seeds 30,000-31,999 | 2,000 | 98,140 | 2,000 | see below | 0 |

List seed 2026 throughout. Known value differences: 10,049 (direction 1,
nearly all STD) and 167 (direction 2).

**How a rank difference is judged.** It counts as known only when a
documented cause accounts for all of it. The tool ranks the field again
from TieBreakServer's own printed values, with our direct encounter (and,
for teams, our group codes, with TieBreakServer's BC and knockout rules
modelled). If that replay does not give TieBreakServer's ranks, the
difference is unexplained unless it is finding C. If it does, every value
the ranking used must be ours or a known difference - reading 8, finding B,
finding A (the ranking run's value differs from TieBreakServer's own value
with the Fore codes sent last, and that one is ours or itself known),
reading 12, or on teams reading T6 - and at least one named cause must be
present; otherwise it is unexplained.

**What the random lists found.**

- **Our fault: the primary score of a team list** (reading T5). A list
  starting with GPTS ranked by game points but ran MPVGP, SSSC, EDE and
  codes without a score on match points. Fixed, with tests.
- **Finding E** (`finding-tiebreakserver-2026-09.md`): TieBreakServer
  applies Board Count to teams whose game points differ, which 12.1
  forbids.
- **Readings T6 and T7** (`conformance-c07-tiebreaks.md`): Type B codes on
  game points counted per board game; EDE's knockout steps applied to two
  teams level on one score only.
- **Reading 12:** TieBreakServer ranks AOB rounded to two decimals.
- **Findings A and B together** in one ranking (direction 2, t205511 under
  `FB/M2 SB/C2 FB/C1`), now classified as such.

A first pass of both directions ran with a classifier that could call a
rank difference "known" without naming a cause (it was reading 12); both
directions were rerun from scratch with the final classifier and gave the
same totals. In a 1,000-tournament sample of direction 1 the known rank
differences were reading 8 (36 tournaments) and reading 12 (3). The team
run's known rank differences by cause, per event: finding E 76, finding D
with readings T4/T7 15, both 17, reading T6 23 (plus 1 with D), finding C
2; 104 events had values known as reading T6.

### The nightly tie-break check

`.github/workflows/tiebreak-check.yml` runs a bounded version of all of the
above every night (02:17 UTC), on demand (`gh workflow run tiebreak-check.yml`,
optionally `-f seed_base=N`), and on pull requests touching the tie-break
code, `trf.ex`, the tools or the reference. TieBreakServer is fetched from
github.com/OttoMilvang/TieBreakServer at the commit pinned in `TBS_COMMIT`
(`14a34a2`, the version the runs above used) and never vendored.

Each run takes a seed base N (the run number unless given) and checks:

| step | size | seeds |
|---|---|---|
| reference proof (`tiebreak_reference_test.exs`, scale mode) | 500 events | 1,000,000 + 500N .. +499 |
| direction 1, random lists `N` | 100 tournaments | 10,000,000 + 100N .. +99 |
| direction 2, random lists `N` | 6 batches of 17 (every setup) | batches 100,000 + 6N .. +5 |
| team events, random lists `N` | 100 events | 1,000,000 + 100N .. +99 |

so every night covers new ground. The whole job takes about a minute and a
half on a GitHub runner. Any unexplained difference, reference disagreement
or tool error fails the job; the failing step's annotation gives the seed
base and the exact command that reproduces it locally, and the files that
disagreed are uploaded as the `tiebreak-failing-N` artifact. Known
differences are counted and pass, as in the manual runs. To reproduce, run
the command from the annotation in this checkout with `TBS_DIR` and
`TBS_PYTHON` set (as above), or rerun the workflow with `-f seed_base=N`.
The tools' `--strict` (direction scripts) and `--work DIR` (team compare)
exist for this job; without them they behave as before.

### Team events, extended (2026-09-26)

The team runs above covered one shape: Swiss, 4 boards, 2/1/0, match
points primary in the fixed list. `Ainalrami.TeamTrfGenerator`
(`test/support/team_trf_generator.ex`) now drives
`tools/team_tiebreak_compare.exs`: by `rem(seed, 10)` a Swiss (6 in 10), a
team round robin single or double with free rounds (2), a Scheveningen (1)
or a Schiller-type event (1) - the last three predetermined, compared with
TieBreakServer's `-p` and without the Buchholz family (Article 8); 3-10
boards; 2/1/0 or 3/1/0 in a TRF26 `362` record, which `Team.from_trf/2`
now reads, and `310` team records carrying the final ranks; reserves; individual forfeits; whole matches forfeited and
double-forfeited, half the time with `330` records; pairing-allocated byes.
The random lists start with GPTS one time in four.

| run | events | values | rank differences known | unexplained |
|---|---|---|---|---|
| fixed list, seeds 50,000-59,999 | 10,000 | 1,290,920 | 263 | 0 |
| random lists (seed 2026), seeds 40,000-49,999 | 10,000 | 352,388 | 8,638 values and ranks | 0 |

Forfeited matches: 9,208 and 9,146. Three rank differences in the random
run (seeds 42821, 44015, 44460) were first reported as unexplained: the
tool's model of TieBreakServer's EDE knockout counted the boards of
forfeited matches, which TieBreakServer's direct encounter leaves out.
With the model corrected (played matches only) all three are finding D /
readings T4 and T7; the tool was corrected and the three rerun, not the
whole batch. Known causes, by event: finding E 400, reading T6 698,
finding G 192, finding D with readings T4/T7 105, finding C 16 + 56,
reading T9 21, finding H 1 + 3 (events set aside whole), and SSSC left
out of 18 + 120 events (finding F).

**What it found.**

- **Our fault: a match forfeited on every board** was read by
  `Team.from_trf/2` as a played match (a double forfeit as a drawn match).
  Now a forfeited match (reading T8), tested; found while building the
  forfeited-match axis. `Team.from_trf/2` also ignored `362`: match points
  came only from the option.
- **TieBreakServer findings F, G, H** (`finding-tiebreakserver-2026-09.md`):
  SSSC divides by zero when the normalising factor rounds to zero; Koya's
  odd-round-robin test misfires in Scheveningen and Schiller events; a
  board is dropped when every team-round had an individual forfeit.
- **Reading T9** (`conformance-c07-tiebreaks.md`): board numbers when boards
  meet crosswise (Scheveningen, Schiller).

The independent reference now reads board-level team TRFs itself
(`docs/tiebreak-reference.md`): 10,000 team events (every format), 3,975,739
values, and 5,000 mixed events after the change, zero disagreements;
three mutations of `Team.from_trf/2` were each caught.

**Real team files:** none available. Neither repository's fixtures hold a
team TRF, and OpenPairings' three SWAR fixtures (gitignored) are
individual events; its SWAR import does not read team tournaments.
Team rating tie-breaks are not compared: C.07 defines none and the engine
has no team rating.

### Real tournaments

OpenPairings re-ranked 43 real SWAR tournaments with Ainalrami's
tie-breaks and compared the result with SWAR's own standings. No Ainalrami
bug was found; every difference was attributed to SWAR - its use of the
2024 C.07 text, SWAR defects, or Belgian conventions. All 43 are
individual events.


#### Final result (2026-10-14): the full 11-20 axis and the harsh axis

Supersedes the interim above. Raw output is `tmp/refusal_big/results.txt`;
per-chunk totals are tabulated in `tmp/refusal_big/blocks.txt`.

| axis | tournaments | refusals | no perfect matching | legal pairing exists | controls passed | refusals on 13+ active |
|---|---|---|---|---|---|---|
| 11-20 players, 16 rounds, seeds 1-80,000 | 80,000 | 51,306 (64.1%) | 51,306 | 0 | 1,100,330 | 35,335 |
| 13-40 players, 20 rounds, 12% byes, 12% forfeits, 25% forbidden, mixed acceleration and point systems, seeds 4,701-29,100 | 24,400 | 8,230 (33.7%) | 8,230 | 0 | 447,845 | 6,420 |
| **total** | **104,400** | **59,536** | **59,536** | **0** | **1,548,175** | **41,755** |

**Disagreements: none.** Zero flagged positions, zero "oracle too strict"
controls, zero harness errors in the final tally. The 20,000-refusals-on-13+
target was passed with the 11-20 axis alone (at about seed 46,000), so the
harsh axis was run for about two hours rather than five (seeds 4,701-29,100;
seeds 1-4,700 are the 2026-10-12 row above). The 13+ figures here are counted
from the per-size histograms and are for the new runs only, not added to the
2026-10-12 ones.

**Faults in the run, and how they were handled.**

* Chunk 39,501-46,000 hit a full C: drive from another process: one
  tournament, seed 45,597, ended in a harness error ("no space left"). It was
  re-run alone afterwards: 16 positions, 0 refusals, 0 flagged, 0 errors. The
  chunk's own block still reads one harness error; the tally above counts the
  tournament once. A second chunk, 46,001-51,500, was aborted by the same
  full disk, and re-run in full (not stitched).
* `tmp/refusal_big/run_chunk.sh` now refuses to start a chunk with less than
  3 GB free on C:.
* Raw `results.txt` also holds the aborted attempts and notes saying so; the
  per-chunk table in `blocks.txt` uses only completed summaries.

**The rate.** The 11-20 axis refuses 64.1% over the full 80,000 seeds, against
the probe's 57.6% (46,052 refusals) and above the 60.1% floor computed in the
interim. The difference to the probe stays unexplained; this run says the
reference's refusals are correct, not why the probe counted fewer.

The scope limits listed under the 2026-10-12 run still apply: this proves the
reference's refusals correct, not the engine's, and the edge reading is the
brute-force tool's.

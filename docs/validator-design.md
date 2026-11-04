# Design: validating the Dubov, Burstein and Lim readings

Status: **design, nothing built.** Written 2026-11-04 against Ainalrami
main at `7480a29`. Rule texts: C.04.4.1 Dubov, C.04.4.2 Burstein and
C.04.4.3 Lim, "approved by the Council on 28/10/2025, applied from 1st
February 2026", from the local handbook mirror
(`Desktop/fide-handbook/text/C040401202602.md`, `C040402202602.md`,
`C040403202602.md`), with C.04.1 and C.04.2. Article numbers below are
those texts'.

## 0. The problem

For the Dutch system the engine is held to two independent programs,
bbpPairings and Gacrux, over hundreds of millions of rounds
(`docs/validation.md`). Agreement there tests the *reading* as well as the
code: three teams read C.04.3 separately and pair the same.

For the other three systems there is no such program:

| | what exists | what it shows |
|---|---|---|
| Dubov | `test/support/dubov_reference.ex`, a brute-force reading written from the text, no shared code: 507,945 rounds, 4-12 players, 0 disagreements | the procedure is computed as read |
| Burstein | `burstein_reference.ex`: 570,661 rounds, 0 disagreements; seeding rounds against `bbpPairings --dutch` (exact); bbpPairings `--burstein` as a control (old edition, 60.8% agreement) | as above; seeding rounds are right |
| Lim | `lim_reference.ex`: 1,012,508 rounds, 0 disagreements; the 4.2/4.3 tables and 7.2 as unit tests | as above |
| all | pairing proofs (`docs/pairing-proofs.md`) | Dutch only: every matching was optimal for its weights |

Each reference was written from the rule text, but by the same hand,
in the same project, after the readings were chosen; each says so in its
moduledoc. Agreement proves the engine computes what we read. It cannot
show that we read the text right. The readings are listed (D1-D9,
B1-B11, L1-L16 in the three `conformance-*.md` files) and the SPP
questions are parked: FIDE has not answered, and our documented readings
stand.

This design adds five layers, each catching a different kind of error:

| layer | catches | independent of our readings? |
|---|---|---|
| A. rules checker | illegal output; a criterion the engine optimises wrongly | partly: written as predicates from the text |
| B. exhaustive search, 12 players or fewer | a non-optimal pairing; a wrong order | partly: uses A's predicates |
| C. local optimality, above 12 | the same, at real sizes, as a necessary condition | partly |
| D. certificates | a matcher error; a weight encoding that is not the rule | no, but it connects A to the engine |
| E. a second reading, clean room | a reading error | **yes** |
| F. CPPDubovSystem (Dubov only) | a reading or code error | **yes** |

E and F are the only layers that can find a *reading* error that A-D
would share with the engine. They are the point of this document; A-D
make their disagreements cheap to triage.

**Not an input.** Positions on corpora, defaults and settings that the
project heard informally, and that FIDE never published, are not TEC or
Commission positions and are not used here: nothing below relies on any
FIDE body having said anything beyond the published texts and the SPP's
published rulings. "No reference corpus is published" is a statement
about what is published, nothing more.

---

## A. The rules checker

### What it is

A module per system, `tools/rulecheck/{dubov,burstein,lim}.ex` (in
`tools/`, not `lib/`, so it ships with nothing), with a CLI
`elixir tools/rulecheck/check.exs FILE.trf ROUND PAIRS` and a library
call `RuleCheck.check(system, history, round_pairing, opts) -> [verdict]`.

Rules for its authorship:

* **No code shared with the engine**, as `tools/rule_check_round.exs`
  already does for the Dutch C1-C3: it parses the TRF itself, computes
  colour preferences, scores, ARO, the Burstein index and the Lim median
  itself.
* **Written from the rule text, article by article**, by an agent that
  is given the texts and the predicate table below, not the engine or the
  conformance notes. Where the text needs a reading, the checker takes it
  as a named parameter (`d2: :literal | :c7_optimal`, `b3: ...`), and the
  default is decided *after* the checker is written, by comparing with
  the conformance notes. A predicate whose author chose differently from
  us is a finding, even before any corpus is run.
* **Its own matching code.** Several predicates need "can these players
  still be paired" or "the best value any pairing reaches". The checker
  gets its own small Edmonds blossom (cardinality) and a plain O(n³)
  weighted matcher, about 400 lines, tested against brute force on graphs
  of up to 14 vertices. Not `Ainalrami.WeightedMatching`.

### Verdict kinds

Each article gets one of four kinds:

* **H, hard**: a predicate over (history, produced pairing) alone.
  Exact at any size.
* **M, by matching**: exact at any size, but needs an optimisation (a
  matching on the checker's own code) - "no pairing has fewer X".
* **O, by order**: the article picks the *first* element of an order
  among optimal pairings. Exact by enumeration at 12 players or fewer
  (layer B); above that, a necessary condition by local moves (layer C).
* **N, not mechanical**: the text does not determine the answer (a
  reading is needed) or describes a procedure with no objective. The
  checker checks the reading's invariants and says "reading" in the
  verdict.

### Dubov (C.04.4.1)

| article | check | kind |
|---|---|---|
| 1.1.1/1.1.2 every player rated or given a provisional rating | input check | H |
| 1.6 colour preferences, 1.6.4 no games = mild Black | definition used by all checks | - |
| 1.7 ARO (played games only, rounded, 0 with no games) | definition | - |
| 1.8.2 MaxT = 2 + floor(Rnds/5) | definition | - |
| 1.9.1 round complete: everyone paired but at most one bye | count | H |
| 2.1.1 [C1] no rematch | per pair | H |
| 2.1.2 [C2] bye eligibility | the bye recipient | H |
| 2.1.3 [C3] no two equal absolute preferences meet, no topscorer exception | per pair | H |
| 2.2.1 [C4] the rest pairable | implied by a complete legal round | H |
| 3.1.1-3.1.5 the bye: eligible, rest pairable, lowest score, most games, largest TPN | every candidate ordered before the recipient leaves an unpairable rest | M |
| 1.3.2 brackets have no downfloaters | every pair across scores is a resident with a lower-score upfloater; residents of a group all paired in its bracket | H |
| 3.2.1 / [C5] minimum upfloaters per bracket | no legal pairing of the residents and the field below with fewer resident-to-lower pairs | M |
| [C6] upfloater scores, ascending, as high as possible | the bracket's upfloater score list is the best any legal set of that size gives | M |
| [C7] fewest colour preferences denied | the bracket's denials are the fewest any set with the same [C5]/[C6] gives | M |
| [C8]-[C10] (not in the last round) maximum upfloaters, their upfloats, last-round upfloaters | as [C7], one after the other | M |
| 3.2.2 the *first* best set in 4.2's order (4.1.3 set order) | no set earlier in the order is equally good | O |
| 3.2.3 G1 = White seekers (first half by TPN if nobody has played) | recomputed from the bracket | H |
| 3.2.4 re-composition (a) forced pairs, (b) equal sizes; "best" = first in 4.3's middle-out order complying best with [C7] | the shift sets used are recoverable from the output (G1 = the white players of the pairs after colours, modulo shifts); the size of (a) is M; the choice is O | M / O |
| 3.2.5 S1 by ARO asc, then TPN | recomputed | H |
| 3.2.6 T2 the first legal transposition (4.4: lexicographic on TPN) | position by position, no G2 player with a smaller TPN could take that slot and leave the rest legal (a bipartite matching each) | M |
| 5.2.1-5.2.5 colours | recomputed per pair | H |
| D2 (legal in 3.2.6 = [C1]/[C3]/[C4], or also [C7]-optimal) | parameter; both readings checked, splits counted | N |
| D4 forfeit/PAB as an upfloat, D5 rating date, D7 virtual points | parameters | N |

### Burstein (C.04.4.2)

| article | check | kind |
|---|---|---|
| 1.6 seeding rounds = Dutch | not this checker: `bbpPairings --dutch` is an exact oracle for those rounds | - |
| 1.5 colour preferences, 1.5.4 none with no games | definition | - |
| 1.7.1/1.7.2 Buchholz, SB, unplayed rounds as games against oneself, the zero-point-bye exception | definition, with B3/B4 as parameters | N |
| 1.8 ranking: index, then TPN; never the score | definition | - |
| 1.9.1, [C1]-[C4] | as Dubov | H |
| 3.1 the bye: [C2], rest pairable, lowest score, most games, lowest 1.8 rank | as Dubov | M |
| 1.2.2 brackets = residents + incoming floaters | reconstructed top down from the output: a player paired below their scoregroup floated | H |
| [C5] most pairs in the bracket | no legal completion of the round gives this bracket more pairs | M |
| [C6] outgoing floaters' scores, descending, as low as possible | as [C5], then the score list | M |
| [C7] the next bracket complies with [C1]-[C6] (reading B5: its best pairs, then its best floater scores) | as [C6], one bracket deeper | M (under B5) |
| [C8] fewest players denied their preference | | M |
| 3.2.2 / 4.3 the first pairing in BSN order among the best | no pairing earlier in 4.3's order is equally good | O |
| 5.2.1-5.2.5 colours, "higher ranked" by 1.8 (reading B6) | recomputed per pair | H |

### Lim (C.04.4.3)

Lim is a procedure, so most of it is O or N; the checker is mainly a
legality and invariant checker here, and layer E carries the weight.

| article | check | kind |
|---|---|---|
| 1.1 bye: lowest rank in the lowest scoregroup (L9: who can take it and leave the rest pairable) | as Dubov | M |
| 2.1 compatibility: not met; no third colour in a row; no difference of 3 | per pair (after colours) | H |
| 6 last round: equal scores may break 2.1's colour clauses (L12) | per pair | H |
| 2.2 order of scoregroups (down to the median, up from the bottom, median last) | floaters move toward the median: every cross-score pair above the median has its lower player in the higher player's next lower group, and the mirror below | H |
| 2.3.1-2.3.3 transfers of players with no possible opponent | a transferred resident had no compatible player in the group (recomputed) | H |
| 2.3.4 / 3.2-3.10 which player evens a group | each rule alone: no alternative floater is strictly better on that rule with the rules before it equal, under L4's order | O / N (L4) |
| 2.4 top half against bottom half | where no exchange was needed, the pairs are exactly 1 v n/2+1 ... | H |
| 2.5, 4.1-4.4 exchanges | for groups of six or fewer, against the 4.2/4.3 tables literally; above, L5's extrapolation | H (≤6) / N |
| 2.6 blocked median group | reading L7 | N |
| 5.1.1/5.1.2 never three in a row, never three more of one colour | per player | H |
| 5.2 the second scrutiny for colours | reading L6 | N |
| 5.3 two of the same colour must alternate; 5.4 colour history decides | per pair | H |
| 5.5/5.6 the equalising colour "whenever possible" | per pair, given the pairs | H |
| 7.1/7.2 round 1: bye to the lowest rated; 1 v n/2+1; colours alternate down the top half | the whole round | H |

### Output

One line per check: article, kind, `ok` / `fail` / `reading:<name>`, and
for a failure the witness (the better pairing, the earlier set, the
player who could have taken the bye). A `fail` on H or M is a bug in one
of the two; a `fail` on O at 12 players or fewer is a bug or a reading;
`reading:` lines are counted, not judged.

---

## B. Exhaustive search, 12 players or fewer

At 12 players there are 10,395 perfect matchings (at 11, eleven byes
times 945, the same 10,395), so every legal round-pairing can be listed. For Dubov and Burstein the enumerator:

1. lists every legal round-pairing ([C1]-[C4], plus the bye rule);
2. computes, **with layer A's predicates**, each bracket's criterion
   vector in the article's priority order;
3. applies the procedure as an order on whole round-pairings: brackets
   top down, each bracket's best vector, then the article's order (3.2.2
   with 4.2-4.4 for Dubov, 4.3 for Burstein);
4. confirms the engine's round is the head of that order, and reports
   whether it was the unique best or one of several tied before the
   order decided.

This is what the existing references do, with one difference that
matters: the criteria come from layer A, written blind, not from the
reference's author. So B tests A's predicates and the engine together:
every round where B's head is not the engine's round is either an engine
bug, a reference bug, or a predicate written from a different reading,
and the witness says which.

At 13-14 players (135,135 matchings at 14) the enumeration is still
affordable for single positions and is worth running on a sample; above
that, layer C.

Lim: B is the existing reference (every floater split and every pairing
enumerated, no matching). An optimality check has no meaning for a
procedure, so B for Lim checks A's H predicates on every enumerated
candidate and confirms the engine's round is among the candidates the
procedure, read our way, can produce.

**Sizes and volume.** 4-12 players; seeds 1..200,000 at 4-10 and
1..20,000 at 11-12, as the existing runs; about 600,000 rounds per
system. The existing event generators (`test/support/*_events.ex`) supply
the histories: byes, forfeits, late entrants, withdrawals, Baku, 3-1-0,
forbidden pairs, both initial colours.

---

## C. Local optimality, above 12 players

Above enumeration size the checker cannot list every pairing, but for
the M rows it does not need to: its own matcher answers "the best value
any legal pairing reaches" exactly at any size. What is left is the O
rows - the *first* in an order among the best - and for those a
neighbourhood search gives a necessary condition:

* **pair swap**: for two boards a-b and c-d of one bracket, a-c/b-d and
  a-d/b-c;
* **float transfer**: a floater (Burstein: outgoing; Dubov: upfloater)
  exchanged with a player paired in the bracket, the rest re-paired by
  the checker's matcher;
* **bye transfer**: the bye given to the next candidate in 3.1's order;
* **order step**: for the first BSN (Burstein) or transposition slot
  (Dubov) whose partner could be "earlier", the earlier partner with the
  rest completed optimally.

Every neighbour is checked legal ([C1]-[C4] via the checker's own
matcher), then scored with A's criterion vector. A neighbour that is
strictly better, or equally good and earlier in the article's order, is
a failure with a witness. Passing is necessary, not sufficient: a pairing
can be locally best and not first. That is acceptable at this layer,
because B covers small fields exactly and E covers the reading.

**Sizes and volume.** 13-60 players, 100,000 rounds per system; 100-300
players, 5,000 rounds; and after the speed work
(`docs/perf-burstein-lim-2026-11.md`) a few hundred rounds at 600-1000,
including the single-scoregroup case (all draws).

---

## D. How the certificates fit

`docs/pairing-proofs.md`'s proofs establish that every matching the Dutch
engine solved was optimal *for its weights*, with a verifier that shares
no code with the engine. They do not say the weights encode the rule.
For Dubov, Burstein and Lim `--proof` is refused today.

Two pieces connect them to this design:

1. **Extend `--proof` to Burstein and Dubov.** Burstein's bracket is one
   weighted matching per trial (its records are the Dutch ones); Dubov's
   questions are cardinality and weighted matchings
   (`Dubov.Graph`), which the proof format already carries. Lim's floater
   split and pairs walk are matchings too, but they answer our reading of
   a procedure, so a Lim proof would prove the computation and nothing
   about the text; low priority.
2. **Weight faithfulness.** The proof's weak link is "the weight order is
   the rule's order". Test it directly: on every round of layer B,
   for every pair of legal pairings of a bracket, the engine's packed
   weight orders them as A's criterion vector does (at 12 players, every
   pair of 10,395 matchings is 54 million comparisons per bracket - sample
   200,000 pairs instead); at larger sizes, sample pairs of legal
   pairings from layer C's neighbourhoods. A digit that overflows, a
   criterion in the wrong place or a sign error shows up here even when
   no round in the corpus happens to depend on it.

With both, the chain for a Burstein or Dubov round is: text -> A's
predicates (written blind) -> weights (faithfulness, tested) -> optimal
matching (certificate, verified) -> first in order (B exactly, C locally).
Only the first arrow is a reading, and E is the check on it.

---

## E. Two independent readings

### Why

Every layer above inherits the predicate author's reading where the text
is open. A second engine, written by someone who has read only the text,
is the only test of the reading itself, and for Lim (procedural, sixteen
readings) it is most of the validation there can be. Our own Lim
conformance notes already say that two careful implementations will
differ on L4, L5 and L7; the point is to measure how often, and where.

### How, with agents

One clean-room agent per system, run in sequence or in parallel:

* **Environment.** A fresh directory on the VM
  (`/root/w-cleanroom-<system>/`) or a remote session, containing only:
  the rule text of the system, C.04.1, C.04.2, the TRF-26 specification,
  and a one-page interface contract (below). No checkout of Ainalrami, no
  `docs/`, no memory files, no network access to the private repositories.
  The brief says so, and the environment enforces it: the agent cannot
  read what is not there.
* **Brief.** Implement the system from the text in Elixir (no Python in
  this project's tooling), any algorithm, brute force allowed, but able
  to pair 40 players in under a minute. **Before writing code**, write
  `READINGS.md`: every place the text is open, the choice made, and why.
  Do not ask questions; decide and write it down.
* **Interface contract.** Input: a TRF-26 file (the 192 codes for Dubov
  and Burstein; `192 CUSTOM_SWISS` plus `XXO system lim` for Lim) and the
  round to pair. Output: bbpPairings' `-p` format (count, then `white
  black` lines, `n 0` for the bye), or exit 1 for "no legal pairing".
  Nothing about our internals.
* **Model.** A different model and prompt from the one that wrote the
  engine, to reduce shared priors. Same-family models still share a lot;
  that limitation is stated with every result.
* **No contact.** Nobody who worked on the engine answers the agent's
  questions or reviews its code until the first comparison is done.

### Comparison and triage

Run both engines on layer B's and C's histories (one round each, from the
same history, so a difference never compounds) and classify every
disagreement, in this order:

1. **Illegal** on either side (layer A, H rows): a bug, fixed on that
   side, no discussion.
2. **Suboptimal** on either side (A's M rows, B's search): a bug.
3. **Different reading**: both legal and optimal under their own
   readings. Find the article, compare our conformance note with the
   agent's `READINGS.md`. Either we adopt theirs (the text supports it
   better), or we keep ours and the reading gets a measured rate in the
   conformance note ("a second reading differs on X% of rounds, here").
   New ambiguities that are in neither the B/D/L lists nor the SPP
   questions are the most valuable output; they go into the notes.

Then the agent's engine joins the corpus as a standing second reference,
with its disagreement categories counted, as bbpPairings' old Burstein is
today: never the oracle, always measured.

A cheaper variant to run first: a **reading-only agent** that gets the
text and is asked only for the ambiguity list, no code. Diffing its list
with D1-D9, B1-B11 and L1-L16 costs an hour and tells us where to look.

---

## F. CPPDubovSystem, for Dubov

[CPPDubovSystem](https://github.com/MichaelVShapiro/CPPDubovSystem)
(Michael Shapiro) is an open-source C++ Dubov engine:

* **Licence: Apache-2.0** (GitHub's licence field and the README). We may
  build and run it for testing without restriction. We do not vendor it
  into Ainalrami (whose licence is all rights reserved); it lives in the
  VM work directory, as bbpPairings and Gacrux do. If it is ever
  redistributed, its LICENSE and any NOTICE go with it.
* **Edition.** The README links the 2026 text (`C040401202602`); the last
  release is v2.2 of 2025-12-21. The README says it is *not* approved by
  FIDE, was tested on macOS only, and that its `--explain` cannot explain
  "Minimum Weight Matching" - so parts of it use a matching rather than
  the text's enumeration, an independent implementation path.
* **Driving it.** Build with its `build.sh` or CMake (g++, no external
  libraries) on the VM. Pair a round:
  `CPPDubovSystem --pairings FILE.trf --output out.csv` (CSV `White,Black`,
  -1 for the bye). It reads **TRF16** with `XXR`/`TNR` (rounds), `ACC`
  (Baku), `XXC`, `XXP`, `XXZ`, and requires every player rated. It also
  generates tournaments (`--rtg FILE --p_count N --rtg_rounds R`) and
  checks them (`--fpc FILE --fpc_rounds R`).
* **Harness.** `test/support/cpp_dubov.ex`, shaped like `bbppairings.ex`:
  write the round's history in TRF16 (Ainalrami already writes dialects),
  run the binary, parse the CSV, compare pairs and colours. Three
  directions:
  1. our histories (`DubovEvents`, rated fields only, Baku via `ACC`,
     forbidden pairs via `XXP`; provisional ratings written as ratings,
     since it has no `XXO provisional-rating`), every round, theirs vs
     ours;
  2. their generated tournaments (`--rtg`), replayed by our `-c`;
  3. their checker (`--fpc`) on tournaments our generator played.
* **Expectation.** Disagreements will be many at first: D2's reading,
  D4's upfloat definition, D5's rating date, 5.2.1's parity numbering
  (D9), and their README's own warning that some generated rounds "could
  have pairings done incorrectly". Triage as in E; a CPPDubovSystem bug
  found on the way is reported upstream as an issue (a public action,
  so only with the user's word).

---

## Corpus and where it runs

Everything heavy runs on the 80-core VM (`172.16.63.81`), each piece in
its own `/root/w-validator-<piece>/`, at most 12 schedulers per job,
launched detached and checked back on; code shipped by `git archive` +
`scp` (git over https does not work there).

| piece | histories | sizes | rounds |
|---|---|---|---|
| A on its own | `*_events.ex`, `Generator` | 4-300 | every round of B and C |
| B | `*_events.ex` | 4-12 (sample at 13-14) | ~600,000 per system |
| C | `*_events.ex`; `Generator` normal, draw-heavy, all-draws, forbidden 0/40% | 13-60; 100-300; 600-1000 after the speed work | 100,000; 5,000; a few hundred |
| D faithfulness | B's and C's rounds | as B, C | sampled pairs per bracket |
| E | B's and C's histories, one round each | 4-60 (the clean room's speed limits it) | 200,000 per system |
| F | `DubovEvents` rated; their `--rtg` | 4-40; 60-200 | 200,000; 10,000 |

No real Dubov, Burstein or Lim tournaments are on disk. If any turn up (a
Swiss-Manager file, a federation's archive), a few dozen of them are
worth more than any generated corpus for the reading question, and go
straight through A, E and F.

## Effort and order

| step | piece | effort | why here |
|---|---|---|---|
| 1 | reading-only agent per system, diff with our ambiguity lists | 0.5 day | an hour each; points every later step at the right articles |
| 2 | A: the H rows for all three, the checker's own matcher | 3-4 days | catches illegal output at any size; every later layer needs it |
| 3 | E: launch the three clean-room agents | 0.5 day to brief, then background | the long pole; needs only the texts and the contract, so start early |
| 4 | F: CPPDubovSystem harness and first triage | 2 days + 1-3 days triage | the only outside engine; direct reading evidence for Dubov |
| 5 | A: the M rows; B: the enumerator on A's predicates | 3-4 days, then 1-2 days on the VM | exact optimality at small sizes, written blind |
| 6 | E: comparison and triage, per system | 2-3 days each | when the clean-room engines arrive |
| 7 | D: weight faithfulness; `--proof` for Burstein and Dubov | 3-4 days | connects the existing proofs to the rule |
| 8 | C: local optimality | 3-4 days | real sizes, after the speed work makes them affordable |

About five to six weeks of work in all, of which the clean-room agents'
time runs in the background. Lim gets steps 1, 2 (its H rows), 3 and 6;
the rest is Dubov and Burstein.

The deliverable of each step is a section in the system's `conformance-*.md`
with its numbers, in the style of the existing validation sections, and a
`tools/` script that reproduces it.

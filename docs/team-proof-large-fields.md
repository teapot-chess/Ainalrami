# C.04.6 whole rounds on large fields: an exact reference

Written 2026-09-23. Code: `test/support/team_proof/exact_reference.ex`
(`Ainalrami.TeamProof.ExactReference`), `test/support/team_proof/blossom.ex`
(`Ainalrami.TeamProof.Blossom`); tests: `test/ainalrami/team_proof_large_test.exs`,
`test/ainalrami/team_proof_blossom_test.exs`.

## Why

The whole-round proof in `test/ainalrami/team_pairing_validation_test.exs`
checks the engine against a deliberately naive second implementation of
Articles 3.4-3.6 and 4 (`Ainalrami.TeamProof.NaiveReference`, moved to
`test/support` unchanged). It enumerates every upfloater subset and every
bracket pairing, so it stops at about ten teams. Fields of 12-60 teams were
checked only on the absolute criteria ([C1]-[C3] and Article 4), which says
a round is legal, not that it is the round C.04.6 defines.

The exact reference computes the SAME definition as the naive one - same
readings, same output, same recorded reasons - in polynomial time, so the
engine can be compared with it round for round up to 80 teams.

## Independence

- It shares no code with `Ainalrami.TeamPairing.*`, `Ainalrami.WeightedMatching`
  or `Ainalrami.Matching`.
- Its one algorithmic tool is `Ainalrami.TeamProof.Blossom`, a minimum-cost
  perfect matching written for it: an Edmonds primal-dual blossom algorithm
  following the structure of van Rantwijk's public-domain `mwmatching.py`
  (Galil 1986, O(n^3)). The engine's weighted matcher is a port of
  bbpPairings' Galil/Micali/Gabow code, and its feasibility checks are a
  greedy pass plus memoised search - a different lineage and a different
  method.
- It reuses the naive reference's Article 4 (`ref_colours/4`,
  `ref_numbers/2`, `ref_preference/1`): per pair, already polynomial, and
  itself written from the text. So Article 4 at 11-80 teams is checked
  against the same reading as at 4-10 teams, not against a third one.
- Events are still PLAYED by the engine (each round's result applied, then
  the next round paired from it), exactly as in the whole-round test. That
  only chooses which reachable histories get checked; it decides nothing
  about the round being checked.

### Reviewed 2026-10-10: one argument is now shared

The list above was true when written and one line of it has aged. On
2026-09-25 the ENGINE took over section 3's reduction for its own 3.6
(`Ainalrami.TeamPairing.Bracket.exact/1`: the same two matchings, the same
packed identifier, on its own matcher). Still no shared code - but for 3.6
the engine and this reference now share an ARGUMENT, and an error in the
argument would be made on both sides and agree with itself. What stands
between that and a false "0 disagreements":

- at 4-10 teams the naive enumeration, which uses no argument at all;
- the proof in section 3, which does not depend on the size of the bracket;
- since 2026-10-10, `Ainalrami.TeamProof.RoundChecker`: 3.6 checked
  position by position with no identifier packed into any cost (see
  "100-200 teams" below).

Everything else is as stated. 3.5 (the upfloater set) is the part with the
most room for error and it is fully independent: the engine walks candidate
sets in order with feasibility checks, the reference solves one matching of
the whole remaining field. 3.4 and Article 4 share nothing but the reading.

## Readings (the naive reference's, unchanged)

- [C1]: two teams have met when either lists the other.
- 3.4: [C2] first, then lowest score, most matches played (played colours),
  largest TPN; the first that leaves the rest pairable (3.4.1).
- [C4] then [C5] judged over LEGAL sets: the bracket pairable and the teams
  left behind pairable ([C1], [C3]).
- [C5] maximises the upfloaters' scores taken in ascending order (open
  question 5: the article, not the 3.5.4 example).
- [C6] minimises how many more upfloaters than the parity minimum the
  following scoregroup (the highest score among the lower teams) would
  need; 0 when every team of that score floated.
- [C7] minimises upfloaters that floated last round, before 3.5.4's order
  (open question 7); off in the last two rounds, as is [C10].
- 3.6: least {C8, C10} (C8 first), then the smallest identifier. [C10]
  counts per team (each floated team facing an upfloater).
- Type A colour preferences only; primary score = match points; 4.2.2 on.

Agreement with the engine therefore proves the engine computes THESE
readings. It says nothing about whether the readings are FIDE's - that is
what `docs/conformance-c0406-teams.md` argues.

## The method, and why it is exact

### 1. Lexicographic counts are one integer

Every comparison the naive reference sorts by is lexicographic over
non-negative counts. Give each count a digit in a mixed-radix integer whose
base for that digit exceeds the largest total the count can reach in any
perfect matching, and integer order IS lexicographic order - no digit can
carry into the next. The bound used (`solve/4`): for each digit, the sum
over vertices of the largest value on an edge at that vertex; every edge of
a perfect matching is counted at least once. When every count is a sum over
a matching's edges, "least in the order" is "cheapest perfect matching".

### 2. Upfloater sets are matchings of the whole remaining field (3.5)

Let R be the residents, L the lower teams. S is legal when R+S and L-S both
pair without rematches.

*Claim.* If S is legal and no legal set is smaller, then in every pairing
of R+S every member of S faces a resident.

*Proof.* If two members of S were paired together, removing both from S
leaves S' with R+S' still pairable (drop that pair) and L-S' pairable (add
that pair to L-S's pairing). S' is legal and smaller. Contradiction.

So the legal sets of minimal size are exactly "the lower teams matched to a
resident" in the perfect matchings of R+L that use fewest resident-lower
edges. On those matchings:

| digit | per resident-lower edge (lower team l) | per lower-lower edge |
|---|---|---|
| `k` - [C4] | 1 | 0 |
| `{c5, i}` - [C5], one digit per score level, lowest level first | 1 if l is on level i | 0 |
| `u` - [C6] | 0 | 1 if exactly one end has the following score |
| `c7` - [C7] | 1 if l floated last round (0 in the last two rounds) | 0 |
| `pos` - 3.5.4 | 2^\|L\| - 2^(\|L\| - p), p = l's place in (score desc, TPN) | 0 |

- [C5]: all candidate sets have the same size, and "maximise the ascending
  score list" is then "fewest on the lowest level, then the next" - a
  lexicographic count vector.
- [C6]: for a fixed S the fewest upfloaters into the following scoregroup
  is, by the same claim one level down, the fewest edges between that
  scoregroup and the teams below it in a perfect matching of L-S; the
  matching of R+L carries both at once, so minimising `u` jointly
  minimises [C6] over S. The naive value is (|U| - parity) / 2, and the
  parity (how many of the following score stay behind) is the same for
  every set with [C5]'s optimum, so minimising |U| is minimising [C6].
- 3.5.4: within a [C5] class every set has the same number from each
  score, so the sets' TPN lists sorted by (score desc, TPN) compare
  lexicographically exactly as the sets compare by "smallest differing
  element by place" - which is the largest sum of 2^(\|L\| - place).

One matching therefore returns the chosen set. The recorded reason ([C4],
[C5], [C6], [C7] or 3.5.4 - what decided between the chosen set and the
best other legal set) takes at most three more: add a last digit `other`,
1 on a resident-lower edge to a member of the chosen set S*, and ask
whether another set with the named digits at their optimum exists (its
`other` total is then below |S*|). Another set in the {C4, C5} class with
equal {C6, C7} -> 3.5.4; else one with equal [C6] -> C7; else any other in
the class -> C6; else another legal set of the same size -> C5; else C4.

### 3. Identifier order is a sum too (3.6)

3.6.2's identifier is the top members sorted, then the bottoms in the tops'
order. Every pairing of a bracket has the same number of tops, so:

1. **Tops.** Among equal-sized sets, the one whose sorted list is
   lexicographically first contains the smallest element of the symmetric
   difference - the larger sum of 2^(m - index). One matching with digits
   `c8`, `c10`, `tops` (2^m - 2^(m - index of the smaller TPN)) returns
   least {C8, C10} and, among those, the first top set.
2. **Bottoms.** Confined to edges from that top set to the rest (smaller
   TPN on top), one more matching with digits `c8`, `c10`, `bottoms`
   (bottom's rank x h^(h - 1 - top's rank)) returns the lexicographically
   first bottom sequence. The reference asserts the second matching
   reaches the same {C8, C10} as the first.

### 4. The bye (3.4)

The naive order, with pairability decided by a perfect matching instead of
by trying every partner.

### Cost

A round is: one matching per bye candidate tried (almost always one), then
per bracket one matching for the upfloaters, at most three for its reason,
and two for 3.6. The naive reference enumerates every subset and every
pairing.

## How the reference itself was validated

1. **The matcher** against an exhaustive bitmask DP: 3,000 random graphs,
   0-16 vertices, densities 0.15-1.0, costs {0,1}, 0-3, 0-1000 and up to
   2^300 (`team_proof_blossom_test.exs`), plus 80-vertex graphs with a
   planted zero-cost matching. Every answer is also checked on the way out
   to be a perfect matching of the given edges with the claimed cost.
2. **The reference against the naive reference** on every round the
   whole-round generator plays: 2,000 seeds of 4-10 teams, 8,273 rounds,
   reasons included - no disagreement (2026-09-24,
   `TEAM_PROOF_NAIVE_SEEDS="1..2000"`).
3. **Sensitivity.** Three deliberate mutations of the reference were each
   caught by step 2: [C6] and [C7] swapped (first caught at seed 817), the
   3.6 top-set digit removed (seed 39), and [C7]'s reason query dropping
   [C6] (seed 8). The comparison is not vacuous.

## Results: the engine against the exact reference, 11-80 teams

Measured 2026-09-24 (scale mode, 11-80 teams):

| engine 3.6 budget | seeds | rounds | result |
|---|---|---|---|
| default | 1-125 | - | every round agrees; seed 126 is the first disagreement (below) |
| raised (`TEAM_PROOF_ENGINE_MAX_CANDIDATES=10000000`) | 1-300 | 1,825 | every round agrees, reasons included |
| raised | 1-479 | - | every round agrees; seed 480 is the first disagreement |

Every disagreement found is the one below. None was a different reading
or a wrong criterion: with the search exhaustive, the engine's round was
the exact reference's.

After the engine's 3.6 was made exact (2026-09-25, branch
`team-exact-3-6`, below):

| engine | seeds | rounds | result |
|---|---|---|---|
| default settings | 1-2000 | 11,980 | every round agrees, reasons included; seeds 126 and 480 included |
| naive vs exact reference (`TEAM_PROOF_NAIVE_SEEDS="1..2000"`) | 1-2000 | 8,273 | no disagreement |

## The disagreement: 3.6's candidate budget (FIXED 2026-09-25)

**Resolved.** The engine's 3.6 now takes the first legal pairing in
identifier order when it scores `{0,0,0}` (the walk's first candidate, as
before), and otherwise the method of section 3: two minimum-cost perfect
matchings with the criteria and the identifier packed into one integer
cost. The engine's matcher is its own `Ainalrami.WeightedMatching` - the
port of bbpPairings' Galil/Micali/Gabow code - so the proof's
`Ainalrami.TeamProof.Blossom` (van Rantwijk lineage) stays test-only and
independent of it. `:max_candidates` / `:max_steps` are accepted and
ignored; `exhaustive?` is always true. Timing, 80-team events (10 seeds,
50 rounds, `explain: true`): before mean 4 ms / max 99 ms, after mean 1 ms
/ max 11 ms. The history below is kept as found.

The engine's 3.6 search (choosing among a bracket's pairings by [C8],
[C10] and the identifier) stops after a candidate budget and keeps the best
pairing found. When the budget runs out before the first compliant pairing
in 3.6's order is reached, the engine's round is a legal round that C.04.6
does not choose. The test reports it as "engine 3.6 search NOT exhaustive
(candidate budget)" rather than as a wrong answer, because the engine
itself says it did not finish.

- **Default budget:** seed 126, round 3, 55 teams (8 absent), the 2-point
  bracket.
- **Budget raised to 10,000,000 candidates:** seed 480, round 3, 68 teams
  (10 absent), the 2-point bracket. Raising the budget moves the first
  occurrence but does not remove it: a large bracket in an early round
  (many teams on the same score) has more candidate pairings than any
  fixed budget.

What would remove it is a 3.6 search that is exact by construction, as the
reference's is (two minimum-cost matchings per bracket, section 3 above),
instead of an enumeration with a budget. That engine change was made on
2026-09-25 (above).

## 100-200 teams (2026-10-10)

Code: `test/support/team_proof/large_events.ex` (the events),
`test/support/team_proof/round_checker.ex` (the checker),
`test/ainalrami/team_proof_xl_test.exs`, runner `tools/team_large_run.exs`.

### Does the exact reference reach 200 teams? Yes

It is polynomial and nothing in it knows about 80. Measured on this PC,
one scheduler (`+S 1:1`), 11 events of 100-200 teams, 100 rounds:

| | per round |
|---|---|
| exact reference | 3.5 s mean (1.4 s around 115 teams, about 4-8 s at 165-200) |
| engine, `explain: true` | 22 ms |
| checker, brackets up to 64 teams | 70 ms |

About 33 s per event per core. Slow enough that a day buys some ten
thousand events rather than a billion rounds, fast enough that no fallback
to a weaker check was needed: every round of the run is compared with the
exact reference, at every size.

### The events

`Events` plays one shape (4 boards, coin-flip boards, 3-9 rounds, one team
in twelve sitting out). `LargeEvents` draws a shape per seed: 100-200 teams,
4-6 boards, 7-11 rounds; results flat or rated (strength falling with the
TPN, spread drawn per event, so the field forms the long thin scoregroups a
real event has); teams sitting a round out, withdrawing for good, entering
late in round 2 or 3, and whole matches forfeited, each at a rate drawn per
event including zero. Odd fields, and so byes, in about 60% of rounds.
Colour histories and float flags are whatever the played rounds produced.

### The checker, and why

See "Reviewed 2026-10-10" above: 3.6 is the one place engine and reference
share an argument. `RoundChecker` takes the engine's round and, per bracket:

1. least `{C8, C10}`: one matching whose cost is those two counts only;
2. no least-cost pairing has an earlier top set: for each bottom of the
   round, force it to be a top with every smaller team held to its role -
   a least-cost pairing must not exist;
3. no least-cost pairing has an earlier bottom sequence: for each top in
   order, hold the earlier pairs and offer it only smaller bottoms - a
   least-cost pairing must not exist.

That is 3.6's definition asked one position at a time; nothing is packed.
It costs a matching per team, so it takes brackets up to 64 teams - 95% of
the brackets in the measured events; the ones it skips are the first two
rounds' giant scoregroups, where almost every preference can be met and
the engine's answer is usually the plain first legal pairing. It also
checks, on every round at any size: every team placed once, a bye exactly
when the field is odd and only for a team [C2] allows, no rematch.

It shares the matcher with the reference (`Blossom`, used here with costs
below 5,000) and nothing with the engine but the struct. It does not check
3.5 or Article 4; those are the reference's.

### How these were validated (4-10 teams, `LargeEvents` shapes)

1,500 seeds, 8,606 rounds (2026-10-10, `TEAM_XL_NAIVE_SEEDS="1..1500"`):
the exact reference equals the naive one on every round, reasons included;
the checker accepts every naive round; and shown 11,080 OTHER legal
pairings (two pairs of a bracket re-partnered) it refused every one. The
old generator's cross-check was repeated the same day on main at v0.42.0:
1,000 seeds, 4,154 rounds, no disagreement.

The failure path was exercised end to end with `TEAM_XL_INJECT` (one
engine round corrupted on purpose): reproducer written, failure counted,
run carried on.

### What each size range proves

| teams | reference | what agreement proves |
|---|---|---|
| 4-10 | naive enumeration, no argument (3.55 billion rounds, 0 failures) | the engine computes the readings, by brute force |
| 4-10 | exact = naive (2,000 + 1,000 + 1,500 seeds) | the exact reference computes the same definition, where that can be enumerated |
| 11-80 | exact reference (2,000 seeds, 11,980 rounds) | bye, pairs, colours and reasons are the definition's - GIVEN section 2-3's proofs; 3.6 by a shared argument |
| 100-200 | exact reference on every round (9,000 events, 81,101 rounds, 0 disagreements), plus the checker | as 11-80 in realistic shapes; and 3.6 confirmed without the shared argument on brackets up to 64 teams |
| 100-200, brackets over 64 | exact reference only | 3.6 rests on section 3's proof and on the two sides' different matchers |

### Results of the run (2026-10-10 21:37 to 2026-10-11 12:26, this PC)

Ainalrami v0.42.0 plus the proof code, seeds 1..9000, 6 workers of one
scheduler each.

| | |
|---|---|
| events (seeds) | 9,000 |
| rounds compared with the exact reference | 81,101 |
| disagreements | **0** |
| brackets through the 3.6 checker | 621,900, all accepted |
| brackets skipped by the checker (over 64 teams) | 20,415 (3.2%) |
| cost | about 36 core-seconds per event |

Ten chunks of six seeds were interrupted when the process that launched the
run was stopped on the first evening; the runner recorded them as errors,
they were queued again on restart and are among the 9,000. No event was
abandoned on a disagreement, because there was none.

This is a sample, not a census: about eighty thousand rounds, where the
4-10 team runs have billions. The exact reference is the bottleneck at this
size, not the engine.

## Running it

    # default suite: 300 seeds against the naive reference, 12 events of 11-80
    mix test test/ainalrami/team_proof_large_test.exs

    # scale mode (the long run's large-field axis)
    TEAM_PROOF_SEEDS="1..500" mix test test/ainalrami/team_proof_large_test.exs --only whole_rounds_large
    #  -> TEAMPROOF seeds=500 rounds=M ; a failure message starts "seed N,"

    # knobs: TEAM_PROOF_SIZES="20,40" (field sizes drawn), TEAM_PROOF_TIMINGS=1
    # (rounds and reference ms per ten-team band, outside scale mode),
    # TEAM_PROOF_ENGINE_MAX_CANDIDATES=N (raise the engine's 3.6 budget, to
    # look past the known disagreement), TEAM_PROOF_NAIVE_SEEDS / _SIZES.

    # 100-200 teams: scale mode never fails on a disagreement, it writes
    # failures/seed_N_round_R.txt and prints a count
    TEAM_XL_SEEDS="1..20" mix test test/ainalrami/team_proof_xl_test.exs --only whole_rounds_xl
    elixir tools/team_large_run.exs --first 1 --last 14000 --workers 6   # the long run, resumable

On this machine every `mix` run here used `ELIXIR_ERL_OPTIONS="+S 2:2"`.

## Limits - what is NOT proven

- Everything above is SAMPLED: seeded, played events. "Agrees on N rounds"
  is the claim; not "agrees on every round of every event".
- Type A only; match points as primary score; the secondary score used by
  4.2.2; the default `matches_played` (played colours). Type B's [C9],
  game points as primary score and `use_secondary?: false` are not covered
  here (Type B is proven at bracket level in `team_pairing_test.exs`).
- The histories come from two generators (`Events`: 4 boards, one team in
  twelve sitting out, one match in fifteen forfeited, 3-9 rounds;
  `LargeEvents`: above). Neither plays requested half-point byes, a
  secondary score other than game points, or accelerated rounds.
- Events are advanced with the ENGINE's round. After a disagreement the
  rest of that event is not played (the long run abandons the event and
  starts the next seed).
- The readings are shared with the naive reference and the engine by
  design; this proves the computation, not the reading.
- The matcher is trusted by comparison (with the DP up to 16 vertices, and
  through the naive agreement), not by a formal proof of the code.

# Engineering log

The dated record of how this engine was built: what was measured, what it
cost, and what turned out to be wrong. It was this project's `TODO.md`
until the file stopped being a list of work and became an argument for how
the code got where it is.

Open work now lives in [`../TODO.md`](../TODO.md); the measurement record
in [`validation.md`](validation.md); the rules-to-code map in
[`fide-criteria.md`](fide-criteria.md) and
[`conformance-c0403-2026.md`](conformance-c0403-2026.md).

Kept because the negative results are the valuable part. Several changes
here looked obviously correct and measured *worse*; they are recorded as
failures rather than quietly dropped, so nobody re-derives them.

> **Read this as a HISTORY, not as a map of the code.**
>
> Most of this file is a dated record of what was measured and why - which
> is its value, and why entries are corrected in place rather than deleted.
> But it means older entries name functions, flags and constants that have
> since been removed, and reading one cold has already caused real damage:
> the four score-weighted float criteria were recorded here as "implemented,
> measured worse, reverted" long after they went live as C18-C21, so anyone
> tidying the ladder on the strength of that entry would have deleted
> working code.
>
> Identifiers appearing below that **no longer exist in `lib/`**:
> `cascade_brackets/4`, `bracket_options/3`, `placeable_below/1`,
> `within_bracket_weight/4`, `ordering_rungs/4`, `lex_scale/1`,
> `solve_by_cardinality/2`, `repair_bye_count/3`, `Ainalrami.Blossom`,
> `deviation`, `spread`, and the `AINALRAMI_GLOBAL` environment variable.
> `@peek_budget` is `:unbounded`, not 8.
>
> **Superseded rule, not just superseded identifiers:** every entry below
> that takes Article 5.2.5's parity on the fixed TPN describes behaviour
> this engine no longer has. The FIDE Systems of Pairings and Programs
> Commission ruled on 2026-08-27 that the numbering SKIPS players who have
> never been paired, which is what bbpPairings and Gacrux always did. The
> entries are corrected in place where they assert otherwise; the ruling
> and both retractions are the 2026-08-27 entry at the top of "Done" and
> [`dispute-initial-colour.md`](dispute-initial-colour.md).
>
> `docs/fide-criteria.md` is the maintained rules-to-code map. This file is
> the argument for how the code got there.

## Done

### 2026-11-02 - the ten-day run, stopped after seven days

Started 2026-10-26 16:20 UTC on the 80-core VM to raise the three-way
number, the weakest on record at 649,207 rounds. Stopped by hand on
2026-11-02 at about 16:18 UTC, about seven of the planned ten days, judged
enough. Only chunks that reached "Finished in" count; the 26 cut off by the
stop were discarded.

Seven axes, 14 lanes: half against bbpPairings 6.0.0 (chunks of 150,000
tournaments), half three-way with bbpPairings and Gacrux (chunks of
10,000), plus big-field lanes (400-1000 players, 7-11 rounds) added
2026-10-27. Result: 414,606,291 two-way rounds (4,609,130,461 boards) with
2 differing rounds, both bbpPairings' known second-PAB defect (a player who
already had a pairing-allocated bye got another); 35,567,333 three-way
rounds with Ainalrami never the odd one out and 100% agreement on who is
White; big fields at 100% in both harnesses. Gacrux crashed on 0.93% of
attempted rounds, all in its own code, and cost 96 comparisons. Full
tables in [validation.md](validation.md#the-ten-day-run-2026-10-26-to-2026-11-02).

Nothing in the engine changed. The run measured it. The three-way bound
is now about 55 times tighter, which was the point.

### 2026-08-27 - Article 5.2.5 went the other way, and one of our arguments was already false

The FIDE Systems of Pairings and Programs Commission answered the question
this project put to it in
[`spp-question-initial-colour.md`](spp-question-initial-colour.md): the
parity Article 5.2.5 takes is taken on a numbering that **skips players who
have never been paired**, not on the fixed TPN. bbpPairings and Gacrux were
right. This engine was wrong, and had been since colours were implemented.

**Both sides argued from the same sentence.** The SPP decided it on
C.04.2:2.4 - late entries "are given an appropriate TPN and paired only
when they actually arrive" - and so did this project, on 2026-08-17, in the
commit that closed the question the first time (`04df149`, "Settle Article
5.2.5 from the handbook"). We read the clause as granting the number at
registration and making only the PAIRING wait; the SPP reads both halves as
waiting. The grammar carries both. The SPP is the body that says which one
the regulation means, so this is settled and is not open for
re-litigation. It is not a case of nobody having read the handbook, which
is the version of this story that would have been easier to tell.

**What the engine does now.** `Ainalrami.Pairing.arrival_numbers/2` hands
out 1, 2, 3, ... by ascending starting rank over exactly the players who
have arrived, and a player who has not arrived gets no number at all rather
than a late one. "Arrived" for round R is: in R's pairing pool, or
participating in some game before R, where participation is
`Ainalrami.Trf.participated_in_pairing?/1` - this repo's existing port of
bbpPairings' `opponent != id || resultChar == 'U' || resultChar == '+'`
(`fileformats/trf.cpp:303`). Two consequences that no score-based reading
would produce, and which are the reason the empirical rule is believed to
BE the reference's rule rather than a fit to the probe positions:

* `U` (pairing-allocated bye) counts and `F` (full-point bye) does not,
  though both score 1.0. The discriminator is the result CODE.
* `-` counts only WITH an opponent: `2 w -` counts, `0000 - -` does not.

**The second retraction, which is the worse one.**
`docs/dispute-initial-colour.md` carried, as one of the two named reasons
for not fixing this, the claim that the references "do not agree with each
other either" - bbpPairings renumbering around anyone unpaired this round,
Gacrux only around players who had never played - and concluded that
"agreeing with the references is not even a well-defined target". That was
**false when it was written**. It was the pre-probe hypothesis written up
as a finding, and `tools/rip_probe.exs` had already refuted it in the same
document's own evidence section, forty lines above: where the absent player
has already played, this engine, bbpPairings and Gacrux all answer 7 and
nobody renumbers. Re-confirmed 2026-08-27 against the local Windows
binary. The false claim was load-bearing in three places - the decision not
to fix, the README, and a harness classifier it weakened - and it survived
because a hypothesis and the measurement that killed it were written into
one file at different times and never reconciled. Nothing flagged it.

**What this does to the numbers in this file.** The agreement percentages
recorded below are COMPOSITION figures - which players were paired with
which - and those are untouched: the dispute only ever moved which side of
a board a player sat on. Colour differences were counted separately, and
from 2026-08-17 (`04df149`) the comparison harnesses filed every board that
Article 5.2.5 decided under "the known dispute" rather than under
"unexplained", on the strength of the reading that has now been overturned.
Every board so filed was a board this engine got wrong. The only place this
file writes that count down is the odd-field bootstrap entry's 11,009
Article 5.2.5 boards on a single 1,500-tournament bye-and-forfeit axis; the
corpus runs never recorded theirs.

**Pending, and not to be quoted before it exists:** the corpus has NOT been
re-run on the corrected engine. There is no post-fix agreement figure of
any kind - colour or composition - and any number in this file that touches
5.2.5 is a measurement of the superseded behaviour until there is.

### 2026-08-27 - every large benchmark was taken at the wrong parity

`bye_assignee_score/2`'s first clause is `bye_assignee_score(_brackets, 0),
do: {nil, false}`, and it is called with `rem(length(field), 2)`. On an
EVEN field it returns immediately. On an odd one it runs
`bye_assignee_score_from_field/2`, which builds a COMPLETE graph over the
whole active field - every pair, a `legal_pair?/2` and a
`colour_compatible?/2` per pair, an edge emitted on both branches so the
graph stays complete - and hands it to `WeightedMatching.new/3`, which
builds an n-by-n nested weight map on top. At 1,001 players that is 500,500
edges. At 1,000 it is zero.

The recorded sizes are 209 (odd), 400 (even) and 1,000 (even). So the pass
was measured at 209 and nowhere else, and the bracket table already said so
without anyone reading it: the bootstrap row is marked "n/a (even field)"
for 400. The entry that removed the idle first bracket said the quiet part
outright - "That gate opens with `ctx.odd_field?`, and 400 is even, so the
answer was unobservable."

`tools/parity_bench.exs`, best of three, cold process, pairing round 6 of a
nine-round event:

| players | parity | best of 3 | ratio |
|---|---|---|---|
| 208 | even | 527.9 ms | |
| 209 | odd | 716.5 ms | 1.36x |
| 400 | even | 915.9 ms | |
| 401 | odd | 1,490.3 ms | 1.63x |
| 1,000 | even | 6,045.8 ms | |
| 1,001 | odd | **13,335.5 ms** | **2.21x** |

**One extra player costs 2.2x the whole round at 1,000, and the ratio grows
with n** - 1.36, 1.63, 2.21 - which is the signature of a quadratic pass
that only one parity pays.

Parity changes four things, not one, which is why an even-field profile is
misleading rather than merely incomplete. The bootstrap is the expensive
one, but `bye_candidate?/2` also switches clause, and that feeds
`completion_rung/4`, the TOP rung of the ladder - so the edge weights
themselves differ between the two parities. `c9_rank/3` becomes live, and
`ctx.odd_field?` gates the `idle_bracket?/4` skip that bought 0.39 -> 0.23
at 209.

**Half of a real tournament is an odd field.** The published speed table is
the good half.

**Attributed.** `PARITY_BENCH_TRACE=1` at 1,001 players:

    1000 (even): not called - allowed_byes = 0, whole pass skipped
    1001 (odd):  1 call, n=1001, 500,500 edges, 6,529.6 ms (46.2% of the round)

One call. Half the round. The arithmetic closes: 6,474 ms even plus
6,530 ms of bootstrap is the 13,335 ms measured odd, within the noise of a
traced run.

So the answer to "is there a time win left" is yes, and it is the largest
one on the board - larger than the transposition fast path's estimated
ceiling, and on a pass nobody had looked at because it is invisible at even
sizes. Nothing is fixed here; this entry is the measurement and the
correction to the record.

**Split, same day.** `tools/bootstrap_split.exs` traces
`WeightedMatching.new/3` and `solve/1` inside the bootstrap call, so the
7.2 s divides:

| | | |
|---|---|---|
| building the edge list | 2,413.6 ms | 33.7% |
| `WeightedMatching.new/3` | 1,608.9 ms | 22.4% |
| `WeightedMatching.solve/1` | 3,148.0 ms | 43.9% |

The solve is the largest single line, but it is not the majority: **edge
list plus graph construction is 4,022 ms against the solve's 3,148 ms.**
56% of the bootstrap is getting the problem into the matcher, not solving
it - and that half needs no algorithmic argument and carries no conformance
risk, only a representation.

One number puts the whole pass in proportion. The same round performs
**533 bracket solves totalling 5,954.8 ms.** The bootstrap alone is
7,170.5 ms. *One whole-field matching costs more than every bracket
matching of the actual pairing combined.*

**What to try next, in order.** The bootstrap answers one question - C5's
"minimise the score of the PAB assignee" - and it answers it by building
the complete field graph and solving a maximum-weight matching on it. In
priority order now that the split is known:

1. **The 4.0 s of construction, which is pure representation.** The graph
   is complete by design - `dutch.cpp:768-791` emits an edge for
   incompatible pairs too - so 500,500 edges are not negotiable, but the
   list-of-tuples into nested-map path is. `new/3` spends 1.6 s turning a
   list it was just handed into a map; a builder that takes the complete
   graph directly, or an adjacency representation that skips the
   intermediate list, changes no pairing decision at all. Cheapest work
   here with the least to argue about.
2. **Does the answer need a matching at all?** C5 asks for the minimum
   achievable bye score, not for the matching that achieves it. A
   feasibility test per candidate score - "can the field be completely
   paired with this player byed" - walked down the score groups, may settle
   it without ever solving the whole field. That is a bound, not a
   matching. It is the bigger prize and the bigger argument: getting it
   wrong gives a legal-looking wrong pairing, so it would need the
   bracket-level oracle treatment.
3. **Is it reusable across rounds?** The field changes by one round of
   results between calls. Whether any of the graph survives that has never
   been asked.


### 2026-08-27 - the corpus's one blind spot, measured

The two-way corpus halts a tournament the moment bbpPairings answers "no
legal pairing left" and never asks this engine. 45.5% of the ~6M
tournaments in the two 488M-pairing runs ended that way, so the corpus
could not see this engine being MORE permissive than the reference. That
was written up as a known limit and left there.

`tools/exhaustion_probe.exs` asks. On `{:no_valid_pairing, _}` it hands the
identical position to `pair_next_round/2` and classifies the answer:
both refuse, or a pairing which is then checked for a rematch, a second
pairing-allocated bye, a forbidden pair and a correct partition.

**815,479 refused positions across 930,000 tournaments and six axes. The
engine refused every one.** Zero disagreements, including on a 4-6 player
20-round axis built so that every single tournament exhausts, and on an
axis with every knob the harness has switched on at once.

Two things worth keeping from how it went:

* **The probe reproduced the corpus's own exhaustion rates before it
  reported anything** - 78.1% against the recorded 78.2% for
  `4-10, plain`, 88.8% against 88.2% for `4-10, 15% byes`. That is the
  cheapest possible check that a new instrument recreated the conditions it
  claims to be measuring, and it should be the first thing any future probe
  here does. Three instrument bugs have been found in this project before;
  none of them would have survived this check.

* **The result is bounded, and the bound is the interesting part.** Both
  engines refusing is not proof that no legal pairing exists - it is the
  single-oracle limit again, moved from the pairing to the refusal. For the
  4-6 player axis a brute-force search over all complete pairings is
  affordable and would settle it outright. Not run; recorded as the next
  step rather than glossed.


### 2026-08-26 - the sweep's findings, fixed

Thirteen bug-severity findings from `docs/sweep-2026-08-26.md`, plus two
instrument fixes and the suite's last four compile warnings. That document
carries the index and the three findings that turned out to be worse than
written; the commits carry the reasoning. Three are worth repeating here
because of what they say about where the remaining risk is:

* **`points_for/2` was a function of the result character.** `getPoints`
  (tournament.h:310-322) is not: it reads `match.opponent` and
  `match.participatedInPairing` too. Exactly two opponentless codes come
  out differently - `0000 - +` is the pairing's own bye rather than a win,
  `0000 - -` is a zero-point bye rather than a forfeit loss. Both are
  invisible under the standard system, and the generator only ever writes
  `-` against a real opponent, so **488 million fuzzed pairings could not
  reach either**. `parse/1` accepts both from a file. This is the shape to
  keep looking for: not a rule implemented wrongly, but a rule the corpus
  is structurally unable to produce.

* **A blank result column cost the whole file, not the round.** `render/1`
  trimmed two columns off the last round block, and bbpPairings answers
  that with `InvalidLineException` and exit 3. Every TRF this engine wrote
  for a round in progress was unreadable by the reference. Found by
  reading, confirmed by invocation - no corpus would have caught it,
  because the corpus never serializes a round in progress.

* **`even_up_exposed_duals/1` was producing infeasible duals at scale.**
  734 negative blossom duals over 800 nine-round tournaments, while
  agreeing with bbpPairings on all 800. A latent invariant break that
  costs nothing measurable is the hardest kind to find and the easiest
  kind to dismiss; the fix ports the reference's descent and keeps its
  assertion as a raise, so a regression fails the default suite.

  The reference's remedy did NOT port cleanly. `dissolve_one/3` labels the
  children it frees `:free`, which is right between stages and wrong here -
  `solve/1` has just cleared the label map and `carry_caches/2` reads an
  empty one as "rebuild from scratch". The first attempt cost a bracket
  that had been right (seed 19 round 2 of the default corpus, four boards
  different) and looked, for one run, like the fix being wrong rather than
  incomplete.

Also measured, and now in `validation.md`: the JaVaFo agreement rate is
**not one number**. Round one is 100.00%, plain five-round play 98.82%,
10% byes 91.22%, 10% forfeits 89.60%, both 83.68%. This page had carried a
bare "96.26%" attached to no axis at all. Every one of those axes is
100.00% against bbpPairings, which is the argument for the oracle choice
stated as data rather than as a preference.


- ~~Project scaffold~~ - mix.exs (escript config), `.formatter.exs`,
  `.gitignore`.
- ~~TRF16/TRF06 file I/O~~ - `Ainalrami.Trf`, ported from OpenPairings'
  `PairingsEngine.Trf` (same author, pure module, no Phoenix/Ecto
  dependency to strip). Carries over two real bugs that project found and
  fixed against FIDE's actual archived specs (Annexure-B/2006,
  Annexure-C/2016): the `allow_dangling_playing_code` TRF06 tolerance, and
  `parse_games/1` not stopping at a genuinely blank round. 27 ported tests,
  all passing here too.
- ~~Verbose logging infrastructure~~ - `Ainalrami.Log`. Verbose is the
  default (not opt-in), `-q`/`--quiet` suppresses it. `step/1`/`detail/1`
  to stdout, `warn/1`/`error/1` always to stderr regardless of quiet mode.
- ~~CLI skeleton~~ - `Ainalrami.CLI`, mirroring JaVaFo's real invocation
  shape (`input.trf -p [output.trf]`, `-g`, `-c`). `-p` calls the real
  pairing engine now (round 1 or the bracket cascade, whichever applies),
  writing the same shape JaVaFo's own output file uses (count line, then
  `white black`/CRLF per pair, `0` for a bye).

## Next: the actual Dutch-system pairing algorithm

This is the real work - everything above is plumbing. Staged so each piece
is independently correct and tested before the next depends on it, rather
than attempting the whole engine in one pass. **Every stage that touches an
actual FIDE rule needs the primary-source handbook text in hand before
writing it** - not memory, not a paraphrase. OpenPairings hit two real bugs
this exact way (Art. 16.4's dummy-score formula, the TRF06 bye convention)
specifically from trusting a plausible-sounding but unverified rule
description; don't repeat that here for something as central as the pairing
logic itself.

1. ~~**Roster split & round 1.**~~ **Done** - `Ainalrami.Pairing.pair_round_one/1`.
   Rank order, top-half-vs-bottom-half pairing, odd field's lowest rank
   gets the bye. Colour: Article 5.1's "drawing of lots" has no
   deterministic rule to replicate - confirmed empirically (not assumed)
   that JaVaFo's own initial-colour choice isn't a function of roster/round
   count alone (identical roster + round count under two different
   tournament *names* produced opposite colours from JaVaFo, strong
   evidence of a hash-seeded, non-reproducible-by-us choice) - so this uses
   its own fixed, documented, spec-legal convention instead.

   **Verified against real `javafo.jar`, not just unit-tested against our
   own expectations**: `test/ainalrami/javafo_comparison_test.exs`
   (`Ainalrami.Test.Javafo`, gated `:javafo`, jar not vendored - see that
   module's doc) generates random rosters (2-60 players) and diffs pairing
   *composition* (colour-blind) against real JaVaFo output, in parallel.
   **20,000/20,000 (100%) matched in a clean run** (`PAIRING_FUZZ_COUNT=20000`,
   run alone - no other JVM-spawning background job competing for the
   machine at the same time). A separate 100,000-roster attempt run
   *while several other fuzz batches were also active* looked like 6.29%
   - that number is meaningless, not a real finding: every one of its
   reported "disagreements" was actually a javafo.jar process failing to
   even launch (Windows exit code `-1073741502` / `0xC0000142`, a
   resource-exhaustion signature) under sustained heavy concurrent load,
   not a genuine pairing mismatch. Confirmed by checking that all 20
   disagreement examples the failure message printed were
   `{:error, code, ""}` tuples, zero real mismatches among them. Lesson
   for next time this needs re-running at even larger scale: run it
   alone, not alongside other `--only javafo` batches.
2. ~~**Bracket cascade for later rounds.**~~ **99.85% match against real
   `javafo.jar`** (5991/6000 random round-1 outcomes; 99.75% on the 2,000
   the scoring was actually tuned against, so the larger set rules out
   overfitting) -
   `Ainalrami.Pairing.pair_later_round/1`. Forms score brackets (Art. 1.2:
   score desc, TPN asc) and pairs each via `Ainalrami.Matching`'s general
   (non-bipartite) maximum-weight matching-with-floats (memoized bitmask
   DP), scored by `pair_weight/3` and `float_weight/1`.

   **Every scoring term is empirical - measured on the identical
   2,000-history set, not derived from the spec.** The trajectory, in
   order:

   | change | result |
   |---|---|
   | unrestricted exhaustive search, no colour scoring | 0%, and hung past 12 players |
   | + colour preference as a composition criterion | traced case fixed, still hung |
   | bipartite S1-vs-S2 restriction (to fix the hang) | **10.7% - reverted** |
   | general matching + memoization instead | 51.7% |
   | + penalise re-floating an already-floated MDP | 66.24% |
   | + heterogeneous bracket split (Art. 3.3.1, MDPs alone in S1) | 69.1% |
   | + fix: no-colour-preference players were scored as violating | 82.25% |
   | + don't downfloat a player holding an unplayed round | 88.4% |
   | + measure MDP displacement one-sided, not summed | **99.75%** |
   | whole-bracket natural-correspondence deviation vs. rank spread | **64.95% - reverted** |

   Two of those are worth remembering, because both looked obviously
   right and were not:

   - **The bipartite restriction.** Round 1 genuinely does pair "top half
     vs bottom half", so restricting later brackets to the same shape
     seemed safe. It isn't: bbpPairings (`swisssystems/dutch.cpp`)
     computes a weight for ANY two compatible players and uses bracket
     membership as a weighted *bonus*, never a structural exclusion.
   - **Natural-correspondence deviation.** FIDE's procedure really does
     work by minimal transposition of the natural order, and this metric
     explained every hand-traced case - but as a *replacement* for the
     rank-spread tie-break it measured 33.9%, and still only 64.95% when
     retested after every other fix had landed. Scoped to MDP pairs only,
     where Art. 3.3.1 actually applies, the same idea is worth +30
     points. Being "right in principle" decided nothing; scope did.

   The remaining 9/6000 are unexplained. Most likely candidate: the
   float-history criteria that look two rounds back (bbpPairings has four
   such levels, this engine has none), which can only begin to matter
   from round 3 - so a round-3 harness is the honest next measurement
   rather than more round-2 tuning.

   **That measurement happened - see "Depth" below. The hypothesis was
   right, and it was not the only thing wrong.**

## Depth: rounds 3-9

The comparison harnesses were unified into one parameterized file
(`PAIRING_FUZZ_ROUNDS`), because rounds never needed per-round code:
bbpPairings' own generator (`src/tournament/generator.cpp`) is a single
loop over `roundsNumber` calling the identical `computeMatching`. The
harness plays a tournament forward, advancing on JAVAFO's pairing rather
than its own, so every round is an independent measurement against a real
reference history and a disagreement in round 3 can't corrupt round 4.

It also reports **pair-level agreement alongside whole-round agreement**.
At depth the round-level number is nearly useless on its own: one bad
pair in a 20-player field scores exactly as badly as ten.

Starting point, and where it stands now (300 tournaments x 9 rounds,
10-40 players, individual pairs):

| round | start | now |
|---|---|---|
| 1 | 100% | 100% |
| 2 | 99.89% | 99.89% |
| 3 | 91.36% | 99.47% |
| 4 | 68.51% | 99.31% |
| 5 | 74.55% | 98.42% |
| 6 | 60.90% | 97.60% |
| 7 | 66.48% | 94.62% |
| 8 | 56.50% | 93.49% |
| 9 | 62.95% | 91.54% |
| **overall** | **75.68%** | **97.15%** |

Whole rounds: 38.15% → 88.93%. With 10% of games forfeited (a separate,
harder configuration): 94.05% of pairs, 76.96% of rounds.

The harness also checks **legality independently of javafo** - every
player paired exactly once, no rematch, and exactly one bye in an odd
field and none in an even one. That is a different question from
agreement, and it has a right answer. **2699/2700 rounds are legal**; the
one failure is the bounded search giving up and falling back to
best-effort. At the start of this work, 65 of 104 sampled disagreements
were illegal output.

What was actually wrong, in the order it was found. Every step was
measured, and two were reverted on measurement despite being more
elegant:

| change | pairs |
|---|---|
| starting point (HEAD of round-2 work) | 75.68% |
| + full colour model (`computePlayerData` + `insertColorBits`) | 80.64% |
| + float-history criteria (`getFloat`, four levels) | **90.33%** |
| + sum-safe criterion spans | 90.44% |
| + backtracking cascade instead of stranding | **92.92%** |
| + C2 (no second bye) enforced | 92.62% |
| + unplayed-round protection restricted to the bye bracket | 93.61% |
| + several matchings per floater count | **96.11%** |
| + widen the alternative search | 96.47% |
| + forfeit coverage, and the four played/unplayed bugs it found | 96.48% clean |
| + same absolute colour preference made incompatible | 96.97% |
| + final-round exception for top scorers | **97.15%** |

Two bye-eligibility fixes later moved that baseline to 96.36-96.41% pairs
/ 87.50-87.66% rounds on the same 300x9 configuration, which is what the
rows below are measured against:

| change | pairs | rounds |
|---|---|---|
| baseline after the bye-eligibility fixes | 96.36-96.41% | 87.50-87.66% |
| + polynomial matcher, lexicographic tie-break encoded in the weights | 95.92% | 86.40% |
| + next-bracket lookahead as a placeability signal | **96.79%** | **88.97%** |

Also improved on the other two configurations: 8% arbiter-assigned byes
went 92.85% -> 93.50% of pairs and 75.67% -> 77.73% of rounds, and
bbpPairings at 200x9 went 95.92% -> 96.26% and 86.32% -> 87.15%. Zero
illegal rounds throughout.

### A third reference, and which rulebook this engine is actually chasing

`Ainalrami.Test.Gacrux` wraps Otto Milvang's `pairingchecker.py` (the
pairing half of the FIDE Tie Break Server, gacrux.no) - a third
independent Dutch implementation, actively maintained, and the tool
FIDE/TEC itself uses to check pairing programs.

Adding it settled something the other two could not. Over 324 comparable
rounds, four engines on identical positions:

| | agreement |
|---|---|
| bbpPairings 6.0.0 vs Gacrux | **100.00%** |
| JaVaFo 2.2 vs bbpPairings | 97.53% |
| JaVaFo 2.2 vs Gacrux | 97.53% |
| Ainalrami vs JaVaFo | 89.51% |
| Ainalrami vs bbpPairings | 87.96% |
| Ainalrami vs Gacrux | 87.96% |

**There are two Dutch rulebooks in play, and this engine is chasing the
older one.** Gacrux states them outright:

    DUTCH_RULES = { 0: "2022-01-01",
                    1: "2026-02-01" }  # Approved by FIDE Council on 01/02/2026

and selects the 2026 one; bbpPairings 6.0.0 likewise implements the
revised rules - its own README says so: "the 2025 rules for the Dutch
system (the effective date for the rules was delayed to 2026)". Same
document, renamed when the date slipped. They agree with each other
PERFECTLY while JaVaFo 2.2 differs from both on the same 2.47%. That
2.47% is not engine variance, it is the 2022 -> 2026 rule change, and
every comparison in this file above was measured against JaVaFo, i.e.
against the superseded rules.

> **Correction (2026-09-10):** the "2022" in "2022 -> 2026 rule change"
> above is not a FIDE edition - it is read straight off `DUTCH_RULES[0]`
> in the Gacrux quotation two lines up, Gacrux's own bookkeeping tag for
> the ruleset it replaces, not an edition year FIDE ever published. FIDE's
> name for that ruleset is the 2017 edition - approved at the 87th
> Congress, Baku 2016, with Terms and Definitions and Pairing Guidelines
> For Programmers added at the 88th, Goynuk 2017 - in force until 31
> January 2026. The label spread through this file and others from this
> one line; see `docs/fide-criteria.md` for the corrected naming.

### 324 rounds was not enough to call the references a ruler

The "100% agreement" above was originally measured over **324 rounds**,
and that number was doing more work than it could bear. Zero observed
failures in `n` trials bounds the true rate at roughly `3/n` with 95%
confidence - so 324 clean rounds established only that the references
disagree on **less than about 0.9%** of rounds. Fine when this engine sat
at 90% and the error being measured was ten times the ruler's slack.
Useless at 98.6%, where the error is 1.4% and the slack is comparable.

`three_way_comparison_test.exs` now runs all three engines on identical
positions at whatever scale is asked. At **3352 rounds**:

| | agreement |
|---|---|
| bbpPairings vs Gacrux | **100.00%** (3352/3352) |
| Ainalrami vs bbpPairings | 98.6% |
| Ainalrami vs Gacrux | 98.6% |

The bound on reference disagreement tightens from 0.9% to **0.09%** -
about fifteen times smaller than this engine's own error, which makes
them a usable ruler again.

**And it settles what the remaining failures are.** Of the 47 rounds
where Ainalrami differed, **all 47 had the two references agreeing with
each other**; not one was a case of the references splitting. There is no
"legal-but-different, nobody is right" bucket to appeal to - every
remaining disagreement is this engine being wrong, and majority-vote
adjudication is unambiguous on all of them.

Costs ~35x the two-way harness (Gacrux is Python, ~750ms a round against
bbpPairings' ~21ms); 400x9 takes about 4.5 minutes parallelised.

The number to steer by from here is the last one: **when all three
references agree, Ainalrami matches 89.87%** (284/316). Where they are
unanimous there is no tie to break and no rulebook ambiguity, so that
~10% is genuinely this engine's own gap, and it is the honest measure of
what is left to fix. Everything outside it is a choice about which
rulebook to target, not a bug.

### Two things not to redo

**Do not build a k-best matcher for the cascade's alternatives.** Before
the lookahead, substituting `Ainalrami.Matching`'s exhaustive candidate
list for `bracket_candidates/3`'s was worth ~2.9 points of exact rounds,
and the plan was to close that with Chegireddy-Hamacher / Murty
partitioning. It is now worth 0.59 points at 200x9 - 10 rounds in 1684,
about 0.8 sigma - because the placeability signal stops the cascade
stranding a bracket, so it backtracks far less and which alternatives it
holds matters far less. Every knob on that axis is flat: the forced-float
beam at 8, 64 and unbounded all score identically, and so do depths 2, 4
and 6. An unbounded beam at depth 2 already enumerates every floater
pair, so the exact same-count coverage Murty would buy is present and
changes nothing.

**Do not read the next-bracket lookahead as a licence to pair across
brackets.** bbpPairings never finalizes a cross-bracket pair - after its
combined current+next matching it rebuilds the score group's "remainder"
and re-pairs those players within the bracket, and `finalizePair` is only
ever reached for a match inside the group. Emitting cross edges as real
pairings measured 86.40% -> 43.82% of rounds, and porting the rest of
`computeEdgeWeight`'s ladder on top moved it to 42.28%, because the
weights were never the problem. Cross edges also quietly void
`solve_by_cardinality/2`'s guarantee, which is per PAIR COUNT: a cross
edge counts as a pair while meaning a float. The lookahead belongs in
`float_weight/4` as one bit per player - can this player be placed below
if they float - and nowhere else.

**Both of the above still stand, and both are about the DEFAULT
(per-bracket) path. A third entry that used to live here - "the global
cascade cannot be landed incrementally, do it in one piece or not at
all" - has now been acted on and is resolved; see below.**

### Exact agreement with bbpPairings on plain tournaments

| field | now | before today |
|---|---|---|
| 4-40, 500x9 | **100.00% / 100.00%** (4197/4197 rounds, 49802/49802 pairs) | 90.29% / 97.21% |
| 60-80, 20x9 | **100.00% / 100.00%** | 82.22% / 97.99% |
| 90-120, 8x9 | **100.00% / 100.00%** | 86.11% / 99.03% |
| 4-40 + 8% byes | 99.76% / 99.94% | 81.95% / 95.08% |
| 4-40 + 15% byes | 99.64% / 99.92% | - |
| 4-40 + 10% forfeits | 99.52% / 99.91% | 88.70% / 96.90% |

Verified on a second, independent code path: the three-way harness has
Ainalrami matching **both** references on 1261/1261 rounds. And javafo
stays at 96.26%, which is the control - it implements the 2017 edition,
so an engine that agreed with all three at once would mean the harness was
measuring nothing.

**The last fix was C8 counting the wrong pairs.** `lowerPlayerInNextBracket`
in `dutch.cpp` can only ever mean the one score group bbpPairings appends,
including for pairs formed wholly inside it - those genuinely are "pairs
in the next bracket". The peek budget broke that equivalence: with several
groups visible, pairs formed three groups down were still scoring on C8,
and there are far more of those than there are real downfloat placements,
so they swamped the rung until it stopped discriminating at all. Grading
by distance had softened this without fixing it.

Traced on `seed127-r5-p13`: a 3.0 bracket of three residents, where this
engine floated the player who then had to fall two groups while
bbpPairings floated the one who landed in the very next.

The deeper groups stay VISIBLE - that is what the peek is for, and
removing it costs 5.7 points - but only the immediate next group counts
toward C8. Anything further gets re-decided in a later bracket anyway,
and C8 has nothing to say about it. Worth **98.40% -> 100.00%**.

**What is left.** Arbiter byes and forfeits, both inside half a percent,
and both now the entire remaining error. The adjudicator is the tool for
them; note that its verdicts have to be read with `explain_round/3`'s
own C8 accounting in mind, which counts crosses into the immediate next
group only - the same distinction the fix above turned on.

### ~~`bye_assignee_score/2` crashes when exactly one player is left needing a bye~~ **fixed**

Found by a 100,000-tournament overnight run (`overnight_run/run.sh`,
`PAIRING_FUZZ_BYE_PCT=15`) - the first sample large enough to hit it: 102
illegal rounds out of 839,776 (0.012%), where every previous sample (up
to ~5,500 rounds) had shown zero. 95 of those were this crash; the other
7 are a wrong bye count (5) and a non-partition (2), not yet separately
root-caused.

Root cause: `bye_assignee_score/2` built its bootstrap-matching edges
over `0..(n - 2)` where `n` is how many players are left needing the
round's bye. When exactly one is left (`n == 1`, a real, reachable case -
everyone else already resolved, one genuine bye candidate remains), that
range was `0..-1`. Elixir's default step for a descending range walks
`0, -1`, and `elem(arr, -1)` is an invalid tuple index - raised
`ArgumentError`, not the intended `NoValidPairingError`/legal-pairing
outcome. **Fixed** with an `n <= 1` short-circuit (split into
`bye_assignee_score/2` and `bye_assignee_score_from_field/2`): `n == 1`
returns that lone player's own score directly, `n == 0` returns `nil`
the same way the pre-existing `allowed_byes == 0` clause does. Verified
against the saved repro (`crash_reports/seed4886-r5-p5.trf` - copied
into `test/fixtures/bye_assignee_score/one-candidate-left.trf` as a real
regression test, `test/ainalrami/bye_assignee_score_test.exs`, confirmed
to fail on pre-fix code and pass on the fix) and then at the same scale
the bug was found at: **re-ran the identical 100,000×9 bye-rate
overnight batch**. 0 raised exceptions (was 95), illegal rounds
102 → 7, exact-round matches 839565 → 839660 - up by exactly 95, so
every one of those 95 crashes now produces bbpPairings' own correct
pairing, not merely a legal one. Forfeit-axis batch, re-run identically,
is unchanged (99.93%/99.98%/0 illegal both times) - confirms the fix
didn't touch anything it shouldn't have.

### ~~The remaining 5 `Ainalrami: []` cases~~ **fixed** - all one missing rule

**This section previously split these five into "4 degenerate fuzz
artifacts" plus "1 confirmed-genuine bug", and got both halves wrong.**
They are a single missing rule, and the four dismissed ones were the
clearest examples of it. Recorded here as written, because the wrong
grouping is the more useful lesson: the four were waved off precisely
BECAUSE their whole field was pre-byed ("a genuinely degenerate input
... rather than a real tournament state"), which is exactly the input
the rule exists to handle. `seed4385` was then filed as the odd one out
on the strength of a claim - "nobody pre-byed" - that is simply false:
all four of its players carry a round-5 bye (`Z`/`Z`/`Z`/`H`), the same
shape as the other four. Checking that one assertion against the actual
file would have collapsed the two groups into one immediately.

**Root cause.** `rounds_played/1` implemented only half of bbpPairings'
round-number rule. The half it had is real: `playedRounds` only advances
for games the player PARTICIPATED IN THE PAIRING for
(`trf.cpp:339-342`), so one player's pre-recorded half-point bye doesn't
drag the round forward and strand everybody else.

The missing half is `evenUpMatchHistories` (`trf.cpp:646-684`), which
runs after parsing and can advance `playedRounds` once more:

```cpp
forwardRoundIsComplete = includesUnpairedRound;              // true here
for (valid player)
  if (includesUnpairedRound ^ (matches.size() > playedRounds))
    forwardRoundIsComplete = !includesUnpairedRound;
if (playersByRank.size() && forwardRoundIsComplete) ++playedRounds;
```

Pairing mode passes `includesUnpairedRound = true` (`main.cpp:452`,
under `if (doPairings)` - "compute the pairings of the next round"; the
checker's own read at `main.cpp:347` passes `false`), so that XOR
reduces to: increment exactly when EVERY player already holds a game for
the trailing column. A column filled in for the whole field is a round
already fully decided, so it counts as PLAYED and the round to pair is
the one after it. That is why bbpPairings pairs `seed4385` at all - it
is pairing round 6, not round 5.

`every`, not `any`, is what makes it safe: one player holding a
pre-recorded bye leaves everyone else's history shorter, the flag
clears, nothing advances, and the ordinary arbiter-bye case still pairs
the round the others are waiting for - matching what javafo was measured
to do.

**Verified, not assumed:**
- Real `bbpPairings.exe` on the saved `seed4385-r5-p4.trf`: exit 0,
  `4 1` / `2 3`. Ainalrami now returns `[{2,3},{4,1}]` - the same pairing,
  where it used to return `[]`. `seed4886-r5-p5.trf` likewise matches
  (`{3, nil}`).
- **Behaviour-neutral everywhere else**, which is the real risk of
  touching the round number: a 4,000-tournament / 33,601-round
  `PAIRING_FUZZ_BYE_PCT=15` batch run twice, once on each side of the
  change, gives byte-identical results - 33597/33601 exact rounds,
  340929/340942 pairs, 0 refused, 0 illegal, and the SAME four
  mismatching cases by seed and round (223/2582/2628/2738), not merely
  the same count. `seed223-r9-p23` is the already-documented
  bye-assignee gap below, untouched by this.
- Regression cover: `test/ainalrami/rounds_played_test.exs` +
  `test/fixtures/rounds_played/trailing-round-complete.trf`. Fails on
  pre-fix code, passes on the fix. A second test pins the `every`-not-
  `any` half - one player's pre-recorded bye must NOT advance the round -
  since that is the direction this change could plausibly have broken.

An earlier draft of that second test was itself instructive: it reused
the main fixture's players, where rank 1 already held a `U` bye and so
was barred by C2 from taking another, leaving `{2,3}` as the only legal
pair and the position genuinely unpairable. The engine correctly raised
`NoValidPairingError` and the TEST was wrong - worth remembering before
reading any future "engine refuses a pairable position" report as a bug.

Still open from that run: the 2 wrong-bye-count / non-partition cases,
untouched by this fix.

**Confirms as arbiter-bye-specific, not a general odd-field issue**: the
matching `PAIRING_FUZZ_FORFEIT_PCT=10` overnight run (same 100,000
tournaments, 9 rounds) found **0 illegal rounds**. Forfeits don't shrink
a round's active field - a forfeited game still counts as played, the
active count stays at its nominal size. Pre-assigned `H`/`Z` byes do
shrink it (`assign_requested_byes/2` marks the player's round played
before the `active = filter(&(length(&1.games) < round))` check even
runs), which is what makes "exactly one genuine PAB candidate left"
actually reachable at the field sizes this generator produces. Worth
keeping this distinction when reproducing: `PAIRING_FUZZ_BYE_PCT`, not
`PAIRING_FUZZ_FORFEIT_PCT`, is what surfaces it.

### ~~C9's real gate needs a persistent whole-round matcher~~ **done - every measured axis is now 100.00%**

The section below is the diagnosis; this is what acting on it produced.
Against bbpPairings 6.0.0, exact rounds / individual pairs, 4-40 players,
9 rounds, 4,000 tournaments per axis:

| axis | before | after |
|---|---|---|
| plain | 98.69% / 99.59% (500x9) | **33708/33708 = 100.00% / 400021 pairs = 100.00%** |
| 15% byes | 33597/33601 = 99.99% / 340929 of 340942 | **33601/33601 = 100.00% / 340942 = 100.00%** |
| 10% forfeits | 33519/33544 = 99.93% / 399125 of 399201 | **33544/33544 = 100.00% / 399201 = 100.00%** |
| 60-80, 20x9 | 100.00% / 100.00% | 180/180 = 100.00% / 100.00% |
| 90-120, 8x9 | 98.61% / 99.87% | **72/72 = 100.00% / 3834 = 100.00%** |

Zero illegal rounds and zero refusals everywhere, `mix test` 85 passed
(unchanged), and the three-way harness 1007/1007 against BOTH references.
All 29 catalogued disagreements are gone, including the four bye-axis
seeds ({223, 2582, 2628, 2738}) and all 25 forfeit-axis ones - so the two
`tie_on_all_rungs` cases and the uncharacterised bye-axis tie were the
same cause after all, exactly as the "plausibly all 29" caveat allowed.

**The rewrite turned out to be much smaller than "persist dual variables
across bracket transitions".** `finalizePair` (common.h:164) locks a pair
by leaving its two vertices one usable edge each and zeroing every other
edge incident on them, then re-runs `computeMatching()` on the same
instance. A vertex in that state is ISOLATED - any matching either takes
its one edge or leaves both ends unmatched, and taking it is strictly
better and blocks nothing - so a finalised pair contributes nothing to
the rest of the optimisation. Dropping those vertices from the graph
gives the identical matching on the identical remaining vertices, which
is exactly what carrying only the unpaired players forward already did.
bbpPairings' incrementality is a performance optimisation, not a semantic
requirement, and `WeightedMatching.solve/2` was left completely untouched.

What actually had to change was three things:

1. **The graph's SCOPE.** `@peek_budget` is now `:unbounded`: every
   unfinalised player is a vertex in every bracket's solve. Weights stay
   bracket-flavoured - `reach_table/3` already grades visible players by
   distance, so a pair two or more groups down scores only the completion
   rung and C9, which is precisely the weight bbpPairings leaves on its
   own out-of-window edges (`computeEdgeWeight` with both
   `lowerPlayerInCurrentBracket` and `lowerPlayerInNextBracket` false).
2. **`bands` sized to the graph rather than the bracket.** Not optional
   once a single solve mixes bracket-scored and completability-scored
   edges: two differently-scaled radices cannot be compared. This is also
   what bbpPairings does (`scoreGroupSizeBits`/`scoreGroupShifts` are
   computed once over `sortedPlayers`, dutch.cpp:684-730). The bignum
   inflation this section previously warned about is real but affordable
   - see the timings below.
3. **The C9 gate read from that matching instead of guessed at.** Both
   halves of it:
   * The FIRST bracket's flag (dutch.cpp:851-870) is read off the same
     bootstrap whole-field matching that produces `byeAssigneeScore` -
     the bye must fall in the top score group AND no top-group player may
     already be tentatively matched below it. `first_single_bye?/4`.
     Usually FALSE, where the "odd field, even number of players below"
     stand-in it replaces fired constantly.
   * The per-bracket clearing step (dutch.cpp:1608-1643) lost its
     `rem(players_below, 2) == 0` term, which was a proxy for exactly this
     clearing step invented when the step could not be evaluated properly,
     and gained the right scan bound: `i < wsgb`, not `i < nsgb`.

**`wsgb` is the other half of the scope change, and skipping it would
have broken things quietly.** With the graph now the whole field, `st.m`
stopped being an approximation of bbpPairings' `playersByIndex.size()`
(bracket + next score group). Three places meant that specific bound and
had been reading `m` or `nsgb`: `prefer_high_opponents/2`'s addend seed
(dutch.cpp:1218), `cut_exchanged/3`'s second cut set
(dutch.cpp:1473-1484), and `collect_bracket/1`'s `partner_scores` scan
(dutch.cpp:1613). That last one is why the earlier "extend
`partner_scores` to the full peek window" experiment regressed: the
correct bound is the next score group, not however far the peek happened
to reach, and a too-wide scan lets players nowhere near the decision
clear its gate.

**Risk 1, tie-breaking: did not materialise, and needed no fix.** The
worry was that a from-scratch solve might pick a different maximum-weight
matching than an incremental update would (bbpPairings calls its result
`stableMatching`). No deterministic tie-break had to be added: 100.00%
agreement across ~101,000 compared rounds and ~1.14M pairs on three axes
is not a result compatible with tie-break noise. The eight refinement
stages appear to settle every tie before the matcher's own arbitrary
choice can matter, which is the same conclusion `transposition_terms/3`
already reached from the other direction.

**Risk 2, performance: ~2x on large fields, free on the corpus that
matters.** Measured on the same machine, same configs, stash-and-compare:

|  | before | after |
|---|---|---|
| 4-40, 200x9, 15% byes | 23.9s | 24.0s |
| 60-80, 20x9 | 19.4s | 36.9s |
| 90-120, 8x9 | 42.6s | 90.3s |

(Wall clock including the bbpPairings subprocess, so the engine-only
factor is somewhat worse than 2x.) The 4-40 case is free because a
bracket there could already see most of the field under the 8-player peek
budget. `AINALRAMI_PEEK=<n>` still narrows the graph if a much larger
field ever needs it - at the cost of the gate becoming wrong again.

### C9's real gate needs a persistent whole-round matcher, not a bracket cascade

**Two small, real bugs fixed and kept** (both safe, both measured, no
regression, no rate change on the corpora tested - the disagreement they
each touch just never showed up in these particular samples):

- `explain_round/3`/`explain_bracket/6` (the `tools/adjudicate.exs`
  diagnostic) used to call `edge_rungs/6` with `single_bye?` hardcoded
  `false`, so C9 ("minimise the bye assignee's unplayed games") never
  scored anything in this diagnostic, regardless of whether the real
  search had it active. Fixed with an approximation of `bracket_loop/6`'s
  own gate (odd field, `bye_score` known, `players_below` even) - not a
  full port (the real gate also needs `carried_partner_scores`, which a
  post-hoc reconstruction from a finished `pairs` list doesn't have), but
  strictly better than a hardcoded `false`.
- `bye_assignee_score/2`'s bootstrap matching used to simply OMIT an edge
  between two incompatible (rematch/absolute-colour-clash) players.
  Checked directly against `dutch.cpp:768-791`: bbpPairings' own
  bootstrap `matchingComputer` is a COMPLETE graph - an incompatible pair
  still gets an edge, weight 0, so it's only ever a worse choice than a
  compatible one, never an impossible one. Ported as weight `1` (not
  literal `0` - `WeightedMatching.solve/2`'s `build_state/2` silently
  drops any edge with weight `0`, so a literal port would vanish exactly
  like the omitted-edge version it replaces). Matters for fields where
  the legal-only subgraph can't reach a near-perfect matching on its own
  (heavy forfeits, several absolute-colour clashes) - not exercised by
  the corpora measured today, so a real gap closed with 0 measured
  regression, not a proven-worse trade either.

**The real remaining gap, now precisely diagnosed instead of guessed at.**
A live disagreement (`seed223-r9-p23`, 15% bye rate: bbpPairings/Gacrux
both give the pairing-allocated bye to rank 6, this engine gives it to
rank 10 - two players tied on both score and eligibility) turned out to
be **confirmed non-arbitrary**: ran the identical position through
Gacrux (`OttoMilvang/TieBreakServer`'s `pairingchecker.py -m dutch`, a
completely independent implementation) and it agrees with bbpPairings
exactly, board for board. Two independent engines converging rules out
"arbitrary tie-break noise" - there is a real, shared rule here.

Built bbpPairings from source (MinGW-w64/g++ 16.2.0, no code changes
needed beyond adding `DBG_C9`-gated `fprintf` instrumentation around
`isSingleDownfloaterTheByeAssignee` in `dutch.cpp`) and ran it on
`seed223-r9-p23` directly, rather than continuing to infer its behaviour
from reading the source. That produced the actual internal trace, not a
reconstruction:

- The disqualifying event that should suppress C9 for the 3.0-point
  bracket's decision fires **one bracket earlier**, while bbpPairings is
  still processing the 3.5-point bracket - triggered by rank 6, who at
  that point is only a **preview** member of the 3.5 bracket's own
  combined solve (its true residents are just {4, 18}, which pair with
  each other cleanly), not a resident of anything yet.
- Rank 6's tentative match at that moment, per bbpPairings' own trace,
  is rank 20 - a player who isn't even loaded into the window this
  engine's `peek` mechanism would have built at that point.
- This engine's own `single_bye?`/`next_single_bye?` (`bracket_loop/6`)
  only ever inspects `collect_bracket/1`'s `partner_scores`, itself
  scoped to `i < st.nsgb` - true residents of the CURRENT bracket. It
  never sees a disqualifying signal from a preview/peek member at all,
  so it computes `true` where the real engine's own
  `isSingleDownfloaterTheByeAssignee` was `false`.

**Extending `partner_scores` to cover the full peek window (not just
`i < st.nsgb`) fixes `seed223-r9-p23` exactly** - byte-for-byte the same
three pairs and the same bye as both bbpPairings and Gacrux, confirmed.
It also regresses the wider corpus (99.96%/99.96% → 99.92%/99.68% across
the bye and forfeit samples), breaking two previously-correct cases
(`seed207-r9-p14`, `seed242-r6-p10` from that run) that were re-verified
independently correct against Gacrux too. **Ruled out that this was
simply "peek isn't wide enough"**: re-ran with `AINALRAMI_PEEK=999`
(effectively the whole remaining field loaded into every bracket's
`combined`) - `seed223` stays fixed, `seed207`/`seed242` stay broken,
unchanged from the narrow-peek result. So it isn't reach at all.

**The actual cause: bbpPairings' `matchingComputer` is ONE persistent,
incrementally-updated matcher for the entire remaining field, built once
(`dutch.cpp:738`) and never discarded - `computeMatching()` is called
repeatedly against the SAME instance as brackets are locked in
(`finalizePair`), so a query late in the round reflects every decision
already baked in earlier, not just what's currently "visible."
`Ainalrami.Pairing`'s `pair_bracket/5` is the opposite: a fresh,
stateless `WeightedMatching.solve/2` call every time, scoped to whatever
`combined` currently holds. A wider `combined` (more peek) makes the
STATELESS solve see more players, but it's still re-derived from
scratch against this bracket's own local weight function every time -
it can never reproduce a tentative match that only exists because of
specific decisions locked in several brackets earlier. Confirmed this
distinction is the actual cause, not a remaining edge case of "how wide"
- see the `AINALRAMI_PEEK=999` result above.

**What a real fix needs**: not a wider peek, not a stricter or looser
`single_bye?` formula (three variants tried today - blanket disable,
`rest == []`, wide-peek `partner_scores` - each one either regressed the
broader corpus or failed to generalise past the one case it was tuned
against). It needs `Ainalrami.Matching`'s solve to become genuinely
incremental - persisting dual variables/blossom structure across bracket
transitions the way `matching_computer` does, rather than a fresh
`solve/2` per bracket - or equivalently, replacing the bracket-cascade
architecture with one whole-field weighted matching whose edge weights
already encode every bracket's priority via place value (closer to what
`dutch.cpp`'s bit-packed `computeEdgeWeight` actually achieves; the
per-bracket loop in the C++ reads more like incremental refinement/
extraction from one continuously-evolving solve than genuinely
independent per-bracket solves). Either is a rewrite of the core solving
loop, not a tunable - properly scoped, its own dedicated effort with the
same measure-before-trusting discipline as the stage-by-stage cascade
port above, not something to improvise inside an unrelated session.

**How much that rewrite is actually worth, measured rather than
assumed.** The `seed223` diagnosis above is one case; the open question
it left was whether the rest of the residual gap shares its cause or is
a scatter of unrelated defects. Adjudicated the whole remaining set to
find out - a 4,000-tournament / 33,601-round `PAIRING_FUZZ_BYE_PCT=15`
batch leaves exactly **4** disagreeing rounds (223, 2582, 2628, 2738),
dumped with `PAIRING_FUZZ_DUMP` and scored through
`tools/adjudicate.exs`:

| classification | n | cases |
|---|---|---|
| ours scores better (**our ladder is wrong**) | 3 | 223, 2628, 2738 |
| tie on every rung | 1 | 2582 |

All three of the first group are bye-related, and the two the
adjudicator labels `C9 bye unplayed games` are unusually clean: **every
single rung is identical between the two engines except C9** -
seed2628 ours 7 / theirs 6, seed2738 ours 7 / theirs 5. bbpPairings is
choosing the answer OUR OWN ladder scores worse, on one rung, with
nothing else separating them. That is the signature of C9 being APPLIED
where bbpPairings suppresses it, which is precisely the
`isSingleDownfloaterTheByeAssignee` gate the instrumented-C++ trace
above pinned on `seed223`. (`seed223` itself surfaces one rung higher,
as `C2/C4/C5 bye-eligibility` - consistent rather than contradictory: a
mis-fired C9 gate changes who ends up taking the bye, so it shows up as
an eligibility difference downstream. Same root, different surface.)

So the residual gap on the bye axis is **one root cause plus one
genuine tie**, not a scatter - which is the useful thing to know before
committing to the rewrite, because it also bounds the payoff: the
architectural fix plausibly closes 3 of the 4, and `seed2582` is not
reachable by any ladder change at all (it ties on every rung *and* on
`lex`, so FIDE section 3's transposition order is what decides it -
a separate, smaller piece of work with its own primary source to read).

**All 25 confirmed three-way: Gacrux backs bbpPairings on every one.**
The three-way harness had only ever been run on PLAIN tournaments
(1007/1007, all three agreeing), so the forfeit-axis disagreements below
had never actually been shown to Gacrux - they were two-way results,
and at 99.93% the residual error is inside the ~0.3% bound on the
references' own agreement rate, which is precisely where a two-way
comparison stops being able to tell "we are wrong" from "the reference
is wrong". Ran Gacrux over all 25 dumped cases: **25 agree with
bbpPairings, 0 agree with Ainalrami, 0 land on a third answer.**

Two consequences, one of them not obvious:

1. Every one of the 25 is genuinely ours. No ruler-slack escape hatch.
2. **The 2 `tie_on_all_rungs` cases are not ties.** Our own ladder
   cannot separate those answers - but two independent engines picking
   the SAME one means a real deterministic rule decides it and this
   engine doesn't implement it. "The criteria genuinely tie" was a
   statement about our ladder's resolution, not about the rules. That
   reclassifies them from "unreachable, needs FIDE section 3
   transposition order as a tie-break" to "a missing rule, findable the
   same way every other missing rule here was found".

**The forfeit axis, characterised for the first time - and it is NOT
the same story.** The bye axis above was the one with a diagnosis, so
the forfeit axis's own 99.93% had never been broken down. Same method,
4,000 tournaments / 33,544 rounds at `PAIRING_FUZZ_FORFEIT_PCT=10`,
0 illegal, 25 disagreements:

| classification | n | first differing rung |
|---|---|---|
| ours scores better | 20 | C9 bye unplayed games |
| **theirs scores better** | **3** | **C2/C4/C5 bye-eligibility** |
| tie on every rung | 2 | lex picks THEIRS |

The 20 are the same C9-gate signature as the bye axis, which is the
useful confirmation: across BOTH axes, 22 of 29 disagreements are that
one gate, plus `seed223` whose C++ trace already pinned it as C9-rooted
too. **23 of 29 (79%) are the single architectural cause.**

**The 3 `theirs_scores_better` cases are new, and are a different bug
class.** Everything else found so far has been "our ladder is wrong"
(we score better; the reference declines to violate a criterion it
implements). These are the opposite - bbpPairings reaches a pairing OUR
OWN ladder prefers and we do not, i.e. a genuine search failure, which
no amount of ladder tuning fixes. Example `seed1253-r7-p13`, score-3.0
bracket: ours `{11,12},{6,9},{1,4}` floating `[5,8,13]`, theirs
`{11,12},{6,13},{1,9}` floating `[4,5,8]` - identical on every rung
except C2/C4/C5 (ours 11, theirs 12) and C9 (22 vs 23).

Deliberately checked before believing it, because `explain_round/3`'s
`single_bye?` is documented right there as an approximation that can
false-positive: `single_bye?` gates the **C9 rung only** - C2/C4/C5 is
computed independently of it. All three of these cases are classified on
C2/C4/C5, the rung ABOVE C9 and outside that caveat, so they are not
scorer artifacts.

Worth noting they appear **only on the forfeit axis, never on the bye
axis**. Chased that on `seed1253-r7-p13`; **two obvious explanations are
now ruled out, and the third is more interesting than either.**

- **Not the forfeit-rematch rule.** The hypothesis was that
  `dutch.cpp:664` (a forfeited pairing does not forbid a rematch) gives
  bbpPairings a wider legal edge set on forfeit-heavy fields. It does
  not: `legal_pair?/2` already gates on `played?/1`, so a forfeit
  doesn't block a rematch here either. The disputed pair `{1,9}` is one
  of these - ranks 1 and 9 have met TWICE before, both forfeits, and
  bbpPairings pairs them a third time. We allow that too.
- **Not colour-history contamination from forfeits.** The next
  hypothesis was that unplayed games were leaking into colour stats and
  manufacturing a false absolute clash. They aren't: `colour_stats/1`
  filters to `played?/1` first. Checked the actual position - rank 1 is
  W2/B1 (prefers black), rank 9 is W1/B2 (prefers white). Exactly
  complementary; no clash of any kind.

So `{1,9}` was **legal, colour-compatible, and reachable** - and
`WeightedMatching.solve/2` is an exact maximum-weight matching, i.e.
globally optimal for its own weight function. A weak or unlucky search
cannot explain this. The only thing left is that the search's
bracket-local weights and the round-level ladder genuinely disagree.

**Which makes "search failure" the wrong label, and probably makes
these the SAME architectural cause as the C9 group.** The rung these
three classify on is C2/C4/C5 - *bye-eligibility* - which is a
round-level property that isn't resolved until well after the bracket
being solved. A bracket-local solve cannot price it, exactly as it
cannot price C9's gate; bbpPairings' one persistent matcher can,
because the relevant decisions are already baked into it. Same
limitation, different rung.

**CONFIRMED by instrumented trace - it is the same cause.** Rebuilt
bbpPairings with `DBG_C9` instrumentation (recipe in the toolchain note
below; the MinGW toolchain survived the PC reinstall, and the build was
clean first try) and traced `seed1253-r7-p13`. The score-3.0 bracket,
the one in dispute:

```
DBG float id=9  tentative_match=10  match_score=1.5  next_group_score=3.0  gate_was=1
DBG   -> gate CLEARED by this float
DBG pair 11-12
DBG pair 6-13
DBG pair 1-9          <- the answer this engine could not reach
```

`isSingleDownfloaterTheByeAssignee` was TRUE entering that bracket and
was **cleared by rank 9's tentative match to rank 10** - a 1.5-point
player who is not a member of the 3.0 bracket at all, and whose
tentative match exists only inside the persistent global matcher. With
the gate cleared, C9 does not apply to this bracket's decision, and
`{1,9}` follows immediately. This engine's stateless per-bracket solve
cannot observe that tentative match, computes the gate as `true`,
applies C9, and lands elsewhere.

So a case the adjudicator labelled `C2/C4/C5` is driven by the same
`isSingleDownfloaterTheByeAssignee` gate as the ones it labels `C9` -
the rung a disagreement SURFACES on is not the rung that caused it.

**Where that leaves the count**, by evidence rather than assumption:

| | n | confidence |
|---|---|---|
| gate, confirmed by direct trace | 2 | `seed223`, `seed1253` |
| gate, adjudicator-labelled C9 | 22 | strongly implied, same signature |
| ties - gate is exercised in the round (2 clear-events each) | 2 | consistent, NOT proven to cause those divergences |
| bye-axis tie | 1 | uncharacterised |

That is **24 of 29 confirmed or strongly implied**, and plausibly all
29. The honest caveat on the last three: a gate-clear happening
somewhere in the round does not establish it caused that round's
disagreement - proving those needs the divergent bracket identified
first, which is a further trace, not a re-reading of this one.

Toolchain note for next time: no C++ compiler or package manager
(`pacman`/`winget`/`choco`) was present on this machine. Portable
MinGW-w64 (winlibs.com's zip build, no installer) plus `mingw32-make`
built bbpPairings from a fresh clone cleanly on the first try -
`~/Desktop/02cloud/tools/mingw64/bin` on `PATH`, `mingw32-make -j4` in
the bbpPairings checkout. The `DBG_C9` instrumentation was not kept
(reverted with the source clone, which itself wasn't kept in this repo,
matching `Ainalrami.Test.Bbppairings`'s own not-vendored stance) - redo
it the same way (an env-var-gated `fprintf` block right after the
"Compute the new values for the next pairing bracket" comment in
`dutch.cpp`, rebuild, `DBG_C9=1 ./bbpPairings.exe --dutch <file> -p out`)
rather than re-deriving the trace from reading the source cold.

### How it got there: the global cascade replacing the per-bracket one

**Latest numbers first.** Against bbpPairings 6.0.0, exact rounds /
individual pairs, zero illegal rounds everywhere:

| field | now | the deleted per-bracket cascade |
|---|---|---|
| 4-40, 500x9 | **98.69% / 99.59%** | 90.29% / 97.21% |
| 60-80, 20x9 | **100.00% / 100.00%** | 82.22% / 97.99% |
| 90-120, 8x9 | **98.61% / 99.87%** | 86.11% / 99.03% |
| 4-40 + 8% byes | **98.99% / 99.65%** | 81.95% / 95.08% |
| 4-40 + 15% byes | **98.45% / 99.45%** | - |
| 4-40 + 10% forfeits | **98.57% / 99.55%** | 88.70% / 96.90% |

Against javafo at 4-40: 96.26%.

**The second engine is gone**, along with ~950 lines: `cascade_brackets`,
`greedy_cascade`, `bracket_options`, `bracket_candidates`,
`deeper_floats`, `within_bracket_weight`, `float_weight`, `pair_weight`,
`placeable_below`, `solve_bracket_all`, `mdp_deviation`,
`natural_partner_map`, `spans/1`, `lex_scale`, and the five tuning
attributes that fed them. It was reached zero times in ~1700 rounds with
byes and forfeits on, and keeping a whole second engine warm for a path
nothing takes is worse than not having it.

What replaced it as the safety net is part of THIS engine:
`repair_completion/3`, one whole-field matching that fixes completion
while keeping as much of the cascade's answer as it can. Only when that
also fails does `pair_later_round/1` raise `NoValidPairingError` - and at
that point it is the truth, because a whole-field maximum matching could
not pair everyone either.

**The repair fires zero times in normal running** - measured across plain
fields, 8% and 15% bye rates and 10% forfeits. That is the right outcome
and the wrong thing to leave on trust, so `AINALRAMI_FORCE_STRAND=1`
restores the old wrong stop condition on purpose and
`completion_repair_test.exs` asserts the engine still comes out legal
under it, pairing each round twice to prove the fault actually bites.
Insurance nothing has exercised is a guess.

### How the three engines guarantee a complete round

Same guarantee, three mechanisms - worth knowing before assuming ours is
either a hack or an advantage:

| | mechanism |
|---|---|
| bbpPairings | whole-field pre-pass proves a complete matching exists, throws `NoValidPairingException` if not (`dutch.cpp:828`). A CHECK - there is no repair anywhere in the file - then it trusts its incremental matcher to preserve completeness. |
| Gacrux | precomputes per-level feasibility ("hamilton", `pairingdutch.py:300+`) and uses it to REJECT a bracket choice that would strand the rest. |
| Ainalrami | pairs first, then repairs if completeness was lost. |

**Does ours produce legal rounds the others refuse?** No.
`tools/refusals.exs` plays deep Swisses in small fields - where refusals
actually happen - and asks Ainalrami every round bbpPairings turns down.
Over **118 refused rounds, Ainalrami refused all 118**: never a case where
it paired something bbpPairings could not, and never one where it emitted
something illegal instead. The two agree exactly on whether a round is
pairable at all, which is what should happen, since both answers come
from an exact whole-field maximum matching over the same legal edges.

So the repair is not a compliance advantage. It is insurance against
THIS engine's own staged finalisation, which the other two do not need
because they never lose completeness in the first place.

**What made the fallback unnecessary was a one-line bug.**
`bracket_loop/6` stopped when `rest == []`, which is the state *after*
popping the final score group - so the round ended on the very iteration
that first brought that group in, before the players carried into it had
any chance to pair with it. They were reported stranded and the round was
handed to the fallback. The correct test is whether a group was
CONSUMED (`next_group == []`), not whether any are left. That single
condition was essentially every fallback: ~10% of rounds before, zero
after, and it moved 4-40 from 97.51% to 98.69% and 60-80 to a perfect
180/180.

The section below is the older account, kept because the negative
results in it are still worth having.

### How the global cascade became the default, at 95.97%

**Read this first - much of what follows was written while it was still
losing, and is kept because the negative results are worth keeping.**

`global_cascade/2` replaced the per-bracket cascade as the default path.
Against bbpPairings 6.0.0, exact rounds / individual pairs, zero illegal
rounds everywhere:

| field | global (now default) | per-bracket (now fallback) |
|---|---|---|
| 4-40, 200x9 | **97.51% / 99.26%** | 90.29% / 97.21% |
| 60-80, 20x9 | **99.44% / 99.97%** | 82.22% / 97.99% |
| 90-120, 8x9 | **98.61% / 99.87%** | 86.11% / 99.03% |
| 4-40 + 10% forfeits | **97.03% / 99.16%** | 88.70% / 96.90% |
| 4-40 + 8% byes | **98.15% / 99.44%** | 90.62% / 97.28% |
| 4-40 + 15% byes | **97.50% / 99.19%** | - |

### The bye weakness was an off-by-one in float history

Arbiter-assigned byes were the worst axis by a wide margin (86.70%
against 95.97%) right up until the cause turned out to be a single index.

`getFloat` reads `player.matches[tournament.playedRounds - roundsBack]`.
This engine read `length(player.games) - rounds_back`. Those agree only
while every player has exactly one entry per played round - which is
precisely what an arbiter bye breaks: a player holding a pre-recorded bye
for the round about to be paired has one game MORE than the tournament
has played, so the lookup landed on that FUTURE bye instead of their last
real round. `score_before/3` was off by one the same way, so the score
comparison behind every float direction was being taken at the wrong
moment too. Every criterion from C14 to C21 was reading a fabricated
history for those players.

| | rounds | pairs |
|---|---|---|
| indexed by the player's own game count | 87.65% | 96.99% |
| **indexed by the tournament's round count** | **98.15%** | **99.44%** |

Byes went from the weakest axis to the strongest - better than the
no-bye case, which is not as odd as it sounds: a bye removes a player
from the round and shrinks the field the engine has to get exactly right.
At a 15% bye rate it still measures 97.50%.

The fallback path gained too (81.95% -> 90.62% with byes), since
`float_direction/4` is shared.

It is worth noting how long this hid. The bug is invisible without
arbiter byes - the two indexings coincide - and the harness defaults to a
0% bye rate, so nine tenths of every measurement taken on this project
could not see it.

Confirmed on a larger sample: **500x9 measures 97.88% / 99.39%**, zero
illegal rounds. By round it is 100/100/99.80/99.16/97.68/97.81/97.34/
95.25/92.64 - the old engine's round 9 was 69.46%. Against javafo at
4-40 the engine measures 95.78%.

Byes remain the weakest axis by a wide margin - 86.70% against 95.97%
without them - and the classifier says why: with byes, `bye_assignee` is
30.3% of the remaining failures against 2.9% without. That is the next
thing to work on.

**One dead end already ruled out there.** Adjudicating the 112 remaining
bye-rate failures puts 100 of them (89.3%) in "ties on every rung", and
among those FIDE's transposition order prefers bbpPairings' answer 71
times to ours 18. That looks like a tie-break problem and is not one:
the tie-break is inert (removing it changes nothing, with byes or
without), and PROMOTING it above the refinement stages' nudges is much
worse - 86.70% -> 79.93% with byes, 95.97% -> 87.57% without.

The reason is worth keeping: stages 5-7 EXCHANGE players between the two
halves, so by the time partners are chosen, "S1" and "S2" are no longer
the naive first-half/second-half split `transposition_key/3` assumes.
It is scoring transpositions against a reference the bracket has already
moved away from - which is why it reads as disagreeing with the stages
when the stages are right. Do not chase the 71 as a tie-break bug.

Against javafo at 4-40 the same swap is 89.31% -> 94.18%, and javafo is
on the 2017 edition, superseded on 31 January 2026, so full agreement
there is not the goal.

The gain is largest exactly where it matters: a 60-80 player open is the
ordinary case, and the engine went from getting four rounds in five right
to getting 179 of 180. By round on the 4-40 sweep, r9 went 69.46% ->
86.83% and r8 82.04% -> 91.62%.

`AINALRAMI_GLOBAL=0` selects the per-bracket cascade. It also stays the
automatic fallback - `global_cascade/2` verifies its own result and
returns `:infeasible` rather than emit an illegal round, and the
backtracking search runs then. That matters, because the global path has
no backtracking of its own.

**What actually fixed it: brackets could not see far enough.** The port
followed `dutch.cpp` literally in appending exactly one score group to
the bracket graph. But C8 is "choose the set of downfloaters so that in
the FOLLOWING bracket every criterion from C1 to C7 is complied with",
and a bracket cannot check that against players it cannot see. Peeking
further - the extra groups are visible to the matcher and to C8, never
consumed, and nothing in them can be finalised - is worth:

| peek | 4-40 rounds / pairs |
|---|---|
| 0 groups (the literal reading) | 90.29% / 96.89% |
| 1 | 94.14% / 98.17% |
| 2 | 95.62% / 98.52% |
| 3 | 95.91% / 98.63% |
| 4, 6, unbounded | 95.97% / 98.64% |

(Historical: `@peek_budget` is `:unbounded` now - see the persistent-
matcher section above for why the depth question turned out to be the
wrong one.) Budgeted in PLAYERS (`@peek_budget`, 8) rather than groups, because
groups are the wrong unit: a small field has score groups of one to
three, so four of them is a handful of players; a 60-120 field has groups
big enough that one already supplies the same context, and paying for
four costs 2.6x the time for identical output.

**Peeking further then broke C8's own meaning, and fixing that is worth
another 1.5 points.** bbpPairings' graph stops at the next score group,
so its `lowerPlayerInNextBracket` bit can only ever mean that one group.
With several groups visible, the same bit scored a float landing in the
very next group exactly the same as one falling three groups down - and
C8 is about the FOLLOWING bracket specifically. Grading the rung by
distance (`reach_table/3`, nearer is better) measured:

| | 4-40 | +8% byes | +10% forfeits | vs javafo |
|---|---|---|---|---|
| plain `in_next` bit | 95.97% | 86.70% | 95.72% | 94.18% |
| **graded by distance** | **97.51%** | **87.65%** | **97.03%** | **95.78%** |

Worth recording as a general lesson: porting a bit faithfully is not the
same as porting it correctly once the surrounding structure has changed
underneath it.

This does NOT contradict "do not read the lookahead as a licence to pair
across brackets" below - that still holds and is still enforced.
`collect_bracket/1` keeps a pair only when both ends are inside the
current bracket. Seeing further and finalising further are different
things, and only the second one ever measured badly.

**How it was found**, since the method mattered more than the fix: the
failure classifier and then `tools/adjudicate.exs`, which scores both
engines' answers with this engine's own ladder. That flagged 47 of 167
failures on one rung, and reducing those to
`test/fixtures/open_questions/` produced two files with an IDENTICAL
bracket graph that bbpPairings answers differently depending on what lies
below. "The bracket's own graph does not determine the answer" is a
statement about visibility, and C8 is the criterion that is supposed to
provide it.

**C9's gate then turned out to be actively harmful, and porting the rest
of it is worth another 3.6 points with byes.** The rung was gated on
bbpPairings' first two conditions only (odd field, bye score at or above
the next group's), leaving out the refinement at dutch.cpp:1636-1643 that
CLEARS the flag when a carried player is already tentatively matched
below that group - because then the downfloat runs deeper than one
bracket and C9 does not apply. Measured at an 8% bye rate:

| C9 | rounds | pairs |
|---|---|---|
| over-inclusive gate | 83.14% | 95.55% |
| rung switched off entirely | 83.73% | 95.76% |
| **gate ported in full** | **86.70%** | **96.48%** |

So the half-ported criterion was worse than no criterion - a useful
reminder that a gate is part of a rule, not a detail of it. Carrying the
flag between brackets needs `collect_bracket/1` to report the score each
carried player was tentatively matched with, which it now does. Zero
illegal rounds throughout, and the no-bye figures are untouched.

Forfeits benefit too: 10% forfeit rate went 93.10% -> 95.72%.

**One earlier divergence has been withdrawn.** Dropping the leading `1`
from the completion rung was worth +0.18 exact rounds before the peek fix
and is worth exactly nothing after it - both forms now measure identical
to the digit, with and without byes. The literal `dutch.cpp` reading is
back as the default. The anomaly that motivated the divergence was never
about that rung; it was about what the bracket could see.

**Remaining: 68 failures at 4-40** (was 164). By cause: float_partner 37,
float_set 28, bye_assignee 2 (was 25), internal_pairing 1 (was 7).
Adjudicated: 41 tie on every rung with the transposition order now split
almost evenly (17/14/10, i.e. noise rather than a systematic tie-break
error), 22 where our ladder prefers our own answer, 5 the reverse. 26 of
the 68 involve C12 - but see `explain_round/3`'s "what it cannot see":
that scorer cannot measure the C8 rungs, which outrank colour, so a C12
verdict is a lead and not a conclusion. `colour_stats/1` was checked
against `computePlayerData` rung for rung and is faithful.

### Historical: the global cascade before the peek fix

`global_cascade/2` is now bbpPairings' bracket algorithm ported stage for
stage (`dutch.cpp` 1011-1649) rather than one matching per score level.
Three things were wrong with the earlier attempt, in descending order of
how much they cost:

  * the graph spanned the **whole remaining field**, so pairs three
    brackets down carried weight and distorted the optimum before being
    discarded. bbpPairings' graph is the current bracket plus the next
    score group and nothing else, and it never gives two moved-down
    players an edge at all (`dutch.cpp:607`).
  * **six of the eight refinement stages were missing** - everything from
    the remainder split through exchange minimisation, which is FIDE §3's
    transposition-and-exchange procedure in executable form.
  * a **non-terminating bracket loop**: bbpPairings can loop
    unconditionally because it has already proved a complete legal
    matching exists, and this engine deliberately carries on when its own
    pre-pass finds none. A final bracket that cannot pair internally span
    forever. Two tests were timing out on this, not on slowness.

| 200x9 vs bbpPairings | rounds | pairs |
|---|---|---|
| global cascade, before | 60.51% | 93.6% |
| global cascade, after | **90.11%** | 96.82% |
| per-bracket cascade (default) | **90.29%** | 97.21% |

+29.6 points, and a dead heat - three rounds in 1689, still behind on
pairs. It stays behind `AINALRAMI_GLOBAL=1` because "level with" is not a
reason to swap out the path every other measurement in this file was
taken against.

**Where to look next, if this is picked up again.** The global cascade
wins mid-event (r3 97.00 vs 93.50, r4 97.40 vs 95.83, r5 94.79 vs 92.19)
and loses late (r7 83.15 vs 84.24, r8 80.24 vs 82.04, r9 66.47 vs 69.46).
Late rounds are where legal pairings get scarce and the per-bracket
cascade's backtracking earns its 15 points of pairs. The global path has
no backtracking by design, because bbpPairings has none - it does not
need any, having proved feasibility up front (`dutch.cpp:825-837`). That
pre-pass is the last structural difference between the two designs and
the obvious next thing to port.

**One finding worth keeping regardless of which path wins.** The
canonical lexicographic tie-break (`lex_scale/1`), worth ~40 points on
the per-bracket path, is completely **inert** under the staged
refinement: removing it and even inverting it both reproduce 1522/1689
and the identical disagreement set. The switch was confirmed live before
this was believed - a bad value raises from inside the run. A tie-break
exists to choose among equally-optimal matchings; after eight staged
solves there is nothing left to choose, which is exactly what
bbpPairings' design claims for itself. It is deleted from that path (and
deleting it is what keeps the bignums small enough to solve a bracket
eight times without paying for it).

C9's rung measures inert too, but it is a real handbook criterion whose
absence was a documented gap, so it stays; it simply never fires in this
fixture set.

### What the 164 remaining failures actually are

`failure_taxonomy_test.exs` classifies every disagreement the comparison
harness counts, by walking the score groups top-down and reporting the
FIRST one where the two engines part company. It replays the harness's
own tournaments and asserts its count against them
(`EXPECTED_DISAGREEMENTS`), so the buckets provably describe the same
population the rates are measured over.

    PAIRING_FUZZ_COUNT=200 PAIRING_FUZZ_ROUNDS=9 \
      EXPECTED_DISAGREEMENTS=164 mix test --only taxonomy

Default path, 200x9, 164 disagreements:

| cause | count | share |
|---|---|---|
| `float_partner` - same players float, different opponent receives them | 70 | 42.7% |
| `float_set` - a different SET of players floats out (C6/C7/C8) | 62 | 37.8% |
| `bye_assignee` - a different player is left unpaired (C5/C2) | 25 | 15.2% |
| `internal_pairing` - same floats, bracket pairs its own members differently | 7 | 4.3% |

**This overturns what this file and docs/fide-criteria.md have both been
calling the largest remaining gap.** That gap is FIDE section 3's
transposition/exchange procedure, which `deviation` and `spread` stand in
for - and pure "same floats, different internal pairing" is
`internal_pairing`, **4.3% of failures**. The global-cascade rewrite was
substantially motivated by implementing that procedure properly. It did,
and it tied, which is exactly what a correct fix to a 4% cause looks
like. The effort was aimed at the wrong target, and only measuring the
aggregate hid that.

**80.5% of failures are float decisions** - who leaves a bracket (62) and
who receives them below (70). `float_partner` being the single largest is
the surprise: the two engines agree on which players downfloat and then
hand them to different opponents. That is MDP-opponent selection, which
on the global path is stage 2 (`stage_mdp_opponents/1`, dutch.cpp
1207-1255) and on the default path is however `float_weight/4` and the
bracket matcher settle an MDP against residents.

**Start with the top bracket.** 24 of the 164 diverge in the FIRST score
group, which inherits no floats and no earlier decision - a divergence
there is an isolated wrong answer, not the downstream consequence of one,
so it should reproduce standalone. **20 of those 24 (83%) are
`float_partner`**, so the largest cause is also the one with the cleanest
available reproductions. First eight: seeds 3/22/32/32/32/53/74/93 at
rounds 8/8/7/8/9/7/9/7.

Ranked by size, the work is: MDP-opponent selection (70), downfloater
choice (62), bye assignment among equal-lowest-score candidates (25),
and transposition/exchange LAST (7).

### Adjudicating those failures against our own ladder

Classifying says WHAT differs; it does not say who is right. So
`Pairing.explain_round/3` reconstructs the brackets any complete pairing
implies and scores it with this engine's own C1-C21 ladder, rung by
labelled rung. Scoring BOTH engines' answers and comparing the first
bracket where they differ splits every disagreement three ways: the
reference scores better (our search failed to reach a pairing our own
ladder prefers), we score better (then the LADDER is wrong, since the
reference would not violate a criterion it implements), or they tie (the
criteria cannot separate them at all and something below decides).

It self-tests: the reconstruction must account for every pair exactly
once, checked on all 167 cases for both engines' answers, so the buckets
cannot be describing a decomposition the engine never used.

|  | default path (164) | global path (167) |
|---|---|---|
| tie on every rung | 119 (72.6%) | 83 (49.7%) |
| reference scores better | 35 (21.3%) | 75 (44.9%) |
| we score better | 10 (6.1%) | 9 (5.4%) |

`AINALRAMI_GLOBAL=1 mix run adjudicate.exs <dump-dir>` (script in the
scratchpad; dumps come from `PAIRING_FUZZ_DUMP`).

### Four things this settled, three of them negative

**1. `deviation` and `spread` are NOT replaceable stand-ins.** This file
and docs/fide-criteria.md both describe them as non-FIDE terms doing the
work of section 3's transposition/exchange procedure, and call replacing
them the largest remaining gap. Removing them measured **90.29% ->
42.21%** of rounds (dropping `spread` alone accounts for essentially all
of it). `spread` maximises rank distance, which is what produces the
S1-vs-S2 halving in the first place - it is load-bearing, not
decorative. Kept, and `ordering_rungs/4` leaves the switch in place.

**2. The canonical tie-break was keyed on the wrong thing, and fixing it
changes nothing.** `lex_scale/1` keys on ABSOLUTE bracket position, which
makes the natural pairing (S1[0] vs S2[0], positions 0 and k) look large
and an adjacent pairing (0 vs 1) look smallest - the opposite of the
Dutch structure. FIDE's rule is lexicographic over S2: which S2 member
faces S1[0], then S1[1]. Both are now implemented
(`transposition_terms/3`, `transposition_key/3`). Measured: **inert on
both paths**, in every variant tried - removed, inverted, and replaced
with the handbook key. On the default path the two forms are provably
equivalent once `spread` has fixed S1/S2 (the tail of the sequence is
determined by its head); on the global path the eight refinement stages
leave no ties for any tie-break to settle.

**3. `isByeCandidate` was wrong on even fields.** bbpPairings only
computes a real `byeAssigneeScore` for an ODD field; for an even one it
stays at its zero initialiser, so `score <= byeAssigneeScore` is false
for anyone who has scored and the top rung collapses to a constant 3 per
edge - pure "maximise pairs". This engine treated a nil bye score as "no
score test", so the rung VARIED on even fields: an edge touching a player
who had already taken a bye outscored one that did not, at the very top
of the ladder, above C6. Fixed. Inert at the harness's default 0% bye
rate, which is why nothing caught it; it should matter with
`PAIRING_FUZZ_BYE_PCT` set.

**4. The remaining failures are NOT the stages dropping pairs.**
`AINALRAMI_TRACE=1` prints the kept-pair count after each of the eight
stages. On the traced cases the count never falls - the initial solve
already produces the answer the round ends with, so the ladder is
choosing it, not a refinement stage losing it.

### The one fully-isolated open case

`seed102-r7-p28`, bracket at score 4.5. Graph is MDP [7] + residents
[5, 9, 27] + next group [1, 14].

  * ours: `{7,5}` internal, `{9,1}` and `{27,14}` crossing - **3 edges**,
    C6 = 1, and 9/27 are finalised one bracket lower instead.
  * bbpPairings: `{7,5}` and `{9,27}` internal - **2 edges**, C6 = 2.

Every legality question is settled: `{1,14}` is a rematch (round 3), so
the 2-internal option genuinely cannot reach 3 edges; `{9,1}` and
`{27,14}` are both legal and colour-compatible for either engine (all
four players are colour-neutral, imbalance 0).

So bbpPairings took strictly FEWER pairs in the bracket graph than it
could have. Our top rung - the completion criterion, `1 + !isByeCandidate
+ !isByeCandidate`, constant per edge on an even field - is maximised by
the 3-edge answer, and it sits above C6 in `computeEdgeWeight` exactly as
it does here. On the reading of dutch.cpp used for this port, bbpPairings
should have chosen ours. It did not, and 47 of the global path's 167
failures are flagged on precisely this rung.

That is the next thing to resolve, and it is a question about what the
completion rung actually maximises, not about the stages: either it is
not summed over cross-bracket edges the way this port assumes, or
something constrains the bracket graph that this port does not model.

**Reduced to a minimal reproducer, and the answer is now measured rather
than inferred** - see `test/fixtures/open_questions/`. Two files with the
identical bracket graph (`{1} 5.0`, `{2,3,4} 4.5`, `{5,6} 4.0` with 5-6
already played), differing only in whether a `{7,8} 3.5` group exists
below it:

| | bbpPairings 6.0.0 | edges | internal (C6) |
|---|---|---|---|
| nothing below | `1-2, 3-5, 6-4` | 3 | 1 |
| a 3.5 group below | `1-2, 3-4, 7-5, 6-8` | 2 | 2 |

The cross edges exist and bbpPairings uses them when the 2-internal
answer would strand 5 and 6. Given anywhere for 5 and 6 to go, it takes
2 internal pairs over 3 edges - **C6 beats edge count**, the opposite of
what `computeEdgeWeight`'s shift order says, and the same bracket graph
yields different answers depending on what lies beyond it.

So the completion rung is not "maximise edges in this graph". Whatever it
is, it is not a property of the bracket graph alone, and that is the
thing to work out next. Everything needed is in the fixture directory's
README, including why Ainalrami itself returns nothing for those two files
(an artefact of building scores from arbiter byes, not a second finding).

**Acted on, and it is worth a small win.** `completion_rung/4` now drops
the leading `1` from that term, so it expresses only the bye preference
and stops counting edges, leaving C6 - which it outranks - to decide how
many pairs a bracket keeps. Global cascade, 200x9:

| | rounds | pairs | illegal |
|---|---|---|---|
| `AINALRAMI_COMPLETION=edges` (the literal C++) | 90.11% | 96.82% | 0 |
| eligibility only (now the default) | **90.29%** | 96.89% | 0 |

Zero illegal rounds either way, so removing the explicit edge-count
pressure does not cost completion in practice - the cascade still checks
its own result and falls back rather than emitting an illegal round. That
puts the global cascade level with the per-bracket cascade on exact
rounds (90.29% both) and still 0.3 behind on pairs.

This is the first deliberate divergence from a literal reading of
`dutch.cpp` in this port, taken because bbpPairings' observed behaviour
contradicts the literal reading and the measurement agrees with the
behaviour. The verbatim form stays one env var away.

45 of the global path's disagreements are still flagged on this rung by
the adjudicator, but the term now varies only where bye ELIGIBILITY
genuinely differs rather than wherever the edge count does, so those are
a real C2/C5 signal and the next thing to pull on.

  1. **The colour model was only ever right for round 2.** "Preference is
     the opposite of your last colour" is exactly correct when every
     player has played exactly one game, and wrong from round 3 on, where
     a player can be two colours out of balance or have had the same
     colour twice. Both produce an ABSOLUTE preference the old rule could
     not represent. The tell was that the deficit oscillated with round
     PARITY - only colour balance has a reason to care whether the round
     number is even - and fixing it moved even rounds 12-15 points and odd
     rounds 1.5.
  2. **The float-history criteria were the predicted round-3 cliff**, and
     they behaved exactly as item 4 below predicted: round 3 went 91.36%
     → 99.39%. A float is not recorded in a TRF, it is derived by
     comparing what two players' scores were when they were paired.
  3. **Greedy per-bracket pairing is not globally optimal, and produced
     ILLEGAL output** - two pairing-allocated byes in an even field, in 65
     of 104 sampled disagreements. A bracket that pairs as many of its own
     players as possible can strand a later one holding nothing but a
     rematch. This is the largest single defect the depth work found, and
     it is a correctness bug, not a disagreement.
  4. **"Don't downfloat a player holding an unplayed round" was
     over-generalised.** It came from round-2 tuning, where it was worth
     six points. bbpPairings guards the equivalent criterion with
     `isSingleDownfloaterTheByeAssignee`: it is "minimise the unplayed
     games of the BYE ASSIGNEE", not a standing protection for anyone who
     once had a bye.

Two reverted on measurement, both of which looked cleaner than what they
replaced:

  - **Subordinating the float protections to the pair criteria.** Cost
    seven points and most of round 2. Re-floating protection genuinely
    outranks every pairing criterion, matching bbpPairings placing bye
    eligibility above colour. Only the plain rank tie-break belongs at the
    bottom.
  - **Ordering the cascade's alternatives by weight.** Fewer floats almost
    always outweighs more, so a global sort fills the list with
    one-floater variants and the cascade loses the ability to float MORE
    players when that is the only way to finish the round.

And one bug worth remembering because it was invisible: in
`Ainalrami.Matching`, prepending rather than appending a candidate before a
**stable** sort lets it overtake an equal-weight incumbent and silently
inverts a tie-break. Ties are everywhere in this weight scheme. That
one-character difference cost round 2 forty points while leaving every
reported weight identical, and was only localised by setting the
candidate count back to 1 - which should have been behaviourally
identical to the previous commit, and was.

### How close to javafo, and under what conditions

Measured, not estimated. The variable that decides accuracy is NOT the
round number - it is **how much of the field a player has already met**,
i.e. rounds as a fraction of roster size. Opponent exhaustion, not depth.

At 15 rounds, varying only the field (10 tournaments each):

| field | rounds as % of field | pairs | illegal rounds |
|---|---|---|---|
| 18-20 | ~83% | 79.45% | 26/150 |
| 26-28 | ~57% | 86.03% | 17/150 |
| 34-36 | ~44% | 90.62% | 8/150 |
| 44-46 | ~34% | 95.80% | 1/150 |
| 60-70 | ~22% | 97.76% | 1/150 |

A 60-70 player field over 15 rounds is 97.76% - as good as the 9-round
number. A 32-40 player field over 30 rounds collapses to 62.89% with
1477/2997 rounds illegal. Same engine, same depth of history; the
difference is entirely how many legal opponents remain.

So for real events: a 9-round Swiss in a 40-player field, or a 15-round
blitz in a 60+ field, both sit near 97%. A 20-round event in a 30-player
field does not work at all.

**Fixed by augmenting-path repair, then closed almost the rest of the
way by adding blossom contraction to it.** When the cascade gives up, the
greedy fallback's result now gets a general-graph maximum-matching pass
applied to it (`Ainalrami.Blossom`), which pairs up players it left over.

First pass - plain alternating-path BFS, no blossom handling - took
illegal rounds at 30 rounds from **1477/2997 to 65/2997**, every round
through 22 legal. The 65 that remained were not random misses: they were
specifically the cases a blossom-blind search structurally cannot reach,
where the only augmenting path runs through an odd cycle. Confirmed by
building `Ainalrami.Blossom` (a direct port of the standard O(V^3)
reference algorithm - see that module's doc) and swapping it in with no
other change: **65/2997 -> 1/2997**, every round through 29 legal.
blossom's own correctness was checked against a brute-force
maximum-matching oracle on 25 random small graphs plus a hand-verified
odd-cycle case, all passing, before it was wired in.

Pair agreement moved 62.89% -> 61.09%, the same trade as before: the
rounds that changed were illegal and are now legal, and a legal round
that differs from javafo is worth more than an illegal one that happens
to share boards with it. The nine-round measurement was 97.15% going into
this step, since the repair only ever runs on rounds the cascade failed.

**The one remaining illegal round turned out to be a real bug, not a
search-budget limit** - worth recording since the previous paragraph
guessed budget with more confidence than the evidence supported. Tracing
it (seed 39, 32-player field, round 30) found Ainalrami leaving two
players unpaired despite a full pairing existing, confirmed reachable at
all by temporarily disabling colour compatibility entirely, which found
one immediately.

The actual cause: `final_round_topscorers?/2`'s threshold used
`expected_rounds` where bbpPairings' own formula (`dutch.cpp:53-56`,
`topScoreThreshold = playedRounds * pointsForWin >> 1`) uses
`playedRounds` - rounds actually played, not the tournament's eventual
length. Those are genuinely different numbers even in the one round this
exception can ever fire in (the final round, where `playedRounds` is
always `expectedRounds - 1`): `floor((expectedRounds-1)/2)` is one lower
than `floor(expectedRounds/2)` whenever `expectedRounds` is even, so the
old formula silently admitted top-scorer exceptions for players who were
one point short of actually qualifying.

One-line fix (`div(played_rounds, 2)` in place of `expected_rounds / 2`).
Re-measured:

  9 rounds, 10-40 players:    97.15% -> 97.19% of pairs, 2 -> 0 illegal
  30 rounds, 32-40 players:   1 -> 0 illegal, EVERY round legal

**2997/2997 legal rounds** - every round, across the hardest
configuration measured in this project so far.

**The failure mode was legality, not disagreement.** The two rise together
because they are one event: when the bracket cascade cannot find a legal
completion inside its bounded search it falls back to greedy, and greedy
output is both an illegal bye count and unrelated to javafo's. Raising
`@cascade_budget` 25x does not help - it makes the search intractable
instead, because a bounded depth-first search over per-bracket
alternatives is the wrong tool when the constraint is global.

This is the strongest argument yet for the global-matching item below:
bbpPairings runs one matching over the whole field FIRST, specifically to
prove a legal round exists.

### What bbpPairings actually uses, and why the obvious shortcut fails

Settled from its own source rather than inferred. `src/matching/computer.h`
documents itself as "the basic algorithm presented in *'An O(EV log V)
Algorithm for Finding a Maximal Weighted Matching in General Graphs,'* by
Zvi Galil, Silvio Micali, and Harold Gabow, 1986", implemented at O(n^3)
with an incremental-update modification. The `blossomimpl.h` /
`parentblossom.cpp` / `rootblossom.cpp` layout is that paper's blossom-tree
decomposition. So it is genuinely the full primal-dual weighted blossom
algorithm - there is no simpler variant hiding in bbpPairings either.

**Bracket sizes say we may not need it.** Measured over 40 generated
tournaments (2504 brackets, 2136 adjacent pairs):

| | median | p90 | p99 | max | over 20 |
|---|---|---|---|---|---|
| single bracket | 4 | 11 | 30 | 58 | 1.9% |
| current+next combined | 9 | 19 | 34 | 43 | 8.6% |

91.4% of combined bracket-pairs fit inside the exact subset DP that is
already in the tree and already weighted. Weighted blossom is what lets
bbpPairings do this at ANY size; at our sizes it is mostly unnecessary.

**But naively merging the two brackets measured 97.19% -> 58.48%** (150
tournaments, 9 rounds) with 7 unit tests failing, so it is not a drop-in.
The reason is specific: `natural_partner_map/1` and `mdp_deviation/4`
assume ONE score tier with floaters sitting above it. Merge two score
groups and the entire lower group becomes "residents" to a doubled MDP
set, which scrambles the S1/S2 natural correspondence those criteria are
defined against. Reverted.

So the remaining path is real design work, not a patch: redefine the
natural-correspondence machinery for a multi-tier bracket before the
merge can be attempted again. That is the actual blocker - not the
matching algorithm, which the DP already covers at these sizes.

**Update:** the matching algorithm itself is no longer a blocker even for
sizes past the DP's reach. `Ainalrami.WeightedMatching` is a from-source
port of the actual Galil/Micali/Gabow primal-dual algorithm described
above (read from bbpPairings' `src/matching/detail/{graph,rootblossom,
parentblossom}.cpp`, not reconstructed from memory), verified against
`Ainalrami.Matching`'s independent subset-DP oracle across 900+ random
graphs (`weighted_matching_test.exs`) including cases dense enough to
require both blossom formation and blossom expansion. It is NOT wired
into `Pairing` yet - that still waits on the natural-correspondence
redesign above, since a wider matcher alone doesn't fix the S1/S2
scrambling a merged bracket causes.

### Still open at depth

Rounds 7-9 sit at 89-92% of pairs. Known gaps, in the order most likely
to matter:

  - ~~The four SCORE-WEIGHTED float criteria~~ - **THIS ENTRY IS OUT OF
    DATE AND DANGEROUS. They are LIVE**: `float_score_criteria/3`
    (`pairing.ex:2660`), wired at `:1845`, scored as the C18-C21 rungs at
    `:1881-1884`, and listed as implemented in `docs/fide-criteria.md`.
    Anyone reading the paragraph below before touching the ladder would
    conclude those four rungs are absent and could "restore" a regression by
    deleting working code. What follows describes the FIRST attempt, made
    against the per-bracket cascade, and its own closing sentence - "worth
    retrying only if the cascade is ever replaced by a global matching" - is
    exactly what then happened. The retry succeeded and this entry was never
    updated. Kept only because the reasoning about WHY it failed the first
    time is the useful part.

    The original entry, as written: **implemented, measured WORSE,
    reverted.** `dutch.cpp` 385-460 weights each float criterion
    by which score group it affects, ranked below the four unweighted
    ones. Ported faithfully (positional weights per score group, lowest
    group at index 0, sum-safe base) it measured **93.40%** against
    97.15%. Disabling just the two "scores of the opponents of
    upfloaters" halves gave 93.27%, so it is the whole family, not one
    bad member.

    The likely reason it does not port: in bbpPairings these criteria are
    guarded by `lowerPlayerInCurrentBracket` and the score groups are
    TOURNAMENT-wide, because its matching spans the current bracket AND
    the next one. Only a subset of edges get the term, and "which score
    group" means something relative to the whole field. In a matcher that
    runs over one bracket at a time, every edge gets it and the group
    index is bracket-local, so the criterion stops discriminating the way
    it does there and just adds noise at high priority.

    Worth retrying only if the cascade is ever replaced by a global
    matching - the two changes are coupled.
  - ~~Half-point byes, zero-point byes and retirements need a protocol
    change~~ - **done, and they were expressible after all.** There is no
    TRF flag for "not playing this round"; the mechanism is that the
    arbiter records the result IN ADVANCE and the engine then leaves that
    player out (`dutch.cpp:658`, `if (player.matches.size() <=
    tournament.playedRounds)`). This engine paired them anyway, so a
    player who had asked for a bye got a game - confirmed against javafo
    on a six-player case. `PAIRING_FUZZ_BYE_PCT` now generates them;
    92.86% of pairs at 8%, with 2/1797 illegal rounds.

    **Update:** those 2/1797 (and a fresh 3/2119 re-measurement) turned
    out to be genuine deadlocks, not search misses - confirmed by an
    independent exhaustive search restricted to the true active player
    set for each case (a small field deep into a Swiss, colour-absolute
    exclusions stacking on top of near-exhausted rematch-free opponents).
    `repair_bye_count/3` was silently returning that still-illegal
    pairing instead of recognising it as unsolvable; it now raises
    `Ainalrami.Pairing.NoValidPairingError`, matching bbpPairings'
    own `NoValidPairingException` (`dutch.cpp`'s `compatible`/
    `matchingIsComplete` never accept more byes than
    `rem(active_count, 2)` either - they throw instead).
    `Ainalrami.Generator` catches it and truncates the tournament at the
    last round that actually completed. Re-verified end to end via the
    generator itself: **0 illegal rounds across 800 generated
    tournaments (~5500 rounds) at mixed bye rates 0/5/8/15%.**

    The round count needed care: neither the minimum games count (breaks
    on a late entrant, who has none, and empties the pairing) nor the
    maximum (breaks on the pre-recorded bye being detected) works.
    bbpPairings only advances `playedRounds` for games the player
    PARTICIPATED IN THE PAIRING for - a real game or a pairing-allocated
    bye, never an arbiter-assigned one (`trf.cpp:339-342`,
    `opponent != id || resultChar == 'U' || resultChar == '+'`).
  - The cascade approximates a global matching. bbpPairings runs one over
    the whole field first, to prove a legal round exists at all.
  - The bracket-ordering terms (MDP displacement, rank spread) still stand
    in for FIDE's transposition/exchange procedure and bbpPairings' three
    lowest criteria.
  - ~~The harness still generates only wins, losses, draws and byes.~~
    **Done for forfeits** (`PAIRING_FUZZ_FORFEIT_PCT`, default 0). It
    found four bugs of one family immediately, all of them code that had
    never executed: a forfeit carries an opponent AND a colour but is
    legally unplayed, and four call sites asked "is there an opponent /
    a colour" instead of "did this game happen". Worst of them was C1:
    a forfeited pairing does NOT forbid a rematch (`dutch.cpp:664`
    guards forbiddenPairs with `if (match.gameWasPlayed)`), confirmed
    against javafo re-pairing two double-forfeiters in preference to two
    rematch-free alternatives. With 10% of games forfeited, pair
    agreement went 69.86% -> 88.67% -> **93.76%**. Half-point byes,
    zero-point byes and retirements are still open, and need a protocol
    change: they are decided BEFORE pairing, so the harness would have to
    withhold those players from the TRF rather than record a result.
  - The old note, for the record: the harness generated only wins,
    losses, draws and byes.
    bbpPairings' generator also produces forfeits, retirements and
    half-point byes (`generator.h`'s `forfeitRate`, `retiredRate`,
    `halfPointByeRate`) - a real coverage gap, deliberately left out of
    the depth work so a rate change could be attributed to depth alone.

   **Historical detail on how each fix was found** (each caught by the
   previous revision's own comparison run):

   1. *Unrestricted exhaustive search, no colour scoring* - failed
      consistently (0/10). Hand-traced 18-player case (seed 3): a
      same-score bracket with zero rematch conflicts still didn't match
      javafo.jar - javafo picked the pairing where every pair had
      complementary colour preferences (one wants white, one black, from
      round-1 colours), over an equally rematch-legal one that didn't.
      Colour preference decides pairing composition, not a step applied
      after composition is fixed.
   2. *Unrestricted exhaustive + colour scoring* - seed-3 fixed, but the
      search re-explored the same subsets with no bound (confirmed 194ms
      at 12 players, didn't finish in 60s at 16 in a real comparison run).
   3. *Bipartite reformulation* (S1 better-half vs S2 worse-half, solved
      as bipartite matching - same structure round 1 uses) - fixed the
      hang, but was **confirmed WRONG at scale**: only 10.7% matched over
      2000 random histories, including a regression on the seed-3 case
      that matched exactly in revision 2. Cloning bbpPairings locally
      (`AuroraRyunix/bbpPairings-source`, independent/open/Apache-2.0) and
      reading `swisssystems/dutch.cpp` explained why: it computes a
      weight for ANY two compatible players (Edmonds' Blossom algorithm
      over the whole field), using bracket/S1-S2 membership as a WEIGHTED
      BONUS in that computation, never a hard structural exclusion. The
      bipartite restriction was a real modelling mistake, not a
      simplification.
   4. *General (non-bipartite) matching, kept tractable via memoization*
      (current) - restores correctness (2000-history re-run: 51.7%, up
      from 10.7%) without reintroducing the unbounded-search hang, at the
      cost of being exponential in the WHOLE bracket size again (not half,
      unlike revision 3) - see `Ainalrami.Matching`'s moduledoc for the
      actual complexity trade-off and where this could still be slow. The
      SAME 2000-history run's remaining disagreements pointed at one more
      concrete gap: two engines can agree a player must float down two
      bracket levels in the same round, yet pick a *different* one to do
      it - javafo strongly prefers floating a bracket's own fresh
      resident over re-floating a player who already floated once this
      round (an MDP), matching bbpPairings' own "minimise downfloaters"
      criterion. `cascade_brackets/3` now stamps `:already_floated` on a
      bracket's own unpaired players before they enter the next bracket,
      and `float_weight/1` penalises that flag heavily. Confirmed fixed on
      the specific case that surfaced it (seed 15), and re-run clean at
      scale: **66.24% at 5,000 random round-1 outcomes** (0 process
      errors - checked directly, see the round-1 100k lesson above about
      not trusting a number without checking for that), up from 51.7%
      before this fix, consistent with the earlier 66.3% at 1,000. A
      real, stable number - not yet 100%, but a genuine three-fix
      trajectory (0% → 51.7% → 66.24%) with each step independently
      confirmed, not a guess.

   Also fixed a real pre-existing bug the seed-3 investigation surfaced
   (revision 1): `colour_preference/1` and `assign_colour_with_history/1`
   were matching atoms (`:white`/`:black`) against `Ainalrami.Trf`'s actual
   `"w"`/`"b"` string convention - colour history was *silently never
   applied* before this, every decision quietly falling through to the
   round-1 fixed convention.

   *(The seed-15 case that this section previously flagged as an
   unexplained spread-tie-break mystery was resolved by the one-sided MDP
   displacement fix - it was never a spread problem.)*
3. **Absolute criteria [C1]-[C5] partly covered.** No-repeat pairing
   (`legal_pair?/2`) and ~~no-second-bye~~ **C2 (`eligible_for_bye?/1`,
   done)** are enforced; topscorer-colour clash and
   bye-assignee-score-minimisation are not.
4. ~~**Float-history criteria (two rounds back).**~~ **Done** - see
   "Depth" above. The prediction in this item held exactly: the criteria
   cannot bind before round 3, and round 3 was the measured cliff
   (91.36% → 99.39% of pairs). Four levels ported from `dutch.cpp`'s
   `getFloat`. (The four SCORE-WEIGHTED variants were listed here as "still
   open" long after they landed - they are live as C18-C21, see the
   correction above.)
5. ~~**Colour allocation & floater history refinement**~~ **Done** -
   Article 5.2's full preference-strength computation is ported
   (`colour_stats/1` from `computePlayerData`, `choose_colour/2` from
   `choosePlayerNeutralColor`), including absolute/strong/mild strength
   and the absolute colour-difference rules.
6. **Checker (`-c`)** - ~~JaVaFo's FPC role~~ **done**. Replays a
   completed tournament, re-pairs each round from the state before it, and
   diffs. Exits nonzero on any composition difference; colour differences
   are reported but never errors.

   One belief this corrected: a checker is NOT "a verifier against every
   criterion", as this item used to claim. bbpPairings' own checker
   (`tournament/checker.cpp`) clears the matches, replays, and calls
   `computeMatching` - it re-runs the ENGINE and defines correct as what
   the engine produces. So a checker cannot tell a legal-but-different
   pairing from an illegal one, and building one does not give an
   independent oracle for the residual disagreement rate. The harness's
   own `illegality/2` remains the only independent legality check here.

   ~~**RTG (`-g`)**~~ **done** - `Ainalrami.Generator`. Random roster,
   played forward with this engine pairing each round, optional forfeits
   and arbiter-assigned byes. Seeded and reproducible, with the seed
   written into the generated file's own tournament name (bbpPairings
   puts it on line one, which would not be valid TRF).

   The generator pairs with the engine under test on purpose, matching
   bbpPairings' own RTG: the point of an RTG in FE1's auto-test is to
   produce tournaments whose pairings a REFERENCE checker then verifies,
   so they have to be the candidate program's own.

   Both halves of FE1's auto-test apparatus now exist. What does NOT
   exist is a reason to run it: FE1 only asks for FPC/RTG when "Internal
   engine: YES", endorsement for Ainalrami is explicitly deferred below,
   and the bar is one difference per 500 tournaments against a current
   rate near 11% of rounds.
7. **Team pairing.** Depends on OpenPairings' own team-tournament work
   landing first (see that project's `TODO.md`) - team-level Swiss/
   round-robin scheduling, then per-board pairing within a scheduled match.
8. **Acceleration variants beyond Baku**, alternate tiebreak orderings -
   the actual point of building a second engine in the first place, per
   the original "too many gimmicks" / "hard pairing variants" discussion in
   OpenPairings.

## Cross-validation against bbpPairings

**Done, and measured** - `Ainalrami.Test.Bbppairings` +
`bbppairings_comparison_test.exs`, the same methodology as the javafo
harness (play a tournament forward, diff each round, advance on the
REFERENCE engine's own answer). Uses OpenPairings' already-vendored
`priv/bbppairings/bbpPairings-windows.exe` (v6.0.0, official release),
located the same way `javafo.jar` is (`BBPPAIRINGS_EXE` env var,
defaulting to that sibling path) - not vendored into this repo either.

Two integration details that only showed up by actually running it, not
by reading the source:

- Output format is byte-identical to javafo's own (`count\r\n` then
  `white black\r\n` per pair, `0` for a bye) - no separate parser needed.
- Unlike javafo, bbpPairings does not choose the first round's colour on
  its own; it refuses to pair at all without an explicit `152 W`/`B`
  field whenever no player has a colour recorded yet. And it signals "no
  legal pairing exists" differently too - exit code 1 with no output
  file, versus javafo's empty-pairs-file-at-exit-0 - its own documented
  error code 1, "no valid pairing exists for the current round". Modelled
  as a distinct `{:no_valid_pairing, message}` return, handled the same
  way as javafo's exhaustion case (tournament ends early, round excluded
  from the rates, not counted as a mismatch).

**First real measurement** (200 tournaments × 9 rounds, 4-40 players):

| round | exact rounds | individual pairs |
|---|---|---|
| 1 | 100.00% | 100.00% |
| 2 | 100.00% | 100.00% |
| 3 | 98.00% | 99.28% |
| 4 | 95.83% | 98.87% |
| 5 | 88.54% | 96.80% |
| 6 | 85.03% | 96.00% |
| 7 | 78.26% | 93.60% |
| 8 | 67.66% | 91.50% |
| 9 | 55.09% | 86.45% |
| **overall** | **86.32%** | **95.92%** |

**0 illegal rounds** - independent confirmation of the legality fix two
commits up: bbpPairings agreed Ainalrami's structural-deadlock cases really
were unpairable (its own exit code 1, on byte-identical input, for the
exact case that motivated that fix).

Slightly lower than the javafo depth number (97.19% pairs / 88.93% rounds,
albeit a different 300×9 sample) but the same shape - rounds 1-2 exact,
gradual divergence at depth. One representative disagreement (seed 25,
round 4, 5 players) was hand-traced against the bracket/downfloat/
bye-eligibility rules: Ainalrami's answer matches a direct reading of
those rules; bbpPairings' differs in a way consistent with its
whole-field weighted matching trading bracket locality for some other
criterion - not an obvious defect, and consistent with the
already-documented gap that the bracket cascade approximates Art
3.3-3.5's exact transposition search rather than replicating it. A full
census of all 231 disagreements from that one run, and which of them
trace to genuine gaps versus legitimate rule variance, has NOT been done
- that's the natural next increment here, the same iterative way the
javafo depth work found float-history, the colour model, and the C1
forfeit-rematch rule.

Once Ainalrami is wired back into OpenPairings as a selectable engine, this
harness should run as a *third* comparison arm there too, not just
standalone here.

## Residual-error triage (2026-08-16) - FE1-shaped, and byes are load-bearing

Post-rewrite the engine agrees with bbpPairings on every axis to 100.00%
at reporting precision, so the residue is now small enough to enumerate
case by case rather than describe statistically. Every disagreement found
across **2.5M+ tournaments** was collected and triaged three ways.

**Rate, in FE1's own units.** FE1's bar is *"1 difference every 500 test
tournaments"* (equivalently: 5000 tournaments, at most 10 discrepancies).

| corpus | tournaments | disagreements |
|---|---|---|
| 8-axis validation (plain/byes/forfeits/combined/small/deep/large×2) | 527,000 | 7 |
| small fields 4-10 + 15% byes | 1,000,000 | 36 |
| small fields 4-10, **no byes** | 1,000,000 | **0** |
| **total** | **2,527,000** | **43** |

That is **1 per ~59,000 tournaments - roughly 120x inside FE1's bar.** A
5000-tournament auto-test would expect 0.09 discrepancies against 10
allowed. Zero illegal rounds throughout (≈26M individual pairings), once
the harness's own stale active-field rule was fixed - see that commit;
the 62 "illegal" rounds it first reported were the checker, not the
engine.

**Byes are necessary for the defect - a clean controlled result.** Two
1,000,000-tournament runs over the identical field sizes (4-10 players),
differing only in whether arbiter byes were generated: 36 disagreements
with byes, **0 without, across 6.0M rounds**. Whatever is left needs a
pre-assigned bye in the position to manifest at all.

**Three-way triage (40 collected cases, all 5-10 player fields):**

| | n | FE1 category |
|---|---|---|
| bbpPairings and Gacrux agree, we differ | 39 | candidate-program error |
| **Gacrux backs US, bbpPairings differs** | **1** | **rules-interpretation dispute** |
| three-way split | 0 | - |

`seed735265-r7-p10` is the dispute, and the first case in this project's
history where Gacrux has sided with Ainalrami against bbpPairings. Round
7, 10 players; the engines disagree about who takes the bye - ours and
Gacrux's give it to rank 7, bbpPairings' to rank 3. Notably it is ALSO
the only case the adjudicator scores `theirs_scores_better`, so our own
ladder prefers bbpPairings' answer while our engine (and Gacrux) produce
the other one. Not resolved here; FE1 explicitly provides for escalating
exactly this to the SPPC rather than "fixing" it.

**Adjudication of all 40 - and why C12 is a red herring:**

| verdict | n | first differing rung |
|---|---|---|
| ours scores better | 22 | C12 colour preference (19), C13 strong (3) |
| tie on every rung | 17 | lex picks ours (9), lex picks theirs (8) |
| theirs scores better | 1 | C2/C4/C5 bye-eligibility |

The C12/C13 surface is not the cause, and this was checked rather than
assumed - the colour predicates were compared line by line against the
primary source:

- C12: bbpPairings' `colorPreferencesAreCompatible` (`common.h:90-98`) is
  `p0 != p1 || p0 == NONE || p1 == NONE`; our `not clash?` where
  `clash? = not is_nil(p) and p == o` is logically identical.
- C13: same four disjuncts in the same order as `dutch.cpp:204-211`.
- The INPUTS match too: bbpPairings' preference ladder
  (`tournament.cpp:80-84`) is `imbalance > 1 -> lower : consecutive > 1 ->
  invert(repeated) : imbalance > 0 -> lower : consecutive -> invert :
  NONE`, which is `colour_stats/1`'s `cond` tier for tier, as are
  `lowerColor`, `colorImbalance` and `repeatedColor`.
- Both colour rungs are gated on `in_current`, matching bbpPairings'
  `inCurrentScoreGroup` mask (`dutch.cpp:170`).

So the ladder is a correct port and the earlier "do not retry" verdict in
`docs/fide-criteria.md` item 4 stands - now on verification rather than
on its own authority. The divergence originates ABOVE C12 and merely
surfaces there, which is that document's own hard-won lesson.

**Where that points.** 17 of 40 tie on every single rung and are decided
purely by the tiebreak, which splits nearly evenly (9 ours / 8 theirs) -
the signature of an ORDERING difference, not a criteria one. That is
`docs/fide-criteria.md` item 5: `deviation` and `spread` standing in for
FIDE §3's exact transposition-and-exchange procedure, already described
there as "the largest remaining gap". The 22 C12-surfacing cases are
consistent with the same cause reaching a different candidate. Combined
with the bye-dependence above, the shape to chase is: **small field +
pre-assigned bye + candidate ordering among criteria-equal pairings.**

**Superseded by the section below.** The shape was right and the
attribution was wrong: it is not transposition ordering, and it is not a
criteria-equal tiebreak. 39 of the 40 were one missing field in the
bootstrap matching, and the surviving one is the Gacrux-backed dispute.

## The first bracket's C9 gate was undefined, not absent (2026-08-16)

**39 of the 40 catalogued disagreements are gone. Every measured axis
stays at 100.00%, and `seed735265-r7-p10` - the rules-interpretation
dispute where Gacrux backs US - is the one that remains.**

### The case, and why C9 was the suspect

`seed940641-r4-p5` (kept as
`test/fixtures/bye_assignee_score/top-score-group-tiebreak.trf`). Five
players, round 4, score groups 2.0 = {3,4,5}, 1.5 = {1}, 1.0 = {2}; the
only legal pairs are 1-2, 1-5, 2-3, 3-4, 3-5. Ranks 2 and 3 hold `U`
byes so are C2-ineligible, and rank 1 cannot take the bye because the
remainder then cannot pair legally - so the bye is rank 4 or rank 5 and
both answers are legal.

    ours          [{1,2}, {3,4}, {5,nil}]
    bbpPairings   [{1,2}, {3,5}, {4,nil}]      <- Gacrux agrees

C9 is the whole difference: rank 4 has played all three rounds, rank 5
sat out round 1 with an `H`, and "minimise the number of unplayed games
of the bye assignee" therefore byes rank 4. An instrumented bbpPairings
confirmed the rung was live for it (`gate_was=1`), while
`tools/adjudicate.exs` scored C9 as **0 vs 0, not differing**, with the
disagreement surfacing at C12.

### The cause: a packed field that was never ported

`bye_assignee_score_from_field/2` is the bootstrap whole-field matching
of `dutch.cpp:766-786`, and it produces two things - `byeAssigneeScore`
and `isSingleDownfloaterTheByeAssignee`, the C9 gate for the FIRST
bracket. The C++ edge weight packs THREE fields; this port had two:

    eligibility   1u + !eligibleForBye(player) + !eligibleForBye(opponent)
    score         scoreGroupShifts[playerScore] + scoreGroupShifts[opponentScore]
    MISSING       player->score >= sortedPlayers.front()->score

`player` is the outer loop variable and the inner loop breaks at
`opponentIndex == playerIndex`, so `player` is always the worse-sorted of
the pair. On a field sorted best-first that bottom field means *the edge
lies wholly inside the top score group*, and summed over a matching it is
a count: **maximise the pairs formed inside the top score group.**

**Why it is not redundant with the two fields above it.** On an odd field
the matcher returns a near-perfect matching, so all but one player is
covered and both higher fields collapse into statements about that one
leftover - eligibility into "leave out someone who may actually take the
bye", score into "leave out the lowest-placed player". Neither can
distinguish two matchings with the same leftover, nor two leftovers that
tie on both. The bottom field is the only one that says anything about
the matching's SHAPE.

**And shape is exactly what the gate reads.** `first_single_bye?/4`
(`dutch.cpp:851-870`) clears the flag when any top-group player is
tentatively matched BELOW the top group. For this case the bootstrap has
a genuine three-way tie - `{1-2, 3-4}` (leftover 5), `{1-2, 3-5}`
(leftover 4) and `{1-5, 2-3}` (leftover 4) all score identically on
eligibility and on score - and a maximum-weight matcher may return any of
them. Ours returned `{1-5, 2-3}`, whose top-group player 3 is matched to
a 1.0 player, so the scan cleared the flag and **C9 was dead for the
entire first bracket**. Probed directly, since the process-dictionary key
is deleted before `pair_next_round/2` returns:

    PROBE bootstrap matching=[{3,2},{4,4},{5,1},{1,5},{2,3}]
          leftovers=[4] bye_score=2.0 first_single_bye?=false

The bottom field gives `{1-5, 2-3}` a count of 0 against 1 for the other
two, so bbpPairings never sees the tie. Both survivors set the flag.

### The fix

Three lines. The new term is SCALED rather than packed: multiplying
everything above it by `div(n, 2) + 1` - one more than the number of
edges a matching can hold, hence one more than the largest attainable bit
total - makes it provably a pure tiebreak, unable to overturn a
difference in the fields above and able only to decide one they leave
open. bbpPairings gets the same guarantee from bit widths, sizing the
field at `scoreGroupSizeBits` so its sum cannot carry. Packing by hand
here would have meant re-deriving band separation for the existing
multiplicative `score_places/1` encoding, which the scaling sidesteps
entirely - every previously-measured ordering is preserved exactly.

### Results

Re-pairing all 40 dumped cases in `/root/triage/` with the live engine:

| | before | after |
|---|---|---|
| reproduce the stored disagreement | 40 | 1 |
| **match bbpPairings** | **0** | **39** |

The survivor is `seed735265-r7-p10`, the one case Gacrux backs us on -
i.e. everything the triage classified as a candidate-program error is
fixed, and everything it classified as a rules-interpretation dispute is
untouched. That is the outcome the triage predicted if its own
three-way classification was sound.

`tools/adjudicate.exs` over the same 40, scoring the STORED answers:

| | before | after |
|---|---|---|
| ours scores better | 22 (C12 x19, C13 x3) | 0 |
| tie on all rungs | 17 | 0 |
| theirs scores better | 1 (C2/C4/C5) | **40 - C9 x39, C2/C4/C5 x1** |

Which is the same finding from the other side: with the gate fixed, our
own ladder now says bbpPairings' answer was the better one on C9 for all
39, where before the rung was silent on both sides and the argument
surfaced at whatever colour rung happened to differ.

**Every axis, against bbpPairings 6.0.0, exact rounds / individual
pairs. Zero illegal rounds and zero refusals on all of them.**

| axis | rounds | pairs |
|---|---|---|
| plain 4-40, 4000x9 | 33708/33708 = 100.00% | 400021/400021 = 100.00% |
| small 4-10 **no byes**, 100000x9 | 599779/599779 = 100.00% | 2434429/2434429 = 100.00% |
| small 4-10 **+15% byes**, 100000x9 | 582297/582297 = 100.00% | 2040785/2040785 = 100.00% |
| 15% byes 4-40, 4000x9 | 33601/33601 = 100.00% | 340942/340942 = 100.00% |
| 10% forfeits 4-40, 4000x9 | 33544/33544 = 100.00% | 399201/399201 = 100.00% |
| 10% byes + 10% forfeits, 4000x9 | 33715/33715 = 100.00% | 360941/360941 = 100.00% |
| deep 13 rounds 4-40, 2000x13 | 22860/22860 = 100.00% | 279818/279818 = 100.00% |
| deep 13 rounds + 15% byes, 2000x13 | 22716/22716 = 100.00% | 238034/238034 = 100.00% |
| large 60-80, 300x9 | 2700/2700 = 100.00% | 94896/94896 = 100.00% |
| large 90-120, 120x9 | 1080/1080 = 100.00% | 56700/56700 = 100.00% |
| large 60-120 + 15% byes, 200x9 | 1800/1800 = 100.00% | 69951/69951 = 100.00% |

The plain, 15%-byes and 10%-forfeits rows are bit-for-bit identical to
the totals recorded for the same axes above, which is the check that
matters most: the change is confined to a tie the old code resolved
arbitrarily.

The small-fields-with-byes row is the one that moved. That axis carried
36 of the 43 residual disagreements; the 100,000-tournament slice of it
had 3 and now has 0 over 582,297 rounds.

**The full 1,000,000-tournament corpus, re-run: 5,822,425 / 5,822,426
exact rounds, 20,416,198 / 20,416,202 pairs, zero illegal, zero
refusals.** One disagreement remains where there were 36 - the same
corpus, the same seeds. In FE1's units that is **1 per ~5.8 million
rounds** on the engine's worst axis, against a bar of 1 per 500
tournaments.

**And the survivor is `seed735265-r7-p10`** - the Gacrux-backed
rules-interpretation dispute, the same one that survived in
`/root/triage/`. Nothing else on that corpus differs from bbpPairings at
all. So the residue is no longer a defect class with a rate; it is one
named case with an argument attached, and FE1 provides for escalating
exactly that to the SPPC.

Establishing it took a second pass with `PAIRING_FUZZ_DUMP` set, and that
pass is worth recording on its own: it reported **two** disagreements,
not one, and dumped `seed133484-r2-p7` alongside - a 7-player round for
which bbpPairings had supposedly returned fifteen pairs with ranks up to
33. That is not a pairing of that tournament at all, and the harness had
already said so: `WARNING: 2 bbpPairings process error(s) - this run was
likely resource-starved`. Re-run alone, bbpPairings gives `2 7 / 3 5 /
4 6`, which is Ainalrami's answer exactly. **A saturated box can
manufacture a phantom disagreement**, the harness flags it, and the flag
is worth reading before chasing the case - the same 36-core box was
running an unrelated job at 2800% CPU throughout.

The three-way harness agrees with **both** references on both profiles -
1000x9 over 4-40 (8,402 rounds) and 2000x9 over the small-fields+byes
profile that carried the defect (11,879 rounds). bbpPairings vs Gacrux,
Ainalrami vs bbpPairings and Ainalrami vs Gacrux are all 100.0% on both.

`mix test` 86 passed (85 before, plus the new regression test).

### The methodological note

`docs/fide-criteria.md` item 4's lesson held a second time, and needs
one extension. The adjudicator reporting a rung as **0 vs 0** looks like
evidence that the rung is irrelevant, and is not: a rung switched OFF on
both sides scores zero on both sides, which is indistinguishable from a
rung with nothing to say. C9 read 0 vs 0 on all 40 cases *because it was
gated off*, and the visible C12/C13 disagreement was the first rung below
it that happened to differ - the identical failure mode that item 4
already records, one layer further down. A silent rung is not an
exonerated rung.

## `XXP` and `XXA` (2026-08-16) - the extension lines that were being discarded

`Ainalrami.Trf` parsed exactly one extension line, `XXR`. Every other `XX*`
line fell through `parse_header_line/3`'s `nil -> acc` clause and was
dropped without a word. For two of them that is not a tidiness issue:

- **`XXP`** (forbidden pairings) - an arbiter's "these two must never
  meet" was ignored, and the engine then returned a complete, perfectly
  legal-LOOKING pairing that seated them together. Nothing downstream
  could detect it. This is why the sibling project, having just wired
  Ainalrami in as an optional engine, had to **refuse to pair** whenever
  the generated TRF carried any non-`XXR` `XX` line at all.
- **`XXA`** (acceleration) - virtual points were ignored, so brackets
  formed on the wrong scores.

Both are now read, and both are ported from bbpPairings rather than
invented - `readForbiddenPairsXxp` (`trf.cpp:554-568`) and
`readPlayerAccelerationsXxa` (`trf.cpp:487-514`) for the reading,
`resolveForbiddenPairs` (`tournament.cpp:100-116`) and
`scoreWithAcceleration` (`tournament.h:335-359`) for the meaning.

### Where each one belongs

**`XXP` is an absolute criterion, not a scored term**, and the reference
settles that rather than an argument about it: `compatible`
(`dutch.cpp:39-68`) opens with
`!forbiddenPairs[player0.id].count(player1.id)` before it looks at colour
at all, and the no-rematch rule reaches that same test by being INSERTED
INTO the very same set (`dutch.cpp:653-666`). The two rules are literally
one lookup in the C++, so the port is one line in `legal_pair?/2` and
nothing anywhere else. One `XXP` line is an N-player GROUP, not a pair -
`readForbiddenPairsXxp` tokenizes the whole rest of the line - so
`XXP 4 9 17` forbids all three of 4-9, 4-17 and 9-17.

**`XXA` is folded into `:points`** for the round being paired, which is
the port rather than a shortcut. Inside `dutch.cpp` there is essentially
no other kind of score: bracket formation (680, 698-701), the bye
assignee (846, 882), the C9 gate (852-865), the bracket loop's own reads
(1114-1126, 1611-1640), bye eligibility (220), the float criteria's score
comparisons (295-457) and `compatible`'s own final-round exception (63-65)
all go through `scoreWithAcceleration`. The ONLY reads of
`scoreWithoutAcceleration` in the whole engine are in `common.cpp`'s
`sortResults` (180-206), which orders the output and is not pairing. So
the accelerated score is what `.points` means inside the engine, and the
two things that genuinely need the real score take it first: the float
history, and the caller's standings.

That second one is the subtle half. `scoreWithAcceleration(tournament,
roundsBack)` winds its round index back in step with the score it is
stripping and adds `accelerations[roundIndex]` - the virtual points that
applied AT THE TIME, not this round's. Which is exactly why JaVaFo's
manual insists the `XXA` line carry the full round-by-round record.

Round 1 now routes through the bracket cascade when either extension is
present. `pair_round_one/1` is a shortcut that assumes one score group and
decides everything by rank; acceleration breaks the first assumption and a
forbidden pair breaks the second, and bbpPairings has no round-one special
case for either to be compared against.

### Two column findings, both confirmed against the real binary

**`XXA` is fixed-column and the columns are not negotiable.**
`readPlayerAccelerationsXxa` reads the rank from `line[4]..line[8)` -
columns 5-8 - then walks `startIndex = 9; startIndex += 5` reading four
characters at each stop, i.e. columns `10 + 5*(r-1)` for round `r`. That
is the JaVaFo AUM's spec exactly. Verified end to end: an 8-player round 1
with the top four accelerated by 1.0 pairs 1-5/2-6/3-7/4-8 unaccelerated
and **1-3/2-4/5-7/6-8** accelerated, and bbpPairings and Ainalrami produce
the same answer on the same file, colours included.

**The sibling project's own `XXA` emitter is one column wide at every
field**, and real bbpPairings rejects those lines outright:

    Error parsing file ...: Invalid line "XXA     1  1.0  1.0  0.5  0.0  0.0"

exit code 3, reproduced directly against the vendored binary.
`acceleration_lines/4` in `../openpairings` right-aligns the rank in a
FIVE-column field (so it lands in columns 5-9, and bbpPairings reads four
blanks) and each value in a five-column field. Real javafo evidently
tolerates it - the sibling verified the pairing genuinely changes shape -
but it is not the spec and it is not readable by the second reference.
**This parser raises on such a line rather than quietly pairing an
unaccelerated tournament**, which is the same reasoning that put the
feature here in the first place: a silently dropped arbiter instruction is
the failure mode, so the fix must not reintroduce it one layer down.
`XXR`'s tolerant shrug stays, because a missing round count has a fallback
and a missing exclusion does not.

### Results

Both features are validated by the EXISTING oracle, because bbpPairings
implements both: `Ainalrami.Generator` and the comparison harness learned to
emit the lines (`PAIRING_FUZZ_FORBIDDEN_PCT`, `PAIRING_FUZZ_ACCEL=baku`
`|random`), the same file goes to both engines, and the diff is the same
diff every other axis uses. The harness's legality check gained
`:forbidden_pair` - the one violation that leaves a round looking correct
in every other respect (clean partition, right bye count, no rematch, and
two people who were never to meet sitting across a board).

**Every previously-measured axis is BYTE-IDENTICAL after the change.** Not
"still 100.00%" - the same numerators and denominators, all eleven:

| axis | before | after |
|---|---|---|
| plain 4-40, 4000x9 | 33708/33708, 400021/400021 | identical |
| small 4-10 no byes, 100000x9 | 599779/599779, 2434429/2434429 | identical |
| small 4-10 +15% byes, 100000x9 | 582297/582297, 2040785/2040785 | identical |
| 15% byes 4-40, 4000x9 | 33601/33601, 340942/340942 | identical |
| 10% forfeits 4-40, 4000x9 | 33544/33544, 399201/399201 | identical |
| 10% byes + 10% forfeits, 4000x9 | 33715/33715, 360941/360941 | identical |
| deep 13 rounds 4-40, 2000x13 | 22860/22860, 279818/279818 | identical |
| deep 13 rounds + 15% byes, 2000x13 | 22716/22716, 238034/238034 | identical |
| large 60-80, 300x9 | 2700/2700, 94896/94896 | identical |
| large 90-120, 120x9 | 1080/1080, 56700/56700 | identical |
| large 60-120 + 15% byes, 200x9 | 1800/1800, 69951/69951 | identical |

Zero illegal rounds and zero refusals throughout, both times. That is the
result the design predicts and the reason it was worth designing for:
without an `XXP` line the forbidden set is `nil` and `legal_pair?/2` reads
one process-dictionary key that isn't there; without an `XXA` line
`with_acceleration/2` returns the roster untouched. The change is inert
when the lines are absent, and this measures that rather than asserting it.

**The new axes, against bbpPairings 6.0.0, exact rounds / individual
pairs.** Every one at 100.00%, zero illegal rounds, zero refusals:

| axis | rounds | pairs |
|---|---|---|
| plain 4-40, 4000x9 *(control, re-run on the final code)* | 33708/33708 = 100.00% | 400021/400021 = 100.00% |
| XXP 10% 4-40, 4000x9 | 33315/33315 = 100.00% | 398444/398444 = 100.00% |
| XXP 30% 4-40, 4000x9 | 32726/32726 = 100.00% | 396048/396048 = 100.00% |
| XXA baku 4-40, 4000x9 | 33834/33834 = 100.00% | 400410/400410 = 100.00% |
| XXA random 4-40, 4000x9 | 33753/33753 = 100.00% | 400159/400159 = 100.00% |
| XXP 15% + XXA baku + 15% byes + 10% forfeits, 4000x9 | 33409/33409 = 100.00% | 340223/340223 = 100.00% |
| deep 13 rounds + XXA baku, 2000x13 | 22922/22922 = 100.00% | 279971/279971 = 100.00% |
| large 60-120 + XXP 10% + XXA baku, 200x9 | 1800/1800 = 100.00% | 82143/82143 = 100.00% |
| small 4-10 + XXP 25%, 100000x9 | 492239/492239 = 100.00% | 2010814/2010814 = 100.00% |
| small 4-10 + XXA random, 100000x9 | 601001/601001 = 100.00% | 2435952/2435952 = 100.00% |
| small 4-10 + XXP 25% + XXA baku + 15% byes, 100000x9 | 504555/504555 = 100.00% | 1791983/1791983 = 100.00% |

**1,789,554 rounds and 8,536,147 individual pairs carrying at least one
extension line, and not one disagreement.** The three small-field rows are
deliberately the ones that historically carried every residual defect this
project has found (see the triage above); half a million rounds each of
`XXP` and `XXA` on that surface is the measurement that matters most.

The `XXP` rows lose tournaments early far more often than the plain axis
does - 98,598 of 100,000 on small fields at 25%, against 78,126 with no
exclusions at all - which is the expected signature and not a failure: a
4-10 player field with a quarter of the players excluded from someone runs
out of legal opponents fast, bbpPairings says so with its own
no-valid-pairing exit, and the harness ends the tournament there. It is
also the shape that proves the exclusions are load-bearing rather than
decorative.

### How wrong the old behaviour actually was

"The line was ignored" is easy to state and easy to under-weigh, so it was
measured: same corpus, same file to bbpPairings, and Ainalrami told nothing
about the extension lines - i.e. exactly what this engine did last week.

| | compared rounds | differs from bbpPairings | seats a forbidden pair |
|---|---|---|---|
| `XXP` at 20%, 4-40, 1000x9 | 8230 | **2281 (27.72%)** | **2281 (27.72%)** |
| `XXA` baku, 4-40, 1000x9 | 8421 | **5568 (66.12%)** | - |

Two things worth reading off that. For `XXP` the two columns are the SAME
number, every round: on that axis the old engine's entire disagreement
with bbpPairings was the ignored exclusion - nothing else differed, and
every difference was a violation of an arbiter's explicit instruction, in
better than one round in four. And for `XXA`, two thirds of all rounds
were paired on the wrong scores.

Neither number was visible before, because the engine could not have known
to look: it produced a complete, legal, well-formed pairing every time.

### What is not covered

- **`260`** (round-limited forbidden pairs) and **`250`** (round-limited
  acceleration), bbpPairings' fixed-column siblings of these two
  (`trf.cpp:519-548` and `418-482`). `XXP`/`XXA` are the universal forms
  and the ones the sibling project emits; the round-range machinery
  (`ForbiddenPairsEntry`'s `roundStart`/`roundEnd`) is deliberately absent
  rather than stubbed, since `resolveForbiddenPairs` filters on a range
  that for `XXP` is always `[0, expectedRounds)`.
- **bbpPairings' own Baku flag.** `applyBakuAcceleration`
  (`trf.cpp:708-753`) sizes Group A as `ceil(n/2)` where FIDE C.04.7 as the
  sibling project reads it uses `2 * ceil(n/4)` - 5 players against 6 on a
  10-player field, agreeing exactly on the round split. That path is
  reached only through its own flag, never through `XXA`, so it cannot
  make the two engines disagree here: both read the identical `XXA` lines
  out of the identical file. The generator follows the sibling's reading
  because that is what Ainalrami will actually be handed.

## Explicitly deferred / not being pursued yet

- Any FIDE endorsement application for Ainalrami itself. It's meant to stay
  a non-default, non-homologated-tournament-only option inside
  OpenPairings, at least until (if ever) it's genuinely proven out - see
  the endorsement-risk discussion in OpenPairings' own project history.
  The error ratio is no longer the obstacle (see the triage above); what
  remains is strategic - declaring "Internal engine: YES" on FE1 means
  owning pairing correctness rather than inheriting JaVaFo's endorsement,
  with two-week/two-month mandatory fix windows attached.
- ~~A license file / open-source release.~~ **Done (2026-08-16, `f984803`)** -
  **Apache-2.0**, with a `NOTICE` naming `lib/ainalrami/pairing.ex` and
  `lib/ainalrami/weighted_matching.ex` as derived from bbpPairings and
  recording the §4(b) changes. Not really a choice: bbpPairings is
  Apache-2.0 and those two files are ports of it, so the licence is
  inherited. The repo was public. This is no longer a submission blocker. (Superseded 2026-11-01: the project was all rights reserved; superseded again: it is now FSL-1.1-ALv2, and only the bbpPairings-derived parts keep Apache terms.)

## The 2.55M-tournament run, and the blind spot it did not have (2026-08-17)

Ran the whole validation corpus again on the 36-core box, on a fresh clone,
nine axes, **2,510,600 tournaments / ~11.2M rounds / ~92M individual pairings**:

| axis | tournaments | rounds | agreement | illegal |
|---|---|---|---|---|
| 15% byes, 4-40 | 250,000 | 2,099,071 | 100.00% | 0 |
| 15% byes, 4-10 | 1,200,000 | - | 100.00% | 0 |
| 20% forbidden (`XXP`), 4-40 | 120,000 | - | 100.00% | 0 |
| Baku (`XXA`), 4-40 | 120,000 | 1,014,963 | 100.00% | 0 |
| byes + forfeits + `XXP` + `XXA` | 120,000 | 1,000,527 | 100.00% | 0 |
| plain, 4-10 | 500,000 | 2,994,942 | 100.00% | 0 |
| plain, 4-40 | 120,000 | 1,011,700 | 100.00% | 0 |
| 10% forfeits, 4-40 | 120,000 | 1,007,116 | 100.00% | 0 |
| 60-120 players | 600 | 5,400 | 100.00% | 0 |

**One disagreement in the entire corpus**, and it is `seed735265-r7-p10` -
the already-catalogued FE1 rules-interpretation dispute where Gacrux sides
with this engine. Adjudicated again with the float-history fix in place:
`theirs_scores_better` on `C2/C4/C5 bye-eligibility`, unchanged.

**The 2 wrong-bye-count / non-partition illegal rounds are closed.** The
first axis re-ran the exact configuration that produced them (seeds
1..250,000 at `PAIRING_FUZZ_BYE_PCT=15`, covering the original 1..100,000)
and found zero illegal rounds in 2,099,071. The C9-gate rewrite closed them;
nothing further to chase.

### And yet the corpus could not see a real bug

**Every axis above ran `PAIRING_FUZZ_ROUNDS=9`. Every axis this project has
ever measured ran `ROUNDS=9`.** The final round is then paired with 8 rounds
played, and `div(8, 2) == 8 / 2`. So a threshold that floors a half-point is
invisible: it can only differ when the played-round count is ODD, i.e. when
the tournament has an EVEN number of rounds.

`final_round_topscorers?/2` had exactly that. Re-measured at `ROUNDS=8`
(7 played at the final round), 2,000 tournaments, 12% byes:

| | exact rounds | individual pairs |
|---|---|---|
| before | 15051/15060 = **99.94%** | 155831/155862 = 99.98% |
| after | **15060/15060 = 100.00%** | **155862/155862 = 100.00%** |

Nine wrong rounds that 2.55M tournaments at `ROUNDS=9` could not produce.
Six-, eight- and ten-round Swisses are ordinary events; this was never an
exotic corner.

**Lesson worth keeping**: corpus SIZE bought nothing here. The axes varied
field size, bye rate, forfeit rate and extension lines, and held the one
parameter fixed that this bug was a function of. When adding an axis, ask
what the existing ones hold CONSTANT, not what they vary.

`PAIRING_FUZZ_ROUNDS` is now a first-class axis: run even and odd.

### The even-round axis, measured (2026-08-17)

Run on the fix, varying the parameter the whole previous corpus held
constant. **1,800,000 tournaments / 12,276,248 rounds / 102,985,278
individual pairings.**

| axis | rounds | tournaments | agreement | illegal |
|---|---|---|---|---|
| 15% byes, 4-40 | **8** | 250,000 | 100.00% | 0 |
| 15% byes, 4-40 | **6** | 250,000 | 100.00% | 0 |
| 15% byes, 4-40 | **10** | 150,000 | 100.00% | 0 |
| plain, 4-40 | **8** | 200,000 | 100.00% | 0 |
| 15% byes, 4-10 | **8** | 600,000 | 100.00% | 0 |
| 15% byes, 4-40 (control) | 9 | 150,000 | 100.00% | 0 |
| 15% byes, 4-40 (control) | 7 | 200,000 | 100.00% | 0 |

**Zero disagreements on any axis, even or odd.** The odd controls are the
point: had 7 and 9 also moved, the fix would have been wrong in a way the
2,000-tournament local run could not show. They did not.

Combined with the run earlier the same day, the engine now stands at
**~4.3M tournaments and ~195M individual pairings against bbpPairings, with
exactly one disagreement** - `seed735265-r7-p10`, the rules-interpretation
dispute where Gacrux sides with this engine. In FE1's units (1 difference
per 500 tournaments allowed) that is **1 per ~4.3 million**, four orders of
magnitude inside the bar.

## Removed: the bye-count repair and Ainalrami.Blossom (2026-08-17)

Recorded because deleting a tested 233-line matcher deserves an explanation,
and because git is the recovery path if this reasoning is ever found wrong.

`repair_bye_count/3` sat on the output of `global_cascade/2`, guarded by
`bye_legal?/3`. `global_cascade/2` returns `{:ok, pairs, leftover}` **only
after `check_completion/3` has passed** on exactly those pairs and that
leftover - bye count, C2 eligibility and the C5 bye score. `bye_legal?/3`
restated two of those three tests over the same set, so it was true whenever
it was reached, so the repair branch could not execute. `Ainalrami.Blossom`'s
only non-test caller was inside it.

The sweep found this as "a predicate implied by its own parent". Unifying
`bye_legal?/3` to delegate to `check_completion/3` made it literal: the
guard became the same function call that had already returned `:ok`.

Two further reasons not to keep it as insurance:

- **The dead path was wrong.** `to_pairs/2` assigned colours by rank alone,
  with no `assign_colour_with_history/1` - so if `check_completion/3` were
  ever relaxed, the "safety net" would have emitted a whole round with
  colours decided by seeding, bypassing Article 5.2. Insurance that would
  itself produce an illegal round is not insurance.
- **The project's own principle.** "Insurance nothing has exercised is a
  guess" (TODO.md, on `repair_completion/3`, which IS fault-injected via
  `AINALRAMI_FORCE_STRAND=1`). That standard was applied to one repair path
  and not to this one.

`repair_completion/3` - the whole-field maximum-weight matching inside
`global_cascade/2` - is untouched and remains the real completion fallback.
It is reached, it is tested, and it is fault-injected.

Removed: ~152 lines from `pairing.ex` (`repair_bye_count/3`, `bye_legal?/3`,
`to_pairs/2`, `add_reverse_edges/1`, `bye_ranks/1`, the stamping helpers),
`lib/ainalrami/blossom.ex` (233 lines) and `test/ainalrami/blossom_test.exs`.
Validated after removal on four axes (rounds 6/8/9, byes, forfeits, `XXP`,
`XXA`): 100.00% of rounds and pairs, zero illegal.

## Open


- ~~**`explain_round/3` never stamps float history.**~~ **Fixed.** The real
  path calls `with_float_history/2` before `with_acceleration/2`, over the
  whole roster (`pair_later_round/1`); the diagnostic stamped acceleration
  and colour stats only. `float_of/2` therefore read `:none` for every
  player in every position, so **C14-C21 scored a constant on both sides of
  every verdict `tools/adjudicate.exs` has ever printed** - C14/C16 pinned
  at zero, C15/C17 at one per in-bracket pair.

  It could not invent a disagreement (both sides were scored with the same
  blank history, so a tie stayed a tie); it could only MISATTRIBUTE one, by
  reporting a round genuinely decided on a float rung as tying there and
  differing further down. `explain_round/3` had no test of any kind until
  `test/ainalrami/explain_round_test.exs`, which is how this survived; both
  of its cases fail on the pre-fix code.

  **The adjudication tables above were produced with the blank history and
  have not been re-run.** They are not wrong about WHETHER the engines
  differed - that comes from the harness, not the scorer - but the "first
  differing rung" column is only trustworthy where the winning rung
  outranks C14. Anything the tables attribute to C14-C21 is unverified, and
  a case attributed to a rung BELOW them could really have been decided
  above. Re-running needs a fresh large fuzz, since the dumps were never
  kept.
- **`seed735265-r7-p10`** - the one surviving disagreement, and the only
  case in this project's history where Gacrux backs Ainalrami against
  bbpPairings. FE1 category 3 (rules-interpretation dispute), which FE1
  explicitly provides for escalating to the SPPC rather than "fixing".
  Needs a written-up position before it can be escalated.

  Now kept as `test/fixtures/fe1_disputes/seed735265-r7-p10.trf` with its
  own README, and re-adjudicated after the float-history fix: the verdict
  is **unchanged** (`theirs_scores_better`, first differing rung `C2/C4/C5
  bye-eligibility`). That rung outranks C14-C21, so the fix could not have
  reached it - recorded so nobody re-runs it expecting a change.
- ~~**The 2 wrong-bye-count / non-partition illegal cases**~~ **closed** by
  the 2026-08-17 run above: the original configuration re-run over 250,000
  tournaments / 2,099,071 rounds produced zero illegal rounds.
- ~~**Even-round validation at scale.**~~ **Done** - 1,800,000 tournaments
  across rounds 6/7/8/9/10, zero disagreements, table above.

Reproducing any dumped case is now cheap: `PAIRING_FUZZ_SEED_FROM` starts
the seed range anywhere, and every seed is independent, so
`seed735265-r7-p10` regenerates in about a second instead of requiring the
735,264 tournaments before it. That knob not existing is a large part of
why the catalogued cases were adjudicated once and never revisited.

## Matcher performance, 2026-08-18: what worked and what did not

One day, one 209-player round, warm medians of three. From 90 s to 10.6 s.

| change | 209 players | note |
|---|---|---|
| start of day | 90 s | |
| hoisting, adjacency map, GCD reduction | 38 s | constant factors |
| per-vertex delta-scan caches | 38 s | correct; moved the cost rather than removing it |
| persistent matcher across a bracket's eight stages | 24.6 s | `set_weight/4` + `solve/1`, bbpPairings' `Computer` API |
| **prepare only the modified end** | **13.3 s** | one misread argument: `setEdgeWeight(modifiedVertex, neighbor)` prepares the FIRST only; preparing both tore the whole matching down on every `finalize_pair` |
| per-blossom-pair cross table + running minimum | 10.6 s | bbpPairings' `minOuterEdges`; formation becomes a merge, not a rescan |
| field-wide weight bands | 10.6 s | no speed change; a precondition, and aligns the engine with `explain_round/3` |

**Tried and reverted, with the reason**, so nobody repeats them:

- *Starting fresh when >50% of vertices changed* (24.6 → 27 s). A
  mostly-torn matching still keeps some pairs and all its duals, and
  re-augmenting from that beats an empty state. Reuse unconditionally.
- *Nested per-blossom rows for the cross table* (12.4 → 15 s). Two nested
  `Map.update!`s per outer neighbour; `settle_outer_vertex` went from 21 to
  54 µs. Flat `{lo, hi}` keys instead.
- *Packed integer keys instead of tuple keys* (0.95×, no difference). The
  cost of a losing offer is the map lookup, not the key.
- *`:atomics` for the inner loop* - measured 2.96× on an isolated
  micro-benchmark of the access pattern, then tried for real on
  `in_blossom` alone (the most-read small-int map): correct on both nets
  and **2.5× SLOWER** (395 → 1015 ms on the real 209 solve). The
  micro-benchmark held the array ref in a local; in the module every read
  is a map field access plus a NIF dispatch plus a `v + 1`, and a BEAM map
  on a few hundred small-int keys is a shallow HAMT that beats that. The
  bookkeeping is already at the BEAM's native floor. Closed.
- *One matcher for the whole round, carried across brackets* (10.6 →
  11.9 s). Correct - corpus 100% once the ceiling was a true upper bound -
  but `base_edge_weights` is recomputed per bracket with different
  `sgb`/`nsgb`, so an edge that was "next bracket" becomes "current" and
  its C6/C7/C8 values change: ~20,000 of 21,000 edges differ at every
  boundary, every vertex gets prepared, and it is a cold solve plus 20,000
  `set_weight` calls. The premise ("a boundary is a small edge diff") was
  wrong, and the reference has the same property - it recomputes
  `baseEdgeWeights` per bracket too, and simply solves fast enough not to
  care.

Against bbpPairings on the same 209-player file: 0.68 s. The remaining 15×
is, by measurement, BEAM map bookkeeping against C++ in-place arrays on
the same algorithm - bignum arithmetic is 3% of a solve. Profiled at the
end of the day: `settle_outer_vertex` 52% (165,000 calls, most from
`rebuild_caches` at stage start on the ~7 cold bracket-boundary solves),
`rebuild_caches` itself 36%, the running-minimum `min_outer_outer` now
under 2%.

### Where the matcher work stopped, and why (2026-08-18, evening)

The loop converged. Final profile of a 209-player round, 9.5 s: no single
item above 36%, every remaining item doing work the reference also does
(`carry_caches` rebuilding inner-outer resistances per stage is
`initializeInnerOuterEdges`; the cold solve at each bracket boundary is a
cold solve there too; `finalizePair` zeroes whole rows in both). Measured
by reach: at a 205-vertex bracket the refinement stages change 3,020
edges, 2,620 of them beyond the current+next window - that is
`finalize_pair`'s row-zeroing, identical to `common.h`'s `finalizePair`,
and it is why a round-level matcher saw 20,000 changed edges per boundary.

Three data-structure swaps were measured on the real solve and all lost:
tuples for maps (0.85×), packed integer keys (0.95×), `:atomics` for the
most-read small-int map (0.39× - correct, and 2.5× SLOWER; the NIF
dispatch per read costs more than a shallow HAMT lookup). BEAM maps on a
few hundred small-int keys are the floor.

So the remaining 14× at 209 and 24× at 400 is the per-operation gap
between a BEAM map lookup and a C array index, on the same algorithm with
the same number of operations. That is not a guess this time; it is what
is left after every other explanation was measured away.

What *would* move it, in order of plausibility, none of them tried:

- **Fewer solves per bracket.** Eight refinement stages, each a solve;
  the reference runs the same eight. Whether any stage's solve can be
  skipped when its stage changed nothing is a question about the cascade,
  not the matcher, and was not examined today.
- **Window-sized graphs.** The reference's `playersByIndex` is the
  current bracket plus the next group; its out-of-window edges exist from
  the bootstrap but are never rewritten. Ours rewrites every bracket via
  `base_edge_weights`. The unbounded peek was what took the cascade from
  95.97% to 100% (see above), so narrowing it is a correctness question
  first and a speed question second.
- **A native matcher.** Ruled out by the project owner; recorded only as
  the thing that would close the gap outright.

## Matcher performance, 2026-08-19: the gap was structural after all

Yesterday's closing note said the remaining 14x at 209 players and 24x at
400 was "the per-operation gap between a BEAM map lookup and a C array
index, on the same algorithm with the same number of operations", and
that it was measured rather than guessed. It was measured; the
conclusion was still wrong. The operations were not the same number.
Today, one 209-player round went 9.2 s -> 1.24 s and one 400-player round
69.8 s -> 4.5 s, every step held to 100.00% on all six corpus axes and
both differential nets, and 200 of 200 boards at 400 players still
identical to bbpPairings. Warm medians of three.

| change | 209 | 400 | what was actually wrong |
|---|---|---|---|
| start of day | 9.2 s | 69.8 s | |
| one matcher per round, but the transposition `scale` per bracket | 10.9 s | -- | every weight multiplied by a per-bracket factor, so every edge changed at every boundary -- the same failure as yesterday's attempt, one level down |
| transposition tie-break off by default | 8.0 s | 56.8 s | inert for the pairing (measured again: identical), and a 46-digit factor in every comparison |
| **prepare the MODIFIED vertex** (`set_live/4`, dirty list) | **4.4 s** | **26.6 s** | the whole-map diff prepared the lower-indexed end of each changed edge; `finalize_pair` then prepared every earlier vertex the pair still touched -- 10.7 stages per in-bracket solve where `computer.cpp:69` says O(k n^2) for k modified vertices, and k is three |
| offer from the outer side at stage start | 3.9 s | -- | 136,000 row walks per round for what three outer vertices could deliver |
| **greedy start** (`greedy_start/3`) | **2.6 s** | **14.8 s** | a cold solve matched one heaviest edge per stage for 106 stages; duals at each vertex's heaviest edge and a greedy tight matching start it at seven exposed vertices |
| bootstrap duals (`new/3 duals:`) | 2.06 s | n/a (even field) | the bye bootstrap's weights are per-vertex sums, so "mutually heaviest" matched nothing; per-vertex duals make every compatible edge tight |
| cross table as rows (`cross_merge` O(children x k)) | 1.99 s | 14.05 s | formation rebuilt a k^2 table: 9,877 times a round at 400 |
| score only the window per bracket | 1.9 s | 13.3 s | every bracket rescored all m^2/2 pairs and diffed them again; bbpPairings scores `playersByIndex` and sets far edges once |
| **nearness term below every criterion** | **1.7 s** | **8.0 s** | thousands of equal far edges were all TIGHT at the optimum; each stage's forest grew across the whole field before it could augment -- growths 23,470 -> 13,405, formations 9,142 -> 4,525 |
| cached sorted top list, settle-loop trim | 1.37 s | 6.8 s | two or three sorts per delta step; resistance computed for neighbours that took no offer |
| **greedy resume** (`greedy_resume/1`) | **1.24 s** | **4.5 s** | the same tight start for a RESUMED solve: at a boundary every resident is prepared and their heaviest edges are to each other, so they pair before a stage runs; boundary solves were a third of the round |
| **end of day** | **1.24 s** | **4.5 s** | bbpPairings: 0.67 s / 2.9 s -- **1.9x and 1.5x**, from 14x and 24x |

Things learned, each the reverse of something believed yesterday:

- **"Nested rows lose to a flat map"** (yesterday, 12.4 -> 15 s) was true
  when `cross_merge` was not on the profile. Once the k^2 rebuild per
  formation was the largest item at 400 players, the same rows won by
  4.7 s. The measurement was right and local; the conclusion was global.
- **"The round-level matcher sees 20,000 changed edges per boundary"**
  was the transposition scale, not the bracket structure. With far edges
  frozen and the scale gone, a boundary changes the window's clique and
  its edges into the next group -- 1-28% -- exactly as the premise said.
- **"The tie structure does not matter"** is true for the pairing and
  false for the search. The far edges all tie on purpose (completability
  only), and at the optimum every one of them is tight, so the
  alternating forest of every stage spans the field. A canonical term
  below every criterion and every stage addend -- nearness in field
  position, scaled by n^2 + 1 so no sum of it can reach one unit above --
  leaves the optimum nearly unique and the forest local. Nearness rather
  than any other term because the greedy start matches mutually-heaviest
  pairs, and nearest neighbours are mutual.
- **The :atomics spike was committed**, not reverted, alongside the note
  saying it was 2.5x slower. Measured on a full round the two are equal
  (8.0 / 8.2 s); the pure map version is back because it has no
  mutable-array hazard against the persistent state, not because it is
  faster.
- **bbpPairings' matcher IS whole-field.** `matchingComputer(sortedPlayers
  .size())` is built once per round with completability weights on every
  pair (dutch.cpp:740-816), the bootstrap matching is solved on it, and
  each bracket `setEdgeWeight`s only `playersByIndex`. Yesterday's note
  had it as a bracket-sized graph. The window/far split above is that
  design exactly; the greedy start and the nearness term are the two
  places this engine now does LESS work than the reference.

What is left at 400 players (4.5 s, profile before the greedy resume: 6.8 s): tree growth 2.1 s (13,405
events, one O(V) row walk each -- `updateInnerOuterEdges` in the
reference), the per-stage inner-outer rebuild 1.2 s (O(non-outer x
outer), `initializeInnerOuterEdges`), formation 0.7 s, and about 1 s
outside the matcher. All of it is work the reference does too, and the
per-operation ratio on it is now 1.5-2x, which is the BEAM against C++
on bignums of 450 bits -- the weights are that wide because six rungs
carry a score-place digit with a 50-bit span, and bbpPairings' are just
as wide (it sizes `edge_weight` to the field). Fewer solves per bracket
was re-examined and is closed: one of 124 solves changed nothing.

Not tried, and the only things left that would move it: narrower weights
(the six place-span rungs are 300 of the 450 bits; whether any two can
share a band is a question about the criteria, not the matcher), and
carrying the alternating forest across stages instead of relabelling,
which is a different algorithm from the reference's.

## 1,000 players, and why the graph cannot shrink (2026-08-19)

Measured, not extrapolated. bbpPairings' own generator built a
1,000-player, 5-round tournament (that generation took 229 s, because it
pairs with its own engine); all three implementations then paired round 6
of it on the same machine, and all three returned the **identical 500
boards**:

| 1,000 players, round 6 | time |
|---|---|
| Gacrux (`pairingchecker.py`, Python + networkx) | **5.1 s** (0.6 s of that is interpreter + networkx import) |
| bbpPairings 6.0.0 (C++) | **50.1 s** |
| Ainalrami | **85.5 s** |

The Python engine beats both C++ and BEAM by an order of magnitude, and
not because Python is fast. Its verbose log shows why: on the 400- and
1,000-player files every large bracket is answered by its `BI` path in
"0.00 s". That path (`pair_simple_round` / `simple_permute`) walks
Article 3's transposition procedure directly -- natural S1-S2 pairing,
then permutations of S2 in lexicographic order -- and accepts the first
candidate that is legal AND meets a counting bound on the colour
criteria (`analysis_colordiff`'s `c12`/`c13`), with completability read
off a precomputed per-score-level table. It falls back to a weighted
matching (networkx, bracket-sized) only where that fails, and its own
comment says that path gets slow past 500 players. bbpPairings and this
engine run the full matcher on every bracket regardless, which is n^3-ish
per round; the language buys bbpPairings 1.7x over us and nothing more.

### The window graph: 2.8x, and not faithful

Where our 85 s goes, profiled: ten bracket boundaries cost 49 s and the
in-bracket stages 26 s, and about 60 s of the whole round is row walks
over 1,000-wide rows. Round 6 of a 1,000-player event has score groups of
120-220, so a boundary re-prepares ~400 vertices and each of its ~200
augmentations walks the entire field.

So the graph was cut down to the WINDOW -- the bracket plus the next score
group, `dutch.cpp`'s `playersByIndex` -- with the far part replaced by a
sparse maximum-cardinality oracle. The argument for it is sound as far as
it goes: a far edge scores only the completion rung and C9
(`edge_rungs/6` gates everything else on `in_current` or `reach == 1`),
both of which are sums of PER-VERTEX terms, so a far edge is worth
`P + g(a) + g(b)` and every perfect matching of the far part scores
identically. The far part is a cardinality constraint, not a weighted one.
Three things followed and all of them were needed:

* **The marginal weight.** On the window graph the completion rung counts
  WINDOW edges, so a four-player bracket over a two-player group scored
  three window pairs above two and pulled both members of the lower group
  up rather than pairing the bracket and letting them float. The fix is
  exact and pretty: subtract from every window edge what the same pair
  would score as a far edge, `ladder(i,j) - far(i,j)`. If `i` and `j` each
  float out to some `u1`, `u2`, those pairs are worth
  `2P + g(i) + g(j) + g(u1) + g(u2)`; pairing `i` with `j` leaves `u1` and
  `u2` to each other for `P + g(u1) + g(u2)`; the difference is exactly
  that subtraction, and every term about the far part cancels.
* **The bye.** The cancellation is exact only while everyone is matched.
  An odd field has one player who never is, and their terms are the whole
  of C9 and half the completion rung -- so the window path had to be
  refused whenever the bye could be inside the window (`bye_score` is
  absolute, so a window scoring entirely above it cannot hold the bye).
  Without that, `top-score-group-tiebreak.trf` byes the player who sat a
  round out instead of the one who played them all.
* **The tentative matching.** `carried_partner_scores` (dutch.cpp:1636)
  wants the score of whoever the WHOLE-FIELD tentative matching had each
  carried player with, and the window has no opinion about anyone below
  it; that came off the oracle instead. And the completion criterion is a
  statement about the whole-field matching, so the oracle had to verify
  the window's ENTIRE tentative matching, not just the pairs the bracket
  finalises -- `seed15-r6-p16` pairs one bracket pair and sends both
  remaining bracket players into the next group, which scores higher on C8
  than the reference answer and leaves the bottom four unable to pair at
  all, while the finalised pair alone looks perfectly completable.

Result: **400 players 5.97 s -> 1.84 s, 1,000 players 76.7 s -> 27.6 s**,
a 2.8-3.2x that would have put a 1,000-player round inside half a minute.
And the corpus went to 99.34%.

It was not shipped. The last mechanism was chased with a decisive
experiment rather than another guess: the oracle's degree was raised from
12 to 40 to 400 -- dense, every legal edge present -- and the rate did not
move, **99.34% at all three**. So the residue is not the oracle failing to
see a matching; it is the window truncation itself, and the criteria
depend on the far part in ways a cardinality oracle cannot express. That
is the same finding the peek measurement made from the other side
(PEEK=0 94.52%, PEEK=1 99.33%, unbounded 100.00%) -- note that 99.33% and
this 99.34% are the same number, which is what a bracket-plus-next-group
window costs however it is dressed up.

**The whole-field graph is load-bearing, which is what bbpPairings'
design says too**: it builds `matchingComputer(sortedPlayers.size())` once
per round with completability weights on every pair and only ever
`setEdgeWeight`s `playersByIndex`. The window is the part it SCORES, not
the part it SOLVES.

The experiment is kept out of the tree. Reverted at 85.5 s and 100.00%,
which is the trade this project makes every time.

### What would actually close the gap

Gacrux's answer, done rigorously: for a bracket the tentative matching
already pairs internally, every rung except the four colour criteria is a
constant over perfect internal matchings (checked term by term:
completion, C6, C7, C9, C14-C17 are sums of per-vertex terms, C8 and
C18-C21 are zero for a non-crossing pair), so the answer is the
lexicographically-first Article 3 candidate that attains the colour
optimum. `Ainalrami.Sequence` already generates that order and is already
tested against the engine. That is a second pairing path with its own
correctness burden, and the corpus -- which now runs 60-120 players at
12 tournaments/s -- is the only thing that could license it.

## The local graph (2026-08-19, evening): faster than the C++ reference

The window experiment above failed because it asked the window to decide
things the far part has a say in -- who the next group pairs with, who
floats deeper. The fix was to ask less. A bracket's own graph decides only
the bracket's own pairs, and there is a clean argument for when that is
exactly what the whole-field graph would have decided (`pair_bracket/6`):

1. Every member of the window is a non-candidate for the bye. Then the
   completion rung's per-vertex terms are the same for every bracket
   member, `c9_rank/3` is zero for all of them, and `bracket_loop/6`'s C9
   gate for the next bracket cannot fire -- the three places the far part
   and the bye reached into a bracket's scoring.
2. The bracket has a perfect internal matching on legal edges, and the
   rest of the field can be paired without it. Then every ladder-optimal
   matching pairs the bracket internally: the completion rung is maximal
   with it internal (by 2), and C6 -- pairs inside the bracket, which
   outranks everything below it -- is maximal ONLY with it internal.
3. An internal bracket shares no edge with the rest, so the optimum
   splits, and the bracket's part is the optimum over the bracket's own
   edges with the bracket's own weights. The eight stages only add to
   bracket-internal edges, in the reserve band below every rung, so none
   of them breaks 2, and each stage's optimum is again the local one.

(2)'s first half is what the local graph's own first solve establishes --
the completion rung is the top rung, so its maximum-weight matching is
perfect or nothing. Its second half is `oracle_completable?/2`: a sparse
maximum-cardinality matching over the whole field with the bracket taken
out, weighted `B + K*noncand + nearness` so that maximum weight is maximum
cardinality, then most non-candidates matched -- the shape of the
completion rung -- then nearest. Sound in the direction that matters: a
matching it finds is real, and a matching it misses (twelve nearest legal
opponents per player) costs one bracket a fall back to the field graph.

An odd bracket floats one member, and who floats is decided jointly with
the field below. It gets a stand-in vertex for the next score group
(`stand_in_edges/8`): the float edge (F, G) scores the completion rung,
C8 and C8's score term and nothing else -- every other rung is gated on
`in_current` -- so its weight depends on F alone; and if every F has the
same G to choose from, the rest's value once G is gone is the same
constant whichever F floats, so F is decided by the bracket's internal
optimum without F plus F's own float weight, which is the local graph
with the stand-in. The first condition was tried literally (every F legal
with every G) and never held -- a 121-player bracket over a 171-player
group had 70 illegal pairs of 20,691 -- so it is `floats_placeable?/3`:
every F has SOME legal partner in the group, and the group is at least
`@local_min_next_group` (16) strong, which is the one condition in the
whole path that is not certified term by term. Dense groups are not
fragile -- taking any one member out leaves the same matching number and
the same room below -- and brackets over smaller groups are cheap on the
field graph anyway, since the field below them is small. The small-field
corpus axes put every bracket on the field graph; the 60-120 and 150-250
axes put the large ones here; the 5M run was restarted on the final
engine to judge it.

Two more things went in the same evening, both below every rung:

* the nearness term between two bracket members now prefers a distance
  of half the bracket (`natural_gap/3`), where Article 3.3 puts S1[i]
  against S2[i] and where stages 4 and 8 push the matching anyway;
* `state.min_outer` is tracked as `{dual + shift_outer, vertex}`, which is
  invariant under delta steps, instead of scanned on every one.

| players | bbpPairings | Gacrux | before (08-19 noon) | after |
|---|---|---|---|---|
| 209 | 0.72 s | 0.88 s | 1.24 s | **0.37 s** |
| 400 | 3.05 s | 1.22 s | 4.5 s | **1.33 s** |
| 1,000 | 50.1 s | 5.1 s | 85.5 s | **7.3 s** |

Every step at 100.00% on seven corpus axes and both nets; 105/105,
200/200 and 500/500 boards identical to bbpPairings on the three files.
At 1,000 players the nine brackets the local graph takes cost 9 ms to
3.1 s each; the two bye-level brackets at the bottom go to the field
graph and cost 60 ms between them, because the field below them is small.

What is left at 1,000 players (7.3 s, profiled): the cold solve of each
bracket's own graph (489 stages, 2.3 s -- the greedy start pairs the
mutually-heaviest half and the rest augments), the stage-4 re-solve
(372 stages, 2.7 s -- every remainder pair's weight is rewritten, so
every remainder vertex is prepared, and the matching is rediscovered),
and the stage-8 per-pair solves (482 of them, 1.9 s). All of it is on
200-vertex graphs now, and all of it is what the reference does on a
1,000-vertex one.

Tried and reverted the same evening, so nobody repeats them: choosing
between carrying the caches and rebuilding them by size (slower, 7.7 ->
9.3 s; the rebuild's per-vertex settle costs more than the estimate);
running the greedy resume in descending index order or over every
exposed vertex rather than the prepared ones (no change).

### Stage 4 by dual shift (2026-08-19, late)

The stage-4 re-solve above (372 stages, 2.7 s at 1,000) is now mostly
gone: when the stage-3 matching already pairs first half against second
half, the per-smaller-member addend is absorbed by raising each
first-half dual by its own addend (`WeightedMatching.shift_and_set/3`),
nothing is unmatched, and the solve has nothing to do. Two things were
learned on the way, both recorded in the code:

* Skipping the solve outright, on the argument that the matching is
  already optimal, is NOT exact -- it is optimal, but among exact ties
  bbpPairings' `setEdgeWeight`-everything-then-`computeMatching` lands
  on a particular one, the prepare-everything path here lands on the
  same one (that is part of what the 100% measures), and keeping the old
  matching lands on another. The dual shift keeps the matching AND the
  duals, so the subsequent searches start from the same place the
  reference's do.
* `dissolve_one/3` is valid only when the base is unmatched next. It
  pushes half the blossom dual into every vertex, which keeps internal
  edges tight and puts that half onto the base's external match.
  `prepare_vertex/2` removes that match a moment later; `shift_and_set/3`
  does not, and a state that passed every local check broke the next
  real search (60-120 players: 98.33%). It now refuses when a touched
  vertex is inside a blossom, and the bracket takes the old path.

1,000 players 7.3 s -> 6.8 s; corpus 100.00% on seven axes. The 5M run
was restarted on this engine (b185abc) at 19:30 UTC.

### Measuring it fairly (2026-08-19, correction)

The table in the local-graph section above compared bbpPairings and
Gacrux as COLD PROCESSES against this engine measured WARM and
in-process, which flatters us by exactly one BEAM start-up and is not a
comparison. Corrected, by measuring each engine's own floor on a
ten-player file and subtracting it:

| | start-up | 209 | 400 | 1,000 |
|---|---|---|---|---|
| bbpPairings | 0.18 s | 0.72 s | 3.05 s | 50.1 s |
| Gacrux | 0.68 s | 0.88 s | 1.22 s | 5.14 s |
| Ainalrami (CLI) | 0.63 s | 1.05 s | 2.07 s | 7.35 s |

Pairing work alone: bbpPairings 0.54 / 2.87 / 49.9 s, Gacrux 0.20 /
0.54 / 4.46 s, this engine 0.42 / 1.43 / 6.72 s.

So: **faster than the C++ reference (1.3x, 2x, 7.4x) and slower than the
Python one (2.1x, 2.7x, 1.5x)**, and a cold 209-player invocation loses
to bbpPairings outright on start-up. The gap to Gacrux narrows with field
size, which is what the local graph predicts -- it is the small brackets,
where the local path's preconditions fail and the whole field is small
enough not to matter, that still run the full matcher.

Worth keeping in view: the widest remaining gap is at 400 players
(2.7x), not at 1,000 (1.5x). And 0.63 s of every CLI invocation is BEAM
start-up, which a long-lived process pays once -- a packaging question,
not an engine one.

### The bracket that was solving the whole field for nothing (2026-08-19, last)

Profiling 400 players after the local graph: 1,334 ms total, of which the
matcher accounted for 427 ms. The other two thirds were one bracket --
the first, a lone 4.0-point leader -- taking 660 ms and returning **zero
pairs**. `collect_bracket/1` records a pair only when both ends are
inside the bracket, so a bracket of one member can never finalise
anything; the solve existed entirely for its tentative matching, on the
whole 400-vertex field, and the only consumer of that matching is
`carried_partner_scores` feeding `bracket_loop/6`'s C9 gate. That gate
opens with `ctx.odd_field?`, and 400 is even, so the answer was
unobservable.

`idle_bracket?/4` skips it when the gate's own preconditions
(`c9_gate_live?/4`, the four conjuncts of `next_single_bye?` that do not
depend on the matching) do not hold. A lone leader is a common shape and
it is always the FIRST bracket, which is exactly when the field graph is
at its largest.

| | 209 | 400 | 1,000 |
|---|---|---|---|
| before | 0.39 s | 1.35 s | 6.8 s |
| after | **0.23 s** | **0.72 s** | **6.45 s** |

Against Gacrux's pairing work (0.20 / 0.54 / 4.46 s) that is 1.15x, 1.3x
and 1.45x. Against bbpPairings' (0.54 / 2.87 / 49.9 s), 2.3x, 4x and
7.7x the other way. A corpus axis with a fixed odd field was added,
because the skip's guard turns on `odd_field?` and every existing axis
mixes parities.

## The cross-axis run (2026-08-23)

**25 axes / 35,436,044 rounds / 474,685,328 individual pairings / 9.7 hours.
Zero disagreements. Zero illegal rounds.** Engine v0.10.0 (e3ae30a).

The round sweep earlier the same day closed the round count and named its
own gap in the same breath: it held forfeits, forbidden pairs,
acceleration, initial colour, numeric extensions and field size constant
while varying only rounds. That is the exact shape of the bug that started
all this - a corpus varying a great deal while holding still the one
parameter the defect was a function of.

So every axis here is <something previously fixed> x <round count>, at
three counts chosen for shape: **4** (short and EVEN, the parity that hid
`final_round_topscorers?/2`), **9** (the historical default, as a control)
and **16** (deeper than anything measured before this week).

Three axes run everything at once - byes, forfeits, forbidden pairs, random
acceleration and Black-first together - because a bug needing three
conditions simultaneously appears on no single-parameter axis.

| axis | rounds | individual pairings | agreement |
|---|---|---|---|
| `forfeit-r4` | 1,598,287 | 18,778,447 | 100.00% |

| `forfeit-r9` | 1,978,408 | 25,718,415 | 100.00% |

| `forfeit-r16` | 1,987,334 | 29,346,916 | 100.00% |

| `forbidden-r4` | 1,595,378 | 18,766,085 | 100.00% |

| `forbidden-r9` | 1,979,853 | 25,752,483 | 100.00% |

| `forbidden-r16` | 1,996,740 | 29,419,953 | 100.00% |

| `baku-r4` | 1,595,529 | 18,782,959 | 100.00% |

| `baku-r9` | 1,979,993 | 25,733,829 | 100.00% |

| `baku-r16` | 1,998,711 | 29,461,263 | 100.00% |

| `randaccel-r4` | 1,596,489 | 18,787,951 | 100.00% |

| `randaccel-r9` | 1,979,997 | 25,719,246 | 100.00% |

| `randaccel-r16` | 1,998,594 | 29,489,842 | 100.00% |

| `black-r4` | 1,595,475 | 18,770,241 | 100.00% |

| `black-r9` | 1,979,997 | 25,758,882 | 100.00% |

| `black-r16` | 1,998,690 | 29,457,792 | 100.00% |

| `numeric-r4` | 1,196,407 | 14,084,109 | 100.00% |

| `numeric-r9` | 1,529,850 | 19,868,382 | 100.00% |

| `kitchensink-r4` | 1,198,893 | 12,037,418 | 100.00% |

| `kitchensink-r9` | 1,529,208 | 16,969,773 | 100.00% |

| `kitchensink-r16` | 1,599,611 | 20,134,813 | 100.00% |

| `big60-r4` | 120,000 | 4,613,804 | 100.00% |

| `big60-r9` | 180,000 | 6,914,780 | 100.00% |

| `big60-r16` | 192,000 | 7,391,030 | 100.00% |

| `big150-r9` | 27,000 | 2,312,182 | 100.00% |

| `big300-r9` | 3,600 | 614,733 | 100.00% |

The one worth naming: **`black-*`**. Article 5.2.5 is the only place this
engine parts from JaVaFo, it turns on the initial colour, and every corpus
before this had drawn White. Three axes of it, 4/9/16 rounds, clean.

**Corrected 2026-08-27.** It no longer parts from anything: the SPP ruled
that 5.2.5's parity is taken on a numbering that skips players who have
never been paired, and the engine now does that (see the 2026-08-27 entry
at the top of this file). The axis itself is untouched and was always worth
running - it is about which colour the draw hands out, not about which
number the parity is taken on - but the reason given here for naming it was
the reading that lost.

### Cumulative

With the round sweep and the 2026-08-20 run, the engine now stands at
**1.16 billion individual pairings against bbpPairings across 95 million
rounds, with two disagreements** - both the bbpPairings C2 second-bye
defect, both answered this engine's way by Gacrux.

### Still held constant, and worth saying out loud

`initial_roster/1` draws `fide_rating` uniformly from 1000..2800. So every
player in every corpus this project has ever run is RATED, and rating ties
are rare and incidental. Real chess is the opposite: unrated juniors on 0,
and whole club fields clustered on a handful of rounded ratings. Equal
ratings put the initial ranking on a different tiebreak path entirely, and
two engines disagreeing there would disagree about every pairing that
follows. That is the next axis.

## The round-count sweep, R=1..20 (2026-08-23)

**10,793,215 tournaments / 59,966,505 rounds / 684,901,202 individual
pairings / 20 axes / 12.5 hours on the 36-core box. Zero disagreements.
Zero illegal rounds.** Engine v0.10.0 (e3ae30a).

The largest run this project has done, and the one that closes the axis
that caused its most expensive bug.

### Why this axis and not another

Every corpus before 2026-08-17 held `PAIRING_FUZZ_ROUNDS=9`, and that
constant hid a real defect in `final_round_topscorers?/2`: the threshold is
`floor((expectedRounds - 1) / 2)`, which only differs from the wrong
spelling when the played count is ODD, i.e. when the tournament has an EVEN
number of rounds. At 9 rounds, 8 are played and the floor rounds nothing.
2.55M tournaments could not produce a single instance.

The even-round axis was added that day and measured 6, 8 and 10. The
2026-08-20 six-million run reached 13. **Nothing had ever compared 1-5, and
nothing had ever gone past 13** - so the commonest events in club chess (a
four-round weekend Swiss, a five-round rapid) sat entirely outside the
corpus, as did anything deeper than a large open.

Equal ROUND volume per axis, roughly 3M rounds each, rather than equal
tournament counts: the work is per round, so this gives every round count
the same statistical weight instead of starving the deep end. `MIN_PLAYERS`
scales with R, because a Swiss exhausts its field after `players - 1` rounds
and a 20-round run over a 6-player field deadlocks at round 6 and measures
nothing.

### Result

| rounds | players | rounds compared | pairings compared | agreement | illegal |
|---|---|---|---|---|---|
| 1 | 4-40 | 2,999,955 | 28,804,307 | 100.00% | 0 |
| 2 | 4-40 | 2,998,651 | 28,801,091 | 100.00% | 0 |
| 3 | 5-40 | 2,999,286 | 29,410,586 | 100.00% | 0 |
| 4 | 6-40 | 2,998,444 | 30,077,539 | 100.00% | 0 |
| 5 | 7-40 | 2,998,401 | 30,720,809 | 100.00% | 0 |
| 6 | 8-40 | 2,998,215 | 31,365,901 | 100.00% | 0 |
| 7 | 9-40 | 2,998,115 | 31,956,092 | 100.00% | 0 |
| 8 | 10-40 | 2,998,101 | 32,650,455 | 100.00% | 0 |
| 9 | 11-40 | 2,998,195 | 33,263,772 | 100.00% | 0 |
| 10 | 12-40 | 2,998,092 | 33,911,049 | 100.00% | 0 |
| 11 | 13-40 | 2,998,141 | 34,538,597 | 100.00% | 0 |
| 12 | 14-40 | 2,998,181 | 35,156,850 | 100.00% | 0 |
| 13 | 15-40 | 2,998,180 | 35,809,145 | 100.00% | 0 |
| 14 | 16-40 | 2,998,158 | 36,421,254 | 100.00% | 0 |
| 15 | 17-40 | 2,998,239 | 37,090,738 | 100.00% | 0 |
| 16 | 18-40 | 2,998,074 | 37,701,758 | 100.00% | 0 |
| 17 | 19-40 | 2,998,086 | 38,346,982 | 100.00% | 0 |
| 18 | 20-40 | 2,998,002 | 38,985,080 | 100.00% | 0 |
| 19 | 21-40 | 2,998,014 | 39,624,940 | 100.00% | 0 |
| 20 | 22-40 | 2,997,975 | 40,264,257 | 100.00% | 0 |

Every one of the twenty logs ends `legality: every Ainalrami round was a
legal pairing.`

### What it does and does not establish

It closes the round count as a variable, from a single round to twenty. In
FE1's units - one difference per 500 tournaments allowed - this run alone is
10.8 million tournaments with none.

It does NOT make the engine "fully tested", and the lesson from the 9-round
bug is exactly why it would be wrong to say so. This run holds other things
constant: 15% requested byes, no forfeits, no forbidden pairs, no
acceleration, fields capped at 40. Those axes have been measured separately,
at 9 rounds. They have not been measured CROSSED with unusual round counts.

The question to ask of the next corpus is still the one that found this bug:
not what does it vary, but what does it hold still.

## The 6-million-tournament run (2026-08-20)

The validation run for the local-graph engine, and the largest this
project has done: **5,993,000 tournaments, 44,486,465 rounds, 488,033,862
individual pairings, seventeen axes, ~15 hours on the 36-core box.** Two
disagreements, both the bbpPairings C2 second-bye defect, both scored
`incomparable` by the adjudicator, both answered our way by Gacrux. Zero
illegal rounds.

That is one disagreement per 22 million rounds, or per 3 million
tournaments, against an FE1 bar of one per 500.

**The speed is what bought the coverage**, which is the point worth
recording. 60-120 players ran at ~22 tournaments/s against 0.36 before the
matcher work, so axes that were previously unaffordable became routine:

| | before (08-17 corpus) | this run |
|---|---|---|
| 60-120 players | 600 tournaments | 300,000 |
| 150-250 players | never run | 40,000 |
| 300-500 players | never run | 3,000 |

The large-field axes alone are 3.1 million rounds. That matters more than
the headline total, because the local graph only engages on brackets big
enough to meet its preconditions -- the dimension the old corpus was
thinnest on is exactly the one the new engine most needed tested, and it
is now among the thickest.

Also new: a Black-drawn-first axis (300,000 tournaments), exercising the
5.2.5 reading this engine settles against both references; 13-round
tournaments, the deepest yet, where the pairing graph is most exhausted;
and random acceleration alongside Baku.

**Corrected 2026-08-27.** There is no such reading to exercise. The SPP
ruled that the references were right and this engine was wrong about which
number 5.2.5's parity is taken on; the twin of this sentence in
`validation.md` was corrected at the same time. What the axis actually
exercises is which colour the drawing of lots hands out, which is
worth the same as it ever was; the justification written here was not.

`@local_min_next_group` -- the one condition on the local path that was
not certified term by term, that an odd bracket's float choice does not
depend on which member of a dense next group it lands on -- has now
survived roughly 3.1 million large-field rounds without a disagreement
attributable to it. That is not a proof, and it is not claimed as one; it
is the evidence that was available, and it is the reason the condition
ships rather than the whole path being reverted.

## `finalize_pair/3` as a pure removal (2026-08-20)

`finalize_pair/3` locks a pair by leaving each vertex exactly one usable
edge, and it did that through `set_live/4` on every edge -- including the
KEPT one, raised to `st.max_w`. Raising it is what forced `set_weight/4`'s
`prepare_vertex/2` on both `i` and `j`: unmatch, dissolve every blossom
either sits in, reset both duals to the ceiling. At 1,000 players
`stage_first_group_partners` alone finalises ~482 pairs a round, each one
paying that prepare and then a re-solve that mostly just re-discovers the
same pair by augmenting-path search -- the exact shape `shift_and_set/3`
already cut out of stage 4.

Dropping an edge, unlike raising one, is a pure RELAXATION: dual
feasibility only needs `y_u + y_v >= w(u, v)`, and lowering `w` can only
make that easier. Complementary slackness only constrains MATCHED edges,
and every edge `finalize_pair/3` drops is by construction unmatched --
`i` and `j` have only each other. So none of `dual`, `mate`,
`blossom_match` or `in_blossom` needs to move, and the kept edge doesn't
need raising either: once every other edge at `i` and `j` is gone, `(i,
j)` is the only edge either vertex has, every weight is positive, and a
maximum-weight matching always takes the one positive edge available over
leaving both ends exposed. `WeightedMatching.finalize_pair/3` is that --
plain `Map.delete`s on `state.weight`, nothing else touched -- and it
refuses (`:error`) when `i` or `j` sits inside a non-trivial blossom,
exactly the guard `shift_and_set/3` already needed for the same reason:
`dissolve_one/3` rebases a blossom at whichever vertex is about to be
unmatched and pushes half the blossom dual onto the base's OLD external
match, which is sound only because `prepare_vertex/2` removes that match
a moment later. Nothing here unmatches anything, so a dissolve would be
unsound; refusing sends the caller back to `set_weight/4`, correctness-safe
by construction since that's the already-proven path, just slower. The
field graph keeps its `WeightedMatching` state in the round matcher
(`@round_matcher_key`), not `st.wm`, so `Ainalrami.Pairing`'s
`fast_finalize_pair/3` has a mode-specific branch that translates `i`/`j`
to field indices first; the local graph calls straight through.

Measured at 1,000 players: the fast path engaged 497/500 finalisations in
one round (3 refused into blossoms and fell back). 209: 0.207 s (was
0.211 s). 400: 0.718 s (was 0.731 s). 1,000: 6.46 s (was 6.83 s, -5.4%).
Smaller than `stage_first_group_partners`'s finalisation count alone
would suggest -- the prepare's re-solve was already cheap in most cases
(`greedy_resume/1` picks a freshly-prepared pair straight back up when its
heaviest edge is to its own kind, which a residual pair usually is), so
removing the prepare mostly removes bookkeeping rather than search. Still
a real, unconditional win with no corpus cost: `mix test` (187/187),
`matching_baseline.exs` (460/460), `matching_incremental.exs` (all
optimal and valid), all seven corpus axes at 100.00%, and board-for-board
identical output at both 400 (200/200) and 1,000 (500/500) players
against bbpPairings.

## Where the remaining time goes, and three levers that do not move it (2026-08-21)

Re-measured on the 36-core box against freshly generated fields (the
2026-08-19 files were not kept), all three engines on the same input, best
of three, cold process. **All three return identical boards at every size**
- bbpPairings and this engine byte-for-byte, Gacrux differing only by a
trailing tab line.

| | start-up floor | 209 | 400 | 1,000 |
|---|---|---|---|---|
| bbpPairings 6.0.0 | 6 ms | 417 ms | 2,094 ms | 43,760 ms |
| Ainalrami | **604 ms** | 960 ms | 1,567 ms | 8,299 ms |
| Gacrux | 252 ms | 587 ms | 1,346 ms | 7,921 ms |

The floor is measured on a 30-player file, where the pairing work is
nil. Subtracting each engine's own:

| pairing work | bbpPairings | Ainalrami | Gacrux |
|---|---|---|---|
| 209 | 411 ms | **356 ms** | 335 ms |
| 400 | 2,088 ms | **963 ms** | 1,094 ms |
| 1,000 | 43,754 ms | **7,695 ms** | 7,669 ms |

So 1.15x-5.7x quicker than the C++ reference, and *level with* the Python
one - faster at 400, within 0.3% at 1,000. The README's older "1.15x to
1.45x slower than the Python one" no longer holds; that gap closed.

At 209 players 63% of the wall clock is booting the BEAM, which is why
the reference "wins" there and why that loss does not exist inside a host
application that is already running.

### The cost is four brackets

Instrumented `pair_bracket/6` at 1,000 players. `nsgb` is the bracket's
own size; `sgb` is its moved-down count.

| nsgb | sgb | path | cost | share |
|---|---|---|---|---|
| 205 | 0 | local | 3.75 s | **42%** |
| 178 | 0 | local | 1.40 s | 16% |
| 184 | 1 | local | 1.27 s | 14% |
| 113 | 0 | local | 0.81 s | 9% |
| seven others | | | 0.9 s | 10% |

Four brackets are 89% of the round, and cost scales steeply with bracket
size rather than with the combined list - the three largest *combined*
lists (1000, 992, 970) are nearly free. Anything that does not make large
brackets cheaper is not worth doing.

### `finalize_pair/3` as a pure removal: +2%

A/B on the same box and files, boards identical: 209 players 947 -> 960 ms,
400 players 1,580 -> 1,567 ms, 1,000 players 8,488 -> **8,299 ms**. Noise
at the two smaller sizes, 2.2% at the largest. It targeted the 1.9 s
stage-8 block and returned ~0.2 s. Correctness-neutral (the 487M-pairing
corpus) and, it turns out, performance-neutral too.

### Dead lever 1: the natural pairing is not the answer

Gacrux answers every large bracket in "0.00 s" without a matcher, so the
obvious idea is to check whether the natural S1-S2 pairing is already
optimal and skip the solve when it is. Measured how many natural pairs
survive into the matcher's answer:

| bracket | natural pairs kept |
|---|---|
| 205 | 33 / 102 |
| 178 | 15 / 89 |
| 113 | 4 / 56 |
| 78 | 6 / 39 |

7% to 32%. By round 6 the colour and rematch constraints have rearranged
almost everything, so the check would essentially never fire.

That is not what Gacrux does either. It walks Article 3's transposition
order and accepts the first candidate that is legal and meets a counting
bound on the colour criteria, with completability read off a precomputed
table. It reaches the same answer because that walk is what the
regulations *define* the answer to be. That is a second pairing algorithm,
not a shortcut into this one - and its own author notes it degrades past
500 players. It remains the only lever with order-of-magnitude potential.

### Dead lever 2: the weights cannot usefully be narrowed

Measured, not estimated: edge weights are **512 bits** - eight limbs.

The idea was that the width is load-bearing in general but not per
bracket, so a bracket could pack only the criteria that actually vary in
it. It does not pay. `count_span` is `length(field) + 1`; narrowing it to
the local graph's size saves about 1.7 bits per power of `s`, roughly 31
bits across the whole encoding. 512 -> 481 is eight limbs -> eight limbs.
Nothing.

Nor does changing the representation. Measured on the box:

| | 512-bit | 58-bit |
|---|---|---|
| add | 120.5 ns | 47.2 ns |
| compare | 35.4 ns | 13.5 ns |

A tuple of 21 small integers with component-wise arithmetic would need 21
machine-word adds plus a tuple allocation to replace one 120 ns bignum
add. **The packed bignum is already the efficient representation**, which
is the opposite of what the "narrow the weights" note in TODO.md assumed.

### Dead lever 3: not parallelism either

`stage_first_group_partners/1` is a strict `Enum.reduce` threading the
solver state, each iteration finalising a pair and re-solving on the
result, so the per-pair solves are sequentially dependent by construction.
Brackets cascade floats top-down and are dependent for the same reason.
The only genuinely parallel spot is the `changes` comprehension in
`stage_exchange_weights/1` - O(remainder^2) pure `exchange_weight/4` calls
- and the profile attributes that stage's cost to the solve, not the
comprehension. A 36-core box buys this workload close to nothing.

### What is actually left

One lever, and it is a project: Article 3's transposition procedure as a
fast path with this matcher as the fallback and the oracle. Everything
else measured here is percentages on a round that is already level with
the fastest implementation in existence and several times quicker than the
FIDE-endorsed one.

### The greedy start does nothing on a local graph (2026-08-21)

Measured, and it corrects a claim made twice above. `greedy_start/3` is
described here and in its own comment as pairing "the mutually-heaviest
half"; on the 209-player FIELD graph it does exactly that, and better -
992 of 1,000 vertices. On every LOCAL bracket graph it matches **one
pair**:

| graph | n | matched |
|---|---|---|
| field | 1000 | 992 |
| local | 206 | 2 |
| local | 184 | 2 |
| local | 178 | 2 |
| local | 114 | 2 |
| local | 102 | 2 |
| local | 82 | 2 |
| local | 78 | 2 |

`map_size(blossom_match)` counts vertices, so 2 is a single pair and ~n
vertices are left exposed. That is the 489 stages and the 2.3 s: the cold
solve of a local graph is doing nearly all of its work through augmenting
search, from an almost empty matching.

The cause is the dual initialisation, not the matching pass. `y_v` starts
at `max_u w(v,u) / 2`, so an edge is tight exactly when its two endpoints
are each other's heaviest - and on a bracket graph they almost never are.
The criteria make nearly every vertex's heaviest edge point at the same
small set of top-ranked opponents, which reciprocate at most one of them.
A star has one mutually-heaviest pair, and that is what comes back.

On the field graph the same initialisation works because cross-bracket
edges spread the maxima out.

So the lever here is a feasible dual that makes more edges tight on a
star-shaped weight matrix, not a cleverer greedy pass over the one that
exists - the pass is fine, it is being handed a graph with one tight edge.
Any replacement has to keep `y_u + y_v >= w` everywhere, which is what
makes it real work rather than a tweak; lowering a dual to create one
tight edge can violate another. `tools/matching_baseline.exs` is the net:
it checks total weight first and identity second, precisely because a
different-but-equal-weight matching is not a regression.

This is now the best-evidenced target on the matcher, and it is a much
narrower one than "narrower weights" ever was.

### Dead lever 4: a cheaper feasible dual makes it twice as slow (2026-08-21)

The lever the previous section left standing, tried and measured.

`greedy_start/3` matches on TIGHT edges, and under the symmetric start
`y_v = max_w(v)` an edge is tight only when its endpoints are each other's
heaviest - which is why a local bracket graph yields one pair. The obvious
fix is a cheaper feasible dual with more tight edges: process vertices in
order and give each the least value that keeps it feasible against those
already fixed,

    y_v = max over already-fixed u of (w2(v, u) - y_u), floored at 0

which is feasible for the whole graph (for an edge between two fixed
vertices the later one was raised to satisfy it; for an edge to an unfixed
vertex, that vertex is raised in its turn), and makes the edge achieving
the maximum exactly tight.

It is correct. `tools/matching_baseline.exs` reports the same total weight
and the same matched count on all 460 graphs, differing only in WHICH
optimum it lands on in 39 of them, and the full suite passes.

It is also **twice as slow**:

| | symmetric start | sequential duals |
|---|---|---|
| 209 players | 937 ms | 1,091 ms |
| 400 players | 1,531 ms | 1,974 ms |
| 1,000 players | **8,026 ms** | **15,948 ms** |

Both halves of the theory were wrong, and the dual sums say why.

**The dual gets catastrophically worse.** On the 1,000-player field graph
the starting dual objective goes from 1.85×10¹² to about 1.4×10¹⁷⁰. The
sequential rule cascades into an alternating 0 / `w2` pattern - a vertex
fixed at 0 forces every neighbour to `w2`, those force their neighbours
back to 0 - so the sum is roughly `n/2` times a 512-bit weight. The
primal-dual algorithm's entire job is walking the dual objective down to
the optimum, and this hands it a starting point 158 orders of magnitude
away.

**And it barely buys any tight edges.** 992 matched vertices became 154 on
the field graph; the local graphs went 2 → 2, 2 → 4, 2 → 12. A vertex's
dual is set by ONE edge, so only that edge is tight, and the greedy pass
still needs both endpoints free. The mutually-heaviest condition is
restrictive, but so is "the one edge that happened to fix this vertex".

So the one-pair greedy start on local graphs is not a defect to be fixed
by a better dual. It is what a symmetric feasible dual does on a
star-shaped weight matrix, and the symmetric dual is worth keeping: it is
close to optimal, which matters far more than how many edges it makes
tight. Anything that improves the tight-edge count has to do it WITHOUT
inflating the dual objective, and this project has no candidate for that.

Reverted. `matching_baseline.exs` is byte-identical again on all 460.

## The odd-field bootstrap: 4.0 s of construction for a graph that was already known (2026-08-27)

`tools/bootstrap_split.exs` had just established where the odd-field bye
bootstrap's time goes at 1,001 players. Three halves, and only one of them
is the algorithm:

| | before | after |
|---|---|---|
| building the edge list | 2,407 ms | **638 ms** |
| `WeightedMatching.new/3` | 1,409 ms | **224 ms** |
| `WeightedMatching.solve/1` | 2,877 ms | 2,254 ms |
| bootstrap total | 6,621 ms | **3,090 ms** |

Medians of three on the 36-core box, same cached 1,001-player round-6 field
for every run. End to end, best of three, cold process: the odd round goes
14,291 ms -> **9,016 ms**, and the parity ratio against the same field one
player smaller goes 2.04-2.32x -> 1.31-1.45x. The even field is the
control and does not move (6,399 ms -> 6,477 ms, inside a 400 ms spread).

`solve/1` was not touched and fell 22% anyway. Nothing about the search
changed - the state it is handed is bit-identical, see below - so that is
garbage: the old path put a 500,500-tuple list and a second 500,500-element
list of discarded comprehension results on the process heap before the
search started, and every collection during the search walked them.

### Three constructions, none of which the answer depends on

**The per-pair work was per-player.** The inner comprehension called
`legal_pair?/2` and `colour_compatible?/2` per PAIR and read
`Map.fetch!(places, _.points)` and `eligible_for_bye?/1` for each endpoint.
Every one of those is a property of a POSITION in the sorted field:
`eligible_for_bye?/1` alone walked a game list a million times to produce a
thousand distinct answers. They are now tuples indexed by position, built
once. `legal_pair?/2`'s `Enum.any?(p1.games, ...)` scan becomes a single
`is_map_key/2` against a played-opponent set - the MapSet the note in that
function had been asking for - with the arbiter's forbidden pairs folded
into the same map, which is legitimate because `legal_pair?/2` asks both
questions of the same player and bbpPairings answers both from one lookup
anyway (`dutch.cpp:653-666` inserts the rematch straight into
`forbiddenPairs`).

**The weight did not need reassembling per pair.** A compatible edge is
`tie_unit * (cardinality_unit + eligibility * eligibility_unit + score) +
top_pair` where `eligibility` and `score` are both sums of per-endpoint
terms - the very property the `duals` handed to `new/3` were already
derived from. Doubled, that is `2 * half_const + vertex(lo) + vertex(hi) +
2 * top(hi)`: two additions per edge instead of six multiplications and
four hash lookups. No weight changes; the same integer arrives by a
shorter route.

**The edge list existed only to be taken apart again.** The graph is
COMPLETE by construction (dutch.cpp:768-791 emits an edge even for
`compatible/4`-failing pairs), so at n=1,001 the `[{i, j, w}]` list was
500,500 tuples allocated and immediately consumed by `new/3`'s fold, which
spent a million `Map.update/4`s scattering them into the nested
`%{u => %{v => 2w}}` the solver actually reads. The bootstrap now emits
that structure directly, a row at a time - one `:maps.from_list/1` per row
- and `new/3` takes it as `:adjacency` and does no fold at all. The price
is that each pair's weight is arrived at twice, once from each endpoint's
row; with the per-player facts above that is two tuple reads and an
addition, and it is still four times quicker.

Two smaller things fell out of the same reading. `greedy_start/3`'s
dual-feasibility assertion was a `for` comprehension whose result was
discarded - 500,500 list cells built for nothing - and both of its O(E)
scans read the dual map with `Map.fetch!/2` where the duals are keyed by
exactly `0..n-1` and a flat tuple does. Two million hashes, on a graph
whose vertices are already dense integers.

### Proving it invisible

The bar is that the matcher receives the same input, not that it returns
the same answer - a maximum-weight matching need not be unique, so "same
answer" would have been the weaker claim. Both trees were patched, on the
box only, to print `:erlang.phash2` of `weights`, `max_w`, `dual` and the
greedy `blossom_match` at the point `build_state/5` hands them over. All
three whole-field solves in a 1,001-player round hash identically:

    WMFP n=1001 weights=35949947 max_w=103196167 dual=68492382 bm=94596732
    WMFP n=1001 weights=90091074 max_w=116873996 dual=32900900 bm=114629392
    WMFP n=1001 weights=100857086 max_w=34984707 dual=43914350 bm=79643213

`max_w` is in there deliberately: it is not decoration, `greedy_resume/1`
tests `dual[v] == max_w` to decide which vertices are fresh, so an
"obviously equivalent" ceiling would have been a behaviour change. It is
tracked exactly while the rows are built rather than derived from a bound.

On top of that, and recorded here because the 2026-08-26 sweep found the
default fuzz axis exercises neither forbidden pairs nor byes:

* `tools/bootstrap_identity.exs`, new, traces
  `bye_assignee_score_from_field/2`'s return without exporting it -
  `{0.0, false}` and a round hashing to 59399646 in both trees.
* 296 tests, 0 failures.
* `tools/matching_baseline.exs`: 460/460 byte-identical, recorded on the
  old tree and verified on the new one.
* bbpPairings, 3,000 tournaments x 9 rounds: 25,274/25,274 rounds,
  299,281/299,281 pairs, 100.00%.
* bbpPairings on an axis that actually runs this code, 1,500 tournaments
  of exactly 41 players x 9 rounds with 20% forbidden pairs, 15% byes and
  10% forfeits: 13,500/13,500 rounds, 238,687/238,687 pairs, 100.00%, and
  the old tree returns the same figures down to the 11,009 Article 5.2.5
  colour-dispute boards.

**Corrected 2026-08-27.** The identity claim stands - it was a comparison
of two Ainalrami trees against each other, and the refactor did not touch
colours. What the 11,009 are does not: the harness filed them as the known
Article 5.2.5 dispute, and the SPP has since ruled that reading wrong, so
they are 11,009 boards on which the old engine gave the wrong player White.
It is the only count of them this file records. Both figures were taken
before the fix and neither has been re-measured on the corrected engine.

### What is left

Construction is 862 ms of a 3,090 ms bootstrap, and most of what remains
is irreducible: a million bignum additions and a million map entries.
`places` is a mixed-radix encoding, so a 1,001-player field's weights run
to about a hundred digits, and `new/3` does not divide out the common
factor when the caller supplies duals. Narrowing them is a weights
question, and dead lever 2 above already says what happened last time.

The bootstrap is now 28% of an odd round rather than 47%, and `solve/1` is
73% of what is left of it. `bootstrap_split.exs`'s verdict line has
changed accordingly: it now says THE SOLVE, which is the question it was
written to hand over - whether C5's "minimise the score of the PAB
assignee" needs a maximum-weight matching at all. That is still open.

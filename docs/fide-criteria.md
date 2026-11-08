# FIDE (Dutch) System criteria - primary source, and what this engine does

> **Checked 2026-08-17.** Every function named below was verified to exist.
> A previous version of this file mapped articles onto `cascade_brackets/4`,
> `placeable_below/1`, `downfloater_scores/1`, `bracket_options/3`,
> `within_bracket_weight/4`, `spans.locality`, `spans.score_paired` and an
> `AINALRAMI_GLOBAL` environment variable - **none of which exist in `lib/`**.
> They were real once and were deleted with the per-bracket cascade; this
> file was not updated. A rules-to-code map naming functions the code does
> not have is worse than no map, because it gets read as authority. If you
> delete something named here, edit here.

Source: **FIDE Handbook C.04.3, "FIDE (Dutch) System", effective 1 February
2026** (<https://handbook.fide.com/chapter/C0403202602>), plus the
definitions it inherits from C.04.1 Basic Rules for Swiss Systems.

Worked companion, added 2026-08-17: **Mario Held, *Mastering the Dutch*** - a
72-page tournament example developed with C.04.3 version 2026, published by
the FIDE Technical Commission
(<https://tec.fide.com/wp-content/uploads/2026/07/Mastering_the_Dutch_2026.pdf>).
It confirms two rules this engine had derived from bbpPairings' source and
from measurement rather than from the rules text:

* **C1, C2, C3 are the absolute criteria**, and C2 is the PAB rule - the
  assignee must be a player who "did not receive a previous PAB, a forfeit
  win, or a Full-Point Bye". A candidate breaching an absolute criterion
  "can only be immediately discarded", so this is legality, not quality. C2
  excludes full points earned *without playing*, which is why an ordinary
  win - including TRF16's letter spelling `W` - never costs eligibility, and
  why `W` was removed from `@bye_disqualifying_results`.
* **A topscorer holds strictly more than half the score available so far.**
  Its footnote 27: "in a nine-round tournament the maximum score before the
  last round is eight points. So, a topscorer is a player who has 4.5 points
  or more." That is `points > played_rounds / 2` - an exact half, strict
  comparison, against the tournament's played rounds rather than a player's
  own game count. It confirms both halves of the `final_round_topscorers?/2`
  fix independently of bbpPairings.

Its team counterpart, added 2026-11-09: **Mario Held, *Mastering the FIDE
Team Pairing System*** (ver. 2607090900), the worked example of C.04.6,
published by the FIDE Technical Commission
(<https://tec.fide.com/wp-content/uploads/2026/07/Mastering_the_TPS_2026.pdf>).
It is the source for how a match forfeited as a whole is scored: in round 4
"Team #8 did not show in time to play, thus forfeiting the match", the
results table scores it `0F-4F`, and the opponents of absent players get
"a forfeit win fully equivalent to a victory on-the-board". The pairing "may
be repeated in a future round"; game points serve only 4.2.2 and the first
tie-break; the PAB is 1 MP and 2 GP. See `conformance-c0406-teams.md`
(question 6, *Forfeited matches*) and `conformance-c07-tiebreaks.md`
(reading T8, Q3).

Written down here because this project's rule is that anything touching a
FIDE rule needs the handbook text in hand rather than a paraphrase, and
because the numbering itself is new: the February 2026 revision introduced
a **unified criteria numbering** (C1-C21) that the 2017 edition did not
have. Quoting it once, here, means the next person does not re-derive it
from a C++ bit layout.

## Which rulebook this engine targets

**The 2026 one.** There are two live Dutch rulebooks and the references do
not agree about which they implement:

| engine | Gacrux's tag (`DUTCH_RULES`) | FIDE edition |
|---|---|---|
| JaVaFo 2.2 | 2022-01-01 | 2017 |
| bbpPairings 6.0.0 | 2026-02-01 | 2026 |
| Gacrux (FIDE TBS) 1.9.57 | 2026-02-01 (`DUTCH_RULES[1]`, "Approved by FIDE Council on 01/02/2026") | 2026 |

The middle column is Gacrux's own bookkeeping, quoted from
`pairingdutch.py` - `2022-01-01` is not a FIDE edition year, it is the
date Gacrux attaches to the ruleset it replaces. FIDE's own name for that
ruleset is the 2017 edition (approved at the 87th Congress, Baku 2016;
Terms and Definitions and Pairing Guidelines For Programmers added at the
88th, Goynuk 2017), right column above.

Measured over **3352 comparable rounds**, bbpPairings and Gacrux agree
with each other **100%**, while JaVaFo differs from both on 2.47%. That
2.47% is the rule change, not engine variance - so "disagrees with
JaVaFo" is no longer evidence of a bug, and the number to steer by is
agreement with the two 2026 implementations.

**That sample size is the point, not a detail.** This claim used to rest
on 324 rounds. Zero observed failures in `n` trials bounds the true rate
at about `3/n` with 95% confidence, so 324 clean rounds only established
the references disagree on less than roughly **0.9%** - which is not a
usable ruler for an engine whose own error is 1.4%. At 3352 rounds the
bound tightens to **0.09%**, about fifteen times smaller than the thing
being measured, and the references become trustworthy ground truth at
this engine's current accuracy.

It also settles what the remaining disagreements are. Of the 47 rounds in
that run where Ainalrami differed from either reference, **all 47 had the
two references agreeing with each other** - not one was a case of the
references splitting and no ground truth existing. So there is no
"legal-but-different, nobody is right" bucket left to hide in: every
remaining disagreement is this engine being wrong. Re-run it with
`mix test --only three_way` (see `three_way_comparison_test.exs`).

## Definitions (C.04.1)

- **MDP** (moved-down player) - a player who remained unpaired in a bracket
  and was transferred to the next one.
- **Resident** - a player coming from the current scoregroup being paired.
- **Downfloater** - a player left unpaired in a bracket and moved to the
  next for pairing.
- **Topscorer** (Art. 1.8) - a player scoring over 50% of the maximum
  possible score **when pairing the final tournament round**. Note the
  qualifier: outside the final round there are no topscorers at all.

## Absolute criteria - never violated

| | text | this engine |
|---|---|---|
| C1 | Two participants shall not play against each other more than once. | `legal_pair?/2` |
| C2 | A participant who has already received a pairing-allocated bye, or has already scored in one single round without playing as many points as rewarded for a win, shall not receive the pairing-allocated bye. | `eligible_for_bye?/1`, plus a near-absolute penalty in `float_weight/4` |
| C3 | Non-topscorers with the same absolute colour preference shall not meet. | `colour_compatible?/2` with `final_round_topscorers?/2` as the carve-out |
| C4 | *(Completion Criterion)* A pairing complying with all the absolute criteria shall always exist for all players not yet paired. | `check_completion/3` on the cascade's final state, with `repair_completion/3` as the whole-field fallback; `NoValidPairingError` when genuinely impossible |
| C5 | *(PAB Criterion)* Minimise the score of the assignee of the pairing-allocated-bye. | `bye_assignee_score/2` - a whole-field pre-pass fixing the bye's score, enforced by `bye_score_ok?/1` inside `check_completion/3` |

### The arbiter's own absolute criterion

An `XXP` line - "these players must never meet", for family members, the
same club, or a federation exclusion rule - is not in the handbook's list,
because it is not a pairing rule: it is an instruction the arbiter gives
the engine about this particular event. But it has exactly C1's STANDING,
and bbpPairings settles that rather than leaving it to taste. `compatible`
(`dutch.cpp:39-68`) tests one `forbiddenPairs` set before it looks at
colour at all, and C1 itself reaches that test by being inserted into the
very same set (`dutch.cpp:653-666`). One lookup, two rules.

So it lives in `legal_pair?/2` beside C1 and is never weighed against
anything. One line names a GROUP, not a pair: `XXP 4 9 17` forbids 4-9,
4-17 and 9-17 alike (`readForbiddenPairsXxp`, `trf.cpp:554-568`).

Acceleration (`XXA`) is the mirror image - not a criterion at all, but a
change to the score every criterion reads. See `with_acceleration/2` in
`Ainalrami.Pairing`, and engineering-log.md's "`XXP` and `XXA`" section for why that is
the port rather than a shortcut.

## Quality criteria - in descending priority

Verbatim from §2.4, with this engine's implementation beside each.

| | text | this engine |
|---|---|---|
| C6 | Minimise the number of downfloaters *(equivalent to: maximise the number of pairs)*. | the `"C6 pairs in bracket"` rung, `edge_rungs/6` |
| C7 | Minimise the scores (taken in descending order) of the downfloaters. | the `"C7 scores paired"` rung, graded by score group via `bands.places` |
| C8 | Choose the set of downfloaters so that in the following bracket every criterion from C1 to C7 is complied with. | the two `"C8 … next bracket"` rungs, over edges reaching the immediately following score group only (`reach == 1`) |
| C9 | Minimise the number of unplayed games of the assignee of the pairing-allocated-bye. *(Applies to brackets downfloating exactly one player receiving the bye.)* | `unplayed_ranks/2`, gated on `single_bye?`. Both halves of the parenthetical are enforced: the previous bracket's tentative matching supplies "the float does not run deeper than one group", and an EVEN number of players below the bracket supplies "and that one receives the bye" - an even remainder pairs among itself, leaving the lone floater nobody to meet. Getting this gate right is worth more than any other single fix measured: see the gaps section |
| C10 | Minimise the number of topscorers or topscorers' opponents who get a colour difference higher than +2 or lower than -2. | `colour_criteria/2` bit 1 - **not restricted to topscorers** |
| C11 | Minimise the number of topscorers or topscorers' opponents who get the same colour three times in a row. | `colour_criteria/2` bit 2 - **not restricted to topscorers** |
| C12 | Minimise the number of players who do not get their colour preference. | `colour_criteria/2` bit 3 |
| C13 | Minimise the number of players who do not get their strong colour preference. | `colour_criteria/2` bit 4 |
| C14 | Minimise the number of resident downfloaters who received a downfloat the previous round. | `float_criteria/2` f1 |
| C15 | Minimise the number of MDP opponents who received an upfloat the previous round. | `float_criteria/2` f2 |
| C16 | Minimise the number of resident downfloaters who received a downfloat two rounds before. | `float_criteria/2` f3 |
| C17 | Minimise the number of MDP opponents who received an upfloat two rounds before. | `float_criteria/2` f4 |
| C18 | Minimise the score differences (taken in descending order) of MDPs who received a downfloat the previous round. | `float_score_criteria/3` s18 |
| C19 | Minimise the score differences (taken in descending order) of MDP opponents who received an upfloat the previous round. | `float_score_criteria/3` s19 |
| C20 | Minimise the score differences (taken in descending order) of MDPs who received a downfloat two rounds before. | `float_score_criteria/3` s20 |
| C21 | Minimise the score differences (taken in descending order) of MDP opponents who received an upfloat two rounds before. | `float_score_criteria/3` s21 |

### On "minimise" versus this engine's maximising weights

The handbook phrases every quality criterion as a MINIMISATION over the
players left unpaired or mispaired; `ranked/1` maximises over the pairs
actually formed. These are the same statement seen from opposite sides -
pairing a player who downfloated last round is exactly how you avoid
counting them among C14's repeat downfloaters - which is why the criteria
appear here as rewards on an edge rather than penalties on a float.
bbpPairings' `computeEdgeWeight` does the same inversion.

## Known divergences from the handbook

1. ~~**C8 is only approximated.**~~ **Closed - C8 is implemented, and
   implementing it properly is what made the global cascade the default
   path at 95.97% of exact rounds against the per-bracket cascade's
   90.29% (99.44% vs 82.22% on 60-80 player fields).**

   The account below is kept because it is the record of two failed
   attempts and of the reasoning that eventually paid off - the
   "structural, not scoring" conclusion at the end was right, and the
   thing it identified is exactly what was wrong.

   What the earlier attempts missed: C8 asks whether the FOLLOWING
   bracket can satisfy C1-C7, and no scoring of a bracket that cannot SEE
   the following bracket can answer that. The fix was visibility, not a
   better measure - see `@peek_budget` and engineering-log.md. The old approximation
   (a per-player "can this player be placed below" bit) is
   strictly weaker: C1/C3 feasibility for one player, not C1-C7
   compliance for a bracket.

   Attempt one scored each candidate by the pair COUNT the following
   bracket could reach. Inert ranked low, a regression ranked high, no
   fixture moved. Fixture 6 explains it: JaVaFo drops one 3.5 player two
   brackets while the 2026 answer drops two players one bracket each, and
   both leave the same NUMBER of pairs available, so a count cannot
   separate them.

   Attempt two therefore scored `{count, scores descending}` - C6 *and* C7
   one bracket ahead, which does separate fixture 6's two options. It still
   loses, and by more the higher it is ranked:

   | candidate ordering | rounds | pairs |
   |---|---|---|
   | baseline (no C8 term) | 89.93% | 97.08% |
   | C8 below the packed weight | 89.88% | 97.07% |
   | C8 above the packed weight | 88.28% | 96.64% |

   So the measure is not the problem either. What the same experiment DID
   find is that C7 stated explicitly at candidate level is worth **+0.36
   exact rounds** on its own (89.93% -> 90.29%) - see the C7 row above.
   Running both together scored 89.34%, C7's gain cancelled by C8's loss,
   which is what sent this apart into separate measurements.

   Reverted, twice. The remaining hypothesis is structural rather than
   about scoring: choosing between one double-float and two single-floats
   needs three brackets in view at once, and the old per-bracket cascade peeked
   exactly one ahead by construction. Widening that lookahead is not a
   one-line change either, because the peeked bracket deliberately
   contributes no edges - it survived only as that placeability bit's
   per-player bit (see `pair_weight/4`), so a second peeked bracket would
   merely make that bit MORE permissive, which is the wrong direction.

   **The structural hypothesis was then tested directly, and it holds.**
   `global_cascade/2` (now the only path; there is no flag) is bbpPairings'
   architecture ported stage for stage: the graph is the current bracket
   plus the whole next score group, and each bracket is solved up to eight
   times, every solve answering one question and freezing the answer
   before the next is asked. C8 stops being a lookahead in that design -
   it falls out of the C8 rungs being on real edges to real next-bracket
   players, rather than a per-player feasibility bit.

   | 200x9 vs bbpPairings | rounds | pairs |
   |---|---|---|
   | global cascade, single solve per level | 60.51% | 93.6% |
   | global cascade, all stages ported | 90.11% | 96.82% |
   | global cascade, completion rung corrected | **90.29%** | 96.89% |
   | per-bracket cascade (still the default) | **90.29%** | 97.21% |

   So the missing 30 points really were the refinement, as predicted, and
   a further correction to the completion rung (see engineering-log.md, and
   `test/fixtures/open_questions/`) brings it level with the default on
   exact rounds. It remains 0.3 behind on pairs.

   The split by round says where the rest is: the global cascade is
   *better* mid-event (r3 97.00 vs 93.50, r4 97.40 vs 95.83, r5 94.79 vs
   92.19) and worse late (r7 83.15 vs 84.24, r8 81.44 vs 82.04, r9 67.07
   vs 69.46), which
   is where legal pairings run short and the per-bracket cascade's
   backtracking - measured at 15 points of pairs by itself - pays for
   itself. bbpPairings needs no backtracking because it proves a complete
   legal matching exists before it starts (`dutch.cpp:825-837`, throwing
   `NoValidPairingException` otherwise); that pre-pass is the obvious next
   thing to port, and the last real difference between the two designs.

   One finding from the port is worth recording on its own: **the
   canonical lexicographic tie-break is inert under the staged
   refinement.** Removing it, and even inverting it, reproduce 1522/1689
   and the same disagreement set exactly - verified against a live switch,
   since a bad value raises from inside the run. In the per-bracket
   cascade the same tie-break is worth ~40 points, because a
   maximum-weight matcher may return any optimum and something has to
   choose. After eight staged solves there is nothing left to choose,
   which is precisely the claim bbpPairings' design makes for itself.

2. ~~**C10/C11 are not restricted to topscorers.**~~ **Investigated and
   withdrawn - this is not a divergence.** The reasoning looked sound:
   both criteria are about "topscorers or topscorers' opponents", Art. 1.8
   makes topscorers exist only when pairing the FINAL round, and Gacrux
   guards them explicitly with `if (a["top"] or b["top"])` while this
   engine does not.

   But bbpPairings does not guard them either - `insertColorBits` gates on
   `inCurrentScoreGroup`, never on topscorer status - and bbpPairings
   agrees with Gacrux 100%. The two are reconciled by C3: two
   non-topscorers with the same absolute colour preference may never meet
   at all, so the C10/C11 bits can only ever fire where C3 already permits
   the pairing, which is exactly the topscorer cases. Gacrux gates
   explicitly; bbpPairings lets the absolute criterion do it; the outcome
   is identical.

   This engine takes bbpPairings' route (`colour_compatible?/2` enforces
   C3, with `final_round_topscorers?/2` as its carve-out) and
   `colour_criteria/2` is a faithful port of `insertColorBits`, condition
   for condition. Adding a topscorer gate would be redundant, and would
   risk diverging if the two C3 implementations ever disagreed at the
   edges. Left alone deliberately.

3. ~~**C9's gate was wrong, and it dominated the colour criteria.**~~
   **Closed - this was the single largest remaining defect.** C9 sits
   above every colour rung, so wherever it fired spuriously it decided
   the bracket outright.

   The handbook scopes it to "brackets downfloating exactly one player
   receiving the bye", and only the first half was enforced. The second
   half turns out to be a parity fact about what lies BELOW the bracket:
   an even number of players there pair among themselves, leaving the
   bracket's lone floater nobody to meet and therefore the bye; an odd
   number needs a partner from above, so the bracket floats two and the
   criterion has no single assignee.

   Two stricter readings were measured and rejected on the way. `rest ==
   []` ("no group below at all") is correct but incomplete - it silences
   the legitimate case where an even remainder pairs off. Gating instead
   on the next bracket's own size being odd was much worse (97.57%
   against 99.94% at a 15% bye rate): a bracket of odd size does not
   reliably float exactly one, since who is left over depends on who can
   legally pair inside it.

   Measured at 600 tournaments x 9 rounds against bbpPairings.exe:

   | profile | before | `rest == []` | players-below even |
   |---|---|---|---|
   | plain | 100.00% | 100.00% | 100.00% |
   | 8% byes | 99.76% | 99.92% | **100.00%** |
   | 15% byes | 99.73% | 99.94% | **99.98%** |
   | 10% forfeits | 99.52% | 99.70% | **99.98%** |
   | 10% byes + 10% forfeits | - | 99.78% | **99.96%** |

   Forfeits improve for the same reason byes do: a forfeit is an unplayed
   game, so it feeds the same `unplayed_ranks` the rung reads. Their
   disagreement count over 5025 rounds went 15 -> 1.

   **A third layer, found later and worth stating separately: the gate
   also has to be well-DEFINED.** For the first bracket the gate is not
   computed, it is READ - off the bootstrap whole-field matching, by
   `first_single_bye?/4`, which asks whether any top-group player is
   tentatively matched below the top group. That makes it a property of
   the matching's SHAPE, and a maximum-weight matcher may return any
   optimum. `bye_assignee_score_from_field/2` was missing
   `dutch.cpp:782-786`'s lowest packed field - a bit set when an edge lies
   wholly inside the top score group, i.e. "maximise the pairs formed
   inside the top score group" - which is exactly what resolves those
   ties in bbpPairings' favour. Without it the gate was decided by
   whichever tied matching came back, and it came back FALSE often enough
   to kill C9 in the first bracket of small fields. See engineering-log.md; it closed
   39 of the 40 catalogued residual disagreements.

4. ~~**C12 may count colour preferences bbpPairings ignores.**~~
   **Tested and refuted - do not retry.** Partway through the C9 work the
   remaining disagreements inverted: the adjudicator started reporting
   *ours* scoring better on C12, which is normally the shape that says
   our LADDER is over-crediting, since a reference that implements a
   criterion will not casually violate it. The hypothesis was that
   bbpPairings' colour-preference bit ignores a MILD preference - a
   player at colour difference 0, who by E.5 prefers the opposite of
   their last colour but has no imbalance behind it.

   Requiring both sides of a clash to hold a strong-or-absolute
   preference collapsed the engine: 99.91% -> 57.88% of exact rounds at
   a 15% bye rate, and 100% -> 63.66% on plain tournaments. bbpPairings
   counts mild preferences, emphatically. `colour_criteria/2`'s
   `not clash?` is correct as written.

   Worth recording WHY the signal was misleading: those cases were not
   colour defects at all. They were C9 firing in brackets it does not
   belong in, and because C9 outranks the colour rungs the damage
   surfaced at the first rung below it that happened to differ. An
   "ours scores better on C<n>" verdict points at the first DIFFERING
   rung, which is not necessarily the faulty one - check whether
   anything above it is misgated before believing the criterion itself
   is wrong.

   **That held a second time, on the same rung.** The 40 residual cases
   catalogued in engineering-log.md surfaced at C12 (19) and C13 (3), with the rest
   tying outright - and C9 was reported as 0 vs 0, "not differing", which
   reads like evidence that the rung is irrelevant and is not. A rung
   switched OFF on both sides scores zero on both sides, and that is
   indistinguishable in the adjudicator's output from a rung with nothing
   to say. C9's first-bracket gate was false for every one of those cases;
   making it true fixed 39. So extend the lesson: a rung reading 0 vs 0 is
   not exonerated, only silent, and WHY it is silent is worth establishing
   before believing the first rung that does differ.

5. **`deviation` and `spread` are not FIDE criteria.** They sit mid-ladder
   in the deleted per-bracket weight function and did the work the handbook assigns to a
   different mechanism entirely - §3's transposition and exchange
   procedure, which picks among pairings that are already equal on every
   criterion by taking the smallest transposition of the natural order.
   Replacing these two with that procedure is the largest remaining gap,
   and the one this project's TODO has long described as "approximate
   bracket-ordering vs FIDE's exact transposition search".

6. ~~**C5 is not enforced explicitly.**~~ **Closed.** The prediction that
   "these coincide in ordinary cases; whether they can diverge has not been
   tested" turned out to be testable and false. Diffing JaVaFo against
   bbpPairings/Gacrux surfaced a 5-player round-2 case where the 0.5
   bracket held two players who had already met: keeping the top bracket
   whole left the bye on a 0.5 player when a 0.0 player was reachable, and
   the 2026 answer breaks the top bracket up because C5 is ABSOLUTE and C6
   is only quality. Now implemented as `bye_assignee_score/2`, a single
   whole-field matching run before any bracket is paired -- affordable only
   because the bracket matcher is polynomial now.

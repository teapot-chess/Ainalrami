# C.04.6 Swiss Team Pairing System - conformance notes

Working notes on the FIDE Swiss Team Pairing System **effective 1 February
2026** ([handbook](https://handbook.fide.com/chapter/SwissTeamPairingSystem202602)),
written before any code exists so the reading can be checked against the
regulation rather than against an implementation.

Checking the effective date first is deliberate: the individual rules were
rewritten in the same February 2026 wave.

This paragraph used to continue "and every reference implementation still
carries the pre-2026 reading of Article 5.2.5", and offered that as part of
the case for reading the regulation before reading an implementation. **The
claim was false.** The FIDE Systems of Pairings and Programs Commission
ruled on 2026-08-27 that the references' behaviour is what the current text
requires and that this engine's reading was the wrong one - see
[dispute-initial-colour.md](dispute-initial-colour.md) and Article 4 below.
Reading the regulation first is still the right method for this chapter,
where no reference exists to read at all; it was never a licence to
discount an implementation that disagreed. The version-till page for this
chapter exists too; this document is about the current one.

## The short version

**It is not the Dutch system applied to teams.** The preface says the
Basic Rules apply *mutatis mutandis*, but C.04.6 defines its own criteria
set, its own bye rule, and - most importantly - its own *procedure*.

Three structural differences from C.04.3, each of which changes the
implementation:

| | individual (C.04.3) | teams (C.04.6) |
|---|---|---|
| criteria | C1-C21 | C1-C3 absolute/completion, C4-C10 quality |
| bracket procedure | best candidate under a lexicographic weight ladder | **first** candidate in a defined enumeration order |
| score | one score | **two** - primary and secondary |

## Article 2 - the criteria

**Absolute (2.1)**

* **[C1]** Two participants shall not play against each other more than
  once.
* **[C2]** A team that has already received a pairing-allocated bye or won
  a match by forfeit (or been given a FIDE-deprecated full-point bye)
  shall not receive the pairing-allocated bye.

**Completion (2.2)**

* **[C3]** A pairing complying with all the absolute criteria shall always
  exist for all teams not yet paired.

**Quality (2.3), in descending priority**

* **[C4]** Minimize the count of upfloaters.
* **[C5]** Minimize score differences in pairs involving upfloaters.
* **[C6]** Unless the following scoregroup has been emptied by upfloating,
  choose the upfloaters so that [C1], [C3] and [C4] can still be complied
  with in the bracket where that scoregroup is paired.
* **[C7]** Minimize upfloaters who were floaters in the previous round
  (except in the last two rounds).
* **[C8]** Minimize teams whose colour preference is not fulfilled.
* **[C9]** Minimize teams whose STRONG colour preference is not fulfilled
  (Type B only).
* **[C10]** Minimize upfloaters' opponents who were floaters in the
  previous round (except in the last two rounds).

Nine rungs against the individual system's twenty-one, and [C6] is the
only one that reaches forward into a later bracket.

## Article 3 - the procedure

**3.3 Round-pairing outlook.** Assign the bye (3.4); combine the
top scoregroup with upfloaters into a bracket and pair it (3.6); repeat
until every team is paired; then allocate colours (Article 4).

**3.4 The bye** goes to the team with, in order: the lowest score (3.4.2),
then the highest number of matches played (3.4.3), then the largest TPN
(3.4.4) - subject to 3.4.1, that the remaining teams can still be legally
paired. It is worth as many match points **and** game points as a draw.

**3.6 Bracket pairing.** This is the part that decides the architecture.

> A pairing is a sequence of pairs that includes all teams in the bracket.
> For each pair, the team with the smaller TPN is the top member; the team
> with the larger TPN is the bottom member.

The pairing's *identifier* is the top members' TPNs in ascending order,
followed by their corresponding bottom members' TPNs. Pairings are ordered
**lexicographically by that identifier**, and the procedure takes the
**first** one complying with [C1], [C8], [C9] and [C10].

So the regulation defines an ORDER and a PREDICATE, not a scoring
function. There is no weight ladder to maximise here and no matching
problem to solve - which means `Ainalrami.WeightedMatching` is not
involved in team pairing at all.

## Article 4 - colours

* **4.1** The initial-colour is drawn by lot before round one.
* **4.2** The *first-team* of a pair is the one with the higher primary
  score, else the higher secondary score, else the smaller TPN.
* **4.3** Descending priority. **4.3.1**: when both teams have yet to play
  a match, if the first-team has an **odd TPN** it takes the
  initial-colour, otherwise the opposite. "Odd TPN" is the article's own
  wording and is quoted here as such; which number that parity is actually
  taken on is the point the SPP settled, immediately below.
  4.3.2-4.3.9 then apply colour
  preferences, strong preferences (Type B), colour difference, historical
  alternation, and the first-team's preference.

The board-one colour cascades to the remaining boards.

> **4.3.1 is the same TPN-parity rule as the individual 5.2.5**, and that
> rule was put to the SPP (see
> [spp-question-initial-colour.md](spp-question-initial-colour.md)) and
> **answered on 2026-08-27, against this engine.**
>
> The parity is *not* taken on the TPN as the file gives it. It is taken on
> a numbering that counts only the participants who have arrived,
> recomputed each round. The SPP's reasoning is C.04.2 Article 2.4: a late
> entry is "given an appropriate TPN and paired only when they actually
> arrive", so a participant who has not arrived holds no TPN at all. Both
> reference implementations already did this and were right to.
>
> The crux is worth carrying here rather than only in the dispute
> document, because it is the part a future reader can use. **Both sides
> argued from that same sentence.** This project's case was "the TPN
> exists before the arrival; it is the *pairing* that waits". The SPP
> reads the identical clause as "no TPN until arrival". We read it the
> wrong way round.

It applies here unchanged, and the team side implements it now:
`TeamPairing.pair_round/2` builds the round's numbering once via
`Colour.parity_numbers/1` and threads it through `Colour.allocate/3`'s
`:parity_numbers` option to `initial_colour_by_parity/2`.

This document warned that team colour allocation should not be finalised
before the answer arrived, or it would be built twice. **The warning was
written and then ignored.** Article 4.3.1 was implemented on the reading
the SPP overturned - `initial_colour_by_parity(first.tpn, initial)`, under
a moduledoc asserting that line was "the single line that would change" -
and the ruling rewrote it. The change was four functions, not one line:
`Colour.parity_numbers/1` is new, `decide/5` became `decide/6`,
`allocate/3` grew the `:parity_numbers` option, and
`TeamPairing.pair_round/2` with `allocate_colours/5` (now `/6`) changed to
build the numbering and carry it down. Article 4 was built twice, exactly
as predicted, by the project that predicted it. Writing the warning down
was not the same as acting on it, and this paragraph exists so the next
reader does not mistake a recorded risk for a managed one.

What the individual ruling does **not** settle is what "arrived" means for
a TEAM. C.04.6 has no Article 2.4 of its own, and `%Team{}` carries no
per-round history, so a team's arrival is not reconstructible from the
struct the way a player's is from their TRF game list. The engine's
numbering is therefore position in ascending TPN over exactly the list
`pair_round/2` is handed: roster membership, nothing else.

For a team that has NEVER arrived that is the right answer - a host that
omits it gets the renumbering for free, and a host that keeps it in the
list would have it paired.

For a team that arrived and is then **absent** - sitting a round out, or
withdrawn after playing - it is the wrong one, and it is a defect rather
than a licensed difference between the two chapters. The individual rule
keeps such a player numbered forever (`Pairing.arrived_for?/2`'s second
clause: participated in any earlier round). Nothing in C.04.6 says teams
should behave differently; the team side loses the number only because the
absent team is not in the list, and everyone below it silently shifts. It
is reachable inside 4.3.1's own window: a team that takes the
pairing-allocated bye in round 1 has arrived with zero played matches, and
if it sits round 2 out it can still meet 4.3.1 in round 3 with the wrong
parity for every team below it.

`Colour` cannot fix that - the absent team is not in its scope at all - so
the fix belongs on `TeamPairing.pair_round/2`, as an explicit roster or
absentee argument distinct from "the teams to pair this round".

**Fixed 2026-09-13 (branch `team-swiss`):** `pair_round/2` takes
`:absent`, the TPNs of teams that have arrived but are not in this round's
field, and `Colour.parity_numbers/2` numbers them without pairing them. The
host holds the round-by-round record, so the host names them; a host that
omits the option gets the old numbering.

## Type A and Type B

A per-competition setting, defined in Article 1.7. Type A is used unless
the competition's own rules say otherwise (or say colour preferences are
not used at all). Type A grades preference on a coarser threshold; Type B
distinguishes STRONG from mild preferences, and **[C9] exists only under
Type B**. Both must be selectable per tournament; neither is a default we
get to choose for the arbiter.

## Scores

Article 1.2: the competition states which of *match points* and *game
points* is the primary score, and whether the other is used for colour
allocation. **The default is match points primary, game points for
colours.** Both are needed - a team model carrying only one cannot express
4.2, and the bye pays in both.

## Board order is NOT specified

The regulation never says how a team orders its own boards, nor whether
that order may change between rounds. That is explicitly left to the
competition. It is therefore ours to model, and it should be a stored,
arbiter-editable property rather than anything derived - deriving it would
invent a rule FIDE deliberately declined to write.

## Performance, from the start

Naive enumeration is fatal, and it is worth being explicit about why: a
bracket of 2n teams has (2n−1)!! pairings. Ten teams is 945; twenty is
6.5×10⁸; forty is about 10²². **Round one is a single bracket containing
the entire field**, so the worst case is not exotic - it is the first
round of any ordinary event.

The regulation is not asking for enumeration, though. It defines an order
and asks for the first element satisfying a predicate. The implementation
must therefore:

* **generate lazily in identifier order** and stop at the first hit -
  never materialise the set;
* **prune on prefixes**: a partial pairing that already repeats a pair
  ([C1]) kills the whole subtree below it, and the subtree is enormous;
* **short-circuit the common case**: with no history, round one's first
  candidate is the natural pairing and satisfies everything, so the
  expected cost is a handful of candidates rather than a search;
* **answer [C3] with a completability oracle** rather than by trying -
  this is a matching-feasibility question, and the individual engine
  already has the shape of the answer in `oracle_completable?`.

That last point is the one place a matching algorithm still earns its
keep: not to *choose* a pairing, but to certify that a choice leaves the
rest of the bracket pairable.

Target: a team round should be well inside a millisecond for realistic
field sizes, because the work is a short walk down a generator, not a
search. If it is ever slow, the pruning is wrong, not the approach.

## Is any of this required?

**No.** Endorsement is granted per pairing system, not per program:
C.04.A says "the endorsement is given for the specific pairing systems
(one or more)", and the bar is being able to manage Swiss tournaments
using the FIDE (Dutch) System *or any other approved system* - at least
one. So C.04.6 is a separate, optional endorsement, and team support is a
product decision rather than a prerequisite for FE1 on the Dutch system.

Worth knowing before spending the effort, and worth re-reading before
starting: nothing below is blocking anything.

## Verification: no reference we can automate against

Team pairing is not unsolved - **Swiss-Manager** does team Swiss and team
round-robin, is FIDE-endorsed, is used by 180+ federations, and is what
pairs the Olympiad and most national leagues. It is also closed-source
Windows software, so it cannot be read, run headless, or diffed against a
generated corpus.

What that leaves is no *automatable* oracle. Checked, rather than
assumed:

| | teams? |
|---|---|
| bbpPairings 6.0.0 | **no** - no team code at all; `--dutch` and `--burstein` are both individual |
| JaVaFo | no |
| Gacrux (`pairingchecker.py`) | no |
| SWAR 6.65 | **no** - searched for `Team` AND the French `Equipe`; neither appears anywhere, and there is no team tournament type. It is an individual-tournament program, which is a surprise for the Belgian tool given the interclub is team-based |

This inverts the method that made the individual engine trustworthy: there
is no oracle to run a corpus against, so "we agree with bbpPairings across
millions of tournaments" is unavailable here.

**The good news is that the regulation hands back something stronger.**
For the individual system, exhaustive verification was impossible in
principle: C.04.3 defines a sequential procedure, not a global optimum, so
"which whole-round pairing scores highest" is a question with no defined
answer (see
[conformance-c0403-2026.md](conformance-c0403-2026.md), "Why that test is
harder than it looks"). Here the opposite holds. Article 3.6 defines the
answer *as* the first element of an enumerable order - so for a bracket
small enough to enumerate exhaustively, a test can BE the definition:
generate every pairing, sort by identifier, filter by the criteria, and
assert the engine returns the head.

That is a proof, not a correlation. It is available for small brackets
today and does not depend on anyone else having implemented the rules.

The corpus still has a role, but a different one: fuzzing for crashes,
[C1]/[C2] legality violations, and [C3] dead ends - properties that hold
regardless of which candidate is chosen.

## Reading decisions the implementation had to make

Written while building `lib/ainalrami/team_pairing.ex`, so these are the
places the text ran out rather than places nobody looked.

### [C5]'s score profile, and the 3.5.4 example that contradicts it

2.3.2 reads: "Minimise the score differences (taken in descending order) in
the pairs involving upfloaters, i.e. maximise the scores (taken in ascending
order) of the upfloaters." Taken at face value, a set of three upfloaters
should take the three highest-scoring candidates available.

The example under 3.5.4 says otherwise. It assumes 2, 6 and 8 have 3 points
and 1, 3 and 5 have 2.5, states that three upfloaters are needed, and then
says "[C5] determines that two upfloaters must have 3 points and the other
2.5" - dropping one of the three available 3-pointers for a 2.5-pointer,
which is a *larger* score difference. It asserts that step rather than
deriving it, and no other article visible in the chapter forces it.

**The implementation follows the article, judged over legal sets**
(`TeamPairing.c5_profile_key/2`, reached only for sets that pass
`legality/3`): [C5] takes the best score profile among the sets of the
[C4]-minimal size whose bracket can be paired and whose remainder can too.
With no history the example's position produces {2,6,8}; if {2,6,8} cannot
be paired, it produces the example's {2,6,1}. The example's own ORDERING -
`{2,6,1} < {2,6,3} < {2,6,5} < {2,8,1} < ...` - is implemented and tested
exactly as written.

Pinned both ways in `team_pairing_test.exs`: "[C5] takes every top-scoring
candidate when it can" and "the 3.5.4 example exactly as printed: {2,6,8}
cannot be paired, so {2,6,1}".

The [C6] explanation this section once suggested is **ruled out** by the
research findings below: 3.5.5 has [C4]/[C5] met "by construction" before
[C6] is looked at, and the same example is in the 2024 edition, which had
no "unless ... empty" clause.

**The first cut got [C4] and [C5] the wrong way round**: it fixed the
profile from raw scores and, when no set with that profile was pairable,
grew the set by two. That broke [C4] to keep [C5]. Fixed 2026-09-13.

### 3.6.4 names minimisation criteria as if they were predicates

"Choose the first pairing that also complies with criteria [C1], [C8], [C9]
and [C10]." [C1] is a predicate. The other three are minimisations, and no
single pairing complies with a minimisation in isolation - it complies by
achieving the minimum attainable over the bracket's legal pairings.

So `Bracket.pair/2` minimises `{c8, c9, c10}` lexicographically and
tie-breaks by identifier order. That is the same statement made computable:
the first compliant pairing in identifier order IS the lex-smallest
identifier among those achieving the minima. The practical consequence is
that the walk cannot always stop at the first legal candidate - though it
stops immediately on `{0,0,0}`, which cannot be beaten and which round one
and most ordinary brackets hit on the first try.

**Since 2026-09-25 the rest is exact, not budgeted.** The walk is kept only
as a fast path to its first candidate (the first legal pairing in
identifier order); when that scores `{0,0,0}` it is the answer. Otherwise
two minimum-cost perfect matchings decide it - one for the least
`{c8, c9, c10}` and the lexicographically first top set, one confined to
that top set for the first bottom sequence - with the criteria and the
identifier packed into one integer cost (method:
`docs/team-proof-large-fields.md` section 3). The matcher is the engine's
own `Ainalrami.WeightedMatching` (bbpPairings' Galil/Micali/Gabow lineage).
Before this the walk continued under a candidate budget (200,000) and a
step budget, keeping the best found, and on large early-round brackets that
was a legal round 3.6 does not choose. `:max_candidates` and `:max_steps`
are still accepted and now ignored.

### [C7] is a minimisation applied to a choice between sets

2.3.4 minimises upfloaters that were floaters in the previous round, and
3.5.5 asks for "the first set that ... complies with [C6] and [C7]".

**What this section used to say was not what the code did.** It described
legality plus [C6] as a gate with [C7] "acting as part of the ordering".
In fact `workable?/3` checked only that the bracket could be paired: not
[C3] for the teams outside it, not [C6] (whatever its comment said), and
[C7] had no effect whatsoever.

Since 2026-09-13 `TeamPairing.select_upfloaters/4` applies, in 2.3's order:
[C4] (the smallest size with a legal set - bracket pairable AND the rest
pairable, [C1] and [C3]); [C5] among those; then the least [C6] excess
(`c6_excess/4`: how many more upfloaters than the parity minimum the
following scoregroup's bracket would need, [C1]/[C3]/[C4] there, zero
when that scoregroup is emptied); then the least [C7] count
(`c7_previous_floaters/2`, zero in the last two rounds); then 3.5.4's order.

The two readings question 7 put to the SPP ("rank by [C7], then 3.5.4" and
"the first set in 3.5.4's order achieving the minimum") choose the same set.
The reading that differs, and is rejected, is "the first legal set in 3.5.4's
order whatever its [C7] count" - the first cut's behaviour.

## Research findings, 2026-09-13 (not SPP rulings)

A research pass answered open questions 5-7 from the 2024 edition's edit
history, Double-Swiss C.04.5 and Dubov C.04.4.1 from the same 2026 wave,
TRF-2026, the 2026 Olympiad regulations and the Swiss-Manager guide. No
published event could be checked: Olympiads are paired by the Olympiad
Pairing Rules, and Swiss-Manager only switched its team Swiss to Gacrux in
July 2026.

| Q | Reading implemented | Where | Confidence |
|---|---|---|---|
| 5 | [C5]'s best profile among LEGAL sets ([C3] kept) of the [C4]-minimal size; the 3.5.4 example holds when {2,6,8} cannot be paired. Not [C6]. | `TeamPairing.c5_profile_key/2`, `legality/3` | medium-high (high that it is not [C6]) |
| 6 | A match is won by forfeit when the opponent played no game in it (every board forfeited). One game played makes it a played match, which does not bar the bye. The winner scores every board (Held, *Mastering the TPS* 2026: `0F-4F`). | the host's `%Team{won_by_forfeit?: _}`; documented on `Team` | high; medium for matches forfeited by decision after play |
| 7 | Minimise [C7] among compliant sets, then 3.5.4's order. | `TeamPairing.c7_previous_floaters/2` | high |

Evidence in brief. **Q5:** the example is word for word in the 2024 edition
and in Double-Swiss, both with the same maximin [C5]; 3.5.2's note says the
criteria "somehow" determine the count and scores, and Dubov 2026 says the
count is the minimum "needed to obtain a legal pairing". **Q6:** 2024's
[C2] said "without playing"; Double-Swiss, which shares the 2026 wording,
says a match "ends by forfeit only if at least one player forfeits both
games" and treats partial forfeits as played; TRF-2026 record 330 is "one or
both teams didn't show up", a team showing up "if at least one player is
present"; the 2026 Olympiad defines an unplayed match as one where "all
games were scored as defaults". **Q7:** 2.3 says "as much as possible ...
in descending priority", "the first X that complies with [a minimisation]"
is the chapter's standing phrasing (3.6.4), Dubov 2026 says "complies at
best", and 2026 moved floater avoidance up into set selection.

The match's game points are no longer inferred: Mario Held's *Mastering the
FIDE Team Pairing System* (FIDE TEC, 2026), the worked example of C.04.6,
gives "the opponents of absent players ... a forfeit win fully equivalent
to a victory on-the-board" and scores a team that "did not show in time to
play" `0F-4F` (round 4) - every board to the team that came.

C.04.2 3.5 also settles a point the host needs (and Held's round 4 repeats
it: the forfeited pairing "may be repeated in a future round"): "two paired participants,
who did not play their game or match, may be paired together in a future
round" - a match forfeited as a whole is not a meeting for [C1].

## Large fields, 2026-09-16

On 2026-09-14 the team engine was run on generated events of 100-500 teams
and 9-15 rounds. It broke no rule, but it gave up with `:budget_exhausted` on
6 of 150 events, all at 200-500 teams in rounds 11-14, and at 300-500 teams
30% of rounds took more than 10 s (the slowest was 500 teams, round 1).

The search was changed so it asks cheaper questions, not different ones:

- whether a set of teams can be paired at all is answered by a maximum
  bipartite matching (`TeamPairing.Matching`) instead of by enumerating
  pairings;
- facts about the field that do not change during a round (who has met whom,
  colour state) are computed once per round (`TeamPairing.Field`) instead of
  once per candidate;
- upfloater sets are generated in the order the rules already rank them, so
  the first acceptable set is found without ranking every set first.

Which set, which pairs and which colours the rules pick is unchanged. The
pre-change bracket walk is kept as test support (`TeamBracketReference`) and
diffed against the new one on generated brackets, and the matching and
feasibility checks are tested against brute force.

**Same pairings, byte for byte.** 350 generated events (seeds 1-350, sizes
100/200/300/500, 9-15 rounds) were recorded on the old engine and on the new
one and compared with `:erlang.term_to_binary` round by round: **4,156 rounds
and 533,093 matches, 0 differences.** The 11 events the old engine could not
finish were compared up to its refusal; the new engine paired every one of
those rounds and finished the event.

| | old engine | new engine |
|---|---|---|
| budget refusals, 350 events | 11 | **0** |
| round time, seeds 1-150: median | 2.7 s | **0.14 s** |
| p95 | 29.1 s | **1.4 s** |
| max | 76.9 s | **2.6 s** |
| rounds over 10 s | 501 of 1,814 | **0** |
| 500 teams: median / max | 21.6 s / 76.9 s | **1.0 s / 2.6 s** |
| whole run, seeds 1-150 | 1,468 s | **69 s** |

Both timed on the same 16-core desktop at `+S 10`. The old engine's run had
profiling work alongside it, so its times are somewhat pessimistic; a clean
re-timing was started and not finished. The shape does not depend on that:
the new engine's slowest round in all 350 events is 5.3 s.

**Not proven:** the 11 rounds the old engine refused have no reference answer,
so for those only the absolute criteria are known to hold, not that the
chosen pairing is the rules' first choice. Fields that large are beyond the
brute-force reference.

## Open questions

* ~~**4.3.1 and the TPN-parity dispute.** Blocked on the SPP reply. Build
  the rest first.~~ **Closed 2026-08-27**: answered against this engine,
  and implemented on the team side (Article 4 above). This was the only
  item on the team system whose *correct answer* was unknown rather than
  merely unwritten, so team-pairing validation no longer has a colour
  question hanging over it - the small-bracket exhaustive proof covers who
  plays whom, and colour now has a settled rule to test against instead of
  a pending one.

  Nothing measured in this document moves as a result, for the plain
  reason that nothing here was ever measured: C.04.6 has no automatable
  oracle (see above), so there is no team corpus to re-run. The individual
  side's disputed-board counts do move, and re-measuring them is that
  side's work, not recorded here.
* ~~**The absent team's number (4.3.1).**~~ **Closed 2026-09-13**:
  `pair_round/2`'s `:absent`. See Article 4 above.
* **Board order.** Unspecified by FIDE; a product decision for the host
  (OpenPairings: the Teams page's roster order).
* ~~**Forfeited matches.**~~ **Answered 2026-09-13** by research (question
  6 above): the opponent played no game in the match. The host computes it.
  The game points of such a match have a source since 2026-11-09: Mario
  Held, *Mastering the FIDE Team Pairing System* (FIDE TEC, 2026, ver.
  2607090900), the worked C.04.6 example, scores round 4's no-show ("Team
  #8 did not show in time to play, thus forfeiting the match") `0F-4F`:
  every board to the team that came, "a forfeit win fully equivalent to a
  victory on-the-board". The same example says the pairing "may be
  repeated in a future round", that game points serve only 4.2.2 and the
  first tie-break, and that the PAB is 1 MP and 2 GP. The generator writes
  such a match on the players' lines too (TRF-2026 330 Notes 1 and 2) as
  well as in the `330`.
* **Questions 5-7** are answered by research, not ruled on. Still worth
  sending to the SPP with the wording in OpenPairings'
  `docs/teams-phase-2-plan.md`.
* ~~**What a TRF26 team Swiss code says (checker, 2026-09-27).**~~
  **Closed 2026-09-27** by FIDE's own Tournament Type Code Table for
  TRF_CODE 192, published by the TEC with TRF-2026
  (tec.fide.com/trf-2026). The first reading (R1) took a code without
  `TYPEA`/`TYPEB` as Type A, 1.7's default. The table says otherwise:

  | code | the table's meaning |
  |---|---|
  | `FIDE_TEAM_TYPEA_*` / `FIDE_TEAM_TYPEB_*` | Type A / Type B colour preferences |
  | `FIDE_TEAM_MP_GP`, `_GP_MP`, `_MP`, `_GP`, `_MP_GP_BAKU`, `_MP_BAKU` | **no colour preferences** |
  | `..._X_Y` | X primary, Y secondary "to be used in colour allocation" |
  | `..._X` | X primary, the secondary score not used |
  | `FIDE_TEAM` / `FIDE_TEAM_BAKU` | `FIDE_TEAM_TYPEA_MP_GP` / `FIDE_TEAM_TYPEA_MP_GP_BAKU` |

  So the question the entry left open - whether a code without the type
  means 1.7's third option - is answered yes, and the engine now has that
  mode (*No colour preferences* below). `Ainalrami.TypeCode` holds the whole table's
  reading; `Ainalrami.TeamReplay` replays with it.
* **Which board is board 1 in a TRF (checker, 2026-09-27).** 1.6.1 reads a
  team's colour off its first board. A TRF names no boards unless it
  carries TRF26 `300` records; the checker takes the
  first player in `310`/`013` order who met somebody, as the team
  tie-breaks already do. A file whose teams shift their board order
  between rounds without `300` records will show colour differences that
  are not there. Since 2026-10-03 `300` records are read: board 1 is the
  record's first board, and a team colour read off a lower board is turned
  round on every even board (team colours alternate down the boards).

## No colour preferences (1.7), 2026-09-27

Article 1.7: "Type A colour preferences are used unless the rules of the
team competition specify that either Type B colour preferences shall be
used, or colour preferences are not to be used at all." The third option is
`TeamPairing.pair_round/2`'s `type: :none`, and the text defines it without
needing a reading:

* **No team has a colour preference** (`Team.preference/3` is `:none`).
  1.7.1 and 1.7.2 are the only definitions of a preference, and neither is
  used.
* **[C8] and [C9] count nothing** - they minimise unfulfilled preferences,
  and there are none. 3.6.4's first pairing complying with [C1], [C8],
  [C9] and [C10] is then the first legal one in identifier order with the
  least [C10].
* **Article 4.3 without its preference rules.** 4.3.2 ("if only one team
  has a colour preference"), 4.3.3 (opposite preferences), 4.3.4 (Type B
  strong) and 4.3.7 (the first-team's preference) have nothing to act on
  and never fire. 4.3.1 (neither team has played: the initial colour by
  parity), 4.3.5 (White to the lower colour difference), 4.3.6 (alternate
  from the last time the two differed), 4.3.8 and 4.3.9 (alternate the
  first-team's, then the other team's, last colour) do not mention a
  preference and allocate every colour. The colour difference (1.6.2) is
  still counted - it is a definition of its own, not a preference.

Nothing else in the chapter reads a preference: the bye (3.4), the
upfloater selection (3.5, [C4]-[C7]) and [C10] are unchanged.

**Validation.** The brute-force whole-round reference
(`test/support/team_proof/naive_reference.ex`) takes the type, and the
whole-round test (`team_pairing_validation_test.exs`) plays generated
events of 4-10 teams without preferences: 30,000 events (seeds
1-30,000, `TEAM_VALIDATION_NONE_SEEDS`), 123,593 rounds, every one the
reference's pairing, bye and colours, recorded reasons included. The suite
runs 120 seeds and fails if 4.3.2, 4.3.3, 4.3.4 or 4.3.7 ever decides a
colour; hand-worked positions pin the bracket that Type A's [C8] moves
off the first identifier and no-preferences keeps, and 4.3.5, 4.3.6,
4.3.8 and 4.3.9 each deciding. The checker replays engine-paired
no-preference files clean, and the same files read as Type A (the first
reading) differ in 20 of 46 events.

## Validation, 2026-09-13

`test/ainalrami/team_pairing_validation_test.exs`:

* **A brute-force whole-round reference**, written from Articles 3.4-3.6
  and 4 without sharing code with the engine, agrees on 371 reachable rounds
  of 4-10 teams (generated by playing events through the engine with random
  results, whole-match forfeits, byes and teams sitting out): 259 with an
  upfloater bracket, 192 with a bye, 105 with an absent team.
* **Absolute criteria** on generated events of 12, 17, 24, 31, 40 and 60
  teams, every round: [C1], [C2], [C3], a bye exactly when the field is odd,
  and every board's colours against the reference Article 4.
* **Hand-worked positions** for [C3], [C4] (an even scoregroup that needs
  upfloaters; [C4] over [C5]), [C5] (both variants of the 3.5.4 example),
  [C6], [C7], [C6] over [C7], [C10] and 3.6.3.
* **Mutation check**: removing [C3]'s look past the bracket, [C6], [C7],
  [C5]-over-legal-sets, [C4]'s growth for even scoregroups, the absent
  numbering, [C2]'s forfeit clause, 4.3.1's parity, 4.3.5 or [C10]'s
  per-team count each fails at least one test. The whole-round reference
  alone catches [C3], [C5], [C7], [C2] and 4.3.5; it does **not** catch
  [C6] or the absent numbering (the generator rarely reaches positions they
  decide), which only the hand-worked tests pin.

Not done: the large-field crash and budget fuzz on the fuzz server.

Since then the same whole-round test has run on seeds 1-250,000,000
(1,032,949,115 rounds, 0 failures, 2026-09-26), and an exact reference
covers fields up to 80 teams ([team-proof-large-fields.md](team-proof-large-fields.md)).
Totals: [validation.md](validation.md#team-swiss-pairings-c046).

## The engine reports its reasons (`explain: true`)

`TeamPairing.pair_round/2` with `explain: true` adds `:explanation` to its
result; everything else in the result is unchanged. Shape and bound are in
`Ainalrami.TeamPairing.Explanation`'s moduledoc. What it records, and the
reading behind each:

| Decision | Recorded | Where it is recorded |
|---|---|---|
| The bye (3.4) | teams [C2] took out and which clause (a previous bye, a forfeit win); the eligible teams the engine tried first and found would strand the rest (3.4.1); the next eligible team and the first of 3.4.2 / 3.4.3 / 3.4.4 on which the bye ranks ahead of it | the 3.4 walk itself (`choose_bye/3`) |
| Upfloaters (3.5) | per bracket: every set considered, in order, with its [C4] size, [C5] profile (scores ascending), [C6] and [C7]; sets rejected because no legal pairing exists, as `"C1"` (the bracket cannot be paired) or `"C3"` (the teams below cannot); sizes at which every set was rejected; the chosen set, the runner-up and `decided_by` | the 3.5 walk (`best_set_of_size/6`) |
| Colours (Article 4) | per pair, the clause of 4.2 that named the first-team and the clause of 4.3 (4.3.1-4.3.9) that gave it its colour | `Colour.allocate_explained/3`, which `allocate/3` now calls |

**What "decided by" means.** The first criterion, in 2.3's priority, on
which the chosen set beats the runner-up - the best other set of the same
size that can be paired: `"C5"`, `"C6"`, `"C7"`, or `"3.5.4"` when they tie
on all three. When no other set of that size can be paired it is `"C4"`: any
alternative would need more upfloaters. That includes a scoregroup that
floats nobody in (the empty set is the only set of size zero).

**Finding the runner-up without touching the choice.** 3.5.5 takes the
FIRST compliant set, so the walk stops early and usually never examines the
set that came second. With `explain: true`, and only after the choice is
made, the engine looks on from where the walk stopped, in the same order,
for at most 50 sets: through the remaining sets with the winner's profile
(a `{0, 0}` on [C6]/[C7] ends it, nothing later can beat that), and past
them to the first legal set of a worse profile only if none was legal. A
budget or oracle limit, or the 50-set bound, ends the look with
`decided_by: nil` - the engine claims no reason it did not establish - and
never fails the round.

**The bound.** Each recorded list (per bracket `considered` and `rejected`;
for the bye `ineligible` and `passed_over`) keeps `:explain_limit` entries,
default 10, and counts the rest in `*_omitted`. The chosen set, the
runner-up, the bye's `next` and one entry per pair are always kept. So a
round's account is O(limit x brackets + pairs) whatever the field size, and
the extra work is at most fifty legality checks (with their [C6]
look-aheads) per bracket.

**Checked** (`team_pairing_validation_test.exs`, `team_pairing_test.exs`):

* on every generated round of the whole-round reference (371 rounds, 4-10
  teams), the result with `explain: true` minus `:explanation` is identical
  to the result without it, and so on every round of the 12-60 team events,
  whose accounts are also checked to stay within the bound;
* on those same 371 rounds the recorded reasons equal the brute-force
  reference's own - the bye's passed-over teams and deciding tie-break, each
  bracket's chosen set and `decided_by` (computed there from every legal
  set, not by looking past a stopping point), and both Article 4 clauses of
  every pair. Generated rounds reach C4, C5, C6, C7 and 3.5.4, all of 3.4.1-
  3.4.4, 4.2.1-4.2.3 and 4.3.1-4.3.3, 4.3.5, 4.3.6, 4.3.8 and 4.3.9;
* the hand-worked positions pin their reasons: the three 3.5.4 example
  variants (3.5.4, C5, and {2,6,8} rejected on [C1]), [C3] (the empty set
  rejected on [C3]), [C4] (an even scoregroup, and [C4] over [C5]), [C6],
  [C6] over [C7] (3.5.4 as worked, C6 with the tie removed), [C7] (3.5.4, C7,
  and off in the last two rounds), [C6] switched off (C5), 3.6.3 and [C10]
  (C4); every 4.2 and 4.3 clause, 4.3.4 and 4.3.7 included; the bound and the
  runner-up search's own bound;
* **mutation check**: swapping [C6] and [C7] in `decided_by/2`, dropping its
  [C5] clause, reporting anything but C4 without a runner-up, swapping 3.4.2
  and 3.4.3, ignoring the walk's own runner-up, skipping a worse-profile
  runner-up, not ending the look on a `{0, 0}`, and ranking runner-ups
  without 3.5.4's order each fail at least one test.

## Keeping teams apart (not FIDE), 2026-10-24

`Ainalrami.TeamPairing.pair_round/2` takes `:forbidden_pairs` and
`:soft_pairs`, the individual engine's options of the same names and
shapes: groups of team numbers, each optionally `{tpns, first, last}`.
C.04.6 has neither, so a round they change is not a C.04.6 round; the
readings below are this engine's, chosen so that FIDE's own answer moves as
little as the wish allows.

**Forbidden pairs are pairs that have met.** The only place [C1] is read
is the teams' opponents, in `Field` and in `Bracket` alike, so the
forbidden partners are added there for the pairing (and only the pairing:
Article 4 sees the teams as given). That one change reaches every question
[C1] answers - 3.4.1's "leaves a legal pairing", [C3], the [C6]
look-ahead, every bracket - and no criterion is reordered. When the
groups leave a round unpairable that pairs without them, the answer is
`{:error, {:forbidden_pairs, %{reason:, groups:, lifting:}}}` rather than
3.3.3's bare verdict, with `lifting` the groups that, lifted on their own,
let it pair.

**Soft pairs are a fourth digit in 3.6.** The bracket's answer is the
least `{C8, C9, C10}` and then the first identifier; with soft pairs it is
the least `{C8, C9, C10, soft}` and then the first identifier. Both of
`Bracket`'s paths carry it - the fast path stops early only on
`{0, 0, 0, 0}`, and the matching packs the count as a digit of base
`h + 1` below the three - and without soft pairs the digit does not exist,
so every packed cost is the integer it was. Soft pairs never reach 3.4 or
3.5: the bye and the upfloaters are chosen exactly as FIDE chooses them.
The individual engine's `:strong` placement (above C6) has no team
counterpart on purpose - above 3.5 it would buy a wish with a FIDE
criterion.

**Evidence.** `test/ainalrami/team_keep_apart_test.exs`: 300 played events
of 4-10 teams (1,185 rounds) with random hard and soft groups against
`NaiveReference`, which reads both options from the description above, 0
disagreements; no forbidden pair seated; every soft round with FIDE's
bye, brackets, floaters and criteria, no more soft pairs than FIDE's
answer, and FIDE's answer itself whenever that seats none. Plus the case
it was built for: sixteen teams from six clubs over five rounds, round one
pairing 3-12 and 4-11 instead of 3-11 and 4-12. The whole-round validation
without groups runs unchanged.

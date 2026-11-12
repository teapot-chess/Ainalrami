# The Dutch bracket cascade: a specification

What `Ainalrami.Pairing` computes for a round after the first, written
from the regulations rather than from any implementation:

* C.04.3, FIDE (Dutch) System, effective 1 February 2026
  (<https://handbook.fide.com/chapter/C0403202602>);
* C.04.2, General handling rules for Swiss tournaments (late entrants,
  byes, forfeits, acceleration);
* the readings recorded in this repository, which are binding where the
  text leaves a choice: [conformance-c0403-2026.md](conformance-c0403-2026.md),
  [fide-criteria.md](fide-criteria.md), the 5.2.5 ruling
  ([spp-question-initial-colour.md](spp-question-initial-colour.md),
  `Pairing.arrival_numbers/2`), and the readings listed in section 9 below.

Round one, colour allocation (Article 5) and the input rules (who is
active, what a score is, floats, acceleration) are specified where they are
implemented and are not repeated here. This document covers the part
between the scores and the colours: which players meet.

Article numbers are C.04.3's unless stated. "Rank" is the Article 1.2
order: score descending, then pairing number ascending. Section 9 lists
every place where the text admits more than one reading and says which one
the engine takes.

## 1. What a round is made of

The **field** is every player active this round, in rank order. A player's
score is their points plus this round's acceleration (C.04.2 / C.04.7).
A **score group** is the players of one score.

The field is odd or even. An odd field gives exactly one pairing-allocated
bye (PAB); an even one gives none.

Brackets are paired from the top. A **bracket** is the players carried down
from the bracket above - the moved-down players, MDPs - followed by the
next score group, its **residents**. The score group after the residents is
the bracket's **next group**; everything below it is the **field below**.
Positions inside a bracket follow rank, so MDPs come first.

A bracket fixes some pairs and **carries** the rest of its members into the
next bracket. Pairs are fixed only between two members of the bracket.

## 2. The PAB score, fixed before any bracket (C4, C5, C2)

C5 asks for the PAB to go to the lowest score possible. It is decided once,
over the whole field, before the first bracket, and is then a constraint
(conformance note 3 records that this is equivalent to treating C5 as the
top comparison, given that the value is achievable).

Call two players **compatible** when they may meet: they have not played
each other (C1; only played games count), the arbiter has not forbidden the
pair, and they do not share an absolute colour preference unless the
final-round topscorer exception of C3 lets them.

On an odd field, consider the matchings of the field. Rank them, highest
priority first, by:

1. the number of compatible pairs, largest first;
2. among the players left without a compatible partner, the best one to
   give the bye to: a player C2 allows before one it does not, then the
   lowest score;
3. the number of pairs formed wholly inside the top score group, largest
   first.

Incompatible pairs are allowed in this ranking (they count for nothing in
1), so that a field whose compatible pairs cannot cover all but one player
still yields a ranking. The **PAB score** is the lowest score among the
players a best matching leaves out of its compatible pairs; when every
player is covered the PAB score is undefined and C5 constrains nothing.

The same matching decides the **first bracket's C9 gate** (section 6): it is
open when the PAB score is at least the top score and no top-group player's
partner in that matching scores below the top score. The third ranking
term exists for this: it makes the answer the same in every best matching.

An even field has no PAB score, and the first bracket's gate is shut.

## 3. The criteria, as a value per pair

Each criterion C5-C21 is, for one candidate pairing of one bracket, a count
or a score to be made as small or as large as possible. Every one of them
except C9's bye term is a **sum over the pairs** of the candidate, so it can
be written as a value on each possible pair, with the candidate's value the
sum of its pairs' values. The engine compares candidates on these sums in
priority order. This section defines the value of a pair `{a, b}`, `a` the
higher ranked, as seen from the bracket being paired.

The pair's **reach** is 0 when `b` is a member of the bracket, 1 when `b` is
in the next group, and 2 or more below that. Every value below is "larger
is better".

| rung | value | span |
|---|---|---|
| completion and PAB eligibility (C4, C2, C5) | `1 + [a not a bye candidate] + [b not a bye candidate]` | `3 * (n + 1)` |
| soft avoidance, strong position (not FIDE) | `[pair not soft-avoided]` | 2 |
| C6 pairs in the bracket | `[reach = 0]` | `n + 1` |
| C7 scores of the paired | `place(score a)` when reach = 0 | place span |
| C8 pairs in the next bracket | `[reach = 1]` | `n + 1` |
| C8 scores in the next bracket | `place(score a)` when reach = 1 | place span |
| C9 the PAB assignee's unplayed games | `u(a) + u(b)` when the bracket's C9 gate is open | `(n + 1)^2` |
| C10 topscorer colour difference | when reach = 0 | `n + 1` |
| C11 topscorer same colour three times | when reach = 0 | `n + 1` |
| C12 colour preference granted | when reach = 0 | `n + 1` |
| C13 strong colour preference granted | when reach = 0 | `n + 1` |
| C14 downfloat repeated from round r-1 | when reach = 0 | `2 * (n + 1)` |
| C15 upfloat repeated from round r-1 | when reach = 0 | `n + 1` |
| C16 downfloat repeated from round r-2 | when reach = 0 | `2 * (n + 1)` |
| C17 upfloat repeated from round r-2 | when reach = 0 | `n + 1` |
| C18-C21 the same four, by score difference | when reach = 0 | place span |
| soft avoidance, weak position (not FIDE) | `[pair not soft-avoided]` | 2 |

`n` is the field's size. A span is one more than the largest sum the rung
can reach over a matching, so packing the rungs as digits of a mixed-radix
number (each rung's sum times the product of the spans after it) compares
two matchings exactly as comparing their rung sums one by one would.

The terms:

* **Bye candidate** (C2, C5): a player C2 allows to take the PAB and whose
  score is at most the PAB score. On an even field there is no PAB score;
  a bye candidate is then an eligible player on zero. The leading `1`
  counts pairs, so the rung prefers more pairs before anything else and,
  on an odd field, a bye candidate as the player left over.
* **Place** of a score: the score groups of the round, lowest first, as
  digits of a mixed-radix number whose radix for each group is one more
  than its size. A bigger score is a bigger place, and a sum of places over
  a matching compares like the list of the paired players' scores taken
  from the top (C7's "scores ... in descending order").
* **u(p)** (C9): for a player on the PAB score, the rank of their count of
  played games among the players on that score, most games first (so the
  rung, maximising, prefers pairing the players with more unplayed games
  and leaves the bye to the one with the fewest); 0 for anyone else. Equal
  counts share one rank.
* **C10-C13** (colour), with `p` the lower-ranked player's colour state
  and `o` the higher's, "clash" meaning both prefer the same colour:
  C10 is `not (both colour differences beyond ±1 and clash)`; C11 is
  `not (both absolute and clash)`, or the clash is the lesser one (the
  less unbalanced player is not the one whose repeated colour it would
  extend; equal imbalance: they do not repeat the same colour); C12 is
  `not clash`; C13 is `not clash`, or at most one of them holds a strong
  or absolute preference, or both hold absolute ones.
* **C14-C17** (float repeats): C14 is the number of the two players who
  downfloated last round and are now paired inside their own score (the
  lower player always, the higher one when the pair does not cross
  scores); C15 is `not (the pair crosses scores and the lower player
  upfloated last round)`; C16 and C17 the same two rounds back.
* **C18-C21**: when the pair crosses scores, the place of the higher
  player's score, granted to C18/C20 when the higher player downfloated
  one/two rounds ago, and to C19/C21 unless the lower player upfloated
  one/two rounds ago; zero when it does not cross.

A pair of reach 1 scores only the completion rung, C8 and the soft rung
(and C9 when its gate is open); one of reach 2 or more only the
completion rung, the soft rung and C9. Two MDPs are never a pair of the
bracket: the rules seat an MDP against a resident or nobody (3.3).

A pair is a **possible pair** of the bracket when the two are compatible
(section 2) and, inside the bracket, not two MDPs.

## 4. Pairing one bracket

The regulations generate candidates in a fixed sequence and take the
first perfect one, or the best, with earlier generation as the last
tie-break (3.4-3.8). The engine does not enumerate. It describes the same
choice as a sequence of filters over a set of matchings and computes each
filter on a matcher. This section defines the filters; section 5 how they
are computed.

### 4.1 The optimal set

Take as vertices every player not yet paired this round: the bracket, the
next group and the field below. Every possible pair is an edge, valued by
section 3 as seen from this bracket. Let **Ω** be the set of matchings of
maximum packed value. Every matching in Ω is equally good on C5-C21 and on
completion; the filters below choose among them, in the order Articles 3.7
and 4 generate candidates, and each keeps a non-empty subset of Ω.

Seeing the field below is what makes C4 and C8 answerable: a bracket's
choice is only allowed to cost the field below what it must.

### 4.2 Which MDPs are paired (3.2, 3.7, 4.4)

The MDP-sets of 4.4 are ordered by their smallest differing pairing
number, which ranks a set that pairs a better-ranked MDP ahead of one that
does not. So: for each MDP in rank order, if some matching left in Ω pairs
it with a resident, keep only those matchings. This is the set the
candidate sequence reaches first among the best candidates.

Every matching in Ω pairs the same number of MDPs of each score (C7's sum
of places fixes it), so within one score the filter picks the
lexicographically first set of that size, and across scores it does
nothing.

### 4.3 The MDP-Pairing (3.3.1, 4.2)

S1 is the selected MDPs, S2 the residents. 4.2 orders transpositions of S2
lexicographically over the opponents of S1 in order. So: for each selected
MDP in rank order, keep the matchings that give it the best-ranked resident
any matching left gives it.

### 4.4 The remainder and its halves (3.2, 3.3.2)

The **remainder** R is the residents not seated against an MDP, in rank
order. Every matching left pairs the same number of R's members with each
other (C6 fixes the total); call it `r`. S1 is R's first `r` members, S2
the rest.

### 4.5 Exchanges: how many and how far (4.3.1, 4.3.2)

In a matching, call a member of R **paired down** when its partner is a
later member of R; let L be the set of R's paired-down members (one per
pair inside R, so `|L| = r`). A candidate generated after exchanging `x`
players between S1 and S2 has `|S1 \ L| = x`, and 4.3.2's difference of
the exchanged sums is `sum(L) - sum(S1)` in remainder positions, with
`sum(S1)` fixed. So: keep the matchings with the fewest members of S1 not
paired down, and among those the smallest sum of the positions of L.

### 4.6 Who leaves S1 (4.3.3)

4.3.3 prefers the exchange whose largest differing player moving out of S1
is largest. So: for each member of S1 from the last to the first, while the
number of leavers chosen is below `x`, if some matching left does not pair
it down, keep only those (it leaves S1).

### 4.7 Who joins S1 (4.3.4)

4.3.4 prefers the smallest differing player moving into S1. So: for each
member of S2 in order, while more than one joiner is still to be chosen,
if some matching left pairs it down, keep only those (it joins S1). The
last joiner is then forced by 4.5's sum.

### 4.8 The remainder's pairing (3.3.2, 4.2)

L is now the same in every matching left: these are the new S1, and the
rest of R the new S2. For each member of L in rank order, keep the
matchings that give it the best-ranked partner any matching left gives it.

### 4.9 The bracket's result

After 4.8 every matching left agrees on every pair inside the bracket. Those
pairs are fixed. Everyone else in the bracket is carried, and their
partners in the remaining matching - the **tentative** matching, which the
filters do not determine - matter only to the next bracket's C9 gate
(section 6).

## 5. How the engine computes the filters

The engine keeps one maximum-weight matcher for the round
(`Ainalrami.WeightedMatching`). Each edge weighs its packed criteria value
times a **reserve** `R = 2 (n+1)^3`, plus a smaller term used only to steer
the search (section 8). A filter adds, below `R`, a small value to the
edges whose use it prefers and solves again: a maximum-weight matching then
lies in Ω and, among those, maximises the added value. The values below
are chosen so that their sum over any matching stays under `R`, and no
filter can outvote a criterion.

A question about one player ("is there a matching left that pairs this MDP
inside the bracket?") is asked with a **probe**: a one-unit change on that
player's edges, then a solve. Its answer is **committed** before the next
question:

* a **hold**: a bonus kept on the edges the answer needs, larger than all
  the questions after it can add;
* a **cut**: an edge no matching left uses gets weight zero;
* a **fix**: once a partner is known, the pair is locked (each end keeps
  that one edge).

A probe that answers "no" is left in place: its edges are in no matching
left, and the filters only narrow the set.

* 4.2: per MDP, a probe of +1 on its resident edges; a yes is held with
  `|bracket| + 1` on those edges. How many MDPs of each score are paired is
  read once from the matching (it is the same in all of Ω).
* 4.3: per selected MDP, each open resident's edge gets the hold plus one
  more than the residents ranked below it; the solve gives the seat, which
  is fixed.
* 4.5: on each pair inside R, a value of its earlier member's position
  `p`: `2 (U [p in S1] - p)` with `U = |R|^2 + 1`. Summed over a matching
  that is `2 (U |S1 ∩ L| - sum(L))`.
* 4.6: per S1 member from the last, a probe of -1 on its edges to later
  members of R; a leaver's edges to later members are cut.
* 4.7: per S2 member from the first, a probe of +1 on the same edges; a
  joiner's edges to earlier members of R are cut. Its edges to the next
  score group are not: C6 already keeps every matching left off them
  (reading 9).
* After 4.7 every edge inside R that does not run from a member of L to a
  later member outside L is cut, and 4.5's values are removed.
* 4.8: per member of L, each later open member of R gets one more than the
  members ranked below it; the solve gives the partner, which is fixed.

Probes run on even values (4.5 doubles its layer), so a one-unit probe
always falls between two values the filters distinguish.

When a weight change leaves the matching the matcher holds still optimal,
the engine moves dual values instead of searching (the matcher checks the
claim and refuses otherwise), and in the certified mode it reads answers
it can prove are the same in every optimum. These are speed only: the
corpus holds them to the plain computation (docs/performance.md).

## 6. Carrying forward, and the C9 gate

C9 "applies to brackets downfloating exactly one player, who will receive
the PAB". The engine opens a bracket's C9 gate, and scores C9's rung there,
only when:

* the field is odd and has a PAB score;
* the bracket's next group exists and the PAB score is at least its score;
* the bracket above carried no player whose tentative partner scores below
  the next group (if one did, the float runs deeper than one group and the
  PAB is not this bracket's single downfloater).

The last condition is read over the bracket above and its next group: for
every player of either that the bracket above did not pair, the score of
their tentative partner, an unpartnered player counting as their own. The
first bracket's gate comes from section 2.

## 7. Completion

If the brackets end with more unpaired players than the round has byes, a
leftover C2 forbids the bye, or a leftover scoring above the PAB score, the
round is repaired by one whole-field matching ranked by: pairs; leaving
over a player C2 allows; leaving over one at most on the PAB score; keeping
the brackets' pairs; the colour, float and equal-score criteria; and last
an order of our own that makes the answer unique (section 8). If no
matching pairs enough players the round is refused.

## 8. Ties, and what decides them

Everything in section 4 is decided by the criteria and the filters: every
pair the engine fixes is the same in every optimum. Three things are not,
and for each the engine decides by a rule of its own:

* **The search's steering term.** Below the decision band every edge
  carries `n - |gap|`, the gap measured between the two players' positions
  in the field (inside a bracket, measured from half the bracket's size).
  It changes no answer the filters determine; it keeps the search short.
* **The tentative matching below a bracket**, read only by the C9 gate.
  The certified mode proves the gate's answer the same in every optimum
  or falls back to the plain computation; the plain computation reads the
  matcher's answer.
* **The completion repair** (section 7) adds a last band that orders every
  matching strictly: a pair `{i, j}`, `i < j` in field order, adds
  `(n + 1)^(n - 1 - i) * (n - j)`. Of two optima the one whose first
  differing player has the earlier partner wins, which no other optimum
  ties.

## 9. Readings

Each of these is a point where the text leaves room, and the choice the
engine makes. They predate this document; they are recorded here so the
specification is complete. The measured evidence is in the documents
cited.

1. **C5 is a constraint**, from a whole-field pre-pass (section 2;
   conformance note 3).
2. **The pre-pass ranks bye eligibility by C2 alone**, not by the PAB
   score it is computing, and breaks ties toward pairs inside the top
   group (section 2).
3. **On an even field a bye candidate is an eligible player on zero**
   (section 3). The rung then counts pairs and nothing else on any field
   where everyone has scored.
4. **The completion rung counts pairs, above C6.** `AINALRAMI_COMPLETION=
   eligibility` drops the count; it is an experiment, not a reading the
   engine stands behind, and under it a lowest band counting pairs
   decides what the rung no longer does.
5. **C8 is scored on the next score group only**, with the field below
   visible but not scored (section 3, reach).
6. **C9's unplayed-game ranks share a rank on equal counts**, and the
   rung is scored only behind the gate of section 6.
7. **The C9 gate is cleared by tentative partners**, read over the
   previous bracket and its next group (section 6).
8. **Two MDPs never meet inside a bracket** (3.3: an MDP is seated against
   a resident or carried).
9. **The halves are committed by cuts inside the remainder only**
   (section 5): a joiner keeps its edges to the next group, which C6
   already forbids it to use.
10. **Article 5.2.5** decides on the higher ranked player's arrival
    number, per the SPP ruling.
11. **Forfeited games do not forbid a rematch** (C1 counts played games).
12. **A bye exclusion or a bye preference** (organiser deviations, not
    FIDE) makes a player ineligible wherever C2 would.

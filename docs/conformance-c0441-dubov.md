# C.04.4.1 Dubov System - conformance notes

Working notes on the FIDE Dubov System, **edition approved by the Council
on 28/10/2025 and applied from 1 February 2026**, as built in
`Ainalrami.Dubov` (2026-10-31). The rule text used is the local handbook
mirror, `Desktop/fide-handbook/text/C040401202602.md` (mirrored 2026-09-04
from handbook.fide.com). The design that preceded the code, with the
ambiguities first listed, is `docs/design-other-swiss-systems.md` §1.1.

No second Dubov implementation of the 2026 edition was available to compare
with. The engine is therefore held to a **brute-force reading written
separately from the rule text** (`test/support/dubov_reference.ex`) and to
the absolute criteria directly, the method the team engine used for
C.04.6 (`docs/conformance-c0406-teams.md`). Agreement with a reference
written by the same hand from the same readings proves the procedure is
implemented as read, not that it is read right; the readings below are
where it could be read differently, and four of them are with the FIDE SPP.

## The short version

| | Dutch (C.04.3) | Dubov (C.04.4.1) |
|---|---|---|
| procedure | best candidate under a weight ladder | **first** candidate in a defined order, after choosing upfloaters by the criteria |
| ranking inside a bracket | TPN | White seekers by **ARO** (1.7), then TPN |
| ratings | optional | **required** (1.1.1); an unrated player needs a provisional one (1.1.2) |
| [C3] | topscorers excepted | **no exception**: a round can be unpairable where Dutch pairs it |
| colours | 5.2.1-5.2.5 | the same ladder, 1.6.4 gives every player a preference |

## Readings

Each reading is implemented, named in the code where it applies, and held
by the reference. **Asked of the FIDE SPP on 2026-10-31, answer pending:
D2, D4, D5, D7.**

### D1 - 4.4.1's "Article 2.2.4" is 3.2.4

4.4.1 refers to "the manoeuvres described in Article 2.2.4". 2.2 has no
2.2.4 (2.2 is the completion criterion [C4]); the shifts it describes are
3.2.4's. Read as a typo for 3.2.4. Nothing else fits the sentence.

### D2 - 3.2.6 is literal: the first legal transposition (SPP, pending)

3.2.2 chooses the upfloaters by how well the *best* bracket pairing meets
[C5]-[C10], [C7] (colour preferences) included. 3.2.6 then takes the
*first* transposition of G2 that gives a legal pairing, where legal is only
[C1], [C3] and [C4]. Two readings:

* **(a)** 3.2.6 as written - the first legal transposition. **Implemented.**
* **(b)** "legal" also means reaching the [C7] value 3.2.2 assumed.

**They cannot part.** In a bracket of White seekers W and Black seekers B
(every player has a preference, 1.6.4) a pair denies a preference exactly
when both seek the same colour. 3.2.4 shifts p players out of the smaller
subgroup S, p being the fewest pairs inside S any legal pairing has, then
q = p + (|L| - |S|)/2 of the larger L's own players the other way. After
both steps every pair is one from each new subgroup, and is S-native vs
L-native (granted), S-native vs shifted-S (denied), shifted-L vs L-native
(denied) or shifted-L vs shifted-S (granted). With t pairs of the last kind
the bracket denies p + q - 2t preferences and holds p - t pairs inside S;
p is the least possible, so t = 0, and every legal transposition denies
exactly p + q - 3.2.2's [C7]. The argument is in `Ainalrami.Dubov.Bracket`'s
moduledoc and rests on D3.

Both are built. `Ainalrami.Dubov`'s `@default_transposition_rule
:first_legal` is the one line to change for (b), and the option
`transposition_rule: :first_reaching_c7` selects it per call. Tested both
ways: `dubov_test.exs` pins each on a constructed partition where they
differ, and checks they agree on generated events; the whole-round
validation pairs every round under both, and the reference runs both
literally and counts the rounds where they part (`d2_splits`). It has
never counted one.

### D3 - 3.2.4's second step moves the larger subgroup's own players

3.2.4(a) moves the p unavoidable players out of the smaller subgroup into
the larger; (b) then equalises by moving q players the other way. 4.3
defines a shift as moving "players seeking a colour ... to the subgroup of
players initially seeking the other colour", so (b) moves players of the
larger subgroup's **own** colour - never the (a) movers back. q = (l - s)/2
+ p (l, s the original sizes), the design's formula.

"Must unavoidably be paired together" is a minimum over all legal pairings
of the bracket: a maximum-weight matching (`Graph.max_cross/3`).

### D4 - an upfloat is a played game against a higher score (SPP, pending)

1.8 and [C8]-[C10] do not say what an unplayed game is. Read: a player
upfloated in a round when they **played** a game in it against an opponent
whose score was higher when the round was paired. A forfeit (either way)
and the pairing-allocated bye are not upfloats. C.04.3 settles its own
floats otherwise (a bye or forfeit win is a downfloat there); Dubov names
only upfloats and says nothing, so only what happened over the board
counts.

### D5 - the ratings the file holds now (SPP, pending)

ARO (1.7) is "the ratings of the opponents" with no date, and 1.2.2 lets
ratings change before round 4. Read: the rating each player holds in the
file now, the one the TPNs are computed from, for every opponent whenever
they were met; an unrated player's provisional rating (1.1.2) likewise.
`XXO round-ratings` (per-round ratings, read for the C.07 tie-breaks) is
not used by the pairing.

### D6 - [C6] is the team engine's [C5] score profile, over legal sets

[C6] says "minimise the score differences (descending)" and then "maximise
the upfloaters' scores (ascending)". For one bracket the residents share a
score, so the two coincide. Read as C.04.6's [C5] was
(`docs/conformance-c0406-teams.md`, "[C5]'s score profile"): the best
profile - upfloaters' scores in ascending order, as high as possible -
among the **legal** sets of 3.2.1's minimal size (bracket pairable,
remainder pairable), never a better profile bought with an illegal set.

### D7 - virtual points count everywhere (SPP, pending)

With Baku (`FIDE_DUBOV_BAKU` is in the TRF26 `192` table), "score" and
"points" - scoregroups, the bye's lowest score, the upfloater order, an
upfloat's "higher score", 5.2.1's "more points" - include the round's
virtual points (C.04.7 is for "any Swiss system"). Dubov does not say;
Burstein 1.7.2 says so for its own index.

### D8 - an unpairable round is refused

[C3] (no two players with the same absolute colour preference meet) has no
topscorer or last-round exception, so a round can have no legal pairing
where Dutch pairs one. 1.9.3 leaves it to the Chief Arbiter. The engine
returns `{:error, :no_legal_pairing}` (or `:no_legal_bye` when nobody can
take the bye and leave the rest pairable) and pairs nothing, as the team
engine does; the CLI exits 1 with the reason.

### D9 - 5.2.1's parity on the arrival numbering

5.2.1 gives the higher ranked player of two who have not played the
initial colour "if their TPN is odd". The SPP ruled on 2026-08-27, on the
identical sentence in the Dutch system's 5.2.5, that a late entrant has no
TPN until it arrives (C.04.2 Article 2.4): the parity is taken on
`Ainalrami.Pairing.arrival_numbers/2`. Carried over unchanged.

### Smaller readings

* **[C9]** "minimise the number of times a maximum upfloater is
  upfloated" is the sum, over the set's maximum upfloaters, of their
  previous upfloats.
* **3.1.4** "has played the highest number of games" counts games played
  over the board (the same "played" as 1.7's ARO), not rounds attended.
* **1.6.1** lists both absolute triggers. When they disagree - a colour
  difference past ±1 and the last two games the other colour - the
  difference decides, the order 1.6.1 states them in and the Dutch
  engine's.
* **5.1** With no `152`, the initial colour is read off round 1, the way
  5.2.1 must have given it; with no round 1 either, White.
* **[C8]-[C10]** "unless it is the last round" is the round count the file
  declares (`142`/`XXR`); it is therefore required.

## What is reused

As the design said (§2): the team engine's compatibility graph
(`TeamPairing.Field`, its [C4] feasibility and minimum-crossing answers,
`TeamPairing.Matching.bipartite_perfect?/3`), the weighted and cardinality
matchings, and from the Dutch side input checking, [C2] bye eligibility,
arrival numbers, and the TRF result helpers. The Dutch engine's own code
is untouched; its suite and golden corpora are unchanged.

## Validation (2026-10-31)

`test/ainalrami/dubov_validation_test.exs` plays generated events
(`test/support/dubov_events.ex`: rated fields, provisional ratings, Baku,
late entrants, half-point byes, forfeits, forbidden pairs, both initial
colours) and pairs every round four ways - the engine and the reference,
each under D2 (a) and (b) - and asserts all four agree, refusals included;
a second test checks the absolute criteria directly on 12-40 player
fields. `tools/dubov_validation_run.exs` is the same at scale, resumable,
in chunks.

| run | fields | seeds | rounds compared | disagreements |
|---|---|---|---|---|
| tool, chunked | 4-10 players | 1..100,000 | 447,984 | 0 |
| tool, chunked | 11-12 players | 1..10,000 | 59,961 | 0 |
| **total** | | | **507,945** | **0** |

D2 splits (the two readings parting, engine or reference): 0, on the
direct 20,000-seed run (89,237 rounds) and in every run of the test.

Over those 20,000 seeds the procedure was exercised as follows: 196,530
brackets, 121,184 with upfloaters and 19,463 with two or more, 4,463
3.2.4(a) shifts and 77,278 3.2.4(b) shifts; colours decided by 5.2.3
35,865 times, 5.2.4 4,441 and 5.2.5 39,543.

The reference is sensitive: removing 4.3.3's middle-out numbering, or
zeroing [C10], each made it fail within the default 150 seeds.

Re-run: `elixir tools/dubov_validation_run.exs --last 100000` (sizes via
`DUBOV_VALIDATION_SIZES=4..10`), or `DUBOV_VALIDATION_SEEDS=1..2000 mix test
test/ainalrami/dubov_validation_test.exs` (the default is seeds 1..150, sizes
4..10, in every `mix test`).

## Not built

* A Dubov proof (`--proof`), and Dubov's own `-x` / alternatives: refused.
* Burstein (C.04.4.2) and Lim (C.04.4.3): `--system=` refuses them.
* OpenPairings wiring (design §5).

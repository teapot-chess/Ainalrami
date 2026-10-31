# Design: the other FIDE Swiss systems (Dubov, Burstein, Lim)

Status: **Dubov built** (branch `dubov`, 2026-10-31; readings and validation in `docs/conformance-c0441-dubov.md`). **Burstein built** (branch `burstein`, 2026-10-31; `docs/conformance-c0442-burstein.md`). Lim: design only. Written 2026-10-31 against
Ainalrami main at `7916279` (v0.48.0) and OpenPairings main at `8dda1052`.

Rule texts used: C.04.4.1 Dubov, C.04.4.2 Burstein and C.04.4.3 Lim, all
"approved by the Council on 28/10/2025, applied from 1st February 2026",
from the local handbook mirror (`Desktop/fide-handbook/text/C040401202602.md`,
`C040402202602.md`, `C040403202602.md`, mirrored 2026-09-04 from
handbook.fide.com). Also C.04.1 (Basic rules), C.04.2 (General handling rules,
PDF in Downloads) and C.04.7 (Accelerated systems). The TEC Manual draft
and VCL4THP v13 in Downloads say nothing about these three systems (searched,
no hits).

Wherever this says "guess", it is one.

---

## 0. Why bother, in one paragraph

C.04.2 Article 1.4 (2026): FIDE's Swiss systems "are deprecated, unless a
tournament handler program approved by FIDE is available for them, provided
with a free pairing-checker able to verify tournaments run with that
system." The only endorsed programs on the current lists are endorsed for
the Dutch system (Swiss-Manager 13, Swiss Master, Swiss-Chess; Vega once
had a Dubov endorsement from 2006 under the old rules). No free checker
exists for the 2026 texts of any of the three. bbpPairings implements
"a previous version of the Burstein system", self-described as flawed and
not endorsed (its README); Gacrux/TieBreakServer only *names* `FIDE_DUBOV`
and `FIDE_BURSTEIN` in `trf2json.py`. A free CLI that pairs and checks the
2026 Dubov or Burstein would be the only one.

---

## 1. The rules

Common to all three (C.04.1): no rematch (Art. 2), PAB rules (Arts. 3-4),
colour difference within ±2 and no three-in-a-row unless the system says
otherwise (Arts. 6-7). C.04.2 3.4 (unplayed rounds drop out of the colour
history: BWBuW reads as uBWBW) applies to all three; Dubov and Burstein
cite it explicitly in 5.2.4.

### 1.1 Dubov (C.04.4.1)

**Goal** (0): equalise the ARO of players within a scoregroup by pairing
low-ARO players against high-rated opponents.

**Inputs the Dutch engine does not need**: every player's rating (1.1.1;
a provisional one from the CA if unrated, 1.1.2), and ARO (1.7): mean
rating of over-the-board opponents only, rounded to nearest, .5 up; 0 for a
player with no games (1.7.3). MaxT = 2 + floor(Rnds/5) (1.8.2), so the
number of rounds must be known.

**Brackets** (1.3): residents of one scoregroup plus *upfloaters* from any
lower scoregroup. There are **no downfloaters**: a bracket's residents are
all paired inside it, with upfloaters added as needed.

**Colour preference** (1.6): absolute (|CD| > 1, or same colour in the
last two rounds played), strong (CD = ±1), mild (CD = 0, alternate). Same
classes as C.04.3 and as `Ainalrami.Pairing.colour_stats/1`. **Different**:
a player with no games has a *mild preference for Black* (1.6.4), not
"none".

**Criteria** (2):
- absolute: [C1] no rematch, [C2] PAB eligibility, [C3] two players with the
  same absolute preference never meet - **no topscorer exception**, unlike
  the Dutch C3;
- completion: [C4] the players not yet paired can still be paired;
- quality, in order: [C5] fewest upfloaters; [C6] upfloaters' scores as high
  as possible (ascending profile); [C7] fewest players denied their colour
  preference; [C8]-[C10], *not in the last round*: fewest maximum upfloaters,
  fewest upfloats of maximum upfloaters, fewest upfloaters who upfloated last
  round.

**Procedure** (1.9, 3):
1. PAB (3.1): eligible under [C2], leaves the rest pairable ([C4]), lowest
   score, most games played, largest TPN.
2. Scoregroups top down (1.9.2). For each:
   - 3.2.1: the minimum number of upfloaters for a *legal* pairing
     (legal = [C1], [C3], [C4]).
   - 3.2.2: of the sets of that size, the one whose bracket "complies at best"
     with [C5]-[C10]; ties broken by the set order of 4.2 (pool = all
     lower-score players, numbered by score desc then TPN asc; sets compared by
     smallest differing sequence number, 4.1.3).
   - 3.2.3: G1 = White seekers, G2 = the rest; if *nobody* in the bracket has
     played, G1 = first half by TPN.
   - 3.2.4: re-composition. (a) If players of the smaller subgroup (G1 on a
     tie) must unavoidably be paired together, shift as many players as there
     are such pairs to the other subgroup; (b) then equalise sizes by shifting
     from the larger. "Best" set = first in the 4.3 order that gives a legal
     pairing complying at best with [C7].
   - 3.2.5: S1 = G1 sorted by ARO asc, then TPN asc.
   - 3.2.6: T2 = the first transposition of G2 (4.4: lexicographic on TPN asc)
     giving a legal pairing S1[i]-T2[i].
3. Shifter order (4.3): White seekers by ARO asc then TPN; Black seekers by
   TPN; sequence numbers assigned **from the middle outwards** (worked
   7-player example in 4.3.3: D, C, E, B, F, A, G).

**Colours** (5.2), in order: both unplayed → the higher-ranked (more
points, then lower TPN) gets the initial colour if their TPN is odd, else
the other; grant both; grant the stronger; alternate from the latest round
where they differed; grant the higher-ranked's preference.

**Byes, late entrants**: only the PAB above. A late entrant has ARO 0 and
a mild Black preference.

**Dubov ambiguities**
- **D1** 4.4.1 refers to "the manoeuvres described in Article 2.2.4". No
  such article exists; 3.2.4 is meant. Typo.
- **D2 (substantive)** 3.2.2 picks the upfloater set by the *best* bracket
  pairing under [C5]-[C10], but 3.2.6 then takes the *first legal*
  transposition, where legal is only [C1]/[C3]/[C4]. [C7] is not
  constant across transpositions after a shift: a shifted Black seeker in G1
  meeting a shifted White seeker in G2 gets both preferences; meeting a
  native G2 Black seeker, one is denied. So the pairing 3.2.6 produces may
  score worse on [C7] than the one 3.2.2 assumed when it chose the set.
  Two readings: (a) 3.2.6 is literal, first legal transposition; (b)
  "legal" includes the [C7] optimum fixed in 3.2.4. Must be decided, and
  probably asked of the SPP. Guess: (a) is the text, (b) is the intent.
- **D3** 3.2.4(a): "must unavoidably be paired together" is a minimum over
  all legal pairings (a matching question, answerable), but the remedy
  moves players *out of the smaller subgroup into the larger*, which widens
  the imbalance that (b) then undoes. Moving k players and then equalising
  is well defined but odd; the text does not say whether the (b) movers may
  be the (a) movers moved back.
- **D4** "Upfloated" (1.8, [C8]-[C10]) is not defined for unplayed games.
  If an upfloater's game is forfeited, or a player gets the PAB, is that an
  upfloat? C.04.3 settles this for its own floats; Dubov says nothing.
- **D5** Which rating: ARO is "the ratings of the opponents" with no date.
  If ratings change before round 4 (1.2.2 recalculates TPNs), is a past
  opponent counted at their old or new rating? Guess: the current one, the
  same rating the TPN uses.
- **D6** [C6] wording mixes "minimise score differences (descending)" and
  "maximise upfloater scores (ascending)"; these coincide for one bracket
  (same resident score), so harmless. C.04.6's analogous [C5] profile needed a
  reading decision (`docs/conformance-c0406-teams.md`, "[C5]'s score
  profile"), and the same one should be used here.
- **D7** With Baku (`FIDE_DUBOV_BAKU` exists in the TRF-26 192 table),
  "score" for scoregroups, the PAB's "lowest score", the upfloater order and
  5.2.1's "more points" presumably includes virtual points (C.04.7 is
  "used with any Swiss system"), but Dubov does not say. Burstein 1.7.2
  says so for its index only.
- **D8** No exception for the last round or topscorers to [C3]: a round
  can be unpairable where Dutch would pair it. 1.9.3 leaves it to the CA.
  The engine must refuse cleanly, as the team engine does.

### 1.2 Burstein (C.04.4.2)

**Goal** (0): equalise opposition strength within scoregroups, measured by
an index built from tournament data only.

**Seeding rounds** (1.6): the first min(floor(Rnds/2), 4) rounds are paired
**by the Dutch system** (C.04.3). Number of rounds must be known.

**Index** (1.7, 1.8.1), after seeding: Buchholz (sum of opponents' current
scores), then Sonneborn-Berger, then TPN asc (1.8.2). **Score is not part of
the ranking** (1.8 note). Unplayed rounds (1.7.2): the round counts as a game
"against himself" with the result worth the registered points; exception:
a run of consecutive zero-point byes up to the current round counts, for
the benefit of the player's actual opponents, as draws. Virtual
(acceleration) points are excluded from the index.

**Brackets** (1.2.2): residents plus *incoming floaters* (unpaired players
from the previous bracket). Downfloat model, like the Dutch system.

**Colour preference** (1.5): as Dutch; no games = **no preference**
(1.5.4).

**Criteria** (2): [C1]-[C3] as Dubov (again no topscorer exception for
[C3]); [C4] completion; [C5] most pairs (fewest outgoing floaters); [C6]
outgoing floaters' scores as low as possible (descending); [C7] choose
outgoing floaters so the *next* bracket complies with [C1]-[C6]; [C8] fewest
players denied their colour preference. **No float-history criteria at all.**

**Procedure** (3):
1. PAB (3.1): [C2], [C4], lowest score, most games, lowest ranking by 1.8
   (index, then TPN).
2. Per bracket (3.2): maximum pairs under [C1]-[C5]; then the **first**
   pairing in the 4.3 order that is best on [C5]-[C8].
3. Order (4): BSN = in-bracket rank by 1.8. Add one virtual player with
   BSN 0 per outgoing floater. Pairing A precedes B if BSN 1's opponent in A
   has the larger BSN; tie → compare BSN 2's opponent; and so on. 0 is the
   smallest, so "floats" is each player's last choice. A 6-player, 2-floater
   example lists the order in full.

**Colours** (5.2): same ladder as Dubov, but "higher ranked" means by 1.8
(index), **not by score**.

**Burstein ambiguities**
- **B1** The cross-references are wrong: 1.7 points at "Articles 2.1.5,
  5.2.1, 5.2.5, 4.1" (2.1.5 does not exist; 3.1.5 is meant); 1.9.1 says the
  absolute criteria are in "Article 3.1" (they are in 2.1). Typos.
- **B2** The 4.3 example lists `1-3, 2-0, 4-5, 6-0` twice. A typo, but it
  is the only worked example of the order and a test built from it must
  drop the duplicate.
- **B3 (substantive)** "Played against himself": the virtual opponent's
  score for Buchholz is presumably the player's *own current score*, and for
  SB that score times the registered points. C.07 Article 16 does something
  similar with a cap and five categories; Burstein has no cap and only one
  exception. Whether C.07's machinery (`Ainalrami.Tiebreaks.Unplayed`) or a
  literal reading applies is not stated. Guess: literal, no cap.
- **B4 (substantive)** The zero-point-bye exception ("each of the ones
  gathered in previous rounds ... is considered as a draw") is about how
  the *absent player's score* looks to the people they played, i.e. it
  changes their opponents' Buchholz and SB. The text does not say whether
  this also changes the absent player's own virtual-opponent rounds, or what
  "up to the current round" means for a player who returns later (is the
  adjustment taken back?).
- **B5** [C7]'s "every criterion from [C1] to [C6] is complied with" in the
  next bracket: [C5] and [C6] are optimisations, so "complied with" must mean
  "the next bracket reaches the best it could reach with any choice of
  floaters". A one-bracket look-ahead, like C.04.3's [C7]/[C8] lineage; not
  defined beyond the next bracket.
- **B6** 5.2.1/5.2.5 rank by index, so a downfloater (higher score) meeting a
  resident with a higher Buchholz is the *lower*-ranked player for colours.
  Deliberate (1.8 note) but unusual, and the opposite of Dubov 5.2.1; worth
  confirming.
- **B7** The seeding rounds are "paired following the rules of the FIDE
  (Dutch) System". Whether the first post-seeding round's PAB rule, [C2]
  and late-entrant handling use the Dutch definitions or Burstein's is clear
  enough (Burstein's), but the *Dutch* float history accrued in seeding rounds
  is simply discarded. Not an ambiguity, a trap: the Dutch engine must be
  called with the round's state as Dutch would see it.
- **B8** Baku with Burstein (`FIDE_BURSTEIN_BAKU`): virtual points are out of
  the index (1.7.2), but scoregroups, [C6] and the PAB's "lowest score"
  are silent, as in D7. The seeding rounds are also Baku's accelerated
  rounds, so the two overlap.
- **B9** The older Burstein text had a default acceleration (bbpPairings
  applies it when no `XXA` is present). The 2026 text has none; the
  seeding rounds replace it. bbpPairings' behaviour is therefore *not* the
  2026 rules.

### 1.3 Lim (C.04.4.3)

A procedural text from 1987-1999, re-approved for 2026 unchanged in
substance. It describes what an arbiter does with cards, not an optimum.

**Compatibility** (2.1): not yet met, and no third successive same colour
and no colour difference of 3. Looser than Dutch/Dubov/Burstein: a difference
of 2 is allowed (5.6).

**Order of scoregroups** (2.2): top down to just above the **median
scoregroup** (score = half the rounds played), then the lowest group up,
the median group last, paired downward.

**Transfers before pairing** (2.3): players with no possible opponent in
the group (2.3.1-2.3.3), and one more to make the group even (2.3.4),
move to the neighbouring group: down when pairing downward, up when
pairing upward (3.2.1).

**Floater choice** (3.2-3.10): to even a group, pick the player that
balances due-White against due-Black counts (3.2.2), else the lowest-ranked
(downward) or highest-ranked (upward) player (3.2.4), restricted to
players with a compatible opponent next door (3.3-3.5), avoiding four
floater types in order (3.9) and last-round floaters for 2.3.4 (3.10). In
"Maxi-tournaments", a 100-point rating window limits floater choice
(3.2.3) and exchanges (3.8, 5.7).

**Pairing a group** (2.4, 4): top half against bottom half, 1 v n/2+1, ...;
proposed pairs are checked from the top (downward) or bottom (upward), and an
incompatible pair is repaired by exchanging the lower player, in the order
the 6-player tables of 4.2-4.3 show. A player who cannot be paired floats
(4.4).

**Blocked median group** (2.6): crack the next pairing of the lower or
higher neighbouring group, depending on which side sent more floaters,
and retry.

**Colours** (5): alternate and equalise; a second scrutiny exchanges
players for colour (5.2); same-colour-twice must alternate (5.3); ties by
colour history, then higher rank at/above the median and *lower* rank
below it (5.4); odd rounds give "one more of one colour", even rounds equal
(5.5-5.6). Last round (6): score beats colour, even three in a row or a
difference of 3.

**Round 1** (7): bye to the lowest-rated; lots for #1's colour; 1 v n/2+1
with alternating colours down the top half.

**Lim ambiguities** (many; this is the main cost of Lim)
- **L1 Terminology inverted.** "Highest numbered player" means #1 (4.2:
  "Player #1, the highest numbered player"), "lowest numbered" the weakest.
  3.7.2's parenthesis ("not always the player with the highest pairing number")
  only reads correctly under that convention. Every rule has to be read with
  it, and any summary that uses "number" in the arithmetic sense gets the
  rule backwards.
- **L2** "Maxi-tournament" is not defined anywhere in the 2026 texts. It
  needs a parameter (and a default: none, guess).
- **L3** The median scoregroup may be empty (no player on exactly half the
  rounds played), or not exist with a non-standard point system (3-1-0).
  2.2 does not say where the two directions meet then.
- **L4** No precedence between the floater rules: 3.2.2 (colour balance),
  3.3/3.4 (compatible opponent next door), 3.9 (floater types), 3.10 (no
  repeat floater), 3.2.3 (rating window). They can conflict and the text
  orders none of them except 3.9's internal list.
- **L5** The exchange order is given only for six players (4.2, 4.3). The
  general sequence for n players must be extrapolated (guess: the remaining
  bottom-half players in order, then the top-half players from the bottom
  up, as in the 4.2 table's 4, 5, 6, 3, 2).
- **L6** The second, colour scrutiny (5.2) has no search order and no
  objective beyond "if possible".
- **L7** 2.6: "the next pairing" of the neighbouring group is undefined
  (the last one made? the one nearest the median?), and there is no stopping
  rule if cracking keeps failing.
- **L8** 3.6 vs 3.6.1-3.6.3: "highest score first, then highest pairing
  number" against "higher pairing number first" and "from the highest
  scoregroup first, not always the highest pairing number". Consistent
  only under L1, and even then 3.6.3 (DF before UF in the upper half) and
  3.7.3 (UF before DF in the lower half) leave the median group's mixed case
  to 3.6.3 alone.
- **L9** 1.1 "lowest rank in the lowest scoregroup" for the PAB: rank =
  TPN (guess) or current standing? C.04.1 Art. 4 still applies but Lim does
  not say what happens if that player is ineligible.
- **L10** Unplayed games, forfeits and late entrants are not mentioned at
  all beyond C.04.2 3.4.
- **L11** Lim has **no TRF-26 `192` code.** The table has `FIDE_DUBOV` and
  `FIDE_BURSTEIN` (and `_BAKU`), not Lim, although Lim is C.04.4.3. An
  omission in TEC's table, worth reporting.

---

## 2. Reuse versus new code

What exists (Ainalrami v0.48.0): `Pairing` (Dutch, 10.6k lines, packed-weight
global cascade), `WeightedMatching` (Gabow), `CardinalityMatching` (Edmonds,
Gallai-Edmonds, completability oracle), `Matching` (bitmask DP),
`Sequence` (C.04.3 Article 4 order, independent of the engine),
`TeamPairing` (C.04.6: upfloater sets, first-in-enumeration bracket pairing,
`Field` feasibility masks), `ByePreference`, `Acceleration`, `Trf`/`TypeCode`
(the `192` codes for Dubov and Burstein are already parsed), `Proof`/
`MatchCertificate`, `Tiebreaks` (Buchholz, SB, C.07 Art. 16 unplayed rules),
`Generator`, `Alternatives`, `CLI`.

| piece | Dubov | Burstein | Lim |
|---|---|---|---|
| TRF parse/serialize, `XXR`, `XXP`, `XXA`, `XXZ`, bye letters | reuse | reuse | reuse |
| `192` code | exists (`TypeCode`) | exists | none: new extension (§4) |
| colour classes | reuse `colour_stats/1` + 1.6.4 override | reuse as is | new: Lim's compatibility is different |
| colour allocation ladder 5.2 | new small module, shared by Dubov and Burstein (same ladder, different "higher ranked") | shared | new |
| PAB | new rule, reuse completability oracle | new rule, same oracle | new |
| completability ([C4]) | reuse `CardinalityMatching` / `TeamPairing.Field` | reuse | not needed (procedural) |
| bracket solving | **port of `TeamPairing`'s shape**: upfloater-set selection by profile, then first-in-order; C.04.6 was written by the same school and its 3.5/3.6 match Dubov 3.2 closely | packed lexicographic weights on `WeightedMatching` (the Dutch technique), or fix-and-check per BSN with a matching oracle | a literal procedural simulator; no matching |
| ordering | 4.1.3 set order, 4.3 middle-out, 4.4 transpositions: new, small | 4.3 order: new, small | 4.2 exchange order: new |
| ratings / ARO | new: the Dutch engine never reads ratings | not needed | needed only for Maxi |
| index (BH, SB, unplayed) | - | new, reusing `Tiebreaks` arithmetic where 1.7.2 agrees with C.07 | - |
| seeding rounds | - | **call the Dutch engine unchanged** | - |
| proof | the matching questions it asks are certifiable with the existing `cardinality` records; the bracket choice is an enumeration, so the proof is "the order + the predicate", as for teams | weighted records reuse as is | not applicable |
| `explain`, `Alternatives` | not reused at first (Dutch-specific ladder) | same | same |

**Proposed layout** (one module per file, per AGENTS.md):

```
lib/ainalrami/swiss_system.ex          # behaviour + dispatch: :dutch | :dubov | :burstein | :lim
lib/ainalrami/swiss_colour.ex          # the 5.2 ladder shared by Dubov and Burstein
lib/ainalrami/dubov.ex                 # entry: pair_next_round/2, PAB, scoregroup loop
lib/ainalrami/dubov/aro.ex             # ratings, provisional ratings, ARO, MaxT, upfloat counts
lib/ainalrami/dubov/bracket.ex         # 3.2.1-3.2.6
lib/ainalrami/dubov/order.ex           # 4.1.3 set order, 4.3 middle-out, 4.4 transpositions
lib/ainalrami/burstein.ex              # entry: seeding dispatch to Pairing, PAB, bracket loop
lib/ainalrami/burstein/index.ex        # BH, SB, 1.7.2 unplayed rules
lib/ainalrami/burstein/bracket.ex      # [C5]-[C8] + 4.3 order as packed weights
lib/ainalrami/lim.ex                   # entry, median order, round 1
lib/ainalrami/lim/scoregroup.ex        # transfers, proposed pairs, exchanges
lib/ainalrami/lim/floaters.ex          # Article 3
lib/ainalrami/lim/colour.ex            # Article 5
```

`Ainalrami.Pairing.pair_next_round/2` stays the Dutch entry and keeps its
contract; `SwissSystem.pair_next_round(players, system: :dubov, ...)` is the
new front door, and the validation of input/options (`check_input!/2`) is
shared so every system refuses the same bad rosters the same way. If
`TeamPairing`'s set-selection helpers are generalised rather than copied,
move them to a neutral module (`Ainalrami.UpfloaterSets`) first, as a
no-behaviour-change commit covered by the team corpus.

**Cheapest and most valuable first: Dubov.**
- Its structure is C.04.6's (minimum upfloater set, profile, then the first
  in a defined enumeration), which this repo has already built, read
  closely (`docs/conformance-c0406-teams.md`) and validated over 3.5 billion
  rounds. The reading decisions taken there ([C5] profile, "complies at best"
  as a minimisation) carry over.
- The answer is *defined* as the first element of an order, so a
  brute-force reference written from the text is a proof for small brackets,
  as for teams.
- It has a `192` code, so TRF/CLI parity is free.
- It is the most used of the three (guess: Russia, parts of Eastern Europe,
  Vega's user base), and its endorsement lineage (Vega 2006) shows FIDE has
  endorsed a Dubov program before.

Burstein second (seeding is free, the bracket is a weight-ladder problem we
know how to solve, but the index's unplayed-round rules B3/B4 need a ruling
first). Lim last, and only if someone asks: the text is procedural and
under-specified (L1-L11), it has no `192` code, and two careful
implementations will differ on L4/L5/L7 regardless of how good either is.

---

## 3. Validation

### 3.1 What reference exists

| | external engine | worked examples in the text | other |
|---|---|---|---|
| Dubov | none for 2026 (Vega's 2006 endorsement predates the rewrite; Swiss-Manager probably has a Dubov mode, guess, closed Windows software) | 4.3.3 shifter order (7 players); 4.4.2 transpositions (3 players) | none |
| Burstein | bbpPairings 6.0.0 `--burstein`: **previous** version, self-declared flawed; a *control*, like JaVaFo for Dutch | 4.3 pairing order (6 players, 2 floaters; one duplicated line, B2) | seeding rounds = Dutch, so bbpPairings `--dutch` is an exact oracle for rounds 1..min(R/2,4) |
| Lim | none known (Swiss-Manager possibly, guess) | 4.2-4.3 exchange tables (6 players); 7.2 round-1 example (40 players) | none |

### 3.2 Method (all Elixir; no Python anywhere)

1. **Unit tests from the text.** Every worked example above becomes a test
   that pins the order module (`Dubov.Order`, `Burstein.Bracket` order,
   `Lim.Scoregroup` exchanges), independent of the rest.
2. **Brute-force reference, written from the text, sharing no code with the
   engine** (`test/support/dubov_reference.ex`, `burstein_reference.ex`),
   the C.04.6 pattern (`test/support/team_bracket_reference.ex`): enumerate
   every pairing of a small bracket (and every upfloater set), filter by the
   criteria literally, sort by the article's order, take the head. Whole
   rounds for fields of 4-12 players, exhaustively. This proves the
   computation, not the reading; the reading is the ambiguity list above.
3. **Random tournaments at scale.** Extend `Ainalrami.Generator` with
   `system:` (it already pairs with the engine under test, by design) and
   the `PAIRING_FUZZ_*` axes (byes, forfeits, withdrawals, late entrants,
   ratings modes, Baku, point systems). A comparison harness
   (`test/ainalrami/dubov_reference_test.exs`, tag `dubov_reference`)
   replays each round against the reference. Fields above enumeration size
   get the legality checks only ([C1]-[C4] and the colour rules, independent
   of any reference), as `validation.md`'s "Legality, independent of any
   reference" does for Dutch.
4. **Burstein specifically**: rounds 1..seed against bbpPairings `--dutch`
   (exact); later rounds against our reference; bbpPairings `--burstein`
   run as a control with its default acceleration disabled (`XXA 0.0`) and
   the differences categorised, never targeted.
5. **Checker direction** (FE1/VCL Q33 analogue): `-c` must replay a Dubov or
   Burstein file the generator wrote, and must flag a mutated pairing.
6. **Real data**: none of the Belgian files in Downloads is Dubov/Burstein
   (all Dutch, by their `192`/SWAR origin; guess from the names). If a
   Swiss-Manager installation becomes available, a few dozen hand-paired
   tournaments in each system, compared round by round, are worth more than
   a further billion generated rounds, because they test the *reading*.
7. **No reference engine (Dubov, Lim)**: the reference *is* the regulation,
   so each ambiguity becomes a named switch in the reference
   (`d2: :literal | :c7_optimal`), both readings are run, and the rate at
   which they differ is measured and reported with the SPP question. That
   number is the honest answer to "how much does this ambiguity matter".

### 3.3 Lim, separately

A reference for Lim cannot be independent in any useful sense: both would
encode the same extrapolations (L4, L5, L7). Validate the six-player tables,
the round-1 example and invariants (compatibility, colour limits, the
last-round exception), and label the system "experimental, reading
documented" rather than claiming conformance.

---

## 4. CLI and TRF parity

Every option below must work from a TRF alone (`docs/cli-parity.md`).

| setting | library | flag | file |
|---|---|---|---|
| system | `system: :dubov \| :burstein \| :lim` | `--system=dutch\|dubov\|burstein\|lim` | `192 FIDE_DUBOV` / `FIDE_BURSTEIN` (`_BAKU` → Baku); Lim: `192 CUSTOM_SWISS` plus an Ainalrami extension record (below) |
| rounds (MaxT, seeding count) | `expected_rounds:` | `--rounds=N` | `142`, `XXR` - **required** for Dubov and Burstein, refused if absent |
| ratings for Dubov | the player's rating | - | `001` rating column |
| provisional rating (Dubov 1.1.2) | `provisional_ratings:` | `--provisional-rating=12:1500/17:1400` | new `XXO provisional-rating 12 1500` (FIDE-required, so **not** warned as non-FIDE) |
| rating at the time of each round (D5 reading) | reuse round-ratings | - | existing `XXO round-ratings` |
| Lim Maxi window | `maxi: true` | `--lim-maxi` | the Lim extension record's parameter |
| everything Dutch already has (forbidden pairs, byes, Baku, points, late entrants) | unchanged | unchanged | unchanged |

Precedence: flag over file, as today. A `192` that disagrees with
`--system` is refused (exit 2), not silently overridden.

**The Lim record.** Do not use `XXS`: I believe JaVaFo's AUM uses `XXS` for
the scoring system (unverified, check the AUM before naming anything).
Proposed: `XXO system lim [maxi]`, read together with `192 CUSTOM_SWISS`,
with the `XXO` reader taught that this keyword is a FIDE system (no
"not FIDE" warning). Separately, ask TEC to add `FIDE_LIM` to the `192`
table (L11); if they do, read it and keep reading the extension.

Today `-c` exits 2 on Dubov/Burstein files ("Ainalrami pairs the Dutch
system only", `team_replay.ex`); that becomes a replay. `-g` gets
`--system=`. `-x` (explain) and the `Alternatives` flags are refused for
the new systems with a clear message until they exist.

---

## 5. OpenPairings wiring

**Data model.** Keep `pairing_system: "swiss"` (53 call sites test it
literally, and every one of them means "a Swiss": Baku, late entrants,
byes, standings). Add `swiss_system :string, default: "dutch"`, values
`dutch dubov burstein lim`, validated, meaningful only when
`pairing_system == "swiss"` and individual. Lock it after round 1
(`@locked_fields` in `settings_options_live.ex`), as `pairing_system` is.
Team Swiss stays C.04.6 only.

**Engine call.** `Pairing.dispatch_swiss/1` passes `system:` through
`ainalrami_opts/3`; Dubov needs the rating the app pairs by (the same
`rating_method` that sets TPNs) and provisional ratings for unrated players
(a per-player field or the existing rating override, guess: the override).
Requires an Ainalrami release tag bump in `mix.exs`.

**Settings UI** (Settings → Options): a second select under "Pairing
system", shown only for an individual Swiss: "Dutch (C.04.3)", "Dubov
(C.04.4.1)", "Burstein (C.04.4.2)", "Lim (C.04.4.3)". `pairing_system_label/1`
and `engine_name/1` learn the variants. Dubov shows a notice when unrated
players have no provisional rating, and pairing is refused until they do
(1.1.1 is "must").

**FIDE mode.** All three are FIDE-approved systems (C.04.4), so choosing
one is not a `:non_fide_pairing_system` departure. Two cautions from
`docs/design-fide-mode.md`:
- VCL.03/VCL.06: the word FIDE and the endorsement claim cover only the
  systems the program is endorsed for. Until Dubov/Burstein are endorsed,
  the selector should not label them "FIDE ..." and the About/endorsement
  page should list the Dutch system only. Decision for the user.
- Lim, if built as "experimental", is outside FIDE mode (a Level-3/4
  warning on selection, recorded as a departure), because the program cannot
  claim a conforming reading of L4-L7.

**TRF export** (`trf_export.ex`, `tournament_type_code/1`):
`FIDE_DUBOV`/`FIDE_BURSTEIN` with `_BAKU`; Lim as `CUSTOM_SWISS` plus the
extension record; `142` always written. **TRF import**
(`trf_import.ex` 1228: "a code this app has no system for (Dubov,
Burstein ...)"): map the codes to `swiss_system`. SWAR import/export: SWAR
has no Dubov/Burstein/Lim as far as this app knows (guess); export refuses
with a message rather than writing a Dutch file.

**Norm forms.** IT3 B17 already reads `officials["swiss_variant"]`
("Dutch | Lim | Dubov | Burstein", `norms/forms.ex`); derive it from
`swiss_system` when the official field is blank.

**What disappears or changes for a non-Dutch Swiss** (until built): the
pairing rationale page, "why not me"/"why did I float", "what if these two
met", judging an arbiter's proposal (all Dutch-ladder based): hidden with a
one-line reason, not a dead control (the Vega-report lesson in
`design-fide-mode.md` 1.1). Manual pairing and swaps still work; the
"illegal pairing" check must use the system's own [C1]/[C3].

**Manual (EN + NL)**: `priv/manual/06-pairing.md` (a section per system:
what it optimises, what the arbiter must supply, what is unavailable),
`03-tournament-setup.md` (the selector), `02-fide-mode.md` (what counts as
FIDE), `10-fide-report.md` (the `192` code), and their `nl/` twins. Plus
CHANGELOG entries, House tone.

---

## 6. Effort and build order

Estimates are guesses, in focused working days, for one implementer with
the reviewer loop this repo uses.

| step | what | estimate |
|---|---|---|
| 0 | SPP questions for D2, D4, B3, B4, B5 (exact wording, sent before code) | 0.5 |
| 1 | `SwissSystem` dispatch, shared input validation, `swiss_colour.ex`, CLI `--system`, `-c` refusal → "not yet" per system | 2 |
| 2 | Dubov: ARO/ratings, order module + text tests, bracket, PAB | 5-7 |
| 3 | Dubov reference + generator `system:` + harness; first corpus | 4-5 |
| 4 | Dubov in `-c`, proof records, docs (`conformance-c04041-dubov.md`) | 2 |
| 5 | OpenPairings: field, selector, lock, export/import, FIDE-mode labels, manual EN+NL, hidden Dutch-only pages | 4-5 |
| 6 | Burstein: index + unplayed rules, seeding dispatch, bracket weights, PAB | 5-6 |
| 7 | Burstein reference, bbpPairings seeding oracle and control run, corpus | 4 |
| 8 | OpenPairings Burstein (mostly the same switches as 5) | 1-2 |
| 9 | Lim, experimental: simulator, text tests, invariants, docs of every reading | 8-12 |

Total: Dubov end to end ~17-21 days; Burstein ~10-12 more; Lim ~8-12 more
and optional.

**Recommended order**: 0 → 1 → 2-4 (Dubov in Ainalrami, released) → 5
(Dubov in OpenPairings) → 6-8 (Burstein) → decide on Lim with real demand
in hand. Endorsement of Dubov can be requested once step 4's corpus and
the SPP's answers exist.

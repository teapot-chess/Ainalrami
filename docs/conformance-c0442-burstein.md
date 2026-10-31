# C.04.4.2 Burstein System - conformance notes

Working notes on the FIDE Burstein System, **edition approved by the
Council on 28/10/2025 and applied from 1 February 2026**, as built in
`Ainalrami.Burstein` (2026-10-31). The rule text used is the local handbook
mirror, `Desktop/fide-handbook/text/C040402202602.md` (mirrored 2026-09-04
from handbook.fide.com). The design that preceded the code, with the
ambiguities first listed, is `docs/design-other-swiss-systems.md` §1.2.

There is one other Burstein engine, bbpPairings 6.0.0's `--burstein`, and it
implements "a previous version of the Burstein system" by its own README -
a different index, a default acceleration, a different order. It is used
here as a **control**, never as the oracle. The seeding rounds, which the
2026 text pairs by the Dutch system, have a real oracle in `bbpPairings
--dutch`. The rounds after them are held to a **brute-force reading written
separately from the rule text** (`test/support/burstein_reference.ex`), the
method the Dubov system and the team engine used. Agreement with a
reference written by the same hand from the same readings proves the
procedure is implemented as read, not that it is read right; the readings
below are where it could be read differently.

## The short version

| | Dutch (C.04.3) | Burstein (C.04.4.2) |
|---|---|---|
| first rounds | - | min(floor(R/2), 4) **seeding rounds paired by the Dutch system** (1.6) |
| ranking inside a bracket | score, then TPN | **index**: Buchholz, then Sonneborn-Berger, then TPN (1.8); never the score |
| procedure | best candidate under a weight ladder | **first** pairing in 4.3's order among those best on [C5]-[C8] |
| criteria | [C1]-[C21] | [C1]-[C8]; no float history at all |
| [C3] | topscorers excepted | **no exception**: a round can be unpairable where Dutch pairs it |
| colours | 5.2.1-5.2.5, by rank | the same ladder; "higher ranked" by the **index** |
| ratings | optional | not read (after seeding) |

## How it is computed

`Ainalrami.Burstein.Bracket` pairs a bracket over one maximum-weight perfect
matching of every player still unpaired - the bracket and everybody below
it - so that [C4] (the rest stays pairable), [C5] (pairs), [C6] (floaters'
scores), [C7] (the next bracket's pairs and floaters) and [C8] (colours) are
each one digit of the edge weight, most significant first. The first
pairing in 4.3's order is then found BSN by BSN: BSN 1's opponent is the
largest BSN for which a matching still reaches the best weight, then BSN 2,
and so on, 0 (float) last. The moduledoc has the digit layout. The
reference does none of this: it lists every pairing of the bracket, every
completion, every pairing of the next bracket, and sorts.

## Readings

Each reading is implemented, named in the code where it applies, and held
by the reference. Where the reference carries the alternative as a switch,
`tools/burstein_readings.exs` measures how often it would change a round
(table at the end of this section).

### B1 - the cross-references are typos

1.7 sends the reader to "Articles 2.1.5, 5.2.1, 5.2.5, 4.1": there is no
2.1.5, and the sorting it means is 3.1.5's (the bye's "lowest ranking").
1.9.1 puts the absolute criteria "[C1] to [C3]" in "Article 3.1"; they are
2.1. Read as typos for 3.1.5 and 2.1. Nothing else fits.

### B2 - 4.3's example prints one line twice

The note lists `1-3, 2-0, 4-5, 6-0` twice. Dropped once, the list (with
the first candidate the note gives in prose) holds all 45 pairings of six
players with two floaters - C(6,4) x 3 - in exactly the order 4.3 defines,
so nothing is missing. `burstein_test.exs` checks `Burstein.Order` against
the list line by line.

### B3 - "played against himself": the player's own score, no cap

1.7.2: a round the player did not play "shall be considered as one in which
that player played against himself getting the result ... that yields the
same number of points as registered". Read literally: the virtual opponent's
current score is **the player's own current score**; Buchholz adds it, and
Sonneborn-Berger adds it times the points registered for the round. Every
unplayed round counts - the pairing-allocated bye, an arbiter's bye of any
value, a forfeit either way, an absence. C.07 Article 16's machinery (a
dummy opponent, a cap, five categories) is not imported: 1.7.2 is
self-contained and says nothing of it.

The alternative the reference carries (`b3: :nothing`): an unplayed round
adds nothing.

### B4 - the zero-point-bye exception, to the last round paired, for opponents only

1.7.2's exception: "if a player has a series of consecutive zero-point-byes
up to the current round, each of the ones gathered in previous rounds, for
the benefit of the player's actual over-the-board opponents, is considered
as a draw". Read:

* a zero-point bye is a round with no opponent, not played, scoring 0
  (`Z`, a blank, an opponentless `-`, a round with no entry); a forfeit loss
  against a real opponent is not one;
* "up to the current round" means the run reaches **the last round
  paired**: the player has not come back since. Whether they also sit out
  the round being paired is not asked (the pairing often cannot know);
* the player's real opponents - those who met them over the board - see
  their score raised by a draw's points per bye of the run; the player's own
  virtual games (B3) use their real score;
* a player who returns loses the adjustment at once, because the run no
  longer reaches the current round.

The alternative the reference carries (`b4: :current_too`): the run must
also cover the round being paired.

### B5 - [C7] is one bracket deep: the next bracket's [C5], then its [C6]

"Choose the outgoing floaters so that in the following bracket every
criterion from [C1] to [C6] is complied with." [C1]-[C4] are absolute and
already hold; [C5] and [C6] are optimisations, which cannot be "complied
with" except as "reach the best value they can". Read: the following
bracket is the outgoing floaters plus the residents of the next scoregroup;
among the choices left by [C5] and [C6], prefer the one whose following
bracket can be paired with the most pairs, then with its own outgoing
floaters' scores (descending) as low as possible - each over every
completion that keeps the rest pairable. Not the following bracket's own
[C7] or [C8], and not two brackets ahead.

### B6 - "higher ranked" in Article 5 is 1.8's ranking, not the score

5.2.1 and 5.2.5 say "higher ranked player (according to Article 1.8)", and
1.8 is the index with the note "players' scores are not used". So a
downfloater meeting a resident with a better index is the **lower** ranked
of the two for colours, although it has more points - the opposite of the
Dubov and Dutch systems. Taken as written. The alternative the reference
carries (`b6: :score`): points first, as in Dubov.

### B7 - the seeding rounds are the Dutch system, colours included

1.6.1: "paired following the rules of the FIDE (Dutch) System". The engine
hands those rounds to `Ainalrami.Pairing` unchanged - its bye, its
criteria, its colours, its topscorer rules (which cannot apply: a seeding
round is never the last). From the first round after them, nothing of the
Dutch system is carried over; Burstein has no float criteria, so the Dutch
float history simply stops mattering. The round count is therefore
**required** (1.6.2 counts the seeding rounds from it).

### B8 - virtual points: in the score, out of the index

1.7.2 excludes virtual (acceleration) points from the index, and says
nothing else about them. With `FIDE_BURSTEIN_BAKU`, "score" - the
scoregroups, [C6]'s and [C7]'s floater scores, the bye's "lowest score"
(3.1.3) - includes the round's virtual points, as reading D7 decided for
Dubov; the index (Buchholz and Sonneborn-Berger, of every player) is built
from real points only. In the seeding rounds the Dutch engine reads the
virtual points as it always does.

### B9 - 5.2.1's parity on the arrival numbering

As Dubov's D9: the SPP's 2026-08-27 ruling on the identical sentence in the
Dutch 5.2.5 (a late entrant has no TPN until it arrives, C.04.2 Article
2.4), so the parity is taken on `Ainalrami.Pairing.arrival_numbers/2`.

### B10 - an unpairable round is refused

[C3] has no topscorer or last-round exception, so a round can have no legal
pairing where Dutch pairs one; 1.9.3 leaves it to the Chief Arbiter. The
engine returns `{:error, :no_legal_pairing}` (or `:no_legal_bye`) and pairs
nothing; the CLI exits 1 with the reason. In a seeding round the refusal
is the Dutch engine's.

### B11 - [C8] counts players, without weighing strengths

"Minimise the number of players who do not get their colour preference":
a pair whose two players prefer the same colour denies exactly one of them;
a player with no preference (1.5.4: no games yet) is never denied. An
absolute, strong or mild preference counts the same - [C8] does not rank
them, 5.2.3 does that afterwards.

### Smaller readings

* **1.7 "current scores"** - the points of the rounds before the one being
  paired; a bye recorded ahead for the round being paired is not counted
  yet, for the player or for anyone's index.
* **1.8 inside the bracket** - incoming floaters and residents are ranked
  together by the index; a floater with more points can have a larger BSN.
* **[C6]** "minimise the scores (taken in descending order)" - the floaters'
  scores sorted descending and compared lexicographically, smaller first;
  with the count fixed by [C5], that is fewest floaters at the highest
  score, then at the next.
* **1.5.1** lists both absolute triggers; when they disagree (a colour
  difference past ±1 and the last two games the other colour) the
  difference decides, the order 1.5.1 states them in, as for Dubov.
* **3.1.4** "has played the highest number of games" counts games played
  over the board.
* **3.1.5** "the lowest ranking (according to Article 1.8)" - the smallest
  index (Buchholz, then Sonneborn-Berger), then the largest TPN.
* **[C1]** - a forfeited game is not a meeting (C.04.2 Article 3.5); an
  `XXP` pair counts as having met.
* **5.1** With no `152`, the initial colour is read off round 1 (a seeding
  round, paired by Dutch); with no round 1 either, White.

### What the alternatives would change

Rounds after the seeding rounds where the reference pairs differently - a
pair or a colour - under the alternative reading, over generated events
of 4-10 players (`tools/burstein_readings.exs`, seeds 1..20,000):

| reading | alternative | rounds | differ |
|---|---|---|---|
| B3 | unplayed rounds add nothing to the index | 47,048 | 5,159 (10.97%) |
| B4 | the zero-bye run must cover the round being paired | 47,048 | 249 (0.53%) |
| B6 | "higher ranked" in 5.2 by score first | 47,048 | 4,625 (9.83%) |

## What is reused

The Dutch engine (`Ainalrami.Pairing`), unchanged, for the seeding rounds;
its [C2] bye eligibility, arrival numbers and input checks after them. The
Dubov system's compatibility graph (`Ainalrami.Dubov.Graph`, itself the
team engine's `TeamPairing.Field`) for [C1]/[C3] and [C4]'s feasibility;
the weighted matching (`Ainalrami.WeightedMatching`) for the bracket; the
TRF result helpers. The Dutch and Dubov engines' code is untouched.

## Validation (2026-10-31)

`test/ainalrami/burstein_validation_test.exs` plays generated events
(`test/support/burstein_events.ex`: rated fields, Baku, a 3-1-0 point
system, late entrants, half- and zero-point byes, withdrawals with and
without a return, forfeits either way and double, forbidden pairs, both
initial colours), lets the engine pair the seeding rounds and compares
every later round with the reference: pairs, colours, the bye, and
refusals. A second test checks completeness and the absolute criteria
directly on 12-40 player fields. `tools/burstein_validation_run.exs` is the
same at scale, resumable, in chunks. `test/ainalrami/burstein_bbp_test.exs`
(tag `:interop`) compares the seeding rounds with `bbpPairings --dutch`
and counts the later ones against `bbpPairings --burstein`.

| run | fields | seeds | rounds compared | disagreements |
|---|---|---|---|---|
| reference, chunked | 4-10 players | 1..200,000 | 504,942 | 0 |
| reference, chunked | 11-12 players | 1..20,000 | 65,719 | 0 |
| **reference, total** | | | **570,661** | **0** |
| seeding rounds vs `bbpPairings --dutch` | 4-10 players | 1..10,000 | 19,261 | 0 |

The control: of 23,458 later rounds both programs paired, bbpPairings'
old Burstein agreed with the 2026 reading on 14,262 (60.8%) - the
order, the index and the colours of the two editions differ, so this is a
measure of how far apart they are, not of either's correctness. On the
same events bbpPairings refused 1,037 later rounds and this engine 1,637:
the two editions refuse different rounds, and the 2026 [C3] has no
topscorer exception (B10).

The reference is sensitive: dropping [C7]'s next-floater digit, dropping
[C8], reversing 4.3's order, ignoring Sonneborn-Berger, or ignoring B4's
adjustment each made it fail within 3,000 seeds.

Re-run: `elixir tools/burstein_validation_run.exs --last 200000` (sizes via
`BURSTEIN_VALIDATION_SIZES=4..10`), or `BURSTEIN_VALIDATION_SEEDS=1..2000
mix test test/ainalrami/burstein_validation_test.exs` (the default is seeds
1..150, sizes 4..10, in every `mix test`); `BURSTEIN_10,000=1..10000 mix
test test/ainalrami/burstein_bbp_test.exs --include interop`.

## Not built

* A Burstein proof (`--proof`) and Burstein's own `-x` / alternatives:
  refused.
* OpenPairings wiring (design §5).

## Questions for the SPP

The exact questions a mail to the FIDE Systems of Pairings and Programs
Commission would need, numbered; each names the reading it would settle.

1. (B3) C.04.4.2 Article 1.7.2 says a round a player did not play "shall be
   considered as one in which that player played against himself". For the
   Buchholz and Sonneborn-Berger of that player, is the opponent's "current
   score" in that round the player's own current score (so a bye adds the
   player's own score to their Buchholz, and the points registered times
   that score to their Sonneborn-Berger)? Is any cap or adjustment applied,
   such as the dummy-opponent rules of C.07 Article 16, or none?
2. (B3) Does that rule apply to every unplayed round alike - the
   pairing-allocated bye, a half- or full-point bye granted by the arbiter,
   a forfeit win, a forfeit loss and an unexcused absence?
3. (B4) In the exception to 1.7.2, does "a series of consecutive
   zero-point-byes up to the current round" mean that the series must reach
   the last round already played (the player has not played since), or that
   it must also include the round now being paired (the player is absent
   from it too)?
4. (B4) Does the exception change only how the absent player's score is
   seen by the opponents they actually played, or also the absent player's
   own index? When the player returns and plays again, is the adjustment
   withdrawn from the opponents' indexes from then on?
5. (B4) Which unplayed rounds count as "zero-point-byes" for the exception:
   only byes requested from or given by the arbiter with zero points, or
   also forfeit losses and unexcused absences?
6. (B5) [C7] asks that "in the following bracket every criterion from [C1]
   to [C6] is complied with". Is the following bracket the outgoing floaters
   plus the next scoregroup, and is [C7] satisfied by choosing the floaters
   that let that bracket reach its own best [C5] (most pairs) and then its
   own best [C6] (lowest floater scores) - and nothing beyond that bracket?
7. (B6) Articles 5.2.1 and 5.2.5 give the decision to the "higher ranked
   player (according to Article 1.8)", and 1.8 ranks by the index and TPN
   without the score. Is it intended that a player with more points (for
   example, a downfloater) is the lower ranked player for colours when their
   opponent has the higher Buchholz?
8. (B8) With the Baku acceleration (`FIDE_BURSTEIN_BAKU`), do the
   scoregroups, the floater scores in [C6] and [C7], and the "lowest score"
   for the pairing-allocated bye (3.1.3) include the virtual points, while
   only the index of 1.7 excludes them?
9. (B7) Is it correct that after the seeding rounds no part of the Dutch
   system's state - in particular its float history - is used, and that the
   seeding rounds' colours are allocated by the Dutch system's Article 5,
   not by Burstein's?
10. (B11) [C8] minimises "the number of players who do not get their colour
    preference". Does a player without a colour preference (1.5.4) ever count
    as not getting it, and are absolute, strong and mild preferences counted
    alike?
11. (B10) [C3] has no exception for topscorers or for the last round. Is a
    round that cannot be paired without two players of the same absolute
    colour preference meeting therefore left to the Chief Arbiter (1.9.3),
    as the text reads?
12. (B1, B2) Editorial: in 1.7, "Article 2.1.5" should read 3.1.5; in 1.9.1,
    "Article 3.1" should read 2.1; and the note to 4.3 lists
    "1-3, 2-0, 4-5, 6-0" twice. Can these be corrected?

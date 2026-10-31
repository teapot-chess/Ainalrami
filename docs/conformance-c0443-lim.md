# C.04.4.3 Lim System - conformance notes

Working notes on the FIDE Lim System, **edition approved by the Council on
28/10/2025 and applied from 1 February 2026**, as built in `Ainalrami.Lim`
(2026-10-31). The rule text used is the local handbook mirror,
`Desktop/fide-handbook/text/C040403202602.md` (mirrored 2026-09-04 from
handbook.fide.com). The design that preceded the code, with the first list
of ambiguities, is `docs/design-other-swiss-systems.md` §1.3.

**This is a reading, labelled as one.** The text is a procedure for an
arbiter with pairing cards, approved in 1987 and amended to 1999: it says
what to try, in places in what order, and rarely what the result must
satisfy. No other Lim engine is known, for this edition or any earlier
one, and TRF26 has no `192` code for the system (L11). The engine is held
to a **brute-force reading written separately** from the rule text and the
readings below (`test/support/lim_reference.ex`), the method the Dubov and
Burstein systems used; agreement with it shows the procedure is
implemented as read, not that it is read the way FIDE meant. Every place
the text was read is listed here with the rule it reads, and the
questions at the end are the ones whose answers would replace a reading
with a ruling.

## The short version

| | Dutch (C.04.3) | Lim (C.04.4.3) |
|---|---|---|
| order of the scoregroups | top down | **top down to the median, bottom up to the median, the median group last** (2.2) |
| inside a group | best candidate under a weight ladder | top half v bottom half, **exchanges in a fixed order** (2.4, 4) |
| floaters | chosen by [C6]-[C21] | chosen by 3.2-3.10: colour balance, floater "types", no repeat floater |
| compatibility | [C1], [C3] with topscorer exceptions | not met, no third colour in succession, no three more of one colour (2.1); **last round: equal scores may meet regardless** (6) |
| colours | 5.2.1-5.2.5 | alternate and equalise; 5.4's history, then rank - **lower ranked below the median** |
| the bye | lowest score, lowest ranked | the same (1.1, 7.1) |
| ratings | optional | not read: pairing numbers only (Maxi-tournaments aside, not built) |

## How it is computed

A group is paired in two steps (`Ainalrami.Lim.Group`). First, who floats
on: one maximum-weight perfect matching of every player still unpaired, in
which a pair inside the group is a pair of this group, a group player
matched outside it a floater, and each of L4's criteria is a digit of the
edge weight - a sum over the floaters, so the best floater set is the
matching's. Second, the pairs: the fewest denied colours over a matching of
the players kept, then the first pairing in scrutiny order (L5), fixed one
choice at a time - a partner is kept when some pairing with the fewest
denials still contains it. Colours follow pair by pair (`Ainalrami.Lim.Colour`).

The reference does none of this. It tries every split of the group into
floaters and paired players and compares them as tuples; it lists every
pairing of the players kept, counts their denied colours, replays the
scrutiny against each to find its place in the order, and sorts; "can
these players still be paired" is a memoised search. It derives the due
colours and 2.1's compatibility again from the colour histories.

## Readings

Each reading is implemented, named in the code where it applies, and held
by the reference. Where the reference carries the alternative as a switch,
`tools/lim_readings.exs` measures how often it would change a round (table
at the end of this section).

### L1 - "highest numbered" is #1

4.2 calls "Player #1, the highest numbered player in the scoregroup", so
throughout the text a *higher* number is a *better* pairing number: the
highest numbered player is the top of the list, the lowest numbered the
bottom. Every rule below is read that way - 3.2.4 (the lowest numbered,
the weakest, floats down), 3.3/3.4, 3.6-3.8, 4.1, 4.4.2. Read
arithmetically, 3.2.4 would float the strongest player down, which no
version of any Swiss system does. "Higher ranked" in 5.4 is the better
pairing number too.

### L2 - Maxi-tournaments are not built

3.2.3, 3.8 and 5.7 add a 100-point rating window "in Maxi-tournaments",
and no FIDE text of 2026 says what a Maxi-tournament is. The library
refuses `maxi:` and the command line has no flag for it, rather than guess
the definition. Ratings are then read nowhere: 7.1's "lowest rated" is the
last pairing number, the pairing list being in rating order (C.04.2).

### L3 - the median scoregroup is half the possible score, and may be empty

2.2: "the score equal to half the number of rounds that have been played".
With another point system that is read as half the points a player who won
every round would have: `(rounds played) x (points for a win) / 2`. No
player need have that score (after an odd number of rounds, or with 3-1-0).
Then the median group is only the floaters that reach it from both sides,
paired last and downward as 2.2 says; with no floaters either, it is empty
and every group was paired on its own. Round 1 puts everybody in the median
group (0 of 0 rounds), so 2.4's halves give 7.2's pairing without a rule of
their own.

### L4 - who floats, in this order

2.3, 3.2-3.5, 3.9, 3.10 and 4.4 all choose floaters and none ranks itself
against the others except 3.9's list and 3.10's provisos. Read, most
important first:

1. **the most pairs in the group.** 2.3 transfers players with no partner
   and one more to make the number even; 4.4 floats a player only when no
   exchange pairs them; 3.10.2 will not "decrease the number of pairings".
2. **3.9's types**, fewest of type a, then b, then c (3.9.2): a floater who
   floated into this group and has no compatible player in the adjacent
   group; one who floated in and has; a resident who has none. The adjacent
   group is the next one in the pairing direction - for the last group
   before the median, the median group's residents.
3. **3.10**: fewest floaters who floated in the round before ("provided
   this will not produce other floaters of the types a, b, c").
4. **3.2.2**: fewest floaters who are not due the colour most of the group
   is due - floating one of the majority is what "tends to equalise".
5. **3.2.4, 3.3, 3.4**: pairing downward, the lowest-ranked players float;
   pairing upward, the highest ranked. Between sets, the one whose
   worst-ranked floater is worse ranked, then the next (downward), and the
   mirror upward.

3.3's "who has a compatible opponent in the lower scoregroup" and 3.5 are
then the type criteria at work. 4.4 needs no rule of its own: when #1 and
#2 both have only #6 left, the most pairs are kept by floating one of them,
and step 5 floats #2 (4.4.1) or, in an even group, #2 and the lowest player
left (4.4.2) - the unit tests check both. The alternative measured: 3.2.2
before the types.

### L5 - the scrutiny order, for any number of players

4.2 and 4.3 give the exchanges for six players only. Read: inside a group
the incoming floaters choose first (3.6, 3.7, L8), each trying the
residents best ranked first if they floated down and worst ranked first if
they floated up, those due the opposite colour first (3.8), then the other
floaters. The residents left are then put in pairing-number order - from
the top pairing downward, from the bottom pairing upward (4.1) - and split
into halves (2.4); the first unpaired one tries the second half's unpaired
players in order, then the first half's from its far end back. That is
4.2's table for #1 of six (4, 5, 6, 3, 2) and 4.3's first three columns
for #2 (4, 5, 3). 4.3's last two columns re-pair #1 (1 v 3, 1 v 2): read as
the backtracking into #1's own list when nothing is left for #2, which
4.4 then caps - when no exchange works, #2 floats instead (L4). The
pairing chosen is the first, in that order, among those L6 allows.

### L6 - 5.2's second scrutiny is the fewest denied colours

5.2: after the pairings are all new, "a second scrutiny with exchanges
where necessary ... to give each player, if possible, the alternating
colour and at the same time, the equalising colour". Read: of the pairings
of the group's players, those that deny the fewest players their due
colour, and of those the first in L5's order. The alternative measured:
the first pairing in L5's order, its colours as they fall.

### L7 - 2.6's cracking is done in advance

2.6 reopens the pairings next to a median group that cannot be paired,
without saying which pairing is "the next" or when to stop. Read: no group
is ever paired in a way that leaves the players still unpaired unpairable
(L4 only chooses among splits that leave a complete round possible), so
the median group always pairs and 2.6 is never reached. Where the text
would crack a pairing of the group next door, this pairs that group with
one pair fewer in the first place.

### L8 - which floater chooses first

3.6 and 3.7 are read under L1: down-floaters by highest score, then best
ranked (3.6.1, 3.6.2); up-floaters by lowest score, then worst ranked
(3.7.1, 3.7.2); in the median group down-floaters before up-floaters
(3.6.3), and an up-floater there chooses as an up-floater (3.8, worst
ranked first). 3.7.2's parenthesis ("this is not always the player with
the highest pairing number") reads arithmetically, against L1 - a
question.

### L9 - the bye

1.1: "the player with the lowest rank in the lowest scoregroup", on top of
C.04.1 Article 3 (no second bye, no bye after a forfeit win). Rank is the
pairing number. If that player's bye would leave the rest unpairable the
next one is taken - the text does not say; C.04.1 requires a pairing to
exist. No candidate at all: refused, `:no_legal_bye`.

### L10 - unplayed games

The text does not mention them. As in the other systems: a forfeit is no
meeting (C.04.2 3.5) and gives no colour; a round not played drops out of
the colour history, so 5.1.1's "three successive rounds" are three
successive games; a bye's points count in the score. A late entrant has a
score and no history. Previous-round floaters (3.10) are players who were
paired, played or forfeited, against an opponent of another score; a bye
is not a float.

### L11 - the file says `192 CUSTOM_SWISS` and `XXO system lim`

TRF26's Tournament Type Code Table has `FIDE_DUBOV` and `FIDE_BURSTEIN`
and nothing for Lim, although Lim is C.04.4.3. Inventing `FIDE_LIM` would
put a code FIDE has not defined into a FIDE field, so the file says what
TRF26 allows, a Swiss of the competition's own (`192 CUSTOM_SWISS`), and
this program's own record says which: `XXO system lim`. `XXO` is the
record this program already keeps its other options in; other programs
skip it. Read together they choose Lim; `XXO system lim` with no `192`
does too; `XXO system lim` beside any other `192` code is refused, exit 2.
`-g --system=lim` writes both. A question for TEC asks for the code.

### L12 - the last round frees equal scores only

6: in the last round, Article 5 of the Basic Rules, "requiring players
with the same score to be paired if they had not met", has priority over
alternation and equalisation. Read literally: two players of equal score
are compatible in the last round whatever their colours; any other pair
keeps 2.1's colour limits. The alternative measured: every pair freed.

### L13 - colours with no history

7.2 colours round 1: #1 takes the colour drawn, the other odd numbers of
the top half the same, the even numbers the other. Read as a pair rule:
when neither player has a colour history, the higher ranked takes the
initial colour on an odd pairing number and the other on an even one -
round 1 by 7.2, and later two late entrants the same way. One with a
history and one without: the one with it is served.

### L14 - the due colour

5.5 and 5.6: in odd rounds a colour that leaves one more of one colour, in
even rounds the equalising one. With every game played that is the
equalising colour when the colours are unequal and the alternating one
when they are equal; after unplayed rounds the same rule is kept by
counting games, not rounds. 5.3's "must be given the alternating colour"
after two of the same yields to 5.1.2 when the colours are already two
apart (the ladder the other systems share).

### L15 - 5.4 for every pair due the same colour

5.4 is worded for two players who "had the same colour in the previous
round"; 5.6 sends two players due the same equalising colour to it too.
Read for every pair due the same colour: a player who must have it (5.3,
5.1.2) gets it first; otherwise, going back through the two histories, at
the most recent round where they differ, the player who then had the other
colour gets it; identical histories, the higher ranked "in the median
scoregroup or above" and the lower ranked below it, judged by the group
being paired.

### L16 - 2.1 for a player with no colour left

2.1 makes two players compatible when "the pairing will not require either
player" to break 5.1.1 or 5.1.2. A player who could take neither colour
(two of one colour running and already two more of the other) is therefore
compatible with nobody until the last round's L12. The shared absolute
colour criterion of the other systems would let them meet anyone whose
own colour is not forced; the literal text is followed here.

### Smaller readings

* **Board order** (the text has none): by the higher score of the pair,
  then the lower, then the better pairing number.
* **2.3.4's floater and 3.2.2** are one floater among L4's, not a separate
  step.
* **An unpairable round** - one with no complete pairing at all - is
  refused, `:no_legal_pairing`; the Chief Arbiter decides.
* **XXP / forbidden pairs** count as having met.

### What the alternatives would change

Rounds where the reference pairs differently - a pair or a colour - under
the alternative reading, over generated events of 4-10 players
(`tools/lim_readings.exs`, seeds 1..20,000):

| reading | alternative | rounds | differ |
|---|---|---|---|
| L4 | 3.2.2's colour balance before 3.9's types | 85,799 | 2,140 (2.49%) |
| L6 | the scrutiny order before the colours | 85,799 | 7,060 (8.23%) |
| L12 | the last round frees every pair | 85,799 | 290 (0.34%) |

## What is reused

The Dubov system's compatibility graph and its "can these still be
paired" oracle (`Ainalrami.Dubov.Graph`), the weighted matching
(`Ainalrami.WeightedMatching`), the Burstein system's player view for the
colour history and preference ladder (`Ainalrami.Burstein.Player`), C.04.1
bye eligibility and the input checks of `Ainalrami.Pairing`, the TRF
helpers. The Dutch, Dubov and Burstein engines are untouched.

## Validation (2026-10-31)

`test/ainalrami/lim_validation_test.exs` plays generated events
(`test/support/lim_events.ex`: rated fields, a 3-1-0 point system, late
entrants, half- and zero-point byes, withdrawals with and without a
return, forfeits either way and double, forbidden pairs, both initial
colours), lets the engine pair every round and compares it with the
reference: pairs, colours, the bye, and refusals. A second test checks
completeness, no rematch and 2.1's colour limits directly on 12-40 player
fields. `tools/lim_validation_run.exs` is the same at scale, resumable, in
chunks. `test/ainalrami/lim_test.exs` holds 4.2's and 4.3's exchange
tables, 4.4.1 and 4.4.2, 7.2's forty-player round one and 5.3/5.4.

| run | fields | seeds | rounds compared | disagreements |
|---|---|---|---|---|
| reference, chunked | 4-10 players | 1..200,000 | 892,552 | 0 |
| reference, chunked | 11-12 players | 1..20,000 | 119,956 | 0 |
| **reference, total** | | | **1,012,508** | **0** |

A refusal counts as agreement only when both refuse the same round for the
same reason. They are common: in a 3,000-seed sample 471 events reached a
round with no legal pairing and stopped there. Small fields, deep into an
event, under a compatibility rule with no exception for anybody.

The reference is sensitive: dropping 3.10's digit, dropping 3.2.2's,
dropping the colour count of L6, ignoring 3.8's colour preference for a
floater's partner, not reversing the first half in L5's list, giving the
higher ranked the colour below the median, or swapping 3.9's types a and
b each made it fail within 3,000 seeds.

Re-run: `elixir tools/lim_validation_run.exs --last 200000` (sizes via
`LIM_VALIDATION_SIZES=4..10`), or `LIM_VALIDATION_SEEDS=1..2000 mix test
test/ainalrami/lim_validation_test.exs` (the default is seeds 1..150, sizes
4..10, in every `mix test`).

## Not built

* Maxi-tournaments (3.2.3, 3.8, 5.7; L2).
* A Lim proof (`--proof`) and `-x` for Lim: refused.
* OpenPairings wiring.

## Questions for the SPP

The exact questions a mail to the FIDE Systems of Pairings and Programs
Commission would need, numbered; each names the reading it would settle.

1. (L1) In C.04.4.3, does "highest numbered player" mean the player with
   pairing number 1, as 4.2 says of Player #1, everywhere in the text - in
   3.2.4, 3.3, 3.4, 3.6-3.8, 4.1 and 4.4 alike?
2. (L8) 3.7.2 says the up-floater from the lowest scoregroup is paired
   first, "not always the player with the highest pairing number". Under
   question 1's convention the up-floater from the lowest group would
   usually be the *lowest* numbered. Should the parenthesis read "lowest",
   or is "highest pairing number" meant arithmetically here?
3. (L2) What is a "Maxi-tournament" in 3.2.3, 3.8 and 5.7 - a number of
   players, a rating spread, or a designation by the organiser?
4. (L3) 2.2 defines the median scoregroup by "half the number of rounds
   that have been played". (a) When no player has exactly that score, is
   the median group empty, with the floaters from above and below meeting
   there, or does another group take its place? (b) With a point system
   other than 1-½-0, is the median half the maximum score?
5. (L4) When the floater rules disagree, which comes first: 3.2.2 (colour
   balance), 3.9 (floater types), 3.10 (no floater of the round before) or
   3.2.4/3.3/3.4 (the lowest or highest numbered)? Is the following order
   correct: most pairs; 3.9's types; 3.10; 3.2.2; 3.2.4?
6. (L4) In 3.9, is "the adjacent scoregroup" the next group in the
   direction of pairing, and for the last group before the median, the
   median group's own players?
7. (L5) 4.2 and 4.3 show the exchanges for six players. For a group of any
   size, is the order: the second half in order, then the first half from
   the bottom up? And are 4.3's last two columns (1 v 3, then 1 v 2) a
   return to Player #1's own exchanges when Player #2 has none?
8. (L6) In 5.2's second scrutiny, is the aim the fewest players denied
   their due colour, with the first scrutiny's order deciding between
   pairings that deny equally many?
9. (L7) In 2.6, which pairing is "the next pairing" of the neighbouring
   scoregroup - the last one made, or the one nearest the median group?
   When the median group still cannot be paired after a pairing has been
   cracked, is the next one cracked, and so on until it can?
10. (L12) Does Article 6 free only pairs of equal score from 5.1.1/5.1.2 in
    the last round, or every pair?
11. (L15) Does 5.4 apply to every pair of players due the same colour, or
    only when both had the same colour in the previous round? And is "the
    median scoregroup or above" judged by the group being paired or by the
    players' own scores?
12. (L16) Is a player who can take neither colour without breaking 5.1.1 or
    5.1.2 compatible with nobody (2.1 read literally), or does the
    shared rule of the other systems - two players with the same forced
    colour cannot meet - apply?
13. (L9) If the lowest-ranked player of the lowest scoregroup cannot take
    the pairing-allocated bye without making the rest of the round
    unpairable, does the bye go to the next player up?
14. (L10) Is a forfeited game a meeting for 2.1 and 2.5, and does an
    unplayed round count among the "three successive rounds" of 2.1 and
    5.1.1?
15. (L11, for TEC) TRF26's Tournament Type Code Table has no code for the
    Lim system (C.04.4.3), though it has `FIDE_DUBOV` and `FIDE_BURSTEIN`.
    Could `FIDE_LIM` be added? Until then, this program writes `192
    CUSTOM_SWISS` with its own record `XXO system lim`.

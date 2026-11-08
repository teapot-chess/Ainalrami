# DRAFT - Measured behaviour of the FIDE (Dutch) System, C.04.3 (2026)

> **DRAFT for internal review. Not to be sent, posted or shared.** Prepared
> in the Ainalrami repository on 2026-11-08 for review by the project's
> maintainer before any decision about submitting it to the FIDE Systems
> of Pairings and Programs Commission (SPP). Figures marked "sample" come
> from desktop-sized runs; the commands for the full runs are in
> section 8. Reviewer notes are collected in section 9 and must be
> removed before anything is sent.

**To:** FIDE Systems of Pairings and Programs Commission
**Subject:** Quantitative behaviour of C.04.3 (2026): colour streaks, float
cascades and Article 5.2.5, with simulated effects of candidate changes

## 1. Summary

This note reports what the Dutch System (C.04.3, effective 1 February
2026) does when it is run, measured on simulated tournaments and on the
large comparison corpora this project has accumulated while validating
its pairing engine. It does not propose that any rule be changed. Where
the measurements show behaviour that may be unintended, it describes one
or two candidate changes and their simulated effect, so that the
Commission can weigh them with numbers rather than intuitions.

Sources are restricted to FIDE regulations (C.04.1, C.04.2, C.04.3) and
this project's own measurements. Every number is reproducible from the
public repository with the commands given.

Headline measurements (sample runs; corpora S, L and E are described in
2.3; brackets are 95% intervals of the paired difference):

1. **[C1] is the constraint everything else bends around.** If
   rematches were allowed, 65.6% of rounds in S and 76.6% in L would be
   paired differently. In S, boards between players a point or more
   apart would fall by 14.0 per 100 boards (from 29.8), the summed score
   difference by 1.31 points per round (from 2.66) and the longest
   downfloat cascade by 1.02 brackets (from 2.31). Most of the float
   behaviour in sections 4 and 6 is the price of [C1], not a defect of
   [C14]-[C21].
2. **Third consecutive colours are rare: 0.16 per 100 player-games in S,
   0.01 in L.** [C3] and the "same colour in the last two games" clause
   of 1.7.1 each hold them down. Without [C3] the S rate is 0.64, and
   with the clause at three games it is 0.81. Where a third colour does
   occur, one mechanism is 5.2.2 settling two absolute preferences on
   colour difference (example 3.1).
3. **The two-round float memory earns its place in large fields, and a
   third round adds nothing measurable.** With one round of memory
   ([C16], [C17], [C20] and [C21] removed), repeated floats two rounds
   apart rise by 1.16 per 100 player-rounds in L (+56% on a baseline of
   2.06). Three rounds of memory change 0.7% (S) to 26% (L) of rounds,
   with no gain detected on any float metric.
4. **Colour criteria and float criteria trade at a measurable rate.**
   Moving [C12] below [C21] removes 0.37 (S) and 0.21 (L) repeated
   floats per 100 player-rounds and costs 1.37 (S) and 0.90 (L)
   denied colour preferences per 100 boards.
5. **Article 5.2.5 is a question of who gets which colour, not of
   balance.** Two implementations that differed only in the number 5.2.5
   reads disagreed on 64,131 of 6,242,974 boards (1.03%) of a bye-heavy
   corpus. In the simulator, swapping the readings changes no colour or
   float metric detectably. Dropping the parity altogether costs 6.5
   denied preferences per 100 boards.

## 2. Method

### 2.1 The reference reading of the rules

All measurements use a brute-force implementation of C.04.3 written from
the text (`verify/` in the repository): for each bracket every candidate
pairing is listed, candidates failing [C4] are discarded, the remainder
are compared on [C5]-[C21] in order (3.8.1), and ties go to the candidate
Article 4's sequence generates first. Colours follow Article 5.2. Where
the text leaves a choice, the reading is stated in `verify/README.md`; the
two that matter here are:

* [C18]/[C20]: an MDP left unpaired in the Limbo counts, with a score
  difference larger than any it could receive in the bracket ("MDPs who
  received a downfloat" is read as including those who float again);
* 5.2.5: the number whose parity decides is a numbering of the players
  who have arrived (C.04.2 2.4: late entries are "paired only when they
  actually arrive"), not the TPN.

This reference agrees with the Ainalrami engine on every reachable
position in nine size combinations, from 6 players x 3 rounds up to
9 players x 4 rounds and 10 players x 3 rounds (2,076,398 distinct
positions, 0 disagreements). The engine in turn agrees with bbpPairings
6.0.0 on 414,606,289 of 414,606,291 rounds of a seven-day comparison
(both differences are a bbpPairings defect in [C2]). The reading is
therefore not idiosyncratic: it is the reading two independent 2026
implementations share.

### 2.2 The simulator

The rule-change simulator (`lab/` in the repository) splits [C5]-[C21]
into separately named criteria and lets each be dropped or moved, the
colour-preference thresholds of 1.7.1 be changed, the float memory of
[C14]-[C21] be shortened or lengthened, and alternative readings be
swapped in. With every option at its default it reproduces the reference
exactly (held to it by an automated test, criterion vector by criterion
vector).

Each simulated tournament is played twice from the same seed, once under
the 2026 text and once under the variant. Game results are drawn from a
rating model with common random numbers: a game's result depends only
on the seed, the round and the two players, so wherever both arms make
the same pairing they get the same result. Differences are therefore
paired, and intervals are 95% intervals of the mean paired difference
(normal approximation, n ≥ 1,000 for the 10-player corpus). "Rounds
changed" is measured in identical positions: every position reached
under the 2026 text is also paired under the variant (Wilson interval).

Metrics are always computed with the 2026 definitions (1.4 floats, 1.6
colour difference, 1.7 preferences), whatever the variant, so a variant
that redefines a preference is judged by the colours players actually
received.

Fields of up to 10 players are paired by the brute force itself. Larger
fields are paired by a matching formulation of the same reading (one
maximum-weight matching per bracket, each criterion a separate digit of
the weight, Article 4's order encoded below the criteria). On every
round compared it gave the brute-force answer (fields to 10 players,
under the 2026 text and under the variants used here) and the
Ainalrami engine's answer (fields of 24 to 100 players). See section 8.

### 2.3 Corpora used here

| name | players x rounds | tournaments (sample) | disturbances | pairer |
|---|---|---|---|---|
| S | 10 x 7 | 1,000 | requested byes 5% per player-round, forfeits 3% per board | brute force |
| L | 40 x 9 | 300 | the same | matching formulation |
| E | 10 x 6 | 1,000 | requested byes 10%, forfeits 15%, two late entries arriving in round 3 | brute force |

Ratings run linearly from 2500 (TPN 1) to 1700 (last TPN); the draw rate
peaks at 30% between equal players. The model is not a claim about chess;
it only has to produce scoregroups shaped like real ones.

Metrics (all computed on what was actually played):

| metric | unit | meaning |
|---|---|---|
| third colour | per 100 player-games | a game that is a player's third or later consecutive game with the same colour (games from each player's third on) |
| \|CD\| >= 2 | % of players | colour difference of 2 or more at the end of the tournament |
| denied | per 100 boards | colour preferences (1.7, as held before the round) not granted |
| point-apart boards | per 100 boards | boards whose players' scores differ by a point or more |
| repeat float (1) / (2) | per 100 player-rounds | a player floating in the same direction as one / two rounds before (1.4) |
| cascade | brackets | per round, the longest run of consecutive brackets each passing a downfloater to the next (the bye's bracket excluded), averaged over rounds |
| score gap | points per round | sum over the boards of the score difference |
| seeds 1-2 met | % of tournaments | |

Baseline (C.04.3 as written), mean and 95% interval:

| metric | S (10 x 7) | L (40 x 9) | E (10 x 6, late entries) |
|---|---|---|---|
| third colour | 0.16 [0.12, 0.19] | 0.01 [0.01, 0.02] | 0.05 [0.02, 0.08] |
| \|CD\| >= 2 | 5.34 [4.89, 5.79] | 1.98 [1.76, 2.21] | 4.96 [4.53, 5.40] |
| denied | 30.29 [29.86, 30.72] | 19.50 [19.13, 19.88] | 23.76 [23.25, 24.26] |
| floats per player per round | 0.53 | 0.22 | 0.44 |
| point-apart boards | 29.76 [29.33, 30.20] | 2.38 [2.23, 2.52] | 22.47 [22.01, 22.92] |
| repeat float (1) | 17.72 [17.40, 18.04] | 2.63 [2.53, 2.73] | 11.68 [11.40, 11.96] |
| repeat float (2) | 12.75 [12.50, 13.00] | 2.06 [1.97, 2.15] | 8.11 [7.89, 8.34] |
| cascade | 2.31 [2.29, 2.34] | 2.14 [2.09, 2.18] | 1.58 [1.56, 1.61] |
| score gap | 2.66 [2.63, 2.69] | 2.08 [2.05, 2.12] | 1.65 [1.62, 1.67] |
| seeds 1-2 met | 97.4 [96.4, 98.4] | 54.0 [48.4, 59.7] | 91.0 [89.2, 92.8] |

Ten players over seven rounds is a deliberately tight field: by the last
rounds [C1] leaves few legal pairings, which is why its floats are an
order of magnitude above L's. Most open tournaments sit between the two.

## 3. Colour streaks and colour imbalance

### 3.1 What the text does

Under C.04.3 a player who has had the same colour in the last two games
has an absolute preference for the other (1.7.1), and [C3] forbids two
non-topscorers with the same absolute preference from meeting. A third
consecutive colour therefore needs either a topscorer (1.8) or a
conflict that 5.2 has to settle. Both are rare: 0.16 per 100
player-games in S and 0.01 in L (table in 2.3).

**Example 3.1 (third colour for a non-topscorer).** Six players, round 5
of 5, before pairing (TRF-16, 1/½/0):

    XXR 5
    152 W
    001    1      P1                                2590                             3.5    1     4 w =     2 b 1     5 w 1     3 w 1
    001    2      P2                                2580                             2.0    2     5 b 0     1 w 0     6 b 1     4 b 1
    001    3      P3                                2570                             3.0    3     6 w 1     5 b 1     4 w 1     1 b 0
    001    4      P4                                2560                             1.5    4     1 b =     6 w 1     3 b 0     2 w 0
    001    5      P5                                2550                             2.0    5     2 w 1     3 w 0     1 b 0     6 b 1
    001    6      P6                                2540                             0.0    6     3 b 0     4 b 0     2 w 0     5 w 0

C.04.3 pairs 2-3, 5-4, 6-1 (White first). Player 1 (3.5 points, a
topscorer in the final round) has met everyone except 6, so the two must meet. Players 1 and 6 both played White in
rounds 3 and 4, so both have an absolute preference for Black. Because 1
is a topscorer, [C3] does not forbid the game. 5.2.2 settles two absolute
preferences by the wider colour difference: 1 has CD +2 and 6 has CD 0,
so 1 gets Black and 6, who is not a topscorer, gets a third consecutive
White. The topscorer exemption exists for player 1's benefit, and in this
case the colour cost falls on player 6.

### 3.2 Candidate changes and their simulated effect

| variant | rounds changed (S / L) | third colour (S) | third colour (L) | \|CD\| >= 2 (S) | denied (S) | point-apart boards (S) |
|---|---|---|---|---|---|---|
| [C3] removed (`c3=off`) | 2.87% / 3.63% | +0.48 [+0.41, +0.55] | +0.13 [+0.10, +0.15] | +0.44 [+0.19, +0.70] | +0.51 [+0.35, +0.67] | -0.23 [-0.34, -0.12] |
| 1.7.1 "last two games" read as three (`streak=3`) | 2.66% / 6.00% | +0.65 [+0.57, +0.73] | +0.27 [+0.23, +0.31] | -0.39 [-0.69, -0.10] | +0.40 [+0.25, +0.55] | -0.20 [-0.31, -0.09] |
| 1.7.1 colour-difference threshold raised from \|CD\| > 1 to \|CD\| > 2 (`absolute_cd=2`) | 0.09% / 0.07% | -0.01 [-0.03, -0.00] | +0.00 | +0.04 [-0.02, +0.10] | +0.02 [-0.01, +0.05] | -0.01 [-0.03, +0.01] |
| [C13] removed (`drop:C13`) | 1.97% / 29.81% | +0.02 [-0.00, +0.04] | +0.00 | +0.26 [+0.07, +0.45] (L: +1.50 [+1.15, +1.85]) | -0.06 [-0.19, +0.08] | +0.02 [-0.09, +0.14] |

These variants are shown as yardsticks, not proposals. They show that the
present text holds third colours down at a modest cost: [C3] costs 0.23
point-apart boards per 100 in S and 0.12 repeated floats per 100
player-rounds. Relaxing the two-game rule would let colour streaks rise
fourfold in S and buy almost nothing in floats. [C13] matters in large
fields, where removing it changes 30% of rounds and raises the share of
players ending on |CD| >= 2 from 1.98% to 3.48%.

The mechanism of example 3.1 lies in 5.2.2, which the simulator cannot
vary (section 7), so the following change is described but not measured.
**Candidate 3a:** both players in example 3.1 have had White twice, so
one of them must get a third White. 5.2.2 puts it on the player whose
only part in the conflict is that [C3] was waived for his opponent.
When two absolute preferences conflict and only one of the players is a
topscorer, 5.2.2 could grant the non-topscorer's preference first. In
example 3.1 that gives 1-6 instead of 6-1: player 1 ends on three
consecutive Whites and CD +3, and player 6 ends on CD 0. Whether a
topscorer's streak in the final round is the lesser evil is for the
Commission to judge. The frequency bounds the stakes: third colours
occur at 0.16 per 100 player-games in the tightest field measured.

## 4. Floats and float cascades

### 4.1 What the text does

[C6] and [C7] move as few players as possible down, and the lowest
scores; [C14]-[C17] then avoid repeating a float of the last two rounds
and [C18]-[C21] avoid repeating its size. Colour criteria [C10]-[C13]
rank above all of the float-repetition criteria. In S the longest
downfloat chain averages 2.31 brackets per round and 17.7 players per
100 player-rounds float the same way as the round before (table in 2.3).

**Example 4.1 (a cascade, a repeated downfloat and a three-point
board).** Six players, round 4 of 5:

    XXR 5
    152 W
    001    1      P1                                2590                             3.0    1     4 w 1     2 b 1     3 w 1
    001    2      P2                                2580                             2.0    2     5 b 1     1 w 0     6 b 1
    001    3      P3                                2570                             1.0    3     6 w 1     4 b 0     1 b 0
    001    4      P4                                2560                             2.0    4     1 b 0     3 w 1     5 b 1
    001    5      P5                                2550                             1.0    5     2 w 0     6 b 1     4 w 0
    001    6      P6                                2540                             0.0    6     3 b 0     5 w 0     2 w 0

C.04.3 pairs 2-4, 3-5, 1-6. Player 1 (3 points) has met 2, 3 and 4 and
downfloated in round 3. He falls through the 2-point and 1-point brackets
to play the only 0-point player: three consecutive brackets pass him on,
the game is three points apart, and [C14] is breached. Every opponent
player 1 has not met (5 and 6) is below him, so the repeated downfloat
is unavoidable. Its length is not. The 2-point bracket pairs 2-4
internally ([C6]). In the 1-point bracket, 1-5 would leave 3 with only
6, whom he has met ([C4]), so 3-5 is paired and 1 goes on down. The only
other legal round, 1-5 2-3 4-6, has three downfloaters instead of one and a
summed score difference of 5 points instead of 3. The three-point board
is the price of fewer floaters, which is the order the text sets. How
much of the cascading [C1] causes in general is measured directly: with
rematches allowed (section 6.1) the S cascade falls by 1.02
brackets and point-apart boards by 14.0 per 100.

### 4.2 Candidate changes and their simulated effect

Paired differences against the 2026 text (per 100 player-rounds for
repeated floats, per 100 boards for denied preferences):

| variant | rounds changed (S / L) | repeat float (1) S | repeat float (1) L | repeat float (2) S | repeat float (2) L | denied S | denied L |
|---|---|---|---|---|---|---|---|
| [C14] moved above [C10] (`move:C14:before:C10`) | 3.22% / 6.30% | -0.32 [-0.42, -0.21] | -0.16 [-0.20, -0.11] | +0.17 [+0.08, +0.27] | +0.04 [-0.00, +0.08] | +0.65 [+0.44, +0.86] | +0.30 [+0.15, +0.44] |
| [C12] moved below [C21] (`move:C12:after:C21`) | 5.12% / 10.96% | -0.37 [-0.51, -0.24] | -0.21 [-0.27, -0.15] | -0.03 [-0.16, +0.10] | -0.13 [-0.18, -0.08] | +1.37 [+1.09, +1.65] | +0.90 [+0.71, +1.10] |
| [C12] removed (`drop:C12`) | 13.28% / 64.96% | -0.49 [-0.74, -0.23] | -0.35 [-0.47, -0.24] | -0.13 [-0.35, +0.10] | -0.13 [-0.24, -0.02] | +4.29 [+3.81, +4.77] | +12.58 [+12.11, +13.05] |
| one round of float memory (`float_memory=1`: [C16], [C17], [C20], [C21] removed) | 2.27% / 32.33% | -0.01 [-0.11, +0.08] | -0.05 [-0.13, +0.03] | +0.22 [+0.13, +0.30] | +1.16 [+1.06, +1.27] | +0.00 [-0.15, +0.15] | -0.19 [-0.50, +0.13] |
| three rounds of float memory (`float_memory=3`) | 0.71% / 26.11% | -0.02 [-0.07, +0.03] | +0.01 [-0.06, +0.07] | +0.00 [-0.03, +0.04] | +0.07 [+0.02, +0.13] | +0.05 [-0.02, +0.12] | -0.13 [-0.37, +0.10] |
| [C8] removed (`drop:C8`) | 2.73% / 1.96% | -0.07 [-0.17, +0.03] | +0.03 [+0.00, +0.06] | +0.11 [+0.02, +0.20] | +0.02 [-0.00, +0.04] | -0.35 [-0.52, -0.18] | -0.06 [-0.14, +0.01] |

No variant reduced the cascade length measurably: the largest effect is
[C8]'s removal, which lengthens it by 0.01 (S) and 0.02 (L) brackets and
adds 0.06 point-apart boards per 100 in L.

Reading of the table:

* **The exchange rate between colours and floats.** Each step that
  promotes a float criterion above a colour criterion buys about one
  repeated float less for every three to six extra denied colour
  preferences. Removing [C12] outright changes 65% of the rounds in L and
  denies 12.6 more preferences per 100 boards for 0.35 fewer repeated
  floats per 100 player-rounds. The present order ranks colours above
  floats, and that trade is far from free in either direction.
  **Candidate 4a** (`move:C12:after:C21`) is the mildest form of the
  opposite choice. It costs 0.9-1.4 denied preferences per 100 boards
  and removes 0.2-0.4 repeated floats per 100 player-rounds.
* **The two-round memory works.** Without it, repeated floats two
  rounds apart rise by 56% in L (2.06 to 3.22 per 100 player-rounds).
  A third round of memory changes a quarter of the rounds in L, and no
  measured float metric improves; one (repeat float (2)) is slightly
  worse, because the extra criterion competes with [C16]/[C17].
  **Candidate 4b** (no change) is the measured recommendation for the
  memory length.
* **[C14] above the colour criteria** (`move:C14:before:C10`) trades
  repeated floats one round apart for repeated floats two rounds apart
  in S (+0.17). It is not a free improvement either.

**Example 4.2 (one round of float memory changes the pairing).** Seven
players, round 3 of 5; players 6 and 7 had the pairing-allocated bye
(U) in rounds 2 and 1:

    XXR 5
    152 W
    001    1      P1                                2590                             2.0    1     4 w 1     7 b 1
    001    2      P2                                2580                             1.0    2     5 b 1     3 w 0
    001    3      P3                                2570                             2.0    3     6 w 1     2 b 1
    001    4      P4                                2560                             0.5    4     1 b 0     5 w =
    001    5      P5                                2550                             0.5    5     2 w 0     4 b =
    001    6      P6                                2540                             1.0    6     3 b 0  0000 - U
    001    7      P7                                2530                             1.0    7  0000 - U     1 w 0

C.04.3 pairs 1-3, 6-7, 4-2 with the bye to 5. With [C16], [C17], [C20]
and [C21] removed it pairs 1-3, 6-2, 5-7 with the bye to 4. The
difference is entirely the round-1 float history that only the two-round
criteria see.

## 5. Article 5.2.5 and the numbering of late entries

### 5.1 What the text leaves open

When 5.2.1-5.2.4 do not decide a board (always in round 1, and later when
neither player has a colour history that differs), 5.2.5 gives the
higher-ranked player the initial colour if his pairing number is odd
and the other colour if it is even. C.04.2 2.4 says a late entry is
given an appropriate TPN and paired only when he actually arrives. The
text does not say whether 5.2.5's "pairing number" is that TPN or a
numbering of the players who have arrived. The two differ for every
player ranked below a late entrant, and in round 1 they differ on about
half the boards below him.

**Example 5.1 (the two numberings disagree).** Eight players, round 2;
players 3 and 5 have not arrived (Z in rounds 1 and 2), and all three
round-1 games were forfeits:

    XXR 4
    152 W
    001    1      P1                                2590                             0.0    1     6 w -
    001    2      P2                                2580                             1.0    2     7 b +
    001    3      P3                                2570                             0.0    3  0000 - Z  0000 - Z
    001    4      P4                                2560                             0.0    4     8 w -
    001    5      P5                                2550                             0.0    5  0000 - Z  0000 - Z
    001    6      P6                                2540                             1.0    6     1 b +
    001    7      P7                                2530                             0.0    7     2 w -
    001    8      P8                                2520                             1.0    8     4 b +

Only played games count towards colour history, so in round 2 every
board falls to 5.2.5. On board 4-7 the higher-ranked player 4 has
TPN 4 (even, so Black) but is third among the players who have arrived
(odd, so White). The two readings give opposite colours. The reference
used throughout this note pairs 4-7 (the arrival numbering); the TPN
reading pairs 7-4.

### 5.2 How often it matters

* **Our own cross-implementation corpus.** Before this project's engine
  changed reading (v0.14.0), it and bbpPairings 6.0.0 differed on
  exactly this point. On a corpus of 649,207
  rounds they disagreed on the colours of 64,131 of 6,242,974 boards
  (1.03%). On the same seeds after the change they disagreed on 0 of
  7,392,594 boards (a nine-axis rerun).
* **Simulated (corpus E, two late entries per tournament, arriving in
  round 3).** The readings give different colours in 17.3% of all
  rounds (`c525=tpn`), almost all of them round 1, where 5.2.5 decides
  every board. From round 2 on, 5.2.5 decides 0.31 boards per tournament
  [0.27, 0.34], and the readings disagree on 0.04 [0.03, 0.05].

### 5.3 Candidate changes and their simulated effect

| variant (corpus E) | rounds changed | colours only | third colour | \|CD\| >= 2 | denied |
|---|---|---|---|---|---|
| TPN instead of arrival numbering (`c525=tpn`) | 0.00% | 17.29% | +0.04 [-0.01, +0.09] | +0.12 [-0.49, +0.73] | +0.06 [-0.63, +0.76] |
| no parity: the higher-ranked player always takes the initial colour (`c525=initial`) | 0.00% | 17.60% | +0.06 [+0.01, +0.11] | +1.67 [+1.01, +2.34] | +6.52 [+5.76, +7.28] |

Neither reading is better for colour balance: the TPN reading changes no
metric detectably. 5.2.5's alternation itself does real work: without it,
6.5 more preferences per 100 boards are denied, and 1.7 more players per
100 finish on |CD| >= 2. The issue is therefore one of certainty, not of
quality. Two implementations of the same text should give the same
colours, and on 1% of boards in an awkward corpus they did not.

* **Candidate 5a:** state in 5.2.5 that the number is the player's rank
  among the players paired in the round being considered, or among
  those who have been paired at least once. This is the reading the
  reference uses. It needs the arrival order defined when several
  players arrive in the same round, which C.04.2 2.4's "appropriate TPN"
  supplies.
* **Candidate 5b:** state in 5.2.5 that the number is the TPN (C.04.2
  2), whether or not players ranked above have arrived.

Both are one sentence long, and the measurements give no reason to prefer
either on quality.

## 6. Other measurements

### 6.1 The price of [C1]

For scale, the same corpora were paired with [C1] removed: rematches
allowed, and every other rule unchanged. This is not a candidate. It
measures how much of the float behaviour above is imposed by the
prohibition on rematches rather than by [C5]-[C21].

| metric | S: 2026 text | S: rematches allowed | L: 2026 text | L: rematches allowed |
|---|---|---|---|---|
| rounds changed | | 65.6% | | 76.6% |
| point-apart boards per 100 | 29.76 | -14.03 [-14.48, -13.57] | 2.38 | -1.04 [-1.19, -0.90] |
| repeat float (1) per 100 | 17.72 | -9.19 [-9.55, -8.83] | 2.63 | -1.07 [-1.18, -0.95] |
| repeat float (2) per 100 | 12.75 | -5.25 [-5.56, -4.95] | 2.06 | -0.64 [-0.75, -0.54] |
| cascade (brackets) | 2.31 | -1.02 [-1.05, -1.00] | 2.14 | -0.21 [-0.27, -0.15] |
| score gap (points per round) | 2.66 | -1.31 [-1.34, -1.28] | 2.08 | -0.37 [-0.41, -0.33] |
| denied per 100 boards | 30.29 | -7.57 [-8.13, -7.01] | 19.50 | -1.28 [-1.70, -0.85] |
| seeds 1-2 met (%) | 97.4 | -16.8 [-19.2, -14.4] | 54.0 | -17.3 [-23.7, -11.0] |

In a ten-player, seven-round event, [C1] accounts for about half of all
point-apart boards and repeated floats. In S, no variant of [C5]-[C21]
measured here moves the float metrics of this table by more than a tenth
as much. In L the float memory is the exception (section 4.2).

### 6.2 Readings the text leaves open, and whether they matter

| question | readings compared | rounds changed (S / L) | effect detected |
|---|---|---|---|
| [C18]/[C20]: does an MDP who is not paired in the bracket (moves on to the Limbo) count? | counts with a maximal score difference (reference) / only paired MDPs count (`c18=paired`) | 0.73% / 0.63% | none on any metric |
| [C13]: does "strong" include absolute preferences? | strong or absolute (reference) / strong only (`c13=strong_only`) | 0.00% / 0.00% | none: the readings never differed |

Both questions have an answer that some implementer must choose, but on
these corpora the [C13] question never arose, and the [C18] question
changed fewer than 1% of rounds with no measurable consequence. A
clarifying sentence would settle them at no cost. The numbers give no
reason to prefer either reading.

### 6.3 Criteria whose removal changes little

| variant | rounds changed (S / L) | effects detected (S) |
|---|---|---|
| [C9] removed (`drop:C9`) | 0.67% / 3.30% | \|CD\| >= 2: -0.13 [-0.24, -0.02]; nothing in L |
| 1.7.1 threshold \|CD\| > 2 (`absolute_cd=2`) | 0.09% / 0.07% | third colour -0.01 [-0.03, -0.00] |

[C9] (fewest unplayed games for a downfloater who will take the bye)
changes a few rounds and nothing measurable in these corpora, which have
few unplayed games. It may matter more in events with many forfeits,
and the VM run (section 8) should be extended with such a corpus before
anyone draws a conclusion about it.

## 7. Limits of this evidence

* **Simulated tournaments.** The tournaments are generated, not
  recorded. The rating model, the 5% requested-bye rate and the 3%
  forfeit rate are choices, and absolute rates (streaks per 100 games,
  floats per player) depend on them. Differences between rule variants
  measured on the same tournaments are less sensitive to the model than
  absolute rates, but not independent of it.
* **Field sizes.** The exact reference is limited to about 10 players.
  The 40-player figures rest on the matching formulation, which agreed
  with the reference and with the engine on every round compared but is
  not proved equal to them.
* **Readings.** Every number assumes the readings in section 2.1. A
  reader who takes [C18]/[C20] or 5.2.5 differently will see different
  numbers; the effect of the alternative [C18]/[C20] reading is itself
  measured in section 6.
* **What the simulator cannot vary.** Absolute criteria other than [C1]
  and [C3], Article 5.2.1-5.2.4, acceleration and forbidden pairs are
  fixed. Variants act on the quality criteria, the 1.7.1 thresholds, the
  float memory, 5.2.5's number and three readings.
* **Sample sizes.** The figures are from desktop-sized runs. Where an
  interval includes zero, the honest statement is "no effect detected at
  this sample size", not "no effect".

## 8. Reproducing these figures

From a checkout of the repository (Elixir 1.18 or later):

    cd lab
    mix deps.get && mix test                     # the simulator's own checks
    MIX_ENV=prod mix escript.build               # ./ainalrami-lab
    tools/paper_runs.sh runs/paper 1 14          # the sample runs in this note
    mix run tools/summarise.exs runs/paper       # the tables
    mix run tools/examples.exs                   # the minimal examples

The full-size runs, for the project's 80-core machine:

    cd lab && MIX_ENV=prod mix escript.build
    nohup tools/paper_runs.sh runs/paper-vm 20 78 > runs/paper-vm.log 2>&1 &
    mix run tools/summarise.exs runs/paper-vm
    ./ainalrami-lab fidelity --corpus generated:players=10,rounds=7,count=20000,absent=0.05,forfeit=0.03 --against brute --workers 78
    ./ainalrami-lab fidelity --corpus generated:players=100,rounds=11,count=2000,absent=0.05,forfeit=0.03 --against engine --workers 78
    ./ainalrami-lab simulate --variant c525=tpn --corpus generated:players=60,rounds=9,count=4000,absent=0.1,forfeit=0.1,late=6 --workers 78 --out runs/c525-large

`paper_runs.sh` at scale 20 is 20,000 tournaments per variant for S and
E and 6,000 for L. A stopped run resumes where it stopped.

Fidelity of the matching formulation used for L (`ainalrami-lab fidelity`,
local sample, 2026-11-08). Every round of every tournament played with
the matching formulation is re-paired with the brute force (fields of 10)
or with the engine (larger fields, 2026 text only), and the results are
compared:

| hybrid compared with | corpus | variant | rounds | differing | 95% upper bound |
|---|---|---|---:|---:|---:|
| brute force | 10 x 7, 500 tournaments | baseline | 3,500 | 0 | 0.11% |
| brute force | 10 x 7, 300 | `drop:C12+streak=3` | 2,100 | 0 | 0.18% |
| brute force | 10 x 7, 300 | `move:C12:after:C21+float_memory=1` | 2,100 | 0 | 0.18% |
| brute force | 10 x 7, 300 | `c3=off+drop:C13` | 2,100 | 0 | 0.18% |
| brute force | 10 x 7, 300 | `move:C14:before:C10+float_memory=3` | 2,100 | 0 | 0.18% |
| brute force | 10 x 6, 300, late entries | `c525=tpn` | 1,800 | 0 | 0.21% |
| Ainalrami engine 0.51.1 | 40 x 9, 100 | baseline | 900 | 0 | 0.43% |
| Ainalrami engine 0.51.1 | 100 x 11, 40 | baseline | 440 | 0 | 0.87% |

The test suite holds the same agreement on fixed fixtures for every
variant used in this note.

## 9. Reviewer notes (remove before sending)

* **Provenance.** Only C.04.1-C.04.3 and this repository's own
  measurements are cited. The SPP's 2026-08-27 answer on 5.2.5 is
  deliberately not cited: section 5 stands on the text and the numbers.
  No informal contact is cited or alluded to anywhere.
* **Quotations.** The wording of 1.7.1, [C3], 5.2.5 and C.04.2 2.4 is
  paraphrased in places. Before anything is sent, every article referred
  to must be checked against, and where quoted, quoted verbatim from,
  the official C.04.3 (2026) and C.04.2 texts. Section 5.1 also states that
  only played games count towards colour history: add the article.
  Example 3.1 relies on 5.2.2 settling two absolute preferences by the
  wider colour difference: check that against the text word for word.
* **Sample sizes.** S and E are 1,000 tournaments, L 300. Several
  effects in the tables sit near the edge of their intervals; run the VM
  commands in section 8 (20x) before relying on any effect smaller than
  about 0.2 per 100.
* **Tone check.** The note proposes nothing. Each candidate change is
  there because it is the smallest edit that addresses the measured
  behaviour, not because the project wants it. If the maintainer does
  want to propose something, that belongs in a covering letter.
* **The rating model** (section 2.3) is ours and simple. A reviewer may
  reasonably ask for the same tables on recorded tournaments;
  `ainalrami-lab simulate --corpus trf:DIR` replays a directory of TRFs
  under both arms (round by round, on the recorded history), which is
  the answer to have ready.
* Remove this section before sending.

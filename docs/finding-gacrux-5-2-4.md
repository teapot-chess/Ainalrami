# Finding: Gacrux reads Article 5.2.4's "higher ranked" as TPN order

**RETRACTED 2026-10-26.** Gacrux does not read "higher ranked" as TPN order. Cause: the harness called Gacrux without `-n R`, and without it Gacrux pairs "1 + the last round holding an over-the-board game" (`TieBreakServer/trf2json.py:699-706`), so after a round of forfeits and byes only it re-pairs that round and returns the pairing already in the file. Given the round with `-n`, Gacrux, bbpPairings and Ainalrami return identical boards on both boards (the diagnosis below is wrong: Gacrux re-paired the all-forfeit round 3 instead of round 4). The harness now passes the round; the text below is kept as the record of what was believed.

**Status: adjudicated 2026-08-28, and reported upstream.**
Not a finding against this engine. Ainalrami and bbpPairings agree on both
boards; Gacrux is alone.

## The claim

C.04.3 Article 5.2.4 says to *"grant the colour preference of the higher
ranked player"*. **Higher ranked** is defined by Article 1.2: **score first,
then TPN ascending**. Gacrux appears to compare TPN alone, so on any board
where 5.2.4 decides and the two players are on different scores, it hands
the preference to the wrong one.

## The evidence

Two boards, from two independent axes of the 2026-08-28 corpus run, found by
the three-way harness with `COLOUR_DEBUG=1`. They are the *only* two boards
in **7,392,594** on which the two reference engines contradict each other
about colour.

### Board A - `forfeits10`, seed 95201844, round 4

```
  bbpPairings says 2 is White, Gacrux says 3 is White
  #2 pts=1.5 games=[b= w1 b-]
  #3 pts=2.0 games=[b0 w1 w+]
```

### Board B - `everything-gacrux-allows`, seed 95803946, round 4

```
  bbpPairings says 3 is White, Gacrux says 2 is White
  #3 pts=2.0 games=[w= b= b+]
  #2 pts=1.5 games=[w= b1 w-]
```

Ainalrami answers with bbpPairings on both.

## Working board A through Article 5.2

Round 3 was a forfeit for both players (`-` and `+`), and a forfeit is
unplayed under FIDE Art. 16, so it contributes no colour. That leaves:

| | played colours | difference | last colour | preference |
|---|---|---|---|---|
| #2 | b, w | 0 | White | mild, Black |
| #3 | b, w | 0 | White | mild, Black |

- **5.2.1** cannot apply - the preferences do not differ.
- **5.2.2** cannot separate them - both mild, both zero imbalance.
- **5.2.3** cannot separate them - the two played rounds gave them the *same*
  colour as each other, so there is no "most recent round in which one had
  White and the other Black".
- **5.2.4** therefore decides: the higher ranked player takes the shared
  preference (Black) and the other gets White.

Article 1.2 orders by score first. #3 has 2.0 and #2 has 1.5, so **#3 is
higher ranked**, takes Black, and #2 is White. That is bbpPairings' answer
and this engine's.

Order by TPN alone and #2 is "higher", takes Black, and #3 is White. That is
Gacrux's answer.

Board B has the identical structure with the colours mirrored, and the same
substitution explains it: by score #3 is higher and takes the shared White
preference; by TPN #2 is.

**One rule, two boards, both explained.** Not two unrelated flukes.

## Why forfeits appear in both

They are what creates the tie. 5.2.4 is only reachable when neither 5.2.1,
5.2.2 nor 5.2.3 can separate the players, which needs their colour histories
to be effectively identical - uncommon in ordinary Swiss play, because
different opponents give different colours.

An unplayed round is the cheap way to get there: it removes a round from
*both* histories at once and can leave two players who were diverging with
the same effective colour sequence. That is why the two boards are on the
forfeit axis and the combined axis, and on none of the seven others.

## This engine had the same defect

Worth stating plainly, because it is the reason the diagnosis was quick and
because it says something about how easily 5.2.4 is missed.

Ainalrami skipped 5.2.4 entirely and fell straight to 5.2.5's parity rule.
The comment in `Pairing.choose_colour/2` records the fix:

> "Higher ranked" is Article 1.2 - SCORE first, then TPN ascending - not TPN
> alone. A bracket routinely holds players on different scores (every
> moved-down player is one), and comparing TPN there hands the preference to
> the wrong player.

Same article, same wrong reading, different engine.

## Reproducing

```bash
GACRUX_DIR=../TieBreakServer GACRUX_PYTHON=python3 \
  BBPPAIRINGS_EXE=/root/bbpsrc/bbpPairings.exe \
  MIX_ENV=test COLOUR_DEBUG=1 \
  PAIRING_FUZZ_COUNT=10000 PAIRING_FUZZ_ROUNDS=9 \
  PAIRING_FUZZ_SEED_FROM=95200001 PAIRING_FUZZ_FORFEIT_PCT=10 \
  mix test --only three_way
```

The second board comes from the same command with
`PAIRING_FUZZ_SEED_FROM=95800001`, `PAIRING_FUZZ_BYE_PCT=12`,
`PAIRING_FUZZ_FORFEIT_PCT=10`, `PAIRING_FUZZ_WITHDRAW_PCT=8`,
`PAIRING_FUZZ_RATING_MODE=mixed`, `PAIRING_FUZZ_INITIAL_COLOUR=mixed`.

## What this does not claim

Two boards is two boards. The substitution explains both exactly and the
mechanism is one this project has already been caught by, which is strong -
but it is inference from behaviour, not a reading of Gacrux's source. The
report should say so and invite them to check the line rather than assert
what it says.

It also does not touch Article 5.2.5. Both boards are labelled
`0 within 5.2.5's reach`: they are decided by 5.2.1-5.2.4, which nobody
disputes and which the SPP's 2026-08-27 ruling does not bear on.

# Gacrux breaks Article 5.2.5: two boards of one round need opposite initial colours

**RETRACTED 2026-10-26.** Gacrux does not break Article 5.2.5. Cause: the harness called Gacrux without `-n R`, and without it Gacrux pairs "1 + the last round holding an over-the-board game" (`TieBreakServer/trf2json.py:699-706`), so after a round of forfeits and byes only it re-pairs that round and returns the pairing already in the file. Given the round with `-n`, Gacrux, bbpPairings and Ainalrami return identical boards on the fixtures (`seed32007296` with `-n 2` gives `6 8 / 4 1 / 5 0`, as bbpPairings does). The harness now passes the round; the text below is kept as the record of what was believed.

**Status:** confirmed and reproducible, 2026-09-08. Supersedes the reading
recorded earlier the same day, which said the consistency check could not
detect a 5.2.5 violation in Gacrux at all. That reading was wrong. See
"How the earlier verdict went wrong" below, because the mistake is more
instructive than the finding.

**Reproduction:** `test/fixtures/gacrux_5_2_5/seed32007296_r2_p8.trf`

```
python pairingchecker.py -i seed32007296_r2_p8.trf -o out.txt -p -dT -m dutch
```

gives

```
3
5 1
4 6
8 0
```

Confirmed against the checkout on 2026-09-08, byte for byte what the
2026-08-29 validation corpus recorded (`ain_val_run`, axis `3way-everything`,
seed 32007296).

## The position

Eight players, round 2 to pair. Ranks 2, 3 and 7 already carry a round-2
entry and sit it out, so the round is ranks 1, 4, 5, 6 and 8 - five players,
one of whom takes the bye.

| rank | round 1 | points | plays round 2 |
|---|---|---|---|
| 1 | `5 b -` forfeit loss | 0.0 | yes |
| 4 | `6 w -` forfeit loss | 0.0 | yes |
| 5 | `1 w -` forfeit loss | 0.0 | yes |
| 6 | `4 b +` forfeit win | 1.0 | yes |
| 8 | `0000 - U` pairing bye | 1.0 | yes |

Every one of those five games is legally **unplayed** under Article 16 - a
forfeit and a bye alike - so nobody holds a colour preference going into
round 2. That is not our reading imposed on Gacrux: Gacrux accumulates
colour difference and sequence only `if comp["played"] and
comp["opponent"] > 0` (`tiebreak.py`), so it agrees. Every board of this
round is therefore Article 5.2.5's to decide.

## The contradiction

5.2.5: where neither player has a colour preference, the higher-placed
player (Article 1.2: higher score first, then lower number) takes the
initial colour if their number is odd, and the other colour if it is even.

Gacrux's two boards:

| board | higher placed | why | number | parity | they took | so the initial colour was |
|---|---|---|---|---|---|---|
| `5 1` (5 White, 1 Black) | rank 1 | equal scores, lower rank | 1 | odd | Black | **Black** |
| `4 6` (4 White, 6 Black) | rank 6 | 1.0 beats 0.0 | 6 | even | Black | **White** |

One tournament has one initial colour. These two boards need different
ones, so at least one of them is wrong, and no assumption about the draw
rescues both.

**The finding does not depend on the numbering question.** Take the numbers
as starting ranks (1 and 6) or as arrival numbers under the SPP's
2026-08-27 reading (1 and 4) and the parities are odd and even either way,
so the contradiction stands under both. That matters because which
numbering Gacrux uses is still unsettled - see
`tools/gacrux_tpn_membership_probe.exs` - and this finding is independent
of it.

**Which board is wrong.** The file declares `152 B`, an initial colour of
Black. Board `5 1` agrees with that. Board `4 6` does not: rank 6 is higher
placed with an even number, so it should take the colour that is *not* the
initial one - White - and Gacrux gave it Black. bbpPairings and Ainalrami
both pair this round differently and neither produces the clash.

## How the earlier verdict went wrong

Earlier on 2026-09-08 this was adjudicated from source alone, because the
box holding the corpus was down. The argument ran: Gacrux's E.5 branch
(`pairingdutch.py`) is one tournament-wide constant `self.topcolor`
combined with one parity test on `hightpn`, therefore every E.5 board in a
round implies the same initial colour *by construction*, therefore an
internal contradiction is not something Gacrux can produce, therefore the
seventeen firings must be the checker's fault.

Every step of that is sound reasoning about the code as read. The
conclusion is false, and this position is the counterexample. Whatever the
mechanism inside Gacrux - a `topcolor` that is not as constant as it looks,
a board reaching a different branch than expected, something not yet
found - the observable behaviour contradicts the deduction.

The lesson is the ordinary one and worth writing down because it was
ignored: a proof from reading code predicts what an implementation does; it
does not observe it. When a corpus of a million rounds says a thing happens
and a reading says it cannot, the reading is the thing to doubt. The
reading was allowed to overturn the measurement because the measurement was
temporarily unreachable, which is exactly backwards.

## Still open

- **The mechanism.** This documents what Gacrux does, not why. An upstream
  report should carry the position and the two boards; diagnosing
  `topcolor` is its author's job, not ours.
- **A second recorded case**, `seed32010783_r2_p8.trf` (the corpus logged
  it as 2 boards implying White against 2 implying Black), reproduces too
  but is muddier: Gacrux there pairs all eight players including two who
  already carry a round-2 result, where this engine pairs only the six who
  do not. That is a disagreement about *which round is being paired*, not
  about colours, and it needs separating before the position can be read as
  a 5.2.5 case.
- **Seventeen firings** were recorded across the corpus. Two are kept here
  as fixtures; the rest are in the run's own summary.

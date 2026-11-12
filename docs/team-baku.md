# Baku acceleration for a team Swiss (C.04.7 over C.04.6)

What FIDE says about accelerating a team Swiss, what it leaves to the
reader, and which reading this engine implements. Written 2026-11-12,
before OpenPairings offered the option. Every point below is marked
**FIDE** (the text says so) or **reading** (our transposition; FIDE does
not say it in so many words).

## Sources

- **C.04.7**, *FIDE-approved Accelerated Systems* (the Baku Acceleration
  Method), approved by the Council on 28/10/2025, applied from
  1 February 2026. FIDE Handbook, `handbook.fide.com/chapter/C0407202602`.
- **C.04.6**, the Swiss Team Pairing System, effective 1 February 2026
  (`docs/c0406-regulation-text.md`).
- **TRF-2026** (`tec.fide.com/trf-2026`, `TRF-2026.pdf`), record 250,
  "Accelerated Rounds (for both individual and team tournaments)".
- **Tournament Type Code Table for TRF_CODE 192** (same page,
  `TournamentTypeCodeTable192-TRF26.pdf`).

## What FIDE says

1. **Teams are in scope. FIDE.** C.04.7 1.4.4's Example 2 is "an 11-round
   team competition with matchpoints" as the primary score (2 for a win,
   1 for a draw): Group A teams get two virtual matchpoints in the first
   three rounds and one in the next three.
2. **Only with match points primary. FIDE.** Example 2's footnote: "if
   gamepoints were the primary score, the Baku Acceleration could not be
   used". The type-code table agrees: every team `_BAKU` code has MP as the
   primary score - `FIDE_TEAM_TYPEA_MP_GP_BAKU`, `FIDE_TEAM_TYPEA_MP_BAKU`,
   the `TYPEB` pair, `FIDE_TEAM_MP_GP_BAKU`, `FIDE_TEAM_MP_BAKU` and
   `FIDE_TEAM_BAKU` (= `FIDE_TEAM_TYPEA_MP_GP_BAKU`). There is no
   `..._GP_..._BAKU`.
3. **Scoring. FIDE.** C.04.7 1.1: the method applies where a win is worth
   two draws and a loss nothing. C.04.6's default 2/1/0 match points
   qualifies; 3/1/0 does not.
4. **Group A. FIDE.** C.04.7 1.2: the first half of the participants,
   rounded up to an even number - `2 * ceil(n / 4)`, which is the pairing
   number of the last Group A participant. 1.3: the last Group A
   participant stays where it was when a late entrant arrives.
5. **Rounds and values. FIDE.** C.04.7 1.4: the accelerated rounds are the
   first half of the event, rounded up; Group A gets a win's worth in the
   first half (rounded up) of those and half of it in the rest; Group B
   never gets any, and nobody gets any after the last accelerated round.
6. **Pairing score. FIDE.** C.04.7 1.5: the pairing score is the
   standings points plus the virtual points, and it is what defines the
   scoregroups, orders them, and orders the boards.
7. **The file. FIDE.** TRF-2026 record 250: columns 5-8 "fictitious match
   points", "used for team competitions only"; 10-13 fictitious (game)
   points, which in a team competition "may be empty"; at least one of the
   two must be non-zero; 15-17 / 19-21 the first and last round; 23-26 /
   28-31 the first and last "Player/Team ID".
8. **TRF-2026's example. FIDE, and odd.** "in a 11 round Swiss team
   tournament based on matchpoints with 178 teams" the method is
   `250 00.0 02.0 001 003 0001 0090` / `250 00.0 01.0 004 006 0001 0090`.
   Group A 1-90 (`2 * ceil(178 / 4)`) and rounds 1-3 / 4-6 match C.04.7.
   But the values stand in the **game-points** column with `00.0` in the
   match-points one, in an event the same sentence says is based on match
   points, under a field definition that reserves 5-8 for match points.

## What FIDE does not say, and what we read

- **Group A is cut by Team Pairing Number. Reading** (high confidence).
  C.04.7 defines Group A on "the list of participants to be paired
  (properly sorted)"; for teams that list is C.04.6 1.1's TPN order, and
  1.2's note equates `2 * ceil(n / 4)` with the TPN of the last Group A
  participant. TRF-2026's example (teams 1-90 of 178) agrees.
- **`n` is the number of teams when round 1 is paired**, frozen after
  that. **Reading** of 1.3 for teams, the same as the individual engine's
  (`baku_group_a_last` in OpenPairings).
- **Virtual points are match points only; no virtual game points.
  Reading.** C.04.7 adds virtual points to the "standings points", which
  for a team event is the primary score; Example 2 gives matchpoints and
  nothing else. So the secondary score (game points), which C.04.6 4.2.2
  uses to choose the first team, gets nothing.
- **Values follow the event's match points.** A win's worth (2 under
  2/1/0), then a draw's. **FIDE** for 2/1/0 (Example 2); for another
  scale satisfying 1.1, e.g. 4/2/0, our **reading** of 1.4's "points for a
  win".
- **"Wherever the pairing reads a score" means everywhere in C.04.6.
  Reading.** C.04.7 1.5 names scoregroups, their internal order and board
  order. C.04.6 also reads the score in 3.4.2 (the bye: "lowest score"),
  3.5 (upfloater score profiles, [C5]/[C6]), 1.5/[C7]/[C10] (floaters:
  "a different score"), 2.3.2 (score differences), and 4.2.1 (the first
  team: "higher score"). We use the pairing score in all of them. The
  alternative - pairing score for the brackets, real score for the rest -
  would let a team float in a bracket it was not put in.
- **Floaters are judged on the pairing scores of the round they played
  in. Reading**, following from the line above: a Group A team on 0 + 2
  that met a Group B team on 2 + 0 did not float.
- **Tie-breaks and standings never see virtual points. Reading**, but an
  easy one: C.04.7 calls them virtual and defines them for the pairing
  score only; its preface says acceleration must not compromise the
  final ranking. No FIDE text says "excluded from tie-breaks" in so many
  words, for individuals or teams.
- **The bye and byes.** The pairing-allocated bye (C.04.6 3.4) goes to
  the lowest *pairing* score - so in an accelerated round it normally
  goes to Group B. A team on a requested half-point bye (`240 H`) is not
  paired that round and its virtual points for that round go unused; they
  are not carried forward. **Reading** - C.04.7 attaches virtual points to
  rounds, not to games.
- **Reading TRF-2026's example layout. Reading.** A file is read as
  written: 5-8 are virtual match points, 10-13 virtual game points. A
  `_BAKU` team file whose `250` records carry *no* match points at all but
  do carry game points (the example's layout) is read the way the example
  means it: those values are the virtual match points. A file with match
  points in 5-8 is never reinterpreted. Ainalrami writes match points in
  5-8 and leaves 10-13 blank.
- **A `250` naming teams in a code without `_BAKU`** is applied all the
  same, as `XXA`/`250` are for an individual file. **Reading** (the
  spec's record note says the 250s override the `192` for one kind of
  file and is silent on the rest).

## Where it lives

- `Ainalrami.Acceleration.team_baku_table/3`, `team_baku/3`,
  `team_virtual_points/3` - Group A, the values, applied to a round's teams.
- `Ainalrami.TeamPairing.Team` - `:virtual_match_points` /
  `:virtual_game_points`; `Team.score/2` and `secondary_score/2` add them.
  The real `:match_points` / `:game_points` are untouched.
- `Ainalrami.Trf` - team `250`s read into `tournament[:team_accelerations]`
  (`%{tpn => [{mp, gp}, ...]}`) and written back.
- `Ainalrami.TeamReplay` - `_BAKU` team files replayed with them; refused
  without them, and refused on game points.
- CLI: `--acceleration=baku [--baku-group-a=N]` on a team Swiss (`-p`,
  `-x`, `-c`), and on `-g --team=swiss`.
- `Ainalrami.TeamCertificate` / `verify/` - the input record carries the
  virtual points (only when non-zero), and the checker adds them to the
  score it weighs.

## Worth asking the SPP

1. Is TRF-2026's 250 example meant to have the values in the match-points
   column?
2. Does C.04.7 1.5's pairing score also stand in C.04.6 3.4.2, 1.5
   (floaters) and 4.2.1, or only in the three places 1.5 names?
3. Do Group A teams get virtual game points too (affecting 4.2.2)?

# Every recorded difference from bbpPairings, re-checked (2026-10-18)

**Asked:** confirm the claim "2.33 billion individual-Swiss pairings against
bbpPairings 6.0.0, 11 differing rounds, all where bbpPairings itself errors:
3 confirmed as its known C2 bug, 8 still to confirm".

**Answer, short:**

- **The claim is not in any record.** Neither "2.33 billion" nor "11
  differing rounds" appears in this repository, its fixtures, its tools, the
  validation run folders under `VPS projects\`, or anywhere else searched.
  The only place either number is written down is the OpenPairings
  `TODO.md`, which says itself that the figures came from the maintainer and
  are unverified.
- **Six differences are recorded, not eleven.** All six are bbpPairings
  handing a pairing-allocated bye to a player [C2] bars from one. In every
  one Ainalrami's answer is legal and bbpPairings' is not.
- **Five of the six are now confirmed as the bit-field bug** of
  [finding-bbp-2026-10-07.md](finding-bbp-2026-10-07.md), not three: a
  bbpPairings build with the one-line fix returns Ainalrami's pairing
  board for board, colours included, on all five. The sixth has no file to
  reproduce from (see below).
- **The "8 still to confirm" cannot be confirmed because they are not
  identified anywhere.** No seed, dump or log names them. They are not
  invented here.
- **Nothing shows Ainalrami wrong.** No failing test was needed.

## Where the figures were looked for

| place | what is there |
|---|---|
| `docs/validation.md` | six corpora 2026-08-20..24: **2,536,328,265 pairings, 217,470,056 rounds, 2 disagreements**; the 2026-08-26 re-run: 1,561,865 pairings, 0; the 0.36.0 release check (2026-10-02): 135,834,302 pairs / 10,614,756 rounds, 1 disagreement; Q33 direction 2: 28,964,816 pairings, 0 |
| `docs/bbppairings-c2-bug-report.md`, `test/fixtures/fe1_disputes/README.md`, `docs/dispute-seed735265.md` | four positions, each a C2 second bye |
| `docs/finding-bbp-2026-10-07.md` | one position from the VM run in `/root/w-indiv25` (job 00193); the run's totals are not written down anywhere |
| `CHANGELOG.md`, `README.md` | "2.5 billion", two known disputes, the 10-02 mismatch |
| `test/fixtures/`, `crash_reports/`, `overnight_run/`, `tools/` | the four fixture files; no other bbpPairings dumps |
| `VPS projects\ain_val_run_2026-08-29` | the three-way colour run (Article 5.2.5 vs Gacrux); no bbpPairings composition differences |
| OpenPairings `TODO.md` (and copies in other checkouts) | the only "2.33 billion / 11 differing rounds / 3 + 8" text, marked as the maintainer's, unverified |
| the 80-core VM, `172.16.63.250` | **unreachable on 2026-10-18** (ssh: connection timed out). `/root/w-indiv25/jobs/*.log` and `dumps/` were not read. If the 2.33 billion figure is that run's tally, that is where it would be checked |

**Figures, verified or corrected:**

- *2.33 billion pairings*: **not verified.** No record gives it, and no sum
  of recorded runs makes it. The recorded figure is 2,536,328,265
  (2.54 billion) over the six corpora; adding the later recorded
  bbpPairings runs gives about 2.70 billion. The `w-indiv25` run, whose
  totals are not on file, is the likeliest source of a different number.
- *11 differing rounds*: **not verified; the record says 6.** Two in the
  six corpora (#2, #3), one in the release check (#6), one in the
  `w-indiv25` run (#5), and two from runs outside the corpora table: the
  1,000,000-tournament small-field run (#1) and the 2026-08-26 mixed
  point-system axis (#4).
- *3 confirmed as the C2 bug*: **corrected to 5**, by a fixed build (below).
  All 6 are recorded as C2 breaches by rule.
- *8 still to confirm*: **not identified in any record.**

One possibility, labelled as such: the 0.36.0 release check reports
"8 bbpPairings process errors" next to its one C2 mismatch, and "all where
bbpPairings itself errors" could be a reading of that. A process error is
not a differing round. bbpPairings gave no answer to compare, and the
harness keeps those out of the rates. This is a guess about where the
number came from, not a finding.

## The six

All pairing numbers are ranks. "bbp" is bbpPairings 6.0.0 (the release
binary at `openpairings/priv/bbppairings/bbpPairings-windows.exe`).
"Fixed" is the same source (commit 8f9e3c5, `VPS projects\bbpPairings-source`)
built locally with `dutch.cpp:715` changed to
`bitsToRepresent<unsigned int>(std::max<tournament::player_index>(maxScoreGroupSize, sortedPlayers.size()))`.
An unpatched build of the same source gives the release binary's answer on
all five, so the fix is the only thing that changes the output.

| # | position | found in | round | Ainalrami | bbp | what differs | verdict | evidence |
|---|---|---|---|---|---|---|---|---|
| 1 | `fe1_disputes/seed735265-r7-p10.trf` | 1M-tournament small-field run, 4-10 players, 15% byes | 7 | 5-1 8-2 3-9, bye 7 | 7-5 8-1 2-9, bye 3 | bye to 3, who holds `0000 - U` from round 2 | **bbp wrong, bit-field bug** | rule check: bbp breaks C2, Ainalrami legal; bbp `-l` prints `C2 = N` on its own bye row; fixed build = Ainalrami; Gacrux = Ainalrami (recorded) |
| 2 | `fe1_disputes/seed8848759-r9-p10.trf` | six-million run, axis 4-10 with 15% byes (seeds from 7,000,001; README dates it 08-19, the run's start) | 9 | 1-4 7-10 5-2, bye 3 | 1-2 7-10 3-5, bye 4 | bye to 4 (`U` in round 4), whose only legal opponent is 1 | **bbp wrong, bit-field bug** | as #1; forced 1-4 by hand in the fixtures README |
| 3 | `fe1_disputes/seed7073463-r8-p9.trf` | six-million run 2026-08-20, random acceleration | 8 | 9-7 2-1 4-8, bye 6 | 6-1 9-7 4-2, bye 8 | bye to 8 (`U` in round 6); the round has one legal shape | **bbp wrong, bit-field bug** | as #1; the shape follows by elimination (fixtures README) |
| 4 | `c2_seed8112174-r9-p18.trf` | 2026-08-26, mixed point systems x withdrawals (football 3-1-0) | 9 (last) | 6-18 14-13 9-11, bye 8 | 9-8 11-18 14-13, bye 6 | bye to 6, which holds `U` in round **4** (the bug report says round 3; the file says 4) | **bbp wrong, bit-field bug** | as #1. The bug report wondered if a `U` worth a win on this point system was a second mechanism; the fix alone corrects it, so it is the same one |
| 5 | `seed2120538796-r6-p8` (TRF in the 10-07 finding) | `w-indiv25`, job 00193, 2026-10-07 | 6 | 4-2 7-5 6-3, bye 8 | 4-2 8-7 6-3, bye 5 | bye to 5 (`U` in round 4) | **bbp wrong, bit-field bug** | as #1; the root-cause case |
| 6 | seed 15122973, round 6 | 0.36.0 release check, Baku, 4-40 | 6 | not on file | not on file | recorded as a bbp answer that breaks C2 | **bbp wrong by the record**, mechanism unchecked | `validation.md`, release check. The dump stayed on the VM, and the run's generator settings are not recorded. Two guesses at them, re-run on seed 15122973, did not reproduce a mismatch |

The six-million run's two disagreements are #2 and #3: its axes with a
disagreement are "4-10, 15% byes" (11,644,432 rounds; #2 was "found 11.6
million rounds into" a 4-10, 15% byes run from seed 7,000,001) and "random
acceleration" (#3). That is an inference from the axis, the seed range and
the round count, not a record that names the seeds. The C2 bug report fits
it: it calls #1, #2 and #3 "the only ones" across all the runs to that date,
and #1 is from the earlier small-field run.

**Five reproduced here and confirmed as the bit-field bug (#1-#5). One (#6)
is recorded as a C2 breach and could not be re-run here.**

### How each was checked

1. Both engines on the file: `bbpPairings.exe --dutch f.trf -p bbp.txt -l bbp.list`
   and `mix run -e 'Ainalrami.CLI.main(["-p", "f.trf", "ain.txt"])'`
   (worktree of `main` at ea64fd7).
2. Both answers through `tools/rule_check_round.exs`, written for this pass
   and sharing no code with either engine. It checks that every present
   player is paired exactly once and that there is at most one bye, and only
   on an odd field. It checks C1 (no rematch), C2 (no bye to a player with an
   earlier `U`, `F` or `+`) and C3 (no pair whose absolute colour
   preferences match). Its C3 is the strict form without the last-round
   top-scorer exception, which only makes "legal" harder to earn. Result:
   **Ainalrami legal on all five; bbp breaks C2 on all five and nothing
   else.**
3. bbpPairings' own checklist: on all five, the row bbp marks `(bye)` has
   `C2 = N`. bbpPairings' checker knows the bye is illegal; its pairer
   assigns it anyway.
4. The fixed build: output identical to Ainalrami's on all five, including
   who has White.

Legality alone shows bbp is wrong. Whether Ainalrami's pairing is the
*best* legal one rests on two things. For #2, #3 and #5 the position leaves
one legal shape, shown by hand in the fixtures README and the 10-07
finding. For #1 and #4, a corrected bbpPairings and (for #1) Gacrux each
reach Ainalrami's answer independently.

### Reproduce

```bash
# release, unpatched and fixed bbpPairings side by side
for f in test/fixtures/c2_seed8112174-r9-p18.trf test/fixtures/fe1_disputes/*.trf case6.trf; do
  bbpPairings.exe --dutch "$f" -p bbp.txt
  bbp-fixed.exe   --dutch "$f" -p fix.txt
  mix run -e "Ainalrami.CLI.main([\"-p\", \"$f\", \"ain.txt\"])"
  elixir tools/rule_check_round.exs "$f" bbp.txt ain.txt
done
```

`case6.trf` is the TRF in [finding-bbp-2026-10-07.md](finding-bbp-2026-10-07.md),
under "Reproducer". The fixed build is `make static=yes` on
`bbpPairings-source` with the line-715 change above. The binaries were built
in a scratch directory and are not committed.

## What would close the gap

- Read `/root/w-indiv25/jobs/*.log` on the VM when it is back: the run's
  totals, its mismatch count and its dumps. If it holds more than job
  00193's case, each goes through the four steps above.
- Ask the maintainer where "2.33 billion" and "11" were read from. Until
  then, the quotable figures are the recorded ones: **2.54 billion pairings
  in six corpora with 2 disagreements**, and **6 recorded differences in
  all, every one a bbpPairings C2 breach, 5 confirmed as the bit-field bug
  by a fixed build.**

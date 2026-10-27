# Performance

First where the certified shortcuts switch on, then the score variants
(`Pairing.pair_variants/3`, the batch behind OpenPairings' next-round
preview). Then the timing study, which measures
all three engines on 3,000 random positions and is the figure to quote.
Then seven passes, newest first: the
whole-field build, the weighted matcher itself (the blossom fallback), the slow tail of the last
round, the slow spots the direct bracket left, the
direct bracket on odd fields, the direct bracket itself, which took the
pairing past Gacrux on every benchmark file, and the large-field pass
before it. The passes measure single benchmark positions, one per row;
read their tables as before-and-after on those positions, not as a
comparison of engines.

## The certified shortcuts' threshold (2026-10-08)

`pair_next_round/2` took the certified shortcuts (the direct bracket on
the field graph, certified installs, window brackets, the certified reads;
see "certified shortcuts" in the source) from 100 active players up. That
line came in with the shortcuts themselves (e46ef5c) with a reason - "a
small round's searches are cheap and its reads are the ones most often
tied" - and no measurement. The profile under the score variants above
then found forced shortcuts 3-7x faster on 80-player positions. This pass
times the line.

Correctness was never what the line was for. Every shortcut either holds
a certificate that the reference search would read the same value, or
throws, and the round is paired again from the start on the reference
path; nothing in that depends on the field size. The forced mode
(`AINALRAMI_CERT=force`) has been held to the reference on the small
corpus (370,777 rounds of 4-40 players, "The direct bracket" below) and
by `test/ainalrami/direct_bracket_test.exs` on every `mix test`.

### Method

`tools/cert_threshold.exs`: fuzz tournaments of exactly 10, 20, 30, 40,
60, 80, 100 and 150 players, nine rounds, with requested byes (8%),
forfeits (5%), forbidden pairs, withdrawals, late entrants, accelerations,
point systems, initial colours and rating shapes all drawn per tournament,
the arbiter's soft pairs on a third of tournaments and organiser bye
exclusions on a third of rounds (as `tools/perf_diff.exs` draws them).
Rounds 3-9 of each are paired under every mode in a shuffled order, the
best of three calls per mode, one scheduler per worker, 16 workers on the
80-core VM while it ran other work at full load - read the absolute
figures as that box's and the ratios as the point; the ratios are per
position, so both modes of a position share the box's mood. Every answer
was checked equal across the modes (all were). Modes: `off` (the
reference search), `on` (`AINALRAMI_CERT_MIN=0`: the shortcuts at every
size, their own small-solve thresholds kept) and `force` (those lifted
too).

### Results

Milliseconds, median / p95 / p99 over the positions (625-672 per size).
The ratio is off / on per position: its median, and the ratio of the
summed times ("in all"). "Slower" counts positions where `on` took over
20% and 2 ms longer than `off`.

| players | off | on | force | on: median ratio | in all | slower |
|---|---|---|---|---|---|---|
| 10 | 1.3 / 2.6 / 3.0 | 1.5 / 4.7 / 7.2 | 1.6 / 5.1 / 7.5 | 0.87 | 0.78 | 7% |
| 20 | 4.4 / 8.2 / 9.8 | 3.1 / 12.7 / 20.6 | 3.3 / 15.6 / 23.6 | 1.15 | 1.06 | 15% |
| 30 | 9.1 / 17.4 / 21.5 | 5.5 / 19.9 / 31.0 | 5.3 / 22.2 / 37.0 | 1.39 | 1.30 | 14% |
| 40 | 16.4 / 31.3 / 37.0 | 6.2 / 31.3 / 73.4 | 6.5 / 35.1 / 76.7 | 2.32 | 1.51 | 12% |
| 60 | 36.6 / 68.0 / 86.6 | 12.5 / 73.4 / 144.7 | 13.1 / 85.3 / 140.9 | 2.32 | 1.58 | 10% |
| 80 | 61.7 / 110.2 / 126.4 | 24.1 / 118.0 / 201.3 | 25.2 / 133.8 / 216.5 | 1.85 | 1.47 | 10% |
| 100 | 83.8 / 166.3 / 208.2 | 17.9 / 160.9 / 308.9 | 18.3 / 197.7 / 304.3 | 3.93 | 1.98 | 6% |
| 150 | 144.7 / 374.0 / 489.5 | 24.3 / 346.5 / 505.3 | 24.1 / 384.9 / 563.3 | 3.80 | 2.02 | 4% |

`force` is never better than `on`, so the shortcuts' own thresholds stay.
What the field size does not explain is the slow positions - and the
soft pairs do. Split by whether the tournament has them:

| players | no soft pairs: median ratio / in all | slower | soft pairs: median ratio / in all | slower |
|---|---|---|---|---|
| 10 | 0.94 / 0.82 | 8% | 0.82 / 0.73 | 7% |
| 20 | 2.18 / 1.48 | 10% | 0.84 / 0.72 | 25% |
| 30 | 3.02 / 2.05 | 4% | 0.89 / 0.82 | 31% |
| 40 | 3.42 / 2.42 | 4% | 0.93 / 0.81 | 32% |
| 60 | 4.17 / 2.77 | 3% | 0.93 / 0.85 | 24% |
| 80 | 4.61 / 3.02 | 3% | 0.94 / 0.89 | 21% |
| 100 | 5.80 / 3.76 | 2% | 0.94 / 0.89 | 18% |
| 150 | 6.89 / 5.62 | 1% | 0.98 / 0.93 | 11% |

Soft pairs switch the direct bracket off (`direct_allowed?/2`), and with
it the one shortcut that skips whole searches; what is left is mostly
certifying reads the reference search would have made anyway. Without
them the line sits lower than 100. A finer run without soft pairs
(1,106-1,120 positions per size, seeds from 100,001):

| players | off | on | median ratio | in all | slower |
|---|---|---|---|---|---|
| 12 | 1.8 / 3.9 / 4.6 | 1.5 / 7.5 / 10.5 | 1.04 | 0.89 | 12% |
| 16 | 3.0 / 6.0 / 7.3 | 1.6 / 11.0 / 16.4 | 1.37 | 1.02 | 15% |
| 20 | 4.4 / 8.5 / 10.7 | 1.5 / 11.1 / 19.0 | 2.08 | 1.44 | 9% |
| 24 | 5.6 / 11.1 / 14.1 | 1.8 / 12.5 / 23.4 | 2.40 | 1.62 | 9% |
| 30 | 8.7 / 16.7 / 21.8 | 2.3 / 13.8 / 26.1 | 3.09 | 2.04 | 5% |

And with soft pairs on every tournament, from 100 players up (168
positions per size; then 32 per round at 300 and 600, rounds 1-5 of a
five-round event, two calls per mode):

| players | rounds | off / on in all | median ratio |
|---|---|---|---|
| 100 | 3-9 | 0.88 | 0.94 |
| 150 | 3-9 | 0.92 | 0.98 |
| 200 | 3-9 | 0.94 | 0.98 |
| 300 | 3-9 | 0.97 | 1.00 |
| 300 | 1 / 2-5 | 1.19 / 0.95-0.99 | 1.08 / 0.97-0.99 |
| 600 | 1 / 2-5 | 1.13 / 1.00-1.02 | 1.05 / 0.99-1.03 |

### The rule

* **No soft pairs: from 30 active players** (`@cert_min_field`). From 30
  up the shortcuts win on the median (3.1x at 30), at p95 and in all; 20-24
  win on the median and in all too, but not at p95, which was the bar. The
  p99 is worse with the shortcuts at every size up to 100 - without soft
  pairs by 20% at 30, the same 20% the old line already accepted at 100 -
  and is the certification cost on the positions where nearly every read
  needs it.
* **Soft pairs: from 100, as before** (`@cert_min_field_soft`). The
  shortcuts lose 5-15% at 100-200 players, but win 10-25% on the opening
  round from 300 up, so these rounds keep the old line rather than gain a
  new one. Below 100 they were already off.

`AINALRAMI_CERT_MIN=<n>` puts both lines at n (100 is the old rule);
`AINALRAMI_CERT=off|force` are unchanged.

Against the old rule on the same positions (milliseconds, median / p95 /
p99; the first table's run, a third of tournaments with soft pairs; old
and new times are the measured `off` or `on` each rule takes for that
position's active count):

| players | old | new | median ratio | in all | slower |
|---|---|---|---|---|---|
| 10, 20 | - | same path | 1.0 | 1.0 | 0 |
| 30 | 9.1 / 17.4 / 21.5 | 6.2 / 16.9 / 25.2 | 1.01 | 1.37 | 3% |
| 40 | 16.4 / 31.3 / 37.0 | 6.2 / 27.7 / 41.4 | 2.32 | 1.70 | 3% |
| 60 | 36.6 / 68.0 / 86.6 | 12.4 / 60.2 / 116.9 | 2.32 | 1.74 | 2% |
| 80 | 61.7 / 110.2 / 126.4 | 23.1 / 104.4 / 177.6 | 1.85 | 1.60 | 2% |
| 100 | 25.7 / 164.1 / 308.9 | 17.9 / 160.9 / 308.9 | 1.0 | 1.20 | 0 |
| 150 | - | same path | 1.0 | 1.0 | 0 |

(At 30 the median ratio is 1.0 because withdrawals and byes put many of
those rounds under 30 active players, and a third of the tournaments have
soft pairs; at 100 the reverse, a round with fewer than 100 active and no
soft pairs now takes the shortcuts.) Without soft pairs the 30-80 figures
are the second table's: 3.0-4.6x on the median, 2.0-3.0x in all.

### How it was checked

`tools/cert_threshold.exs` with `CT_MODES=plain,old`: every round from the
second of nine is paired under the new rule and under the old one
(`AINALRAMI_CERT_MIN=100`), and the two answers - pairs in order, colours,
bye, or the refusal with its reason, excluded ranks and override - must
be identical. Fuzz tournaments as above at 6-150 players (a sixth 6-29,
two thirds 30-99, a sixth 100-150), seeds from 1,000,001, 16 workers:
272,000 tournaments, **2,157,665 rounds, 0 differences** (344,417 rounds
at 6-29 players, 1,450,624 at 30-99, 362,624 at 100-150). 971,637 of them
were rounds in which the two rules take different paths (30-99 active
players, no soft pairs); the rest take the same path on both sides and
were compared anyway. The timing runs above
compared every mode's answer as well (11,921 positions, 0 differences).

### Reproducing

    # timings (one scheduler per worker; CT_W = 0..15)
    MIX_ENV=test CT_W=0 CT_N=16 CT_COUNT=48 CT_SIZES=10,20,30,40,60,80,100,150 \
      CT_MODES=off,on,force CT_TIME=1 CT_REPS=3 CT_OUT=OUT \
      elixir --erl "+S 1" -S mix run tools/cert_threshold.exs
    CT_SUMMARY=OUT MIX_ENV=test mix run tools/cert_threshold.exs

    # soft pairs everywhere / nowhere
    CT_SOFT=all ...    CT_SOFT=none ...

    # the equality run
    MIX_ENV=test CT_W=0 CT_N=16 CT_COUNT=17000 CT_SEED_FROM=1000001 \
      CT_SIZES=6-29,30-99,30-99,30-99,30-99,100-150 CT_MODES=plain,old \
      CT_FROM_ROUND=2 CT_OUT=OUT elixir --erl "+S 1" -S mix run tools/cert_threshold.exs

## Score variants (2026-10-07)

`Pairing.pair_variants/3` pairs the next round once for each of several
variants of one position that differ only in results of the round just
played - OpenPairings' "which boards are already certain" preview, 3^k
variants for k open games - and must give, for every variant, exactly what
`pair_next_round/2` gives for it alone. This section is what was measured
on the way, what was kept, and what was dropped and why; the equality is
in [validation.md](validation.md#score-variants-2026-10-07).

### Where one pairing spends its time

`pair_next_round/2` on the fuzz generator's positions (5% requested byes,
3% forfeits), eight positions per row, one scheduler on the 80-core VM,
the median of three calls after a warm one. The shares are from a
temporary build with a timer around each phase (not committed): the input
check; the prelude (5.2.5 arrival numbering, float history, colour state
and per-round facts, score groups, the bye bootstrap); the completability
oracle; and the brackets, with the weighted matcher's share of the whole
from `:tprof`.

| players | round | median | input check | prelude | oracle | brackets | matcher |
|---|---|---|---|---|---|---|---|
| 30 | 3 / 5 / 7 / 9 | 8.5 / 12.5 / 12.5 / 10.8 ms | 0.2-0.3% | 5-8% | 2-3% | 89-93% | 49-58% |
| 80 | 3 / 5 / 7 / 9 | 25 / 68 / 86 / 82 ms | 0.1-0.2% | 2-3% | 1-2% | 95-97% | 68-85% |
| 150 | 3 / 5 / 7 / 9 | 6.5 / 10 / 17 / 20 ms | 0.5-1.1% | 13-29% | 5-30% | 41-81% | 0-11% |
| 300 | 3 / 5 / 7 / 9 | 15 / 24 / 21 / 31 ms | 0.3-1.3% | 7-32% | 3-30% | 40-89% | 0-18% |

Inside the prelude the float history was the largest part (4-16%), then
the colour state and facts (2-6%); the arrival numbering stayed under 1%.
Two things stand out. Below 100 players the pairing is mostly the matcher:
the certified shortcuts, which `pair_next_round/2` then took from 100
players up (`@cert_min_field`; 30 since the threshold pass above), are off, and an 80-player round costs three to
four times a 300-player one. And the slowest positions of all have
nothing to do with field size: every position above ~200 ms in the
harness below carried the arbiter's soft pairs, which turn off the direct
bracket (`direct_allowed?/2`) and put every bracket on the field graph -
the same position without them paired 15-90 times faster (250-1,500 ms
against 12-30 ms at 238-279 players).

### What was kept

* **The work that cannot differ between variants, done once.** The input
  check; the arrival numbering and the inferred initial colour, which read
  only the game structure; and per player the colour state, the per-round
  facts and the float history, taken over for every player a variant
  leaves alone. A player's float history reads the scores of the two last
  opponents, so it is worked out again for anyone who met a changed player
  in those rounds. On its own it measured 1.0x below 100 players, where
  the prelude is a few percent; from 100 players up it is most of what the
  table below shows on the light positions (1.1-1.4x).
* **The certified shortcuts at any size - or not.** Below 100 players,
  forcing them (`AINALRAMI_CERT=force`) made the profile's positions 3-7x
  faster (80 players, round 7: 86 -> 14 ms). On the harness's positions it
  was bimodal: up to 13x faster on some, 1.3-1.7x slower on others, where
  most of the reads need certifying (no certified read aborted; the cost is
  the certification itself). Both give the reference search's answer, so
  the batch chooses on time: the first variant `:plain`, then each mode
  once, then the faster one by a running average, with every 32nd variant
  spent on the other so a change is noticed. A third mode, the reference
  search at every size, was tried and dropped: from 100 players up its
  occasional exploration alone made light 150-300-player previews 1.4-4.6x
  slower than pairing each variant on its own.

### What was dropped

* **Gray-code order.** It exists for state carried from one variant to
  the next, and none is: the shared work is taken from the first variant,
  and the dirty set against it is the 2k players of the open games at
  most. The order of the variants does not matter, and they are paired in
  the order given.
* **Warm starts of the matcher between variants.** In the slow positions
  the matcher's time is the field graph's incremental re-solves - 70-80
  of them per pairing at 230 players, three to five stages each, which the
  eight refinement stages ask for one after another. Building the field
  graph's matcher (`new/3`) was 5-8% of it (24% on one position, where a
  window and a whole-field matcher were built besides), and that is all a
  warm start could replace: the re-solves already start from the previous
  optimum. It would also need the previous variant's state relabelled (the
  vertex ids are positions in the score-ordered field, which shift when a
  score changes) and every changed weight set, and it changes which
  optimum the search returns where several tie, and the duals the next
  call inherits - the reason the blossom pass (below) did not attempt one
  either. Not worth 5-8% at that risk.
* **Bracket and prefix reuse.** A bracket on the field graph has every
  unfinalised player of the round as a vertex (`@peek_budget :unbounded`),
  so every changed player is in every bracket's graph whatever their
  score; its weights read round-wide values (the bye score, the score
  places of the whole field, C9's unplayed games); and it runs against the
  round's oracle and matcher, both built over the whole field. No bracket's
  input is the same in two variants, and showing that its answer is would
  mean re-reading every stage's decision under the new weights - the solve
  itself. The local and direct brackets, whose input is the bracket alone,
  are the cheap ones (none of the slow positions' time).

### Results

The timing run of the harness below: positions of nominally 30, 80, 150
and 300 players (a few off once withdrawals and late entrants are drawn),
the general axis's knobs, one scheduler per worker on the shared VM. Per
variant is the preview's time divided by its variants; a preview is all
3^k of them. Median / p95 over the positions, milliseconds; the speedup is
the median of each position's own ratio, and the ratio of the summed times
("in all").

| players | k | positions | per variant, batch | per variant, alone | preview, batch | preview, alone | speedup median | in all |
|---|---|---|---|---|---|---|---|---|
| 30 | 4 | 18 | 5.5 / 13.9 | 10.8 / 14.4 | 447 / 1,124 | 877 / 1,164 | 1.95 | 1.61 |
| 30 | 5 | 14 | 7.5 / 11.7 | 10.6 / 12.2 | 1,830 / 2,830 | 2,582 / 2,958 | 1.61 | 1.45 |
| 30 | 6 | 16 | 9.1 / 14.6 | 11.9 / 14.8 | 6,647 / 10,614 | 8,651 / 10,812 | 1.91 | 1.50 |
| 80 | 4 | 14 | 16.7 / 89.4 | 84.2 / 118.3 | 1,356 / 7,242 | 6,822 / 9,583 | 3.50 | 2.41 |
| 80 | 5 | 14 | 13.6 / 54.0 | 58.6 / 83.6 | 3,312 / 13,110 | 14,245 / 20,314 | 4.59 | 2.35 |
| 80 | 6 | 15 | 28.0 / 86.3 | 57.8 / 106.9 | 20,439 / 62,911 | 42,141 / 77,925 | 1.90 | 1.59 |
| 150 | 4 | 17 | 24.5 / 365 | 25.2 / 370 | 1,983 / 29,589 | 2,044 / 29,932 | 1.10 | 1.01 |
| 150 | 5 | 25 | 22.6 / 345 | 27.2 / 342 | 5,486 / 83,838 | 6,616 / 83,016 | 1.16 | 1.04 |
| 150 | 6 | 16 | 73.1 / 247 | 75.5 / 221 | 53,309 / 180,287 | 55,019 / 161,421 | 1.03 | 0.96 |
| 300 | 4 | 14 | 17.2 / 1,404 | 22.4 / 1,322 | 1,393 / 113,692 | 1,810 / 107,116 | 1.29 | 0.98 |
| 300 | 5 | 13 | 42.0 / 859 | 49.1 / 915 | 10,216 / 208,755 | 11,935 / 222,315 | 1.17 | 1.07 |
| 300 | 6 | 17 | 17.2 / 446 | 22.6 / 440 | 12,557 / 325,267 | 16,493 / 320,895 | 1.24 | 1.04 |

k = 7 and 8 (timed, 60 variants of each preview compared): 30 players
2.5x / 2.9x median, 80 players 5.7x / 3.5x, 150 players 1.2x / 1.4x, 300
players 1.3x / 1.4x.

So: below 100 players a preview is 1.45-2.4x faster in all, and several
times faster on the positions where the shortcuts suit it. From 100
players up the typical preview is 1.0-1.3x faster and the slow ones -
soft pairs, the field graph on every bracket - are not faster at all;
their p95 is within the run-to-run noise of pairing alone, and they are
what the "in all" column is made of. Making those faster is a change to
the pairing itself (the direct bracket under soft pairs), not to the
batch, and is not attempted here.

### Reproducing

    # the differential harness and its timings (one scheduler per worker)
    MIX_ENV=test VAR_W=0 VAR_N=4 VAR_SIZES=30,80,150,300 VAR_K=4,4,5,5,6,6,7,8 VAR_OUT=OUT \
      elixir --erl "+S 1" -S mix run tools/variants_check.exs
    VAR_BANDS=nominal VAR_SUMMARY=OUT MIX_ENV=test mix run tools/variants_check.exs

    # the mode experiments: pin one
    AINALRAMI_VARIANT_MODE=plain|force|off ...

## The timing study (2026-09-30)

The earlier passes below were each measured on a handful of benchmark
files, one position per row. This one measures the three engines on 3,000
random positions, so a row is a distribution rather than one position,
and states its method in full. It measured engine commit **030bd28** (the
slow spots pass, before the slow tail below); the slow tail's before and
after on the study's 30 slowest positions follows the tables.

### Method

* **Positions.** The fuzz generator (`Ainalrami.Test.FuzzTournament`) at
  100, 101, 200, 201, 400, 401, 600, 601, 1,000 and 1,001 players, rounds
  2, 5 and 9 of a nine-round event, 100 seeds each (seed `8,000,000 +
  10,000 x s + players`, s = 1..100): 3,000 positions. The earlier rounds
  are paired by this engine with the generator's simulated results,
  withdrawals and requested byes, and the position is written as a TRF16
  file for the other two.
* **Ainalrami** (030bd28): `Pairing.pair_next_round/2` in-process on a
  BEAM started with one scheduler (`+S 1`), timed on the second of two
  calls on the same position (the first loads code). No start-up and no
  file reading are in the figure.
* **bbpPairings** (C++, built from source on the VM),
  `--dutch in.trf -p out.txt`, and **Gacrux** (TieBreakServer's
  `pairingchecker.py -i in.trf -o out.txt -p -dT -m dutch`, Python): wall
  time of the process minus a start-up baseline, the median of five runs of
  each on a 4-player round-1 file. Both are single-threaded. Their figure
  includes reading the file and writing the pairing, which Ainalrami's does
  not; the baseline subtraction carries some noise, and 26 Gacrux figures
  at 100-101 players came out below zero (by up to 55 ms; shown as 0).
  Differences under about 50 ms for the two external engines are within
  that noise.
* **Machine.** An 80-vCPU cloud VM, 32 positions at a time (each worker
  runs one position through all three engines in turn), 2026-09-30
  13:38-14:26 UTC. The same positions run 1.5-2x faster on one core of an
  i7-10700 (see the slow tail's results), so read the absolute figures as
  this VM's and the comparison as the point.
* **Answers.** All three engines gave the identical pairing on all 3,000
  positions; no Gacrux run timed out (900 s cap) or reported an error.

The script is `tools/timing_study.exs` (usage in its header); every
position's line is in
[`timing-study-2026-09-30.csv`](timing-study-2026-09-30.csv) - `n,round,
seed`, the three times in seconds, whether Gacrux's and bbpPairings'
pairing equals this engine's, and Gacrux's exit status.

### Results

Milliseconds; median / p90 / worst of the 100 positions in each row (p90
is the 90th of 100 by nearest rank).

| players | round | Ainalrami (030bd28) | Gacrux | bbpPairings |
|---|---|---|---|---|
| 100 | 2 | 2.7 / 4.7 / 12 | 291 / 444 / 637 | 34 / 58 / 79 |
| 100 | 5 | 7.9 / 19 / 111 | 82 / 130 / 543 | 41 / 70 / 76 |
| 100 | 9 | 12 / 42 / 128 | 149 / 241 / 322 | 39 / 66 / 75 |
| 101 | 2 | 3.4 / 5.5 / 6.1 | 24 / 64 / 131 | 44 / 78 / 83 |
| 101 | 5 | 6.6 / 15 / 38 | 89 / 138 / 174 | 54 / 89 / 110 |
| 101 | 9 | 16 / 38 / 125 | 162 / 225 / 310 | 55 / 91 / 106 |
| 200 | 2 | 6.6 / 8.7 / 14 | 236 / 2,723 / 3,538 | 230 / 271 / 313 |
| 200 | 5 | 13 / 24 / 104 | 286 / 352 / 443 | 302 / 354 / 423 |
| 200 | 9 | 14 / 29 / 262 | 380 / 515 / 939 | 294 / 352 / 385 |
| 201 | 2 | 7.8 / 13 / 41 | 194 / 249 / 314 | 282 / 338 / 379 |
| 201 | 5 | 12 / 21 / 112 | 267 / 363 / 1,233 | 395 / 456 / 485 |
| 201 | 9 | 16 / 64 / 414 | 407 / 530 / 1,231 | 416 / 468 / 531 |
| 400 | 2 | 17 / 31 / 41 | 6,718 / 17,718 / 22,356 | 2,201 / 2,409 / 2,549 |
| 400 | 5 | 15 / 23 / 41 | 1,099 / 1,215 / 1,683 | 2,477 / 2,624 / 2,754 |
| 400 | 9 | 20 / 32 / 751 | 1,461 / 1,683 / 2,545 | 2,346 / 2,506 / 2,758 |
| 401 | 2 | 21 / 37 / 42 | 800 / 922 / 979 | 2,940 / 3,307 / 3,680 |
| 401 | 5 | 15 / 24 / 53 | 1,092 / 1,256 / 1,542 | 3,316 / 3,606 / 4,062 |
| 401 | 9 | 24 / 70 / 1,251 | 1,489 / 1,690 / 2,690 | 3,466 / 3,722 / 4,062 |
| 600 | 2 | 26 / 50 / 71 | 1,752 / 60,265 / 68,018 | 8,718 / 9,836 / 10,995 |
| 600 | 5 | 23 / 31 / 121 | 2,489 / 2,646 / 10,782 | 8,750 / 9,300 / 9,571 |
| 600 | 9 | 32 / 52 / 3,523 | 3,257 / 3,688 / 5,238 | 8,467 / 8,972 / 9,205 |
| 601 | 2 | 28 / 53 / 77 | 1,752 / 2,082 / 2,219 | 10,472 / 13,307 / 14,486 |
| 601 | 5 | 26 / 34 / 63 | 2,329 / 2,691 / 8,047 | 11,846 / 13,003 / 13,668 |
| 601 | 9 | 35 / 65 / 990 | 3,347 / 3,603 / 6,253 | 12,594 / 13,175 / 14,047 |
| 1,000 | 2 | 75 / 131 / 308 | 109,090 / 266,035 / 327,796 | 49,561 / 54,927 / 58,530 |
| 1,000 | 5 | 43 / 62 / 109 | 6,847 / 7,568 / 8,376 | 42,327 / 43,601 / 44,686 |
| 1,000 | 9 | 49 / 84 / 8,261 | 9,284 / 10,282 / 16,724 | 46,781 / 49,778 / 51,372 |
| 1,001 | 2 | 36 / 131 / 201 | 4,730 / 5,650 / 5,887 | 58,253 / 71,137 / 73,117 |
| 1,001 | 5 | 44 / 74 / 272 | 6,716 / 7,365 / 29,672 | 57,111 / 60,460 / 66,762 |
| 1,001 | 9 | 55 / 299 / 3,770 | 9,521 / 10,393 / 19,170 | 70,436 / 72,926 / 78,214 |

Over all 3,000 positions:

| | Ainalrami (030bd28) | Gacrux | bbpPairings |
|---|---|---|---|
| median | 20 ms | 1.25 s | 2.55 s |
| p90 | 56 ms | 8.9 s | 54 s |
| p99 | 0.29 s | 242 s | 72 s |
| worst | 8.26 s | 328 s | 78 s |
| above 0.5 s | 11 | 1,879 | 1,804 |
| all 3,000, in all | 122 s | 22,396 s | 40,620 s |

Per position, Gacrux's time over Ainalrami's has a median of 63 and a
10th percentile of 9.7; bbpPairings' a median of 141 and a 10th percentile
of 7.1. Ainalrami was the slower on 36 positions against Gacrux - 35 at 100-101
players, 26 of them round-2 positions where Gacrux's figure is below
zero, inside the start-up noise, and one 600-player round 9 - and on 17
against bbpPairings, all at 100-101 players and 16 of them round 9 (42-128
ms against bbpPairings' 35-92 ms).

What the table says, and what it does not:

* **One position per row is noisy.** A row's worst is up to 167x its
  median for Ainalrami (10 of 30 rows at 10x or more, nine of them round 9)
  and up to 39x for Gacrux (600 and 200 players round 2), against at most
  2.3x for bbpPairings, so a table of single positions -
  which is what every earlier pass here and in `validation.md` reported -
  can land on a slow shape for one engine and not the others. That is why
  the old 600-player round-2 row looked out of line: on 0a844f7 that one
  position took this engine 2.93 s where 400 and 1,000 players took 0.02
  and 0.05 s (the slow spots, below), and on the VM's own benchmark
  position Gacrux took 48.3 s at 600 players round 2 where its median over
  100 positions is 1.75 s. The "3x to 46x" figures of the direct bracket
  pass came from one file per row and are superseded by the medians here.
* **Gacrux has large round-2 outliers on even fields.** At 400 and 1,000
  players round 2 its median is already slow (6.7 s and 109 s, against
  0.8 s and 4.7 s for 401 and 1,001), and at 200 and 600 players its p90
  is 12x and 34x its median. The odd fields do not show it. Round 2 of an
  even field puts half the field on zero in one large bracket; whatever
  sends Gacrux there is on its side, and its answers were still the same.
* **Ainalrami's worst case is the last round.** 11 positions above 0.5 s,
  every one round 9; the worst 8.26 s at 1,000 players, where that row's
  median is 49 ms. Those are the slow tail, addressed below on the same
  positions. The study has not been re-run on the release that carries
  that fix; the before and after below are from one core of an i7-10700.
* **bbpPairings** has the tightest spread of the three (worst within 1.4x
  of the median on every row from 200 players up) and grows fastest with the field: ~40 ms at
  100 players, ~2.3-3.5 s at 400, 42-70 s at 1,000.

### The slow tail, before and after

The 30 slowest positions of the study, re-run on one core of an i7-10700
(`+S 1:1`, median of 5 after one warm call) on 030bd28 and on the slow tail
pass (v0.35.0), same pairing on every one (the full table and the causes
are in [the slow tail](#the-slow-tail-2026-09-30)):

| | 030bd28 | v0.35.0 |
|---|---|---|
| the 30, in all | 22.5 s | 4.2 s |
| slowest | 5.24 s | 1.04 s |
| median of the 30 | 0.261 s | 0.049 s |
| 100 other positions at random, median / p90 / slowest | 13.3 / 33.1 / 80 ms | 12.4 / 33.3 / 65 ms |

The 8.26 s position of the study (1,000 players, round 9, seed 8,971,000)
is 5.24 s on the i7 before and 0.031 s after. The slowest that remains is
a 600-player round 9 at 1.04 s, a top bracket that must float more players
than its parity; eight of the 30 are unchanged ([what is
left](#what-is-left)). Positions outside the tail are unchanged.

### Validation alongside the study

* **Against Gacrux on the same VM**, 2026-09-30, engine 030bd28, the
  `gacrux_only` harness over nine-round tournaments in five size bands -
  3,500 tournaments of 500-1,000 players, 15,000 of 300-500, 35,000 of
  150-250, 70,000 of 40-120 and 250,000 of 4-40 (373,500 tournaments):
  **3,219,728 rounds compared, 3,219,728 identical; 119,064,367 boards
  with a colour on both sides, 119,064,367 the same colour; 0
  disagreements, 0 rounds where Gacrux breaks Article 5.2.5.** Every
  difference the harness saw was on Gacrux's side: 25,761 rounds at 4-40
  players where Gacrux returned its Error 510 (an exception escaping the
  checker; counted, dumped and kept out of every rate, as since 0.11.0)
  and 5 Gacrux crashes, which the harness reports as test failures.
* **Against v0.33.0** (the release before), the differential corpus:
  447,152 rounds identical in the default configuration and 44,325 in
  check mode with every new answer held to the path it replaces - see the
  slow tail's [How it was checked](#how-it-was-checked).

## The whole-field build (2026-10-27)

The slow tail after the timing study, re-timed on this branch's base
(c945ad5) on a 16-thread Windows desktop, not the 80-vCPU VM the tables
above came from - its numbers run 10-20% above the VM's and are only
compared with each other. 3,000 positions as the timing study draws them,
then the 40 slowest re-timed alone, median of seven.

### Where the time was

The 8.26 s position the study was written for is long gone (0.031 s since
"The slow tail"). What leads now:

| position | ms | path |
|---|---:|---|
| 600 / 9 / 8150600 | 912 | top bracket of 4, no perfect matching: the whole field graph |
| 400 / 9 / 8780400 | 464 | certified read tied, round re-paired; its 3-player top bracket on the whole field graph |
| 600 / 9 / 8620600 | 329 | pruned walk past budget, stages on an 83-93-player local graph |
| 600 / 9 / 8640600 | 288 | the same |
| 601 / 9 / 8930601 | 279 | the same |
| 201 / 9 / 8710201 | 210 | bracket of 3 with 2 MDPs: the whole field graph |

A debug-trace census of the 3,000 found 32 brackets paired on the whole
field graph - top brackets of two to five players that cannot settle on
their own - costing 5.0 of the 7.7 s spent in all 347 field-graph
brackets. On 600 / 9 / 8150600 that first bracket spent about 220 ms
computing the weight of every pair, 100 ms turning them into an edge
list, 270 ms in `WeightedMatching.new/3` folding that list back into rows,
300 ms in the cold solve and 30 ms in the stages. Three quarters of it was
bookkeeping around a solve that has to happen.

No certificate settles these. The direct bracket needs a perfect matching
inside the bracket (8150600 has none) or a bracket within its MDP rules
(8710201 has more MDPs than residents); the window needs an even window
(8150600's is 15); and on 8780400 the certified pass did run and met a
tie it could not certify, which is the one exit that must go to the
reference.

### What changed

Only how the first whole-field graph of a round is built; the graph is
the same.

* **Per player, not per pair.** A pair outside the bracket weighs
  `reserve * (base*S0 + e(x)*S0 + e(y)*S0 + u(x)*S9 + u(y)*S9 + [reach 1]
  (S8p + place(x)*S8s) + [soft] S_soft)` (`outside_edge_weight/6`
  multiplied out). Every term but the soft rung's belongs to one player,
  so `pair_weigher/8` computes them once per player along with the player's
  played opponents, forbidden set and absolute colour, and a pair costs
  three lookups and two additions. Pairs inside the bracket, and a reach-1
  pair whose score has no C8 place, still go to the exact functions.
* **Rows, not a list.** `first_field_build/8` builds the matcher's
  `%{u => %{v => 2w}}` rows directly, and `new/3` takes them as
  `:adjacency` with `symmetric: true` - the promise that each edge sits in
  both rows at one weight, which lets the greedy start run the way it does
  for a graph built from a list. The state is the one the list would have
  built.

Skipped where the bracket will run on its window (that builds its own
matchers) and with the transposition tie-break on, whose weigher this does
not reproduce.

### Results

Same desktop, same positions, base vs branch run back to back, two at a
time, median of seven:

| position | before ms | after ms | |
|---|---:|---:|---:|
| 600 / 9 / 8150600 | 912 | 734 | 1.24x |
| 400 / 9 / 8780400 | 464 | 372 | 1.25x |
| 201 / 9 / 8710201 | 210 | 172 | 1.22x |
| 200 / 9 / 8390200 | 151 | 126 | 1.19x |
| 200 / 9 / 8090200 | 140 | 108 | 1.30x |
| 1001 / 9 / 8701001 | 131 | 95 | 1.38x |
| 200 / 9 / 8320200 | 91 | 68 | 1.33x |

The first three are traced to the whole-field path; the other four moved
by as much and were not traced. The remaining 33 of the 40 moved within
noise (0.86-1.18x either way). On 600 / 9 / 8150600, `new/3` went from 244 to
67 ms; the cold solve is untouched.

Modest, and said so. The rest of the whole-field cost is the solve, which
is the reference path's own and does not shrink by building faster.

### How it was checked

* While developing, both builds ran side by side on every first field
  bracket (`base` maps and built matcher states compared with `!=` and a
  raise) across 900 study positions (seeds 1-30, all ten sizes, rounds 2,
  5 and 9): equal throughout. The check is not in the shipped code.
* Whole fuzz tournaments paired by base and branch, every round hashed:
  4,350 tournaments of 6-150 players (38,943 rounds, seeds 1-30 per size)
  and 90 of 400-1,001 players (810 rounds), 0 differences. A tournament
  ending in `NoValidPairingError` counts that round, and ends the same on
  both.
* The 40 timed positions: identical results and identical prior rounds.
* `mix test`, full suite.

### What is left

As "The slow tail" lists it: the pruned walks on 83-93-player brackets
(0.26-0.33 s), the tied read on 400 / 9 / 8780400, and the cold solve on
an unsettleable top bracket. Considered and not built: a sparse round
matcher for that bracket (window edges plus near pairs, the far pairs
held strictly slack by the duals), which would make the solve cheaper
but has to keep every certified read, forced-loss check and dual shift
exact on a graph missing edges. Not worth that risk for a handful of
positions under a second.

## The blossom fallback (2026-10-01)

`Ainalrami.WeightedMatching` - the primal-dual weighted matcher a bracket
falls back to when no shortcut answers it, and the one the explanation
and every forced search of the alternatives run on - is **1.24-1.32x
faster per call** on the differential corpus and the slow tail, with every
call held to the previous release's matcher: the same matching, and the
same duals, blossoms and matches left for the next call. Where the matcher
is most of the work the whole run follows - the corpus slices below spend
11-14% less in all, the 30 slowest positions of the timing study 11% - and
where it is not, the typical position, nothing moves: the matcher was 6%
of the timing study's positions, and they are unchanged.

### Where the time was

`AINALRAMI_WM_PROFILE=1` (new: `Ainalrami.WeightedMatching.Profile`,
`tools/matching_profile.exs`) times every `new/3` and `solve/1` and
attributes it to its caller and the context it ran in. One scheduler, the
engine before this pass (5bd5195, v0.35.0's matcher):

| where | measured | in the matcher | its largest share |
|---|---|---|---|
| small set, 30 tournaments per axis | 70.5 s | 34.9 s (49.5%) | the alternatives' forced searches on the field graph, 124,343 solves of 12-40 vertices: 23.0 s |
| flags set, 30 per axis | 48.2 s | 27.8 s (57.6%) | the same, 62,950 solves: 19.5 s |
| large set, 6 per axis | 189 s | 95.4 s (50.4%) | the alternatives' field graphs of 300-780 vertices 27.4 s; local brackets of 50-200, 17.3 s; the pairing's field graph, 17.2 s |
| early set, 4 per axis | 32.9 s | 19.6 s (59.4%) | the explanation's re-pairing on the field graph, 9.9 s |
| the study's 30 slowest positions | 4.84 s | 2.18 s (45.0%) | the field graph of 400-1,001 vertices: solves 0.80 s, building it 0.72 s; local brackets of ~89 vertices, 0.54 s |
| the study's first 10 seeds (300 positions) | 6.04 s | 0.35 s (5.8%) | - |

Every solve the pairing makes runs on weights of 120-680 bits - the packed
criteria, whose spread is nearly their full width - in a few stages and
tens to a hundred grow steps. Inside a solve (the captured calls below,
timed phase by phase): about 40% was walking a vertex's adjacency row as
it becomes outer (`settle_outer_vertex/2`), 30-40% the starts of stages
(labels, carrying the caches, the root table), 12-20% blossom formation and
the cross table, a few percent each the dual steps and the minima. On the
BEAM side the walks were the cost: an `Enum.reduce/3` over a map is
`:maps.fold/3` plus two closure calls per element, and those folds alone
were a fifth to a quarter of the matcher's time.

### What changed

Nothing about the algorithm: the same steps on the same values, in the same
order wherever an order decides anything. Each change is argued in the
comments of `Ainalrami.WeightedMatching`.

* **Rows walked as lists.** The row walks (a vertex becoming outer,
  re-deriving a vertex's best edge, the root table, the cross-table merge,
  the resumed greedy start) take `:maps.to_list/1` of the row and recurse
  over it. Where the order matters - of two equal-resistance edges to one
  blossom the first offered is kept - it is the order `Enum.reduce/3` used:
  both are `erts_internal:map_next/3` from the same start (also checked on
  20,000 maps of 1-3,000 keys, built and edited, before relying on it, and
  by the replay and the lockstep below). Every other walk keeps a least or
  greatest element under a total order and may take any order.
* **Fewer lookups per neighbour.** A vertex that is its own top-level
  blossom is a key of the label map, so its blossom and its label are one
  match on that map, and `in_blossom` is read only for a vertex inside a
  non-trivial blossom (held to `in_blossom` on every walk of the replayed
  calls before the check was taken out); sets are map keys instead of
  `MapSet`s; the root table keeps each root's constant `dual + shift`
  beside it.
* **Work in proportion to what changed.** A stage start re-derives only
  the labels that can change (a `:free` blossom is matched and stays so); a
  dual step walks the forest (`state.forest`) instead of every top-level
  blossom; the sorted list of top-level blossoms (`state.tops`), patched at
  every structural event for a reader that no longer needed it, is gone;
  an outer-outer event walks the two tree paths once instead of twice.
* **The root table built the cheaper way.** At a solve's first stage the
  table was always built by every non-root deriving its own entry - the
  test meant to choose was true for any number of roots - a lookup per
  root for every vertex of the graph. It now compares that with the roots
  offering along their rows. Both build the same table.
* **Quadratic list indexing.** Blossom expansion, dissolution, resolution
  and connector recording read the cycle by index with `Enum.at/2`; they
  use a tuple, or walk the lists in step.
* **The greedy start** of `new/3` takes half of a row's heaviest weight
  (`:lists.max/1`) instead of halving every weight, and with the default
  duals, on the symmetric adjacency `new/3` builds, finds the tight edges
  by comparison - `w(u, v) = 2 y_v` and `y_u = y_v` - instead of a bignum
  sum per edge.

### Results

**The matcher, call by call.** 15,842 calls captured from the four corpus
sets, the timing study and its slow tail (`AINALRAMI_WM_CAPTURE`),
replayed through v0.35.0's matcher and this one
(`tools/matching_replay.exs`, one scheduler, the least of the runs): 12.9
s -> 9.8 s (**1.32x**), every call the same matching and the same state.
By site: the pairing's field graph of 257-1,024 vertices 1.41-1.46x,
building it (`new/3`) 1.3-1.5x, the explanation's field graph 1.35x, the
alternatives' small field graphs 1.24x, local brackets 1.19-1.22x.

**Blossom time by call site** (the profile above, both builds side by
side, one scheduler each):

| where | in the matcher, before | after | | everything, before | after |
|---|---|---|---|---|---|
| small set | 34.9 s | 26.4 s | 1.32x | 70.5 s | 62.7 s |
| flags set | 27.8 s | 21.2 s | 1.31x | 48.2 s | 41.9 s |
| large set | 95.4 s | 77.1 s | 1.24x | 189 s | 168 s |
| early set | 19.6 s | 15.7 s | 1.25x | 32.9 s | 28.4 s |
| the 30 slowest positions | 2.18 s | 1.71 s | 1.28x | 4.84 s | 4.44 s |

The largest sites: the alternatives' field graphs of 12-40 vertices 23.0
-> 17.7 s (small set); their field graphs of ~540 vertices 19.2 -> 16.3 s
and the local brackets of ~85 vertices 8.3 -> 7.1 s (large set); the slow
tail's 1,000-player field graph 0.55 -> 0.47 s, and building it 0.51 ->
0.28 s.

**Whole positions** (`Pairing.pair_next_round/2` at `+S 1:1`, the two
builds side by side on the same saved positions, every pairing the same):

| | before | after |
|---|---|---|
| the study's 3,000 positions, median / p90 / worst (median of 3 runs) | 12.4 / 35.5 / 1,244 ms | 12.5 / 35.1 / 1,054 ms |
| the 3,000 in all | 58.2 s | 57.2 s |
| the 30 slowest, in all (median of 5 runs) | 4.58 s | 4.09 s |
| the 30 slowest: median / worst | 52 / 1,153 ms | 53 / 973 ms |

A typical position spends ~6% of its time in the matcher, so it does not
move (per-position ratio: median 1.00, 10th-90th percentile 0.91-1.11,
the runs' spread). The positions that move are the ones the matcher was
most of: 600 players round 9 1.15 -> 0.97 s, the 400-player round 9 sent
back to the reference path 0.57 -> 0.46 s, the 1,001-player odd bracket
whose rest cannot complete 0.22 -> 0.16 s.

### How it was checked

Every check below ran on the committed matcher.

* **Lockstep with v0.35.0** (`tools/matching_lockstep.exs`,
  `LOCKSTEP_REF=7932e41`), extended for this pass: graphs of up to 400
  vertices (`LOCKSTEP_LARGE=1`, dense and sparse); a `:wide` shape at the
  engine's widths (six criteria in 24-110-bit bands, 150-700-bit weights,
  few distinct values, so optima tie); one-shot `solve/2` on a quarter of
  the sessions; and what the engine reads off a solved state -
  `dual_context/1` and `possible_partners/3`, `certificate_hint/1`,
  `vertex_duals/1` - and `scale/2`. After every call: the same return value
  and the same duals, matches, blossom structure, connectors and weights.
  20,000 sessions of 2-128 vertices (441,031 calls) and 5,000 of 2-400
  (1,636 of them above 128 vertices; 90,258 calls): **every call
  identical**. With one tie-break flipped (`<=` to `<` in
  `cross_gather/6`) it failed 8 of the first 50 sessions.
* **The replay** above: 15,842 real calls, **0 differing**.
* **Differential against v0.33.0** (`tools/perf_diff.exs`, the baseline
  logs of the passes below), default configuration: small 370,777 rounds,
  flags 68,898, large 5,497, early 1,980 - **447,152 rounds, 0 differing,
  0 missing** (89,665 + 16,964 + 477 + 60 of them with the alternatives
  fingerprinted). No solve reached the new raise in `grow_with_delta/6`,
  here or in check mode.
* **Check mode** (`AINALRAMI_DIRECT=check`, certified mode forced, the
  first 400 tournaments of every axis of the four sets): 44,325 rounds,
  identical to v0.33.0 end to end, with every shortcut's answer held to
  the path it replaces and **0 differences** - 115,491 field-graph
  brackets, 194,432 walk and small-bracket answers, 411,578 oracle
  answers, 63,265 pools and 31,055 bye bootstraps (the oracle and pool
  counts the slow tail's run reported, to the unit). Its 247,638 dual
  shifts (stages
  4, 7 and 8) are the matcher's `shift_and_set/3` on every bracket.
* `mix test`: 859 tests, 0 failures.

### Tried and left out

* **A lazy root table** - re-derive an entry only when a stage start reads
  it, with an epoch per root so that a vertex leaving the root set and
  coming back cannot pass an old key for its current one. Exact, and no
  faster: nearly every entry the eager table re-derives is read at the next
  stage start.
* **Building the adjacency by a stable sort** instead of two map updates
  per edge: slower on the dense field graphs (`:lists.keysort/2` over
  350,000 half-edges at 600 players), so `adjacency_of/1` is as it was.
* **Smaller weights.** The weights are 120-680 bits with nearly that
  spread. The one transformation that keeps every step of the search the
  same is dividing by a common factor, which the matchers that outlive a
  bracket give up (`gcd: 1`) because later weights need not share it;
  compressing the bands or offsetting the weights changes the deltas, and
  with them which of several equal edges becomes tight first.
* **Warm-starting duals** from another solve, **sparsifying** edges no
  optimum uses, **a better initial matching**: each changes the path the
  search takes - which optimum it returns when several tie, and the duals
  and blossoms the next call inherits - so none was attempted.
* **A priority queue for the dual step's minima**: the minima were 3-5% of
  a solve; a heap's upkeep on every offer would cost more.
* **A larger heap** (`+hms 4000000`): within 7% on five of the slowest
  positions; not the engine's to set for its caller's process.
* **The small-bracket thresholds** (`@direct_small_max` 12,
  `@direct_small_fallback_max` 16). The matcher's remaining small local
  solves come from brackets the direct path excludes by design (soft
  pairs, `AINALRAMI_NOFAST`), which moving them would not reach. Left as
  they are, as is the field size above which the certified shortcuts run.

### Reproducing

    # where the matcher's time goes, by call site (one scheduler)
    DIFF_LIMIT=30 MIX_ENV=test elixir --erl "+S 1" -S mix run tools/matching_profile.exs corpus small OUT
    MIX_ENV=test elixir --erl "+S 1" -S mix run tools/matching_profile.exs positions 1:10

    # capture the calls, and replay them through v0.35.0's matcher
    AINALRAMI_WM_CAPTURE=calls.bin MIX_ENV=test mix run tools/matching_profile.exs positions 1:3
    REPLAY_FILES=calls.bin REPLAY_REF=7932e41 MIX_ENV=test mix run tools/matching_replay.exs

    # lockstep with v0.35.0, small and large graphs
    LOCKSTEP_SESSIONS=20000 LOCKSTEP_REF=7932e41 MIX_ENV=test mix run tools/matching_lockstep.exs
    LOCKSTEP_LARGE=1 LOCKSTEP_SESSIONS=5000 LOCKSTEP_REF=7932e41 MIX_ENV=test mix run tools/matching_lockstep.exs

## The slow tail (2026-09-30)

A timing study of 3,000 random positions (the fuzz generator at 100, 101,
200, 201, 400, 401, 600, 601, 1,000 and 1,001 players, rounds 2, 5 and 9,
100 seeds each, one scheduler) put the pairing's median at 3-55 ms per size
and round, and found 11 positions above 0.5 s - every one of them round 9,
the last round of a nine-round event. The slowest took 8.26 s at 1,000
players, where the median at that size and round is 0.049 s. On this
machine the 30 slowest took **22.5 s** in all (the worst 5.2 s) and now take
**4.2 s** (the worst 1.04 s), with the same pairing; 100 other positions
drawn at random are unchanged, and every answer on the differential corpus
is unchanged.

### Where the time was

The 30 slowest positions, rebuilt by the study's generator
(`position.(n, round, seed)`), in-VM `Pairing.pair_next_round/2` at
`+S 1:1`, with the per-bracket trace and the certified-mode counters:

| cause | positions | 030bd28 |
|---|---|---|
| the odd field's bye bootstrap went to the whole-field search | 11 (1,001 x4, 601, 401 x5, 201) | 1.6-1.8 s at 1,001 players, 0.48 s at 601, 0.18-0.19 s at 401 |
| the completability oracle's sparse graph missed a matching, and a 127- or 63-player bracket went to the field graph | 2 (1,000, 600) | 5.2 s, 2.4 s |
| blossoms in the cardinality matcher's search: each contraction sorted the whole tree | 7 at 1,001 players | 0.2-0.3 s |
| a top bracket whose MDP can play nobody in it went to the field graph | 1 (600) | 1.0 s |
| a 13-player top bracket that needs an exchange went to the field graph | 1 (401) | 0.75 s |
| left as it was (see "What is left") | 8 | 0.2-1.0 s |

Round 9 is the last round, and in the last round two players due the same
colour absolutely cannot meet unless both are topscorers; a stretch of the
field can then hold more players due one colour than its neighbourhood can
give it. That is what the first two causes have to do with round 9.

* **The bye bootstrap.** On an odd field the bye's score and the first
  bracket's C9 gate come from one whole-field matching (the bootstrap). Its
  two certificates, the greedy pairing and the matched one, each require
  the top group paired inside itself as far as its parity allows, and at
  round 9 the top group was, 11 times of 11, two leaders who had met. What
  remained was the search, a complete-graph matching of the whole field.
* **The sparse oracle.** The completability oracle keeps each player's
  first 12 compatible players below them. At 1,000 players round 9 the
  127-player 5.0 bracket was answered directly, and the rest of the field
  (730 players) was then asked for a perfect matching: the whole compatible
  graph has one, the sparse graph did not find it, and the bracket went to
  the field graph (the 600-player position: a 63-player bracket, the same).
* **The blossoms.** `Ainalrami.CardinalityMatching`'s search found the
  vertices a contraction relabels by walking its whole tree in index order,
  sorted at every contraction. A search whose tree covers most of a
  1,000-player field spent most of a 0.2 s round in those sorts.
* **The MDP who can play nobody.** A leader who had met both players of the
  group below: the bracket of three went to the small bracket, whose
  floater has to be a resident of the pool, and the MDP is the one that
  floats in every matching.
* **The exchange.** A bracket of 13 with one MDP whose walk found no
  exchange-free answer (`:unproven`), past the small bracket's size, at the
  top of a 401-player field.

### What changed

Five changes, each argued in the section comments of `Ainalrami.Pairing`
and `Ainalrami.CardinalityMatching`, and each held to the path it replaces
in check mode:

* **The bootstrap's leftover below the top group**
  (`leftover_bootstrap/5`). The flag the bootstrap returns,
  `first_single_bye?/4`, is false whatever the matching once the bye score
  is below the top score, so of the three things the bootstrap's optimum is
  ranked by only two are read: all but one paired over compatible edges,
  and the leftover's `(ineligible, place)` as small as the field allows.
  With `L` the last player with the least of that term, a perfect matching
  of the field less `L` makes the answer `{score(L), false}`, however few
  pairs the top group can keep inside. The greedy pairing is that matching
  where it covers everyone; otherwise the sparse subgraph's maximum
  matching, grown by augmenting searches over every compatible pair
  (`dense_perfect?/2`), which is exact - so what it misses the search would
  not find either, and it goes to the search as before.
* **The oracle's dense rescue** (`oracle_dense/2`). Where the sparse
  graph's search fails, the same matching is grown by augmenting searches
  over the whole compatible graph - the test the sparse graph is built
  with, plus the bye's stand-in joined to every candidate - its rows built
  only as a search reaches them and kept for the round. A "yes" is a
  matching of the graph the field path pairs on, which is condition (b) as
  a sparse "yes" is; a "no" is exact (a search that finds no augmenting
  path shows some maximum matching leaves its root exposed). Later sparse
  searches run on the sparse graph plus that matching's pairs, still a
  subgraph of the whole one.
* **Blossoms merged by group** (`CardinalityMatching.contract/4`). The
  vertices sharing a base are kept as a group; a contraction merges the
  groups of the cycle's bases, the smaller into the larger, and names the
  cycle's base as the merged group's. The vertices newly outer are the
  cycle's bases not yet outer (every vertex of a group of more than one was
  made outer by the contraction that formed it), queued in index order as
  the scan over the sorted tree queued them: the same search, step for
  step.
* **An MDP with no partner in its bracket** (`stuck_member?/3`, on the odd
  field-graph bracket over a next group of non-candidates). Every perfect
  matching of the small graph puts it on the stand-in, its only edge, whose
  weight is therefore the same across the list; on the field graph every
  optimum floats it too once the rest of the field, the MDP in it,
  completes (the oracle's question after the walk), since the completion
  rung is then at its bound with the rest of the bracket paired inside and
  no matching pairs the MDP inside. The small bracket's answer stands with
  the MDP carried.
* **The small bracket after the walk** (`direct_small_after_walk/10`).
  Where the walk gives up on a bracket of 13-16 vertices, the small
  bracket's list is made anyway: bounded (`enumerate_bounded/6` cuts a
  branch whose weight plus half its vertices' heaviest edges falls short
  of the best, ties kept, so the optima are the same list) and capped at
  200,000 steps. The same stages' decisions over the same list, so the
  same argument.

`AINALRAMI_DIRECT=off` switches off the leftover certificate, the dense
rescue and the small bracket after the walk with the direct brackets, so a
run can be held to the engine without them end to end. The blossom change
is the same search and has no switch.

### Results

In-VM `Pairing.pair_next_round/2`, `+S 1:1`, median of 5 after one warm
call, the two builds (030bd28, the slow spots, and this) run side by side on
the same i7-10700, two positions of each at a time. Every pairing is the
same in both. The study's own timings were on another machine and run
about 1.5-2x slower than these.

| players | round | seed | 030bd28 | after | cause |
|---|---|---|---|---|---|
| 1,000 | 9 | 8,971,000 | 5.241 s | **0.031 s** | sparse oracle |
| 600 | 9 | 8,070,600 | 2.387 s | **0.020 s** | sparse oracle |
| 1,001 | 9 | 8,691,001 | 1.771 s | **0.035 s** | bootstrap |
| 1,001 | 9 | 8,061,001 | 1.751 s | **0.033 s** | bootstrap |
| 1,001 | 9 | 8,011,001 | 1.646 s | **0.055 s** | bootstrap |
| 1,001 | 9 | 8,321,001 | 1.593 s | **0.039 s** | bootstrap |
| 600 | 9 | 8,150,600 | 1.040 s | 1.039 s | left: an even top bracket with no perfect matching |
| 600 | 9 | 8,170,600 | 1.004 s | **0.023 s** | an MDP with no partner |
| 401 | 9 | 8,800,401 | 0.750 s | **0.068 s** | the exchange |
| 400 | 9 | 8,780,400 | 0.516 s | 0.532 s | left: the round sent back to the reference path |
| 601 | 9 | 8,710,601 | 0.482 s | **0.072 s** | bootstrap |
| 600 | 9 | 8,620,600 | 0.317 s | 0.332 s | left: a pruned walk past its budget |
| 600 | 9 | 8,640,600 | 0.296 s | 0.293 s | left: a pruned walk past its budget |
| 1,001 | 9 | 8,581,001 | 0.293 s | **0.129 s** | blossoms |
| 601 | 9 | 8,930,601 | 0.261 s | 0.279 s | left: a pruned walk past its budget |
| 201 | 9 | 8,710,201 | 0.254 s | 0.214 s | bootstrap; left: a bracket of three with two MDPs |
| 1,000 | 9 | 8,381,000 | 0.240 s | 0.240 s | left: a pruned walk (answered) |
| 1,000 | 2 | 8,691,000 | 0.237 s | 0.229 s | left: the 315-player bracket over the zero group |
| 1,001 | 9 | 8,181,001 | 0.216 s | **0.052 s** | blossoms |
| 1,001 | 9 | 8,731,001 | 0.215 s | **0.048 s** | blossoms |
| 1,001 | 9 | 8,501,001 | 0.211 s | **0.046 s** | blossoms |
| 1,001 | 9 | 9,001,001 | 0.208 s | 0.203 s | left: an odd bracket whose rest cannot complete |
| 1,001 | 9 | 8,801,001 | 0.206 s | **0.049 s** | blossoms |
| 1,001 | 9 | 8,371,001 | 0.203 s | **0.048 s** | blossoms |
| 1,001 | 9 | 8,931,001 | 0.201 s | **0.049 s** | blossoms |
| 401 | 9 | 8,390,401 | 0.191 s | **0.013 s** | bootstrap |
| 401 | 9 | 8,320,401 | 0.188 s | **0.019 s** | bootstrap |
| 401 | 9 | 8,070,401 | 0.185 s | **0.015 s** | bootstrap |
| 401 | 9 | 8,060,401 | 0.182 s | **0.021 s** | bootstrap |
| 401 | 9 | 8,310,401 | 0.180 s | **0.011 s** | bootstrap |

| | 030bd28 | after |
|---|---|---|
| the 30, in all | 22.5 s | 4.2 s |
| median of the 30 | 0.261 s | 0.049 s |
| slowest | 5.24 s | 1.04 s |
| 100 others at random (the same sizes and rounds), in all | 1.65 s | 1.59 s |
| their median / p90 / slowest | 13.3 / 33.1 / 80 ms | 12.4 / 33.3 / 65 ms |

Of the 100, one position is more than 20% (and 2 ms) slower (100 players
round 9, 10.3 -> 12.4 ms, within the runs' spread) and three are faster.

### How it was checked

Every check below ran on the committed engine.

* **Differential against v0.33.0** (`tools/perf_diff.exs`, the baseline
  logs of the passes below), default configuration: small 370,777 rounds,
  flags 68,898, large 5,497, early 1,980 - **447,152 rounds, 0 differing,
  0 missing** (89,665 + 16,964 + 477 + 60 of them with the alternatives
  fingerprinted). Its pairing calls took 127,625 leftover bootstraps, 835
  dense rescues (4 of them admitting a local bracket), 732 small brackets
  after the walk and 15 MDPs with no partner.
* **Check mode** (`AINALRAMI_DIRECT=check`, certified mode forced, the
  first 400 tournaments of every axis of the four sets): 44,325 rounds,
  identical to v0.33.0 end to end, with **14,668 new answers checked, 0
  differences** - 11,847 leftover bootstraps held to the search, 1,582
  dense rescues whose matching was checked pair by pair (the 4 local
  brackets they admitted held to the field path, and 778 field-graph
  brackets held to it as every such bracket is), 353 small brackets after
  the walk and 886 MDPs with no partner, each held to the stages or the
  field path - besides 411,578 oracle answers held to the weighted oracle
  and 63,265 pools to per-resident matchings, 0 differences.
* **Generated large fields**, 400-1,001 players, 9 rounds: 20 opens with 3%
  requested byes, 2% forfeits and 1% withdrawals (446-969 players, 11 odd)
  and 20 without (411-993, 10 odd), paired in check mode (1 leftover
  bootstrap, 12 dense rescues, 1 local bracket they admitted, 2 small
  brackets after the walk, 1 MDP with no partner, and 652 field-graph
  brackets, all checked, 0 differences), then again with
  `AINALRAMI_DIRECT=off` and by 030bd28: the 360 rounds identical across
  all three.
* **The study's 30 positions** in check mode, every round leading up to
  each position included (263 rounds): 15 leftover bootstraps, 7 dense
  rescues (2 local brackets), 1 small bracket after the walk and 2 MDPs
  with no partner checked, 0 differences, and each position's pairing the
  same as the timing runs'.
* `mix test`: 816 tests, 0 failures; `direct_bracket_test.exs` requires a
  leftover bootstrap, a dense rescue, a small bracket after the walk and an
  MDP with no partner to have answered (and been checked);
  `cardinality_matching_test.exs` checks the matcher on graphs of 21-140
  vertices against `WeightedMatching` with every weight equal, over a
  neighbour function, and with pairs of its matching outside the graph
  searched.

### What is left

Of the 30, eight positions are as they were, each a shape no argument here
covers:

* **An even top bracket with no perfect matching** (600 players, 1.04 s):
  four leaders, two pairs of whom have met, float two players, and that
  bracket is paired on the whole field graph. A bracket that must float
  more players than its parity is still paid in full.
* **A round sent back to the reference path** (400 players, 0.53 s): a
  tainted round's certified read met a tie (`{:abort, :read}`), and the
  round was paired again without the shortcuts, its 3-player top bracket on
  the field graph.
* **Pruned walks** on 83-93-player brackets (0.28-0.33 s): past their
  budget, so the stages on the local graph; a larger budget answers some of
  them, but the walk then costs what the stages do.
* **A bracket of three with two MDPs** (201 players, 0.21 s): more MDPs
  than residents is outside the direct brackets (`direct_allowed?/2`).
* **An odd bracket whose rest cannot complete** with its window gone
  (1,001 players, 0.20 s): exact now, and a "no".
* 1,000 players round 2's 315-player bracket over the zero group and a
  slow pruned walk at 1,000 players round 9 (0.23-0.24 s), both answered
  directly already.

## The slow spots (2026-09-30)

The Gacrux benchmark's positions had a few rows far off the rest: 600
players round 2 took **2.9 s** where 400 and 1,000 players took 0.02 and
0.05 s, and round 9 took **1.18 s** at 1,000 players and 0.39 s at 600.
Each was one bracket that went to a matcher its answer did not need, or
the completability oracle's matcher itself. Every row is now under 0.07 s
with the same pairing, and every answer on the differential corpus is
unchanged. On 60 generated opens of 158-947 players, rounds 2-9 went from
132 s of pairing in all (worst round 21.7 s) to 7.6 s (worst 88 ms).

### Where the time was

In-VM `Pairing.pair_next_round/2`, `+S 2:2`, the per-bracket trace and the
certified-mode counters, on the benchmark's positions:

| position | in-VM | where |
|---|---|---|
| 600 players, round 2 | 2.93 s | the 0.5 bracket (202 players and one MDP) over the 199 on zero, on the field graph: 2.88 s |
| 600 players, round 9 | 0.39 s | a 108-player bracket whose walk needed 30,709 checks against a budget of 3,968, so the stages on the local graph: 0.33 s |
| 1,000 players, round 9 | 1.18 s | a 169-player bracket, 22,552 checks against 5,920: the stages, 1.02 s; the oracle's first solve, 62 ms; a 19-player odd bracket over a 4-player group with one player below, on the field graph, 28 ms |
| 1,001 players, round 9 | 0.31 s | the oracle's first solve, 0.22 s |
| 200 players, round 9 | 0.08 s | the oracle's re-solve after each bracket, 3-6 ms apiece |

* **The 0.5 bracket of an even round 2.** Odd, over the players on zero:
  on an even field those are bye candidates in the completion rung's
  sense (`1 + !isByeCandidate(a) + !isByeCandidate(b)` with the bye score
  at zero), so the local graph turned it away, and the field-graph odd
  bracket required a window of non-candidates. At 400 and 1,000 players
  the 1.0 group is even, so the 0.5 bracket is too, which is why only 600
  was slow.
* **Two walks past their budget.** The walk is depth-first and discards a
  choice only on the per-edge test and the colour counts, so a conflict
  near the end of S1 (two late S1 players with one S2 partner between
  them) is walked again under every choice above it: 7,424 illegal pairs
  and 12,315 colour-count failures in the 108-player bracket, almost all
  in its last eight levels.
* **The oracle.** A maximum-WEIGHT matching over the sparse field graph,
  solved from cold once a round (0.05-0.22 s at 1,000 players, the odd
  field the slowest) and re-solved after every accepted bracket.
* **The 19-player odd bracket** has an even next group of 4 and one player
  below it, so the floater's `q / 2` pairs leave one of the four to that
  player; the pool required the rest of the field to take ANY of the four,
  and it could take only some.

The generated opens (the fuzz generator at 158-947 players, 3% requested
byes, 2% forfeits, 1% withdrawals, 9 rounds) showed two more, every round
over 0.3 s once the four above were gone:

* **A bracket none of whose members can play each other** - the two
  leaders of a late round who have met - went to the field graph: 2.6 s
  at 926 players round 9, 1.0 s at 494.
* **The odd field's bye bootstrap** (`bye_assignee_score/2`): where the
  greedy certificate fails - a player left without a partner in field
  order, or the top group split - the whole-field complete-graph search:
  0.15-1.8 s.

### What changed

Six changes, each argued in the section comments of `Ainalrami.Pairing`
and each held to the path it replaces in check mode:

* **An odd bracket of an even field over the group on zero**
  (`:odd_zero_group`, certified mode). The players on zero make the
  completion rung's per-edge terms vary, but every optimum is a perfect
  matching (the field is even and one exists: the walk's pairs, the
  floater absorbed, the rest completed), and over perfect matchings those
  terms sum to the same. The completion rung is the only rung that reads
  bye candidacy there (C9 is off with no bye), so the odd bracket's
  argument holds as it stands, with the bracket's own members still
  required to be non-candidates (the walk's per-edge completion test).
* **The odd bracket's pool, all at once, and its takers.** The residents
  the next group `N` absorbs were found by a weighted matching of `N` plus
  the resident, per resident - 202 matchings of a 200-vertex graph at 600
  players round 2. They are the residents who can play some `G` in the
  exposable set of `N` (when `q = |N|` is odd) or of `N` plus a stand-in
  joined to the takers (when it is even) - one Gallai-Edmonds search
  (`absorbed_pool/5`). The takers: with `q` even the floater's `q / 2`
  pairs leave one of `N` to the rest of the field, and the argument needs
  only that the one left over can be taken, not that every player of `N`
  could be - each shown by the oracle, as before.
* **The pruned walk.** A plain walk past its budget runs again with two
  more ways to discard a subtree, both proofs that it holds no leaf:
  Hall's condition on the rest (a maximum matching of the remaining S1
  into the remaining S2 over legal, colour-compatible pairs, kept from
  choice to choice by one augmenting search when a choice takes someone's
  partner), and states that failed once (the S1 position, the S2 players
  used and the two colour counts decide everything below them). It meets
  its leaves in the plain walk's order, so it returns what the plain walk
  would have returned with no budget. The per-edge ladder test is
  remembered per walk. The two brackets: 2,138 and 1,620 checks.
* **The oracle as a cardinality matching.** Every question it answers is
  "is there a matching of the players left, leaving the bye (if any) on a
  candidate", which is a perfect matching of the players plus, on an odd
  count, a stand-in joined to every candidate. A maximum matching is kept
  from question to question: the players taken out leave their partners
  exposed, and an augmenting search from each
  (`Ainalrami.CardinalityMatching.augment_from/4`, which grows only the
  tree it needs - no per-search array over the graph, a blossom
  relabelling only the tree) either matches it or shows some maximum
  matching leaves it exposed. The weighted oracle's answers were the same
  property of the same sparse graph; under `AINALRAMI_DIRECT=check` it
  runs alongside and every answer is held to it.
* **A bracket that cannot pair at all** (`:empty`, certified mode). The
  field graph has no edge between two of its members (an edge is only ever
  made for a legal, colour-compatible pair), so whatever the stages do the
  field path pairs nobody, carries everyone forward in order and counts
  every member as floating. The next bracket's C9 gate, the one reader of
  the tentative partners, must be shut on its own terms; the round matcher
  is left on the certified mode's terms, as the other field-graph shapes
  leave it.
* **The bye bootstrap by matchings.** Where the greedy certificate fails,
  the certificate's existence - all but the leftover `L` paired over
  compatible edges, `L` the last of the least `(ineligible, place)`, the
  top group paired inside itself as far as its parity allows - is shown by
  maximum matchings on sparse subgraphs: the top group less `L` and the
  rest each perfectly matched, or, when the top group less `L` is odd,
  a player its near-perfect matchings can leave over who can play one the
  rest's can (both exposable sets). The answer is read off the bounds:
  the bye score is `L`'s, and the single-downfloater flag holds exactly
  when `L` is in the top group and the rest of that group is paired
  inside it. What the sparse graphs miss goes to the search as before;
  check mode holds every such answer to the search.

### Results

In-VM `Pairing.pair_next_round/2`, `+S 2:2`, medians of 5, the positions
`/root/bench.exs` on the validation VM builds (the fuzz generator at seed
`9,500,000 + players`, earlier rounds paired by this engine), the two
builds run one after the other on the same idle machine (an i7-10700).
Every pairing is the same in both.

| position | before (0a844f7) | after |
|---|---|---|
| 200 players, round 2 | 0.008 s | 0.002 s |
| 200 players, round 9 | 0.082 s | **0.008 s** |
| 400 players, round 2 | 0.019 s | 0.006 s |
| 400 players, round 9 | 0.041 s | 0.011 s |
| 600 players, round 2 | 2.93 s | **0.028 s** |
| 600 players, round 9 | 0.389 s | **0.040 s** |
| 1,000 players, round 2 | 0.046 s | 0.017 s |
| 1,000 players, round 9 | 1.18 s | **0.065 s** |
| 1,001 players, round 2 | 0.125 s | 0.067 s |
| 1,001 players, round 9 | 0.306 s | **0.029 s** |

The generated opens (60 tournaments, seeds 1-60, 158-947 players, 27 of
them odd; four at a time at `+S 4:4`; every round re-paired identically
by both builds), rounds 2-9:

| | before | after |
|---|---|---|
| pairing, all 480 rounds | 132.4 s | 7.6 s |
| median round | 65 ms | 14 ms |
| p95 | 791 ms | 32 ms |
| slowest round | 21.7 s | 88 ms |

### How it was checked

Every check below ran on the committed engine.

* **Differential against v0.33.0** (`tools/perf_diff.exs`, the baseline
  logs of the passes below), default configuration: small 370,777 rounds,
  flags 68,898, large 5,497, early 1,980 - **447,152 rounds, 0 differing,
  0 missing** (89,665 + 16,964 + 477 + 60 of them with the alternatives
  fingerprinted).
* **Check mode** (`AINALRAMI_DIRECT=check`, certified mode forced, the
  first 400 tournaments of every axis of the four sets): 44,325 rounds,
  identical to v0.33.0 end to end, with **20,631 new direct answers
  checked, 0 differences** - 3,244 odd brackets over the group on zero,
  3,339 more odd brackets (54,155 against the previous pass's 50,816: the
  takers), 13,959 brackets that cannot pair and 89 pruned walks - besides
  63,265 pools held to per-resident matchings (a maximum matching per
  resident, and the weighted `absorbed?/3` wherever the pool had its old
  shape and the group is at most 100), **410,485 oracle answers held to
  the weighted oracle** and **19,623 bye bootstraps held to the search**,
  0 differences.
* **Every walk the pruned one** (the same, with
  `AINALRAMI_DIRECT_PLAIN=0`): the 29,843 walk answers of that run all
  came from the pruned walk and were held to the stages, and the 44,325
  rounds are again identical to v0.33.0.
* **Generated large fields**: the 60 opens above, paired in check mode
  (71 odd brackets over the group on zero, 22 more odd brackets, 7
  brackets that cannot pair, 17 pruned walks, 11 bootstraps, 364 pools and
  5,165 oracle answers checked, 0 differences), and again with
  `AINALRAMI_DIRECT=off`: the 540 rounds identical, and identical to the
  previous build's.
* `mix test`: 814 tests, 0 failures; `direct_bracket_test.exs` requires
  the zero group's shape, the bracket that cannot pair and a matched
  bootstrap to have been checked, and runs a pass with every walk pruned;
  `cardinality_matching_test.exs` checks `augment_from/4` against
  exhaustive search on 2,000 random graphs with dead vertices.

### What is left

Over the default corpus the direct brackets still gave up on 198,962
brackets whose local graph has no perfect matching (they go to the field
graph; below 100 players, and above it where some pair is possible), 5,826
whose floater the walk could not
show to be the stages', 1,654 MDP choices whose remainder needs an
exchange, 648 whose bounds no matching met, and 18 pruned walks past their
budget. A bracket that must float more players than its parity - some
pairs possible, not enough - is the shape still paid in full. On the
generated opens the slowest rounds left are 54-88 ms: a matched bootstrap
at 647 players, two pruned walks, a round 2 at 924 players, one such
bracket at 254 players and one pruned walk past its budget.

## The direct bracket on odd fields (2026-09-29)

A 1,001-player round 2 took **31.9 s**, where 1,000 players took 0.05 s:
two brackets of the odd field went to the whole-field matcher. It now
takes **0.12 s**, with the same pairing, and every answer on the
differential corpus is unchanged.

### Where the time was

The fuzz generator's position at 1,001 players (seed 9,501,001, the
position the Gacrux benchmark on the validation VM pairs), round 2: the
1.0 group (319) was already direct; the 0.5 bracket (364 residents and one
MDP, window 683) took 26.6 s and the 0.0 group with its floater (319)
5.3 s, both on the field graph (timed in-VM at `+S 4:4`).

* **The 0.5 bracket.** Its next group is the 0.0 group, the bye
  candidates, so the local graph turned it away (its members' completion
  terms vary), and the field-graph direct bracket did too: it required a
  window of non-candidates.
* **The last group.** The bracket the bye comes out of has the C9 gate on,
  which the field-graph direct bracket excluded by design.

### What changed

Three more shapes of the direct bracket, each argued in the section
comments of `Ainalrami.Pairing` (`attempt_direct_field/7`,
`attempt_direct_last/7`):

* **The last bracket of an odd field** (every mode, since nothing is
  paired after it). The bracket is the whole remaining graph, so once the
  walk finds a matching of all members but one that leaves a bye
  candidate over, every optimum is one; over those, the completion rung
  and C9 are sums of per-vertex terms fixed by the one left over - a bye
  candidate, then the least unplayed-game rank (C9: the assignee with the
  fewest unplayed games) - and C7 keeps every MDP paired. So the walk runs
  with the bye as its floater and the resident candidates of that least
  rank as its pool, and skips the per-edge completion and C9 tests whose
  sums the floater fixes. The stages read an unmatched member exactly as
  one matched to the local graph's stand-in (not paired down, in the
  remainder), which is the walk's model of an odd bracket's floater.
* **An odd bracket over the bye group** (certified mode): every member
  above the bye score, the next group the last one. The existing odd
  bracket's argument goes through with "the rest completed" read as
  "near-perfect, leaving a bye candidate over": a resident F meets the
  completion and C8 bounds exactly when the group and F have `q / 2`
  pairs covering F with a candidate left over, and every such F meets
  them alike. That set is exact and found for all residents at once: F
  qualifies when it can play some G that a maximum matching of the group
  plus a stand-in joined to its candidates can leave exposed - the D of
  the Gallai-Edmonds decomposition, one Edmonds search
  (`Ainalrami.CardinalityMatching`, checked against exhaustive search on
  3,000 random graphs) where the old per-floater question was a matching
  per resident.
* **An even bracket of an odd field** (certified mode), as on an even
  field: the bracket perfectly matched inside, the rest shown completable
  with a candidate over by the oracle, so C6 keeps it inside in every
  optimum.

On an odd field the next bracket's C9 gate reads the tentative partners
of this bracket's window; the new shapes are taken only where that read
is decided without them - the next group scores above the bye (the gate
is shut), or it is the last group (every partner the window can have
scores at least as much, so the gate reads true on both paths).

And one abort that was needlessly conservative: after a field-graph direct
bracket, a later bracket that would build the round matcher with a
different C9 gate from the reference's sent the whole round back to the
reference path. When that bracket's window is the whole remaining field
there is no far edge for the gate to have scored - the reference's
boundary sets every edge to the bracket's own weights - so it now goes on
(`builder_gate_whole_window` in the counters: 21 times in the default
corpus).

### Results

In-VM `Pairing.pair_next_round/2`, `+S 2:2`, medians of 3-7 runs, the
two builds run alternately on the same idle machine (an i7-10700); the
positions are the Gacrux benchmark's (`/root/bench.exs` on the validation
VM: the fuzz generator at seed `9,500,000 + players`, earlier rounds paired
by this engine). Every pairing is the same in both builds.

| position | before (bbcd392) | after |
|---|---|---|
| 1,001 players, round 2 | 31.9 s | **0.12 s** |
| 1,001 players, round 9 | 0.31-0.34 s | 0.31 s |
| 1,000 players, round 2 | 0.049 s | 0.049 s |
| 1,000 players, round 9 | 1.17 s | 1.17 s |

Round 2 at 1,001 players is now its three brackets answered directly:
65 ms for the 1.0 group (as before), 53 ms for the 0.5 bracket over the
bye group (the pool search and the walk) and 2 ms for the last group.
Gacrux takes 4.6 s on that position on the validation VM. Round 9's bye
comes out of an even bracket over a one-player last group, which moves
from the field graph (30 ms) to the direct bracket (2 ms); the rest of
that round is unchanged. The even field is untouched.

### How it was checked

* **Differential against v0.33.0** (`tools/perf_diff.exs`, the baseline
  logs of the passes below), default configuration: small 370,777 rounds,
  flags 68,898, large 5,497, early 1,980 - **447,152 rounds, 0 differing,
  0 missing** (89,665 + 16,964 + 477 + 60 of them with the alternatives
  fingerprinted). Its pairing calls took the new shapes 145,909 times:
  143,792 last brackets (every field size - this one needs no certified
  mode), 925 odd brackets over the bye group, 1,192 even brackets of an
  odd field; the relaxed builder gate went on 21 times.
* **Check mode** (`AINALRAMI_DIRECT=check`, which now also holds the new
  shapes to the field path on the same bracket from the same state -
  pairs, who is carried, how many float, and for the field-graph shapes
  the next bracket's C9 gate - and raises on any difference), certified
  mode forced, the first 400 tournaments of every axis of the four sets:
  44,325 rounds, identical to v0.33.0 end to end, with **33,367 new direct
  answers checked, 0 differences** (14,418 last brackets, 6,905 odd
  brackets over the bye group, 12,044 even brackets of an odd field),
  besides 60,481 of the existing field-graph shapes.
* **Generated odd fields**: 80 tournaments of 107-999 players (odd sizes
  drawn from 101-1,001; 3% requested byes, 2% forfeits, 1% withdrawals),
  9 rounds, paired in check mode - 566 new direct answers checked (250 last
  brackets, 142 odd over the bye group, 174 even of an odd field), 0
  differences - and again with `AINALRAMI_DIRECT=off`: the 720 rounds
  identical.
* `mix test`: 812 tests, 0 failures; `direct_bracket_test.exs` gains an
  axis of 101-151-player fields and requires each new shape to have been
  answered (and checked) at least once;
  `cardinality_matching_test.exs` checks the exposable set against
  exhaustive search on 3,000 random graphs.

### What is left

* **The bye group with a group below it.** An odd bracket, or an even
  one, whose next group holds the bye but is not the last group still
  falls back: the next bracket's C9 gate then depends on whether a window
  player is tentatively matched below, which is a read of the matcher's
  own tie-break.
* **An odd bracket over the bye group whose own members include bye
  candidates** falls back (the walk's per-edge completion test needs its
  members to be non-candidates).
* **A last bracket whose leftover cannot be a least-rank candidate**
  (the walk finds no matching meeting that bound, or runs past its
  budget) goes to the field graph as before.
* **Round 9 at 1,001 players** spends 0.22 s of 0.31 s in the first
  bracket, an existing odd-bracket shape whose pool question solves the
  whole-field completability oracle from cold.

## The direct bracket (2026-09-28)

On the benchmark files `docs/validation.md` compares the three engines
on, the pairing work - a cold run minus the engine's own start-up - is
now **0.08 s at 209 players, 0.11 s at 400, 0.14 s at 1,000, and 0.07 s
and 0.17 s for rounds 2 and 9 of a 600-player open**, from 0.32-7.2 s, and
the output is byte-identical to v0.33.0's. Gacrux (Python + networkx) was
faster than this engine on every file but a fresh round 1; it is now 3x
slower at 209 players and 9-46x slower on the rest.

> **SUPERSEDED as a comparison (2026-09-30).** The 3x and 9-46x are
> single files, one position each, and a single position can land on a
> shape that is slow for one engine and not another. The comparison to
> quote is [the timing study](#the-timing-study-2026-09-30)'s medians over
> 100 positions per row. The before-and-after on these files stands.

### Results

Cold process, start to finish, median of 5 runs (3 at 1,000 players; min
within 0.03 s of the median everywhere): the same six files as
`docs/validation.md`'s 2026-09-28 re-run (`Ainalrami.Generator`, seed
`20260827 + players`; 5 rounds played and round 6 paired at 209, 400 and
1,000; rounds 1, 2 and 9 at 600), every file's boards identical across all
four programs, colours included (105/105, 200/200, 500/500, 300/300 x3).
"Before" is perf-certify (v0.34.0 plus the certified shortcuts), which this
builds on. An i7-10700 (8 cores, 16 threads) with one other job running
throughout at ~15% of total CPU.

| file | bbpPairings | Gacrux | before | after |
|---|---|---|---|---|
| 10 players (start-up floor) | **0.05 s** | 1.08 s | 0.75 s | 0.75 s |
| 209, round 6 | **0.59 s** | 1.32 s | 1.07 s | 0.83 s |
| 400, round 6 | 2.81 s | 2.05 s | 1.99 s | **0.86 s** |
| 1,000, round 6 | 51.6 s | 7.47 s | 7.92 s | **0.89 s** |
| 600, round 1 | 9.59 s | 2.22 s | 0.74 s | **0.74 s** |
| 600, round 2 | 8.29 s | 2.37 s | 7.47 s | **0.82 s** |
| 600, round 9 | 10.8 s | 3.63 s | 3.33 s | **0.92 s** |

Pairing work, each program's own floor subtracted:

| file | bbpPairings | Gacrux | before | after | after vs Gacrux |
|---|---|---|---|---|---|
| 209, round 6 | 0.54 s | 0.24 s | 0.32 s | **0.08 s** | 3.0x faster |
| 400, round 6 | 2.76 s | 0.97 s | 1.24 s | **0.11 s** | 8.8x |
| 1,000, round 6 | 51.6 s | 6.39 s | 7.17 s | **0.14 s** | 46x |
| 600, round 1 | 9.54 s | 1.14 s | 0.00 s | **0.00 s** | - |
| 600, round 2 | 8.24 s | 1.29 s | 6.72 s | **0.07 s** | 18x |
| 600, round 9 | 10.8 s | 2.55 s | 2.58 s | **0.17 s** | 15x |

Pinned to two schedulers (`ERL_FLAGS="+S 2:2"`, the production VPS; the
pairing is single-threaded) the after column is 0.80, 0.83, 0.86, 0.72,
0.78 and 0.89 s cold - the same within noise. What is left of a cold run
is the BEAM's start-up and reading the file; a 1,000-player round is now
cheaper to pair than to start the VM for. bbpPairings keeps the smallest
cold total on the 209-player file, on start-up alone (0.05 s against
0.75 s).

### Where the time was

Profiled on the six benchmark files (perf-certify, which this builds on,
timed in-VM with the per-bracket trace and `:tprof`):

| file | round | in-VM | where |
|---|---|---|---|
| 209 players | 6 | 0.30 s | two small top brackets on the whole-field graph 0.20 s, seven local brackets 0.10 s |
| 400 players | 6 | 1.2 s | a 3-player top bracket on the whole field 0.63 s, local brackets 0.6 s |
| 1,000 players | 6 | 7.2 s | local brackets 7.1 s: 213 players 2.8 s, 218 2.1 s, 172 1.4 s |
| 600 players | 2 | 6.8 s | field brackets of 172 (4.1 s) and 214 (2.1 s), a local one of 214 (0.7 s) |
| 600 players | 9 | 2.3 s | a 5-player top bracket on the whole field 1.5 s, local brackets 0.9 s |

Inside a bracket the time was the eight refinement stages' matcher work:
on the 213-player bracket, the initial solve ~0.6 s, stage 4's re-solve
1.4 s (its dual shift refused), stage 8 0.7 s. `:tprof` put 70-80% of a
round in `Ainalrami.WeightedMatching`.

Gacrux, `cProfile` on the same files: its pairing is one `pair_bracket`
per score group, and most brackets are answered by `simple_permute` - a
depth-first walk of Article 3's transposition order that accepts the first
candidate every pair of which is clean on C9-C21 and whose colour clashes
meet a counting bound - with a networkx `min_weight_matching` only where
that walk fails (4-11 small matchings a round on these files). Its time
goes mostly to building the crosstable - one Python object per pair of
players, 500,000 at 1,000 players (`list_edges`, 2.0 s of 7.1 s there) - and
the "hamilton" completability pre-pass (1.3 s); `pair_bracket` itself is
2.5 s at 1,000 players and 0.19 s at 600 players round 2. So Gacrux was
not faster code: it did less matching - a walk per bracket where this
engine ran eight stages of a general weighted matcher, on the whole field
for the top brackets.

### What changed

The same idea, held to a proof: a bracket whose answer can be shown to
be the stages' answer is answered without them. Three pieces, in
`Ainalrami.Pairing`:

* **The direct walk** ("the direct bracket"). For a bracket on the local
  graph, the stages' answer is the first matching, in the order "each MDP's
  partner in turn, then each S1 player's partner in turn", among the
  matchings of maximum criteria weight `C*` - when one of those pairs every
  MDP and pairs S1 into S2 with no exchange. The walk visits that order
  depth first and accepts a matching only when it meets an upper bound on
  every ladder rung at once - per-edge bests for C10, C11, C15, C17, C19
  and C21; counting bounds for C12 and C13 from the members' colour
  preferences; the floater's own downfloat bits for C14 and C16 - which
  makes it a `C*`-optimum outright; every choice it discards breaks a
  necessary condition of meeting those bounds. The derivation of each
  bound, and why each stage returns what the walk returns, is the
  section comment. It gives up (and the stages run as before) when a
  choice for an MDP passes every necessary condition but its remainder
  has no exchange-free answer, when it runs past a budget of `32n + 512`
  edge checks, or on soft pairs and the experimental ladder switches.
* **The small bracket.** A graph of at most 12 vertices has few enough
  maximum-weight matchings to list, and the stages' decisions are then
  filters over that list, applied in their order - stage 1 keeps an MDP
  inside if some optimum does, stage 2 and stage 8 take the best-ranked
  partner some optimum gives, stages 4-6 keep the exchange weights' optima
  and exchange a player if some optimum does. Every value a stage reads
  off the matching is checked to be the same across the optima left at
  that point, and a read that is not ends the attempt. This covers the
  small brackets the walk cannot, exchanges included.
* **Brackets the local graph turned away** (`attempt_direct_field/7`,
  certified mode only). An even bracket of an even field whose window
  holds players on zero - round 2 of every large open - is its own local
  problem once the rest of the field can be completed: with no bye, every
  optimum of the field graph is perfect and C6 then keeps the bracket
  inside. An odd bracket over a next group too small for the stand-in
  (the lone leaders at the top of a round) is the direct walk over the
  floaters the field below can absorb at the completion and C8 rungs'
  bounds: shown by the completability oracle for the rest of the field
  and a small exact matching on the next group plus the floater. Neither
  leaves the round matcher the reference would carry, so a later field
  bracket's reads are certified (the certified mode's own contract), and a
  later bracket that would build the matcher with a different C9 gate
  than the reference's sends the round back to the reference path.

And one cost the direct brackets exposed: the completability oracle was
solved from cold by every question asked of it before the first bracket
was accepted - eight times for the 400-player file's first bracket. It
is now solved once and kept; its answers are properties of its graph, not
of the state it keeps.

### How it was checked

Every check below ran on the committed engine.

#### Differential against v0.33.0: 892,324 rounds, 0 differences

`tools/perf_diff.exs` (described under the large-field pass below), run
on this tree and compared with the v0.33.0 logs of that pass, round by
round - the pairing or refusal, `explain_round/3`, the perturbed pairing's
explanation and `Alternatives.judge/4`, and on a sampled share of rounds
every forced search `Alternatives` runs. Twice: in the default
configuration, where the local-graph direct brackets run on every field
size and the field-graph ones from 100 players up, and with
`AINALRAMI_CERT=force`, which puts the field-graph ones on the small
fields too.

| set | default | `AINALRAMI_CERT=force` |
|---|---|---|
| small (8 axes, 4-40 players) | 370,777 rounds | 370,777 rounds |
| flags (field graph only, strand repair, completion reading) | 68,898 | 68,898 |
| large (60-600 players) | 5,497 | 5,497 |
| early (100-600 players, opening rounds) | 1,980 | - |
| | **447,152 rounds, 0 differing, 0 missing** | **445,172 rounds, 0 differing, 0 missing** |

214,272 of those rounds also fingerprinted the alternatives. The pairing
calls of the two runs (the alternatives' own forced pairings not counted)
were answered directly 2,113,871 times.

#### Each direct answer held to the stages' on the same bracket

`AINALRAMI_DIRECT=check` pairs every bracket the direct brackets answer
with the stages as well, from the same state, and raises on any
difference. Run on the first 400 tournaments of every axis of the four
sets (fewer where an axis has fewer), certified mode forced: 44,325
rounds, 149,356 direct answers checked, 0 differences - and the same
44,325 rounds identical to v0.33.0 end to end. `test/ainalrami/direct_bracket_test.exs`
does the same on 243 generated tournaments of 4-180 players at every
`mix test`, and also pairs every round with `AINALRAMI_DIRECT=off` and
requires the two to agree.

#### Against the references

* **`mix test --timeout 300000`**: 811 tests, 0 failures (5 tags excluded
  by default); `--only interop` 2 of 2.
* **bbpPairings, direction 1** (`mix test --only bbppairings`): 1,000
  tournaments of 4-40 players over 9 rounds (8,402 rounds, 99,305 pairs)
  and 100 of 60-160 players over 8 rounds (800 rounds, 43,888 pairs) -
  **100.00%, 0 refused, 0 illegal**, no disagreement about who is White on
  138,816 boards.
* **bbpPairings, direction 2** (`tools/bbp_generator_reverse.exs`, seeds
  910001-910600): bbpPairings could not generate 5; on the other 595,
  **5,930 rounds, 346,901 pairs, 0 composition mismatches**, 0 colour
  mismatches on 309,481 shared boards.
* The matcher (`Ainalrami.WeightedMatching`) is unchanged, so the
  lockstep was not re-run.

#### Reproducing

    # the corpus, resumably, against a baseline's logs
    DIFF_CHUNK=100 MIX_ENV=test mix run tools/perf_diff.exs corpus small OUT/new/small
    MIX_ENV=test mix run tools/perf_diff.exs compare OUT/base/small OUT/new/small

    # each direct answer against the stages, a slice of every axis
    AINALRAMI_DIRECT=check AINALRAMI_CERT=force DIFF_LIMIT=400 DIFF_CHUNK=50 \
      MIX_ENV=test mix run tools/perf_diff.exs corpus small OUT/check/small

    # the benchmark files
    ainalrami -g f.trf --seed=$((20260827 + N)) --players=N --rounds=5   # then 142 -> 9

### What is left, and what was tried

* **Where the direct brackets give up.** Over the check-mode run above,
  the walk and the small bracket answered 149,356 brackets; the stages
  still paired those with no perfect local matching (17,726 - they go to
  the field graph as before), those whose floater the walk could not show
  to be the stages' (1,405), MDP choices whose remainder needed an
  exchange (319, plus 285 whose bounds no matching met) and 250 walks
  past their budget. A large bracket that needs an exchange is the case
  still paid in full.
* **Odd fields.** An odd 1,001-player round 6 (seed 20261828), measured
  once while the differential corpus was running: Gacrux 11.8 s cold,
  perf-certify 10.7 s, this 2.2 s. Its first bracket asks the
  completability oracle once per member of an even next group (18 there);
  re-adding each member to one solved state instead of removing the rest
  from scratch each time is the next saving.
* **Not re-measured**: the explanation and the alternatives. Both call
  the same pairing, so both inherit the speed-up; the click tables of
  the large-field pass below are v0.34.0's.
* **Tried and fixed before the first commit**: the C13 bound first
  counted two absolute preferences for the same colour as a pair that
  keeps C13, which only the final-round exception allows - an unreachable
  bound, so the walk exhausted its budget on the large brackets of the
  1,000-player file (never a wrong answer, since nothing below a met
  bound is accepted). And the first cut of the field-graph odd brackets
  solved the oracle from cold for every question: 0.43 s of a 0.56 s
  round at 400 players.

## The large-field pass (2026-09-28)

A pass over the engine for fields of 150-600 players. A large field's
whole round - pairing, explanation and alternatives - is now **2.5-2.8x
faster on 2 cores** (the production VPS) and **3.5-5.2x on 12**, and the
output is **byte-identical to v0.33.0**: the same pairings, the same
`explain_round/3` account, the same alternatives, checked over 445,172
rounds. This document says where the time was, what changed, why each
change cannot move an answer, and how that was checked.

### Results

Generated opens of 150, 300, 450 and 600 players (`tools/perf_bench.exs`:
ratings falling with the starting rank, results drawn from FIDE's expected
score, 2% forfeits, 3% requested byes and a few forbidden pairs every
round; 9 rounds, 11 from 450 up; two tournaments per size), every round
re-paired from the state just before it, **v0.33.0 and this tree compiled
into the same VM and timed alternately round by round** (`PERF_REF`), with
their answers compared as they ran - identical on all 160 round-timings.
"Click" is what OpenPairings' "Pair round" asks of the engine: the
pairing, `explain_round/3`, and the float and bye alternatives it stores
with the round.

`+S 2:2` is the production VPS (2 vCPU); `+S 12:12` a desktop. The pairing
itself is single-threaded, so it is the same on both; the alternatives
run one forced search per scheduler and gain more the more cores there
are.

#### The whole click

At `+S 2:2`:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 2.84 s | 1.04 s | 4.98 s | 1.78 s | 11.1 s | 3.67 s | 2.7x |
| 300 | 18 | 4.01 s | 1.98 s | 25.0 s | 8.62 s | 29.5 s | 9.10 s | 2.8x |
| 450 | 22 | 12.1 s | 4.77 s | 67.7 s | 20.0 s | 170.8 s | 67.5 s | 2.7x |
| 600 | 22 | 18.2 s | 7.01 s | 52.5 s | 32.3 s | 115.4 s | 36.2 s | 2.5x |

At `+S 12:12`:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 2.98 s | 599 ms | 5.10 s | 818 ms | 11.6 s | 1.58 s | 5.2x |
| 300 | 18 | 3.88 s | 1.55 s | 25.3 s | 4.27 s | 29.2 s | 4.56 s | 4.5x |
| 450 | 22 | 12.9 s | 3.44 s | 68.6 s | 16.8 s | 171.4 s | 33.4 s | 4.6x |
| 600 | 22 | 19.5 s | 4.65 s | 57.3 s | 17.2 s | 116.2 s | 37.0 s | 3.5x |

By round, `+S 2:2` (with two tournaments per size, each cell is the
slower of the two):

| round | 150 before | after | 300 before | after | 450 before | after | 600 before | after |
|---|---|---|---|---|---|---|---|---|
| 1 | 496 ms | 370 ms | 2.80 s | 1.98 s | 9.07 s | 6.34 s | 20.6 s | 14.4 s |
| 2 | 1.06 s | 500 ms | 4.01 s | 2.43 s | 170.8 s | 67.5 s | 45.9 s | 36.2 s |
| 3 | 216 ms | 144 ms | 931 ms | 703 ms | 2.58 s | 1.68 s | 6.75 s | 3.52 s |
| 4 | 4.98 s | 1.78 s | 723 ms | 419 ms | 2.07 s | 1.02 s | 2.40 s | 1.91 s |
| 5 | 4.35 s | 1.52 s | 13.3 s | 4.62 s | 61.8 s | 19.9 s | 27.9 s | 11.7 s |
| 6 | 3.93 s | 1.44 s | 5.51 s | 2.56 s | 38.9 s | 13.2 s | 13.7 s | 4.62 s |
| 7 | 4.36 s | 1.57 s | 29.5 s | 9.10 s | 789 ms | 562 ms | 11.2 s | 5.13 s |
| 8 | 4.47 s | 1.54 s | 20.8 s | 6.37 s | 11.5 s | 4.77 s | 52.5 s | 14.1 s |
| 9 | 11.1 s | 3.67 s | 25.0 s | 8.62 s | 46.3 s | 16.3 s | 52.1 s | 18.3 s |
| 10 |  |  |  |  | 13.8 s | 3.84 s | 36.9 s | 12.6 s |
| 11 |  |  |  |  | 67.7 s | 20.0 s | 115.4 s | 32.3 s |

#### Each part, `+S 2:2`

The pairing:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 239 ms | 143 ms | 446 ms | 360 ms | 641 ms | 447 ms | 1.5x |
| 300 | 18 | 903 ms | 548 ms | 2.57 s | 1.96 s | 3.99 s | 2.42 s | 1.7x |
| 450 | 22 | 2.04 s | 1.09 s | 13.5 s | 8.22 s | 20.0 s | 15.8 s | 1.6x |
| 600 | 22 | 3.29 s | 1.88 s | 19.3 s | 14.3 s | 45.1 s | 36.1 s | 1.6x |

The explanation:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 19 ms | 3 ms | 24 ms | 17 ms | 27 ms | 20 ms | 3.9x |
| 300 | 18 | 52 ms | 6 ms | 111 ms | 9 ms | 116 ms | 80 ms | 4.9x |
| 450 | 22 | 209 ms | 13 ms | 275 ms | 16 ms | 278 ms | 210 ms | 7.9x |
| 600 | 22 | 41 ms | 20 ms | 540 ms | 25 ms | 551 ms | 26 ms | 10.2x |

The alternatives:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 2.55 s | 904 ms | 4.73 s | 1.64 s | 10.8 s | 3.52 s | 2.9x |
| 300 | 18 | 2.65 s | 818 ms | 23.9 s | 7.91 s | 28.5 s | 8.58 s | 3.2x |
| 450 | 22 | 10.3 s | 3.26 s | 65.4 s | 18.8 s | 157.2 s | 59.3 s | 3.1x |
| 600 | 22 | 6.73 s | 2.57 s | 50.1 s | 16.3 s | 110.3 s | 29.7 s | 3.3x |

#### Each part, `+S 12:12`

The pairing:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 224 ms | 144 ms | 443 ms | 356 ms | 635 ms | 461 ms | 1.5x |
| 300 | 18 | 915 ms | 564 ms | 2.54 s | 1.97 s | 3.86 s | 2.36 s | 1.7x |
| 450 | 22 | 2.21 s | 1.14 s | 13.7 s | 8.30 s | 20.2 s | 16.8 s | 1.6x |
| 600 | 22 | 3.41 s | 2.04 s | 20.2 s | 14.4 s | 46.3 s | 36.9 s | 1.6x |

The explanation:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 19 ms | 3 ms | 23 ms | 16 ms | 33 ms | 24 ms | 3.6x |
| 300 | 18 | 61 ms | 6 ms | 115 ms | 9 ms | 122 ms | 84 ms | 4.9x |
| 450 | 22 | 220 ms | 13 ms | 290 ms | 16 ms | 296 ms | 202 ms | 8.2x |
| 600 | 22 | 41 ms | 21 ms | 598 ms | 25 ms | 605 ms | 28 ms | 10.4x |

The alternatives:

| field | rounds | p50 before | after | p95 before | after | max before | after | total speed-up |
|---|---|---|---|---|---|---|---|---|
| 150 | 18 | 2.71 s | 470 ms | 4.85 s | 671 ms | 11.3 s | 1.43 s | 6.8x |
| 300 | 18 | 2.73 s | 509 ms | 24.3 s | 3.78 s | 28.2 s | 3.80 s | 6.6x |
| 450 | 22 | 10.6 s | 1.86 s | 66.1 s | 9.56 s | 157.7 s | 25.1 s | 6.7x |
| 600 | 22 | 6.68 s | 1.97 s | 54.5 s | 9.18 s | 111.0 s | 14.6 s | 6.4x |

#### The pairing by round, `+S 2:2`

| round | 150 before | after | 300 before | after | 450 before | after | 600 before | after |
|---|---|---|---|---|---|---|---|---|
| 1 | 446 ms | 360 ms | 2.57 s | 1.96 s | 8.44 s | 6.30 s | 19.3 s | 14.3 s |
| 2 | 641 ms | 447 ms | 3.99 s | 2.42 s | 20.0 s | 15.8 s | 45.1 s | 36.1 s |
| 3 | 167 ms | 137 ms | 916 ms | 693 ms | 2.55 s | 1.66 s | 5.72 s | 3.48 s |
| 4 | 239 ms | 143 ms | 569 ms | 407 ms | 1.44 s | 987 ms | 2.35 s | 1.88 s |
| 5 | 206 ms | 132 ms | 903 ms | 548 ms | 2.23 s | 1.36 s | 2.08 s | 1.49 s |
| 6 | 246 ms | 163 ms | 706 ms | 459 ms | 2.23 s | 1.36 s | 3.29 s | 2.10 s |
| 7 | 242 ms | 149 ms | 909 ms | 571 ms | 747 ms | 535 ms | 1.57 s | 1.19 s |
| 8 | 179 ms | 114 ms | 1.03 s | 582 ms | 987 ms | 766 ms | 1.94 s | 1.12 s |
| 9 | 267 ms | 170 ms | 997 ms | 629 ms | 2.15 s | 1.23 s | 3.46 s | 1.98 s |
| 10 |  |  |  |  | 937 ms | 568 ms | 3.37 s | 1.84 s |
| 11 |  |  |  |  | 2.10 s | 1.09 s | 4.66 s | 2.54 s |

Round 1 is two different cases, and the table shows the slower. On an
even field the refinement stages now run on dual shifts and round 1 is
**4-7x** faster (`+S 2:2`: 294 players 2.44 s -> 560 ms, 440 players
7.93 s -> 1.41 s, 586 players 18.6 s -> 2.76 s). On an odd field the
initial matching leaves a first-half player unmatched, the stage-4 shift
does not apply, the stage-7 reset is re-solved from cold, and round 1
gains 1.3x (437 players: 8.44 s -> 6.30 s; 581: 19.3 s -> 14.3 s).

**Rounds 1-2 of the largest fields are what is left.** At 600 players
round 2 is 45 s -> 36 s. Profiled on its own, that round's first bracket
(273 players, on the whole-field graph) takes 28 s of 40: 15 s building
and solving the round matcher from cold, 4 s re-solving after stage 4
and 8 s after stage 7. Those are the reference algorithm's cold solves
over the whole remaining field; on an odd field the next bracket's C9
gate reads the tie they settle in the field below, so nothing here may
pick a different optimum there. That is the next target (see "Tried and
reverted").

#### OpenPairings, end to end

OpenPairings' "Pair round" click (`PairingsEngine.Pairing.pair_next_round/2`)
timed span by span on a development copy (SQLite, the dev database), with
the same OpenPairings code against v0.33.0 and against this tree. Each
case imports a generated tournament of that size truncated before the
round, then pairs it; "club" gives every player one of n/8 clubs and
switches on OpenPairings' "keep clubmates apart" soft wish, which is
where a 450-player round 1 used to spend 22 s. OpenPairings' own work -
queries, building and parsing the TRF, writing the round, recording
deviations - is 50-120 ms and did not change; everything else is the
engine.

At `+S 2:2`:

| | 150 r7 plain before | after | 300 r7 plain before | after | 450 r1 club before | after | 450 r2 plain before | after |
|---|---|---|---|---|---|---|---|---|
| OpenPairings' own work | 53 ms | 48 ms | 90 ms | 94 ms | 105 ms | 120 ms | 111 ms | 113 ms |
| engine: pairing | 74 ms | 68 ms | 316 ms | 254 ms | 22.0 s | 1.63 s | 17.4 s | 12.6 s |
| engine: soft-wish re-pair | 0.0 ms | 0.0 ms | 0.0 ms | 0.0 ms | 0.3 ms | 0.2 ms | 0.0 ms | 0.0 ms |
| engine: explanation | 4.0 ms | 3.6 ms | 13 ms | 7.2 ms | 10 ms | 13 ms | 16 ms | 10 ms |
| engine: alternatives | 793 ms | 342 ms | 3.30 s | 1.42 s | 20 ms | 20 ms | 235.7 s | 101.1 s |
| click total | 924 ms | 462 ms | 3.72 s | 1.77 s | 22.1 s | 1.78 s | 253.2 s | 113.9 s |
| speed-up |  | 2.0x |  | 2.1x |  | 12.4x |  | 2.2x |

With all 16 schedulers:

| | 150 r7 plain before | after | 300 r7 plain before | after | 450 r1 club before | after | 450 r2 plain before | after |
|---|---|---|---|---|---|---|---|---|
| OpenPairings' own work | 50 ms | 49 ms | 90 ms | 97 ms | 114 ms | 98 ms | 104 ms | 100 ms |
| engine: pairing | 75 ms | 71 ms | 318 ms | 257 ms | 22.3 s | 1.66 s | 17.5 s | 12.6 s |
| engine: soft-wish re-pair | 0.0 ms | 0.0 ms | 0.0 ms | 0.0 ms | 0.3 ms | 0.2 ms | 0.0 ms | 0.0 ms |
| engine: explanation | 4.0 ms | 2.9 ms | 12 ms | 7.2 ms | 13 ms | 13 ms | 20 ms | 10 ms |
| engine: alternatives | 776 ms | 132 ms | 3.30 s | 551 ms | 24 ms | 23 ms | 235.3 s | 42.5 s |
| click total | 905 ms | 255 ms | 3.72 s | 912 ms | 22.5 s | 1.79 s | 252.9 s | 55.2 s |
| speed-up |  | 3.5x |  | 4.1x |  | 12.5x |  | 4.6x |

No OpenPairings change is needed to get this: the engine's API and every
answer are the same, so it arrives with the next Ainalrami release and
the pin bump that follows it. The dominant remaining cost of a late
round is still the alternatives, one forced re-pairing per candidate; on
the 2-vCPU server they run two at a time.

### Where the time was

Measured on v0.33.0 (`tools/perf_bench.exs`,
and OpenPairings' "Pair round" click instrumented span by span):

* **The click was the engine.** OpenPairings' own work - the queries,
  the TRF it builds, writing the round - is 50-120 ms of any click. At
  300 players, round 7, the pairing was 0.3 s of a 3.7 s click and the
  other 3.3 s were the **alternatives**: the "why him and not me"
  accounts OpenPairings stores with every round, one forced re-pairing of
  the whole round per candidate, run one after the other. At 450 players
  in round 2 they were 235 s of 253.
* **Rounds 1 and 2 were the pairing's worst case**, and round 1 with the
  arbiter's "keep clubmates apart" soft wishes the worst of all: 22 s at
  450 players. Rounds 1-2 put whole score groups of 200+ players on the
  field graph, where the refinement stages re-solve the matching from
  cold: stage 4 (exchange weights) and stage 7 (their reset) rewrite
  every remainder pair, and stage 8 re-solves once per player. In the
  club case stage 4 alone was 75% of the round.
* **Inside the matcher**, a sampling profile of a cold solve put ~45% of
  the time in map folds - the stage-start rescans of every free vertex's
  least edge to the outer set, and the cross table rewritten once per
  offer.
* **Everything else** was per-edge work that did not need to be: the
  played-opponent set and bye eligibility recomputed for every candidate
  edge, `colour_stats` twice a round, eighteen criteria folded for pairs
  where only five can be non-zero, and on an odd field a maximum-weight
  matching over the complete graph of the field to find the bye score
  (100 ms of every 300-player explanation).

### What changed, and why it cannot move an answer

Grouped by the argument that makes each one safe.

#### Same values, computed once

* **Per-round player facts** (`Pairing.with_round_facts/1`): who each
  player has met, whether they may take the bye, and how many games they
  played, computed once per player per round instead of once per edge;
  `colour_stats` once instead of twice.
* **Weights outside the bracket** (`outside_edge_weight/6`): a pair
  outside the bracket is weighted from the five rungs that can be
  non-zero there, at the positions the ladder itself reports, instead of
  folding all eighteen. The skipped rungs are gated to zero by
  `in_current`, so the packed integer is the same.
* **`Trf.game_was_played?/1`** answers the common result codes before
  trimming.
* **One explanation context per call** in `Alternatives`:
  `explain_round/3` is now `explain_context/3` (everything that depends on
  the players and options) composed with `explain_pairs/2` (everything
  that depends on the pairs), and a round's alternatives work the context
  out once instead of once per candidate.

These are refactors: the same functions of the same inputs.

#### The same searches, side by side

* **Alternatives run in parallel** (`Alternatives.attempts/1`), one
  forced search per scheduler. Each search is a complete pairing that
  reads nothing but its arguments - the engine's round state lives in the
  process dictionary of whichever process pairs - so each result is the
  value the sequential loop computed; results are collected in order, and
  a search that raises is re-raised in the caller exactly where the loop
  would have raised it. Tracing keeps the sequential order.

#### The matcher, held to v0.33.0 call by call

`Ainalrami.WeightedMatching` is shared by the individual and the team
engines, and it breaks ties by the order edges are offered - so a faster
matcher that finds a *different* optimum of the same weight would be a
different engine. Every change here keeps each tie-break:

* **A root-edge table** (`roots`, `root_min`): at a stage start every
  free vertex whose least edge to the outer set had gone used to walk its
  row, O(V^2) a stage and half of a cold solve. The table keeps each
  non-root's least edge to the exposed roots under a key that stays valid
  while the root stays outer, and is touched only where the root set
  changes.
* **Cross-table writes batched per settling blossom**: the offers of one
  settle are gathered and each touched entry, the settling blossom's row,
  its minimum and the running best written once instead of once per
  offer. An offer only ever replaces an entry by a strictly smaller one,
  and each of those values is a function of the final entries alone.
* **Row minima by a tight scan**, adjacency built a row at a time,
  `cross_retain/2` recomputing a surviving row's minimum once,
  `min_inner_blossom_dual/1` walking only the non-trivial blossoms.

`tools/matching_lockstep.exs` compiles v0.33.0's matcher beside the
working tree and drives both through the same random sessions - solves,
single and bulk weight changes, finalised pairs, dual shifts, reads, on
packed hundred-digit weights, plain weights, heavy ties and complete
graphs - comparing **every return value and every observable field of the
state** (duals, matching, blossoms, their bases, children and matches)
after every call. It detects a flipped tie-break in a single minimum
(mutation-tested). Result: every call identical, state included, over
46,000 sessions of the final matcher.

#### A certificate instead of a search: the bye bootstrap

On an odd field the bye assignee's score came from a maximum-weight
matching over the complete graph of the field. Its two outputs - the bye
score and the first bracket's C9 flag - depend on the optimum only
through three lexicographic quantities: that all but one player are
paired over compatible edges, the leftover's (eligibility, place), and
the number of pairs inside the top group. `certain_bootstrap/7` builds a
matching greedily and checks that it reaches the bound of all three; one
that does is optimal and gives the same answer. Any field it cannot
certify goes to the search exactly as before. Checked against the search
on 19,142 bootstraps before the self-check was taken out.

#### A dual shift instead of a re-solve: stages 4, 7 and 8

The refinement stages rewrite weights and re-solve: stage 4 adds the
exchange weights to every remainder pair, stage 7 takes them off again,
stage 8 adds a per-opponent addend to one player's edges at a time. Each
rewrite prepared every written vertex, and the solve rediscovered a
matching it usually already had. v0.33.0 already absorbed stage 4 on the
local graph by moving dual variables instead
(`WeightedMatching.shift_and_set/3`); now:

* **stage 4** does the same on the field graph when the bracket is
  everything left of the round - round 1, and every round's last bracket;
* **stage 7** moves each paired-down member's dual by what its own pair
  loses; every edge the reset keeps runs from a paired-down player to one
  who is not, so its slack is unchanged;
* **stage 8** raises the player's dual by the addend its current partner
  got.

`shift_and_set/3` checks the optimality conditions on everything the
shift touches - every dual non-negative, every matched edge tight, every
written edge feasible, and every edge of a vertex whose dual went down
(since 2026-10-02 the matcher checks those itself, listed or not; before,
it trusted the caller to list them, which the engine always did and a
direct caller need not have) - and refuses otherwise, in which case the stage re-solves as before. So
the matcher always holds an optimum; the question is whether it could be
a different optimum from the re-solve's, and whether that could show.
What stages 5-8 read from the matching is whether a player is paired
down, and each such read is decided by the weights: stage 4's guard term
fixes the number of exchanges in every optimum; stages 5 and 6 ask each
player's question with a one-unit nudge on even weights, so the answer is
"is there an optimum where this player is (not) paired down" whichever
optimum the matcher holds, and commit it by cutting edges no optimum
still uses; stage 8's addends are distinct per opponent and sit below
every criterion, so every optimum gives the player the same partner. The
one read of a tie is C9's gate for the next bracket, which on an odd
field looks at the carried players' tentative partners in the field below
- which is why the field graph shifts only when there is no field below.
(Tried and measured: allowing it on even fields as well gained nothing on
the bench, so it was left out.)

That is an argument, not a proof by construction like the lockstep; the
differential corpus below is the check, and every one of its rounds that
reaches a last bracket or a local bracket goes through these shifts.

### How it was checked

Every check below ran on the final engine (commit `eb23820`, the
matcher unchanged since `b958b3e`), not on an intermediate one.

#### Differential against v0.33.0: 445,172 rounds, 0 differences

`tools/perf_diff.exs` plays generated tournaments forward
(`Ainalrami.Test.FuzzTournament`, the generator every corpus in this
project uses) and fingerprints, for every round, everything the engine
answers: the pairing - or the refusal, with its reason, excluded ranks,
override and message; `explain_round/3` on it; `explain_round/3` and
`Alternatives.judge/4` on a perturbed pairing (two boards' Black players
swapped, as when an arbiter edits a round); and on a sampled share of
rounds every forced search `Alternatives` runs - float and bye
alternatives at the default cap (and uncapped on small fields),
`force_pair/5` and `no_show/4`. On top of the generator's own knobs, drawn
from a separate random stream, a third of the tournaments carry soft
pairs (either position) and a third of the rounds organiser bye
exclusions. Run once in a v0.33.0 checkout and once on this tree, then
compared line by line:

| set | axis | players | tournaments | rounds | what it adds |
|---|---|---|---|---|---|
| small | s_plain | 4-40 | 6,000 | 51,513 | - |
| | s_byes | 4-40 | 6,000 | 51,136 | 10% byes, 6% forfeits, withdrawals |
| | s_forbid_accel | 4-40 | 6,000 | 51,177 | 10% forbidden pairs, accelerations |
| | s_late | 4-40 | 5,000 | 42,634 | 15% late entrants |
| | s_points | 4-40 | 5,000 | 42,654 | point systems, initial colour, rating modes |
| | s_combined | 4-40 | 8,000 | 67,302 | all of the above, up to 13 rounds |
| | s_tiny_deep | 4-12 | 6,000 | 38,665 | up to 11 rounds on tiny fields |
| | s_late_half | 4-40 | 3,000 | 25,696 | late entrants on half-point byes, Baku |
| flags | f_nofast | 4-60 | 3,000 | 26,119 | every bracket on the field graph |
| | f_strand | 4-40 | 3,000 | 25,619 | completion repair forced |
| | f_completion | 4-40 | 2,000 | 17,160 | the eligibility completion reading |
| large | l_60_120 | 60-120 | 400 | 3,600 | byes, forfeits, forbidden, accelerations |
| | l_150_250 | 150-250 | 150 | 1,501 | point systems, late entrants, up to 11 rounds |
| | l_300_600 | 300-600 | 36 | 396 | 11 rounds, accelerations |
| | | | **70,586** | **445,172** | **0 rounds differing, 0 missing** |

107,106 of those rounds also fingerprinted the alternatives. The rule
readings the engine distinguishes by flag are covered: `AINALRAMI_NOFAST`
(no local graph), `AINALRAMI_FORCE_STRAND`, `AINALRAMI_COMPLETION`.
Before the last engine change three smaller runs held the intermediate
builds to v0.33.0 as well (12,882 + 12,820 rounds at 4-40, 1,080 at
60-200), and 744 round-1 fields of 4-129 players with club soft pairs or
forbidden pairs.

#### The matcher: lockstep with v0.33.0

`tools/matching_lockstep.exs` on the final matcher: 46,000 random
sessions (seeds 700,000-705,999 and 1,000,001-1,040,000) shaped like the
engine's - packed bignum weights with the nearness term, small plain
weights with heavy ties, complete graphs, single-vertex, row and
whole-graph edits, finalised pairs and dual shifts - with every return
value and every observable field of the state equal to v0.33.0's after
every call. Each intermediate matcher commit was held to the same test
before it was committed (up to 30,000 sessions each).

#### Against the references

* **`mix test --timeout 300000`**: 804 tests, 0 failures (5 tags
  excluded by default); `--only interop` (the 209-player real
  tournament, replayed) 2 of 2.
* **bbpPairings, direction 1** (this engine's generated tournaments,
  bbpPairings asked to pair the same history, `mix test --only
  bbppairings`): 3,000 tournaments of 4-40 players over 9 rounds,
  25,255 rounds and 299,216 pairs, and 150 tournaments of 60-160 players
  over 8 rounds, 1,200 rounds and 67,576 pairs - **100.00%, 0 refused, 0
  illegal**, and no disagreement about who is White on 353,711 boards.
* **bbpPairings, direction 2** (`tools/bbp_generator_reverse.exs`: 3,000
  fresh tournaments from bbpPairings' own generator, seeds
  900001-903000, 15-215 players, 5-15 rounds, every round replayed):
  bbpPairings could not generate 10 of them; on the other 2,990,
  **29,854 rounds, 1,730,270 pairs, 0 composition mismatches**, and 0
  colour mismatches on 1,543,847 shared boards.
* **Team Swiss (C.04.6) whole rounds against the brute-force reference**
  (`team_pairing_validation_test.exs`, which shares the matcher):
  909,989 rounds of 4-10 teams (seeds 1-220,000) and 247,976 with no
  colour preferences (seeds 1-60,000), **0 failures**.
* **Bye exclusions against their brute-force reference**
  (`bye_exclusion_validation_test.exs`, seeds 1-10,000): 52,456 rounds,
  **0 disagreements** - the same counts, branch for branch, as the
  release's own run.
* **The bye bootstrap certificate** against the search it replaces:
  19,142 certified bootstraps, all equal, before the self-check was
  removed.


### Tried and reverted

* **A per-solve cache of row lists** in the settle loop, to avoid
  `:maps.to_list/1` per settle: 0.95-1.0x. Reverted.
* **Per-stage vertex views** (tuples for blossom membership and labels):
  2-4% on a cold solve, not worth the second representation. Reverted.
* **The stage-4/7/8 shifts on every bracket of an even field**: safe by
  the argument above (nothing reads the field below's tie on an even
  field), but the first big bracket of round 2 is rarely in the shape the
  shift needs, and the bench showed 1.0x. Left out rather than carried
  for nothing.
* **Not attempted**: skipping the stage-4 re-solve on non-last field
  brackets of odd fields, where C9 reads the tie; certificates of a
  unique optimum for the stage solves; a two-table cross design in the
  matcher. Each would need an argument this pass could not make airtight.

### Reproducing

    # bench, this tree against v0.33.0 in one VM, alternately
    ELIXIR_ERL_OPTIONS="+S 2:2" PERF_REF=v0.33.0 mix run tools/perf_bench.exs

    # matcher lockstep against v0.33.0
    LOCKSTEP_SESSIONS=30000 MIX_ENV=test mix run tools/matching_lockstep.exs

    # differential corpus: the same tool (this tree's copy) run once in a
    # v0.33.0 checkout and once here, for each of small, flags and large
    cd ../v0.33.0-checkout
    MIX_ENV=test mix run ../this-tree/tools/perf_diff.exs corpus small OUT/base/small
    cd ../this-tree
    MIX_ENV=test mix run tools/perf_diff.exs corpus small OUT/new/small
    MIX_ENV=test mix run tools/perf_diff.exs compare OUT/base/small OUT/new/small

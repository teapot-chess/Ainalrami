# Burstein and Lim: where the time goes (2026-11)

A profile of `Ainalrami.Burstein` (C.04.4.2) and `Ainalrami.Lim`
(C.04.4.3) on large fields, and a ranked proposal for making them fast.
**Nothing here changes the engine.** The two prototypes below are
scratch scripts outside the repository, written to measure what each
proposal would buy; the engine code they would replace is unchanged on
this branch.

Engine: main at `7480a29` (the engine code is identical to `1b77a92`,
where the rough timings that started this were taken). Measured on the
80-core VM (`172.16.63.81`), Elixir 1.20.4 / OTP 29, `MIX_ENV=prod`, four
schedulers per job (`+S 4:4`), several jobs at a time on an otherwise idle
box. Every number is one call. Read them as orders of magnitude and
ratios, not as a benchmark.

## The starting point

| players | Dutch | Dubov | Burstein | Lim |
|---|---|---|---|---|
| 300 | 10 ms | 0.3-0.4 s | 10-17 s | 3 s |
| 1000 | 40 ms | 6-7 s | > 5 min (killed), ~1 GB; measured below at 16.5 min | ~2 min |

That rough run used the `Ainalrami.Generator` histories, which never
produce one huge scoregroup. This profile adds that case.

## Method

One round is paired after a history from `Ainalrami.Generator` (nine
rounds, paired by the Dutch engine, then cut to the first *k* rounds). The
Burstein seeding rounds *are* the Dutch system (1.6), so for *k* = 4 this
is exactly the history a Burstein event would have; any legal history is
a valid input to either engine anyway.

* **normal**: the generator's results (FIDE expectancy table, draws at its
  default rate). Round 5 of 300 players has 9 scoregroups, the largest 79;
  at 1000 players the largest is 251.
* **draws**: every played game rewritten as a draw. With an even field
  and no byes, every player has the same score, so the whole field is one
  scoregroup. Rounds 5 and 7 (four and six drawn rounds). This is the
  "big single score group" case the generator never made.

Three instruments, each in its own run:

1. **plain**: wall time and peak memory (`:erlang.memory(:total)` and the
   pairing process's own `memory`, sampled every 50 ms).
2. **trace**: call tracing (`:erlang.trace`, `monotonic_timestamp`) on the
   bracket/group entry points, `WeightedMatching.solve/2`,
   `Dubov.Graph.new/2` and `feasible?/2`, with sizes taken in the match
   spec; plus the matcher's own profile (`AINALRAMI_WM_PROFILE=1`: per
   call site, `new` vs `solve` time, vertices, edges, stages, blossoms,
   bignum weights).
3. **tprof**: `:tprof` call time and call memory over every Ainalrami
   module and the Enum/Map/maps/lists functions they call (300 players).

Scripts: `prof.exs` (the three modes), `proto.exs` and `proto_lim.exs`
(the prototypes), shipped to the VM by `git archive` into
`/root/w-burstein-lim-profile/` and kept there with all logs.

## Results

### Wall time and memory

| system | players | history | groups / largest | round time | peak process / VM |
|---|---|---|---|---|---|
| Burstein | 300 | normal, round 5 | 9 / 79 | 14.6 s | 47 / 106 MB |
| Burstein | 300 | normal, round 7 | 12 / 60 | 9.0 s | 43 / 133 MB |
| Burstein | 300 | **draws**, round 5 | **1 / 300** | 12.7 s | 43 / 126 MB |
| Burstein | 600 | normal, round 5 | 9 / 141 | 128 s | 169 / 408 MB |
| Burstein | 600 | **draws**, round 5 | **1 / 600** | 150 s | 144 / 346 MB |
| Burstein | 1000 | normal, round 5 | 9 / 251 | 988 s (16.5 min) | 625 / 1,141 MB |
| Lim | 300 | normal, round 5 | 9 / 79 | 5.5 s | 32 / 87 MB |
| Lim | 300 | normal, round 7 | 12 / 60 | 5.6 s | 31 / 90 MB |
| Lim | 300 | **draws**, round 5 | **1 / 300** | 18.0 s | 31 / 100 MB |
| Lim | 1000 | normal, round 5 | 9 / 251 | 234 s | 407 / 942 MB |
| Lim | 1000 | **draws**, round 5 | **1 / 1000** | 750 s | 418 / 937 MB |

Burstein grows roughly as n³ (300 to 600: x8.8). Lim at 1000 is slower
here than the "~2 min" of the rough run (other box, other load); the
shape is the same. The all-draws field is *the* bad case for Lim (750 s at
1000) and as bad as the normal one for Burstein.

### Burstein: one cold whole-field matching per trial

`Burstein.Bracket.pair/3` solves each bracket as one maximum-weight
perfect matching of **the bracket and everybody below it** ([C4], [C6]
and [C7] all reach past the bracket). That is by design and is not the
problem by itself: one such solve per bracket costs 0.5 s of the 14.6 s at
300 players. The problem is what follows it. `first_in_order/5` (4.3's
order) fixes BSN 1's opponent, then BSN 2's, trying the largest BSN first,
and every trial that the witness matching does not already answer is a
**fresh `WeightedMatching.solve/2` of the whole remaining field**: a new
edge list filtered by `restrict/3`, a new matcher state built from it, a
solve from an empty matching, and a `Map.new` of every edge to add up the
weight.

| case | round | in `first_in_order` | trial solves | their size (median / max) |
|---|---|---|---|---|
| 300 normal | 14.6 s | 13.8 s (95%) | 290 | 186 / 300 |
| 300 draws | 12.8 s | 12.6 s (99%) | 358 | 300 / 300 |
| 600 normal | 125 s | 121.6 s (97%) | 602 | 372 / 600 |

Per bracket at 600 players (bracket size / players below it / time): 9/591
2.1 s, 31/561 15.9 s, 71/491 32.0 s, **120/372 55.6 s**, 141/231 13.5 s,
121/111 5.1 s, then under a second. The middle brackets cost most: they
are large *and* still have most of the field below them.

Inside those solves, **building the matcher's state costs more than
solving**: at 300 draws, `new` 6.7 s against `solve` 3.3 s; at 600
normal, 63 s against 45 s. The tprof profile agrees: the top entries are
`Map.update/4` (the matcher folding the edge list into adjacency maps),
`Bracket.keep?/4` and `restrict/3`'s filter (10-23 million calls a round),
and `:maps.from_list/1` (the per-solve weight map). Weights are bignums on
almost every large solve (base 2n+3, one digit per score level), which
slows each stage but is not the main cost.

Memory is allocation churn, not a large live set: tprof's call-memory
count for one 300-player round is about 1.2 billion words (~9 GB)
allocated, of which `Map.update/4` alone is 26%; the peak live heap is 47
MB. At 1000 players the edge list alone is ~400,000 tuples with bignum
weights, rebuilt and refiltered on every trial, which is where the ~1 GB
comes from.

**Backtracking**: no blow-up. A trial is one solve; a BSN costs at most
one solve per candidate opponent, and in practice one or two per pair made
(290 trial solves for 150 pairs at 300 players, 602 for 300 at 600). The count is quadratic in the bracket at worst, never
exponential. **List/map copying**: yes, as above, but it is the cost of
rebuilding the graph per trial, and goes away with it.

### Lim: one cold whole-field matching per scoregroup, then per player

Two places, depending on the shape of the field.

**The floater split** (`Lim.Group.floaters/6`, 2.3/3, reading L4/L7): for
every scoregroup above and below the median, one maximum-weight perfect
matching of the group **plus everybody still unpaired** (`outside`), so
that the floaters chosen leave the rest of the round pairable. The weights
are wide: a lexicographic tie digit of 2^position per member (so *m*+1
bits for a group of *m*) under five base-(*m*+1) penalty digits.

| case | round | floater solves | their time | size (median / max) |
|---|---|---|---|---|
| 300 normal | 4.5 s | 8 | 4.0 s (90%) | 250 / 300 |
| 1000 normal | 222 s | 8 | 194 s (87%) | 810 / 1000 |

At 1000 players (group size / outside / time): 11/989 41 s, 51/939 62 s,
130/810 43 s, 183/627 21 s, then 7, 13, 7 and 2 s upward. Eight solves of
450-1000 vertices, 330,000 edges and ~360 stages each, on 300-bit weights.
That is why Lim's time grows with the field and not with forbidden pairs:
each group's choice of floaters is answered over the whole rest of the
field.

**The pairs** (`Lim.Group.pairs/5`, 2.4/4/5.2, readings L5/L6): the
scrutiny walk fixes one player's partner at a time and checks each trial
with a cold solve of the group. Cheap for the generator's groups
(0.35 s of the 300-player round), and the whole cost when the group is the
field: at 300 draws, 630 solves of 300 vertices, 17.9 s; at 1000 draws,
750 s. Same pattern as Burstein's `first_in_order`, on a smaller graph.

Graph construction (`Dubov.Graph.new/2`, the bitmask adjacency) is 30 ms
at 300 and 300 ms at 1000: not a factor for either system. The bye
(`assign_bye/2`) is milliseconds.

## Proposal

Ranked by measured gain per unit of risk. Gains for 1 and 2 are measured
with the prototypes; 3 and 4 are estimates.

### 1. Both systems: one persistent matcher per walk, with dual pruning

**What.** In `Burstein.Bracket.first_in_order/5` and `Lim.Group.walk/7`,
keep the solved `WeightedMatching` state instead of the edge list:

* a trial "fix *i* to *j*" (or "float *i*") becomes
  `WeightedMatching.set_weight(state, i, x, 0)` for the edges it removes,
  then `WeightedMatching.solve(state)` - a warm re-solve from the
  previous optimum, the path the Dutch engine's bracket cascade already
  uses (`finalize_pair/3`, `set_weight/4`);
* an accepted choice the witness already makes is locked with
  `finalize_pair/3` (no re-solve), falling back to the drop-and-solve
  path when it refuses;
* before trying a choice, read `WeightedMatching.possible_partners/3` on
  the current optimum: a choice whose edge is not tight under the optimal
  dual cannot be in any maximum-weight matching, so it is skipped without
  a solve.

**Measured** (prototype `proto.exs` / `proto_lim.exs`, same inputs,
answers compared bracket by bracket and group by group):

| system | case | now | prototype | gain | solves / pruned / failed |
|---|---|---|---|---|---|
| Burstein | 300 normal r5 | 12.3 s | 1.13 s | 11x | 146 / 144 / 34 |
| Burstein | 300 normal r7 | 8.2 s | 1.27 s | 6x | 172 / 40 / 54 |
| Burstein | 300 draws r5 | 12.1 s | 0.65 s | 19x | 81 / 209 / 0 |
| Burstein | 600 normal r5 | 117 s | 8.7 s | 13x | 393 / 220 / 167 |
| Burstein | 600 draws r5 | 150 s (engine) | 4.6 s | 33x | 154 / 1,023 / 0 |
| Burstein | 1000 normal r5 | 988 s (engine) | 37 s | 27x | 527 / 773 / 125 |
| Lim pairs | 300 draws r5 | 16.6 s | 0.99 s | 17x | 146 / 481 / 0 |
| Lim pairs | 600 draws r5 | 319 s | 5.4 s | 59x | 173 / 1,003 / 0 |
| Lim pairs | 1000 normal r5 | 33.7 s | 1.7 s | 20x | 473 / 1,115 / 21 |

("now" for Burstein is the engine's own bracket code timed in the same
script; for Lim, the engine's calls as traced.) Every bracket and group
identical. Pruning removes about half the trials on normal fields and
most of them on the single group; warm re-solves make the rest a few
stages each instead of a fresh build.

**Why it cannot change a pairing.** The walk's answer is "the first
choice, in the article's fixed order, for which *some* matching still
reaches the optimum value". That depends only on the optimum *value* of
each restricted graph, which is unique, never on which optimal matching
the matcher returns. A warm solve and a cold one of the same graph have
the same optimum value. Pruning skips only choices whose edge has positive
reduced cost under an optimal dual; by complementary slackness no maximum
weight matching uses such an edge, so the skipped trial would have failed.
The witness shortcut already in the code relies on the same fact. What is
left is implementation risk (a restriction not applied, a stale witness),
which is what the corpus below is for.

**Risk.** Low. The matcher entry points are the ones the Dutch engine
already drives hundreds of times a round, held step by step to a previous
release by `tools/matching_lockstep.exs`. `possible_partners/3` is already
used by the Dutch engine's certified shortcuts. One trap the prototype
met: `set_weight/4` *prepares* its first vertex (unmatches it), so after a
witness-accepted choice the state must either be locked by
`finalize_pair/3` or re-solved before its duals are read; reading duals of
a prepared state would make pruning unsound.

**Effort.** 1-2 days each system, plus the corpus run.

### 2. Lim: the floater split on the group alone, checked against the rest

**What.** In `Lim.Group.floaters/6`, solve the split on a graph of the
group's *m* members plus *m* "float" vertices instead of the group plus
everybody unpaired:

* member-member edges as now (a pair of the group);
* member-to-float edges only for a member with at least one compatible
  player outside the group, weighted with that member's float value as
  now (the value never depended on *which* outside player);
* float-float edges at the base unit, so unused float vertices pair off.

That is a relaxation: every split the current matching can reach is
reachable here, with the same value. Take its optimum *F* (unique, because
of the 2^position digit) and check that the players outside plus *F* can
be paired **with no two members of F meeting** (`Graph.perfect_restricted?/3`,
one cardinality matching). If yes, *F* is optimal for the original problem
too, and it is the same set; if no, fall back to the current full solve.

**Measured** (`proto_lim.exs`):

| case | now (floaters) | prototype | gain | fallbacks |
|---|---|---|---|---|
| 300 normal r5 | 3.95 s | 0.12 s | 33x | 0 |
| 300 normal r7 | 4.45 s | 0.09 s | 47x | 0 |
| 600 normal r5 | 31.8 s | 0.76 s | 42x | 0 |
| 1000 normal r5 | 258 s | 2.4 s | 107x | 0 |

With proposal 1 for the pairs, the 1000-player normal round goes from
~290 s (traced) to about 4 s; the 600-player all-draws round from 319 s to
5.4 s. The small-field sweep below took the fallback in 100 of 750 rounds,
every time with the same answer.

**The trap, found by the prototype's own review, not by a failure.** The
first version checked "outside plus F pairable" with an ordinary
feasibility test. That accepts a pairing of the rest that puts two
floaters against each other, which in the original problem would be a
pair *of the group*, not two floaters. No test round hit it, but it is
unsound; the check must forbid floater-floater pairs.

**Risk.** Low to medium. Exact by the relaxation argument, with a
fallback to today's code whenever the argument does not apply; the
medium is for the parity and tie-break details of the float vertices,
which the corpus has to exercise (forbidden-pair-heavy and deep rounds of
small fields, where the fallback fires).

**Effort.** 1-2 days.

### 3. Burstein: the same relaxation for the players below the next scoregroup

**What.** In `Burstein.Bracket.pair/3` the vertices below the next
scoregroup (`L` minus `R2`) enter the weights only through "this bracket
or next-scoregroup player floats into L", and the value of that depends
on the floater's own score, never on which `L` player takes them. Replace
them by float vertices as in proposal 2, solve on bracket + `R2` + floats,
and accept when `L` plus the players sent into it can be paired with none
of those players meeting each other; otherwise the current solve.

**Expected.** After proposal 1, Burstein at 1000 players still spends its
time building graphs over the whole remaining field for each bracket (37 s
in the prototype). This cuts the graph from ~n to bracket + next group +
floats, so the early and middle brackets shrink 3-10x in vertices and
more in edges. Estimate: a further 3-5x at 600-1000 players; little on the
single-group case, which has no `L`. Not prototyped.

**Risk.** Medium. [C7]'s second part (the next bracket's floaters into
`L - R2`, by score) must survive the relaxation exactly; the argument is
the same as proposal 2's but has more digits to get right.

**Effort.** 2-3 days.

### 4. Constant factors

* Add the weight of a matching with `WeightedMatching.edge_weight/3` (or
  carry it from the solve) instead of a `Map.new` of every edge per solve
  (`Bracket.solve/2`, `Group.solve/2`): `:maps.from_list/1` is 6% of a
  Burstein round.
* Hand the matcher `:adjacency` directly where the graph is built from a
  bitmask anyway, skipping the edge list (as the Dutch engine's bye
  bootstrap does).
* Burstein's digits: a mixed radix with each digit's real bound instead of
  base 2n+3 for all keeps more solves under 60 bits.

Expected 10-30% on top of 1-3. Risk low; the first two do not touch any
value, the third changes weights but not their order (provable digit by
digit, and checkable on the corpus). Not worth doing before 1-3.

### Not proposed

* **Parallel trials.** Independent trials of one BSN could run
  concurrently, but after proposal 1 most trials are pruned and the rest
  are cheap warm solves; parallelism would add nondeterminism risk for a
  small gain.
* **Changing the readings** (L4's order, B5's look-ahead) for speed: out
  of scope; the readings are documented decisions.

## Proving the pairings identical

A speed change is accepted only with **byte-identical answers** to the
current code on a large corpus, refusals included.

1. **Fingerprints.** Extend `tools/perf_diff.exs` (today Dutch only) with
   `--system burstein|lim`: per round, a SHA-256 over the deterministic
   external form of the whole answer - pairs with colours, the bye,
   every bracket's or group's floaters and BSN list, or the refusal and
   its reason. Run the same corpus in a checkout of the old tag and of
   the branch; `perf_diff.exs compare A B` must report zero differences.
2. **Corpus**, on the VM (own `/root/w-<branch>/`, at most 12 schedulers
   per job):
   * the validation event shapes (`BursteinEvents`, `LimEvents`: byes,
     forfeits, late entrants, withdrawals, Baku, 3-1-0, forbidden pairs,
     both initial colours), 4-40 players, 200,000 events each, every
     round;
   * `Ainalrami.Generator` fields of 60-300 players, normal and draw-heavy
     results, forbidden pairs at 0% and 40%, 2,000 events each, rounds 5-9;
   * the single-scoregroup case explicitly: the all-draws rewrite at
     50-600 players, rounds 3-9, 500 positions;
   * a few dozen 600-1000 player rounds (only affordable after the
     change; the old build is run once on them, offline).
3. **Both paths in one build.** During the corpus run, an environment
   switch (as `AINALRAMI_CERT=force` does for the Dutch shortcuts) runs the
   old walk and the new one on every bracket and raises on any
   difference. This localises a difference to the bracket that made it,
   which a round fingerprint cannot.
4. **Sensitivity.** A two-arm run: one arm with a deliberately broken new
   path (for example, pruning on a stale dual), to show the corpus can see
   a difference at all. The project has had instruments that were blind
   before (`docs/validation.md`, "Four instruments were broken or blind").
5. **The references stay at zero.** `tools/burstein_validation_run.exs`
   and `tools/lim_validation_run.exs` (570,661 and 1,012,508 rounds against
   the brute-force readings) are re-run on the new code; the matcher is
   untouched, so `tools/matching_lockstep.exs` needs no change.

## The prototypes, checked

Both prototypes compared their answer with the engine's on every bracket
or group they touched:

| run | fields | rounds | brackets/groups identical |
|---|---|---|---|
| Burstein, large | 40-1000 players, normal and draws, rounds 5 and 7 | 17 | all |
| Lim, large | 40-1000 players, normal and draws, rounds 5, 7 and 8 | 21 | all |
| small sweep, Burstein | 12-50 players, rounds 6, 8 and 9, forbidden pairs 0% and 40%, 25 seeds | 750 | all |
| small sweep, Lim | the same | 750 | all; the fallback of proposal 2 taken in 100 rounds |

The prototypes are evidence for the size of the gain and for the
argument, not a substitute for the corpus above: they run on even fields
only; `proto.exs` re-implements only Burstein's bracket loop, without the
bye and without forbidden pairs in its compatibility graph; the large runs
use one seed per size. The large Lim runs at 300, 600 and 1000 players
were repeated with the corrected floater check of proposal 2, with the
same results.

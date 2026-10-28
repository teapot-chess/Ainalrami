# Pairing proofs

Every pairing this engine publishes rests on weighted matchings: the
Dutch rules (C.04.3) are turned into packed integer weights, a
maximum-weight matching is found, and the bracket is read off it. A wrong
matcher does not produce an illegal pairing that a legality check would
catch; it produces a legal-looking pairing that simply is not the best one.
The corpora in `docs/validation.md` catch that statistically, against other
engines. This is the other half: a certificate, emitted with the round,
that each matching the engine computed while pairing it is a maximum-weight
matching of the graph it was given, checkable by a small program that
shares no code with the engine.

    ainalrami round.trf -p pairs.txt --proof=round.proof.jsonl
    elixir tools/verify-proof/verify.exs round.proof.jsonl

or, from the library, `Pairing.pair_next_round(players, proof: fn line -> ... end)`.

This document says exactly what is proven, what is trusted, and what is not
covered. It was written before most of the code and corrected where the
code found it wrong; the corrections are marked.

## The claim

A round's certificate proves:

> Every weighted-matching solve the engine ran while pairing this round on
> the **reference path** returned a maximum-weight matching of the graph
> the certificate lists for it.

and the engine states (not proves; see below) that the reference path
produced the same pairing as the one it published.

It does **not** prove that the pairing is the FIDE pairing, nor that it is
the one bbpPairings would produce. Those rest on the parts listed under
"Trusted".

### Proven, solve by solve

For each solve the certificate carries the graph (vertices `0..n-1`,
positive integer edge weights), the matching `M`, and a dual solution in
the textbook form of Edmonds' matching polytope: a value `y[v] >= 0` per
vertex and a list of odd vertex sets `S` with values `z[S] >= 0`. The
verifier checks, with nothing but integer arithmetic:

1. `M` is a matching of the graph (no vertex twice, every pair an edge).
2. `y >= 0`, `z >= 0`, every set has an odd number of distinct vertices.
3. Every edge has reduced cost
   `rc(u, v) = y[u] + y[v] + sum(z[S] : S holds u and v) - w(u, v) >= 0`
   (dual feasibility; a non-edge has weight 0 and a non-negative reduced
   cost automatically).
4. Every edge of `M` has `rc = 0`.
5. Every vertex with `y > 0` is matched.
6. Every set with `z > 0` holds exactly `(|S| - 1) / 2` edges of `M`.

1-3 give weak duality for any matching `M'`: `w(M') <= sum(y) + sum(z[S]
* (|S| - 1) / 2)`. 4-6 are complementary slackness and make that bound
equal to `w(M)`. So no matching of the graph weighs more than `M`. The
verifier computes both sides and checks they are equal as a cross-check.
This is linear-programming duality over the matching polytope, which is
exactly why Edmonds' algorithm keeps blossom duals: a vertex-only dual
cannot certify an odd structure (a triangle of equal weights needs its odd
set; `test/ainalrami/proof_test.exs` has that example).

Weights and duals are on the matcher's internal doubled scale (`w2 = 2w /
gcd`); every number in a check is multiplied by the same positive factor,
so the scale changes nothing and is reported only as `scale`.

### Trusted

* **The weight function.** That the packed weights faithfully encode
  C.04.3's criteria, in priority order. The certificate carries the
  weights; the verifier takes them as given. (See "Where the weights come
  from" for the stronger option and why it is phased.)
* **The control flow.** Which graphs the engine builds, in which order,
  and how it reads each matching: the bracket sequence, the eight
  refinement stages and their weight edits, the pair locks. The proof
  certifies the answer to each question the engine asked the matcher, not
  that it asked the right questions.
* **Ties.** Where several maximum-weight matchings exist, the matcher
  returns the one its search finds (bbpPairings' order, held to a
  previous release call by call by `tools/matching_lockstep.exs`). The
  certificate proves the returned matching is optimal, not that it is the
  optimum bbpPairings would have returned.
* **The agreement.** The published pairing comes from the engine's fast
  path; the certified solves come from pairing the round again on the
  reference path (below). The certificate's `"agrees": true` is the
  engine's comparison of the two; the verifier cannot recompute it without
  a second implementation of the pairing rules. A `false` is reported by
  the verifier as a FAIL.
* **Completeness of the record.** That every solve was written down. The
  verifier checks every solve it is given and cannot see one that is
  missing.

### Not covered

These decisions carry no dual certificate and are counted, by name, in the
certificate's `"uncertified"` map. The verifier prints the counts and does
not judge them.

* **Completability questions** (`cardinality_maximum`,
  `cardinality_augment`, `cardinality_exposable`): whether the rest of the
  field can still be paired, asked of an unweighted maximum-cardinality
  matcher. A maximum-cardinality matching has a certificate of its own (a
  Tutte-Berge / Gallai-Edmonds witness), but this matcher does not keep
  one; adding it is the obvious next step and is not done here. They are
  few on the reference path: median 2 per round in the corpus below,
  90th percentile 6, at most 14 (beside an average of 29 certified
  solves per round).
* **The direct and small brackets, and the certified shortcuts**, on the
  path the round is published from. See "Which solves need certificates".

## Which solves need certificates

A round is not one matching. On the reference path (bbpPairings'
algorithm, which this engine ports), each score bracket is decided by a
sequence of solves of the whole-field graph: an initial solve with the
bracket's criteria packed into the weights, then up to eight refinement
stages that edit weights (stage addends, exchange weights, "prefer the
higher partner" addends) and solve again, then locks that fix the
bracket's pairs before the next bracket starts. Completion and look-ahead
(can the rest still be paired, C.04.3 C4/C8) are part of the packed
weights. The bye falls out of the last bracket's matching. Every one of
those solves is a question whose answer the next step reads, so every one
needs a certificate; the certificate has one entry per solve, in order.

Three kinds of entry:

| kind | written when | claim |
|---|---|---|
| `solve` | `WeightedMatching.solve/1` returns | `M` is a maximum-weight matching |
| `shift` | `WeightedMatching.shift_and_set/3` accepts a dual shift (stages 4, 7 and 8 rewrite weights by moving duals instead of re-solving, and stage 8 reads the result without a solve) | the same |
| `window` | `MatchCertificate.certify/5` finds a certificate (the certified shortcuts) | the same, and, when a `"window"` is listed, every maximum-weight matching gives each window vertex the partner (or the exposure) `M` gives it |

`finalize_pair/3` (a pair lock that drops the locked players' other edges)
is not recorded on its own: dropping unmatched edges from an optimal state
can only keep it optimal, and the next solve on that state is recorded.

### Why the proof is taken on the reference path

**Correction (found while building it).** The design started from the
round as published: record whatever the engine solves. The first
30-player round recorded **zero** solves. Since v0.36 nearly every bracket
is answered by the direct walk, the small-bracket enumeration or a
certified shortcut (`docs/performance.md`, "The direct bracket"), none of
which runs a weighted matching:

* the **direct walk** is a depth-first search that accepts the first
  matching meeting an upper bound on every criterion at once. Its proof of
  optimality is that bound argument, made once in the source and checked
  by the differential corpora - not a per-instance object that could be
  written down and checked independently.
* the **small bracket** lists every maximum-weight matching of a graph of
  at most 12 vertices and filters them. Its per-instance certificate would
  be the whole list, plus a proof that the list is complete.
* the **certified shortcuts** do hold per-instance LP certificates
  (`Ainalrami.MatchCertificate`, vertex duals plus a fixed blossom family,
  with a strictness condition that makes the answer unique on a window).
  They are recorded, as `window` entries, and the verifier checks the
  window condition too (`test/ainalrami/proof_test.exs` forces the
  shortcuts on and checks every one). But they cover a handful of reads
  per round, between direct answers that cover the rest.

So a certificate of the round as published covers almost nothing. The
proof option therefore pairs each round twice: once exactly as without
the option (that is the pairing returned and written, byte for byte), and
once on the reference path - `AINALRAMI_CERT=off`, `AINALRAMI_DIRECT=off`,
`AINALRAMI_NOFAST=1`, set for that call only (`Ainalrami.Proof.reference_flag/1`),
so every bracket is decided by the refinement stages on the whole field
graph, each reading a weighted matching. That second pairing is the one
recorded, and the two are compared. The shortcuts are held to exactly
this path by the differential corpora (`docs/performance.md`) and by
`test/ainalrami/direct_bracket_test.exs` on every `mix test`; the proof
repeats the comparison on the round at hand.

The cost is the reference path's time, which is the engine as it was
before the shortcuts: see "Overhead".

### The one-exposed dual

The matcher sometimes leaves a state with exactly one exposed vertex `x`
at a positive dual `xi` (after a certified install, `WeightedMatching.install/3`).
That is not the textbook form - an exposed vertex must have `y = 0` - but
it is the same dual read differently: every live vertex's `y` lowered by
`xi`, and `2 * xi` on the odd set of all live vertices (odd, since `M`
covers all of them but `x`). The recorder writes it in that form, so the
verifier needs one rule set.

## Where the weights come from

Two ways for a verifier to get the edge weights:

* **Carried.** The certificate lists them. Simple, and enough to prove the
  matcher right; it trusts the weights.
* **Recomputed.** The verifier recomputes them from the TRF and the
  published weight rules, so it also checks that the weights encode
  C.04.3.

**Recommendation: carry now (done), and recompute in phases.** The second
option is harder than it looks, because the graphs are not a function of
the TRF alone. Only the first solve of a bracket has weights that are
"the C.04.3 weight of this pair"; every later one carries the stages' edits
(addends that depend on the previous solve's answer) and the locks of the
brackets before it. Recomputing them needs the stage algorithm, which is
the pairing engine. So:

1. **Carried weights** (this version). Proves the matcher, trusts the
   weights and the control flow.
2. **Recomputed bracket weights.** Tag each `solve` with its bracket and
   stage, and specify the initial bracket weight (the packed criteria,
   C.04.3 C1-C21 and the completion rung) as a document a second
   implementation can follow. The verifier then recomputes the first
   graph of every bracket from the TRF and compares; the stages' edits
   stay carried and trusted. This turns "the weights are faithful" into a
   checked statement for the part of the weight that carries the rules.
3. **Recomputed stages.** A verifier that also replays the stages is a
   second engine. The three-way harness (`docs/validation.md`) already
   plays that role statistically; a per-round version of it is out of
   scope for a page of code that a commission member reads in an
   afternoon.

## The format

JSON Lines: one line per round (one per pairing group in a grouped event),
gzipped when the file name ends in `.gz` (the verifier accepts either).

    {"format": "ainalrami-pairing-proof", "version": 1,
     "engine": "ainalrami 0.47.0", "path": "reference",
     "round": {"players": 30, "agrees": true, "pairs": [[26, 10], ...]},
     "uncertified": {"cardinality_maximum": 1},
     "solves": [
       {"id": 0, "kind": "solve", "n": 30, "scale": 1,
        "graph": {"edges": [[0, 1, "2490..."], ...]},
        "matching": [[0, 3], ...],
        "duals": [[0, "2490..."], ...],
        "sets": [{"vertices": [4, 7, 9], "z": "12"}, ...]},
       {"id": 1, "kind": "solve", "n": 30, "scale": 1,
        "graph": {"base": 0, "set": [[3, 8, "0"], [5, 6, "2490..."]]},
        ...}]}

* Vertices are the solve's own indices (positions in the field graph),
  not starting ranks; `round.pairs` gives the published pairing in
  starting ranks (`null` for a refused round, with the reason).
* Weights, duals and set values are decimal strings: they are integers of
  any size (50-170 digits in practice - the criteria are packed into one
  number).
* A graph is given in full (`edges`), or as an earlier solve's graph of the
  same round (`base`) with some edges changed (`set`, weight `"0"` for a
  removed edge). A round's solves mostly differ by a few edges, and the
  full graph at 1,000 players has half a million.
* Missing duals are 0; sets with `z = 0` are left out.
* `window` (on `window` entries only): the vertices the uniqueness claim is
  made for. The verifier adds two checks: every edge not in `M` with an
  end in the window has `rc > 0`, and every edge of `M` at a window vertex
  has an end with `y > 0` (both ends in the window), or the window end does
  (one end). Complementary slackness then pins every optimum to `M` on the
  window.

## The verifier

`tools/verify-proof/verify.exs`: one Elixir script, standard library only
(Elixir 1.18+ for the built-in `JSON`), no code shared with the engine and
no `Ainalrami` module referenced. About 530 lines, most of them the checks
above and their messages; the header comment is the proof.

    elixir tools/verify-proof/verify.exs FILE [--summary]

prints PASS or FAIL per solve, with the reason for a FAIL ("matched edge
(3, 7) is not tight: reduced cost 2"), and the uncertified counts per
round; exit code 0 when everything passes, 1 on any FAIL, 2 when the file
is not a proof.

`tools/verify-proof/tamper.exs FILE` takes a round from a proof, checks the
verifier passes it, then changes one thing at a time - a matched edge's
weight, a matched vertex's dual, one pair removed from the matching, two
pairs' partners swapped, a set's dual - and checks the verifier fails each.
The same tampers run in `test/ainalrami/proof_test.exs`.

## Overhead

**Off.** The option changes nothing when it is off: the pairing path is
the same code with three process-dictionary reads added (one per matcher
solve, one per shortcut counter, one per engine switch read at a round's
start), each answering "not recording". Measured, not argued: see
"Evidence" for the differential against v0.47.0 and the timing table
below for the off column on both builds.

**On.** The round is paired twice (as published, then on the reference
path while recording), so the cost is the reference path plus the
recording. The reference path is the expensive half: it is the
whole-field matcher run for every bracket, which is exactly the work the
engine's shortcuts exist to avoid.

Per round, averaged over the corpus axes below (one desktop, 16
schedulers, the axes run several tournaments at once, so the absolute
times are loaded ones; the ratio is the point):

| axis | players | off | on | proof size, mean (max) |
|---|---|---|---|---|
| p_tiny | 4-12 | 1.4 ms | 3.0 ms | 6 KB (19 KB) |
| p_small | 3-40 | 5.7 ms | 17 ms | 50 KB (225 KB) |
| p_mixed | 6-150 | 23 ms | 0.70 s | 1.1 MB (5.3 MB) |
| p_150_300 | 155-295 | 13 ms | 5.4 s | 8.6 MB (17 MB) |
| p_400_1000 | 414-996 | 20 ms | 81 s (max 328 s) | 90 MB (222 MB) |

The off column against the release without the option, single positions
(round 6 of a generated event, median of 3-5, nothing else running,
`tools/proof_bench.exs` run unchanged in both checkouts; the branch was
run twice to show the noise):

| players | v0.47.0 | branch | branch, again |
|---|---|---|---|
| 30 | 4.1 ms | 4.3 ms | 4.1 ms |
| 100 | 9.2 ms | 9.6 ms | 9.9 ms |
| 200 | 11.3 ms | 11.4 ms | 11.2 ms |
| 400 | 21.0 ms | 24.8 ms | 21.8 ms |
| 600 | 28.3 ms | 28.7 ms | 28.9 ms |
| 1,000 | 43.2 ms | 47.0 ms | 45.4 ms |

`tools/proof_bench.exs DIR proof` adds the reference path alone and the
proof for the same positions; at a thousand players a proof took about
three minutes and 280 MB during development.

Proofs compress well (the graphs repeat from solve to solve); `.gz` takes
about nine tenths off.

The verifier is linear in the size of the proof: about 2 s for a
290-player round (3.7 MB) and 4 s for a 422-player round (22 MB),
both including the BEAM's start-up, and under two minutes for a
thousand-player round of 280 MB. It keeps a graph only
while a later solve still names it as a base; keeping them all took 27 GB
on a thousand-player round and is how that was found.

## Evidence

Measured 2026-10-28 on the branch that added the option, on a desktop.

**The option off changes nothing.** `tools/perf_diff.exs corpus small`
(8 axes x 250 fuzz tournaments: byes, forbidden pairs and acceleration,
late entrants, point systems, tiny deep fields) paired by v0.47.0 and by
this branch: 16,589 rounds, 0 differing, 0 missing on either side, 3,912
of them with their alternatives fingerprinted as well.

**The option on changes nothing either, and every certificate verifies.**
`tools/proof_corpus.exs` pairs every round of every fuzz tournament with
the option off and on, compares the two, and runs the verifier on the
proof in-process:

| axis | tournaments | rounds | players | solves verified | failed | `agrees` false | on != off |
|---|---|---|---|---|---|---|---|
| p_tiny | 500 | 3,717 | 4-12 | 36,483 | 0 | 0 | 0 |
| p_small | 1,500 | 12,758 | 3-40 | 222,771 | 0 | 0 | 0 |
| p_mixed | 1,000 | 8,940 | 6-150 | 466,234 | 0 | 0 | 0 |
| p_150_300 | 40 | 200 | 155-295 | 23,909 | 0 | 0 | 0 |
| p_400_1000 | 12 | 36 | 414-996 | 12,476 | 0 | 0 | 0 |
| **total** | **3,052** | **25,651** | | **761,873** | **0** | **0** | **0** |

The uncertified completability questions over the same rounds: median 2
per round, 90th percentile 6, maximum 14.

**The verifier is not a rubber stamp.** `tamper.exs` on a corpus round:
the untouched round passes; a matched edge's weight, a matched vertex's
dual, a removed pair and two swapped partners each fail. The test suite
does the same on ten rounds, checks a hand-made triangle that needs its
odd set (and fails without it, and with an even set), and a 4-cycle whose
window claim is refused because the tie is real.

## Reproducing

    # the corpus: every round paired with the option off and on, compared,
    # and every certificate checked by the verifier
    MIX_ENV=test mix run tools/proof_corpus.exs DIR

    # the off path against a release without the option (run in both)
    MIX_ENV=test mix run tools/perf_diff.exs corpus small DIR
    MIX_ENV=test mix run tools/perf_diff.exs compare DIR_A DIR_B

    # single positions
    mix run tools/proof_bench.exs DIR proof
    elixir tools/verify-proof/verify.exs DIR/1000.jsonl --summary

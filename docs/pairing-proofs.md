# Pairing proofs

Every pairing this engine publishes rests on matchings: the Dutch rules
(C.04.3) are turned into packed integer weights, a maximum-weight matching
is found, and the bracket is read off it; along the way unweighted
matchings answer whether the rest of the field can still be paired. A
wrong matcher does not produce an illegal pairing that a legality check
would catch; it produces a legal-looking pairing that simply is not the
best one. The corpora in `docs/validation.md` catch that statistically,
against other engines. This is the other half: a proof, written with the
round, that every matching question the engine asked while pairing it was
answered correctly, and that the published boards are the answers it read
- checkable by a small program that shares no code with the engine.

    ainalrami round.trf -p pairs.txt --proof=round.proof.jsonl
    elixir tools/verify-proof/verify.exs round.proof.jsonl

or, from the library, `Pairing.pair_next_round(players, proof: fn text ->
... end)` (the whole round's proof as one string) or `proof: {:stream, fn
line -> ... end}` (one line at a time, as the CLI writes it).

This document says exactly what is proven, what is trusted, and what is
not covered. It was written before most of the code and corrected where
the code found it wrong; the corrections are marked.

## The claim

A round's proof establishes, for the round as paired on the **reference
path** (below):

1. Every weighted-matching question the engine asked was answered with a
   maximum-weight matching of the graph the proof lists for it.
2. Every unweighted "can the rest still be paired" question was answered
   correctly: a "yes" comes with the matching or the augmenting path, a
   "no" with a Tutte-Berge barrier that rules every matching out.
3. The published boards are **exactly** the pairs the brackets read off
   those proven matchings, and no player sits at two boards. That the
   published round and the reference path agree is a checked fact, not a
   flag the engine reports.
4. Each published board is either **forced** - its pair is in every
   maximum-weight matching of its graph, so no tie-break could have
   changed it - or one of several optima, chosen by the tie-break. The
   verifier says which, per board.

It does **not** prove that the pairing is the FIDE pairing, nor that it is
the one bbpPairings would produce. Those rest on the parts listed under
"Trusted".

### Proven: weighted questions

For each weighted solve the proof carries the graph (vertices `0..n-1`,
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

**Forced pairs.** The same dual decides which pairs of `M` are in every
optimum. Complementary slackness holds between this dual and *any*
maximum-weight matching `M'`: `M'` uses only edges with `rc = 0` and
covers every vertex with `y > 0`. So when a pair `(u, v)` of `M` has an
end with `y > 0` whose only `rc = 0` edge is `(u, v)`, every optimum
contains it. The verifier computes this for every pair a bracket reads
and counts the published boards that are forced.

### Proven: completability questions

**New in format 2.** The engine also asks an unweighted
maximum-cardinality matcher whether the rest of a bracket can still be
paired. Each answer is a `cardinality` record with a witness. With `G` the
graph (minus the vertices the question excludes, plus the matching's own
pairs), and `odd(X)` the components of odd size of `G` with the vertex set
`X` removed, the Tutte-Berge formula says every matching leaves at least
`|odd(X)| - |X|` vertices exposed, for any `X`: each odd component keeps a
vertex exposed or sends one into `X`.

| claim | the engine's answer | the witness and what the verifier checks |
|---|---|---|
| `maximum` | `M` is a maximum matching | a barrier `X` with `vertices - 2|M| = |odd(X)| - |X|`: the lower bound on exposed vertices, met |
| `not_exposable` | no maximum matching leaves exactly one vertex over | the same, with that deficiency not 1 |
| `exposable` | these are exactly the vertices some maximum matching leaves over | `M` maximum with deficiency 1 (barrier as above); the set is exactly the union of `odd(X)`'s components (every maximum matching exposes inside them, by the bound); and each vertex of it has an even alternating path from the exposed root, walked by `parent` links |
| `augment` | an augmenting path from `root` exists | the path: exposed to exposed, alternating non-`M` / `M` edges of `G`, no vertex twice |
| `blocked` | none exists: no matching covers `root` and every vertex `M` covers | a barrier `X` such that more components of `odd(X)` lie wholly inside those vertices than `X` has members |

The matcher already computes everything the witnesses need - a failed
Edmonds search leaves its inner vertices, which are the barrier; the
union of the outer sets of the searches from each exposed vertex is the
Gallai-Edmonds `D(G)`, and its neighbourhood is the barrier - so writing
them down costs a sort and a few lists. A proof's `"uncertified"` map,
which in format 1 counted these questions (median 2 a round, at most 14),
is now empty on every round of the corpus below, and the corpus fails a
round where it is not.

On the reference path the questions asked are `maximum`, `augment` and
`blocked`. `exposable` and `not_exposable` come from a shortcut of the
odd-field bootstrap (the matching that fixes the bye's score) which the
reference path no longer takes: there the bootstrap runs its weighted
matching, which is certified like any other. The two claims are still
checked whenever they are recorded, and the tests hand-build both.

### Proven: the published boards

Each time a bracket on the reference path takes pairs from a weighted
matching, it writes a `read` record: the record id of the matching, and
for each pair its two vertices and the two players' starting ranks. The
verifier checks every read pair is a pair of that record's matching (and
that the record passed), then compares the reads with the round's
published boards: each published board must have been read, each read
pair must be published, and no player may appear twice. A bye is the
player the boards leave over, the same on both sides.

So the round as published - from the fast path, by the direct walk, the
small-bracket enumeration and the certified shortcuts - is shown equal,
board for board, to pairs read off proven-optimal matchings. Format 1 had
the engine compare the two and report `"agrees"`; the flag is still
written in the `end` record, and the verifier no longer needs it.

### Trusted

* **The weight function.** That the packed weights faithfully encode
  C.04.3's criteria, in priority order. The proof carries the weights;
  the verifier takes them as given. (See "Where the weights come from"
  for the stronger option and why it is phased.)
* **The control flow.** Which graphs the engine builds, in which order,
  and what it does with each answer: the bracket sequence, the eight
  refinement stages and their weight edits, the pair locks, and which
  completability question it asks when. The proof certifies the answer
  to each question the engine asked, not that it asked the right ones.
* **The tie-break.** Where several maximum-weight matchings exist, the
  matcher returns the one its search finds first - bbpPairings' order,
  held to a previous release call by call by `tools/matching_lockstep.exs`.
  That choice is **trusted, not checked**; what the proof adds is the
  line between the two cases: a forced board could not have been
  otherwise, a board that is not forced was the tie-break's choice. In
  the corpus below 90-99% of boards are forced, by axis (table under
  "Evidence"); the rest are where a second engine with a different search
  order could publish a different, equally optimal round.
* **Vertex names.** That vertex `u` of a read is the player the record
  says it is. The verifier sees indices into the engine's field and the
  engine's statement of whose they are; checking that would mean
  rebuilding the field order, which is part of the engine.
* **Colours.** Who has White at each board is decided by C.04.3's colour
  rules after the pairs are fixed, not by a matching. The verifier
  compares boards as unordered pairs.
* **Refusals.** A refused round publishes nothing; its reads and records
  are checked, but "no legal pairing exists" itself is the engine's word.
* **Completeness of the record.** That every question was written down.
  The verifier checks every record it is given and cannot see one that is
  missing - though a published board that no record backs is now a FAIL.

### Not covered

The engine's own counters of decisions without a record are written to
the `end` record's `"uncertified"` map. On the reference path it is empty
on every round of the corpus, which fails any round where it is not.

## Which solves need certificates

A round is not one matching. On the reference path (bbpPairings'
algorithm, which this engine ports), each score bracket is decided by a
sequence of solves of the whole-field graph: an initial solve with the
bracket's criteria packed into the weights, then up to eight refinement
stages that edit weights (stage addends, exchange weights, "prefer the
higher partner" addends) and solve again, then locks that fix the
bracket's pairs before the next bracket starts. Completion and look-ahead
(can the rest still be paired, C.04.3 C4/C8) are part of the packed
weights, with the unweighted questions above settling which completions
are possible. The bye falls out of the last bracket's matching. Every one
of those solves is a question whose answer the next step reads, so every
one needs a certificate; the proof has one record per solve, in order.

Three kinds of weighted record:

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
  They can be recorded, as `window` records, and the verifier checks the
  window condition too (`test/ainalrami/proof_test.exs` records the round
  as paired with the shortcuts forced on and checks every one). But they
  cover a handful of reads per round, between direct answers that cover
  the rest.

So the proof option pairs each round twice: once exactly as without the
option (that is the pairing returned and written, byte for byte), and
once on the reference path - `AINALRAMI_CERT=off`, `AINALRAMI_DIRECT=off`,
`AINALRAMI_NOFAST=1`, set for that call only
(`Ainalrami.Proof.reference_flag/1`), with round one and the odd-field
bootstrap also taken through their matchings - so every bracket is
decided by the refinement stages on the whole field graph, each reading a
weighted matching. That second pairing is the one recorded.

**Format 2.** The direct walk and the small-bracket enumeration still
have no certificate of their own, and do not need one: what they publish
is compared, board for board, with the pairs the reference path read off
proven matchings, by the verifier (above). Where the two paths can
legitimately differ - a tie the fast path breaks another way - the round
fails, and that has not happened on the corpus; the shortcuts are held to
exactly this path by the differential corpora (`docs/performance.md`) and
`test/ainalrami/direct_bracket_test.exs` as well.

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

* **Carried.** The proof lists them. Simple, and enough to prove the
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

1. **Carried weights** (this version). Proves the matcher and the reads,
   trusts the weights and the control flow.
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

JSON Lines, **one record per line** (format 2; format 1 put a whole round
on one line, which at a thousand players was one 280 MB line). A round
starts with a `round` record and ends with an `end` record; a grouped
event has one round per pairing group. Gzipped when the file name ends in
`.gz`; the verifier accepts either.

    {"type":"round","format":"ainalrami-pairing-proof","version":2,
     "engine":"ainalrami 0.47.0","path":"reference",
     "round":{"players":30,"pairs":[[26,10],...,[7,null]]}}
    {"type":"weighted","id":0,"kind":"solve","n":30,"scale":1,
     "graph":{"edges":[[0,1,"2490..."],...]},
     "matching":[[0,3],...],"duals":[[0,"2490..."],...],
     "sets":[{"vertices":[4,7,9],"z":"12"},...]}
    {"type":"cardinality","id":1,"claim":"blocked","n":12,
     "graph":{"edges":[[0,1],...]},"dead":[5],"matching":[[0,1],...],
     "root":4,"barrier":[2,7]}
    {"type":"weighted","id":2,"kind":"shift","n":30,
     "graph":{"base":0,"set":[[3,8,"0"],[5,6,"2490..."]]},...}
    {"type":"read","solve":2,"pairs":[[0,3,26,10],...]}
    {"type":"end","uncertified":{},"agrees":true}

* Vertices are the record's own indices (positions in the field graph),
  not starting ranks; `read` records give each read pair's players, and
  `round.pairs` the published pairing in starting ranks (`null` for a
  bye; `"pairs": null` and a `"refused"` reason for a refused round).
* Weights, duals and set values are decimal strings: integers of any size
  (50-170 digits in practice - the criteria are packed into one number).
* A weighted graph is given in full (`edges`), or as one of the last eight
  weighted records' graphs (`base`) with some edges changed (`set`, weight
  `"0"` for a removed edge). A round's solves mostly differ by a few
  edges, and the full graph at 1,000 players has half a million.
* A cardinality graph is given in full, or as one of the last four
  cardinality graphs (`same`), and `dead` lists the vertices the question
  leaves out.
* Missing duals are 0; sets with `z = 0` are left out.
* `window` (on `window` records only): the vertices the uniqueness claim
  is made for. The verifier adds two checks: every edge not in `M` with an
  end in the window has `rc > 0`, and every edge of `M` at a window vertex
  has an end with `y > 0` (both ends in the window), or the window end
  does (one end). Complementary slackness then pins every optimum to `M`
  on the window.

The bounded look-back is what lets both sides stream: the engine writes
each record as it is made and keeps eight graphs to diff against, and
the verifier reads one line at a time and keeps the same window.

## The verifier

`tools/verify-proof/verify.exs`: one Elixir script, standard library only
(Elixir 1.18+ for the built-in `JSON`), no code shared with the engine and
no `Ainalrami` module referenced. Its header comment states every record
and every check and is the proof; the rest is those checks and their
messages.

    elixir tools/verify-proof/verify.exs FILE [--summary]

prints PASS or FAIL per round, the reason for each FAIL ("matched edge
(3, 7) is not tight: reduced cost 2", "published pair (12, 31) was not
read off a proven matching"), the boards published, read and forced, and
any uncertified counts; exit code 0 when everything passes, 1 on any
FAIL, 2 when the file is not a proof.

`tools/verify-proof/tamper.exs FILE` checks the verifier passes the file,
then changes one thing at a time and checks the verifier fails each:

* weighted: a matched edge's weight, a matched vertex's dual, one pair
  removed from the matching, two pairs' partners swapped, a set's dual;
* cardinality: a "maximum" matching with a pair removed, an "augment"
  turned into "blocked" with the path's inner vertices as the barrier, a
  "blocked" turned into "augment" along a made-up path, a vertex added to
  or removed from an "exposable" set;
* published: a read pair moved to another vertex, two published boards'
  partners swapped, a published board split into two byes.

`test/ainalrami/proof_test.exs` runs the same tampers on engine proofs and
hand-builds the witnesses the corpus rarely or never produces (a barrier
that does not meet the bound, a "blocked" where a path exists, an
exposable set one vertex too big or too small, a board read but not
published, a player at two boards).

## Overhead

**Off.** The option changes nothing when it is off: the pairing path is
the same code with a few process-dictionary reads added (one per matcher
solve, one per completability question, one per bracket read, one per
shortcut counter, one per engine switch read at a round's start), each
answering "not recording". Measured, not argued: see "Evidence" for the
differential against v0.47.0.

**On.** The round is paired twice (as published, then on the reference
path while recording), so the cost is the reference path plus the
recording. The reference path is the expensive half: it is the
whole-field matcher run for every bracket, which is exactly the work the
engine's shortcuts exist to avoid.

PLACEHOLDER-OVERHEAD

## Evidence

PLACEHOLDER-EVIDENCE

## Reproducing

    # the corpus: every round paired with the option off and on, compared,
    # and every proof checked by the verifier
    MIX_ENV=test mix run tools/proof_corpus.exs DIR

    # the off path against a release without the option (run in both)
    MIX_ENV=test mix run tools/perf_diff.exs corpus small DIR
    MIX_ENV=test mix run tools/perf_diff.exs compare DIR_A DIR_B

    # single positions
    mix run tools/proof_bench.exs DIR proof
    elixir tools/verify-proof/verify.exs DIR/1000.jsonl --summary
    elixir tools/verify-proof/tamper.exs DIR/30.jsonl

# ainalrami-verify

Three independent checks of the Dutch engine one directory up, against
C.04.3 (FIDE Dutch System, 2026 edition), and a fourth for its team
engine (C.04.6):

| command | answers |
|---|---|
| `certify` / `check` | Is this published round a maximum-weight round of the C.04.3 weights, recomputed from the TRF? A certificate says so, and a small checker confirms it with integer arithmetic. |
| `rules` | Which articles does this pairing break? Absolute criteria first, then quality criteria, then colours, with the article number and the players involved. |
| `exhaustive` / `sample` | Does the engine agree with a brute-force reading of the rules on every tournament that can happen, up to a given size? |
| `team-certify` / `team-check` | Is this team round the one C.04.6 defines, from its input record? A certificate of matching duals says so, checked the same way (Part 4). |

None of the three trusts the engine's search. The rule checker and the
brute force share no code with it, and the certificate checker recomputes
every weight from the TRF.

## Why a separate project

The engine's job is to pair. This project's job is to doubt it, and the
two should not share a build.

* **The engine does not depend on this.** `../mix.exs` knows nothing about
  `verify/`, compiles nothing from here and ships nothing from here. No
  engine module calls into this one, so a change in this directory cannot
  change one pairing, and an engine release built without it is
  byte-for-byte the same.
* **This depends on the engine by path** (`{:ainalrami, path: ".."}`), so
  a verify build always judges the engine in the same checkout and never
  some published version.
* **One door.** Only `AinalramiVerify.Engine` calls the engine. It uses
  `Ainalrami.Pairing.pair_next_round/2`, the same as `-p`, to get the round
  being judged, and the matcher's public API (`WeightedMatching.new/2`,
  `solve/1`, `proof_export/1`) to find dual solutions for a certificate.
  Both are read-only. No engine code was added or changed for this. A dual
  found by the engine's matcher proves nothing on its own: the checker
  tests it against weights it computes itself, so a wrong matcher yields a
  certificate that fails rather than one that lies.
* **Its own CI job, its own escript** (`ainalrami-verify`), and its own
  tests. The engine's `mix test` does not run them, and they do not slow it
  down.

`../docs/pairing-proofs.md` (the engine's `--proof`) is the other half.
It proves the engine's matchings were optimal *for the engine's own packed
weights*, and it lists "the weights encode C.04.3" as trusted. A certificate
from here covers that item: the weights are rebuilt from the rule text, in
a different model (below), with no code shared.

## The commands

    cd verify
    mix deps.get
    mix escript.build                       # ./ainalrami-verify

    ./ainalrami-verify certify round.trf -o round.cert.json
    ./ainalrami-verify check round.trf round.cert.json        # OK, or FAIL: <condition>
    ./ainalrami-verify rules round.trf pairs.txt              # or a TRF that holds the round
    ./ainalrami-verify pair round.trf                         # the brute-force reference's round
    ./ainalrami-verify exhaustive --players 8 --rounds 4 --dir runs/p8r4 [--workers W]
    ./ainalrami-verify sample --players 10 --rounds 5 --walks 20000 --dir runs/s10r5

`pairs.txt` is the engine's `-p` format: a count line, then `white black`
per board, with `x 0` for the pairing-allocated bye. Exit codes: 0 is
clean, 1 is a finding (a failed check, a broken article, a disagreement,
or a round that cannot be certified), and 2 is a usage or input error.

What is read from a TRF: TRF16/TRF26 player lines, `XXR`, `XXC`, `XXZ`,
`142`, `152`, and requested byes (`H`, `Z`, `F`, `U`, `-`, `+`).
Refused rather than guessed: other point systems (`XXA`, `250`, `260`,
`BB*`, `162`), team records (`310`), `XXG`/`XXM`, a `192` code other than
Dutch, and Baku acceleration.

## Part 1: certificates

`certify` pairs the next round with the engine, then for each bracket stage:

1. builds the stage's graph from the rules, using the bracket plus every
   player still below it;
2. weights each legal pair by C.04.3, as a mixed-radix number whose digits
   are the criteria in order: pairs made, bye eligibility, [C5], [C6],
   [C7], [C8] (pairs and scores of the next bracket), [C9], [C10]-[C13]
   and [C14]-[C21];
3. solves the max-weight matching and writes its dual: `y` per player and
   `z` per odd set.

`check` needs nothing from the engine. It verifies:

* the TRF is the certified one (SHA-256), the round number and the weight
  model version match, and the round is legal ([C1]-[C3], 1.9.1);
* every stage's players are the round's, and its boards are edges;
* dual feasibility: every edge has `f·(y_u + y_v + Σz) ≥ 2w`;
* complementary slackness: every board is tight, every positive `y` is
  seated, every positive `z` set is full;
* the primal value equals the dual value.

The certificate is small, versioned JSON
(`format: ainalrami-verify-certificate`, `version: 1`,
`weights: c0403-2026-tiers-1`). Numbers are strings, because the weights
do not fit in a double.

**What a certificate does not cover.** Article 4's order among equally
good rounds (3.8.1, "generated earlier") is not a weight. A round that
loses only on order still certifies, and `rules` reports it as `order`.
Colours are checked against 5.2 as a legality condition, not weighed.

## Part 2: the rule checker

`rules` rebuilds the brackets the published round implies and, for each
one, compares it with the best candidate a brute-force search finds
(`AinalramiVerify.Bracket`). It reports:

* `1.9.1`: a player missing, paired twice, or paired while sitting out;
* `C1`-`C3`: rematches, a second bye, two non-topscorers with the same
  absolute colour preference;
* the first quality criterion ([C5]-[C21]) on which the bracket is worse
  than the best, with the players involved;
* `order`: equal on every criterion but generated later than the best
  (3.8.1, Article 4);
* `5.2.x`: a board whose colours are the wrong way round.

Readings, where the text leaves room:

* An MDP may meet another MDP. Such pairs sort last in Article 4.
* [C9] applies only when exactly one player floats down and the [C5] bye
  score equals that player's score.
* [C13] counts denied preferences of strength strong or absolute.
* [C18]/[C20] count an MDP left over in the limbo as
  `(score − bracket score)·2 + 1` in quarter-points, so it costs more to
  leave an MDP unpaired than to pair them. The first comparison used the
  paired-only reading and disagreed with the engine 155 times on 6-7
  player trees. The engine, bbpPairings and this limbo reading all pay the
  MDP to stay. With this reading the disagreements fall to 0.
* The next round is 1 plus the last round in which any game has an
  opponent, a `U` or a `+`. If every player has an entry in the following
  column, that column counts as played too. This is the engine's rule.

Tests (`test/rule_check_test.exs`):

* every article [C5]-[C21] and `order` is triggered by a deliberately
  wrong round, and it is the first article named
  (`tools/article_examples.exs` built them);
* [C1], [C2], [C3], 1.9.1 and 5.2 are each triggered by hand;
* the engine's rounds are clean on 40 random walks and on every dispute
  fixture;
* bbpPairings' rounds in the two known disputes
  (`test/fixtures/disputes/`, from `../docs/dispute-seed735265.md` and
  `../docs/finding-bbp-2026-10-07.md`) break [C2], for players 3 and 4.
  The Gacrux 5.2.4/5.2.5 and open-question fixtures are clean for the
  engine.

## Part 3: exhaustive comparison

From round 1 on, every combination of results (`1-0`, `½-½`, `0-1` on
every board) is a child. Each node's next round is paired by both the
engine and the reference, and the two are compared on boards, bye and
colours. The last round is `XXR`, so the topscorer rules are in play there.

Symmetry reduction:

* the initial colour is fixed to White, because Black is its mirror;
* positions that agree on everything C.04.3 reads are merged: score,
  colour sequence, opponents, [C2] status, unplayed rounds, and floats in
  the last two rounds. `positions` counts distinct positions and
  `reached` counts before merging;
* with an odd number of players, the bye's result is fixed, so `2k+1`
  players have exactly as many positions as `2k`.

Runs are cut at round `--split` (default 2) into jobs and walked with
`Task.async_stream`. Each finished job is appended to `DIR/done.log`. A
run restarted on the same directory skips finished jobs, so it can be
stopped at any time; a directory refuses a run with other parameters.
Disagreements go to `DIR/disagreements/` as the TRF plus both rounds and
a rule check of the engine's round.

Positive controls (`test/exhaustive_test.exs`): with [C7], [C8], [C12]
or [C14] dropped from the reference, or Article 4's order reversed, the
7-player 4-round tree disagrees. So the zero below is not just a sign of
a comparison too blunt to see anything.

### Results, engine 0.51.1

| players / rounds | positions | reached | agree | refused by both | disagree | time (12 workers) |
|---|---:|---:|---:|---:|---:|---:|
| 6 / 3 | 757 | 757 | 757 | 0 | **0** | <1 s |
| 6 / 4 | 20,440 | 20,440 | 12,637 | 7,803 | **0** | 5 s |
| 7 / 4 | 20,440 | 20,440 | 20,440 | 0 | **0** | 10 s |
| 8 / 3 | 6,643 | 6,643 | 6,643 | 0 | **0** | 5 s |
| 10 / 3 | 59,293 | 59,293 | 59,293 | 0 | **0** | 119 s |
| 6 / 5 | 340,824 | 341,200 | 324,715 | 16,109 | **0** | 59 s |
| 7 / 5 | 551,833 | 551,881 | 551,833 | 0 | **0** | 163 s |
| 8 / 4 | 538,084 | 538,084 | 538,084 | 0 | **0** | 160 s |
| 9 / 4 | 538,084 | 538,084 | 538,084 | 0 | **0** | 276 s |

That is 2,076,398 distinct positions with 0 disagreements. "Refused by
both" means neither the engine nor the reference found a legal round
(1.9.3), which is common with 6 players by round 4.

### Bigger runs (the 80-core VM)

Positions grow by about 3^(boards) per round. Estimates: 9/5 is about
43M positions, 10/4 about 14M, and 10/5 about 3.5B. 10/5 is out of reach
even there, so it is sampled.

    cd verify && MIX_ENV=prod mix escript.build
    ./ainalrami-verify exhaustive --players 9  --rounds 5 --dir runs/p9r5  --workers 78 --split 3
    ./ainalrami-verify exhaustive --players 10 --rounds 4 --dir runs/p10r4 --workers 78 --split 3
    ./ainalrami-verify sample --players 10 --rounds 5 --walks 2000000 --dir runs/s10r5 --workers 78

Use `nohup` or `tmux`. A stopped run continues when restarted with the
same command. `--split 3` makes enough jobs for 78 workers, but the split
is part of the parameters, so a directory started with one split cannot
continue with another.

## Part 4: team certificates (C.04.6)

    ./ainalrami-verify team-pair input.json                          # the engine's round, as a pairing list
    ./ainalrami-verify team-certify input.json [--round output.txt] -o cert.json
    ./ainalrami-verify team-check input.json cert.json [output.txt]  # OK, or FAIL: <condition>

`input.json` is an `ainalrami-team-input` record, version 1, written by
`Ainalrami.TeamCertificate.input/2` when a host pairs a team round: the
round, `expected_rounds`, `score_mode`, `use_secondary`, `type`,
`initial_colour`, `absent`, `forbidden_pairs` / `soft_pairs` (groups, with
optional `from`/`to` rounds), and per team the fields of
`Ainalrami.TeamPairing.Team`. `output.txt` is the pairing list: a count
line, `white black` per match, `tpn 0` for the bye. The certificate is
written by the engine's `Ainalrami.TeamCertificate.certify/3` (format
`ainalrami-team-certificate`, version 1, weights `c0406-2026-2`); its duals
are found with the engine's matcher, and `team-check` decides alone
whether they prove anything.

C.04.6 3.6 defines a bracket's pairing as the FIRST in an order among the
ones that minimise [C8]-[C10], and 3.5 the upfloaters as the first set in
another; `../docs/team-proof-large-fields.md` shows both are cheapest
perfect matchings once the counts are packed into one integer. A
certificate carries the duals of those matchings, with the round itself as
the primal, so `team-check` needs no search. It verifies:

* the input is the one certified (SHA-256), and the round its round;
* legality: every team placed once, a bye exactly when the field is odd
  and only for a team [C2] allows, no rematch and no forbidden pair ([C1]);
* Article 4: every match's colours, allocated here (4.2 first-team, then
  4.3.1-4.3.9) and compared;
* 3.4: the certificate passes over exactly the eligible teams ahead of the
  bye (lowest score, most matches played, largest TPN), each with a dual
  whose bound `f * (sum y + sum z (|S|-1)/2)` is below the number of the
  other teams - so without that team nobody pairs everybody (3.4.1);
* per bracket (residents: the highest score still unpaired; upfloaters:
  the lower teams the round seats against a resident), three duals, each
  checked as in Part 1 (feasible, every board tight, complementary
  slackness, equal objectives):
  * **3.5**, over every team not yet paired. Per pair, most significant
    first: `k` 1 for resident-lower ([C4]); one `c5` digit per lower score
    level, lowest level first, 1 for resident-lower on that level ([C5]);
    `u` 1 for two lower teams of which exactly one has the following
    score ([C6]) - the next score below the residents' among ALL the
    round's teams, the bye's included, so no pair carries it once no team
    of that score is left (weights `c0406-2026-2`, 2026-11-11; `-1` took
    the highest score among the teams still to pair); `c7` 1 for
    resident-lower when the lower team floated last round, 0 in the last
    two rounds ([C7]); `pos` `2^L - 2^(L-p)`
    for resident-lower, `p` the lower team's place by (score desc, TPN)
    (3.5.4). The optimum fixes the upfloater set uniquely.
  * **3.6 top set**, over the bracket in TPN order: `c8` 1 when both teams
    want the same colour; `c10` the number of the pair's teams that
    floated last round facing an upfloater, 0 in the last two rounds;
    `soft` 1 for a soft pair; `tops` `2^m - 2^(m-i)`, `i` the smaller
    team's index.
  * **3.6 bottoms**, confined to pairs from the round's top set to the
    rest: `c8`, `c10`, `soft`, then `rank(bottom) * h^(h-1-rank(top))`.

  Each digit's base is 1 plus the sum over the teams of its largest value
  on a pair at that team, so the packed cost orders lexicographically;
  a pair weighs `(n/2) * max_cost + 1 - cost`, so the maximum-weight
  matching is the cheapest perfect one.

Readings are the engine's documented ones (Type A, [C1] symmetric,
open question 6 is the host's boolean), and the checker proves the round
follows them, not that they are FIDE's. Type B colour preferences are
refused. Tests: `test/team_check_test.exs` certifies and checks played
events (`test/support/team_walk.ex`) under match points and game points,
with teams kept apart, and refuses re-partnered brackets, turned-round
colours, tampered duals and a pairing list that is not the certified one.
A one-off sweep of 2,938 rounds of 5-80 teams found no round refused.

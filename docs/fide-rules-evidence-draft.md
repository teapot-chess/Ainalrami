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

SUMMARY_FINDINGS

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

This reference agrees with the Ainalrami engine on every position of
every tournament of 6 to 10 players and 3 to 5 rounds that we have
enumerated (2,076,398 distinct positions, 0 disagreements), and the
engine agrees with bbpPairings 6.0.0 on 414,606,289 of 414,606,291
rounds of a seven-day comparison (both differences are a bbpPairings
defect in [C2]). The reading is therefore not idiosyncratic: it is the
reading two independent 2026 implementations share.

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

CORPUS_BASELINE

## 3. Colour streaks and colour imbalance

COLOUR_SECTION

## 4. Floats and float cascades

FLOAT_SECTION

## 5. Article 5.2.5 and the numbering of late entries

C525_SECTION

## 6. Other measurements

OTHER_SECTION

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

FIDELITY_NUMBERS

## 9. Reviewer notes (remove before sending)

REVIEWER_NOTES

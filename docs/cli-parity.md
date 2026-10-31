# CLI parity: the library's options, the command line's, and the file's

OpenPairings drives this engine through the library API. The standalone
engine - `ainalrami input.trf -p` - is the same engine with a TRF and a
command line instead of a host, and it is the one FIDE's checklist asks
questions of. This is the inventory of every option the library takes,
whether a flag reaches it, and whether a file can say it.

Three ways in:

- **library** - an option of `Ainalrami.Pairing.pair_next_round/2` and its
  siblings, or data on the players;
- **flag** - on `ainalrami`'s command line;
- **file** - a TRF/TRF26 record, standard or one of the `XX` extension
  codes the README documents.

"OpenPairings" is where the host gets the value from
(`lib/pairings_engine/pairing.ex`, `ainalrami_opts/3` and `engine_trf/7`,
unless said otherwise).

## Individual Swiss (C.04.3) - `-p`, `-x`, `-c`

| library | OpenPairings | flag | file | FIDE? |
|---|---|---|---|---|
| `expected_rounds:` | the tournament's round count, written as `XXR` and read back | `--rounds=N` **(new)** | `142`, `XXR` | yes |
| `initial_colour:` | the drawing of lots, written as `XXC` | `--initial-colour=white\|black` **(new for -p/-x/-c; was -g only)** | `152`, `XXC` | yes |
| `point_system:` | `Tournament.engine_point_system/1` | `--points=3,1,0` or `--points=win:3,draw:1,bye:1,...` **(new)** | `BBW` `BBD` `BBL` `BBZ` `BBF` `BBU`, `162`, `299` | yes |
| `point_system:` `:unknown` (a `?` result) | - (the host writes a postponed game as `=` with its provisional total, never `?`) | `--points=unknown:0.5` **(new, third pass)** | `162` `X` | yes (TRF26) |
| `forbidden_pairs:` (groups) | forbidden pairings and club/federation exclusion rules | `--forbidden=1,4/2,9,12` **(new)** | `XXP` | arbiter's, as before |
| `forbidden_pairs:` `{ranks, first, last}` | round-limited rules | `--forbidden=2,9@3-5` **(new)** | `260` | arbiter's, as before |
| `soft_pairs:` | soft forbidden pairings, club protection | `--soft-pairs=1,4/2,9,12` | `XXO soft-pairs 1 4` **(new)** | **no** - warned |
| `soft_pairs:` `{ranks, first, last}` | round-limited wishes | `--soft-pairs=2,9@3-5` **(new)** | `XXO soft-pairs 2 9 @3-5` **(new)** | **no** - warned |
| `soft_position:` | `tournament.soft_position` | `--soft-position=strong\|weak` | `XXO soft-position weak` **(new)** | **no** - warned |
| `bye_exclusions:` | `with_bye_exclusions/4` | `--bye-exclude=3,7@4-6+9` **(new)** | `XXO bye-exclude 3 7@4-6+9` **(new)** | **no** - warned |
| `bye_preferences:` `:want_hard` | `Player.bye_preference` | `--bye-want=` | `XXO bye-want` **(new)** | **no** - warned |
| `bye_preferences:` `:want_soft` | same | `--bye-want-soft=` | `XXO bye-want-soft` **(new)** | **no** - warned |
| `bye_preferences:` `:avoid_hard` | same | `--bye-avoid=` | `XXO bye-avoid` **(new)** | **no** - warned |
| `bye_preferences:` `:avoid_soft` | same | `--bye-avoid-soft=` | `XXO bye-avoid-soft` **(new)** | **no** - warned |
| ... each for chosen rounds | `bye_preference_for_round/2` | `RANK@3-4+7` | `RANK@3-4+7` **(new)** | |
| `cascade_order: true` | not used (the generator's) | `--cascade-order` **(new)** | - (it is the order of the output, not a fact about the event) | yes |
| `proof:` (a function given each round's proof, or `{:stream, fun}` given it line by line) | not used | `--proof=FILE` **(new)** | - (a certificate about the computation, not a fact about the event) | yes - the pairing is unchanged |
| players' `:accelerations` - Baku (C.04.7) | `accelerations/3`: Group A `2 * ceil(n/4)`, frozen at round 1 | `--acceleration=baku`, `--baku-group-a=N` **(new for -p/-x/-c)** | `XXA`, `250` | yes |
| players' `:accelerations` - anything else | acceleration-mode extra points, as `XXA` | `--virtual-points=1-10:1,1,0.5/11:0.5` **(new)** | `XXA`, `250` | **no** - the flag warns |
| a requested bye (half, zero, full) | a letter in the player's column | `--half-bye=` `--zero-bye=` `--full-bye=` **(new)** | `H` / `Z` / `F` in the column, `240` | yes |
| an absent or withdrawn player | a `Z` in the column | `--zero-bye=` **(new)** | `Z`, a blank column, `240 Z`, `XXZ` **(0.44.1)** | yes |
| a late entrant | blank rounds before the first game; arrival order from the games (5.2.5) | - (the file says it) | short or blank `001` rounds | yes |
| `EventFormat` `match_format:` | `swiss_match_format` | `--match-format` | `XXM` | no FIDE record; refused with groups |
| `EventFormat` `groups:` | `pair_by_category` | `--groups=1-8/9-12` | `XXG` | no FIDE record |
| `explain_round/3` | the rationale page | `-x` | - | |
| `Alternatives.force_pair/5` | "what if these two met" | `-x --force=A-B` | - | |
| `Alternatives.no_show/4` | "N did not turn up" | `-x --absent=N` | - | |
| `Alternatives.judge/4` (and `violations/1`) | judging an arbiter's proposal | `-x --judge=1-5,2-6,3-0` **(new)** | - | |
| `Alternatives.bye_alternatives/3` | "why not me" | `-x --bye-alternatives` **(new)** | - | |
| `Alternatives.float_alternatives/3` | "why did I float" | `-x --float-alternatives` **(new)** | - | |
| each candidate's `alternative` (0.43.0) | both versions of the round, side by side | `-x --alternative-pairs`, with either of the two above | - | opt-in: without it the listings are byte for byte what they were |
| `Alternatives` `max_candidates:` | `:all` when the arbiter asks for the whole bracket (`open_alternative/4`'s `full: true`) | `-x --max-candidates=N\|all`, with either of the two above **(new, third pass)** | - (a search budget, not a fact about the event) | |
| `Trf.serialize/2` `dialect:` | `:trf26` for the FIDE report | `-g --dialect=engine\|trf26` **(new, third pass)**; `-p`/`-x`/`-c`/`-s` read either | - (it is the file's spelling) | |

### Deliberately not on the command line

| library | why not |
|---|---|
| `bye_passed_over: false` | tells `explain_round/3` not to re-derive an account the caller already has. It changes no pairing and no explanation the CLI prints. |
| `bye_preference_exclusions:` | the resolved half of `ByePreference.pair/2`'s report, for `bye_eligibility/2`'s wording. The CLI passes the report's own `opts` on, which carry it. |
| `Pairing.pair_variants/3` | one position paired under many results at once, each answer exactly `pair_next_round/2`'s for that variant. A batching API for a preview, not an option: the CLI's equivalent is `-p` per file. |
| `Pairing.bye_eligibility/2`, `bye_disqualifications/2` | answered inside `-x --bye-alternatives` (each candidate C2 rules out is named with the reason); no listing of its own. |
| `Alternatives.float_alternative/5` | one entry of `--float-alternatives`. |
| `Alternatives` `max_alternative_boards:` | the cap on how many boards of one alternative are written out (40); the CLI keeps the default and prints "not written out, N boards differ" past it. |

## Team Swiss (C.04.6) - `-p`, `-x`, `-c` on a team file

| library (`TeamPairing.pair_round/2`) | OpenPairings (`team_swiss.ex`) | flag | file |
|---|---|---|---|
| `type:` `:a` / `:b` / `:none` | `:a` | `--team-type=a\|b\|none` **(new for -p/-x/-c)** | `192` `FIDE_TEAM_TYPEA...` / `TYPEB` / neither |
| `score_mode:` | `:match_points` | `--score=mp\|gp` **(new for -p/-x/-c)** | `192` `..._MP` / `..._GP` |
| `use_secondary?:` | default | `--secondary=yes\|no` **(new for -p/-x/-c)** | `192` with or without the second score |
| `initial_colour:` | the drawing of lots | `--initial-colour=white\|black` **(new for -p/-x/-c)** | `152` |
| `round:` | the round number | - (the file's history) | the games |
| `expected_rounds:` | the round count | `--rounds=N` **(new)** | `142` |
| `absent:` | teams that arrived and sit this round out | `--absent-teams=2,5` **(new)** | every player of the team with the round recorded (`Z`/`H`/`F`, `240`) |
| `max_upfloater_sets:` | default | `--max-upfloater-sets=N` **(new)** | - |
| `explain: true` | always | `-x` | - |
| `explain_limit:` | default | `--explain-limit=N` **(new)** | - |
| `max_candidates:`, `max_steps:` | - | - (accepted and ignored by the library since 2026-09-25) | - |
| `forbidden_pairs:` (team numbers, optionally `{tpns, first, last}`) | not yet passed (the option is new) | `--team-forbidden=3,11,16/1,8@1-2` **(new, -p/-x/-c)** | `XXO team-forbidden 3 11 16 [@1-2]` **(new)** |
| `soft_pairs:` (same shape) | not yet passed | `--team-soft-pairs=3,11,16` **(new, -p/-x)** | `XXO team-soft-pairs 3 11 16 [@1-2]` **(new)** |
| match points, the bye's and a forfeit's value | the standings | - (`-g` only) | `362`, `320`, `330` |

## The Dubov system (C.04.4.1) - `-p`, `-c`, `-g`

`Ainalrami.Dubov.pair_next_round/2`; the command line's side is
`Ainalrami.DubovCLI`. Readings: `docs/conformance-c0441-dubov.md`.

| library | flag | file | FIDE? |
|---|---|---|---|
| the system itself | `--system=dubov` (`-p`, `-c`, `-g`); one that contradicts `192` exits 2 | `192 FIDE_DUBOV`, `192 FIDE_DUBOV_BAKU` | yes |
| `expected_rounds:` - **required** | `--rounds=N` | `142`, `XXR` | yes |
| the `001` rating | - | `001` | yes |
| `provisional_ratings:` | `--provisional-rating=12:1500/17:1400` (flag over file, per player) | `XXO provisional-rating 12 1500` - not warned, it is 1.1.2 | yes |
| `initial_colour:` | `--initial-colour=` | `152`, `XXC`; absent, read off round 1 | yes |
| `point_system:`, `forbidden_pairs:` | as for Dutch | as for Dutch | as for Dutch |
| virtual points (Baku) | `--acceleration=baku`, `--virtual-points=` | `XXA`, `250` | yes |
| `transposition_rule:` (reading D2) | - (a reading, not a setting: one line in `Ainalrami.Dubov`) | - | - |

Refused for a Dubov file, exit 1: the organiser options (`soft_pairs`,
`bye_preferences`, `bye_exclusions`, pairing groups, the match format, and
their `XXO`/`XXG`/`XXM` records), `--cascade-order`, `--proof`, `--force`,
`--absent`, `--judge` and the alternatives flags. `-x` exits 2. Not built:
a Dubov proof (`--proof`; the team engine has none either) and Dubov's own
`-x`.

`test/ainalrami/dubov_cli_test.exs` holds the flags to the files;
`-g --system=dubov` followed by `-c` replays clean.

## The Burstein system (C.04.4.2) - `-p`, `-c`, `-g`

`Ainalrami.Burstein.pair_next_round/2`; the command line's side is
`Ainalrami.DubovCLI` (both systems). Readings:
`docs/conformance-c0442-burstein.md`.

| library | flag | file | FIDE? |
|---|---|---|---|
| the system itself | `--system=burstein` (`-p`, `-c`, `-g`); one that contradicts `192` exits 2 | `192 FIDE_BURSTEIN`, `192 FIDE_BURSTEIN_BAKU` | yes |
| `expected_rounds:` - **required** (it fixes the seeding rounds, 1.6.2) | `--rounds=N` | `142`, `XXR` | yes |
| `initial_colour:` | `--initial-colour=` | `152`, `XXC`; absent, read off round 1 | yes |
| `point_system:`, `forbidden_pairs:` | as for Dutch | as for Dutch | as for Dutch |
| virtual points (Baku) | `--acceleration=baku`, `--virtual-points=` | `XXA`, `250` | yes |
| ratings | - (`--provisional-rating` refused: the index is Buchholz, SB, TPN) | `001` ignored after seeding | yes |

The seeding rounds go to the Dutch engine unchanged. Refused after them,
exit 1: the same organiser options and flags as for Dubov; `-x` exits 2.
Not built: a Burstein proof and Burstein's own `-x`.

`test/ainalrami/burstein_cli_test.exs` holds the flags to the files;
`-g --system=burstein` followed by `-c` replays clean.

## Round robins - `-p`, `-x`, `-c`

`Ainalrami.Berger.round/4` and `Ainalrami.RoundRobin`: the table has no
options beyond the cycle count and the two event formats, all of which the
file says (`192`, `092`, `XXM`, `XXG`) and `--match-format` / `--groups=`
repeat. Nothing was missing.

## Tie-breaks (C.07) - `-c`, and the new `-s`

| library | OpenPairings | flag | file |
|---|---|---|---|
| `Tiebreaks.rank/3` | the standings | `-s` **(new mode)**; `-c` compares the file's ranks with it | - |
| the list of codes | the tournament's tie-breaks | `--tie-breaks=BH,SB` **(new for -c/-s; was -g only)** | `202`, `212` |
| `Event` `points:` | the point system | `--points=` **(new)** | `BB*`, `162` |
| `Event` `total_rounds:` | the round count | `--rounds=N` **(new)** | `142`, `XXR` |
| `Event` `cap_rounds:` | `:announced` | `--cap-rounds=played\|announced` **(new)** | - |
| `Event` `predetermined?:` | the pairing system | - (the file's type) | `192`, `092` |
| `Participant.round_ratings` (Q214) | `PeriodRatings.per_round_tiebreaks?/1` | - (a table belongs in the file) | `XXO round-ratings 12 2100 2150 -` **(new)** |
| team tie-breaks, `Tiebreaks.Team` | the team standings | `-s` on a team file **(new)** | `310`, `362`, `320`, `330`, `300` |

### Left open

| library | why |
|---|---|
| `Tiebreaks.rank/3` `score:` | the caller's own score in place of the games' (OpenPairings' extra points). A TRF has the `001` total, and reading the standings from a total the games do not explain is a decision about `-c`'s standings check, not a flag. Not done. |
| `Tiebreaks.compute/2`, `working/2` | `-s` prints every value `rank/3` used; the per-opponent working (which opponent contributed what) has no CLI output. A display question, no option is missing. |
| per-round ratings for TEAM tie-breaks | `Tiebreaks.Team.from_trf/2` builds its board events itself and does not carry `round_ratings` through; OpenPairings does not use them there either. |

## The gap list

Before this work, reachable only through the library:

1. the round count, the initial colour and the point system as anything but
   a line in the file;
2. forbidden pairs from the command line, and round-limited ones except as
   `260`;
3. round-limited soft pairs;
4. the plain `:bye_exclusions` option (only as the `:avoid_hard`
   preference);
5. any non-FIDE option in a FILE - soft pairs, soft position, bye
   exclusions, the four bye preferences;
6. `cascade_order:`;
7. Baku worked out from a round count (the file had to carry `XXA`), and
   virtual points from the command line;
8. byes requested for the round being paired, and absences, except by
   editing the file;
9. `Alternatives.judge/4`, `bye_alternatives/3`, `float_alternatives/3`;
10. every team Swiss setting except through the `192` code; absent teams
    except by editing the file; `max_upfloater_sets:`, `explain_limit:`;
11. the standings themselves (only `-c`'s pass/fail), a tie-break list
    other than the file's, `cap_rounds:`, per-round ratings.

After: every row above has a flag, a record, or both, except the rows
under "Deliberately not on the command line" and "Left open", each with
its reason.

## The third pass

A sweep of everything OpenPairings hands the engine (`ainalrami_opts/3`,
`pair_with_preferences/3`, `run_variants/7`, the explanation pages, the team
Swiss, the TRF writers) against the table above found three more:

1. `max_candidates: :all`, which the host passes when the arbiter asks for
   a whole bracket's alternatives - the CLI kept the default of 12;
2. the value of a `?` result, which a file could declare (`162 X`) and the
   command line could not;
3. the TRF26 dialect, which the library writes and the Swiss generator did
   not.

`test/ainalrami/cli_parity_3_test.exs` holds each to the library: the
alternatives under each cap against `Alternatives.bye_alternatives/3` and
`float_alternatives/3`; `--points=unknown:V` against the same file carrying
`162 X V`, through `-p` and `-s`, and against `pair_next_round/2`; a TRF26
generator file against the engine-dialect one of the same seed, the same
players and every round paired again from each, and `-c` passing it.

Still library-only, for the reasons above: `Alternatives`
`max_alternative_boards:` (the host does not set it either), `pair_variants/3`
and `bye_passed_over:`. The serializer's cosmetic options (`column_legend:`,
`ascii:`, `xxr:`/`xxc:`) are not pairing options; the generator writes `XXR`
beside `142` regardless.

## What holds the two to the same answer

`test/ainalrami/cli_library_equivalence_test.exs`: 200 generated
tournaments (5-60 players, cut back to before one of their rounds), each
option paired through the library and through `ainalrami -p`, the boards
compared in order; every compatible pair of options on a slice of the
corpus; the `XXO` records written, read back and paired, in both dialects;
whole events played under them and replayed by `-c`; teams and standings
the same way. `AINALRAMI_CLI_PARITY_SEEDS=2000 mix test
test/ainalrami/cli_library_equivalence_test.exs` is the bigger run.

`tools/cli_golden.exs` is the other half: everything the CLI printed for a
fixed corpus with only the flags it already had, to compare between two
checkouts. This branch against the release before it: 2,747 runs, 5.8 MB
of output, byte for byte the same.

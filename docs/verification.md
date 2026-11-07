# Verification

The engine checks itself in several ways. `docs/validation.md` covers its
agreement with other engines, and `docs/pairing-proofs.md` (`--proof`)
proves its matchings were optimal for its own weights. Neither one asks
whether the engine's reading of C.04.3 is right. That question belongs to
a separate project in [`verify/`](../verify/README.md), which judges the
engine from outside it.

| | what it says about a round | trusts |
|---|---|---|
| `ainalrami-verify certify` / `check` | the round is maximum-weight for C.04.3 weights recomputed from the TRF; the dual certificate is checked with integer arithmetic | the weight model in `verify/` (a second, independent encoding of C.04.3) |
| `ainalrami-verify rules` | every broken article: 1.9.1, [C1]-[C3], the first worse quality criterion per bracket, Article 4's order, 5.2 colours | a brute-force reading of the rules in `verify/` |
| `ainalrami-verify exhaustive` | the engine and the brute-force reading agree on every reachable position of a given size | the same |

Why it is a separate Mix project and not part of `lib/`: the engine must
not depend on its own auditor. `verify/` depends on the engine by path,
calls it through one module, and uses only public, read-only functions.
No engine code was added or changed for it, and nothing here ships in an
engine release.

Coverage on engine 0.51.1 (the whole tree, with positions merged on what
C.04.3 reads): 6 players for 3, 4 and 5 rounds; 7 players for 4 and 5
rounds; 8 players for 3 and 4 rounds; 9 players for 4 rounds; 10 players
for 3 rounds. That is 2,076,398 distinct positions with 0 disagreements.
The tables, the readings adopted where the text leaves room, and the
commands for larger runs on the VM are in
[`verify/README.md`](../verify/README.md).

Run it:

    cd verify && mix deps.get && mix test

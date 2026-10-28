defmodule Ainalrami.Pairing.NoValidPairingError do
  @moduledoc """
  Raised when the active players cannot be simultaneously paired while
  satisfying the absolute criteria (no rematch, no double colour-absolute
  clash) - not a search failure, a proven structural deadlock.

  Direct analogue of bbpPairings' own `NoValidPairingException`
  (`swisssystems/dutch.cpp`'s `matchingIsComplete`/`compatible`): it
  computes ONE matching over the whole field and throws rather than ever
  emitting more byes than `rem(active_count, 2)`. `Ainalrami.Pairing`
  matches that: `global_cascade/2`'s `:infeasible` result
  (`repair_completion/3`'s whole-field maximum-weight matching) only
  reaches this if the true maximum itself still leaves too many players
  unmatched - proof no legal
  completion exists, not evidence the search didn't try hard enough. A
  small field deep into a Swiss (colour-absolute exclusions stacking on
  top of near-exhausted rematch-free opponents) is the realistic way to
  hit this, not a bug in the matcher.

  ## Fields

    * `:reason` - `:no_legal_pairing` when the absolute criteria alone
      leave no legal round, or `:bye_exclusions` when a legal round exists
      but not one that keeps the pairing-allocated bye away from every
      player in `pair_next_round/2`'s `:bye_exclusions` option - the
      organiser's rule, not FIDE's, is what made the round impossible.
    * `:excluded` - with `:bye_exclusions`, the excluded ranks that are
      active in this round (sorted). `[]` otherwise.
    * `:override` - with `:bye_exclusions`, ONE excluded rank whose
      exclusion, lifted for this round alone, makes the round pairable: the
      player who receives the bye when the round is paired without any
      exclusion. A caller can offer "pair anyway, ignoring the exclusion
      for this player" and pair again with that rank removed from the list.
      `nil` otherwise.
  """
  defexception [:message, reason: :no_legal_pairing, excluded: [], override: nil]
end

defmodule Ainalrami.Pairing do
  @moduledoc """
  The actual Dutch-system pairing algorithm. Implemented incrementally -
  see docs/engineering-log.md for the staged plan and its documented simplifications
  (`pair_next_round/1`'s doc lists exactly which parts of the real FIDE
  procedure aren't faithfully implemented yet).

  A pairing is represented as `{white_rank, black_rank | nil}` - `nil` for
  a pairing-allocated bye, the same convention `Ainalrami.Trf`'s parsed game
  records use (`opponent_rank: nil`), rather than JaVaFo's own text-output
  convention of a literal `0` (that translation happens only at the
  CLI/output-formatting boundary).

  A player is `%{rank:, points:, games: [%{opponent_rank:, colour:, result:}]}`
  - the shape `Ainalrami.Trf.parse/1` returns.
  """

  alias Ainalrami.CardinalityMatching
  alias Ainalrami.Log
  alias Ainalrami.WeightedMatching

  # This engine used to carry a second pairing path - a per-bracket
  # cascade with a backtracking search over alternative matchings, tuned
  # by five module attributes that lived here. It is gone, along with
  # ~950 lines, because `global_cascade/2` beat it at every field size and
  # then stopped falling back to it at all.
  #
  # The note those attributes carried is still worth keeping, because it
  # predicted this: a no-backtracking version of the OLD cascade measured
  # 97.19% -> 81.99% of pairs, and the reason given was that bbpPairings
  # needs no backtracking only because its weights are richer - locality
  # graded rather than partitioned, plus an exchange-minimisation
  # refinement. That is exactly what the current path implements, and it
  # needs no backtracking either.
  @bye_score_key :ainalrami_bye_score
  @expected_rounds_key :ainalrami_expected_rounds
  # dutch.cpp:845-870's `isSingleDownfloaterTheByeAssignee` as it stands
  # when the FIRST bracket is paired. It is read off the same bootstrap
  # whole-field matching that determines `byeAssigneeScore`, so it is
  # computed there (`bye_assignee_score/2`) and stashed here rather than
  # threaded through, exactly like the bye score itself.
  @first_single_bye_key :ainalrami_first_single_bye
  # `resolveForbiddenPairs`' answer for the round being paired
  # (`tournament.cpp:100-116`), as `%{rank => MapSet.t(rank)}`, or nil when
  # the tournament has no `XXP` line at all. Stashed for the same reason
  # `@expected_rounds_key` is: `legal_pair?/2` is reached from four call
  # sites deep inside the cascade and the matcher, none of which carry a
  # tournament-level context, and threading one through purely for a rule
  # that is usually absent would touch every weight function on the way.
  @forbidden_key :ainalrami_forbidden_pairs
  # Soft constraints - pairs the arbiter would RATHER avoid (club or school
  # protection in the early rounds, family members), as opposed to the
  # absolute exclusions above. nil unless a caller asked, and when nil the
  # ladder is byte-for-byte what FIDE's is: see `soften/3`.
  @soft_key :ainalrami_soft_pairs
  # The TOURNAMENT's played-round count, stashed for the same reason as the
  # keys above. `final_round_topscorers?/2` used `length(a.games)` - that
  # player's own game count - which is the precise indexing bug this module
  # was deliberately converted away from everywhere else (see
  # `float_direction/4`, where it was worth +10 points on the bye axis). A
  # player carrying a pre-recorded bye for the round being paired has one
  # game MORE than the tournament has played, so the final-round exception
  # could fire a round early for them; a late entrant has fewer, so it could
  # fail to fire when it should.
  @played_key :ainalrami_played_rounds
  # One WeightedMatching state for the whole round, carried across every
  # bracket of the cascade: `{matcher, field_index_of_rank, previous_edges,
  # field_size}`. Set by `global_cascade/2`, consumed by `solve/1`, cleared
  # with the rest of the round-scoped keys.
  @round_matcher_key :ainalrami_round_matcher
  @dirty_key :ainalrami_dirty_edges
  # Certified mode - see "Certified shortcuts" below `run_stages/1`. Whether
  # the round's current attempt may take shortcuts (`@cert_key`), whether
  # the round matcher has left the state the reference search would be in
  # (`@taint_key`), the memo of dual contexts and candidate sets, and the
  # run's counters (kept across rounds, only when AINALRAMI_CERT_STATS is
  # set, for the benchmarks).
  @cert_key :ainalrami_cert_mode
  @taint_key :ainalrami_cert_tainted
  @cert_memo_key :ainalrami_cert_memo
  @cert_stats_key :ainalrami_cert_stats
  # The round.s completability oracle -- see `build_oracle/3`. Set by
  # `global_cascade/2`, consulted by `attempt_local/7`, cleared with the
  # rest of the round-scoped keys.
  @oracle_key :ainalrami_oracle
  # C.04.3 5.1's initial colour -- the one drawn by lot before round 1, which
  # 5.2.5 gives to the higher ranked player of a pair when neither holds a
  # preference. Defaults to White, which is what this engine assumed
  # unconditionally until the TRF's `152` field was read at all.
  @initial_colour_key :ainalrami_initial_colour

  # The round's ARRIVAL NUMBERING - `%{starting_rank => number}` - which is
  # the number Article 5.2.5's parity is taken on. See
  # `arrival_numbers/2`. Stamped once per round by `do_pair_later_round/1`
  # and read by `assign_colour_with_history/1`, which sees only the two
  # players of a board and so cannot build it.
  #
  # Round one does NOT use this key: `pair_round_one/1` builds the numbering
  # from its own sorted field and passes it down as an argument, because it
  # is public and is called directly, with nothing stamped, by tests and by
  # the javafo harness.
  #
  # Same lifecycle as `@initial_colour_key`, and cleaned up in the same
  # `after` blocks. The 2026-08-26 comment in `pair_later_round/2` is the
  # standing warning about what a leaked round-scoped key costs: a stale
  # numbering from tournament A silently renumbers tournament B, and the
  # result is a pairing that looks entirely legal.
  @parity_number_key :ainalrami_parity_numbers

  # What a result is WORTH. Stashed for the same reason as the others: it is
  # read deep in the historic-score reconstruction, which the bracket cascade
  # reaches from several directions.
  #
  # This is not cosmetic. Score decides bracket, and bracket decides
  # everything, so an engine running the standard 1/=/0 against a file that
  # says otherwise does not report the wrong totals - it pairs a different
  # tournament and reports it confidently.
  @point_system_key :ainalrami_point_system

  # The three diagnostic environment flags the hot path used to read
  # per-edge, stamped once per round instead. `System.get_env/1` is not a
  # constant fold: it builds a charlist for the name, goes through the
  # emulator's environment table under a global lock, and allocates a
  # binary for the answer.
  #
  # `completion_rung/3` is the first rung `edge_rungs/6` returns, and
  # `bracket_edge_weight/8` calls that for EVERY legal, colour-compatible
  # candidate pair - order 70,000 reads in a 1,000-player round. The fuzz
  # harnesses run 36 workers in ONE VM, so that is 36 workers queueing on
  # one lock, per edge, for a value that cannot change while the VM is up.
  # `AINALRAMI_TRACE` (roughly 10 reads per bracket) and `AINALRAMI_NOFAST`
  # are stamped with it because the three share one lifetime and splitting
  # them would be three chances to forget one.
  #
  # `:unset` rather than nil is the sentinel for "the variable is not set",
  # because nil is also what `Process.get/1` answers for a key that was
  # never stamped, and those two cases must NOT collapse: an unstamped key
  # has to fall back to a real `System.get_env/1`, so a caller reaching
  # these functions without going through an entry point still sees the
  # truth rather than a silent "unset". `System.get_env/1` returns nil only
  # when the variable is absent - a variable set to nothing comes back as
  # `""`, which is truthy here - so the sentinel is unambiguous and
  # `env_flag/2` reproduces `System.get_env/1` exactly, including for a
  # caller comparing the result against a string.
  # The organiser's bye exclusions for the round being paired - a MapSet of
  # the active players' ranks who must not receive the pairing-allocated
  # bye, or nil. NOT a FIDE rule: see `bye_exclusion_set/2`. nil unless a
  # caller asked AND the round actually has a bye to give, so that without
  # the option every rule reads exactly what it read before it existed.
  @bye_excluded_key :ainalrami_bye_excluded

  @env_completion_key :ainalrami_env_completion
  @env_trace_key :ainalrami_env_trace
  @env_nofast_key :ainalrami_env_nofast
  @env_cert_key :ainalrami_env_cert
  @env_cert_stats_key :ainalrami_env_cert_stats
  @env_cert_min_key :ainalrami_env_cert_min
  @env_direct_key :ainalrami_env_direct
  @env_direct_plain_key :ainalrami_env_direct_plain
  @direct_budget_key :ainalrami_direct_budget
  # The pruned walk's failed states (see "The pruned walk").
  @direct_memo_key :ainalrami_direct_memo
  # Rows of a dense compatible graph built as an augmenting search reaches
  # them (`memo_row/3`): the bye bootstrap's, and the completability
  # oracle's for the round (see `oracle_dense/2`).
  @dense_rows_key :ainalrami_dense_rows
  # Set when `oracle_dense/2` answered a question the sparse oracle could
  # not, so check mode can hold that bracket to the field path.
  @oracle_dense_key :ainalrami_oracle_dense
  # `direct_edge/5`'s answers for the walk in progress.
  @direct_edge_key :ainalrami_direct_edge
  # The C9 gate of the bracket that built the round matcher, and - after a
  # direct bracket on the field graph - the gate of the one the reference's
  # matcher was built by. See `attempt_direct_field/7`.
  @builder_c9_key :ainalrami_builder_c9
  @virtual_builder_key :ainalrami_virtual_builder

  # Three facts about an active player that the rules ask for over and over
  # within one round - once per candidate EDGE, not once per player - and
  # that cannot change while the round is being paired:
  #
  #   * the ranks of every opponent they have actually PLAYED, as a map, for
  #     C1's no-rematch half of `legal_pair?/2`;
  #   * whether C2 (and the organiser's bye exclusions) let them take the
  #     pairing-allocated bye - `eligible_for_bye?/1`;
  #   * how many games they have played - C9's `unplayed_rank/2`.
  #
  # Each used to be recomputed from the game list at every call: a linear
  # walk of the player's games, with `Trf.game_was_played?/1` trimming a
  # string for every game on the way, twice per edge for eligibility alone
  # (`completion_rung/4` asks it of both ends). On a 300-player round that
  # was the largest single cost after the matcher - around a million game
  # visits to recompute a few hundred answers.
  #
  # Stamped by `with_round_facts/1` on the ACTIVE players, after every
  # round-scoped key the answers depend on (the point system, the bye
  # exclusions) has been stamped, under this one key, as
  # `{met, bye_eligible?, played_count}`. The three readers fall back to the
  # old computation for a player map without it, so a caller reaching them
  # with raw players - `bye_eligibility/2` is public - still gets the same
  # answer. The answers are identical by construction: the same expression,
  # evaluated once instead of many times, under the same stamped state.
  @facts_key :ainalrami_round_facts

  # `pair_variants/3`'s shared work - see "The batch's shared work" above
  # `with_round_facts/1`. `@batch_on_key` is set only while one of its
  # variants is being paired, so nothing else ever reads the state, and
  # neither key is round-scoped: both outlive the rounds of one batch and
  # are deleted by `pair_variants/3` itself.
  @batch_state_key :ainalrami_batch_state
  @batch_on_key :ainalrami_batch_on

  @doc """
  Pairs the next round, dispatching to `pair_round_one/1` when no game
  history exists yet, or the bracket cascade below otherwise.

  `opts[:forbidden_pairs]` is a list of mutually-forbidden starting-rank
  GROUPS, exactly as `Ainalrami.Trf.parse/1` reports a file's `XXP` lines in
  `tournament[:forbidden_pairs]`. Acceleration needs no option: it rides on
  the players themselves, as each player's `:accelerations` list - again
  the shape `Ainalrami.Trf.parse/1` produces from `XXA`.

  ## Bye exclusions (not FIDE)

  `opts[:bye_exclusions]` is a list of starting ranks who must NOT receive
  the pairing-allocated bye this round - an organiser's rule (a player who
  travelled far, a junior whose parents drive an hour), not the Dutch
  system's. Each listed player is treated exactly as [C2] treats a player
  who has already had a pairing-allocated bye: ineligible for the bye, and
  nothing else - their score, colours, floats and every other criterion
  are untouched. A round paired with it is therefore not a Dutch-system
  round in the homologation sense, and a FIDE checker replaying the file
  will not reproduce it.

  Ranks not active this round are ignored, as is the whole option on a
  round with an even number of active players (there is no bye to keep
  anyone from). With the option absent or `[]` the engine runs exactly the
  code it ran before the option existed.

  When the exclusions leave no legal round, `NoValidPairingError` is raised
  with `reason: :bye_exclusions`, the active excluded ranks in `excluded`,
  and in `override` the one rank whose exclusion, lifted, lets the round be
  paired - see the exception's doc. A round that is impossible for reasons
  of its own still raises with `reason: :no_legal_pairing`.

  ## Bye preferences (not FIDE)

  `opts[:bye_preferences]` - per player, "must get", "rather gets",
  "rather not" or "must not get" the pairing-allocated bye, for every round
  or chosen rounds - is resolved by `Ainalrami.ByePreference.pair/2`, which
  also returns an account of what each preference did; this returns its
  pairs. Absent or `[]`, the engine runs exactly the code it ran before the
  option existed.

  ## Input

  Checked once, before any path is chosen - the same checks for this,
  `pair_later_round/2`, `pair_round_one/1`, `explain_round/3` and
  `bye_eligibility/2` - and refused with an `ArgumentError` naming what is
  wrong:

    * `players` - a list of maps, each with an integer `:rank`, a numeric
      `:points` and a `:games` list whose entries carry `:opponent_rank`
      (an integer, or nil); starting ranks distinct over the WHOLE roster,
      players sitting the round out included.
    * `opts` - a keyword list. `:expected_rounds` an integer or nil;
      `:initial_colour` exactly `"w"`, `"b"` or nil; `:point_system` nil
      or a map with numeric `:win`, `:draw`, `:loss`,
      `:pairing_allocated_bye`, `:forfeit_loss` and `:zero_point_bye`;
      `:forbidden_pairs` and `:soft_pairs` lists of groups (a list of
      ranks, or `{ranks, first_round, last_round}`); `:soft_position`
      `:strong`, `:weak` or nil (= `:strong`); `:bye_exclusions` a list of
      ranks; `:bye_passed_over` a boolean. Keys this engine does not read
      are left alone.

  Each refused value used to be read as some OTHER value without a word -
  `initial_colour: "W"` as Black, `soft_position: "weak"` as `:strong` -
  or to fail far from the option that caused it.
  """
  def pair_next_round(players, opts \\ []), do: pair_entry(players, opts, :auto)

  @doc """
  Pairs the next round once for each of several SCORE VARIANTS of one
  position - the same players, histories and options, with some results of
  the round just played (and the totals that go with them) different from
  one variant to the next. The case it is built for is "which boards of the
  next round are already certain while k games are still being played":
  `3^k` variants of one round, each paired as if it were the real one.

  `players` is the position as `pair_next_round/2` takes it, `opts` its
  options, and each variant a map `%{rank => player}` of the players that
  differ from `players` in that variant (`%{}` is `players` itself). The
  answer is one entry per variant, in the order given:

    * `{:ok, pairs}` - exactly what `pair_next_round(variant, opts)` returns,
      pairs, colours and order;
    * `{:error, %NoValidPairingError{}}` - exactly what it raises when no
      legal round exists (the same reason, exclusions and override).

  Any other error is raised, as `pair_next_round/2` would raise it.

  ## Equal to pairing each variant on its own

  That is the contract. What the batch saves is only work whose answer
  cannot differ between variants:

    * the input is checked once, and per variant only the players it
      replaces;
    * the 5.2.5 arrival numbering, the inferred initial colour, and every
      player's colour state, float history and per-round facts are worked
      out once and taken over for every player a variant leaves alone - a
      player's float history is worked out again when they or an opponent
      of the last two rounds changed, everything else when they changed;
    * the certified shortcuts (see "certified shortcuts" in the source),
      which `pair_next_round/2` takes from 100 players up, may be taken at
      any size, or not, variant by variant - whichever has been the faster
      on the variants paired so far. They do not change an answer: each
      read they make is proved to be the reference search's, and a read
      that cannot be proved pairs the round again without them.

  Nothing else is carried from one variant to the next, so the order of
  `variants` does not matter.

  The shared work holds while a variant keeps, for every player it
  replaces, the base's game structure: the same number of games, and in
  each the same opponent, the same colour and the same answer to
  `Ainalrami.Trf.participated_in_pairing?/1`. Points, results (a forfeit
  against the same opponent included) and any other key may differ. A
  variant that changes the structure (a bye turned into a game, a colour
  corrected), and every variant when `:bye_preferences` are in play, is
  paired by `pair_next_round/2` itself.

  How much faster than pairing each variant on its own, and how the
  equality was tested, is in `docs/performance.md` and
  `docs/validation.md` ("Score variants").
  """
  def pair_variants(players, variants, opts \\ []) do
    validate_input!(players, opts)

    if not is_list(variants) do
      raise ArgumentError, "variants must be a list of maps, got #{inspect(variants, limit: 8)}"
    end

    by_rank = Map.new(players, &{&1.rank, &1})
    Enum.each(variants, &validate_variant!(&1, by_rank))

    if Ainalrami.ByePreference.active?(opts) do
      Enum.map(variants, &pair_variant_alone(merge_variant(players, &1), opts))
    else
      Process.put(@batch_state_key, %{current: nil, source: nil})

      try do
        variants
        |> Enum.map_reduce(new_mode_policy(), fn variant, policy ->
          merged = merge_variant(players, variant)

          if same_structure?(variant, by_rank) do
            mode = choose_mode(policy)
            started = System.monotonic_time(:microsecond)
            result = pair_variant_batched(merged, variant, opts, mode)
            {result, record_mode(policy, mode, System.monotonic_time(:microsecond) - started)}
          else
            {pair_variant_alone(merged, opts), policy}
          end
        end)
        |> elem(0)
      after
        Process.delete(@batch_state_key)
        Process.delete(@batch_on_key)
      end
    end
  end

  defp validate_variant!(variant, by_rank) when is_map(variant) do
    Enum.each(variant, fn {rank, player} ->
      if not is_map_key(by_rank, rank) do
        raise ArgumentError, "a variant replaces rank #{inspect(rank)}, which is not a player"
      end

      validate_players!([player])

      if player.rank != rank do
        raise ArgumentError,
              "a variant's player under rank #{rank} carries rank #{inspect(player.rank)}"
      end
    end)
  end

  defp validate_variant!(other, _by_rank) do
    raise ArgumentError,
          "a variant is a map of rank => player, got #{inspect(other, limit: 8)}"
  end

  defp merge_variant(players, variant) when map_size(variant) == 0, do: players

  defp merge_variant(players, variant),
    do: Enum.map(players, &Map.get(variant, &1.rank, &1))

  # Whether every replaced player keeps the base's game structure - what
  # the shared work (`@batch_state_key`) is taken from.
  defp same_structure?(variant, by_rank) do
    Enum.all?(variant, fn {rank, player} ->
      base = Map.fetch!(by_rank, rank)

      length(player.games) == length(base.games) and
        Enum.zip(player.games, base.games)
        |> Enum.all?(fn {g, b} ->
          g.opponent_rank == b.opponent_rank and Map.get(g, :colour) == Map.get(b, :colour) and
            participated_in_pairing?(g) == participated_in_pairing?(b)
        end)
    end)
  end

  defp pair_variant_alone(players, opts) do
    {:ok, pair_next_round(players, opts)}
  rescue
    e in Ainalrami.Pairing.NoValidPairingError -> {:error, e}
  end

  # `pair_without_preferences/3` with the batch's shared work switched on
  # for the pairing itself, and off for `diagnose_exclusions/4`'s second
  # pairing, which runs under other options.
  defp pair_variant_batched(players, variant, opts, mode) do
    Process.put(@batch_state_key, %{Process.get(@batch_state_key) | current: variant})
    Process.put(@batch_on_key, mode)

    try do
      {:ok, do_pair_next_round(players, opts, :auto)}
    rescue
      e in Ainalrami.Pairing.NoValidPairingError ->
        Process.delete(@batch_on_key)
        {:error, diagnose_exclusions(e, players, opts, :auto)}
    after
      Process.delete(@batch_on_key)
    end
  end

  # Which search each variant is paired with. The certified shortcuts
  # ("certified shortcuts" in the source) and the reference search give the
  # same answer, so the choice is free, and it is made on time alone: the
  # shortcuts are several times faster on some positions and slower on
  # others (where most of their reads need certifying), and neighbouring
  # variants of one position cost much the same. Two modes:
  #
  #   * `:plain` - what `pair_next_round/2` does: the shortcuts from
  #     `@cert_min_field` players up (`@cert_min_field_soft` in a round
  #     with soft pairs), the reference search below;
  #   * `:force` - the shortcuts at every size, with their own small-solve
  #     thresholds lifted (as `AINALRAMI_CERT=force`).
  #
  # The first variant is paired `:plain` (it also does the batch's shared
  # work, so its time says nothing about the mode); then each mode once;
  # then the one with the lower running time, with every
  # `@mode_explore_every`-th variant spent on the other one, so a mode that
  # has become the faster is noticed. A third mode, `:off` (the reference
  # search at every size), is never chosen: from 100 players up it was
  # measured at up to fifty times the others, and where `:plain` takes no
  # shortcut it is `:plain`. `AINALRAMI_VARIANT_MODE=off|plain|force` pins one, for the
  # harness and the tests.
  @variant_modes [:plain, :force]
  @mode_explore_every 32

  defp new_mode_policy do
    pinned =
      case System.get_env("AINALRAMI_VARIANT_MODE") do
        "off" -> :off
        "plain" -> :plain
        "force" -> :force
        _ -> nil
      end

    %{pinned: pinned, count: 0, time: %{}, last: %{}}
  end

  defp choose_mode(%{pinned: mode}) when not is_nil(mode), do: mode
  defp choose_mode(%{count: 0}), do: :plain

  defp choose_mode(policy) do
    untried = Enum.reject(@variant_modes, &is_map_key(policy.time, &1))

    cond do
      untried != [] ->
        hd(untried)

      rem(policy.count, @mode_explore_every) == 0 ->
        Enum.min_by(@variant_modes, &Map.fetch!(policy.last, &1))

      true ->
        Enum.min_by(@variant_modes, &Map.fetch!(policy.time, &1))
    end
  end

  # The running time is an exponential average, so it follows the variants
  # as they change.
  defp record_mode(%{count: 0} = policy, _mode, _us), do: %{policy | count: 1}

  defp record_mode(policy, mode, us) do
    time = Map.update(policy.time, mode, us, &div(&1 + us, 2))

    %{
      policy
      | count: policy.count + 1,
        time: time,
        last: Map.put(policy.last, mode, policy.count)
    }
  end

  # The one entry every public pairing call goes through: the input checked
  # once, before any path is chosen (`validate_input!/2`), then the bye
  # preferences resolved - with `path` handed to `ByePreference.pair/3` so
  # the rounds it tries are paired by the same entry point - and only then
  # the round itself. `:auto` lets a round nobody has played in take
  # `pair_round_one/1`'s shortcut; `:later` is `pair_later_round/2`'s
  # contract, the bracket cascade whatever the round.
  # `:proof` - a function called with the round's proof (`Ainalrami.Proof`),
  # or `{:stream, fun}` to have it called with each line as it is written.
  # The option is taken off before pairing, so the engine underneath sees
  # exactly the options it would without it.
  # Options that are not a keyword list go straight through, so the input
  # check refuses them in its own words rather than Keyword.pop in its.
  defp pair_entry(players, opts, path) do
    popped = if Keyword.keyword?(opts), do: Keyword.pop(opts, :proof), else: {nil, opts}

    case popped do
      {nil, opts} -> pair_entry_unproved(players, opts, path)
      {sink, opts} when is_function(sink, 1) -> pair_entry_proved(players, opts, path, sink)
      {{:stream, _} = sink, opts} -> pair_entry_proved(players, opts, path, sink)
      {other, _} -> raise ArgumentError, ":proof takes a 1-arity function, got #{inspect(other)}"
    end
  end

  # The round is paired exactly as without the option, and the answer
  # returned is that one. The proof comes from pairing it a second time on
  # the reference path (`Ainalrami.Proof.reference_flag/1`: no certified
  # shortcuts, no direct brackets, every bracket on the whole field graph),
  # where every bracket decision is read off a weighted matching. The
  # published pairs go first in the proof, and every one of them has to
  # turn up among the pairs the reference path read off a proven-optimal
  # matching: the verifier checks that, not this.
  defp pair_entry_proved(players, opts, path, sink) do
    result = Ainalrami.Proof.run(fn -> pair_entry_unproved(players, opts, path) end)

    emit =
      case sink do
        {:stream, fun} when is_function(fun, 1) ->
          fun

        {:stream, other} ->
          raise ArgumentError, ":proof's stream takes a 1-arity function, got #{inspect(other)}"

        _ ->
          nil
      end

    round = Map.put(outcome_meta(result), "players", length(players))

    {reference, rec} =
      Ainalrami.Proof.capture(
        fn -> pair_entry_unproved(players, opts, path) end,
        :reference,
        round,
        emit
      )

    if rec do
      # The engine's own comparison, for the record; the verifier does not
      # take its word for it.
      text = Ainalrami.Proof.finish(rec, %{"agrees" => same_outcome?(result, reference)})
      if emit == nil, do: sink.(text)
    end

    case result do
      {:ok, pairs} -> pairs
      {:raised, e, stack} -> reraise e, stack
    end
  end

  defp same_outcome?({:ok, a}, {:ok, b}), do: a == b
  defp same_outcome?({:raised, a, _}, {:raised, b, _}), do: a.__struct__ == b.__struct__
  defp same_outcome?(_, _), do: false

  defp outcome_meta({:ok, pairs}), do: %{"pairs" => Enum.map(pairs, &Tuple.to_list/1)}

  defp outcome_meta({:raised, e, _}),
    do: %{"pairs" => nil, "refused" => Exception.message(e)}

  defp pair_entry_unproved(players, opts, path) do
    validate_input!(players, opts)

    if Ainalrami.ByePreference.active?(opts) do
      pair = if path == :later, do: &pair_later_round/2, else: &pair_next_round/2
      players |> Ainalrami.ByePreference.pair(opts, pair) |> elem(0)
    else
      pair_without_preferences(players, opts, path)
    end
  end

  defp pair_without_preferences(players, opts, path) do
    do_pair_next_round(players, opts, path)
  rescue
    e in Ainalrami.Pairing.NoValidPairingError ->
      reraise diagnose_exclusions(e, players, opts, path), __STACKTRACE__
  end

  # Tells "impossible" apart from "impossible because of the organiser's
  # exclusions" by the only honest test there is: pair the same round
  # without them. If that succeeds, the exclusions were the cause, and its
  # bye holder is an excluded player (were it not, that very round would
  # have been legal WITH the exclusions too) - so lifting that one player's
  # exclusion is enough, since the round just computed is then legal.
  #
  # Costs a second pairing, but only on a round that has already failed.
  defp diagnose_exclusions(%{reason: :no_legal_pairing} = e, players, opts, path) do
    excluded = active_excluded(players, opts[:bye_exclusions])

    if excluded == [] do
      e
    else
      try do
        pairs = do_pair_next_round(players, Keyword.delete(opts, :bye_exclusions), path)
        holder = Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

        if holder in excluded do
          %Ainalrami.Pairing.NoValidPairingError{
            message:
              "no legal pairing keeps the pairing-allocated bye away from rank(s) " <>
                "#{Enum.join(excluded, ", ")} (organiser exclusion, not a FIDE rule); " <>
                "lifting the exclusion for rank #{holder} allows one",
            reason: :bye_exclusions,
            excluded: excluded,
            override: holder
          }
        else
          e
        end
      rescue
        Ainalrami.Pairing.NoValidPairingError -> e
      end
    end
  end

  defp diagnose_exclusions(e, _players, _opts, _path), do: e

  defp active_excluded(players, ranks) do
    played = rounds_played(players)
    active = Enum.filter(players, &active_this_round?(&1, played))

    case bye_exclusion_set(ranks, active) do
      nil -> []
      set -> set |> MapSet.to_list() |> Enum.sort()
    end
  end

  # The option, reduced to what can matter this round: the listed players
  # who are actually in it, and only when the round has a bye at all. nil
  # otherwise - which is the value every rule already reads as "no
  # exclusions", so a round the option cannot affect is paired by exactly
  # the code that paired it before the option existed.
  defp bye_exclusion_set(ranks, _active) when ranks in [nil, []], do: nil

  defp bye_exclusion_set(ranks, active) when is_list(ranks) do
    Enum.each(ranks, fn
      rank when is_integer(rank) ->
        :ok

      other ->
        raise ArgumentError,
              ":bye_exclusions must be a list of starting ranks, got #{inspect(other)}"
    end)

    wanted = MapSet.new(ranks)
    set = for p <- active, MapSet.member?(wanted, p.rank), into: MapSet.new(), do: p.rank

    if MapSet.size(set) == 0 or rem(length(active), 2) == 0, do: nil, else: set
  end

  defp bye_exclusion_set(other, _active) do
    raise ArgumentError, ":bye_exclusions must be a list of starting ranks, got #{inspect(other)}"
  end

  # Every key this function stamps is stamped INSIDE the `try`, so its
  # `after` runs whatever raises - the initial-colour inference reads every
  # game, and an option that only fails once it is used (a forbidden group
  # of the wrong shape) used to raise between the first stamps and the
  # `try`, leaving them for the next call in the process to read.
  defp do_pair_next_round(players, opts, path) do
    try do
      # The tournament's total round count, when the caller knows it (a
      # TRF's `XXR`/`142`). Only one rule needs it - the final-round
      # exception in `colour_compatible?/2` - so it is optional rather than
      # a required argument, and stashed rather than threaded through the
      # cascade, matching how the search budget is already carried.
      Process.put(@expected_rounds_key, opts[:expected_rounds])

      Process.put(
        @initial_colour_key,
        opts[:initial_colour] ||
          batch_shared(:initial_colour, fn -> infer_initial_colour(players) end) || "w"
      )

      Process.put(@point_system_key, opts[:point_system] || Ainalrami.Trf.default_point_system())
      stamp_env_flags()

      played = rounds_played(players)

      # After `played`, not before: a `260` group is confined to a range of
      # rounds, so the map cannot be built until the round being paired is
      # known.
      Process.put(@forbidden_key, forbidden_map(opts[:forbidden_pairs], played + 1))
      Process.put(@soft_key, soft_map(opts, played + 1))

      active = Enum.filter(players, &active_this_round?(&1, played))
      Process.put(@bye_excluded_key, bye_exclusion_set(opts[:bye_exclusions], active))

      # `pair_round_one/1` is a shortcut: it knows the whole field is tied
      # on zero, so rank order alone decides the split and nothing has to
      # be searched. Both of this commit's features break that assumption -
      # acceleration means round 1 is NOT a single score group, and a
      # forbidden pair means the S1[i]-vs-S2[i] answer may not be legal -
      # and bbpPairings has no round-one special case for either to be
      # compared against: `computeMatching` runs the same bracket machinery
      # from round 1 on. So when either is in play, so does this. A bye
      # exclusion likewise: the shortcut hands the bye to the lowest-ranked
      # player without asking whether they may have it.
      #
      # `pair_later_round/2` asks for the cascade whatever the round, and
      # gets it.
      pairs =
        if path == :auto and not Ainalrami.Proof.reference?() and
             Enum.all?(active, &(&1.games == [])) and
             is_nil(Process.get(@forbidden_key)) and
             is_nil(Process.get(@soft_key)) and is_nil(Process.get(@bye_excluded_key)) and
             not Enum.any?(active, &(acceleration_at(&1, played) != 0.0)) do
          round_one(active)
        else
          # The FULL roster, not just the active players - float direction
          # has to look up opponents' scores, and an opponent may be one of
          # the players sitting this round out.
          do_pair_later_round(players)
        end

      # `:cascade_order` - the pairs as the cascade found them, unsorted -
      # exists for `Ainalrami.Generator` alone: it draws each board's result
      # in board order, so sorting would change every recorded seed's file,
      # the corpora and the reproductions keyed on them included. Nothing
      # that publishes a board passes it.
      if opts[:cascade_order], do: pairs, else: board_order(pairs, players, played)
    after
      clear_round_state()
    end
  end

  # The pairs in board order, C.04.2 Art. 3.6: the higher score of the
  # pair's higher-ranked player first, then the higher sum of the two
  # scores, then the smaller TPN (starting rank) of the higher-ranked
  # player; the pairing-allocated bye last. "Higher-ranked" is C.04.3 1.2's
  # order - score, then TPN.
  #
  # "Score" is the PAIRING score: an accelerated round's virtual points
  # (`acceleration_at/2`, Baku's C.04.7) count, as they count for every
  # other decision this round. That is VCL4THP Q188's answer, which
  # OpenPairings holds the boards to, and where this parts company with
  # bbpPairings' `sortResults` (`common.cpp:172`), which otherwise sorts on
  # the same three keys but takes `scoreWithoutAcceleration`.
  #
  # The cascade hands its pairs back in the order it found them - bracket
  # by bracket, a downfloater's board inside the bracket that took it in -
  # which is not 3.6's order whenever a heterogeneous bracket or a float is
  # involved: about one round in thirteen of a random 10-30 player event.
  # Ordering is applied once here, at the one exit every pairing path
  # shares, so no caller has to know it was ever otherwise.
  defp board_order(pairs, players, played) do
    points = Map.new(players, &{&1.rank, &1.points + acceleration_at(&1, played)})

    Enum.sort_by(pairs, fn
      {white, nil} ->
        {1, 0, 0, white}

      {white, black} ->
        [higher, lower] = Enum.sort_by([white, black], &{-Map.fetch!(points, &1), &1})
        high = Map.fetch!(points, higher)
        {0, -high, -(high + Map.fetch!(points, lower)), higher}
    end)
  end

  # Every process-dictionary key the pairing and explanation paths stamp,
  # whatever stamped it. One list and one clearing function, run by every
  # public entry point's `after`, rather than one hand-kept subset per entry
  # point: the subsets drifted (the explain path cleared the oracle and the
  # round matcher, the pairing path cleared the certified-mode keys, neither
  # cleared both), and a key missed by one `after` is read by the next
  # tournament paired in the same process. `@cert_stats_key` is not here on
  # purpose: it accumulates across rounds for the benchmarks and is taken
  # with `take_cert_stats/0`.
  @round_state_keys [
    @expected_rounds_key,
    @initial_colour_key,
    @parity_number_key,
    @point_system_key,
    @played_key,
    @forbidden_key,
    @soft_key,
    @bye_excluded_key,
    @bye_score_key,
    @first_single_bye_key,
    @round_matcher_key,
    @dirty_key,
    @cert_key,
    @taint_key,
    @cert_memo_key,
    @oracle_key,
    @dense_rows_key,
    {@dense_rows_key, :bootstrap},
    @oracle_dense_key,
    @direct_budget_key,
    @direct_memo_key,
    @direct_edge_key,
    @builder_c9_key,
    @virtual_builder_key,
    :ainalrami_small_nodes
  ]

  defp clear_round_state do
    Enum.each(@round_state_keys, &Process.delete/1)
    clear_env_flags()
  end

  # `resolveForbiddenPairs` (`tournament.cpp:100-116`): each group is
  # inserted WHOLE into every member's own forbidden set, so an N-player
  # `XXP` line forbids all N*(N-1)/2 pairs within it. A player ends up in
  # their own set, exactly as in the C++ - harmless, since nobody is ever a
  # candidate opponent for themselves.
  #
  # nil rather than an empty map when there is nothing to forbid, so
  # `forbidden_pair?/2`'s hot path is a single process-dictionary read
  # returning nil rather than a map lookup per candidate edge.
  defp forbidden_map(groups, _round) when groups in [nil, []], do: nil

  # A group is either a plain list of starting ranks - `XXP`'s universal
  # form, forbidden for the whole tournament - or `{ranks, first, last}`
  # from a `260` line, forbidden only for rounds `first..last` inclusive.
  # Round-limited groups outside the round being paired are dropped here
  # rather than filtered at every lookup, so the map the cascade sees is
  # always simply "who may this player not meet, now".
  defp forbidden_map(groups, round) do
    map =
      Enum.reduce(groups, %{}, fn group, acc ->
        case applicable(group, round) do
          nil ->
            acc

          ranks ->
            members = MapSet.new(ranks)

            Enum.reduce(
              ranks,
              acc,
              &Map.update(&2, &1, members, fn set -> MapSet.union(set, members) end)
            )
        end
      end)

    if map == %{}, do: nil, else: map
  end

  defp applicable({ranks, first, last}, round) when round >= first and round <= last, do: ranks
  defp applicable({_ranks, _first, _last}, _round), do: nil
  defp applicable(ranks, _round) when is_list(ranks), do: ranks

  @doc """
  Scores an ALREADY-CHOSEN pairing against this engine's own C1-C21
  ladder, bracket by bracket. A diagnostic, not part of pairing.

  `pairs` is `[{white_rank, black_rank | nil}]` - any complete pairing of
  `players`, including one produced by a different engine. The brackets a
  pairing implies are reconstructed from it: score groups top-down, with
  each bracket's unpaired members carried into the next as its MDPs.

  "Complete" is checked, not assumed: every player active this round
  appears exactly once, no other rank appears, nobody is paired with
  themselves, and the pairing gives exactly the pairing-allocated byes the
  round has (one on an odd field, none on an even one, as `{rank, nil}`).
  Anything else raises `ArgumentError` - a player left out is NOT read as
  a player given the bye. The players and options are checked as
  `pair_next_round/2` checks them (see "Input" there).

  Returns one map per bracket. Two halves, and the difference matters:

  **What the pairing produced** - `group`, `mdps`, `residents`, `pairs`,
  `floats`, `rungs: [{label, total}]` (each total that criterion summed over
  the pairs the bracket keeps), `edge_rungs`, `edge_count`, `order`, `lex`.

  **What it was produced FROM** - `s1` / `s2` (Article 4.1's subgroups, the
  seeds in the order they were paired off), `heterogeneous?`, `states` (per
  player: colours had, whites/blacks, signed `difference`, `preference`,
  FIDE `class`, and float history), and `exclusions` - the pairs inside the
  bracket the absolute criteria FORBADE, each tagged `:forbidden`,
  `:rematch` (with the round they met) or `:colour`.

  The second half exists because the first cannot answer a question anyone
  asks. "Why am I not playing him" is a question about a pair that was
  removed before the optimisation began, and until 2026-09-06 the removals
  were computed on every round and then dropped on the floor.

  The point is to adjudicate a disagreement rather than guess at it.
  Score both engines' answers and compare the first bracket where they
  differ:

    * the reference scores BETTER - this engine's search or tie-break
      failed to reach a pairing its own ladder prefers.
    * this engine scores better - then the ladder itself is wrong, since
      the reference would not violate a criterion it implements.
    * identical - the difference is below the criteria entirely, i.e.
      transposition/exchange ordering.

  ## What it cannot see

  **Rungs are only comparable between two answers when the bracket's
  `edge_count` matches.** Each bracket's rungs are a sum over the pairs it
  keeps plus the pairs reaching into the next score group, and the top rung
  counts one per edge. Where one answer pairs a player inside a bracket and
  the other floats them onward, the two windows hold different numbers of
  edges and EVERY rung differs by that accounting alone - including the top
  one, whose label names bye eligibility and whose difference in that case
  has nothing to do with bye eligibility. This misled a real adjudication:
  `seed735265-r7-p10` was recorded as `theirs_scores_better` on
  "C2/C4/C5 bye-eligibility" when the two answers simply placed one and two
  edges in the compared bracket. `edge_count` is reported per bracket so a
  caller can tell the two apart.

  It scores only the pairs a bracket KEEPS, so the two C8 rungs - which
  grade what a pairing leaves reachable in the brackets BELOW - are always
  zero here. C8 outranks every colour and float criterion, so a verdict of
  "this engine scores better on C12" may really mean "the reference is
  better on C8, which this cannot measure". Treat a C12 verdict as a lead,
  not a conclusion, and check the bracket below by hand.

  Verified against `colour_stats/1`, which is a faithful port of
  `computePlayerData` (tournament.cpp:43) rung for rung - including that a
  perfectly balanced player still has a MILD preference for the opposite
  of their last colour, and only a player who has never played has none.
  So a C12 verdict is not evidence of a bug in the colour model.

  ## Bye exclusions

  Takes `pair_next_round/2`'s `:bye_exclusions` (not a FIDE rule), and
  scores under it exactly as the pairing was made. When it is in force and
  the round has a bye, the bracket that holds the bye holder also carries
  `bye_passed_over: [%{rank:, reason: :organiser_exclusion}]` - the excluded
  players who would have received the bye had they not been excluded, in
  the order they would have received it: pairing the round with no
  exclusion gives the bye to the first; excluding just that one gives it to
  the second; and so on until the bye lands on someone the organiser did
  not exclude. Empty when the exclusions changed nothing. Working that out
  re-pairs the round once per name on the list plus once, so a caller that
  only wants the brackets can pass `bye_passed_over: false`. Without the
  option no bracket carries the key.
  """
  def explain_round(players, pairs, opts \\ []) do
    # Before the organiser-exclusion chain, which re-pairs the round and
    # reads the bye holder off `pairs`. The rest of the pairing's shape is
    # `partner_map!/2`'s to check.
    validate_input!(players, opts)
    if not is_list(pairs), do: bad_pairing!("a pairing is a list of pairs, got #{inspect(pairs)}")

    if Ainalrami.ByePreference.active?(opts) do
      explain_with_preferences(players, pairs, opts)
    else
      explain_without_preferences(players, pairs, opts)
    end
  end

  # `:bye_preferences` (not FIDE) resolved the way `pair_next_round/2`
  # resolves them, so the round is scored under the exclusions it was
  # really paired by. The bracket holding the bye carries the account as
  # `bye_preference`. The organiser-exclusion chain is not re-run over the
  # resolved list - for a "must get" wish that list is the whole field
  # but one - unless the caller asks for it.
  defp explain_with_preferences(players, pairs, opts) do
    {_pairs, report} = Ainalrami.ByePreference.pair(players, opts)
    resolved = Keyword.put_new(report.opts, :bye_passed_over, false)
    reports = explain_without_preferences(players, pairs, resolved)
    holder = Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)
    index = Enum.find_index(reports, &(holder in &1.order)) || max(length(reports) - 1, 0)
    account = Map.drop(report, [:opts])
    List.update_at(reports, index, &Map.put(&1, :bye_preference, account))
  end

  defp explain_without_preferences(players, pairs, opts) do
    # Before anything is stamped: it re-pairs the round, and
    # `pair_next_round/2` clears every round-scoped key on its way out.
    passed_over = bye_passed_over(players, pairs, opts)

    players
    |> explain_context(opts, pairs)
    |> explain_pairs(pairs)
    |> attach_passed_over(passed_over, pairs)
  end

  @doc false
  # `explain_round/3` in two halves, for a caller that explains several
  # pairings of the SAME round: everything that does not depend on the
  # pairs - the field with its float history and colour state, the
  # bye-assignee bootstrap (a whole-field matching on an odd field), the
  # weight bands - is worked out once by `explain_context/2`, and
  # `explain_pairs/2` scores one pairing against it.
  #
  # `Ainalrami.Alternatives` is that caller: it scores every forced search
  # it runs, forty or more per round, against the same players under the
  # same options, and paid for the bootstrap every time. `explain_round/3`
  # is these two calls composed, so a report reached either way is the same
  # report. The `:bye_passed_over` account is not part of either half - it
  # re-pairs the round, and only `explain_round/3` asks for it.
  #
  # The context also carries every round-scoped value the rules read, so
  # `explain_pairs/2` can stamp them again: the halves each clean up after
  # themselves, as `explain_round/3` always has.
  #
  # `pairs`, when given, is checked against the round's active players
  # (`partner_map!/2`: every active player exactly once, no rank the round
  # does not have, nobody paired with themselves, and exactly the byes the
  # round has - one on an odd field, none on an even one) at the point
  # where the undivided function built its partner map. The context itself
  # never depends on it. `explain_pairs/2` holds every pairing it scores to
  # the same check, so a pairing that leaves a player out is refused rather
  # than read as giving that player the bye: in the partner map an explicit
  # bye is a `nil` partner, and a player with no entry cannot occur.
  #
  # The players and the options are validated as `pair_next_round/2`
  # validates them, and every key is stamped inside the `try`, so a raise
  # anywhere here leaves no state behind.
  def explain_context(players, opts, pairs \\ :none) do
    # Unresolved bye preferences would be judged as absent here - and by
    # every forced search `Ainalrami.Alternatives` runs on this context -
    # which is a report about a round that was not the one paired.
    if Ainalrami.ByePreference.active?(opts) do
      raise ArgumentError,
            "resolve :bye_preferences first: pass the :opts of " <>
              "Ainalrami.ByePreference.pair/2's report instead"
    end

    try do
      validate_input!(players, opts)
      Process.put(@expected_rounds_key, opts[:expected_rounds])

      Process.put(
        @initial_colour_key,
        opts[:initial_colour] || infer_initial_colour(players) || "w"
      )

      # Stamped for the same reason `pair_next_round/2` stamps it, and missing
      # until 2026-08-26. Every score-dependent rule reads the point system
      # through `game_points/1` and `point_system/0`, so without this they
      # all fell back to 1/=/0 - while this function's whole job is to explain
      # what the PAIRING did. The CLI builds one keyword list and hands it to
      # both, so `openpair file.trf -x` on a file carrying `BB*` lines paired
      # under the file's system and explained under the default one.
      Process.put(@point_system_key, opts[:point_system] || Ainalrami.Trf.default_point_system())
      stamp_env_flags()

      played = rounds_played(players)
      Process.put(@played_key, played)
      Process.put(@forbidden_key, forbidden_map(opts[:forbidden_pairs], played + 1))
      Process.put(@soft_key, soft_map(opts, played + 1))

      Process.put(
        @bye_excluded_key,
        bye_exclusion_set(
          opts[:bye_exclusions],
          Enum.filter(players, &active_this_round?(&1, played))
        )
      )

      # Not read on this path today - `explain_bracket/7` grades a pairing
      # it was handed and never reaches `assign_colour_with_history/1`, so
      # nothing here asks for a number. Stamped anyway, for the reason the
      # point-system stamp above was added on 2026-08-26 after being missing:
      # an entry point that sets only SOME of the state the rules read is a
      # trap for whoever next makes one of those rules reachable from here,
      # and this one would surface as a `Map.fetch!` on an empty map.
      Process.put(@parity_number_key, arrival_numbers(players, played + 1))

      field =
        players
        # Same two stamps, in the same order and over the same whole roster,
        # as `pair_later_round/1` - see its own comment for why float history
        # has to precede acceleration and cannot be scoped to the active
        # field. This used to skip `with_float_history/2` entirely, which
        # silently zeroed C14-C21 on BOTH sides of every verdict this
        # function produced: a round genuinely decided on a float rung was
        # reported as tying there and surfacing further down the ladder. It
        # could never invent a disagreement (both sides were equally blank),
        # only misattribute one, which is the harder failure to notice.
        |> with_float_history(played)
        |> with_acceleration(played)
        |> Enum.filter(&active_this_round?(&1, played))
        |> Enum.sort_by(&{-&1.points, &1.rank})
        |> with_round_facts()

      brackets = field |> Enum.group_by(& &1.points) |> Enum.map(fn {_s, m} -> m end)

      {bye_score, first_single_bye?} = bye_assignee_score(brackets, rem(length(field), 2))
      Process.put(@bye_score_key, bye_score)
      Process.put(@first_single_bye_key, first_single_bye?)

      if pairs != :none, do: partner_map!(pairs, field)
      ctx = global_context(field)

      %{
        field: field,
        ctx: ctx,
        groups: Enum.chunk_by(field, & &1.points),
        points: Map.new(field, &{&1.rank, &1.points}),
        # Every key stamped above, as stamped, for `explain_pairs/2`.
        stamps:
          Enum.map(
            [
              @expected_rounds_key,
              @initial_colour_key,
              @point_system_key,
              @played_key,
              @forbidden_key,
              @soft_key,
              @bye_excluded_key,
              @parity_number_key,
              @bye_score_key,
              @first_single_bye_key
            ],
            &{&1, Process.get(&1)}
          )
      }
    after
      clear_round_state()
    end
  end

  @doc false
  # The pairs-dependent half of `explain_round/3` - see `explain_context/2`.
  # `pairs` is checked against the context's field by `partner_map!/2`.
  def explain_pairs(%{field: field, ctx: ctx, groups: groups, points: points} = context, pairs) do
    try do
      Enum.each(context.stamps, fn {key, value} -> Process.put(key, value) end)
      stamp_env_flags()
      partner = partner_map!(pairs, field)

      groups
      |> Enum.with_index()
      |> Enum.reduce({[], [], ctx.first_single_bye?}, fn {group, i}, {acc, mdps, single_bye?} ->
        next_group = Enum.at(groups, i + 1, [])

        {report, floated} =
          explain_bracket(mdps ++ group, group, next_group, field, partner, ctx, single_bye?)

        {[report | acc], floated, next_single_bye?(ctx, next_group, floated, partner, points)}
      end)
      |> elem(0)
      |> Enum.reverse()
    after
      clear_round_state()
    end
  end

  # The same shape as `bracket_loop/6`'s own gate (dutch.cpp:1608-1643),
  # reconstructed from a finished pairing. The one thing this cannot have
  # is the TENTATIVE match a floating player carried at the moment the
  # bracket closed - that only exists inside the live cascade's persistent
  # matching. It substitutes the FINAL partner, which is the same player
  # whenever the float ends up paired where the tentative match said it
  # would, and a bye-taker reports their own score (an unmatched vertex is
  # its own partner in bbpPairings' convention, dutch.cpp:1637).
  #
  # This replaces a much cruder stand-in (odd field, and an even number of
  # players below the bracket) that ignored both the `byeAssigneeScore >=
  # next group` precondition and the clearing step entirely, and so could
  # score C9 in brackets where the engine itself does not.
  # Who the organiser's exclusions passed over for the bye - see
  # `explain_round/3`'s "Bye exclusions". nil when there is nothing to say:
  # no exclusion that can matter this round, no bye in the pairing, or a
  # caller that asked not to be told.
  #
  # The chain re-pairs with a GROWING subset of the exclusions, starting
  # from none. Each subset is looser than the full list, and the full list
  # was pairable (the round being explained exists), so none of these can
  # fail for a pairing this engine made; one handed in from elsewhere might,
  # and then the chain simply stops where it got to.
  defp bye_passed_over(players, pairs, opts) do
    excluded = active_excluded(players, opts[:bye_exclusions])

    # Runs before `partner_map!/2` has looked at `pairs`, so an entry of
    # the wrong shape is skipped here and refused there, with its reason.
    holder =
      Enum.find_value(pairs, fn
        {w, nil} -> w
        _ -> nil
      end)

    if excluded == [] or is_nil(holder) or opts[:bye_passed_over] == false do
      nil
    else
      base = Keyword.put(opts, :bye_exclusions, [])
      passed_over_chain(players, base, MapSet.new(excluded), [])
    end
  end

  defp passed_over_chain(players, opts, excluded, passed) do
    pairs =
      do_pair_next_round(
        players,
        Keyword.put(opts, :bye_exclusions, Enum.reverse(passed)),
        :auto
      )

    holder = Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)

    if MapSet.member?(excluded, holder) and holder not in passed do
      passed_over_chain(players, opts, excluded, [holder | passed])
    else
      Enum.reverse(passed)
    end
  rescue
    Ainalrami.Pairing.NoValidPairingError -> Enum.reverse(passed)
  end

  defp attach_passed_over(reports, nil, _pairs), do: reports

  defp attach_passed_over(reports, passed, pairs) do
    holder = Enum.find_value(pairs, fn {w, b} -> if is_nil(b), do: w end)
    entries = Enum.map(passed, &%{rank: &1, reason: :organiser_exclusion})

    index =
      Enum.find_index(reports, &(holder in &1.order)) || max(length(reports) - 1, 0)

    List.update_at(reports, index, &Map.put(&1, :bye_passed_over, entries))
  end

  defp next_single_bye?(_ctx, [], _floated, _partner, _points), do: false

  defp next_single_bye?(ctx, next_group, floated, partner, points) do
    next_score = hd(next_group).points

    ctx.odd_field? and not is_nil(ctx.bye_score) and ctx.bye_score >= next_score and
      Enum.all?(floated, fn p ->
        case Map.get(partner, p.rank) do
          nil -> p.points >= next_score
          other -> Map.get(points, other, p.points) >= next_score
        end
      end)
  end

  # The supplied pairing as `%{rank => partner rank | nil}`, `nil` meaning
  # an EXPLICIT pairing-allocated bye - checked against `field`, the round's
  # active players, before anything is scored from it.
  #
  # Until 2026-10-02 the map was built from whatever it was given, and every
  # reader asks it `Map.get(partner, rank)`: a player missing from the
  # pairing came back `nil`, exactly as a player given the bye, so a round
  # with a board left out was explained as a round with an extra bye. A rank
  # listed twice kept its LAST partner and silently dropped the first, and a
  # rank the round does not have was scored against nobody. Each of those is
  # a report about a round that does not exist, so each is refused here
  # instead: every active player exactly once, only active ranks, nobody
  # against themselves, and exactly the byes the round has - one on an odd
  # field, none on an even one, which with full coverage is also the most
  # it can hold.
  defp partner_map!(pairs, field) when is_list(pairs) do
    active = MapSet.new(field, & &1.rank)

    {partner, byes} =
      Enum.reduce(pairs, {%{}, 0}, fn pair, {acc, byes} ->
        case pair do
          {w, nil} ->
            {put_partner!(acc, w, nil, active, pair), byes + 1}

          {w, b} when w == b ->
            bad_pairing!("#{inspect(w)} is paired with themselves")

          {w, b} ->
            acc = put_partner!(acc, w, b, active, pair)
            {put_partner!(acc, b, w, active, pair), byes}

          other ->
            bad_pairing!(
              "each entry is {white_rank, black_rank} or {rank, nil} for the bye, " <>
                "got #{inspect(other)}"
            )
        end
      end)

    case Enum.reject(field, &Map.has_key?(partner, &1.rank)) do
      [] ->
        :ok

      missing ->
        bad_pairing!(
          "active player(s) #{Enum.map_join(missing, ", ", & &1.rank)} are not in it " <>
            "(a bye is {rank, nil}, not an absence)"
        )
    end

    allowed = rem(MapSet.size(active), 2)

    if byes != allowed do
      bad_pairing!(
        "it gives #{byes} pairing-allocated bye(s) where this round of " <>
          "#{MapSet.size(active)} active player(s) has #{allowed}"
      )
    end

    partner
  end

  defp partner_map!(other, _field),
    do: bad_pairing!("a pairing is a list of pairs, got #{inspect(other)}")

  defp put_partner!(acc, rank, partner, active, pair) do
    cond do
      not MapSet.member?(active, rank) ->
        bad_pairing!(
          "#{inspect(pair)} names #{inspect(rank)}, who is not an active player this round"
        )

      Map.has_key?(acc, rank) ->
        bad_pairing!("rank #{rank} appears more than once")

      true ->
        Map.put(acc, rank, partner)
    end
  end

  defp bad_pairing!(why), do: raise(ArgumentError, "invalid pairing to explain: " <> why)

  defp explain_bracket(bracket, group, next_group, field, partner, ctx, single_bye?) do
    ranks = MapSet.new(bracket, & &1.rank)
    score = hd(group).points

    # A bracket member is kept here when their partner is also in it;
    # everyone else floats on and becomes the next bracket's MDP.
    {kept, floated} =
      Enum.split_with(bracket, fn p ->
        case Map.get(partner, p.rank) do
          nil -> false
          other -> MapSet.member?(ranks, other)
        end
      end)

    by_rank = Map.new(bracket, &{&1.rank, &1})

    edges =
      kept
      |> Enum.map(fn p -> Enum.min_max([p.rank, Map.fetch!(partner, p.rank)]) end)
      |> Enum.uniq()

    # The C8 rungs grade what a bracket leaves reachable BELOW it, so they
    # are scored over the pairs that reach from this bracket into the next
    # score group - exactly the edges the real matcher sees with
    # `in_current` false. Leaving them out was this diagnostic's blind
    # spot: C8 outranks every colour and float criterion, so two answers
    # differing only there used to come back as "tie on every rung", and
    # the C12 verdict below them was then read as a colour bug.
    next_ranks = MapSet.new(next_group, & &1.rank)
    cross_by_rank = Map.new(bracket ++ next_group, &{&1.rank, &1})

    cross_edges =
      bracket
      |> Enum.flat_map(fn p ->
        case Map.get(partner, p.rank) do
          nil -> []
          other -> if MapSet.member?(next_ranks, other), do: [{p.rank, other}], else: []
        end
      end)
      |> Enum.uniq()

    # Sized over the WHOLE FIELD, exactly as the engine sizes it
    # (`pair_bracket/6`: `score_places(combined)`, `count_span = m + 1`).
    #
    # This used `bracket ++ next_group`, which broke comparability twice
    # over. Against the engine: rung values that depend on `places` -- C7,
    # C8, C18-C21 -- sat on a different radix here than in the weights they
    # are supposed to explain, so an `explain_round` number could never be
    # held against an engine weight. And between two ANSWERS: the bracket
    # composition depends on which players each answer floats, so two reports
    # of the same position were scaled differently from each other, which is
    # the thing an adjudicator does nothing but compare.
    {places, place_span} = score_places(field)
    count_span = length(field) + 1

    bands = %{
      places: places,
      place_span: place_span,
      count_span: count_span,
      reserve: 2 * count_span * count_span * count_span
    }

    kept_rungs =
      Enum.map(edges, fn {x, y} ->
        {a, b} = order_by_placement(Map.fetch!(by_rank, x), Map.fetch!(by_rank, y))
        edge_rungs(a, b, 0, ctx, bands, single_bye?)
      end)

    cross_rungs =
      Enum.map(cross_edges, fn {x, y} ->
        {a, b} = order_by_placement(Map.fetch!(cross_by_rank, x), Map.fetch!(cross_by_rank, y))
        edge_rungs(a, b, 1, ctx, bands, single_bye?)
      end)

    rungs = sum_rungs(kept_rungs ++ cross_rungs)
    {s1, s2} = subgroups(bracket, score)

    {%{
       group: score,
       # The same rungs, before they were summed: one entry per edge, in the
       # order `pairs ++ the cross edges the floats leave on`. A bracket's
       # `rungs` are exactly the column-wise sum of these, so a caller can
       # say WHICH pair carries a criterion's cost rather than only that the
       # bracket paid it.
       #
       # These were computed and thrown away for as long as this function has
       # existed; keeping them costs nothing and answers the question an
       # arbiter actually asks, which is never "why did this bracket score
       # 6" but "why is THIS board like that".
       #
       # Caveat for anyone rendering them: the top rung counts one per edge,
       # so every pair contributes exactly one there and it discriminates
       # nothing per-pair. It is the bracket-level total that means
       # something.
       edge_rungs: per_edge_rungs(edges ++ cross_edges, kept_rungs ++ cross_rungs),
       mdps: bracket |> Enum.filter(&(&1.points > score)) |> Enum.map(& &1.rank),
       residents: Enum.map(group, & &1.rank),
       pairs: edges,
       floats: Enum.map(floated, & &1.rank),
       rungs: rungs,
       # How many edges this bracket's rungs were summed over. Every rung
       # here is a SUM over `kept ++ cross`, and the leading term of the top
       # rung is one per edge -- so when two answers put different numbers of
       # edges in the same bracket's window, every rung differs for that
       # reason alone and none of the differences are criterial. Two answers
       # are only comparable rung by rung when this number matches; the
       # adjudicator reads it to say so rather than reporting a verdict it
       # cannot support. See `explain_round/3`'s "What it cannot see".
       edge_count: length(edges) + length(cross_edges),
       order: Enum.map(bracket, & &1.rank),
       lex: transposition_key(bracket, group, partner),
       # ---- the state the decision was made FROM ----
       #
       # Everything above describes the OUTCOME: who ended up where, and
       # what the criteria cost. None of it can answer the question an
       # arbiter is actually asked, which is never "why did this bracket
       # score 6" but "why am I not playing HIM". That question is about a
       # pair the engine could not use, and the pairs it could not use were
       # computed and discarded on every round this engine has ever paired.
       #
       # So: the subgroups the pairing was built from, each player's colour
       # and float state, and the pairs the absolute criteria removed.
       heterogeneous?: s1 != [] and hd(s1).points > score,
       s1: Enum.map(s1, & &1.rank),
       s2: Enum.map(s2, & &1.rank),
       states: Enum.map(bracket, &player_state/1),
       exclusions: exclusions(bracket)
     }, floated}
  end

  # One bracket member's state, as a person would read it off a scoresheet:
  # the colours they have actually had, what that makes them due, and
  # whether they have floated recently (which is what C14-C21 grade).
  defp player_state(player) do
    stats = player.colour_stats
    floats = Map.get(player, :floats, %{})

    %{
      rank: player.rank,
      points: player.points,
      colours: stats.colours,
      whites: stats.whites,
      blacks: stats.blacks,
      difference: stats.difference,
      preference: stats.preference,
      class: colour_class(stats),
      repeated: stats.repeated,
      floated_last_round: Map.get(floats, 1),
      floated_round_before: Map.get(floats, 2)
    }
  end

  # Every pair INSIDE this bracket that the absolute criteria forbid, and
  # why. This is the half of the reasoning that was always computed and
  # never kept: the matcher applies these as edge filters and then optimises
  # over what survives, so the report described the optimisation and could
  # say nothing at all about the filter. "Why am I not playing him" is a
  # question about a filtered edge, every time.
  #
  # O(n^2) over the bracket, which is what it has to be - the subject is
  # pairs that do NOT exist, so there is nothing smaller to walk. It is also
  # cheap where it matters: brackets are score groups and shrink as the
  # tournament goes on, and the one bracket that holds the whole field is
  # round one, where nobody has played anybody and the result is empty.
  defp exclusions(bracket) do
    for a <- bracket, b <- bracket, a.rank < b.rank do
      exclusion_reason(a, b)
    end
    |> Enum.reject(&is_nil/1)
  end

  # First reason wins, most decisive first: a rematch ends the conversation
  # in a way a colour clash does not, and a pair can be both.
  defp exclusion_reason(a, b) do
    met = met_in_round(a, b)

    cond do
      forbidden_pair?(a.rank, b.rank) ->
        %{players: [a.rank, b.rank], reason: :forbidden}

      met != nil ->
        %{players: [a.rank, b.rank], reason: :rematch, round: met}

      not colour_compatible?(a, b) ->
        %{
          players: [a.rank, b.rank],
          reason: :colour,
          colour: a.colour_stats.preference
        }

      true ->
        nil
    end
  end

  defp met_in_round(a, b) do
    case Enum.find_index(a.games, &(played?(&1) and &1.opponent_rank == b.rank)) do
      nil -> nil
      index -> index + 1
    end
  end

  @doc """
  FIDE Article 4.1's S1/S2 split of one bracket, given that bracket's own
  score.

  A homogeneous bracket halves: S1 is the top half in Article 1.2 order, S2
  the bottom, and the pairing is S1[i] against S2[i] before transpositions
  and exchanges move it. A heterogeneous one splits differently - S1 is the
  players MOVED DOWN into it, S2 everyone who belongs there - because the
  moved-down players are paired off against the residents first.

  Public, and used by both `transposition_key/3` and `explain_round/3`, so
  that the split a report SHOWS is by construction the split the pairing
  USED. Two copies of this rule that drifted apart would produce a panel
  that quietly described a different tournament than the one on the board.
  """
  def subgroups(bracket, score) do
    case Enum.split_with(bracket, &(&1.points > score)) do
      {[], _residents} -> Enum.split(bracket, div(length(bracket), 2))
      {mdps, residents} -> {mdps, residents}
    end
  end

  # FIDE section 3's transposition order, as a comparable key.
  #
  # Articles 3.3-3.5 pick the SMALLEST transposition of the natural order,
  # and "smallest" is lexicographic over S2 - which member of S2 faces
  # S1[0], then S1[1], and so on, with the identity permutation smallest.
  # So the key is the S2 INDEX of each S1 member's opponent, in S1 order,
  # and a smaller key wins.
  #
  # Getting this wrong is easy and was: a first attempt keyed on absolute
  # bracket position, which makes the natural pairing (0 vs k, 1 vs k+1)
  # look large and the adjacent pairing (0 vs 1) look smallest - the
  # opposite of the Dutch structure. It is also why `spread` in
  # `within_bracket_weight/4` is load-bearing rather than decorative:
  # maximising rank distance is what produces the S1-vs-S2 halving in the
  # first place, and removing it measured 90.29% -> 42.21% of rounds.
  @doc """
  Article 4.2's transposition order for one bracket, as a comparable key.

  Returns, for each S1 member in Article 1.2 order, the INDEX in S2 of the
  player they face (or `length(s2)` when they are unpaired). Smaller wins,
  compared lexicographically.

  **This is 4.2.2's ordering exactly, not an approximation of it.** The
  article sorts transpositions by "the lexicographic value of their first N1
  BSN(s)" - the BSNs of the players facing S1[0], S1[1], … S2 is sorted by
  Article 1.2 and BSNs are assigned in that same order (4.1.1), so a member's
  index in S2 and their BSN rank within S2 increase together. Lexicographic
  comparison over indices therefore induces the identical order as
  lexicographic comparison over BSNs. `sequence_test.exs` checks this against
  `Ainalrami.Sequence.transpositions/2` rather than leaving it as an argument.

  What it does NOT cover is Article 4.3. Once every transposition of a given
  S1/S2 has been tried, the regulations *exchange* players between the two
  subgroups and start the sequence again, reaching candidates no transposition
  can. Those candidates are still considered here - the matcher searches every
  matching - but ties among them are not ranked by generation order, and that
  is the whole of the remaining divergence from 3.8.1.
  """
  def transposition_key(bracket, group, partner) do
    {s1, s2} = subgroups(bracket, hd(group).points)

    s2_index = s2 |> Enum.map(& &1.rank) |> Enum.with_index() |> Map.new()
    unpaired = length(s2)

    Enum.map(s1, fn p ->
      case Map.get(partner, p.rank) do
        nil -> unpaired
        other -> Map.get(s2_index, other, unpaired)
      end
    end)
  end

  defp order_by_placement(x, y) do
    if {-x.points, x.rank} <= {-y.points, y.rank}, do: {x, y}, else: {y, x}
  end

  # Pairs each edge with its own rung vector, dropping the internal span
  # term that only `sum_rungs/1` and the weight model need. Returned as a
  # list rather than a map because an edge is a tuple, and a caller that
  # wants it keyed can do that itself.
  defp per_edge_rungs(edges, per_edge) do
    Enum.zip_with(edges, per_edge, fn edge, rungs ->
      {edge, Enum.map(rungs, fn {label, value, _span} -> {label, value} end)}
    end)
  end

  defp sum_rungs([]), do: []

  defp sum_rungs([first | _] = per_edge) do
    Enum.with_index(first)
    |> Enum.map(fn {{label, _v, _span}, i} ->
      {label, Enum.sum(Enum.map(per_edge, fn rungs -> elem(Enum.at(rungs, i), 1) end))}
    end)
  end

  @doc """
  Pairs the very first round.

  Per FIDE C.04.3 Article 1: split the full field into two equal halves by
  rank (S1 = top half, S2 = bottom half - everyone is tied on 0 points, so
  rank order alone determines the split); an odd field first removes the
  lowest-ranked player for the pairing-allocated bye, then splits the
  remaining even field. Pair S1[i] against S2[i].

  Confirmed against real `javafo.jar` output for 7/8/9/10/11/12/13-player
  fields, not assumed from the spec text alone.

  Colours (Article 5.1/5.2.5): 5.2.5 hands the higher ranked player of each
  pair the initial colour when their number is odd and the opposite when it
  is even. That number is NOT the TPN: per the SPP's 2026-08-27 ruling on
  C.04.2 Article 2.4, players who have not yet arrived are not numbered at
  all, so it is the player's position among the arrivals. See
  `arrival_numbers/2`. In round one the distinction is invisible - the whole
  field is being paired, so every player has arrived and the position is the
  rank - but it is computed rather than assumed here so the two code paths
  state the same rule.

  Article 5.1's *draw* is a different matter, and FIDE leaves the very first
  colour to a literal "drawing of lots" - there is no deterministic rule to
  replicate.
  This picks a fixed, documented convention rather than JaVaFo's own
  choice, which is empirically NOT a function of the roster/round-count
  alone: pairing the identical 8-player roster and round count under two
  different tournament *names* produced opposite initial colours from
  JaVaFo - strong evidence it's seeded from something incidental (a hash
  of the input file, most likely), not a reproducible rule. Colour output
  will legitimately not always match JaVaFo's own for this reason; pairing
  *composition* (who plays whom) is the thing that should match, and does
  - see the comparison harness in `test/ainalrami/javafo_comparison_test.exs`.

  The roster is checked as `pair_next_round/2` checks it (see "Input" there)
  and must be a round nobody has played in: a player with any game raises
  `ArgumentError`, since the rank split above is only Article 1's answer
  when everyone is tied on zero. It takes no options - a round one with
  forbidden pairs, acceleration or a recorded drawing of lots is
  `pair_next_round/2`'s.
  """
  def pair_round_one(players) do
    validate_players!(players)

    case Enum.find(players, &(&1.games != [])) do
      nil ->
        :ok

      p ->
        raise ArgumentError,
              "pair_round_one/1 pairs a round nobody has played in, and rank #{p.rank} " <>
                "has #{length(p.games)} game(s) - use pair_next_round/2"
    end

    players |> round_one() |> board_order(players, 0)
  end

  defp round_one(players) do
    sorted = Enum.sort_by(players, & &1.rank)

    # 5.2.5's number, built locally rather than read from
    # `@parity_number_key`. This function is PUBLIC and is called directly -
    # by `pairing_test.exs` and by the javafo harness - with none of the
    # round-scoped process state stamped, so a key would be nil on exactly
    # those paths and the parity would silently fall back to the overturned
    # reading.
    #
    # Building it here is not an approximation. This branch is only taken
    # when nobody in the tournament has ever been paired: `pair_next_round/2`
    # requires every active player to have `games == []`, and `rounds_played/1`
    # is 0 only when no player anywhere holds a `participated_in_pairing?`
    # game. So "has arrived" is exactly "is in `sorted`", and the number is
    # the 1-based index in rank order.
    #
    # Numbered over `sorted`, not over `field`: the odd-field bye player is
    # removed from `field` below but is being PAIRED and must be counted.
    # They are last in rank order, so today the two coincide - numbering
    # over `sorted` is the version that stays right if the bye selection
    # ever changes.
    numbers = sorted |> Enum.with_index(1) |> Map.new(fn {p, n} -> {p.rank, n} end)

    {bye, field} =
      if rem(length(sorted), 2) == 1 do
        {List.last(sorted), List.delete_at(sorted, -1)}
      else
        {nil, sorted}
      end

    half = div(length(field), 2)
    {s1, s2} = Enum.split(field, half)

    pairs =
      s1
      |> Enum.zip(s2)
      |> Enum.map(fn {top, bottom} ->
        assign_colour_round_one(top, bottom, Map.fetch!(numbers, top.rank))
      end)

    if bye, do: pairs ++ [{bye.rank, nil}], else: pairs
  end

  # Article 5.1 leaves the initial colour to a drawing of lots taken before
  # round one, and TRF's `152` is where that draw is recorded. When a file
  # omits it, the draw is NOT unknown and must not be guessed at: round
  # one's own colours ARE the record of it, and reconstructing the draw from
  # them is reading the data rather than assuming a convention.
  #
  # Assuming White cost 1954 disagreeing boards per 600 bye-heavy
  # tournaments and none at all without byes, which is the signature of
  # exactly this: the assumption only breaks when the players who would have
  # revealed the draw sat round one out.
  #
  # THE RULE: take the LOWEST-RANKED player who holds a colour in the first
  # round that records any, and read the parity of THEIR number. Odd means
  # they held the initial colour, so their colour IS the draw; even means
  # they held its opposite, so invert.
  #
  # The number is the arrival number, not the TPN. Since the SPP's
  # 2026-08-27 ruling (see `arrival_numbers/2`) 5.2.5's parity is taken on
  # the player's position among those who had ARRIVED, and reading the raw
  # TPN here would disagree with the allocation on exactly the fields where
  # somebody sat a round out. See RAW-TPN SPLITS below for the measurement.
  #
  # The numbering has to be the one in force in the round the observed
  # colour was RECORDED in, not the one for the round about to be paired:
  # `first_coloured` is an index into `p.games`, so that round is
  # `first_coloured + 1`, and `arrival_numbers_at/2` builds the numbering as
  # of it. Using the current round's numbering would be a different rule
  # whenever anybody arrived in between.
  #
  # ## This is NOT an exact inverse of the allocation, deliberately
  #
  # `assign_colour_round_one/3` takes the parity of the TOP of the board -
  # "higher ranked" is Article 1.2, SCORE first and TPN only to break the
  # tie, via `order_by_placement/2`. This reads the parity off whichever
  # player happens to hold a colour, without asking whether they were the
  # top or the bottom.
  #
  # The two coincide only when the first coloured round is round ONE: every
  # player is then on zero, so "higher ranked" collapses to the lower TPN,
  # and the lowest-ranked player holding a colour anywhere in the field is
  # necessarily a top. Let round one record nothing but H/F/Z byes and
  # forfeits and the first coloured round is round TWO or later, where the
  # scores already differ - a downfloat can seat a low-TPN low-score player
  # as the BOTTOM, and the two readings then answer opposite.
  #
  # An exact inverse was written on 2026-08-28 and REVERTED the same day,
  # because bbpPairings v6.0.0 does not do it either and this file's job is
  # to reproduce the reference, not to out-reason it.
  #
  # The instrument is `tools/inference_numbering_probe.exs`. It serialises
  # the identical roster three times - no `152`, `152 W`, `152 B` - and
  # hands all three to the real binary. The two stated runs are the
  # alternatives; whichever one the silent run reproduces IS bbpPairings'
  # deduction, read off bbpPairings' own output with this engine nowhere in
  # the loop. It re-derives both candidate readings itself rather than
  # calling in here, and `INP_SELFTEST=1` swaps them before the classifier
  # to prove the losing column is a live tally and not a dead arm.
  #
  # Run 2026-08-28: 200 tournaments, 7 rounds, seeds 1-200, round one all
  # byes so the first coloured round is round two. Four quantities, kept
  # separate because they have separate denominators:
  #
  #   * READABLE POSITIONS, 189, from 142 distinct tournaments - positions
  #     where the two stated runs differed and the silent one matched
  #     exactly one. bbpPairings was read as deducing White on 87 of them
  #     and Black on 102, so it is deducing rather than defaulting.
  #   * SPLIT POSITIONS, 38 of those 189, from 26 tournaments - where this
  #     reading and the exact inverse predict OPPOSITE draws. bbpPairings
  #     followed the coloured player's own number 38 times and the
  #     top-of-board number 0. Under `INP_SELFTEST=1` the same run reports
  #     0 and 38.
  #   * RAW-TPN SPLITS, 52 of those 189 - where this reading and the
  #     overturned raw-TPN reading predict opposite draws. bbpPairings
  #     followed the arrival numbering 52 times and the raw TPN 0, so the
  #     arrival numbering is genuinely exercised and the flat result above
  #     is not a corpus that never reached the rule.
  #   * Over all 189 readable positions this reading predicted
  #     bbpPairings' deduction 189 times and missed 0.
  #
  # These replace an earlier set - 17/17/0, "27 times in 106", and an "81
  # positions in 600 fields" that also appeared as a conformance total. No
  # script in the tree produced any of them, and they are not preserved.
  # The CONCLUSION they were offered for is the one measured above and it
  # holds; the numbers themselves were unreproducible and are gone.
  #
  # bbpPairings is therefore asymmetric with ITSELF here, which is worth
  # stating plainly: on those same fields its ALLOCATION does hand the
  # initial colour to the higher-SCORED player (checked forwards, with
  # `152` present, and we match it board for board). So a file bbpPairings
  # paired with `152` present does not round-trip through bbpPairings' own
  # deduction with `152` stripped. We copy the asymmetry.
  #
  # No article decides this. 5.1 leaves the initial colour to a drawing of
  # lots and `152` is the record of it; where the record is missing C.04.3
  # says nothing whatsoever, so the reference's behaviour is the only rule
  # there is. Preferring our own derivation to the measured reference on a
  # point the text does not cover is precisely the mistake the SPP caught
  # this engine making one article up.
  #
  # Pinned in `test/ainalrami/bbppairings_comparison_test.exs`, which
  # re-runs the three-way file comparison above on two hand-built fields
  # rather than asserting our own answer back to us. The probe is the same
  # comparison at corpus scale; the tests are the two positions that must
  # not silently start passing for the wrong reason.
  #
  # CONFORMANCE is a fourth quantity and deliberately not folded into the
  # three above: the same probe run also compared this engine's whole
  # pairing - colours included - against bbpPairings' silent run on all 189
  # readable positions, and got 189 identical, 0 differing, 0 raised. That
  # one has this engine in the loop and answers a different question.
  #
  # A player with no number at that round is skipped rather than guessed
  # at. It cannot happen for a player who HOLDS a colour there - a colour
  # means an opponent, which is an arrival - but the map is the authority
  # and `Enum.find_value/2` simply moves to the next player.
  #
  # Returns nil when the file records no colours at all - before round one
  # there is genuinely nothing to infer from, which real bbpPairings treats
  # as fatal rather than guessable.
  defp infer_initial_colour(players) do
    ranked = Enum.sort_by(players, & &1.rank)

    first_coloured =
      ranked
      |> Enum.flat_map(fn p ->
        p.games |> Enum.with_index() |> Enum.filter(&(elem(&1, 0).colour != nil))
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.min(fn -> nil end)

    if first_coloured do
      numbers = arrival_numbers_at(ranked, first_coloured + 1)

      Enum.find_value(ranked, fn p ->
        case {Enum.at(p.games, first_coloured), Map.get(numbers, p.rank)} do
          {%{colour: c}, number} when c in ["w", "b"] and is_integer(number) ->
            if rem(number, 2) == 1, do: c, else: invert(c)

          _ ->
            nil
        end
      end)
    end
  end

  # `top` is always the better-ranked (lower rank number) of the pair, since
  # both halves are traversed in ascending rank order before zipping.
  #
  # `top_number` is 5.2.5's number for `top` - its position among the
  # players who have arrived, NOT its TPN. See `arrival_numbers/2` for the
  # ruling that separated the two. It is passed in rather than computed
  # because the numbering is a property of the ROUND: computing it here
  # would rebuild it once per board, which is the exact class of regression
  # `score_before/3` and `legal_pair?/2` have already cost this file once
  # each.
  defp assign_colour_round_one(top, bottom, top_number) do
    # 5.2.5: `top` holds the initial colour on an odd number and the
    # opposite on an even one. The initial colour comes from the file's
    # `152` field, or is reconstructed by `infer_initial_colour/1` when the
    # file is silent.
    initial_white? = Process.get(@initial_colour_key, "w") == "w"
    top_takes_initial? = rem(top_number, 2) == 1

    if top_takes_initial? == initial_white? do
      {top.rank, bottom.rank}
    else
      {bottom.rank, top.rank}
    end
  end

  @doc """
  Pairs a round from existing score/game history.

  `opts` are exactly `pair_next_round/2`'s, checked and resolved by the same
  code - soft pairs, bye exclusions and bye preferences included - and the
  input is validated the same way. The one difference is the path: this
  never takes `pair_round_one/1`'s shortcut, so a round nobody has played
  in is paired by the cascade below too. Prefer `pair_next_round/2`.

  Until 2026-10-02 this was a second, hand-kept copy of the option
  handling, and it had drifted: `:soft_pairs` and `:bye_preferences` were
  accepted and silently ignored, and its process state was stamped before
  its `try`, so a raise there leaked into the next call.

  Forms score brackets (Article 1.2: ranked by score, then TPN ascending)
  in descending order and pairs them in one continuous solve. Every
  unfinalised player in the field is a vertex in every bracket's matching;
  weights are bracket-flavoured, so a pair two or more score groups away
  scores only the completion rung and C9 - which is exactly the weight
  bbpPairings leaves on its own out-of-window edges. Players a bracket
  cannot pair float down and merge with the next one (Articles
  1.3.3/3.2/3.3), ranked ahead of that bracket's residents by their higher
  score, which falls out of re-sorting by Article 1.2 directly.

  The matcher is `Ainalrami.WeightedMatching.solve/2` - a Galil/Micali/Gabow
  primal-dual maximum-weight general matching. The criteria and their
  priority order are ported from bbpPairings' `computeEdgeWeight`
  (`swisssystems/dutch.cpp`) and packed into one integer per edge by
  `edge_rungs/6`: completion and bye eligibility, C6/C7 (pairs and scores
  within the bracket), C8 (the same one bracket down), C9 (the bye
  assignee's unplayed games), C10-C13 (colour), C14-C17 (float history) and
  C18-C21 (score-weighted float history).

  ## Accuracy

  Against **bbpPairings 6.0.0**, which implements the same 2026 rules this
  engine targets: **100.00% of rounds and of individual pairs** across
  roughly 4.3 million tournaments and 195 million pairings, over axes
  varying field size (4-120), round count (6-10), arbiter byes, forfeits,
  `XXP` exclusions and `XXA` acceleration. One disagreement in that whole
  corpus, `seed735265-r7-p10`, where Gacrux - a third independent
  implementation - sides with this engine.

  Against **javafo.jar** it measures ~96%, and that gap is the control
  rather than an error: javafo implements the 2017 edition, so an engine
  agreeing with all three at once would mean the comparison was measuring
  nothing. See docs/engineering-log.md for the measured history.

  ## Do not "simplify" the scoring terms without re-measuring

  Several plausible-sounding changes have each been measured WORSE and
  reverted (see docs/engineering-log.md): a bipartite S1-vs-S2 restriction (10.7%), a
  whole-bracket natural-correspondence deviation metric (64.95%),
  subordinating the float protections to the pair criteria (-7 points), and
  emitting the next-bracket lookahead as real cross-bracket pairs
  (86.40% -> 43.82% of rounds). The terms are empirical, not derived.

  Two of the criteria are invisible outside the final round by
  construction: `bracket_edge_weight/8` only creates an edge where
  `colour_compatible?/2` holds, which already rejects a same-absolute-colour
  clash, so the C10/C11 rungs are constant across candidate matchings except
  where `final_round_topscorers?/2` admits such a pair.
  """
  def pair_later_round(players, opts \\ []), do: pair_entry(players, opts, :later)

  defp do_pair_later_round(players) do
    played = rounds_played(players)
    Process.put(@played_key, played)

    # 5.2.5's numbering, built ONCE for the round from the FULL roster -
    # not from `active` below. Both halves of the arrival test need it: a
    # player who played round 1 and sits round 2 out has arrived but is not
    # active, and a player who has never been paired but is in this round's
    # pool has arrived and is.
    Process.put(
      @parity_number_key,
      batch_shared(:arrival, fn -> arrival_numbers(players, played + 1) end)
    )

    field =
      players
      # Float history first, over the WHOLE roster: `float_direction/4`
      # compares against the opponent's score at the time, and that
      # opponent may be sitting this round out. It runs BEFORE
      # `with_acceleration/2` on purpose - `score_before/3` reconstructs a
      # historic score by subtracting later results from the current one,
      # so it needs the REAL score to subtract from, and adds that round's
      # own acceleration itself.
      |> batch_float_history(played)
      |> with_acceleration(played)

    active =
      field
      |> Enum.filter(&active_this_round?(&1, played))
      |> batch_round_facts()

    brackets =
      active
      |> Enum.group_by(& &1.points)
      |> Enum.sort_by(fn {score, _} -> -score end)
      |> Enum.map(fn {_score, members} -> members end)

    # Exactly one pairing-allocated bye in an odd field, none in an even
    # one. Counted over the ACTIVE players - a field of even size with one
    # player sitting out needs a bye, and one of odd size with one sitting
    # out does not.
    allowed_byes = rem(length(active), 2)

    {bye_score, first_single_bye?} = bye_assignee_score(brackets, allowed_byes)
    Process.put(@bye_score_key, bye_score)
    Process.put(@first_single_bye_key, first_single_bye?)

    try do
      case certified_cascade(brackets, allowed_byes) do
        {:ok, pairs, leftover} ->
          # `global_cascade/2` returns `:ok` only after `check_completion/3`
          # has passed on exactly these pairs and this leftover, so the round
          # is already known legal here: bye count, C2 eligibility and the C5
          # bye score. A `repair_bye_count/3` pass used to follow, guarded by
          # a `bye_legal?/3` that restated two of those three tests over the
          # same set - provably true whenever it was reached, so its repair
          # branch, and with it every use of `Ainalrami.Blossom`, could not
          # run. Both are gone; see docs/engineering-log.md.
          pairs ++ Enum.map(leftover, &{&1.rank, nil})

        :infeasible ->
          # `global_cascade/2` only reports this once its own completion
          # repair - a whole-field maximum matching - has also failed to
          # pair everyone, which means no legal round exists at all.
          # bbpPairings answers the same case the same way, with
          # `NoValidPairingException`.
          raise Ainalrami.Pairing.NoValidPairingError,
                "no legal pairing exists for #{length(active)} active player(s)"
      end
    after
      Process.delete(@bye_score_key)
      Process.delete(@round_matcher_key)
      Process.delete(@oracle_key)
      Process.delete(@dense_rows_key)
      Process.delete(@oracle_dense_key)
      Process.delete(@dirty_key)
      Process.delete(@first_single_bye_key)
      Process.delete(@cert_key)
      Process.delete(@taint_key)
      Process.delete(@cert_memo_key)
      Process.delete(@virtual_builder_key)
      Process.delete(@builder_c9_key)
    end
  end

  # `global_cascade/2` with the certified shortcuts allowed, and - if a
  # shortcut's state ever meets a read it cannot certify - again from the
  # start without them, which is the reference computation exactly: every
  # round-scoped key the cascade uses is (re)initialised at its entry, and
  # nothing before this call depends on the attempt.
  #
  # Unless forced: from `@cert_min_field` players up, and from
  # `@cert_min_field_soft` in a round with the arbiter's soft pairs. Both
  # measured (docs/performance.md, "The certified shortcuts' threshold").
  # Below ~30 players the searches are cheap and the reads the most often
  # tied, so the shortcuts mostly buy certification work. Soft pairs switch
  # the direct bracket off (`direct_allowed?/2`), which leaves the shortcuts
  # little to skip and nearly every read to certify: 5-15% slower at 100-200
  # players, 10-25% faster in the opening round from 300 up - so those
  # rounds keep the old line rather than gain a new one. It used to be 100
  # everywhere, a figure nobody had timed.
  @cert_min_field 30
  @cert_min_field_soft 100

  defp certified_cascade(brackets, allowed_byes) do
    size = brackets |> Enum.map(&length/1) |> Enum.sum()

    # `pair_variants/3` may ask for them at every size, or not at all: see
    # `choose_mode/1`.
    if cert_enabled?() and Process.get(@batch_on_key) != :off and
         (cert_worth?(size) or cert_force?()) do
      Process.put(@cert_key, true)

      try do
        global_cascade(brackets, allowed_byes)
      catch
        :throw, {:cert_abort, reason} ->
          cert_count(:abort)
          cert_count({:abort, reason})
          Process.put(@cert_key, false)
          global_cascade(brackets, allowed_byes)
      end
    else
      Process.put(@cert_key, false)
      global_cascade(brackets, allowed_byes)
    end
  end

  # AINALRAMI_CERT=off takes the reference path everywhere; =force takes
  # every shortcut there is, however small the solve it saves (for the
  # corpus, which is mostly small fields).
  defp cert_enabled?, do: env_flag(@env_cert_key, "AINALRAMI_CERT") != "off"

  # AINALRAMI_CERT_MIN=<n> puts both thresholds at n: the threshold study's
  # knob, and with n = 100 the behaviour before it.
  defp cert_worth?(size) do
    min =
      case env_flag(@env_cert_min_key, "AINALRAMI_CERT_MIN") do
        nil -> if is_nil(Process.get(@soft_key)), do: @cert_min_field, else: @cert_min_field_soft
        value -> String.to_integer(value)
      end

    size >= min
  end

  defp cert_force?,
    do:
      env_flag(@env_cert_key, "AINALRAMI_CERT") == "force" or Process.get(@batch_on_key) == :force

  @doc false
  # The certified-mode counters accumulated in the calling process since the
  # last call, when AINALRAMI_CERT_STATS is set (the benchmark reads them).
  def take_cert_stats do
    Process.delete(@cert_stats_key) || %{}
  end

  defp cert_count(key, by \\ 1) do
    if env_flag(@env_cert_stats_key, "AINALRAMI_CERT_STATS") do
      Process.put(
        @cert_stats_key,
        Map.update(Process.get(@cert_stats_key, %{}), key, by, &(&1 + by))
      )
    end

    # The same counters go into a pairing proof as the decisions it does
    # not cover with a dual certificate (`Ainalrami.Proof`).
    Ainalrami.Proof.count(key, by)
  end

  # `fun.()`, its time added to the counter `key` (ms) when counting.
  defp cert_timed(key, fun) do
    if env_flag(@env_cert_stats_key, "AINALRAMI_CERT_STATS") do
      {us, value} = :timer.tc(fun)
      cert_count(key, div(us, 1000))
      value
    else
      fun.()
    end
  end

  # How many rounds the tournament has actually completed.
  #
  # Neither the minimum nor the maximum games count works. The minimum
  # breaks on a late entrant, who has no games at all and would make
  # everyone else look like they'd already been paired - measured, it
  # emptied the pairing entirely. The maximum breaks on a pre-recorded
  # bye, which is the very thing being detected.
  #
  # bbpPairings resolves it by only advancing `playedRounds` for games the
  # player PARTICIPATED IN THE PAIRING for (`trf.cpp:339-342`): a real
  # game, or a pairing-allocated bye, but not an arbiter-assigned one. So
  # the round number is the furthest any player has been genuinely paired
  # to, and a half-point bye recorded in advance doesn't move it.
  #
  # That is only HALF of bbpPairings' rule, and the missing half was a real
  # bug - see `evenUpMatchHistories` (`trf.cpp:646-684`), which runs after
  # parsing and can advance `playedRounds` once more:
  #
  #     forwardRoundIsComplete = includesUnpairedRound            // true here
  #     for (valid player)
  #       if (includesUnpairedRound ^ (matches.size() > playedRounds))
  #         forwardRoundIsComplete = !includesUnpairedRound
  #     if (playersByRank.size() && forwardRoundIsComplete) ++playedRounds
  #
  # Pairing mode passes `includesUnpairedRound = true` (`main.cpp:452`,
  # under `if (doPairings)` - "compute the pairings of the next round";
  # the checker's own read at `main.cpp:347` passes false), so that XOR
  # reduces to "clear the flag for any player whose history is NOT longer
  # than playedRounds", i.e. the increment happens exactly when EVERY
  # player already carries a game for the trailing column. Then that
  # column is a round that is already fully decided - everyone in it is
  # accounted for - so it counts as PLAYED, and the round to pair is the
  # one after it.
  #
  # The distinction that makes this safe is "every" vs "any": one player
  # holding a pre-recorded half-point bye for the next round leaves
  # everyone else's history shorter, the flag clears, and nothing
  # advances - so the ordinary arbiter-bye case still pairs the round
  # those other players are waiting for, exactly as `active_this_round?/2`
  # below describes and as javafo was measured to do. Only a trailing
  # column that is complete for the WHOLE field advances the count.
  #
  # Found via `crash_reports/seed4385-r5-p4.trf`, where all four players
  # carry a round-5 bye: this engine returned `{:ok, []}` (nobody active
  # for round 5) where bbpPairings pairs round 6 cleanly. docs/engineering-log.md had
  # recorded the four sibling cases as degenerate fuzz artifacts and this
  # one as an unexplained genuine bug; they are all this single rule.
  # The rule lives in `Ainalrami.Trf.rounds_played/1` now: the TRF26 writer
  # needs the same count to tell a bye already in a column from one that
  # belongs in a `240` record, and two copies of a rule this subtle would
  # drift.
  defp rounds_played(players), do: Ainalrami.Trf.rounds_played(players)

  # The engine's own test of a game hands it to
  # `Ainalrami.Trf.participated_in_pairing?/1`, not a private copy of its
  # rule: two spellings of "took part in the pairing" would drift.
  defp participated_in_pairing?(game), do: Ainalrami.Trf.participated_in_pairing?(game)

  # A player is paired this round only if they don't already have a result
  # for it. bbpPairings has exactly this test - `if (player.matches.size()
  # <= tournament.playedRounds)` before pushing onto `sortedPlayers`
  # (`dutch.cpp:658`) - and it's the mechanism by which requested
  # half-point byes, zero-point byes and retirements work at all: the
  # arbiter records the result in advance, and the engine then leaves that
  # player out of the pairing.
  #
  # This engine paired them anyway, which meant a player who had asked for
  # a bye got a game. Confirmed against javafo on a six-player case where
  # player 6 held a pre-recorded half-point bye: javafo paired the other
  # five and gave the odd one out the pairing-allocated bye, while this
  # engine paired player 6 with player 4.
  defp active_this_round?(player, rounds_played), do: length(player.games) <= rounds_played

  # ---------------------------------------------------------------------
  # Article 5.2.5's number - the ARRIVAL NUMBERING
  # ---------------------------------------------------------------------
  #
  # 5.2.5 says "if the higher ranked player has an odd TPN, give them the
  # initial-colour; otherwise, give them the opposite colour." Which number
  # that is was disputed: the TPN as C.04.2 Article 2 fixes it for the whole
  # tournament, or a numbering that skips players who have not been paired.
  # This engine implemented the first reading; both bbpPairings and Gacrux
  # implement the second.
  #
  # The FIDE Systems of Pairings and Programs Commission answered the
  # question on 2026-08-27, and answered it against this engine. Its
  # reasoning is C.04.2 Article 2.4, quoted in full:
  #
  #   "A Late Entry is a participant who is only taken into account for the
  #    pairing of rounds after the first. If admitted to the tournament,
  #    LATE ENTRIES receive no points for unplayed rounds [...] and ARE
  #    GIVEN AN APPROPRIATE TPN AND PAIRED ONLY WHEN THEY ACTUALLY ARRIVE."
  #
  # The SPP reads that as withholding the number until the arrival. This
  # engine had read the identical sentence the other way round - that the
  # number exists from the start and only the PAIRING waits. Both sides
  # argued from the same clause; we read it backwards. The SPP is the
  # authority on C.04.3, so this is settled and not open for
  # re-litigation.
  #
  # So the number is NOT the TPN, and is deliberately not called one
  # anywhere below. It is a position among the players who have arrived, it
  # is recomputed for every round, and a late entrant's arrival shifts the
  # number of everyone ranked below them.
  #
  # WHAT "ARRIVED" MEANS was then pinned empirically against bbpPairings
  # v6.0.0, over twenty hand-built positions. Two records of that, and both
  # are in the repository: `Ainalrami.InitialColourTest`'s "which round-one
  # entries are an ARRIVAL" block is the table rebuilt as assertions and is
  # what runs in CI, and `tools/tpn_membership_probe*.exs` are the four
  # probes that produced it, kept so the table can be re-measured against
  # the binary rather than re-asserted from itself. An earlier version of
  # this comment said the probes were scratch and unversioned; they were
  # committed instead.
  # Every position is explained by a predicate this repo already had:
  # `Ainalrami.Trf.participated_in_pairing?/1`, itself a port of
  # bbpPairings' `opponent != id || resultChar == 'U' || resultChar == '+'`
  # (`fileformats/trf.cpp:303`). The two counter-intuitive splits the probes
  # found are exactly what that one line predicts, which is why the
  # empirical rule is believed to BE the reference's rule rather than an
  # artifact of the positions:
  #
  #   * `F` (full-point bye) is EXCLUDED though it scores 1.0 exactly like
  #     the `U` bye that is INCLUDED - so the score is not the
  #     discriminator, the result code is.
  #   * `-` is the only code whose membership turns on the OPPONENT field:
  #     `2 w -` (a forfeit loss against a real opponent) counts, the
  #     opponentless `0000 - -` does not.
  #
  # Per prior-round entry, then: any played game counts (`1` `=` `0` and
  # the letter spellings `W` `D` `L`), `+` counts with or without an
  # opponent, `-` counts only WITH one, and `U` counts. `H`, `F`, `Z`,
  # opponentless `-` and a blank round do not.
  @doc """
  The numbering Article 5.2.5's parity is taken on: `%{rank => number}`.

  Public because it is a RULE rather than an internal. Until the SPP's
  2026-08-27 ruling on C.04.2 Article 2.4, what 5.2.5 counted was disputed,
  and the comparison harness deliberately refused to compute it - modelling a
  reference's internals is not a conformance test, it is a prediction. The
  ruling settled it, all three engines now implement the same reading, and
  applying an agreed article is exactly what a conformance test is.

  So the harness calls this instead of keeping a fourth copy of the rule in
  the test tree. That copy is the drift `Ainalrami.Test.ColourArticle`'s
  moduledoc is about, and it has already cost this repo once.

  A player who has not arrived is absent from the map rather than numbered
  late - see `number_arrivals/2`.
  """
  def arrival_numbers(players, round) do
    number_arrivals(players, &arrived_for?(&1, round))
  end

  # A player is numbered for round `round` if EITHER holds:
  #
  #   (a) they are in this round's pairing POOL - decided before the pairing
  #       runs, so a player who enters the pool and ends up with the
  #       pairing-allocated bye instead of an opponent still counts; or
  #   (b) in some round strictly before this one they had a real opponent
  #       recorded, or a `U`/`+`.
  #
  # `Enum.take(games, round - 1)` rather than the whole list is the honest
  # statement of "before now". No constructible position distinguishes the
  # two - a participating entry AT this round would itself raise
  # `rounds_played/1` and move the round under computation - so this is a
  # statement of intent rather than a measured difference.
  defp arrived_for?(player, round) do
    active_this_round?(player, round - 1) or
      player.games |> Enum.take(round - 1) |> Enum.any?(&participated_in_pairing?/1)
  end

  # The numbering as it stood in a round the file has ALREADY recorded,
  # which is what `infer_initial_colour/1` needs and is not the same
  # question as the one above.
  #
  # Clause (a) there - "is in the pool" - is only decidable for the round
  # being computed; a historic round's pool is not recoverable from the
  # file. It does not have to be: every player who entered a round's pool
  # left it either with an opponent or with the pairing-allocated `U`, and
  # both satisfy `participated_in_pairing?/1`. So for a past round, "was in
  # the pool at or before it" collapses to "participated in the pairing of
  # some round up to and including it".
  defp arrival_numbers_at(players, round) do
    number_arrivals(players, fn p ->
      p.games |> Enum.take(round) |> Enum.any?(&participated_in_pairing?/1)
    end)
  end

  # Walk in ascending starting rank and hand out consecutive integers to
  # exactly the arrivals. A player who has not arrived receives no number at
  # all - they are absent from the map, not numbered late - so a caller that
  # reaches for a missing key is asking about a player 5.2.5 cannot be
  # deciding a board for, and should fail rather than fall back to the rank.
  defp number_arrivals(players, arrived?) do
    players
    |> Enum.sort_by(& &1.rank)
    |> Enum.filter(arrived?)
    |> Enum.with_index(1)
    |> Map.new(fn {player, number} -> {player.rank, number} end)
  end

  # Fold each player's acceleration for the round about to be paired INTO
  # their `:points`, so every score read below this line is the accelerated
  # one.
  #
  # That is not a shortcut, it is the port. Inside `dutch.cpp` there is
  # essentially no other kind of score: bracket formation
  # (`dutch.cpp:680`, 698-701), the bye assignee (846, 882), the C9 gate
  # (852-865), the bracket loop's own score reads (1114-1126, 1611-1640),
  # `bye_candidate?`'s eligibility (220), the float criteria's score
  # comparisons (295-457) and even `compatible`'s final-round exception
  # (63-65) ALL go through `scoreWithAcceleration`. The only reads of
  # `scoreWithoutAcceleration` in the whole engine are in `common.cpp`'s
  # `sortResults` (180-206), which orders the OUTPUT and is not pairing.
  # So rather than auditing every `.points` in this module one at a time,
  # the accelerated score is what `.points` means from here on, and the two
  # places that genuinely need the real score take it before this runs:
  # `with_float_history/2` above, and the caller's own standings.
  #
  # The whole list is returned untouched when no player carries an
  # `:accelerations` key at all, which is every tournament without an `XXA`
  # line - the ordinary case pays one `Enum.any?` and allocates nothing.
  defp with_acceleration(players, played) do
    if Enum.any?(players, &Map.has_key?(&1, :accelerations)) do
      Enum.map(players, fn p -> %{p | points: p.points + acceleration_at(p, played)} end)
    else
      players
    end
  end

  # ---------------------------------------------------------------------
  # The batch's shared work (`pair_variants/3`)
  # ---------------------------------------------------------------------
  #
  # The variants of one batch differ only in the points and results of the
  # players they replace; their game structure - opponents, colours,
  # whether each round took part in the pairing, how many rounds - is the
  # base's (`same_structure?/2` sends any other variant down the plain
  # path). So what is worked out from that structure alone is the same in
  # every variant, and what is worked out per player from that player's map
  # is the same for every player whose map is.
  #
  # The state holds the variant being paired (`current`) and the one the
  # shared values were taken from (`source`, nil until the first variant
  # reaches `do_pair_later_round/1`). A rank is DIRTY when its player in
  # `current` differs from its player in `source`; a dirty player's values
  # are worked out again, every other player's are taken over.
  #
  # Each value below is the same expression `do_pair_later_round/1` would
  # evaluate, under the same stamped state: the options are the batch's,
  # the bye exclusions depend only on who is active (the same in every
  # variant), and so does everything else these read.

  defp batch_state do
    if Process.get(@batch_on_key) != nil, do: Process.get(@batch_state_key)
  end

  # A value that depends on the game structure alone - the arrival numbering
  # (lengths and `participated_in_pairing?/1`) and the inferred initial
  # colour (colours and the same) - worked out once per batch.
  defp batch_shared(key, fun) do
    case batch_state() do
      nil ->
        fun.()

      %{^key => value} ->
        value

      state ->
        value = fun.()
        Process.put(@batch_state_key, Map.put(state, key, value))
        value
    end
  end

  # The dirty ranks of the variant being paired: where its players and the
  # source's differ.
  defp batch_dirty(%{source: source, current: current}) do
    (Map.keys(current) ++ Map.keys(source))
    |> Enum.reject(fn rank -> Map.get(current, rank) == Map.get(source, rank) end)
    |> MapSet.new()
  end

  # `with_float_history/2`. A player's float history reads their own map and
  # their opponents' of the last two rounds (`float_direction/4`), so it is
  # worked out again - the player is STALE - for a dirty player and for
  # every player who met one in those two rounds, and taken over for the
  # rest.
  defp batch_float_history(players, played) do
    case batch_state() do
      nil ->
        with_float_history(players, played)

      %{source: nil} = state ->
        store_float_history(players, played, state)

      %{floats: floats} = state ->
        dirty = batch_dirty(state)

        stale =
          Enum.reduce(dirty, dirty, fn rank, acc ->
            state.float_dependents |> Map.get(rank, []) |> Enum.into(acc)
          end)

        Process.put(@batch_state_key, Map.put(state, :stale, stale))
        by_rank = Map.new(players, &{&1.rank, &1})

        Enum.map(players, fn player ->
          if MapSet.member?(stale, player.rank),
            do: with_floats(player, by_rank, played),
            else: Map.put(player, :floats, Map.fetch!(floats, player.rank))
        end)
    end
  end

  # The first variant's: worked out in full, and kept with the variant as
  # the source. `float_dependents` maps a rank to the players whose float
  # history reads it - those who met it `played - 1` or `played - 2` rounds
  # ago, the indices `float_direction/4` reads.
  defp store_float_history(players, played, state) do
    field = with_float_history(players, played)

    dependents =
      Enum.reduce(players, %{}, fn player, acc ->
        [played - 1, played - 2]
        |> Enum.filter(&(&1 >= 0 and &1 < length(player.games)))
        |> Enum.map(&Enum.at(player.games, &1).opponent_rank)
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(acc, fn opponent, acc ->
          Map.update(acc, opponent, [player.rank], &[player.rank | &1])
        end)
      end)

    Process.put(
      @batch_state_key,
      Map.merge(state, %{
        source: state.current,
        floats: Map.new(field, &{&1.rank, &1.floats}),
        float_dependents: dependents,
        stale: nil,
        facts: nil
      })
    )

    field
  end

  # `with_round_facts/1`: the colour state and the per-round facts, taken
  # over for every player who is not stale - whose whole map, floats
  # included, is then the source's.
  defp batch_round_facts(players) do
    case batch_state() do
      nil ->
        with_round_facts(players)

      %{stale: nil} = state ->
        field = with_round_facts(players)
        facts = Map.new(field, &{&1.rank, {&1.colour_stats, Map.fetch!(&1, @facts_key)}})
        Process.put(@batch_state_key, Map.put(state, :facts, facts))
        field

      %{stale: stale, facts: facts} ->
        Enum.map(players, fn p ->
          if MapSet.member?(stale, p.rank) do
            with_player_facts(p)
          else
            {stats, facts} = Map.fetch!(facts, p.rank)
            p |> Map.put(:colour_stats, stats) |> Map.put(@facts_key, facts)
          end
        end)
    end
  end

  # The colour state and the three per-round facts (see `@facts_key`), once
  # per active player. Must run after the point system and the bye
  # exclusions are stamped - every caller builds its field after both.
  #
  # `colour_stats/1` used to be computed here twice over, by
  # `bye_assignee_score/2` and again by `global_cascade/2`, each over its own
  # copy of the field; both now keep the one stamped here.
  defp with_round_facts(players), do: Enum.map(players, &with_player_facts/1)

  defp with_player_facts(p) do
    p
    |> Map.put(:colour_stats, colour_stats(p))
    |> Map.put(@facts_key, {met_ranks(p), eligible_for_bye?(p), played_games(p)})
  end

  defp met_ranks(player) do
    for g <- player.games, played?(g), into: %{}, do: {g.opponent_rank, true}
  end

  defp ensure_colour_stats(%{colour_stats: _} = player), do: player
  defp ensure_colour_stats(player), do: Map.put(player, :colour_stats, colour_stats(player))

  # `accelerations[roundIndex]`, with `roundIndex >= size` reading as zero
  # (`tournament.h:346-348`). The index is the TOURNAMENT's played-round
  # count, 0-based, so the value that applies to the round about to be
  # paired is the one at `played` - `accelerations[0]` is round 1's.
  defp acceleration_at(_player, round_index) when round_index < 0, do: 0.0

  defp acceleration_at(player, round_index) do
    case player do
      %{accelerations: values} -> Enum.at(values, round_index) || 0.0
      _ -> 0.0
    end
  end

  # Stamp each player's float direction for the last two rounds, once per
  # round rather than per candidate pair - `float_direction/4` needs every
  # player (it compares against the OPPONENT's score at the time), which
  # `pair_weight/4` doesn't have and shouldn't need.
  defp with_float_history(players, played) do
    by_rank = Map.new(players, &{&1.rank, &1})
    Enum.map(players, &with_floats(&1, by_rank, played))
  end

  defp with_floats(player, by_rank, played) do
    Map.put(player, :floats, %{
      1 => float_direction(player, 1, by_rank, played),
      2 => float_direction(player, 2, by_rank, played)
    })
  end

  # Which way a player was floated `rounds_back` rounds ago - a port of
  # bbpPairings' `getFloat` (`dutch.cpp`). A float isn't recorded anywhere
  # in a TRF; it's *derived*, by comparing what the two players' scores
  # were when they were paired. Outscoring your opponent that round means
  # you were floated DOWN to meet them.
  #
  # An unplayed round counts as a downfloat whenever it scored better than
  # a loss, so a pairing-allocated bye is a downfloat - which is what makes
  # this criterion bite in odd-sized tournaments.
  #
  # "Better than a LOSS", not "better than nothing": `getFloat`
  # (dutch.cpp:117-120) reads `getPoints(player, match) >
  # tournament.pointsForLoss`, and `pointsForLoss` is whatever the file's
  # `BBL`/`162 L` says. The two readings coincide under the standard 1 /
  # 1/2 / 0 system, where a loss pays zero, and only there - which is why a
  # hardcoded `> 0.0` survived 2.5 billion pairings of standard-scored
  # cross-checking and then collapsed to 88.62% of rounds the moment
  # `BBL 0.5` was added as an axis. With a loss worth a half point a
  # half-point bye is no longer better than losing, so it is NOT a
  # downfloat, and C14-C21 read a float history the reference does not
  # have for every player who ever sat one out.
  #
  # Indexed by the TOURNAMENT's played-round count, not by the player's own
  # game count - bbpPairings reads `player.matches[tournament.playedRounds
  # - roundsBack]`. The two are the same only while every player has an
  # entry per round, which arbiter-assigned byes break: a player carrying a
  # pre-recorded bye for the round about to be paired has one game MORE
  # than the tournament has played, so `length(games) - 1` pointed at that
  # future bye instead of their last real round, and every float criterion
  # C14-C21 then read a fabricated history for them.
  defp float_direction(player, rounds_back, by_rank, played) do
    index = played - rounds_back

    if index < 0 or index >= length(player.games) do
      :none
    else
      game = Enum.at(player.games, index)

      cond do
        not played?(game) ->
          if game_points(game) > point_system().loss, do: :down, else: :none

        not is_map_key(by_rank, game.opponent_rank) ->
          :none

        true ->
          mine = score_before(player, rounds_back, played)
          theirs = score_before(Map.fetch!(by_rank, game.opponent_rank), rounds_back, played)

          cond do
            mine > theirs -> :down
            mine < theirs -> :up
            true -> :none
          end
      end
    end
  end

  # A player's score as it stood after round `played - rounds_back` -
  # current score minus what every later round paid out. bbpPairings keeps
  # the same thing as `scoreWithAcceleration(tournament, roundsBack)`.
  #
  # Counted from the TOURNAMENT's round number for the same reason
  # `float_direction/4` is: a player holding a pre-recorded bye has an
  # extra game, and taking "the last `rounds_back`" off their own list
  # then subtracts the wrong rounds.
  #
  # The acceleration term is that round's, not this one's:
  # `scoreWithAcceleration` (`tournament.h:335-359`) winds `roundIndex`
  # back in step with the score it is stripping and then adds
  # `accelerations[roundIndex]`. A float direction is therefore judged on
  # the scores as the two players' brackets saw them AT THE TIME, virtual
  # points included - which is precisely why JaVaFo's manual insists the
  # `XXA` line carry the full round-by-round record rather than just the
  # current round's value.
  defp score_before(player, rounds_back, played) do
    from = max(played - rounds_back, 0)

    # A SLICE of the played rounds, not everything from `from` onwards.
    # `scoreWithAcceleration` (tournament.h:335-359) winds back exactly
    # `roundsBack` steps from `playedRounds`, so a game recorded for a round
    # beyond that - a pre-recorded bye for the round being paired - is never
    # one of the subtractions. It is handled once, in the base, by
    # `reconciled_points/2`.
    #
    # Dropping to the end instead happened to agree while the base was the
    # raw total: the future round was included there and subtracted here, and
    # the two cancelled. Reconciling the base without narrowing this
    # subtracted it twice - measured at 88.19% of rounds against 100.00%,
    # which is what caught it.
    player.games
    |> Enum.slice(from, played - from)
    |> Enum.reduce(reconciled_points(player, played), fn game, score ->
      score - game_points(game)
    end)
    |> Kernel.+(acceleration_at(player, played - rounds_back))
  end

  # The player's total as a base to wind BACK from, reconciled against the
  # games they actually hold.
  #
  # This used `player.points` raw, which is the TRF's own columns 81-84 and
  # not derived from the games at all. Where the two disagree - an arbiter's
  # point adjustment, a total that already includes the acceleration, a
  # pre-recorded bye for the round being paired that has already been
  # credited - every reconstructed historic score was wrong by that much, and
  # therefore every float criterion C14-C21 for that player, silently.
  #
  # bbpPairings does not trust the field either. `trf.cpp:885-925` sums the
  # matches and, when the stored total disagrees, tries subtracting the
  # acceleration and then the points of a round beyond `playedRounds`,
  # keeping whichever reconciles. That is what this ports. When nothing
  # reconciles the file is simply inconsistent, and the stored value is kept
  # - bbpPairings' own final fallback, and the conservative one, since the
  # arbiter's recorded total is the authority on a hand-adjusted score.
  defp reconciled_points(player, played) do
    played_sum =
      player.games
      |> Enum.take(played)
      |> Enum.reduce(0.0, fn game, sum -> sum + game_points(game) end)

    future_sum =
      player.games
      |> Enum.drop(played)
      |> Enum.reduce(0.0, fn game, sum -> sum + game_points(game) end)

    acceleration = acceleration_at(player, played)

    Enum.find(
      [
        player.points,
        player.points - acceleration,
        player.points - future_sum,
        player.points - acceleration - future_sum
      ],
      player.points,
      &same_score?(&1, played_sum)
    )
  end

  # Scores are halves, so they are exact in binary floating point and could be
  # compared directly - but they arrive via subtraction chains, and a
  # tolerance costs nothing and removes the question.
  defp same_score?(a, b), do: abs(a - b) < 0.001

  # Delegates rather than restating. This was a second copy of the same
  # mapping, and the duplication cost something concrete: adding TRF16's
  # letter result codes meant editing BOTH tables, separately, on the same
  # day -- exactly the drift `Trf.points_for/1` existing at all is supposed
  # to prevent. `Pairing` aliases nothing from `Trf` by design (the engine
  # runs on plain maps and does not require a parsed file), so this is the
  # one call rather than a module-wide alias.
  # What a game is worth here, under whichever point system is in force.
  #
  # bbpPairings scores from `getPoints(player, match)` everywhere it scores
  # at all, and that reads the OPPONENT as well as the result: `0000 - +`
  # is a pairing-allocated bye rather than a win, and `0000 - -` is a
  # zero-point bye rather than a forfeit loss (see
  # `Trf.points_for_game/2`). This scored the code alone, which put those
  # two players in the wrong bracket under any file setting its own point
  # values. Every caller holds the whole game, so none of them needs to.
  defp game_points(game) do
    case Process.get(@point_system_key) do
      nil -> Ainalrami.Trf.points_for_game(game)
      system -> Ainalrami.Trf.points_for_game(game, system)
    end
  end

  defp point_system do
    Process.get(@point_system_key) || Ainalrami.Trf.default_point_system()
  end

  # Stamped by every entry point that stamps `@point_system_key`, and
  # cleared by the same `after` blocks - see those keys' own comment for
  # why anything less leaks state from one tournament into the next one
  # paired in the same process.
  #
  # An unconditional read rather than `Process.get(key) || ...`: the other
  # round-scoped keys carry that fallback because a direct call to
  # `pair_later_round/2` has to be able to inherit an outer caller's
  # options, and there are no options to inherit here. Re-reading costs
  # three env lookups on the `pair_next_round/2` -> `pair_later_round/2`
  # path, against the ~70,000 it removes, and in exchange a stale value can
  # never be inherited at all.
  defp stamp_env_flags do
    Process.put(@env_completion_key, read_env_flag("AINALRAMI_COMPLETION"))
    Process.put(@env_trace_key, read_env_flag("AINALRAMI_TRACE"))
    Process.put(@env_nofast_key, read_env_flag("AINALRAMI_NOFAST"))
    Process.put(@env_cert_key, read_env_flag("AINALRAMI_CERT"))
    Process.put(@env_cert_stats_key, read_env_flag("AINALRAMI_CERT_STATS"))
    Process.put(@env_cert_min_key, read_env_flag("AINALRAMI_CERT_MIN"))
    Process.put(@env_direct_key, read_env_flag("AINALRAMI_DIRECT"))
    Process.put(@env_direct_plain_key, read_env_flag("AINALRAMI_DIRECT_PLAIN"))
  end

  defp clear_env_flags do
    Process.delete(@env_completion_key)
    Process.delete(@env_trace_key)
    Process.delete(@env_nofast_key)
    Process.delete(@env_cert_key)
    Process.delete(@env_cert_stats_key)
    Process.delete(@env_cert_min_key)
    Process.delete(@env_direct_key)
    Process.delete(@env_direct_plain_key)
  end

  defp read_env_flag(name) do
    case Ainalrami.Proof.reference_flag(name) do
      nil -> System.get_env(name) || :unset
      value -> value
    end
  end

  defp env_flag(key, name) do
    case Process.get(key) do
      nil -> Ainalrami.Proof.reference_flag(name) || System.get_env(name)
      :unset -> nil
      value -> value
    end
  end

  defp float_of(player, rounds_back) do
    player |> Map.get(:floats, %{}) |> Map.get(rounds_back, :none)
  end

  # bbpPairings' bracket algorithm, ported stage for stage from
  # `dutch.cpp` 1011-1649. This replaces an earlier port that solved each
  # score level once; see "Why one matching is not enough" below.
  #
  # ## The graph is the current bracket plus the next score group
  #
  # `playersByIndex` holds the current bracket followed by the whole of
  # the NEXT score group, and nothing else - every other player has no
  # edge at all. Local indices, in the field's own `(-points, rank)`
  # order:
  #
  #     [0, sgb)      MDPs - moved down from a bracket above
  #     [sgb, nsgb)   residents - this bracket's own score group
  #     [nsgb, m)     the next score group, present only to be pairable
  #
  # `computeBaseEdgeWeights` (dutch.cpp:607) only builds an edge when the
  # LARGER index is at least `sgb`, so two MDPs never have an edge: a
  # moved-down player is paired against a resident or not at all.
  #
  # The first port put the ENTIRE remaining field in one graph and threw
  # the far pairs away afterwards. By then the matcher had already traded
  # a good internal pair for two of them - the discard happens after the
  # optimum is chosen, not before.
  #
  # ## Why one matching is not enough
  #
  # A maximum-weight matching decides everything at once and may return
  # any optimum. bbpPairings does not let it: it calls `computeMatching()`
  # seven times per bracket, each call re-solving the SAME graph after a
  # targeted nudge that forces exactly one decision, which is then frozen
  # with `finalizePair` before the next question is asked. The stages, in
  # order, are `stage_select_mdps/1` (which moved-down players get paired
  # at all), `stage_mdp_opponents/1` (who each one plays),
  # `stage_build_remainder/1` and `stage_exchange_weights/1` (what is left
  # and how it splits), the two exchange-selection loops, the reset pass,
  # and `stage_first_group_partners/1`.
  #
  # Those last five are FIDE C.04.3 §3's transposition and exchange
  # procedure, done properly. The per-bracket cascade approximates it with
  # two invented terms, `deviation` and `spread`, which is the divergence
  # docs/fide-criteria.md calls "the largest remaining gap". They are
  # deliberately absent from this ladder: the exchange stages ARE the
  # mechanism they stand in for, and keeping both would let a stand-in
  # outvote the real thing.
  #
  # ## Arithmetic
  #
  # `computeEdgeWeight` leaves `3 * scoreGroupSizeBits + 1` bits of
  # RESERVED low space (dutch.cpp:462-469) that the stages write into, so
  # a nudge can break a tie without ever outranking a real criterion.
  # `bands.reserve` is that space, and every stage addend lives inside it.
  #
  # `edgeWeightComputer`'s addend goes NEGATIVE (dutch.cpp:1076 subtracts
  # from a value that is zero whenever its guard bit is clear). In C++
  # that is unsigned wraparound; here it is just subtraction, which is
  # what the wraparound computes. It borrows into the criterion above,
  # but can never invert an ordering: the borrow is under `2 * s`, and one
  # unit of the lowest criterion is `reserve = 2 * s^3`.
  #
  # ## What it measures, and why it is still not the default
  #
  # 200 tournaments x 9 rounds against bbpPairings, same harness the other
  # figures in docs/engineering-log.md come from:
  #
  #     this cascade, before the stages     60.51% rounds / 93.6% pairs
  #     this cascade, stages ported         90.11% rounds / 96.82% pairs
  #     the per-bracket cascade (default)   90.29% rounds / 97.21% pairs
  #
  # So the architecture is vindicated - the missing 30 points really were
  # the refinement, exactly as predicted - but it lands on PARITY, three
  # rounds in 1689 behind the thing it was meant to beat, and it is still
  # behind on pairs. It stays off until it actually wins.
  #
  # Where the two differ is informative. This cascade is BETTER in the
  # middle rounds (3: 97.00 vs 93.50, 4: 97.40 vs 95.83, 5: 94.79 vs
  # 92.19) and worse in the late ones (7: 83.15 vs 84.24, 8: 80.24 vs
  # 82.04, 9: 66.47 vs 69.46). Late rounds are where legal pairings get
  # scarce, which is where the per-bracket cascade's backtracking earns
  # its keep - measured at 15 points of pairs on its own. This cascade has
  # no backtracking at all, by design, because bbpPairings has none.
  # Closing the remaining gap most likely means the whole-field
  # feasibility pre-pass bbpPairings runs first (dutch.cpp:825-837), which
  # is what lets it commit to a bracket decision without ever needing to
  # revisit one.
  #
  # ## Two things measured as INERT, and one of them removed
  #
  # The canonical lexicographic tie-break this engine relies on everywhere
  # else (`lex_scale/1`) was carried here too at first, below the reserved
  # space. It makes no difference whatever: removing it, and even
  # INVERTING it, both reproduce 1522/1689 and the same disagreement set,
  # byte for byte. The switch was verified to be live before believing
  # that - a bad value raises `CaseClauseError` from inside the run. So it
  # is gone from this path, which is also what makes the bignums small
  # enough to solve a bracket eight times over without cost.
  #
  # That is a real result, not a null one: a tie-break exists to choose
  # among equally-optimal matchings, and having nothing left to choose is
  # the claim bbpPairings' design makes for its own staged refinement.
  #
  # C9's rung measured inert on THIS fixture set, which runs at a 0% bye
  # rate and so barely exercises it. With byes it matters a great deal,
  # and its gate has to be ported in full to help rather than hurt: see
  # `bracket_loop/6`, where the dutch.cpp:1636-1643 clearing step lives.
  # Half-ported it measured WORSE than having no C9 rung at all.

  # THE pairing path. There is no longer a second one.
  #
  # A per-bracket cascade with backtracking used to sit behind this as a
  # fallback, and for a while it was the default. It is gone: this beat it
  # on every field size measured, and once the bracket loop stopped ending
  # a round early (see `bracket_loop/6`) the fallback stopped being
  # reached at all - zero times in ~1700 rounds, with byes and forfeits
  # on. Keeping ~950 lines of a second engine warm for a path nothing
  # takes is worse than not having it.
  #
  # What replaced it as the safety net is `repair_completion/3`, which is
  # part of THIS engine rather than a different one: if the staged
  # refinement leaves anyone unpairable, one whole-field matching fixes
  # the completion while keeping as much of the cascade's answer as it
  # can. Only when that also fails does `pair_later_round/1` raise
  # `NoValidPairingError`, which at that point is the truth - a
  # whole-field maximum matching could not pair everyone either.
  defp global_cascade(brackets, allowed_byes) do
    field =
      brackets
      |> List.flatten()
      |> Enum.sort_by(&{-&1.points, &1.rank})
      |> Enum.map(&ensure_colour_stats/1)

    ctx = global_context(field)

    # Vertex ids for the round.s field matcher are positions in `field`,
    # which every bracket.s vertex set is a subsequence of. The matcher
    # itself is created lazily by the first field-graph `solve/1`, and
    # rebuilt after any bracket the local graph answered.
    Process.put(@round_matcher_key, {nil, ctx.field_index, length(field)})
    # A fresh matcher is the reference's own state until a shortcut is taken.
    Process.put(@taint_key, false)
    Process.delete(@virtual_builder_key)
    Process.delete(@builder_c9_key)
    Process.delete(@cert_memo_key)
    # Whole-field and round-scoped, like the matcher: see `build_oracle/3`.
    Process.put(@oracle_key, build_oracle(field, allowed_byes, ctx))

    {pairs, leftover} = run_brackets(field, ctx)

    # The staged refinement is not told how many byes are legal, so the
    # result is checked rather than assumed. Falling back to the
    # backtracking cascade beats emitting an illegal round.
    case check_completion(pairs, leftover, allowed_byes) do
      :ok ->
        {:ok, pairs, leftover}

      {:incomplete, reason} ->
        # The staged refinement finalises pairs one at a time and locks
        # them, so a bracket can in principle commit a pair that leaves
        # someone further down unpairable.
        #
        # The three engines guard this differently. bbpPairings proves a
        # complete matching exists before it starts and throws if not
        # (dutch.cpp:828 - a CHECK, with no repair anywhere), then trusts
        # its incremental matcher to preserve completeness. Gacrux
        # precomputes per-level feasibility ("hamilton") and uses it to
        # reject a bracket choice that would strand the rest. This one
        # repairs after the fact instead.
        if System.get_env("AINALRAMI_TRACE_FALLBACK"), do: IO.puts("[repair] #{reason}")

        case repair_completion(field, pairs, allowed_byes) do
          {:ok, repaired, repaired_leftover} = ok ->
            case check_completion(repaired, repaired_leftover, allowed_byes) do
              :ok -> ok
              {:incomplete, r} -> trace_fallback("repair failed: #{r} (was #{reason})")
            end

          :infeasible ->
            trace_fallback("no complete matching exists (#{reason})")
        end
    end
  end

  defp check_completion(_pairs, leftover, allowed_byes) do
    cond do
      length(leftover) > allowed_byes ->
        {:incomplete, "stranded #{length(leftover)}, allowed #{allowed_byes}"}

      not Enum.all?(leftover, &eligible_for_bye?/1) ->
        {:incomplete, "bye assignee is C2-ineligible"}

      not Enum.all?(leftover, &bye_score_ok?/1) ->
        {:incomplete, "bye assignee's score is above the C5 minimum"}

      true ->
        :ok
    end
  end

  # One whole-field matching that must (a) pair as many players as
  # possible, then (b) keep as much of the cascade's own answer as it can,
  # then (c) prefer pairing equal scores where it has to choose.
  #
  # (a) strictly above (b) is the point: the cascade's answer is already
  # the criteria-best one it could find, so the ONLY reason to overrule it
  # is that it left someone unpairable. Ranking cardinality first means
  # this breaks exactly as many of its pairs as completion requires and no
  # more - usually one, since the shortfall is usually a single pair.
  defp repair_completion(field, pairs, allowed_byes) do
    n = length(field)

    if n < 2 do
      :infeasible
    else
      arr = List.to_tuple(field)
      chosen = MapSet.new(pairs, fn {w, b} -> Enum.min_max([w, b]) end)

      # Five strictly-ordered bands. Cardinality first, so the repair
      # breaks exactly as many of the cascade's pairs as completion
      # demands - usually one, since the shortfall is usually one pair.
      #
      # Then the two ABSOLUTE criteria that constrain who may be left
      # over, both phrased the way `bye_assignee_score/2` phrases them:
      # pairing a player who may NOT take the bye is preferred, so
      # whoever ends up unmatched is someone C2 and C5 allow. Cardinality
      # alone does not pin this down - several maximum matchings usually
      # exist and they do not leave the same vertex out - so without
      # these bands the repair would hand `check_completion/3` a complete
      # matching whose leftover is a player who has already had a bye,
      # and the whole round was then refused as impossible. That was the
      # entire "illegal" column at high round counts: 142 rounds out of
      # 2126 at 39 rounds, every one of which bbpPairings paired legally.
      #
      # Preservation fourth, so among the completions that satisfy all of
      # the above it keeps as much as it can of the criteria-best answer
      # the cascade already found. The criteria themselves last, to
      # settle WHICH of several equally preserving completions to take:
      # without that the choice falls to the matcher's arbitrary
      # tie-break, and an arbitrary choice measurably loses rounds the
      # cascade had right.
      s = n + 1
      criteria_span = Integer.pow(s, 9)
      preserve = criteria_span * s
      bye_score_band = preserve * s
      eligibility_band = bye_score_band * s
      cardinality = eligibility_band * s

      edges =
        Enum.flat_map(0..(n - 2), fn i ->
          a = elem(arr, i)

          Enum.flat_map((i + 1)..(n - 1), fn j ->
            b = elem(arr, j)

            if legal_pair?(a, b) and colour_compatible?(a, b) do
              keep =
                if MapSet.member?(chosen, Enum.min_max([a.rank, b.rank])), do: preserve, else: 0

              eligibility = bit(not eligible_for_bye?(a)) + bit(not eligible_for_bye?(b))
              bye_score = bit(not bye_score_ok?(a)) + bit(not bye_score_ok?(b))

              weight =
                cardinality + eligibility * eligibility_band + bye_score * bye_score_band +
                  keep + repair_criteria(a, b, s)

              [{i, j, weight}]
            else
              []
            end
          end)
        end)

      matching = WeightedMatching.solve(n, edges)
      leftover = for i <- 0..(n - 1), not is_map_key(matching, i), do: elem(arr, i)

      if length(leftover) > allowed_byes do
        :infeasible
      else
        repaired =
          for {i, j} <- matching,
              i < j,
              do: assign_colour_with_history({elem(arr, i), elem(arr, j)})

        {:ok, repaired, leftover}
      end
    end
  end

  # The subset of the ladder that still means something with no brackets
  # to speak of: keep equal scores together (C6/C7's whole purpose),
  # satisfy colour (C10-C13), and respect float history (C14-C17). The
  # bracket-relative rungs - C8's reach, C9's bye gate - have no referent
  # in a whole-field matching and are left out rather than faked.
  defp repair_criteria(a, b, s) do
    {higher, lower} = order_by_placement(a, b)
    {c1, c2, c3, c4} = colour_criteria(higher, lower)
    {f1, f2, f3, f4} = float_criteria(higher, lower)

    ranked([
      {bit(a.points == b.points), s},
      {bit(c1), s},
      {bit(c2), s},
      {bit(c3), s},
      {bit(c4), s},
      {f1, s},
      {f2, s},
      {f3, s},
      {f4, s}
    ])
  end

  defp trace_fallback(reason) do
    if System.get_env("AINALRAMI_TRACE_FALLBACK"), do: IO.puts("[fallback] #{reason}")
    :infeasible
  end

  # Everything the ladder needs that is genuinely round-wide. The spans
  # themselves are per bracket - see `pair_bracket/6`.
  defp global_context(field) do
    bye_score = Process.get(@bye_score_key)

    # The weight bands, computed ONCE over the whole field and shared by
    # every bracket of the round. They used to be re-derived per bracket
    # from `combined` (`m + 1`, the scores present in the bracket's graph),
    # which rescaled every edge weight whenever the bracket changed -- and
    # that is what made each bracket boundary a cold solve: a matcher
    # cannot be carried across a boundary when every weight in it changes.
    #
    # bbpPairings computes `scoreGroupSizeBits` once over `sortedPlayers`
    # and never re-derives it (dutch.cpp:684-730), and `explain_round/3`
    # here already sized its bands over the field for exactly the reason
    # its comment gives: per-bracket scaling made rung values incomparable.
    # A radix is a radix; a span wider than any bracket needs only leaves
    # headroom in each band, never changes an ordering.
    {places, place_span} = score_places(field)
    count_span = length(field) + 1

    ctx = %{
      bye_score: bye_score,
      unplayed_ranks: unplayed_ranks(field, bye_score),
      odd_field?: rem(length(field), 2) == 1,
      first_single_bye?: Process.get(@first_single_bye_key, false),
      # Rank -> position in the round.s field: the vertex ids of the round
      # matcher and the oracle.
      field_index: field |> Enum.with_index() |> Map.new(fn {p, i} -> {p.rank, i} end),
      bands: %{
        places: places,
        place_span: place_span,
        count_span: count_span,
        reserve: 2 * count_span * count_span * count_span
      }
    }

    Map.put(ctx, :outside, outside_layout(field, ctx))
  end

  # Where the rungs that can be non-zero for a pair OUTSIDE the bracket sit
  # in the packed weight - see `outside_edge_weight/6`. Read off the ladder
  # itself, one `edge_rungs/6` call on any player of the round at reach 2,
  # so the positions and spans come from the one definition of the ladder
  # rather than a second copy of it: the soft rung's place (strong or weak,
  # or absent) is whatever `soften/3` put there this round.
  #
  # `suffix` holds, for each rung, the product of the spans of every rung
  # after it - the factor `ranked/1`'s fold ends up multiplying that rung's
  # value by.
  defp outside_layout([], _ctx), do: nil

  defp outside_layout([p | _], ctx) do
    rungs = edge_rungs(p, p, 2, ctx, ctx.bands, false)
    labels = Enum.map(rungs, &elem(&1, 0))

    suffix =
      rungs
      |> Enum.map(&elem(&1, 2))
      |> Enum.reverse()
      |> Enum.map_reduce(1, fn span, product -> {product, product * span} end)
      |> elem(0)
      |> Enum.reverse()
      |> List.to_tuple()

    at = fn label -> Enum.find_index(labels, &(&1 == label)) end

    %{
      suffix: suffix,
      soft: at.("S soft avoid"),
      c8_pairs: at.("C8 pairs next bracket"),
      c8_scores: at.("C8 scores next bracket"),
      c9: at.("C9 bye unplayed games")
    }
  end

  # ---------------------------------------------------------------------
  # Input validation
  # ---------------------------------------------------------------------
  #
  # Run once by every public entry point - `pair_next_round/2`,
  # `pair_later_round/2`, `pair_round_one/1`, `explain_context/3` (and with
  # it `explain_round/3`), `bye_eligibility/2` - BEFORE any path is chosen,
  # so a fast path cannot skip a check the slow one makes. That is what
  # happened to the duplicate-rank check, which lived in `global_context/1`
  # and so was never reached by a round one.
  #
  # Each check refuses a value the engine would otherwise have read as some
  # OTHER value, without saying so. Values it would refuse loudly anyway (a
  # missing key, a wrong type deep in the arithmetic) are refused here too,
  # but with a message that names the option. Unknown option keys are not
  # refused: hosts pass their own keys alongside (`Ainalrami.Alternatives`
  # and `Ainalrami.ByePreference` both carry options of their own through).
  defp validate_input!(players, opts) do
    validate_players!(players)
    validate_opts!(opts)
  end

  @doc false
  # For the entry points that live in other modules and read the roster
  # before they reach one of these - `Ainalrami.ByePreference.pair/3`.
  def check_input!(players, opts), do: validate_input!(players, opts)

  defp validate_players!(players) when is_list(players) do
    Enum.each(players, fn
      %{rank: rank, points: points, games: games}
      when is_integer(rank) and is_number(points) and is_list(games) ->
        Enum.each(games, fn
          %{opponent_rank: opponent} when is_nil(opponent) or is_integer(opponent) ->
            :ok

          other ->
            raise ArgumentError,
                  "rank #{rank}: a game is a map with :opponent_rank (an integer, or nil " <>
                    "for no opponent), got #{inspect(other)}"
        end)

      other ->
        raise ArgumentError,
              "a player is a map with an integer :rank, a numeric :points and a :games " <>
                "list, got #{inspect(other, limit: 8)}"
    end)

    check_unique_ranks!(players)
  end

  defp validate_players!(other),
    do: raise(ArgumentError, "players must be a list, got #{inspect(other, limit: 8)}")

  @point_system_fields [
    :win,
    :draw,
    :loss,
    :pairing_allocated_bye,
    :forfeit_loss,
    :zero_point_bye
  ]
  @point_system_optional [:forfeit_win, :full_point_bye, :half_point_bye, :unknown]

  defp validate_opts!(opts) do
    if not (is_list(opts) and Keyword.keyword?(opts)) do
      raise ArgumentError, "options must be a keyword list, got #{inspect(opts, limit: 8)}"
    end

    Enum.each(opts, fn {key, value} -> validate_opt!(key, value) end)
  end

  # `played + 1 >= expected - 1` is the final-round test; anything but an
  # integer there raised an ArithmeticError from deep in the colour rules.
  defp validate_opt!(:expected_rounds, v) when is_nil(v) or (is_integer(v) and v >= 0), do: :ok

  # Anything but "w" used to be read as Black: `assign_colour_round_one/3`
  # compares the stamped value with "w" and nothing else, so "W", "white"
  # or :white all paired the drawing of lots the other way round.
  defp validate_opt!(:initial_colour, v) when v in [nil, "w", "b"], do: :ok

  defp validate_opt!(:point_system, nil), do: :ok

  defp validate_opt!(:point_system, %{} = system) do
    required = Enum.all?(@point_system_fields, &is_number(Map.get(system, &1)))

    optional =
      Enum.all?(@point_system_optional, fn f ->
        v = Map.get(system, f)
        is_nil(v) or is_number(v)
      end)

    if required and optional, do: :ok, else: bad_opt!(:point_system, system)
  end

  defp validate_opt!(key, groups) when key in [:forbidden_pairs, :soft_pairs] do
    cond do
      is_nil(groups) ->
        :ok

      is_list(groups) and Enum.all?(groups, &rank_group?/1) ->
        :ok

      true ->
        bad_opt!(key, groups)
    end
  end

  # The soft rung went to the end of the ladder for `:weak` and to the top
  # for ANYTHING else (`soften/3`'s `_strong` clause), so a misspelt
  # `:weak` - or "weak", as a host storing it as a string would send it -
  # quietly became the strongest setting there is.
  defp validate_opt!(:soft_position, v) when v in [nil, :strong, :weak], do: :ok

  defp validate_opt!(key, v)
       when key in [:bye_exclusions, :bye_preference_exclusions] and
              (is_nil(v) or is_list(v)) do
    if Enum.all?(v || [], &is_integer/1), do: :ok, else: bad_opt!(key, v)
  end

  # Anything but `false` used to mean "work it out", including `nil`, and
  # including "false".
  defp validate_opt!(:bye_passed_over, v) when is_boolean(v) or is_nil(v), do: :ok

  defp validate_opt!(key, v)
       when key in [
              :expected_rounds,
              :initial_colour,
              :point_system,
              :soft_position,
              :bye_exclusions,
              :bye_preference_exclusions,
              :bye_passed_over
            ],
       do: bad_opt!(key, v)

  # `:bye_preferences` is `Ainalrami.ByePreference.pair/3`'s to check, and
  # every other key is the host's.
  defp validate_opt!(_key, _v), do: :ok

  defp rank_group?(ranks) when is_list(ranks), do: Enum.all?(ranks, &is_integer/1)

  defp rank_group?({ranks, first, last}) when is_integer(first) and is_integer(last),
    do: rank_group?(ranks)

  defp rank_group?(_), do: false

  defp bad_opt!(key, value) do
    raise ArgumentError, "#{inspect(key)}: #{opt_expects(key)}, got #{inspect(value, limit: 8)}"
  end

  defp opt_expects(:expected_rounds), do: "the tournament's round count (an integer) or nil"
  defp opt_expects(:initial_colour), do: ~s(the drawing of lots, "w" or "b", or nil to infer it)

  defp opt_expects(:point_system),
    do:
      "a map with numeric #{Enum.map_join(@point_system_fields, ", ", &inspect/1)} " <>
        "(and optionally numeric #{Enum.map_join(@point_system_optional, ", ", &inspect/1)})"

  defp opt_expects(key) when key in [:forbidden_pairs, :soft_pairs],
    do: "a list of groups, each a list of starting ranks or {ranks, first_round, last_round}"

  defp opt_expects(:soft_position), do: ":strong or :weak (nil means :strong)"

  defp opt_expects(key) when key in [:bye_exclusions, :bye_preference_exclusions],
    do: "a list of starting ranks"

  defp opt_expects(:bye_passed_over), do: "true or false"

  # `field_index` is `Map.new` over `p.rank`, so two players sharing a
  # starting rank silently collapse onto one vertex id. Nothing upstream
  # refuses that - `Ainalrami.Trf.parse/1` accepts a file with two `001`
  # lines carrying the same rank, checked - and the damage is quiet rather
  # than loud: the colliding pair's rank-spread addend, the lowest rung of
  # `edge_weigher/3`, is computed against the wrong position. Unique
  # starting ranks are what a TRF's rank column MEANS, so a duplicate is a
  # caller bug; say so here rather than pair on a degraded tie-break.
  #
  # Over the WHOLE roster, since 2026-10-02, and from `validate_players!/1`
  # at every entry point: it used to run on the active field only, from
  # `global_context/1`, which `pair_round_one/1`'s shortcut never reaches -
  # so the same duplicate was refused on round two and paired on round one,
  # and a duplicate among the players sitting a round out was never seen,
  # although opponent ranks in the game records resolve against them too.
  defp check_unique_ranks!(players) do
    players
    |> Enum.frequencies_by(& &1.rank)
    |> Enum.filter(fn {_rank, n} -> n > 1 end)
    |> case do
      [] ->
        :ok

      dups ->
        raise ArgumentError,
              "duplicate starting rank(s) in the roster: " <>
                Enum.map_join(Enum.sort(dups), ", ", fn {rank, n} -> "#{rank} (x#{n})" end) <>
                " - every player needs a distinct starting rank"
    end
  end

  # dutch.cpp:879-892. Rank the played-game counts of everyone who could
  # take the bye, most games played first, so a rung that MAXIMISES weight
  # prefers PAIRING the player with the most unplayed games - which is how
  # you leave the bye to someone with the fewest. Equal counts collapse
  # onto the last rank written, exactly as the C++ map assignment does.
  defp unplayed_ranks(_field, nil), do: %{}

  defp unplayed_ranks(field, bye_score) do
    field
    |> Enum.filter(&(&1.points == bye_score))
    |> Enum.map(&played_games/1)
    |> Enum.sort(:desc)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {played, rank}, acc -> Map.put(acc, played, rank) end)
  end

  defp played_games(%{@facts_key => {_met, _eligible, played}}), do: played
  defp played_games(player), do: Enum.count(player.games, &played?/1)

  # dutch.cpp:981 - keep going while a bracket still has two players to
  # pair OR there is another score group to bring in.
  defp run_brackets(field, ctx) do
    case Enum.chunk_by(field, & &1.points) do
      [] -> {[], []}
      [first | rest] -> bracket_loop(first, 0, rest, ctx, [])
    end
  end

  # The FIRST bracket's C9 flag is not a bracket property at all - it is
  # read off the bootstrap whole-field matching that also produced the bye
  # assignee's score (dutch.cpp:851-870, ported in `first_single_bye?/4`).
  # Two earlier readings lived here: a hardcoded `true`, which is only
  # right for a field that is a single score group, and then "odd field
  # with an even number of players below", which was a guess at the same
  # thing without the matching to read it from.
  defp bracket_loop(by_index, sgb, rest_groups, ctx, pairs) do
    bracket_loop(by_index, sgb, rest_groups, ctx, pairs, ctx.first_single_bye?)
  end

  defp bracket_loop(by_index, _sgb, [], _ctx, pairs, _single_bye?) when length(by_index) <= 1 do
    {pairs, by_index}
  end

  defp bracket_loop(by_index, sgb, rest_groups, ctx, pairs, single_bye?) do
    nsgb = length(by_index)

    {next_group, rest} =
      case rest_groups do
        [] -> {[], []}
        [group | tail] -> {group, tail}
      end

    # The graph is the WHOLE remaining field - see `peek_groups/3`. Only
    # the current bracket and the next score group (`wsgb` players, the
    # exact analogue of bbpPairings' `playersByIndex`) are consumed or can
    # be finalised; everything past `wsgb` is visible to the matcher and
    # goes back to `rest` untouched.
    peek = peek_groups(rest, peek_budget(), [])
    wsgb = nsgb + length(next_group)

    {new_pairs, carried_all, new_sgb, carried_partner_scores} =
      pair_bracket(by_index ++ next_group ++ peek, sgb, nsgb, wsgb, ctx, single_bye?)

    peeked = MapSet.new(peek, & &1.rank)
    carried = Enum.reject(carried_all, &MapSet.member?(peeked, &1.rank))

    # dutch.cpp:1607-1643, computed at the END of a bracket for the NEXT
    # one. C9 applies only where a bracket downfloats exactly one player
    # and that player takes the bye, so the preliminary test (odd field, a
    # next group exists, and the bye's score is at or above it) is then
    # CLEARED if any carried player is already tentatively matched below
    # that group - because then the float runs deeper than one bracket and
    # the criterion does not apply.
    #
    # Leaving that clearing step out is not harmless. With it missing the
    # rung fired in brackets bbpPairings excludes, and measured WORSE than
    # having no C9 rung at all: 83.14% against 83.73% of exact rounds at
    # an 8% bye rate.
    #
    # ## Why the clearing step only started working once the matching went
    # ## whole-field
    #
    # `carried_partner_scores` is the score of each carried player's
    # TENTATIVE match. bbpPairings reads that off its one persistent
    # matcher over the entire remaining field, so the clearing player can
    # be tentatively matched to somebody several score groups away who has
    # nothing to do with this bracket. Instrumented C++ trace of
    # `seed1253-r7-p13`'s score-3.0 bracket:
    #
    #     DBG float id=9 tentative_match=10 match_score=1.5
    #                    next_group_score=3.0 gate_was=1
    #     DBG   -> gate CLEARED by this float
    #
    # Rank 10 has 1.5 points and is not a member of the 3.0 bracket at
    # all. A per-bracket solve scoped to a bracket-plus-peek window cannot
    # produce that tentative match, so it computed the gate as `true`,
    # applied C9, and landed on a different pairing.
    #
    # A parity stand-in used to sit here - "an even number of players
    # below the next bracket" - reasoning that an odd remainder forces the
    # next bracket to float two players and so cannot have a single bye
    # assignee. It was a proxy for exactly this clearing step, added when
    # the step could not be evaluated properly, and it is dropped now that
    # it can: bbpPairings has no such term (dutch.cpp:1608-1643 is the
    # whole rule), and keeping both means suppressing C9 in brackets the
    # reference scores it in.
    next_single_bye? =
      ctx.odd_field? and not is_nil(ctx.bye_score) and next_group != [] and
        ctx.bye_score >= hd(next_group).points and
        Enum.all?(carried_partner_scores, &(&1 >= hd(next_group).points))

    # bbpPairings loops unconditionally because by this point it has
    # already PROVED a complete legal matching exists - its whole-field
    # pre-pass throws `NoValidPairingException` otherwise (dutch.cpp:828).
    # This engine deliberately carries on when that pre-pass finds nothing
    # (`bye_assignee_score/2` returns nil rather than aborting), so a last
    # bracket whose players simply cannot play each other would spin here
    # forever: no pairs made, nothing consumed, same arguments next time.
    #
    # The test is whether a group was CONSUMED, not whether any are left.
    # An earlier version stopped on `rest == []`, which is the state after
    # popping the final group - so the round ended on the very iteration
    # that first brought that group in, before the players it carried had
    # any chance to pair with it. They were reported stranded and the
    # round was handed to the fallback engine. That single wrong condition
    # was most of the fallbacks.
    # `AINALRAMI_FORCE_STRAND=1` restores the old, wrong condition on
    # purpose. `repair_completion/3` is the engine's only completion
    # safety net and it never fires in normal running - measured zero
    # times across every configuration - which would leave it as untested
    # emergency code. This is the fault injection that tests it: with the
    # flag on, roughly a tenth of rounds strand, and the suite asserts
    # every one of them still comes out legal.
    stop? =
      if System.get_env("AINALRAMI_FORCE_STRAND"),
        do: rest == [] and new_pairs == [],
        else: next_group == [] and new_pairs == []

    if stop? do
      {pairs, carried}
    else
      bracket_loop(carried, new_sgb, rest, ctx, pairs ++ new_pairs, next_single_bye?)
    end
  end

  # How many score groups BEYOND the next one to put in the bracket's
  # graph. They are visible to the matcher and to C8, never consumed, and
  # nothing in them can be finalised.
  #
  # This is the single largest correction in the port. `dutch.cpp` appends
  # exactly one score group, and read literally that is what the C8 rungs
  # score - but C8 is "choose the set of downfloaters so that in the
  # FOLLOWING bracket every criterion from C1 to C7 is complied with", and
  # a bracket cannot check that against players it cannot see. Both
  # confirmed anomalies in `test/fixtures/open_questions/` have exactly
  # that signature: an identical current+next graph answering differently
  # depending on what lies below it.
  #
  # Global cascade, 200x9 against bbpPairings:
  #
  #     depth 0 (one group, the literal reading)  90.29% / 96.89%
  #     depth 1                                   94.14% / 98.17%
  #     depth 2                                   95.62% / 98.52%
  #     depth 3                                   95.91% / 98.63%
  #     depth 4                                   95.97% / 98.64%
  #     depth 6 and unbounded                     95.97% / 98.64%
  #
  # Zero illegal rounds at every depth, and it saturates at 4 (unbounded
  # measures identically, for more time).
  #
  # Budgeted in PLAYERS rather than groups, because groups are the wrong
  # unit: a 4-40 field has score groups of one to three, so four of them
  # is a handful of players and depth genuinely buys accuracy; a 60-120
  # field has groups big enough that ONE already supplies the same
  # context. Measured - 60-80 and 90-120 both score identically at depth
  # 1 and depth 4, while depth 4 costs 2.7x and 2.6x the time:
  #
  #     60-80 players    depth 1  99.44% / 99.97%   21s
  #                      depth 4  99.44% / 99.97%   57s
  #     90-120 players   depth 1  98.61% / 99.87%   64s
  #                      depth 4  98.61% / 99.87%  166s
  #
  # A player budget gets the small field's depth and the large field's
  # speed from one rule, and it is the same reasoning `depth_for/1` and
  # `per_count_limit/1` already use: a big bracket has more ways to pair,
  # so it needs less help.
  #
  # Note what this does NOT contradict: docs/engineering-log.md's "do not read the
  # lookahead as a licence to pair across brackets" still holds, and is
  # still enforced - `collect_bracket/1` keeps a pair only when both ends
  # are below `nsgb`. Seeing further and finalising further are different
  # things, and it was only ever the second one that measured badly.
  #
  # ## Why it is now UNBOUNDED
  #
  # bbpPairings' `matchingComputer` is one persistent matcher over the
  # whole remaining field, built once (dutch.cpp:738) and re-solved as
  # brackets are locked in. That is not the same object as a wide peek -
  # but the difference collapses, because `finalizePair` (common.h:164)
  # locks a pair by leaving its two vertices exactly one usable edge each
  # and zeroing every other edge incident on them. A vertex with a single
  # positive edge to a partner in the same state is ISOLATED: any matching
  # either takes that edge or leaves both ends unmatched, and taking it is
  # strictly better and blocks nothing. So a finalised pair contributes
  # nothing to the rest of the optimisation, and dropping those vertices
  # from the graph - which is what carrying only the unpaired players
  # forward already does - gives the identical matching on the identical
  # remaining vertices.
  #
  # What is left is the SCOPE, and that is what an unbounded peek supplies:
  # every unfinalised player is a vertex, so a player floating out of this
  # bracket gets a real tentative match against the field below it instead
  # of no match at all. `bracket_loop/6`'s C9 gate is derived from exactly
  # those tentative matches, and could not be evaluated correctly while
  # the graph stopped a few groups down.
  #
  # A wide peek ALONE was measured earlier and changed nothing (docs/engineering-log.md:
  # `AINALRAMI_PEEK=999` left the disputed cases exactly as they were),
  # which is consistent: without the gate reading the wider matching, the
  # extra vertices had nothing to say. The two halves only work together.
  #
  # The weights stay bracket-flavoured throughout, and that is faithful
  # rather than a shortcut. `reach_table/3` grades every visible player by
  # how far below the bracket they sit, `in_current` is `reach == 0` and
  # C8 is `reach == 1`, so a pair two or more groups down scores only the
  # completion rung and C9 - exactly the weight bbpPairings leaves on its
  # own out-of-window edges (`computeEdgeWeight` with both
  # `lowerPlayerInCurrentBracket` and `lowerPlayerInNextBracket` false,
  # dutch.cpp:766-786's bootstrap). The one knowing difference: bbpPairings
  # never REFRESHES those out-of-window edges, so they keep the C9 gate
  # value the bootstrap pass computed, where these are recomputed with the
  # current bracket's gate.
  @peek_budget :unbounded

  defp peek_budget do
    case System.get_env("AINALRAMI_PEEK") do
      nil -> @peek_budget
      n -> String.to_integer(n)
    end
  end

  # Whole score groups, never a partial one - a bracket that could see
  # half of a group would score C8 against a fiction. `:unbounded` takes
  # everything that is left, which is the default; the numeric budget is
  # kept so `AINALRAMI_PEEK=<n>` can still narrow the graph for measurement.
  defp peek_groups([], _budget, acc), do: List.flatten(Enum.reverse(acc))
  defp peek_groups(rest, :unbounded, acc), do: List.flatten(Enum.reverse([rest | acc]))
  defp peek_groups(_rest, budget, acc) when budget <= 0, do: List.flatten(Enum.reverse(acc))

  defp peek_groups([group | rest], budget, acc) do
    peek_groups(rest, budget - length(group), [group | acc])
  end

  # `sgb` is where the residents start (everything before it is a
  # moved-down player), `nsgb` where the bracket ends, and `wsgb` where the
  # NEXT SCORE GROUP ends - bbpPairings' `playersByIndex.size()`. Anything
  # from `wsgb` on is visible to the matcher only: it can never be
  # finalised, consumed, or exchanged into, and it exists so that players
  # leaving this bracket get a realistic tentative match (see
  # `peek_groups/3`).
  # A bracket is paired on one of two graphs.
  #
  # The FIELD graph is the whole remaining field, one matcher for the
  # round, the eight stages re-solving it at every step -- bbpPairings'
  # design, and the one every number in docs/validation.md was measured
  # on. It is exact and it is n^3 a round: 85 s for 1,000 players.
  #
  # The LOCAL graph is the bracket alone. It is exact too, but only under
  # conditions this function checks first, and the argument for it goes
  # like this. Suppose the bracket has an even number of members, every one
  # of them a non-candidate for the bye, and suppose (a) the bracket has a
  # perfect internal matching on legal edges and (b) the rest of the field
  # can be perfectly matched among themselves (leaving the one bye, if any,
  # on a bye candidate). Then every matching that is optimal on the ladder
  # pairs the bracket internally: the completion rung is maximal with the
  # bracket internal, by (a) and (b), and C6 -- pairs inside the bracket,
  # which outranks everything below it -- is maximal ONLY with the bracket
  # internal. An internal bracket shares no edge with the rest, so the
  # optimum splits: the bracket's part is the optimum over the bracket's
  # own edges with the bracket's own weights, which is what the local graph
  # computes, and the rest's part is constant across every candidate. The
  # eight stages only ever add to bracket-internal edges, in the reserve
  # band below every rung, so none of them can break (a)'s internality
  # either, and each stage's optimum is again the local one.
  #
  # (a) is what the local graph's own first solve establishes -- the
  # completion rung is the top rung, so its maximum-weight matching is a
  # maximum-cardinality one, and it is perfect or it is not. (b) is what
  # `oracle_completable?/2` establishes: a sparse maximum-cardinality
  # matching over the field with this bracket removed, sound in the
  # direction that matters (a matching it finds is real; one it misses
  # costs a fall back to the field graph, never a wrong answer). The
  # non-candidate condition is what makes the completion rung's per-vertex
  # terms a constant for the bracket and keeps C9 and the C9 gate out of
  # it -- see `local_eligible?/4`.
  #
  # What the local graph does NOT claim is the tie-break. When two
  # matchings tie on every rung and on the nearness term, the two graphs
  # could in principle settle it differently; the stages are built to
  # leave no such tie, and the corpus is the judge.
  # Two paths only so the debug trace can time and label a bracket without
  # costing anything when it is switched off: `Log.debug?/0` is one
  # application-env read per bracket, and the timing wrapper is not built
  # at all otherwise. See `Ainalrami.Log`.
  defp pair_bracket(combined, sgb, nsgb, wsgb, ctx, single_bye?) do
    if Log.debug?() do
      {us, {path, result}} =
        :timer.tc(fn -> pair_bracket_solve(combined, sgb, nsgb, wsgb, ctx, single_bye?) end)

      Log.debug(fn -> bracket_trace(combined, sgb, nsgb, wsgb, path, us) end)
      result
    else
      {_path, result} = pair_bracket_solve(combined, sgb, nsgb, wsgb, ctx, single_bye?)
      result
    end
  end

  # `path` says which of the three routes the bracket took, which is the
  # first thing worth knowing when one is slow or wrong: `idle` did no
  # work, `local` solved the bracket on its own graph, `field` fell back to
  # the whole remaining field. See `pair_bracket/6`'s own comment and
  # docs/engineering-log.md, "The local graph".
  defp pair_bracket_solve(combined, sgb, nsgb, wsgb, ctx, single_bye?) do
    m = length(combined)

    with false <- idle_bracket?(combined, nsgb, wsgb, ctx),
         true <- local_eligible?(combined, nsgb, wsgb, ctx),
         {:ok, path, result} <- attempt_local(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
      {path, result}
    else
      :idle ->
        {:idle, {[], combined, nsgb, Enum.map(Enum.take(combined, min(wsgb, m)), & &1.points)}}

      false ->
        with :no <- attempt_direct_last(combined, m, sgb, nsgb, wsgb, ctx, single_bye?),
             :no <- attempt_direct_field(combined, m, sgb, nsgb, wsgb, ctx, single_bye?),
             :no <- attempt_direct_empty(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
          {:field, attempt_field(combined, m, sgb, nsgb, wsgb, ctx, single_bye?)}
        else
          {:ok, result} -> {:direct, result}
        end

      _ ->
        case attempt_direct_empty(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
          {:ok, result} -> {:direct, result}
          :no -> {:field, attempt_field(combined, m, sgb, nsgb, wsgb, ctx, single_bye?)}
        end
    end
  end

  # `nsgb` is the bracket's own size and `sgb` its moved-down count, which
  # are the two numbers that actually predict cost -- not `length(combined)`,
  # which includes the peek and is routinely the whole field on a cheap
  # bracket.
  defp bracket_trace(combined, sgb, nsgb, wsgb, path, us) do
    score =
      case combined do
        [%{points: p} | _] -> :erlang.float_to_binary(p / 1, decimals: 1)
        _ -> "?"
      end

    "bracket score=#{score} size=#{nsgb} mdps=#{sgb} window=#{wsgb} " <>
      "combined=#{length(combined)} path=#{path} #{us}us"
  end

  # A bracket with fewer than two members cannot finalise a pair at all --
  # `collect_bracket/1` records one only when BOTH ends are inside the
  # bracket -- so the whole solve exists for its tentative matching, and
  # the only thing downstream reads that for is `carried_partner_scores`,
  # which feeds `bracket_loop/6`.s C9 gate and nothing else. When that
  # gate.s own preconditions do not hold, the solve has no observable
  # effect and is skipped: the bracket carries everyone forward, its
  # members counted as this round.s downfloaters, and every carried player
  # reports their own score, which is what an unmatched vertex reports
  # anyway (bbpPairings reads one as matched to itself).
  #
  # This is not a rare shape. A lone leader at the top of a large Swiss is
  # the FIRST bracket of the round, so the graph it was solving was the
  # whole field: 660 ms of a 1,334 ms round at 400 players, for nothing.
  defp idle_bracket?(combined, nsgb, wsgb, ctx) do
    if nsgb < 2, do: not c9_gate_live?(combined, nsgb, wsgb, ctx) && :idle, else: false
  end

  # The first four conjuncts of `bracket_loop/6`.s `next_single_bye?`, the
  # ones that do not depend on the tentative matching. False here and the
  # gate is false whatever the carried players report.
  defp c9_gate_live?(combined, nsgb, wsgb, ctx) do
    ctx.odd_field? and not is_nil(ctx.bye_score) and wsgb > nsgb and
      ctx.bye_score >= Enum.at(combined, nsgb).points
  end

  # The bracket can be paired on its own graph only if its members are all
  # non-candidates for the bye -- which on an odd field means everyone in
  # the window scores above `bye_score`, and on an even one means nobody in
  # the window is an eligible player on zero points (`bye_candidate?/2`'s
  # even-field reading). That is what keeps three things out of the local
  # computation: the completion rung's `!isByeCandidate` terms are then the
  # same for every bracket member; `c9_rank/3` is zero for everyone in it;
  # and `bracket_loop/6`'s C9 gate for the NEXT bracket cannot fire, since
  # it needs the bye score to reach the next group. The local path's
  # tentative matching says nothing about the field below, which is fine
  # precisely because nothing downstream reads it here.
  #
  # An ODD bracket floats one member, and who floats is decided jointly
  # with the field below. The local graph stands the next score group in
  # with ONE vertex (`local_graph_length/1`), and that is exact when two
  # things hold -- see `stand_in_edges/7` for the argument:
  #
  #   * every member of the bracket has at least one legal, colour-
  #     compatible partner in the next group, so every one of them can
  #     take the C8 float and none is forced deeper; and
  #   * the next group is large enough that taking any one member out of
  #     it leaves it as well off as taking any other -- its internal
  #     matching number unchanged, its own float (if the parity forces
  #     one) still placeable below. That is a property of a DENSE group,
  #     and `@local_min_next_group` is where "dense enough" is drawn: a
  #     group that size with the legality a real event has is never
  #     fragile, and brackets over smaller groups are cheap on the field
  #     graph anyway, since the field below them is small.
  #
  # The second condition is the one that is not certified term by term,
  # and it is the one the corpus is asked to judge: the small-field axes
  # put every bracket on the field graph, and the 60-120 and 150-250
  # axes put the large ones here.
  @local_min_next_group 16

  defp local_eligible?(combined, nsgb, wsgb, ctx) do
    window = Enum.take(combined, min(wsgb, length(combined)))

    env_flag(@env_nofast_key, "AINALRAMI_NOFAST") == nil and nsgb >= 2 and
      Enum.all?(window, fn p ->
        if ctx.odd_field?,
          do: not is_nil(ctx.bye_score) and p.points > ctx.bye_score,
          else: not bye_candidate?(p, nil)
      end) and
      (rem(nsgb, 2) == 0 or floats_placeable?(combined, nsgb, wsgb))
  end

  defp floats_placeable?(combined, nsgb, wsgb) do
    {bracket, rest} = Enum.split(combined, nsgb)
    next_group = Enum.take(rest, wsgb - nsgb)

    length(next_group) >= @local_min_next_group and
      Enum.all?(bracket, fn a ->
        Enum.any?(next_group, fn b -> legal_pair?(a, b) and colour_compatible?(a, b) end)
      end)
  end

  # The local graph is the bracket -- plus, for an odd bracket, one vertex
  # at position `nsgb` standing in for the whole next score group.
  defp local_graph_length(nsgb), do: nsgb + rem(nsgb, 2)

  # The stand-in's edges: one per bracket member that has a legal,
  # colour-compatible partner in the next group, weighted as that member's
  # float edge.
  #
  # Why one vertex is exact. Under the eligibility conditions an odd
  # bracket's optimum has exactly one member F floating into the next
  # group: C6 wants the other (b-1)/2 pairs internal, and C8 and its score
  # term put the float in the NEXT group rather than deeper, which
  # `floats_placeable?/3` says it always can be. The float edge (F, G)
  # scores the completion rung, C8 and C8's score term and nothing else --
  # every other rung is gated on `in_current`, and under `local_eligible?/4`
  # the completion rung's per-vertex terms are the same for every G -- so
  # its weight depends on F alone and is the same for every legal G. What
  # the field below is worth once G is gone is, by the density condition,
  # the same whichever G it was. So what decides F is the bracket's
  # internal optimum without F plus F's own float weight: the local graph
  # with the stand-in, exactly. The stand-in's weight for F is computed
  # against F's first legal partner in the group, which by the above is
  # the weight against any of them.
  #
  # The stand-in also carries the right tie-break. The nearness term on a
  # real float edge (F, G) is `n - (G - F)`; two bracket members compare
  # on it by `F - F'` whatever G is, and that is what a stand-in at a fixed
  # position gives them too.
  defp stand_in_edges(base, arr, sgb, nsgb, wsgb, ctx, bands, single_bye?) do
    if rem(nsgb, 2) == 0 do
      base
    else
      Enum.reduce(0..(nsgb - 1)//1, base, fn i, acc ->
        a = elem(arr, i)

        g =
          Enum.find(nsgb..(wsgb - 1)//1, fn j ->
            b = elem(arr, j)
            legal_pair?(a, b) and colour_compatible?(a, b)
          end)

        case g && bracket_edge_weight(a, elem(arr, g), nsgb, sgb, 1, ctx, bands, single_bye?) do
          nil -> acc
          w -> Map.put(acc, {i, nsgb}, w)
        end
      end)
    end
  end

  # The stages on the local graph, or - where it can be shown to be the same
  # answer - the direct bracket (`direct_bracket/7`), which finds that answer
  # without a matcher. Either way the same condition (b) follows.
  defp attempt_local(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    case direct_bracket(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
      {:ok, result} ->
        if env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "check" do
          check_direct!(result, local_stages(combined, m, sgb, nsgb, wsgb, ctx, single_bye?))
        end

        accept_local(result, ctx, :direct, fn -> {combined, m, sgb, nsgb, wsgb, single_bye?} end)

      :no ->
        case local_stages(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
          {:ok, result} ->
            accept_local(result, ctx, :local, fn ->
              {combined, m, sgb, nsgb, wsgb, single_bye?}
            end)

          :field ->
            :field
        end
    end
  end

  defp local_stages(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    wl = local_graph_length(nsgb)
    st = new_bracket(:local, combined, m, sgb, nsgb, wsgb, wl, ctx, single_bye?) |> solve()

    if map_size(st.matching) == wl do
      {:ok, st |> run_stages() |> collect_bracket()}
    else
      :field
    end
  end

  # `bracket` gives the bracket's arguments back, for check mode.
  defp accept_local({pairs, _, _, _} = result, ctx, path, bracket) do
    # Condition (b): with this bracket's finalised players gone, the rest
    # -- the floater included, on an odd bracket -- can still be paired.
    positions =
      Enum.flat_map(pairs, fn {w, b} ->
        [Map.fetch!(ctx.field_index, w), Map.fetch!(ctx.field_index, b)]
      end)

    Process.delete(@oracle_dense_key)

    case oracle_completable?(Process.get(@oracle_key), positions) do
      {:ok, oracle} ->
        # Condition (b) shown only by the whole compatible graph
        # (`oracle_dense/2`): check mode holds the bracket to the field path
        # from the same state as well.
        if Process.delete(@oracle_dense_key) do
          cert_count(:local_dense)

          if env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "check" do
            {combined, m, sgb, nsgb, wsgb, single_bye?} = bracket.()
            check_direct_field!(result, combined, m, sgb, nsgb, wsgb, ctx, single_bye?)
            cert_count(:local_dense_checked)
          end
        end

        # The bracket is out of the field for good, for the oracle and
        # for the field matcher alike: the next field-graph bracket
        # rebuilds its matcher from the players that remain.
        Process.put(@oracle_key, oracle)
        {_, field_index, field_size} = Process.get(@round_matcher_key)
        Process.put(@round_matcher_key, {nil, field_index, field_size})
        # The next field bracket builds its matcher from nothing, exactly
        # as the reference does, so no shortcut's state survives this.
        Process.put(@taint_key, false)
        Process.delete(@virtual_builder_key)
        Process.delete(@builder_c9_key)
        {:ok, path, result}

      :no ->
        :field
    end
  end

  # A bracket the local graph turned away, answered directly on the field
  # graph's terms. Two shapes, both with the C9 rung off (in this bracket and
  # on the far edges the round matcher would carry), no soft pairs, and only
  # in certified mode:
  #
  # **An even bracket of an even field** whose window holds bye candidates
  # (players on zero, who on an even field make the completion rung vary).
  # With no bye, every optimum of the field graph is a perfect matching (the
  # completion rung is `|M|` plus the matched non-candidates, both largest
  # only on a perfect matching), so once the bracket has a perfect internal
  # matching and the rest of the field has one too, C6 puts the bracket
  # inside in every optimum, and the bracket's part is its own optimum - the
  # direct bracket's answer, whose even-bracket bounds hold whatever the
  # completion rung does (its sum is the same over every perfect matching of
  # the bracket).
  #
  # **An odd bracket** whose window is all non-candidates but whose next
  # group is too small, or not connected enough, for the stand-in. Every
  # optimum pairs the bracket but one resident F, who floats; the ladder
  # then ranks the floaters by the completion rung and C8 before anything
  # the direct walk bounds, and for F the part of the field outside the
  # bracket can do no better than: completed (the rung's bound), with
  # `div(q + 1, 2)` pairs among the next group and F (`q` its size), F among
  # them - C8's bounds. With `q` odd, where the rest of the field can be
  # completed with the window gone, a floater meets those bounds exactly
  # when the next group and F are perfectly matched; with `q` even the
  # `q / 2` pairs leave one of the next group over, and a floater meets them
  # exactly when those pairs can cover F and leave over a player the rest
  # of the field can be completed with (a "taker", shown one by one by the
  # oracle, which proves what it finds). Both are found for every resident
  # at once (`absorbed_pool/5`). Those floaters are
  # the walk's pool (`direct_field_pool/5`), and on every ladder rung below
  # C8 the rest of the field scores nothing, so the bracket's answer is the
  # direct walk's over that pool.
  #
  # On an ODD field two more shapes, both where the bracket's window reaches
  # the players the bye may go to. With one bye, every optimum of the field
  # graph pairs all but one player and leaves over a bye candidate, when
  # that can be done at all (the completion rung is `|M|` plus the matched
  # non-candidates: largest on a near-perfect matching whose leftover is a
  # candidate) - a property of the whole matching, whatever each edge's own
  # term is. And the next bracket's C9 gate, which reads the tentative
  # partners of this window, must be decided without them: it is shut when
  # the next group scores above the bye, and when the next group is the last
  # one every partner the window can have scores at least as much as it, so
  # the gate reads true on both paths (`direct_result/4` reports scores that
  # say so). Anything else falls back.
  #
  # **An even bracket of an odd field**: as on an even field, once the
  # bracket has a perfect internal matching and the rest of the field can be
  # completed leaving a candidate over (the oracle, after the walk), every
  # optimum has the bracket inside (C6), and the bracket's part is its own
  # optimum.
  #
  # **An odd bracket over the bye group**: every member of the bracket above
  # the bye score, the next group the last group. The argument of the odd
  # bracket above holds with "completed" read as "near-perfect, leaving a
  # candidate": a resident F meets the completion and C8 bounds exactly when
  # the group and F have `q / 2` pairs covering F and leaving a candidate
  # over (`bye_group_pool/4`, exact), every such F meets them alike, and
  # below C8 the group scores nothing - C9 is off here, and the completion
  # rung's per-edge terms only move the matching's total, which is the same
  # for every such F.
  #
  # The reference would carry the round matcher it built here into the next
  # bracket; this leaves none. Every far edge a later bracket builds is the
  # weight the reference carries, as long as the C9 gate that builds it
  # matches the one the reference's was built with (the other ladder terms
  # of a far edge do not depend on the bracket that scores it, and every
  # member of this bracket but a floater is finalised), which
  # `attempt_field/7` checks; only the matcher's state then differs, which is
  # what a tainted round's certified reads are for.
  defp attempt_direct_field(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    {round_matcher, field_index, field_size} = Process.get(@round_matcher_key)

    far_c9 =
      if round_matcher == nil, do: single_bye?, else: Process.get(@builder_c9_key, true)

    arr = List.to_tuple(combined)
    Process.delete(@oracle_dense_key)

    with true <- Process.get(@cert_key) == true and not single_bye? and not far_c9,
         true <- direct_allowed?(sgb, nsgb),
         {:ok, pool, kind} <- direct_field_pool(arr, sgb, nsgb, wsgb, ctx),
         {:ok, {pairs, _, _, _} = result} <-
           direct_bracket(
             combined,
             m,
             sgb,
             nsgb,
             wsgb,
             ctx,
             single_bye?,
             pool,
             false,
             kind == :odd
           ),
         positions =
           Enum.flat_map(pairs, fn {w, b} ->
             [Map.fetch!(ctx.field_index, w), Map.fetch!(ctx.field_index, b)]
           end),
         {:ok, oracle} <- oracle_completable?(Process.get(@oracle_key), positions) do
      if env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "check" do
        check_direct_field!(result, combined, m, sgb, nsgb, wsgb, ctx, single_bye?)
        cert_count({:direct_field_checked, kind})
      end

      cert_count({:direct_field, kind})
      if Process.delete(@oracle_dense_key), do: cert_count({:direct_field_dense, kind})
      Process.put(@oracle_key, oracle)
      Process.put(@round_matcher_key, {nil, field_index, field_size})
      Process.put(@virtual_builder_key, false)
      if nsgb < m, do: taint!()
      {:ok, result}
    else
      _ -> :no
    end
  end

  # A bracket none of whose members can play each other - the two leaders
  # of a late round who have met, a group of two or three who all have.
  # The field graph has no edge between two of them (an edge is only ever
  # made for a legal, colour-compatible pair, `bracket_edge_weight/8`), so
  # no matching pairs two of them, and `collect_bracket/1` finalises a pair
  # only with both ends in the bracket: whatever the stages do, the field
  # path pairs nobody, carries everyone forward in order and counts every
  # member as floating. What it would also leave is the round matcher and
  # the tentative partners' scores; the scores are read only by the next
  # bracket's C9 gate, so the gate must be shut on its own terms
  # (`c9_gate_live?/4`), and the matcher is the certified mode's, on the
  # same terms as `attempt_direct_field/7` (C9 off here and on the far
  # edges, a later builder gate held to the reference's). At round 9 of a
  # 926-player field the two leaders who had met sent the round's first
  # bracket to the field graph for 2.6 s.
  defp attempt_direct_empty(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    {round_matcher, field_index, field_size} = Process.get(@round_matcher_key)

    far_c9 =
      if round_matcher == nil, do: single_bye?, else: Process.get(@builder_c9_key, true)

    with true <- Process.get(@cert_key) == true and not single_bye? and not far_c9,
         true <- direct_allowed?(0, nsgb),
         false <- c9_gate_live?(combined, nsgb, wsgb, ctx),
         arr = List.to_tuple(combined),
         false <-
           Enum.any?(0..(nsgb - 2)//1, fn i ->
             a = elem(arr, i)

             Enum.any?((i + 1)..(nsgb - 1)//1, fn j ->
               b = elem(arr, j)
               legal_pair?(a, b) and colour_compatible?(a, b)
             end)
           end) do
      result = {[], combined, nsgb, Enum.map(Enum.take(combined, min(wsgb, m)), & &1.points)}

      if env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "check" do
        check_direct_field!(result, combined, m, sgb, nsgb, wsgb, ctx, single_bye?)
        cert_count({:direct_field_checked, :empty})
      end

      cert_count({:direct_field, :empty})
      Process.put(@round_matcher_key, {nil, field_index, field_size})
      Process.put(@virtual_builder_key, false)
      if nsgb < m, do: taint!()
      {:ok, result}
    else
      _ -> :no
    end
  end

  # The last bracket of an odd field: whoever it leaves over takes the bye.
  # Answered by the direct bracket with the bye as its floater, in any mode -
  # nothing is paired after it, so no later bracket reads a matcher it did
  # not leave.
  #
  # The bracket is the whole remaining graph (no next group, nothing below),
  # so every edge is inside it. The completion rung sums to the matched
  # pairs (none under `AINALRAMI_COMPLETION=eligibility`) plus the matched
  # non-candidates, and C6 to the pairs; a matching of `P = nsgb div 2`
  # pairs leaving a bye candidate L over meets both bounds, so once the walk
  # has found one, every optimum is such a matching. Over those, two rungs
  # are sums of per-vertex terms fixed by L alone: the completion rung, and
  # C9 when its gate is on, `(sum of the unplayed-game ranks) - rank(L)`,
  # largest for the least rank (the most games played: C9's "fewest
  # unplayed games of the assignee"); C7, between them, pairs every MDP, so
  # L is a resident. The pool is the resident candidates of that least rank,
  # and every optimum's L is among them. Below C9 the ladder is the local
  # graph's, with the floater
  # standing on no edge at all, which is how the walk already treats an odd
  # bracket's floater (the stand-in's edge is outside the bracket, where no
  # rung below C9 is live); and the stages read an unmatched member exactly
  # as one matched to the stand-in - not paired down, and in the remainder.
  # The walk skips the per-edge completion and C9 tests here for that
  # reason: their sums are fixed by L.
  defp attempt_direct_last(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    with true <-
           ctx.odd_field? and not is_nil(ctx.bye_score) and rem(nsgb, 2) == 1 and nsgb == m and
             wsgb == m,
         true <- direct_allowed?(sgb, nsgb),
         arr = List.to_tuple(combined),
         [_ | _] = pool <- last_pool(arr, sgb, nsgb, ctx, single_bye?),
         {:ok, result} <-
           direct_bracket(combined, m, sgb, nsgb, wsgb, ctx, single_bye?, pool, true) do
      if env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "check" do
        check_direct_last!(result, combined, m, sgb, nsgb, wsgb, ctx, single_bye?)
        cert_count({:direct_field_checked, :last})
      end

      cert_count({:direct_field, :last})
      {:ok, result}
    else
      _ -> :no
    end
  end

  # The residents the last bracket may leave over, as its rungs above C10
  # allow (see `attempt_direct_last/7`).
  defp last_pool(arr, sgb, nsgb, ctx, single_bye?) do
    candidates = Enum.filter(sgb..(nsgb - 1)//1, &bye_candidate?(elem(arr, &1), ctx.bye_score))
    rank = &unplayed_rank(elem(arr, &1), ctx)

    if single_bye? and candidates != [] do
      least = candidates |> Enum.map(rank) |> Enum.min()
      Enum.filter(candidates, &(rank.(&1) == least))
    else
      candidates
    end
  end

  # The floaters a field-graph bracket may take (see `attempt_direct_field/7`),
  # with the shape's name for the counters: `{:ok, nil, _}` for an even
  # bracket, `{:ok, pool, _}` for an odd bracket whose field below is shown
  # to take any of the pool and none of the other residents, `:no`
  # otherwise.
  defp direct_field_pool(arr, sgb, nsgb, wsgb, ctx) do
    q = wsgb - nsgb
    m = tuple_size(arr)
    bye_score = ctx.bye_score

    non_candidate? = fn p ->
      if ctx.odd_field?,
        do: not is_nil(bye_score) and p.points > bye_score,
        else: not bye_candidate?(p, nil)
    end

    # On an odd field, what the next bracket's C9 gate reads off this one
    # is decided without a matching when the next group scores above the
    # bye (the gate is shut) or is the last group (every tentative partner
    # in the window then scores at least as much as it).
    gate_decided? = fn ->
      q >= 1 and not is_nil(bye_score) and
        (elem(arr, nsgb).points > bye_score or window_to_end?(wsgb, m))
    end

    cond do
      rem(nsgb, 2) == 0 and not ctx.odd_field? ->
        {:ok, nil, :even}

      rem(nsgb, 2) == 0 ->
        if gate_decided?.(), do: {:ok, nil, :even_odd_field}, else: :no

      q < 1 ->
        :no

      not Enum.all?(0..(wsgb - 1)//1, &non_candidate?.(elem(arr, &1))) ->
        members_ok? = Enum.all?(0..(nsgb - 1)//1, &non_candidate?.(elem(arr, &1)))

        cond do
          ctx.odd_field? and gate_decided?.() and window_to_end?(wsgb, m) and members_ok? ->
            bye_group_pool(arr, sgb, nsgb, ctx)

          # An even field whose next group holds players on zero: the
          # completion rung's per-edge terms vary there, but every optimum
          # is a perfect matching, over which they sum to the same (see
          # `attempt_direct_field/7`), so the odd bracket's argument holds.
          not ctx.odd_field? and members_ok? ->
            odd_field_pool(arr, sgb, nsgb, wsgb, ctx, :odd_zero_group)

          true ->
            :no
        end

      true ->
        odd_field_pool(arr, sgb, nsgb, wsgb, ctx, :odd)
    end
  end

  # The pool of an odd bracket on the field graph (see
  # `attempt_direct_field/7`): the residents the next group absorbs, once
  # the rest of the field is shown to complete around it.
  defp odd_field_pool(arr, sgb, nsgb, wsgb, ctx, kind) do
    q = wsgb - nsgb

    # Solved once here rather than by each question below, which would
    # otherwise each solve the whole field from cold. The oracle's
    # answers are properties of its graph, not of the state it keeps.
    oracle = solved_oracle()
    pos = fn i -> Map.fetch!(ctx.field_index, elem(arr, i).rank) end
    window = Enum.to_list(0..(wsgb - 1)//1)
    next_group = Enum.to_list(nsgb..(wsgb - 1)//1)

    completes? = fn h ->
      positions = window |> List.delete(h) |> Enum.map(pos)
      match?({:ok, _}, oracle_completable?(oracle, positions))
    end

    # The rest of the field completed with the whole window gone - or, with
    # an even next group, with one of it left over: the ones it can take.
    takers =
      cond do
        rem(q, 2) == 1 -> if completes?.(nil), do: [], else: nil
        true -> Enum.filter(next_group, completes?)
      end

    pool =
      if takers == nil or (rem(q, 2) == 0 and takers == []),
        do: [],
        else: absorbed_pool(arr, sgb, nsgb, wsgb, takers)

    if env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "check" and takers != nil,
      do: check_absorbed_pool!(pool, arr, sgb, nsgb, next_group, takers)

    if pool != [], do: {:ok, pool, kind}, else: :no
  end

  # Check mode: the pool asked of each resident on its own - a maximum
  # matching of the next group, the resident and the takers' stand-in; and,
  # on a group of up to 100 that can leave any of its players to the rest
  # (the shape the pool had before the takers), the weighted matching
  # `absorbed?/3` as well.
  defp check_absorbed_pool!(pool, arr, sgb, nsgb, next_group, takers) do
    cert_count(:pool_checked)
    q = length(next_group)
    residents = sgb..(nsgb - 1)//1

    by_cardinality =
      Enum.filter(residents, &absorbed_by_cardinality?(arr, &1, next_group, takers))

    if pool != by_cardinality do
      raise "absorbed pool differs from the per-resident matchings: " <>
              "#{inspect(pool)} vs #{inspect(by_cardinality)}"
    end

    if q <= 100 and (rem(q, 2) == 1 or takers == next_group) and
         pool != Enum.filter(residents, &absorbed?(arr, &1, next_group)) do
      raise "absorbed pool differs from the weighted per-resident matchings: #{inspect(pool)}"
    end
  end

  # The residents `f` the next group absorbs, found for all of them at once.
  # With `N` the next group (`q` players) and every edge legal and colour-
  # compatible:
  #
  #   * `q` odd: `N` and `f` are perfectly matched exactly when `f` can play
  #     some `G` with `N - G` perfectly matched, i.e. some near-perfect
  #     matching of `N` leaves `G` exposed;
  #   * `q` even: `N` and `f` have `q / 2` pairs covering `f` and leaving over
  #     one of the `takers` (the players of `N` the rest of the field can
  #     take) exactly when `f` can play some `G` with `N - G` holding
  #     `q / 2 - 1` pairs that leave a taker over, i.e. `N - G` plus a vertex
  #     `x` joined to the takers perfectly matched, i.e. some near-perfect
  #     matching of `N + x` leaves `G` exposed.
  #
  # Either way the `G`s are the exposable set of one graph of odd order
  # (`Ainalrami.CardinalityMatching.exposable/1`, the Gallai-Edmonds `D`), and
  # when no maximum matching of it leaves just one vertex exposed, no `f`
  # is absorbed at all (a near-perfect matching of `N`, or of `N + x`, is
  # what any absorbing `f` would give). One search where the per-resident
  # form (`absorbed?/3`) solved a weighted matching of the whole next group
  # per resident: 202 of them over a 199-player group at 600 players round
  # 2. Check mode holds it to per-resident matchings
  # (`check_absorbed_pool!/6`).
  defp absorbed_pool(arr, sgb, nsgb, wsgb, takers) do
    q = wsgb - nsgb
    group = List.to_tuple(for i <- nsgb..(wsgb - 1)//1, do: elem(arr, i))
    compatible? = fn a, b -> legal_pair?(a, b) and colour_compatible?(a, b) end
    order = if rem(q, 2) == 1, do: q, else: q + 1

    pairs =
      for a <- 0..(q - 1)//1,
          b <- (a + 1)..(q - 1)//1,
          compatible?.(elem(group, a), elem(group, b)),
          do: {a, b}

    stand_in = if rem(q, 2) == 1, do: [], else: for(h <- takers, do: {h - nsgb, q})

    adj =
      Enum.reduce(pairs ++ stand_in, Map.new(0..(order - 1)//1, &{&1, []}), fn {a, b}, acc ->
        acc |> Map.update!(a, &[b | &1]) |> Map.update!(b, &[a | &1])
      end)

    adj = List.to_tuple(for v <- 0..(order - 1)//1, do: Enum.reverse(Map.fetch!(adj, v)))

    case CardinalityMatching.exposable(adj) do
      {:ok, exposable} ->
        Enum.filter(sgb..(nsgb - 1)//1, fn f ->
          Enum.any?(0..(q - 1)//1, fn g ->
            MapSet.member?(exposable, g) and compatible?.(elem(arr, f), elem(group, g))
          end)
        end)

      :no ->
        []
    end
  end

  # Whether the next group and `f` have `div(q + 1, 2)` pairs, `f` in one:
  # weights 2 and, on `f`'s edges, 3, so a heaviest matching is a largest
  # one first and covers `f` if a largest one can.
  defp absorbed?(arr, f, next_group) do
    members = List.to_tuple([f | next_group])
    q = length(next_group)

    edges =
      for a <- 0..(q - 1)//1,
          b <- (a + 1)..q//1,
          pa = elem(arr, elem(members, a)),
          pb = elem(arr, elem(members, b)),
          legal_pair?(pa, pb) and colour_compatible?(pa, pb),
          do: {a, b, if(a == 0, do: 3, else: 2)}

    matching = WeightedMatching.solve(q + 1, edges)
    map_size(matching) == 2 * div(q + 1, 2) and is_map_key(matching, 0)
  end

  # Whether `f` is absorbed, as a maximum-cardinality question for check
  # mode: `f` (vertex 0) and the group perfectly matched, with, when the
  # group is even, a vertex joined to the takers to take the one the
  # `q / 2` pairs leave over.
  defp absorbed_by_cardinality?(arr, f, next_group, takers) do
    q = length(next_group)
    members = List.to_tuple([f | next_group])
    order = if rem(q, 2) == 1, do: q + 1, else: q + 2

    pairs =
      for a <- 0..(q - 1)//1,
          b <- (a + 1)..q//1,
          pa = elem(arr, elem(members, a)),
          pb = elem(arr, elem(members, b)),
          legal_pair?(pa, pb) and colour_compatible?(pa, pb),
          do: {a, b}

    index = next_group |> Enum.with_index(1) |> Map.new()

    stand_in =
      if rem(q, 2) == 1, do: [], else: for(h <- takers, do: {Map.fetch!(index, h), q + 1})

    adj =
      Enum.reduce(pairs ++ stand_in, Map.new(0..(order - 1)//1, &{&1, []}), fn {a, b}, acc ->
        acc |> Map.update!(a, &[b | &1]) |> Map.update!(b, &[a | &1])
      end)

    adj = List.to_tuple(for v <- 0..(order - 1)//1, do: Enum.reverse(Map.fetch!(adj, v)))
    map_size(CardinalityMatching.maximum(adj)) == order
  end

  # Whether the window runs to the end of the field: nothing is left below
  # the next group (`AINALRAMI_PEEK=<n>` hides groups from the graph, so
  # there the end of the graph is not the end of the field).
  defp window_to_end?(wsgb, m), do: wsgb >= m and peek_budget() == :unbounded

  # The pool of an odd bracket whose next group is the last group and holds
  # the bye (see `attempt_direct_field/7`): the residents `F` for which the
  # next group and `F` have `q / 2` pairs covering `F` and leaving a bye
  # candidate over. With `x` a vertex joined to the group's candidates,
  # that is "the group plus `x` less some `G` next to `F` has a perfect
  # matching", i.e. `G` is one a maximum matching of the group plus `x` can
  # leave exposed (`Ainalrami.CardinalityMatching.exposable/1`) - one search
  # for every resident at once, where asking per resident is a matching
  # per resident.
  defp bye_group_pool(arr, sgb, nsgb, ctx) do
    m = tuple_size(arr)
    q = m - nsgb
    compatible? = fn a, b -> legal_pair?(a, b) and colour_compatible?(a, b) end

    # Parity: a near-perfect matching of the rest leaves an even group
    # plus the floater.
    if rem(q, 2) == 0 do
      group = List.to_tuple(for i <- nsgb..(m - 1)//1, do: elem(arr, i))
      x = q

      pairs =
        for a <- 0..(q - 1)//1,
            b <- (a + 1)..(q - 1)//1,
            compatible?.(elem(group, a), elem(group, b)),
            do: {a, b}

      stand_in =
        for a <- 0..(q - 1)//1, bye_candidate?(elem(group, a), ctx.bye_score), do: {a, x}

      adj =
        Enum.reduce(pairs ++ stand_in, Map.new(0..q//1, &{&1, []}), fn {a, b}, acc ->
          acc |> Map.update!(a, &[b | &1]) |> Map.update!(b, &[a | &1])
        end)
        |> then(fn adj ->
          List.to_tuple(for v <- 0..q//1, do: Enum.reverse(Map.fetch!(adj, v)))
        end)

      with {:ok, exposable} <- CardinalityMatching.exposable(adj) do
        pool =
          Enum.filter(sgb..(nsgb - 1)//1, fn f ->
            Enum.any?(0..(q - 1)//1, fn g ->
              MapSet.member?(exposable, g) and compatible?.(elem(arr, f), elem(group, g))
            end)
          end)

        if pool != [], do: {:ok, pool, :odd_bye_group}, else: :no
      end
    else
      :no
    end
  end

  # The check for `attempt_direct_field/7`: the field path on a copy of the
  # round's state, compared on what the next bracket reads (the pairs, who
  # is carried, how many float) - its tentative partners' scores are read
  # only by the C9 gate, which cannot open below a window that scores above
  # the bye (an odd field) or on a field with no bye (an even one).
  defp check_direct_field!(
         {pairs, carried, sgb_out, scores},
         combined,
         m,
         sgb,
         nsgb,
         wsgb,
         ctx,
         single_bye?
       ) do
    {ref_pairs, ref_carried, ref_sgb, ref_scores} =
      reference_field_bracket(combined, m, sgb, nsgb, wsgb, ctx, single_bye?)

    # What `bracket_loop/6`'s gate makes of the tentative partners' scores
    # (the gate's other conjuncts are the same on both paths).
    gate = fn scores ->
      c9_gate_live?(combined, nsgb, wsgb, ctx) and
        Enum.all?(scores, &(&1 >= Enum.at(combined, nsgb).points))
    end

    mine = {pairs, Enum.map(carried, & &1.rank), sgb_out, gate.(scores)}
    ref = {ref_pairs, Enum.map(ref_carried, & &1.rank), ref_sgb, gate.(ref_scores)}

    if mine != ref do
      raise "direct field bracket differs from the stages: #{inspect(mine)} vs #{inspect(ref)}"
    end
  end

  # The check for `attempt_direct_last/7`: the last bracket on the field
  # graph, from the same state.
  defp check_direct_last!(
         {pairs, carried, sgb_out, _},
         combined,
         m,
         sgb,
         nsgb,
         wsgb,
         ctx,
         single_bye?
       ) do
    {ref_pairs, ref_carried, ref_sgb, _} =
      reference_field_bracket(combined, m, sgb, nsgb, wsgb, ctx, single_bye?)

    mine = {pairs, Enum.map(carried, & &1.rank), sgb_out}
    ref = {ref_pairs, Enum.map(ref_carried, & &1.rank), ref_sgb}

    if mine != ref do
      raise "direct last bracket differs from the stages: #{inspect(mine)} vs #{inspect(ref)}"
    end
  end

  # `attempt_field/7` on a copy of the round's state.
  defp reference_field_bracket(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    saved =
      for key <- [
            @round_matcher_key,
            @oracle_key,
            @taint_key,
            @cert_memo_key,
            @dirty_key,
            @virtual_builder_key,
            @builder_c9_key
          ],
          do: {key, Process.get(key)}

    reference = attempt_field(combined, m, sgb, nsgb, wsgb, ctx, single_bye?)

    Enum.each(saved, fn
      {key, nil} -> Process.delete(key)
      {key, value} -> Process.put(key, value)
    end)

    reference
  end

  # `AINALRAMI_DIRECT=check`: every direct answer is held to the stages' own
  # on the same bracket, and a difference raises.
  defp check_direct!(direct, stages) do
    view = fn {pairs, carried, sgb, scores} ->
      {pairs, Enum.map(carried, & &1.rank), sgb, scores}
    end

    case stages do
      {:ok, reference} ->
        if view.(direct) != view.(reference) do
          raise "direct bracket differs from the stages: #{inspect(view.(direct))} vs #{inspect(view.(reference))}"
        end

      :field ->
        raise "direct bracket answered where the stages found no perfect local matching"
    end
  end

  defp attempt_field(combined, m, sgb, nsgb, wsgb, ctx, single_bye?) do
    # A bracket about to build the round matcher scores every far edge with
    # its own C9 gate. After a direct field bracket the reference's matcher
    # was built with the gate `@virtual_builder_key` holds, and a different
    # one would be a different graph: the round is paired again without the
    # shortcuts (`certified_cascade/2`) - unless the window is everything that
    # is left: then there is no far edge, the reference's boundary sets every
    # edge of the graph to this bracket's weights (`solve_field/1`), and a
    # matcher built from them is that graph.
    case Process.get(@round_matcher_key) do
      {nil, _, _} ->
        case Process.get(@virtual_builder_key) do
          nil ->
            :ok

          ^single_bye? ->
            Process.delete(@virtual_builder_key)

          _ ->
            if window_to_end?(wsgb, m) do
              cert_count(:builder_gate_whole_window)
              Process.delete(@virtual_builder_key)
            else
              throw({:cert_abort, :builder_gate})
            end
        end

        Process.put(@builder_c9_key, single_bye?)

      _ ->
        :ok
    end

    st =
      new_bracket(:field, combined, m, sgb, nsgb, wsgb, m, ctx, single_bye?)
      |> window_setup()
      |> solve()
      |> run_stages()
      |> flush_live()

    {pairs, _, _, _} = result = collect_bracket(st)
    graft_back(st)

    # Keep the oracle in step: whoever this bracket finalised is out of the
    # field for every later bracket's (b).
    positions =
      Enum.flat_map(pairs, fn {w, b} ->
        [Map.fetch!(ctx.field_index, w), Map.fetch!(ctx.field_index, b)]
      end)

    Process.put(@oracle_key, oracle_remove(Process.get(@oracle_key), positions))
    result
  end

  defp new_bracket(mode, combined, m, sgb, nsgb, wsgb, wl, ctx, single_bye?) do
    arr = List.to_tuple(combined)
    Process.delete(@dirty_key)

    field_pos =
      arr
      |> Tuple.to_list()
      |> Enum.map(&Map.fetch!(ctx.field_index, &1.rank))
      |> List.to_tuple()

    # Field-wide and constant for the round -- see `global_context/2`. That
    # is what bbpPairings does too: `scoreGroupSizeBits`/`scoreGroupShifts`
    # are computed once over `sortedPlayers` and never re-derived per
    # bracket (dutch.cpp:684-730). It is also what makes the weights
    # commensurable: one solve mixes edges scored for this bracket with
    # edges scored as plain completability, and two differently-scaled
    # radices cannot be compared.
    bands = ctx.bands

    # The field graph scores the whole field only when it is about to BUILD
    # the round matcher from it; once built, a bracket boundary is the
    # window's edges changing on an existing graph.
    {round_matcher, _, field_size} = Process.get(@round_matcher_key)
    transposition = transposition_terms(m, sgb, nsgb)

    {base, prebuilt} =
      case mode do
        :local ->
          base =
            arr
            |> base_edge_weights(m, sgb, nsgb, nsgb, ctx, bands, single_bye?)
            |> stand_in_edges(arr, sgb, nsgb, wsgb, ctx, bands, single_bye?)

          {base, nil}

        :field ->
          if round_matcher == nil and
               first_build_rows?(transposition, m, nsgb, wsgb) do
            first_field_build(arr, field_pos, field_size, sgb, nsgb, ctx, bands, single_bye?)
          else
            scored = if round_matcher != nil, do: min(wsgb, m), else: m
            {base_edge_weights(arr, m, sgb, nsgb, scored, ctx, bands, single_bye?), nil}
          end
      end

    %{
      mode: mode,
      arr: arr,
      field_pos: field_pos,
      from_field: field_pos |> Tuple.to_list() |> Enum.with_index() |> Map.new(),
      m: m,
      wl: wl,
      sgb: sgb,
      nsgb: nsgb,
      wsgb: wsgb,
      ctx: ctx,
      bands: bands,
      base: base,
      live: base,
      wm: nil,
      synced: false,
      transposition: transposition,
      # The round matcher's rows, built with `base` by `first_field_build/8`
      # for the solve that builds the matcher (`solve_field/1`), and dropped
      # by it.
      prebuilt: prebuilt,
      # Any value above every real weight will do: `finalize_pair/3`
      # leaves the two vertices exactly one usable edge each, so the pair
      # is forced regardless of magnitude.
      max_w: 1 + (base |> Map.values() |> Enum.max(fn -> 0 end)),
      matched: MapSet.new(),
      matching: %{},
      # The round matcher as of the moment `matching` was last read off it
      # (field graph only), for certifying reads - see `certified/3`.
      snap: nil,
      # A matching the next certified install may try besides the one held.
      guess: nil,
      # Set when the bracket runs on its window alone - see `window_setup/1`.
      window: nil,
      remainder: [],
      remainder_pairs: 0,
      exchange_count: 0
    }
  end

  defp run_stages(st) do
    st
    |> trace_stage("initial solve")
    |> stage_select_mdps()
    |> trace_stage("1 select MDPs")
    |> stage_mdp_opponents()
    |> trace_stage("2 MDP opponents")
    |> stage_build_remainder()
    |> trace_stage("3 remainder")
    |> stage_exchange_weights()
    |> trace_stage("4 exchange weights")
    |> stage_exchange_lower_from_higher()
    |> trace_stage("5 lower-from-higher")
    |> stage_exchange_higher_from_lower()
    |> trace_stage("6 higher-from-lower")
    |> stage_reset_exchange_bits()
    |> trace_stage("7 reset bits")
    |> stage_first_group_partners()
    |> trace_stage("8 first-group partners")
  end

  # How many pairs the bracket would KEEP if it stopped here. Set
  # AINALRAMI_TRACE=1 to watch it across the eight stages: the count should
  # never fall, and a stage where it does is dropping a pair the criteria
  # say it should have kept.
  defp trace_stage(st, label) do
    if env_flag(@env_trace_key, "AINALRAMI_TRACE") do
      kept =
        Enum.count(0..(st.m - 1)//1, fn i ->
          p = partner(st, i)
          i < st.nsgb and p != i and p < st.nsgb and i < p
        end)

      ranks = st.arr |> Tuple.to_list() |> Enum.map(& &1.rank)

      matched =
        for i <- 0..(st.m - 1)//1,
            p = partner(st, i),
            p != i and i < p,
            do: {Enum.at(ranks, i), Enum.at(ranks, p)}

      IO.puts(
        "    [trace] m=#{st.m} sgb=#{st.sgb} nsgb=#{st.nsgb} #{label}: #{kept} internal" <>
          " | #{inspect(ranks, charlists: :as_lists)} -> #{inspect(matched, charlists: :as_lists)}"
      )
    end

    st
  end

  ## ---------- the direct bracket ----------
  #
  # A bracket that takes the local graph (`local_eligible?/4`) is paired by
  # the eight stages on that graph, and what they return is fixed by the
  # weights alone. Where the answer is also one Article 3's own order finds
  # directly - moved-down players against residents in rank order, then S1
  # against S2 with no exchange - it can be found by walking that order and
  # PROVED to be the stages' answer, without a matcher. Gacrux pairs most
  # brackets this way; this is the same walk, held to a proof instead of
  # trusted.
  #
  # ## What the stages return, when the walk can succeed
  #
  # The local graph is the bracket (MDPs `0..sgb-1`, residents `sgb..nsgb-1`)
  # plus, when `nsgb` is odd, the stand-in for the next group. Under
  # `local_eligible?/4` every member is a non-candidate for the bye, so every
  # edge's completion rung is the same (three, or two under
  # `AINALRAMI_COMPLETION=eligibility`) and the rung counts edges: once a
  # perfect matching exists every optimum is perfect - `P = nsgb div 2`
  # pairs inside the bracket and, on an odd bracket, one member on the
  # stand-in. Write `C*` for the optimal weight of the criteria (everything
  # above the stages' reserved band). Then:
  #
  #   * stage 1 commits every MDP that every `C*`-optimum pairs inside;
  #   * stage 2 gives each MDP in turn the best-ranked resident some
  #     `C*`-optimum (with the earlier MDPs' pairs) gives it;
  #   * stages 3-4 take the remainder, split S1 = its first `div(|R|, 2)`,
  #     S2 the rest, and weight every remainder pair so that the optima are
  #     the `C*`-optima with the fewest exchanges - none, if one of them pairs
  #     S1 wholly into S2 (the odd one out, if any, from S2 on the stand-in);
  #     every such optimum has the same second stage-4 term, the sum of S1's
  #     positions;
  #   * stages 5 and 6 then have no exchange to make, stage 7 cuts every
  #     S1-S1 and S2-S2 edge, and stage 8 gives each S1 player in turn the
  #     best-ranked S2 player some `C*`-optimum (with the pairs already
  #     made) gives it - its addends are distinct per opponent, so no tie
  #     survives it.
  #
  # So when some `C*`-optimum pairs every MDP and pairs S1 into S2, the
  # stages return the first such matching in the order "MDP partners in
  # turn, then S1 partners in turn" - and a depth-first walk of exactly that
  # order, which only ever discards a choice that cannot be completed to a
  # `C*`-optimum, finds it as its first complete answer.
  #
  # ## Knowing `C*` without a matcher
  #
  # The walk accepts only a matching that meets an upper bound on every rung
  # at once, which makes it a `C*`-optimum outright. For a perfect matching
  # of the local graph, rung by rung (`ladder_rungs/6`; the stand-in edge is
  # outside the bracket, where only the completion and C8 rungs are live):
  #
  #   * completion, C6, C8 pairs: the same on every perfect matching;
  #   * C7: at most every MDP's place plus `P - sgb` residents' places, met
  #     exactly when every MDP is paired with a resident - so C7's optima all
  #     do that, and on an odd bracket float a resident;
  #   * C8 scores: a resident's place on every one of those; C9: zero (no
  #     member scores the bye score), as are C18 and C20's variable parts;
  #   * C10, C11, C15, C17, C19, C21: at most their per-edge best on every
  #     pair, met when every pair meets it;
  #   * C12 and C13: counting bounds (`colour_lb/1`). With `W`, `B`, `Z` the
  #     members preferring White, Black and nothing, every perfect matching
  #     has at least `(W - B - Z)/2` White-White pairs, so at least `K`
  #     colour clashes; one with exactly `K` has every clash White-White, and
  #     a White-White pair keeps C13 only with a mild member or two absolute
  #     ones, so at least `K - mild - div(absolute, 2)` of them break it. On
  #     an odd bracket the floater is any resident: the bounds are the
  #     smallest over the residents' types;
  #   * C14 and C16: every paired resident's own downfloat bit, so the bound
  #     is all of them less the smallest a floater can have.
  #
  # Each bound holds over every matching the rungs above it leave in play,
  # so a matching meeting all of them at once is lexicographically maximal:
  # it weighs `C*`. And a choice the walk discards breaks a necessary
  # condition of meeting them - an edge that is missing or below its per-
  # edge best, or colour counts that cannot come back within `K` and the
  # C13 bound whatever the rest does (the same counting bounds, applied to
  # who is left), or no floater left that the C14/C16 bound allows.
  #
  # ## Where the walk gives up
  #
  # A choice for an MDP that passes every necessary condition but whose
  # remainder then has no exchange-free answer is NOT proof that no
  # `C*`-optimum makes it - one with exchanges might - so the walk stops and
  # the stages pair the bracket as before. So does a walk that runs past its
  # budget, and any bracket with soft pairs or with the ladder's
  # experimental switches set. Stopping costs the time spent; it never
  # changes an answer.
  @direct_budget_per_member 32
  @direct_pruned_budget_per_member 128
  @direct_small_max 12
  # Where the walk gives up on a bracket this small, the small bracket's list
  # is still cheap once it is bounded (`direct_small_after_walk/10`).
  @direct_small_fallback_max 16
  @small_fallback_nodes 200_000
  @small_nodes_key :ainalrami_small_nodes

  # `stuck?`: an MDP with no partner in the bracket may be the one floated
  # (`direct_small/11`), on an odd bracket of the field graph over a next
  # group of non-candidates.
  defp direct_bracket(
         combined,
         m,
         sgb,
         nsgb,
         wsgb,
         ctx,
         single_bye?,
         pool \\ nil,
         last? \\ false,
         stuck? \\ false
       ) do
    if direct_allowed?(sgb, nsgb) do
      Process.put(@direct_budget_key, plain_budget(nsgb))

      try do
        arr = List.to_tuple(combined)
        wl = local_graph_length(nsgb)

        if wl <= @direct_small_max do
          weights = small_weights(arr, m, sgb, nsgb, wsgb, ctx, single_bye?, pool, last?)
          {:ok, direct_small(arr, weights, wl, m, sgb, nsgb, wsgb, ctx, pool, :all, stuck?)}
        else
          try do
            try do
              direct_walk(arr, m, sgb, nsgb, wsgb, ctx, single_bye?, pool, last?, false)
            catch
              # The same walk again, pruned (see "The pruned walk" below): it
              # visits the same choices in the same order less the subtrees
              # shown to hold no complete answer, so it ends as the plain walk
              # would have with no budget at all.
              :throw, {:direct_abort, :budget} ->
                cert_count(:direct_pruned)
                Process.put(@direct_budget_key, @direct_pruned_budget_per_member * nsgb + 2048)
                direct_walk(arr, m, sgb, nsgb, wsgb, ctx, single_bye?, pool, last?, true)
            end
          catch
            :throw, {:direct_abort, reason} when wl <= @direct_small_fallback_max ->
              direct_small_after_walk(reason, arr, wl, m, sgb, nsgb, wsgb, ctx, single_bye?, {
                pool,
                last?,
                stuck?
              })
          end
        end
      catch
        :throw, {:direct_abort, reason} ->
          cert_count({:direct_abort, reason})
          :no
      after
        Process.delete(@direct_budget_key)
        Process.delete(@direct_memo_key)
        Process.delete(@direct_edge_key)
      end
    else
      :no
    end
  end

  # The plain walk's budget. `AINALRAMI_DIRECT_PLAIN=<checks>` replaces it,
  # for measurement and for the check runs: at 0 every walk goes straight
  # to the pruned one.
  defp plain_budget(nsgb) do
    case env_flag(@env_direct_plain_key, "AINALRAMI_DIRECT_PLAIN") do
      nil -> @direct_budget_per_member * nsgb + 512
      checks -> String.to_integer(checks)
    end
  end

  defp direct_allowed?(sgb, nsgb) do
    env_flag(@env_direct_key, "AINALRAMI_DIRECT") != "off" and
      env_flag(@env_trace_key, "AINALRAMI_TRACE") == nil and
      env_flag(@env_nofast_key, "AINALRAMI_NOFAST") == nil and
      System.get_env("AINALRAMI_TRANS") == nil and
      System.get_env("AINALRAMI_TRANS_ABOVE") == nil and
      is_nil(Process.get(@soft_key)) and nsgb >= 2 and 2 * sgb <= nsgb
  end

  defp direct_walk(arr, m, sgb, nsgb, wsgb, ctx, single_bye?, pool, last?, pruned?) do
    facts = List.to_tuple(for i <- 0..(nsgb - 1)//1, do: direct_fact(elem(arr, i)))
    odd? = rem(nsgb, 2) == 1
    # Who may float: any resident on the local graph (the stand-in takes
    # every one), the ones the field below can absorb on the field graph.
    residents = if pool == nil, do: Enum.to_list(sgb..(nsgb - 1)//1), else: pool
    type = fn i -> elem(elem(facts, i), 0) end
    counts = Enum.reduce(0..(nsgb - 1)//1, %{}, fn i, acc -> count_add(acc, type.(i), 1) end)

    # Two absolute preferences for the same colour may meet only under the
    # final-round exception (`colour_compatible?/2`), which holds for a pair
    # when it holds for either member on their own.
    absolute_pairs? =
      Enum.any?(0..(nsgb - 1)//1, fn i ->
        p = elem(arr, i)
        final_round_topscorers?(p, p)
      end)

    # The floaters C14 and C16 allow: those with the least (downfloat r-1,
    # downfloat r-2), in that order.
    floaters =
      if odd? do
        least = residents |> Enum.map(&direct_float_bits(facts, &1)) |> Enum.min()
        residents |> Enum.filter(&(direct_float_bits(facts, &1) == least)) |> MapSet.new()
      else
        MapSet.new()
      end

    {k12, k13} =
      if odd? do
        residents
        |> Enum.map(type)
        |> Enum.uniq()
        |> Enum.map(&colour_lb(count_add(counts, &1, -1), absolute_pairs?))
        |> Enum.min()
      else
        colour_lb(counts, absolute_pairs?)
      end

    env = %{
      arr: arr,
      facts: facts,
      sgb: sgb,
      nsgb: nsgb,
      odd?: odd?,
      k12: k12,
      k13: k13,
      absolute_pairs?: absolute_pairs?,
      floaters: floaters,
      ctx: ctx,
      single_bye?: single_bye?,
      # The last bracket of an odd field (`attempt_direct_last/7`): the
      # completion and C9 rungs' sums are fixed by who is left over.
      last?: last?,
      pruned?: pruned?,
      completion:
        if(env_flag(@env_completion_key, "AINALRAMI_COMPLETION") == "eligibility", do: 2, else: 3)
    }

    st = %{
      used: MapSet.new(),
      counts: counts,
      cand: floaters,
      fl: floater_counts(floaters, type),
      c: 0,
      v: 0,
      pairs: [],
      hall: nil
    }

    case direct_mdps(env, st, 0) do
      {:found, st} ->
        cert_count(:direct_ok)
        if pruned?, do: cert_count(:direct_pruned_ok)
        {:ok, direct_result(env, st, m, wsgb)}

      other ->
        throw({:direct_abort, other})
    end
  end

  # `{colour type, downfloat r-1 bit, downfloat r-2 bit}`, the type being the
  # preference and its strength exactly as `colour_criteria/2` reads them.
  defp direct_fact(p) do
    s = p.colour_stats

    strength =
      cond do
        s.absolute? -> :absolute
        s.strong? -> :strong
        is_nil(s.preference) -> :none
        true -> :mild
      end

    {{s.preference, strength}, bit(float_of(p, 1) == :down), bit(float_of(p, 2) == :down)}
  end

  defp direct_float_bits(facts, i) do
    {_type, df1, df2} = elem(facts, i)
    {df1, df2}
  end

  defp count_add(counts, type, by), do: Map.update(counts, type, by, &(&1 + by))

  defp floater_counts(set, type),
    do: Enum.reduce(set, %{}, fn i, acc -> count_add(acc, type.(i), 1) end)

  # `{fewest colour clashes, fewest C13 breaches among those}` over every
  # perfect matching of an even set of members with these types - see the
  # section comment.
  defp colour_lb(counts, absolute_pairs?) do
    tally =
      Enum.reduce(counts, %{}, fn {{pref, strength}, n}, acc ->
        acc |> count_add(pref, n) |> count_add({pref, strength}, n)
      end)

    at = &Map.get(tally, &1, 0)
    {w, b, z} = {at.("w"), at.("b"), at.(nil)}

    pairable = fn pref -> if absolute_pairs?, do: at.({pref, :absolute}), else: 0 end

    cond do
      w > b + z -> colour_lb_side(div(w - b - z, 2), at.({"w", :mild}), pairable.("w"))
      b > w + z -> colour_lb_side(div(b - w - z, 2), at.({"b", :mild}), pairable.("b"))
      true -> {0, 0}
    end
  end

  defp colour_lb_side(k, mild, absolute), do: {k, max(0, k - mild - div(absolute, 2))}

  # Stage 2's order: each MDP in turn against the residents, best-ranked
  # first. `:proven` - no choice here survives a necessary condition, so no
  # `C*`-optimum extends the pairs made so far; anything else ends the walk.
  defp direct_mdps(%{sgb: sgb} = env, st, mdp) when mdp == sgb, do: direct_remainder(env, st)

  defp direct_mdps(env, st, mdp) do
    Enum.reduce_while(env.sgb..(env.nsgb - 1)//1, :proven, fn r, acc ->
      if MapSet.member?(st.used, r) do
        {:cont, acc}
      else
        case direct_try(env, st, mdp, r) do
          :no ->
            {:cont, acc}

          {:ok, next} ->
            case direct_mdps(env, next, mdp + 1) do
              :proven -> {:cont, acc}
              other -> {:halt, other}
            end
        end
      end
    end)
  end

  # Stages 3-8 with no exchange: S1 into S2, each S1 player in turn, best-
  # ranked S2 player first. An exhausted walk here proves nothing about
  # answers with exchanges, so it is `:unproven`.
  defp direct_remainder(env, st) do
    remainder = Enum.reject(env.sgb..(env.nsgb - 1)//1, &MapSet.member?(st.used, &1))
    {s1, s2} = Enum.split(remainder, div(length(remainder), 2))
    type = fn i -> elem(elem(env.facts, i), 0) end

    # Only an S2 player can be left over now.
    cand = if env.odd?, do: MapSet.intersection(env.floaters, MapSet.new(s2)), else: MapSet.new()
    st = %{st | cand: cand, fl: floater_counts(cand, type)}

    if direct_feasible?(env, st.counts, st.fl, st.c, st.v) do
      s1 = List.to_tuple(s1)
      st = if env.pruned?, do: hall_setup(env, st, s1, s2), else: st

      case st.hall != :none and direct_s1(env, st, s1, 0, s2) do
        {:found, _} = found -> found
        _ -> :unproven
      end
    else
      :unproven
    end
  end

  defp direct_s1(env, st, s1, k, s2) when k == tuple_size(s1) do
    leftover = Enum.reject(s2, &MapSet.member?(st.used, &1))

    cond do
      # The bounds are lower bounds: a matching beating one means the
      # argument above does not hold here, and the walk says so.
      st.c < env.k12 or (st.c == env.k12 and st.v < env.k13) ->
        throw({:direct_abort, :bound})

      st.c == env.k12 and st.v == env.k13 and
          (not env.odd? or direct_floater_ok?(st, leftover)) ->
        {:found, st}

      true ->
        :fail
    end
  end

  defp direct_s1(env, st, s1, k, s2) do
    x = elem(s1, k)

    Enum.reduce_while(s2, :fail, fn y, acc ->
      if MapSet.member?(st.used, y) do
        {:cont, acc}
      else
        case env |> direct_try(st, x, y) |> hall_step(k, y) do
          :no ->
            {:cont, acc}

          {:ok, next} ->
            case direct_s1_memo(env, next, s1, k + 1, s2) do
              {:found, _} = found -> {:halt, found}
              :fail -> {:cont, acc}
            end
        end
      end
    end)
  end

  ## The pruned walk
  #
  # The plain walk above is a depth-first search that discards a choice
  # only on the per-edge test and the colour counts, so a conflict near the
  # end of S1 - two late S1 players left with one S2 partner between them -
  # is found again under every choice made above it: on round 9 of the
  # benchmark's 600- and 1,000-player fields the 108- and 169-player
  # brackets needed 30,709 and 22,552 checks (their budgets 3,968 and
  # 5,920), and went to the stages for a second or so.
  #
  # When the plain walk runs out of budget, the same walk runs again with
  # two more ways to discard a subtree, both proofs that it holds no leaf
  # at all - no complete S1-into-S2 matching whose every pair passes the
  # per-edge test with colour counts that come back to the bounds:
  #
  #   * Hall's condition. Every leaf pairs each remaining S1 player with a
  #     distinct remaining S2 player, on an edge that passes the per-edge
  #     test and so is legal and colour-compatible (`direct_pairable?/3`,
  #     a property of the pair alone - the ladder's per-edge bests are left
  #     out of it, which only makes it prune less). So a choice after which
  #     the remaining S1 players have no matching on such edges into the
  #     remaining S2 players has no leaf below it. A maximum matching of
  #     the rest is kept from choice to choice: taking `(x, y)` removes `x`
  #     and frees its partner, and if `y` was someone else's partner, that
  #     one player needs a new one - an augmenting path from them exists
  #     exactly when the rest still has a matching covering S1 (Berge: a
  #     matching exposing one left vertex is maximum unless a path from that
  #     vertex augments it).
  #   * Failed states. Below a choice, what the walk can still do depends on
  #     the S1 position it has reached, which S2 players are used, and the
  #     clash and C13 counts so far (the colour counts, the floater's
  #     candidates and every feasibility test are functions of those), not
  #     on the order they were reached in. A state whose subtree ended
  #     `:fail` once ends `:fail` again, and is not walked twice.
  #
  # Neither discards a leaf, so the pruned walk meets its leaves - the one
  # it accepts, and any that would end it on the `:bound` safety check - in
  # the plain walk's order, and returns what the plain walk would have with
  # no budget at all. Its own budget (`@direct_pruned_budget_per_member`)
  # counts checks as the plain walk does, plus the players each failed
  # augmenting search looked at.

  defp direct_s1_memo(env, %{hall: nil} = st, s1, k, s2), do: direct_s1(env, st, s1, k, s2)

  defp direct_s1_memo(env, st, s1, k, s2) do
    key = {k, st.hall.u2, st.c, st.v}

    if MapSet.member?(Process.get(@direct_memo_key), key) do
      :fail
    else
      case direct_s1(env, st, s1, k, s2) do
        :fail ->
          Process.put(@direct_memo_key, MapSet.put(Process.get(@direct_memo_key), key))
          :fail

        found ->
          found
      end
    end
  end

  # The pruned walk's state for one remainder: every S1 player's legal,
  # colour-compatible S2 partners (as indices into S2), a maximum
  # matching of S1 into S2 over them (`m1` S1 index to S2 index, `m2` back),
  # and the S2 players used so far (`u2`, a bit per index). `:none` when S1
  # has no such matching at all.
  defp hall_setup(env, st, s1, s2) do
    Process.put(@direct_memo_key, MapSet.new())
    indexed = Enum.with_index(s2)

    adj =
      for k <- 0..(tuple_size(s1) - 1)//1 do
        x = elem(s1, k)
        for {y, j} <- indexed, direct_pairable?(env, x, y), do: j
      end

    h = %{adj: List.to_tuple(adj), bit: Map.new(indexed), m1: %{}, m2: %{}, u2: 0}

    h =
      Enum.reduce_while(0..(tuple_size(s1) - 1)//1, h, fn k, h ->
        case hall_path(h, k, MapSet.new()) do
          {:ok, h} -> {:cont, h}
          {:no, _} -> {:halt, :none}
        end
      end)

    %{st | hall: h}
  end

  # `direct_try/4`'s first test, which no pair it accepts fails.
  defp direct_pairable?(env, x, y) do
    a = elem(env.arr, x)
    b = elem(env.arr, y)
    legal_pair?(a, b) and colour_compatible?(a, b)
  end

  # A choice `(S1 index k, S2 player y)` the counts allowed, held to Hall's
  # condition for the rest (see "The pruned walk").
  defp hall_step(:no, _k, _y), do: :no
  defp hall_step({:ok, %{hall: nil}} = ok, _k, _y), do: ok

  defp hall_step({:ok, %{hall: h} = st}, k, y) do
    j = Map.fetch!(h.bit, y)
    j0 = Map.fetch!(h.m1, k)
    m1 = Map.delete(h.m1, k)
    m2 = Map.delete(h.m2, j0)
    h = %{h | u2: Bitwise.bor(h.u2, Bitwise.bsl(1, j))}

    case Map.get(m2, j) do
      nil ->
        {:ok, %{st | hall: %{h | m1: m1, m2: m2}}}

      k2 ->
        h = %{h | m1: Map.delete(m1, k2), m2: Map.delete(m2, j)}

        case hall_path(h, k2, MapSet.new()) do
          {:ok, h} ->
            {:ok, %{st | hall: h}}

          {:no, seen} ->
            left = Process.get(@direct_budget_key) - MapSet.size(seen)
            if left < 0, do: throw({:direct_abort, :budget})
            Process.put(@direct_budget_key, left)
            :no
        end
    end
  end

  # Kuhn's augmenting search from S1 index `k` over the unused S2 players:
  # `{:ok, h}` with `k` matched, or `{:no, seen}`.
  defp hall_path(h, k, seen) do
    Enum.reduce_while(elem(h.adj, k), {:no, seen}, fn j, {:no, seen} = acc ->
      if Bitwise.band(h.u2, Bitwise.bsl(1, j)) != 0 or MapSet.member?(seen, j) do
        {:cont, acc}
      else
        seen = MapSet.put(seen, j)

        case Map.get(h.m2, j) do
          nil ->
            {:halt, {:ok, %{h | m1: Map.put(h.m1, k, j), m2: Map.put(h.m2, j, k)}}}

          k2 ->
            case hall_path(h, k2, seen) do
              {:ok, h} -> {:halt, {:ok, %{h | m1: Map.put(h.m1, k, j), m2: Map.put(h.m2, j, k)}}}
              {:no, seen} -> {:cont, {:no, seen}}
            end
        end
      end
    end)
  end

  defp direct_floater_ok?(st, [f]), do: MapSet.member?(st.cand, f)
  defp direct_floater_ok?(_st, _leftover), do: false

  # Pair `x` (the better placed) with `y`, if the edge meets its per-edge
  # best and the counts can still meet the bounds.
  defp direct_try(env, st, x, y) do
    case Process.get(@direct_budget_key) do
      left when left > 0 -> Process.put(@direct_budget_key, left - 1)
      _ -> throw({:direct_abort, :budget})
    end

    a = elem(env.arr, x)
    b = elem(env.arr, y)

    with true <- legal_pair?(a, b) and colour_compatible?(a, b),
         {:ok, clash, breach} <- direct_edge_memo(env, a, b, x, y) do
      tx = elem(elem(env.facts, x), 0)
      ty = elem(elem(env.facts, y), 0)
      counts = st.counts |> count_add(tx, -1) |> count_add(ty, -1)

      fl =
        Enum.reduce([{x, tx}, {y, ty}], st.fl, fn {i, t}, acc ->
          if MapSet.member?(st.cand, i), do: count_add(acc, t, -1), else: acc
        end)

      c = st.c + clash
      v = st.v + breach

      if direct_feasible?(env, counts, fl, c, v) do
        {:ok,
         %{
           st
           | used: st.used |> MapSet.put(x) |> MapSet.put(y),
             counts: counts,
             fl: fl,
             c: c,
             v: v,
             pairs: [{x, y} | st.pairs]
         }}
      else
        :no
      end
    else
      _ -> :no
    end
  end

  # `direct_edge/5` once per pair and walk: a walk that backs up asks the
  # same pairs again, and the answer is the pair's alone.
  defp direct_edge_memo(env, a, b, x, y) do
    memo = Process.get(@direct_edge_key, %{})

    case memo do
      %{{^x, ^y} => answer} ->
        answer

      _ ->
        answer = direct_edge(env, a, b, x, y)
        Process.put(@direct_edge_key, Map.put(memo, {x, y}, answer))
        answer
    end
  end

  # The pair's rungs, from the ladder itself. `{:ok, clash, C13 breach}` when
  # every rung the section comment bounds per edge is at its best.
  defp direct_edge(env, a, b, x, y) do
    case ladder_rungs(a, b, 0, env.ctx, env.ctx.bands, env.single_bye?) do
      [
        {_, completion, _},
        _c6,
        _c7,
        _c8_pairs,
        _c8_scores,
        {"C9 bye unplayed games", c9, _},
        {"C10 topscorer colour diff", c10, _},
        {"C11 topscorer same colour x3", c11, _},
        {"C12 colour preference", c12, _},
        {"C13 strong colour preference", c13, _},
        _c14,
        {"C15 upfloat repeat r-1", c15, _},
        _c16,
        {"C17 upfloat repeat r-2", c17, _}
        | _
      ] ->
        # The counting bounds read clashes off the members' types; the
        # ladder must agree with them on every pair it is asked about.
        {pref_x, sx} = elem(elem(env.facts, x), 0)
        {pref_y, sy} = elem(elem(env.facts, y), 0)
        typed_clash = pref_x != nil and pref_x == pref_y

        typed_breach =
          typed_clash and
            not (sx == :mild or sy == :mild or (sx == :absolute and sy == :absolute))

        cond do
          bit(typed_clash) != 1 - c12 or bit(typed_breach) != 1 - c13 ->
            throw({:direct_abort, :types})

          (env.last? or ((completion == env.completion or not env.odd?) and c9 == 0)) and
            c10 == 1 and c11 == 1 and c15 == 1 and c17 == 1 ->
            {:ok, 1 - c12, 1 - c13}

          true ->
            :no
        end
    end
  end

  # Whether the members still to pair (`counts`, the floater among them on
  # an odd bracket, of a type `fl` still offers) can bring the clashes to
  # exactly `k12` and the C13 breaches to `k13`.
  defp direct_feasible?(env, counts, fl, c, v) do
    budget = env.k12 - c

    fits? = fn counts ->
      {k, l} = colour_lb(counts, env.absolute_pairs?)
      k <= budget and v + if(k == budget, do: l, else: 0) <= env.k13
    end

    cond do
      budget < 0 or v > env.k13 -> false
      env.odd? -> Enum.any?(fl, fn {t, n} -> n > 0 and fits?.(count_add(counts, t, -1)) end)
      true -> fits?.(counts)
    end
  end

  # What `collect_bracket/1` returns after the stages, from the walk's pairs:
  # the pairs in order of their better-placed member, everyone else carried
  # in order, and the tentative partners' scores it reports (on the local
  # graph an odd bracket's floater sits on the stand-in, at index `nsgb`,
  # and the next group's first player reads the floater back).
  defp direct_result(env, st, m, wsgb) do
    arr = env.arr

    partner =
      Enum.reduce(st.pairs, %{}, fn {x, y}, acc -> acc |> Map.put(x, y) |> Map.put(y, x) end)

    pairs =
      for i <- 0..(env.nsgb - 1)//1,
          p = Map.get(partner, i),
          p != nil and i < p,
          do: assign_colour_with_history({elem(arr, i), elem(arr, p)})

    carried = for i <- 0..(m - 1)//1, not is_map_key(partner, i), do: elem(arr, i)
    floater = Enum.find(0..(env.nsgb - 1)//1, &(not is_map_key(partner, &1)))

    scores =
      for i <- 0..(min(wsgb, m) - 1)//1, not is_map_key(partner, i) do
        cond do
          # The last bracket's floater is unmatched, and reads as its own.
          i == floater and env.nsgb < m -> elem(arr, env.nsgb).points
          floater != nil and i == env.nsgb -> elem(arr, floater).points
          true -> elem(arr, i).points
        end
      end

    {pairs, carried, if(floater == nil, do: 0, else: 1), scores}
  end

  ## ---------- the small bracket ----------
  #
  # A bracket small enough to list every maximum-weight matching of its graph
  # is answered by running the stages' decisions over that list, rather than
  # over a matcher. Each stage either asks whether SOME optimum makes a
  # choice (a nudge, a probe, an addend per opponent) and then commits it by
  # cutting what no longer fits, or reads what every optimum agrees on; so
  # each one is a filter over the set of optima, applied in the stages'
  # order:
  #
  #   * stage 1: each MDP in turn stays inside if some optimum has it inside;
  #   * stage 2: each committed MDP takes the best-ranked partner an optimum
  #     gives it (`prefer_high_opponents/2`'s addends);
  #   * stages 3-4: the remainder and its split are read, then the optima of
  #     the exchange weights kept (fewest exchanges, then the smallest sum of
  #     the paired-down positions - `exchange_weight/4`);
  #   * stage 5: from the bottom of S1 up, while exchanges are left, a player
  #     is exchanged if some optimum does not pair them down;
  #   * stage 6: from the top of S2 down, while more than one is left, a
  #     player is exchanged if some optimum pairs them down;
  #   * stage 7 changes nothing once every player's direction is settled;
  #   * stage 8: each paired-down player in turn takes the best-ranked
  #     partner an optimum gives them.
  #
  # Every value a stage READS off the matching (the remainder's split, the
  # exchange count, each player's direction before stage 8, the final
  # pairs) is checked to be the same across the optima left at that point -
  # the reads are the weights' own, not a matcher's - and a read that is not
  # stops this and leaves the bracket to the stages. The weights are the
  # stages' own: the local graph's (`base_edge_weights/8` and
  # `stand_in_edges/8`, as `new_bracket/9` builds them), or on the field
  # graph those of `attempt_direct_field/7`'s argument. `@direct_small_max`
  # is where the list stops being cheap.

  defp direct_small(arr, weights, wl, m, sgb, nsgb, wsgb, ctx, pool, listing, stuck?) do
    adj =
      List.to_tuple(
        for i <- 0..(wl - 1)//1 do
          for j <- (i + 1)..(wl - 1)//1, w = get_w(weights, i, j), w != 0, do: {j, w}
        end
      )

    full = Bitwise.bsl(1, wl) - 1

    optima =
      case listing do
        :all -> enumerate_optima(full, adj, [], 0, {nil, []})
        :bounded -> enumerate_bounded(full, adj, heaviest_edges(weights, wl), [], 0, {nil, []})
      end

    case optima do
      {nil, _} ->
        throw({:direct_abort, :no_perfect})

      {_best, optima} ->
        optima = Enum.map(optima, &partner_tuple(&1, wl))
        chosen = small_stages(optima, arr, sgb, nsgb, ctx)
        partner = for i <- 0..(nsgb - 1)//1, p = elem(chosen, i), p < nsgb, into: %{}, do: {i, p}
        floater = Enum.find(0..(nsgb - 1)//1, &(not is_map_key(partner, &1)))

        stuck_mdp? =
          stuck? and floater != nil and floater < sgb and stuck_member?(adj, floater, nsgb)

        if floater != nil and
             (elem(chosen, floater) != nsgb or
                (pool != nil and floater not in pool and not stuck_mdp?)),
           do: throw({:direct_abort, :floater})

        if stuck_mdp?, do: cert_count(:direct_small_stuck_mdp)

        if map_size(partner) + if(floater, do: 1, else: 0) != nsgb,
          do: throw({:direct_abort, :shape})

        pairs = Enum.flat_map(partner, fn {i, p} -> if i < p, do: [{i, p}], else: [] end)
        cert_count(:direct_small_ok)
        direct_result(%{arr: arr, nsgb: nsgb}, %{pairs: pairs}, m, wsgb)
    end
  end

  # The small bracket where the walk gave up on a bracket of 13-16 vertices -
  # one that needs an exchange, most often. The list is the same list, so its
  # answer is the stages' on the same argument as above (`direct_small/11`),
  # and a read it cannot settle ends it as before; only the listing is
  # bounded (`enumerate_bounded/6`), which leaves out partial matchings that
  # cannot reach the heaviest weight and so cannot change the list of optima,
  # and it stops after `@small_fallback_nodes` steps (then the stages run, as
  # they would have). A 13-player bracket over one MDP at the top of a
  # 401-player round 9 went to the field graph for 1.1 s. The walk's own
  # reason is counted as before, and a list that settles nothing as
  # `:small_fallback`.
  defp direct_small_after_walk(reason, arr, wl, m, sgb, nsgb, wsgb, ctx, single_bye?, {
         pool,
         last?,
         stuck?
       }) do
    if small_fallback?() do
      cert_count({:direct_abort, reason})
      weights = small_weights(arr, m, sgb, nsgb, wsgb, ctx, single_bye?, pool, last?)

      Process.put(@small_nodes_key, @small_fallback_nodes)

      result =
        try do
          direct_small(arr, weights, wl, m, sgb, nsgb, wsgb, ctx, pool, :bounded, stuck?)
        catch
          :throw, {:direct_abort, _} -> throw({:direct_abort, :small_fallback})
        after
          Process.delete(@small_nodes_key)
        end

      cert_count(:direct_small_fallback)
      {:ok, result}
    else
      throw({:direct_abort, reason})
    end
  end

  defp small_fallback?, do: env_flag(@env_direct_key, "AINALRAMI_DIRECT") != "off"

  # An MDP with no edge to another member of the bracket (it has met them
  # all, or cannot take a colour any of them can give). Every perfect
  # matching of the small graph then puts it on the stand-in - its one edge,
  # whose weight is therefore the same over the whole list - and the rest of
  # the bracket perfectly matched. On the field graph the same holds of
  # every optimum once the rest of the field, the MDP in it, completes (the
  # oracle's question after the walk, as for any floater): the completion
  # rung is then at its bound with the rest of the bracket paired inside,
  # and C6 asks for exactly that, since the MDP can be paired inside by no
  # matching at all. What the field below does with it is the same for every
  # candidate, so the bracket's answer is the list's, the MDP carried. At
  # round 9 of a 600-player open a leader who had met both players of the
  # group below took the round's first bracket to the field graph for 2 s.
  defp stuck_member?(adj, v, nsgb) do
    not Enum.any?(0..(nsgb - 1)//1, fn i ->
      cond do
        i == v -> false
        i < v -> Enum.any?(elem(adj, i), &(elem(&1, 0) == v))
        true -> Enum.any?(elem(adj, v), &(elem(&1, 0) == i))
      end
    end)
  end

  # Every perfect matching of the graph on the vertices in `mask`, keeping
  # the heaviest: `{weight, [pairs]}`.
  defp enumerate_optima(0, _adj, pairs, w, {best, list}) do
    cond do
      best == nil or w > best -> {w, [pairs]}
      w == best -> {best, [pairs | list]}
      true -> {best, list}
    end
  end

  defp enumerate_optima(mask, adj, pairs, w, acc) do
    u = lowest_bit(mask, 0)
    rest = Bitwise.bxor(mask, Bitwise.bsl(1, u))

    Enum.reduce(elem(adj, u), acc, fn {v, wv}, acc ->
      bit_v = Bitwise.bsl(1, v)

      if Bitwise.band(rest, bit_v) != 0,
        do: enumerate_optima(Bitwise.bxor(rest, bit_v), adj, [{u, v} | pairs], w + wv, acc),
        else: acc
    end)
  end

  # `enumerate_optima/5` less the partial matchings that cannot reach the
  # heaviest weight found so far: a perfect matching of the vertices left
  # weighs at most half the sum of their heaviest edges (`top`, doubled
  # below to stay in integers), and a branch whose bound falls short of the
  # best cannot hold an optimum. Ties are kept, so the optima listed are
  # exactly `enumerate_optima/5`'s.
  defp enumerate_bounded(0, _adj, _top, pairs, w, acc),
    do: enumerate_optima(0, nil, pairs, w, acc)

  defp enumerate_bounded(mask, adj, top, pairs, w, {best, _} = acc) do
    case Process.get(@small_nodes_key) do
      left when left > 0 -> Process.put(@small_nodes_key, left - 1)
      _ -> throw({:direct_abort, :small_nodes})
    end

    if best != nil and 2 * w + mask_top(mask, top, 0, 0) < 2 * best do
      acc
    else
      u = lowest_bit(mask, 0)
      rest = Bitwise.bxor(mask, Bitwise.bsl(1, u))

      Enum.reduce(elem(adj, u), acc, fn {v, wv}, acc ->
        bit_v = Bitwise.bsl(1, v)

        if Bitwise.band(rest, bit_v) != 0,
          do:
            enumerate_bounded(Bitwise.bxor(rest, bit_v), adj, top, [{u, v} | pairs], w + wv, acc),
          else: acc
      end)
    end
  end

  defp mask_top(0, _top, _i, sum), do: sum

  defp mask_top(mask, top, i, sum) do
    sum = if Bitwise.band(mask, 1) == 1, do: sum + elem(top, i), else: sum
    mask_top(Bitwise.bsr(mask, 1), top, i + 1, sum)
  end

  # Each vertex's heaviest edge weight (0 with none).
  defp heaviest_edges(weights, wl) do
    Enum.reduce(weights, :erlang.make_tuple(wl, 0), fn {{i, j}, w}, top ->
      if i < wl and j < wl and w != 0 do
        top
        |> put_elem(i, max(elem(top, i), w))
        |> put_elem(j, max(elem(top, j), w))
      else
        top
      end
    end)
  end

  defp lowest_bit(mask, i) do
    if Bitwise.band(mask, 1) == 1, do: i, else: lowest_bit(Bitwise.bsr(mask, 1), i + 1)
  end

  defp partner_tuple(pairs, wl) do
    Enum.reduce(pairs, :erlang.make_tuple(wl, nil), fn {u, v}, t ->
      t |> put_elem(u, v) |> put_elem(v, u)
    end)
  end

  defp small_stages(optima, arr, sgb, nsgb, ctx) do
    internal? = fn p -> p >= sgb and p < nsgb end
    down? = fn mt, i -> elem(mt, i) > i and elem(mt, i) < nsgb end

    # The one value every optimum agrees on, or the attempt ends.
    agreed = fn optima, read ->
      case optima |> Enum.map(read) |> Enum.uniq() do
        [value] -> value
        _ -> throw({:direct_abort, :tied_read})
      end
    end

    # Keep the optima with `pred`, if there are any.
    some = fn optima, pred ->
      case Enum.filter(optima, pred) do
        [] -> {false, optima}
        kept -> {true, kept}
      end
    end

    # Stages 1-2. Stage 1 reads, per score among the MDPs, how many are
    # inside (`count_mdp_group/2`).
    Enum.each(0..(sgb - 1)//1, fn mdp ->
      score = elem(arr, mdp).points
      group = Enum.filter(0..(sgb - 1)//1, &(elem(arr, &1).points == score))
      agreed.(optima, fn mt -> Enum.count(group, &internal?.(elem(mt, &1))) end)
    end)

    {optima, committed} =
      Enum.reduce(0..(sgb - 1)//1, {optima, []}, fn mdp, {optima, committed} ->
        case some.(optima, &internal?.(elem(&1, mdp))) do
          {true, kept} -> {kept, [mdp | committed]}
          {false, optima} -> {optima, committed}
        end
      end)

    optima =
      committed
      |> Enum.reverse()
      |> Enum.reduce(optima, fn mdp, optima ->
        best = optima |> Enum.map(&elem(&1, mdp)) |> Enum.min()
        Enum.filter(optima, &(elem(&1, mdp) == best))
      end)

    # Stage 3.
    taken = MapSet.new(committed, &elem(hd(optima), &1))
    remainder = Enum.reject(sgb..(nsgb - 1)//1, &MapSet.member?(taken, &1))
    index = remainder |> Enum.with_index() |> Map.new()
    rp = agreed.(optima, fn mt -> Enum.count(remainder, &(elem(mt, &1) < &1)) end)

    # Stage 4: fewest exchanges, then the smallest sum of paired-down
    # positions - `exchange_weight/4`'s addend, summed.
    s = ctx.bands.count_span

    score4 = fn mt ->
      Enum.reduce(remainder, 0, fn v, acc ->
        p = elem(mt, v)

        if is_map_key(index, p) and v < p do
          idx = Map.fetch!(index, v)
          acc + bit(idx < rp) * s * s - idx
        else
          acc
        end
      end)
    end

    top = optima |> Enum.map(score4) |> Enum.max(fn -> 0 end)
    optima = Enum.filter(optima, &(score4.(&1) == top))

    first = Enum.take(remainder, rp)
    exchanges = agreed.(optima, fn mt -> Enum.count(first, &(not down?.(mt, &1))) end)

    # Stage 5.
    {optima, _} =
      Enum.reduce_while(Enum.reverse(first), {optima, exchanges}, fn player, {optima, left} ->
        if left == 0 do
          {:halt, {optima, left}}
        else
          case some.(optima, &(not down?.(&1, player))) do
            {true, kept} -> {:cont, {kept, left - 1}}
            {false, optima} -> {:cont, {optima, left}}
          end
        end
      end)

    # Stage 6.
    {optima, _} =
      Enum.reduce_while(Enum.drop(remainder, rp), {optima, exchanges}, fn player,
                                                                          {optima, left} ->
        if left <= 1 do
          {:halt, {optima, left}}
        else
          case some.(optima, &down?.(&1, player)) do
            {true, kept} -> {:cont, {kept, left - 1}}
            {false, optima} -> {:cont, {optima, left}}
          end
        end
      end)

    # Stage 7 reads every player's direction.
    Enum.each(remainder, fn player -> agreed.(optima, &down?.(&1, player)) end)

    # Stage 8.
    optima =
      Enum.reduce(remainder, optima, fn player, optima ->
        if agreed.(optima, &down?.(&1, player)) do
          best = optima |> Enum.map(&elem(&1, player)) |> Enum.min()
          Enum.filter(optima, &(elem(&1, player) == best))
        else
          optima
        end
      end)

    agreed.(optima, fn mt -> Enum.map(0..(nsgb - 1)//1, &elem(mt, &1)) end)
    hd(optima)
  end

  # The graph `direct_small/11` lists the optima of: the local graph's, or on
  # the field graph (`attempt_direct_field/7`) the bracket with a stand-in
  # whose edge is the float every floater of the pool scores in full, and
  # any other member one C8 unit less - so an optimum that floats one of them
  # has won above C8, where no pool floater could, and is refused.
  defp small_weights(arr, m, sgb, nsgb, wsgb, ctx, single_bye?, pool, last?) do
    bands = ctx.bands
    base = base_edge_weights(arr, m, sgb, nsgb, nsgb, ctx, bands, single_bye?)

    cond do
      # The last bracket: the one left over stands on the stand-in, whose
      # edge is the same for everyone - leaving L over is already priced by
      # the rungs of the pairs it is not in (`attempt_direct_last/7`).
      last? ->
        Enum.reduce(0..(nsgb - 1)//1, base, fn i, acc -> Map.put(acc, {i, nsgb}, 1) end)

      pool == nil ->
        stand_in_edges(base, arr, sgb, nsgb, wsgb, ctx, bands, single_bye?)

      true ->
        local = stand_in_edges(base, arr, sgb, nsgb, wsgb, ctx, bands, single_bye?)

        # Every floater of the pool scores the same outside the bracket, and
        # every perfect matching here has one stand-in edge, so any common
        # value is exact; the stand-in's edge for a member is its float
        # against the first partner it has in the next group, whose
        # completion term (over the bye group) need not be the same for all.
        ideal = pool |> Enum.map(&Map.fetch!(local, {&1, nsgb})) |> Enum.max()

        short = ideal - elem(ctx.outside.suffix, ctx.outside.c8_pairs) * bands.reserve

        Enum.reduce(0..(nsgb - 1)//1, base, fn i, acc ->
          Map.put(acc, {i, nsgb}, if(i in pool, do: ideal, else: short))
        end)
    end
  end

  ## ---------- the graph ----------

  defp put_w(weights, i, j, w) when i < j, do: Map.put(weights, {i, j}, w)
  defp put_w(weights, i, j, w), do: Map.put(weights, {j, i}, w)

  defp get_w(weights, i, j) when i < j, do: Map.get(weights, {i, j}, 0)
  defp get_w(weights, i, j), do: Map.get(weights, {j, i}, 0)

  # `put_w/4` for the LIVE weights: the same write, plus a note of which
  # vertex was modified. `i` is the modified vertex and `j` its neighbour,
  # in that order, at every call site -- the same order `dutch.cpp` passes
  # them to `setEdgeWeight(modifiedVertex, neighbor)`, and for the same
  # reason: the matcher re-prepares exactly the modified end of each
  # changed edge, and the cost of the next solve is proportional to how
  # many DISTINCT vertices were modified (computer.cpp:69-71: "after calls
  # to setEdgeWeight using at most k different values for modifiedVertex,
  # the subsequent computeMatching() operation will take O(k n^2) time").
  # A whole-map diff of `live` cannot recover that vertex, and preparing
  # the lower-indexed end instead made `finalize_pair/3` prepare every
  # earlier vertex the pair still had an edge to: ~10.7 stages per
  # in-bracket solve where the reference's contract needs two or three.
  defp set_live(live, i, j, w) do
    Process.put(@dirty_key, [{i, j} | Process.get(@dirty_key, [])])
    put_w(live, i, j, w)
  end

  defp solve(%{mode: :local} = st), do: solve_local(st)
  defp solve(st), do: solve_field(st)

  ## ---------- certified shortcuts ----------
  #
  # The refinement stages ask the round matcher the same question again and
  # again after small weight changes, and each answer is a search whose
  # result the stages then READ: whether a player is paired down, paired
  # inside the bracket, with whom, against what score. Where the answer can
  # be PROVED instead of searched for, the search can be skipped - but the
  # matcher breaks ties by the order of its search, and the next search
  # starts from the state the last one left, so a shortcut that leaves a
  # different optimum (or merely different duals) behind could change which
  # optimum a later search lands on. The engine would then be answering a
  # different question than v0.33.0 answered.
  #
  # So a shortcut is allowed to change the matcher's state only under a
  # contract that makes the state irrelevant. From the first shortcut of a
  # round on (the state is "tainted"), every value the stages read from a
  # matching is CERTIFIED to be the same in every maximum-weight matching of
  # the weights it was read at (`certified/3`), using an optimal dual
  # solution of those weights: complementary slackness pins every optimum's
  # partners of a vertex to its zero-reduced-cost edges (and lets it go
  # unmatched only when its dual is at the floor), so a property all of
  # those candidates share is a property of every optimum - of the one the
  # reference search would have returned in particular. By induction over
  # the reads, the reference and this engine read the same values, write the
  # same weights and finalise the same pairs; the states they hold may
  # differ and nothing observes it. A read that cannot be certified throws,
  # and `certified_cascade/2` pairs the round again from the start with the
  # shortcuts off, which is the reference computation step for step.
  #
  # Which weights a read is "at": `matching` is refreshed by a solve, and a
  # stage-8 dual shift keeps the matching it had, which is optimal for the
  # shifted weights whichever way the reference went (its own shift keeping
  # it, or its search finding an optimum of the same weights). `snap` is the
  # matcher at that moment and nothing else: a stage-7 shift changes the
  # matcher but not `matching`, and the reads that follow it are still
  # about the weights of the last solve, which is what the reference's
  # `matching` is an optimum of.

  # A read of `class.(partner)`, certified when the round matcher's state is
  # not the reference's. `tag` names the question (with `st`'s bracket
  # bounds and `i` it determines `class`), so a certified answer is
  # remembered per snapshot and asked again for free.
  defp certified(st, i, tag, class) do
    if st.mode == :field and Process.get(@taint_key) == true do
      {_matcher, ref} = st.snap || throw({:cert_abort, :no_snapshot})
      key = {ref, i, tag}

      case Process.get(@cert_memo_key, %{}) do
        %{^key => value} ->
          value

        _ ->
          value = class.(partner(st, i))
          cert_timed(:ms_reads, fn -> certify_read(st, i, tag, class, value) end)
          Process.put(@cert_memo_key, Map.put(Process.get(@cert_memo_key, %{}), key, value))
          value
      end
    else
      class.(partner(st, i))
    end
  end

  # A count over `vertices` of `class.(partner) == true`, certified as a
  # COUNT: the stages read how many (C6's pairs in the remainder, the
  # exchanges stage 4 left, an MDP group's internal members), which the
  # ladder fixes even where each member's own answer is tied.
  #
  # Each answer certified on its own is enough; when some are not, the
  # count is certified directly. Over any matching `M'` it is a constant
  # plus `c(M')`, a sum over `M'`'s edges of `c(u, v) = [u counted] *
  # (class_u(v) - class_u(u)) + [v counted] * (class_v(u) - class_v(v))`
  # (an unmatched vertex answers for itself). Two ways to show that every
  # optimum has the held matching's `c`: over the optimal face of the
  # snapshot's duals (`count_on_face?/5`), or by asking the matcher for an
  # optimum of `K * w + c` and of `K * w - c` (`count_by_search?/4`).
  defp certified_count(st, vertices, tag, class) do
    count = Enum.count(vertices, &class.(&1, partner(st, &1)))

    if st.mode == :field and Process.get(@taint_key) == true do
      {matcher, ref} = st.snap || throw({:cert_abort, :no_snapshot})
      key = {ref, :count, tag, vertices}

      case Process.get(@cert_memo_key, %{}) do
        %{^key => ^count} ->
          count

        _ ->
          cheap? =
            Enum.all?(vertices, fn v ->
              value = class.(v, partner(st, v))

              try do
                certify_read_cheap(st, v, &class.(v, &1), value)
              catch
                :throw, {:cert_abort, _} -> false
              end
            end)

          ok? =
            cheap? or
              cert_timed(:ms_count, fn -> count_on_face?(st, matcher, ref, vertices, class) end) or
              cert_timed(:ms_count_search, fn ->
                count_by_search?(st, matcher, vertices, class)
              end)

          cert_count({:count, cheap?, ok?})
          unless ok?, do: throw({:cert_abort, :count})
          Process.put(@cert_memo_key, Map.put(Process.get(@cert_memo_key, %{}), key, count))
          count
      end
    else
      count
    end
  end

  # `certify_read/4` without the walk and the forced search: true when every
  # candidate partner answers alike.
  defp certify_read_cheap(st, i, class, value) do
    {matcher, ref} = st.snap
    cands = read_candidates(st, matcher, ref, i)
    partner(st, i) in cands and Enum.all?(cands, &(class.(&1) == value))
  end

  # The count over the optimal face. Every optimum uses tight edges only and
  # covers every vertex whose dual is above the floor; on a window alone
  # that is every window vertex (their duals are held above the dummies'
  # offers), so every optimum's window part is a PERFECT matching of the
  # window's tight graph. The count is `const + c(M')` over such a matching
  # (see `certified_count/4`), so if the heaviest and the lightest perfect
  # matching of the tight graph under `c` both weigh what the held matching
  # does, no optimum can count differently. Both are small-integer
  # matchings on a sparse graph: weights `B * 2 + 3 + c(e)` with `B` above
  # any sum of the small parts, so that the optimum is perfect first and
  # extreme in `c` second, and the constant 3 keeps every weight positive
  # and is the same on every perfect matching. Any shortfall - the solve
  # not perfect, or not at the held matching's value - is inconclusive.
  #
  # The cardinality has to be pinned for the constant to cancel, and it is
  # where every optimum covers all but at most one vertex: on a window
  # (every window vertex's dual is held above the dummies' offers), when
  # at most one vertex with edges sits at the dual floor, or when the one
  # unmatched vertex's top blossom has a positive dual and holds every
  # vertex with edges (every optimum is then near-perfect in it). Otherwise
  # inconclusive.
  defp count_on_face?(st, matcher, ref, vertices, class) do
    ctx = read_ctx(st, matcher, ref)
    to_local = st.from_field

    live =
      for {v, row} <- matcher.weight,
          map_size(row) > 0,
          not dummy?(st, v),
          lv = Map.get(to_local, v),
          lv != nil,
          do: {v, lv}

    if face_pinned?(st, matcher, ctx, live) do
      counted = MapSet.new(vertices)

      c = fn u, v ->
        side = fn a, b ->
          if MapSet.member?(counted, a), do: bit(class.(a, b)) - bit(class.(a, a)), else: 0
        end

        side.(u, v) + side.(v, u)
      end

      index = live |> Enum.with_index() |> Map.new(fn {{_f, lv}, k} -> {lv, k} end)

      edges =
        Enum.flat_map(live, fn {f, i} ->
          {tight, _} = tight_row(matcher, ctx, ref, f)

          Enum.flat_map(tight, fn g ->
            case Map.get(to_local, g) do
              j when is_integer(j) and j > i and is_map_key(index, j) -> [{i, j}]
              _ -> []
            end
          end)
        end)

      n = length(live)
      big = 8 * n + 16

      held =
        Enum.reduce(live, 0, fn {_f, i}, acc ->
          p = partner(st, i)
          if p > i and is_map_key(index, p), do: acc + c.(i, p), else: acc
        end)

      held_size =
        Enum.count(live, fn {_f, i} ->
          is_map_key(index, partner(st, i)) and partner(st, i) != i
        end)

      live_t = List.to_tuple(live)

      Enum.all?([1, -1], fn sign ->
        list =
          for {i, j} <- edges,
              do: {Map.fetch!(index, i), Map.fetch!(index, j), 2 * big + 3 + sign * c.(i, j)}

        best = WeightedMatching.solve(n, list)

        map_size(best) == held_size and
          Enum.reduce(best, 0, fn {a, b}, acc ->
            if a < b do
              {_, i} = elem(live_t, a)
              {_, j} = elem(live_t, b)
              acc + sign * c.(i, j)
            else
              acc
            end
          end) == sign * held
      end)
    else
      false
    end
  end

  # Whether every optimum of the snapshot's weights matches the same number
  # of vertices as the held matching - see `count_on_face?/5`.
  defp face_pinned?(%{window: w}, _matcher, _ctx, _live) when w != nil, do: true

  defp face_pinned?(_st, matcher, ctx, live) do
    at_floor = Enum.count(live, fn {f, _} -> Map.fetch!(matcher.dual, f) == ctx.xi end)
    exposed = Enum.reject(live, fn {f, _} -> is_map_key(matcher.mate, f) end)

    at_floor <= 1 or
      case exposed do
        [{x, _}] ->
          top = Map.fetch!(matcher.in_blossom, x)

          Map.has_key?(matcher.children, top) and Map.get(matcher.dual, top, 0) > 0 and
            Enum.all?(live, fn {f, _} -> Map.fetch!(matcher.in_blossom, f) == top end)

        _ ->
          false
      end
  end

  defp read_ctx(st, matcher, ref) do
    _ = read_candidates(st, matcher, ref, 0)
    Map.fetch!(Process.get(@cert_memo_key), {ref, :ctx})
  end

  # The count by search. `K * w + c` scaled into the snapshot's state (a
  # valid state for `K * w`, see `WeightedMatching.scale/2`), `c` written
  # onto the counted vertices' edges only - the only edges where it is not
  # zero - and the search resumed: its optimum is an optimum of `w` with the
  # largest `c` there is among them, since `K` exceeds anything `c` adds up
  # to on a matching. The same with `-c` gives the smallest. Both equal to
  # the held matching's `c`: every optimum counts alike. Costs a search
  # that re-examines the counted vertices, so it is the last resort.
  #
  # On a window alone the search runs on the window's matcher, and the
  # window part of every optimum of the whole graph is an optimum of the
  # window (see `forced_loses?/5`), so the answer carries over.
  defp count_by_search?(st, matcher, vertices, class) do
    counted = MapSet.new(vertices, &elem(st.field_pos, &1))
    to_local = st.from_field
    k = 4 * map_size(matcher.weight) + 8

    answer = fn u, x ->
      # `class_u(x)`: bracket indices; a vertex outside the bracket's graph
      # (a dummy of a window) is never a partner in an optimum, see
      # `window_setup/1`, and contributes nothing.
      case {Map.get(to_local, u), Map.get(to_local, x)} do
        {lu, lx} when lu != nil and lx != nil -> bit(class.(lu, lx))
        _ -> nil
      end
    end

    c = fn u, v ->
      side = fn a, b ->
        if MapSet.member?(counted, a) do
          case {answer.(a, b), answer.(a, a)} do
            {nil, _} -> 0
            {x, y} -> x - y
          end
        else
          0
        end
      end

      side.(u, v) + side.(v, u)
    end

    held =
      Enum.reduce(matcher.mate, 0, fn {u, v}, acc -> if u < v, do: acc + c.(u, v), else: acc end)

    scaled = WeightedMatching.scale(matcher, k)

    Enum.all?([1, -1], fn sign ->
      # Weights read off `scaled`, not the state being written: an edge
      # between two counted vertices is written from both ends, to the
      # same value.
      perturbed =
        Enum.reduce(counted, scaled, fn v, acc ->
          scaled
          |> WeightedMatching.neighbours(v)
          |> Enum.reduce(acc, fn {u, w}, acc ->
            case c.(v, u) do
              0 -> acc
              g -> WeightedMatching.set_weight(acc, v, u, w + sign * g)
            end
          end)
        end)

      {_state, best} = WeightedMatching.solve(perturbed)
      found = Enum.reduce(best, 0, fn {u, v}, acc -> if u < v, do: acc + c.(u, v), else: acc end)
      found == held
    end)
  end

  defp read_candidates(st, matcher, ref, i) do
    memo = Process.get(@cert_memo_key, %{})
    ctx_key = {ref, :ctx}
    cands_key = {ref, i}

    {ctx, memo} =
      case memo do
        %{^ctx_key => ctx} ->
          {ctx, memo}

        _ ->
          ctx = WeightedMatching.dual_context(matcher)

          ctx =
            cond do
              ctx == :invalid ->
                cert_count({:invalid, :context})
                :invalid

              not window_valid?(st, matcher) ->
                cert_count({:invalid, :window})
                :invalid

              true ->
                ctx
            end

          {ctx, Map.put(memo, ctx_key, ctx)}
      end

    if ctx == :invalid, do: throw({:cert_abort, :dual})

    case memo do
      %{^cands_key => cands} ->
        Process.put(@cert_memo_key, memo)
        cands

      _ ->
        {tight, exposable?} =
          WeightedMatching.possible_partners(matcher, ctx, elem(st.field_pos, i))

        # A window's dummy is not a vertex of the graph: the combined dual
        # leaves every real crossing edge strictly slack whatever the
        # dummy's own edge does (see `window_setup/1`).
        cands =
          tight
          |> Enum.reject(&dummy?(st, &1))
          |> Enum.map(fn f -> Map.get(st.from_field, f) || throw({:cert_abort, :outside}) end)

        cands = if exposable?, do: [i | cands], else: cands
        Process.put(@cert_memo_key, Map.put(memo, cands_key, cands))
        cands
    end
  end

  # A read is certified when every candidate partner (`read_candidates/4`)
  # answers `class` alike. A candidate that answers differently is ruled out
  # by the cheap walk (`alternative_exists?/7`) or, failing that, by the
  # exact forced search (`forced_loses?/5`); a candidate neither rules out
  # is a genuine tie on the answer, and the attempt is abandoned.
  defp certify_read(st, i, tag, class, value) do
    {matcher, ref} = st.snap
    cands = read_candidates(st, matcher, ref, i)
    ctx = Map.fetch!(Process.get(@cert_memo_key), {ref, :ctx})
    cert_count(:read)

    p = partner(st, i)
    odd = Enum.reject(cands, &(class.(&1) == value))

    ok? =
      p in cands and
        (odd == [] or
           (cert_count(:read_walk) == :ok and
              Enum.all?(odd, fn c ->
                not alternative_exists?(st, matcher, ctx, ref, i, p, c) or
                  (cert_count(:read_forced) == :ok and
                     cert_timed(:ms_forced, fn -> forced_loses?(st, matcher, ref, i, c) end))
              end)))

    unless ok? do
      cert_count({:tied_read, tag})
      throw({:cert_abort, :read})
    end

    :ok
  end

  # Could some maximum-weight matching give `i` the candidate `c` (bracket
  # indices; `c == i` is "leave `i` unmatched") instead of its partner `p`?
  #
  # Such an optimum `M'` differs from the current one `M` on a disjoint
  # union of alternating paths and cycles, all of whose edges are tight
  # (complementary slackness: `M'` uses tight edges only), and the component
  # through `i` would carry the change. Walking it from `i`'s side: the edge
  # `(i, c)` enters `c`, `c`'s old `M` edge leaves it, a tight edge enters
  # the next vertex, and so on - a walk in the digraph "`s` -> `M(w)` for
  # every tight non-`M` edge `(s, w)`". A cycle closes back at `i`; a path
  # ends where a tight edge reaches a vertex `M` leaves unmatched, or where
  # a vertex whose dual sits at the floor (and so may go unmatched) stops.
  # Both sides of `i` must end properly for a path. The digraph allows walks
  # that revisit a vertex, which no alternating path does, so "no walk"
  # proves "no such optimum"; "a walk" proves nothing, and the candidate is
  # left to the forced search.
  defp alternative_exists?(st, matcher, ctx, ref, i, p, c) do
    v = elem(st.field_pos, i)
    mate = matcher.mate
    real? = fn u -> not dummy?(st, u) end
    ends? = fn s -> walk_reaches?(matcher, ctx, ref, s, :end, real?) end

    cond do
      c == i ->
        ends?.(elem(st.field_pos, p))

      p == i ->
        cf = elem(st.field_pos, c)
        not is_map_key(mate, cf) or ends?.(Map.fetch!(mate, cf))

      true ->
        cf = elem(st.field_pos, c)

        case Map.fetch(mate, cf) do
          :error ->
            ends?.(elem(st.field_pos, p))

          {:ok, mc} ->
            walk_reaches?(matcher, ctx, ref, mc, {:vertex, v}, real?) or
              (ends?.(mc) and ends?.(elem(st.field_pos, p)))
        end
    end
  end

  # The exact form of the same question, asked of the matcher itself: the
  # best matching that gives `i` the candidate `c` (or leaves `i` unmatched,
  # `c == i`) is a maximum-weight matching of the graph with every other
  # edge at `i` and `c` deleted, and the snapshot's state - a valid state for
  # these weights - is a valid starting point for that search once the
  # deletions have prepared `i` and `c`. If it weighs less than the matching
  # held, no optimum makes that choice. Only asked when the walk could not
  # rule the candidate out.
  #
  # On a window alone (`window_setup/1`) the question is asked of the
  # window's matcher, and the answer still holds for the whole graph. The
  # combined dual is optimal and leaves every crossing edge strictly slack,
  # so any optimum of the whole graph is a window matching plus a matching
  # of the field below, each at most as heavy as the one held (both are
  # optimal on their own part) and so exactly as heavy: its window part is
  # an optimal matching of the window. The dummies only add options, so a
  # forced search that loses with them would lose without them too.
  defp forced_loses?(st, matcher, ref, i, c) do
    key = {ref, :forced, i, c}

    case Process.get(@cert_memo_key, %{}) do
      %{^key => answer} ->
        answer

      _ ->
        v = elem(st.field_pos, i)
        cf = if c == i, do: nil, else: elem(st.field_pos, c)

        forced =
          [v | if(cf, do: [cf], else: [])]
          |> Enum.reduce(matcher, fn x, acc ->
            acc
            |> WeightedMatching.neighbours(x)
            |> Enum.reduce(acc, fn {u, _w}, acc ->
              if {x, u} in [{v, cf}, {cf, v}],
                do: acc,
                else: WeightedMatching.set_weight(acc, x, u, 0)
            end)
          end)

        {forced, best} = WeightedMatching.solve(forced)
        answer = matching_weight(forced, best) < matching_weight(matcher, matcher.mate)
        Process.put(@cert_memo_key, Map.put(Process.get(@cert_memo_key, %{}), key, answer))
        answer
    end
  end

  defp matching_weight(state, mate) do
    Enum.reduce(mate, 0, fn {u, v}, acc ->
      if u < v, do: acc + WeightedMatching.edge_weight(state, u, v), else: acc
    end)
  end

  # Breadth-first over the walk digraph from `start` (itself included):
  # does it reach `{:vertex, v}`, or (`:end`) a vertex that may go
  # unmatched or that has a tight edge to one `M` leaves unmatched? Edges
  # to vertices `real?` rejects (a window's dummies) are not edges of the
  # graph and are not walked.
  defp walk_reaches?(matcher, ctx, ref, start, goal, real?) do
    mate = matcher.mate
    do_walk(:queue.from_list([start]), MapSet.new([start]), matcher, ctx, ref, mate, goal, real?)
  end

  defp do_walk(queue, seen, matcher, ctx, ref, mate, goal, real?) do
    case :queue.out(queue) do
      {:empty, _} ->
        false

      {{:value, s}, queue} ->
        {tight, floor?} = tight_row(matcher, ctx, ref, s)
        tight = Enum.filter(tight, real?)
        own = Map.get(mate, s)

        cond do
          goal == {:vertex, s} ->
            true

          goal == :end and (floor? or Enum.any?(tight, &(&1 != own and not is_map_key(mate, &1)))) ->
            true

          true ->
            {queue, seen} =
              Enum.reduce(tight, {queue, seen}, fn w, {q, sn} = acc ->
                case Map.get(mate, w) do
                  nil ->
                    acc

                  next when w == own ->
                    _ = next
                    acc

                  next ->
                    if MapSet.member?(sn, next),
                      do: acc,
                      else: {:queue.in(next, q), MapSet.put(sn, next)}
                end
              end)

            do_walk(queue, seen, matcher, ctx, ref, mate, goal, real?)
        end
    end
  end

  defp tight_row(matcher, ctx, ref, s) do
    key = {ref, :row, s}

    case Process.get(@cert_memo_key, %{}) do
      %{^key => row} ->
        row

      memo ->
        row = WeightedMatching.possible_partners(matcher, ctx, s)
        Process.put(@cert_memo_key, Map.put(memo, key, row))
        row
    end
  end

  defp taint! do
    if Process.get(@taint_key) != true, do: cert_count(:tainted_round)
    Process.put(@taint_key, true)
  end

  # The minimum number of vertices a solve must re-examine before a
  # certificate is worth trying in its place: `set_weight/4` prepares one
  # vertex per distinct modified end, and a resumed solve costs about that
  # many row walks, against a certificate's one pass over the graph.
  @install_min_prepared 24

  # Skip a solve by proving that the matching the matcher held before the
  # writes is still optimal for the weights after them - optimal with a
  # certificate strong enough (`Ainalrami.MatchCertificate`) to install as
  # the matcher's new state, so the stages that follow can shift duals on
  # it rather than search. The certificate's window is the bracket and the
  # next group: strictness there is what lets the reads that follow be
  # certified.
  defp certified_install(nil, _prepared, _st, _dirty, _to_field), do: :no

  defp certified_install(before, prepared, st, dirty, to_field) do
    prepared_count = dirty |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()

    # Only where the bracket is everything left: with a field below, the
    # optimum needs odd-set duals for the bracket (C6 would otherwise gain
    # from a fractional matching of an odd bracket) that a vertex-dual
    # certificate cannot express, and the attempt only costs.
    if Process.get(@cert_key) == true and st.nsgb == st.m and st.window == nil and
         (prepared_count >= @install_min_prepared or (cert_force?() and prepared_count > 0)) do
      held = still_matched(before.mate, prepared)
      window = MapSet.new(0..(min(st.wsgb, st.m) - 1)//1, to_field)
      hint = WeightedMatching.vertex_duals(before)

      # The shaped guess first when there is one: it is offered exactly when
      # the held matching was found out of shape.
      guesses =
        case st.guess do
          nil -> [{:held, held}]
          {members, pairs} -> [{:shaped, reshape(held, members, pairs, to_field)}, {:held, held}]
        end

      # Strict on the window first: the duals then leave as few edges tight
      # as the ties allow, which is what makes the reads that follow
      # certifiable. Failing that, any optimal duals will do for the state -
      # each read is certified on its own.
      attempts =
        Enum.map(guesses, fn {label, guess} -> {label, guess, true} end) ++
          [{:held, held, false}]

      Enum.find_value(attempts, :no, fn {label, guess, strict} ->
        case Ainalrami.MatchCertificate.certify(
               prepared.weight,
               guess,
               &MapSet.member?(window, &1),
               hint,
               strict: strict
             ) do
          {:ok, cert} ->
            cert_count({:install_ok, label, strict})
            taint!()
            {:ok, {WeightedMatching.install(prepared, guess, cert.dual), guess}}

          {:error, _} ->
            cert_count({:install_fail, label, strict})
            nil
        end
      end)
    else
      :no
    end
  end

  ## ---------- the window alone ----------
  #
  # A field-graph bracket's stages read the matching only on its WINDOW -
  # the bracket and the next score group - but every search runs over the
  # whole remaining field. When the field below is large (round 2 of a big
  # open: a 273-player bracket over a 291-player field of zeros), most of
  # each search is spent there.
  #
  # In certified mode such a bracket can run on the window alone. The field
  # below is solved on its own, once - its weights do not change while this
  # bracket is paired - and certified optimal (`Ainalrami.MatchCertificate`,
  # optimality only) with duals `y'` and, if it leaves one player unmatched,
  # the level `xi` of the odd set of every vertex. What the field below
  # offers a window player `v` is then a single number,
  # `L(v) = max(xi, max_f (w(v, f) - y'(f))) + 1`, and a private dummy
  # vertex joined to `v` at weight `L(v)` puts exactly that offer into the
  # window's own matcher: while every dummy is unmatched with dual 0, every
  # window dual is at least `L(v)`, which makes the window's duals, the
  # field's `y'` and `xi` together a dual solution for the WHOLE graph -
  # feasible on every edge (window, field and crossing ones, the crossing
  # ones strictly) and complementary to the window's matching plus the
  # field's. Reads are certified against that combined solution, exactly as
  # on the whole graph (`window_valid?/2` is the condition). A search that
  # breaks it - the window's optimum matching a dummy, or pricing one - ends
  # the window there and then: the bracket goes on over the whole field
  # (`leave_window/4`), from a matcher with the reference's weights, before
  # anything is read off that search.
  #
  # At the bracket's end the round matcher is rebuilt (`graft_back/1`) with
  # the weights the reference's round matcher has - the window's as they now
  # stand, the far and crossing weights it held, minus every edge of a
  # player finalised here - so the next bracket continues from the same
  # weights, with a different but valid state.
  #
  # Worth it where both halves are large: a bracket whose searches are
  # expensive, over a field below that makes up much of each search. A
  # small bracket pays the setup (one search of the field below and its
  # certificate) for little.
  @window_min_bracket 60
  @window_min_below 60

  defp window_setup(st) do
    {r_matcher, field_index, field_size} = Process.get(@round_matcher_key)

    big? = st.nsgb >= @window_min_bracket and st.m - st.wsgb >= @window_min_below

    if Process.get(@cert_key) == true and st.m > st.wsgb and rem(st.wsgb, 2) == 0 and
         st.nsgb >= 2 and (big? or cert_force?()) do
      case cert_timed(:ms_window_setup, fn ->
             window_parts(st, r_matcher, field_index, field_size)
           end) do
        {:ok, window_matcher, window} ->
          cert_count(:window_mode)
          taint!()
          Process.put(@round_matcher_key, {window_matcher, field_index, field_size})
          %{st | window: window}

        :no ->
          cert_count(:window_declined)
          st
      end
    else
      st
    end
  end

  defp window_parts(st, r_matcher, field_index, field_size) do
    to_field = field_positions(st, field_index)
    weigh = edge_weigher(st, to_field, field_size)
    w_last = st.wsgb - 1
    in_window = MapSet.new(0..w_last//1, to_field)
    far_set = MapSet.new(st.wsgb..(st.m - 1)//1, to_field)

    # Far and crossing weights as the round matcher holds them (frozen
    # since the bracket that built it), or as this bracket would build it.
    {far_edges, cross_edges} =
      case r_matcher do
        nil ->
          Enum.reduce(st.live, {[], []}, fn {{i, j}, w}, {far, cross} ->
            cond do
              w <= 0 -> {far, cross}
              i >= st.wsgb -> {[{to_field.(i), to_field.(j), weigh.(i, j, w)} | far], cross}
              j >= st.wsgb -> {far, [{to_field.(i), to_field.(j), weigh.(i, j, w)} | cross]}
              true -> {far, cross}
            end
          end)

        matcher ->
          Enum.reduce(far_set, {[], []}, fn f, acc ->
            matcher
            |> WeightedMatching.neighbours(f)
            |> Enum.reduce(acc, fn {u, w}, {far, cross} ->
              cond do
                MapSet.member?(far_set, u) and f < u -> {[{f, u, w} | far], cross}
                MapSet.member?(in_window, u) -> {far, [{u, f, w} | cross]}
                true -> {far, cross}
              end
            end)
          end)
      end

    ceiling = round_ceiling(st, field_size)

    {far_state, far_mate} =
      WeightedMatching.new(field_size, far_edges, max_weight: ceiling, gcd: 1)
      |> WeightedMatching.solve()

    # A far player whose only edges cross into the window would be a second
    # unmatched vertex of the field part that its certificate never saw.
    far_live = MapSet.new(Ainalrami.MatchCertificate.live_vertices(far_state.weight))

    {far_hint, far_family} = WeightedMatching.certificate_hint(far_state)

    with true <- Enum.all?(cross_edges, fn {_v, f, _w} -> MapSet.member?(far_live, f) end),
         {:ok, far_cert} <-
           Ainalrami.MatchCertificate.certify(
             far_state.weight,
             far_mate,
             fn _ -> false end,
             far_hint,
             strict: false,
             family: far_family
           ) do
      far_dual = far_cert.dual
      xi = far_cert.xi

      offer =
        Enum.reduce(cross_edges, %{}, fn {v, f, w}, acc ->
          need = 2 * w - Map.get(far_dual, f, 0)
          Map.update(acc, v, need, &max(&1, need))
        end)

      window_vertices = Enum.map(0..w_last//1, to_field)

      {dummy_edges, dummies} =
        window_vertices
        |> Enum.with_index(field_size)
        |> Enum.reduce({[], %{}}, fn {v, d}, {edges, dummies} ->
          l2 = max(xi, Map.get(offer, v, 0)) + 1
          l2 = l2 + Bitwise.band(l2, 1)
          {[{v, d, div(l2, 2)} | edges], Map.put(dummies, v, d)}
        end)

      window_edges =
        for {{i, j}, w} <- st.live,
            w > 0,
            j <= w_last,
            do: {to_field.(i), to_field.(j), weigh.(i, j, w)}

      matcher =
        WeightedMatching.new(field_size + length(window_vertices), window_edges ++ dummy_edges,
          max_weight: ceiling,
          gcd: 1
        )

      {:ok, matcher,
       %{
         dummies: dummies,
         first_dummy: field_size,
         far_edges: far_edges,
         cross_edges: cross_edges,
         ceiling: ceiling
       }}
    else
      _ -> :no
    end
  end

  # The round matcher the next bracket continues from: every edge the
  # reference's round matcher holds at this point - the window's final
  # weights, and the far and crossing weights as they were, less every edge
  # of a player finalised here - in a fresh matcher that the next bracket's
  # first search completes. A state, not a solution: the next bracket's
  # reads are certified like every other read of a tainted round.
  defp graft_back(%{window: nil}), do: :ok

  defp graft_back(st) do
    {matcher, field_index, field_size} = Process.get(@round_matcher_key)
    Process.put(@round_matcher_key, whole_field_matcher(st, matcher, field_index, field_size))
    :ok
  end

  # A fresh, unsolved matcher over the whole remaining field with exactly the
  # reference's current weights: the window's (as the window matcher holds
  # them now, dummies left out), and the far and crossing ones it was built
  # from, less every edge of a player finalised in this bracket.
  defp whole_field_matcher(st, window_matcher, field_index, field_size) do
    w = st.window
    finalised = MapSet.new(st.matched, &elem(st.field_pos, &1))

    window_edges =
      for {v, _d} <- w.dummies,
          {u, wt} <- WeightedMatching.neighbours(window_matcher, v),
          u < field_size and v < u,
          do: {v, u, wt}

    cross = Enum.reject(w.cross_edges, fn {v, _f, _w} -> MapSet.member?(finalised, v) end)

    fresh =
      WeightedMatching.new(field_size, window_edges ++ w.far_edges ++ cross,
        max_weight: w.ceiling,
        gcd: 1
      )

    {fresh, field_index, field_size}
  end

  defp dummy?(%{window: nil}, _v), do: false
  defp dummy?(%{window: w}, v), do: v >= w.first_dummy

  # The window's extra condition on a snapshot: every dummy unmatched, at
  # dual 0, and a bare vertex - outside every blossom, so that its edge's
  # reduced cost is `y[v] - L(v)` and nothing else, which is what holds `v`'s
  # own dual at `L(v)` - see the section comment above.
  defp window_valid?(%{window: nil}, _matcher), do: true

  defp window_valid?(st, matcher) do
    Enum.all?(st.window.dummies, fn {_v, d} ->
      not is_map_key(matcher.mate, d) and Map.fetch!(matcher.dual, d) == 0 and
        Map.fetch!(matcher.in_blossom, d) == d and not is_map_key(matcher.parent_of, d)
    end)
  end

  # The pairs of `mate` whose edge the writes left in place.
  defp still_matched(mate, prepared) do
    kept =
      Enum.reduce(mate, %{}, fn {u, v}, acc ->
        case prepared.weight do
          %{^u => %{^v => w}} when w > 0 -> Map.put(acc, u, v)
          _ -> acc
        end
      end)

    Map.filter(kept, fn {u, v} -> Map.get(kept, v) == u end)
  end

  # `held` with every pair touching `members` (bracket indices) replaced by
  # `pairs`; a member left out of `pairs` keeps a partner outside `members`
  # if it had one.
  defp reshape(held, members, pairs, to_field) do
    members_f = MapSet.new(members, to_field)

    kept =
      Map.filter(held, fn {u, v} ->
        not (MapSet.member?(members_f, u) and MapSet.member?(members_f, v))
      end)

    paired = Enum.flat_map(pairs, fn {a, b} -> [to_field.(a), to_field.(b)] end) |> MapSet.new()

    kept =
      Map.filter(kept, fn {u, v} ->
        not MapSet.member?(paired, u) and not MapSet.member?(paired, v)
      end)

    Enum.reduce(pairs, kept, fn {a, b}, acc ->
      acc |> Map.put(to_field.(a), to_field.(b)) |> Map.put(to_field.(b), to_field.(a))
    end)
  end

  # The LOCAL graph: the bracket's own `nsgb` vertices, bracket-local
  # indices, one fresh matcher per bracket, the full ladder on every edge.
  # See `pair_bracket/6` for when this is exact. The weights carry the
  # same nearness term as the field graph's (`edge_weigher/3`), on the
  # same positions -- the bracket is a prefix of `arr` -- so the two graphs
  # agree on every tie the term can break.
  defp solve_local(st) do
    weigh = edge_weigher(st, & &1, st.m)
    dirty = Process.get(@dirty_key, [])
    Process.delete(@dirty_key)

    wm =
      case st.wm do
        nil ->
          # The same bound `solve_field/1` uses, minus the round scale: the
          # transposition tie-break's scale is per bracket and this matcher
          # is too.
          s = st.bands.count_span
          ps = st.bands.place_span
          span_product = Integer.pow(s, 12) * Integer.pow(ps, 6) * Integer.pow(s, 4) * 64

          ceiling =
            2 * span_product * st.bands.reserve * st.transposition.scale * s *
              (st.m * st.m + 1)

          list = for {{i, j}, w} <- st.live, w > 0, j < st.wl, do: {i, j, weigh.(i, j, w)}
          WeightedMatching.new(st.wl, list, max_weight: ceiling, gcd: 1)

        wm ->
          {wm, _seen} =
            Enum.reduce(dirty, {wm, MapSet.new()}, fn {i, j} = key, {acc, seen} ->
              cond do
                i >= st.wl or j >= st.wl ->
                  {acc, seen}

                MapSet.member?(seen, key) ->
                  {acc, seen}

                true ->
                  want = weigh.(i, j, get_w(st.live, i, j))

                  acc =
                    if WeightedMatching.edge_weight(acc, i, j) == want,
                      do: acc,
                      else: WeightedMatching.set_weight(acc, i, j, want)

                  {acc, MapSet.put(seen, key)}
              end
            end)

          wm
      end

    {wm, matching} = WeightedMatching.solve(wm)
    %{st | wm: wm, matching: matching, guess: nil}
  end

  ## ------------------------------------------- the completability oracle
  #
  # One question, asked once per bracket that wants the local graph: with
  # this bracket taken out, can everyone who is left still be paired --
  # leaving the one bye, if any, on a bye candidate? That is condition (b)
  # of `pair_bracket/6`, and it is a MAXIMUM-CARDINALITY question, which two
  # things make cheap:
  #
  #   * **Sparse.** Each player keeps only their `@oracle_degree` nearest
  #     legal, colour-compatible opponents below them in the field order
  #     (and inherits the same from above), so the graph is O(n) edges
  #     rather than O(n^2). Sound in the direction that matters: a
  #     matching of a subgraph is a matching of the graph. A false NEGATIVE
  #     is possible -- the sparse graph may miss a matching the dense one
  #     has -- and it costs a fall back to the field graph for that
  #     bracket, never a wrong answer.
  #
  #   * **A stand-in for the bye.** On an odd field one more vertex, joined
  #     to every bye candidate, takes part whenever the players left are
  #     odd: the players can be paired leaving the bye on a candidate
  #     exactly when the players and the stand-in can be perfectly matched.
  #     With an even number left (a question about part of a bracket) it
  #     sits out, and the question is a perfect matching of the players.
  #     So every question is "is there a perfect matching", and a maximum
  #     matching kept from question to question answers it: the players
  #     taken out leave their partners exposed, and an augmenting search from
  #     each exposed vertex (`Ainalrami.CardinalityMatching.augment_from/4`)
  #     either matches it or shows that some maximum matching leaves it
  #     exposed - no perfect matching.
  #
  # This was a maximum-WEIGHT matching (`B + K*(noncand(i) + noncand(j)) +
  # (n - |i-j|)`: cardinality, then matched non-candidates, then nearness),
  # whose answer is the same property of the same graph - it said yes
  # exactly when a maximum-weight matching left at most the allowed byes
  # unmatched and each of them a candidate, which is the perfect matching
  # above. Its first solve cost 0.05-0.22 s a round at 1,000 players, most
  # of an odd 1,001-player round 9. It is kept as the check: under
  # `AINALRAMI_DIRECT=check` the weighted oracle runs alongside
  # (`weighted_oracle/4`) and every answer is held to it.
  #
  # Taking a bracket out returns a new oracle, so the one before is kept
  # for free and simply discarded when the answer is good.
  @oracle_degree 12

  defp build_oracle(field, allowed_byes, ctx) do
    arr = List.to_tuple(field)
    n = length(field)
    candidate? = fn i -> bye_candidate?(elem(arr, i), ctx.bye_score) end

    pairs =
      for i <- 0..(n - 1)//1,
          j <-
            Enum.reduce_while((i + 1)..(n - 1)//1, {[], 0}, fn j, {acc, taken} ->
              cond do
                taken >= @oracle_degree ->
                  {:halt, {acc, taken}}

                legal_pair?(elem(arr, i), elem(arr, j)) and
                    colour_compatible?(elem(arr, i), elem(arr, j)) ->
                  {:cont, {[j | acc], taken + 1}}

                true ->
                  {:cont, {acc, taken}}
              end
            end)
            |> elem(0),
          do: {i, j}

    # The bye's stand-in, vertex `n`, on an odd field.
    x = if allowed_byes == 1, do: n
    bye_edges = if x, do: for(i <- 0..(n - 1)//1, candidate?.(i), do: {i, x}), else: []
    order = if x, do: n + 1, else: n

    rows =
      Enum.reduce(pairs ++ bye_edges, %{}, fn {i, j}, acc ->
        acc |> Map.update(i, [j], &[j | &1]) |> Map.update(j, [i], &[i | &1])
      end)

    ref =
      if env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "check" do
        noncand = for i <- 0..(n - 1)//1, into: %{}, do: {i, bit(not candidate?.(i))}
        weighted_oracle(n, pairs, allowed_byes, noncand)
      end

    %{
      adj: List.to_tuple(for v <- 0..(order - 1)//1, do: rows |> Map.get(v, []) |> Enum.sort()),
      x: x,
      live: n,
      gone: MapSet.new(),
      match: nil,
      ref: ref,
      # For `oracle_dense/2`: the field, who may take the bye, and a name
      # for the rows it builds.
      field: arr,
      candidates: MapSet.new(for i <- 0..(n - 1)//1, candidate?.(i), do: i),
      id: make_ref()
    }
  end

  # The oracle with its matching solved (kept, so this happens once).
  defp solved_oracle do
    case Process.get(@oracle_key) do
      %{match: nil} = oracle ->
        {_, solved} = oracle_settle(oracle, [], false)
        oracle = %{solved | ref: oracle.ref && weighted_solved(oracle.ref)}
        Process.put(@oracle_key, oracle)
        oracle

      oracle ->
        oracle
    end
  end

  # Condition (b) for `positions` as the bracket: take them out, re-augment,
  # and see whether everyone left (with the bye's stand-in, when it takes
  # part) is matched. `{:ok, oracle}` carries the state with the bracket
  # gone, to keep if the bracket is accepted.
  defp oracle_completable?(oracle, positions) do
    {answer, half} =
      case oracle_settle(oracle, positions, true) do
        {:ok, settled} -> {{:ok, settled}, nil}
        {:short, half} -> {:no, half}
      end

    # The sparse graph's answer, held to the weighted oracle on the same
    # graph in check mode.
    answer =
      case oracle.ref do
        nil ->
          answer

        ref ->
          reference = weighted_completable?(ref, positions)
          cert_count(:oracle_checked)

          if match?({:ok, _}, answer) != match?({:ok, _}, reference) do
            raise "completability oracle differs from the weighted one on #{inspect(positions)}: " <>
                    "#{inspect(match?({:ok, _}, answer))}"
          end

          case {answer, reference} do
            {{:ok, settled}, {:ok, ref}} -> {:ok, %{settled | ref: ref}}
            _ -> :no
          end
      end

    case answer do
      :no when half != nil ->
        case oracle_dense(half, oracle.ref && weighted_remove(oracle.ref, positions)) do
          {:ok, settled} ->
            Process.put(@oracle_dense_key, true)
            {:ok, settled}

          :no ->
            :no
        end

      answer ->
        answer
    end
  end

  # Where the sparse graph misses a matching: the whole compatible graph.
  #
  # The sparse graph keeps each player's first `@oracle_degree` compatible
  # players below them, and in a final round - where two players with the
  # same absolute colour preference cannot meet, so a stretch of the field
  # can hold more of one colour than its neighbourhood can take - a matching
  # of the field can need partners further apart than that. The sparse "no"
  # then sent a 127-player bracket to the field graph: 8 s at 1,000 players
  # round 9, where the whole graph had a perfect matching of the rest.
  #
  # This grows the sparse search's matching (every pair of it compatible)
  # by augmenting searches over every compatible pair - the test
  # `build_oracle/3` makes, `legal_pair?/2` and `colour_compatible?/2` with
  # the better-placed player first - plus the bye's stand-in joined to every
  # candidate. The rows are built only as a search reaches them and kept for
  # the round's oracle. The answer is exact: a search from an exposed player
  # that finds no augmenting path shows that some maximum matching of the
  # whole graph leaves them exposed, so no perfect one exists, which is the
  # field graph's own "no". And a "yes" is a matching of the graph the field
  # path pairs on, so condition (b) holds as it holds for a sparse "yes".
  # Later sparse searches run on the sparse graph plus this matching's
  # pairs, still a subgraph of the whole one.
  #
  # `AINALRAMI_DIRECT=off` switches it off with the direct brackets.
  defp oracle_dense(half, ref) do
    x = half.x

    cond do
      env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "off" ->
        :no

      # An odd number of players and no bye: no perfect matching, exactly.
      x == nil and rem(half.live, 2) == 1 ->
        :no

      true ->
        dead =
          if x != nil and rem(half.live, 2) == 0, do: MapSet.put(half.gone, x), else: half.gone

        row = &oracle_row(half, &1)

        result =
          Enum.reduce_while(0..(tuple_size(half.adj) - 1)//1, half.match, fn v, match ->
            if MapSet.member?(dead, v) or is_map_key(match, v) do
              {:cont, match}
            else
              case CardinalityMatching.augment_from(row, match, v, dead) do
                {:ok, match} -> {:cont, match}
                :none -> {:halt, :none}
              end
            end
          end)

        case result do
          :none ->
            :no

          match ->
            settled = %{half | match: match, ref: ref}
            if ref != nil, do: check_oracle_match!(settled, dead)
            cert_count(:oracle_dense)
            {:ok, settled}
        end
    end
  end

  # A row of the whole compatible graph of the oracle's field (vertex `x`,
  # the bye's stand-in, joined to the candidates), kept for the round.
  defp oracle_row(oracle, v) do
    rows =
      case Process.get(@dense_rows_key) do
        {id, rows} when id == oracle.id -> rows
        _ -> %{}
      end

    case rows do
      %{^v => row} ->
        row

      _ ->
        row = dense_oracle_row(oracle, v)
        Process.put(@dense_rows_key, {oracle.id, Map.put(rows, v, row)})
        row
    end
  end

  defp dense_oracle_row(%{x: x} = oracle, v) when v == x, do: Enum.sort(oracle.candidates)

  defp dense_oracle_row(oracle, v) do
    arr = oracle.field
    p = elem(arr, v)

    row =
      for q <- 0..(tuple_size(arr) - 1)//1,
          q != v,
          {a, b} = if(v < q, do: {p, elem(arr, q)}, else: {elem(arr, q), p}),
          legal_pair?(a, b) and colour_compatible?(a, b),
          do: q

    if oracle.x != nil and MapSet.member?(oracle.candidates, v), do: row ++ [oracle.x], else: row
  end

  # Check mode: the dense answer's matching covers everyone left, and every
  # pair of it is one the field graph has an edge for.
  defp check_oracle_match!(oracle, dead) do
    arr = oracle.field

    Enum.each(0..(tuple_size(oracle.adj) - 1)//1, fn v ->
      u = Map.get(oracle.match, v)

      ok? =
        cond do
          MapSet.member?(dead, v) -> true
          u == nil or MapSet.member?(dead, u) -> false
          v == oracle.x -> MapSet.member?(oracle.candidates, u)
          u == oracle.x -> MapSet.member?(oracle.candidates, v)
          true -> compatible_positions?(arr, min(u, v), max(u, v))
        end

      if not ok?, do: raise("dense completability oracle left #{v} without a compatible partner")
    end)
  end

  defp compatible_positions?(arr, i, j) do
    legal_pair?(elem(arr, i), elem(arr, j)) and colour_compatible?(elem(arr, i), elem(arr, j))
  end

  # `positions` leave the field, and the matching is re-augmented around
  # the hole.
  defp oracle_remove(oracle, []), do: oracle

  defp oracle_remove(oracle, positions) do
    {_, settled} = oracle_settle(oracle, positions, false)
    %{settled | ref: oracle.ref && weighted_remove(oracle.ref, positions)}
  end

  # Take `positions` out and augment from every exposed vertex left:
  # `{:ok, oracle}` when everyone is then matched, `{:short, oracle}` when
  # not (with `stop?`, as soon as one search fails, the oracle half done).
  defp oracle_settle(oracle, positions, stop?) do
    gone = Enum.reduce(positions, oracle.gone, &MapSet.put(&2, &1))
    live = oracle.live - length(positions)
    match = oracle.match || CardinalityMatching.maximum(oracle.adj)
    match = Enum.reduce(positions, match, &oracle_unmatch(&2, &1))
    x = oracle.x

    # The stand-in takes part when the players left are odd.
    {dead, match} =
      if x != nil and rem(live, 2) == 0,
        do: {MapSet.put(gone, x), oracle_unmatch(match, x)},
        else: {gone, match}

    parity = if x == nil and rem(live, 2) == 1, do: :short, else: :ok

    {status, match} =
      if parity == :short and stop? do
        {:short, match}
      else
        Enum.reduce_while(0..(tuple_size(oracle.adj) - 1)//1, {parity, match}, fn v,
                                                                                  {status, match} ->
          if MapSet.member?(dead, v) or is_map_key(match, v) do
            {:cont, {status, match}}
          else
            case CardinalityMatching.augment_from(oracle.adj, match, v, dead) do
              {:ok, match} -> {:cont, {status, match}}
              :none when stop? -> {:halt, {:short, match}}
              :none -> {:cont, {:short, match}}
            end
          end
        end)
      end

    {status, %{oracle | gone: gone, live: live, match: match}}
  end

  defp oracle_unmatch(match, v) do
    case Map.pop(match, v) do
      {nil, match} -> match
      {u, match} -> Map.delete(match, u)
    end
  end

  # The weighted oracle, run alongside in check mode (see above).
  defp weighted_oracle(n, pairs, allowed_byes, noncand) do
    edges = for {i, j} <- pairs, do: {i, j, oracle_weight(i, j, n, noncand)}

    %{
      state: WeightedMatching.new(n, edges, max_weight: oracle_ceiling(n), gcd: 1),
      n: n,
      allowed_byes: allowed_byes,
      noncand: noncand,
      gone: MapSet.new(),
      solved?: false
    }
  end

  defp weighted_solved(%{solved?: true} = ref), do: ref

  defp weighted_solved(ref) do
    {state, _} = WeightedMatching.solve(ref.state)
    %{ref | state: state, solved?: true}
  end

  defp oracle_weight(i, j, n, noncand) do
    k = n * n
    b = n * k + n * n + 1
    b + k * (Map.fetch!(noncand, i) + Map.fetch!(noncand, j)) + (n - abs(j - i))
  end

  defp oracle_ceiling(n), do: n * n * n + 4 * n * n + n + 1

  defp weighted_completable?(ref, positions) do
    ref = weighted_remove(ref, positions)

    unmatched =
      for v <- 0..(ref.n - 1)//1,
          not MapSet.member?(ref.gone, v),
          WeightedMatching.mate_of(ref.state, v) == nil,
          do: v

    if length(unmatched) <= ref.allowed_byes and
         Enum.all?(unmatched, &(Map.fetch!(ref.noncand, &1) == 0)),
       do: {:ok, ref},
       else: :no
  end

  defp weighted_remove(ref, []), do: ref

  defp weighted_remove(ref, positions) do
    state =
      Enum.reduce(positions, ref.state, fn v, acc ->
        acc
        |> WeightedMatching.neighbours(v)
        |> Enum.reduce(acc, fn {u, _w}, acc -> WeightedMatching.set_weight(acc, v, u, 0) end)
      end)

    {state, _} = WeightedMatching.solve(state)

    %{
      ref
      | state: state,
        gone: MapSet.union(ref.gone, MapSet.new(positions)),
        solved?: true
    }
  end

  # The FIELD graph: the whole remaining field, one matcher for the round,
  # carried across every bracket.
  defp solve_field(st) do
    {round_matcher, field_index, field_size} = Process.get(@round_matcher_key)
    to_field = field_positions(st, field_index)
    weigh = edge_weigher(st, to_field, field_size)
    dirty = Process.get(@dirty_key, [])
    Process.delete(@dirty_key)

    # One matcher for the whole ROUND, carried across every bracket.
    #
    # Every bracket's vertex set is a subsequence of the round's field
    # order, and the bands are field-wide and constant (`global_context/1`),
    # so a bracket boundary is a set of edge changes on one graph rather
    # than a new graph. Vertex ids are positions in `field`; bracket-local
    # indices are translated on the way in and back on the way out.
    #
    # Three ways in:
    #
    #   * no matcher yet -- the round's first bracket builds it;
    #   * a bracket's FIRST solve -- its `live` is a fresh
    #     `base_edge_weights/7`, so the matcher's edges on this bracket's
    #     vertices are diffed against it and the differences applied. The
    #     far edges are frozen (`:far_weights`), so that diff is the new
    #     bracket's own pairs and its edges into the next group, not the
    #     whole graph;
    #   * every later solve of the same bracket -- exactly the edges the
    #     stages wrote through `set_live/4`, each prepared at its modified
    #     vertex, as `setEdgeWeight` would have been called.
    matcher =
      cond do
        round_matcher == nil ->
          # Ceiling for the ROUND -- must exceed every weight ANY bracket can
          # produce, not just this one's. `st.max_w` is per bracket and a later
          # bracket's can be larger (different sgb/MDP structure, same bands),
          # which the guard caught as "weight exceeds the initial dual" on
          # 4-player fields where the first bracket is trivial.
          #
          # A safe bound from the packing itself: `ranked/1` packs rungs as
          # `acc * span + value` with every span from the field-wide `bands`,
          # so the product of the spans bounds any base weight; times the
          # reserve band the stages add into; times the largest transposition
          # scale any bracket can reach, `(n + 2)^(n/2 + 1)`, when that
          # tie-break is switched on; doubled for room. Too LARGE is
          # harmless -- it is only the initial dual, and bbpPairings'
          # `aboveMaxEdgeWeight` is likewise a bound, not exact.
          case st.prebuilt do
            nil ->
              list =
                for {{i, j}, w} <- st.live, w > 0 do
                  {to_field.(i), to_field.(j), weigh.(i, j, w)}
                end

              WeightedMatching.new(field_size, list,
                max_weight: round_ceiling(st, field_size),
                gcd: 1
              )

            # The same rows `new/3` would fold out of that list, built with
            # `base` (`first_field_build/8`) - `live` is still `base` at the
            # bracket's first solve.
            adjacency ->
              WeightedMatching.new(field_size, [],
                adjacency: adjacency,
                symmetric: true,
                max_weight: round_ceiling(st, field_size),
                gcd: 1
              )
          end

        not st.synced ->
          # Bracket boundary. For every vertex of the WINDOW (the bracket and
          # the next score group -- see `base_edge_weights/8`), the matcher's
          # edges to other window vertices must become exactly `live`'s.
          # Everything else stays: edges into the far field are the frozen
          # completability weights set with the first bracket, and edges to
          # finalised players were zeroed when they were finalised. Applied
          # lower-index first, which is also the near-minimal set of vertices
          # to prepare: the changes are a clique on the new bracket's
          # residents plus their edges into the next group.
          last = min(st.wsgb, st.m) - 1
          here = Map.new(0..last//1, fn i -> {to_field.(i), i} end)

          Enum.reduce(0..last//1, round_matcher, fn i, acc ->
            fi = to_field.(i)

            # Edges the matcher has from `fi` into this graph that `live`
            # does not have, or has at a different weight.
            acc =
              Enum.reduce(WeightedMatching.neighbours(acc, fi), acc, fn {fj, cur}, acc ->
                case Map.get(here, fj) do
                  nil ->
                    acc

                  j when j < i ->
                    acc

                  j ->
                    want = weigh.(i, j, get_w(st.live, i, j))
                    if want == cur, do: acc, else: WeightedMatching.set_weight(acc, fi, fj, want)
                end
              end)

            # Edges `live` has from `i` that the matcher lacks.
            Enum.reduce((i + 1)..last//1, acc, fn j, acc ->
              case get_w(st.live, i, j) do
                0 ->
                  acc

                w ->
                  fj = to_field.(j)
                  want = weigh.(i, j, w)

                  if WeightedMatching.edge_weight(acc, fi, fj) == want,
                    do: acc,
                    else: WeightedMatching.set_weight(acc, fi, fj, want)
              end
            end)
          end)

        true ->
          apply_dirty(round_matcher, st, dirty, to_field, weigh)
      end

    install =
      st.synced and
        cert_timed(:ms_install, fn ->
          certified_install(round_matcher, matcher, st, dirty, to_field)
        end)

    {matcher, matching_f} =
      case install do
        {:ok, installed} -> installed
        _ -> cert_timed(:ms_solve, fn -> WeightedMatching.solve(matcher) end)
      end

    # Back to bracket-local indices; anything matched outside this
    # bracket's vertex set is another bracket's business.
    from_field = st.from_field

    matching =
      Enum.reduce(matching_f, %{}, fn {a, b}, acc ->
        case {Map.get(from_field, a), Map.get(from_field, b)} do
          {nil, _} -> acc
          {_, nil} -> acc
          {i, j} -> Map.put(acc, i, j)
        end
      end)

    Process.put(@round_matcher_key, {matcher, field_index, field_size})

    st = %{
      st
      | matching: matching,
        synced: true,
        snap: {matcher, make_ref()},
        guess: nil,
        prebuilt: nil
    }

    # A window whose optimum wants the field below (a dummy matched, or
    # priced) no longer stands for the whole graph: the bracket continues on
    # the whole field from here, before anything is read off this solve.
    if st.window != nil and not window_valid?(st, matcher),
      do: leave_window(st, matcher, field_index, field_size),
      else: st
  end

  defp leave_window(st, window_matcher, field_index, field_size) do
    cert_count(:window_left)

    {fresh, _field_index, _field_size} =
      whole_field_matcher(st, window_matcher, field_index, field_size)

    {solved, matching_f} = WeightedMatching.solve(fresh)

    matching =
      Enum.reduce(matching_f, %{}, fn {a, b}, acc ->
        case {Map.get(st.from_field, a), Map.get(st.from_field, b)} do
          {nil, _} -> acc
          {_, nil} -> acc
          {i, j} -> Map.put(acc, i, j)
        end
      end)

    Process.put(@round_matcher_key, {solved, field_index, field_size})
    %{st | matching: matching, window: nil, snap: {solved, make_ref()}}
  end

  # The round matcher's weight ceiling: see the first branch of
  # `solve_field/1`.
  defp round_ceiling(st, field_size) do
    n = field_size
    s = st.bands.count_span
    ps = st.bands.place_span
    span_product = Integer.pow(s, 12) * Integer.pow(ps, 6) * Integer.pow(s, 4) * 64

    round_scale =
      if st.transposition.scale == 1, do: 1, else: Integer.pow(n + 2, div(n, 2) + 1)

    2 * span_product * st.bands.reserve * round_scale * s * (n * n + 1)
  end

  # The stages' writes since the last solve, most recent first. Each
  # `{modified, neighbour}` pair is applied once, at `live`'s current (final)
  # value; a write that left the matcher's weight as it was is skipped,
  # which prepares nothing the reference would not also have left
  # untouched in effect.
  # Bracket-local index -> the player's position in the round's field, the
  # round matcher's vertex id. A tuple built once per bracket
  # (`new_bracket/9`'s `field_pos`, from the same `field_index` the round
  # matcher was created with) rather than a rank lookup per endpoint per
  # edge: the first field bracket of a round hands the matcher every pair
  # of the field, and every translation went through two map lookups.
  defp field_positions(%{field_pos: pos}, _field_index), do: &elem(pos, &1)

  defp apply_dirty(matcher, st, dirty, to_field, weigh) do
    {matcher, _seen} =
      Enum.reduce(dirty, {matcher, MapSet.new()}, fn {i, j} = key, {acc, seen} ->
        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          fi = to_field.(i)
          fj = to_field.(j)
          want = weigh.(i, j, get_w(st.live, i, j))

          acc =
            if WeightedMatching.edge_weight(acc, fi, fj) == want,
              do: acc,
              else: WeightedMatching.set_weight(acc, fi, fj, want)

          {acc, MapSet.put(seen, key)}
        end
      end)

    matcher
  end

  # Push the stages' writes since the last solve into the round matcher
  # WITHOUT solving -- called once at the end of every bracket, so that the
  # next bracket's boundary diff starts from a matcher whose edges equal
  # this bracket's final `live`. Without it the last `finalize_pair/3` of a
  # bracket (which always follows its last solve) would be lost, and the
  # finalised pair's stale edges into the next bracket would still be in
  # the graph.
  defp flush_live(st) do
    case Process.get(@round_matcher_key) do
      {nil, _, _} ->
        st

      {matcher, field_index, field_size} ->
        dirty = Process.get(@dirty_key, [])
        Process.delete(@dirty_key)
        to_field = field_positions(st, field_index)

        matcher =
          apply_dirty(matcher, st, dirty, to_field, edge_weigher(st, to_field, field_size))

        Process.put(@round_matcher_key, {matcher, field_index, field_size})
        st
    end
  end

  # The weight the matcher sees for a `live` weight `w` on `{i, j}`.
  #
  # Two things sit on top of the criteria weight, both strictly below it
  # and below every stage addend:
  #
  #   * the transposition tie-break, only when switched on (see
  #     `transposition_terms/3`), scales `w` to make room for its term;
  #   * always, a NEARNESS term: the whole thing is scaled by `n^2 + 1` and
  #     `n - |fi - fj|` is added, `fi`/`fj` being the two players' positions
  #     in the round's field. Among matchings of equal criteria weight the
  #     one pairing nearer positions wins; a sum of fewer than n/2 such
  #     terms cannot reach `n^2 + 1`, so it can never overturn a one-unit
  #     difference in anything above it.
  #
  # The nearness term is not there for the pairing. The refinement stages
  # settle every tie the criteria leave, and the corpus is identical with
  # it on or off. It is there for the SEARCH. The far edges -- most of the
  # graph on a large field -- carry only the completability weight, and
  # with thousands of them equal, every one of them is TIGHT at the
  # optimum: the alternating forest of each stage then grows across the
  # entire field, at a row walk per vertex, before it can augment, and
  # odd cycles of tight edges form blossoms by the thousand. With each
  # edge's weight made distinct by a canonical term, the optimum leaves
  # few edges tight, the forest grows only where it must, and a
  # 400-player round ran 14.2 s -> 9.0 s on that alone: 23,470 -> 13,405
  # tree growths and 9,142 -> 4,525 blossom formations. Nearness in
  # particular, rather than any other canonical term, because the greedy
  # start (`WeightedMatching.new/3`) matches mutually-heaviest pairs and
  # nearest neighbours are mutual, so the cold solve stays short.
  #
  # Field positions, not bracket positions, so that a far edge's weight is
  # the same in every bracket that sees it and the round matcher never has
  # to be told about it twice.
  # The distance the tie-break prefers between two bracket members: half the
  # bracket, which is where Article 3.3 puts S1[i] against S2[i] and where
  # stage 4 (fewest exchanges) and stage 8 (highest remaining partner for
  # each S1 player in turn) will push the matching anyway. Starting the
  # search there instead of at adjacent pairs means those stages find the
  # matching already in shape and augment a handful of times rather than
  # half the bracket. Zero outside the bracket, where adjacent is right:
  # the far edges only need SOME canonical order, and the greedy start
  # pairs adjacent far vertices in one pass.
  defp natural_gap(st, i, j) do
    if i < st.nsgb and j < st.nsgb, do: div(st.nsgb, 2), else: 0
  end

  defp edge_weigher(st, to_field, field_size) do
    scale = st.transposition.scale
    terms = st.transposition.terms
    reserve = st.bands.reserve
    p = field_size * field_size + 1

    criteria =
      cond do
        scale == 1 and map_size(terms) == 0 ->
          fn _i, _j, w -> w end

        System.get_env("AINALRAMI_TRANS_ABOVE") != nil ->
          # Split `w` back into its criteria part and the refinement
          # stages' reserved addend, and slot the transposition order
          # BETWEEN them: criteria still win, but FIDE's order now
          # outranks a stage nudge instead of the other way round.
          fn i, j, w ->
            term = Map.get(terms, {min(i, j), max(i, j)}, 0)
            div(w, reserve) * scale * reserve + term * reserve + rem(w, reserve)
          end

        true ->
          fn i, j, w -> w * scale + Map.get(terms, {min(i, j), max(i, j)}, 0) end
      end

    fn
      _i, _j, 0 ->
        0

      i, j, w ->
        criteria.(i, j, w) * p + field_size -
          abs(abs(to_field.(j) - to_field.(i)) - natural_gap(st, i, j))
    end
  end

  # FIDE section 3's transposition order as an edge-additive tie-break,
  # strictly below every criterion AND below the reserved space the
  # refinement stages write into, so it can only settle what they leave
  # open.
  #
  # Articles 3.3-3.5 take the SMALLEST transposition of the natural order,
  # and "smallest" is lexicographic over S2: which S2 member faces S1[0],
  # then S1[1], and so on. Maximising `B^(k-p) * (|S2| - q)` for an edge
  # from S1[p] to S2[q] minimises exactly that sequence, and it splits
  # over edges because each pair contributes one (p, q).
  #
  # An earlier version of this carried the engine's general-purpose
  # canonical tie-break instead (`lex_scale/1`), which keys on ABSOLUTE
  # bracket position rather than S2 index. That is a different order - it
  # makes the natural pairing (S1[0] vs S2[0], i.e. positions 0 and k)
  # look large and an adjacent pairing (0 vs 1) look smallest.
  #
  # ## It is inert, and promoting it is actively worse
  #
  # Every variant measures identically: removed, inverted, and replaced
  # with this handbook key, with byes and without. The eight refinement
  # stages settle every tie before it is consulted.
  #
  # `AINALRAMI_TRANS_ABOVE=1` slots it between the criteria and the stages'
  # reserved addends, so FIDE's order outranks a stage nudge rather than
  # the reverse. That is much worse - 95.97% -> 87.57% without byes and
  # 86.70% -> 79.93% with them.
  #
  # Which says the key is the wrong model, not the priority. Stages 5-7
  # EXCHANGE players between the two halves, so by the time partners are
  # chosen "S1" and "S2" are no longer the naive first-half/second-half
  # split this function assumes; it is measuring transpositions against a
  # reference the bracket has already moved away from. The stages are the
  # transposition procedure, and they are right. Kept, off the critical
  # path, because a correct key would be worth having if anyone works out
  # what the post-exchange split actually is.
  #
  # "Off the critical path" is what the flag check being FIRST buys. It
  # used to be last, so a switched-off tie-break still paid for itself in
  # full on every bracket and then threw the answer away: on the
  # 205-player bracket that is 104 `Integer.pow` calls topping out near
  # 690 bits, and 10,506 `terms` entries, each one a ~690-bit bignum
  # multiply plus an `Enum.min_max` allocation. The flag-off branch
  # returns the same `%{terms: %{}, scale: 1}` the tail used to.
  defp transposition_terms(_m, sgb, nsgb) do
    if System.get_env("AINALRAMI_TRANS") do
      transposition_terms_on(sgb, nsgb)
    else
      %{terms: %{}, scale: 1}
    end
  end

  defp transposition_terms_on(sgb, nsgb) do
    {s1, s2} =
      cond do
        # A heterogeneous bracket pairs its moved-down players against the
        # residents: MDPs are S1 (Article 3.3.1).
        sgb > 0 and sgb < nsgb -> {0..(sgb - 1)//1, sgb..(nsgb - 1)//1}
        nsgb >= 2 -> {0..(div(nsgb, 2) - 1)//1, div(nsgb, 2)..(nsgb - 1)//1}
        true -> {1..0//1, 1..0//1}
      end

    s1 = Enum.to_list(s1)
    s2 = Enum.to_list(s2)
    k = length(s1)
    n2 = length(s2)
    base = n2 + 2
    pow = for e <- 0..(k + 1), into: %{}, do: {e, Integer.pow(base, e)}

    # Hoisted: a comprehension re-evaluates its INNER generator once per
    # outer element, so leaving this inline rebuilt the same 103-element
    # indexed list 102 times on that bracket.
    #
    # This only bites under `AINALRAMI_TRANS=1`. The guard above means the
    # whole function is skipped in the default configuration, so the hoist
    # saves nothing there - it is fixed because the flag exists to be used,
    # not because it is on a hot path today.
    s2_indexed = Enum.with_index(s2)

    terms =
      for {p, pi} <- Enum.with_index(s1),
          {q, qi} <- s2_indexed,
          into: %{} do
        {Enum.min_max([p, q]), Map.fetch!(pow, k - pi) * (n2 - qi)}
      end

    # One unit above anything the terms can reach, so the whole tie-break
    # sits under the criteria rather than beside them.
    %{terms: terms, scale: Map.fetch!(pow, k + 1)}
  end

  # bbpPairings reads an unmatched vertex as matched to ITSELF, and three
  # of the stage tests below (`< playerVertex`, `<= playerVertex`) depend
  # on that convention rather than on a nil check.
  #
  # `partner/2` is the raw read, for the places that only choose between two
  # ways of reaching the same weights (a dual shift or a search) or format a
  # trace. Everything the stages DECIDE on goes through `certified/3` - the
  # helpers below and `certified_partner/2` - see "certified shortcuts".
  defp partner(st, i), do: Map.get(st.matching, i, i)

  defp certified_partner(st, i), do: certified(st, i, :exact, & &1)

  # Matched to a resident of this bracket's own score group.
  defp internal?(st, i) do
    sgb = st.sgb
    nsgb = st.nsgb
    certified(st, i, :internal, fn p -> p >= sgb and p < nsgb end)
  end

  # Paired with someone LATER in the bracket - the "higher group" role in
  # an exchange.
  defp paired_down?(st, i) do
    nsgb = st.nsgb
    certified(st, i, :down, fn p -> p > i and p < nsgb end)
  end

  defp raw_paired_down?(st, i) do
    p = partner(st, i)
    p > i and p < st.nsgb
  end

  defp exchange_needed?(st, i) do
    nsgb = st.nsgb
    certified(st, i, :need, fn p -> p <= i or p >= nsgb end)
  end

  # `common.h:164`. Lock the pair by leaving each vertex exactly one
  # usable edge - the one to the other.
  #
  # The fast path, `WeightedMatching.finalize_pair/3`, is a pure edge
  # REMOVAL with no `prepare_vertex/2` and no forced re-solve (see its own
  # doc for why that stays optimal). It runs directly against whichever
  # matcher `i`/`j` are ALREADY matched in - `st.wm` for the local graph,
  # or the round matcher for the field one, `i`/`j` translated to field
  # indices exactly as `solve_field/1` itself does. Both call sites
  # (`finalize_matched/2`, `finalize_both/2`) reach here right after their
  # own `solve/1`, so that matcher always exists; the fallback below is for
  # when the fast function itself refuses - `i` or `j` inside a
  # non-trivial blossom - which is correctness-safe by construction since
  # it is the old, already-proven path, just slower.
  defp finalize_pair(st, i, j) do
    case fast_finalize_pair(st, i, j) do
      {:ok, st} -> st
      :error -> finalize_pair_by_rebuild(st, i, j)
    end
  end

  defp fast_finalize_pair(%{mode: :local, wm: nil}, _i, _j), do: :error

  defp fast_finalize_pair(%{mode: :local} = st, i, j) do
    case WeightedMatching.finalize_pair(st.wm, i, j) do
      {:ok, wm} -> {:ok, %{st | wm: wm, live: drop_other_live(st, i, j)}}
      :error -> :error
    end
  end

  defp fast_finalize_pair(%{mode: :field} = st, i, j) do
    case Process.get(@round_matcher_key) do
      {nil, _field_index, _field_size} ->
        :error

      {matcher, field_index, field_size} ->
        to_field = field_positions(st, field_index)

        case WeightedMatching.finalize_pair(matcher, to_field.(i), to_field.(j)) do
          {:ok, matcher} ->
            Process.put(@round_matcher_key, {matcher, field_index, field_size})
            {:ok, %{st | live: drop_other_live(st, i, j)}}

          :error ->
            :error
        end
    end
  end

  defp fast_finalize_pair(_st, _i, _j), do: :error

  # `live`'s half of the fast path: the matcher already has every OTHER
  # edge of `i` and `j` gone, so `live` is brought in line the same way -
  # plain writes, not `set_live/4`, since there is nothing left to apply
  # and so nothing to queue as dirty. The `(i, j)` edge itself is left
  # untouched here, unlike the slow path's max_w bump: the matcher already
  # holds it exactly as it was, and writing `st.max_w` into `live` would
  # queue exactly the `set_weight/4` prepare this path exists to avoid,
  # the next time `live` is diffed against the matcher.
  defp drop_other_live(st, i, j) do
    0..(st.wl - 1)//1
    |> Enum.reject(&(&1 == i or &1 == j))
    |> Enum.reduce(st.live, fn k, acc -> acc |> put_w(i, k, 0) |> put_w(j, k, 0) end)
  end

  defp finalize_pair_by_rebuild(st, i, j) do
    live =
      Enum.reduce(0..(st.wl - 1)//1, st.live, fn k, acc ->
        acc = if k == i, do: acc, else: set_live(acc, i, k, if(k == j, do: st.max_w, else: 0))
        if k == j, do: acc, else: set_live(acc, j, k, if(k == i, do: st.max_w, else: 0))
      end)

    %{st | live: live}
  end

  ## ---------- the ladder ----------

  defp base_edge_weights(_arr, m, _sgb, _nsgb, _scored, _ctx, _bands, _single_bye?) when m < 2,
    do: %{}

  # The weights for this bracket's graph -- and the graph is the whole
  # remaining field, but only the WINDOW of it is scored here.
  #
  # The window is the bracket and the next score group, positions
  # `0..wsgb-1`: bbpPairings' `playersByIndex`, the only vertices its
  # `computeBaseEdgeWeights` sees. Every edge with an end below the window
  # is a far edge -- scored for completability alone, at reach two or
  # more -- and bbpPairings sets those ONCE per round, before the first
  # bracket (dutch.cpp:740-816), and never touches them again. So does
  # this: the round's first bracket scores the whole field and the round
  # matcher is built from it; every later bracket scores its window and
  # nothing else, and the matcher still holds the far edges from the
  # first. The one thing that has to reach past the window is
  # `finalize_pair/3`, which zeroes a finalised player's every edge, and
  # it does so through `set_live/4` whether or not `live` ever held the
  # edge.
  #
  # Before this every bracket rescored all m^2/2 pairs and the boundary
  # diff walked them again: 1.4 s of a 9 s round at 400 players, for
  # values that could not have changed.
  defp base_edge_weights(arr, m, sgb, nsgb, scored, ctx, bands, single_bye?) do
    weight = pair_weigher(arr, m, sgb, nsgb, scored, ctx, bands, single_bye?)
    last = scored - 1

    list =
      for i <- 0..(last - 1)//1,
          j <- (i + 1)..last//1,
          w = weight.(i, j),
          w != nil,
          do: {{i, j}, w}

    :maps.from_list(list)
  end

  # `bracket_edge_weight/8` for the pair at positions `x < y` of `arr`, with
  # the per-player parts of every pair OUTSIDE the bracket computed once per
  # player instead of once per pair. Those pairs are most of the graph on a
  # large field (`outside_edge_weight/6`), and every term of their weight but
  # the soft rung's is a sum of one term per player - the completion rung's
  # `!isByeCandidate` bits, C8's place of the higher player, C9's unplayed
  # ranks - so the weight is
  #
  #     reserve * (base * S0 + e(x) * S0 + e(y) * S0 + u(x) * S9 + u(y) * S9
  #                + [reach 1] (S8p + place(x) * S8s) + [not soft] S_soft)
  #
  # with `S` the suffix products `outside_layout/2` reads off the ladder:
  # the integer `outside_edge_weight/6` computes, multiplied out. Legality is
  # the same lookups as `legal_pair?/2` and `colour_compatible?/2`, asked of
  # the better-placed player as they are there, with the player's played
  # opponents, forbidden set and absolute colour read once. A pair inside
  # the bracket goes to `bracket_edge_weight/8` itself. `nil` for no edge.
  defp pair_weigher(arr, m, sgb, nsgb, scored, ctx, bands, single_bye?) do
    layout = ctx.outside
    suffix = layout.suffix
    reserve = bands.reserve
    reach = reach_table(arr, m, nsgb)
    reach_t = List.to_tuple(for j <- 0..(scored - 1)//1, do: Map.get(reach, j, 0))
    forbidden = Process.get(@forbidden_key)
    soft = Process.get(@soft_key)

    base_c =
      case env_flag(@env_completion_key, "AINALRAMI_COMPLETION") do
        "eligibility" -> 0
        _ -> 1
      end

    s0 = elem(suffix, 0) * reserve
    s8p = elem(suffix, layout.c8_pairs) * reserve
    s8s = elem(suffix, layout.c8_scores) * reserve
    s9 = elem(suffix, layout.c9) * reserve
    soft_s = if layout.soft != nil, do: elem(suffix, layout.soft) * reserve
    const = base_c * s0

    facts =
      List.to_tuple(
        for i <- 0..(scored - 1)//1 do
          p = elem(arr, i)
          stats = p.colour_stats
          own = bit(not bye_candidate?(p, ctx.bye_score)) * s0
          own = if single_bye?, do: own + unplayed_rank(p, ctx) * s9, else: own

          c8 =
            case Map.get(bands.places, p.points) do
              nil -> nil
              place -> s8p + place * s8s
            end

          pref = if stats.absolute? and not is_nil(stats.preference), do: stats.preference
          forbidden_set = if forbidden, do: Map.get(forbidden, p.rank)
          soft_set = if soft, do: Map.get(soft.map, p.rank)
          {p.rank, met_set(p), forbidden_set, pref, own, c8, soft_set}
        end
      )

    fn x, y ->
      cond do
        y < sgb ->
          nil

        elem(reach_t, y) == 0 ->
          bracket_edge_weight(elem(arr, x), elem(arr, y), y, sgb, 0, ctx, bands, single_bye?)

        true ->
          {_rank_x, met_x, forbidden_x, pref_x, own_x, c8_x, soft_x} = elem(facts, x)
          {rank_y, _met_y, _forbidden_y, pref_y, own_y, _c8_y, _soft_y} = elem(facts, y)

          if not forbids?(forbidden_x, rank_y) and not is_map_key(met_x, rank_y) and
               (pref_x == nil or pref_x != pref_y or
                  final_round_topscorers?(elem(arr, x), elem(arr, y))) do
            r = elem(reach_t, y)

            if r == 1 and c8_x == nil do
              # No place for the score: the exact computation, which refuses
              # it the same way.
              outside_edge_weight(elem(arr, x), elem(arr, y), r, ctx, bands, single_bye?)
            else
              w = const + own_x + own_y
              w = if r == 1, do: w + c8_x, else: w
              if soft_s != nil and not forbids?(soft_x, rank_y), do: w + soft_s, else: w
            end
          end
      end
    end
  end

  defp met_set(%{@facts_key => {met, _eligible, _played}}), do: met
  defp met_set(player), do: met_ranks(player)

  # The round's first field-graph bracket builds the round matcher from
  # every pair of the field. Its rows are built here with `base`, a row at a
  # time with both halves computed, and `new/3` takes them as `:adjacency` -
  # instead of `base` becoming an edge list that `new/3` folds back apart,
  # two map updates per edge (the trade `searched_bootstrap/9` measured).
  # Not where the bracket will run on its window alone (`window_setup/1`
  # builds its own matchers), nor with the transposition tie-break on,
  # whose weigher this does not reproduce.
  defp first_build_rows?(transposition, m, nsgb, wsgb) do
    big? = nsgb >= @window_min_bracket and m - wsgb >= @window_min_below

    window? =
      Process.get(@cert_key) == true and m > wsgb and rem(wsgb, 2) == 0 and nsgb >= 2 and
        (big? or cert_force?())

    transposition.scale == 1 and map_size(transposition.terms) == 0 and not window?
  end

  # `{base, rows}`: `base_edge_weights/8` over the whole field, and the
  # matcher's `%{u => %{v => 2w}}` for it - `w` what `edge_weigher/3` gives
  # the pair at field positions `u` and `v`, a vertex without a positive edge
  # left out - exactly what `new/3` builds from the list `solve_field/1`
  # makes of `base`. A pair's weight is computed from each end by the same
  # function on the same ordered pair, so the two rows agree.
  defp first_field_build(arr, field_pos, field_size, sgb, nsgb, ctx, bands, single_bye?) do
    m = tuple_size(arr)
    weight = pair_weigher(arr, m, sgb, nsgb, m, ctx, bands, single_bye?)
    p = field_size * field_size + 1
    half = div(nsgb, 2)

    # `edge_weigher/3` on the doubled scale, for `x < y` (`natural_gap/3`:
    # both in the bracket exactly when `y` is).
    doubled = fn y, fx, fy, w ->
      gap = if y < nsgb, do: half, else: 0
      2 * (w * p + field_size - abs(abs(fy - fx) - gap))
    end

    {rows, base} =
      Enum.reduce((m - 1)..0//-1, {[], []}, fn i, {rows, base} ->
        fi = elem(field_pos, i)

        {row, base} =
          Enum.reduce((m - 1)..(i + 1)//-1, {[], base}, fn j, {row, base} ->
            case weight.(i, j) do
              nil ->
                {row, base}

              w when w > 0 ->
                fj = elem(field_pos, j)
                {[{fj, doubled.(j, fi, fj, w)} | row], [{{i, j}, w} | base]}

              w ->
                {row, [{{i, j}, w} | base]}
            end
          end)

        row =
          Enum.reduce((i - 1)..0//-1, row, fn j, row ->
            case weight.(j, i) do
              w when is_integer(w) and w > 0 ->
                fj = elem(field_pos, j)
                [{fj, doubled.(i, fj, fi, w)} | row]

              _ ->
                row
            end
          end)

        case row do
          [] -> {rows, base}
          _ -> {[{fi, :maps.from_list(row)} | rows], base}
        end
      end)

    {:maps.from_list(base), :maps.from_list(rows)}
  end

  # How far BELOW the current bracket each position sits, counted in score
  # groups: 0 for the bracket itself, 1 for the next group, 2 for the one
  # after it, and so on.
  #
  # bbpPairings needs no such thing, because its graph stops at the next
  # group and `lowerPlayerInNextBracket` can only mean that one group. The
  # peek budget broke that equivalence: with several groups visible, a
  # plain "is the partner below?" bit scores a float that lands in the
  # very next group exactly the same as one that falls three groups. C8 is
  # about the FOLLOWING bracket specifically, so distance has to be graded.
  defp reach_table(_arr, m, nsgb) when nsgb >= m, do: %{}

  defp reach_table(arr, m, nsgb) do
    nsgb..(m - 1)//1
    |> Enum.reduce({%{}, 1, nil}, fn j, {acc, d, prev} ->
      points = elem(arr, j).points
      d = if prev != nil and points != prev, do: d + 1, else: d
      {Map.put(acc, j, d), d, points}
    end)
    |> elem(0)
  end

  defp bracket_edge_weight(a, b, j, sgb, reach, ctx, bands, single_bye?) do
    # dutch.cpp:607 - no edge unless the LARGER index is a resident or
    # lower, which is what stops two MDPs being paired with each other.
    if j >= sgb and legal_pair?(a, b) and colour_compatible?(a, b) do
      if reach == 0 do
        # `ranked/1` over the rungs, folded straight off the labelled list
        # rather than through an intermediate `{value, span}` copy of it.
        a
        |> edge_rungs(b, reach, ctx, bands, single_bye?)
        |> Enum.reduce(0, fn {_label, value, span}, acc -> acc * span + value end)
        |> Kernel.*(bands.reserve)
      else
        outside_edge_weight(a, b, reach, ctx, bands, single_bye?)
      end
    end
  end

  # The same integer as the fold above, for a pair outside the bracket.
  #
  # `ladder_rungs/6` gates every rung but five on `in_current`, which is
  # false here: the completion rung, the soft rung when there is one, the
  # two C8 rungs (non-zero at reach 1 only) and C9 (non-zero on a C9
  # bracket only). The fold `acc * span + value` over the whole ladder is
  # `sum(value_k * suffix_k)`, so with every other value zero it is those
  # five terms and nothing else - three or four bignum products where the
  # fold made eighteen, and none of the ladder's criteria computed only to
  # be multiplied by zero. That is most of the graph: on the round's first
  # field bracket every pair more than one score group below the bracket is
  # one of these, forty thousand of them at 300 players.
  #
  # Each term is computed by the very expression `ladder_rungs/6` uses for
  # it; `outside_layout/2` supplies where it sits.
  defp outside_edge_weight(a, b, reach, ctx, bands, single_bye?) do
    layout = ctx.outside
    suffix = layout.suffix
    {_label, completion, _span} = completion_rung(a, b, ctx, bands.count_span)
    weight = completion * elem(suffix, 0)

    weight =
      case layout.soft do
        nil -> weight
        at -> weight + bit(not soft_pair?(a, b)) * elem(suffix, at)
      end

    weight =
      if reach == 1 do
        place = Map.fetch!(bands.places, a.points)
        weight + elem(suffix, layout.c8_pairs) + place * elem(suffix, layout.c8_scores)
      else
        weight
      end

    weight =
      if single_bye?,
        do: weight + c9_rank(a, b, ctx) * elem(suffix, layout.c9),
        else: weight

    weight * bands.reserve
  end

  # The ladder itself, as LABELLED rungs highest-priority first, so the
  # same definition serves both the matcher (packed by `ranked/1`) and
  # `explain_round/3`, which needs to say WHICH criterion two pairings
  # part company on. Keeping one definition is the point: a diagnostic
  # that scored a reimplementation of the criteria would only ever tell
  # you whether the two implementations agreed.
  #
  # `a` is the higher-placed player of the pair, `b` the lower.
  # The FIDE ladder, plus - only when a caller asked for it - the soft rung.
  # Every consumer of the ladder (the matcher's weights, `explain_round/3`'s
  # report) goes through here, so a soft constraint shows up in the report
  # exactly where it changed the decision.
  defp edge_rungs(a, b, reach, ctx, bands, single_bye?) do
    a |> ladder_rungs(b, reach, ctx, bands, single_bye?) |> soften(a, b)
  end

  # ---------------------------------------------------------------------
  # Soft constraints
  # ---------------------------------------------------------------------
  #
  # A soft pair is one the arbiter would rather not see - two players from
  # the same club in round one, a parent and child - but will accept if the
  # alternative is worse. It is not a FIDE concept. C.04.3 knows absolute
  # criteria and quality criteria and nothing in between, so this is an
  # explicit departure from the Dutch system, and a tournament that uses it
  # is not a Dutch-system tournament in the homologation sense. It exists
  # for the youth and club events where that trade is the right one.
  #
  # Mechanically it is one more rung on the ladder: 1 when the pair is
  # fine, 0 when it is one to avoid, so the matcher prefers avoiding it
  # exactly as it prefers any other criterion. WHERE the rung sits is the
  # arbiter's choice:
  #
  #   :strong  right after the bye-eligibility rung, i.e. above C6. The
  #            engine would rather float a player than seat the pair - which
  #            is what "club protection" means in practice.
  #   :weak    after C21. It breaks ties and nothing else.
  #
  # When no soft pairs are given the ladder is returned untouched, so the
  # engine's FIDE behaviour is preserved byte for byte - the comparison
  # corpus is the proof, since it runs without soft pairs.
  defp soft_map(opts, round) do
    case opts[:soft_pairs] do
      nil ->
        nil

      [] ->
        nil

      groups ->
        case forbidden_map(groups, round) do
          nil -> nil
          map -> %{map: map, position: opts[:soft_position] || :strong}
        end
    end
  end

  defp soft_pair?(a, b) do
    case Process.get(@soft_key) do
      nil -> false
      %{map: map} -> map |> Map.get(a.rank) |> forbids?(b.rank)
    end
  end

  defp soften(rungs, a, b) do
    case Process.get(@soft_key) do
      nil ->
        rungs

      %{position: position} ->
        rung = {"S soft avoid", bit(not soft_pair?(a, b)), 2}

        # Only these two: `validate_opt!/2` refuses any other
        # `:soft_position` before a round starts. This was `_strong` and took
        # everything that was not `:weak`.
        case position do
          :weak -> rungs ++ [rung]
          :strong -> List.insert_at(rungs, 1, rung)
        end
    end
  end

  defp ladder_rungs(a, b, reach, ctx, bands, single_bye?) do
    in_current = reach == 0
    s = bands.count_span

    place = Map.fetch!(bands.places, a.points)

    # C8 is about the FOLLOWING bracket, singular. bbpPairings' graph
    # stops at the next score group, so its `lowerPlayerInNextBracket`
    # can only ever mean that one group - including for pairs formed
    # wholly inside it, which genuinely are "pairs in the next bracket".
    #
    # The peek budget broke that equivalence in a way grading by distance
    # did not fix. With several groups visible, pairs formed THREE groups
    # down were still scoring on C8, and there are many more of those than
    # there are real downfloat placements, so they swamped the signal:
    # nearly every candidate matching carried the same large C8 total and
    # the rung stopped discriminating. Traced on seed127-r5-p13, where the
    # engine floated a player who then had to fall two groups while
    # bbpPairings floated one who landed in the next.
    #
    # So the deeper groups stay VISIBLE - the matcher still needs to know
    # those players exist, which is what the peek was for - but only the
    # immediate next group counts toward C8. Anything further is re-decided
    # in a later bracket anyway, and C8 has nothing to say about it.
    scores_c8? = reach == 1
    nearness = bit(scores_c8?)

    # C10-C21 are all gated on `in_current` below, so for a pair outside the
    # bracket - most of the graph, on a large field - every one of them is
    # zero whatever the criteria say. They are not computed there: the
    # placeholders are never read, since `gate` answers 0 without looking.
    {c1, c2, c3, c4} =
      if in_current, do: colour_criteria(a, b), else: {false, false, false, false}

    {f1, f2, f3, f4} = if in_current, do: float_criteria(a, b), else: {0, 0, 0, 0}

    {s18, s19, s20, s21} =
      if in_current,
        do: float_score_criteria(a, b, %{score_place: bands.places}),
        else: {0, 0, 0, 0}

    gate = fn value, on? -> if on?, do: value, else: 0 end

    [
      # C4 completion + C2/C5 bye eligibility. `isByeCandidate` is
      # `eligibleForBye AND score <= byeAssigneeScore` - pairing someone
      # who may NOT take the bye is preferred, so whoever is left over
      # is someone the absolute criteria allow.
      #
      # The leading `1` is what makes this rung count EDGES, and on an
      # even field (where the rest is constant) that is all it does. Since
      # it outranks C6, it makes the matcher trade an internal pair for
      # two cross-bracket ones whenever that yields more edges - and
      # `test/fixtures/open_questions/` shows bbpPairings does NOT do
      # that. `completion_rung/3` is where that is measured.
      completion_rung(a, b, ctx, s),
      # C6, then C7 graded by which score group got paired.
      {"C6 pairs in bracket", bit(in_current), s},
      {"C7 scores paired", gate.(place, in_current), bands.place_span},
      # C8, the same two rungs one bracket down - but graded by how far
      # down, since the peek budget makes several groups visible at once.
      {"C8 pairs next bracket", nearness, s},
      {"C8 scores next bracket", gate.(place, scores_c8?), bands.place_span},
      {"C9 bye unplayed games", gate.(c9_rank(a, b, ctx), single_bye?), s * s},
      # C10-C13, `insertColorBits`.
      {"C10 topscorer colour diff", gate.(bit(c1), in_current), s},
      {"C11 topscorer same colour x3", gate.(bit(c2), in_current), s},
      {"C12 colour preference", gate.(bit(c3), in_current), s},
      {"C13 strong colour preference", gate.(bit(c4), in_current), s},
      # C14-C17.
      {"C14 downfloat repeat r-1", gate.(f1, in_current), 2 * s},
      {"C15 upfloat repeat r-1", gate.(f2, in_current), s},
      {"C16 downfloat repeat r-2", gate.(f3, in_current), 2 * s},
      {"C17 upfloat repeat r-2", gate.(f4, in_current), s},
      # C18-C21.
      {"C18 downfloat scores r-1", gate.(s18, in_current), bands.place_span},
      {"C19 upfloat scores r-1", gate.(s19, in_current), bands.place_span},
      {"C20 downfloat scores r-2", gate.(s20, in_current), bands.place_span},
      {"C21 upfloat scores r-2", gate.(s21, in_current), bands.place_span}
    ]
  end

  # dutch.cpp:276 reads `1u + !isByeCandidate(higher) + !isByeCandidate(lower)`.
  #
  #   default        the C++ verbatim - the leading 1 makes it count edges
  #   "eligibility"  drop the leading 1, so the rung expresses only the
  #                  bye preference and leaves C6 to decide pair counts
  #
  # This briefly diverged from the literal text. On an even field the
  # bye-eligibility part is constant, so the leading 1 makes the rung
  # purely an edge count - and since it outranks C6 it will trade an
  # internal pair for two cross-bracket ones to gain an edge, which
  # `test/fixtures/open_questions/` catches bbpPairings NOT doing.
  # Dropping the 1 was worth +0.18 exact rounds at the time.
  #
  # The peek-budget fix then superseded it. Once brackets can see far
  # enough to evaluate C8 (see `peek_budget/0`), the two forms measure
  # IDENTICALLY - 95.97% / 98.64% without byes and 86.70% / 96.48% at an
  # 8% bye rate, byte for byte - so the divergence bought nothing and the
  # verbatim reading is back. The anomaly was never about this rung; it
  # was about what the bracket could see.
  defp completion_rung(a, b, ctx, s) do
    eligibility =
      bit(not bye_candidate?(a, ctx.bye_score)) + bit(not bye_candidate?(b, ctx.bye_score))

    case env_flag(@env_completion_key, "AINALRAMI_COMPLETION") do
      "eligibility" -> {"C2/C5 bye-eligibility", eligibility, 3 * s}
      _ -> {"C2/C4/C5 bye-eligibility", 1 + eligibility, 3 * s}
    end
  end

  # `isByeCandidate` (dutch.cpp:213) is `eligibleForBye AND score <=
  # byeAssigneeScore`, and bbpPairings only ever computes a real
  # `byeAssigneeScore` for an ODD field - for an even one it stays at its
  # zero initialiser (dutch.cpp:822). So on an even field the test is
  # `score <= 0`, false for anyone who has scored at all, and the rung
  # collapses to a constant 3 per edge: pure "maximise the number of
  # pairs", which is what the completion criterion wants.
  #
  # Treating a nil bye score as "no score test" instead made the rung VARY
  # on even fields - an edge touching someone who had already taken a bye
  # outscored one that did not - so the top rung of the whole ladder was
  # quietly expressing a preference bbpPairings does not have, above C6.
  defp bye_candidate?(player, nil), do: eligible_for_bye?(player) and player.points <= 0

  defp bye_candidate?(player, bye_score) do
    eligible_for_bye?(player) and player.points <= bye_score
  end

  defp c9_rank(a, b, ctx) do
    unplayed_rank(a, ctx) + unplayed_rank(b, ctx)
  end

  defp unplayed_rank(player, ctx) do
    if player.points == ctx.bye_score,
      do: Map.get(ctx.unplayed_ranks, played_games(player), 0),
      else: 0
  end

  ## ---------- stage 1: which MDPs get paired (dutch.cpp 1091-1205) ----------

  # Walks the moved-down players in rank order and, for each one the
  # current matching has NOT placed inside the bracket, nudges its edges
  # to residents and RE-SOLVES, keeping the result only if the MDP is now
  # paired. That is the ordering guarantee a lone matching cannot give:
  # among equally-optimal matchings, the better-ranked MDPs are the ones
  # that get paired.
  #
  # The two early exits are what the previous port was missing. Counting
  # how many of a score group CAN be matched (`matched_left`) lets the
  # loop skip the expensive re-solve entirely when the answer is already
  # forced - either none of them can be paired, or all of the ones left
  # will be.
  defp stage_select_mdps(%{sgb: 0} = st), do: st

  defp stage_select_mdps(st) do
    {st, _, _, _} =
      Enum.reduce(0..(st.sgb - 1), {st, nil, 0, 0}, fn i, {st, group, remaining, matched_left} ->
        {group, remaining, matched_left} =
          if is_nil(group) or elem(st.arr, i).points < group,
            do: count_mdp_group(st, i),
            else: {group, remaining, matched_left}

        cond do
          matched_left == 0 ->
            {st, group, remaining, matched_left}

          # Every MDP still to process in this group is matched internally, so
          # they can be committed without re-deriving it - `matched_left` can
          # never exceed `remaining`, so this arm only fires when the two are
          # equal.
          #
          # `internal?/2` is checked anyway, and that is not belt-and-braces.
          # `matched_left` is counted once when the group is entered, while
          # `nudge_mdp_edges/2` below re-solves the matching mid-loop and can
          # move a LATER member of the same group out of the bracket - after
          # which the count is stale and this arm would freeze an MDP against
          # a partner in the next score group. The invariant was previously
          # held only by `collect_bracket/1`'s `p < st.nsgb` guard, a
          # downstream filter documented as this port's own addition rather
          # than bbpPairings'. Enforced at the decision instead.
          remaining <= matched_left and internal?(st, i) ->
            {%{st | matched: MapSet.put(st.matched, i)}, group, remaining - 1, matched_left - 1}

          true ->
            st = if internal?(st, i), do: st, else: nudge_mdp_edges(st, i)

            if internal?(st, i) do
              {st |> Map.update!(:matched, &MapSet.put(&1, i)) |> freeze_mdp_edges(i), group,
               remaining - 1, matched_left - 1}
            else
              {st, group, remaining - 1, matched_left}
            end
        end
      end)

    st
  end

  # How many MDPs share this one's score, and how many of them the current
  # matching already places inside the bracket. The scan stops at the
  # first lower score, which is the first resident - moved-down players
  # are by definition higher-scored than the group they landed in.
  defp count_mdp_group(st, from) do
    score = elem(st.arr, from).points
    members = Enum.take_while(from..(st.m - 1)//1, &(elem(st.arr, &1).points >= score))
    {sgb, nsgb} = {st.sgb, st.nsgb}
    matched_left = certified_count(st, members, :internal, fn _k, p -> p >= sgb and p < nsgb end)
    {score, length(members), matched_left}
  end

  # dutch.cpp:1168 `edgeWeight |= 1u` - the smallest bump there is, enough
  # to break a tie in favour of using this edge and far too small to
  # outrank any criterion.
  defp nudge_mdp_edges(st, mdp) do
    live =
      Enum.reduce(st.sgb..(st.nsgb - 1)//1, st.live, fn opp, acc ->
        case get_w(st.base, mdp, opp) do
          0 -> acc
          w -> set_live(acc, mdp, opp, w + 1)
        end
      end)

    solve(%{st | live: live})
  end

  # dutch.cpp:1196. Once an MDP is committed to being paired here, its
  # resident edges are lifted clear of the plain nudge so a later MDP's
  # re-solve cannot quietly drop it again.
  defp freeze_mdp_edges(st, mdp) do
    bump = st.nsgb - st.sgb + 1

    live =
      Enum.reduce(st.sgb..(st.nsgb - 1)//1, st.live, fn opp, acc ->
        case get_w(st.base, mdp, opp) do
          0 -> acc
          w -> set_live(acc, mdp, opp, w + bump)
        end
      end)

    %{st | live: live}
  end

  ## ---------- stage 2: who each MDP plays (dutch.cpp 1207-1255) ----------

  # Stage 1 settled WHETHER each moved-down player is paired; this settles
  # WITH WHOM, one player at a time, highest-ranked opponent first. The
  # ascending addend runs over the candidate opponents from the bottom up,
  # so the best-ranked available resident carries the largest bump.
  defp stage_mdp_opponents(%{sgb: 0} = st), do: st

  defp stage_mdp_opponents(st) do
    Enum.reduce(0..(st.sgb - 1), st, fn mdp, st ->
      if MapSet.member?(st.matched, mdp) do
        st |> prefer_high_opponents(mdp) |> solve() |> finalize_matched(mdp)
      else
        st
      end
    end)
  end

  # dutch.cpp:1218 seeds the addend with `playersByIndex.size()` - the
  # bracket plus the next score group, i.e. `wsgb`, NOT the size of the
  # whole graph. It used to read `st.m`, which was the same order of
  # magnitude while the graph stopped a few groups down and is not now that
  # the graph is the whole remaining field.
  defp prefer_high_opponents(st, mdp) do
    {live, _} =
      Enum.reduce((st.nsgb - 1)..st.sgb//-1, {st.live, st.wsgb}, fn opp, {acc, addend} ->
        if MapSet.member?(st.matched, opp) do
          {acc, addend}
        else
          case get_w(st.base, mdp, opp) do
            0 -> {acc, addend}
            w -> {set_live(acc, mdp, opp, w + addend), addend + 1}
          end
        end
      end)

    %{st | live: live}
  end

  defp finalize_matched(st, i) do
    case certified_partner(st, i) do
      ^i -> st
      p -> st |> Map.update!(:matched, &MapSet.put(&1, p)) |> finalize_pair(i, p)
    end
  end

  ## ---------- stages 3-4: the remainder (dutch.cpp 1257-1318) ----------

  # What is left of the score group once the moved-down players and their
  # opponents are settled. `remainder_pairs` splits it into FIDE's S1 and
  # S2: the first `remainder_pairs` entries are the higher half, the rest
  # the lower half, and pairing them is the homogeneous-bracket problem.
  defp stage_build_remainder(st) do
    sgb = st.sgb

    remainder =
      Enum.filter(sgb..(st.nsgb - 1)//1, &certified(st, &1, :resident, fn p -> p >= sgb end))

    %{
      st
      | remainder: remainder,
        remainder_pairs: certified_count(st, remainder, :earlier, fn v, p -> p < v end)
    }
  end

  defp stage_exchange_weights(%{remainder: []} = st), do: st

  defp stage_exchange_weights(st) do
    changes =
      for opp <- st.remainder,
          {p, idx} <- st.remainder |> Enum.take_while(&(&1 < opp)) |> Enum.with_index(),
          do: {p, opp, idx, exchange_weight(st, p, opp, idx)}

    case exchange_by_dual_shift(st, changes) do
      {:ok, st} ->
        solve(st)

      :no ->
        live =
          Enum.reduce(changes, st.live, fn {p, opp, _, w}, acc -> set_live(acc, p, opp, w) end)

        # The shape the exchange weights reward, offered to a certified
        # install as a second guess besides the matching already held: the
        # shift fails exactly when that matching is not in this shape.
        solve(%{st | live: live, guess: canonical_remainder_pairs(st)})
    end
  end

  # S1[k] against S2[k] over the remainder, as `{remainder members, pairs}`.
  defp canonical_remainder_pairs(st) do
    {s1, s2} = Enum.split(st.remainder, st.remainder_pairs)
    {st.remainder, Enum.zip(s1, s2)}
  end

  # Stage 4 rewrites every remainder pair's weight, which through
  # `set_live/4` prepares every remainder vertex and makes the next solve
  # rediscover the matching from nothing -- 372 stages and 2.7 s of a
  # 1,000-player round, for a step that almost always returns the matching
  # it was given. It returns it because of how the change is shaped: pair
  # (p, opp) with p < opp moves by `2 * c(p)`, a per-vertex amount on the
  # SMALLER side, with c >= 0 for the first half of the remainder and
  # c <= 0 for the second. When the current matching already pairs first
  # half against second half -- every pair one of each, the odd one out
  # from the second half -- raising each first-half vertex's dual by its
  # own `2 * c(p)` (doubled scale) absorbs the change exactly: a first-to-
  # second pair's slack is unchanged and stays tight; a first-to-first
  # pair's slack rises by the other member's c; a second-to-second pair's
  # slack rises by minus its own c. Nothing is unmatched, so the state is
  # still optimal and `solve/1` has nothing to do. `shift_and_set/3`
  # checks the invariants it relies on and refuses otherwise -- including
  # when a remainder vertex sits inside a blossom, which it dissolves
  # first -- and a refusal, or a matching not in that shape, takes the
  # old path.
  #
  # Why the stages after this one answer the same as after a re-solve,
  # which may land on a different matching of the same weight: what they
  # read from the matching is whether a player is paired down, and every
  # such read is one the weights decide. Stage 4's guard term makes the
  # number of exchanges the same in every optimum; stages 5 and 6 ask
  # each player's question with a one-unit nudge on even weights, so the
  # answer is "is there an optimum where this player is (not) paired
  # down", whichever optimum the matcher holds; each answer is committed
  # by cutting edges no optimum still uses, so the matcher's matching
  # stays optimal and the next question is asked of the same weights;
  # and stage 8 fixes one partner at a time with addends distinct per
  # opponent, which no tie can split. What the weights do NOT decide is
  # the tentative matching of the field below the bracket, which the next
  # bracket reads (`carried_partner_scores`) and the round matcher carries.
  # So on the field graph the shift is taken only when there is no field
  # below: the bracket is everything left of the round. That argument is
  # the reason to expect no change; the differential corpus against
  # v0.33.0 (docs/performance.md) is the check that there is none.
  defp exchange_by_dual_shift(%{mode: :local} = st, changes) do
    if shaped_for_shift?(st, false) do
      weigh = edge_weigher(st, & &1, st.m)
      {shifts, edges} = shift_terms(st, changes, weigh, & &1)

      case WeightedMatching.shift_and_set(st.wm, shifts, edges) do
        {:ok, wm} -> {:ok, %{st | wm: wm, live: put_changes(st.live, changes)}}
        :error -> :no
      end
    else
      :no
    end
  end

  # The field graph, when the bracket is everything left of the round:
  # the same shift on the round matcher, at field positions. With nothing
  # below the bracket, the only vertices outside it are players already
  # finalised, whose edges are gone, so the argument above holds on this
  # graph exactly as on the local one. The matcher must be the one the
  # last solve left -- `synced` and no queued writes -- since the shift
  # is checked against the matching that solve returned. A second-half
  # member may be unmatched here, where the local graph pairs it with the
  # stand-in: its own dual is not shifted, and none of its edges loses
  # slack (an edge from the first half gains exactly what that end's dual
  # does; one from the second half only loses weight).
  #
  # With a field below, the same shift is taken only in certified mode, and
  # taking it taints the round: the reads that follow are then certified
  # (see "certified shortcuts") rather than argued.
  defp exchange_by_dual_shift(%{mode: :field, synced: true} = st, changes) do
    {matcher, field_index, field_size} = Process.get(@round_matcher_key)
    whole? = st.nsgb == st.m

    if matcher != nil and (whole? or Process.get(@cert_key) == true) and
         Process.get(@dirty_key, []) == [] and shaped_for_shift?(st, true) do
      to_field = field_positions(st, field_index)
      {shifts, edges} = shift_terms(st, changes, edge_weigher(st, to_field, field_size), to_field)

      case WeightedMatching.shift_and_set(matcher, shifts, edges) do
        {:ok, matcher} ->
          if not whole? do
            taint!()
            cert_count(:exchange_shift_ok)
          end

          Process.put(@round_matcher_key, {matcher, field_index, field_size})
          {:ok, %{st | live: put_changes(st.live, changes)}}

        :error ->
          if not whole?, do: cert_count(:exchange_shift_refused)
          :no
      end
    else
      :no
    end
  end

  defp exchange_by_dual_shift(_st, _changes), do: :no

  # Every first-half member paired with a second-half member; a second-
  # half member may be paired outside the remainder (the odd one floats),
  # or - on the field graph, `unmatched_ok?` - with nobody.
  defp shaped_for_shift?(st, unmatched_ok?) do
    s1 = st.remainder |> Enum.take(st.remainder_pairs) |> MapSet.new()
    remainder = MapSet.new(st.remainder)

    Enum.all?(st.remainder, fn v ->
      p = partner(st, v)

      cond do
        MapSet.member?(s1, v) -> MapSet.member?(remainder, p) and not MapSet.member?(s1, p)
        p == v -> unmatched_ok?
        true -> not MapSet.member?(remainder, p) or MapSet.member?(s1, p)
      end
    end)
  end

  # Each first-half member's dual shift and every changed edge, as the
  # matcher sees them: `weigh` puts a `live` weight on the matcher's
  # scale and `to_matcher` a bracket index in the matcher's numbering.
  defp shift_terms(st, changes, weigh, to_matcher) do
    s = st.bands.count_span

    shifts =
      for {p, idx} <- st.remainder |> Enum.take(st.remainder_pairs) |> Enum.with_index(),
          into: %{},
          do:
            {to_matcher.(p), 2 * (weigh.(p, p + 1, 1 + 2 * (s * s - idx)) - weigh.(p, p + 1, 1))}

    edges =
      for {p, opp, _, w} <- changes, do: {to_matcher.(p), to_matcher.(opp), weigh.(p, opp, w)}

    {shifts, edges}
  end

  defp put_changes(live, changes),
    do: Enum.reduce(changes, live, fn {p, opp, _, w}, acc -> put_w(acc, p, opp, w) end)

  # dutch.cpp:1055-1085. Two objectives, lexicographically: first keep the
  # pair inside its own half of the remainder (minimise the number of
  # exchanges), then prefer the smaller position (minimise the difference
  # of the exchanged branch scoring numbers).
  #
  # The `- remainder_index` runs off the end of the guard bit when that
  # bit is clear, which is where the negative addend discussed at the top
  # of this section comes from.
  defp exchange_weight(st, smaller, larger, remainder_index) do
    case get_w(st.base, smaller, larger) do
      0 ->
        0

      w ->
        s = st.bands.count_span
        w + (bit(remainder_index < st.remainder_pairs) * s * s - remainder_index) * 2
    end
  end

  ## ---------- stages 5-7: exchange selection (dutch.cpp 1320-1543) ----------

  defp stage_exchange_lower_from_higher(%{remainder: []} = st), do: st

  defp stage_exchange_lower_from_higher(st) do
    st = %{st | exchange_count: count_exchanges(st)}

    {st, _} =
      Enum.reduce_while(
        (st.remainder_pairs - 1)..0//-1,
        {st, st.exchange_count},
        fn pos, {st, left} ->
          if left == 0 do
            {:halt, {st, left}}
          else
            player = Enum.at(st.remainder, pos)
            opponents = Enum.drop(st.remainder, pos + 1)

            # Make this player's downward edges fractionally worse and ask
            # again: if the matcher now declines to pair them downward,
            # they are the one to exchange.
            st =
              if paired_down?(st, player) do
                live =
                  Enum.reduce(opponents, st.live, fn opp, acc ->
                    case exchange_weight(st, player, opp, pos) do
                      0 -> acc
                      w -> set_live(acc, player, opp, w - 1)
                    end
                  end)

                solve(%{st | live: live})
              else
                st
              end

            exchange = exchange_needed?(st, player)
            {:cont, {settle_exchange(st, player, pos, opponents, exchange), left - bit(exchange)}}
          end
        end
      )

    st
  end

  # How many of the higher half are not currently paired downward - the
  # number of exchanges the bracket has to make.
  defp count_exchanges(st) do
    case Enum.at(st.remainder, st.remainder_pairs) do
      nil ->
        0

      bound ->
        nsgb = st.nsgb
        first = Enum.take_while(st.remainder, &(&1 < bound))
        certified_count(st, first, :need, fn v, p -> p <= v or p >= nsgb end)
    end
  end

  # Either commit the exchange by cutting the player's edges to everyone
  # after them, or put the untouched weights back.
  defp settle_exchange(st, player, pos, opponents, exchange) do
    {base, live} =
      Enum.reduce(opponents, {st.base, st.live}, fn opp, {b, l} ->
        b = if exchange, do: put_w(b, player, opp, 0), else: b
        {b, set_live(l, player, opp, exchange_weight(%{st | base: b}, player, opp, pos))}
      end)

    %{st | base: base, live: live}
  end

  defp stage_exchange_higher_from_lower(%{remainder: []} = st), do: st

  defp stage_exchange_higher_from_lower(st) do
    {st, _} =
      Enum.reduce_while(
        st.remainder_pairs..(length(st.remainder) - 1)//1,
        {st, st.exchange_count},
        fn pos, {st, left} ->
          # dutch.cpp:1414 stops at one, not zero: the last exchange has
          # no partner left to swap with.
          if left <= 1 do
            {:halt, {st, left}}
          else
            player = Enum.at(st.remainder, pos)
            opponents = Enum.drop(st.remainder, pos + 1)
            already? = paired_down?(st, player)

            st = if already?, do: st, else: probe_upward(st, player, pos, opponents)
            exchange = paired_down?(st, player)
            st = if exchange, do: cut_exchanged(st, player, pos), else: st
            st = if already?, do: st, else: restore_probe(st, player, pos, opponents)

            {:cont, {st, left - bit(exchange)}}
          end
        end
      )

    st
  end

  # The mirror of stage 5's probe: sweeten rather than sour, and ask
  # whether the matcher will now pair this lower-half player downward.
  defp probe_upward(st, player, pos, opponents) do
    live =
      Enum.reduce(opponents, st.live, fn opp, acc ->
        case exchange_weight(st, player, opp, pos) do
          0 -> acc
          w -> set_live(acc, player, opp, w + 1)
        end
      end)

    solve(%{st | live: live})
  end

  defp restore_probe(st, player, pos, opponents) do
    live =
      Enum.reduce(opponents, st.live, fn opp, acc ->
        set_live(acc, player, opp, exchange_weight(st, player, opp, pos))
      end)

    %{st | live: live}
  end

  # A player promoted out of the lower half can no longer play anyone
  # ABOVE them in the remainder, nor anyone in the next score group -
  # dutch.cpp:1473-1484 cuts both sets of edges from the base weights,
  # permanently. The second set is `nextScoreGroupBegin ..
  # playersByIndex.size()`, i.e. the next score group EXACTLY: players
  # further down are outside the window and keep their edges, so the
  # bound is `wsgb`, not the size of the graph.
  defp cut_exchanged(st, player, pos) do
    cuts = Enum.take(st.remainder, pos) ++ Enum.to_list(st.nsgb..(st.wsgb - 1)//1)

    {base, live} =
      Enum.reduce(cuts, {st.base, st.live}, fn opp, {b, l} ->
        {put_w(b, player, opp, 0), set_live(l, player, opp, 0)}
      end)

    %{st | base: base, live: live}
  end

  # dutch.cpp:1509. Drop every edge inconsistent with the exchange pattern
  # just chosen, and put the live weights back to their (now edited) base
  # so the reserved bits the probes used are clear again.
  defp stage_reset_exchange_bits(%{remainder: []} = st), do: st

  defp stage_reset_exchange_bits(st) do
    {base, live} =
      st.remainder
      |> Enum.with_index()
      |> Enum.reduce({st.base, st.live}, fn {player, pos}, acc ->
        st.remainder
        |> Enum.drop(pos + 1)
        |> Enum.reduce(acc, fn opp, {b, l} ->
          b =
            if exchange_needed?(st, player) or paired_down?(st, opp),
              do: put_w(b, player, opp, 0),
              else: b

          {b, set_live(l, player, opp, get_w(b, player, opp))}
        end)
      end)

    st = %{st | base: base, live: live}

    # Taking the exchange weights off again moves every pair by its smaller
    # member's addend, so lowering (or, in the second half, raising) each
    # paired-down member's dual by the addend its own pair loses keeps the
    # matched pairs tight -- and every edge the reset leaves in place runs
    # from a paired-down player to one who is not, whose slack that shift
    # leaves exactly as it was. Where that holds the next solve would find
    # nothing to do; see `shift_to_live/5`, and `exchange_by_dual_shift/2`
    # for why the stages that follow cannot tell the difference.
    down = Enum.filter(st.remainder, &raw_paired_down?(st, &1))

    case with_shiftable_matcher(st, &shift_to_live(st, down, &1, &2, &3)) do
      {:ok, st} -> st
      :no -> st
    end
  end

  ## ---------- stage 8: partners for the higher half (dutch.cpp 1545-1599) ----------

  defp stage_first_group_partners(st) do
    Enum.reduce(st.remainder, st, fn player, st ->
      if paired_down?(st, player) do
        st = prefer_high_remainder(st, player)

        case keep_partner_by_dual_shift(st, player) do
          {:ok, st} -> finalize_both(st, player)
          _ -> st |> solve() |> finalize_both(player)
        end
      else
        st
      end
    end)
  end

  # The same move as stage 4's `exchange_by_dual_shift/2`, for one player.
  # `prefer_high_remainder/2` adds an addend to each of the player's edges,
  # the largest to the highest-ranked opponent, and the solve that follows
  # asks which partner the player gets. Raising the player's dual by the
  # addend its CURRENT partner got keeps that pair tight, and leaves every
  # other changed edge feasible exactly when no opponent with a larger
  # addend is within reach -- `shift_and_set/3` checks that edge by edge
  # and refuses otherwise. When it holds, the current matching is optimal
  # for the new weights, and since the addends are distinct and sit below
  # every criterion, every optimum gives the player the same partner: the
  # one the solve would have returned, found without the search.
  #
  # On the field graph the matching the player's partner is then read from
  # is the one the shift kept, optimal for the shifted weights - so that is
  # the state a certified read of it is checked against.
  defp keep_partner_by_dual_shift(st, player) do
    with_shiftable_matcher(st, fn matcher, to_matcher, weigh ->
      shift_to_live(st, [player], matcher, to_matcher, weigh)
    end)
    |> case do
      {:ok, %{mode: :field} = st} ->
        {matcher, _, _} = Process.get(@round_matcher_key)
        {:ok, %{st | snap: {matcher, make_ref()}}}

      other ->
        other
    end
  end

  # Where a dual shift may stand in for a re-solve: the local graph, or the
  # field graph when the bracket is everything left of the round -- the
  # places `exchange_by_dual_shift/2` shifts, for the reason given there.
  # Hands `fun` the matcher, its vertex numbering and its weigher, and
  # keeps the matcher `fun` returns.
  defp with_shiftable_matcher(%{mode: :local, wm: wm} = st, fun) when wm != nil do
    # The local matcher has only the bracket (and the stand-in); `live`
    # also holds edges into the peek beyond it, which `solve_local/1`
    # skips and so does this.
    local = fn i -> if i < st.wl, do: i end

    case fun.(wm, local, edge_weigher(st, & &1, st.m)) do
      {:ok, wm} -> {:ok, %{st | wm: wm}}
      :error -> :no
    end
  end

  # With a field below, only in certified mode, and tainting the round - see
  # `exchange_by_dual_shift/2`.
  defp with_shiftable_matcher(%{mode: :field, synced: true} = st, fun) do
    whole? = st.nsgb == st.m

    case Process.get(@round_matcher_key) do
      {nil, _, _} ->
        :no

      {matcher, field_index, field_size} ->
        if whole? or Process.get(@cert_key) == true do
          to_field = field_positions(st, field_index)

          case fun.(matcher, to_field, edge_weigher(st, to_field, field_size)) do
            {:ok, matcher} ->
              if not whole? do
                taint!()
                cert_count(:shift_ok)
              end

              Process.put(@round_matcher_key, {matcher, field_index, field_size})
              {:ok, st}

            :error ->
              if not whole?, do: cert_count(:shift_refused)
              :no
          end
        else
          :no
        end
    end
  end

  defp with_shiftable_matcher(_st, _fun), do: :no

  # Bring the matcher's weights up to `live` -- every write queued since
  # the last solve, on the vertices the matcher has (`to_matcher` answers
  # nil for the rest) -- by moving the duals of `shifted` (each by what its
  # matched edge changed, so that edge stays tight) instead of preparing
  # the written vertices for a re-solve. `shift_and_set/3` then checks
  # what makes the unchanged matching optimal for the new weights: every
  # dual non-negative, every matched edge tight, every listed edge
  # feasible. A dual that goes DOWN can make an unwritten edge infeasible
  # too, so every edge of such a vertex is listed. Since 2026-10-02
  # `shift_and_set/3` checks those edges itself whether listed or not; they
  # are still listed here because listing an edge also makes its far end a
  # TOUCHED vertex, refused when it sits inside a blossom - and that refusal
  # is part of what the differential corpus pins. On success the queue
  # has been applied and is cleared.
  defp shift_to_live(st, shifted, matcher, to_matcher, weigh) do
    edges =
      Process.get(@dirty_key, [])
      |> Enum.map(fn {i, j} -> {min(i, j), max(i, j)} end)
      |> Enum.uniq()
      |> Enum.flat_map(fn {i, j} ->
        case {to_matcher.(i), to_matcher.(j)} do
          {nil, _} -> []
          {_, nil} -> []
          {fi, fj} -> [{fi, fj, weigh.(i, j, get_w(st.live, i, j))}]
        end
      end)

    shifts =
      Map.new(shifted, fn v ->
        q = partner(st, v)
        {fv, fq} = {to_matcher.(v), to_matcher.(q)}
        now = WeightedMatching.edge_weight(matcher, fv, fq)
        {fv, 2 * (weigh.(v, q, get_w(st.live, v, q)) - now)}
      end)

    listed = MapSet.new(edges, fn {a, b, _} -> {min(a, b), max(a, b)} end)

    kept =
      for {fv, d} <- shifts,
          d < 0,
          {fu, w} <- WeightedMatching.neighbours(matcher, fv),
          not MapSet.member?(listed, {min(fv, fu), max(fv, fu)}),
          do: {fv, fu, w}

    case WeightedMatching.shift_and_set(matcher, shifts, edges ++ kept) do
      {:ok, matcher} ->
        Process.delete(@dirty_key)
        {:ok, matcher}

      :error ->
        :error
    end
  end

  defp prefer_high_remainder(st, player) do
    {live, _} =
      st.remainder
      |> Enum.reverse()
      |> Enum.reduce({st.live, 0}, fn opp, {acc, addend} ->
        if opp <= player or MapSet.member?(st.matched, opp) do
          {acc, addend}
        else
          acc =
            case get_w(st.base, player, opp) do
              0 -> acc
              w -> set_live(acc, player, opp, w + addend)
            end

          # Incremented even when the edge was unusable, so the ordering
          # reflects rank rather than availability (dutch.cpp:1580).
          {acc, addend + 1}
        end
      end)

    %{st | live: live}
  end

  defp finalize_both(st, i) do
    case certified_partner(st, i) do
      ^i ->
        st

      p ->
        st
        |> Map.update!(:matched, &(&1 |> MapSet.put(i) |> MapSet.put(p)))
        |> finalize_pair(i, p)
    end
  end

  ## ---------- carry forward (dutch.cpp 1601-1649) ----------

  # A pairing proof's record of the pairs this bracket is about to publish
  # (`collect_bracket/1`'s own test, read the same way) and where they came
  # from: the matcher the bracket's matching was read off, its vertices, the
  # players. The verifier holds each to that matcher's proven matching.
  defp proof_read(st) do
    pairs =
      for i <- 0..(min(st.nsgb, st.m) - 1)//1,
          MapSet.member?(st.matched, i),
          p = partner(st, i),
          p != i and p < st.nsgb and i < p,
          do: {i, p}

    {matcher, vertex} =
      case st.mode do
        :field ->
          {matcher, field_index, _} = Process.get(@round_matcher_key)
          {matcher, field_positions(st, field_index)}

        _ ->
          {Map.get(st, :wm), & &1}
      end

    Ainalrami.Proof.read(
      matcher,
      Enum.map(pairs, fn {i, p} ->
        {vertex.(i), vertex.(p), elem(st.arr, i).rank, elem(st.arr, p).rank}
      end)
    )
  end

  defp collect_bracket(st) do
    if Ainalrami.Proof.recording?(), do: proof_read(st)

    {pairs, carried, sgb} =
      Enum.reduce(0..(st.m - 1)//1, {[], [], 0}, fn i, {pairs, carried, sgb} ->
        # Read only where the answer depends on it: a player who is not
        # `matched` carries forward whoever the matching has them with.
        matched? = i < st.nsgb and MapSet.member?(st.matched, i)
        p = if matched?, do: certified_partner(st, i), else: i

        # `p < st.nsgb` is this port's own guard, not bbpPairings'. Their
        # recording condition tests only the near end of the pair, which
        # would let an MDP that was flagged matched but ended up paired
        # into the NEXT score group be written out as a finalised pair
        # while its partner also carried forward. bbpPairings never
        # finalises a cross-bracket pair (see docs/engineering-log.md); this makes that
        # invariant explicit rather than relying on it.
        if matched? and p != i and p < st.nsgb do
          if i < p,
            do:
              {[assign_colour_with_history({elem(st.arr, i), elem(st.arr, p)}) | pairs], carried,
               sgb},
            else: {pairs, carried, sgb}
        else
          {pairs, [mark_float(elem(st.arr, i), i < st.nsgb) | carried], sgb + bit(i < st.nsgb)}
        end
      end)

    # dutch.cpp:1636-1643 needs, for each player carrying forward, the
    # score of whoever the tentative matching had them with - that is what
    # tells the NEXT bracket whether its downfloat runs deeper than one
    # group, and so whether C9 applies there at all. An unmatched carried
    # player constrains nothing, so they report their own score
    # (bbpPairings reads an unmatched vertex as matched to itself).
    #
    # The scan runs to `wsgb`, not `nsgb`: dutch.cpp:1613 loops over the
    # whole of `playersByIndex`, which is the bracket AND the next score
    # group, and every one of those that is not finalised here goes into
    # the next bracket and gets its tentative match checked. Members of the
    # next group are exactly the players who become residents next time, so
    # excluding them dropped the majority of the clearing signal.
    #
    # It stops there rather than running to `st.m`. Everything past `wsgb`
    # is graph-only lookahead that bbpPairings has no analogue for - its
    # window IS bracket-plus-next-group - and an earlier attempt that used
    # the full peek window here fixed one traced case and broke two others
    # (docs/engineering-log.md), which is what a too-wide scan looks like: players who are
    # nowhere near this decision clearing its gate.
    #
    # The scores are read by `bracket_loop/6`'s C9 gate and nothing else, and
    # only as "is every one at or above the next group's score", and only
    # when the gate's other conditions hold (`c9_gate_live?/4`). That one
    # answer is what a round in certified mode certifies - as a count of
    # tentative partners below that score, see `certified_count/4` - and
    # only when the gate can fire; a single player's tentative partner is
    # often genuinely tied, the answer seldom is.
    arr = st.arr
    score_of = fn q -> elem(arr, q).points end
    window = 0..(min(st.wsgb, st.m) - 1)//1

    partner_scores =
      window
      |> Enum.reduce([], fn i, acc ->
        if MapSet.member?(st.matched, i) do
          p = certified_partner(st, i)
          if p != i and p < st.nsgb, do: acc, else: [score_of.(p) | acc]
        else
          [score_of.(partner(st, i)) | acc]
        end
      end)
      |> Enum.reverse()

    if st.wsgb > st.nsgb and st.nsgb < st.m do
      next_points = elem(arr, st.nsgb).points

      # `c9_gate_live?/4`, on the bracket's own arrays.
      if st.ctx.odd_field? and not is_nil(st.ctx.bye_score) and st.ctx.bye_score >= next_points do
        open = Enum.reject(window, &MapSet.member?(st.matched, &1))

        certified_count(st, open, {:below, next_points}, fn _i, p ->
          score_of.(p) < next_points
        end)
      end
    end

    {Enum.reverse(pairs), Enum.reverse(carried), sgb, partner_scores}
  end

  # A current-bracket player who was not paired here IS a downfloater.
  # `mark_float(player, true)` used to stamp `:already_floated`, which was
  # `float_weight/1`'s heavy re-float penalty. That function is gone with the
  # per-bracket cascade, and nothing has read the key since - it cost an
  # allocation per carried player to record something no rule consults.
  defp mark_float(player, true), do: player
  defp mark_float(player, false), do: player
  # Returns `{bye assignee score | nil, isSingleDownfloaterTheByeAssignee}`.
  # The two come from the SAME bootstrap whole-field matching in
  # bbpPairings (dutch.cpp:818-870) and are returned together for the same
  # reason: the C9 gate's first-bracket value is a property of that
  # matching, not something recoverable afterwards. On an even field
  # bbpPairings never computes either (dutch.cpp:872's `else` branch sets
  # the flag `false` and leaves the score at its zero initialiser).
  defp bye_assignee_score(_brackets, 0), do: {nil, false}

  defp bye_assignee_score(brackets, _allowed_byes) do
    field =
      brackets
      |> List.flatten()
      |> Enum.sort_by(&{-&1.points, &1.rank})
      |> Enum.map(&ensure_colour_stats/1)

    n = length(field)

    # Found by a 100,000-tournament overnight run (PAIRING_FUZZ_BYE_PCT=15
    # - see docs/engineering-log.md): with n <= 1 there is at most one candidate, so
    # there's no pair to build an edge list over at all. The general path
    # below builds it as `0..(n - 2)`, which for n == 1 is `0..-1` -
    # Elixir's default step for a descending range walks `0, -1`, and
    # `elem(arr, -1)` raised ArgumentError instead of pairing (n == 1) or
    # doing nothing (n == 0). n == 1 is the reachable case in practice
    # (one genuine bye candidate left after everyone else resolved) -
    # trivially THEIR score, no matching needed. n == 0 shouldn't arise
    # given the `allowed_byes == 0` clause above already short-circuits
    # the no-candidates case, but costs nothing to make safe the same way
    # rather than assume it can't happen.
    if n <= 1 do
      case field do
        # One player, who takes the bye. They are also the whole top score
        # group and are matched to themselves, so dutch.cpp:851-870's scan
        # finds nothing below the top score and the flag stays `true`.
        [player] -> {player.points, true}
        [] -> {nil, false}
      end
    else
      bye_assignee_score_from_field(field, n)
    end
  end

  defp bye_assignee_score_from_field(field, n) do
    arr = List.to_tuple(field)
    {places, place_span} = score_places(field)
    max_place = places |> Map.values() |> Enum.max(fn -> 1 end)

    # Room for the eligibility term above the score term, and for a
    # cardinality term above both, so more pairs always wins.
    eligibility_unit = place_span
    edge_ceiling = 3 * eligibility_unit + 2 * max_place
    cardinality_unit = div(n, 2) * edge_ceiling + 1

    # dutch.cpp:782-786's THIRD packed field, which this port was missing
    # entirely: after the eligibility and score-group fields are shifted
    # up, the bottom `scoreGroupSizeBits` hold
    #
    #     player->scoreWithAcceleration(tournament)
    #       >= sortedPlayers.front()->scoreWithAcceleration(tournament)
    #
    # `player` is the OUTER loop variable and `opponent` the inner one,
    # and the inner loop breaks at `opponentIndex == playerIndex`, so
    # `player` is always the WORSE-sorted of the two. On a field sorted
    # best-first that makes the test "the lower player is still in the top
    # score group", i.e. the edge lies WHOLLY inside the top score group.
    # Summed over a matching it is a count: *maximise the number of pairs
    # formed inside the top score group*.
    #
    # Why it is not redundant with the two fields above it. On an odd
    # field the matcher returns a near-perfect matching, so every player
    # but one is covered and both higher fields collapse to statements
    # about that one leftover - eligibility to "leave out someone who may
    # actually take the bye", score to "leave out the lowest-placed
    # player". They cannot distinguish two matchings with the SAME
    # leftover, nor two leftovers that tie on both. This field can, and it
    # is the only one that says anything about the matching's SHAPE.
    #
    # Shape is exactly what `first_single_bye?/4` reads back out. That
    # scan clears the C9 gate when any top-group player is tentatively
    # matched BELOW the top group - which is precisely the arrangement
    # this field penalises - so leaving it out let the gate be decided by
    # whichever member of a tie the matcher happened to return.
    #
    # Scaled rather than packed. Multiplying everything above it by
    # `div(n, 2) + 1` - one more than the number of edges a matching can
    # hold, hence one more than the largest attainable bit total - makes
    # this strictly a TIEBREAK: it can never overturn a difference in the
    # fields above, only decide one they leave open. bbpPairings gets the
    # same guarantee from bit widths, sizing the field at
    # `scoreGroupSizeBits` so its sum cannot carry.
    top_score = elem(arr, 0).points
    tie_unit = div(n, 2) + 1

    # --- per-PLAYER facts, hoisted out of the pair loop -----------------
    #
    # Everything from here to `incompatible` used to be recomputed per
    # PAIR, 500,500 times at n=1,001, for a value that is a property of one
    # POSITION. `eligible_for_bye?/1` walks a game list and was called
    # twice per edge - a million walks for a thousand distinct answers.
    # `Map.fetch!(places, _.points)` was two hash lookups per edge.
    # `legal_pair?/2` was a linear scan of the first player's games plus a
    # `Process.get/1`, and `colour_compatible?/2` two map fetches to read
    # four fields. Not one weight changes; they are computed a thousand
    # times instead of a million.
    #
    # `blocked` is the played-opponent set the note asked for, with the
    # arbiter's forbidden pairs folded into the same map. `legal_pair?/2`
    # asks both questions of the SAME player - its first argument, which
    # the pair loop always gave the better-sorted endpoint - so one
    # membership test answers both. That is how bbpPairings has it anyway:
    # `dutch.cpp:653-666` inserts the rematch straight into
    # `forbiddenPairs`, and `compatible` makes a single lookup.
    forbidden = Process.get(@forbidden_key)

    blocked =
      field
      |> Enum.map(fn p ->
        played = for g <- p.games, played?(g), into: %{}, do: {g.opponent_rank, []}

        case forbidden && Map.get(forbidden, p.rank) do
          nil -> played
          set -> Enum.reduce(set, played, &Map.put(&2, &1, []))
        end
      end)
      |> List.to_tuple()

    ranks = field |> Enum.map(& &1.rank) |> List.to_tuple()

    # `colour_compatible?/2`'s clash test in one value per player: the
    # colour this player is ABSOLUTELY committed to, or nil. The clash it
    # looks for is "both absolute, same non-nil preference", so nil stands
    # for "not absolute" and "absolute with no preference" alike and two
    # nils never clash.
    prefs =
      field
      |> Enum.map(fn p ->
        cs = p.colour_stats
        if cs.absolute? and not is_nil(cs.preference), do: cs.preference, else: nil
      end)
      |> List.to_tuple()

    # Every compatible weight is a SUM OF PER-VERTEX TERMS plus one bit -
    # the same property the `duals` below are built on - so it does not
    # have to be reassembled out of `eligibility`, `score` and `top_pair`
    # once per pair. Split once, on the matcher's DOUBLED scale so the
    # adjacency handed to `new/3` needs no second pass over it:
    #
    #     2 * (tie_unit * (cardinality_unit + eligibility * eligibility_unit
    #                      + score) + top_pair)
    #       = 2 * half_const + vertex(lo) + vertex(hi) + 2 * top(hi)
    #
    # since `eligibility` is `1 + ineligible(lo) + ineligible(hi)` and
    # `score` is `place(lo) + place(hi)`. Identical integers, two additions
    # instead of six multiplications and four map lookups.
    half_const = tie_unit * (cardinality_unit + eligibility_unit)

    # The `eligibility` half of `vertex`. NOT `bye_candidate?/2` (the
    # eligible-AND-score<=threshold test): checked directly against
    # dutch.cpp:766-786, the bootstrap matching that DETERMINES
    # byeAssigneeScore for an odd field uses its own separate, simpler
    # inline weight -
    # `1u + !eligibleForBye(player) + !eligibleForBye(opponent)` -
    # not the real per-bracket `computeEdgeWeight`/`isByeCandidate`
    # test. That's not an oversight on the C++ side: `isByeCandidate`
    # needs `byeAssigneeScore` as an input, which is exactly what
    # this pass is computing, so testing candidates against it here
    # would be circular. Confirmed by measurement too - swapping
    # this to `bye_candidate?(_, nil)` (tried during the
    # `tools/adjudicate.exs` investigation below) made ~80/2522
    # rounds newly unpairable where bbpPairings still found a legal
    # pairing, a large regression, not the intended fix.
    #
    # The `score` half is a deliberate NON-literal reading, argued rather
    # than copied.
    # bbpPairings sums the raw SHIFT amounts here -
    # `scoreGroupShifts[a] + scoreGroupShifts[b]`, roughly linear
    # in the score-group index - where everywhere else it uses
    # them as shifts (`1u << scoreGroupShifts[...]`). `places` is
    # the mixed-radix encoding used by the rest of this port, and
    # it is geometric, so the two are different functions.
    #
    # They agree on everything this pass can observe. The field is
    # odd, the graph is complete, so the matcher covers all but one
    # player and this band's total is `constant - value(leftover)`
    # under EITHER encoding. Both are strictly increasing in the
    # score-group index, so both say the same thing: minimise the
    # leftover's score. The same collapse applies to the
    # eligibility band above (`(n-1)/2 + ineligible_total -
    # [leftover ineligible]`), which is why neither band can see
    # the matching's shape and the field below had to.
    #
    # The reduction needs every edge compatible. Where it isn't,
    # more than one player goes uncovered and the two encodings
    # could in principle part company - but that is the case where
    # real bbpPairings throws `NoValidPairingException` instead,
    # and the `[] -> {nil, false}` branch below already declines to
    # constrain C5 there.
    vertex =
      field
      |> Enum.map(fn p ->
        2 * tie_unit *
          (eligibility_unit * bit(not eligible_for_bye?(p)) + Map.fetch!(places, p.points))
      end)
      |> List.to_tuple()

    # The worse-sorted of a pair is the one the C++ condition tests, so
    # this bit is read off whichever endpoint sits LOWER in the sorted
    # field - see `tie_unit` above.
    top = field |> Enum.map(&bit(&1.points >= top_score)) |> List.to_tuple()

    search = fn ->
      searched_bootstrap(arr, n, blocked, ranks, prefs, vertex, top, half_const, tie_unit)
    end

    # Check mode holds every answer not exhibited pair by pair to the search.
    checked = fn result, counter ->
      if env_flag(@env_direct_key, "AINALRAMI_DIRECT") == "check" do
        cert_count(:bootstrap_checked)

        if result != search.() do
          raise "bootstrap certificate differs from the search: #{inspect(result)}"
        end
      end

      cert_count(counter)
      result
    end

    # A proof's reference path takes the matching every time: the
    # shortcuts below are arguments the engine makes to itself, and a
    # proof has no record type for "trust me, I did the algebra".
    if Ainalrami.Proof.reference?(),
      do: search.(),
      else: shortcut_bootstrap(arr, n, blocked, ranks, prefs, vertex, top, checked, search)
  end

  defp shortcut_bootstrap(arr, n, blocked, ranks, prefs, vertex, top, checked, search) do
    case certain_bootstrap(arr, n, blocked, ranks, prefs, vertex, top) do
      {:ok, result} ->
        result

      {:leftover, result} ->
        checked.(result, :bootstrap_leftover)

      :search ->
        case matched_bootstrap(n, blocked, ranks, prefs, arr, vertex, top) do
          {:ok, result} ->
            checked.(result, :bootstrap_matched)

          {:leftover, result} ->
            checked.(result, :bootstrap_leftover)

          :search ->
            search.()
        end
    end
  end

  # The bootstrap's answer without the matching, where it can be proved.
  #
  # Written out on the matcher's (doubled) scale, the weight of a matching
  # M that pairs every player but one, L, over compatible edges only is
  #
  #     2 * tie_unit * (K + C - (eligibility_unit * inelig(L) + place(L))) + 2 * T
  #
  # where K and C are the same for every such M - `cardinality_unit` and
  # the per-vertex terms summed over the whole field - and T is the number
  # of M's edges lying wholly inside the top score group. A matching that
  # uses an incompatible edge pairs one fewer compatible edge and loses a
  # whole `cardinality_unit`, which outweighs everything after it (that is
  # what `cardinality_unit` is sized for above), and T is below `tie_unit`.
  # So the optimum is lexicographic: first all but one player paired over
  # compatible edges, if that is possible at all; then the leftover's
  # `(inelig, place)` as small as possible (`eligibility_unit` outranks any
  # place); then T as large as possible.
  #
  # The two things this function returns depend on the optimum only
  # through those three: the bye score is the leftover's score, which its
  # place names (places are distinct per score), and `first_single_bye?/4`
  # asks whether the leftover is in the top group and every other top
  # player is paired inside it - T at its ceiling `(|top| - 1) / 2`. Every
  # optimal matching agrees on all three, so every optimal matching gives
  # the same answer, and the matcher returns one of them.
  #
  # So if a matching can be EXHIBITED that reaches the best value each of
  # the three could possibly take - all but one paired, a leftover whose
  # `vertex` term is the least in the field, and T at its bound
  # `(|top| - [leftover in top]) / 2` - it is optimal, and its answer is
  # the answer. This builds one greedily: leave out the LAST player with the
  # least `vertex` term (`vertex` is exactly `(inelig, place)` in
  # lexicographic order), and pair the rest in field order, each with the
  # first later player it is compatible with - the same compatibility the
  # search's edges are weighted by. When that pairs everyone and the top
  # group comes out internal, the answer is read off it. Anything else -
  # a player left without a partner, a top group split more than it had
  # to be - goes to the search, which is the old path unchanged; failing
  # to find the certificate costs nothing but the attempt.
  #
  # The search was a whole-field matching over a complete graph - on an
  # odd field it built every one of the field's n^2/2 edges and grew a
  # tree over all of them, a sixth of a 300-player round - and the round
  # pays for it again in every forced search `Ainalrami.Alternatives` runs.
  defp certain_bootstrap(arr, n, blocked, ranks, prefs, vertex, top) do
    least = vertex |> Tuple.to_list() |> Enum.min()
    leftover = Enum.max(for i <- 0..(n - 1)//1, elem(vertex, i) == least, do: i)

    compatible? = fn i, j ->
      not is_map_key(elem(blocked, i), elem(ranks, j)) and
        colours_pairable?(arr, elem(prefs, i), elem(prefs, j), i, j)
    end

    others = for i <- 0..(n - 1)//1, i != leftover, do: i

    with {:ok, pairs} <- pair_in_order(others, compatible?, []) do
      top_players = Enum.count(0..(n - 1)//1, &(elem(top, &1) == 1))
      bound = div(top_players - elem(top, leftover), 2)
      internal = Enum.count(pairs, fn {i, j} -> elem(top, i) == 1 and elem(top, j) == 1 end)

      cond do
        internal == bound ->
          matching =
            Enum.reduce(pairs, %{}, fn {i, j}, m -> m |> Map.put(i, j) |> Map.put(j, i) end)

          score = elem(arr, leftover).points
          {:ok, {score, first_single_bye?(arr, n, matching, score)}}

        # A leftover below the top group decides both answers alone (see
        # `leftover_bootstrap/5`), and the pairs are its certificate.
        elem(top, leftover) == 0 and leftover_bootstrap?() ->
          {:leftover, {elem(arr, leftover).points, false}}

        true ->
          :search
      end
    else
      :none -> :search
    end
  end

  # The same certificate where the greedy pairing cannot give one: its
  # existence shown by maximum matchings instead of exhibited pair by pair.
  #
  # With `L` the leftover `certain_bootstrap/7` picks (the last with the
  # least `vertex` term), `U` the top group less `L` and `R` everyone else
  # less `L`, a matching of all but `L` over compatible edges with `T` at
  # its bound `div(|U|, 2)` exists exactly when
  #
  #   * `|U|` even: `U` and `R` are each perfectly matched (the bound pairs
  #     all of `U` inside it, so nothing crosses);
  #   * `|U|` odd: some `t` of `U` is left over by a near-perfect matching of
  #     `U` and plays some `r` that a near-perfect matching of `R` leaves
  #     over (then `U - t`, `R - r` and `(t, r)` make one), i.e. `t` and `r`
  #     in the exposable sets (`Ainalrami.CardinalityMatching.exposable/1`).
  #
  # Both are asked of a sparse subgraph (each player's first
  # `@oracle_degree` compatible later players in the set), which is sound
  # the way the oracle's is: what it finds is real, and what it misses goes
  # to the search. The answer is then read off the three bounds rather than
  # off a matching: the bye score is `L`'s, and `first_single_bye?/4` holds
  # exactly when `L` is in the top group and `U` is paired wholly inside it
  # (`|U|` even) - every optimum agrees, as above. Check mode holds it to the
  # search.
  defp matched_bootstrap(n, blocked, ranks, prefs, arr, vertex, top) do
    least = vertex |> Tuple.to_list() |> Enum.min()
    leftover = Enum.max(for i <- 0..(n - 1)//1, elem(vertex, i) == least, do: i)

    compatible? = fn i, j ->
      not is_map_key(elem(blocked, i), elem(ranks, j)) and
        colours_pairable?(arr, elem(prefs, i), elem(prefs, j), i, j)
    end

    {upper, rest} =
      0..(n - 1)//1
      |> Enum.reject(&(&1 == leftover))
      |> Enum.split_with(&(elem(top, &1) == 1))

    ok? =
      if rem(length(upper), 2) == 0 do
        sparse_perfect?(upper, compatible?) and sparse_perfect?(rest, compatible?)
      else
        with {:ok, d_upper} <- sparse_exposable(upper, compatible?),
             {:ok, d_rest} <- sparse_exposable(rest, compatible?) do
          Enum.any?(d_upper, fn t ->
            Enum.any?(d_rest, fn r -> compatible?.(min(t, r), max(t, r)) end)
          end)
        else
          :no -> false
        end
      end

    cond do
      ok? ->
        score = elem(arr, leftover).points
        {:ok, {score, elem(top, leftover) == 1 and rem(length(upper), 2) == 0}}

      elem(top, leftover) == 0 and leftover_bootstrap?() ->
        leftover_bootstrap(leftover, compatible?, arr, upper, rest)

      true ->
        :search
    end
  end

  # The certificate with the leftover below the top group. `first_single_bye?/4`
  # is then false whatever the matching (the bye score is below the top
  # score), so of the three things the optimum is ranked by, only the first
  # two are read: all but one paired over compatible edges, and the
  # leftover's `vertex` term as small as the field allows. `L` has the least
  # term in the field, so once the field less `L` is shown perfectly matched
  # over compatible edges, every optimum leaves over a player with `L`'s
  # term - `L`'s eligibility and place, hence `L`'s score - and the answer is
  # `{score(L), false}`, however few pairs the top group can keep inside it.
  # That is the shape that went to the search: the two leaders of a late
  # round who have met, the top group split in every matching (3.9 s at
  # 1,001 players round 9).
  #
  # The field less `L` is asked of the sparse subgraph first and, where that
  # misses, of the whole compatible graph: the sparse maximum matching is
  # grown by augmenting searches over every compatible pair
  # (`dense_perfect?/3`), which is exact - a search that finds no path shows
  # some maximum matching leaves its root exposed - so what it misses the
  # search would not find either, and it goes to the search as before.
  defp leftover_bootstrap(leftover, compatible?, arr, upper, rest) do
    others = Enum.sort(upper ++ rest)

    if dense_perfect?(others, compatible?) do
      {:leftover, {elem(arr, leftover).points, false}}
    else
      :search
    end
  end

  # The leftover certificate is new with this pass; `AINALRAMI_DIRECT=off`
  # switches it off with the direct brackets, so a run can be held to the
  # engine without it end to end.
  defp leftover_bootstrap?, do: env_flag(@env_direct_key, "AINALRAMI_DIRECT") != "off"

  # Whether `set` (field positions, ascending) is perfectly matched over
  # `compatible?`: the sparse subgraph's maximum matching, grown where it
  # leaves anyone exposed by an augmenting search over the whole graph, its
  # rows built only as the search reaches them.
  defp dense_perfect?(set, compatible?) do
    {members, adj} = sparse_adjacency(set, compatible?)
    size = tuple_size(members)
    match = CardinalityMatching.maximum(adj)

    if map_size(match) == size do
      true
    else
      key = {@dense_rows_key, :bootstrap}

      row = fn a ->
        memo_row(key, a, fn ->
          i = elem(members, a)

          for b <- 0..(size - 1)//1,
              b != a,
              j = elem(members, b),
              compatible?.(min(i, j), max(i, j)),
              do: b
        end)
      end

      try do
        Enum.reduce_while(0..(size - 1)//1, match, fn v, match ->
          if is_map_key(match, v) do
            {:cont, match}
          else
            case CardinalityMatching.augment_from(row, match, v, MapSet.new()) do
              {:ok, match} -> {:cont, match}
              :none -> {:halt, :none}
            end
          end
        end) != :none
      after
        Process.delete(key)
      end
    end
  end

  # A row of a dense graph, built on first use and kept under `key` (a map
  # of rows) for as long as the caller keeps the key.
  defp memo_row(key, a, build) do
    rows = Process.get(key, %{})

    case rows do
      %{^a => row} ->
        row

      _ ->
        row = build.()
        Process.put(key, Map.put(rows, a, row))
        row
    end
  end

  # The sparse subgraph on `set` (field positions, ascending): each one
  # joined to its first `@oracle_degree` compatible later members, as
  # neighbour lists over indices into `set`.
  defp sparse_adjacency(set, compatible?) do
    members = List.to_tuple(set)
    size = tuple_size(members)

    rows =
      Enum.reduce(0..(size - 1)//1, %{}, fn a, acc ->
        i = elem(members, a)

        {partners, _} =
          Enum.reduce_while((a + 1)..(size - 1)//1, {[], 0}, fn b, {partners, taken} ->
            cond do
              taken >= @oracle_degree -> {:halt, {partners, taken}}
              compatible?.(i, elem(members, b)) -> {:cont, {[b | partners], taken + 1}}
              true -> {:cont, {partners, taken}}
            end
          end)

        Enum.reduce(partners, acc, fn b, acc ->
          acc |> Map.update(a, [b], &[b | &1]) |> Map.update(b, [a], &[a | &1])
        end)
      end)

    {members, List.to_tuple(for v <- 0..(size - 1)//1, do: rows |> Map.get(v, []) |> Enum.sort())}
  end

  defp sparse_perfect?([], _compatible?), do: true

  defp sparse_perfect?(set, compatible?) do
    {members, adj} = sparse_adjacency(set, compatible?)
    map_size(CardinalityMatching.maximum(adj)) == tuple_size(members)
  end

  # The field positions of `set` some near-perfect matching of its sparse
  # subgraph leaves over, or `:no`.
  defp sparse_exposable(set, compatible?) do
    {members, adj} = sparse_adjacency(set, compatible?)

    case CardinalityMatching.exposable(adj) do
      {:ok, outer} -> {:ok, Enum.map(outer, &elem(members, &1))}
      :no -> :no
    end
  end

  # Each player in order with the first later one it is compatible with.
  defp pair_in_order([], _compatible?, acc), do: {:ok, acc}

  defp pair_in_order([i | rest], compatible?, acc) do
    case take_first(rest, &compatible?.(i, &1), []) do
      {j, rest} -> pair_in_order(rest, compatible?, [{i, j} | acc])
      nil -> :none
    end
  end

  defp take_first([], _match?, _skipped), do: nil

  defp take_first([x | xs], match?, skipped) do
    if match?.(x),
      do: {x, Enum.reverse(skipped, xs)},
      else: take_first(xs, match?, [x | skipped])
  end

  # The bootstrap as a whole-field maximum-weight matching - the path every
  # case the certificate above cannot settle still takes, unchanged.
  defp searched_bootstrap(arr, n, blocked, ranks, prefs, vertex, top, half_const, tie_unit) do
    # dutch.cpp:768-791: `compatible/4`-failing pairs still get a
    # real edge here (`edgeWeight` starts at, and for these stays,
    # exactly 0) - the bootstrap matching_computer is built as a
    # COMPLETE graph, so an incompatible pair is only ever a worse
    # choice than a compatible one, never an impossible one.
    # `WeightedMatching.solve/2`'s `build_state/2` silently drops
    # any edge with weight `0` (`if w > 0`), so a literal port of
    # "weight 0" would vanish here exactly like the omitted-edge
    # version this replaces - hence weight `1`, the smallest weight
    # that still registers, still guaranteed below every compatible
    # edge's `cardinality_unit`-or-higher floor. Previously this
    # pair contributed NO edge at all, so a field whose only
    # legal/colour-compatible pairs can't form a near-perfect
    # matching (heavy forfeits/absolute-colour clashes) could leave
    # MORE than one player unmatched here - a case real bbpPairings
    # doesn't hit at this bootstrap step, since it always has a
    # complete graph to fall back on.
    #
    # Scaled by `tie_unit` along with every compatible edge, so an
    # incompatible pair stays exactly as far below them as before.
    incompatible = 2 * tie_unit

    # The graph is COMPLETE, so the matcher's own `%{u => %{v => 2w}}` can
    # be built a ROW at a time and the `[{i, j, w}]` list in between is
    # pure overhead: 500,500 tuples at n=1,001, consed up by two nested
    # `flat_map`s and then folded straight back apart by a million
    # `Map.update/4`s inside `new/3`. `Map.new/1` over a finished row is
    # one `:maps.from_list/1` instead, and `new/3` takes the structure as
    # `:adjacency` and does no fold at all.
    #
    # The price is that each pair's weight is arrived at twice, once from
    # each endpoint's row, where the triangular list arrived at it once.
    # With the per-player facts above that is two tuple reads and one
    # addition, and `tools/bootstrap_split.exs` at 1,001 players measures
    # this half of the bootstrap at 638 ms against 2,407 ms even so
    # (medians of three), with `new/3` on top going 1,409 ms -> 224 ms.
    #
    # Legality is NOT symmetric to compute, only to answer:
    # `legal_pair?(p1, p2)` interrogates p1's game list and p1's forbidden
    # set, and the pair loop always handed it the better-sorted player. So
    # a row consults its OWN `blocked` above the diagonal and the other
    # endpoint's below it, and the two halves are written out separately
    # for that reason rather than for the hoisting.
    {rows, max_weight2} =
      Enum.map_reduce(0..(n - 1)//1, 0, fn i, mx ->
        rank_i = elem(ranks, i)
        pref_i = elem(prefs, i)
        blocked_i = elem(blocked, i)
        below = 2 * half_const + elem(vertex, i) + 2 * elem(top, i)
        above = 2 * half_const + elem(vertex, i)

        {pairs, mx} =
          Enum.reduce(0..(i - 1)//1, {[], mx}, fn j, {acc, mx} ->
            w =
              if not is_map_key(elem(blocked, j), rank_i) and
                   colours_pairable?(arr, elem(prefs, j), pref_i, j, i) do
                below + elem(vertex, j)
              else
                incompatible
              end

            {[{j, w} | acc], max(mx, w)}
          end)

        {pairs, mx} =
          Enum.reduce((i + 1)..(n - 1)//1, {pairs, mx}, fn j, {acc, mx} ->
            w =
              if not is_map_key(blocked_i, elem(ranks, j)) and
                   colours_pairable?(arr, pref_i, elem(prefs, j), i, j) do
                above + elem(vertex, j) + 2 * elem(top, j)
              else
                incompatible
              end

            {[{j, w} | acc], max(mx, w)}
          end)

        {{i, Map.new(pairs)}, mx}
      end)

    adjacency = Map.new(rows)

    # Every compatible edge's weight is a sum of per-vertex terms plus the
    # one-bit `top_pair`, so a dual of half the symmetric part per vertex
    # (on the matcher's doubled scale: the whole of it), plus one for a
    # top-group vertex, makes every compatible edge tight except a
    # top-to-lower one (slack 1) and leaves the incompatible ones far from
    # it. The matcher's greedy start then pairs the field in index order
    # along those edges and the search has one or two exposed vertices to
    # settle, instead of matching one heaviest edge per stage for a
    # hundred stages. Checked against the weights by `new/3`.
    #
    # Written out of the same decomposition as the weights above, and
    # producing the same integers the per-vertex form did:
    # `half_const + vertex(i) + top(i)`.
    duals = Map.new(0..(n - 1)//1, fn i -> {i, half_const + elem(vertex, i) + elem(top, i)} end)

    {_state, matching} =
      n
      |> WeightedMatching.new([],
        adjacency: adjacency,
        duals: duals,
        max_weight: div(max_weight2, 2)
      )
      |> WeightedMatching.solve()

    case Enum.reject(0..(n - 1), &is_map_key(matching, &1)) do
      # No legal complete round exists; leave C5 unconstrained and let the
      # cascade and `repair_bye_count/3` produce the best answer they can
      # rather than refusing every candidate here.
      [] ->
        {nil, false}

      leftovers ->
        score = leftovers |> Enum.map(&elem(arr, &1).points) |> Enum.min()
        {score, first_single_bye?(arr, n, matching, score)}
    end
  end

  # dutch.cpp:851-870, verbatim. C9 ("minimise the unplayed games of the
  # bye assignee") only means anything in a bracket that downfloats exactly
  # ONE player and that player takes the bye. For the very first bracket
  # bbpPairings decides that from the bootstrap matching above: the bye has
  # to fall in the TOP score group at all (`byeAssigneeScore >= topScore`),
  # and no top-group player may already be tentatively matched below it -
  # if one is, the top group is floating someone down as well as producing
  # the bye, so there is no single assignee to talk about.
  #
  # In practice this is usually FALSE, because the bye assignee is normally
  # the lowest-scoring eligible player and `byeAssigneeScore >= topScore`
  # then only holds for a field that is effectively one score group. That
  # is the point: `bracket_loop/5` used to approximate this as "odd field,
  # and an even number of players below the top bracket", which fires far
  # more often and so scored C9 in brackets bbpPairings excludes.
  #
  # The scan stops at the first player below the top score - the C++ loop
  # `break`s there - which the sorted field turns into a plain implication.
  # An unmatched vertex is its own partner in bbpPairings' convention, so
  # the bye assignee themselves never clears the flag.
  #
  # This reads the matching's SHAPE, so it is only as well-defined as the
  # matching is. Where several matchings tie on weight the flag can differ
  # between them, and a maximum-weight matcher may return any of them -
  # which is exactly why the bootstrap's lowest-order weight field (see
  # `tie_unit` above) is not optional. That field prefers matchings that
  # pair the top score group internally, i.e. the ones this scan does NOT
  # clear, so the tie is resolved before it ever gets here.
  defp first_single_bye?(arr, n, matching, bye_score) do
    top = elem(arr, 0).points

    bye_score >= top and
      Enum.all?(0..(n - 1)//1, fn i ->
        elem(arr, i).points < top or
          elem(arr, Map.get(matching, i, i)).points >= top
      end)
  end

  # C5, the PAB Criterion: "Minimise the score of the assignee of the
  # pairing-allocated-bye". ABSOLUTE, so it is checked here alongside C2
  # rather than weighted anywhere.
  defp bye_score_ok?(player) do
    case Process.get(@bye_score_key) do
      nil -> true
      score -> player.points <= score
    end
  end

  defp score_places(players) do
    players
    |> Enum.group_by(& &1.points)
    |> Enum.map(fn {score, members} -> {score, length(members)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, 1}, fn {score, size}, {places, place} ->
      {Map.put(places, score, place), place * (size + 1)}
    end)
  end

  defp float_score_criteria(higher, lower, spans) do
    crossing? = higher.points > lower.points

    # Only a pair that spans two score groups HAS a score difference, and
    # the difference belongs to the MDP - the higher-scored player, who
    # moved down into this bracket. `score_place` already encodes exactly
    # that: one digit per score group, the higher group more significant,
    # so a bigger drop is a bigger number and "taken in descending order"
    # falls out of the positional comparison.
    #
    # Weighting by the LOWER player instead was tried first and is inert:
    # `lower` is decided by bracket position, so in an MDP bracket it is
    # always a resident, every resident shares one score, and the term is
    # then the same constant for every candidate pairing.
    if crossing? do
      psd = Map.fetch!(spans.score_place, higher.points)

      {
        # C18/C20 - the MDP itself downfloated recently. Pairing it here is
        # what stops it floating on, so the reward grows with the drop.
        if(float_of(higher, 1) == :down, do: psd, else: 0),
        # C19/C21 - inverted like `float_criteria/2`'s f2/f4: the reward is
        # for an opponent who did NOT just upfloat.
        if(float_of(lower, 1) == :up, do: 0, else: psd),
        if(float_of(higher, 2) == :down, do: psd, else: 0),
        if(float_of(lower, 2) == :up, do: 0, else: psd)
      }
    else
      {0, 0, 0, 0}
    end
  end

  # Pack ranked criteria, highest priority first, the same way bbpPairings'
  # `computeEdgeWeight` does with successive left-shifts: each criterion is
  # worth more than every lower-priority criterion combined, so a better
  # value on an earlier term can never be outvoted by later ones. Passing
  # explicit spans rather than hard-coded decimal magnitudes is what makes
  # that guarantee hold - the previous `* 1_000_000` / `* 1_000` scheme was
  # only safe as long as nobody looked at a bracket big enough to overflow
  # the gap between two of its terms.
  defp ranked(components) do
    Enum.reduce(components, 0, fn {value, span}, acc -> acc * span + value end)
  end

  defp bit(true), do: 1
  defp bit(false), do: 0
  # A forfeit carries an opponent AND a colour but is legally unplayed,
  # which is why every caller has to ask whether the game HAPPENED rather
  # than whether there was an opponent - four separate call sites had that
  # wrong until the harness started generating forfeits.
  #
  # Defined by the same table as `Trf.game_was_played?/1` rather than by a
  # private list of its own. The list said `1 = 0`, which was right only
  # while `Trf.parse/1` folded the letter spellings `W`, `D` and `L` into
  # the symbols on the way in, and wrong for a caller who builds player maps
  # directly, which the engine's public API invites. Such a caller's played,
  # unrated game would have been read as unplayed: no colour, no float. Two
  # definitions of "played" that disagreed on the same input is the bug, and
  # one of them is the reference's. The fold is gone now, so the letters
  # reach here from a parsed file as well.
  defp played?(game), do: Ainalrami.Trf.game_was_played?(game.result)

  # A player's full colour state, ported from bbpPairings'
  # `tournament.cpp` `computePlayerData`. This replaces a one-line
  # stand-in ("preference is the opposite of your last colour") that was
  # only ever right for round 2, which is exactly why round 2 measured
  # 99.85% and round 3 fell off a cliff: after two games a player can be
  # two colours out of balance, or have had the same colour twice running,
  # and both produce an ABSOLUTE preference that the old rule couldn't
  # represent at all.
  #
  # Unplayed games (byes, forfeits) are excluded entirely - they carry no
  # colour and must not break a run of repeated colours either.
  defp colour_stats(player) do
    played = Enum.filter(player.games, &played?/1)
    whites = Enum.count(played, &(&1.colour == "w"))
    blacks = Enum.count(played, &(&1.colour == "b"))
    imbalance = abs(whites - blacks)
    consecutive = trailing_run(played)

    last =
      case List.last(played) do
        nil -> nil
        game -> game.colour
      end

    # Ties go to White, matching bbpPairings' own `gamesAsWhite >
    # gamesAsBlack ? BLACK : WHITE` - not a coin flip.
    lower_colour = if whites > blacks, do: "b", else: "w"

    # The ladder's order matters: an imbalance of 2+ outranks a repeated
    # colour, which outranks an imbalance of 1, which outranks plain
    # alternation.
    preference =
      cond do
        imbalance > 1 -> lower_colour
        consecutive > 1 -> invert(last)
        imbalance > 0 -> lower_colour
        consecutive > 0 -> invert(last)
        true -> nil
      end

    repeated = if consecutive > 1, do: last, else: nil
    absolute_imbalance? = imbalance > 1
    absolute? = absolute_imbalance? or not is_nil(repeated)

    %{
      preference: preference,
      imbalance: imbalance,
      repeated: repeated,
      absolute_imbalance?: absolute_imbalance?,
      absolute?: absolute?,
      strong?: not absolute? and imbalance > 0,
      # Everything below is for `explain_round/3` and is never read by the
      # pairing itself. `imbalance` is an ABSOLUTE value because that is all
      # the criteria need; a person reading a colour column needs the SIGN
      # (is this player two Whites up, or two Blacks up), and reconstructing
      # it from `preference` is a puzzle rather than a fact.
      whites: whites,
      blacks: blacks,
      difference: whites - blacks,
      consecutive: consecutive,
      last: last,
      colours: Enum.map(played, & &1.colour)
    }
  end

  @doc """
  How FIDE classifies a player's colour preference: `:absolute`, `:strong`,
  `:mild` or `:none`.

  The distinction is the one an arbiter defends a pairing with, and the
  three classes are not degrees of the same thing - they are different
  KINDS of claim:

    * `:absolute` - a colour difference beyond ±1, or the same colour in the
      two most recent rounds. It must be granted, and two non-topscorers
      with the same absolute preference may not meet at all. This is a
      constraint, not a preference.
    * `:strong` - a colour difference of exactly ±1. The player is due the
      colour that equalises it.
    * `:mild` - balanced, so the player is due the colour that alternates
      from their last game.
    * `:none` - no played games to have a preference from.

  Derived from `colour_stats/1` rather than recomputed, so it can never
  disagree with the state the pairing itself used.
  """
  def colour_class(%{absolute?: true}), do: :absolute
  def colour_class(%{strong?: true}), do: :strong
  def colour_class(%{preference: nil}), do: :none
  def colour_class(_stats), do: :mild

  # How many games at the END of the list share the same colour.
  defp trailing_run([]), do: 0

  defp trailing_run(played) do
    [last | earlier] = Enum.reverse(played)
    1 + Enum.count(Enum.take_while(earlier, &(&1.colour == last.colour)))
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"
  defp invert(nil), do: nil

  # The four separately-ranked colour criteria of bbpPairings'
  # `insertColorBits`, in its own priority order (highest first). The old
  # engine had only the third of these - a single "are the preferences
  # compatible" boolean - which cannot distinguish a clash between two
  # absolute preferences (near-unpairable) from a clash between two mild
  # ones (a routine tie-break). All four sit ABOVE every float-history
  # criterion in bbpPairings' bit layout, so colour errors dominate float
  # errors whenever the two disagree.
  defp colour_criteria(higher, lower) do
    p = lower.colour_stats
    o = higher.colour_stats
    clash? = not is_nil(p.preference) and p.preference == o.preference

    {
      not (p.absolute_imbalance? and o.absolute_imbalance? and clash?),
      not (p.absolute? and o.absolute? and clash?) or absolute_tiebreak(p, o),
      not clash?,
      (not p.strong? and not p.absolute?) or (not o.strong? and not o.absolute?) or
        (p.absolute? and o.absolute?) or not clash?
    }
  end

  # The four float-history criteria of bbpPairings' `computeEdgeWeight`,
  # ranked immediately below every colour criterion and above the
  # bracket-ordering ones. These are what docs/engineering-log.md item 4 predicted would
  # first bite in round 3: `float_direction/4` looks one and two rounds
  # back, and two rounds back doesn't exist until round 3.
  #
  # All four are phrased so that HIGHER is better, since the matcher
  # maximises. The two "repeated downfloater" terms reward *pairing* a
  # player who was floated down recently - pairing them here is precisely
  # how you avoid floating them again. The two "repeated upfloater" terms
  # instead withhold their bit from an edge that would upfloat someone who
  # already upfloated, an edge being an upfloat exactly when it crosses
  # score groups.
  defp float_criteria(higher, lower) do
    crossing? = higher.points > lower.points

    {
      bit(float_of(lower, 1) == :down) + bit(not crossing? and float_of(higher, 1) == :down),
      bit(not (crossing? and float_of(lower, 1) == :up)),
      bit(float_of(lower, 2) == :down) + bit(not crossing? and float_of(higher, 2) == :down),
      bit(not (crossing? and float_of(lower, 2) == :up))
    }
  end

  # Reached only when both players hold an absolute preference for the SAME
  # colour, i.e. one of them is definitely going to be denied. It decides
  # which such clash is the least bad: prefer the one where the player who
  # is *less* out of balance isn't the one whose repeated colour would be
  # extended.
  defp absolute_tiebreak(p, o) do
    if p.imbalance == o.imbalance do
      is_nil(p.repeated) or p.repeated != o.repeated
    else
      less_imbalanced = if p.imbalance > o.imbalance, do: o, else: p
      less_imbalanced.repeated != invert(p.preference)
    end
  end

  # C1, no repeat pairings - but only actually-PLAYED games forbid a
  # rematch. bbpPairings builds its `forbiddenPairs` set under an explicit
  # `if (match.gameWasPlayed)` guard (`dutch.cpp:664`), so two players who
  # were paired and forfeited have not "met" and may be paired again.
  #
  # Confirmed against real javafo before changing it: seed 140, an
  # 11-player round 2 where players 5 and 10 were paired in round 1 and
  # double-forfeited. javafo paired them with each other AGAIN, in
  # preference to two rematch-free alternatives it could have taken
  # instead - so this is javafo's actual behaviour, not an artefact of
  # having no other option.
  #
  # An arbiter's `XXP` exclusion lives here, and nowhere else, because
  # that is where bbpPairings puts it: `compatible` (`dutch.cpp:39-68`)
  # opens with `!forbiddenPairs[player0.id].count(player1.id)` and only
  # then considers colour, and the rematch rule reaches that same test by
  # being INSERTED INTO the very same set (`dutch.cpp:653-666`). The two
  # rules are literally one lookup in the reference. So a forbidden pair is
  # an absolute criterion of exactly the standing of "you have already
  # played this opponent" - never a term weighed against the others.
  defp legal_pair?(p1, p2) do
    not forbidden_pair?(p1.rank, p2.rank) and not met?(p1, p2.rank)
  end

  # Whether `player` has PLAYED `rank` - `@facts_key`'s map when the round
  # stamped one, the walk it replaces otherwise.
  defp met?(%{@facts_key => {met, _eligible, _played}}, rank), do: is_map_key(met, rank)

  defp met?(player, rank),
    do: Enum.any?(player.games, &(played?(&1) and &1.opponent_rank == rank))

  defp forbidden_pair?(rank1, rank2) do
    case Process.get(@forbidden_key) do
      nil -> false
      map -> map |> Map.get(rank1) |> forbids?(rank2)
    end
  end

  defp forbids?(nil, _rank), do: false
  defp forbids?(set, rank), do: MapSet.member?(set, rank)

  # Two players who both hold an ABSOLUTE colour preference for the same
  # colour cannot be paired at all. bbpPairings puts this in `compatible`
  # (`dutch.cpp:57-68`) alongside the no-rematch rule - an absolute
  # criterion, not something weighed against other considerations. This
  # engine had it only as scored criteria c1/c2, which means a bad enough
  # position elsewhere could buy a pairing that is simply not allowed.
  #
  # bbpPairings carries one exception: in the FINAL round, two players
  # above half the maximum possible score may be paired despite the
  # clash, rather than leave a tournament's decisive game unplayed. It
  # needs the expected round count, which reaches here via
  # `pair_next_round/2`'s `:expected_rounds` option; without it the
  # exception simply never fires and the engine stays strict.
  #
  # Leaving it out was measurable: rounds 4-8 all improved when the hard
  # exclusion landed, and round 9 - the final round of the nine-round
  # sweep, and the only round where this exception can apply - was the
  # one round that got worse.
  defp colour_compatible?(a, b) do
    p = a.colour_stats
    o = b.colour_stats

    if p.absolute? and o.absolute? and not is_nil(p.preference) and
         p.preference == o.preference do
      final_round_topscorers?(a, b)
    else
      true
    end
  end

  # `colour_compatible?/2` for a caller that has already reduced each
  # player to the colour they are ABSOLUTELY committed to, or nil - see
  # `prefs` in `bye_assignee_score_from_field/2`. Same three outcomes: no
  # commitment on the better-sorted side, or two different commitments,
  # pairs; the same commitment twice falls through to the same final-round
  # exception, which is the only branch that needs the player maps and is
  # rare enough to pay for `elem/2` when it fires.
  #
  # `i` is the better-sorted endpoint and `j` the worse, matching the order
  # `colour_compatible?/2` itself passes on - `final_round_topscorers?/2`
  # reads its FIRST argument's game count as the played-round fallback.
  defp colours_pairable?(_arr, nil, _pref_j, _i, _j), do: true

  defp colours_pairable?(arr, pref_i, pref_j, i, j) do
    pref_i != pref_j or final_round_topscorers?(elem(arr, i), elem(arr, j))
  end

  defp final_round_topscorers?(a, b) do
    case Process.get(@expected_rounds_key) do
      nil ->
        false

      expected_rounds ->
        # `playedRounds >= expectedRounds - 1`: the round being paired is
        # the last one. The threshold is bbpPairings' own
        # `(tournament.playedRounds * pointsForWin) >> 1` - half of what a
        # player could have scored SO FAR (rounds already played), not
        # half the tournament's eventual maximum. Those are genuinely
        # different numbers even in the one round this exception can ever
        # fire in: playedRounds is expectedRounds-1 there, so the correct
        # threshold is floor((expectedRounds-1)/2), one lower than
        # floor(expectedRounds/2) whenever expectedRounds is even. This
        # engine used expectedRounds directly, which was simply the wrong
        # variable - found by tracing a genuine round-30 disagreement
        # (seed 39, 32-player field): Ainalrami left two players unpaired
        # despite a full pairing existing, confirmed reachable by
        # disabling colour compatibility entirely first, and this
        # one-line fix alone was enough to reach it (see docs/engineering-log.md).
        # Not `length(a.games)`: that is this player's own game count, and a
        # player holding a pre-recorded bye for the round being paired has one
        # more of those than the tournament has played rounds.
        played_rounds = Process.get(@played_key, length(a.games))

        # `div/2` here rounded the threshold down: at playedRounds 7 the
        # real threshold is 3.5 and this used 3, admitting a player on
        # exactly 3.5 as a topscorer where the reference requires strictly
        # more than half. Kept as a float and compared with `>`, so
        # 3.5 > 3.5 is false.
        #
        # `>> 1` in the reference IS an integer shift that truncates, and
        # not on doubled units as this comment used to claim - points are
        # TENTHS there (`pointsForWin{ 10u }`, `tournament.h:299`), so
        # `playedRounds * maxPerRound` is odd, and the shift loses 0.05,
        # whenever the per-round maximum has an odd tenths digit: a win
        # worth 0.5, or 1.5. The float here does not truncate, and does not
        # need to: every score is itself a whole number of tenths, so the
        # only values the two thresholds disagree about lie strictly
        # between T and T + 0.05, and no score can land there. Equivalent
        # for every input a TRF can state - but for that reason, not
        # because the shift is exact.
        # `pointsForWin` is the missing factor whenever a win is not worth
        # 1.0: the reference's expression is
        # `(playedRounds * pointsForWin) >> 1`, i.e. half of what a player
        # COULD have scored so far, and scores are in the file's own units.
        # Dividing rounds by two alone silently assumed the standard system.
        # `std::max(pointsForWin, pointsForDraw)`, not `pointsForWin`
        # alone (`dutch.cpp:55`, read from the 6.0.0 source rather than
        # inferred). The two differ only in a point system where a draw
        # outscores a win, which FIDE would never publish but a TRF can
        # state outright: `BBW` and `BBD` are free-form numbers, so
        # `BBW 1.0` with `BBD 2.0` parses. The reference takes the larger
        # of the two as "the most a round can be worth", and the whole
        # conformance claim here is that we compute what it computes.
        # Cheap insurance besides: the last point-system bug found this
        # way (a half-point loss) cost 87% agreement on that axis.
        points_per_round = max(point_system().win, point_system().draw)
        threshold = played_rounds * points_per_round / 2

        played_rounds >= expected_rounds - 1 and
          (a.points > threshold or b.points > threshold)
    end
  end

  # Absolute criterion C2: nobody receives a second pairing-allocated bye.
  # bbpPairings' `eligibleForBye` (common.h:104-118) disqualifies a player who
  # has an UNPLAYED game that is either worth at least a win, or was a
  # pairing-allocated bye:
  #
  #     U   pairing-allocated bye        both limbs
  #     F   full-point bye (arbiter)     worth a win
  #     +   forfeit win                  worth a win
  #
  # and leaves eligible the ones worth less: `H` (half-point bye), `Z`
  # (zero-point bye), `-` (forfeit loss).
  #
  # **`W` was here and should not have been**, on the reading that it is an
  # "unplayed win". It is not. bbpPairings gates the whole rule on
  # `!match.gameWasPlayed` (common.h:111) and sets that false for exactly
  # `+ - H F U Z` and space (trf.cpp:278-286) - `W`, `D` and `L` are absent
  # from that list, so they are PLAYED games, scored through the same
  # WIN/DRAW/LOSS branch as `1`, `=` and `0` (trf.cpp:252-270). They are
  # letter spellings of an ordinary result, and an ordinary win has never
  # disqualified anybody from a bye.
  #
  # It was unreachable through this repo's own parser while that folded `W`
  # into `1` before the engine saw it, and reachable from a caller that hands
  # in player maps directly, which is exactly how the sibling Phoenix app
  # uses this engine. There it would have barred a player from a bye for the
  # crime of having won a game. The fold is gone, so a parsed file reaches
  # this rule with its letters intact too, and it has to be right for both.
  #
  # Enforced as a hard requirement on the cascade's final state rather
  # than scored, so the search has to find a legal bye assignee or report
  # that none exists.
  # Under the standard system this is exactly `~w(U F +)`, which is what
  # this was: `+` and `F` are unplayed and worth a win, and `U` is the
  # pairing's own bye. Written as the reference writes it - a comparison
  # against `pointsForWin` rather than a fixed list - because the list stops
  # being right the moment a file sets its own point values. With
  # `BBF 1.0`, a forfeit LOSS is worth a win and disqualifies its holder;
  # with `BBW 2.0`, a half-point bye still does not.
  #
  # The score test is only the reference's FIRST disjunct. The second -
  # `participatedInPairing && opponent == id` - catches the opponentless
  # `U` and `+` however little the file pays them, and was written here as
  # a bare `result == "U"`. It coincided while `+` was scored as a win;
  # once `+` is scored as the pairing-allocated bye it is, a file setting
  # `BBU 0.0` would have handed a second bye to somebody who already had a
  # forfeit win.

  @doc """
  Why each player may not receive the pairing-allocated bye - C.2, as this
  engine applies it - keyed by rank: `nil` when eligible, else
  `:pairing_bye` (already had one), `:forfeit_win` (won a game without
  playing it) or `:full_point_bye`.

  Public for `Ainalrami.Alternatives`, which answers "why did HE get the
  bye and not me" and has to say, for every other candidate, whether the
  rule even allowed it. Derived from the same `bye_disqualifying?/1` the
  pairing uses, under the same point system, so it cannot disagree with
  what was decided.

  With `pair_next_round/2`'s `:bye_exclusions` (not a FIDE rule), a listed
  player C.2 itself allows is `:organiser_exclusion`; one C.2 already rules
  out keeps C.2's reason, since the exclusion changed nothing for them. A
  player also listed in `:bye_preference_exclusions` - the exclusions
  `Ainalrami.ByePreference` resolved another player's bye preference into,
  which its report's `:opts` carry - is `:bye_preference` instead.
  """
  def bye_eligibility(players, opts \\ []) do
    validate_input!(players, opts)
    previous = Process.get(@point_system_key)

    try do
      Process.put(@point_system_key, opts[:point_system] || Ainalrami.Trf.default_point_system())
      excluded = MapSet.new(opts[:bye_exclusions] || [])
      by_preference = MapSet.new(opts[:bye_preference_exclusions] || [])

      Map.new(players, fn player ->
        reason =
          case bye_disqualification(player) do
            nil ->
              cond do
                MapSet.member?(by_preference, player.rank) -> :bye_preference
                MapSet.member?(excluded, player.rank) -> :organiser_exclusion
                true -> nil
              end

            c2 ->
              c2
          end

        {player.rank, reason}
      end)
    after
      if previous,
        do: Process.put(@point_system_key, previous),
        else: Process.delete(@point_system_key)
    end
  end

  @doc false
  # For each player C.2 rules out of the bye, the reason and the round of the
  # game that does it (1-based, the earliest), as `%{rank => {reason,
  # round}}` - `bye_eligibility/2`'s reasons with the round a message can
  # name. For `Ainalrami.ByePreference`, which refuses a "must get the bye"
  # for such a player.
  def bye_disqualifications(players, opts \\ []) do
    validate_input!(players, opts)
    previous = Process.get(@point_system_key)

    try do
      Process.put(@point_system_key, opts[:point_system] || Ainalrami.Trf.default_point_system())

      for player <- players,
          found =
            player.games
            |> Enum.with_index(1)
            |> Enum.find_value(fn {game, round} ->
              case bye_disqualification(%{player | games: [game]}) do
                nil -> nil
                reason -> {reason, round}
              end
            end),
          into: %{},
          do: {player.rank, found}
    after
      if previous,
        do: Process.put(@point_system_key, previous),
        else: Process.delete(@point_system_key)
    end
  end

  @doc false
  # The round's active players, each with the score its bracket is built on
  # (points plus this round's acceleration), as `%{rank => score}`. For
  # `Ainalrami.ByePreference`, which compares bye holders' scores and must
  # read them by the same rule the brackets do rather than a copy of it.
  def round_scores(players) do
    played = rounds_played(players)

    players
    |> Enum.filter(&active_this_round?(&1, played))
    |> with_acceleration(played)
    |> Map.new(&{&1.rank, &1.points})
  end

  defp bye_disqualification(player) do
    Enum.find_value(player.games, fn game ->
      cond do
        not bye_disqualifying?(game) -> nil
        not is_nil(game.opponent_rank) -> :forfeit_win
        Ainalrami.Trf.participated_in_pairing?(game) -> :pairing_bye
        true -> :full_point_bye
      end
    end)
  end

  # [C2], plus the organiser's bye exclusions when a caller gave any - the
  # one place they enter the engine. Every rule that asks whether a player
  # may take the bye (the bootstrap that fixes the bye score, the ladder's
  # bye-candidate rung, the completion check and its repair) asks here, so
  # an excluded player is ineligible everywhere C2 would have made them
  # ineligible, and nowhere else.
  defp eligible_for_bye?(%{@facts_key => {_met, eligible, _played}}), do: eligible

  defp eligible_for_bye?(player) do
    not excluded_from_bye?(player) and not Enum.any?(player.games, &bye_disqualifying?/1)
  end

  defp excluded_from_bye?(player) do
    case Process.get(@bye_excluded_key) do
      nil -> false
      set -> MapSet.member?(set, player.rank)
    end
  end

  defp bye_disqualifying?(game) do
    not Ainalrami.Trf.game_was_played?(game.result) and
      (game_points(game) >= point_system().win or
         (is_nil(game.opponent_rank) and Ainalrami.Trf.participated_in_pairing?(game)))
  end

  defp assign_colour_with_history({a, b}) do
    case choose_colour(a, b) do
      "w" ->
        {a.rank, b.rank}

      "b" ->
        {b.rank, a.rank}

      nil ->
        # Neither player has a colour preference, so 5.2.1-5.2.4 cannot apply
        # and 5.2.5 decides on the higher ranked player's parity.
        #
        # The parity is taken on the ARRIVAL NUMBER, not the TPN - see
        # `arrival_numbers/2` for the SPP ruling that separated them. Read
        # from `@parity_number_key`, which `do_pair_later_round/1` stamps
        # once for the whole round; this function sees only the two players
        # of one board and could not build it.
        #
        # "Higher ranked" is Article 1.2 -- SCORE first, then TPN ascending --
        # and is a SEPARATE question from which number the parity is then
        # taken on. The ruling moved the second, not the first, so
        # `order_by_placement/2` is untouched. This once compared TPN alone,
        # the same defect 5.2.4 carried one article up: any pair straddling a
        # score group got the parity rule applied to the wrong player.
        # Reachable wherever a player has no PLAYED games at all, which
        # arbiter byes produce routinely -- and which is exactly where the
        # residual colour disagreements clustered.
        {top, bottom} = order_by_placement(a, b)

        # `fetch!`, not a `rank` fallback: `top` is being paired this round,
        # so it is in this round's pool and therefore always numbered. A
        # silent fallback here would restore the overturned reading on
        # whatever path forgot to stamp the key.
        assign_colour_round_one(top, bottom, Map.fetch!(parity_numbers(), top.rank))
    end
  end

  defp parity_numbers, do: Process.get(@parity_number_key) || %{}

  # The colour `player` gets against `opponent` - a port of bbpPairings'
  # `choosePlayerNeutralColor` (`swisssystems/common.cpp`), which is
  # Article 5.2 in full: grant the preference outright when they don't
  # clash, otherwise let the stronger preference win (absolute over strong
  # over mild, and within absolute, the larger imbalance), and only when
  # they are genuinely equal fall back to alternating from the most recent
  # round in which the two players actually had different colours.
  #
  # `nil` means "still undecided" and leaves the caller on the fixed
  # round-1 convention. Note this affects only which of the two players is
  # printed as White; the comparison harness is colour-blind, so nothing
  # here moves the match rate. It's correctness, not score.
  defp choose_colour(player, opponent) do
    p = player.colour_stats
    o = opponent.colour_stats

    cond do
      is_nil(p.preference) or is_nil(o.preference) or p.preference != o.preference ->
        p.preference || invert(o.preference)

      p.absolute? and (p.imbalance > o.imbalance or not o.absolute?) ->
        p.preference

      o.absolute? and (o.imbalance > p.imbalance or not p.absolute?) ->
        invert(o.preference)

      p.strong? and not o.strong? ->
        p.preference

      o.strong? and not p.strong? ->
        invert(o.preference)

      true ->
        case first_colour_difference(player, opponent) do
          {players_colour, opponents_colour}
          when not is_nil(players_colour) and not is_nil(opponents_colour) ->
            opponents_colour

          # 5.2.3 could not separate them: the two have identical colour
          # histories, so there is no "most recent time in which one player
          # had White and the other Black".
          #
          # 5.2.4 decides next -- "grant the colour preference of the higher
          # ranked player" -- and this used to skip it, falling straight to
          # 5.2.5's odd-TPN rule. Both players hold the same preference here
          # (the branch above rules out any other case), so the higher ranked
          # of the two takes it and the other gets the opposite.
          #
          # Only reachable when two players' colour histories match exactly,
          # which ordinary Swiss play makes uncommon -- different opponents
          # give different colours -- and which no random corpus produced in
          # 195 million pairings. It was found by building a position that
          # forces it: see `tools/forced_exchange.exs`.
          _ ->
            #  is non-nil here: the first clause of this cond
            # already handled a missing or differing preference, so both hold
            # the same one and only who is higher ranked is left to decide.
            # "Higher ranked" is Article 1.2 -- SCORE first, then TPN
            # ascending -- not TPN alone. A bracket routinely holds players on
            # different scores (every moved-down player is one), and comparing
            # TPN there hands the preference to the wrong player. Caught by the
            # first colour-aware fuzz run: both disagreeing boards had
            # identical colour histories, so 5.2.4 was deciding, and in each
            # the engine preferred the lower TPN where bbpPairings preferred
            # the higher score.
            if {-player.points, player.rank} < {-opponent.points, opponent.rank},
              do: p.preference,
              else: invert(o.preference)
        end
    end
  end

  # The colours the two players had in the most recent round where they
  # differed, walking both histories back in step and skipping unplayed
  # games on either side independently.
  defp first_colour_difference(a, b) do
    walk_back(played_colours(a), played_colours(b))
  end

  # bbpPairings' `skipUnplayedGames`: a forfeit is skipped here too, so
  # the two histories stay aligned on rounds that were actually contested.
  defp played_colours(player) do
    player.games |> Enum.filter(&played?/1) |> Enum.map(& &1.colour) |> Enum.reverse()
  end

  defp walk_back([x | xs], [y | ys]) when x == y, do: walk_back(xs, ys)
  defp walk_back([x | _], [y | _]), do: {x, y}
  defp walk_back([], [y | _]), do: {nil, y}
  defp walk_back([x | _], []), do: {x, nil}
  defp walk_back([], []), do: {nil, nil}
end

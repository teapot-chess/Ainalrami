defmodule Ainalrami.ThreeWayComparisonTest do
  @moduledoc """
  Asks all three engines the same question, every round.

  ## Why this exists

  This project has been steering by agreement with bbpPairings, on the
  strength of one earlier measurement: bbpPairings and Gacrux agreed with
  each other on **324 comparable rounds, zero disagreements**. That was
  used to justify treating either as ground truth.

  324 rounds with zero disagreements does not establish that. Zero
  observed failures in n trials bounds the true rate at roughly `3/n` with
  95% confidence - here about **0.9%**. So the references could disagree
  with each other on nearly one round in a hundred and that measurement
  would very likely still have come back clean.

  That mattered little when this engine was at 90% of exact rounds: the
  error being measured was ten times larger than the uncertainty in the
  ruler. It matters now. At 100% over 2.5 billion pairings, "ainalrami is
  wrong" and "the reference is wrong" are not distinguishable by a two-way
  comparison at all, and the precision of every headline number in
  `docs/validation.md` is really the precision of this measurement.

  So this runs all three, at whatever scale is asked for, and reports the
  pairwise rates plus the three-way split. Two things come out of it: a
  tight bound on how far the references actually agree, and - for the
  rounds where this engine differs - whether the other two agree with each
  other (this engine is wrong) or disagree (nobody's ground truth).

  ## It generates what the two-way harness generates

  Until 2026-08-24 it did not, and that was the flaw worth fixing before
  running it at scale. This harness had its own generator producing plain
  tournaments: uniform ratings, no byes, no forfeits, a fixed round count.
  The two-way harness had long since moved on to byes, forfeits,
  acceleration, withdrawals, five rating shapes and a variable round count.

  Bounding the references' agreement on plain tournaments would have been
  close to worthless, because **both known disputes in 2.5 billion pairings
  are about byes** - the one construct the old generator never produced. A
  ruler verified only where nobody doubted it is not a verified ruler.

  Both harnesses now generate through `Ainalrami.Test.FuzzTournament`, so
  an axis added for one is available to the other.

  ## Three axes Gacrux cannot take, and why they are refused rather than run

  `PAIRING_FUZZ_FORBIDDEN_PCT`, `PAIRING_FUZZ_NUMERIC_EXT` and
  `PAIRING_FUZZ_ACCEL` raise here instead of being quietly ignored.

  Gacrux has **no forbidden-pairs concept at all** - no `XXP`, no `260`,
  nothing in `trf2json.py` that reads one - and it does not read `250`
  either. Handing it a file with those lines does not fail; it produces a
  perfectly good pairing of a tournament with different rules, and every
  round where the constraint bit would be recorded as a three-way
  disagreement. That reads exactly like the references contradicting each
  other, which is the one thing this harness exists to measure, so a silent
  skip here would corrupt the only number it produces.

  **Acceleration is now the third, and it was added the hard way.** This
  moduledoc used to say acceleration was passed through because Gacrux
  parses `XXA`, and it ended with a prediction:

  > If a run shows disagreement concentrated on accelerated tournaments,
  > suspect the reader before the rules.

  It happened. The 2026-08-24 run put the accelerated axis at **42.23%**
  bbpPairings-vs-Gacrux over 98,323 rounds, against 100.00% on every axis
  without acceleration, and dragged the combined `everything` axis down to
  49.96%. It is not a rules disagreement. On
  `dumps/3way-everything/seed30700002_r1_p20.trf` - a round-1 position with
  Baku acceleration - bbpPairings and Ainalrami both pair inside the
  accelerated groups while Gacrux produces the textbook UNACCELERATED
  top-half-against-bottom-half pairing. Gacrux is pairing a different
  tournament, so the number measures its reader, not the rules, exactly as
  with `250`/`260`. Run this axis two-way.

  Note what the prediction bought: because it was written down before the
  run, the 42% was diagnosed in one position instead of being reported as
  the references contradicting each other on half of all accelerated rounds.

  ## A crashed reference is missing data, but only sometimes costly

  Gacrux reports failure INSIDE its output file with exit status 0, and
  `### Error 510` is its catch-all for "an exception escaped the checker".
  `Ainalrami.Test.Gacrux` used to map that to "no legal pairing". A
  `{:crashed, _}` round is now its own kind: counted, reported, dumped, and
  in no rate.

  What that change then revealed is worth stating carefully, because the
  first reading of it was wrong. Re-running Gacrux on the 234 exhaustion
  splits the 2026-08-24 run dumped found 203 crashes, and every one of the
  60 sampled was `crosstabledutch.py:253 KeyError: 'n'` - which looked like
  a single bug. It is not. Those 234 were dumped BECAUSE bbpPairings paired
  the position, so that sample could only ever contain the crash that
  happens on pairable positions. Measured without that filter, on 200
  crashes from a 21,079-round run, there are three sites and they mean
  opposite things:

      196x  pairingdutch.py:314   RuntimeError: No active exception to reraise
        2x  pairingdutch.py:465   KeyError: 'rem_hamilton'
        2x  crosstabledutch.py:253  KeyError: 'n'

  `pairingdutch.py:314` is `if len(edges) == 0: raise` - a bare `raise` with
  no active exception, i.e. a placeholder where Gacrux means "this bracket
  has no pairable edges". bbpPairings independently found NO legal pairing
  on 196 of 196 of them. So that crash lands where the position really is
  unpairable, the tournament ends on that round either way, and no
  comparison was lost. `crosstabledutch.py:253` is the opposite: bbpPairings
  paired 2 of 2, so a comparison that was available did not happen.

  The report therefore splits crashes by whether bbpPairings had an answer,
  and warns on the costly ones only. A single lumped percentage would have
  read 1.1006% when the number that can actually move a rate was 0.02%.

  Both numbers print whether or not they are zero, so a future run cannot
  quietly turn crashes back into disagreements the way this one did.

  ## Colour is a second instrument, and the reference pair is the point of it

  The three rates above are colour-blind. `same?/2` sorts each pair's two
  ranks before comparing, so every number this harness has ever produced
  measures who plays whom and never who is White. That is not a small gap:
  the identical blindness in the two-way harness let a missing Article
  5.2.4 survive 195 million pairings, and it was found by building a
  position by hand rather than by any corpus.

  So colour is measured too, over the boards a pair of engines BOTH formed,
  and there are three pairwise numbers rather than one. The one worth
  running this for is **bbpPairings vs Gacrux**. Every colour figure in this
  project is quoted against one reference or the other, so the distance
  between the two references is the accuracy those figures actually carry -
  and nothing had ever measured it.

  An earlier version of this moduledoc predicted it was not zero, on the
  grounds that the two references renumber differently from each other -
  bbpPairings around anyone absent this round, Gacrux only around players
  who have never played. That claim was false when it was written.
  `tools/rip_probe.exs` had already refuted it: when the absent player has
  played, all three engines answer alike. See the note above
  `explained_by_article_5_2_5?/4`, and `docs/dispute-initial-colour.md`,
  which records the retraction. The reason to run this comparison is simply
  that nobody had ever measured the two references against each other, not
  that a split was predicted.

  Differences against THIS ENGINE are no longer split at all: the SPP ruled
  on 2026-08-27 that 5.2.5's parity is taken on the arrival numbering rather
  than on the fixed TPN, this engine now does that, and so a colour
  difference against either reference has nothing left to be except a
  finding. The `bbpPairings vs Gacrux` row keeps its weaker split, because
  what it measures is not settled. See `explained_by_article_5_2_5?/4`.

  None of this can fail a run. The assertions below are untouched and the
  composition rates still measure exactly what they measured before: a
  colour difference on an otherwise identical round is a different finding
  from a different round, and folding the two together would lose both.
  That is the choice the two-way harness made, for the same reason.

  ## Cost

  Gacrux is a Python script, ~750ms per round against bbpPairings' ~21ms,
  so this is roughly 35x the cost of the two-way harness and is excluded
  from the default suite. It parallelises cleanly - 36 cores put it at
  ~25 rounds/s at 4-40 players.

      PAIRING_FUZZ_COUNT=200 PAIRING_FUZZ_ROUNDS=9 mix test --only three_way

  Same tunables as the other harnesses, minus the three above.
  """

  use ExUnit.Case
  alias Ainalrami.{Pairing, Test.Bbppairings, Test.ColourArticle, Test.Gacrux}

  import Ainalrami.Test.FuzzTournament

  @moduletag :three_way
  @moduletag timeout: :infinity

  test "bbpPairings, Gacrux and Ainalrami on identical positions" do
    refuse_unsupported_axes!()

    count = env_int("PAIRING_FUZZ_COUNT", 20)
    rounds = env_int("PAIRING_FUZZ_ROUNDS", 5)
    players = env_int("PAIRING_FUZZ_MIN_PLAYERS", 4)..env_int("PAIRING_FUZZ_MAX_PLAYERS", 40)
    seed_from = env_int("PAIRING_FUZZ_SEED_FROM", 1)

    rows =
      seed_from..(seed_from + count - 1)
      |> Task.async_stream(&run_tournament(&1, rounds, players),
        max_concurrency: System.schedulers_online(),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, r} -> r end)

    {errors, rest} = Enum.split_with(rows, &(&1.kind == :error))
    {crashes, rest} = Enum.split_with(rest, &(&1.kind == :reference_crash))
    {splits, compared} = Enum.split_with(rest, &(&1.kind == :exhaustion_split))

    report(compared, splits, crashes, errors)
    dump(compared, splits, crashes)

    assert errors == [], """
    #{length(errors)} round(s) where a reference engine failed to run at all.

    This is not a pairing result and none of the rates above include it. The
    usual cause is the environment rather than the tournament: Gacrux needs
    `networkx`, and GACRUX_PYTHON must point at the interpreter that has it.
    A run reporting these is measuring its own setup, so it fails here rather
    than quoting a bound derived from whatever survived.

    #{Enum.map_join(Enum.take(errors, 3), "

", &format_error/1)}
    """

    assert compared != [], "no comparable rounds were produced"
  end

  # The measurement is only meaningful on files all three engines read the
  # same way. See the moduledoc - this is a wrong-answer guard, not a
  # capability check.
  defp refuse_unsupported_axes! do
    forbidden = env_int("PAIRING_FUZZ_FORBIDDEN_PCT", 0)
    numeric = System.get_env("PAIRING_FUZZ_NUMERIC_EXT")
    accel = System.get_env("PAIRING_FUZZ_ACCEL")

    if accel not in [nil, "", "0", "false"] do
      raise """
      PAIRING_FUZZ_ACCEL=#{accel} cannot be measured three-way.

      Gacrux parses `XXA` but does not ACT on it: on an accelerated round-1
      position it pairs top-half against bottom-half as though the
      acceleration were not there, while bbpPairings and Ainalrami both pair
      inside the accelerated groups. Measured 2026-08-24 at 42.23%
      bbpPairings-vs-Gacrux over 98,323 accelerated rounds, against 100.00%
      on every unaccelerated axis.

      Every one of those is Gacrux pairing a DIFFERENT tournament, not the
      references contradicting each other. Run this axis two-way.
      """
    end

    if forbidden != 0 do
      raise """
      PAIRING_FUZZ_FORBIDDEN_PCT=#{forbidden} cannot be measured three-way.

      Gacrux implements no forbidden-pairs concept, so it would pair a
      DIFFERENT tournament and every constrained round would be counted as
      the two references contradicting each other. Run this axis two-way.
      """
    end

    if numeric not in [nil, "0", "false"] do
      raise """
      PAIRING_FUZZ_NUMERIC_EXT=#{numeric} cannot be measured three-way.

      `250`/`260` are bbpPairings' own fixed-column extension lines. Gacrux
      reads neither, so acceleration written that way would reach it as an
      unaccelerated tournament. Run this axis two-way.
      """
    end
  end

  defp run_tournament(seed, rounds, player_range) do
    {rounds, player_count, forbidden, roster} = begin!(seed, rounds, player_range)

    {rows, _} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, ps} ->
        withdraw_some(round, player_count)
        ps = assign_requested_byes(ps)
        trf = build_trf(ps, rounds, forbidden)

        base = %{seed: seed, round: round, player_count: player_count, trf: trf}

        # Both are asked before anything is decided, because WHICH of them
        # refuses is itself a measurement. An earlier version used a `with`
        # that treated every non-`{:ok, _}` the same and simply stopped the
        # tournament - so a Gacrux that could not start at all (a missing
        # `networkx` is enough) looked exactly like a field running out of
        # legal opponents, and the run would report a confident bound
        # computed from almost no rounds.
        case {Bbppairings.pair(trf), Gacrux.pair(trf, round)} do
          {{:ok, bbp}, {:ok, gac}} ->
            ours = safely_pair(ps, rounds, forbidden)

            row =
              Map.merge(base, %{
                kind: :compared,
                bbp: bbp,
                gac: gac,
                ours: ours,
                bbp_gac: same?(bbp, gac),
                ours_bbp: same?(ours, bbp),
                ours_gac: same?(ours, gac),
                # Counts, not boards. `ps` is the roster the round was
                # paired FROM - before `apply_round/3` writes this round's
                # results onto it - because Article 5.2 is decided by the
                # colour history the engines were handed, not by the one
                # they produce. Reducing to four integers here rather than
                # keeping the boards is what lets a billion-pairing run
                # hold its rows in memory at all.
                colours: colour_agreement(ours, bbp, gac, ps, base)
              })

            {:cont, {[row | acc], apply_round(ps, bbp, simulate_results(bbp))}}

          # One reference says the round has no legal pairing and the other
          # produced one. That is the two of them contradicting each other
          # about whether the position is pairable at all - the strongest
          # form of the disagreement this harness exists to find, and one no
          # two-way run against either engine could ever report.
          {{:no_valid_pairing, _}, {:ok, gac}} ->
            {:halt,
             {[Map.merge(base, %{kind: :exhaustion_split, refused: :bbp, gac: gac}) | acc], ps}}

          {{:ok, bbp}, {:no_valid_pairing, _}} ->
            {:halt,
             {[Map.merge(base, %{kind: :exhaustion_split, refused: :gacrux, bbp: bbp}) | acc], ps}}

          {{:no_valid_pairing, _}, {:no_valid_pairing, _}} ->
            {:halt, {acc, ps}}

          # Gacrux fell over where bbpPairings had an answer. THIS is the
          # crash that costs something: a comparison that could have been
          # made was not, so the round is recorded, kept out of every rate,
          # and the TOURNAMENT CONTINUES on bbpPairings' pairing. Truncating
          # here is what the old no-valid-pairing reading did, and it
          # silently biased the corpus towards short tournaments.
          {{:ok, bbp}, {:crashed, detail}} ->
            row = crash_row(base, detail, :comparison_lost)
            {:cont, {[row | acc], apply_round(ps, bbp, simulate_results(bbp))}}

          # Gacrux fell over where bbpPairings also found no legal pairing.
          # Still a crash - Gacrux did not conclude anything, it raised - but
          # it cost NOTHING, because the tournament ends here either way.
          # Measured, not assumed: of 200 dumped crashes, 198 were this and
          # every one of them was a position bbpPairings refuses too.
          {{:no_valid_pairing, _}, {:crashed, detail}} ->
            {:halt, {[crash_row(base, detail, :none) | acc], ps}}

          {bbp_result, gac_result} ->
            row =
              Map.merge(base, %{
                kind: :error,
                bbp: bbp_result,
                gac: gac_result
              })

            {:halt, {[row | acc], ps}}
        end
      end)

    Enum.reverse(rows)
  end

  defp crash_row(base, detail, cost) do
    Map.merge(base, %{kind: :reference_crash, who: :gacrux, detail: detail, cost: cost})
  end

  defp safely_pair(players, rounds, forbidden) do
    Pairing.pair_next_round(players,
      expected_rounds: rounds,
      forbidden_pairs: forbidden,
      initial_colour: String.downcase(initial_colour()),
      # `nil` on every run that does not set the axis, which is what
      # `Pairing` already defaults to - so this changes nothing until a file
      # carries `BB*` lines saying otherwise.
      point_system: point_system()
    )
  rescue
    _ -> :raised
  end

  defp same?(:raised, _), do: false
  defp same?(_, :raised), do: false
  defp same?(a, b), do: normalize(a) == normalize(b)

  @no_colours %{shared: 0, agreed: 0, disputed: 0, unexplained: 0}

  # WHO IS WHITE, which `same?/2` and `normalize/1` deliberately throw away.
  #
  # Ported from `Ainalrami.BbppairingsComparisonTest.colour_mismatches/5`,
  # and its reasoning is worth restating rather than referencing, because it
  # is the whole argument for the function existing: sorting each pair's
  # ranks before comparing means 4.3 million tournaments and 195 million
  # pairings validated who plays whom and never once checked Article 5. A
  # missing 5.2.4 survived all of it. The rates in this harness are built on
  # the same `normalize/1` and carry the same blind spot.
  #
  # What this harness can ask that the two-way one cannot: it holds THREE
  # answers to one position, so the reference pair can be asked the question
  # too. bbpPairings-vs-Gacrux is the only colour rate in this project that
  # is not measured against an assumption - it bounds the distance between
  # the two rulers rather than the distance from this engine to one of them.
  #
  # Counted separately from composition and reported beside it, never folded
  # in: the two fail for different reasons, and the existing pass/fail
  # assertion stays exactly as colour-blind as it was so that this
  # instrument cannot turn a green run red.
  defp colour_agreement(ours, bbp, gac, players, where) do
    # Built once and shared by all three comparisons. The two-way harness
    # rebuilds this inside the predicate, once per board; here that would be
    # three passes over the same roster for the same round.
    by_rank = Map.new(players, &{&1.rank, &1})

    %{
      bbp_gac: colours_between({"bbpPairings", "Gacrux"}, bbp, gac, by_rank, :none, where),
      # Asked of each reference's own round, not of the pair: an engine can be
      # internally inconsistent whether or not the other one agrees with it,
      # and that is a finding about THAT engine.
      article: %{
        bbp: article_consistency(bbp, by_rank, players, where, "bbpPairings"),
        gac: article_consistency(gac, by_rank, players, where, "Gacrux")
      },
      ours_bbp: colours_between({"Ainalrami", "bbpPairings"}, ours, bbp, by_rank, :none, where),
      ours_gac: colours_between({"Ainalrami", "Gacrux"}, ours, gac, by_rank, :none, where)
    }
  end

  # An engine that gave no answer contributes NO boards rather than
  # zero-agreement boards, which is the same distinction this file already
  # draws twice over for Gacrux: an `### Error 510` is not a refusal, and a
  # refusal is not a wrong pairing. A denominator that quietly absorbs a
  # missing answer reports a confidence nobody measured.
  #
  # Only `:raised` needs handling here. A crashed or refused reference never
  # reaches this function at all - those rounds become `:reference_crash`
  # and `:exhaustion_split` rows, which are not `:compared` and so hold no
  # `colours` key to be summed.
  defp colours_between(_names, :raised, _right, _by_rank, _mode, _where), do: @no_colours

  # Unreachable today: `ours` is always the LEFT argument above, precisely so
  # that one clause covers it. It stays because the cost of being wrong
  # about that later is silent - a rate that counts Ainalrami's refusal as a
  # colour disagreement looks exactly like a colour regression.
  defp colours_between(_names, _left, :raised, _by_rank, _mode, _where), do: @no_colours

  defp colours_between(names, left, right, by_rank, mode, where) do
    theirs = MapSet.new(right)

    # Only a board both engines formed can disagree about COLOUR; a board
    # only one of them formed is a composition difference and is already
    # counted by `same?/2`. A pairing is a partition, so `theirs` can hold
    # at most one orientation of a given board and these two membership
    # tests can never both be true.
    both_formed =
      Enum.filter(left, fn
        {_w, nil} -> false
        {w, b} -> MapSet.member?(theirs, {w, b}) or MapSet.member?(theirs, {b, w})
      end)

    {reversed, agreed} =
      Enum.split_with(both_formed, fn {w, b} -> MapSet.member?(theirs, {b, w}) end)

    # Split the differences into the one there is a diagnosis for and
    # everything else. The two-way harness used to need this badly: the
    # 5.2.5 dispute put nearly two thousand boards per six hundred bye-heavy
    # tournaments into the "differs" column, which buried any genuine colour
    # regression. That bucket is gone since the SPP ruling, so what is left
    # here is the reference-against-reference case, where the split still
    # separates "5.2.5 decided this board" from a finding needing a look.
    {disputed, unexplained} =
      Enum.split_with(reversed, &explained_by_article_5_2_5?(&1, by_rank, where.round, mode))

    debug_unexplained(names, unexplained, by_rank, where)

    %{
      shared: length(both_formed),
      agreed: length(agreed),
      disputed: length(disputed),
      unexplained: length(unexplained)
    }
  end

  # Is this board one there is an expected explanation for?
  #
  # 5.2.5 is the last resort, reached only when neither player holds a
  # colour preference at all, which per Article 1.7.4 means neither has ever
  # played a game with a colour.
  #
  # Two modes, and the gap between them is the honest part of this port.
  #
  # `:none` is used wherever ONE SIDE IS THIS ENGINE, and it explains
  # nothing. Until 2026-08-28 those two comparisons ran a `:conformance`
  # mode: 5.2.5 decides the board AND this engine's answer is the article's,
  # where "the article" meant a model of this engine's reading of it - the
  # parity of the fixed TPN. The SPP settled that reading against us on
  # 2026-08-27 and this engine now takes the parity of the arrival numbering,
  # which is what both references do, so `:conformance` would have become
  # flat equality: a board where we differ from a reference would be
  # "explained" by our differing from it. That is not an explanation, it is
  # a tautology that swallows regressions, so the bucket is gone rather than
  # left to report zero.
  #
  # RETRACTED 2026-10-26: bbpPairings against Gacrux now runs as `:none`.
  # `:reach` existed to file bbp-vs-Gacrux colour differences under a
  # weaker word, and every such difference was Gacrux pairing the wrong
  # round (it was not given `-n`). With the round passed there is nothing
  # to explain, so a difference there is reported as unexplained.
  #
  # `:reach` is all that survives when NEITHER side is this engine. On a
  # bbpPairings-vs-Gacrux board there is no claim to make about THIS
  # engine's conformance - it formed neither answer - so the test is only
  # that 5.2.5 is what decides the board. That is a weaker claim and it is
  # reported under a weaker word: those boards are "within 5.2.5's reach",
  # not a confirmed anything.
  #
  # An earlier version of this comment justified `:reach` differently, by
  # claiming the two references renumber differently FROM EACH OTHER -
  # bbpPairings around anyone absent this round, Gacrux only around players
  # who have never played - so that a field where somebody who HAS played
  # sits out could still split them. That claim was false when it was
  # written. It was the hypothesis `tools/rip_probe.exs` was built to test,
  # and the probe refuted it: when the absent player has already played,
  # all three engines answer alike and nobody renumbers. Re-confirmed
  # 2026-08-27 against the local bbpPairings binary. It survived in prose
  # anyway, in `docs/dispute-initial-colour.md` and from there into this
  # harness, where it justified keeping a weaker instrument.
  #
  # So `:reach` is not kept because the references might still split. It is
  # kept because a weaker word is the honest one for a board this engine did
  # not form.
  #
  # STRENGTHENED 2026-08-29. The ruling fixed the article's answer, so
  # computing it is applying a rule all three engines implement rather than
  # predicting an internal - and `article_5_2_5_consistency/3` now makes a
  # real claim about a reference from it.
  #
  # The claim is not "this board is right", because that needs the initial
  # colour and Article 5.1 leaves it to a literal drawing of lots. It is that
  # every board a round decides by 5.2.5 must imply the SAME initial colour.
  # An engine whose round implies both has broken the article on at least one
  # of those boards, whatever the constant was - which is a defect in a
  # reference, found by applying an agreed article to its output.
  #
  # `explained_by_article_5_2_5?/4` keeps its old job: deciding whether a
  # DISAGREEING board is one 5.2.5 was deciding at all. The consistency check
  # is the separate, stronger question, asked per round rather than per
  # board, and reported beside it.
  defp explained_by_article_5_2_5?({white, black}, by_rank, _round, mode) do
    a = Map.get(by_rank, white)
    b = Map.get(by_rank, black)

    cond do
      mode != :reach -> false
      is_nil(a) or is_nil(b) -> false
      not ColourArticle.no_colour_preference?(a) -> false
      not ColourArticle.no_colour_preference?(b) -> false
      true -> true
    end
  end

  # Whether one engine's answers for this round can all be explained by a
  # single initial colour - see `ColourArticle.article_5_2_5_consistency/3`.
  #
  # An inconsistent round is printed immediately rather than only counted:
  # this is the strongest claim the harness can make against a reference, it
  # is expected never to fire, and a rate that ticks up in a summary is not
  # something anybody would go looking for the position behind.
  defp article_consistency(:raised, _by_rank, _players, _where, _name), do: :not_applicable

  defp article_consistency(boards, by_rank, players, where, name) do
    numbers = Pairing.arrival_numbers(players, where.round)

    case ColourArticle.article_5_2_5_consistency(boards, by_rank, numbers) do
      {:inconsistent, whites, blacks} = verdict ->
        IO.puts(
          "
  #{name} broke Article 5.2.5 on seed #{where.seed}, round #{where.round}: " <>
            "#{whites} board(s) imply an initial white, #{blacks} imply black. " <>
            "One constant decides them all, so at least one board is wrong."
        )

        verdict

      verdict ->
        verdict
    end
  end

  defp debug_unexplained(_names, [], _by_rank, _where), do: :ok

  defp debug_unexplained({left_name, right_name}, boards, by_rank, where) do
    if System.get_env("COLOUR_DEBUG") do
      for {w, b} <- boards do
        # Seed, round and player count together, because those three are
        # exactly what reproduces a position on its own - the same triple
        # `write_dispute/2` puts in a dump filename. Colour differences are
        # not dumped, so this line is the only route back to the board.
        IO.puts("
seed #{where.seed} round #{where.round}, #{where.player_count} players: UNEXPLAINED
  #{left_name} says #{w} is White, #{right_name} says #{b} is White")

        # Deciding WHICH of Article 5.2's five steps applies needs both
        # players' full colour history, unplayed rounds included: 5.2.3
        # walks the two histories back in step, and a round nobody played is
        # not a round where the colours agreed.
        #
        # No acceleration column, unlike the two-way harness's version of
        # this line: `refuse_unsupported_axes!/0` refuses that axis here, so
        # the field is always nil and a column that is always nil is one a
        # reader learns to skip over.
        Enum.each([w, b], &IO.puts(history_line(by_rank, &1)))
      end
    end

    :ok
  end

  # Never raises on a rank it cannot find. This runs inside a `Task`, where
  # an exception takes the whole run down rather than one round - the same
  # reason `Ainalrami.Test.Gacrux`'s `parse_pair/1` returns `:error` instead
  # of matching inline. A diagnostic that can kill the run it is diagnosing
  # is worse than no diagnostic.
  defp history_line(by_rank, rank) do
    case Map.get(by_rank, rank) do
      nil ->
        "  ##{rank} is not in the roster - an engine named a rank the file does not carry"

      player ->
        history = Enum.map_join(player.games, " ", fn g -> "#{g.colour || "-"}#{g.result}" end)
        "  ##{rank} pts=#{player.points} games=[#{history}]"
    end
  end

  defp report(compared, splits, crashes, errors) do
    n = length(compared)
    pct = fn k -> "#{Float.round(k * 100 / max(n, 1), 4)}%" end

    bbp_gac = Enum.count(compared, & &1.bbp_gac)
    ours_bbp = Enum.count(compared, & &1.ours_bbp)
    ours_gac = Enum.count(compared, & &1.ours_gac)

    IO.puts("
three-way comparison over #{n} compared round(s):
")
    IO.puts("  bbpPairings vs Gacrux       #{bbp_gac}/#{n}  #{pct.(bbp_gac)}")
    IO.puts("  Ainalrami   vs bbpPairings  #{ours_bbp}/#{n}  #{pct.(ours_bbp)}")
    IO.puts("  Ainalrami   vs Gacrux       #{ours_gac}/#{n}  #{pct.(ours_gac)}")

    # The reason for running three: when this engine differs, is it
    # outvoted or is there simply no majority to be outvoted by?
    ours_differs = Enum.reject(compared, &(&1.ours_bbp and &1.ours_gac))

    outvoted = Enum.count(ours_differs, & &1.bbp_gac)
    no_majority = Enum.count(ours_differs, &(not &1.bbp_gac))

    IO.puts("
  of the #{length(ours_differs)} round(s) where Ainalrami differs from either:")
    IO.puts("    references agree, so Ainalrami is the odd one out    #{outvoted}")
    IO.puts("    references disagree too, so there is no ground truth #{no_majority}")

    report_colours(compared)

    # Counted apart from the rates: one engine refused the position entirely,
    # so there is no pairing to compare, but the two references have still
    # contradicted each other about whether it can be paired.
    if splits != [] do
      by_who = Enum.frequencies_by(splits, & &1.refused)

      IO.puts(
        "
  #{length(splits)} round(s) where one reference found NO legal pairing and " <>
          "the other paired it: bbpPairings refused #{Map.get(by_who, :bbp, 0)}, " <>
          "Gacrux refused #{Map.get(by_who, :gacrux, 0)}"
      )
    end

    # PRINTED WHETHER OR NOT IT IS ZERO, and deliberately so. The 510
    # crashes spent a whole validation run disguised as exhaustion splits
    # because nothing ever counted them; a line that only appears when the
    # count is nonzero is a line a reader never learns to look for.
    crashed = length(crashes)
    attempted = n + length(splits) + crashed
    {costly, free} = Enum.split_with(crashes, &(&1.cost == :comparison_lost))

    IO.puts(
      "
  Gacrux crashed on #{crashed}/#{attempted} attempted round(s)  " <>
        "#{Float.round(crashed * 100 / max(attempted, 1), 4)}% - " <>
        "excluded from every rate above, being neither a pairing nor a refusal"
    )

    # The split that matters. A 510 where bbpPairings ALSO finds no legal
    # pairing costs nothing: the tournament ends on that round either way,
    # so no comparison was available to lose. A 510 where bbpPairings had an
    # answer is missing data, and only that number can move a rate.
    #
    # Reporting one lumped percentage would be true and useless - the smoke
    # run that produced this split read 1.1006% crashed, of which 99% cost
    # nothing at all.
    IO.puts(
      "    #{length(free)} at positions bbpPairings also found unpairable " <>
        "- the tournament ended there regardless, so no comparison was lost"
    )

    breakdown(free, "      ")

    lost_pct = length(costly) * 100 / max(attempted, 1)

    IO.puts(
      "    #{length(costly)} where bbpPairings HAD an answer  " <>
        "#{Float.round(lost_pct, 4)}% - these are the ones that cost a comparison"
    )

    breakdown(costly, "      ")

    # The same shape as the two-way harness' resource-starvation warning:
    # past a few percent the surviving rounds are a filtered sample, and a
    # rate computed on them is not the rate that was asked for. Thresholded
    # on the costly crashes only, for the reason above.
    if lost_pct > 1.0 do
      IO.puts(
        "    WARNING: over 1% of attempted rounds lost a comparison to a crash. " <>
          "The rates above are computed on the rounds Gacrux survived, which is " <>
          "then not a random sample of positions - treat them as untrustworthy " <>
          "until the crash is understood."
      )
    end

    if errors != [] do
      IO.puts("
  #{length(errors)} round(s) where a reference failed to run - see the failure below")
    end

    # Rule of three: zero observed failures in n trials bounds the true
    # rate at about 3/n with 95% confidence. The denominator is compared
    # rounds only, and an exhaustion split is an observed disagreement, so
    # it disqualifies the clean-bound branch.
    cond do
      n == 0 ->
        :ok

      bbp_gac == n and splits == [] ->
        IO.puts(
          "
  references never disagreed; that bounds their true disagreement " <>
            "rate at about #{Float.round(300 / n, 5)}% (95%), not at zero"
        )

      true ->
        IO.puts(
          "
  references disagreed on #{n - bbp_gac + length(splits)} round(s) - " <>
            "dumped for adjudication"
        )
    end

    IO.puts("")
  end

  # Colour, reported ALONGSIDE the composition rates and never folded into
  # them - see the moduledoc. The labels are character-for-character the
  # ones the block above uses, so the two triples line up in a terminal and
  # one can be read against the other without counting columns.
  #
  # Every line prints whether or not it is zero, for the reason the crash
  # lines do: a line that appears only when something is wrong is a line
  # nobody learns to look for, and the first thing a new instrument has to
  # establish is that it ran at all.
  defp report_colours(compared) do
    bbp_gac = colour_totals(compared, :bbp_gac)
    ours_bbp = colour_totals(compared, :ours_bbp)
    ours_gac = colour_totals(compared, :ours_gac)

    IO.puts("
  colours - who is WHITE, over the boards each pair of engines BOTH formed:")

    IO.puts(colour_line("bbpPairings vs Gacrux       ", bbp_gac, "within 5.2.5's reach"))
    IO.puts(colour_line("Ainalrami   vs bbpPairings  ", ours_bbp, "expected (none are)"))
    IO.puts(colour_line("Ainalrami   vs Gacrux       ", ours_gac, "expected (none are)"))

    references_worst_warning(bbp_gac, [ours_bbp, ours_gac])
    unexplained_warning(bbp_gac, ours_bbp, ours_gac)
    reference_colour_bound(bbp_gac)
  end

  defp colour_line(label, totals, dispute_word) do
    "  #{label}#{totals.agreed}/#{totals.shared}  #{colour_percent(totals)}  " <>
      "#{totals.disputed} #{dispute_word}, #{totals.unexplained} unexplained"
  end

  # "n/a" rather than the 0.0% a `max(shared, 1)` denominator would print,
  # following `percent/2` in the two-way harness. No shared boards is not a
  # rate of zero, and it happens for reasons worth telling apart from a
  # disagreement: a bye-only round, or an Ainalrami that refused every
  # position it was handed.
  defp colour_percent(%{shared: 0}), do: "n/a"

  defp colour_percent(totals),
    do: "#{Float.round(totals.agreed * 100 / totals.shared, 4)}%"

  defp colour_totals(compared, key) do
    Enum.reduce(compared, @no_colours, fn row, acc ->
      counts = Map.fetch!(row.colours, key)

      %{
        shared: acc.shared + counts.shared,
        agreed: acc.agreed + counts.agreed,
        disputed: acc.disputed + counts.disputed,
        unexplained: acc.unexplained + counts.unexplained
      }
    end)
  end

  # The line this harness was extended for. If the two REFERENCES agree with
  # each other about colour LESS often than this engine agrees with either
  # of them, then every colour figure this project has published - each one
  # measured against one of those two - carries an error bar wider than the
  # quantity it reports, and no two-way run can say which engine is wrong.
  # Nobody has ever measured that number, so it is printed as a finding
  # rather than quietly folded into a rate.
  defp references_worst_warning(references, ours) do
    if references_worst?(references, ours) do
      IO.puts("
    !! the two REFERENCES agree about colour LESS often than Ainalrami agrees
       with either of them. Every colour number this project quotes is
       measured against one of those two, so the pair of rulers disagrees
       by more than the thing they are being used to measure - read this
       line before reading any of the rest.")
    end
  end

  # Guarded on every side having boards to compare. A pair with no shared
  # boards has no rate at all, and "worse than nothing" is not a finding.
  defp references_worst?(references, ours) do
    rate = colour_rate(references)
    rate != nil and Enum.all?(Enum.map(ours, &colour_rate/1), &(&1 != nil and rate < &1))
  end

  defp colour_rate(%{shared: 0}), do: nil
  defp colour_rate(totals), do: totals.agreed / totals.shared

  defp unexplained_warning(bbp_gac, ours_bbp, ours_gac) do
    total = bbp_gac.unexplained + ours_bbp.unexplained + ours_gac.unexplained

    if total > 0 do
      IO.puts("
    !! #{total} board(s) where two engines agreed on WHO plays whom and then
       disagreed on who is WHITE.
       Article 5 is a real conformance surface and every rate above it is
       blind to it. Re-run with COLOUR_DEBUG=1 to print each board and both
       players' full colour histories.")
    else
      IO.puts("
    no unexplained disagreement about who is White.")
    end
  end

  # Rule of three again, on BOARDS rather than rounds. That denominator is
  # several times the composition bound's, so a clean colour run bounds the
  # references far more tightly than a clean composition run does - which is
  # the point, since this is the bound every other colour figure in the
  # project inherits.
  #
  # A board within 5.2.5's reach is still an observed difference between the
  # two references, so it disqualifies the clean branch exactly as an
  # exhaustion split disqualifies the composition one.
  defp reference_colour_bound(%{shared: 0}), do: :ok

  defp reference_colour_bound(totals) do
    if totals.agreed == totals.shared do
      bound = Float.round(300 / totals.shared, 5)

      IO.puts("
  the references never disagreed about colour on #{totals.shared} board(s); that
  bounds their true colour-disagreement rate at about #{bound}% (95%), not at zero")
    else
      differing = totals.shared - totals.agreed

      IO.puts("
  the references differ about colour on #{differing} of #{totals.shared} board(s)")
    end
  end

  # Crash sites, commonest first. `-v` makes Gacrux re-raise, so `detail` is
  # a real file:line rather than its uninformative "Program error" page, and
  # the sites turn out to mean different things - see the moduledoc.
  defp breakdown(rows, indent) do
    rows
    |> Enum.frequencies_by(& &1.detail)
    |> Enum.sort_by(fn {_detail, k} -> -k end)
    |> Enum.take(5)
    |> Enum.each(fn {detail, k} ->
      IO.puts("#{indent}#{k}x #{detail |> String.split(~r/\r?\n/) |> List.first()}")
    end)
  end

  # The rounds worth keeping are the ones where the REFERENCES differ from
  # each other. Those are the whole point: each is a case where the two
  # implementations this project calls ground truth cannot both be right,
  # and no two-way harness can ever surface one.
  defp dump(compared, splits, crashes) do
    case System.get_env("PAIRING_FUZZ_DUMP") do
      nil ->
        :ok

      dir ->
        disputes = Enum.reject(compared, & &1.bbp_gac)
        File.mkdir_p!(dir)

        # Capped, and the cap reports what it dropped - a directory listing
        # gets read as the finding, so it must not quietly be a sample.
        limit = env_int("PAIRING_FUZZ_DUMP_LIMIT", 200)
        {kept_disputes, dropped_disputes} = Enum.split(disputes, limit)
        {kept_splits, dropped_splits} = Enum.split(splits, limit)
        {kept_crashes, dropped_crashes} = Enum.split(crashes, limit)

        Enum.each(kept_disputes, &write_dispute(dir, &1))
        Enum.each(kept_splits, &write_split(dir, &1))
        Enum.each(kept_crashes, &write_crash(dir, &1))

        total = length(kept_disputes) + length(kept_splits) + length(kept_crashes)
        dropped = length(dropped_disputes) + length(dropped_splits) + length(dropped_crashes)

        if total > 0 do
          IO.puts("  #{total} dispute/split/crash file(s) written to #{dir}")
        end

        # "dispute" was the word here until crashes joined the same cap, and
        # it then printed "2276 further dispute(s) NOT dumped" on an axis
        # with ZERO disputes - a line that reads like a finding and is not
        # one. The counts are per kind, so say which kind ran over.
        if dropped > 0 do
          kinds =
            [
              {length(dropped_disputes), "dispute"},
              {length(dropped_splits), "split"},
              {length(dropped_crashes), "crash"}
            ]
            |> Enum.reject(fn {k, _} -> k == 0 end)
            |> Enum.map_join(", ", fn {k, name} -> "#{k} #{name}(s)" end)

          IO.puts("  NOT dumped (cap #{limit} per kind): #{kinds}")
        end
    end
  end

  defp write_dispute(dir, r) do
    base = Path.join(dir, "seed#{r.seed}_r#{r.round}_p#{r.player_count}")
    File.write!(base <> ".trf", r.trf)

    File.write!(base <> ".txt", """
    seed #{r.seed}, round #{r.round}, #{r.player_count} players

    bbpPairings: #{inspect(Enum.sort(r.bbp))}
    Gacrux:      #{inspect(Enum.sort(r.gac))}
    Ainalrami:   #{inspect(summarise(r.ours))}

    agreement: ainalrami/bbp #{r.ours_bbp}, ainalrami/gacrux #{r.ours_gac}
    """)
  end

  defp write_split(dir, r) do
    base = Path.join(dir, "split_seed#{r.seed}_r#{r.round}_p#{r.player_count}")
    File.write!(base <> ".trf", r.trf)
    paired = if r.refused == :bbp, do: r.gac, else: r.bbp

    File.write!(base <> ".txt", """
    seed #{r.seed}, round #{r.round}, #{r.player_count} players

    #{r.refused} found NO legal pairing for this position.
    The other reference paired it as: #{inspect(Enum.sort(paired))}

    One of the two is wrong about whether this round is pairable at all.
    """)
  end

  defp write_crash(dir, r) do
    base = Path.join(dir, "crash_seed#{r.seed}_r#{r.round}_p#{r.player_count}")
    File.write!(base <> ".trf", r.trf)

    File.write!(base <> ".txt", """
    seed #{r.seed}, round #{r.round}, #{r.player_count} players

    #{r.who} raised inside the checker and wrote `### Error 510` to its own
    output file, exiting 0. It gave no answer for this position, so this
    round is in NO rate - it is not a refusal and not a disagreement.

    #{r.detail}

    Reproduce (`-v` makes it re-raise instead of swallowing):
      python3 $GACRUX_DIR/pairingchecker.py -i #{Path.basename(base)}.trf \\
        -o /tmp/out.txt -p -dT -m dutch -v
    """)
  end

  defp format_error(r) do
    """
    seed #{r.seed}, round #{r.round}, #{r.player_count} players
      bbpPairings: #{inspect(r.bbp)}
      Gacrux:      #{inspect(r.gac)}
    """
  end

  defp summarise(:raised), do: :raised
  defp summarise(pairs), do: Enum.sort(pairs)
end

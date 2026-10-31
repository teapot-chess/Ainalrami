defmodule Ainalrami.Trf.ValidationError do
  @moduledoc """
  Raised by `Ainalrami.Trf` when a player's round-by-round game data contains
  an illegal FIDE result: an unrecognized result code, or a result that is
  inconsistent with the opponent's own recorded result for the same round
  (e.g. both sides claim a win, or both sides are marked forfeit-win).
  """
  defexception [:message]
end

defmodule Ainalrami.Trf.UnknownResultError do
  @moduledoc """
  No longer raised, since v0.44.0. Until then `Ainalrami.Trf` raised it when
  the `?` unknown-result code reached `points_for/2` without a declared
  `162` `X`, or `game_was_played?/1` at all; both now answer as TRF-2026
  does (see `Ainalrami.Trf`'s moduledoc, "The `?` unknown result"). Kept
  defined so that a caller's `rescue` of it still compiles - it simply
  never fires.
  """
  defexception [:message]
end

defmodule Ainalrami.Trf do
  @moduledoc """
  FIDE TRF16 (Tournament Report File) serializer and parser, per the official
  specification: https://www.fide.com/FIDE/handbook/C04Annex2_TRF16.pdf

  All column positions are 1-indexed and inclusive, exactly as printed in the
  spec. This is Ainalrami's file format for both directions: the roster/result
  history it's asked to pair, and the paired output it writes back - same
  format JaVaFo itself reads and writes, so a TRF file built for one engine
  works unmodified for the other.

  Both `serialize/1` and `parse/1` validate every player's per-round result
  codes before returning, raising `Ainalrami.Trf.ValidationError` on an
  unrecognized code or an illegal combination between two opponents (see
  `validate_games!/2`). Validation only cross-checks a pairing when both
  sides are present in the given player set and mutually reference each
  other for that round - a lone/dangling reference is not itself an error.

  Ported from the sibling project (`teapot-chess/openpairings`)'s own
  `PairingsEngine.Trf`, which fixed two real bugs against FIDE's actual
  archived TRF06 specs (Annexure-B/2006, Annexure-C/2016) - the
  `allow_dangling_playing_code` tolerance and the `parse_games/1` blank-round
  handling below both come directly from that work, not reinvented here.

  ## Two dialects

  `serialize/2` writes one of two spellings of the same file, chosen with
  `dialect:`:

    * `:engine` (the default) - what the pairing programs read: JaVaFo's
      `XXR`/`XXP`/`XXA` extension lines and bbpPairings' `BB*` point
      directives. Byte for byte what this module has always written, and
      what the comparison corpus is measured on.
    * `:trf26` - FIDE's Tournament Report File Format Version 2026
      (approved 12 May 2025, applied from 1 September 2025), the file an
      arbiter uploads: `142` for the round count, `162` for the points,
      `250` and `260` for acceleration and prohibited pairings, `240` for a
      bye granted for a round not yet paired, `299` for what `162` cannot
      say, and the `192`/`202`/`212`/`222` headers.

  `parse/1` reads both, and reads them to the same players - so a round
  paired from either spelling of one tournament is the same round. The
  reference programs read only the first, which is why it is a dialect and
  not a replacement.

  ## The `?` unknown result

  `?` says there was a game and its result is not on record - the lost
  scoresheet of a historical event, which is what FIDE's TRF-26 ITDX
  conventions give the symbol for. It is READ and never written, and it is
  interchangeable with nothing else here:

    * a BLANK column means no result has been recorded YET, which is a
      statement about the file. `?` is a statement about the tournament, and
      `parse/1` keeps the two apart: a blank still comes back as `nil`, a
      `?` comes back as `"?"`;
    * an INVALID code is still invalid. The other available reading - that
      any code a reader does not recognize means "unknown" - converts a
      corrupt file into a plausible one, which is the failure mode hardest
      to notice, and it is the reading this engine argued against when FIDE
      consulted on the draft. `validate_game!/5` refuses an unrecognized
      code exactly as it always did.

  What it is worth and whether it was played are FIDE's questions, and
  since v0.44.0 this module takes FIDE's answers rather than refusing both:

    * `points_for/2` and `points_for_game/2` return the file's own `162`
      `X` - TRF-2026's value for an unknown result, "like for instance in an
      adjourned game" - stored under the point system's `:unknown` key by
      `parse_point_system/2`; and, when the file declares no `X`, a draw's
      points, which is the default the same line of the specification
      gives. Before v0.44.0 an undeclared `X` raised
      `Ainalrami.Trf.UnknownResultError`, on the grounds that assuming a
      draw was inventing a value. It is not: the value is the format's,
      stated in the record that defines the symbol, and FIDE's checklist
      for pairing programs counts a pending adjourned game as a draw
      (VCL4THP Q167). The superseded reasoning is kept in the CHANGELOG,
      under 0.26.1;
    * `game_was_played?/1` answers `true`. The `001` record that carries
      a `?` carries an opponent and a colour with it, and the game it
      stands for - the specification's own example is the adjourned game -
      sat down at a board with those colours. Colour history
      and C2's bye eligibility are built on this predicate, so both count
      the game as the one it was. Before v0.44.0 this raised too, which made
      every tournament with a `?` in a decision unpairable - the engine's
      own `Ainalrami.Tiebreaks.Event` had been counting the same game as
      played all along;
    * `participated_in_pairing?/1` is unchanged: a `?` carries an opponent,
      so the player was in the pairing.

  What is still refused is the other reading FIDE was argued out of: an
  invalid code is not an unknown result. `validate_game!/5` refuses an
  unrecognized code exactly as it always did, and `?` against anything but
  `?` is a contradiction, not a lost result.

  `Ainalrami.Trf.UnknownResultError` is no longer raised by anything in
  this library; it stays defined so a caller's `rescue` still compiles.

  `serialize/1` refuses `?` in BOTH dialects. This engine has no unknown
  results of its own to report - it writes pairings it computed and history
  it was handed - and a writable `?` is a placeholder waiting to be used for
  "not entered yet", which is what the blank column already means. The price
  is that a file carrying `?` does not round-trip through this module;
  `validate_games!/2`'s `allow_unknown_result` option is the single switch
  that would have to be opened for it to.

  `parse/1` takes `?` from either dialect, because it does not know which
  dialect it is reading - the round blocks of a `001` line are byte
  identical in both, and only the header records differ. Refusing it in an
  `:engine`-spelled file would mean guessing at the writer's intent from
  records that have nothing to do with the game.

  ## The `XX*` extension lines

  Five of JaVaFo's own `XX` extension codes are read; two of them are
  written by default. The three that are not - `XXR`, `XXC` and `XXZ` -
  each have another spelling that `serialize/1` emits in their place, and
  each is written on request (`serialize/2`'s `:xxr`, `:xxc` and `:xxz`)
  for a file JaVaFo will read:

    * `XXR n` - the round count (see `parse_xxr/2`), which is the same field
      as TRF16's `142`. A file may carry both spellings, but they must
      AGREE: two different counts are refused rather than silently resolved,
      since every implementation resolves them differently. `serialize/2`
      emits `142` by default, so a file that came in with `XXR` goes out
      with `142` unless the caller asks for `xxr: true` - the value always
      round-trips, the spelling only when asked for. It has to be askable:
      JaVaFo reads `XXR` and not `142`, so a file written for JaVaFo with
      the default spelling carries no round count that reader can see.
    * `XXP a b [c ...]` - a mutually-forbidden GROUP of players
      (see `parse_xxp/2`), surfaced as `tournament[:forbidden_pairs]`.
    * `XXA` - per-player acceleration/virtual points, round by round
      (see `parse_xxa/2`), surfaced as each player's `:accelerations`.
    * `XXC white1|black1` - the colour drawn by lot before round 1 (see
      `parse_xxc/2`), the same field as TRF16's `152`. READ ONLY for the
      same reason `XXR` is: the value round-trips, the spelling does not.
      `XXC rank` is a third setting on the same line and RAISES, because
      this engine cannot honour it.
    * `XXZ r1 r2 ...` - the players absent from the round about to be
      paired (see `parse_xxz/2`), which is what Swar writes. Read as a
      `0000 - Z` in that round's column, so every pairing path sees the
      same thing it sees for the column; a rank the file does not have, or
      one whose column already holds a game or a bye, raises. TRF26 says
      it with `240 Z`.

  Two more are this engine's own, for what OpenPairings pairs and neither
  TRF16 nor TRF26 can say. Both are read and written in either dialect:

    * `XXM` - match format: every match is two games in a row, colours
      reversed in the second (OpenPairings' `swiss_match_format` and
      `rr_match_format`). Surfaced as `tournament[:match_format]` (`true`).
      In a Swiss the odd rounds are paired and each even round replays the
      round before it with the colours reversed; in a round robin rounds
      `2k - 1` and `2k` are round `k` of a single Berger table. Nothing may
      follow the code.
    * `XXG a b [c ...]` - one pairing group: a category paired on its own
      (OpenPairings' `pair_by_category`). One line per group, in the order
      the groups are paired and their boards numbered; players on no line
      form a last group of their own. Surfaced as
      `tournament[:pairing_groups]`, a list of rank lists. A rank the file
      does not have, or one in two groups, raises `ValidationError`.

  `Ainalrami.EventFormat` and `Ainalrami.RoundRobin` pair by them.

  ## The organiser's records

  One more code, also this engine's own and also read and written in
  either dialect: `XXO keyword ...`, for the options OpenPairings pairs and
  ranks with that no TRF record carries. The keywords are the command
  line's own names. All but the last carry options that are NOT FIDE's - a
  round they change is not a Dutch-system round, and whoever pairs from
  them says so:

    * `XXO soft-pairs a b [c ...] [@ROUND | @FIRST-LAST]` - a soft group:
      players to keep apart where the criteria allow it, for every round or
      the rounds named. Surfaced as `tournament[:soft_pairs]`, in the shape
      `Ainalrami.Pairing`'s `:soft_pairs` takes.
    * `XXO soft-position strong|weak` - `:soft_position`
      (`tournament[:soft_position]`).
    * `XXO bye-want|bye-want-soft|bye-avoid-soft|bye-avoid rank[@ROUNDS] ...`
      - the four bye preferences (`tournament[:bye_preferences]`, as
      `Ainalrami.ByePreference` takes them). `ROUNDS` is `3`, `3-5` or
      several joined by `+`.
    * `XXO team-forbidden a b [c ...] [@ROUND | @FIRST-LAST]` - a team
      event's `XXP`: TEAM numbers (the `310` numbers, file order for `013`
      teams) that must not meet, for every round or the rounds named.
      `XXP` names players, so it cannot say this. Surfaced as
      `tournament[:team_forbidden_pairs]`, in the shape
      `Ainalrami.TeamPairing`'s `:forbidden_pairs` takes.
    * `XXO team-soft-pairs a b [c ...] [@ROUND | @FIRST-LAST]` - teams to
      keep apart where no C.04.6 criterion minds
      (`tournament[:team_soft_pairs]`, `Ainalrami.TeamPairing`'s
      `:soft_pairs`). Both team records are checked against the file's
      teams when a team round is paired or replayed, not here.
    * `XXO bye-exclude rank[@ROUNDS] ...` - the plain bye exclusion
      (`tournament[:bye_exclusions]`: a rank, or `{rank, rounds}`).
    * `XXO round-ratings rank rating rating ...` - the rating the player
      held in each round, `-` or `0` for none, for an event whose
      regulations count the rating tie-breaks that way (C.07 Article 10's
      note). Surfaced as the player's `:round_ratings`,
      `%{round => rating}`.
    * `XXO provisional-rating rank rating` - the provisional rating the Chief
      Arbiter assigned an unrated player, which the Dubov system (C.04.4.1
      1.1.2) pairs by (`tournament[:provisional_ratings]`, `%{rank => rating}`).

  One code, not one per option, because each new `XX` code is a chance of
  meaning something else to another program: `XXS` would have been the
  obvious name for soft pairs and is JaVaFo's point system.

  `Ainalrami.PairingInput` has the spelling and turns the first four into
  engine options. A malformed line, a keyword `XXO` does not have and a
  rank the file does not have raise `ValidationError`. A file with no `XXO`
  line parses to exactly what it parsed to before the code existed: the
  keys are absent, not empty.

  Anything else beginning `XX` still falls through `parse_header_line/3`'s
  `nil -> acc` clause and is ignored - with a warning on stderr naming the
  line, since 0.44.1. Ignoring is right for a genuinely unknown code; doing
  it in silence is how `XXZ` went unread for as long as it did. It was
  WRONG outright for these two: an
  arbiter's `XXP` "these two must never meet" was dropped on the floor and
  the engine then returned a complete, perfectly legal-looking pairing that
  seated them together, with nothing downstream able to detect it. That is
  why the sibling project had to refuse to pair any TRF carrying a
  non-`XXR` `XX` line at all.

  For the same reason, a MALFORMED `XXP`/`XXA` line raises
  `Ainalrami.Trf.ValidationError` rather than being skipped - see
  `parse_xxp/2`. bbpPairings does the same (`InvalidLineException`, exit
  code 3); a MALFORMED `XXR` is the exception, and can afford to be
  ignored, because a missing round count has a fallback and a missing
  exclusion does not. A CONTRADICTED round count is a different thing
  again and does raise - see `check_round_count_agreement!/2`.
  """

  alias Ainalrami.Trf.ValidationError

  @player_cols %{
    code: {1, 3},
    starting_rank: {5, 8},
    sex: {10, 10},
    title: {11, 13},
    name: {15, 47},
    fide_rating: {49, 52},
    federation: {54, 56},
    fide_number: {58, 68},
    birth_date: {70, 79},
    points: {81, 84},
    rank: {86, 89}
  }

  @team_cols %{code: {1, 3}, name: {5, 36}}

  # TRF26 `362`'s symbols, in the order they are written.
  @team_symbols [
    {"W", :win},
    {"D", :draw},
    {"L", :loss},
    {"P", :pab},
    {"A", :absent},
    {"X", :unknown}
  ]

  @header_codes %{
    name: "012",
    city: "022",
    federation: "032",
    start_date: "042",
    end_date: "052",
    number_of_players: "062",
    number_of_rated_players: "072",
    number_of_teams: "082",
    type: "092",
    chief_arbiter: "102",
    deputy_arbiter: "112",
    time_control: "122",
    # Not in the official TRF16 spec, but real-world precedent from
    # Swiss-Manager (which already emits both) - optional/additive, an
    # unrecognized header code is already silently ignored by
    # `parse_header_line/3`, so including them never breaks a TRF16-only
    # reader.
    number_of_rounds: "142",
    round_dates: "132",
    # TRF-2026's initial-piece-colour field: the colour drawn by lot before
    # round 1 (C.04.3 5.1), which 5.2.5 hands to the higher ranked player of
    # a pair when neither holds a preference - and hands them on the parity
    # of their ARRIVAL NUMBER, not of their TPN, per the SPP's 2026-08-27
    # ruling (see `Ainalrami.Pairing`'s `arrival_numbers/2`). Parsed as
    # `"w"`/`"b"` into `tournament[:initial_colour]`.
    #
    # It was not read at all until 2026-08-17: the engine assumed White
    # unconditionally, so a file specifying Black was paired with every
    # no-preference colour inverted, and no test could see it because the
    # harness only ever wrote `152 W`.
    initial_colour: "152",
    generator: "182",
    # TRF26 (FIDE Council 12 May 2025, applied from 1 September 2025): the
    # encoded tournament type (`tournament_type_codes/0`), the tie-breaks
    # in use, the standings order, and the encoded time control. Written
    # in either dialect when given; read from any file.
    type_code: "192",
    tie_breaks: "202",
    standings_order: "212",
    time_control_code: "222"
  }

  @type_labels %{
    "swiss" => "Individual: Swiss System",
    "roundrobin" => "Individual: Round Robin System",
    "team-swiss" => "Team: Swiss System",
    "team-roundrobin" => "Team: Round Robin System"
  }

  @result_codes %{
    win: "1",
    draw: "=",
    loss: "0",
    forfeit_win: "+",
    forfeit_loss: "-",
    half_point_bye: "H",
    full_point_bye: "F",
    pairing_allocated_bye: "U",
    zero_point_bye: "Z",
    # A game that WAS contested but does not reach the rating report -
    # typically one that ended before the minimum number of moves
    # (VCL4THP Q185). Scored and paired exactly like "1"/"="/"0", which is
    # bbpPairings' reading too: W/D/L are absent from its
    # `gameWasPlayed = false` list (`trf.cpp:278-286`) and are scored
    # through the same WIN/DRAW/LOSS branch as the symbols
    # (`trf.cpp:252-270`).
    #
    # They are published because both directions carry them: a caller
    # building a file has no other way to say "played, not rated", and
    # `parse/1` hands the letter back untouched rather than folding it into
    # its symbol - see `parse_game_at_round/2` for why a reader that folds
    # is a reader that loses the only thing they encode.
    unrated_win: "W",
    unrated_draw: "D",
    unrated_loss: "L",
    # FIDE's TRF-26 ITDX symbol for a game whose result is not on record.
    # The one published code `serialize/1` will not write and `points_for/2`
    # will not score - see the moduledoc's "The `?` unknown result" for both
    # refusals and for why they are refusals rather than defaults.
    unknown: "?"
  }

  def result_codes, do: @result_codes

  @bb_codes ~w(BBW BBD BBL BBZ BBF BBU)

  @bb_fields %{
    "BBW" => :win,
    "BBD" => :draw,
    "BBL" => :loss,
    "BBZ" => :zero_point_bye,
    "BBF" => :forfeit_loss,
    "BBU" => :pairing_allocated_bye
  }

  @doc """
  The standard 1 / ½ / 0 point system, and what every caller gets unless a
  file says otherwise.

  `pairing_allocated_bye` is separate from `win` even though both are 1.0
  here, because it is the one an organiser is most likely to move: FIDE
  permits valuing the bye at a half point, and bbpPairings exposes it as
  its own `BBU` directive for exactly that reason.
  """
  def default_point_system do
    %{
      win: 1.0,
      draw: 0.5,
      loss: 0.0,
      pairing_allocated_bye: 1.0,
      forfeit_loss: 0.0,
      zero_point_bye: 0.0
    }
  end

  @doc """
  What a single result code is worth.

  With one argument, under the standard 1 / ½ / 0 system. With a point
  system (see `default_point_system/0`), under that one.

  The split follows bbpPairings' `getPoints` (`tournament.h:310-322`)
  exactly, because the two engines have to agree on a player's SCORE before
  they can agree on a bracket:

    * `1` `W` `+` `F` - a win, a forfeit win, and an arbiter's full-point
      bye all pay `:win`. `F` looks like a bye but is not the pairing's:
      its `participatedInPairing` is false, so it misses the
      pairing-allocated branch and falls through to the ordinary win.
    * `U` - the PAIRING's own bye, and the only code that pays
      `:pairing_allocated_bye`.
    * `=` `D` `H` - a draw and a half-point bye are the same value; there is
      no separate half-point-bye setting in this system.
    * `0` `L` - a played loss pays `:loss`.
    * `-` - a forfeit loss pays `:forfeit_loss`, which an organiser may set
      above zero even though a played loss is zero.
    * `?` - the declared `X` value from the file's own `162` line, under the
      `:unknown` key `parse_point_system/2` stores it in - or, if the file
      declared none, a draw's points, which is the default TRF-2026 gives
      `X` (see the moduledoc). Never the blank-and-`Z` default below, which
      would quietly assert that the player scored nothing.
    * anything else, `Z` and a blank included - `:zero_point_bye`.
  """
  def points_for(result), do: points_for(result, default_point_system())

  # `+`, `F` and `H` pay the win, the win and the draw unless a TRF26 `299`
  # record has given them a value of their own - `forfeit_win`,
  # `full_point_bye`, `half_point_bye`, absent from `default_point_system/0`
  # so that every existing caller sees exactly what it always saw.
  def points_for("+", points), do: Map.get(points, :forfeit_win) || points.win
  def points_for("F", points), do: Map.get(points, :full_point_bye) || points.win
  def points_for("H", points), do: Map.get(points, :half_point_bye) || points.draw
  def points_for(result, points) when result in ~w(1 W), do: points.win
  def points_for("U", points), do: points.pairing_allocated_bye
  def points_for(result, points) when result in ~w(= D), do: points.draw
  def points_for(result, points) when result in ~w(0 L), do: points.loss
  def points_for("-", points), do: points.forfeit_loss

  # Before the catch-all, and that ORDER is the whole guarantee: `?` would
  # otherwise fall through to `zero_point_bye` and be scored as a nought,
  # which is exactly the silent conversion of a file that says "not known"
  # into one that says "lost". `:unknown` is only ever present because the
  # file's own `162` line declared an `X` (`parse_point_system/2`); without
  # one, the draw is TRF-2026's own default for `X`, not this engine's.
  def points_for("?", points), do: Map.get(points, :unknown) || points.draw

  def points_for(_result, points), do: points.zero_point_bye

  @doc """
  What a single GAME is worth - the result code read together with whether
  it had an opponent.

  `points_for/2` maps the code alone, and for two opponentless codes that is
  not enough. bbpPairings' `getPoints` (`tournament.h:310-322`) reads
  `match.opponent == player.id` and `match.participatedInPairing` as well as
  the score, and `participatedInPairing` is built at `trf.cpp:303` as
  `opponent != id || resultChar == 'U' || resultChar == '+'`. Two
  combinations come out differently:

    * `0000 - +` - an arbiter's forfeit WIN with nobody on the other side.
      It counts as having taken part in the pairing (`+` is on that list),
      so it lands in the pairing-allocated-bye branch, not the ordinary
      win one.
    * `0000 - -` - a forfeit LOSS with nobody on the other side. `-` is
      NOT on that list, so it did not take part, and a non-participating
      loss is a zero-point bye rather than a forfeit loss.

  Under the standard system both distinctions are invisible (a win and a
  pairing-allocated bye are both 1, a forfeit loss and a zero-point bye
  both 0), which is why 488M fuzzed pairings never saw them - the generator
  only ever writes `-` against a real opponent. They separate the moment a
  file sets its own values with `BBW`/`BBU`/`BBF`, and then they separate a
  player's SCORE, which decides their bracket.

  Every other combination agrees with `points_for/2`, and the ones that do
  not appear here are the ones bbpPairings rejects outright: `0000 - 1`,
  `0000 - 0` and a bare `Z` against an opponent are all invalid lines.

  `?` reaches `points_for/2` in every combination and behaves exactly as it
  does there, opponent or none: the file's own `162` `X`, or a draw when it
  declared none. Reading the
  opponent could not help either way - knowing that a game had two seats
  says nothing about what an unknown result was worth.
  """
  def points_for_game(game), do: points_for_game(game, default_point_system())

  def points_for_game(game, points) do
    case {Map.get(game, :opponent_rank), Map.get(game, :result)} do
      {nil, result} when result in ~w(+ U) -> points.pairing_allocated_bye
      {nil, "-"} -> points.zero_point_bye
      {_opponent, result} -> points_for(result, points)
    end
  end

  @doc """
  Whether a result code represents a game that was actually PLAYED.

  bbpPairings sets `gameWasPlayed = false` for exactly `+ - H F U Z` and a
  blank (`trf.cpp:278-286`); `W`, `D` and `L` are absent from that list, so
  they are letter spellings of ordinary played results rather than unplayed
  ones. Several rules turn on this distinction, C2's bye eligibility among
  them.

  `?` is played. Its record names the opponent and the colour, and the
  game TRF-2026 gives as its example - the adjourned one - was sat down to
  with them; what is not known is how it ended, which is `points_for/2`'s
  question and not this one. `false` would file it with the forfeits and
  the byes, FIDE Art. 16's unplayed games, and hand the same colour twice
  in a row to a player who already had it. (Before v0.44.0 this raised
  `Ainalrami.Trf.UnknownResultError`; see the moduledoc.)
  """
  def game_was_played?(nil), do: false
  def game_was_played?("?"), do: true

  # The seven codes every tournament is made of answer without the trim
  # below: this predicate sits under the pairing engine's colour, float and
  # rematch rules and is asked hundreds of thousands of times a round, and
  # `String.trim/1` was most of what it cost. Both lists are exactly what
  # the general clause answers for them.
  def game_was_played?(result) when result in ~w(1 0 = W D L), do: true
  def game_was_played?(result) when result in ~w(+ - H F U Z), do: false

  def game_was_played?(result),
    do: result not in ~w(+ - H F U Z) and String.trim(result) != ""

  @doc """
  How many rounds the whole field has been paired for; the round to pair
  next is one more.

  The base is the last round in which anybody took part in the pairing
  (`participated_in_pairing?/1`). A trailing column that is complete for
  the WHOLE field - everyone has a game there, byes included - is a round
  already fully decided, so it counts as played and the count advances; one
  player holding a pre-recorded bye for the next round leaves everyone
  else's history shorter, and nothing advances. That is the rule the
  pairing engine has always applied (found via
  `crash_reports/seed4385-r5-p4.trf`, see `Ainalrami.Pairing`), and the
  TRF26 writer needs the same count to tell a bye that belongs in a column
  from one that belongs in a `240` record.
  """
  def rounds_played(players) do
    base = players |> Enum.map(&paired_through/1) |> Enum.max(fn -> 0 end)

    if players != [] and Enum.all?(players, &(length(&1[:games] || []) > base)) do
      base + 1
    else
      base
    end
  end

  defp paired_through(player) do
    (player[:games] || [])
    |> Enum.with_index(1)
    |> Enum.filter(fn {game, _round} ->
      participated_in_pairing?(%{opponent_rank: game[:opponent_rank], result: game[:result]})
    end)
    |> Enum.map(fn {_game, round} -> round end)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Whether the player took part in the PAIRING for this game, as opposed to
  having a result recorded for them without being paired.

  This is what distinguishes an arbiter-assigned bye (half-point,
  zero-point, full-point - granted before the round is paired, so the
  player is left out of it) from a pairing-allocated bye, which the
  pairing itself produced. bbpPairings expresses the same test as
  `opponent != id || resultChar == 'U' || resultChar == '+'`
  (`fileformats/trf.cpp:303`).

  This is the one question a `?` game answers without complaint. It carries
  an opponent, so the player was in the pairing, and what became of the game
  afterwards does not bear on it. `rounds_played/1` is built from this
  predicate alone, which is why a file with an unknown result can still say
  how far the tournament has been paired.
  """
  def participated_in_pairing?(game) do
    not is_nil(game.opponent_rank) or game.result in ~w(U +)
  end

  # TRF16 result codes for an actually-contested game (win/draw/loss/forfeit)
  # vs. an unpaired round (byes of every kind). A forfeit is legally
  # "unplayed" per FIDE Art. 16, but it still occupies a pairing slot (an
  # opponent), unlike a bye - so the two groups get different validation.
  #
  # `W`/`D`/`L` are on the playing list because they are ordinary played
  # results spelled with letters (see `@result_codes`), and this list was
  # the one place in the file that said otherwise: `points_for/2` above
  # scores them as win/draw/loss and `game_was_played?/1` calls them played,
  # while `validate_game!/5` refused them as unrecognized. The contradiction
  # stayed hidden on the READING side only while the parser rewrote the
  # letters into symbols before validation ever ran; `serialize/1` had no
  # such rewrite, so the writer rejected exactly the input its own scorer
  # accepts, and a caller handing in a played-but-unrated game got a
  # `ValidationError` naming a code this module documents. The rewrite is
  # gone too (`parse_game_at_round/2`), so this list is now what both
  # directions are measured against.
  @playing_codes ~w(1 = 0 + - W D L)
  @bye_codes ~w(H F U Z)

  # The read-only third category. `?` sits with neither list because it
  # belongs to neither question those two answer: it is not a result the
  # writer may emit (so it is outside `bye_codes/0`'s "the complement of
  # `playing_codes/0` over everything `serialize/1` accepts"), and it is not
  # something a scorer may treat as a played game.
  @unknown_codes ~w(?)

  # Codes that occupy an OPPONENT's slot. The structural rules are identical
  # for a playing code and for `?` - there has to be somebody on the other
  # side, and the two sides have to agree about what happened - so they are
  # validated together. What separates them is only what the result is
  # WORTH, which is `points_for/2`'s question and not the validator's.
  @opposed_codes @playing_codes ++ @unknown_codes

  @doc """
  The TRF16 result codes for a round the player was PAIRED in: a played game
  (`1` `=` `0`, and the unrated letter spellings `W` `D` `L` of the same
  three) or a forfeit (`+` `-`), which FIDE Art. 16 calls unplayed but which
  still occupies an opponent's slot.

  Published because this list is the one thing a caller must agree with this
  module about, and every private copy of it so far has drifted. The sibling
  app (`teapot-chess/openpairings`) grew two - a standings presence rule and
  a compile-time `@playing_codes` in its TRF importer - both spelled
  `~w(1 = 0 + -)` back when that was the whole list, and both then quietly
  stopped treating an unrated game as a game: the importer left those rounds
  unpaired, and standings counted them as absences. Neither copy was wrong
  on the day it was written, which is exactly the failure mode - a private
  list cannot be corrected by fixing the canonical one.

  `?` is deliberately absent, even though a `?` game does occupy an
  opponent's slot. Every existing caller reads this list to decide what to
  SCORE or IMPORT, and an unknown result can be neither; adding it here
  would have changed those callers' behaviour silently, which is the one
  thing publishing the list was meant to prevent. Ask `unknown_result?/1`
  instead.
  """
  def playing_codes, do: @playing_codes

  @doc """
  The TRF16 codes for a round the player was NOT paired in: the half-point,
  full-point, pairing-allocated and zero-point byes.

  The complement of `playing_codes/0` over everything `serialize/1` accepts,
  and exported alongside it because deciding what a round MEANS needs both
  halves - `playing_codes/0` on its own cannot tell a bye from a code this
  module would refuse.

  That complement is still exact with `?` in the world, because `?` is a
  code `serialize/1` does not accept. The two lists partition what may be
  WRITTEN; `result_codes/0` is what may be READ, and it is one entry larger.
  """
  def bye_codes, do: @bye_codes

  @doc """
  Whether a result code says the result is not known: true for `?` and for
  nothing else.

  Not true for `nil` or a blank, which is the distinction the whole code
  exists to make. A blank column is an ABSENT result - the round has not
  been played, or the file has not caught up - and a caller may sensibly
  wait for it. `?` is a PRESENT statement that the result is lost, and
  waiting will not produce one.

  `points_for/2` and `game_was_played?/1` answer for it (the file's `X`, or
  a draw; played) - this is the predicate for a caller that has to SAY the
  result is not known, a crosstable or a report, rather than score it.
  """
  def unknown_result?(result), do: result in @unknown_codes

  # Legal opponent-result for each of this player's playing codes. A win
  # ("1") only pairs with a loss ("0"); a played "0-0" (both players lose,
  # e.g. both defaulted after making moves) is two losses, so "0" also
  # legally pairs with "0". A double forfeit is "-"/"-"; a single forfeit is
  # "+"/"-". A draw ("=") also legally pairs with a loss ("0") - an
  # asymmetric ½-0/0-½ (an arbiter's disciplinary point adjustment on an
  # otherwise-drawn game, not a chess outcome the TRF spec itself
  # distinguishes with its own code - it's still just "=" and "0" per
  # player, only no longer required to mirror). Anything else (both win,
  # both forfeit-win, a win against a draw, etc.) is impossible and
  # rejected.
  #
  # The unrated letters mirror the symbols they spell and pair only with
  # each other. Whether a game reaches the rating report is a property of
  # the GAME, not of a seat in it, so it cannot be rated for White and
  # unrated for Black: `W`/`0` and `D`/`=` are not legal halves of one
  # result, and a file carrying them has two players disagreeing about what
  # happened rather than one unusual game.
  #
  # `?` pairs only with `?`, and that is a real constraint rather than a
  # placeholder. Knowing one seat's result is knowing the other's - a win on
  # one board is a loss on the other - so a file that spells one side `?`
  # and the other `1` is not a file with one lost result. It is two records
  # of the same game that contradict each other, and the whole point of
  # having the symbol is to refuse to smooth that over.
  @legal_result_pairs %{
    "1" => ["0"],
    "0" => ["1", "0", "="],
    "=" => ["=", "0"],
    "+" => ["-"],
    "-" => ["+", "-"],
    "W" => ["L"],
    "L" => ["W"],
    "D" => ["D"],
    "?" => ["?"]
  }

  # Round blocks repeat every 10 columns starting at column 92 (round 1):
  # opponent id at base..base+3, colour at base+5, result at base+7.
  defp round_cols(round) do
    base = 92 + (round - 1) * 10
    %{id: {base, base + 3}, colour: {base + 5, base + 5}, result: {base + 7, base + 7}}
  end

  # The "132" round-dates line uses the same cadence with 8-char YY/MM/DD slots.
  defp round_date_cols(round) do
    base = 92 + (round - 1) * 10
    {base, base + 7}
  end

  # Team player slots repeat every 5 columns starting at column 37.
  defp team_player_cols(slot) do
    base = 37 + (slot - 1) * 5
    {base, base + 3}
  end

  # `XXA` is FIXED-COLUMN, unlike the free-form `XXR`/`XXP` extension lines
  # next to it, and the columns are not negotiable in either direction.
  #
  # bbpPairings' `readPlayerAccelerationsXxa` (`trf.cpp:487-514`) reads the
  # starting rank from `line[4]..line[8)` - 0-indexed, so columns 5-8 - and
  # then walks `startIndex = 9; startIndex += 5`, reading four characters at
  # each stop: columns 10-13, 15-18, 20-23, i.e. `10 + 5*(r-1)` for round
  # `r`, with a single separator column between fields. That is exactly the
  # JaVaFo 2.2 Advanced User Manual's own spec ("XXA NNNN pp.p pp.p ...",
  # `NNNN` at column 5, each `pp.p` at column `10 + 5*(r-1)`).
  #
  # The sibling project confirmed by direct experiment that free-form `XXA`
  # crashes real javafo with a bare NullPointerException while the
  # fixed-column form runs clean - see `acceleration_lines/4`'s docs in
  # `../openpairings`. Its own emitter, however, right-aligns the rank in a
  # FIVE-column field (cols 5-9) and each value in a five-column field
  # (10-14, 15-19, ...), which is one column wider than the spec at every
  # stop; javafo evidently tolerates that, bbpPairings does not (it reads
  # four blanks where the rank should be). The widths below are the spec's,
  # and are what bbpPairings actually round-trips.
  @xxa_rank_cols {5, 8}

  defp xxa_points_cols(round) do
    base = 10 + (round - 1) * 5
    {base, base + 3}
  end

  ## ---------- Serializing ----------

  @doc """
  Serializes to TRF16 text.

      serialize(%{
        tournament: %{name: ..., city: ..., type: "swiss", ...},
        players: [%{rank: 1, name: ..., points: 2.5,
                    games: [%{opponent_rank: 2, colour: "w", result: "1"}]}],
        teams: [%{name: ..., player_ranks: [1, 2]}]
      })

  `opts[:column_legend]`: when true, inserts the ruler/field-code lines
  Swiss-Manager prepends to its own TRF exports (a `DDD SSSS sTTT NNN...`
  legend plus two column-position rulers) right before the player rows -
  purely a human-readability courtesy, no header code of its own, and
  safely ignored by any TRF16 reader (including `parse/1`, since these
  lines don't start with a recognized 3-digit code). `:line` writes the
  legend alone, without the two rulers, as Swiss-Manager's rating files
  do. Off by default.

  `opts[:ascii]`: when true, folds every string in `data` to ASCII
  (é -> e, ß -> ss) before any of it is placed in a column, so that one
  character is one byte again and no accent can shift the fields to its
  right - see `maybe_fold_ascii/2` for the damage that does and for why
  this is off by default. Set it for a file that leaves the building (a
  FIDE submission, an arbiter's printout); leave it off for a file an
  engine reads back.

  A player carrying `:accelerations` (a list of virtual-point values, one
  per round from round 1) gets an `XXA` line, and
  `tournament[:forbidden_pairs]` (a list of mutually-forbidden starting-rank
  GROUPS) becomes one `XXP` line per group. Both are emitted after the
  player/team rows, and both round-trip through `parse/1`.

  `opts[:xxr]`: write `tournament[:number_of_rounds]` as JaVaFo's `XXR n`
  extension line INSTEAD of TRF16's `142 n` header. Off by default, and it
  is the caller's knowledge of its reader that decides: the two are the
  same field (see the moduledoc), but only one of them reaches JaVaFo.
  `142` is a Swiss-Manager convention this module emits because it is the
  TRF16-shaped spelling; JaVaFo does not read it, and a file that gives
  JaVaFo no round count at all is paired without the final-round colour
  exception. bbpPairings reads both prefixes into the same
  `expectedRounds` (`trf.cpp:1117-1124`), so it does not care which.

  Only one is written, never both. Two spellings of one field in a file
  that only one reader will ever open is a second thing to keep in step for
  no reader's benefit, and `parse/1` already refuses a file whose two
  spellings disagree - a refusal a writer should not be able to provoke.

  `opts[:xxc]`: write `tournament[:initial_colour]` as JaVaFo's `XXC white1`
  / `XXC black1` INSTEAD of the `152` header, for the same reason and with
  the same only-one rule as `:xxr`. JaVaFo does not read `152`: measured
  2026-09-13 on a six-player round one, a file carrying `152 B` - or `152 W`,
  or no line at all - was paired with the top seed on White in some runs and
  on Black in others, because JaVaFo draws the colour itself when it is not
  told, while `XXC black1` gave Black on every run. bbpPairings reads both.

  `opts[:xxz]`: write the players absent from the round about to be paired
  - a lone `0000 - Z` as the last column, for that round - as JaVaFo's
  `XXZ r1 r2 ...` line INSTEAD of the column, the way Swar writes them.
  Engine dialect only (TRF26 says the same thing as `240 Z`, which it
  already writes). Off by default and only-one, like `:xxr`: bbpPairings
  does not read `XXZ`, and a file it is handed with the column lifted out
  would pair the absentees, which is the bug `XXZ` was read to fix. Either
  spelling parses back to the same players.
  """
  def serialize(data, opts \\ [])

  def serialize(%{tournament: _, players: _} = given, opts) do
    %{tournament: t, players: players} = data = maybe_fold_ascii(given, opts[:ascii])
    dialect = dialect!(opts)

    validate_games!(players)
    validate_trf26_headers!(t)
    teams = Map.get(data, :teams, [])

    # TRF26 carries a bye granted for a round not yet paired as a `240`
    # record, not as a column on the `001` line - so those columns come off
    # the players before their lines are written, and go out at the end.
    system = t[:point_system] || default_point_system()
    {written, future_byes} = split_future_byes(players, dialect, system, team_rounds(t))
    xxz? = dialect == :engine and opts[:xxz] == true
    {written, absentees} = split_absences(written, xxz?, system, team_rounds(t))
    max_round = Enum.reduce(written, 0, &max(&2, length(&1[:games] || [])))
    xxr? = dialect == :engine and opts[:xxr] == true
    xxc? = dialect == :engine and opts[:xxc] == true
    numeric? = dialect == :trf26 or opts[:numeric_extensions] == true

    header_lines(t, players, teams, xxr?, xxc?)
    |> Kernel.++(point_system_lines(t[:point_system], dialect))
    |> Kernel.++(free_point_lines(t[:free_points]))
    |> Kernel.++(legend_lines(opts[:column_legend], max_round))
    |> Kernel.++(Enum.map(written, &player_line/1))
    |> Kernel.++(Enum.map(teams, &team_line/1))
    |> Kernel.++(team_record_lines(t))
    |> Kernel.++(xxr_line(t[:number_of_rounds], xxr?))
    |> Kernel.++(xxc_line(t[:initial_colour], xxc?))
    |> Kernel.++(xxz_line(absentees))
    |> Kernel.++(extension_lines(t, players, max_round, numeric?, dialect))
    |> Kernel.++(bye_lines(future_byes))
    |> Enum.map_join("", &(&1 <> "\r\n"))
  end

  # See the moduledoc's "Two dialects".
  defp dialect!(opts) do
    case Keyword.get(opts, :dialect, :engine) do
      dialect when dialect in [:engine, :trf26] ->
        dialect

      other ->
        raise ArgumentError, "unknown TRF dialect #{inspect(other)}: use :engine or :trf26"
    end
  end

  # A bye granted for a round the pairing has not reached - `0000 - H` in a
  # column past the last paired round, which is how the engines are told
  # to leave the player out (`Ainalrami.Pairing`'s `active_this_round?/2`)
  # - is a `240` record in TRF26, and the column is not written. Only a
  # trailing run of byes moves; anything else past the paired rounds stays
  # where it is, since removing it would shift the columns after it.
  defp split_future_byes(players, :engine, _system, _team_rounds), do: {players, []}

  # `team_rounds`: the last round a `330` or `320` record names. A round
  # whose only matches were forfeited as a whole (`330`, no boards) has no
  # game anybody took part in, but it was paired; the byes recorded in it
  # stay in their columns rather than becoming `240` records for a round
  # "not yet paired", which a reader would then place a round too early.
  defp split_future_byes(players, :trf26, system, team_rounds) do
    played = max(rounds_played(players), team_rounds)

    Enum.map_reduce(players, [], fn player, records ->
      {kept, future} = Enum.split(player[:games] || [], played)

      # The trailing run takes the empty columns along with the byes: a bye
      # for round 6 entered after round 2 arrives as three blank columns
      # and then the bye, the blanks there only to put it in column 6. Once
      # the bye is a `240` naming round 6 itself, the blanks hold nothing
      # up, and left behind they wrote `0000 -` three times on the `001`
      # line for rounds that do not exist.
      {run_reversed, rest_reversed} =
        future |> Enum.reverse() |> Enum.split_while(&(future_bye?(&1) or blank_game?(&1)))

      rest = Enum.reverse(rest_reversed)

      new_records =
        run_reversed
        |> Enum.reverse()
        |> Enum.with_index(played + length(rest) + 1)
        |> Enum.filter(fn {game, _round} -> future_bye?(game) end)
        |> Enum.map(fn {game, round} ->
          {String.upcase(String.trim(game[:result])), round, player[:rank]}
        end)

      # A run of blanks with no bye after it is not ours to remove.
      rest = if new_records == [], do: future, else: rest

      # The `001` total is the standings total, which a bye not yet reached
      # is not part of; the engines' convention credits it up front, so it
      # comes off here and `attach_byes/2` puts it back on the way in.
      moved =
        Enum.reduce(new_records, 0.0, fn {type, _round, _rank}, sum ->
          sum + points_for(type, system)
        end)

      player =
        player
        |> Map.put(:games, kept ++ rest)
        |> Map.update(:points, 0.0, &((&1 || 0.0) - moved))

      {player, records ++ new_records}
    end)
  end

  @doc false
  # The last round a TRF26 `330` (forfeited match) or `320` (team bye)
  # record names, 0 without any.
  def team_rounds(tournament) do
    forfeits =
      for f <- tournament[:forfeited_matches] || [], is_integer(f[:round]), do: f[:round]

    byes = length(get_in(tournament, [:team_pab, :teams]) || [])
    Enum.max([byes | forfeits], fn -> 0 end)
  end

  defp blank_game?(game) do
    is_nil(game[:opponent_rank]) and String.trim(to_string(game[:result] || "")) == ""
  end

  defp future_bye?(game) do
    is_nil(game[:opponent_rank]) and
      String.upcase(String.trim(to_string(game[:result] || ""))) in ~w(H F Z)
  end

  # One `240` per bye type per round: type at column 5, the round in 7-9,
  # then the starting ranks in four-character fields every five columns
  # from 11 - the spec's own example, `240 H 003  026  047`.
  defp bye_lines([]), do: []

  defp bye_lines(records) do
    records
    |> Enum.group_by(fn {type, round, _rank} -> {round, type} end, fn {_, _, rank} -> rank end)
    |> Enum.sort()
    |> Enum.map(fn {{round, type}, ranks} ->
      ranks
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.reduce(
        []
        |> place({1, 3}, "240")
        |> place({5, 5}, type)
        |> place({7, 9}, String.pad_leading(Integer.to_string(round), 3, "0")),
        fn {rank, i}, acc ->
          start = 11 + i * 5
          place(acc, {start, start + 3}, rank, align: :right)
        end
      )
      |> render()
    end)
  end

  # `xxz: true` - see `serialize/2`. A `0000 - Z` standing alone in the
  # column of the round about to be paired, as the player's last column,
  # comes off the `001` line and goes out as one `XXZ` line, which is
  # where Swar puts it and `parse/1` reads it back from. A Z with anything
  # after it stays a column: lifting it would shift the rest.
  defp split_absences(players, false, _system, _team_rounds), do: {players, []}

  defp split_absences(players, true, system, team_rounds) do
    played = max(rounds_played(players), team_rounds)

    {players, ranks} =
      Enum.map_reduce(players, [], fn player, ranks ->
        games = player[:games] || []

        if length(games) == played + 1 and lone_absence?(List.last(games)) do
          player =
            player
            |> Map.put(:games, Enum.take(games, played))
            |> Map.update(:points, 0.0, &((&1 || 0.0) - points_for("Z", system)))

          {player, [player[:rank] | ranks]}
        else
          {player, ranks}
        end
      end)

    {players, Enum.sort(ranks)}
  end

  defp lone_absence?(%{opponent_rank: nil, result: result} = game) when is_binary(result),
    do: is_nil(game[:colour]) and String.upcase(String.trim(result)) == "Z"

  defp lone_absence?(_game), do: false

  defp xxz_line([]), do: []
  defp xxz_line(ranks), do: ["XXZ " <> Enum.map_join(ranks, " ", &Integer.to_string/1)]

  # Emitted after the player rows rather than up with the headers, next to
  # the `XXA`/`XXP` lines it keeps company with in every file JaVaFo is
  # actually handed. Position carries no meaning to any reader here -
  # `parse/1` folds lines in file order and both references scan the whole
  # file - so this is only about where a human looking at the file expects
  # the extension block to be.
  defp xxr_line(rounds, true) when not is_nil(rounds), do: ["XXR #{rounds}"]
  defp xxr_line(_rounds, _xxr), do: []

  # `XXC white1` / `XXC black1`, JaVaFo's spelling of the drawing of lots -
  # see `serialize/2`'s `opts[:xxc]`. The value goes through
  # `initial_colour_line/1` first so a bad one raises the same
  # `ValidationError` either spelling would.
  defp xxc_line(nil, _xxc), do: []

  defp xxc_line(colour, true) do
    case initial_colour_line(colour) do
      "152 W" -> ["XXC white1"]
      "152 B" -> ["XXC black1"]
    end
  end

  defp xxc_line(_colour, _xxc), do: []

  # Written as `BB*` rather than as a `162` line: the `BB` directives are one
  # value per line, so a file carrying them says exactly which settings were
  # deliberate, and a reader that supports only some of them fails on the
  # line it cannot take rather than misreading a packed record.
  #
  # Only the values that DIFFER from the standard system are emitted, so an
  # ordinary tournament serialises byte-identically to before this existed.
  # `BBU` comes last on purpose - `BBW` drags the pairing-allocated bye with
  # it unless the bye has already been pinned, which is the reference's own
  # `usePairingAllocatedByeScore` behaviour and depends on the file's order.
  defp point_system_lines(nil, _dialect), do: []

  # TRF26's own spelling: one `162` line - symbol at column 6 and the value
  # in the four columns after it, nine columns per entry, which is what
  # `chunk_point_entries/1` reads back - written whenever the system
  # differs from the standard one, all five symbols at once with `P` last
  # so it pins the bye against `W` dragging it. What `162` cannot say - a
  # forfeit loss worth something other than the zero-point bye it folds it
  # into, and the `299` overrides - follows as `299` records.
  #
  # A declared `X` (`:unknown`, see `parse_point_system/2`) is appended
  # after `P` whenever the system carries one, even if the other five
  # values are all standard - otherwise a file read in with an `X` and
  # written back out would silently lose it, which is the one thing a
  # round trip must not do to a value the file itself declared. `:unknown`
  # is never present unless a `162` line put it there, so a file without
  # `X` writes exactly the `162` line (or absence of one) it always did.
  defp point_system_lines(system, :trf26) do
    default = default_point_system()

    standard? =
      Enum.all?(default, fn {field, value} -> Map.get(system, field, value) == value end)

    declared_unknown = Map.get(system, :unknown)

    line_162 =
      if standard? and is_nil(declared_unknown) do
        []
      else
        entries =
          for {symbol, field} <- [
                {"W", :win},
                {"D", :draw},
                {"L", :loss},
                {"A", :zero_point_bye},
                {"P", :pairing_allocated_bye}
              ] do
            value = Map.get(system, field, Map.fetch!(default, field))
            symbol <> String.pad_leading(format_points(value), 4)
          end

        entries =
          if declared_unknown,
            do: entries ++ ["X" <> String.pad_leading(format_points(declared_unknown), 4)],
            else: entries

        ["162  " <> Enum.join(entries, "    ")]
      end

    line_162 ++ abnormal_point_lines(system, :trf26)
  end

  defp point_system_lines(system, :engine) do
    bb_lines(system) ++ abnormal_point_lines(system, :engine)
  end

  @doc false
  # `299` records for points assigned outside the scoring system - a bonus
  # or a penalty an arbiter added by hand, which the `001` points column
  # does not carry (TRF26 defines it as the tournament standings' score
  # from the games). Untyped, value right-aligned in 14-17, an optional
  # round in 20-22, and the starting ranks from 24 in four-character fields
  # every five columns. The shape `parse_299/2` reads back.
  def free_point_lines(nil), do: []
  def free_point_lines([]), do: []

  def free_point_lines(records) do
    for record <- records, points = record[:points] || record["points"], points != nil do
      ranks = record[:ranks] || record["ranks"] || []
      round = record[:round] || record["round"]

      base =
        []
        |> place({1, 3}, "299")
        |> place({14, 17}, format_signed_points(points), align: :right)

      base =
        if round,
          do: place(base, {20, 22}, String.pad_leading(Integer.to_string(round), 3, "0")),
          else: base

      ranks
      |> Enum.with_index()
      |> Enum.reduce(base, fn {rank, i}, acc ->
        start = 24 + i * 5
        place(acc, {start, start + 3}, rank, align: :right)
      end)
      |> render()
    end
  end

  # `format_points/1` goes through `float_to_binary/2`, which keeps the
  # sign - a penalty is a negative number and `299` says so ("free points
  # can be a negative number").
  defp format_signed_points(points), do: format_points(points)

  # `299` records for what neither the `162` line nor the `BB*` lines can
  # carry: the three overrides, and - in the TRF26 dialect only, since the
  # engine dialect says it with `BBF` - a forfeit loss that differs from
  # the zero-point bye. Type at column 5, the value right-aligned in 14-17.
  defp abnormal_point_lines(system, dialect) do
    default = default_point_system()

    overrides = [
      {"+", Map.get(system, :forfeit_win)},
      {"F", Map.get(system, :full_point_bye)},
      {"H", Map.get(system, :half_point_bye)}
    ]

    forfeit_loss = Map.get(system, :forfeit_loss, default.forfeit_loss)
    zero_point_bye = Map.get(system, :zero_point_bye, default.zero_point_bye)

    forfeit =
      if dialect == :trf26 and forfeit_loss != zero_point_bye,
        do: [{"-", forfeit_loss}],
        else: []

    for {symbol, value} <- overrides ++ forfeit, not is_nil(value) do
      []
      |> place({1, 3}, "299")
      |> place({5, 5}, symbol)
      |> place({14, 17}, format_points(value), align: :right)
      |> render()
    end
  end

  defp bb_lines(system) do
    default = default_point_system()

    order = [
      {:win, "BBW"},
      {:draw, "BBD"},
      {:loss, "BBL"},
      {:zero_point_bye, "BBZ"},
      {:forfeit_loss, "BBF"},
      {:pairing_allocated_bye, "BBU"}
    ]

    for {field, code} <- order,
        value = Map.get(system, field),
        emit?(field, value, system, default) do
      # Fixed columns, not free-form. `readPoints` (trf.cpp:637-644) demands
      # a line of at least 8 characters and reads the value from column 5
      # onwards, so `BBW 2.0` - the obvious spelling, and 7 characters - is
      # rejected outright as an invalid line. Right-aligned in columns 5-8,
      # matching how every other point field in TRF16 is written.
      code <> " " <> String.pad_leading(:erlang.float_to_binary(value / 1, decimals: 1), 4)
    end
  end

  # Whether a `BB*` line has to be written.
  #
  # "It differs from the default" is the obvious rule and it is wrong for
  # exactly one field. Reading a `BBW` sets `pairing_allocated_bye` to the
  # same value unless a `BBU` has already pinned it - that is this module's
  # own `parse_bb_points/3` (`pab_pinned?`) and bbpPairings'
  # `usePairingAllocatedByeScore` (`trf.cpp:1206-1213`). So whenever the win
  # is non-default and the bye is at its default, the "differs" rule omitted
  # `BBU` and the reader then made the bye worth the WIN.
  #
  # The emitter's own note about ordering shows the interaction was known -
  # "BBU comes last on purpose, BBW drags the pairing-allocated bye with it
  # unless the bye has already been pinned" - but it was applied to the order
  # of the lines and not to the decision of whether to write one. The file
  # was wrong, not just the round trip: a 3-1-0 event with an ordinary
  # one-point bye stated a three-point bye.
  #
  # The rule is therefore what the READER will reconstruct, not what the
  # default is: write `BBU` whenever a `BBW` is being written at all.
  defp emit?(:pairing_allocated_bye, value, system, default) do
    value != default.pairing_allocated_bye or
      Map.get(system, :win) != default.win
  end

  defp emit?(field, value, _system, default), do: value != Map.fetch!(default, field)

  # `XXA`/`XXP` are JaVaFo's spellings and what the sibling project emits,
  # so they stay the default. `250`/`260` are bbpPairings' own fixed-column,
  # round-limited siblings - and it is the implementation that DEFINES them,
  # which is exactly why generating them matters. Until now they were
  # covered by unit tests written from its source, and never by a file the
  # real binary had to read back.
  defp extension_lines(t, players, max_round, true, dialect) do
    rounds = t[:number_of_rounds] || max_round

    acceleration =
      case dialect do
        :trf26 -> compact_acceleration_lines(players)
        :engine -> numeric_acceleration_lines(players)
      end

    acceleration ++
      numeric_forbidden_lines(t[:forbidden_pairs], max(rounds, max_round + 1)) ++
      format_lines(t) ++ organiser_lines(t, players)
  end

  defp extension_lines(t, players, _max_round, _numeric?, _dialect) do
    acceleration_lines(players) ++
      forbidden_pair_lines(t[:forbidden_pairs]) ++ format_lines(t) ++ organiser_lines(t, players)
  end

  # The `XXO` lines, this engine's own (see the moduledoc, "The
  # organiser's records"). Nothing is written for a tournament that has
  # none of them, which is every tournament written before they existed.
  defp organiser_lines(t, players) do
    soft =
      for group <- t[:soft_pairs] || [] do
        "XXO soft-pairs " <> Ainalrami.PairingInput.format_group(group)
      end

    position =
      case t[:soft_position] do
        :weak -> ["XXO soft-position weak"]
        :strong when soft != [] -> ["XXO soft-position strong"]
        _ -> []
      end

    excluded =
      case t[:bye_exclusions] || [] do
        [] ->
          []

        entries ->
          [
            "XXO bye-exclude " <>
              Enum.map_join(entries, " ", fn
                {rank, rounds} -> Ainalrami.PairingInput.format_ranked(rank, rounds)
                rank -> Ainalrami.PairingInput.format_ranked(rank, :all)
              end)
          ]
      end

    preferences =
      for {word, setting} <- Ainalrami.PairingInput.bye_kinds(),
          entries = Enum.filter(t[:bye_preferences] || [], &(elem(&1, 1) == setting)),
          entries != [] do
        "XXO bye-#{word} " <>
          Enum.map_join(entries, " ", fn
            {rank, _setting} -> Ainalrami.PairingInput.format_ranked(rank, :all)
            {rank, _setting, :all} -> Ainalrami.PairingInput.format_ranked(rank, :all)
            {rank, _setting, rounds} -> Ainalrami.PairingInput.format_ranked(rank, rounds)
          end)
      end

    ratings =
      for player <- players,
          by_round = player[:round_ratings],
          is_map(by_round),
          by_round != %{} do
        last = by_round |> Map.keys() |> Enum.max()

        "XXO round-ratings #{player[:rank]} " <>
          Enum.map_join(1..last, " ", &(Map.get(by_round, &1) || "-"))
      end

    teams =
      for {key, keyword} <- [
            team_forbidden_pairs: "team-forbidden",
            team_soft_pairs: "team-soft-pairs"
          ],
          group <- t[key] || [] do
        "XXO #{keyword} " <> Ainalrami.PairingInput.format_group(group)
      end

    provisional =
      for {rank, rating} <- Enum.sort(t[:provisional_ratings] || %{}),
          do: "XXO provisional-rating #{rank} #{rating}"

    soft ++ position ++ excluded ++ preferences ++ ratings ++ provisional ++ teams
  end

  # `XXM` and `XXG`, this engine's own (see the moduledoc). Written in both
  # dialects: neither TRF16 nor TRF26 has a record for a two-game match or
  # for a category paired on its own, so there is no numeric spelling to
  # write instead.
  defp format_lines(t) do
    match = if t[:match_format] == true, do: ["XXM"], else: []

    groups =
      for group <- t[:pairing_groups] || [], group != [] do
        "XXG " <> Enum.map_join(group, " ", &Integer.to_string/1)
      end

    match ++ groups
  end

  # One `250` per rank range per round range - the shape of TRF26's own
  # example. Baku, the whole top half on the same virtual points for the
  # same rounds, is two lines; anything else takes as many as it needs,
  # down to one per player per round. A range only spans players whose
  # ranks are consecutive AND whose virtual points agree round for round.
  defp compact_acceleration_lines(players) do
    players
    |> Enum.filter(&(&1[:accelerations] not in [nil, []]))
    |> Enum.sort_by(& &1[:rank])
    |> Enum.chunk_while([], &chunk_consecutive/2, &{:cont, Enum.reverse(&1), []})
    |> Enum.reject(&(&1 == []))
    |> Enum.flat_map(fn [first | _] = chunk ->
      last = List.last(chunk)

      first[:accelerations]
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {points, _round} -> points end)
      |> Enum.reject(fn [{points, _round} | _] -> points == 0 end)
      |> Enum.map(fn run ->
        {points, first_round} = hd(run)
        {_points, last_round} = List.last(run)
        line_250(points, first_round, last_round, first[:rank], last[:rank])
      end)
    end)
  end

  defp chunk_consecutive(player, []), do: {:cont, [player]}

  defp chunk_consecutive(player, [previous | _] = chunk) do
    if player[:rank] == previous[:rank] + 1 and
         player[:accelerations] == previous[:accelerations] do
      {:cont, [player | chunk]}
    else
      {:cont, Enum.reverse(chunk), [player]}
    end
  end

  # One `250` per player per round carrying non-zero virtual points.
  #
  # A `250` says "these players, over these rounds, get these points", so a
  # single line can cover a whole accelerated group - but only when that
  # group is contiguous by rank AND flat across the rounds, which is true of
  # Baku and false of the random axis. The degenerate range (one player, one
  # round) is correct for both, and for a corpus that is the better trade:
  # it puts MORE lines through the parser, not fewer.
  defp numeric_acceleration_lines(players) do
    for player <- players,
        {points, round} <- Enum.with_index(player[:accelerations] || [], 1),
        points != 0 do
      # Widths taken from `readAccelerations250` (trf.cpp:418) rather than
      # from `parse_250/2` below, and they are NOT the same. The C++ reads
      # half-open 0-based ranges - [4,8) match points, [9,13) game points,
      # [14,17) and [18,21) the rounds, [22,26) and [27,31) the players -
      # so every field is separated from the next by one blank column.
      #
      # `parse_250/2` reads each field one column wider, swallowing that
      # separator, which is harmless on the way IN because `read/2` trims.
      # On the way OUT it is fatal: right-aligning into the wider field puts
      # the digit in the separator, and the real binary then reads a blank
      # round and rejects the line. Verified by feeding both to
      # bbpPairings - the wide form is `Invalid line`, this one pairs.
      #
      # Same shape as the `XXA` column bug: a field written one column too
      # wide, tolerated by the reader we happened to test against and
      # rejected by the one that defines the format.
      line_250(points, round, round, player[:rank], player[:rank])
    end
  end

  defp line_250(points, first_round, last_round, first_player, last_player) do
    []
    |> place({1, 3}, "250")
    # 5-8 is MATCH points and must stay blank; bbpPairings rejects a `250`
    # that carries any, and `parse_250/2` enforces the same on the way in.
    |> place({10, 13}, format_points(points), align: :right)
    |> place({15, 17}, first_round, align: :right)
    |> place({19, 21}, last_round, align: :right)
    |> place({23, 26}, first_player, align: :right)
    |> place({28, 31}, last_player, align: :right)
    |> render()
  end

  # One `260` per forbidden group, spanning every round.
  #
  # `XXP` carries no round limit at all - it means "never pair these" - so
  # the equivalent `260` has to name a range that outlives the tournament,
  # not just the rounds already played. Bounding it at `number_of_rounds`
  # is the subtle version of getting this wrong: on a file whose declared
  # round count is behind the round actually being paired, the ban expires
  # exactly when it is needed and the two spellings pair differently.
  # Caught by diffing bbpPairings' own output on both forms of one
  # tournament, which is the only way it shows up - each file is
  # individually valid and parses without complaint.
  defp numeric_forbidden_lines(nil, _rounds), do: []
  defp numeric_forbidden_lines([], _rounds), do: []

  defp numeric_forbidden_lines(groups, rounds) do
    for group <- groups, ids = group_ids(group), length(ids) >= 2 do
      {first, last} = group_rounds(group, rounds)
      forbidden_260_line(ids, first, last)
    end
  end

  # A group carries its own round range when it was parsed from a `260`.
  # Writing every group as `1..rounds` discarded it, so a ban limited to
  # rounds 2-6 came back out as a ban on the whole event - the parser read
  # the range and the writer threw it away.
  defp group_rounds({_ids, first, last}, _rounds)
       when is_integer(first) and is_integer(last),
       do: {first, last}

  defp group_rounds(_group, rounds), do: {1, max(rounds, 1)}

  defp forbidden_260_line(ids, first, last) do
    ids
    |> Enum.with_index()
    |> Enum.reduce(
      []
      |> place({1, 3}, "260")
      |> place({5, 7}, first, align: :right)
      |> place({9, 11}, last, align: :right),
      fn {id, i}, acc ->
        start = 13 + i * 5
        place(acc, {start, start + 3}, id, align: :right)
      end
    )
    |> render()
  end

  # A group is either a bare list of ranks (`XXP`) or the round-limited
  # `{ids, first, last}` a `260` parses into. Writing either back out has to
  # accept both, so that a file read as `260` and written as `260`
  # round-trips rather than losing its groups.
  defp group_ids({ids, _first, _last}) when is_list(ids), do: ids
  defp group_ids(ids) when is_list(ids), do: ids
  defp group_ids(_), do: []

  defp acceleration_lines(players) do
    players
    |> Enum.filter(&(&1[:accelerations] not in [nil, []]))
    |> Enum.map(&acceleration_line/1)
  end

  defp acceleration_line(player) do
    player[:accelerations]
    |> Enum.with_index(1)
    |> Enum.reduce(
      [] |> place({1, 3}, "XXA") |> place(@xxa_rank_cols, player[:rank], align: :right),
      fn {points, round}, acc ->
        place(acc, xxa_points_cols(round), format_points(points), align: :right)
      end
    )
    |> render()
  end

  # Free-form, matching `readForbiddenPairsXxp` (`trf.cpp:554-568`): it
  # takes `line.substr(3)` and tokenizes on space/tab, so the whole line
  # after the code is just a list of starting ranks. A group of N ids
  # forbids every pair WITHIN it, not merely the first two.
  defp forbidden_pair_lines(nil), do: []

  defp forbidden_pair_lines(groups) do
    # `length/1` used to be called straight on the group, and a group parsed
    # from a `260` is the tuple `{ids, first, last}` - `length/1` is a BIF
    # that requires a list, so a parse-then-serialize round trip on any file
    # containing a `260` raised ArgumentError. `group_ids/1` exists precisely
    # to normalise the two shapes and the sibling writer already used it.
    #
    # A round-limited group is written back as `260` even on this default
    # path, because `XXP` has no way to say "rounds 2 to 6" - emitting one
    # would silently WIDEN the ban to the whole event, which is a worse
    # answer than the crash it replaces.
    {ranged, plain} =
      groups
      |> Enum.filter(&(length(group_ids(&1)) >= 2))
      |> Enum.split_with(
        &match?({_ids, first, last} when is_integer(first) and is_integer(last), &1)
      )

    Enum.map(plain, &("XXP " <> Enum.join(group_ids(&1), " "))) ++
      Enum.map(ranged, fn {ids, first, last} -> forbidden_260_line(ids, first, last) end)
  end

  defp legend_lines(true, max_round) when max_round >= 0 do
    legend = legend_line(max_round)
    width = String.length(legend)
    ["", ruler_line(width, :tens), ruler_line(width, :units), legend]
  end

  # Swiss-Manager's own rating files carry the field legend alone, no
  # rulers: the line a person reads the columns by.
  defp legend_lines(:line, max_round) when max_round >= 0, do: [legend_line(max_round)]

  defp legend_lines(_, _), do: []

  defp legend_line(max_round) do
    []
    |> place(@player_cols.code, "DDD")
    |> place(@player_cols.starting_rank, "SSSS")
    |> place(@player_cols.sex, "s")
    |> place(@player_cols.title, "TTT")
    |> place(@player_cols.name, String.duplicate("N", 33))
    |> place(@player_cols.fide_rating, "RRRR")
    |> place(@player_cols.federation, "FFF")
    |> place(@player_cols.fide_number, String.duplicate("I", 11))
    |> place(@player_cols.birth_date, "BBBB/BB/BB")
    |> place(@player_cols.points, "PPPP")
    |> place(@player_cols.rank, "RRRR")
    |> legend_games(max_round)
    |> render()
  end

  # No rounds is not a reason to withhold the legend.
  #
  # This used to require `max_round > 0`, so an export taken before the first
  # pairing - a registration list, the commonest thing to eyeball against the
  # column positions - came out with no ruler at all. The player columns are
  # exactly as meaningful without games, and that is precisely when somebody
  # is checking whether a name has overrun its 33 characters.
  defp legend_games(acc, 0), do: acc

  defp legend_games(acc, max_round) do
    Enum.reduce(1..max_round, acc, fn round, acc ->
      cols = round_cols(round)
      digit = round |> Integer.to_string() |> String.last()

      acc
      |> place(cols.id, String.duplicate(digit, 4))
      |> place(cols.colour, digit)
      |> place(cols.result, digit)
    end)
  end

  # `:tens` marks every 10th column with its running count (e.g. "1" ending
  # at column 10, "18" ending at column 180); `:units` repeats "1234567890"
  # across the full width - together, a standard fixed-width column ruler.
  defp ruler_line(width, :tens) do
    Enum.reduce(10..width//10, List.duplicate(" ", width), fn col, acc ->
      label = col |> div(10) |> Integer.to_string()
      start = col - String.length(label)

      label
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {ch, i}, acc2 -> List.replace_at(acc2, start + i, ch) end)
    end)
    |> Enum.join()
  end

  defp ruler_line(width, :units) do
    1..width |> Enum.map_join("", &Integer.to_string(rem(&1, 10)))
  end

  defp header_lines(t, players, teams, xxr?, xxc?) do
    [
      header(:name, t[:name]),
      header(:city, t[:city]),
      header(:federation, t[:federation]),
      header(:start_date, slash_date(t[:start_date])),
      header(:end_date, slash_date(t[:end_date])),
      header(:number_of_players, length(players)),
      t[:number_of_rated_players] && header(:number_of_rated_players, t[:number_of_rated_players]),
      # Always emitted (082), even 0 for an individual tournament.
      header(:number_of_teams, length(teams)),
      header(:type, t[:type] && Map.get(@type_labels, t[:type], t[:type])),
      header(:chief_arbiter, t[:chief_arbiter])
    ]
    |> Kernel.++(Enum.map(t[:deputy_arbiters] || [], &header(:deputy_arbiter, &1)))
    |> Kernel.++([
      header(:time_control, t[:time_control]),
      round_count_header(t[:number_of_rounds], xxr?),
      if(xxc?, do: nil, else: initial_colour_line(t[:initial_colour])),
      round_dates_line(t[:round_dates]),
      header(:generator, t[:generator]),
      # TRF26's headers. Written in either dialect when the caller gives
      # them - a pairing program ignores a code it does not know - and
      # checked first (`validate_trf26_headers!/1`), because a file that
      # leaves the building with a typo in its type code is a file FIDE
      # bounces.
      header(:type_code, t[:type_code]),
      header(:tie_breaks, code_list(t[:tie_breaks])),
      header(:standings_order, code_list(t[:standings_order])),
      header(:time_control_code, t[:time_control_code])
    ])
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp code_list(nil), do: nil
  defp code_list(codes) when is_list(codes), do: Enum.join(codes, ",")
  defp code_list(codes) when is_binary(codes), do: codes

  defp validate_trf26_headers!(t) do
    code = t[:type_code]

    if not is_nil(code) and not tournament_type_code?(code) do
      raise ValidationError,
        message: "192: #{inspect(code)} is not a tournament type code from TRF26's table"
    end

    time_control = t[:time_control_code]

    if not is_nil(time_control) and not encoded_time_control?(time_control) do
      raise ValidationError,
        message:
          "222: #{inspect(time_control)} is not an encoded time control " <>
            "(d[:d] or Wd[:d]-Bd[:d], where d is [moves/]seconds[+increment])"
    end

    # The syntax, not the name: `BH/C1`, `KS/L-1`, `SB:GP/C1` (see
    # `Ainalrami.Tiebreaks.Code`). Until this allowed the `/`, every modified
    # code was refused - a file listing FIDE's most common tie-break, BH/C1,
    # could not be written. A name this library does not compute still
    # passes: a file from another program keeps its own list.
    for list <- [t[:tie_breaks], t[:standings_order]],
        is_list(list),
        code <- list,
        not (is_binary(code) and
               Regex.match?(~r"^[A-Z][A-Z0-9]*(:[A-Z]{2})?(/[A-Z0-9][A-Z0-9+.-]*)*$", code)) do
      raise ValidationError, message: "202/212: #{inspect(code)} is not a tie-break code"
    end

    :ok
  end

  # The Tournament Type Code Table for `192` (FIDE TEC, published with
  # TRF-2026 at tec.fide.com/trf-2026), less the four parametrised
  # families, which `tournament_type_code?/1` matches by shape. What each
  # code means is `Ainalrami.TypeCode`'s.
  #
  # Until 2026-09-27 this list had `FIDE_DUTCH_2026` where the published
  # table has `FIDE_DUTCH_2025` (the Dutch system "after June 30th, 2025"),
  # copied from a draft; `@legacy_type_codes` keeps the draft's spelling
  # readable and writable, since files carrying it exist.
  @tournament_type_codes ~w(
    FIDE_DUTCH_2017 FIDE_DUTCH_2025 FIDE_DUTCH FIDE_DUBOV FIDE_BURSTEIN
    FIDE_DUTCH_2017_BAKU FIDE_DUTCH_2025_BAKU FIDE_DUTCH_BAKU FIDE_DUBOV_BAKU
    FIDE_BURSTEIN_BAKU CUSTOM_SWISS FIDE_DOUBLESWISS FIDE_DOUBLESWISS_BAKU
    CUSTOM_DOUBLESWISS
    BERGER_ROUNDROBIN BERGER_DOUBLEROUNDROBIN FIDE_ROUNDROBIN FIDE_DOUBLEROUNDROBIN
    CUSTOM_ROUNDROBIN FIDE_SCHILLER CUSTOM_SCHILLER FIDE_SCHEVENINGEN
    FIDE_DOUBLESCHEVENINGEN CUSTOM_SCHEVENINGEN CUSTOM_KNOCKOUT
    FIDE_TEAM_TYPEA_MP_GP FIDE_TEAM_TYPEA_GP_MP FIDE_TEAM_TYPEA_MP FIDE_TEAM_TYPEA_GP
    FIDE_TEAM_TYPEB_MP_GP FIDE_TEAM_TYPEB_GP_MP FIDE_TEAM_TYPEB_MP FIDE_TEAM_TYPEB_GP
    FIDE_TEAM_MP_GP FIDE_TEAM_GP_MP FIDE_TEAM_MP FIDE_TEAM_GP FIDE_TEAM
    CUSTOM_TEAM_SWISS_MP CUSTOM_TEAM_SWISS_GP
    FIDE_TEAM_TYPEA_MP_GP_BAKU FIDE_TEAM_TYPEA_MP_BAKU FIDE_TEAM_TYPEB_MP_GP_BAKU
    FIDE_TEAM_TYPEB_MP_BAKU FIDE_TEAM_MP_GP_BAKU FIDE_TEAM_MP_BAKU FIDE_TEAM_BAKU
    CUSTOM_TEAM_SWISS
    BERGER_TEAM_ROUNDROBIN BERGER_TEAM_DOUBLEROUNDROBIN FIDE_TEAM_ROUNDROBIN
    FIDE_TEAM_DOUBLEROUNDROBIN CUSTOM_TEAM_ROUNDROBIN CUSTOM_TEAM_KNOCKOUT
  )

  @doc """
  The fixed entries of TRF26's Tournament Type Code Table, the values a
  `192` line may carry - without the four parametrised families
  (`BERGER_ROUNDROBIN_Gn`, `BERGER_TEAM_ROUNDROBIN_Gn`, `FIDE_SCHILLER_TxP`,
  `FIDE_SCHEVENINGEN_Gn`), which `tournament_type_code?/1` accepts by shape.
  """
  def tournament_type_codes, do: @tournament_type_codes

  @legacy_type_codes ~w(FIDE_DUTCH_2026 FIDE_DUTCH_2026_BAKU)

  @doc """
  Whether `code` is a value TRF26's `192` line may carry: an entry of
  `tournament_type_codes/0`, one of the parametrised families, or one of
  the draft table's `FIDE_DUTCH_2026` / `FIDE_DUTCH_2026_BAKU`, still
  accepted and read as `FIDE_DUTCH_2025` (see `Ainalrami.TypeCode`).
  """
  def tournament_type_code?(code) when is_binary(code) do
    code in @tournament_type_codes or code in @legacy_type_codes or
      Enum.any?(
        [
          ~r/^BERGER_ROUNDROBIN_G[1-9]\d*$/,
          ~r/^BERGER_TEAM_ROUNDROBIN_G[1-9]\d*$/,
          ~r/^FIDE_SCHILLER_[1-9]\d*x[1-9]\d*$/,
          ~r/^FIDE_SCHEVENINGEN_G[1-9]\d*$/
        ],
        &Regex.match?(&1, code)
      )
  end

  def tournament_type_code?(_code), do: false

  @doc """
  Whether `code` is an encoded time control as TRF26's `222` line defines
  it: `d[:d]` or `Wd[:d]-Bd[:d]`, each `d` a period `[moves/]seconds[+increment]`
  - `5400+30` for 90 minutes plus 30 seconds a move, `40/6000+30:900+30`
  for 100 minutes for 40 moves then 15, `W300-B240` for an Armageddon.
  """
  def encoded_time_control?(code) when is_binary(code) do
    period = "(?:\\d+/)?\\d+(?:\\+\\d+)?"
    sequence = "#{period}(?::#{period})*"
    Regex.match?(~r/^(?:#{sequence}|W#{sequence}-B#{sequence})$/, code)
  end

  def encoded_time_control?(_code), do: false

  # Article 5.1's drawing of lots. Parsed since 2026-08-17 but never
  # written until now, so `serialize/2` silently dropped it and a
  # round-trip lost the draw - and a file with no round one played has
  # nothing to infer it back from, which real bbpPairings treats as fatal
  # rather than guessable ("Please configure the initial piece colors",
  # exit 3). Round one is exactly when the field decides every board.
  #
  # FIXED WIDTH, unlike every other header here: `trf.cpp:1181` rejects
  # the line outright unless it is exactly five characters, so this is
  # built directly rather than through `header/2`, whose trailing trim
  # would be harmless but whose lowercase value would not.
  #
  # Spelled out and case-insensitive, because "white"/"black" is what
  # `CLI.normalise_colour/1` accepts from an operator and what
  # `Generator.generate/1`'s undocumented `:initial_colour` option passes
  # straight through. Three literal clauses meant those crashed
  # `serialize/2` with a `FunctionClauseError` from a private function -
  # no message, no line, nothing naming the option. Anything else raises a
  # `ValidationError` that says what was given, which is what the rest of
  # this module does with a value it cannot use. Sweep 2026-09-01, M3.
  defp initial_colour_line(nil), do: nil

  defp initial_colour_line(colour) when is_binary(colour) do
    case String.downcase(colour) do
      c when c in ["w", "white"] ->
        "152 W"

      c when c in ["b", "black"] ->
        "152 B"

      _ ->
        raise ValidationError,
          message: "initial colour must be one of w/W/white or b/B/black, got #{inspect(colour)}"
    end
  end

  defp initial_colour_line(colour) do
    raise ValidationError,
      message: "initial colour must be a string (w/W/white or b/B/black), got #{inspect(colour)}"
  end

  # The round count goes out under one spelling or the other, never both -
  # see `serialize/2`'s `opts[:xxr]`.
  defp round_count_header(_rounds, true), do: nil
  defp round_count_header(rounds, _xxr), do: header(:number_of_rounds, rounds)

  defp header(_field, value) when value in [nil, ""], do: nil
  defp header(field, value), do: String.trim_trailing("#{@header_codes[field]} #{value}")

  defp round_dates_line(nil), do: nil
  defp round_dates_line([]), do: nil

  defp round_dates_line(dates) do
    # Only emit the line at all if at least one round actually has a date -
    # a list of all-nil/blank entries means "no round dates", same as [].
    if Enum.all?(dates, &(&1 in [nil, ""])) do
      nil
    else
      dates
      |> Enum.with_index(1)
      |> Enum.reduce(place([], {1, 3}, "132"), fn {date, i}, acc ->
        place(acc, round_date_cols(i), short_slash_date(date))
      end)
      |> render()
    end
  end

  defp player_line(p) do
    games = p[:games] || []

    []
    |> place(@player_cols.code, "001")
    |> place(@player_cols.starting_rank, p[:rank], align: :right)
    |> place(@player_cols.sex, trf_sex(p[:sex]))
    |> place(@player_cols.title, p[:title])
    |> place(@player_cols.name, p[:name])
    |> place(@player_cols.fide_rating, blank_if_falsy(p[:fide_rating]), align: :right)
    |> place(@player_cols.federation, p[:federation])
    |> place(@player_cols.fide_number, blank_if_falsy(p[:fide_number]), align: :right)
    |> place(@player_cols.birth_date, slash_date(p[:birth_date]))
    |> place(@player_cols.points, format_points(p[:points]), align: :right)
    # Columns 86-89 are the player's place in the final standings. A caller
    # that has standings passes `:final_rank`; without one the starting
    # rank is written, as it always was - wrong for a rating report, but the
    # fallback is kept so no existing output changes behind its caller's back.
    |> place(@player_cols.rank, p[:final_rank] || p[:rank], align: :right)
    |> place_games(games)
    |> render()
    |> pad_to_last_round(games)
  end

  # `render/1` trims trailing whitespace, which every other line here wants
  # and a `001` line with games does not. A round whose result column is
  # blank - a round paired but not yet played, or one its holder sat out
  # with nothing recorded - loses BOTH the separator at `base + 6` and the
  # result at `base + 7`, and the line stops two columns short.
  #
  # bbpPairings then refuses the whole FILE, not just the round.
  # `trf.cpp:189-191` only enters a round block while
  # `startIndex <= line.size() - 8`, so the short block is never read; and
  # `trf.cpp:352-355` then finds non-space characters left over past
  # `startIndex` and throws `InvalidLineException`. Confirmed by direct
  # invocation on a serialized two-round file: exit code 3, "Invalid line".
  # Every TRF this engine wrote for a round in progress was unreadable by
  # the reference implementation.
  defp pad_to_last_round(line, []), do: line

  defp pad_to_last_round(line, games) do
    {result_col, _} = round_cols(length(games)).result

    # Padded to a BYTE count, like every other column decision in this
    # module. `String.pad_trailing/2` counts graphemes, so a row whose name
    # carries an accent was padded short by one byte per accent - and the
    # thing being padded to is the result column of the last round, which is
    # exactly the column bbpPairings refuses a file for missing (see this
    # function's own note above). Our reader self-heals it by dropping empty
    # trailing blocks, which is why no test here ever saw it; a third-party
    # reader has no reason to.
    line <> String.duplicate(" ", max(result_col - byte_size(line), 0))
  end

  defp place_games(acc, games) do
    games
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {g, i}, acc ->
      cols = round_cols(i)

      acc
      |> place(cols.id, g[:opponent_rank] || "0000", align: :right)
      |> place(cols.colour, g[:colour] || "-")
      |> place(cols.result, g[:result] || "")
    end)
  end

  # TRF26 `362`, `320`, `330` and `300`, when the tournament carries them.
  defp team_record_lines(t) do
    points =
      case t[:team_point_system] do
        system when is_map(system) and map_size(system) > 0 ->
          entries =
            for {symbol, key} <- @team_symbols, is_number(system[key]) do
              symbol <> String.pad_leading(format_points(system[key]), 4)
            end

          ["362  " <> Enum.join(entries, "    ")]

        _ ->
          []
      end

    pab =
      case t[:team_pab] do
        %{} = pab ->
          (pab[:teams] || [])
          |> Enum.with_index()
          |> Enum.reduce(
            []
            |> place({1, 3}, "320")
            |> place({5, 8}, format_points(pab[:match_points]), align: :right)
            |> place({10, 13}, format_points(pab[:game_points]), align: :right),
            fn {team, i}, acc ->
              place(acc, {15 + 4 * i, 17 + 4 * i}, if(team in [nil, 0], do: "", else: team),
                align: :right
              )
            end
          )
          |> render()
          |> String.trim_trailing()
          |> List.wrap()

        _ ->
          []
      end

    forfeits =
      for f <- t[:forfeited_matches] || [] do
        []
        |> place({1, 3}, "330")
        |> place({5, 6}, f[:type])
        |> place({8, 10}, f[:round], align: :right)
        |> place({12, 14}, f[:white], align: :right)
        |> place({16, 18}, f[:black], align: :right)
        |> render()
      end

    orders =
      for o <- t[:board_orders] || [] do
        (o[:order] || [])
        |> Enum.with_index()
        |> Enum.reduce(
          []
          |> place({1, 3}, "300")
          |> place({5, 7}, o[:round], align: :right)
          |> place({9, 11}, o[:team], align: :right)
          |> place({13, 15}, o[:opponent], align: :right),
          fn {rank, i}, acc ->
            place(acc, {17 + 5 * i, 20 + 5 * i}, if(rank in [nil, 0], do: "0", else: rank),
              align: :right
            )
          end
        )
        |> render()
      end

    points ++ pab ++ forfeits ++ orders
  end

  # A team with a number is a TRF26 `310` record (layout in parse/1's doc);
  # one without is the TRF16 `013` it always was.
  defp team_line(%{number: number} = t) when is_integer(number) do
    fields =
      []
      |> place({1, 3}, "310")
      |> place({5, 7}, number, align: :right)
      |> place({9, 40}, t[:name])
      |> place({42, 46}, t[:nickname])
      |> place({48, 53}, t[:strength], align: :right)
      |> place({55, 60}, t[:match_points] && format_points(t[:match_points]), align: :right)
      |> place({62, 67}, t[:game_points] && format_points(t[:game_points]), align: :right)
      |> place({69, 71}, t[:final_rank], align: :right)

    (t[:player_ranks] || [])
    |> Enum.with_index(1)
    |> Enum.reduce(fields, fn {rank, slot}, acc ->
      place(acc, team_310_player_cols(slot), rank, align: :right)
    end)
    |> render()
    |> String.trim_trailing()
  end

  defp team_line(t) do
    (t[:player_ranks] || [])
    |> Enum.with_index(1)
    |> Enum.reduce(
      [] |> place(@team_cols.code, "013") |> place(@team_cols.name, t[:name]),
      fn {rank, slot}, acc -> place(acc, team_player_cols(slot), rank, align: :right) end
    )
    |> render()
  end

  # Placements are collected as {start_col, text} and rendered in one pass.
  #
  # Truncation and padding are counted in BYTES, for the same reason
  # `read/2` indexes in bytes: a column is a byte everywhere this file's
  # output is read. Padding by grapheme instead shifted every field after a
  # name with an accent in it one column early for the reader on the other
  # end - FIDE's rating server, SWAR, Swiss-Manager - and, on the way back
  # in, for this module's own `read/2`.
  defp place(placements, {start_col, end_col}, value, opts \\ []) do
    width = end_col - start_col + 1

    text =
      (value || "")
      |> to_string()
      |> strip_controls()
      |> truncate_bytes(width)
      |> pad_bytes(width, opts[:align])

    [{start_col, text} | placements]
  end

  # A field narrower than its value is cut on a GRAPHEME boundary, never
  # mid-codepoint: half a UTF-8 sequence in the middle of a line is not a
  # short name, it is a file no reader can decode. The remaining columns are
  # then filled with spaces, so the row keeps its byte width either way.
  defp truncate_bytes(text, width) when byte_size(text) <= width, do: text

  defp truncate_bytes(text, width) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, size} ->
      next = size + byte_size(grapheme)
      if next > width, do: {:halt, {kept, size}}, else: {:cont, {[grapheme | kept], next}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp pad_bytes(text, width, align) do
    pad = String.duplicate(" ", max(width - byte_size(text), 0))
    if align == :right, do: pad <> text, else: text <> pad
  end

  # TRF is line- and column-oriented: a newline, carriage return or tab
  # inside a field (a player name has no format check beyond length) would
  # split or shift the fixed-width row - control characters are flattened
  # to spaces before the value is placed.
  #
  # A byte scan, not `String.replace(text, ~r/[\x00-\x1F\x7F]/, " ")`: on
  # this Elixir/OTP a regex literal is recompiled on every call, and this
  # runs once per field - ~35,000 compiles to write one 1000-player round.
  # Same bytes out: that regex had no `u` flag, so it matched single bytes,
  # and no byte of a multibyte UTF-8 sequence is below 0x80. Almost every
  # value has no control byte at all and is returned untouched.
  defp strip_controls(text) do
    if control_byte?(text),
      do: for(<<byte <- text>>, into: <<>>, do: <<flatten_control(byte)>>),
      else: text
  end

  defp control_byte?(<<byte, _::binary>>) when byte < 0x20 or byte == 0x7F, do: true
  defp control_byte?(<<_, rest::binary>>), do: control_byte?(rest)
  defp control_byte?(<<>>), do: false

  defp flatten_control(byte) when byte < 0x20 or byte == 0x7F, do: ?\s
  defp flatten_control(byte), do: byte

  # Folding to ASCII (é -> e), which is what FIDE itself stores names as.
  #
  # This was introduced as the fix for a column shift: `place/4` and
  # `render/1` counted graphemes while every reader of a submitted file
  # counts bytes, so one accented letter in one name moved every later
  # field a column early, and folding made the two counts the same thing
  # again. `place/4` now pads by byte, so that shift is gone and this is no
  # longer load-bearing for alignment. It is kept, still opt-in, for the
  # other half of what it was worth: a caller submitting to a registry that
  # wants plain ASCII names, or printing to a device that cannot render the
  # accents, can ask for the transliteration without doing it by hand.
  #
  # Applied to the whole `data` map up front rather than inside `place/4`,
  # because the request is not a property of the name field: the
  # `012`/`022`/`102` headers, the `013` team names and anything else
  # free-text carry names too, and folding once means no future placed
  # field can be forgotten.
  #
  # OFF by default, and that default is still the important half. The
  # pairing path writes a TRF that only an engine reads back, and
  # bbpPairings and JaVaFo both decode UTF-8 correctly - their pairings are
  # byte-identical with and without accents, and those exact bytes are what
  # the differential corpus validated this engine against.
  defp maybe_fold_ascii(data, true), do: deep_ascii(data)
  defp maybe_fold_ascii(data, _), do: data

  # Structs are left alone: a %Date{} or %Decimal{} is a value with its own
  # printing rules, not free text to be rewritten a character at a time.
  defp deep_ascii(%_{} = struct), do: struct
  defp deep_ascii(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, deep_ascii(v)} end)
  defp deep_ascii(list) when is_list(list), do: Enum.map(list, &deep_ascii/1)
  defp deep_ascii(text) when is_binary(text), do: ascii_fold(text)
  defp deep_ascii(other), do: other

  # Letters with no canonical decomposition, so NFD alone would leave them
  # non-ASCII. "ß" -> "ss" and "æ" -> "ae" LENGTHEN the string, which can
  # push a long name past its 33-column field - correct, and handled by the
  # same truncation in `place/4` that any over-long name already gets.
  @ascii_fallbacks %{
    "ß" => "ss",
    "æ" => "ae",
    "Æ" => "AE",
    "œ" => "oe",
    "Œ" => "OE",
    "ø" => "o",
    "Ø" => "O",
    "đ" => "d",
    "Đ" => "D",
    "ð" => "d",
    "Ð" => "D",
    "þ" => "th",
    "Þ" => "TH",
    "ł" => "l",
    "Ł" => "L",
    "ı" => "i",
    "İ" => "I",
    "ħ" => "h",
    "Ħ" => "H",
    "ŋ" => "n",
    "Ŋ" => "N",
    "ŧ" => "t",
    "Ŧ" => "T",
    "ĸ" => "k"
  }

  # Anything still non-ASCII after decomposition is a non-Latin script
  # (Cyrillic, Greek, CJK) with no one-to-one Latin form. It becomes "?"
  # rather than being dropped: a visibly wrong name is something an arbiter
  # can spot and fix before submitting, a silently shortened one is not -
  # and dropping it would put the column count back where the fold was
  # meant to fix it.
  defp ascii_fold(text) do
    @ascii_fallbacks
    |> Enum.reduce(text, fn {from, to}, acc -> String.replace(acc, from, to) end)
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.replace(~r/[^\x00-\x7F]/u, "?")
  end

  defp render(placements) do
    placements
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], 1}, fn {start, text}, {io, pos} ->
      # `byte_size`, not `String.length`: see `place/4` - a column is a byte.
      {[io, String.duplicate(" ", max(start - pos, 0)), text], start + byte_size(text)}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp trf_sex(s) when s in ["w", "W", "f", "F"], do: "w"
  defp trf_sex(s) when s in [nil, ""], do: ""
  defp trf_sex(_), do: "m"

  defp blank_if_falsy(v) when v in [nil, 0, ""], do: ""
  defp blank_if_falsy(v), do: v

  defp format_points(nil), do: "0.0"
  defp format_points(points), do: :erlang.float_to_binary(points / 1, decimals: 1)

  # yyyy-mm-dd -> yyyy/mm/dd
  defp slash_date(nil), do: nil
  defp slash_date(""), do: nil
  defp slash_date(date), do: String.replace(date, "-", "/")

  # yyyy-mm-dd -> yy/mm/dd (required for the "132" round-dates line)
  defp short_slash_date(date) do
    case String.split(date || "", "-") do
      [y, m, d] -> "#{String.slice(y, -2, 2)}/#{m}/#{d}"
      _ -> ""
    end
  end

  ## ---------- Result validation ----------

  # Validates every player's per-round result code, raising ValidationError
  # naming the player and round on the first illegal one found. Games with
  # no result yet (nil/"") are skipped. A code is checked two ways:
  #   1. It must be a recognized TRF16 result code at all.
  #   2. If it's a "playing" code (win/draw/loss/forfeit) and the opponent
  #      for that round is resolvable in `players` *and* mutually references
  #      this player back, the two codes must be a legal pair (see
  #      `@legal_result_pairs`). An unresolvable/dangling opponent reference
  #      is not itself flagged - the caller may be validating a partial
  #      roster.
  #
  # `opts[:allow_dangling_playing_code]` relaxes the "opponent 0000 needs a
  # bye code (F/H/Z/U)" rule below - those four codes didn't exist before
  # TRF16 (FIDE's Annexure-B, the 2006 spec: only 1/=/0/+/-/blank, a bye
  # represented as a dangling playing code against 0000, no dedicated bye
  # code at all). That rule protects OUR OWN pairing-output construction (a
  # dangling playing code there is a real crash risk downstream), which only
  # matters on the way OUT (`serialize/1`); a file we're reading FROM
  # someone else, possibly TRF06-vintage, is exactly what this option
  # exists for - `parse/1` passes it, `serialize/1` never does.
  #
  # `opts[:allow_unknown_result]` is the same shape and the same asymmetry,
  # and it is what makes `?` a READ-ONLY code rather than a code this module
  # happens not to emit today. `parse/1` passes it; `serialize/1` never
  # does, so a `?` handed to the writer is refused by name instead of being
  # placed in a column. One switch in one place, so "the engine does not
  # write unknown results" is a property with a single point of failure
  # rather than a habit of the render path.
  defp validate_games!(players, opts \\ []) do
    by_rank = Map.new(players, &{&1[:rank], &1})

    for player <- players,
        {game, round} <- Enum.with_index(player[:games] || [], 1) do
      validate_game!(player, round, game, by_rank, opts)
    end

    :ok
  end

  defp validate_game!(_player, _round, %{result: result}, _by_rank, _opts)
       when result in [nil, ""],
       do: :ok

  defp validate_game!(player, round, %{result: result} = game, by_rank, opts) do
    cond do
      # Ahead of the recognition test, so the message says which of the two
      # things is wrong. A caller who hands `?` to the writer has a code this
      # module documents and reads; telling them it is "unrecognized" would
      # send them looking for a typo.
      result in @unknown_codes and !opts[:allow_unknown_result] ->
        raise ValidationError,
          message:
            "#{player_label(player)}, round #{round}: #{inspect(result)} is a read-only result " <>
              "code - `parse/1` accepts it, nothing writes it"

      result not in (@opposed_codes ++ @bye_codes) ->
        raise ValidationError,
          message:
            "#{player_label(player)}, round #{round}: unrecognized TRF result code #{inspect(result)}"

      result in @opposed_codes and is_nil(game[:opponent_rank]) and
          !opts[:allow_dangling_playing_code] ->
        raise ValidationError,
          message:
            "#{player_label(player)}, round #{round}: opponent 0000 cannot carry played-game result " <>
              "#{inspect(result)} - opponentless games must use a bye code (F/H/Z/U)"

      result in @opposed_codes ->
        validate_playing_pair!(player, round, game, by_rank, result)

      true ->
        :ok
    end
  end

  defp validate_playing_pair!(player, round, game, by_rank, result) do
    with opp_rank when not is_nil(opp_rank) <- game[:opponent_rank],
         opponent when not is_nil(opponent) <- Map.get(by_rank, opp_rank),
         opp_game when not is_nil(opp_game) <- Enum.at(opponent[:games] || [], round - 1),
         true <- opp_game[:opponent_rank] == player[:rank],
         opp_result when opp_result not in [nil, ""] <- opp_game[:result] do
      unless opp_result in Map.get(@legal_result_pairs, result, []) do
        raise ValidationError,
          message:
            "#{player_label(player)} vs #{player_label(opponent)}, round #{round}: " <>
              "illegal result combination '#{result}' / '#{opp_result}'"
      end
    else
      _ -> :ok
    end
  end

  defp player_label(p), do: to_string(p[:name] || p[:rank])

  defp strip_bom("﻿" <> rest), do: rest
  defp strip_bom(text), do: text

  ## ---------- Parsing ----------

  @doc """
  Inverse of serialize/1: returns %{tournament: ..., players: ..., teams: ...}.

  Tolerates a TRF06-vintage file (FIDE's Annexure-B, 2006): before TRF16
  added the F/H/U/Z bye codes, a bye was just a dangling playing code
  against opponent 0000 (see `validate_games!/2`'s
  `allow_dangling_playing_code` option) - column positions are otherwise
  byte-identical between the two versions, so no separate TRF06 parser is
  needed, just this one relaxed rule.

  Accepts the `?` unknown-result code, which `serialize/1` refuses, and
  hands it back as `"?"` - see the moduledoc's "The `?` unknown result" for
  what it then means to everything that reads a result. A code that is
  neither `?` nor a real one is still refused: the concession is to one
  documented symbol, not to unrecognized input in general.

  `XXP` lines land in `tournament[:forbidden_pairs]`, and `XXA` lines
  attach an `:accelerations` list to the player they name. Neither key is
  added at all when the file carries no such line, so a plain TRF parses
  to exactly the same shape it always did. A malformed one of either
  raises `Ainalrami.Trf.ValidationError` - see the moduledoc.

  TRF26's records are read to the same shape: `162` and `299` into
  `tournament[:point_system]`, `250` and `260` as above, `240` into the
  players' games (and all of them into `tournament[:byes]`), and the
  `192`/`202`/`212`/`222` headers into `tournament[:type_code]`,
  `[:tie_breaks]`, `[:standings_order]` and `[:time_control_code]`.

  TRF26 team records: each `310` becomes a team (`:number`, `:name`,
  `:nickname`, `:strength`, `:match_points`, `:game_points`, `:final_rank`,
  `:player_ranks`), and when a file has any `310` its `013` lines are
  ignored; `362` goes to `tournament[:team_point_system]` (`%{win:, draw:,
  loss:}` plus `:pab`, `:absent`, `:unknown` when given), `320` to
  `[:team_pab]`, `330` lines to `[:forfeited_matches]` and `300` lines
  (a team's board order in one match) to `[:board_orders]` (`%{round:,
  team:, opponent:, order: [starting rank, 0 for an empty board]}`).
  `801`, `802` and national-rating records are not read. Columns (1-based) as FIDE's TRF-2026 description lays them out and
  TieBreakServer's `trf2json.py` reads them: `310` team number 5-7, name
  9-40, nickname 42-46, strength 48-53, match points 55-60, game points
  62-67, rank 69-71, players' starting ranks in 4-column fields from 74
  every 5; `362` a symbol (`W` `D` `L` `P` `A` `X`) in column 6 and its
  points in 7-10, repeating every 9 columns; `320` match points 5-8, game
  points 10-13, then the team given the bye in each round, 3 columns from
  15 every 4; `330` type 5-6, round 8-10, white team 12-14, black team
  16-18; `300` round 5-7, team 9-11, opponent 13-15, then the starting
  ranks in board order, 4 columns from 17 every 5. `serialize/2` writes all
  five back.
  """
  def parse(text) do
    lines =
      text
      # A UTF-8 byte-order mark, dropped ONCE before anything else looks at
      # the text. Windows Notepad writes one by default and this project
      # ships a Windows binary, so an arbiter editing a TRF by hand is the
      # ordinary way to acquire one. Three bytes ahead of the first line's
      # code makes that line's code `"﻿00"`, which matches nothing:
      # the file's first record - a `012` name, or a whole player - was
      # silently discarded and the parse succeeded. Sweep 2026-09-01, H4.
      #
      # Only leading, and only one: a BOM anywhere else in a TRF is a
      # zero-width no-break space inside a field, which is the field's
      # business, not this function's.
      |> strip_bom()
      # All three line endings, not just the two anyone expects. Real
      # bbpPairings writes its generated TRFs with a BARE `\r` and no `\n`
      # at all -- 212 of them in a 209-player file, zero newlines -- so
      # `\r?\n` matched nothing, the whole file parsed as a single line,
      # and `parse/1` returned zero players without complaint.
      #
      # That made this engine unable to read the reference implementation's
      # own output, which no test could see: the comparison harness only
      # ever feeds OUR files to THEM. Found by generating a tournament with
      # `bbpPairings --dutch -g -o` and reading it back.
      #
      # `\r\n` has to be first in the alternation so a CRLF is consumed as
      # one separator rather than as two.
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.reject(&(String.trim(&1) == ""))

    empty = %{
      tournament: %{deputy_arbiters: []},
      players: [],
      teams: [],
      accelerations: %{},
      acceleration_ranges: [],
      byes: []
    }

    result =
      Enum.reduce(lines, empty, fn line, acc ->
        case String.slice(line, 0, 3) do
          # PREPENDED, not appended, and reversed once below. `&1 ++ [x]`
          # copies the whole list per record, so reading n players cost
          # O(n^2): measured 10 ms at 1,000 records, 280 ms at 8,000, and
          # over an hour for the million `001` lines a 5 MB file of them
          # holds. A file that size is not a tournament - the starting-rank
          # field is four columns, so no TRF can name more than 9,999
          # players - but an engine should not be the thing that decides
          # that, and the sibling app now refuses such a file at the door
          # (`PairingsEngine.TrfImport.check_bounds/1`) BECAUSE this was
          # quadratic. Linear here means the refusal is a policy rather
          # than a load-bearing guard.
          "001" ->
            update_in(acc.players, &[parse_player_line(line) | &1])

          "013" ->
            update_in(acc.teams, &[parse_team_line(line) | &1])

          "310" ->
            Map.update(acc, :teams_310, [parse_310(line)], &[parse_310(line) | &1])

          "320" ->
            put_in(acc.tournament[:team_pab], parse_320(line))

          "330" ->
            update_in(acc.tournament[:forfeited_matches], &((&1 || []) ++ [parse_330(line)]))

          "300" ->
            update_in(acc.tournament[:board_orders], &((&1 || []) ++ [parse_300(line)]))

          "362" ->
            put_in(acc.tournament[:team_point_system], parse_362(line))

          "132" ->
            put_in(acc.tournament[:round_dates], parse_round_dates(line))

          "XXR" ->
            parse_xxr(acc, line)

          "XXP" ->
            parse_xxp(acc, line)

          "XXA" ->
            parse_xxa(acc, line)

          "XXC" ->
            parse_xxc(acc, line)

          "XXM" ->
            parse_xxm(acc, line)

          "XXG" ->
            parse_xxg(acc, line)

          "XXO" ->
            parse_xxo(acc, line)

          "XXZ" ->
            parse_xxz(acc, line)

          "250" ->
            parse_250(acc, line)

          "260" ->
            parse_260(acc, line)

          "162" ->
            parse_point_system(acc, line)

          "240" ->
            parse_240(acc, line)

          "299" ->
            parse_299(acc, line)

          code when code in @bb_codes ->
            parse_bb_points(acc, code, line)

          code ->
            parse_header_line(acc, code, line)
        end
      end)

    # The two hot record types are accumulated in reverse (see the reduce
    # above); every other key keeps file order as it always did.
    result = %{result | players: Enum.reverse(result.players), teams: Enum.reverse(result.teams)}

    # A file with TRF26 `310` team records is read from them, and its `013`
    # lines (if any, written for older readers) are then ignored - the same
    # precedence TieBreakServer gives them (`trf2json.py`, `read_all_lines`).
    result =
      case Map.pop(result, :teams_310) do
        {nil, result} -> result
        {teams, result} -> %{result | teams: Enum.reverse(teams)}
      end

    validate_games!(result.players,
      allow_dangling_playing_code: true,
      allow_unknown_result: true
    )

    # The round about to be paired, counted once for both of the records
    # that place something in it, so neither can move the goalposts for
    # the other. A round paired with nothing but whole-match forfeits
    # (`330`) counts, as `split_future_byes/4` counts it when writing.
    played = max(rounds_played(result.players), team_rounds(result.tournament))

    result
    |> check_pairing_groups!()
    |> check_organiser_records!()
    |> attach_round_ratings()
    |> attach_accelerations()
    |> attach_absences(played)
    |> attach_byes(played)
  end

  # bbpPairings' point-system directives (`trf.cpp:1203-1232`) plus TRF16's
  # own `162` line, which says the same thing in fixed columns.
  #
  # ## Why an engine needs these at all
  #
  # They set what a result is WORTH, and a player's score is what decides
  # which bracket they are paired in. Every score group in the Dutch system
  # is built from these numbers, so an engine that ignores them does not
  # merely report the wrong totals - it pairs a different tournament. The
  # one an organiser is most likely to change is `BBU`: FIDE permits valuing
  # the pairing-allocated bye at half a point rather than a full one, and
  # that moves its recipient into a different score group for every
  # remaining round.
  #
  # Unread until 2026-08-24, which meant they fell through to the header
  # parser and were silently discarded - the same failure mode `250`/`260`
  # had, and with the same consequence: a legal-looking round paired on
  # scores the file did not ask for.
  defp parse_bb_points(acc, code, line) do
    value = read_points!(String.slice(line, 3..-1//1), line)
    field = Map.fetch!(@bb_fields, code)

    acc
    |> put_point(field, value)
    |> then(fn acc ->
      # `BBW` moves the pairing-allocated bye with it unless `BBU` has
      # already pinned it - bbpPairings' `usePairingAllocatedByeScore` flag.
      # Order matters, and it is the FILE's order, not ours.
      if field == :win and not Map.get(acc, :pab_pinned?, false) do
        put_point(acc, :pairing_allocated_bye, value)
      else
        acc
      end
    end)
    |> then(fn acc ->
      if field == :pairing_allocated_bye, do: Map.put(acc, :pab_pinned?, true), else: acc
    end)
  end

  # `162 <char><score> <char><score> ...`, nine columns per entry starting at
  # column 6 (`readPointSystem`, trf.cpp:573-631). `A` is a synonym for `Z`
  # and sets the forfeit loss along with it. `X` is FIDE TRF-2026's symbol
  # for what an unknown (`?`) result is worth - unimplemented by the
  # reference, which predates TRF-2026, but a file that declares it is
  # stating a value, not asking this engine to invent one, so it is stored
  # under `:unknown` rather than refused; see the moduledoc's "The `?`
  # unknown result" for what reads it back and what still refuses without a
  # declared `X`.
  defp parse_point_system(acc, line) do
    line
    |> String.slice(5..-1//1)
    |> to_string()
    |> chunk_point_entries()
    |> Enum.reduce(acc, fn {char, score_text}, acc ->
      score = read_points!(score_text, line)

      case char do
        "W" ->
          acc = put_point(acc, :win, score)

          if Map.get(acc, :pab_pinned?, false),
            do: acc,
            else: put_point(acc, :pairing_allocated_bye, score)

        "D" ->
          put_point(acc, :draw, score)

        "L" ->
          put_point(acc, :loss, score)

        c when c in ["Z", "A"] ->
          acc |> put_point(:zero_point_bye, score) |> put_point(:forfeit_loss, score)

        "P" ->
          acc |> put_point(:pairing_allocated_bye, score) |> Map.put(:pab_pinned?, true)

        "X" ->
          put_point(acc, :unknown, score)

        other ->
          raise ValidationError,
            message: "162 line has unknown result symbol #{inspect(other)}: #{line}"
      end
    end)
  end

  defp chunk_point_entries(rest) do
    rest
    |> String.graphemes()
    |> Enum.chunk_every(9)
    |> Enum.map(&Enum.join/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(fn entry ->
      {String.slice(entry, 0, 1), String.slice(entry, 1, 4)}
    end)
  end

  defp put_point(acc, field, value) do
    system = acc.tournament[:point_system] || default_point_system()
    put_in(acc.tournament[:point_system], Map.put(system, field, value))
  end

  defp read_points!(text, line) do
    case text |> to_string() |> String.trim() |> Float.parse() do
      {value, ""} when value >= 0 -> value
      _ -> raise ValidationError, message: "unreadable point value: #{line}"
    end
  end

  # An `XXA` line may legally precede the `001` line of the player it names
  # - bbpPairings handles the same ordering problem by pre-sizing
  # `tournament.players` in `readPlayerAccelerationsXxa` and then MOVING the
  # accelerations onto the real player record when its `001` line arrives
  # (`trf.cpp:369-372`). Collecting them in a rank-keyed map and merging at
  # the end is the same thing without the resize dance.
  #
  # The key is only added to players that actually have one, so a file with
  # no `XXA` at all parses to the identical map it did before.
  defp attach_accelerations(%{accelerations: accelerations, acceleration_ranges: ranges} = result) do
    # `250` ranges are expanded first, then `XXA` rows are APPENDED to
    # them rather than laid over them.
    #
    # Appending looks odd and is what the reference does:
    # `readPlayerAccelerationsXxa` (`trf.cpp:487-514`) calls `push_back` on
    # the player's acceleration vector, so an `XXA` line lands after
    # whatever a `250` already filled in - round 3 onwards, not round 1.
    # This engine's own `parse_xxa/2` already appends when two `XXA` lines
    # name the same player, so the two are consistent.
    #
    # Overwriting instead put `XXA`'s values at rounds 1-2 and produced a
    # different bracket from bbpPairings on the same bytes. A file carrying
    # both forms is exotic - `XXA` is JaVaFo's spelling and `250` is
    # bbpPairings' - but "exotic" is not a reason to diverge silently.
    expanded = Enum.reduce(ranges, %{}, &expand_acceleration_range/2)

    merged =
      Map.merge(expanded, accelerations, fn _rank, from_250, from_xxa ->
        from_250 ++ from_xxa
      end)

    players =
      if merged == %{} do
        result.players
      else
        Enum.map(result.players, fn player ->
          case Map.fetch(merged, player[:rank]) do
            {:ok, values} -> Map.put(player, :accelerations, values)
            :error -> player
          end
        end)
      end

    result
    |> Map.put(:players, players)
    |> Map.delete(:accelerations)
    |> Map.delete(:acceleration_ranges)
  end

  # One `250` line covers players `first_player..last_player` for rounds
  # `first_round..last_round`, both inclusive. Rounds before the range pay
  # nothing, which is the `accelerations.resize(roundStart)` zero-fill in
  # `readAccelerations250`.
  defp expand_acceleration_range({points, first_round, last_round, first, last}, acc) do
    row = for round <- 1..last_round, do: if(round >= first_round, do: points, else: 0.0)

    Enum.reduce(first..last, acc, fn rank, inner ->
      Map.update(inner, rank, row, &merge_acceleration_rows(&1, row))
    end)
  end

  # Two ranges can overlap in rounds; the later line wins for the rounds it
  # names, and anything it does not reach keeps the earlier value.
  defp merge_acceleration_rows(existing, new) do
    length = max(length(existing), length(new))

    for index <- 0..(length - 1)//1 do
      value = Enum.at(new, index)

      if is_nil(value) or value == 0.0 do
        Enum.at(existing, index, 0.0)
      else
        value
      end
    end
  end

  # `XXR n` is JaVaFo's own extension for the number of rounds, and it is
  # what JaVaFo actually consumes - plenty of real files carry it INSTEAD
  # of TRF16's `142`, not as well as. Read as a fallback so both spellings
  # land in the same field; an explicit `142` always wins.
  #
  # Missing this was a real defect, not a tidiness issue. The round count
  # feeds the final-round exception in `Ainalrami.Pairing`'s
  # `colour_compatible?/2`, so a file carrying only `XXR` was paired with a
  # round count and re-checked without one - the two disagreeing on
  # exactly the last round, and no other. Found by fuzzing `-g` output
  # through `-c`: 4 failures in 250, every one of them the final round.
  defp parse_xxr(acc, line) do
    case line |> String.slice(3..-1//1) |> String.trim() |> Integer.parse() do
      {rounds, _rest} ->
        check_round_count_agreement!(acc.tournament[:number_of_rounds], rounds)
        update_in(acc.tournament, fn t -> Map.put_new(t, :number_of_rounds, rounds) end)

      :error ->
        acc
    end
  end

  # A file may carry both spellings - `142` is TRF16's, `XXR` is JaVaFo's,
  # and a file that has passed through both toolchains can hold each. Two
  # copies of the same number are fine; two DIFFERENT numbers are not, and
  # this refuses rather than picking one.
  #
  # Picking one is what every implementation does and they do not agree:
  # this engine preferred `142` regardless of position, bbpPairings takes
  # whichever line comes LAST (`trf.cpp:1117-1124` assigns
  # `expectedRounds` from either prefix, so the later assignment wins). On
  # `142 9` followed by `XXR 5` the two therefore pair different final
  # rounds from the same bytes.
  #
  # It has to be a refusal for the reason `parse_xxp/2` raises: the round
  # count feeds the final-round exception in `colour_compatible?/2` and the
  # topscorer threshold in `final_round_topscorers?/2`, so the wrong value
  # yields a complete, perfectly legal-LOOKING round that applies the
  # last-round rules to the wrong round - with nothing downstream able to
  # tell. A self-contradictory file has no correct pairing, only two
  # plausible ones.
  defp check_round_count_agreement!(nil, _rounds), do: :ok
  defp check_round_count_agreement!(same, same), do: :ok

  defp check_round_count_agreement!(existing, rounds) do
    raise ValidationError,
          "the file gives two different round counts (#{existing} and #{rounds}); " <>
            "`142` and `XXR` are the same field and must agree"
  end

  # `XXC [rank] [white1|black1]` - JaVaFo's free-form spelling of the two
  # settings TRF16 gives fixed columns to. A port of `trf.cpp:1143-1177`,
  # which takes `line.substr(3)`, tokenizes on space/tab, and folds the
  # tokens left to right; unknown tokens are skipped, and the LAST of
  # `white1`/`black1` wins.
  #
  # `white1`/`black1` is the same field as `152` (C.04.3 5.1: the colour
  # drawn by lot before round 1, which 5.2.5 hands to the higher ranked
  # player of a pair when neither holds a preference, on the parity of that
  # player's arrival number rather than of their TPN). A file may carry
  # either spelling; unlike `142`/`XXR` these are not checked against each
  # other, because the reference does not check them either - it assigns as
  # it reads, so the later line simply wins, and that is what reading the
  # lines in file order does here. READ ONLY: `serialize/1` emits `152`, the
  # TRF16 spelling, the same way an incoming `XXR` goes out as `142`.
  #
  # `rank` RAISES. It tells the reference to use the RANK column (86-89) as
  # the effective pairing number for colour assignment and tie-breaking
  # instead of the start number (`computePlayerIndexes`, `trf.cpp:691-706`),
  # and this engine has no such notion - `parse_player_line/1` reads
  # `rank:` from columns 5-8 unconditionally. Ignoring it would pair a
  # DIFFERENT tournament from the one the file describes and report it with
  # full confidence, which is exactly the failure `XXP` raises to avoid. A
  # file carrying it is refused until the ordering is implemented.
  defp parse_xxc(acc, line) do
    line
    |> String.slice(3..-1//1)
    |> String.split([" ", "	"], trim: true)
    |> Enum.reduce(acc, fn
      "white1", acc -> put_in(acc.tournament[:initial_colour], "w")
      "black1", acc -> put_in(acc.tournament[:initial_colour], "b")
      "rank", _acc -> raise ValidationError, message: rank_ordering_message(line)
      _other, acc -> acc
    end)
  end

  defp rank_ordering_message(line) do
    "`XXC rank` asks for the rank column (86-89) to be used as the pairing " <>
      "number, which this engine does not implement - it would pair a " <>
      "different tournament than the file describes: #{line}"
  end

  # `XXP a b [c ...]` - a mutually-forbidden GROUP of players, JaVaFo's own
  # extension for an arbiter's "these must never meet" (family members, the
  # same club, a federation exclusion rule).
  #
  # A port of `readForbiddenPairsXxp` (`trf.cpp:554-568`), which takes
  # `line.substr(3)` and tokenizes on space/tab into a LIST of player ids.
  # So one line is an N-player group in which EVERY pair is forbidden, not
  # just a pair - the sibling project only ever emits two ids per line, but
  # the general form is what the reference reads and so is what this reads.
  # bbpPairings then files each list under rounds `[0, expectedRounds)`
  # (`trf.cpp:1344-1347`), i.e. universally, which is why no round range is
  # kept here; its round-limited sibling is the `260` line, not this one.
  #
  # An unreadable id RAISES, where `parse_xxr/2` next door merely shrugs.
  # That difference is deliberate and is the whole point of this commit:
  # `XXR` has a safe fallback (the `142` header, or no round count at all),
  # while a dropped `XXP` produces a complete, perfectly legal-LOOKING
  # pairing that seats two players an arbiter said must never meet, with
  # nothing downstream able to tell. bbpPairings takes the same view -
  # `readPlayerId` throws `InvalidLineException` and the whole file is
  # rejected (exit code 3, confirmed by direct invocation).
  #
  # A line naming fewer than two players is accepted and then dropped, not
  # raised on: bbpPairings accepts it too (an empty or one-element deque
  # inserts a player into their own forbidden set at most, and nobody is
  # ever a candidate opponent for themselves).
  defp parse_xxp(acc, line) do
    ids =
      line
      |> String.slice(3..-1//1)
      |> String.split([" ", "\t"], trim: true)
      |> Enum.map(fn token ->
        # STRICT: `parse_int/1` is `Integer.parse` with the remainder thrown
        # away, so it reads "12,13" as 12 and "3x" as 3. Written with any
        # separator but a space - a comma, a semicolon, a dash - the line
        # therefore yielded ONE id, fell through the `length(ids) < 2`
        # branch below, and was discarded in silence. That is the exact
        # failure this module's moduledoc says it raises to prevent: the
        # arbiter's "these two must never meet" dropped on the floor, and a
        # complete, perfectly legal-looking pairing seating them together
        # with nothing downstream able to notice.
        #
        # `read_260_ids/3` already matches `{id, ""}` for the same reason,
        # so the two spellings of one rule now behave alike on the same
        # malformed input - as does bbpPairings, whose `readPlayerId`
        # throws `InvalidLineException` here.
        strict_int(token) ||
          raise ValidationError,
            message: "XXP line names #{inspect(token)}, which is not a starting rank: #{line}"
      end)

    if length(ids) < 2 do
      acc
    else
      update_in(acc.tournament[:forbidden_pairs], &((&1 || []) ++ [ids]))
    end
  end

  # `XXM` - this engine's own extension (see the moduledoc): every match is
  # two games in a row, colours reversed in the second. Nothing may follow
  # the code: a value would be a request this engine does not know how to
  # honour (three-game matches, say), and pairing the two-game shape
  # instead would be pairing a different event.
  defp parse_xxm(acc, line) do
    case line |> String.slice(3..-1//1) |> String.trim() do
      "" ->
        put_in(acc.tournament[:match_format], true)

      other ->
        raise ValidationError,
          message:
            "XXM takes no value (a match is two games, colours reversed), got " <>
              "#{inspect(other)}: #{line}"
    end
  end

  # `XXG a b [c ...]` - this engine's own extension: one pairing group (a
  # category paired on its own), its players by starting rank. Raises on
  # an unreadable rank for `parse_xxp/2`'s reason - a group read wrong
  # pairs players across categories with nothing to show for it. Ranks
  # unknown to the file, and a rank in two groups, are refused once every
  # line is read (`check_pairing_groups!/1`).
  defp parse_xxg(acc, line) do
    ids =
      line
      |> String.slice(3..-1//1)
      |> String.split([" ", "\t"], trim: true)
      |> Enum.map(fn token ->
        strict_int(token) ||
          raise ValidationError,
            message: "XXG line names #{inspect(token)}, which is not a starting rank: #{line}"
      end)

    if ids == [] do
      raise ValidationError, message: "XXG line names nobody: #{line}"
    end

    update_in(acc.tournament[:pairing_groups], &((&1 || []) ++ [ids]))
  end

  defp check_pairing_groups!(%{tournament: %{pairing_groups: groups}} = result)
       when is_list(groups) do
    ranks = MapSet.new(result.players, & &1.rank)
    all = List.flatten(groups)

    case Enum.find(all, &(not MapSet.member?(ranks, &1))) do
      nil ->
        :ok

      rank ->
        raise ValidationError,
          message: "XXG names #{rank}, which is not a starting rank in this file"
    end

    case all -- Enum.uniq(all) do
      [] -> result
      [rank | _] -> raise ValidationError, message: "XXG puts #{rank} in two pairing groups"
    end
  end

  defp check_pairing_groups!(result), do: result

  # `XXO keyword ...` - this engine's own extension (see the moduledoc, "The
  # organiser's records"): the options OpenPairings pairs and ranks with
  # that no TRF record carries, under one code and the command line's own
  # names. One code rather than one per option because every new `XX` code
  # is a chance of meaning something else to another program - JaVaFo's
  # `XXS` is its point system, which is why soft pairs are not `XXS`.
  #
  # Refused when malformed, as `XXP` is: a wish read wrong is a round paired
  # by rules nobody asked for.
  defp parse_xxo(acc, line) do
    rest = line |> String.slice(3..-1//1) |> String.trim()

    case String.split(rest, [" ", "\t"], parts: 2, trim: true) do
      [keyword, text] when keyword in ["team-forbidden", "team-soft-pairs"] ->
        case Ainalrami.PairingInput.parse_group(text) do
          {:ok, group} ->
            key =
              if keyword == "team-forbidden", do: :team_forbidden_pairs, else: :team_soft_pairs

            update_in(acc.tournament[key], &((&1 || []) ++ [group]))

          :error ->
            raise ValidationError,
              message:
                "XXO #{keyword} takes two or more team numbers, optionally @ROUND or " <>
                  "@FIRST-LAST: #{line}"
        end

      ["soft-pairs", text] ->
        case Ainalrami.PairingInput.parse_group(text) do
          {:ok, group} ->
            update_in(acc.tournament[:soft_pairs], &((&1 || []) ++ [group]))

          :error ->
            raise ValidationError,
              message:
                "XXO soft-pairs takes two or more starting ranks, optionally @ROUND or " <>
                  "@FIRST-LAST: #{line}"
        end

      ["soft-position", word] ->
        case String.trim(word) do
          "strong" ->
            put_in(acc.tournament[:soft_position], :strong)

          "weak" ->
            put_in(acc.tournament[:soft_position], :weak)

          _ ->
            raise ValidationError, message: "XXO soft-position takes strong or weak: #{line}"
        end

      ["round-ratings", text] ->
        parse_xxo_ratings(acc, text, line)

      ["provisional-rating", text] ->
        parse_xxo_provisional(acc, text, line)

      ["bye-" <> kind = keyword, text] ->
        kinds = Map.new(Ainalrami.PairingInput.bye_kinds())

        unless kind == "exclude" or Map.has_key?(kinds, kind) do
          raise ValidationError, message: "XXO does not have #{inspect(keyword)}: #{line}"
        end

        entries =
          text
          |> String.split([" ", "\t"], trim: true)
          |> Enum.map(fn token ->
            case Ainalrami.PairingInput.parse_ranked(token) do
              {:ok, rank, rounds} ->
                {rank, rounds}

              :error ->
                raise ValidationError,
                  message:
                    "XXO #{keyword} takes starting ranks, each optionally with @ROUNDS " <>
                      "(e.g. 12@3-4+7): #{line}"
            end
          end)

        if kind == "exclude" do
          entries =
            Enum.map(entries, fn
              {rank, :all} -> rank
              entry -> entry
            end)

          update_in(acc.tournament[:bye_exclusions], &((&1 || []) ++ entries))
        else
          setting = Map.fetch!(kinds, kind)

          entries =
            Enum.map(entries, fn
              {rank, :all} -> {rank, setting}
              {rank, rounds} -> {rank, setting, rounds}
            end)

          update_in(acc.tournament[:bye_preferences], &((&1 || []) ++ entries))
        end

      [keyword | _] ->
        raise ValidationError,
          message:
            "XXO does not have #{inspect(keyword)} (soft-pairs, soft-position, bye-want, " <>
              "bye-want-soft, bye-avoid, bye-avoid-soft, bye-exclude, round-ratings, provisional-rating, " <>
              "team-forbidden, team-soft-pairs), or " <>
              "it has nothing after it: #{line}"

      [] ->
        raise ValidationError, message: "XXO line says nothing: #{line}"
    end
  end

  # `XXO provisional-rating rank rating`: the rating the Chief Arbiter gives an
  # unrated player for the Dubov system (C.04.4.1 Article 1.1.2), which pairs
  # by ratings and requires every player to have one. A FIDE rule, not the
  # organiser's own, so it is not one of `PairingInput.organiser?/1`'s.
  defp parse_xxo_provisional(acc, text, line) do
    case text |> String.split([" ", "\t"], trim: true) |> Enum.map(&strict_int/1) do
      [rank, rating] when is_integer(rank) and is_integer(rating) and rating > 0 ->
        if Map.has_key?(acc.tournament[:provisional_ratings] || %{}, rank) do
          raise ValidationError,
            message: "two XXO provisional-rating lines for starting rank #{rank}"
        end

        update_in(acc.tournament[:provisional_ratings], &Map.put(&1 || %{}, rank, rating))

      _ ->
        raise ValidationError,
          message: "XXO provisional-rating takes a starting rank and a positive rating: #{line}"
    end
  end

  # `XXO round-ratings rank rating rating ...`: the rating a player held in
  # each round, for the rating tie-breaks of an event whose regulations
  # count them that way (C.07 Article 10's note, VCL4THP Q214). `-` or `0`
  # is a round with nothing to say: the 001 rating counts.
  defp parse_xxo_ratings(acc, text, line) do
    bad = fn ->
      raise ValidationError,
        message:
          "XXO round-ratings takes a starting rank, then one rating per round " <>
            "(- or 0 for none): #{line}"
    end

    case String.split(text, [" ", "\t"], trim: true) do
      [rank | [_ | _] = ratings] ->
        rank = strict_int(rank) || bad.()

        by_round =
          ratings
          |> Enum.with_index(1)
          |> Enum.flat_map(fn
            {"-", _round} ->
              []

            {token, round} ->
              case strict_int(token) do
                0 -> []
                n when is_integer(n) and n > 0 -> [{round, n}]
                _ -> bad.()
              end
          end)
          |> Map.new()

        if Map.has_key?(Map.get(acc, :round_ratings, %{}), rank) do
          raise ValidationError, message: "two XXO round-ratings lines for starting rank #{rank}"
        end

        Map.update(acc, :round_ratings, %{rank => by_round}, &Map.put(&1, rank, by_round))

      _ ->
        bad.()
    end
  end

  # Every rank an `XXO` line names has to be a rank the
  # file has - checked once every line is read, as `XXG` is.
  defp check_organiser_records!(result) do
    t = result.tournament

    named =
      Enum.flat_map(t[:soft_pairs] || [], fn
        {ids, _first, _last} -> Enum.map(ids, &{"XXO", &1})
        ids -> Enum.map(ids, &{"XXO", &1})
      end) ++
        Enum.map(t[:bye_exclusions] || [], fn
          {rank, _rounds} -> {"XXO", rank}
          rank -> {"XXO", rank}
        end) ++
        Enum.map(t[:bye_preferences] || [], &{"XXO", elem(&1, 0)}) ++
        Enum.map(Map.keys(Map.get(result, :round_ratings, %{})), &{"XXO", &1})

    if named == [] do
      result
    else
      ranks = MapSet.new(result.players, & &1.rank)

      case Enum.find(named, fn {_code, rank} -> not MapSet.member?(ranks, rank) end) do
        nil ->
          result

        {code, rank} ->
          raise ValidationError,
            message: "#{code} names #{rank}, which is not a starting rank in this file"
      end
    end
  end

  defp attach_round_ratings(result) do
    case Map.pop(result, :round_ratings) do
      {nil, result} ->
        result

      {by_rank, result} ->
        players =
          Enum.map(result.players, fn player ->
            case Map.fetch(by_rank, player[:rank]) do
              {:ok, ratings} -> Map.put(player, :round_ratings, ratings)
              :error -> player
            end
          end)

        %{result | players: players}
    end
  end

  # `250` - bbpPairings' ROUND-LIMITED acceleration, the fixed-column
  # sibling of `XXA`. One line hands the same number of virtual points to a
  # RANGE of players over a RANGE of rounds, where `XXA` spells out one
  # player's whole row.
  #
  # A port of `readAccelerations250` (`trf.cpp:418-482`). Columns, all
  # 1-based here and inclusive: match points in 5-9, which must be blank or
  # zero; game points in 10-14, which must be non-zero; the round range in
  # 15-18 and 19-22; the player range in 23-27 and 28-32. Shorter than 31
  # characters, either range inverted, or a zero round index, and the line
  # is refused - every one of those is an `InvalidLineException` there.
  #
  # Silently discarding it was the same defect `260` had: acceleration
  # changes a player's score for bracketing purposes, so a dropped line
  # produces a complete, well-formed round paired on the wrong scores.
  # bbpPairings' own Baku pass measured that at 66.12% of rounds when
  # `XXA` was being dropped.
  defp parse_250(acc, line) do
    # Byte length, like every other column measurement in this module.
    if byte_size(line) < 31 do
      raise ValidationError, message: "250 line is too short: #{line}"
    end

    match_points = read(line, {5, 9})

    if match_points not in ["", "0", "0.0"] do
      raise ValidationError,
        message: "250 line must not carry match points, got #{inspect(match_points)}: #{line}"
    end

    points =
      case line |> read({10, 14}) |> parse_float() do
        nil ->
          raise ValidationError, message: "250 line has unreadable game points: #{line}"

        value ->
          if value == 0.0 do
            raise ValidationError, message: "250 line has zero game points: #{line}"
          end

          value
      end

    first_round = positive_field!(line, {15, 18}, line, "250", "first round number")
    last_round = positive_field!(line, {19, 22}, line, "250", "last round number")
    first_player = positive_field!(line, {23, 27}, line, "250", "first player starting rank")
    last_player = positive_field!(line, {28, 32}, line, "250", "last player starting rank")

    if first_round > last_round or first_player > last_player do
      raise ValidationError, message: "250 line has an inverted range: #{line}"
    end

    update_in(
      acc.acceleration_ranges,
      &(&1 ++ [{points, first_round, last_round, first_player, last_player}])
    )
  end

  # `260` - bbpPairings' ROUND-LIMITED forbidden pairs, the fixed-column
  # sibling of `XXP`. Same meaning, but confined to a range of rounds:
  # "these players must not meet in rounds 3 to 7".
  #
  # A port of `readForbiddenPairs260` (`trf.cpp:519-548`): the first round
  # is read from columns 5-7, the last from 9-11, and the ids follow from
  # column 13 in four-character fields every five columns. bbpPairings
  # stores the range as `[first, last + 1)`, i.e. the last round is
  # INCLUSIVE, and rejects the line outright if it is shorter than 18
  # characters or carries anything but spaces after the final id.
  #
  # This was on the "deliberately not covered" list until 2026-08-17, on
  # the reasoning that `XXP` is the universal form and the one the sibling
  # project emits. That reasoning was wrong in a specific and dangerous
  # way: "not covered" meant the line fell through to `parse_header_line/3`
  # and was SILENTLY DISCARDED, so a file saying "1 and 3 must never meet"
  # produced a complete, perfectly legal-looking round that seated 1
  # against 3. That is precisely the failure `parse_xxp/2` exists to
  # prevent, in a different spelling, and it was verified happening before
  # this was written.
  defp parse_260(acc, line) do
    if byte_size(line) < 18 do
      raise ValidationError, message: "260 line is too short to hold a round range: #{line}"
    end

    first = positive_field!(line, {5, 7}, line, "260", "first round number")
    last = positive_field!(line, {9, 11}, line, "260", "last round number")

    ids = read_260_ids(line, 13, [])

    if length(ids) < 2 do
      acc
    else
      update_in(
        acc.tournament[:forbidden_pairs],
        &((&1 || []) ++ [{ids, first, last}])
      )
    end
  end

  # `240` - TRF26's bye record: a bye granted before a round is paired. For
  # a round already in the `001` lines it duplicates the column and has to
  # agree with it. For the round about to be paired it is the ONLY place
  # the bye can be, and `attach_byes/2` turns it into the `0000 - H` column
  # the engine reads (`Ainalrami.Pairing`'s `active_this_round?/2`). For a
  # round further ahead it stays in `tournament[:byes]`, because the game
  # list cannot hold a gap. Type at column 5, round in 7-9, starting ranks
  # from 11 in four-character fields every five columns.
  defp parse_240(acc, line) do
    type = line |> read({5, 5}) |> String.upcase()

    unless type in ~w(F H Z) do
      raise ValidationError, message: "240 line has an unknown bye type #{inspect(type)}: #{line}"
    end

    round = positive_field!(line, {7, 9}, line, "240", "round number")
    ranks = read_id_fields(line, 11)

    if ranks == [] do
      raise ValidationError, message: "240 line names nobody: #{line}"
    end

    update_in(acc.byes, &(&1 ++ [%{type: type, round: round, ranks: ranks}]))
  end

  # `299` - TRF26's abnormal point assignments. Three shapes, of which this
  # reader takes two:
  #
  #   * typed, with no round and no players - "every forfeit win is worth
  #     0.5" - sets the point system: `+` `forfeit_win`, `F`
  #     `full_point_bye`, `H` `half_point_bye`, `Z` `zero_point_bye`, `-`
  #     `forfeit_loss`. `W`/`D`/`L` are team match points (record `362`)
  #     with no individual meaning, and are kept rather than applied;
  #   * untyped - free points, a bonus or a penalty - is kept in
  #     `tournament[:free_points]`. The `001` total already includes it,
  #     and the total is what the engine reconciles against;
  #   * typed and limited to a round or to named players is refused. It
  #     would change what one game is worth for one player, which the point
  #     system cannot express, and a rule read and dropped is the failure
  #     this module exists to prevent.
  defp parse_299(acc, line) do
    type = line |> read({5, 5}) |> String.upcase()
    match_points = line |> read({8, 11}) |> parse_float()
    points = line |> read({14, 17}) |> parse_float()
    round = line |> read({20, 22}) |> parse_int()
    ranks = read_id_fields(line, 24)
    scoped? = (round || 0) > 0 or ranks != []

    record = %{type: type, match_points: match_points, points: points, round: round, ranks: ranks}

    cond do
      type == "" ->
        update_in(acc.tournament[:free_points], &((&1 || []) ++ [record]))

      type not in ~w(W D L F H Z + -) ->
        raise ValidationError,
          message: "299 line has an unknown assignment type #{inspect(type)}: #{line}"

      scoped? ->
        raise ValidationError,
          message: "299 line limited to a round or to named players is not supported: #{line}"

      is_nil(points) ->
        raise ValidationError, message: "299 line has no point value: #{line}"

      type in ~w(W D L) ->
        update_in(acc.tournament[:abnormal_match_points], &((&1 || []) ++ [record]))

      true ->
        field =
          %{
            "+" => :forfeit_win,
            "F" => :full_point_bye,
            "H" => :half_point_bye,
            "Z" => :zero_point_bye,
            "-" => :forfeit_loss
          }[type]

        put_point(acc, field, points)
    end
  end

  # Starting ranks in four-character fields every five columns from
  # `start`, as `240` and `299` lay them out; a blank or zero field ends
  # the list (`299` spells "everybody" as `000`).
  defp read_id_fields(line, start) do
    Stream.iterate(start, &(&1 + 5))
    |> Enum.reduce_while([], fn col, acc ->
      case read(line, {col, col + 3}) do
        "" ->
          {:halt, acc}

        field ->
          case Integer.parse(field) do
            {0, ""} ->
              {:halt, acc}

            {id, ""} when id > 0 ->
              {:cont, acc ++ [id]}

            _ ->
              raise ValidationError,
                message: "unreadable starting rank #{inspect(field)} at column #{col}: #{line}"
          end
      end
    end)
  end

  # `XXZ r1 r2 ...` - JaVaFo's extension, and what Swar writes: the players
  # absent for the round about to be paired. Not paired, no bye, nothing -
  # exactly a `0000 - Z` in that round's column, which is what
  # `attach_absences/2` turns it into once every `001` line is read. Until
  # 0.44.1 it fell through `parse_header_line/3` as an unknown code and the
  # absentees were paired anyway, with a straight face. Several lines add
  # up; a rank named twice is still one absence. A token that is not a
  # starting rank raises for `parse_xxp/2`'s reason: a list read wrong
  # pairs someone who is not there.
  defp parse_xxz(acc, line) do
    ranks =
      line
      |> String.slice(3..-1//1)
      |> String.split([" ", "	"], trim: true)
      |> Enum.map(fn token ->
        case strict_int(token) do
          rank when is_integer(rank) and rank > 0 ->
            rank

          _ ->
            raise ValidationError,
              message: "XXZ line names #{inspect(token)}, which is not a starting rank: #{line}"
        end
      end)

    Map.update(acc, :xxz, ranks, &(&1 ++ ranks))
  end

  # `XXZ`, applied once every player is read - see `parse_xxz/2`. The
  # round is the one about to be paired, `played + 1`. A player whose line
  # stops short of it (a late entrant) is padded with the blank rounds the
  # file left off, as `apply_bye/5` pads for a `240`. A `0000 - Z` already
  # in that column says the same thing twice and is let through; anything
  # else there - a game, a bye with points - is a contradiction, and which
  # half of the file to believe is not this function's call.
  defp attach_absences(result, played) do
    case Map.pop(result, :xxz) do
      {nil, result} ->
        result

      {ranks, result} ->
        absent = ranks |> Enum.uniq() |> MapSet.new()
        known = MapSet.new(result.players, & &1[:rank])

        case Enum.find(ranks, &(not MapSet.member?(known, &1))) do
          nil ->
            :ok

          rank ->
            raise ValidationError,
              message: "XXZ names starting rank #{rank}, which no 001 line has"
        end

        system = result.tournament[:point_system] || default_point_system()

        players =
          Enum.map(result.players, fn player ->
            if MapSet.member?(absent, player[:rank]),
              do: mark_absent(player, played, system),
              else: player
          end)

        %{result | players: players}
    end
  end

  defp mark_absent(player, played, system) do
    games = player[:games] || []

    case Enum.at(games, played) do
      nil ->
        blank = %{opponent_rank: nil, colour: nil, result: nil}
        padding = List.duplicate(blank, played - length(games))
        absence = %{opponent_rank: nil, colour: nil, result: "Z"}

        # Credited as the column would have been: nothing, under any point
        # system that leaves a zero-point bye at zero.
        player
        |> Map.put(:games, games ++ padding ++ [absence])
        |> Map.update(:points, 0.0, &((&1 || 0.0) + points_for("Z", system)))

      %{opponent_rank: nil, result: result} when is_binary(result) ->
        if String.upcase(String.trim(result)) == "Z" do
          player
        else
          xxz_conflict!(player, played, result)
        end

      game ->
        xxz_conflict!(player, played, game[:result])
    end
  end

  defp xxz_conflict!(player, played, result) do
    raise ValidationError,
      message:
        "XXZ says starting rank #{player[:rank]} is absent from round #{played + 1}, " <>
          "but its 001 line already has #{inspect(result)} in that round"
  end

  # `240` records, applied once every player is read - see `parse_240/2`.
  defp attach_byes(%{byes: []} = result, _played), do: Map.delete(result, :byes)

  defp attach_byes(%{byes: byes, players: players} = result, played) do
    system = result.tournament[:point_system] || default_point_system()

    by_rank =
      Enum.reduce(byes, Map.new(players, &{&1[:rank], &1}), fn bye, by_rank ->
        Enum.reduce(bye.ranks, by_rank, fn rank, by_rank ->
          case Map.fetch(by_rank, rank) do
            {:ok, player} ->
              Map.put(by_rank, rank, apply_bye(player, bye.type, bye.round, played, system))

            :error ->
              raise ValidationError,
                message: "240 line names starting rank #{rank}, which no 001 line has"
          end
        end)
      end)

    result
    |> Map.put(:players, Enum.map(players, &Map.fetch!(by_rank, &1[:rank])))
    |> Map.delete(:byes)
    |> put_in([:tournament, :byes], byes)
  end

  defp apply_bye(player, type, round, played, system) do
    games = player[:games] || []

    cond do
      # The round about to be paired, and nothing in the column yet: this
      # is the bye, as the engine reads it. A short line (a late entrant)
      # is padded with the blank rounds the file left off.
      round == played + 1 and length(games) <= played ->
        blank = %{opponent_rank: nil, colour: nil, result: nil}
        padding = List.duplicate(blank, played - length(games))
        bye = %{opponent_rank: nil, colour: nil, result: type}

        # Credited now, as the engines' files credit a pre-recorded bye -
        # the exact reverse of what the writer took off.
        player
        |> Map.put(:games, games ++ padding ++ [bye])
        |> Map.update(:points, 0.0, &((&1 || 0.0) + points_for(type, system)))

      # Already in the `001` line: it has to say the same thing. A blank
      # column is a zero-point bye by the spec's own words.
      round <= played + 1 ->
        recorded =
          case Enum.at(games, round - 1) do
            nil -> "Z"
            %{opponent_rank: nil, result: nil} -> "Z"
            %{opponent_rank: nil, result: ""} -> "Z"
            %{opponent_rank: nil, result: result} when is_binary(result) -> String.upcase(result)
            _game -> :played
          end

        if recorded == type do
          player
        else
          raise ValidationError,
            message:
              "240 line gives starting rank #{player[:rank]} a #{type} bye in round #{round}, " <>
                "which its 001 line contradicts"
        end

      # Further ahead than the game list can reach: kept in
      # `tournament[:byes]` only.
      true ->
        player
    end
  end

  # Round numbers in the file are 1-based, and `readRoundIndex`
  # (`trf.cpp:113-140`) rejects a round index of 0 outright before
  # converting to its own 0-based form. This keeps the 1-based value, since
  # that is what the engine compares against the round being paired.
  # Shared by `parse_250/2` and `parse_260/2`, so the line code and the
  # field's meaning are PARAMETERS: the message used to say "260 line has
  # an unreadable round number" for a `250` line's player range, sending a
  # reader to the wrong line looking for the wrong field. Sweep
  # 2026-09-01, L3.
  defp positive_field!(line, cols, whole, code, field) do
    case line |> read(cols) |> Integer.parse() do
      {value, ""} when value > 0 ->
        value

      _ ->
        raise ValidationError,
          message: "#{code} line has an unreadable #{field} in columns #{inspect(cols)}: #{whole}"
    end
  end

  # Ids sit in four-character fields every five columns from 13. The loop
  # takes a field only when all four characters are present, matching
  # bbpPairings' `startIndex <= line.size() - 4` condition; a trailing
  # partial field is not silently swallowed but caught below.
  # `byte_size`, not `String.length`: a TRF column is a byte here
  # (`read/2` takes `binary_part`, `place/4` pads to bytes), so measuring
  # the line in graphemes was both the wrong number on any line carrying
  # an accent AND a full walk of the line per field - quadratic on a long
  # one. Measured on `132`/`013`: 267 ms at 50 KB, 1,057 ms at 100 KB, so
  # a single 5 MB line was some forty-five minutes of walking. That is the
  # "two-line file hangs the parser" case.
  defp read_260_ids(line, start, acc) do
    if start + 3 <= byte_size(line) do
      case line |> read({start, start + 3}) |> Integer.parse() do
        {id, ""} ->
          read_260_ids(line, start + 5, [id | acc])

        _ ->
          if line |> String.slice((start - 1)..-1//1) |> String.trim() == "" do
            Enum.reverse(acc)
          else
            raise ValidationError,
              message: "260 line has an unreadable starting rank at column #{start}: #{line}"
          end
      end
    else
      Enum.reverse(acc)
    end
  end

  # `XXA` - per-player acceleration ("virtual points", FIDE C.04.7 Baku
  # Acceleration and anything else an arbiter chooses to hand out), one
  # value per round from round 1. Fixed-column; see `@xxa_rank_cols`.
  #
  # A port of `readPlayerAccelerationsXxa` (`trf.cpp:487-514`). Its loop
  # condition is `startIndex + 4 <= line.size()`, so a round's slot counts
  # only when all four of its characters are actually present, and a slot
  # that is present but blank reads as zero rather than ending the line.
  #
  # An unreadable rank or value RAISES, for the reason `parse_xxp/2` gives:
  # silently discarding it changes which bracket a player is paired in and
  # produces a wrong answer that looks entirely well-formed. It is also
  # the concrete way a caller finds out its `XXA` columns are wrong, which
  # is not hypothetical - the sibling project's own emitter is one column
  # wide at every field, and bbpPairings rejects those lines outright
  # (`Invalid line "XXA     1  1.0 ..."`, exit 3, reproduced directly).
  # Reading the rank out of columns 5-8 of such a line finds four blanks,
  # so this raises where a tolerant parser would have quietly paired an
  # unaccelerated tournament and said nothing.
  defp parse_xxa(acc, line) do
    rank =
      parse_int(read(line, @xxa_rank_cols)) ||
        raise ValidationError,
          message:
            "XXA line has no starting rank in columns 5-8 (see Ainalrami.Trf's " <>
              "@xxa_rank_cols for the fixed-column layout): #{inspect(line)}"

    # APPENDS rather than replaces, matching `push_back` onto a player's
    # existing `accelerations` (`trf.cpp:510`) - `tournament.players[id]`
    # persists between lines, so two `XXA` lines for one player continue
    # the same record rather than the second one winning.
    update_in(acc.accelerations[rank], &((&1 || []) ++ parse_xxa_points(line)))
  end

  defp parse_xxa_points(line) do
    # Trimmed first, and measured in bytes, exactly as `parse_games/1`
    # does it: five trailing spaces on an `XXA` line used to buy a phantom
    # round of 0.0 acceleration, and a trailing tab or stray character a
    # `ValidationError` blaming a round that is not in the file. Sweep
    # 2026-09-01, L1.
    length = line |> String.trim_trailing() |> byte_size()
    {_round1_start, round1_end} = xxa_points_cols(1)

    round_count =
      if length < round1_end do
        0
      else
        div(length - round1_end, 5) + 1
      end

    Enum.map(1..round_count//1, fn round ->
      case read(line, xxa_points_cols(round)) do
        "" ->
          0.0

        field ->
          parse_float(field) ||
            raise ValidationError,
              message:
                "XXA line, round #{round}: #{inspect(field)} is not a virtual-point " <>
                  "value: #{inspect(line)}"
      end
    end)
  end

  # TRF16 addresses its fields by COLUMN, and a column is a BYTE: the
  # format predates Unicode, the specification's own layouts are counted in
  # characters of a single-byte encoding, and every implementation whose
  # files this one has to read - Swiss-Manager, bbpPairings, JaVaFo - pads
  # and indexes by byte. This used to be `String.slice/3`, which counts
  # graphemes, and the two agree only for ASCII: a byte-padded row carrying
  # "Hendricks, Björn" (16 graphemes, 17 bytes) read its rating 2200 as
  # 200, its federation "GER" as "ER" and its whole round history as blank.
  # One accented letter in one name was enough.
  #
  # A short line yields whatever part of the field is there (possibly ""),
  # which is what `parse_games/1`'s completeness rule and every
  # `parse_int/1 || default` above already expect. A field that starts or
  # ends mid-codepoint - only reachable from a file some other writer
  # mis-padded - comes back as the raw bytes; `String.trim/1` leaves an
  # invalid binary alone rather than raising, and the numeric fields it
  # could land in fail their `Integer.parse/1` the same way any other
  # garbage would.
  defp read(line, {start_col, end_col}) do
    size = byte_size(line)
    start = start_col - 1

    if start >= size do
      ""
    else
      line |> binary_part(start, min(end_col - start, size - start)) |> String.trim()
    end
  end

  defp parse_header_line(acc, code, line) do
    field = Enum.find_value(@header_codes, fn {f, c} -> if c == code, do: f end)
    value = line |> String.slice(4..-1//1) |> String.trim()

    case field do
      # An `XX` code nobody here reads is still accepted - JaVaFo and Swar
      # have more of them than this engine has opinions - but no longer in
      # silence: `XXZ` spent a year in this clause, pairing absentees, and
      # nobody could tell. Whatever the next one means, the arbiter gets to
      # see that it meant nothing here.
      nil ->
        if String.starts_with?(code, "XX") do
          Ainalrami.Log.warn("ignored a TRF extension line this engine does not read: #{line}")
        end

        acc

      :round_dates ->
        acc

      :initial_colour ->
        case String.downcase(value) do
          "w" -> put_in(acc.tournament[:initial_colour], "w")
          "b" -> put_in(acc.tournament[:initial_colour], "b")
          _ -> acc
        end

      :deputy_arbiter ->
        update_in(acc.tournament.deputy_arbiters, &(&1 ++ [value]))

      f when f in [:start_date, :end_date] ->
        put_in(acc.tournament[f], String.replace(value, "/", "-"))

      # An unparsable value is NO ASSERTION, the same rule `parse_xxr/2`
      # already applies to its own spelling of this field: `|| 0` turned a
      # blank `142` into a claim that the tournament has zero rounds -
      # silently on its own, and as a false "two different round counts (9
      # and 0)" beside an `XXR 9`. `142` and `XXR` are the same field and
      # have to fail the same way. Sweep 2026-09-01, M4.
      :number_of_rounds ->
        case parse_int(value) do
          nil ->
            acc

          rounds ->
            check_round_count_agreement!(acc.tournament[:number_of_rounds], rounds)
            put_in(acc.tournament[:number_of_rounds], rounds)
        end

      f
      when f in [
             :number_of_players,
             :number_of_rated_players,
             :number_of_teams
           ] ->
        put_in(acc.tournament[f], parse_int(value) || 0)

      # TRF26's `202`/`212`: comma-separated tie-break codes. `212` is the
      # standings order and may lead with `PTS`; without a `202` of its
      # own, the codes after `PTS` are the tie-breaks.
      f when f in [:tie_breaks, :standings_order] ->
        codes = value |> String.split(~r/[,\s]+/, trim: true) |> Enum.map(&String.upcase/1)
        acc = put_in(acc.tournament[f], codes)

        if f == :standings_order and is_nil(acc.tournament[:tie_breaks]) do
          put_in(acc.tournament[:tie_breaks], Enum.reject(codes, &(&1 == "PTS")))
        else
          acc
        end

      f ->
        put_in(acc.tournament[f], value)
    end
  end

  defp parse_player_line(line) do
    %{
      rank: parse_int(read(line, @player_cols.starting_rank)),
      sex: line |> read(@player_cols.sex) |> String.downcase(),
      title: read(line, @player_cols.title),
      name: read(line, @player_cols.name),
      fide_rating: parse_int(read(line, @player_cols.fide_rating)) || 0,
      federation: read(line, @player_cols.federation),
      fide_number: parse_int(read(line, @player_cols.fide_number)),
      birth_date: line |> read(@player_cols.birth_date) |> iso_date(),
      points: parse_float(read(line, @player_cols.points)) || 0.0,
      final_rank: parse_int(read(line, @player_cols.rank)),
      games: parse_games(line)
    }
  end

  # Stops on where the line's real content actually ends, not on the first
  # blank round - a fully-blank round block (FIDE's own "not paired", see
  # Annexure-B, the 2006 TRF06 spec) is a real, legal "no game recorded this
  # round" for a late entrant, and can legitimately be followed by real
  # games in later rounds. Stopping at the first one silently drops every
  # game after it.
  #
  # A round counts only if its WHOLE block is on the line - opponent id,
  # colour and result, columns 92-99 for round one and every ten columns
  # after. Counting from the block's first column instead let a line
  # truncated inside the opponent field contribute a round anyway, and
  # `read/2` on a short line returned the digits that were there: opponent
  # 2034 cut at column 93 read as 20, cut at 92 as 2. Either is a
  # different real player, or a dangling reference `validate_games!/2`
  # documents as not an error - a wrong pairing history from a wrong file,
  # with nothing to say so.
  #
  # A partial TRAILING block is IGNORED rather than fatal, matching
  # bbpPairings' reader, whose loop condition (`startIndex <= line.size() -
  # 8u`, cited by `render/1` above) simply stops. The last round of a
  # hand-edited file is exactly where a line loses its tail, and the rounds
  # before it are still perfectly readable.
  # Measured on the line AS WRITTEN, not on a trimmed copy. `serialize/1`
  # pads a 001 line out to the last round's result column on purpose
  # (`pad_to_last_round/2`) so that a round already paired but not yet
  # played is a WHOLE block - without the pad bbpPairings refuses the file.
  # Trimming here deleted exactly that pad, so the block measured short and
  # the round was dropped: serialize a paired round, read it back, and the
  # round was simply gone. A caller that writes a round's pairings to a TRF
  # and parses them again - which is how the sibling app talks to this
  # engine - then believes the round is still open and PAIRS IT A SECOND
  # TIME, quietly producing different boards for a round already published.
  #
  # bbpPairings does not trim either: its loop condition is
  # `startIndex <= line.size() - 8u` on the real line.
  #
  # Trailing blocks that are entirely empty are dropped afterwards instead,
  # which keeps the promise the note above makes - a hand-edited file whose
  # tail is ragged loses nothing readable - while a padded paired round,
  # which always carries an opponent or a result, survives.
  defp parse_games(line) do
    length = byte_size(line)
    {_, round1_end} = round_cols(1).result

    round_count =
      if length < round1_end do
        0
      else
        div(length - round1_end, 10) + 1
      end

    1..round_count//1
    |> Enum.map(&parse_game_at_round(line, &1))
    |> Enum.reverse()
    |> Enum.drop_while(&empty_game?/1)
    |> Enum.reverse()
  end

  defp empty_game?(%{opponent_rank: nil, colour: nil, result: nil}), do: true
  defp empty_game?(_), do: false

  # The result column comes back exactly as the file spells it, letters
  # included. This used to rewrite `W`, `D` and `L` into `1`, `=` and `0` on
  # the way in, which is the one thing a reader of this format must not do:
  # the letters ARE the symbols, played and scored identically, differing
  # only in that the game does not reach the rating report (typically one
  # that ended before the minimum number of moves). That single bit is what
  # TRF16 spells them for, and rewriting them threw it away with nothing
  # left to recover it from.
  #
  # Nothing downstream needed the rewrite. Every point where this repo
  # consumes a result already reads the letters, and reads them because
  # bbpPairings does: `points_for/2` scores them through `~w(1 + F W)` /
  # `~w(= H D)` / `~w(0 L)` (`trf.cpp:252-270`), `game_was_played?/1` calls
  # them played (`trf.cpp:278-286`), and `@playing_codes` /
  # `@legal_result_pairs` validate them. The rewrite outlived all three.
  #
  # For the sibling app it was not cosmetic. `PairingsEngine.TrfImport`
  # turns a mutual pair of codes into a stored result, and its `W` ->
  # `1-0U`, `L`/`W` -> `0-1U` and `D`/`D` -> `1/2-1/2U` clauses can only be
  # reached while the letter survives the parse. Under the rewrite they were
  # dead code and every imported unrated game was stored as a rated one -
  # the same drift that module's own `@playing_codes` copy had already
  # suffered once, and the reason `Trf.playing_codes/0` is public there.
  #
  # A blank column still becomes `nil`. "No result recorded yet" is a
  # different question from which result, and every caller asks it that way.
  defp parse_game_at_round(line, round) do
    cols = round_cols(round)
    id_raw = read(line, cols.id)
    colour = read(line, cols.colour)
    result = read(line, cols.result)

    %{
      opponent_rank: if(id_raw in ["", "0000"], do: nil, else: parse_int(id_raw)),
      colour: if(colour in ["", "-"], do: nil, else: colour),
      result: if(result == "", do: nil, else: result)
    }
  end

  defp parse_team_line(line, slot \\ 1, ranks \\ []) do
    cols = team_player_cols(slot)
    {start, _} = cols

    cond do
      byte_size(line) < start ->
        %{name: read(line, @team_cols.name), player_ranks: Enum.reverse(ranks)}

      read(line, cols) == "" ->
        %{name: read(line, @team_cols.name), player_ranks: Enum.reverse(ranks)}

      true ->
        parse_team_line(line, slot + 1, [parse_int(read(line, cols)) | ranks])
    end
  end

  # ---- TRF26 team records (layouts in parse/1's doc) ----------------------

  defp team_310_player_cols(slot) do
    base = 74 + (slot - 1) * 5
    {base, base + 3}
  end

  defp parse_310(line) do
    ranks =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&team_310_player_cols/1)
      |> Enum.take_while(fn {start, _} = cols ->
        byte_size(line) >= start and read(line, cols) != ""
      end)
      |> Enum.map(&parse_int(read(line, &1)))

    %{
      number: parse_int(read(line, {5, 7})),
      name: read(line, {9, 40}),
      nickname: read(line, {42, 46}),
      strength: parse_int(read(line, {48, 53})),
      match_points: parse_float(read(line, {55, 60})),
      game_points: parse_float(read(line, {62, 67})),
      final_rank: parse_int(read(line, {69, 71})),
      player_ranks: ranks
    }
  end

  defp parse_362(line) do
    Stream.iterate(6, &(&1 + 9))
    |> Enum.take_while(&(byte_size(line) >= &1))
    |> Enum.reduce(%{}, fn col, acc ->
      symbol = line |> read({col, col}) |> String.upcase()

      # `Z` is read as `A` (a match lost by forfeit), which is how some
      # writers spell it; `serialize/2` always writes `A`.
      symbol = if symbol == "Z", do: "A", else: symbol

      case List.keyfind(@team_symbols, symbol, 0) do
        {_, key} ->
          case parse_float(read(line, {col + 1, col + 4})) do
            nil -> acc
            points -> Map.put(acc, key, points)
          end

        nil ->
          acc
      end
    end)
  end

  defp parse_320(line) do
    teams =
      Stream.iterate(15, &(&1 + 4))
      |> Enum.take_while(&(byte_size(line) >= &1))
      |> Enum.map(&(parse_int(read(line, {&1, &1 + 2})) || 0))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()

    %{
      match_points: parse_float(read(line, {5, 8})),
      game_points: parse_float(read(line, {10, 13})),
      teams: teams
    }
  end

  # TRF26 `300`, a team's board order for one match ("out of order"): the
  # round in 5-7, the team in 9-11, its opponent in 13-15, then its players'
  # starting ranks in board order, four columns from 17 every 5, `0` (or
  # blank) for an empty board - TieBreakServer's `parse_trf_outoforder`.
  defp parse_300(line) do
    order =
      Stream.iterate(17, &(&1 + 5))
      |> Enum.take_while(&(byte_size(line) >= &1))
      |> Enum.map(&(parse_int(read(line, {&1, &1 + 3})) || 0))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()

    %{
      round: parse_int(read(line, {5, 7})),
      team: parse_int(read(line, {9, 11})),
      opponent: parse_int(read(line, {13, 15})),
      order: order
    }
  end

  defp parse_330(line) do
    %{
      type: read(line, {5, 6}),
      round: parse_int(read(line, {8, 10})),
      white: parse_int(read(line, {12, 14})),
      black: parse_int(read(line, {16, 18}))
    }
  end

  defp parse_round_dates(line, round \\ 1, acc \\ []) do
    cols = round_date_cols(round)
    {start, _} = cols

    if byte_size(line) < start or read(line, cols) == "" do
      Enum.reverse(acc)
    else
      date =
        case String.split(read(line, cols), "/") do
          [y, m, d] when byte_size(y) == 2 -> "20#{y}-#{m}-#{d}"
          [y, m, d] -> "#{y}-#{m}-#{d}"
          _ -> nil
        end

      parse_round_dates(line, round + 1, [date | acc])
    end
  end

  defp iso_date(""), do: ""
  defp iso_date("0000" <> _), do: ""
  defp iso_date(slash), do: String.replace(slash, "/", "-")

  defp parse_int(""), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  # `parse_int/1` with the leftovers taken seriously. Fixed-column reads can
  # afford to ignore a remainder - the column boundary already said where
  # the number ends - but a whitespace-split token has no such boundary, so
  # anything after the digits means the token was not a number at all. See
  # `parse_xxp/2`.
  defp strict_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_float(""), do: nil

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
end

defmodule Ainalrami.TeamPairing.Team do
  @moduledoc """
  A team as C.04.6 sees it, plus the derived quantities Articles 1.6 and 1.7
  define on top.

  The regulation text this implements is kept verbatim in
  `docs/c0406-regulation-text.md`; the reading decisions are in
  `docs/conformance-c0406-teams.md`. Article numbers below cite that text.

  ## What is deliberately NOT here

  **Board order.** The regulation never says how a team orders its own
  boards, nor whether that order may change between rounds - Article 0 says
  outright that individuals "can be substituted or shifted between the
  various boards". It is left to each competition, so it is the host
  application's to store and the arbiter's to set. An engine that derived it
  would be inventing a rule FIDE declined to write.

  **Player ratings, names, federations.** Article 0 also removes the
  individual system's initial-order rules (General Handling 2.1-2.3) because
  "there are too many variants to take into account to define an appropriate
  strength for teams". The TPN arrives already assigned (1.1.2: by the
  competition's rules, else the Chief Arbiter). This engine never computes a
  seeding.

  ## Fields

    * `:tpn` - Tournament Pairing Number, 1..N, unique (1.1.1).
    * `:match_points` / `:game_points` - both are needed. Which one is the
      *primary* score is a competition setting (1.2.1), the default is match
      points (1.2.2), and the other is used for colour allocation (4.2.2).
      A team model carrying one number cannot express 4.2, and the PAB pays
      in both (1.4).
    * `:opponents` - TPNs already played, for [C1]. A list, not a MapSet, so
      "who did we play in round 3" stays answerable; membership tests go
      through `met?/2`.
    * `:colours` - colours of matches ACTUALLY PLAYED, oldest first
      (1.6.1). A match with no colour is not a played match, so byes and
      unplayed matches are simply absent rather than recorded as `nil` - the
      list length is the played-match count.
    * `:had_pab?` - has already received a pairing-allocated bye, and so may
      not receive another ([C2], 2.1.2).
    * `:won_by_forfeit?` - won a match by forfeit, or was given a
      FIDE-deprecated full-point bye. [C2] bars these from the PAB on the
      same footing as a previous PAB, which is why they are one condition
      (`pab_ineligible?/1`) rather than three checks at the call site.
      **Open question 6** - what "won a match by forfeit" means - is the
      host's to answer, because only the host knows how a match was
      recorded; this engine takes the boolean. The reading OpenPairings
      implements, and the one this project proposes: the opponent did not
      turn up as a team, i.e. every board it should have filled was
      forfeited. A match with at least one board actually played is not a
      forfeit win, however many other boards were. The research note of
      2026-09-13 (docs/conformance-c0406-teams.md, "Research findings")
      supports it at high confidence: the 2024 [C2] said "without playing";
      Double-Swiss C.04.5, which shares the 2026 wording, defines a
      forfeited match as one where a side forfeited every game; TRF-2026's
      record 330 is "one or both teams didn't show up". Whether a match
      forfeited "by decision" after games were played counts is left open
      (medium confidence that it does not).
      Since 2026-11-11 a match where BOTH teams scored on a board by
      forfeit counts as played even with no game over the board (both
      turned up, each was short somewhere): a colour, a meeting, and no
      forfeit win for either side.
    * `:floated_last_round?` - was a floater (1.5: played an opponent with a
      different score) in the previous round. Only a PLAYED match makes a
      floater; a forfeited one does not, and a bye never did (2026-11-11). Read by [C7] and [C10], both
      of which stop applying in the last two rounds.
    * `:matches_played` - for the bye tie-break 3.4.3. Defaults to
      `length(colours)`; settable because a competition may count a
      forfeited match as played when this engine cannot know that.
  """

  defstruct tpn: nil,
            match_points: 0.0,
            game_points: 0.0,
            opponents: [],
            colours: [],
            had_pab?: false,
            won_by_forfeit?: false,
            floated_last_round?: false,
            matches_played: nil

  @type colour :: :white | :black
  @type preference :: {:white | :black, :strong | :mild} | :none

  @type t :: %__MODULE__{
          tpn: pos_integer() | nil,
          match_points: number(),
          game_points: number(),
          opponents: [pos_integer()],
          colours: [colour()],
          had_pab?: boolean(),
          won_by_forfeit?: boolean(),
          floated_last_round?: boolean(),
          matches_played: non_neg_integer() | nil
        }

  @doc "Whether these two teams have already met ([C1], 2.1.1)."
  def met?(%__MODULE__{} = team, tpn) when is_integer(tpn), do: tpn in team.opponents

  @doc """
  Whether [C2] (2.1.2) bars this team from the pairing-allocated bye.

  One predicate rather than three checks at the call site, because the
  article names three ways in and they are not independent options - a team
  that has had any of them is out.
  """
  def pab_ineligible?(%__MODULE__{} = team), do: team.had_pab? or team.won_by_forfeit?

  @doc "Matches actually played (1.6.1) - the 3.4.3 bye tie-break reads this."
  def matches_played(%__MODULE__{matches_played: n}) when is_integer(n), do: n
  def matches_played(%__MODULE__{colours: colours}), do: length(colours)

  @doc """
  Colour difference (1.6.2): matches with White minus matches with Black.

  Only played matches carry a colour at all (1.6.1), and `:colours` holds
  only those, so this is a straight count.
  """
  def colour_difference(%__MODULE__{colours: colours}) do
    Enum.count(colours, &(&1 == :white)) - Enum.count(colours, &(&1 == :black))
  end

  @doc """
  Colour preference under Article 1.7.

  Returns `{:white, :strong}`, `{:white, :mild}`, the Black equivalents, or
  `:none`. Type A never produces `:mild` - the strength is carried anyway so
  callers have one shape to match on, and [C9]/4.3.4 simply never fire.

  `type` is `:a` (the default, 1.7), `:b`, or `:none` - 1.7's third option,
  a competition whose rules say "colour preferences are not to be used at
  all" (TRF26's `FIDE_TEAM_MP_GP`, `FIDE_TEAM_GP`, ...). Under `:none` no
  team ever has a preference, so [C8] and [C9] count nothing and Article
  4.3's preference rules (4.3.2-4.3.4, 4.3.7) never fire; the rules that do
  not mention a preference - 4.3.1, 4.3.5, 4.3.6, 4.3.8, 4.3.9 - still
  allocate the colours. `last_round?` matters only to Type B, whose mild
  preferences switch off when pairing the final round.

  ## The two types are not two rules

  Type B's STRONG conditions are word-for-word Type A's conditions. Type B
  adds mild preferences underneath them. So `preference/3` computes the
  shared condition once and Type B only asks the extra question when the
  shared one says nothing - which also makes it structurally impossible for
  the two to disagree about the strong case, a drift this codebase has been
  bitten by elsewhere.
  """
  def preference(team, type \\ :a, last_round? \\ false)

  # 1.7: "... or colour preferences are not to be used at all".
  def preference(%__MODULE__{}, :none, _last_round?), do: :none

  def preference(%__MODULE__{} = team, type, last_round?) do
    case strong_preference(team) do
      :none when type == :b -> mild_preference(team, last_round?)
      :none -> :none
      colour -> {colour, :strong}
    end
  end

  # 1.7.1 / the strong half of 1.7.2, which are the same sentence twice:
  #
  #   White if CD < -1, or - CD being 0 or -1 - the team had Black in the
  #   last two played matches. Black is the mirror.
  #
  # "the last two played matches" needs two of them; a team with fewer has
  # not had Black in two matches, so the clause cannot fire. That is why
  # `last_two/1` returns nil rather than padding.
  defp strong_preference(team) do
    cd = colour_difference(team)
    last_two = last_two(team)

    cond do
      cd < -1 -> :white
      cd > 1 -> :black
      cd in [0, -1] and last_two == [:black, :black] -> :white
      cd in [0, 1] and last_two == [:white, :white] -> :black
      true -> :none
    end
  end

  # The mild half of 1.7.2, Type B only:
  #
  #   White if CD is -1, or - CD being zero and it not being the last round -
  #   the team had Black in the last played match. Black is the mirror.
  #
  # And explicitly none when the team has yet to play, or when CD is zero and
  # this IS the last round. Both fall out: no matches means no last colour,
  # and the CD-zero clauses are guarded on `not last_round?`.
  defp mild_preference(team, last_round?) do
    cd = colour_difference(team)
    last = List.last(team.colours)

    cond do
      cd == -1 -> {:white, :mild}
      cd == 1 -> {:black, :mild}
      cd == 0 and not last_round? and last == :black -> {:white, :mild}
      cd == 0 and not last_round? and last == :white -> {:black, :mild}
      true -> :none
    end
  end

  defp last_two(%__MODULE__{colours: colours}) do
    case Enum.reverse(colours) do
      [a, b | _] -> [a, b]
      _ -> nil
    end
  end

  @doc """
  The colour a preference asks for, or `nil` for `:none`.

  Flattens `{colour, strength}` for the callers that only care which side.
  """
  def preferred_colour(:none), do: nil
  def preferred_colour({colour, _strength}), do: colour

  @doc "Whether a preference is strong. `:none` is not strong."
  def strong?(:none), do: false
  def strong?({_colour, strength}), do: strength == :strong

  @doc """
  This team's primary score under `mode` (1.2).

  `:match_points` (the 1.2.2 default) or `:game_points`.
  """
  def score(%__MODULE__{} = team, :match_points), do: team.match_points
  def score(%__MODULE__{} = team, :game_points), do: team.game_points
  def score(%__MODULE__{}, mode), do: raise_bad_mode(mode)

  @doc "The secondary score - the other one (1.2.1), used by 4.2.2."
  def secondary_score(%__MODULE__{} = team, :match_points), do: team.game_points
  def secondary_score(%__MODULE__{} = team, :game_points), do: team.match_points
  def secondary_score(%__MODULE__{}, mode), do: raise_bad_mode(mode)

  # 1.2.1 defines exactly two scores, so a third mode is a caller's mistake
  # and not a case to add. What it was NOT is a FunctionClauseError naming
  # `Ainalrami.TeamPairing.Team.score/2` and printing the whole team struct,
  # which is what a host application driving this module directly used to
  # get - the one thing it did not say was which atom it had passed.
  defp raise_bad_mode(mode) do
    raise ArgumentError,
          "unknown score mode #{inspect(mode)} - Article 1.2.1 defines only " <>
            ":match_points and :game_points"
  end
end

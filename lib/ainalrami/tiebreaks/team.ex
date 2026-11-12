defmodule Ainalrami.Tiebreaks.Team do
  @moduledoc """
  C.07's team tie-breaks (Articles 11-13), and every individual tie-break
  applied to teams through match points or game points.

      event = Team.new(teams, 9, boards: 4)
      {:ok, standings} = Team.rank(event, ~w(GPTS EMGSB/C1 BH:MP EDEBT))

  ## Two views of one event

  A team's round has match points and game points. `view/2` turns the event
  into an ordinary `Ainalrami.Tiebreaks.Event` scored in one of them - teams
  as participants, the round's points the match points (or game points)
  taken - so every individual tie-break works for teams (`BH:MP`, `SB:GP`,
  `PS`, `KS:GP` ...), Article 16 included: C.07 applies it to "Individual or
  Team Swiss tournaments", with "points" meaning both. A round's outcome is
  the MATCH's in both views (reading T1 in
  docs/conformance-c07-tiebreaks.md). A code without `:MP`/`:GP` uses the
  primary score (reading T2).

  ## The team-only tie-breaks

    * `MPTS`, `GPTS`, `MPVGP` - match points, game points, the secondary
      score (11.1, 13.1)
    * `EMMSB`, `EMGSB`, `EGMSB`, `EGGSB` - extended Sonneborn-Berger (13.2),
      via `Ainalrami.Tiebreaks.Individual.extended_sonneborn/3`
    * `EDE`, `EDEBT`, `EDEBB`, `EDET`, `EDEB` - extended direct encounter
      (13.3) and its knockout follow-ups (reading T3 for which is which)
    * `BC`, `TBR`, `BBE` - board count, top board results, bottom board
      elimination (Article 12)
    * `SSSC` - scores and schedule strength (13.4)

  BC, TBR, BBE and the EDE family order a tied GROUP rather than giving
  each team a value, like direct encounter; their value in the standings is
  the position they gave within the group.

  ## Boards

  A round's `boards` maps board number to the game points the team took on
  it. Article 12 counts individual forfeits as ordinary wins and losses,
  which is what those game points already are. A pairing-allocated bye or a
  forfeited match has no boards played: a pairing-allocated bye scores a
  win on every board - "if the team received a pairing-allocated bye, the
  game points considered for each board are the same as those assigned to
  a standard win" (Article 12) - and, as FIDE's TieBreakServer counts the
  cases the text leaves open, so do a match won by forfeit and a
  full-point bye; a half-point bye scores a draw on every board, a match
  lost by forfeit and a zero-point bye nothing.
  """

  alias Ainalrami.Tiebreaks.{Code, DirectEncounter, Event, Individual}
  alias Ainalrami.Tiebreaks.Event.{Participant, Round}

  defmodule Match do
    @moduledoc """
    One team's round. `kind` is as in `Ainalrami.Tiebreaks.Event` (a
    forfeited match is `:forfeit_win`/`:forfeit_loss`); `boards` is
    `%{board_number => game points}`.
    """
    @enforce_keys [:kind]
    defstruct kind: nil, opponent: nil, mp: 0.0, gp: 0.0, boards: %{}
  end

  defmodule Entry do
    @moduledoc "One team: its id, TPN and rounds (`%{round => %Match{}}`)."
    @enforce_keys [:id]
    defstruct id: nil, tpn: nil, rounds: %{}
  end

  @enforce_keys [:rounds, :boards, :teams]
  defstruct rounds: 0,
            total_rounds: 0,
            predetermined?: false,
            boards: 0,
            primary: :mp,
            match_points: %{win: 2.0, draw: 1.0, loss: 0.0},
            game_points: %{win: 1.0, draw: 0.5, loss: 0.0},
            teams: %{}

  @doc """
  Builds a team event. Options: `:boards` (required), `:primary` (`:mp`,
  the default, or `:gp`), `:match_points` and `:game_points`
  (`%{win:, draw:, loss:}`, defaults 2/1/0 and 1/½/0), `:predetermined?`,
  `:total_rounds`. A round a team has no record for is a zero-point bye.
  """
  def new(entries, rounds, opts) do
    boards = Keyword.fetch!(opts, :boards)

    teams =
      Map.new(entries, fn %Entry{} = t ->
        filled =
          Map.new(1..rounds//1, fn r -> {r, Map.get(t.rounds, r) || %Match{kind: :zero_bye}} end)

        {t.id, %{t | rounds: filled}}
      end)

    %__MODULE__{
      rounds: rounds,
      total_rounds: max(Keyword.get(opts, :total_rounds) || rounds, rounds),
      predetermined?: Keyword.get(opts, :predetermined?, false),
      boards: boards,
      primary: Keyword.get(opts, :primary, :mp),
      match_points:
        Map.merge(%{win: 2.0, draw: 1.0, loss: 0.0}, Map.new(opts[:match_points] || %{})),
      game_points:
        Map.merge(%{win: 1.0, draw: 0.5, loss: 0.0}, Map.new(opts[:game_points] || %{})),
      teams: teams
    }
  end

  @doc """
  A team event from a parsed TRF with `013` or TRF26 `310` team records
  (`Ainalrami.Trf.parse/1`). A `310` team keeps its own number; `013`
  teams are numbered in the order of their lines, as FIDE's
  TieBreakServer numbers them.

  A team's round is read from its players' games: the opposing team is
  the team of the players they met, and the boards are those players in
  the order the `013` line lists them (a team fielding a reserve moves
  the players below up a board). A board whose opponent the other team
  could not fill - a win with no opponent (`F`, or `+`/`U` with `0000`)
  in a round the team met somebody - is one of its boards, a forfeit win
  worth its point. A round where none of a team's players met an
  opponent is a pairing-allocated bye when they were given one (`U`, or
  `+` with no opponent) or the `320` record names the team for the
  round, and a zero-point bye otherwise.

  A match is PLAYED when at least one board was played over the board, or
  when both teams scored on a board by forfeit - both turned up (TRF-2026
  `330`: a team shows up if one player is present). Otherwise every game
  was a forfeit and only one side, or neither, scored: a forfeited match,
  won by the side that scored, a double forfeit when neither did. This is
  the one place that is decided; `Ainalrami.TeamReplay` reads a match's
  colour, meeting and float from it, and `:forfeit_win` is [C2]'s "won a
  match by forfeit". A TRF26 `330`
  record forfeits a match neither team has board records for (see
  `declared_forfeit/5`), and outranks the bye the winners' `0000 +` (330
  Note 1) or `0000 F` would otherwise read as; a match with board records
  is read from them.

  Match points are the file's TRF26 `362` record (`W`/`D`/`L`; `A` for a
  match lost by forfeit) when it has one, 2/1/0 otherwise; `:match_points`
  overrides either. A pairing-allocated bye is worth the `320` record's
  match points, else `362`'s `P`, else a win, and the `320` record's game
  points, else a win on every board. A TRF26 `300` record gives a team's
  board order in one match, in place of its roster order. Options:
  `:boards` (default: the count the file's TRF26 `352` colour sequence
  states, else the most games any match had), `:primary`,
  `:match_points`, `:rounds`, `:predetermined?`.
  """
  def from_trf(%{players: players, teams: trf_teams, tournament: tournament} = trf, opts \\ []) do
    individual_opts = Keyword.take(opts, [:rounds, :predetermined?])
    individual = Event.from_trf(trf, individual_opts)

    # A round whose matches were all forfeited as a whole (`330`, no board
    # records) - or that only a `320` bye names - has no games to count it
    # by, but it is a round of the event.
    team_rounds = Ainalrami.Trf.team_rounds(tournament)

    individual =
      if is_nil(opts[:rounds]) and team_rounds > individual.rounds,
        do: Event.from_trf(trf, Keyword.put(individual_opts, :rounds, team_rounds)),
        else: individual

    system = Map.get(tournament, :point_system) || Ainalrami.Trf.default_point_system()
    game_points = %{win: system.win, draw: system.draw, loss: system.loss}

    from_file = Map.get(tournament, :team_point_system) || %{}

    match_points =
      %{win: 2.0, draw: 1.0, loss: 0.0}
      |> Map.merge(Map.take(from_file, [:win, :draw, :loss]))
      |> Map.merge(Map.new(opts[:match_points] || %{}))

    # A match lost by forfeit: `362`'s `A`, else a loss's.
    forfeit_mp = Map.get(from_file, :absent, match_points.loss)

    # A pairing-allocated bye's match points: the `320` record's, else
    # `362`'s `P`, else a win's.
    pab_mp =
      get_in(tournament, [:team_pab, :match_points]) || from_file[:pab] || match_points.win

    # TRF26 `310` numbers its teams; `013` does not, and its teams are
    # numbered in file order.
    rosters =
      trf_teams
      |> Enum.with_index(1)
      |> Map.new(fn {team, index} -> {Map.get(team, :number) || index, team.player_ranks} end)

    team_of = for {id, ranks} <- rosters, rank <- ranks, into: %{}, do: {rank, id}
    known = MapSet.new(players, & &1.rank)

    # {team, round} => [{roster position, rank, %Round{}}] for the players
    # who met somebody, in roster order.
    orders = board_orders(tournament)

    games =
      for {team, ranks} <- rosters,
          {rank, position} <- Enum.with_index(ranks),
          rank in known,
          {r, round} <- individual.participants[rank].rounds,
          reduce: %{} do
        acc ->
          position = board_position(orders, team, r, rank, position)
          Map.update(acc, {team, r}, [{position, rank, round}], &[{position, rank, round} | &1])
      end
      |> Map.new(fn {key, list} -> {key, Enum.sort(list)} end)

    # The board count: the caller's, else the file's TRF26 `352` colour
    # sequence (one letter per board), else the most games any match had.
    # The last is only an inference, and a round forfeited on every match
    # with `330` records alone has no games to count - its winners were
    # credited one board (sweep 2026-11-11).
    boards =
      Keyword.get_lazy(opts, :boards, fn ->
        board_count(tournament) || inferred_boards(games)
      end)

    pab_gp = get_in(tournament, [:team_pab, :game_points])

    points = %{
      match: match_points,
      game: game_points,
      pab: pab_mp,
      pab_gp: pab_gp,
      forfeit: forfeit_mp,
      boards: boards
    }

    forfeited =
      for f <- Map.get(tournament, :forfeited_matches) || [],
          winner <- [forfeit_winner(f[:type])],
          winner != nil,
          into: %{},
          do: {{f.round, f.white, f.black}, winner}

    pab_by_round = get_in(tournament, [:team_pab, :teams]) || []
    team_byes = team_byes(tournament, points)

    entries =
      for {team, _ranks} <- rosters do
        rounds =
          Map.new(1..individual.rounds//1, fn r ->
            match =
              Map.get(games, {team, r}, [])
              |> trf_match(team_of, points, Enum.at(pab_by_round, r - 1) == team)
              |> declared_forfeit(team, r, forfeited, points)
              |> requested_bye(Map.get(team_byes, {team, r}))

            {r, match}
          end)

        %Entry{id: team, tpn: team, rounds: rounds}
      end

    # Each match's points, now both sides are read.
    entries = with_match_points(entries, points)

    new(entries, individual.rounds,
      boards: boards,
      primary: Keyword.get(opts, :primary, :mp),
      match_points: match_points,
      game_points: game_points,
      predetermined?: individual.predetermined?,
      total_rounds: individual.total_rounds
    )
  end

  @doc """
  The number of boards a file's TRF26 `352` record states (its colour
  sequence, one letter per board), or nil without one.
  """
  def board_count(tournament) do
    case Map.get(tournament, :board_colours) do
      seq when is_binary(seq) and seq != "" -> String.length(seq)
      _ -> nil
    end
  end

  defp inferred_boards(games) do
    games
    |> Map.values()
    |> Enum.map(&length(boards_of(&1)))
    |> Enum.max(fn -> 1 end)
    |> max(1)
  end

  # `%{{team, round} => %{rank => board index}}` from the TRF26 `300`
  # records.
  defp board_orders(tournament) do
    for o <- Map.get(tournament, :board_orders) || [],
        is_integer(o[:round]) and is_integer(o[:team]),
        into: %{} do
      boards =
        for {rank, i} <- Enum.with_index(o[:order] || []),
            is_integer(rank) and rank > 0,
            into: %{},
            do: {rank, i}

      {{o.team, o.round}, boards}
    end
  end

  # A player's position among the team's boards in round `r`: the `300`
  # record's board when there is one, otherwise the roster order (after
  # every board the record names).
  defp board_position(orders, team, r, rank, position) do
    case orders do
      %{{^team, ^r} => boards} -> Map.get(boards, rank, 10_000 + position)
      _ -> position
    end
  end

  # The boards a team's players sat at in one round: every game against
  # somebody, and - when the team met somebody - every board whose opponent
  # the other team could not fill, which the file writes as a win with no
  # opponent (`F`, or `+`/`U` with `0000`): a forfeit win on that board,
  # worth its point. Without a game against anybody the round is not a
  # match and has no boards.
  defp boards_of(games) do
    if Enum.any?(games, fn {_, _, g} -> g.opponent end) do
      Enum.filter(games, fn {_, _, g} -> g.opponent || unfilled?(g) end)
    else
      []
    end
  end

  defp unfilled?(g), do: is_nil(g.opponent) and g.kind in [:full_bye, :pab]

  defp trf_match(games, team_of, points, pab_team?) do
    # A game against a player on no team's roster says nothing about which
    # team this one met - `TeamReplay.read_round/6` reads it the same way.
    # Counting it named `nil` as the opponent team, and the match points
    # then looked `nil` up as a team (sweep 2026-11, AIN-2).
    met =
      Enum.filter(games, fn {_, _, g} -> g.opponent && Map.has_key?(team_of, g.opponent) end)

    case met do
      [] ->
        # The players' `U` (or `+` with no opponent), or the team the `320`
        # record names for the round - a file may give the bye there alone.
        if pab_team? or Enum.any?(games, fn {_, _, g} -> g.kind == :pab end) do
          %Match{
            kind: :pab,
            mp: points.pab,
            gp: points.pab_gp || points.game.win * points.boards,
            boards: Map.new(1..points.boards, &{&1, points.game.win})
          }
        else
          %Match{kind: :zero_bye, mp: points.match.loss}
        end

      _ ->
        opponent =
          met
          |> Enum.frequencies_by(fn {_, _, g} -> team_of[g.opponent] end)
          |> Enum.max_by(fn {_, n} -> n end)
          |> elem(0)

        board_points =
          games
          |> boards_of()
          |> Enum.with_index(1)
          |> Map.new(fn {{_, _, g}, board} -> {board, g.points} end)

        # A match where no board was played over the board - every game a
        # forfeit - is `:unplayed` until both sides are read: played after
        # all if both scored, a forfeit otherwise (`with_match_points/2`).
        played? = Enum.any?(met, fn {_, _, g} -> g.kind == :played end)

        %Match{
          kind: if(played?, do: :played, else: :unplayed),
          opponent: opponent,
          gp: board_points |> Map.values() |> Enum.sum(),
          boards: board_points
        }
    end
  end

  # A `330` record for a match neither team has board records for: the
  # match was forfeited as a whole. The winner takes a win's match points
  # and a win on every board in game points (no boards recorded - Article
  # 12 then reads it as a win on every board, reference question Q3); the
  # loser, or both sides of a double forfeit, the forfeit's match points
  # and nothing. A match with board records is read from its boards.
  #
  # TRF-2026 330, Note 1, credits the winner's present players with
  # `0000 - +`, which on its own reads as a pairing-allocated bye; the
  # older `0000 - F` reads as a zero-point bye here. A `330` record naming
  # the team outranks either: the round is the forfeited match, not a bye.
  defp declared_forfeit(%Match{kind: kind} = m, team, r, forfeited, points)
       when kind in [:zero_bye, :pab] do
    found =
      Enum.find_value(forfeited, fn
        {{^r, ^team, other}, winner} -> {other, winner == :white}
        {{^r, other, ^team}, winner} -> {other, winner == :black}
        _ -> nil
      end)

    case found do
      nil ->
        m

      {other, true} ->
        %Match{
          kind: :forfeit_win,
          opponent: other,
          mp: points.match.win,
          gp: points.game.win * points.boards
        }

      {other, false} ->
        %Match{kind: :forfeit_loss, opponent: other, mp: points.forfeit, gp: 0.0}
    end
  end

  defp declared_forfeit(m, _team, _r, _forfeited, _points), do: m

  # A team event's requested byes, TRF26 `240` with team numbers
  # (`tournament[:team_byes]`): `%{{team, round} => %Match{}}`. Their value
  # is the `299` record's for the type when the file has one, otherwise
  # what TRF-2026's "Abnormal Assignment points" says a team does receive:
  # a half-point bye "TD MP and N*D GP" (a drawn match, a draw on every
  # board), a full-point bye "TW MP and N*W GP", a zero-point bye nothing.
  # The boards are left empty, as for a zero-point bye: Article 12's board
  # sums read the kind (`unplayed_boards/3`).
  defp team_byes(tournament, points) do
    values = Map.get(tournament, :team_bye_points) || %{}
    n = points.boards

    defaults = %{
      "H" => {:half_bye, points.match.draw, points.game.draw * n},
      "F" => {:full_bye, points.match.win, points.game.win * n},
      "Z" => {:zero_bye, points.match.loss, 0.0}
    }

    for bye <- Map.get(tournament, :team_byes) || [],
        {kind, mp, gp} = Map.fetch!(defaults, bye.type),
        team <- bye.teams,
        into: %{} do
      value = values[bye.type] || %{}

      {{team, bye.round},
       %Match{
         kind: kind,
         mp: (value[:match_points] || mp) * 1.0,
         gp: (value[:game_points] || gp) * 1.0
       }}
    end
  end

  # The requested bye replaces only a round the team was not paired in -
  # `Ainalrami.Trf.parse/1` refuses a file that pairs it as well, and a
  # caller building the data by hand gets the pairing, which happened.
  defp requested_bye(%Match{kind: :zero_bye, opponent: nil}, %Match{} = bye), do: bye
  defp requested_bye(match, _bye), do: match

  # A `330` record's result: `+-`, `-+`, `--`, or TieBreakServer's
  # spellings `10 WL WZ`, `01 LW ZW`, `00 LL ZZ`. Anything else is not a
  # forfeit this reader knows, and the record is skipped.
  defp forfeit_winner(type) do
    type = (type || "") |> String.trim() |> String.upcase()

    cond do
      type in ~w(+- 10 WL WZ) -> :white
      type in ~w(-+ 01 LW ZW) -> :black
      type in ~w(-- 00 LL ZZ) -> :none
      true -> nil
    end
  end

  defp with_match_points(entries, points) do
    by_id = Map.new(entries, &{&1.id, &1})
    match_points = points.match

    for entry <- entries do
      rounds =
        Map.new(entry.rounds, fn
          {r, %Match{kind: :played, opponent: opp} = m} ->
            theirs = by_id[opp].rounds[r].gp
            {r, %{m | mp: by_game_points(m.gp, theirs, match_points)}}

          # No board played over the board. THE definition of a played
          # match, which the checker's replay (`Ainalrami.TeamReplay`) and
          # the generator read from here: when BOTH teams scored on a board
          # by forfeit, both turned up (TRF-2026 330: a team shows up "if at
          # least one player is present"; Gacrux `decide_score`: "if both
          # team have points we consider the match played"), so the match
          # was played and is scored on its game points like any other -
          # a colour, a meeting, a float, and not a forfeit win for [C2].
          # Only when one side scored nothing is it a forfeit, won by the
          # side that scored; neither scoring is a double forfeit. Until
          # 2026-11-11 only the level case (reading T8) was played, and a
          # 2-1 on forfeits was a forfeit win.
          {r, %Match{kind: :unplayed, opponent: opp} = m} ->
            theirs = by_id[opp].rounds[r].gp

            m =
              cond do
                m.gp > 0 and theirs > 0 ->
                  %{m | kind: :played, mp: by_game_points(m.gp, theirs, match_points)}

                m.gp > theirs ->
                  %{m | kind: :forfeit_win, mp: match_points.win}

                true ->
                  %{m | kind: :forfeit_loss, mp: points.forfeit}
              end

            {r, m}

          other ->
            other
        end)

      %{entry | rounds: rounds}
    end
  end

  # A played match's match points, from the two sides' game points.
  defp by_game_points(ours, theirs, match_points) do
    cond do
      ours > theirs -> match_points.win
      ours < theirs -> match_points.loss
      true -> match_points.draw
    end
  end

  @doc "The event scored in match points (`:mp`) or game points (`:gp`)."
  def view(%__MODULE__{} = t, score) do
    {points, pick} =
      case score do
        :mp -> {t.match_points, & &1.mp}
        :gp -> {Map.new(t.game_points, fn {k, v} -> {k, v * t.boards} end), & &1.gp}
      end

    participants =
      for {id, team} <- t.teams do
        %Participant{
          id: id,
          tpn: team.tpn,
          rounds:
            Map.new(team.rounds, fn {r, m} ->
              {r,
               %Round{
                 kind: m.kind,
                 opponent: m.opponent,
                 points: pick.(m) * 1.0,
                 outcome: Event.outcome(m.mp * 1.0, t.match_points)
               }}
            end)
        }
      end

    Event.new(participants, t.rounds,
      points: points,
      predetermined?: t.predetermined?,
      total_rounds: t.total_rounds
    )
  end

  defp secondary(%{primary: :mp}), do: :gp
  defp secondary(%{primary: :gp}), do: :mp

  # ---- the public API ------------------------------------------------------

  @contextual ~w(DE EDE EDEBT EDEBB EDET EDEB BC TBR BBE)

  @doc """
  Values of every code that has one per team, as
  `{:ok, %{code => %{id => value} | :dropped}}`.
  """
  def compute(%__MODULE__{} = t, codes) do
    with {:ok, parsed} <- Code.parse_list(codes),
         :ok <- usable(parsed, t) do
      t = primary_from_list(t, parsed)
      views = views(t)

      {:ok,
       for(
         code <- parsed,
         code.name not in @contextual,
         into: %{},
         do: {Code.format(code), value(code, t, views)}
       )}
    end
  end

  @doc """
  The standings: `{:ok, [%{id:, rank:, values:}]}` in rank order, the
  primary score first unless the list names a score. As
  `Ainalrami.Tiebreaks.rank/3`, with the team tie-breaks.
  """
  def rank(%__MODULE__{} = t, codes, opts \\ []) do
    with {:ok, parsed} <- Code.parse_list(codes),
         :ok <- usable(parsed, t) do
      t = primary_from_list(t, parsed)
      parsed = with_score_first(parsed)
      views = views(t)

      {values, dropped} =
        Enum.reduce(parsed, {%{}, []}, fn code, {acc, dropped} ->
          if code.name in @contextual do
            {acc, dropped}
          else
            case value(code, t, views) do
              :dropped -> {acc, [Code.format(code) | dropped]}
              map -> {Map.put(acc, Code.format(code), map), dropped}
            end
          end
        end)

      active = Enum.reject(parsed, &(Code.format(&1) in dropped))
      ids = t.teams |> Map.keys() |> Enum.sort()
      {groups, positions} = order(ids, active, values, t, views, %{})
      standings = assign_ranks(groups, active, values, positions)

      if Keyword.get(opts, :with_dropped, false),
        do: {:ok, standings, Enum.reverse(dropped)},
        else: {:ok, standings}
    end
  end

  @doc """
  Orders one tied `group` of team ids by one code that orders groups rather
  than giving values (`DE`, the `EDE` family, `BC`, `TBR`, `BBE`), as
  `rank/3` does inside a ranking: `[[id]]`, subgroups in rank order, each
  still tied. The event's `:primary` is the primary score. For tools that
  rebuild a ranking step by step (`tools/team_tiebreak_compare.exs`).
  """
  def order_group(%__MODULE__{} = t, group, code) do
    %Code{name: name} = parsed = Code.parse!(code)
    true = name in @contextual
    split(Enum.sort(group), parsed, %{}, t, views(t))
  end

  @doc """
  How each value was reached, round by round: `{:ok, %{code => %{id =>
  [part]}}}` in `Ainalrami.Tiebreaks.Individual.working/3`'s shape, for the
  Buchholz and Sonneborn-Berger family (on either score), Koya, progressive
  score and the extended Sonneborn-Berger codes. Other codes are left out.
  """
  def working(%__MODULE__{} = t, codes) do
    with {:ok, parsed} <- Code.parse_list(codes),
         :ok <- usable(parsed, t) do
      views = views(t)

      {:ok,
       for code <- parsed,
           parts = team_working(code, t, views),
           parts != nil,
           into: %{} do
         {Code.format(code), parts}
       end}
    end
  end

  defp team_working(
         %Code{name: "E" <> <<a::binary-size(1), b::binary-size(1)>> <> "SB"} = code,
         _t,
         views
       )
       when a in ["M", "G"] and b in ["M", "G"] do
    first = if a == "M", do: :mp, else: :gp
    second = if b == "M", do: :mp, else: :gp
    Individual.extended_sonneborn_working(code, views.ctx[first], views[second])
  end

  defp team_working(%Code{name: name} = code, t, views) when name in ~w(BH FB SB KS PS) do
    score = code.score || t.primary
    Individual.working(code, views[score], views.ctx[score])
  end

  defp team_working(_code, _t, _views), do: nil

  # Article 8: no Buchholz-type tie-break when the pairings were fixed in
  # advance, as for individual events.
  defp usable(codes, t) do
    case Enum.find(codes, &(&1.name in ~w(BH FB AOB))) do
      %Code{} = code when t.predetermined? ->
        {:error, "#{Code.format(code)} must not be used in round robins (C.07 Article 8)"}

      _ ->
        :ok
    end
  end

  # Reading T5: a list that starts with a score names the primary score -
  # `GPTS EDE MPVGP` ranks by game points, so EDE starts from game points,
  # MPVGP is the match points, and a code without `:MP`/`:GP` is on game
  # points. Otherwise the event's `:primary` stands.
  defp primary_from_list(t, [%Code{name: "MPTS"} | _]), do: %{t | primary: :mp}
  defp primary_from_list(t, [%Code{name: "GPTS"} | _]), do: %{t | primary: :gp}
  defp primary_from_list(t, _codes), do: t

  defp with_score_first([%Code{name: name} | _] = codes) when name in ~w(PTS MPTS GPTS), do: codes
  defp with_score_first(codes), do: [%Code{name: "PTS"} | codes]

  defp views(t) do
    mp = view(t, :mp)
    gp = view(t, :gp)
    %{mp: mp, gp: gp, ctx: %{mp: Individual.context(mp), gp: Individual.context(gp)}}
  end

  # ---- values --------------------------------------------------------------

  defp value(%Code{name: "PTS"}, t, views), do: views.ctx[t.primary].scores
  defp value(%Code{name: "MPTS"}, _t, views), do: views.ctx.mp.scores
  defp value(%Code{name: "GPTS"}, _t, views), do: views.ctx.gp.scores
  defp value(%Code{name: "MPVGP"}, t, views), do: views.ctx[secondary(t)].scores

  # 13.2: the opponent's total in the first score times the points scored
  # against them in the second.
  defp value(
         %Code{name: "E" <> <<a::binary-size(1), b::binary-size(1)>> <> "SB"} = code,
         _t,
         views
       )
       when a in ["M", "G"] and b in ["M", "G"] do
    first = if a == "M", do: :mp, else: :gp
    second = if b == "M", do: :mp, else: :gp
    Individual.extended_sonneborn(code, views.ctx[first], views[second])
  end

  # 13.4: secondary score + Buchholz of the primary / the normalising factor.
  # `/F` makes the Buchholz a Fore Buchholz (13.4.2 a), `/P` counts forfeits
  # as games in it, and `/K<n>` is "a different value if stated by the rules
  # of the competition" for the factor (13.4.2 b).
  defp value(%Code{name: "SSSC"} = code, t, views) do
    primary = t.primary
    bh_name = if code.fore?, do: "FB", else: "BH"

    bh =
      Individual.values(
        %Code{name: bh_name, forfeits?: code.forfeits?},
        views[primary],
        views.ctx[primary]
      )

    highest_primary = t.rounds * views[primary].points.win

    highest_secondary_match =
      case secondary(t) do
        :gp -> t.boards * t.game_points.win
        :mp -> t.match_points.win
      end

    divisor = code.normaliser || max(trunc(highest_primary / highest_secondary_match), 1)
    secondary_scores = views.ctx[secondary(t)].scores

    Map.new(bh, fn {id, v} -> {id, secondary_scores[id] + v / divisor} end)
  end

  # Articles 6-10 on the score the code names, or the primary.
  defp value(%Code{} = code, t, views) do
    score = code.score || t.primary
    Individual.values(code, views[score], views.ctx[score])
  end

  # ---- ordering ------------------------------------------------------------

  defp order(group, [], _values, _t, _views, pos), do: {[group], pos}
  defp order([_] = group, _codes, _values, _t, _views, pos), do: {[group], pos}

  defp order(group, [code | rest], values, t, views, pos) do
    subgroups = split(group, code, values, t, views)
    pos = record_positions(pos, code, subgroups)

    Enum.reduce(subgroups, {[], pos}, fn sub, {acc, pos} ->
      {groups, pos} = order(sub, rest, values, t, views, pos)
      {acc ++ groups, pos}
    end)
  end

  defp record_positions(pos, %Code{name: name} = code, subgroups) when name in @contextual do
    subgroups
    |> Enum.with_index(1)
    |> Enum.reduce(pos, fn {members, p}, pos ->
      Enum.reduce(members, pos, &Map.put(&2, {Code.format(code), &1}, p))
    end)
  end

  defp record_positions(pos, _code, _subgroups), do: pos

  defp split(group, %Code{name: "DE"} = code, _values, t, views) do
    DirectEncounter.order(group, code, views[code.score || t.primary])
  end

  defp split(group, %Code{name: "EDE" <> variant} = code, _values, t, views) do
    group
    |> extended_direct_encounter(code, t, views)
    |> Enum.flat_map(&knockout(&1, variant, t, views))
  end

  defp split(group, %Code{name: "BC"}, _values, t, views), do: board_count(group, t, views)
  defp split(group, %Code{name: "TBR"}, _values, t, _views), do: top_boards(group, 1, t)

  defp split(group, %Code{name: "BBE"}, _values, t, _views),
    do: bottom_boards(group, t.boards - 1, t)

  defp split(group, code, values, _t, _views) do
    map = values[Code.format(code)]
    direction = if code.name == "TPN" != code.reverse?, do: :asc, else: :desc

    group
    |> Enum.group_by(&key(map[&1]))
    |> Enum.sort_by(fn {v, _} -> v end, direction)
    |> Enum.map(fn {_v, members} -> Enum.sort(members) end)
  end

  defp key(nil), do: -1.0e18
  defp key(v), do: Float.round(v * 1.0, 6)

  # 13.3.1 and 13.3.3: Article 6 on the primary score; if that breaks no
  # tie, on the secondary; every new subset starts again from the primary.
  defp extended_direct_encounter([_] = group, _code, _t, _views), do: [group]

  defp extended_direct_encounter(group, code, t, views) do
    de = %Code{name: "DE", forfeits?: code.forfeits?}

    subgroups =
      case DirectEncounter.order(group, de, views[t.primary]) do
        [^group] -> DirectEncounter.order(group, de, views[secondary(t)])
        split -> split
      end

    case subgroups do
      [same] when length(same) == length(group) -> [group]
      _ -> Enum.flat_map(subgroups, &extended_direct_encounter(&1, code, t, views))
    end
  end

  # 13.3.2: exactly two teams still level in both scores go on to the
  # knockout tie-breaks the variant names (reading T3).
  defp knockout([a, b] = pair, variant, t, views) do
    level? =
      same?(views.ctx.mp.scores[a], views.ctx.mp.scores[b]) and
        same?(views.ctx.gp.scores[a], views.ctx.gp.scores[b])

    steps =
      case variant do
        "BT" -> [:bc, :tbr]
        "BB" -> [:bc, :bbe]
        "T" -> [:tbr]
        "B" -> [:bbe]
        _ -> []
      end

    if level?, do: apply_steps([pair], steps, t, views), else: [pair]
  end

  defp knockout(group, _variant, _t, _views), do: [group]

  defp apply_steps(groups, [], _t, _views), do: groups

  defp apply_steps(groups, [step | rest], t, views) do
    groups
    |> Enum.flat_map(fn
      [_] = g -> [g]
      g -> step_split(g, step, t, views)
    end)
    |> apply_steps(rest, t, views)
  end

  defp step_split(g, :bc, t, views), do: board_count(g, t, views)
  defp step_split(g, :tbr, t, _views), do: top_boards(g, 1, t)
  defp step_split(g, :bbe, t, _views), do: bottom_boards(g, t.boards - 1, t)

  # 12.1: lower is better, and only among teams with the same game points.
  defp board_count(group, t, views) do
    gps = group |> Enum.map(&key(views.ctx.gp.scores[&1])) |> Enum.uniq()

    if length(gps) > 1 do
      [group]
    else
      group
      |> Enum.group_by(fn id -> key(board_sum(t, id, fn board, gp -> board * gp end)) end)
      |> Enum.sort_by(fn {v, _} -> v end, :asc)
      |> Enum.map(fn {_v, members} -> Enum.sort(members) end)
    end
  end

  # 12.2: board `k`'s game points; the teams still level go on to k + 1.
  defp top_boards(group, k, t) when k > t.boards or length(group) < 2, do: [group]

  defp top_boards(group, k, t) do
    group
    |> Enum.group_by(fn id ->
      key(board_sum(t, id, fn board, gp -> if board == k, do: gp, else: 0 end))
    end)
    |> Enum.sort_by(fn {v, _} -> v end, :desc)
    |> Enum.flat_map(fn {_v, members} -> top_boards(Enum.sort(members), k + 1, t) end)
  end

  # 12.3: boards 1..k; the teams still level go on to 1..k-1.
  defp bottom_boards(group, k, _t) when k < 1 or length(group) < 2, do: [group]

  defp bottom_boards(group, k, t) do
    group
    |> Enum.group_by(fn id ->
      key(board_sum(t, id, fn board, gp -> if board <= k, do: gp, else: 0 end))
    end)
    |> Enum.sort_by(fn {v, _} -> v end, :desc)
    |> Enum.flat_map(fn {_v, members} -> bottom_boards(Enum.sort(members), k - 1, t) end)
  end

  # Game points per board over every round, as Article 12 counts them. An
  # unplayed match with no boards recorded scores its result on every
  # board: a pairing-allocated bye a win (Article 12); a match won by
  # forfeit and a full-point bye a win, a half-point bye a draw, a match
  # lost by forfeit and a zero-point bye nothing - the text names only the
  # pairing-allocated bye, and this is how FIDE's TieBreakServer counts
  # the rest (reading Q3 in docs/conformance-c07-tiebreaks.md).
  defp board_sum(t, id, fun) do
    Enum.reduce(t.teams[id].rounds, 0.0, fn {_r, m}, acc ->
      boards =
        if m.boards == %{},
          do: unplayed_boards(m.kind, t.boards, t.game_points),
          else: m.boards

      Enum.reduce(boards, acc, fn {board, gp}, acc -> acc + fun.(board, gp) end)
    end)
  end

  defp unplayed_boards(kind, boards, gp) when kind in [:pab, :forfeit_win, :full_bye],
    do: Map.new(1..boards//1, &{&1, gp.win})

  defp unplayed_boards(:half_bye, boards, gp), do: Map.new(1..boards//1, &{&1, gp.draw})
  defp unplayed_boards(_kind, _boards, _gp), do: %{}

  defp same?(a, b), do: abs(a - b) < 1.0e-9

  defp assign_ranks(groups, codes, values, positions) do
    {rows, _} =
      Enum.flat_map_reduce(groups, 1, fn group, next ->
        rows =
          for id <- group do
            %{
              id: id,
              rank: next,
              values:
                Map.new(codes, fn code ->
                  f = Code.format(code)

                  {f,
                   if(code.name in @contextual,
                     do: Map.get(positions, {f, id}),
                     else: values[f][id]
                   )}
                end)
            }
          end

        {rows, next + length(group)}
      end)

    rows
  end
end

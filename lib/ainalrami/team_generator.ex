defmodule Ainalrami.TeamGenerator do
  @moduledoc """
  Random Tournament Generator for team events - `ainalrami -g --team=swiss`
  and `--team=roundrobin`, the team counterpart of `Ainalrami.Generator`.

  Builds random teams, then plays the event forward board by board and
  writes it as a TRF26 file: `310` teams with their rosters (board order),
  `001` players with every board game, `362` the match-point system
  (`W`/`D`/`L`, `P` for the pairing-allocated bye, `A` for a match lost by
  forfeit), `320` the bye teams, `330` forfeited matches, `300` boards
  played out of roster order, `192` the system, `152` the initial colour,
  `142` the round count and, with a tie-break list, `212` and the teams'
  final ranks.

  A team Swiss is paired round by round by `Ainalrami.TeamPairing`
  (C.04.6) itself, from the generator's own record of the event - not from
  the file, so that `ainalrami file -c` and `-p` on a truncated copy of it
  test the reading of the file against the engine's direct answer. A team
  round robin follows the Berger tables (`Ainalrami.Berger`).

  ## Reproducibility

  Everything is drawn from the seed: given `:seed`, the same options give
  the same bytes. Without one a fresh seed is drawn. The seed is returned
  and written into the tournament name (`012`), as `Ainalrami.Generator`
  does. Options left out are drawn from the seed too.

  ## What it varies

    * the system (`:system` - `:swiss`, the default, or `:round_robin`),
      the number of teams (`:teams`; a Swiss 4-16, a round robin 3-10),
      rounds (`:rounds`; a Swiss 3-9 and never more than teams - 1, a round
      robin its whole table unless fewer are asked for), boards (`:boards`,
      2-6), reserves (`:reserves`, at most this many per team, 0-2), and a
      round robin's cycles (`:cycles`, 1 or 2);
    * a Swiss's C.04.6 settings - `:type` (`:a`, `:b` or `:none` colour
      preferences), `:score_mode` (`:match_points` or `:game_points`
      primary), `:use_secondary?` (whether the secondary score allocates
      colours) - written as the `192` code that says them, and the
      `:initial_colour` (`:white` or `:black`, `152`);
    * the match points (`:match_points`, `{win, draw, loss}`, 2/1/0 or
      3/1/0), the pairing-allocated bye's (`:pab` - `:draw`, C.04.6 1.4's
      default, or `:win`; game points to match) and a match lost by
      forfeit's (`:forfeit_match_points`, default a loss's);
    * results (by the rating table, `:draw_rate` default 0.3), boards
      forfeited (`:board_forfeit_pct`), whole matches not turned up for
      (`:match_forfeit_pct` - board by board, or as a `330` with every board
      a forfeit, `--` excepted), teams sitting a round out
      (`:absent_team_pct`: every player has a zero-point bye; in a round
      robin the match is then forfeited, `330`, its first boards the `-`),
      players announced absent (`:absent_player_pct`: a zero-point bye,
      the players below moving up a board, a reserve filling in - never so
      many that a team cannot fill its boards), and lineups out of roster
      order (`:out_of_order_pct`, with a `300` record);
    * a team tie-break list (`:tie_breaks`, the codes after the score:
      `["GPTS", "EDE"]`); the file then carries the score and the list as
      `212` and the final ranks they give in the `310` records.

  A Swiss round the engine cannot pair (C.04.6 3.3.3) ends the event there;
  the header keeps the planned round count.

  ## How a file is laid out (and read back)

  A team's players are seated in roster order, the absent ones skipped, so
  board 1 is the first player who plays - unless a `300` record says
  otherwise. The team with White on board 1 has White on every odd board.
  The pairing-allocated bye is a `U` for the players the team would have
  seated. A team sitting the round out has a `Z` for every player, which
  is how `ainalrami -p` knows, before the pairing, to leave it out.
  """

  alias Ainalrami.{Berger, TeamPairing, Tiebreaks, Trf}
  alias Ainalrami.TeamPairing.Team

  @board_points %{"1" => 1.0, "=" => 0.5, "0" => 0.0, "+" => 1.0, "-" => 0.0}

  @doc """
  Generates a team event and returns `{trf_text, seed}`. See the moduledoc
  for the options.
  """
  def generate(opts \\ []) do
    %{text: text, seed: seed} = run(opts)
    {text, seed}
  end

  @doc """
  `generate/1` with the generator's own record: `%{text:, seed:, system:,
  teams:, boards:, planned:, rounds:, pairings:}`, `pairings` mapping each
  round to `%{matches: [{white, black}], bye:, lineups: %{team => [rank |
  nil]}}` - the pairing as the engine (or the Berger table) gave it and
  each paired team's boards.
  """
  def run(opts \\ []) do
    seed = Keyword.get_lazy(opts, :seed, &Ainalrami.Generator.fresh_seed/0)
    :rand.seed(:exsss, {seed, seed * 7919 + 11, seed * 104_729 + 3})

    ctx = context(opts, seed)
    rosters = rosters(ctx)
    ratings = ratings(rosters)
    ctx = Map.merge(ctx, %{rosters: rosters, ratings: ratings})

    start = %{
      games: Map.new(Enum.flat_map(Map.values(rosters), & &1), &{&1, %{}}),
      mp: Map.new(1..ctx.teams, &{&1, 0.0}),
      gp: Map.new(1..ctx.teams, &{&1, 0.0}),
      opponents: Map.new(1..ctx.teams, &{&1, []}),
      colours: Map.new(1..ctx.teams, &{&1, []}),
      had_pab: MapSet.new(),
      won_by_forfeit: MapSet.new(),
      floated: MapSet.new(),
      arrived: MapSet.new(),
      byes: %{},
      forfeits: [],
      orders: [],
      pairings: %{}
    }

    {final, played} =
      Enum.reduce_while(1..ctx.play//1, {start, 0}, fn r, {st, _} ->
        case play_round(st, r, ctx) do
          {:ok, st} -> {:cont, {st, r}}
          :stop -> {:halt, {st, r - 1}}
        end
      end)

    text = write(final, played, ctx)

    %{
      text: text,
      seed: seed,
      system: ctx.system,
      teams: ctx.teams,
      boards: ctx.boards,
      planned: ctx.planned,
      rounds: played,
      pairings: final.pairings
    }
  end

  # ---- options ---------------------------------------------------------------

  defp context(opts, seed) do
    system = Keyword.get(opts, :system, :swiss)

    unless system in [:swiss, :round_robin] do
      raise ArgumentError, ":system - :swiss or :round_robin, not #{inspect(system)}"
    end

    teams =
      opts
      |> Keyword.get_lazy(:teams, fn ->
        if system == :swiss, do: Enum.random(4..16), else: Enum.random(3..10)
      end)
      |> at_least!(:teams, 2)

    boards =
      opts |> Keyword.get_lazy(:boards, fn -> Enum.random(2..6) end) |> at_least!(:boards, 1)

    reserves =
      opts |> Keyword.get_lazy(:reserves, fn -> Enum.random(0..2) end) |> at_least!(:reserves, 0)

    # A round robin's match format (`XXM`): one table, every pairing played
    # as two matches in a row. Drawn from nothing, so every seed recorded
    # before it existed generates what it did.
    match? = Keyword.get(opts, :match_format, false) == true

    if match? and system != :round_robin,
      do: raise(ArgumentError, ":match_format is for a team round robin here")

    cycles =
      if match? do
        cycles = Keyword.get(opts, :cycles, 1)

        if cycles != 1,
          do: raise(ArgumentError, ":match_format plays a single table, not #{cycles} cycles")

        cycles
      else
        opts
        |> Keyword.get_lazy(:cycles, fn -> if :rand.uniform(4) == 1, do: 2, else: 1 end)
        |> at_least!(:cycles, 1)
      end

    {planned, play} =
      case system do
        :swiss ->
          rounds =
            opts
            |> Keyword.get_lazy(:rounds, fn -> Enum.random(3..9) end)
            |> at_least!(:rounds, 0)
            |> min(teams - 1)

          {rounds, rounds}

        :round_robin ->
          total = Berger.total_rounds(teams, cycles, match_format?: match?)
          play = opts |> Keyword.get(:rounds, total) |> at_least!(:rounds, 0) |> min(total)
          {total, play}
      end

    type = Keyword.get_lazy(opts, :type, fn -> Enum.random([:a, :a, :b, :none]) end)
    member!(type, [:a, :b, :none], :type)

    score_mode =
      Keyword.get_lazy(opts, :score_mode, fn ->
        Enum.random([:match_points, :match_points, :match_points, :game_points])
      end)

    member!(score_mode, [:match_points, :game_points], :score_mode)
    use_secondary? = Keyword.get_lazy(opts, :use_secondary?, fn -> :rand.uniform(4) > 1 end)

    initial_colour =
      Keyword.get_lazy(opts, :initial_colour, fn -> Enum.random([:white, :black]) end)

    member!(initial_colour, [:white, :black], :initial_colour)

    {w, d, l} =
      Keyword.get_lazy(opts, :match_points, fn ->
        Enum.random([{2.0, 1.0, 0.0}, {3.0, 1.0, 0.0}])
      end)
      |> then(fn {w, d, l} -> {w * 1.0, d * 1.0, l * 1.0} end)

    pab = Keyword.get_lazy(opts, :pab, fn -> Enum.random([:draw, :draw, :draw, :win]) end)
    member!(pab, [:draw, :win], :pab)
    {pab_mp, pab_gp} = if pab == :win, do: {w, 1.0 * boards}, else: {d, 0.5 * boards}
    forfeit_mp = Keyword.get(opts, :forfeit_match_points, l) * 1.0

    pct = fn key, choices ->
      opts |> Keyword.get_lazy(key, fn -> Enum.random(choices) end) |> pct!(key)
    end

    tie_breaks =
      case Keyword.fetch(opts, :tie_breaks) do
        {:ok, list} -> list
        :error -> if :rand.uniform(2) == 1, do: random_tie_breaks(system, score_mode), else: nil
      end

    %{
      seed: seed,
      system: system,
      teams: teams,
      boards: boards,
      reserves: reserves,
      cycles: cycles,
      match_format?: match?,
      planned: planned,
      play: play,
      type: type,
      score_mode: score_mode,
      use_secondary?: use_secondary?,
      initial_colour: initial_colour,
      points: %{win: w, draw: d, loss: l, pab: pab_mp, pab_gp: pab_gp, forfeit: forfeit_mp},
      draw_rate: opts |> Keyword.get(:draw_rate, 0.3),
      board_forfeit_pct: pct.(:board_forfeit_pct, [0, 2, 5]),
      match_forfeit_pct: pct.(:match_forfeit_pct, [0, 3, 8]),
      absent_team_pct: pct.(:absent_team_pct, [0, 5, 10]),
      absent_player_pct: pct.(:absent_player_pct, [0, 5, 15]),
      out_of_order_pct: pct.(:out_of_order_pct, [0, 10, 30]),
      tie_breaks: tie_breaks
    }
  end

  defp random_tie_breaks(system, score_mode) do
    {first, second} = if score_mode == :game_points, do: {"GPTS", "MPTS"}, else: {"MPTS", "GPTS"}
    pool = if system == :swiss, do: ~w(BH SB EDE BC SSSC), else: ~w(SB EDE BC SSSC)
    [first, second | Enum.take_random(pool, Enum.random(0..2))]
  end

  defp at_least!(value, _key, minimum) when is_integer(value) and value >= minimum, do: value

  defp at_least!(value, key, minimum),
    do:
      raise(
        ArgumentError,
        ":#{key} must be an integer of at least #{minimum}, not #{inspect(value)}"
      )

  defp pct!(value, _key) when is_integer(value) and value in 0..100, do: value
  defp pct!(value, key), do: raise(ArgumentError, ":#{key} takes 0 to 100, not #{inspect(value)}")

  defp member!(value, allowed, key) do
    unless value in allowed do
      raise ArgumentError, ":#{key} - one of #{inspect(allowed)}, not #{inspect(value)}"
    end
  end

  # ---- teams -----------------------------------------------------------------

  # Starting ranks team by team, board order within a team.
  defp rosters(ctx) do
    {rosters, _next} =
      Enum.map_reduce(1..ctx.teams, 1, fn t, next ->
        size = ctx.boards + Enum.random(0..ctx.reserves)
        {{t, Enum.to_list(next..(next + size - 1))}, next + size}
      end)

    Map.new(rosters)
  end

  defp ratings(rosters) do
    for {t, ranks} <- rosters, {rank, k} <- Enum.with_index(ranks), into: %{} do
      {rank, max(1400, 2500 - 50 * (t - 1) - 25 * k + Enum.random(0..40))}
    end
  end

  # ---- one round -------------------------------------------------------------

  defp play_round(st, r, ctx) do
    absent_teams = draw_absent_teams(ctx)
    present = Enum.reject(1..ctx.teams, &(&1 in absent_teams))
    absent_players = draw_absent_players(present, ctx)

    case pairing(st, r, present, ctx) do
      {:ok, matches, bye} ->
        st = mark_absent(st, r, absent_teams, absent_players, ctx)

        free = fn t ->
          if t in absent_teams,
            do: [],
            else: Enum.reject(ctx.rosters[t], &(&1 in absent_players))
        end

        floated =
          for {a, b} <- matches,
              score(st, a, ctx) != score(st, b, ctx),
              t <- [a, b],
              into: MapSet.new(),
              do: t

        {st, lineups} =
          Enum.reduce(matches, {st, %{}}, fn {a, b}, {st, lineups} ->
            {st, la, lb} = play_match(st, r, a, b, free, absent_teams, ctx)
            {st, lineups |> Map.put(a, la) |> Map.put(b, lb)}
          end)

        {st, lineups} = give_bye(st, r, bye, free, lineups, ctx)

        # A team out of the round's pairing scores a zero-point bye's match
        # points (`Tiebreaks.Team.from_trf/2`'s reading); in a round robin
        # the table's free team as well.
        paired = Enum.flat_map(matches, fn {a, b} -> [a, b] end) ++ List.wrap(bye)

        st =
          Enum.reduce(1..ctx.teams, st, fn t, st ->
            if t in paired,
              do: st,
              else: %{st | mp: Map.update!(st.mp, t, &(&1 + ctx.points.loss))}
          end)

        arrived =
          if ctx.system == :swiss,
            do: Enum.reduce(paired, st.arrived, &MapSet.put(&2, &1)),
            else: st.arrived

        {:ok,
         %{
           st
           | floated: floated,
             arrived: arrived,
             pairings:
               Map.put(st.pairings, r, %{
                 matches: matches,
                 bye: if(ctx.system == :swiss, do: bye),
                 free: if(ctx.system == :round_robin, do: bye),
                 lineups: lineups
               })
         }}

      :stop ->
        :stop
    end
  end

  defp draw_absent_teams(ctx) do
    absent = for t <- 1..ctx.teams, :rand.uniform(100) <= ctx.absent_team_pct, do: t
    if ctx.teams - length(absent) < 2, do: [], else: absent
  end

  # Announced absences, never so many that a team cannot fill its boards.
  defp draw_absent_players(present, ctx) do
    Enum.flat_map(present, fn t ->
      roster = ctx.rosters[t]
      spare = length(roster) - ctx.boards

      roster
      |> Enum.filter(fn _ -> :rand.uniform(100) <= ctx.absent_player_pct end)
      |> Enum.take(spare)
    end)
  end

  defp mark_absent(st, r, absent_teams, absent_players, ctx) do
    ranks = Enum.flat_map(absent_teams, &ctx.rosters[&1]) ++ absent_players
    games = Enum.reduce(ranks, st.games, &put_in(&2, [&1, r], {nil, nil, "Z"}))
    %{st | games: games}
  end

  defp pairing(st, r, present, %{system: :swiss} = ctx) do
    teams =
      for t <- present do
        %Team{
          tpn: t,
          match_points: st.mp[t],
          game_points: st.gp[t],
          opponents: st.opponents[t],
          colours: st.colours[t],
          had_pab?: MapSet.member?(st.had_pab, t),
          won_by_forfeit?: MapSet.member?(st.won_by_forfeit, t),
          floated_last_round?: MapSet.member?(st.floated, t)
        }
      end

    absent = st.arrived |> MapSet.to_list() |> Enum.reject(&(&1 in present)) |> Enum.sort()

    opts = [
      score_mode: ctx.score_mode,
      use_secondary?: ctx.use_secondary?,
      type: ctx.type,
      initial_colour: ctx.initial_colour,
      absent: absent,
      round: r,
      expected_rounds: ctx.planned
    ]

    case TeamPairing.pair_round(teams, opts) do
      {:ok, result} -> {:ok, Enum.map(result.pairs, &{&1.white, &1.black}), result.bye}
      {:error, _reason} -> :stop
    end
  end

  defp pairing(_st, r, _present, %{system: :round_robin} = ctx) do
    {:ok, pairs, free} = Berger.round(ctx.teams, ctx.cycles, r, match_format?: ctx.match_format?)
    {:ok, pairs, free}
  end

  defp score(st, t, %{score_mode: :game_points}), do: st.gp[t]
  defp score(st, t, _ctx), do: st.mp[t]

  # ---- one match ---------------------------------------------------------------

  defp play_match(st, r, a, b, free, absent_teams, ctx) do
    la = seat(free.(a), ctx)
    lb = seat(free.(b), ctx)

    # A whole match not played: a team sitting the round out (a round
    # robin's scheduled match), or a team not turning up.
    whole =
      cond do
        a in absent_teams and b in absent_teams ->
          :none

        a in absent_teams ->
          :black

        b in absent_teams ->
          :white

        :rand.uniform(100) <= ctx.match_forfeit_pct ->
          Enum.random([:white, :white, :black, :black, :none])

        true ->
          nil
      end

    declared? = whole != nil and (a in absent_teams or b in absent_teams or :rand.uniform(2) == 1)

    if declared? do
      declare_forfeit(st, r, a, b, whole, la, lb, ctx)
    else
      {st, la, lb} = out_of_order(st, r, a, b, la, lb, ctx)
      play_boards(st, r, a, b, whole, la, lb, ctx)
    end
  end

  # The first `boards` free players, in roster order.
  defp seat(free, ctx), do: Enum.take(free, ctx.boards)

  defp out_of_order(st, r, a, b, la, lb, ctx) do
    {la, orders} = maybe_reorder(la, r, a, b, st.orders, ctx)
    {lb, orders} = maybe_reorder(lb, r, b, a, orders, ctx)
    {%{st | orders: orders}, la, lb}
  end

  defp maybe_reorder(lineup, r, team, opponent, orders, ctx) do
    if length(lineup) >= 2 and :rand.uniform(100) <= ctx.out_of_order_pct do
      i = Enum.random(0..(length(lineup) - 2))
      j = Enum.random((i + 1)..(length(lineup) - 1))
      x = Enum.at(lineup, i)
      y = Enum.at(lineup, j)
      lineup = lineup |> List.replace_at(i, y) |> List.replace_at(j, x)
      {lineup, [%{round: r, team: team, opponent: opponent, order: lineup} | orders]}
    else
      {lineup, orders}
    end
  end

  # A `330` record: the winner a win's match points and a win on every
  # board, the loser (both, in a double forfeit) the forfeit's match points
  # and nothing - `Tiebreaks.Team.from_trf/2`'s reading.
  #
  # A one-sided forfeit (`+-`/`-+`) also goes on the players' lines, board
  # by board: the winners `+` against the board's player of the absent
  # team, who gets the `-` (TRF-2026, record 330, Notes 1 and 2 - XXXX "a
  # player of the absent team", C `w`/`b`, and the matching forfeit loss on
  # his line). Gacrux and anybody else who adds up a team's game points
  # from its players' lines then sees the forfeit wins Mario Held's TPS
  # example scores `0F-4F`; with the `330` alone they saw nothing, and the
  # winners of a forfeited match had no game points. A team sitting the
  # round out seated nobody, so its roster's first boards stand in. No
  # board is played, so the reader still calls it a forfeited match.
  #
  # A double forfeit stays a bare `330 --`: neither team showed up, and by
  # the record's own definition a team that shows up has its `001` records
  # updated.
  defp declare_forfeit(st, r, a, b, whole, la, lb, ctx) do
    type = %{white: "+-", black: "-+", none: "--"}[whole]
    p = ctx.points
    win_gp = 1.0 * ctx.boards

    {ma, ga, mb, gb} =
      case whole do
        :white -> {p.win, win_gp, p.forfeit, 0.0}
        :black -> {p.forfeit, 0.0, p.win, win_gp}
        :none -> {p.forfeit, 0.0, p.forfeit, 0.0}
      end

    games =
      if whole == :none do
        st.games
      else
        forfeit_boards(st.games, r, whole, nominal(la, a, ctx), nominal(lb, b, ctx))
      end

    st = %{
      st
      | games: games,
        forfeits: [%{type: type, round: r, white: a, black: b} | st.forfeits],
        mp: st.mp |> Map.update!(a, &(&1 + ma)) |> Map.update!(b, &(&1 + mb)),
        gp: st.gp |> Map.update!(a, &(&1 + ga)) |> Map.update!(b, &(&1 + gb)),
        won_by_forfeit:
          case whole do
            :white -> MapSet.put(st.won_by_forfeit, a)
            :black -> MapSet.put(st.won_by_forfeit, b)
            :none -> st.won_by_forfeit
          end
    }

    {st, la, lb}
  end

  # The boards a forfeited match is written on: the team's line-up, or for
  # a team that seated nobody, the first boards of its roster.
  defp nominal([], team, ctx), do: seat(ctx.rosters[team], ctx)
  defp nominal(lineup, _team, _ctx), do: lineup

  # Board k: the first team's player against the second's, White on the
  # odd boards for the first team (C.04.6 1.6.1), `+` for the winners and
  # `-` for the side that did not turn up.
  defp forfeit_boards(games, r, whole, la, lb) do
    {ra, rb} = board_result(whole, nil, nil, nil)

    la
    |> Enum.zip(lb)
    |> Enum.with_index(1)
    |> Enum.reduce(games, fn {{x, y}, board}, games ->
      x_white? = rem(board, 2) == 1

      games
      |> put_in([x, r], {y, if(x_white?, do: "w", else: "b"), ra})
      |> put_in([y, r], {x, if(x_white?, do: "b", else: "w"), rb})
    end)
  end

  defp play_boards(st, r, a, b, whole, la, lb, ctx) do
    boards = Enum.zip(la, lb) |> Enum.with_index(1)

    {games, pa, pb, played?} =
      Enum.reduce(boards, {st.games, 0.0, 0.0, false}, fn {{x, y}, board},
                                                          {games, pa, pb, played?} ->
        {rx, ry} = board_result(whole, x, y, ctx)
        x_white? = rem(board, 2) == 1

        games =
          games
          |> put_in([x, r], {y, if(x_white?, do: "w", else: "b"), rx})
          |> put_in([y, r], {x, if(x_white?, do: "b", else: "w"), ry})

        {games, pa + @board_points[rx], pb + @board_points[ry], played? or rx in ~w(1 = 0)}
      end)

    # A team that did not turn up, played out board by board, is recorded
    # by a `330` as well in half the events that have one: the boards rule
    # either way.
    st =
      if whole != nil and :rand.uniform(2) == 1 do
        type = %{white: "+-", black: "-+", none: "--"}[whole]
        %{st | forfeits: [%{type: type, round: r, white: a, black: b} | st.forfeits]}
      else
        st
      end

    p = ctx.points

    # `Tiebreaks.Team.from_trf/2`: a match with a board played is scored on
    # game points; one with none is a forfeit won by the side with more
    # game points, a double forfeit when neither scored, and a drawn match
    # (not a forfeit) when they are level on something.
    {ma, mb, winner} =
      cond do
        played? and pa > pb -> {p.win, p.loss, nil}
        played? and pa < pb -> {p.loss, p.win, nil}
        played? -> {p.draw, p.draw, nil}
        pa > pb -> {p.win, p.forfeit, a}
        pa < pb -> {p.forfeit, p.win, b}
        pa == 0 -> {p.forfeit, p.forfeit, nil}
        true -> {p.draw, p.draw, nil}
      end

    st = %{
      st
      | games: games,
        mp: st.mp |> Map.update!(a, &(&1 + ma)) |> Map.update!(b, &(&1 + mb)),
        gp: st.gp |> Map.update!(a, &(&1 + pa)) |> Map.update!(b, &(&1 + pb)),
        won_by_forfeit:
          if(winner, do: MapSet.put(st.won_by_forfeit, winner), else: st.won_by_forfeit)
    }

    st =
      if played? do
        %{
          st
          | opponents:
              st.opponents |> Map.update!(a, &(&1 ++ [b])) |> Map.update!(b, &(&1 ++ [a])),
            colours:
              st.colours |> Map.update!(a, &(&1 ++ [:white])) |> Map.update!(b, &(&1 ++ [:black]))
        }
      else
        st
      end

    {st, la, lb}
  end

  defp board_result(:white, _x, _y, _ctx), do: {"+", "-"}
  defp board_result(:black, _x, _y, _ctx), do: {"-", "+"}
  defp board_result(:none, _x, _y, _ctx), do: {"-", "-"}

  defp board_result(nil, x, y, ctx) do
    if :rand.uniform(100) <= ctx.board_forfeit_pct do
      Enum.random([{"+", "-"}, {"+", "-"}, {"-", "+"}, {"-", "+"}, {"-", "-"}])
    else
      game_result(ctx.ratings[x], ctx.ratings[y], ctx.draw_rate)
    end
  end

  defp game_result(ra, rb, draw_rate) do
    e = 1 / (1 + :math.pow(10, (rb - ra) / 400))
    x = :rand.uniform()

    cond do
      x < draw_rate -> {"=", "="}
      x < draw_rate + (1 - draw_rate) * e -> {"1", "0"}
      true -> {"0", "1"}
    end
  end

  defp give_bye(st, _r, nil, _free, lineups, _ctx), do: {st, lineups}

  defp give_bye(st, r, t, free, lineups, %{system: :round_robin}) do
    _ = {r, free}
    {st, Map.put(lineups, t, [])}
  end

  defp give_bye(st, r, t, free, lineups, ctx) do
    seated = seat(free.(t), ctx)
    games = Enum.reduce(seated, st.games, &put_in(&2, [&1, r], {nil, nil, "U"}))

    st = %{
      st
      | games: games,
        mp: Map.update!(st.mp, t, &(&1 + ctx.points.pab)),
        gp: Map.update!(st.gp, t, &(&1 + ctx.points.pab_gp)),
        had_pab: MapSet.put(st.had_pab, t),
        byes: Map.put(st.byes, r, t)
    }

    {st, Map.put(lineups, t, seated)}
  end

  # ---- the file ----------------------------------------------------------------

  defp write(st, played, ctx) do
    players =
      for {_t, ranks} <- Enum.sort(ctx.rosters), rank <- ranks do
        games =
          for r <- 1..played//1 do
            case st.games[rank][r] do
              nil -> %{opponent_rank: nil, colour: nil, result: ""}
              {opp, colour, res} -> %{opponent_rank: opp, colour: colour, result: res}
            end
          end

        %{
          rank: rank,
          name: "Player #{rank}",
          fide_rating: ctx.ratings[rank],
          points: games |> Enum.map(&individual_points(&1.result)) |> Enum.sum(),
          games: games
        }
      end

    p = ctx.points

    tournament =
      %{
        name: "Ainalrami team RTG seed=#{ctx.seed}",
        type: if(ctx.system == :swiss, do: "Team Swiss System", else: "Team Round Robin"),
        type_code: type_code(ctx),
        number_of_rounds: ctx.planned,
        match_format: if(ctx.match_format?, do: true),
        team_point_system: %{
          win: p.win,
          draw: p.draw,
          loss: p.loss,
          pab: p.pab,
          absent: p.forfeit
        }
      }
      |> put_if(
        ctx.system == :swiss,
        :initial_colour,
        if(ctx.initial_colour == :black, do: "b", else: "w")
      )
      |> put_if(ctx.system == :swiss, :team_pab, %{
        match_points: p.pab,
        game_points: p.pab_gp,
        teams: for(r <- 1..played//1, do: Map.get(st.byes, r, 0))
      })
      |> put_if(st.forfeits != [], :forfeited_matches, Enum.reverse(st.forfeits))
      |> put_if(st.orders != [], :board_orders, Enum.reverse(st.orders))
      |> put_if(ctx.tie_breaks != nil, :standings_order, ctx.tie_breaks)

    teams =
      for {t, ranks} <- Enum.sort(ctx.rosters) do
        %{number: t, name: "Team #{t}", player_ranks: ranks}
      end

    data = %{tournament: tournament, players: players, teams: teams}

    # The teams' totals and ranks as the file itself scores them.
    parsed = Trf.parse(Trf.serialize(data, dialect: :trf26))
    event = Tiebreaks.Team.from_trf(parsed)

    totals =
      Map.new(event.teams, fn {id, team} ->
        mp = team.rounds |> Map.values() |> Enum.map(& &1.mp) |> Enum.sum()
        gp = team.rounds |> Map.values() |> Enum.map(& &1.gp) |> Enum.sum()
        {id, {mp * 1.0, gp * 1.0}}
      end)

    ranks = final_ranks(event, ctx.tie_breaks)

    teams =
      Enum.map(teams, fn team ->
        {mp, gp} = totals[team.number]

        team
        |> Map.merge(%{match_points: mp, game_points: gp})
        |> put_if(ranks != nil, :final_rank, ranks && ranks[team.number])
      end)

    Trf.serialize(%{data | teams: teams}, dialect: :trf26)
  end

  # Teams still level after the whole list are placed in team-number order.
  defp final_ranks(_event, nil), do: nil

  defp final_ranks(event, list) do
    case Tiebreaks.Team.rank(event, list) do
      {:ok, standings} ->
        standings
        |> Enum.sort_by(&{&1.rank, &1.id})
        |> Enum.with_index(1)
        |> Map.new(fn {row, i} -> {row.id, i} end)

      {:error, reason} ->
        raise ArgumentError, ":tie_breaks - #{reason}"
    end
  end

  defp individual_points("U"), do: 1.0
  defp individual_points(result), do: Map.get(@board_points, result, 0.0)

  defp type_code(%{system: :round_robin, match_format?: true}), do: "CUSTOM_TEAM_ROUNDROBIN"
  defp type_code(%{system: :round_robin, cycles: cycles}), do: "BERGER_TEAM_ROUNDROBIN_G#{cycles}"

  defp type_code(ctx) do
    type = %{a: "TYPEA_", b: "TYPEB_", none: ""}[ctx.type]

    scores =
      case {ctx.score_mode, ctx.use_secondary?} do
        {:match_points, true} -> "MP_GP"
        {:match_points, false} -> "MP"
        {:game_points, true} -> "GP_MP"
        {:game_points, false} -> "GP"
      end

    "FIDE_TEAM_#{type}#{scores}"
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map
end

defmodule Ainalrami.TeamTrfGenerator do
  @moduledoc """
  Board-level team tournaments as TRF26 text, for the team tie-break
  comparisons: `tools/team_tiebreak_compare.exs` (against TieBreakServer)
  and `Ainalrami.TiebreakReference.Proof` (against the independent
  reference). The pairing is not under test - only the tie-breaks computed
  from the file - so it is simple.

  `generate(seed)` draws everything from the seed:

    * the format, by `rem(seed, 10)`: 0-5 a Swiss by match points (6-20
      teams, a pairing-allocated bye in an odd field, greedy pairing with a
      rematch only when forced); 6-7 a team round robin (3-10 teams, single
      or one time in four double, a free round in an odd field); 8 a
      Scheveningen (two teams, every player of one meets every player of the
      other, once or twice); 9 a Schiller-type event (3-4 teams, each pair
      of teams meets once per board, the boards crosswise as in a
      Scheveningen). Round robins, Scheveningen and Schiller carry their
      TRF26 `192` code, so the pairings are predetermined (Article 8 and
      15.2);
    * 3-10 boards (3-6 for the Scheveningen-type formats);
    * match points 2/1/0 or 3/1/0, written as a TRF26 `362` record, teams as `310` records (with
      `P` for the pairing-allocated bye and `A` for a forfeited match);
    * zero to two reserves per team, who play instead of a regular half the
      time (moving the players below up a board);
    * individual forfeits (none, 1.5% or 5% of games);
    * whole matches forfeited (none, 3% or 8% of matches; one in four of
      them a double forfeit), written board by board (`+`/`-` against the
      opponents) and, in half the events, with a TRF26 `330` record too.

  `opts[:selector]` (0-9) picks the format instead of `rem(seed, 10)`.

  `opts[:pairing]` - `:greedy` (the default, above) or `:engine`: a Swiss
  paired round by round by `Ainalrami.TeamPairing` (C.04.6) itself, board
  1's White to the team the engine gives White and the boards alternating
  from it, for the checker's team replay (`ainalrami -c`,
  `Ainalrami.TeamReplay`). The file then carries the settings as a `192`
  code and the initial colour as `152`, from `opts[:type]` (`:a`, default,
  `:b`, or `:none` for no colour preferences), `opts[:score_mode]` (`:match_points`, default, or
  `:game_points`) and `opts[:initial_colour]` (`:white`, default, or
  `:black`). The engine's view of the history is kept alongside: points,
  opponents and board-1 colours of played matches, the bye, forfeit wins
  (no board played, more game points) and last round's floaters. A round
  the engine cannot pair ends the event there, the header keeping the
  planned round count. The draws differ from `:greedy`'s, so a seed makes
  a different event in each mode; `:greedy` is unchanged.

  Returns `%{text:, rounds:, boards:, format:, predetermined?:,
  match_points:, forfeited_matches:}`.
  """

  alias Ainalrami.TeamPairing
  alias Ainalrami.Trf

  @wins %{"1" => 1.0, "=" => 0.5, "0" => 0.0, "+" => 1.0, "-" => 0.0}

  def generate(seed, opts \\ []) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 5})

    format =
      case Keyword.get(opts, :selector, rem(seed, 10)) do
        r when r in 0..5 -> :swiss
        r when r in 6..7 -> :round_robin
        8 -> :scheveningen
        9 -> :schiller
      end

    boards =
      if format in [:scheveningen, :schiller], do: Enum.random(3..6), else: Enum.random(3..10)

    mpts = Enum.random([{2.0, 1.0, 0.0}, {3.0, 1.0, 0.0}])
    forfeit_rate = Enum.random([0.0, 0.015, 0.05])
    match_forfeit_rate = Enum.random([0.0, 0.0, 0.03, 0.08])
    write_330? = :rand.uniform() < 0.5

    teams =
      case format do
        :swiss -> Enum.random(6..20)
        :round_robin -> Enum.random(3..10)
        :scheveningen -> 2
        :schiller -> Enum.random(3..4)
      end

    reserves = fn ->
      if format == :swiss or format == :round_robin, do: Enum.random([0, 0, 1, 2]), else: 0
    end

    {rosters, _} =
      Enum.map_reduce(1..teams, 1, fn t, next ->
        size = boards + reserves.()
        {{t, Enum.to_list(next..(next + size - 1))}, next + size}
      end)

    rosters = Map.new(rosters)
    players = rosters |> Map.values() |> List.flatten() |> Enum.sort()
    rating = Map.new(players, &{&1, 2400 - &1 * 3 + :rand.uniform(60)})

    engine? = format == :swiss and Keyword.get(opts, :pairing, :greedy) == :engine

    ctx = %{
      boards: boards,
      rosters: rosters,
      rating: rating,
      mpts: mpts,
      forfeit_rate: forfeit_rate,
      match_forfeit_rate: match_forfeit_rate,
      engine?: engine?,
      type: Keyword.get(opts, :type, :a),
      score_mode: Keyword.get(opts, :score_mode, :match_points),
      initial_colour: Keyword.get(opts, :initial_colour, :white)
    }

    {schedule, type_code, predetermined?} = schedule(format, teams, boards)

    type_code = if engine?, do: engine_type_code(ctx), else: type_code

    zero = Map.new(1..teams, &{&1, 0.0})

    start = %{
      mp: zero,
      gp: zero,
      cd: Map.new(1..teams, &{&1, 0}),
      met: MapSet.new(),
      byes: [],
      forfeited: [],
      games: Map.new(players, &{&1, %{}}),
      # The engine's view (`pairing: :engine` only).
      colours: Map.new(1..teams, &{&1, []}),
      played: Map.new(1..teams, &{&1, []}),
      forfeit_won: MapSet.new(),
      floated: MapSet.new(),
      floating: MapSet.new()
    }

    planned =
      case schedule do
        {:swiss, n} -> n
        list -> length(list)
      end

    {final, rounds} =
      Enum.reduce_while(1..planned, {start, 0}, fn r, {st, _} ->
        paired =
          case schedule do
            {:swiss, _} when engine? -> engine_round(st, teams, r, planned, ctx)
            {:swiss, _} -> {:ok, swiss_round(st, teams)}
            list -> {:ok, {Enum.at(list, r - 1), nil}}
          end

        case paired do
          {:ok, {pairs, bye}} ->
            # 1.5: only a PLAYED match against a different score makes a
            # floater (`engine_history/7` collects them as the matches go).
            st = Enum.reduce(pairs, %{st | floating: MapSet.new()}, &play_match(&1, &2, r, ctx))
            {:cont, {%{give_bye(st, bye, r, ctx) | floated: st.floating}, r}}

          :stop ->
            {:halt, {st, r - 1}}
        end
      end)

    trf_players =
      for rank <- players do
        games =
          for r <- 1..rounds//1 do
            case final.games[rank][r] do
              nil -> %{opponent_rank: nil, colour: "-", result: ""}
              {opp, colour, res} -> %{opponent_rank: opp, colour: colour, result: res}
            end
          end

        points =
          games
          |> Enum.map(fn g ->
            if g.result == "U", do: 1.0, else: Map.get(@wins, g.result, 0.0)
          end)
          |> Enum.sum()

        %{
          rank: rank,
          name: "Player #{rank}",
          fide_rating: rating[rank],
          points: points,
          games: games
        }
      end

    {w, d, l} = mpts

    tournament =
      %{
        name: "Ainalrami team tie-breaks seed=#{seed}",
        type: if(predetermined?, do: "Team round robin", else: "Team swiss"),
        number_of_rounds: planned
      }
      |> then(&if(type_code, do: Map.put(&1, :type_code, type_code), else: &1))
      |> then(
        &if(engine?,
          do:
            &1
            |> Map.put(:initial_colour, if(ctx.initial_colour == :black, do: "b", else: "w"))
            |> Map.put(:board_colours, Trf.board_colours(boards)),
          else: &1
        )
      )

    forfeited = Enum.reverse(final.forfeited)

    # Written by `Trf.serialize/2` itself (`310`, `362`, `330`), so every
    # file this returns round-trips through `Trf.parse/1`.
    forfeit_records =
      if write_330? do
        for {r, a, b, winner} <- forfeited do
          %{type: %{white: "+-", black: "-+", none: "--"}[winner], round: r, white: a, black: b}
        end
      else
        []
      end

    tournament =
      tournament
      |> Map.put(:team_point_system, %{win: w, draw: d, loss: l, pab: w, absent: l})
      |> then(
        &if(forfeit_records == [], do: &1, else: Map.put(&1, :forfeited_matches, forfeit_records))
      )

    text =
      Trf.serialize(%{
        tournament: tournament,
        players: trf_players,
        teams:
          Enum.map(1..teams, fn t ->
            %{
              number: t,
              name: "Team #{t}",
              match_points: final.mp[t],
              game_points: final.gp[t],
              player_ranks: rosters[t]
            }
          end)
      })

    %{
      text: text,
      rounds: rounds,
      boards: boards,
      format: format,
      predetermined?: predetermined?,
      match_points: %{win: w, draw: d, loss: l},
      forfeited_matches: forfeited
    }
  end

  # ---- schedules ------------------------------------------------------------

  # A pair is `{white_team, black_team, crosswise_offset}`: board 1's white
  # is the first team's; with an offset k, the first team's i-th player
  # meets the second team's (i + k)-th (mod boards).
  defp schedule(:swiss, teams, _boards),
    do: {{:swiss, Enum.min([teams - 1, 5 + :rand.uniform(5) - 1])}, nil, false}

  defp schedule(:round_robin, teams, _boards) do
    cycles = if :rand.uniform(4) == 1, do: 2, else: 1
    code = if cycles == 2, do: "FIDE_TEAM_DOUBLEROUNDROBIN", else: "FIDE_TEAM_ROUNDROBIN"

    rounds =
      for c <- 1..cycles, pairs <- berger(teams) do
        for {a, b} <- pairs, do: if(c == 2, do: {b, a, 0}, else: {a, b, 0})
      end

    {rounds, code, true}
  end

  defp schedule(:scheveningen, 2, boards) do
    cycles = if :rand.uniform(3) == 1, do: 2, else: 1
    code = if cycles == 2, do: "FIDE_DOUBLESCHEVENINGEN", else: "FIDE_SCHEVENINGEN"

    rounds =
      for c <- 1..cycles, k <- 0..(boards - 1) do
        if rem(k + c, 2) == 0, do: [{1, 2, k}], else: [{2, 1, boards - k}]
      end

    {rounds, code, true}
  end

  defp schedule(:schiller, teams, boards) do
    rounds =
      for k <- 0..(boards - 1), pairs <- berger(teams) do
        for {a, b} <- pairs, do: if(rem(k, 2) == 0, do: {a, b, k}, else: {b, a, boards - k})
      end

    {rounds, "FIDE_SCHILLER", true}
  end

  # The circle method; in an odd field the team meeting the phantom has the
  # round free.
  defp berger(teams) do
    field = if rem(teams, 2) == 1, do: teams + 1, else: teams
    others = Enum.to_list(1..(field - 1))

    for r <- 1..(field - 1) do
      circle = [field | Enum.drop(others, r - 1) ++ Enum.take(others, r - 1)]

      for i <- 0..(div(field, 2) - 1),
          a = Enum.at(circle, i),
          b = Enum.at(circle, field - 1 - i),
          a <= teams and b <= teams do
        if rem(r + i, 2) == 0, do: {a, b}, else: {b, a}
      end
    end
  end

  defp swiss_round(st, teams) do
    order = Enum.sort_by(1..teams, &{-st.mp[&1], -st.gp[&1], &1})

    {bye, order} =
      if rem(teams, 2) == 1 do
        b = order |> Enum.reverse() |> Enum.find(List.last(order), &(&1 not in st.byes))
        {b, List.delete(order, b)}
      else
        {nil, order}
      end

    pairs =
      order
      |> greedy(st.met, [])
      # The team with fewer whites on board 1 so far gets white there, so no
      # team's colour difference runs away (TieBreakServer's colour
      # bookkeeping indexes a table that stops at +-4).
      |> Enum.map(fn {a, b} -> if st.cd[a] <= st.cd[b], do: {a, b, 0}, else: {b, a, 0} end)

    {pairs, bye}
  end

  defp greedy([], _met, acc), do: Enum.reverse(acc)

  defp greedy([a | rest], met, acc) do
    b = Enum.find(rest, &(not MapSet.member?(met, {a, &1}))) || hd(rest)
    greedy(List.delete(rest, b), met, [{a, b} | acc])
  end

  # ---- pairing: :engine ---------------------------------------------------------

  defp engine_type_code(ctx) do
    # TRF26's table: no TYPEA/TYPEB means no colour preferences.
    type = %{a: "TYPEA_", b: "TYPEB_", none: ""}[ctx.type]
    scores = if ctx.score_mode == :game_points, do: "GP_MP", else: "MP_GP"
    "FIDE_TEAM_#{type}#{scores}"
  end

  defp score(st, t, %{score_mode: :game_points}), do: st.gp[t]
  defp score(st, t, _ctx), do: st.mp[t]

  defp engine_round(st, teams, r, planned, ctx) do
    structs =
      for t <- 1..teams do
        %TeamPairing.Team{
          tpn: t,
          match_points: st.mp[t],
          game_points: st.gp[t],
          opponents: st.played[t],
          colours: st.colours[t],
          had_pab?: t in st.byes,
          won_by_forfeit?: MapSet.member?(st.forfeit_won, t),
          floated_last_round?: MapSet.member?(st.floated, t)
        }
      end

    opts = [
      type: ctx.type,
      score_mode: ctx.score_mode,
      initial_colour: ctx.initial_colour,
      round: r,
      expected_rounds: planned
    ]

    case TeamPairing.pair_round(structs, opts) do
      {:ok, result} -> {:ok, {Enum.map(result.pairs, &{&1.white, &1.black, 0}), result.bye}}
      {:error, _} -> :stop
    end
  end

  # `a` had White on board 1. Colours, opponents and floats count only a
  # PLAYED match: a board played over the board, or both teams scoring on a
  # board by forfeit (both turned up - `Tiebreaks.Team.from_trf/2`). One
  # without is won by forfeit by the side that scored.
  defp engine_history(st, a, b, pa, pb, played?, ctx) do
    cond do
      played? or (pa > 0 and pb > 0) ->
        floating =
          if score(st, a, ctx) != score(st, b, ctx),
            do: st.floating |> MapSet.put(a) |> MapSet.put(b),
            else: st.floating

        %{
          st
          | floating: floating,
            colours: %{
              st.colours
              | a => st.colours[a] ++ [:white],
                b => st.colours[b] ++ [:black]
            },
            played: %{st.played | a => st.played[a] ++ [b], b => st.played[b] ++ [a]}
        }

      pa > pb ->
        %{st | forfeit_won: MapSet.put(st.forfeit_won, a)}

      pb > pa ->
        %{st | forfeit_won: MapSet.put(st.forfeit_won, b)}

      true ->
        st
    end
  end

  # ---- one match --------------------------------------------------------------

  defp lineup(ctx, t) do
    roster = ctx.rosters[t]

    if length(roster) > ctx.boards and :rand.uniform() < 0.5 do
      roster
      |> Enum.take(ctx.boards + 1)
      |> List.delete_at(:rand.uniform(ctx.boards) - 1)
    else
      Enum.take(roster, ctx.boards)
    end
  end

  defp play_match({a, b, offset}, st, r, ctx) do
    # Board 1's white to the team with fewer so far, in every format (see
    # swiss_round/2); swapping the teams turns the crosswise offset round.
    # With `pairing: :engine` the engine has already given `a` White.
    {a, b, offset} =
      if ctx.engine? or st.cd[a] <= st.cd[b],
        do: {a, b, offset},
        else: {b, a, rem(ctx.boards - offset, ctx.boards)}

    la = lineup(ctx, a)
    lb = lineup(ctx, b)
    lb = Enum.drop(lb, offset) ++ Enum.take(lb, offset)

    whole =
      if :rand.uniform() < ctx.match_forfeit_rate do
        case :rand.uniform(8) do
          n when n <= 3 -> :white
          n when n <= 6 -> :black
          _ -> :none
        end
      end

    result = fn x, y ->
      case whole do
        :white -> {"+", "-"}
        :black -> {"-", "+"}
        :none -> {"-", "-"}
        nil -> game_result(x, y, ctx)
      end
    end

    # TieBreakServer takes the match's white team from the game of the
    # lower-numbered team's top-listed player, and its colour bookkeeping
    # breaks past a difference of +-8; so the whole match's colours are
    # turned round when that team is already the one with more whites.
    paired = Enum.with_index(Enum.zip(la, lb), 1)
    low_side = if a < b, do: 0, else: 1

    {_, top_board} =
      Enum.min_by(paired, fn {pair, _board} -> elem(pair, low_side) end)

    a_white_at_top? = rem(top_board, 2) == 1
    tbs_white = if a_white_at_top?, do: a, else: b
    tbs_black = if tbs_white == a, do: b, else: a
    flip? = not ctx.engine? and st.cd[tbs_white] > st.cd[tbs_black]
    {tbs_white, tbs_black} = if flip?, do: {tbs_black, tbs_white}, else: {tbs_white, tbs_black}

    {games, pa, pb, played?} =
      paired
      |> Enum.reduce({st.games, 0.0, 0.0, false}, fn {{x, y}, board}, {games, pa, pb, played?} ->
        {rx, ry} = result.(x, y)
        white_first? = rem(board, 2) == 1 != flip?

        games =
          games
          |> put_in([x, r], {y, if(white_first?, do: "w", else: "b"), rx})
          |> put_in([y, r], {x, if(white_first?, do: "b", else: "w"), ry})

        {games, pa + @wins[rx], pb + @wins[ry], played? or rx not in ["+", "-"]}
      end)

    st = engine_history(st, a, b, pa, pb, played?, ctx)

    {w, d, l} = ctx.mpts

    {ma, mb} =
      cond do
        pa > pb -> {w, l}
        pa < pb -> {l, w}
        pa == 0 -> {l, l}
        true -> {d, d}
      end

    %{
      st
      | games: games,
        mp: %{st.mp | a => st.mp[a] + ma, b => st.mp[b] + mb},
        gp: %{st.gp | a => st.gp[a] + pa, b => st.gp[b] + pb},
        cd: %{st.cd | tbs_white => st.cd[tbs_white] + 1, tbs_black => st.cd[tbs_black] - 1},
        met: st.met |> MapSet.put({a, b}) |> MapSet.put({b, a}),
        forfeited: if(whole, do: [{r, a, b, whole} | st.forfeited], else: st.forfeited)
    }
  end

  defp game_result(a, b, ctx) do
    x = :rand.uniform()
    e = 1 / (1 + :math.pow(10, (ctx.rating[b] - ctx.rating[a]) / 400))
    f = ctx.forfeit_rate

    cond do
      x < f / 2 -> {"+", "-"}
      x < f -> {"-", "+"}
      x < f + 0.3 -> {"=", "="}
      x < f + 0.3 + (0.7 - f) * e -> {"1", "0"}
      true -> {"0", "1"}
    end
  end

  defp give_bye(st, nil, _r, _ctx), do: st

  defp give_bye(st, t, r, ctx) do
    {w, _, _} = ctx.mpts

    games =
      Enum.reduce(
        Enum.take(ctx.rosters[t], ctx.boards),
        st.games,
        &put_in(&2, [&1, r], {nil, "-", "U"})
      )

    %{
      st
      | games: games,
        mp: %{st.mp | t => st.mp[t] + w},
        gp: %{st.gp | t => st.gp[t] + ctx.boards * 1.0},
        byes: [t | st.byes]
    }
  end
end

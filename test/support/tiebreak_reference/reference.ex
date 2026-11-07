defmodule Ainalrami.TiebreakReference do
  @moduledoc """
  A deliberately naive second implementation of FIDE C.07 tie-breaks
  (effective 1 March 2026), written straight from
  `docs/c07-regulation-text.md`, for comparison with `Ainalrami.Tiebreaks`.

  It shares NO code with `lib/ainalrami/tiebreaks*`: no calls, no helpers,
  not even the code parser or the rating tables (transcribed again here from
  the FIDE Rating Regulations). It builds its own event model from what the
  engine is handed - a parsed TRF (`from_trf/2`, from `Ainalrami.Trf.parse/1`,
  not from `Ainalrami.Tiebreaks.Event.from_trf/2`) or the raw data of a
  `%Ainalrami.Tiebreaks.Team{}` (`from_team/1`, fields only).

  Clarity over speed: everything is recomputed on demand, lists are scanned
  from the start, and Article 6.3's "whatever the outcome of the missing
  games" is checked by enumerating the outcomes when there are few enough.

  The readings are the ones recorded in `docs/conformance-c07-tiebreaks.md`
  ("reading N" below) - agreement proves the engine computes THOSE readings,
  not that they are FIDE's. Why and how it is used:
  `docs/tiebreak-reference.md`.

  ## The model

      %{n: rounds counted, total: announced rounds, rr?: pairings fixed in
        advance (Article 15.2), win:, draw:, loss:, ids: [id],
        p: %{id => %{tpn:, rating: nil | integer, r: %{round => rd}}}}

  where a round `rd` is `%{t:, opp:, col:, pts:, res:}`, `t` one of
  `:game` (over the board), `:fwin`, `:floss`, `:pab`, `:fbye`, `:hbye`,
  `:zbye`, and `res` `:w | :d | :l`.
  """

  # ======================================================================
  # Building the model
  # ======================================================================

  @trf_default %{
    win: 1.0,
    draw: 0.5,
    loss: 0.0,
    pairing_allocated_bye: 1.0,
    forfeit_loss: 0.0,
    zero_point_bye: 0.0
  }

  @doc """
  The model of an individual event from `Ainalrami.Trf.parse/1`'s map.
  Options: `:rounds` (standings after that round), `:predetermined?`.
  """
  def from_trf(trf, opts \\ []) do
    t = trf.tournament
    sys = Map.get(t, :point_system) || @trf_default

    n =
      opts[:rounds] ||
        trf.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)

    rr? =
      case Keyword.fetch(opts, :predetermined?) do
        {:ok, v} ->
          v

        :error ->
          code = Map.get(t, :type_code)

          is_binary(code) and
            (String.contains?(code, "ROUNDROBIN") or String.contains?(code, "SCHILLER") or
               String.contains?(code, "SCHEVENINGEN"))
      end

    base = %{win: sys.win * 1.0, draw: sys.draw * 1.0, loss: sys.loss * 1.0}

    players =
      Map.new(trf.players, fn pl ->
        games = Enum.take(pl.games, n)

        rounds =
          for r <- 1..n//1, into: %{} do
            case Enum.at(games, r - 1) do
              nil -> {r, %{t: :zbye, opp: nil, col: nil, pts: 0.0, res: :l}}
              g -> {r, trf_round(g, sys, base)}
            end
          end

        rating =
          case Map.get(pl, :fide_rating) do
            x when is_integer(x) and x > 0 -> x
            _ -> nil
          end

        {pl.rank, %{tpn: pl.rank, rating: rating, r: rounds}}
      end)

    total = max(Map.get(t, :number_of_rounds) || n, n)

    Map.merge(base, %{
      n: n,
      total: total,
      rr?: rr?,
      ids: players |> Map.keys() |> Enum.sort(),
      p: players
    })
  end

  defp trf_round(g, sys, base) do
    opp = Map.get(g, :opponent_rank)
    code = Map.get(g, :result)

    t =
      cond do
        opp != nil and code in ~w(1 W = D 0 L ?) -> :game
        opp != nil and code == "+" -> :fwin
        opp != nil and code == "-" -> :floss
        code in ~w(U +) -> :pab
        code == "F" -> :fbye
        code == "H" -> :hbye
        true -> :zbye
      end

    opp = if t in [:game, :fwin, :floss], do: opp
    pts = trf_points(t, code, sys) * 1.0

    res =
      cond do
        t == :game and code in ~w(1 W) -> :w
        t == :game and code in ~w(= D) -> :d
        t == :game and code in ~w(0 L) -> :l
        # everything else: "the result corresponding to the awarded number
        # of points" (16.3.1, 16.4)
        true -> result_of(pts, base)
      end

    col =
      if opp do
        case Map.get(g, :colour) do
          "w" -> :white
          "b" -> :black
          _ -> nil
        end
      end

    %{t: t, opp: opp, col: col, pts: pts, res: res}
  end

  # The TRF's own scoring of a result code.
  defp trf_points(:zbye, _code, sys), do: sys.zero_point_bye
  defp trf_points(:pab, _code, sys), do: sys.pairing_allocated_bye
  defp trf_points(:fbye, _code, sys), do: Map.get(sys, :full_point_bye) || sys.win
  defp trf_points(:hbye, _code, sys), do: Map.get(sys, :half_point_bye) || sys.draw
  defp trf_points(:fwin, _code, sys), do: Map.get(sys, :forfeit_win) || sys.win
  defp trf_points(:floss, _code, sys), do: sys.forfeit_loss
  defp trf_points(:game, c, sys) when c in ~w(1 W), do: sys.win
  defp trf_points(:game, c, sys) when c in ~w(= D), do: sys.draw
  defp trf_points(:game, c, sys) when c in ~w(0 L), do: sys.loss
  defp trf_points(:game, "?", sys), do: Map.fetch!(sys, :unknown)

  defp result_of(pts, m) do
    cond do
      eq?(pts, m.win) -> :w
      eq?(pts, m.draw) -> :d
      true -> :l
    end
  end

  @doc """
  The model of a team event from a `%Ainalrami.Tiebreaks.Team{}`'s data
  (read field by field; nothing of the engine's is called). Two individual
  models - one scored in match points, one in game points - plus the boards.
  """
  def from_team(team) do
    kinds = %{
      played: :game,
      forfeit_win: :fwin,
      forfeit_loss: :floss,
      pab: :pab,
      full_bye: :fbye,
      half_bye: :hbye,
      zero_bye: :zbye
    }

    mp_pts = Map.new(team.match_points, fn {k, v} -> {k, v * 1.0} end)
    # Reading T1: in the game-point view a win is a win on every board.
    gp_pts = Map.new(team.game_points, fn {k, v} -> {k, v * team.boards * 1.0} end)

    view = fn which, pts ->
      players =
        Map.new(team.teams, fn {id, entry} ->
          rounds =
            for r <- 1..team.rounds//1, into: %{} do
              case Map.get(entry.rounds, r) do
                nil ->
                  {r, %{t: :zbye, opp: nil, col: nil, pts: 0.0, res: :l}}

                m ->
                  # Reading T1: the round's outcome is the MATCH's.
                  {r,
                   %{
                     t: Map.fetch!(kinds, m.kind),
                     opp: m.opponent,
                     col: nil,
                     pts: Map.fetch!(m, which) * 1.0,
                     res: result_of(m.mp * 1.0, mp_pts)
                   }}
              end
            end

          {id, %{tpn: entry.tpn, rating: nil, r: rounds}}
        end)

      Map.merge(%{win: pts.win, draw: pts.draw, loss: pts.loss}, %{
        n: team.rounds,
        total: max(team.total_rounds || team.rounds, team.rounds),
        rr?: team.predetermined?,
        ids: players |> Map.keys() |> Enum.sort(),
        p: players
      })
    end

    boards =
      Map.new(team.teams, fn {id, entry} ->
        per_round =
          for r <- 1..team.rounds//1 do
            case Map.get(entry.rounds, r) do
              nil ->
                %{}

              m ->
                # Article 12: a pairing-allocated bye scores a standard win on
                # every board. The text is silent on other unplayed matches;
                # the maintainer's decision (follow TieBreakServer there, Q3)
                # gives each its result on every board: a forfeit win or a
                # full-point bye a win, a half-point bye a draw, else nothing.
                cond do
                  m.boards != %{} ->
                    m.boards

                  m.kind in [:pab, :forfeit_win, :full_bye] ->
                    Map.new(1..team.boards, &{&1, team.game_points.win * 1.0})

                  m.kind == :half_bye ->
                    Map.new(1..team.boards, &{&1, team.game_points.draw * 1.0})

                  true ->
                    %{}
                end
            end
          end

        {id, per_round}
      end)

    %{
      team?: true,
      mp: view.(:mp, mp_pts),
      gp: view.(:gp, gp_pts),
      primary: team.primary,
      boards: team.boards,
      board_points: boards,
      mp_win: mp_pts.win,
      gp_win: team.game_points.win * 1.0
    }
  end

  @doc """
  The model of a team event read from a board-level TRF - `Ainalrami.Trf.parse/1`'s
  map, with `013` team records - by the reference's own reading, not
  `Ainalrami.Tiebreaks.Team.from_trf/2`'s:

    * teams are numbered in the order of their `013` records; a player's
      team is the record that lists them;
    * a team's round is the games its players had against somebody (a
      game, a forfeit win or a forfeit loss, classified as for individual
      events); the opponent is the team most of those opponents belong to;
      the boards are those games in the order the `013` record lists the
      players;
    * no game against anybody: a pairing-allocated bye if any of the
      players has one (a win on every board, the `362` record's `P` in match
      points, else a win's), otherwise a zero-point bye;
    * a match where some board was played over the board is won by the
      side with more game points and drawn when level; a match where none
      was (every board forfeited) is a forfeited match - lost by the side
      with fewer game points, both sides lost when neither scored, drawn
      when level on something (reading T8);
    * a `330` record forfeits a match neither team has games for, the
      winner taking a win on every board in game points;
    * match points from the `362` record (win, draw, loss, `A`/`Z` for a
      forfeited match; `320`, else `P`, for the pairing-allocated bye), else 2/1/0; game points from the `162` record;
    * the number of boards is the most games any team had in one round;
    * the pairings were fixed in advance when the `192` code names a round
      robin, Scheveningen or Schiller event.

  Options: `:primary` (`:mp` default, or `:gp`), `:rounds`.
  """
  def from_team_trf(trf, opts \\ []) do
    t = trf.tournament
    sys = Map.get(t, :point_system) || @trf_default
    declared = Map.get(t, :team_point_system) || %{}

    mp = %{
      win: Map.get(declared, :win, 2.0) * 1.0,
      draw: Map.get(declared, :draw, 1.0) * 1.0,
      loss: Map.get(declared, :loss, 0.0) * 1.0
    }

    # the 320 record's match points, else 362's P, else a win
    pab_mp =
      ((t[:team_pab] && t[:team_pab][:match_points]) || Map.get(declared, :pab, mp.win)) * 1.0

    forfeit_mp = Map.get(declared, :absent, mp.loss) * 1.0
    base = %{win: sys.win * 1.0, draw: sys.draw * 1.0, loss: sys.loss * 1.0}

    n =
      opts[:rounds] ||
        trf.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)

    rosters =
      trf.teams
      |> Enum.with_index(1)
      |> Enum.map(fn {tm, id} -> {Map.get(tm, :number) || id, tm.player_ranks} end)

    team_of = for {id, ranks} <- rosters, rank <- ranks, into: %{}, do: {rank, id}
    player = Map.new(trf.players, &{&1.rank, &1})

    # {team, round} => [round record] of its players, roster order
    seen = fn id, r ->
      {_, ranks} = List.keyfind(rosters, id, 0)

      for rank <- ranks, Map.has_key?(player, rank) do
        case Enum.at(player[rank].games, r - 1) do
          nil -> %{t: :zbye, opp: nil, pts: 0.0}
          g -> trf_round(g, sys, base)
        end
      end
    end

    boards =
      Enum.max(
        for {id, _} <- rosters, r <- 1..n//1 do
          Enum.count(seen.(id, r), & &1.opp)
        end,
        fn -> 1 end
      )
      |> max(1)

    # First pass: each side on its own.
    raw =
      for {id, _} <- rosters, r <- 1..n//1, into: %{} do
        rds = seen.(id, r)
        met = Enum.filter(rds, & &1.opp)
        # A 330 record outranks a bye the players' own codes suggest
        # (`0000 - +` is how 330 Note 1 credits the winner's players).
        declared = declared_forfeit(t, id, r)

        match =
          cond do
            met != [] ->
              opp =
                met
                |> Enum.map(&team_of[&1.opp])
                |> Enum.frequencies()
                |> Enum.sort_by(fn {team, k} -> {-k, team} end)
                |> hd()
                |> elem(0)

              board_map = met |> Enum.with_index(1) |> Map.new(fn {x, k} -> {k, x.pts} end)

              %{
                kind: if(Enum.any?(met, &(&1.t == :game)), do: :played, else: :unplayed),
                opponent: opp,
                gp: Enum.reduce(met, 0.0, &(&1.pts + &2)),
                boards: board_map
              }

            declared != nil ->
              declared

            Enum.any?(rds, &(&1.t == :pab)) ->
              %{
                kind: :pab,
                opponent: nil,
                mp: pab_mp,
                gp: base.win * boards,
                boards: Map.new(1..boards, &{&1, base.win})
              }

            true ->
              %{kind: :zero_bye, opponent: nil, mp: 0.0, gp: 0.0, boards: %{}}
          end

        {{id, r}, match}
      end

    # Second pass: match points from both sides.
    settle = fn id, r ->
      m = raw[{id, r}]

      case m do
        %{kind: :forfeit, winner?: true} ->
          %{
            kind: :forfeit_win,
            opponent: m.opponent,
            mp: mp.win,
            gp: base.win * boards,
            boards: %{}
          }

        %{kind: :forfeit, winner?: false} ->
          %{kind: :forfeit_loss, opponent: m.opponent, mp: forfeit_mp, gp: 0.0, boards: %{}}

        %{kind: kind} when kind in [:played, :unplayed] ->
          theirs = raw[{m.opponent, r}].gp

          {kind, pts} =
            cond do
              kind == :played and m.gp > theirs -> {:played, mp.win}
              kind == :played and m.gp < theirs -> {:played, mp.loss}
              kind == :played -> {:played, mp.draw}
              m.gp > theirs -> {:forfeit_win, mp.win}
              m.gp < theirs -> {:forfeit_loss, forfeit_mp}
              m.gp == 0.0 -> {:forfeit_loss, forfeit_mp}
              true -> {:played, mp.draw}
            end

          %{m | kind: kind} |> Map.put(:mp, pts)

        other ->
          other
      end
    end

    code = Map.get(t, :type_code)

    rr? =
      is_binary(code) and
        Enum.any?(~w(ROUNDROBIN SCHILLER SCHEVENINGEN), &String.contains?(code, &1))

    from_team(%{
      rounds: n,
      total_rounds: max(Map.get(t, :number_of_rounds) || n, n),
      predetermined?: rr?,
      boards: boards,
      primary: Keyword.get(opts, :primary, :mp),
      match_points: mp,
      game_points: base,
      teams:
        Map.new(rosters, fn {id, _} ->
          {id, %{tpn: id, rounds: Map.new(1..n//1, fn r -> {r, settle.(id, r)} end)}}
        end)
    })
  end

  # A 330 record for this team and round: %{kind: :forfeit, winner?:, opponent:}.
  defp declared_forfeit(t, id, r) do
    Enum.find_value(Map.get(t, :forfeited_matches) || [], fn f ->
      winner =
        case f.type |> to_string() |> String.trim() |> String.upcase() do
          x when x in ["+-", "10", "WL", "WZ"] -> :white
          x when x in ["-+", "01", "LW", "ZW"] -> :black
          x when x in ["--", "00", "LL", "ZZ"] -> :none
          _ -> :unknown
        end

      cond do
        winner == :unknown ->
          nil

        f.round == r and f.white == id ->
          %{kind: :forfeit, opponent: f.black, winner?: winner == :white, gp: 0.0}

        f.round == r and f.black == id ->
          %{kind: :forfeit, opponent: f.white, winner?: winner == :black, gp: 0.0}

        true ->
          nil
      end
    end)
  end

  # ======================================================================
  # Codes
  # ======================================================================

  @doc "Reads one code (`BH/C1`, `KS/L-1`, `SB:GP`, `ESB:MG`, ...)."
  def code(text) do
    [head | mods] = text |> String.trim() |> String.upcase() |> String.split("/")

    {name, score} =
      case String.split(head, ":") do
        [n] -> {n, nil}
        ["ESB", pair] when pair in ~w(MM MG GM GG) -> {"E" <> pair <> "SB", nil}
        [n, "MP"] -> {n, :mp}
        [n, "GP"] -> {n, :gp}
      end

    Enum.reduce(
      mods,
      %{
        name: name,
        score: score,
        low: 0,
        high: 0,
        limit: 0,
        rev: false,
        forfeits: false,
        fore: false,
        unrated: nil
      },
      fn
        "C" <> k, c ->
          %{c | low: String.to_integer(k)}

        "M" <> k, c ->
          %{c | low: String.to_integer(k), high: String.to_integer(k)}

        "L" <> k, c ->
          %{c | limit: String.to_integer(String.trim_leading(k, "+"))}

        "R", c ->
          %{c | rev: true}

        "P", c ->
          %{c | forfeits: true}

        "F", c ->
          %{c | fore: true}

        "U" <> k, c ->
          %{c | unrated: String.to_integer(k)}
      end
    )
  end

  # ======================================================================
  # Values
  # ======================================================================

  @doc """
  `%{id => value}` for one code, or `:dropped` (Article 10 with unrated
  participants and no `U` rating).
  """
  def values(%{team?: true} = tm, text), do: team_values(tm, code(text))
  def values(m, text), do: ind_values(m, code(text))

  defp each(m, fun), do: Map.new(m.ids, fn id -> {id, fun.(id)} end)
  defp rd(m, id, r), do: m.p[id].r[r]
  defp rounds(m), do: Enum.to_list(1..m.n//1)

  defp score(m, id), do: Enum.reduce(rounds(m), 0.0, fn r, acc -> acc + rd(m, id, r).pts end)

  # ---- Article 7 -------------------------------------------------------

  defp ind_values(m, %{name: "PTS"}), do: each(m, &score(m, &1))

  # 7.1: rounds with as many points as a win, with or without playing.
  defp ind_values(m, %{name: "WIN"}) do
    each(m, fn id -> Enum.count(rounds(m), &eq?(rd(m, id, &1).pts, m.win)) end)
  end

  # 7.2-7.4: over the board only (reading 9: also under 15.2).
  defp ind_values(m, %{name: "WON"}) do
    each(m, fn id ->
      Enum.count(rounds(m), fn r -> rd(m, id, r).t == :game and rd(m, id, r).res == :w end)
    end)
  end

  defp ind_values(m, %{name: "BPG"}) do
    each(m, fn id ->
      Enum.count(rounds(m), fn r -> rd(m, id, r).t == :game and rd(m, id, r).col == :black end)
    end)
  end

  defp ind_values(m, %{name: "BWG"}) do
    each(m, fn id ->
      Enum.count(rounds(m), fn r ->
        x = rd(m, id, r)
        x.t == :game and x.col == :black and x.res == :w
      end)
    end)
  end

  # 7.5, with 14.1.2 c: Cut-n leaves out the scores after the first n rounds.
  defp ind_values(m, %{name: "PS"} = c) do
    each(m, fn id ->
      after_each =
        for k <- rounds(m) do
          Enum.reduce(1..k, 0.0, fn r, acc -> acc + rd(m, id, r).pts end)
        end

      after_each |> Enum.drop(c.low) |> Enum.sum()
    end)
  end

  # 7.6
  defp ind_values(m, %{name: "REP"}) do
    each(m, fn id ->
      m.n - Enum.count(rounds(m), &(rd(m, id, &1).t in [:hbye, :zbye, :floss]))
    end)
  end

  # 7.7, reading 8: against the scheduled opponent's points that round;
  # without an opponent, against a draw's points.
  defp ind_values(m, %{name: "STD"}) do
    each(m, fn id ->
      Enum.reduce(rounds(m), 0.0, fn r, acc ->
        x = rd(m, id, r)
        other = if x.opp, do: rd(m, x.opp, r).pts, else: m.draw

        cond do
          eq?(x.pts, other) -> acc + 0.5
          x.pts > other -> acc + 1.0
          true -> acc
        end
      end)
    end)
  end

  defp ind_values(m, %{name: "TPN"}), do: each(m, &m.p[&1].tpn)

  # 10.6
  defp ind_values(m, %{name: "RTNG"} = c) do
    if dropped?(m, c), do: :dropped, else: each(m, &(m.p[&1].rating || c.unrated))
  end

  # ---- Articles 8, 9, 16 ---------------------------------------------

  # 8.1
  defp ind_values(m, %{name: "BH"} = c) do
    each(m, fn id -> m |> bh_elements(id) |> cut(c, :bh, m) |> sum_values() end)
  end

  # 8.3
  defp ind_values(m, %{name: "FB"} = c) do
    f = fore(m)
    each(m, fn id -> f |> bh_elements(id) |> cut(c, :bh, m) |> sum_values() end)
  end

  # 8.2: over opponents played over the board (a dummy has no Buchholz).
  defp ind_values(m, %{name: "AOB"} = c) do
    theirs = ind_values(m, code(if c.fore, do: "FB", else: "BH"))

    each(m, fn id ->
      list = for r <- rounds(m), rd(m, id, r).t == :game, do: theirs[rd(m, id, r).opp]
      if list == [], do: 0.0, else: Enum.sum(list) / length(list)
    end)
  end

  # 9.1
  defp ind_values(m, %{name: "SB"} = c) do
    each(m, fn id -> m |> sb_elements(m, id) |> cut(c, :sb, m) |> sum_values() end)
  end

  # 9.2 with 14.5 and reading 10.
  defp ind_values(m, %{name: "KS"} = c) do
    maximum =
      if m.rr? do
        # the rounds a participant could be scheduled against somebody
        m.ids
        |> Enum.map(fn id -> Enum.count(rounds(m), &(rd(m, id, &1).opp != nil)) end)
        |> Enum.max(fn -> 0 end)
        |> Kernel.*(m.win)
      else
        m.n * m.win
      end

    line = maximum / 2 + c.limit * 0.5
    scores = each(m, &score(m, &1))

    each(m, fn id ->
      Enum.reduce(rounds(m), 0.0, fn r, acc ->
        x = rd(m, id, r)

        if x.opp != nil and (scores[x.opp] > line or eq?(scores[x.opp], line)),
          do: acc + x.pts,
          else: acc
      end)
    end)
  end

  # ---- Article 10 -----------------------------------------------------

  defp ind_values(m, %{name: "ARO"} = c) do
    if dropped?(m, c) do
      :dropped
    else
      each(m, fn id ->
        ratings =
          m
          |> rated_games(id, c)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()
          |> Enum.drop(c.low)
          |> Enum.reverse()
          |> Enum.drop(c.high)

        average_half_up(ratings)
      end)
    end
  end

  defp ind_values(m, %{name: "TPR"} = c) do
    if dropped?(m, c), do: :dropped, else: each(m, &tpr(rated_games(m, &1, c)))
  end

  defp ind_values(m, %{name: "PTP"} = c) do
    if dropped?(m, c), do: :dropped, else: each(m, &ptp(rated_games(m, &1, c)))
  end

  defp ind_values(m, %{name: name} = c) when name in ~w(APRO APPO) do
    if dropped?(m, c) do
      :dropped
    else
      theirs = ind_values(m, %{c | name: if(name == "APRO", do: "TPR", else: "PTP")})

      each(m, fn id ->
        rounds(m)
        |> Enum.filter(&(rd(m, id, &1).t == :game))
        |> Enum.map(&theirs[rd(m, id, &1).opp])
        |> Enum.reject(&is_nil/1)
        |> average_half_up()
      end)
    end
  end

  # Article 10's opening paragraph.
  defp dropped?(m, c), do: c.unrated == nil and Enum.any?(m.ids, &(m.p[&1].rating == nil))

  # {opponent rating, game score} per game over the board; forfeits stay
  # unplayed here even under 15.2.
  defp rated_games(m, id, c) do
    for r <- rounds(m), x = rd(m, id, r), x.t == :game do
      {m.p[x.opp].rating || c.unrated, %{w: 2, d: 1, l: 0}[x.res]}
    end
  end

  # ---- elements, the dummy and the cuts ------------------------------

  # 16.1.2
  defp vur?(x), do: x.t in [:hbye, :zbye, :floss]

  # 16.2: the category of an unplayed round (nil for a game).
  defp category(m, id, r) do
    case rd(m, id, r).t do
      :game ->
        nil

      t when t in [:pab, :fbye] ->
        1

      :fwin ->
        2

      :floss ->
        4

      t when t in [:hbye, :zbye] ->
        later = for k <- (r + 1)..m.n//1, do: rd(m, id, k)
        if Enum.any?(later, &(not vur?(&1))), do: 3, else: 5
    end
  end

  # 16.3: the score as the participant's OPPONENTS' tie-breaks see it.
  defp adjusted(m, id) do
    Enum.reduce(rounds(m), 0.0, fn r, acc ->
      if category(m, id, r) == 5, do: acc + m.draw, else: acc + rd(m, id, r).pts
    end)
  end

  # 16.4: the dummy of round r, with reading 5 (own actual score) and
  # reading 11 (16.4.2's rounds are the rounds the standings count).
  defp dummy(m, id, r) do
    own = score(m, id)

    limit =
      if category(m, id, r) in [2, 4],
        do: adjusted(m, rd(m, id, r).opp),
        else: m.draw * m.n

    min(own, limit)
  end

  # The opponent's score a round contributes: the adjusted score for a game,
  # the dummy for an unplayed round (Swiss, Article 16); with pairings fixed
  # in advance (15.2) forfeits are games and nothing is adjusted, and a round
  # without an opponent is not an element at all.
  defp counted_rounds(m, id) do
    if m.rr?, do: Enum.filter(rounds(m), &(rd(m, id, &1).opp != nil)), else: rounds(m)
  end

  defp opponent_value(m, id, r) do
    x = rd(m, id, r)

    cond do
      m.rr? -> score(m, x.opp)
      x.t == :game -> adjusted(m, x.opp)
      true -> dummy(m, id, r)
    end
  end

  defp bh_elements(m, id) do
    for r <- counted_rounds(m, id) do
      s = opponent_value(m, id, r)
      %{r: r, value: s, key: s, vur: vur?(rd(m, id, r))}
    end
  end

  # `first` scores the opponents, `second` the points against them (the
  # same model for SB; 13.2's extended SB mixes the two team views).
  defp sb_elements(first, second, id) do
    for r <- counted_rounds(first, id) do
      s = opponent_value(first, id, r)
      %{r: r, value: s * rd(second, id, r).pts, key: s, vur: vur?(rd(first, id, r))}
    end
  end

  defp sum_values(elements), do: Enum.reduce(elements, 0.0, &(&1.value + &2))

  # Article 14 with 16.5. The least significant value: for Buchholz the
  # lowest element; for Sonneborn-Berger the contribution of the opponent
  # with the lowest score, the lowest such contribution among several
  # (14.1.2 d). In a Swiss event with VURs left, 16.5 cuts the lowest VUR
  # contribution when it is not lower than the least significant value -
  # "cut the higher of these two values". Medians: least first (14.3).
  defp cut(elements, c, notion, m) do
    swiss? = not m.rr?
    after_low = Enum.reduce(1..c.low//1, elements, fn _, els -> cut_low(els, notion, swiss?) end)
    Enum.reduce(1..c.high//1, after_low, fn _, els -> cut_high(els, notion) end)
  end

  defp cut_low([], _notion, _swiss?), do: []

  defp cut_low(els, notion, swiss?) do
    least = least_significant(els, notion)
    vurs = if swiss?, do: Enum.filter(els, & &1.vur), else: []

    victim =
      case Enum.sort_by(vurs, & &1.value) do
        [lowest_vur | _] ->
          if lowest_vur.value > least.value or eq?(lowest_vur.value, least.value),
            do: lowest_vur,
            else: least

        [] ->
          least
      end

    Enum.reject(els, &(&1.r == victim.r))
  end

  defp cut_high([], _notion), do: []

  defp cut_high(els, notion) do
    most =
      case notion do
        :bh -> els |> Enum.sort_by(& &1.value) |> List.last()
        :sb -> els |> Enum.sort_by(&{&1.key, &1.value}) |> List.last()
      end

    Enum.reject(els, &(&1.r == most.r))
  end

  defp least_significant(els, :bh), do: els |> Enum.sort_by(& &1.value) |> hd()
  defp least_significant(els, :sb), do: els |> Enum.sort_by(&{&1.key, &1.value}) |> hd()

  # 8.3: every paired game of the final round drawn - once the event's
  # final round is among the rounds counted.
  defp fore(m) do
    if m.n == 0 or m.n < m.total do
      m
    else
      p =
        Map.new(m.p, fn {id, pl} ->
          x = pl.r[m.n]

          x =
            if x.t in [:game, :fwin, :floss],
              do: %{x | t: :game, pts: m.draw, res: :d},
              else: x

          {id, %{pl | r: Map.put(pl.r, m.n, x)}}
        end)

      %{m | p: p}
    end
  end

  # ======================================================================
  # Rating arithmetic (FIDE Rating Regulations 8.1), transcribed afresh
  # ======================================================================

  # dp for p = 1.00, 0.99, ..., 0.50 (8.1.1); below 0.50 it is -dp(1 - p).
  @dp_from_top [800, 677, 589, 538, 501, 470, 444, 422, 401, 383] ++
                 [366, 351, 336, 322, 309, 296, 284, 273, 262, 251] ++
                 [240, 230, 220, 211, 202, 193, 184, 175, 166, 158] ++
                 [149, 141, 133, 125, 117, 110, 102, 95, 87, 80] ++
                 [72, 65, 57, 50, 43, 36, 29, 21, 14, 7, 0]

  defp dp(pct) when pct >= 50, do: Enum.at(@dp_from_top, 100 - pct)
  defp dp(pct), do: -dp(100 - pct)

  # 8.1.2: the lowest difference of each band and the higher-rated player's
  # expected score in hundredths; above 735 it is 1.00 (full scale, 10.3).
  @bands [
    {0, 50},
    {4, 51},
    {11, 52},
    {18, 53},
    {26, 54},
    {33, 55},
    {40, 56},
    {47, 57},
    {54, 58},
    {62, 59},
    {69, 60},
    {77, 61},
    {84, 62},
    {92, 63},
    {99, 64},
    {107, 65},
    {114, 66},
    {122, 67},
    {130, 68},
    {138, 69},
    {146, 70},
    {154, 71},
    {163, 72},
    {171, 73},
    {180, 74},
    {189, 75},
    {198, 76},
    {207, 77},
    {216, 78},
    {226, 79},
    {236, 80},
    {246, 81},
    {257, 82},
    {268, 83},
    {279, 84},
    {291, 85},
    {303, 86},
    {316, 87},
    {329, 88},
    {345, 89},
    {358, 90},
    {375, 91},
    {392, 92},
    {412, 93},
    {433, 94},
    {457, 95},
    {485, 96},
    {518, 97},
    {560, 98},
    {620, 99},
    {736, 100}
  ]

  # The band of each difference 0..736, looked up rather than searched (PTP
  # asks thousands of times); 736 stands for every difference above 735.
  @by_difference (for d <- 0..736 do
                    {_, h} = @bands |> Enum.filter(fn {from, _} -> d >= from end) |> List.last()
                    h
                  end)
                 |> List.to_tuple()

  defp expected(own, opp) do
    d = own - opp
    h = elem(@by_difference, min(abs(d), 736))
    if d >= 0, do: h, else: 100 - h
  end

  # "rounded to the nearest whole number (0.5 rounded up)", in integers.
  defp average_half_up([]), do: nil

  defp average_half_up(list) do
    k = length(list)
    Integer.floor_div(2 * Enum.sum(list) + k, 2 * k)
  end

  # 10.2: ARO + dp(p), p the percentage score over the games, rounded half
  # up (games are {rating, half-points}).
  defp tpr([]), do: nil

  defp tpr(games) do
    g = length(games)
    halves = games |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    pct = Integer.floor_div(halves * 100 + g, 2 * g)
    average_half_up(Enum.map(games, &elem(&1, 0))) + dp(pct)
  end

  # 10.3 with reading 7: the lowest whole rating whose expected score
  # reaches the score in the games; 800 under the lowest opponent for zero.
  defp ptp([]), do: nil

  defp ptp(games) do
    ratings = Enum.map(games, &elem(&1, 0))
    target = (games |> Enum.map(&elem(&1, 1)) |> Enum.sum()) * 50

    if target == 0 do
      Enum.min(ratings) - 800
    else
      Stream.iterate(Enum.min(ratings) - 800, &(&1 + 1))
      |> Enum.find(fn own -> Enum.sum(Enum.map(ratings, &expected(own, &1))) >= target end)
    end
  end

  # ======================================================================
  # Teams (Articles 11-13)
  # ======================================================================

  defp other(:mp), do: :gp
  defp other(:gp), do: :mp

  defp team_values(tm, %{name: "PTS"}), do: ind_values(tm[tm.primary], code("PTS"))
  defp team_values(tm, %{name: "MPTS"}), do: ind_values(tm.mp, code("PTS"))
  defp team_values(tm, %{name: "GPTS"}), do: ind_values(tm.gp, code("PTS"))
  defp team_values(tm, %{name: "MPVGP"}), do: ind_values(tm[other(tm.primary)], code("PTS"))

  # 13.2: the opponent's total in the first score times the points scored
  # against them in the second; Cut-1 by the opponent lowest in the FIRST
  # score (14.1's team paragraph), with 16.5.
  defp team_values(tm, %{name: <<"E", a, b, "SB">>} = c) when a in ~c"MG" and b in ~c"MG" do
    first = if a == ?M, do: tm.mp, else: tm.gp
    second = if b == ?M, do: tm.mp, else: tm.gp

    each(first, fn id ->
      first |> sb_elements(second, id) |> cut(c, :sb, first) |> sum_values()
    end)
  end

  # 13.4
  defp team_values(tm, %{name: "SSSC"} = c) do
    primary = tm[tm.primary]
    bh = ind_values(primary, code(if c.fore, do: "FB", else: "BH"))
    highest_primary = primary.n * primary.win

    highest_secondary_match =
      if tm.primary == :mp, do: tm.boards * tm.gp_win, else: tm.mp_win

    divisor = max(trunc(highest_primary / highest_secondary_match), 1)
    secondary = ind_values(tm[other(tm.primary)], code("PTS"))
    Map.new(bh, fn {id, v} -> {id, secondary[id] + v / divisor} end)
  end

  # Articles 6-10 on the named score, or the primary (reading T2).
  defp team_values(tm, c), do: ind_values(tm[c.score || tm.primary], c)

  # ======================================================================
  # Ranking (4.2) and the group tie-breaks (6, 12, 13.3)
  # ======================================================================

  @group_codes ~w(DE EDE EDEBT EDEBB EDET EDEB BC TBR BBE)

  @doc """
  The final ranks for a tie-break list: `%{id => rank}`, participants still
  tied after the list sharing a rank. The score comes first unless the list
  starts with one; Article 10 codes that are dropped are skipped.
  """
  def rank(model, texts) do
    model = for_list(model, texts)
    codes = Enum.map(texts, &code/1)

    codes =
      if hd(codes).name in ~w(PTS MPTS GPTS), do: codes, else: [code("PTS") | codes]

    codes = Enum.reject(codes, &(values_or_group(model, &1) == :dropped))
    ids = if model[:team?], do: model.mp.ids, else: model.ids
    groups = order([ids], codes, model)

    {ranks, _} =
      Enum.reduce(groups, {%{}, 1}, fn g, {acc, next} ->
        {Enum.reduce(g, acc, &Map.put(&2, &1, next)), next + length(g)}
      end)

    ranks
  end

  @doc """
  The model as a tie-break list `texts` reads it (reading T5): a team list
  whose first code is `MPTS` or `GPTS` names the primary score - the event's
  regulations choosing it - and every code without `:MP`/`:GP` follows.
  Anything else leaves the model as it is.
  """
  def for_list(%{team?: true} = tm, [first | _]) do
    case code(first).name do
      "MPTS" -> %{tm | primary: :mp}
      "GPTS" -> %{tm | primary: :gp}
      _ -> tm
    end
  end

  def for_list(model, _texts), do: model

  defp values_or_group(_model, %{name: name}) when name in @group_codes, do: :group
  defp values_or_group(%{team?: true} = tm, c), do: team_values(tm, c)
  defp values_or_group(m, c), do: ind_values(m, c)

  defp order(groups, [], _model), do: groups

  defp order(groups, [c | rest], model) do
    groups
    |> Enum.flat_map(fn
      [_] = g -> [g]
      g -> split(g, c, model)
    end)
    |> order(rest, model)
  end

  defp split(g, %{name: "DE"} = c, %{team?: true} = tm),
    do: de(tm[c.score || tm.primary], g, c.forfeits)

  defp split(g, %{name: "DE"} = c, m), do: de(m, g, c.forfeits)

  defp split(g, %{name: "EDE" <> variant} = c, tm) do
    g |> ede(c.forfeits, tm) |> Enum.flat_map(&knockout(&1, variant, tm))
  end

  defp split(g, %{name: "BC"}, tm), do: board_count(g, tm)
  defp split(g, %{name: "TBR"}, tm), do: top_board(g, 1, tm)
  defp split(g, %{name: "BBE"}, tm), do: bottom_board(g, tm.boards - 1, tm)

  defp split(g, c, model) do
    vals = values_or_group(model, c)
    # higher first, except TPN (7.8); R reverses TPN and RTNG
    ascending? = c.name == "TPN" != c.rev

    g
    |> Enum.group_by(&sort_key(vals[&1]))
    |> Enum.sort_by(fn {k, _} -> k end, if(ascending?, do: :asc, else: :desc))
    |> Enum.map(fn {_, members} -> Enum.sort(members) end)
  end

  # no value (no games to average) ranks below every value
  defp sort_key(nil), do: -1_000_000_000_000_000
  defp sort_key(v), do: round(v * 1_000_000)

  # ---- Article 6 ------------------------------------------------------

  @doc false
  def de(_m, [_] = g, _forfeits?), do: [g]
  def de(_m, [], _forfeits?), do: []

  def de(m, g, forfeits?) do
    # 6.1.1: forfeits count when P says so, or when 15.2 makes them games.
    counted? = fn x -> x.t == :game or (x.t in [:fwin, :floss] and (forfeits? or m.rr?)) end

    games =
      for a <- g, r <- rounds(m), x = rd(m, a, r), x.opp in g, x.opp != a, counted?.(x) do
        {{a, x.opp}, x.pts}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # 6.1.2: two who met more than once add the average of those games.
    sep =
      Map.new(g, fn a ->
        {a,
         Enum.reduce(g, 0.0, fn b, acc ->
           case games[{a, b}] do
             nil -> acc
             list -> acc + Enum.sum(list) / length(list)
           end
         end)}
      end)

    missing = for a <- g, b <- g, a < b, not Map.has_key?(games, {a, b}), do: {a, b}

    cond do
      missing == [] ->
        # 6.2
        groups =
          g
          |> Enum.group_by(&sort_key(sep[&1]))
          |> Enum.sort_by(fn {k, _} -> k end, :desc)
          |> Enum.map(fn {_, members} -> Enum.sort(members) end)

        if length(groups) == 1, do: [g], else: Enum.flat_map(groups, &de(m, &1, forfeits?))

      m.rr? ->
        [g]

      true ->
        # 6.3
        {ranked, rest} = peel(g, sep, missing, m, [])

        case ranked do
          [] -> [g]
          _ -> Enum.map(ranked, &[&1]) ++ de(m, rest, forfeits?)
        end
    end
  end

  # 6.3: who is alone at the top of the separate standings whatever the
  # missing games' results are. Enumerated outright when there are at most
  # eight missing games (3^8 outcomes); above that, reading 6's closed form
  # (a candidate's every-missing-game-lost total above every rival's
  # every-missing-game-won total).
  defp peel(candidates, sep, missing, m, ranked) do
    alone =
      Enum.find(candidates, fn c ->
        rivals = candidates -- [c]

        if length(missing) <= 8 do
          Enum.all?(outcomes(missing, m), fn extra ->
            mine = sep[c] + Map.get(extra, c, 0.0)

            Enum.all?(rivals, fn x ->
              theirs = sep[x] + Map.get(extra, x, 0.0)
              mine > theirs and not eq?(mine, theirs)
            end)
          end)
        else
          count = fn id -> Enum.count(missing, fn {a, b} -> a == id or b == id end) end
          worst = sep[c] + count.(c) * m.loss

          Enum.all?(rivals, fn x ->
            best = sep[x] + count.(x) * m.win
            worst > best and not eq?(worst, best)
          end)
        end
      end)

    case alone do
      nil -> {Enum.reverse(ranked), candidates}
      c -> peel(candidates -- [c], sep, missing, m, [c | ranked])
    end
  end

  # Every assignment of win / draw / loss to the missing games, as the
  # points it adds to each participant.
  defp outcomes([], _m), do: [%{}]

  defp outcomes([{a, b} | rest], m) do
    for tail <- outcomes(rest, m),
        {pa, pb} <- [{m.win, m.loss}, {m.draw, m.draw}, {m.loss, m.win}] do
      tail |> Map.update(a, pa, &(&1 + pa)) |> Map.update(b, pb, &(&1 + pb))
    end
  end

  # ---- 13.3 -----------------------------------------------------------

  # 13.3.1 / 13.3.3: Article 6 on the primary score; if no tie is broken,
  # on the secondary; every new subset starts again from the primary.
  defp ede([_] = g, _f, _tm), do: [g]

  defp ede(g, f, tm) do
    by_primary = de(tm[tm.primary], g, f)
    result = if by_primary == [g], do: de(tm[other(tm.primary)], g, f), else: by_primary

    if result == [g], do: [g], else: Enum.flat_map(result, &ede(&1, f, tm))
  end

  # 13.3.2 with reading T3: EDEBT = BC, TBR; EDEBB = BC, BBE; EDET = TBR;
  # EDEB = BBE - only for exactly two teams level in both scores.
  defp knockout([a, b] = pair, variant, tm) do
    mp = ind_values(tm.mp, code("PTS"))
    gp = ind_values(tm.gp, code("PTS"))

    steps =
      %{"BT" => ["BC", "TBR"], "BB" => ["BC", "BBE"], "T" => ["TBR"], "B" => ["BBE"]}
      |> Map.get(variant, [])

    if eq?(mp[a], mp[b]) and eq?(gp[a], gp[b]),
      do: order([pair], Enum.map(steps, &code/1), tm),
      else: [pair]
  end

  defp knockout(g, _variant, _tm), do: [g]

  # Article 12, reading T4: over every match of the tournament.
  defp board_total(tm, id, fun) do
    for per_round <- tm.board_points[id], {board, gp} <- per_round, reduce: 0.0 do
      acc -> acc + fun.(board, gp)
    end
  end

  # 12.1: lower is better; only when every tied team has the same GP.
  defp board_count(g, tm) do
    gp = ind_values(tm.gp, code("PTS"))

    if g |> Enum.map(&sort_key(gp[&1])) |> Enum.uniq() |> length() > 1 do
      [g]
    else
      g
      |> Enum.group_by(&sort_key(board_total(tm, &1, fn board, pts -> board * pts end)))
      |> Enum.sort_by(fn {k, _} -> k end, :asc)
      |> Enum.map(fn {_, members} -> Enum.sort(members) end)
    end
  end

  # 12.2: board k; teams still level go on to board k + 1.
  defp top_board(g, k, tm) when k > tm.boards or length(g) < 2, do: [g]

  defp top_board(g, k, tm) do
    g
    |> Enum.group_by(&sort_key(board_total(tm, &1, fn b, pts -> if b == k, do: pts, else: 0 end)))
    |> Enum.sort_by(fn {key, _} -> key end, :desc)
    |> Enum.flat_map(fn {_, members} -> top_board(Enum.sort(members), k + 1, tm) end)
  end

  # 12.3: boards 1..k; teams still level go on to 1..k-1.
  defp bottom_board(g, k, _tm) when k < 1 or length(g) < 2, do: [g]

  defp bottom_board(g, k, tm) do
    g
    |> Enum.group_by(&sort_key(board_total(tm, &1, fn b, pts -> if b <= k, do: pts, else: 0 end)))
    |> Enum.sort_by(fn {key, _} -> key end, :desc)
    |> Enum.flat_map(fn {_, members} -> bottom_board(Enum.sort(members), k - 1, tm) end)
  end

  defp eq?(a, b), do: abs(a - b) < 1.0e-9
end

defmodule Ainalrami.Test.TeamThreeWay do
  @moduledoc """
  The pieces of `Ainalrami.TeamThreeWayTest` that are not the comparison
  itself: what a seed's event looks like, the file as it stood before a
  round was paired, and Ainalrami's own answer to that file.

  Kept apart from the test so a probe (`mix run`) can rebuild one dumped
  round without running the harness.
  """

  alias Ainalrami.{TeamCLI, TeamGenerator, TeamReplay, Trf}

  # ---- the event a seed generates -------------------------------------------

  @doc """
  The `Ainalrami.TeamGenerator` options for `seed`, drawn from the seed and
  the axis's environment. Every knob is drawn here rather than left to the
  generator, so the generator's own random stream starts from the same
  place whatever the axis, and so the settings can be printed beside a dump.

  Only settings all three engines can be told are drawn:

    * `:type` - `:a` or `:b`. `:none` is left out: FIDE's code table writes
      it as `FIDE_TEAM_MP_GP`, which Gacrux reads as no colour preferences
      and chesspairing as Type A (its `codedTeamOptions` defaults a code
      without `TYPE` to A).
    * `:use_secondary?` - always true. chesspairing reads only the first
      score word of the `192` code; its `secondaryScoreForColour` option is
      not reachable from a TRF or its command line.
    * `:pab` - a draw unless `TEAM3_PAB` says otherwise. chesspairing scores
      a pairing-allocated bye as a drawn match whatever the `320` record
      says, so a won PAB is a known difference, not a finding.
  """
  def options(seed) do
    :rand.seed(:exsss, {seed, 104_729, seed * 31 + 7})

    teams = pick_range("TEAM3_TEAMS", 4..40)
    teams = maybe_parity(teams)
    rounds = pick_range("TEAM3_ROUNDS", 5..11)

    [
      seed: seed,
      system: :swiss,
      teams: teams,
      rounds: rounds,
      boards: pick_list("TEAM3_BOARDS", [2, 4, 6]),
      reserves: pick_list("TEAM3_RESERVES", [0, 1, 2]),
      type: pick_list("TEAM3_TYPE", [:a, :b]),
      score_mode: pick_list("TEAM3_SCORE", [:match_points, :game_points]),
      use_secondary?: true,
      initial_colour: pick_list("TEAM3_INITIAL_COLOUR", [:white, :black]),
      match_points: pick_list("TEAM3_MATCH_POINTS", [{2, 1, 0}, {3, 1, 0}]),
      pab: pick_list("TEAM3_PAB", [:draw]),
      board_forfeit_pct: pick_list("TEAM3_BOARD_FORFEIT_PCT", [0]),
      match_forfeit_pct: pick_list("TEAM3_MATCH_FORFEIT_PCT", [0]),
      absent_team_pct: pick_list("TEAM3_ABSENT_TEAM_PCT", [0]),
      absent_player_pct: pick_list("TEAM3_ABSENT_PLAYER_PCT", [0]),
      withdraw_pct: pick_list("TEAM3_WITHDRAW_PCT", [0]),
      out_of_order_pct: pick_list("TEAM3_OUT_OF_ORDER_PCT", [0]),
      tie_breaks: nil
    ]
  end

  # `TEAM3_PARITY=even|odd` forces the team count's parity (the PAB axis);
  # anything else leaves it as drawn.
  defp maybe_parity(n) do
    case System.get_env("TEAM3_PARITY") do
      "even" when rem(n, 2) == 1 -> n + 1
      "odd" when rem(n, 2) == 0 -> n + 1
      _ -> n
    end
  end

  # "4-40" or "4"
  defp pick_range(var, default) do
    range =
      case System.get_env(var) do
        nil ->
          default

        text ->
          case String.split(text, "-") |> Enum.map(&String.to_integer/1) do
            [a, b] -> a..b
            [a] -> a..a
          end
      end

    Enum.random(range)
  end

  # "2,4,6"; atoms and `2/1/0` triples by name.
  defp pick_list(var, default) do
    choices =
      case System.get_env(var) do
        nil -> default
        text -> text |> String.split(",") |> Enum.map(&value/1)
      end

    Enum.random(choices)
  end

  defp value("a"), do: :a
  defp value("b"), do: :b
  defp value("mp"), do: :match_points
  defp value("gp"), do: :game_points
  defp value("white"), do: :white
  defp value("black"), do: :black
  defp value("draw"), do: :draw
  defp value("win"), do: :win

  defp value(text) do
    case String.split(text, "/") do
      [w, d, l] -> {String.to_integer(w), String.to_integer(d), String.to_integer(l)}
      [n] -> String.to_integer(n)
    end
  end

  @doc "Generates the event: `Ainalrami.TeamGenerator.run/1`'s map."
  def generate(seed), do: TeamGenerator.run(options(seed))

  # ---- the file before round k ------------------------------------------------

  @doc """
  The file as it stood before round `k` was paired: the rounds before it,
  and of round `k` only what is known before a pairing exists - the players
  and teams announced absent (`Z`). Not round `k`'s `300` lineups: they
  name the opponent, which is the answer. The `310` totals, final ranks and
  each player's points are what the kept rounds give, not the whole event's,
  so no reader can take a score from the future.

  Same cut as `Ainalrami.TeamCLITest`'s, minus round `k`'s `300` records.
  """
  def cut(text, k, announced? \\ true) do
    parsed = Trf.parse(text)

    players =
      Enum.map(parsed.players, fn p ->
        earlier = Enum.take(p.games, k - 1)

        games =
          case Enum.at(p.games, k - 1) do
            %{opponent_rank: nil, result: "Z"} = g when announced? -> earlier ++ [g]
            _ -> earlier
          end

        %{p | games: games, points: earlier |> Enum.map(&points(&1.result)) |> Enum.sum()}
      end)

    t =
      parsed.tournament
      |> Map.drop([:standings_order, :tie_breaks, :byes])
      |> Map.update(:forfeited_matches, nil, fn l -> l && Enum.filter(l, &(&1.round < k)) end)
      |> Map.update(:board_orders, nil, fn l -> l && Enum.filter(l, &(&1.round < k)) end)
      |> Map.update(:team_pab, nil, fn p -> p && %{p | teams: Enum.take(p.teams, k - 1)} end)
      |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
      |> Map.new()

    teams = Enum.map(parsed.teams, &Map.drop(&1, [:final_rank, :match_points, :game_points]))
    Trf.serialize(%{parsed | players: players, tournament: t, teams: teams}, dialect: :trf26)
  end

  @doc """
  `cut/2`, then rewritten into the one form all three readers take - the
  file every engine is given, Ainalrami included. Two records differ
  between the readers, found by feeding them Ainalrami's own output
  (2026-11-07):

    * `362`. Ainalrami writes one-letter symbols in column 6
      (`362  W 2.0    D 1.0 ...`, plus `P` and `A`); chesspairing accepts
      only `TW`/`TD`/`TL` and rejects the file ("invalid team scoring
      symbol"). Ainalrami and Gacrux both read the symbol from column 6, so
      `362 TW 2.0   TD 1.0   TL 0.0` reads the same in all three. The
      dropped `P` is in the `320` record (the bye's match and game points),
      and `A` is the generator's default, a loss.
    * `352`. Without it chesspairing counts reserves as boards when it
      scores a bye (with reserves on the rosters it disagreed on about one
      round in seven; with `352`, none); Gacrux reads the board count from
      it too. Ainalrami writes it itself since 0.56.0; a file without one
      gets `WBWB...` of the board count (1.6.1), a file with one is left
      alone.
    * `240`. Ainalrami's TRF26 writer lifts a trailing `Z` (an absence
      announced for the round not yet paired) out of the `001` line into a
      `240 Z` record of PLAYER numbers. Gacrux reads a `240` in a team file
      as TEAM numbers and refuses the file (`### Error 401`, "Record 240
      names team 27, the tournament has 11 teams").

  And there is no form of round `k`'s own `Z` that all three read the
  same way. Put back into round `k`'s `001` column, Gacrux refuses round 1
  (`### Error 502`) and in later rounds leaves out teams that have only a
  reserve absent, and chesspairing refuses the file ("unknown or inactive
  player 18": it takes the player-level byes it stages for the unpaired
  round as team numbers). So the file given to the engines says nothing
  about round `k`: every team is in its field. A team the generator had
  sitting round `k` out is paired like the rest - by all three, so the
  comparison is still like for like - and its absence shows up in the
  history of every later round, which is where absent teams and
  withdrawals are tested. The price is the self-check against the
  generator's own pairing, which only holds for rounds nobody sat out.
  """
  def file_for(text, k, boards), do: text |> cut(k, false) |> portable(k, boards)

  def portable(text, k, boards) do
    lines = String.split(text, "\r\n")
    has_352? = Enum.any?(lines, &String.starts_with?(&1, "352"))

    absent =
      for "240 Z" <> _ = line <- lines,
          String.slice(line, 6, 3) |> String.to_integer() == k,
          rank <- line |> String.slice(9..-1//1) |> String.split(),
          into: MapSet.new(),
          do: String.to_integer(rank)

    stray = for "240" <> _ = line <- lines, not String.starts_with?(line, "240 Z"), do: line
    if stray != [], do: raise(ArgumentError, "unexpected 240 records: #{inspect(stray)}")

    lines
    |> Enum.reject(&String.starts_with?(&1, "240"))
    |> Enum.flat_map(fn
      "362" <> _ = line ->
        if has_352?,
          do: [team_points(line)],
          else: [team_points(line), "352 " <> board_colours(boards)]

      "001" <> _ = line ->
        rank = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()

        if MapSet.member?(absent, rank),
          do: [String.pad_trailing(line, 91 + (k - 1) * 10) <> "0000 - Z"],
          else: [line]

      line ->
        [line]
    end)
    |> Enum.join("\r\n")
  end

  # C.04.6 1.6.1: the first team has White on the odd boards.
  defp board_colours(boards), do: "WB" |> String.duplicate(boards) |> String.slice(0, boards)

  defp team_points(line) do
    points =
      for {symbol, col} <- [{"W", 5}, {"D", 14}, {"L", 23}] do
        unless String.at(line, col) == symbol,
          do: raise(ArgumentError, "362 not in the expected layout: #{inspect(line)}")

        {symbol, String.slice(line, col + 1, 4)}
      end

    "362 " <> Enum.map_join(points, "   ", fn {s, p} -> "T" <> s <> p end)
  end

  @board_points %{"1" => 1.0, "=" => 0.5, "+" => 1.0, "U" => 1.0}
  defp points(result), do: Map.get(@board_points, result, 0.0)

  @doc """
  The teams with every player `Z` in round `k` of the cut file: the teams
  sitting the round out, as the file says it before the pairing.
  """
  def absent_teams(cut_text, k) do
    parsed = Trf.parse(cut_text)
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    for team <- parsed.teams,
        ranks = team.player_ranks || [],
        ranks != [],
        Enum.all?(ranks, fn rank ->
          match?(%{result: "Z"}, Enum.at(by_rank[rank].games, k - 1))
        end),
        do: team.number
  end

  # ---- Ainalrami on the cut file ---------------------------------------------

  @doc """
  Ainalrami's answer for the cut file, through the path `ainalrami file -p`
  takes (`TeamReplay.system/1`, `TeamCLI.pair/3`): `{:ok, %{matches:,
  bye:}}`, `:refused` when the engine finds no legal pairing, or
  `{:error, message}` for anything else.
  """
  def ainalrami(cut_text) do
    parsed = Trf.parse(cut_text)

    case TeamReplay.system(parsed) do
      {:team, _} = system ->
        case TeamCLI.pair(parsed, system) do
          {:ok, round} ->
            {:ok, %{matches: round.matches, bye: round.bye}}

          {:error, message} ->
            if message =~ "no pairing", do: :refused, else: {:error, message}
        end

      other ->
        {:error, "not a team Swiss to this reader: #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
  end

  # ---- comparing ---------------------------------------------------------------

  @doc """
  An engine's list output (`count`, then `white black` per match, `team 0`
  for the bye) as `%{matches:, bye:}`. The Gacrux wrapper already gives
  `[{white, black | nil}]`.
  """
  def from_pairs(pairs) do
    {byes, matches} = Enum.split_with(pairs, fn {_w, b} -> is_nil(b) end)

    case byes do
      [] -> {:ok, %{matches: matches, bye: nil}}
      [{t, nil}] -> {:ok, %{matches: matches, bye: t}}
      _ -> {:error, "more than one bye: #{inspect(byes)}"}
    end
  end

  @doc "Who plays whom, and who has the bye - colour-blind."
  def composition(%{matches: matches, bye: bye}),
    do: {matches |> Enum.map(fn {w, b} -> Enum.sort([w, b]) end) |> Enum.sort(), bye}

  @doc "The same, with each match's first team (White on board 1)."
  def oriented(%{matches: matches, bye: bye}), do: {Enum.sort(matches), bye}
end

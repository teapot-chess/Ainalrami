defmodule Ainalrami.TeamReplay do
  @moduledoc """
  The checker's round replay (`ainalrami input.trf -c`) for a team event:
  each team round re-paired with `Ainalrami.TeamPairing` (C.04.6) from the
  history the file records before it, and compared with the pairing the
  file actually has.

  The individual replay lives in `Ainalrami.CLI` and pairs players with
  `Ainalrami.Pairing`; on a team file that compared the players' boards
  with a Dutch-system pairing of individuals, found every round different
  and exited 1. This module is the team half, and `system/1` is what tells
  the two apart.

  ## Which replay (`system/1`)

  The `192` type code decides, read by `Ainalrami.TypeCode` against FIDE's
  Tournament Type Code Table:

    * the Dutch system (`FIDE_DUTCH`, `FIDE_DUTCH_2017`, `FIDE_DUTCH_2025`)
      - the individual replay, whatever team records the file has: an
      individual open routinely lists club teams in `013` lines for a team
      prize. Accelerated (`FIDE_DUTCH*_BAKU`) the same, when the file gives
      the virtual points (`XXA` or `250`), which the engine pairs with; a
      Baku file without them is unreplayable, since the engine does not
      derive C.04.7's groups itself.
    * a C.04.6 team Swiss (`FIDE_TEAM`, `FIDE_TEAM_TYPEA_MP_GP`,
      `FIDE_TEAM_MP`, ...) - the team replay, with the settings the code
      names (below);
    * a team round robin by the Berger tables (`BERGER_TEAM_ROUNDROBIN_Gn`
      and its aliases) - `{:team_round_robin, %{games: n, code:}}`, compared
      with `Ainalrami.Berger` (`check_round_robin/3`);
    * an individual round robin (`BERGER_ROUNDROBIN_Gn` and its aliases,
      `FIDE_DOUBLEROUNDROBIN`) - `{:round_robin, %{games: n,
      reverse_last_two?:, code:}}`, read by `Ainalrami.RoundRobin`;
    * everything else is `{:unreplayable, reason}`: Schiller and Scheveningen (predetermined, by rules FIDE has not yet
      defined), knockouts, the Double Swiss systems (`Ainalrami.CLI` sends a
      Dubov or Burstein file to `Ainalrami.Dubov` or `Ainalrami.Burstein`
      before it gets here), and every `CUSTOM_*` system.

  With no `192` - or one that is not in the table - the `092` type is read
  for a round robin (a team round robin when the games show a team event,
  an individual one otherwise, played as many times as its rounds need),
  Scheveningen, Schiller or knockout (unreplayable, as above), and
  otherwise the games decide: the file is a team event when, in
  every round, all the players of a team who met somebody met players of
  one and the same other team, and that team's players met theirs. An
  individual event with team records does not look like that past its
  first board.

  ## What a team Swiss code says

  The table spells the C.04.6 variants
  `FIDE_TEAM[_TYPEA|_TYPEB]_{MP|GP}[_{GP|MP}][_BAKU]`, and says:

    * `TYPEA` / `TYPEB` - Type A / Type B colour preferences (1.7.1,
      1.7.2). **Neither means "no colour preferences"** - 1.7's third
      option, "colour preferences are not to be used at all" - replayed
      with `type: :none` (see `Ainalrami.TeamPairing.Team.preference/3`).
      Until 2026-09-27 this module read a code without either as Type A,
      1.7's default; the table says otherwise.
    * the first of `MP`/`GP` - the primary score (1.2.1); the second, when
      present, the secondary score "to be used in colour allocation"
      (4.2.2); a single one - "secondary score ... not used".
    * `FIDE_TEAM` alone is `FIDE_TEAM_TYPEA_MP_GP`, and `FIDE_TEAM_BAKU`
      `FIDE_TEAM_TYPEA_MP_GP_BAKU`.
    * `_BAKU` - C.04.7's acceleration: replayed with the virtual points of
      the file's `250` records naming teams (`tournament[:team_accelerations]`),
      added to each team's score for the pairing only (`settings.virtual`).
      A `_BAKU` file without them is unreplayable - this checker does not
      cut Group A itself unless `--acceleration=baku` asks. A file laid out
      like TRF-2026's own example, the values in the game-points column, is
      read as match points (docs/team-baku.md). A `250` in a team file
      without `_BAKU` is applied all the same, as `XXA`/`250` are for an
      individual one.

  A file with no usable `192` that the games show to be a team event is
  replayed with the C.04.6 defaults: Type A (1.7), match points primary and
  game points for colours (1.2.2) - the same as `FIDE_TEAM`.

  ## What the file's history says (`history/1`)

  Per team and round, read from the players' games in `310`/`013` order
  (the first player of a team who met somebody is its board 1, as
  `Ainalrami.Tiebreaks.Team.from_trf/2` numbers the boards) - or in the
  order of a TRF26 `300` record for the match, when the file has one:

    * **a match** against the team whose players they met. It was *played*
      when at least one board was played over the board, or when both
      teams scored on a board by forfeit (both turned up) - the definition
      lives in `Ainalrami.Tiebreaks.Team.from_trf/2` and is read from
      there. A match where only one side scored, or neither, with no board
      played, or a TRF26 `330` record with no board records, was paired but
      not played (C.04.2 3.5: such teams "may be
      paired together in a future round", so it is not an opponent for
      [C1]). The team's colour is its board-1 player's (1.6.1), and a
      `330` record's white and black teams for a match with no boards.
    * **the pairing-allocated bye** - its players' `U` (or `+` with no
      opponent), or the team named for the round in a `320` record.
    * **a half-point bye** the team asked for - a TRF26 `240 H` naming the
      team (team numbers in a team event, as the spec's example has them).
      Not paired: no opponent, no colour, no float, not the
      pairing-allocated bye (so [C2] still allows that one later), and
      not an arrival for 4.3.1's numbering. Its points are
      `Ainalrami.Tiebreaks.Team.from_trf/2`'s - a drawn match unless a
      `299 H` says otherwise.
    * **out** of the round's pairing otherwise - sat it out, not yet
      arrived, or withdrawn.

  Match and game points are `Ainalrami.Tiebreaks.Team.from_trf/2`'s, the
  same reading the standings check uses (`362`, `320`, `330`). A team
  "won a match by forfeit" ([C2]) when that reading makes it a forfeit win -
  no board played and the opponent scored nothing, or a `330` record -
  OpenPairings' reading of open question 6. A team whose players all hold an `F`, or
  that a `240 F` names, has a full-point bye, which [C2] also bars from the
  pairing-allocated bye.

  ## Replaying a round (`check_round/4`)

  The field is the teams the file pairs in that round (a match or the
  bye). A team out of the round that was paired in an earlier one is
  passed as `:absent`, keeping its place in 4.3.1's numbering. Each team's
  `%Ainalrami.TeamPairing.Team{}`: points so far, opponents of played
  matches, board-1 colours of played matches, whether it had the bye or won
  a match by forfeit, and whether it floated in the previous round -
  PLAYED against a team on a different primary score (1.5; a forfeited
  match floats nobody). The round number and the file's `142` round count switch [C7],
  [C10] and Type B's mild preferences off at the end, as the engine does.

  A round is compared in composition (who meets whom, who has the bye) and
  in colours (the team with White on board 1). Unlike the individual
  replay, a colour difference counts: Article 4 decides every team colour
  from the initial colour, and the initial colour is the file's `152`, or,
  when it has none, the one of White and Black that reproduces more of
  round 1's colours (4.3.1 gives round 1's colours from it alone).
  """

  alias Ainalrami.Berger
  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamPairing.Team
  alias Ainalrami.Tiebreaks
  alias Ainalrami.TypeCode

  @type settings :: %{
          type: :a | :b | :none,
          score_mode: :match_points | :game_points,
          use_secondary?: boolean(),
          code: String.t() | nil,
          unlisted_code: String.t() | nil,
          virtual: %{optional(pos_integer()) => [{number(), number()}]}
        }

  @defaults %{
    type: :a,
    score_mode: :match_points,
    use_secondary?: true,
    code: nil,
    unlisted_code: nil,
    virtual: %{}
  }

  # ---- which replay --------------------------------------------------------

  @doc """
  How the checker replays this parsed file: `:individual`,
  `{:team, settings}` or `{:unreplayable, reason}`. See the moduledoc.
  """
  def system(%{tournament: tournament} = parsed) do
    case tournament[:type_code] do
      code when is_binary(code) and code != "" ->
        case TypeCode.parse(code) do
          {:ok, description} -> system_for(description, parsed)
          :error -> system_without_code(parsed, tournament[:type], String.trim(code))
        end

      _ ->
        system_without_code(parsed, tournament[:type], nil)
    end
  end

  defp system_for(%{system: :dutch, baku?: true, code: code}, parsed) do
    if Enum.any?(Map.get(parsed, :players, []), &accelerated?/1) do
      :individual
    else
      {:unreplayable,
       "#{code} is accelerated (Baku Acceleration Method, C.04.7) but the file gives no " <>
         "virtual points (XXA or 250 lines), and this checker does not derive the " <>
         "accelerated groups itself"}
    end
  end

  defp system_for(%{system: :dutch}, _parsed), do: :individual

  # OpenPairings writes its Swiss match format as CUSTOM_SWISS (FIDE's
  # table has no code for it); with `XXM` (or `--match-format`) saying so,
  # it is the Dutch system with the second legs copied
  # (`Ainalrami.EventFormat`).
  defp system_for(%{system: :custom_swiss}, %{tournament: %{match_format: true}}),
    do: :individual

  # And its round robin match format as CUSTOM_ROUNDROBIN: one Berger table,
  # every game a two-game match.
  defp system_for(%{system: :custom_round_robin, code: code}, %{
         tournament: %{match_format: true} = t
       }) do
    {:round_robin,
     %{
       games: 1,
       reverse_last_two?: false,
       code: code,
       match_format?: true,
       groups: t[:pairing_groups] || []
     }}
  end

  defp system_for(
         %{system: :custom_team_round_robin, code: code},
         %{tournament: %{match_format: true}} = parsed
       ) do
    if Map.get(parsed, :teams, []) == [] do
      {:unreplayable,
       "#{code} is a team round robin, but the file has no team records (013 or 310)"}
    else
      {:team_round_robin, %{games: 1, code: code, match_format?: true}}
    end
  end

  # An accelerated team Swiss (C.04.7 over C.04.6): replayed with the
  # virtual points the file's `250` records give the teams, as the
  # individual replay pairs with `XXA`/`250`. A file without them is
  # refused rather than given groups this checker made up.
  defp system_for(%{system: :team_swiss, baku?: true, score_mode: :game_points, code: code}, _),
    do:
      {:unreplayable,
       "#{code} accelerates a team Swiss on game points, and C.04.7 (Example 2) says " <>
         "that \"if gamepoints were the primary score, the Baku Acceleration could not " <>
         "be used\""}

  defp system_for(%{system: :team_swiss, baku?: true, code: code} = d, parsed) do
    case system_for(Map.put(d, :baku?, false), parsed) do
      {:team, %{virtual: virtual}} when virtual == %{} ->
        {:unreplayable,
         "#{code} is an accelerated team Swiss (Baku Acceleration Method, C.04.7) but the " <>
           "file gives no virtual points (250 records naming teams), and this checker does " <>
           "not derive the accelerated groups itself"}

      {:team, settings} ->
        {:team, Map.put(settings, :virtual, baku_virtual(parsed.tournament[:team_accelerations]))}

      other ->
        other
    end
  end

  defp system_for(%{system: :team_swiss, code: code}, %{tournament: %{match_format: true}}) do
    {:unreplayable,
     "XXM (match format) is for a Swiss or a round robin, and #{code} is a team Swiss, " <>
       "which has no match format"}
  end

  defp system_for(%{system: :team_swiss, code: code} = d, parsed) do
    if Map.get(parsed, :teams, []) == [] do
      {:unreplayable, "#{code} is a team Swiss, but the file has no team records (013 or 310)"}
    else
      {:team,
       %{
         @defaults
         | type: d.colour_preferences,
           score_mode: d.score_mode,
           use_secondary?: d.use_secondary?,
           code: code,
           virtual: parsed.tournament[:team_accelerations] || %{}
       }}
    end
  end

  defp system_for(%{system: :team_round_robin, code: code} = d, parsed) do
    if Map.get(parsed, :teams, []) == [] do
      {:unreplayable,
       "#{code} is a team round robin, but the file has no team records (013 or 310)"}
    else
      match_format_settings(%{games: d.games, code: code}, parsed, :team_round_robin)
    end
  end

  defp system_for(%{system: :round_robin, code: code} = d, parsed) do
    %{games: d.games, reverse_last_two?: Map.get(d, :reverse_last_two?, false), code: code}
    |> match_format_settings(parsed, :round_robin)
  end

  defp system_for(%{code: code} = d, _parsed), do: {:unreplayable, "#{code} #{not_replayed(d)}"}

  defp not_replayed(%{system: system}) when system in [:schiller, :scheveningen] do
    "is a #{if system == :schiller, do: "Schiller", else: "Scheveningen"} event, whose " <>
      "pairings are predetermined (by rules FIDE has not yet defined)"
  end

  defp not_replayed(%{system: system})
       when system in [:custom_round_robin, :custom_team_round_robin] do
    "is a round robin of the competition's own, whose pairings are predetermined"
  end

  defp not_replayed(%{system: system})
       when system in [:custom_schiller, :custom_scheveningen] do
    "is a predetermined system of the competition's own"
  end

  defp not_replayed(%{system: system}) when system in [:knockout, :team_knockout],
    do: "is a knockout, not a Swiss"

  defp not_replayed(%{system: :dubov}),
    do: "is the Dubov system, which is replayed as an individual Swiss, not here"

  defp not_replayed(%{system: :burstein}),
    do: "is the Burstein system, which is replayed as an individual Swiss, not here"

  defp not_replayed(%{system: :double_swiss}),
    do: "is a Double Swiss, and Ainalrami pairs the Dutch, Dubov and Burstein systems only"

  defp not_replayed(%{system: system}) when system in [:custom_swiss, :custom_double_swiss],
    do: "is a Swiss of the competition's own, not the Dutch system"

  defp not_replayed(%{system: :custom_team_swiss}),
    do: "is a custom team Swiss - a system of the competition's own, not C.04.6"

  # A Berger round robin's settings with the file's match format (`XXM`)
  # and, for an individual one, its pairing groups (`XXG`). The match format
  # is a single table played as two-game matches, so a code playing the
  # table twice, or reversing its last two rounds, contradicts it - and
  # OpenPairings refuses the two together too.
  defp match_format_settings(settings, %{tournament: t}, kind) do
    match? = t[:match_format] == true

    cond do
      match? and (settings.games != 1 or Map.get(settings, :reverse_last_two?, false)) ->
        {:unreplayable,
         "XXM (match format) plays one Berger table as two-game matches, and " <>
           "#{settings.code || "this round robin"} plays the table #{settings.games} times"}

      kind == :team_round_robin ->
        {kind, Map.put(settings, :match_format?, match?)}

      true ->
        {kind,
         settings
         |> Map.put(:match_format?, match?)
         |> Map.put(:groups, t[:pairing_groups] || [])}
    end
  end

  # The virtual points of a `_BAKU` team code, which the table defines only
  # with match points primary. TRF-2026's own example of the method ("a 11
  # round Swiss team tournament based on matchpoints") writes them in the
  # GAME points column, `250 00.0 02.0 001 003 0001 0090`, under a field
  # definition that puts match points in 5-8. A file laid out like the
  # example - no `250` with match points, some with game points - is read
  # the way the example means it: those values are the virtual MATCH points.
  # Our reading, docs/team-baku.md. A file with match points in 5-8 is
  # read as it is written.
  defp baku_virtual(table) do
    rows = Map.values(table)
    mp? = Enum.any?(rows, fn row -> Enum.any?(row, fn {mp, _gp} -> mp != 0 end) end)

    if mp?,
      do: table,
      else:
        Map.new(table, fn {tpn, row} -> {tpn, Enum.map(row, fn {_mp, gp} -> {gp, 0.0} end)} end)
  end

  defp accelerated?(player) do
    Enum.any?(player[:accelerations] || [], &(&1 != 0))
  end

  # No code, or one FIDE's table does not have (`unlisted`).
  defp system_without_code(parsed, type, unlisted) do
    type = String.downcase(to_string(type || ""))

    cond do
      String.contains?(type, "robin") and team_structured?(parsed) ->
        if parsed.tournament[:match_format] == true,
          do: {:team_round_robin, %{games: 1, code: nil, match_format?: true}},
          else: {:team_round_robin, %{games: cycles_played(parsed), code: nil}}

      String.contains?(type, "robin") ->
        games =
          if parsed.tournament[:match_format] == true,
            do: 1,
            else: Ainalrami.RoundRobin.cycles_played(parsed)

        match_format_settings(
          %{games: games, reverse_last_two?: false, code: nil},
          parsed,
          :round_robin
        )

      String.contains?(type, "scheveningen") or String.contains?(type, "schiller") ->
        {:unreplayable,
         "the file's type (092) is a Scheveningen or Schiller event, whose pairings are " <>
           "predetermined"}

      String.contains?(type, "knock") ->
        {:unreplayable, "the file's type (092) is a knockout, which is not a Swiss"}

      team_structured?(parsed) ->
        {:team,
         %{
           @defaults
           | unlisted_code: unlisted,
             virtual: parsed.tournament[:team_accelerations] || %{}
         }}

      true ->
        :individual
    end
  end

  # A team round robin known only from its `092` type: as many cycles of
  # the Berger table as its rounds need.
  defp cycles_played(parsed) do
    teams = length(parsed.teams)
    rounds = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)
    per_cycle = if teams < 2, do: 1, else: Berger.total_rounds(teams, 1)
    max(1, div(rounds + per_cycle - 1, per_cycle))
  end

  @doc "A one-line description of `settings`, for the trace."
  def describe(%{games: games} = s) do
    times = if games == 1, do: "once", else: "#{games} times"

    source =
      if s.code,
        do: " (192 #{s.code})",
        else: " (092 round robin, no 192: #{times} by the rounds)"

    shape =
      if s[:match_format?],
        do: "each pairing played as two matches in a row, colours reversed in the second (XXM)",
        else: "each match played #{times}"

    "a team round robin by the Berger tables (C.05 Annex 1), #{shape}" <> source
  end

  def describe(%{} = s) do
    {primary, secondary} =
      case s.score_mode do
        :match_points -> {"match points", "game points"}
        :game_points -> {"game points", "match points"}
      end

    colours =
      if s.use_secondary?,
        do: "#{secondary} for colours",
        else: "no secondary score for colours"

    type =
      case s.type do
        :a -> "Type A colour preferences"
        :b -> "Type B colour preferences"
        :none -> "no colour preferences"
      end

    source =
      cond do
        s.code ->
          " (192 #{s.code})"

        s[:unlisted_code] ->
          " (192 #{s.unlisted_code} is not in FIDE's table: the C.04.6 defaults)"

        true ->
          " (no 192: the C.04.6 defaults)"
      end

    accelerated =
      if Map.get(s, :virtual, %{}) == %{},
        do: "",
        else: ", virtual points for #{map_size(s.virtual)} teams (C.04.7, 250)"

    "C.04.6, #{type}, #{primary} primary, #{colours}#{accelerated}#{source}"
  end

  # Every round's matches are team against team - see the moduledoc.
  defp team_structured?(parsed) do
    {rosters, team_of} = rosters(parsed)
    by_rank = Map.new(parsed.players, &{&1.rank, &1})
    rounds = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)

    opponents =
      for r <- 1..rounds//1, {team, ranks} <- rosters, into: %{} do
        met =
          for rank <- ranks,
              player = by_rank[rank],
              player != nil,
              game = Enum.at(player.games, r - 1),
              game != nil,
              is_integer(game.opponent_rank),
              do: team_of[game.opponent_rank]

        {{team, r}, Enum.uniq(met)}
      end

    matches = Enum.count(opponents, fn {_key, met} -> met != [] end)

    matches > 0 and
      Enum.all?(opponents, fn
        {_key, []} ->
          true

        {{team, r}, [other]} when is_integer(other) and other != team ->
          opponents[{other, r}] == [team]

        _ ->
          false
      end)
  end

  @doc """
  The file's team numbers: a `310` team's own number, a `013` team's place
  in the file - the numbers every team record, flag and pairing list uses.
  """
  def team_numbers(parsed) do
    {rosters, _team_of} = rosters(parsed)
    Enum.map(rosters, &elem(&1, 0))
  end

  # `310` teams keep their number; `013` teams are numbered in file order,
  # as `Tiebreaks.Team.from_trf/2` numbers them.
  defp rosters(parsed) do
    rosters =
      parsed
      |> Map.get(:teams, [])
      |> Enum.with_index(1)
      |> Enum.map(fn {team, index} -> {Map.get(team, :number) || index, team.player_ranks} end)

    team_of = for {id, ranks} <- rosters, rank <- ranks, into: %{}, do: {rank, id}
    {rosters, team_of}
  end

  # ---- the file's history --------------------------------------------------

  @doc """
  Every team's rounds as the file records them: `%{tpn => %{round => record}}`,
  a record being `%{kind: :match | :pab | :half_bye | :out, opponent:, played?:,
  colour: :white | :black | nil, mp:, gp:, forfeit_win?:, full_bye?:}`.
  See the moduledoc.
  """
  def history(parsed) do
    {rosters, team_of} = rosters(parsed)
    event = Tiebreaks.Team.from_trf(parsed)
    individual = Tiebreaks.Event.from_trf(parsed, rounds: event.rounds)
    tournament = parsed.tournament

    declared =
      for f <- tournament[:forfeited_matches] || [],
          is_integer(f[:round]) and is_integer(f[:white]) and is_integer(f[:black]),
          do: f

    pab_by_round = get_in(tournament, [:team_pab, :teams]) || []

    orders = board_orders(tournament)

    Map.new(rosters, fn {team, ranks} ->
      rounds =
        Map.new(1..event.rounds//1, fn r ->
          rounds =
            for rank <- board_order(orders, team, r, ranks),
                participant = individual.participants[rank],
                participant != nil,
                do: {participant.rounds[r], board_of(orders, team, r, rank)}

          points = event.teams[team].rounds[r]

          record =
            rounds
            |> read_round(team, r, team_of, declared, Enum.at(pab_by_round, r - 1))
            |> requested_bye(points.kind)

          record =
            Map.merge(record, %{
              mp: points.mp * 1.0,
              gp: points.gp * 1.0,
              forfeit_win?: points.kind == :forfeit_win,
              # Played or not is `Tiebreaks.Team.from_trf/2`'s to say (a board
              # played, or both teams scoring by forfeit) - one definition.
              played?: record.kind == :match and points.kind == :played
            })

          {r, record}
        end)

      {team, rounds}
    end)
  end

  # `{team, round} => [starting rank]` from the TRF26 `300` records: the
  # team's players in board order for that match.
  defp board_orders(tournament) do
    for o <- tournament[:board_orders] || [],
        is_integer(o[:round]) and is_integer(o[:team]),
        into: %{},
        do: {{o.team, o.round}, o[:order] || []}
  end

  # The roster in board order for round `r`: a `300` record's order first,
  # then the rest of the roster as listed.
  defp board_order(orders, team, r, ranks) do
    case Map.fetch(orders, {team, r}) do
      {:ok, order} ->
        named = Enum.filter(order, &(is_integer(&1) and &1 > 0))
        named ++ (ranks -- named)

      :error ->
        ranks
    end
  end

  # The board (0-based) a `300` record seats `rank` on, nil without one.
  defp board_of(orders, team, r, rank) do
    case Map.fetch(orders, {team, r}) do
      {:ok, order} -> Enum.find_index(order, &(&1 == rank))
      :error -> nil
    end
  end

  defp read_round(boards, team, r, team_of, declared, pab_team) do
    rounds = Enum.map(boards, &elem(&1, 0))

    # A game against a player on no team's roster says nothing about which
    # team this one met.
    met =
      Enum.filter(boards, fn {g, _board} ->
        g.opponent != nil and Map.has_key?(team_of, g.opponent)
      end)

    base = %{kind: :out, opponent: nil, played?: false, colour: nil, full_bye?: false}

    case met do
      [] ->
        found =
          Enum.find_value(declared, fn
            %{round: ^r, white: ^team, black: other} -> {other, :white}
            %{round: ^r, white: other, black: ^team} -> {other, :black}
            _ -> nil
          end)

        cond do
          found ->
            {other, colour} = found
            %{base | kind: :match, opponent: other, colour: colour}

          pab_team == team or Enum.any?(rounds, &(&1.kind == :pab)) ->
            %{base | kind: :pab}

          rounds != [] and Enum.all?(rounds, &(&1.kind == :full_bye)) ->
            %{base | full_bye?: true}

          true ->
            base
        end

      _ ->
        opponent =
          met
          |> Enum.frequencies_by(fn {g, _board} -> team_of[g.opponent] end)
          |> Enum.max_by(fn {_team, n} -> n end)
          |> elem(0)

        %{
          base
          | kind: :match,
            opponent: opponent,
            colour: Enum.find_value(met, &team_colour/1)
        }
    end
  end

  # A round the team was not paired in, which `Tiebreaks.Team.from_trf/2`
  # scores as a requested bye (a TRF26 `240` naming the team): a
  # half-point bye is its own kind - not paired, no opponent, no colour, no
  # float, and not the pairing-allocated bye, so [C2] (2.1.2) still lets
  # the team have that one; a full-point bye stays out of the round and
  # bars the pairing-allocated bye, as its players' `F`s already did.
  defp requested_bye(%{kind: :out} = record, :half_bye), do: %{record | kind: :half_bye}
  defp requested_bye(%{kind: :out} = record, :full_bye), do: %{record | full_bye?: true}
  defp requested_bye(record, _kind), do: record

  # The team's colour (1.6.1, board 1's) from the first board that has one:
  # board 1 itself, or - when a `300` record seats that player lower - the
  # board's colour turned round on every even board, team colours
  # alternating down the boards.
  defp team_colour({%{colour: nil}, _board}), do: nil
  defp team_colour({%{colour: colour}, board}) when board in [nil, 0], do: colour

  defp team_colour({%{colour: colour}, board}) do
    if rem(board, 2) == 0, do: colour, else: opposite(colour)
  end

  defp opposite(:white), do: :black
  defp opposite(:black), do: :white

  @doc "The last round in which the file pairs any team, 0 if none."
  def paired_rounds(history) do
    history
    |> Enum.flat_map(fn {_team, rounds} ->
      for {r, %{kind: kind}} <- rounds, kind in [:match, :pab], do: r
    end)
    |> Enum.max(fn -> 0 end)
  end

  # ---- one round -----------------------------------------------------------

  @doc """
  The file's pairing of `round`: `{pairs, bye}`, each pair
  `{white, black, colour_known?}` (lower number first when the colours are
  not known).
  """
  def recorded(history, round) do
    records = Map.new(history, fn {team, rounds} -> {team, rounds[round]} end)

    pairs =
      records
      |> Enum.filter(fn {_team, rec} -> rec.kind == :match end)
      |> Enum.map(fn {team, rec} ->
        theirs = records[rec.opponent]

        cond do
          rec.colour == :white and (theirs == nil or theirs.colour != :white) ->
            {team, rec.opponent, true}

          rec.colour == :black and (theirs == nil or theirs.colour != :black) ->
            {rec.opponent, team, true}

          rec.colour == nil and theirs != nil and theirs.colour == :black ->
            {team, rec.opponent, true}

          rec.colour == nil and theirs != nil and theirs.colour == :white ->
            {rec.opponent, team, true}

          true ->
            {min(team, rec.opponent), max(team, rec.opponent), false}
        end
      end)
      |> Enum.uniq_by(fn {a, b, _} -> Enum.sort([a, b]) end)
      |> Enum.sort()

    bye = Enum.find_value(records, fn {team, rec} -> if rec.kind == :pab, do: team end)

    {pairs, bye}
  end

  @doc """
  The engine's input for `round`: `{teams, absent}` - the
  `%Ainalrami.TeamPairing.Team{}` of every team the file pairs in the
  round, and the teams paired earlier but out of this round.
  """
  def state_before(history, round, settings) do
    field =
      for {team, rounds} <- history,
          rec = rounds[round],
          rec != nil and rec.kind in [:match, :pab],
          do: team

    state_for(history, round, settings, field)
  end

  @doc """
  The engine's input for `round` with the field given: `{teams, absent}`
  as in `state_before/3`, for the teams in `field`.
  """
  def state_for(history, round, settings, field) do
    teams =
      for team <- Enum.sort(field) do
        earlier = earlier(history[team], round)
        played = Enum.filter(earlier, &(&1.kind == :match and &1.played?))

        %Team{
          tpn: team,
          match_points: total(earlier, :mp),
          game_points: total(earlier, :gp),
          opponents: Enum.map(played, & &1.opponent),
          colours: played |> Enum.map(& &1.colour) |> Enum.reject(&is_nil/1),
          matches_played: length(played),
          had_pab?: Enum.any?(earlier, &(&1.kind == :pab)),
          won_by_forfeit?: Enum.any?(earlier, &(&1.forfeit_win? or &1.full_bye?)),
          floated_last_round?: floated?(history, team, round - 1, settings)
        }
        |> with_virtual(settings, round)
      end

    absent =
      for {team, rounds} <- history,
          team not in field,
          Enum.any?(earlier(rounds, round), &(&1.kind in [:match, :pab])),
          do: team

    {teams, Enum.sort(absent)}
  end

  # A team's virtual points for `round` (`settings.virtual`, the file's `250`
  # records), on the Team struct the engine reads them from.
  defp with_virtual(%Team{} = team, settings, round) do
    case settings |> Map.get(:virtual, %{}) |> Map.get(team.tpn, []) |> Enum.at(round - 1) do
      {mp, gp} when mp != 0 or gp != 0 ->
        %{team | virtual_match_points: mp * 1.0, virtual_game_points: gp * 1.0}

      _ ->
        team
    end
  end

  defp virtual(settings, team, round, mode) do
    case settings |> Map.get(:virtual, %{}) |> Map.get(team, []) |> Enum.at(round - 1) do
      {mp, _gp} when mode == :match_points -> mp
      {_mp, gp} -> gp
      nil -> 0.0
    end
  end

  defp earlier(rounds, round),
    do: for(r <- 1..(round - 1)//1, rec = rounds[r], rec != nil, do: rec)

  defp total(records, key), do: records |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() |> tidy()

  defp tidy(x), do: Float.round(x * 1.0, 6)

  # 1.5: PLAYED, in `previous`, against a team on a different score before
  # it. A forfeited match makes nobody a floater (2026-11-11: 1.5 says
  # "plays against", and the Basic Rules' "play against each other" is a
  # game actually played); until then the pairing alone floated a team.
  #
  # With virtual points (C.04.7) the scores compared are the PAIRING scores
  # that round was paired on - real plus that round's virtual points - since
  # 1.5's "different score" is the one the scoregroups were made of (C.04.7
  # 1.5). Our reading, docs/team-baku.md.
  defp floated?(_history, _team, previous, _settings) when previous < 1, do: false

  defp floated?(history, team, previous, settings) do
    mode = settings.score_mode

    case history[team][previous] do
      %{kind: :match, played?: true, opponent: other} when is_map_key(history, other) ->
        key = if mode == :game_points, do: :gp, else: :mp

        score = fn t ->
          tidy(total(earlier(history[t], previous), key) + virtual(settings, t, previous, mode))
        end

        score.(team) != score.(other)

      _ ->
        false
    end
  end

  @doc """
  Replays `round` and compares it with the file. Returns

    * `{:ok, file}` - same pairing, same colours;
    * `{:colours, file, engine, differing}` - same pairing, the colours of
      the `differing` matches (the file's `{white, black}`) not;
    * `{:differs, file, engine}` - a different pairing;
    * `{:no_pairing, reason}` - the engine refused the round.

  `file` and `engine` are `[{white, black}]` plus `{bye, nil}`, sorted.
  Options: `:initial_colour` (`:white` default), `:expected_rounds`, and
  `:max_upfloater_sets`, `:forbidden_pairs` and `:soft_pairs`
  (`Ainalrami.TeamPairing.pair_round/2`'s - a file that keeps teams apart is
  replayed keeping them apart, or every round they changed would differ).
  """
  def check_round(history, round, settings, opts \\ []) do
    {teams, absent} = state_before(history, round, settings)
    {pairs, bye} = recorded(history, round)

    engine_opts = [
      score_mode: settings.score_mode,
      use_secondary?: settings.use_secondary?,
      type: settings.type,
      initial_colour: Keyword.get(opts, :initial_colour, :white),
      absent: absent,
      round: round,
      expected_rounds: Keyword.get(opts, :expected_rounds)
    ]

    engine_opts =
      engine_opts ++ Keyword.take(opts, [:max_upfloater_sets, :forbidden_pairs, :soft_pairs])

    file = Enum.sort(Enum.map(pairs, fn {w, b, _} -> {w, b} end) ++ bye_entry(bye))

    case TeamPairing.pair_round(teams, engine_opts) do
      {:ok, result} ->
        engine =
          Enum.sort(Enum.map(result.pairs, &{&1.white, &1.black}) ++ bye_entry(result.bye))

        if composition(file) != composition(engine) do
          {:differs, file, engine}
        else
          engine_set = MapSet.new(engine)

          differing =
            for {w, b, true} <- pairs, not MapSet.member?(engine_set, {w, b}), do: {w, b}

          if differing == [], do: {:ok, file}, else: {:colours, file, engine, differing}
        end

      {:error, reason} ->
        {:no_pairing, reason}
    end
  end

  defp bye_entry(nil), do: []
  defp bye_entry(team), do: [{team, nil}]

  defp composition(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  @doc """
  The initial colour (4.1) to replay with: the file's `152` when it has
  one (`{colour, :file}`), else whichever of White and Black reproduces
  more of round 1's colours (`{colour, :inferred}`), White on a tie.
  """
  def initial_colour(history, tournament, settings, opts \\ []) do
    case tournament[:initial_colour] do
      c when c in ["w", "W"] ->
        {:white, :file}

      c when c in ["b", "B"] ->
        {:black, :file}

      _ ->
        misses = fn colour ->
          case check_round(history, 1, settings, Keyword.put(opts, :initial_colour, colour)) do
            {:ok, _} -> 0
            {:colours, _, _, differing} -> length(differing)
            _ -> :infinity
          end
        end

        if paired_rounds(history) >= 1 and misses.(:black) < misses.(:white),
          do: {:black, :inferred},
          else: {:white, :inferred}
    end
  end

  # ---- the next round (`ainalrami input.trf -p`) ---------------------------

  @doc """
  What `-p` pairs on a team Swiss file: the round after the last one the
  file pairs, with the field and the engine's input for it -
  `%{round:, field:, out:, teams:, absent:}`.

  The field is every team with at least one player free to sit at a board:
  a player is not free when the file already records the round for them -
  a zero-, half- or full-point bye in its column, or a TRF26 `240` record -
  which is how an arbiter tells the engine, before the pairing, that
  somebody will not play. A `240` naming the TEAM for the round (any type)
  takes the whole team out, whatever its players' columns say. A team none of whose players is free sits the
  round out (`out`); if it was paired before, it is passed as `:absent`
  and keeps its place in 4.3.1's numbering, as in the replay.
  """
  def next_round(parsed, history, settings) do
    round = paired_rounds(history) + 1
    {rosters, _team_of} = rosters(parsed)
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    # A team's own bye for the round, TRF26 `240` with team numbers (or
    # `--half-bye-teams`), whatever its players' columns say.
    with_bye =
      for bye <- parsed.tournament[:team_byes] || [],
          bye.round == round,
          team <- bye.teams,
          into: MapSet.new(),
          do: team

    {field, out} =
      rosters
      |> Enum.split_with(fn {team, ranks} ->
        not MapSet.member?(with_bye, team) and Enum.any?(ranks, &free?(by_rank[&1], round))
      end)

    field = field |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    {teams, absent} = state_for(history, round, settings, field)

    %{
      round: round,
      field: field,
      out: out |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      teams: teams,
      absent: absent
    }
  end

  @doc """
  Whether `player` is free to be seated in `round`: the file records
  nothing for them in that round. A player not in the file is not free.
  """
  def free?(nil, _round), do: false

  def free?(player, round) do
    case Enum.at(player.games, round - 1) do
      nil -> true
      game -> blank?(game)
    end
  end

  defp blank?(game) do
    is_nil(game[:opponent_rank]) and
      (is_nil(game[:result]) or String.trim(to_string(game[:result])) == "")
  end

  @doc """
  The players a team seats in `round`, board 1 first: the order of a TRF26
  `300` record for the round when the file has one, otherwise its free
  players in roster order (`310`/`013`) - the players below an absent one
  moving up a board. `boards` long, `nil` for a board nobody fills.
  """
  def lineup(parsed, team, round, boards) do
    {rosters, _team_of} = rosters(parsed)
    ranks = rosters |> List.keyfind(team, 0, {team, []}) |> elem(1)
    by_rank = Map.new(parsed.players, &{&1.rank, &1})

    seated =
      case Enum.find(
             parsed.tournament[:board_orders] || [],
             &(&1[:round] == round and &1[:team] == team)
           ) do
        %{order: order} -> Enum.map(order, &if(&1 in [nil, 0], do: nil, else: &1))
        nil -> Enum.filter(ranks, &free?(by_rank[&1], round))
      end

    seated
    |> Enum.take(boards)
    |> then(&(&1 ++ List.duplicate(nil, boards - length(&1))))
  end

  @doc """
  The number of boards a match has: the file's TRF26 `352` colour sequence
  when it has one, else the most players of one team who met somebody in
  one round (`Ainalrami.Tiebreaks.Team.from_trf/2`'s count), or nil when
  neither says.
  """
  def boards(parsed) do
    Tiebreaks.Team.board_count(parsed.tournament) || boards_from_games(parsed)
  end

  defp boards_from_games(parsed) do
    {_rosters, team_of} = rosters(parsed)

    counts =
      for player <- parsed.players,
          team = team_of[player.rank],
          team != nil,
          {game, r} <- Enum.with_index(player.games, 1),
          is_integer(game.opponent_rank),
          Map.has_key?(team_of, game.opponent_rank),
          reduce: %{} do
        acc -> Map.update(acc, {team, r}, 1, &(&1 + 1))
      end

    case Map.values(counts) do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  # ---- a team round robin --------------------------------------------------

  @doc """
  The Berger table's pairing of `round` for this file's teams: `{:ok,
  pairs, free}` with `pairs` as `[{white, black}]` in team numbers (the
  team with White on board 1 first) and `free` the team the table gives
  the round off (an odd field), or `{:error, {:all_rounds_paired,
  total}}`. The teams are numbered for the table in the order of their
  numbers (`310`; file order for `013`), which for teams numbered 1..n is
  their own number.
  """
  def berger_round(history, round, %{games: games} = settings) do
    numbers = history |> Map.keys() |> Enum.sort()
    n = length(numbers)

    if n < 2 do
      {:error, :too_few_teams}
    else
      team = fn position -> Enum.at(numbers, position - 1) end
      opts = [match_format?: Map.get(settings, :match_format?, false)]

      with {:ok, pairs, free} <- Berger.round(n, games, round, opts) do
        {:ok, Enum.map(pairs, fn {w, b} -> {team.(w), team.(b)} end), free && team.(free)}
      end
    end
  end

  @doc """
  Compares `round` of a team round robin with the Berger table. Returns
  `%{result:, file:, engine:, differing:, missing:}`:

    * `result` - `:ok`, `:colours` (every recorded match is scheduled, but
      the board-1 colours of `differing` are the other way round),
      `:differs` (a recorded match the table does not have, or a bye for a
      team the table seats), or `:beyond` (the table has no such round);
    * `file` / `engine` - the recorded and the scheduled pairing,
      `[{white, black}]` plus `{team, nil}` for a bye or a free round;
    * `missing` - scheduled matches the file records nothing for (neither
      team's players have a game, and no `330`): not a different pairing,
      only an unrecorded one.
  """
  def check_round_robin(history, round, settings) do
    {pairs, bye} = recorded(history, round)
    file = Enum.sort(Enum.map(pairs, fn {w, b, _} -> {w, b} end) ++ bye_entry(bye))

    case berger_round(history, round, settings) do
      {:ok, scheduled, free} ->
        engine = Enum.sort(scheduled ++ bye_entry(free))
        by_composition = Map.new(scheduled, fn {w, b} -> {Enum.sort([w, b]), {w, b}} end)

        unscheduled =
          Enum.reject(pairs, fn {w, b, _} -> Map.has_key?(by_composition, Enum.sort([w, b])) end)

        recorded_set = MapSet.new(pairs, fn {w, b, _} -> Enum.sort([w, b]) end)

        missing =
          for {w, b} <- scheduled, not MapSet.member?(recorded_set, Enum.sort([w, b])), do: {w, b}

        differing =
          for {w, b, true} <- pairs,
              Map.get(by_composition, Enum.sort([w, b])) == {b, w},
              do: {w, b}

        result =
          cond do
            unscheduled != [] or (bye != nil and bye != free) -> :differs
            differing != [] -> :colours
            true -> :ok
          end

        %{result: result, file: file, engine: engine, differing: differing, missing: missing}

      {:error, _reason} ->
        %{result: :beyond, file: file, engine: [], differing: [], missing: []}
    end
  end
end

defmodule Ainalrami.TeamCLI do
  @moduledoc """
  The team half of `ainalrami input.trf -p` and `-x`: the next round of a
  team event, team against team, read from a TRF26 team file (`310`
  rosters, `001` games, `362`/`320`/`330`/`300` records) - see
  `Ainalrami.TeamReplay` for how the file is read.

    * a C.04.6 team Swiss (`192 FIDE_TEAM...`, or a file whose games show a
      team event) is paired by `Ainalrami.TeamPairing` with the settings
      the `192` code names - colour preferences, primary score, whether the
      secondary score allocates colours - the initial colour of `152` (or
      the one round 1 shows), the round count of `142`/`XXR`, the teams
      sitting the round out passed as absent, and the teams the file keeps
      apart (`XXO team-forbidden` / `XXO team-soft-pairs`, plus the
      command line's `--team-forbidden` / `--team-soft-pairs`) as
      `:forbidden_pairs` / `:soft_pairs` - the organiser's rule, not
      C.04.6, and announced as such;
    * a team round robin (`192 BERGER_TEAM_ROUNDROBIN_Gn` and its aliases,
      or a `092` round robin whose games show teams) is given the next
      round of the Berger table (`Ainalrami.Berger`).

  ## The output (`-p`)

  JaVaFo's pairing list, one level up - a count line and one line per
  match, CRLF throughout:

      3            matches in the round, the bye counted as one
      1 4          the team with White on board 1, then its opponent
      5 2
      3 0          a team with no opponent: the pairing-allocated bye
                   (Swiss) or the Berger table's free round (round robin)

  Matches come in C.04.2 3.6's recommended order (the higher score of the
  pair's first team, then the higher sum of both scores, then the smaller
  number of the first team) for a Swiss, and by the lower team number for
  a round robin; the bye last. Team numbers are the `310` numbers (file
  order for `013` teams).

  With `--lineups` the boards follow, as a second block:

      12           board lines
      1 1 3 17     match (line number above, from 1), board, White, Black
      1 2 18 4     - players' starting ranks, 0 for a board nobody fills

  A team's players are seated in the order of a `300` record for the round
  when the file has one, otherwise its free players in roster order - a
  player is not free when the file already records a bye for them in the
  round being paired - and the team with White on board 1 has White on
  every odd board. The number of boards is the file's TRF26 `352` colour
  sequence, else the most any match of the file had, or `--boards=N` (needed before round 1 has been played).
  """

  alias Ainalrami.{Log, TeamPairing, TeamReplay}
  alias Ainalrami.TeamPairing.Team

  @doc """
  Pairs the next round. `system` is `TeamReplay.system/1`'s `{:team, _}` or
  `{:team_round_robin, _}`. Options: `:explain` (record the engine's
  reasons), `:boards`, and for a Swiss `:max_upfloater_sets` and
  `:explain_limit`, passed to `Ainalrami.TeamPairing.pair_round/2`. Returns `{:ok, round}` or `{:error, message}`.
  """
  def pair(parsed, system, opts \\ []) do
    history = TeamReplay.history(parsed)

    case system do
      {:team, settings} -> pair_swiss(parsed, history, settings, opts)
      {:team_round_robin, settings} -> pair_round_robin(parsed, history, settings)
    end
  end

  defp pair_swiss(parsed, history, settings, opts) do
    next = TeamReplay.next_round(parsed, history, settings)
    expected = parsed.tournament[:number_of_rounds]

    {colour, source} =
      TeamReplay.initial_colour(history, parsed.tournament, settings, expected_rounds: expected)

    engine_opts = [
      score_mode: settings.score_mode,
      use_secondary?: settings.use_secondary?,
      type: settings.type,
      initial_colour: colour,
      absent: next.absent,
      round: next.round,
      expected_rounds: expected,
      explain: Keyword.get(opts, :explain, false)
    ]

    # `Ainalrami.TeamPairing`'s own budget and explanation bound, when the
    # caller gives them; otherwise the list above is the whole of it.
    engine_opts =
      engine_opts ++
        Keyword.take(opts, [:max_upfloater_sets, :explain_limit]) ++
        keep_apart_opts(parsed.tournament)

    cond do
      unknown = unknown_team(parsed, parsed.tournament) ->
        {:error, unknown}

      length(next.field) < 2 ->
        {:error,
         "round #{next.round}: fewer than two teams have a player free to play " <>
           "(#{length(next.field)} of #{length(next.field) + length(next.out)})"}

      true ->
        case TeamPairing.pair_round(next.teams, engine_opts) do
          {:ok, result} ->
            by_tpn = Map.new(next.teams, &{&1.tpn, &1})

            {:ok,
             %{
               system: :swiss,
               settings: settings,
               round: next.round,
               expected_rounds: expected,
               initial_colour: {colour, source},
               field: next.field,
               out: next.out,
               absent: next.absent,
               teams: next.teams,
               matches:
                 result.pairs
                 |> order(by_tpn, settings.score_mode)
                 |> Enum.map(&{&1.white, &1.black}),
               bye: result.bye,
               keep_apart: keep_apart_opts(parsed.tournament),
               result: result
             }}

          {:error, reason} ->
            {:error, "round #{next.round}: no pairing - #{describe_refusal(reason)}"}
        end
    end
  end

  defp pair_round_robin(parsed, history, settings) do
    round = TeamReplay.paired_rounds(history) + 1

    case TeamReplay.berger_round(history, round, settings) do
      {:ok, pairs, free} ->
        {:ok,
         %{
           system: :round_robin,
           settings: settings,
           round: round,
           teams_count: map_size(history),
           matches: Enum.sort_by(pairs, fn {w, b} -> min(w, b) end),
           bye: free,
           field: Map.keys(history) |> Enum.sort(),
           out: [],
           parsed: parsed
         }}

      {:error, {:all_rounds_paired, total}} ->
        {:error, "every round of the Berger table is paired (#{total})"}

      {:error, :too_few_teams} ->
        {:error, "a round robin needs at least two teams"}
    end
  end

  # C.04.2 3.6: the higher score of the pair's first team, then the higher
  # sum of both scores, then the smaller number of the first team.
  defp order(pairs, by_tpn, mode) do
    score = fn tpn -> Team.score(Map.fetch!(by_tpn, tpn), mode) end

    Enum.sort_by(pairs, fn p ->
      {-score.(p.first_team), -(score.(p.white) + score.(p.black)), p.first_team}
    end)
  end

  defp describe_refusal(:no_legal_pairing),
    do: "no pairing complies with the absolute criteria (C.04.6 3.3.3: the Chief Arbiter decides)"

  defp describe_refusal(:no_legal_bye),
    do:
      "no team can take the pairing-allocated bye and leave the rest pairable " <>
        "(C.04.6 3.3.3: the Chief Arbiter decides)"

  defp describe_refusal(:budget_exhausted),
    do: "the upfloater search ran past its budget (:max_upfloater_sets)"

  defp describe_refusal({:forbidden_pairs, %{groups: groups, lifting: lifting}}) do
    lifted =
      case lifting do
        [] -> "no single group lifted on its own would do"
        list -> "lifting any one of " <> Enum.map_join(list, ", ", &group/1) <> " would"
      end

    "the teams kept apart (team-forbidden: " <>
      Enum.map_join(groups, ", ", &group/1) <>
      ") leave no legal pairing, and without them the round pairs - #{lifted}"
  end

  defp describe_refusal(other), do: inspect(other)

  defp group(tpns), do: "[#{Enum.join(tpns, " ")}]"

  defp group_text({tpns, first, last}), do: "#{group(tpns)} rounds #{first}-#{last}"
  defp group_text(tpns), do: group(tpns)

  @doc """
  The teams a file (and the command line, which adds to the same keys)
  keeps apart, as `Ainalrami.TeamPairing.pair_round/2`'s options:
  `tournament[:team_forbidden_pairs]` as `:forbidden_pairs` and
  `tournament[:team_soft_pairs]` as `:soft_pairs`, each only when there is
  something in it - so a file without them is paired with exactly the
  options it always was.
  """
  def keep_apart_opts(tournament) do
    [forbidden_pairs: :team_forbidden_pairs, soft_pairs: :team_soft_pairs]
    |> Enum.flat_map(fn {option, key} ->
      case Map.get(tournament, key) do
        [_ | _] = groups -> [{option, groups}]
        _ -> []
      end
    end)
  end

  @doc """
  The first team number a `team-forbidden`/`team-soft-pairs` group names
  that the file has no team for, as a message, or nil.
  """
  def unknown_team(parsed, tournament) do
    known = parsed |> TeamReplay.team_numbers() |> MapSet.new()

    Enum.find_value([team_forbidden_pairs: "forbidden", team_soft_pairs: "soft-pairs"], fn
      {key, word} ->
        tournament
        |> Map.get(key, [])
        |> Enum.flat_map(fn
          {tpns, _first, _last} -> tpns
          tpns -> tpns
        end)
        |> Enum.find(&(not MapSet.member?(known, &1)))
        |> case do
          nil -> nil
          tpn -> "team-#{word} names team #{tpn}, which the file does not have"
        end
    end)
  end

  @doc "The team pairing list - see the moduledoc's \"The output\"."
  def format_pairs(round) do
    lines =
      Enum.map(round.matches, fn {w, b} -> "#{w} #{b}" end) ++
        if(round.bye, do: ["#{round.bye} 0"], else: [])

    Enum.map_join(["#{length(lines)}" | lines], "", &(&1 <> "\r\n"))
  end

  @doc """
  The board block of `--lineups`: `{:ok, text}` or `{:error, message}`
  when the number of boards is not known.
  """
  def format_lineups(parsed, round, boards_option) do
    case boards_option || TeamReplay.boards(parsed) do
      nil ->
        {:error,
         "--lineups needs the number of boards, and no match in the file says it - " <>
           "give it as --boards=N"}

      boards ->
        lines =
          for {{w, b}, match} <- Enum.with_index(round.matches, 1),
              {{white_team_player, black_team_player}, board} <-
                Enum.with_index(
                  Enum.zip(
                    TeamReplay.lineup(parsed, w, round.round, boards),
                    TeamReplay.lineup(parsed, b, round.round, boards)
                  ),
                  1
                ) do
            {white, black} =
              if rem(board, 2) == 1,
                do: {white_team_player, black_team_player},
                else: {black_team_player, white_team_player}

            "#{match} #{board} #{white || 0} #{black || 0}"
          end

        {:ok, Enum.map_join(["#{length(lines)}" | lines], "", &(&1 <> "\r\n"))}
    end
  end

  @doc "Trace lines for a paired round (stderr, at the normal level)."
  def report(round) do
    case round.system do
      :swiss ->
        Log.detail("C.04.6 team Swiss - #{TeamReplay.describe(round.settings)}")
        {colour, source} = round.initial_colour

        Log.detail(
          "initial colour #{colour}" <>
            if(source == :file, do: " (152)", else: " (no 152: White unless round 1 shows Black)")
        )

      :round_robin ->
        Log.detail(TeamReplay.describe(round.settings))
    end

    Log.detail("pairing team round #{round.round}")

    for {option, groups} <- Map.get(round, :keep_apart, []) do
      what =
        if option == :forbidden_pairs,
          do: "never paired",
          else: "kept apart where no FIDE criterion minds"

      Log.detail(
        "#{what} (the organiser's rule, not C.04.6): " <>
          Enum.map_join(groups, ", ", &group_text/1)
      )
    end

    unless round.out == [] do
      Log.detail(
        "sitting the round out (a 240 team bye, or every player has a bye recorded): " <>
          Enum.map_join(round.out, ", ", &"team #{&1}")
      )
    end

    for {w, b} <- round.matches, do: Log.detail("team #{w} (white on board 1) vs. team #{b}")

    if round.bye do
      Log.detail(
        if(round.system == :swiss,
          do: "team #{round.bye} - pairing-allocated bye",
          else: "team #{round.bye} - free round (Berger table)"
        )
      )
    end
  end

  # ---- -x ------------------------------------------------------------------

  @doc "The `-x` account of a paired team round."
  def render_explanation(%{system: :round_robin} = round) do
    """

    Round #{round.round} - #{length(round.matches)} match#{es(length(round.matches))}, round #{round.round} of the Berger table for #{round.teams_count} teams
      #{TeamReplay.describe(round.settings)}
      Nothing is chosen: the table fixes every match and its colours (the
      first-named team has White on board 1).
    #{Enum.map_join(round.matches, "", fn {w, b} -> "  team #{w} (white) vs. team #{b}\n" end)}#{if round.bye, do: "  team #{round.bye}: free round\n", else: ""}
    """
  end

  def render_explanation(%{system: :swiss} = round) do
    explanation = round.result.explanation
    mode = round.settings.score_mode
    last_round? = last_round?(round)

    teams =
      Enum.map_join(round.teams, "", fn t ->
        flags =
          [
            t.had_pab? && "had bye",
            t.won_by_forfeit? && "won by forfeit",
            t.floated_last_round? && "floated",
            Team.accelerated?(t) &&
              "virtual +#{fmt(t.virtual_match_points)} MP" <>
                if(t.virtual_game_points == 0, do: "", else: " +#{fmt(t.virtual_game_points)} GP")
          ]
          |> Enum.filter(& &1)
          |> Enum.join(", ")

        "  #{pad(t.tpn, 4)} #{pad(fmt(t.match_points), 6)} #{pad(fmt(t.game_points), 6)} " <>
          "#{String.pad_trailing(colours(t.colours), 12)} " <>
          "#{String.pad_trailing(preference(Team.preference(t, round.settings.type, last_round?)), 15)}" <>
          "#{flags}\n"
      end)

    header =
      "\nRound #{round.round} - #{length(round.matches)} match#{es(length(round.matches))}" <>
        if(round.bye, do: ", bye team #{round.bye}", else: "") <>
        "\n  #{TeamReplay.describe(round.settings)}\n" <>
        if(round.absent == [],
          do: "",
          else: "  absent (arrived, out this round): #{Enum.join(round.absent, ", ")}\n"
        )

    header <>
      "\nTeams going in (#{score_name(mode)} primary)\n" <>
      "   TPN     MP     GP colours      preference    \n" <>
      teams <>
      render_bye(explanation.bye) <>
      Enum.map_join(Enum.with_index(explanation.brackets, 1), "", &render_bracket(&1, round)) <>
      render_colours(explanation.pairs)
  end

  defp last_round?(%{expected_rounds: expected, round: round}),
    do: is_integer(expected) and round >= expected

  defp render_bye(nil), do: "\nNo pairing-allocated bye (an even field)\n"

  defp render_bye(bye) do
    ineligible =
      case bye.ineligible do
        [] ->
          ""

        list ->
          "  barred by [C2]: " <>
            Enum.map_join(list, ", ", fn i ->
              "#{i.tpn} (#{Enum.map_join(i.reasons, ", ", &reason/1)})"
            end) <> omitted(bye.ineligible_omitted) <> "\n"
      end

    passed =
      case bye.passed_over do
        [] ->
          ""

        list ->
          "  tried first, would leave the rest unpairable (3.4.1): " <>
            Enum.map_join(list, ", ", & &1.tpn) <> omitted(bye.passed_over_omitted) <> "\n"
      end

    decided =
      case {bye.next, bye.decided_by} do
        {nil, _} -> "  nobody else could take it\n"
        {next, rule} -> "  ahead of team #{next.tpn} by #{rule}\n"
      end

    "\nPairing-allocated bye (3.4): team #{bye.tpn} " <>
      "(score #{fmt(bye.score)}, #{bye.matches_played} match#{es(bye.matches_played)} played)\n" <>
      ineligible <> passed <> decided
  end

  defp render_bracket({account, index}, round) do
    bracket = Enum.at(round.result.brackets, index - 1)
    selection = account.selection

    pairs = Enum.map_join(bracket.pairs, ", ", fn {a, b} -> "#{a}-#{b}" end)

    chosen =
      case selection do
        %{chosen: chosen} when is_map(chosen) -> "  upfloaters chosen: #{set(chosen)}\n"
        _ -> ""
      end

    runner_up =
      case selection do
        %{runner_up: r} when is_map(r) -> "  runner-up: #{set(r)}\n"
        _ -> ""
      end

    decided =
      case selection do
        %{decided_by: rule} when is_binary(rule) -> "  decided by #{rule}\n"
        _ -> ""
      end

    rejected =
      case selection do
        %{rejected: [_ | _] = list} = sel ->
          "  rejected (no legal pairing): " <>
            Enum.map_join(list, "; ", fn r -> "[#{Enum.join(r.upfloaters, ", ")}] #{r.failed}" end) <>
            omitted(Map.get(sel, :rejected_omitted, 0)) <> "\n"

        _ ->
          ""
      end

    "\nBracket #{index} · score #{fmt(account.score)} · residents #{Enum.join(account.residents, ", ")}" <>
      if(account.upfloaters == [],
        do: "",
        else: " · upfloaters #{Enum.join(account.upfloaters, ", ")}"
      ) <>
      "\n" <>
      chosen <> runner_up <> decided <> rejected <> "  pairs: #{pairs}\n" <> soft_line(bracket)
  end

  # Only a round paired with soft pairs has the count.
  defp soft_line(%{soft: soft}), do: "  soft pairs it could not avoid: #{soft}\n"
  defp soft_line(_bracket), do: ""

  defp render_colours(pairs) do
    "\nColours (Article 4)\n" <>
      Enum.map_join(pairs, "", fn p ->
        "  team #{p.white} (white) vs. team #{p.black}: first team #{p.first_team} " <>
          "(#{p.first_team_rule}), colours by #{p.colour_rule}\n"
      end)
  end

  defp set(set) do
    extra =
      [
        "C4 #{set.c4}",
        "C5 [#{Enum.map_join(set.c5, ", ", &fmt/1)}]",
        set[:c6] != nil && "C6 #{set.c6}",
        set[:c7] != nil && "C7 #{set.c7}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    "[#{Enum.join(set.upfloaters, ", ")}] (#{extra})"
  end

  defp reason(:had_pab), do: "had the bye"
  defp reason(:won_by_forfeit), do: "won by forfeit"
  defp reason(other), do: to_string(other)

  defp omitted(0), do: ""
  defp omitted(n), do: " (+#{n} more)"

  defp colours(list), do: Enum.map_join(list, "", &if(&1 == :white, do: "W", else: "B"))

  defp preference(:none), do: "-"
  defp preference({colour, strength}), do: "#{colour} (#{strength})"

  defp score_name(:match_points), do: "match points"
  defp score_name(:game_points), do: "game points"

  defp fmt(x) when is_float(x) do
    if x == Float.round(x), do: :erlang.float_to_binary(x, decimals: 1), else: to_string(x)
  end

  defp fmt(x), do: to_string(x)

  defp pad(x, n), do: String.pad_leading(to_string(x), n)

  defp es(1), do: ""
  defp es(_), do: "es"
end

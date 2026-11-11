defmodule Ainalrami.TeamForfeitBoardLinesTest do
  @moduledoc """
  A match forfeited as a whole (TRF26 `330 +-` / `-+`) is written on the
  players' lines too: the winners `+` against the board's player of the
  absent team, who gets the `-` (TRF-2026 record 330, Notes 1 and 2). A
  reader that adds up game points from the `001` lines (Gacrux) then sees
  the winners' forfeit wins, as Mario Held's TPS example scores them
  (`0F-4F`).

  The board lines must not change what the file means. Each file is read
  as written and again with those board lines blanked - the `330` alone,
  as the writer used to leave it - and both readings must agree on every
  match: the result, the match and game points, the won-by-forfeit flag,
  and the engine's input for every round, [C2]'s bye eligibility included.
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{TeamGenerator, TeamReplay, Tiebreaks, Trf}

  @swiss_seeds 1..40
  @rr_seeds 1..25

  defp events do
    swiss =
      for seed <- @swiss_seeds do
        TeamGenerator.run(seed: seed, system: :swiss, match_forfeit_pct: 30)
      end

    rr =
      for seed <- @rr_seeds do
        TeamGenerator.run(
          seed: seed,
          system: :round_robin,
          match_forfeit_pct: 20,
          absent_team_pct: 15
        )
      end

    swiss ++ rr
  end

  # The one-sided forfeits of a file: `{round, winner, loser}`.
  defp one_sided(parsed) do
    for f <- parsed.tournament[:forfeited_matches] || [], f.type in ["+-", "-+"] do
      if f.type == "+-", do: {f.round, f.white, f.black}, else: {f.round, f.black, f.white}
    end
  end

  defp team_of(parsed) do
    for t <- parsed.teams, rank <- t.player_ranks, into: %{}, do: {rank, t.number}
  end

  # The file with the forfeited matches' board lines blanked: the `330`
  # record alone.
  defp without_board_lines(parsed) do
    team_of = team_of(parsed)
    cells = for {r, w, l} <- one_sided(parsed), t <- [w, l], into: MapSet.new(), do: {r, t}

    players =
      Enum.map(parsed.players, fn p ->
        games =
          p.games
          |> Enum.with_index(1)
          |> Enum.map(fn {g, r} ->
            if MapSet.member?(cells, {r, team_of[p.rank]}) and g.result in ["+", "-"],
              do: %{opponent_rank: nil, colour: nil, result: ""},
              else: g
          end)

        points =
          games
          |> Enum.map(&Map.get(%{"1" => 1.0, "=" => 0.5, "+" => 1.0, "U" => 1.0}, &1.result, 0.0))
          |> Enum.sum()

        %{p | games: games, points: points}
      end)

    Trf.parse(Trf.serialize(%{parsed | players: players}, dialect: :trf26))
  end

  test "the generator writes forfeited matches on the players' lines" do
    found =
      for g <- events(), parsed = Trf.parse(g.text), {r, w, l} <- one_sided(parsed) do
        team_of = team_of(parsed)

        winners =
          for p <- parsed.players,
              team_of[p.rank] == w,
              game = Enum.at(p.games, r - 1) || %{result: ""},
              game.result == "+",
              do: {p.rank, game}

        assert length(winners) == g.boards,
               "seed #{g.seed} round #{r}: #{length(winners)} winners' lines for #{g.boards} boards"

        by_rank = Map.new(parsed.players, &{&1.rank, &1})

        for {rank, game} <- winners do
          assert team_of[game.opponent_rank] == l
          assert game.colour in ["w", "b"]

          theirs = Enum.at(by_rank[game.opponent_rank].games, r - 1)
          assert theirs.result == "-"
          assert theirs.opponent_rank == rank
          assert theirs.colour == if(game.colour == "w", do: "b", else: "w")
        end

        :ok
      end

    # Enough forfeits to mean something, absent round-robin teams among them.
    assert length(found) > 100
  end

  test "a double forfeit gets no winner on the boards" do
    for g <- events(),
        parsed = Trf.parse(g.text),
        f <- parsed.tournament[:forfeited_matches] || [],
        f.type == "--" do
      team_of = team_of(parsed)

      for p <- parsed.players, team_of[p.rank] in [f.white, f.black] do
        assert (Enum.at(p.games, f.round - 1) || %{result: ""}).result in ["", nil, "Z", "-"]
      end
    end
  end

  test "write -> read: the same matches, points and won-by-forfeit flags" do
    for g <- events() do
      with_lines = Trf.parse(g.text)
      bare = without_board_lines(with_lines)

      a = Tiebreaks.Team.from_trf(with_lines)
      b = Tiebreaks.Team.from_trf(bare)

      for {team, entry} <- a.teams, {r, m} <- entry.rounds do
        other = b.teams[team].rounds[r]

        assert {m.kind, m.opponent, m.mp, m.gp} ==
                 {other.kind, other.opponent, other.mp, other.gp},
               "seed #{g.seed} (#{g.system}) team #{team} round #{r}"
      end

      for {_r, winner, loser} <- one_sided(with_lines) do
        assert Enum.any?(Map.values(a.teams[winner].rounds), &(&1.kind == :forfeit_win))
        refute is_nil(a.teams[loser])
      end

      ha = TeamReplay.history(with_lines)
      hb = TeamReplay.history(bare)

      for {team, rounds} <- ha, {r, rec} <- rounds do
        theirs = hb[team][r]

        assert Map.take(rec, [:kind, :opponent, :played?, :mp, :gp, :forfeit_win?, :full_bye?]) ==
                 Map.take(theirs, [
                   :kind,
                   :opponent,
                   :played?,
                   :mp,
                   :gp,
                   :forfeit_win?,
                   :full_bye?
                 ]),
               "seed #{g.seed} (#{g.system}) team #{team} round #{r}"
      end
    end
  end

  test "the engine's input, [C2]'s bye eligibility included, is unchanged" do
    for g <- events(), g.system == :swiss do
      with_lines = Trf.parse(g.text)
      bare = without_board_lines(with_lines)
      {:team, settings} = TeamReplay.system(with_lines)

      ha = TeamReplay.history(with_lines)
      hb = TeamReplay.history(bare)

      for r <- 1..(g.rounds + 1)//1 do
        {ta, absent_a} = TeamReplay.state_before(ha, min(r, g.rounds), settings)
        {tb, absent_b} = TeamReplay.state_before(hb, min(r, g.rounds), settings)

        assert absent_a == absent_b
        assert ta == tb, "seed #{g.seed} round #{r}"

        # [C2]: neither a previous bye nor a forfeit win.
        eligible = fn teams ->
          for t <- teams, not t.had_pab?, not t.won_by_forfeit?, do: t.tpn
        end

        assert eligible.(ta) == eligible.(tb)
      end

      for r <- 1..g.rounds//1 do
        assert TeamReplay.check_round(ha, r, settings) == TeamReplay.check_round(hb, r, settings)
      end
    end
  end
end

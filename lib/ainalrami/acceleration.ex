defmodule Ainalrami.Acceleration do
  @moduledoc """
  Virtual points, worked out rather than read: FIDE C.04.7's Baku
  acceleration from a round count, and an arbitrary table of them.

  The pairing engine takes acceleration as data - each player's
  `:accelerations` list, one value per round, which is what an `XXA` line
  parses to (`Ainalrami.Pairing.pair_next_round/2`). It does not derive
  C.04.7's groups: the host does, and writes them down. This module is that
  derivation for a caller with no host - the standalone CLI's
  `--acceleration=baku` and `--virtual-points=` - and it is the reading
  OpenPairings and `Ainalrami.Generator` use, which the tests hold it to.

  ## Baku (C.04.7)

    * Group A is the top half of the starting list, rounded up to an even
      number: `2 * ceil(n / 4)` players, the lowest starting ranks.
    * The accelerated rounds are the first `ceil(rounds / 2)`.
    * In the first `ceil(accelerated / 2)` of those a Group A player has one
      virtual point, in the rest of them a half, afterwards none. FIDE's own
      example: nine rounds, five accelerated, 1 1 1 ½ ½.

  Group A is fixed when round one is paired. A late entrant does not grow
  it, which a program counting today's roster would get wrong - so the
  group's last starting rank can be given (`:group_a_last`), and has to be
  for a field that grew.

  bbpPairings' own Baku flag sizes Group A as `ceil(n / 2)` - 5, not 6, of
  10. That path is not this one; see `Ainalrami.Generator`.

  ## Team Swiss (C.04.6 with C.04.7)

  `team_baku_table/3` and `team_baku/3`: the same groups and rounds, over
  teams by Team Pairing Number, in MATCH points - a Group A team gets a
  match win's worth (2 under C.04.6 1.2.2), then a draw's. C.04.7's own
  Example 2 is an 11-round team competition on match points: two virtual
  matchpoints in rounds 1-3, one in rounds 4-6. Its footnote rules out game
  points as the primary score, so there are no virtual game points here.
  What is FIDE's text and what is our reading: `docs/team-baku.md`.
  """

  alias Ainalrami.Trf

  @doc """
  How many players C.04.7 puts in Group A of a field of `count`.
  """
  def baku_group_size(count) when is_integer(count) and count >= 0,
    do: min(count, 2 * ceil_div(count, 4))

  @doc """
  A Group A player's virtual points for rounds `1..through` of an event of
  `total_rounds`.
  """
  def baku_points(total_rounds, through)
      when is_integer(total_rounds) and total_rounds >= 1 and is_integer(through) do
    accelerated = ceil_div(total_rounds, 2)
    full = ceil_div(accelerated, 2)

    Enum.map(1..through//1, fn round ->
      cond do
        round <= full -> 1.0
        round <= accelerated -> 0.5
        true -> 0.0
      end
    end)
  end

  @doc """
  `players` with C.04.7's virtual points on Group A, as `:accelerations`.

  Options:

    * `:group_a_last` - the last starting rank of Group A. Default: the
      rank of the `baku_group_size/1`-th player of `players` by starting
      rank, which is right for a field nobody joined late.
    * `:through` - the last round to give a value for. Default: the later
      of `total_rounds` and the round about to be paired, so every round
      the engine can ask about has one.

  Raises `ArgumentError` when a player already carries virtual points: two
  accelerations at once is a question, not an instruction.
  """
  def baku(players, total_rounds, opts \\ [])
      when is_list(players) and is_integer(total_rounds) and total_rounds >= 1 do
    refuse_existing!(players)

    last =
      case Keyword.get(opts, :group_a_last) do
        nil ->
          players
          |> Enum.map(& &1.rank)
          |> Enum.sort()
          |> Enum.at(baku_group_size(length(players)) - 1)

        rank when is_integer(rank) and rank >= 0 ->
          rank

        other ->
          raise ArgumentError, ":group_a_last must be a starting rank, got #{inspect(other)}"
      end

    through =
      Keyword.get_lazy(opts, :through, fn ->
        max(total_rounds, Trf.rounds_played(players) + 1)
      end)

    points = baku_points(total_rounds, through)

    Enum.map(players, fn player ->
      if is_integer(last) and player.rank <= last,
        do: Map.put(player, :accelerations, points),
        else: player
    end)
  end

  @doc """
  `players` with the virtual points of `table` - `%{rank => [points per
  round]}` - as `:accelerations`. Not C.04.7: whatever the organiser's
  scheme is, written out.

  Raises `ArgumentError` for a rank the roster does not have, a value that
  is not a non-negative number, and a player who already carries virtual
  points.
  """
  def virtual_points(players, table) when is_list(players) and is_map(table) do
    refuse_existing!(players)
    ranks = MapSet.new(players, & &1.rank)

    for {rank, values} <- table do
      unless MapSet.member?(ranks, rank) do
        raise ArgumentError, "virtual points name #{inspect(rank)}, which is not a starting rank"
      end

      unless is_list(values) and Enum.all?(values, &(is_number(&1) and &1 >= 0)) do
        raise ArgumentError,
              "virtual points for #{rank} must be non-negative numbers, one per round, " <>
                "got #{inspect(values)}"
      end
    end

    Enum.map(players, fn player ->
      case Map.fetch(table, player.rank) do
        {:ok, values} -> Map.put(player, :accelerations, Enum.map(values, &(&1 / 1)))
        :error -> player
      end
    end)
  end

  @doc """
  C.04.7's virtual points for a team Swiss: `%{tpn => [{match_points,
  game_points}, ...]}`, one pair per round from round 1, for every Group A
  team - the shape TRF-2026's `250` records carry
  (`tournament[:team_accelerations]` in `Ainalrami.Trf`).

  `team_count` is the number of teams in the event when round 1 was paired;
  Group A is TPNs `1..2 * ceil(team_count / 4)` (C.04.7 1.2). Options:

    * `:group_a_last` - the last TPN of Group A, in place of the count's
      (a late entrant does not grow the group, C.04.7 1.3);
    * `:through` - the last round to give a value for (default
      `total_rounds`);
    * `:match_points` - the event's `{win, draw, loss}` for a match
      (default `{2, 1, 0}`, C.04.6 1.2.2). C.04.7 1.1 applies the method
      only where a win is worth two draws and a loss nothing; anything else
      raises `ArgumentError`.
  """
  def team_baku_table(team_count, total_rounds, opts \\ [])
      when is_integer(team_count) and team_count >= 0 and is_integer(total_rounds) and
             total_rounds >= 1 do
    win = baku_win!(Keyword.get(opts, :match_points, {2.0, 1.0, 0.0}))

    last =
      case Keyword.get(opts, :group_a_last) do
        nil -> baku_group_size(team_count)
        tpn when is_integer(tpn) and tpn >= 0 -> tpn
        other -> raise ArgumentError, ":group_a_last must be a TPN, got #{inspect(other)}"
      end

    through = Keyword.get(opts, :through, total_rounds)
    row = Enum.map(baku_points(total_rounds, through), &{&1 * win, 0.0})

    Map.new(1..last//1, &{&1, row})
  end

  @doc """
  `teams` (`%Ainalrami.TeamPairing.Team{}`) with C.04.7's virtual points
  for the round being paired, ready for `Ainalrami.TeamPairing.pair_round/2`.

  Options: `:round` (required), and one of `:team_count` or
  `:group_a_last` - required, because the teams being paired are one
  round's field, and a field with a team sitting out is not the event
  Group A was cut from. `:match_points` as in `team_baku_table/3`.
  """
  def team_baku(teams, total_rounds, opts) when is_list(teams) do
    round = Keyword.fetch!(opts, :round)
    count = Keyword.get(opts, :team_count)

    if count == nil and Keyword.get(opts, :group_a_last) == nil do
      raise ArgumentError,
            "team_baku/3 needs :team_count or :group_a_last - the round's field is not " <>
              "the event Group A was cut from"
    end

    table =
      team_baku_table(
        count || 0,
        total_rounds,
        Keyword.take(opts, [:group_a_last, :match_points]) ++ [through: max(round, total_rounds)]
      )

    team_virtual_points(teams, table, round)
  end

  @doc """
  `teams` with the virtual points `table` (`%{tpn => [{match_points,
  game_points}, ...]}`, `team_baku_table/3`'s shape, or a file's `250`
  records) gives them in `round`. A team the table does not name, or names
  for fewer rounds, gets none. Raises `ArgumentError` for a team that
  already carries virtual points.
  """
  def team_virtual_points(teams, table, round)
      when is_list(teams) and is_map(table) and is_integer(round) and round >= 1 do
    Enum.map(teams, fn team ->
      if Ainalrami.TeamPairing.Team.accelerated?(team) do
        raise ArgumentError, "team #{team.tpn} already carries virtual points"
      end

      case table |> Map.get(team.tpn, []) |> Enum.at(round - 1) do
        {mp, gp} -> %{team | virtual_match_points: mp * 1.0, virtual_game_points: gp * 1.0}
        nil -> team
      end
    end)
  end

  defp baku_win!({win, draw, loss}) when is_number(win) and is_number(draw) and is_number(loss) do
    if win == 2 * draw and loss == 0 and win > 0 do
      win * 1.0
    else
      raise ArgumentError,
            "C.04.7 1.1: the Baku Acceleration Method needs a win worth two draws and a " <>
              "loss worth nothing, not #{format_triple({win, draw, loss})}"
    end
  end

  defp baku_win!(other),
    do: raise(ArgumentError, ":match_points must be {win, draw, loss}, got #{inspect(other)}")

  defp format_triple({w, d, l}), do: "#{w}/#{d}/#{l}"

  @doc "Whether any player carries virtual points."
  def accelerated?(players),
    do: Enum.any?(players, &(Map.get(&1, :accelerations) not in [nil, []]))

  defp refuse_existing!(players) do
    if accelerated?(players) do
      raise ArgumentError,
            "the players already carry virtual points (:accelerations, a file's XXA or 250)"
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end

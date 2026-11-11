defmodule Ainalrami.TeamHeldExampleTest do
  @moduledoc """
  Mario Held's "Mastering the FIDE Team Pairing System" (Venice, 2026)
  pairs a sixteen-team, nine-round C.04.6 event by hand from start to
  finish. This replays it: for each round the teams' state is built from
  his crosstable (Appendix I) as it stood before the round, the engine pairs
  it, and the pairing, the bye AND every board-1 colour must be his.

  Settings as the example states them: Type A, initial colour White (4.1),
  match points primary, game points secondary. PAB and half-point bye 1 MP
  + 2 GP, zero-point bye nothing.

  Round 1 is paired on provisional numbers 1-13: the three teams that took
  a half-point bye in round 1 (final 9, 12, 14) have no number yet and are
  simply not in it. Final 1-8 keep theirs; 10, 11, 13, 15, 16 are 9-13.
  From round 2 everyone has a final number. A team on a half-point or
  zero-point bye in a later round has arrived and is passed as `absent:`
  (7 in round 3, 11 in round 5, 16 in round 9).

  Round 4's 8-15 is a forfeit (0F-4F): no meeting (C.04.2 3.5 - an
  unplayed pairing may be repeated), no colour, nobody's float, and 15 won
  it by forfeit for [C2].
  """
  use ExUnit.Case, async: true

  alias Ainalrami.TeamPairing
  alias Ainalrami.TeamPairing.Team

  # TPN, then per round: result/colour/opponent, MP after it, GP after it.
  @crosstable """
  1 +W7 2 3 +B4 4 5.5 =W2 5 7.5 =W3 6 9.5 +B6 8 12 =B5 9 14 +W11 11 17.5 =B10 12 19.5 +B9 14 22
  2 +B8 2 2.5 =W5 3 4.5 =B1 4 6.5 +B10 6 9.5 =W3 7 11.5 +W4 9 14 =B6 10 16 +W11 12 19 +B7 14 22
  3 =W10 1 2 +B6 3 5 +W9 5 8 =B1 6 10 =B2 7 12 +W7 9 15 =B4 10 17 +W5 12 19.5 =B8 13 21.5
  4 +B11 2 3 -W1 2 4.5 +B8 4 7 =W5 5 9 +W10 7 12 -B2 7 13.5 =W3 8 15.5 =B6 9 17.5 +B12 11 21
  10 =B3 1 2 +W16 3 6 +B5 5 9 -W2 5 10 -B4 5 11 =W6 6 13 +B7 8 15.5 =W1 9 17.5 =B11 10 19.5
  5 +W13 2 2.5 =B2 3 4.5 -W10 3 5.5 =B4 4 7.5 =B9 5 9.5 =W1 6 11.5 +W14 8 14.5 -B3 8 16 +W15 10 19
  6 +B15 2 3.5 -W3 2 4.5 =B11 3 6.5 +W12 5 9 -W1 5 10.5 =B10 6 12.5 =W2 7 14.5 =W4 8 16.5 +B14 10 19
  9 HPB 1 2 +W14 3 5 -B3 3 6 =B13 4 8 =W5 5 10 -B11 5 11.5 =W8 6 13.5 +B16 8 16.5 -W1 8 18
  7 -B1 0 1 +W12 2 3.5 HPB 3 5.5 =W11 4 7.5 +B13 6 10.5 -B3 6 11.5 -W10 6 13 +B14 8 16 -W2 8 17
  8 -W2 0 1.5 =B13 1 3.5 -W4 1 5 -F15 1 5 PAB 2 7 +B16 4 10.5 =B9 5 12.5 +W12 7 15 =W3 8 17
  11 -W4 0 1 +B15 2 3.5 =W6 3 5.5 =B7 4 7.5 HPB 5 9.5 +W9 7 12 -B1 7 12.5 -B2 7 13.5 =W10 8 15.5
  13 -B5 0 1.5 =W8 1 3.5 +B16 3 6.5 =W9 4 8.5 -W7 4 9.5 -B14 4 10.5 =W12 5 12.5 =B15 6 14.5 PAB 7 16.5
  12 HPB 1 2 -B7 1 3.5 +W14 3 7 -B6 3 8.5 -W16 3 10 +W15 5 13 =B13 6 15 -B8 6 16.5 -W4 6 17
  15 -W6 0 0.5 -W11 0 2 PAB 1 4 +F8 3 8 =B14 4 10 -B12 4 11 =W16 5 13 =W13 6 15 -B5 6 16
  14 HPB 1 2 -B9 1 3 -B12 1 3.5 +W16 3 6 =W15 4 8 +W13 6 11 -B5 6 12 -W7 6 13 -W6 6 14.5
  16 PAB 1 2 -B10 1 2 -W13 1 3 -B14 1 4.5 +B12 3 7 -W8 3 7.5 =B15 4 9.5 -W9 4 10.5 ZPB 4 10.5
  """

  # The forfeited pairings, which the crosstable gives no colour: round 4's
  # as Held pairs it before the forfeit ("8-15", in the Fourth Round chapter).
  @forfeited %{4 => [{8, 15}]}

  # Final number => provisional number for round 1.
  @round_one %{1 => 1, 2 => 2, 3 => 3, 4 => 4, 5 => 5, 6 => 6, 7 => 7, 8 => 8}
             |> Map.merge(%{10 => 9, 11 => 10, 13 => 11, 15 => 12, 16 => 13})

  # %{tpn => %{round => entry}}, an entry `%{kind:, colour:, opponent:,
  # result:, mp:, gp:}` with mp/gp the totals after the round.
  defp crosstable do
    for line <- String.split(@crosstable, "\n", trim: true), into: %{} do
      [tpn | rest] = String.split(line)

      rounds =
        rest
        |> Enum.chunk_every(3)
        |> Enum.with_index(1)
        |> Map.new(fn {[entry, mp, gp], r} ->
          {r, Map.merge(entry(entry), %{mp: num(mp), gp: num(gp)})}
        end)

      {String.to_integer(tpn), rounds}
    end
  end

  defp num(s), do: elem(Float.parse(s), 0)

  defp entry(bye) when bye in ["PAB", "HPB", "ZPB"],
    do: %{
      kind:
        String.downcase(bye)
        |> then(&Map.fetch!(%{"pab" => :pab, "hpb" => :hpb, "zpb" => :zpb}, &1))
    }

  defp entry(<<result::binary-size(1), how::binary-size(1), opponent::binary>>) do
    %{
      kind: if(how == "F", do: :forfeit, else: :played),
      result: result,
      colour: Map.get(%{"W" => :white, "B" => :black}, how),
      opponent: String.to_integer(opponent)
    }
  end

  defp before(rounds, r, key), do: if(r == 1, do: 0.0, else: rounds[r - 1][key])

  # The engine's input for round `r`, in final numbers.
  defp field(table, r) do
    present = for {tpn, rounds} <- table, rounds[r].kind in [:played, :forfeit, :pab], do: tpn

    teams =
      for tpn <- Enum.sort(present) do
        rounds = table[tpn]
        earlier = for q <- 1..(r - 1)//1, do: rounds[q]
        played = Enum.filter(earlier, &(&1.kind == :played))

        %Team{
          tpn: tpn,
          match_points: before(rounds, r, :mp),
          game_points: before(rounds, r, :gp),
          opponents: Enum.map(played, & &1.opponent),
          colours: Enum.map(played, & &1.colour),
          had_pab?: Enum.any?(earlier, &(&1.kind == :pab)),
          won_by_forfeit?: Enum.any?(earlier, &(&1.kind == :forfeit and &1.result == "+")),
          floated_last_round?: floated?(table, tpn, r - 1)
        }
      end

    # Arrived: played, forfeited or had the PAB in an earlier round. Round
    # 1's half-point byes arrive in round 2.
    arrived = fn tpn ->
      Enum.any?(1..(r - 1)//1, &(table[tpn][&1].kind in [:played, :forfeit, :pab]))
    end

    absent = for {tpn, _} <- table, tpn not in present, arrived.(tpn), do: tpn

    {teams, Enum.sort(absent)}
  end

  # 1.5: played, in `q`, against a team on a different score before it.
  defp floated?(_table, _tpn, q) when q < 1, do: false

  defp floated?(table, tpn, q) do
    case table[tpn][q] do
      %{kind: :played, opponent: other} ->
        before(table[tpn], q, :mp) != before(table[other], q, :mp)

      _ ->
        false
    end
  end

  defp held(table, r) do
    pairs =
      for {tpn, rounds} <- table,
          %{kind: kind, colour: :white, opponent: b} <- [rounds[r]],
          kind == :played do
        {tpn, b}
      end

    bye = Enum.find_value(table, fn {tpn, rounds} -> rounds[r].kind == :pab && tpn end)
    {Enum.sort(pairs ++ Map.get(@forfeited, r, [])), bye}
  end

  defp renumber(teams, map) do
    for t <- teams do
      %{t | tpn: map[t.tpn], opponents: Enum.map(t.opponents, &map[&1])}
    end
  end

  defp engine(table, r) do
    {teams, absent} = field(table, r)

    {teams, absent, back} =
      if r == 1,
        do: {renumber(teams, @round_one), [], Map.new(@round_one, fn {f, p} -> {p, f} end)},
        else: {teams, absent, nil}

    opts = [
      type: :a,
      initial_colour: :white,
      score_mode: :match_points,
      round: r,
      expected_rounds: 9,
      absent: absent
    ]

    assert {:ok, result} = TeamPairing.pair_round(teams, opts)
    to_final = fn tpn -> if back, do: back[tpn], else: tpn end

    pairs = result.pairs |> Enum.map(&{to_final.(&1.white), to_final.(&1.black)}) |> Enum.sort()
    {pairs, result.bye && to_final.(result.bye)}
  end

  test "the crosstable is consistent: every match is recorded on both sides" do
    table = crosstable()
    assert map_size(table) == 16

    for {tpn, rounds} <- table, r <- 1..9, %{opponent: o} = e <- [rounds[r]] do
      other = table[o][r]
      assert other.opponent == tpn
      assert other.kind == e.kind
      if e.colour, do: assert(other.colour != e.colour)
    end
  end

  for r <- 1..9 do
    test "round #{r}: Held's pairing, bye and colours" do
      table = crosstable()
      assert engine(table, unquote(r)) == held(table, unquote(r))
    end
  end
end

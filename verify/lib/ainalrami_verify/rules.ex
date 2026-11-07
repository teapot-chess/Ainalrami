defmodule AinalramiVerify.Rules do
  @moduledoc """
  C.04.3 (2026) articles that judge one pair or one player, written from
  the text. Nothing here searches; `AinalramiVerify.Bracket` does that.
  """

  alias AinalramiVerify.Position

  @doc "[C1] and [C3] for the pair `a`-`b`; `:ok` or `{:error, article}`."
  def pair_check(pos, a, b) do
    pa = pos.players[a]
    pb = pos.players[b]

    cond do
      a == b -> {:error, "C1"}
      MapSet.member?(pa.opponents, b) -> {:error, "C1"}
      c3_conflict?(pa, pb) -> {:error, "C3"}
      true -> :ok
    end
  end

  def legal?(pos, a, b), do: pair_check(pos, a, b) == :ok

  # 2.1.3: non-topscorers with the same absolute preference shall not meet.
  defp c3_conflict?(pa, pb) do
    match?({c, :absolute} when c != nil, pa.pref) and pa.pref == pb.pref and
      not pa.topscorer? and not pb.topscorer?
  end

  @doc "[C2]: may `a` receive the pairing-allocated bye?"
  def bye_eligible?(pos, a), do: not pos.players[a].bye_ineligible?

  @doc """
  Article 5.2: `{white, black, article}` for the pair, the article being
  the first of 5.2.1-5.2.5 that decided it.
  """
  def colours(pos, a, b) do
    pa = pos.players[a]
    pb = pos.players[b]
    {ca, sa} = split(pa.pref)
    {cb, sb} = split(pb.pref)

    {hi, lo} =
      if Position.order_key(pos, a) <= Position.order_key(pos, b), do: {a, b}, else: {b, a}

    cond do
      # 5.2.1: both can be granted (a player without a preference takes
      # whatever the opponent's preference leaves, 1.7.4)
      ca != nil and ca != cb ->
        white_if(a, b, ca, "5.2.1")

      cb != nil and cb != ca ->
        white_if(b, a, cb, "5.2.1")

      # both prefer the same colour (or neither has a preference)
      ca != nil and sa != sb ->
        if sa > sb, do: white_if(a, b, ca, "5.2.2"), else: white_if(b, a, cb, "5.2.2")

      ca != nil and sa == 3 and abs(pa.cd) != abs(pb.cd) ->
        if abs(pa.cd) > abs(pb.cd),
          do: white_if(a, b, ca, "5.2.2"),
          else: white_if(b, a, cb, "5.2.2")

      (alt = alternate(pa.colours, pb.colours)) != nil ->
        # 5.2.3: alternate to the most recent time one had White and the
        # other Black; `alt` is the colour `a` had then.
        if alt == :w, do: {b, a, "5.2.3"}, else: {a, b, "5.2.3"}

      ca != nil ->
        # 5.2.4: the higher-ranked player's preference
        white_if(hi, lo, ca, "5.2.4")

      true ->
        # 5.2.5
        n = Map.get(pos.arrival, hi, hi)
        c = if rem(n, 2) == 1, do: pos.initial_colour, else: Position.opposite(pos.initial_colour)
        white_if(hi, lo, c, "5.2.5")
    end
  end

  defp white_if(x, y, :w, art), do: {x, y, art}
  defp white_if(x, y, :b, art), do: {y, x, art}

  defp split(nil), do: {nil, 0}
  defp split(pref), do: {elem(pref, 0), Position.strength(pref)}

  # Walk both played-colour histories back in step.
  defp alternate(ca, cb) do
    Enum.zip(Enum.reverse(ca), Enum.reverse(cb))
    |> Enum.find_value(fn
      {x, y} when x != y -> x
      _ -> nil
    end)
  end

  @doc """
  What the pair `a`-`b` costs on the colour criteria once 5.2 has
  allocated the colours: `%{c10: n, c11: n, c12: n, c13: n}`, each the
  number of the two players the criterion counts.

    * C10: topscorers or their opponents who end with |CD| > 2.
    * C11: topscorers or their opponents with the same colour three times
      in a row.
    * C12: players who do not get their colour preference.
    * C13: players who do not get their strong colour preference
      (1.7.2: a colour difference of +1 or -1). See `strong_denied?/1` for
      the reading.
  """
  def colour_costs(pos, a, b) do
    {w, bl, _} = colours(pos, a, b)
    pw = pos.players[w]
    pb = pos.players[bl]
    top? = pw.topscorer? or pb.topscorer?

    denied = fn p, got -> p.pref != nil and elem(p.pref, 0) != got end

    after_cd = fn p, got -> p.cd + if(got == :w, do: 1, else: -1) end

    three = fn p, got ->
      case Enum.take(p.colours, -2) do
        [^got, ^got] -> true
        _ -> false
      end
    end

    list = [{pw, :w}, {pb, :b}]

    %{
      c10: if(top?, do: Enum.count(list, fn {p, g} -> abs(after_cd.(p, g)) > 2 end), else: 0),
      c11: if(top?, do: Enum.count(list, fn {p, g} -> three.(p, g) end), else: 0),
      c12: Enum.count(list, fn {p, g} -> denied.(p, g) end),
      c13: Enum.count(list, fn {p, g} -> denied.(p, g) and strong_denied?(p) end)
    }
  end

  @doc """
  C13's reading: a denied preference counts when the player's colour
  difference is +1 or -1 (1.7.2's definition), whether or not the
  preference is also absolute by 1.7.1's "same colour twice" clause, and
  also when it is absolute by the colour difference: a preference stronger
  than strong is not less strong. Only a mild one (CD 0) is left out.
  """
  def strong_denied?(p), do: Position.strength(p.pref) >= 2

  @doc "Whether `rank` floated `dir` (`:down`/`:up`) `back` rounds before the one being paired."
  def floated?(pos, rank, dir, back),
    do: Map.get(pos.players[rank].float, pos.round - back) == dir
end

defmodule AinalramiLab.Rules do
  @moduledoc """
  The per-pair and per-player articles of C.04.3 (2026), with a variant's
  parameters plugged in. Under `AinalramiLab.Variant.baseline/0` every
  function here answers exactly what `AinalramiVerify.Rules` answers - the
  test suite holds them to that - and the code is kept line for line
  parallel to it so the difference a variant makes is visible.

  The position is `AinalramiVerify.Position`, built from the TRF by the
  verify suite. `position/2` only re-derives the colour preferences
  (1.7.1-1.7.3) when the variant changes what makes one absolute.
  """

  alias AinalramiLab.Variant
  alias AinalramiVerify.Position

  @doc "The position as the variant sees it."
  def position(%Position{} = pos, %Variant{absolute_cd: 1, streak: 2}), do: pos

  def position(%Position{} = pos, %Variant{} = v) do
    players =
      Map.new(pos.players, fn {rank, p} ->
        {rank, %{p | pref: preference(p.cd, p.colours, v)}}
      end)

    %{pos | players: players}
  end

  # 1.7.1-1.7.4, with the thresholds as parameters.
  @doc false
  def preference(_cd, [], _v), do: nil

  def preference(cd, colours, %Variant{absolute_cd: limit, streak: streak}) do
    tail = Enum.take(colours, -streak)

    run =
      case Enum.uniq(tail) do
        [c] when length(tail) == streak -> c
        _ -> nil
      end

    cond do
      cd < -limit -> {:w, :absolute}
      cd > limit -> {:b, :absolute}
      run == :b -> {:w, :absolute}
      run == :w -> {:b, :absolute}
      cd < 0 -> {:w, :strong}
      cd > 0 -> {:b, :strong}
      true -> {Position.opposite(List.last(colours)), :mild}
    end
  end

  @doc "[C1] and [C3] under the variant."
  def legal?(pos, a, b, %Variant{} = v) do
    pa = pos.players[a]
    pb = pos.players[b]

    cond do
      a == b -> false
      v.rematches == :forbidden and MapSet.member?(pa.opponents, b) -> false
      v.c3 == :on and c3_conflict?(pa, pb) -> false
      true -> true
    end
  end

  defp c3_conflict?(pa, pb) do
    match?({c, :absolute} when c != nil, pa.pref) and pa.pref == pb.pref and
      not pa.topscorer? and not pb.topscorer?
  end

  @doc """
  Article 5.2 under the variant: `{white, black, article}`. Only 5.2.5's
  number depends on the variant.
  """
  def colours(pos, a, b, %Variant{} = v) do
    pa = pos.players[a]
    pb = pos.players[b]
    {ca, sa} = split(pa.pref)
    {cb, sb} = split(pb.pref)

    {hi, lo} =
      if Position.order_key(pos, a) <= Position.order_key(pos, b), do: {a, b}, else: {b, a}

    cond do
      ca != nil and ca != cb ->
        white_if(a, b, ca, "5.2.1")

      cb != nil and cb != ca ->
        white_if(b, a, cb, "5.2.1")

      ca != nil and sa != sb ->
        if sa > sb, do: white_if(a, b, ca, "5.2.2"), else: white_if(b, a, cb, "5.2.2")

      ca != nil and sa == 3 and abs(pa.cd) != abs(pb.cd) ->
        if abs(pa.cd) > abs(pb.cd),
          do: white_if(a, b, ca, "5.2.2"),
          else: white_if(b, a, cb, "5.2.2")

      (alt = alternate(pa.colours, pb.colours)) != nil ->
        if alt == :w, do: {b, a, "5.2.3"}, else: {a, b, "5.2.3"}

      ca != nil ->
        white_if(hi, lo, ca, "5.2.4")

      true ->
        white_if(hi, lo, c525_colour(pos, hi, v.c525), "5.2.5")
    end
  end

  @doc "The colour 5.2.5 gives the higher-ranked player `hi` under a reading."
  def c525_colour(pos, hi, reading) do
    case reading do
      :initial ->
        pos.initial_colour

      _ ->
        n = if reading == :tpn, do: hi, else: Map.get(pos.arrival, hi, hi)

        if rem(n, 2) == 1,
          do: pos.initial_colour,
          else: Position.opposite(pos.initial_colour)
    end
  end

  defp white_if(x, y, :w, art), do: {x, y, art}
  defp white_if(x, y, :b, art), do: {y, x, art}

  defp split(nil), do: {nil, 0}
  defp split(pref), do: {elem(pref, 0), Position.strength(pref)}

  defp alternate(ca, cb) do
    Enum.zip(Enum.reverse(ca), Enum.reverse(cb))
    |> Enum.find_value(fn
      {x, y} when x != y -> x
      _ -> nil
    end)
  end

  @doc "[C10]-[C13] for the pair once 5.2 has allocated colours, as `AinalramiVerify.Rules.colour_costs/3`."
  def colour_costs(pos, a, b, %Variant{} = v) do
    {w, bl, _} = colours(pos, a, b, v)
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

    strong? = fn p ->
      case v.c13 do
        :strong_or_absolute -> Position.strength(p.pref) >= 2
        :strong_only -> Position.strength(p.pref) == 2
      end
    end

    list = [{pw, :w}, {pb, :b}]

    %{
      c10: if(top?, do: Enum.count(list, fn {p, g} -> abs(after_cd.(p, g)) > 2 end), else: 0),
      c11: if(top?, do: Enum.count(list, fn {p, g} -> three.(p, g) end), else: 0),
      c12: Enum.count(list, fn {p, g} -> denied.(p, g) end),
      c13: Enum.count(list, fn {p, g} -> denied.(p, g) and strong?.(p) end)
    }
  end

  @doc "Whether `rank` floated `dir` `back` rounds before the round being paired."
  def floated?(pos, rank, dir, back),
    do: Map.get(pos.players[rank].float, pos.round - back) == dir
end

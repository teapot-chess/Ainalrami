defmodule AinalramiLab.Brute do
  @moduledoc """
  The brute-force reference pairer of `verify/`, with its criteria made
  pluggable.

  The search is `AinalramiVerify.Bracket`'s: every candidate of a
  bracket is listed (`Bracket.candidates/2`), candidates that leave the
  rest of the round unpairable are dropped (`Bracket.completion/2`,
  [C4]), the rest are compared on the criteria and ties go to the one
  Article 4 generates first (`Bracket.sequence_key/3`). What is replaced
  is the scoring: the criteria come from `AinalramiLab.Criteria` in the
  variant's order, and legality and colours from `AinalramiLab.Rules`
  with the variant's parameters. The baseline variant reproduces
  `AinalramiVerify.Bracket.pair/1` exactly; `test/brute_test.exs` checks
  it.

  Limits: the search is exponential in the bracket size. Round 1 of 10
  players (one bracket of 10) takes about a quarter of a second, 12
  players six seconds, 14 players four and a half minutes. Use it to 10
  players; `AinalramiLab.Hybrid` is the answer above that.
  """

  import Bitwise

  alias AinalramiLab.{Criteria, Rules, Variant}
  alias AinalramiVerify.{Bracket, Position}

  @doc "A search context: verify's, with legality decided by the variant."
  def context(%Position{} = pos, %Variant{} = v) do
    ranks = Position.sort(pos, pos.pool) |> List.to_tuple()
    n = tuple_size(ranks)
    index = for i <- 0..(n - 1)//1, into: %{}, do: {elem(ranks, i), i}

    adj =
      for i <- 0..(n - 1)//1, into: %{} do
        a = elem(ranks, i)

        {i,
         Enum.reduce(0..(n - 1)//1, 0, fn j, acc ->
           if i != j and Rules.legal?(pos, a, elem(ranks, j), v),
             do: acc ||| 1 <<< j,
             else: acc
         end)}
      end

    %Bracket.Ctx{pos: pos, ranks: ranks, index: index, adj: adj, memo: make_ref(), bend: nil}
  end

  @doc """
  Pair the position under the variant: `{:ok, round}` with `round` =
  `%{pairs: [{white, black}], bye: rank | nil, articles: [article]}`
  (the 5.2 article that decided each board), or `{:error,
  :no_legal_pairing}`.
  """
  def pair(%Position{} = pos0, %Variant{} = v) do
    pos = Rules.position(pos0, v)
    ctx = context(pos, v)

    try do
      if Bracket.completion(ctx, Bracket.mask(ctx, pos.pool)) == :none do
        {:error, :no_legal_pairing}
      else
        groups = Bracket.scoregroups(ctx)

        {pairs, left} =
          Enum.reduce(0..(length(groups) - 1)//1, {[], []}, fn k, {acc, mdps} ->
            b = Bracket.bracket(ctx, groups, k, mdps)

            %{candidate: {ps, df}} =
              best(ctx, b, v) || raise "C4 failed in a bracket of a completable round"

            {acc ++ ps, df}
          end)

        bye =
          case left do
            [] -> nil
            [x] -> x
          end

        coloured = Enum.map(pairs, fn {a, b} -> Rules.colours(pos, a, b, v) end)

        {:ok,
         %{
           pairs: Enum.map(coloured, fn {w, b, _} -> {w, b} end),
           bye: bye,
           articles: Enum.map(coloured, &elem(&1, 2))
         }}
      end
    after
      Bracket.cleanup(ctx)
    end
  end

  @doc "The criteria vector of one candidate, as a map, or `{:error, \"C4\"}`."
  def evaluate(ctx, b, {pairs, df}, %Variant{} = v) do
    pos = ctx.pos
    rest = Bracket.mask(ctx, df) ||| b.below

    case Bracket.completion(ctx, rest) do
      :none ->
        {:error, "C4"}

      {:ok, bye} ->
        p = pos.players

        cross =
          for {x, y} <- pairs, p[x].score != p[y].score do
            if p[x].score > p[y].score, do: {x, y}, else: {y, x}
          end

        env = %{
          ctx: ctx,
          pos: pos,
          variant: v,
          b: b,
          pairs: pairs,
          df: df,
          bye: bye,
          colour: Enum.map(pairs, fn {x, y} -> Rules.colour_costs(pos, x, y, v) end),
          cross: cross,
          partner: Map.new(Enum.flat_map(pairs, fn {x, y} -> [{x, y}, {y, x}] end))
        }

        {:ok, Map.new(v.order, fn c -> {c, Criteria.value(c, env)} end)}
    end
  end

  @doc "The best candidate of a bracket under the variant (3.8.1), or `nil`."
  def best(ctx, b, %Variant{} = v) do
    scored =
      ctx
      |> Bracket.candidates(b.players)
      |> Enum.flat_map(fn cand ->
        case evaluate(ctx, b, cand, v) do
          {:ok, vec} -> [{cand, key(vec, v), vec}]
          {:error, _} -> []
        end
      end)

    case scored do
      [] ->
        nil

      list ->
        top = list |> Enum.map(&elem(&1, 1)) |> Enum.min()
        tied = Enum.filter(list, &(elem(&1, 1) == top))
        {cand, k, vec} = Enum.min_by(tied, fn {c, _, _} -> Bracket.sequence_key(ctx, b, c) end)
        %{candidate: cand, key: k, vector: vec, tied: length(tied)}
    end
  end

  @doc "A vector in the variant's priority order, as a comparable tuple."
  def key(vec, %Variant{order: order}),
    do: order |> Enum.map(&Map.fetch!(vec, &1)) |> List.to_tuple()

  @doc """
  [C8]: the best [C5], [C6], [C7] the following bracket can reach with
  `df` as its MDPs - `AinalramiVerify.Bracket`'s private `outlook/3`,
  repeated here because the lab may not call a private function.
  """
  def outlook(_ctx, %Bracket.B{next: []}, _df), do: {}

  def outlook(ctx, %Bracket.B{} = b, df) do
    memo = {ctx.memo, :c8, b.score, Bracket.mask(ctx, df)}

    case Process.get(memo) do
      nil ->
        nb_players = Position.sort(ctx.pos, df ++ b.next)
        below = b.below &&& bnot(Bracket.mask(ctx, b.next))

        v =
          ctx
          |> Bracket.candidates(nb_players)
          |> Enum.flat_map(fn {_pairs, ndf} ->
            case Bracket.completion(ctx, Bracket.mask(ctx, ndf) ||| below) do
              :none ->
                []

              {:ok, bye} ->
                [
                  {bye || 0, length(ndf),
                   ndf |> Enum.map(&ctx.pos.players[&1].score) |> Enum.sort(:desc)}
                ]
            end
          end)
          |> Enum.min(fn -> {1_000_000, 1_000_000, []} end)

        Process.put(memo, v)
        v

      v ->
        v
    end
  end
end

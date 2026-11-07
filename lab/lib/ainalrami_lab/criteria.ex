defmodule AinalramiLab.Criteria do
  @moduledoc """
  The quality criteria of C.04.3 (2026) Article 2.3-2.4 as named,
  separable pieces. Each takes one evaluated candidate (`env`, below) and
  returns a value; lower is better on every one, and 3.8.1 compares them
  in the variant's order, the first difference deciding.

  The readings are `AinalramiVerify.Bracket.evaluate/3`'s, the same
  expressions taken apart. Under the baseline variant the vector this
  module produces is equal, criterion for criterion, to that function's;
  `test/criteria_test.exs` holds it to that on the article fixtures and
  on random positions.

  `env` holds: `pos`, `variant`, `b` (the bracket, `AinalramiVerify.Bracket.B`),
  `pairs`, `df` (downfloaters), `bye` (the lowest score the bye can then
  go to, [C5]), `colour` (per pair, `AinalramiLab.Rules.colour_costs/4`),
  `cross` (pairs across scores as `{higher, lower}`), `partner`, `ctx`.
  """

  alias AinalramiLab.Rules

  @articles %{
    "C5" => "2.3.1",
    "C6" => "2.4.1",
    "C7" => "2.4.2",
    "C8" => "2.4.3",
    "C9" => "2.4.4",
    "C10" => "2.4.5",
    "C11" => "2.4.6",
    "C12" => "2.4.7",
    "C13" => "2.4.8",
    "C14" => "2.4.9",
    "C15" => "2.4.10",
    "C16" => "2.4.11",
    "C17" => "2.4.12",
    "C18" => "2.4.13",
    "C19" => "2.4.14",
    "C20" => "2.4.15",
    "C21" => "2.4.16",
    "C16@3" => "2.4.11, three rounds back (variant)",
    "C17@3" => "2.4.12, three rounds back (variant)",
    "C20@3" => "2.4.15, three rounds back (variant)",
    "C21@3" => "2.4.16, three rounds back (variant)"
  }

  @summaries %{
    "C5" => "lowest score for the pairing-allocated bye",
    "C6" => "fewest downfloaters (most pairs in the bracket)",
    "C7" => "lowest downfloater scores",
    "C8" => "the next bracket can still meet C5-C7 as well as possible",
    "C9" => "fewest unplayed games for a lone downfloater who will take the bye",
    "C10" => "topscorers (or opponents) ending with |CD| > 2",
    "C11" => "topscorers (or opponents) with the same colour three times running",
    "C12" => "colour preferences denied",
    "C13" => "strong colour preferences denied",
    "C14" => "residents downfloated who downfloated last round",
    "C15" => "MDP opponents upfloated who upfloated last round",
    "C16" => "residents downfloated who downfloated two rounds ago",
    "C17" => "MDP opponents upfloated who upfloated two rounds ago",
    "C18" => "score differences of MDPs who downfloated last round",
    "C19" => "score differences of MDP opponents who upfloated last round",
    "C20" => "score differences of MDPs who downfloated two rounds ago",
    "C21" => "score differences of MDP opponents who upfloated two rounds ago",
    "C16@3" => "as C16, three rounds ago",
    "C17@3" => "as C17, three rounds ago",
    "C20@3" => "as C20, three rounds ago",
    "C21@3" => "as C21, three rounds ago"
  }

  def article(name), do: Map.fetch!(@articles, name)
  def summary(name), do: Map.fetch!(@summaries, name)

  @doc "The value of criterion `name` for an evaluated candidate."
  def value("C5", env), do: env.bye || 0
  def value("C6", env), do: length(env.df)
  def value("C7", env), do: env.df |> Enum.map(&env.pos.players[&1].score) |> Enum.sort(:desc)
  def value("C8", env), do: AinalramiLab.Brute.outlook(env.ctx, env.b, env.df)

  def value("C9", env) do
    case env.df do
      [d] when env.bye != nil ->
        if env.bye == env.pos.players[d].score, do: env.pos.players[d].unplayed, else: 0

      _ ->
        0
    end
  end

  def value("C10", env), do: csum(env, :c10)
  def value("C11", env), do: csum(env, :c11)
  def value("C12", env), do: csum(env, :c12)
  def value("C13", env), do: csum(env, :c13)
  def value("C14", env), do: resident_down(env, 1)
  def value("C15", env), do: opponent_up(env, 1)
  def value("C16", env), do: resident_down(env, 2)
  def value("C17", env), do: opponent_up(env, 2)
  def value("C18", env), do: mdp_diffs(env, 1)
  def value("C19", env), do: diffs(env, 1)
  def value("C20", env), do: mdp_diffs(env, 2)
  def value("C21", env), do: diffs(env, 2)
  def value("C16@3", env), do: resident_down(env, 3)
  def value("C17@3", env), do: opponent_up(env, 3)
  def value("C20@3", env), do: mdp_diffs(env, 3)
  def value("C21@3", env), do: diffs(env, 3)

  defp csum(env, k), do: env.colour |> Enum.map(& &1[k]) |> Enum.sum()

  defp resident_down(env, back) do
    residents = MapSet.new(env.b.residents)

    Enum.count(env.df, fn x ->
      MapSet.member?(residents, x) and Rules.floated?(env.pos, x, :down, back)
    end)
  end

  defp opponent_up(env, back),
    do: Enum.count(env.cross, fn {_, l} -> Rules.floated?(env.pos, l, :up, back) end)

  # C19/C21: quarter-point score differences of cross pairs whose lower
  # player floated up `back` rounds ago, largest first, padded.
  defp diffs(env, back) do
    p = env.pos.players

    env.cross
    |> Enum.filter(fn {_, l} -> Rules.floated?(env.pos, l, :up, back) end)
    |> Enum.map(fn {h, l} -> 2 * (p[h].score - p[l].score) end)
    |> Enum.sort(:desc)
    |> pad(length(env.b.players))
  end

  # C18/C20: each MDP that floated down `back` rounds ago. Paired: its
  # difference with its opponent. Left in the Limbo: the baseline counts
  # it as more than any opponent here would give it; c18=paired leaves it
  # out, the reading verify/ rejected.
  defp mdp_diffs(env, back) do
    p = env.pos.players

    env.b.mdps
    |> Enum.filter(&Rules.floated?(env.pos, &1, :down, back))
    |> Enum.flat_map(fn m ->
      case env.partner do
        %{^m => o} ->
          [2 * max(p[m].score - p[o].score, 0)]

        _ ->
          if env.variant.c18 == :limbo, do: [2 * (p[m].score - env.b.score) + 1], else: []
      end
    end)
    |> Enum.sort(:desc)
    |> pad(length(env.b.players))
  end

  defp pad(list, n), do: list ++ List.duplicate(0, max(n - length(list), 0))
end

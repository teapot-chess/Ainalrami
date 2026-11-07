defmodule AinalramiVerify.Certificate do
  @moduledoc """
  Part 1: a proof with every pairing.

  `certify/2` pairs a TRF's next round with Ainalrami and writes an
  optimality certificate for it: for every bracket stage of the round
  (`AinalramiVerify.Weights`), a dual solution of Edmonds' matching
  polytope - a value `y` per player and `z` per odd set of players - for
  the stage's weights as recomputed from the rules. The published round,
  restricted to the stage's players, is the primal.

  `check/2` takes the TRF and the certificate and, with integer arithmetic
  and the rules alone, checks:

    1. the TRF is the one certified (SHA-256), and the round is the one it
       asks for;
    2. feasibility: the round is complete (1.9.1) and every board legal
       ([C1], [C3]), the bye eligible ([C2]);
    3. per stage, on weights it recomputes itself: `y >= 0`, `z >= 0`,
       every set odd and inside the stage; dual feasibility, `rc(u, v) =
       f * (y[u] + y[v] + sum(z[S] : u, v in S)) - 2 * w(u, v) >= 0` on
       every legal pair; complementary slackness, `rc = 0` on every board
       of the stage, every player with `y > 0` seated, every set with
       `z > 0` holding `(|S| - 1) / 2` boards; and, as a cross-check,
       equal primal and dual objectives.

  1-3 make the published round's brackets maximum-weight, so best on
  [C4]-[C21] in 3.8.1's sense: weak duality bounds every other matching by
  the dual objective, and complementary slackness makes the published one
  meet it.

  The checker does not run a matching algorithm and shares no code with
  the engine: the weights are this suite's (`Weights`, over `Rules` and
  `Position`), the arithmetic is below. `certify/2` does use the engine's
  matcher (`Ainalrami.WeightedMatching`, through its public read-only API)
  to *find* the duals, which costs the checker nothing: a dual that does
  not satisfy the conditions is refused, whoever found it.

  `f` (`dual_factor`) is the matcher's scale: it solves on `2 * w / f`.

  What it does not certify: Article 4's order among equally good
  candidates (3.8.1's last resort, not a weight - `rules` checks it), and
  colours (Article 5, checked per board by `rules`).
  """

  alias AinalramiVerify.{Bracket, Engine, Position, RuleCheck, Trf, Weights}

  @format "ainalrami-verify-certificate"
  @version 1

  @doc """
  Certify Ainalrami's pairing of the TRF's next round. Returns
  `{:ok, certificate_map}` or `{:error, reason}`; `reason` is
  `{:not_optimal, stage_score, published_weight, optimum}` when the
  engine's round is not best on some stage - a finding, not a crash.
  """
  def certify(trf_text, opts \\ []) do
    case Keyword.get_lazy(opts, :round, fn -> Engine.pair(trf_text) end) do
      {:ok, round} -> certify_round(trf_text, round)
      %{pairs: _} = round -> certify_round(trf_text, round)
      {:error, reason} -> {:error, {:engine_refused, reason}}
    end
  end

  @doc "Certify a given round (any program's) of the TRF."
  def certify_round(trf_text, round) do
    pos = trf_text |> Trf.parse() |> Position.build()

    with [] <- RuleCheck.legality(pos, round) do
      stages =
        Enum.map(stages(pos, round), fn {b, w, matching} ->
          {b, w, matching, solve(w, matching)}
        end)

      case Enum.find(stages, fn {_, _, _, s} -> match?({:error, _}, s) end) do
        {b, _, _, {:error, reason}} ->
          {:not_optimal, pub, opt} = reason
          {:error, {:not_optimal, b.score, pub, opt}}

        nil ->
          {:ok,
           %{
             "format" => @format,
             "version" => @version,
             "weights" => Weights.version(),
             "engine" => "ainalrami #{Engine.version()}",
             "trf_sha256" => sha256(trf_text),
             "round" => pos.round,
             "pairs" => Enum.map(round.pairs, fn {a, b} -> [a, b] end),
             "bye" => round.bye,
             "stages" =>
               Enum.map(stages, fn {b, _w, _m, {:ok, d}} ->
                 %{
                   "bracket" => b.score,
                   "vertices" => d.vertices,
                   "dual_factor" => Integer.to_string(d.factor),
                   "duals" =>
                     for({v, y} <- Enum.sort(d.y), y != 0, do: [v, Integer.to_string(y)]),
                   "sets" =>
                     for(
                       {vs, z} <- d.sets,
                       z != 0,
                       do: %{"vertices" => vs, "z" => Integer.to_string(z)}
                     )
                 }
               end)
           }}
      end
    else
      violations -> {:error, {:illegal_round, violations}}
    end
  end

  # [{bracket, weights, the published boards inside the stage}]
  defp stages(pos, round) do
    ctx = Bracket.context(pos)
    groups = Bracket.scoregroups(ctx)

    ctx
    |> Bracket.structure(round.pairs)
    |> Enum.with_index()
    |> Enum.map(fn {{b, {_ps, df}}, k} ->
      below = groups |> Enum.drop(k + 1) |> Enum.flat_map(&elem(&1, 1))

      next =
        case Enum.at(groups, k + 1) do
          nil -> []
          {_, rs} -> rs
        end

      w = Weights.stage(pos, b, below, next, length(df) == 1)
      inside = MapSet.new(w.vertices)

      matching =
        for {x, y} <- round.pairs,
            MapSet.member?(inside, x) and MapSet.member?(inside, y),
            do: Weights.norm(x, y)

      {b, w, matching}
    end)
  end

  # Find duals with the engine's matcher, then convert them to textbook
  # form (an exposed vertex at y = 0) and keep them only if the published
  # matching is optimal against them.
  defp solve(w, matching) do
    index = w.vertices |> Enum.with_index() |> Map.new()
    back = w.vertices |> Enum.with_index() |> Map.new(fn {r, i} -> {i, r} end)
    n = length(w.vertices)
    edges = for {{u, v}, wt} <- w.edges, do: {index[u], index[v], wt}

    {y, sets, factor} =
      if edges == [] do
        {%{}, [], 1}
      else
        ex = Engine.max_weight_matching(n, edges)

        live =
          ex.weight |> Enum.filter(fn {_, row} -> map_size(row) > 0 end) |> Enum.map(&elem(&1, 0))

        exposed = Enum.reject(live, &Map.has_key?(ex.mate, &1))

        {y, sets} =
          case exposed do
            [x] ->
              xi = Map.fetch!(ex.dual, x)

              if xi > 0,
                do:
                  {Map.new(live, &{&1, ex.dual[&1] - xi}),
                   [{Enum.sort(live), 2 * xi} | ex.blossoms]},
                else: {Map.new(live, &{&1, ex.dual[&1]}), ex.blossoms}

            _ ->
              {Map.new(live, &{&1, ex.dual[&1]}), ex.blossoms}
          end

        {Map.new(y, fn {i, d} -> {back[i], d} end),
         Enum.map(sets, fn {vs, z} -> {vs |> Enum.map(&back[&1]) |> Enum.sort(), z} end), ex.gcd}
      end

    dual = %{vertices: w.vertices, y: y, sets: sets, factor: factor}

    case verify_stage(w, matching, dual) do
      :ok ->
        {:ok, dual}

      {:error, _} ->
        published = Weights.weight(w, matching)
        optimum = div(factor * dual_objective(dual), 2)
        {:error, {:not_optimal, published, optimum}}
    end
  end

  # ---------------------------------------------------------------------------
  # The checker

  @doc """
  Check a certificate against its TRF. Returns `:ok` or `{:error,
  message}` naming the first violated condition.
  """
  def check(trf_text, cert) when is_map(cert) do
    with :ok <- expect(cert["format"] == @format, "not an #{@format}"),
         :ok <-
           expect(
             cert["version"] == @version,
             "certificate version #{inspect(cert["version"])}, this checker reads #{@version}"
           ),
         :ok <-
           expect(
             cert["weights"] == Weights.version(),
             "weights #{inspect(cert["weights"])}, this checker computes #{Weights.version()}"
           ),
         :ok <-
           expect(
             cert["trf_sha256"] == sha256(trf_text),
             "the TRF is not the one certified (SHA-256 differs)"
           ),
         pos = trf_text |> Trf.parse() |> Position.build(),
         :ok <-
           expect(
             cert["round"] == pos.round,
             "certificate is for round #{cert["round"]}, the TRF asks for round #{pos.round}"
           ),
         round = %{pairs: Enum.map(cert["pairs"], fn [a, b] -> {a, b} end), bye: cert["bye"]},
         :ok <- feasible(pos, round) do
      stages = stages(pos, round)
      given = cert["stages"] || []

      if length(given) != length(stages) do
        {:error,
         "the round has #{length(stages)} bracket stages, the certificate #{length(given)}"}
      else
        Enum.zip(stages, given)
        |> Enum.reduce_while(:ok, fn {{b, w, matching}, s}, :ok ->
          dual = %{
            vertices: s["vertices"],
            factor: String.to_integer(s["dual_factor"]),
            y: Map.new(s["duals"], fn [v, y] -> {v, String.to_integer(y)} end),
            sets:
              Enum.map(s["sets"], fn %{"vertices" => vs, "z" => z} ->
                {vs, String.to_integer(z)}
              end)
          }

          cond do
            s["bracket"] != b.score ->
              {:halt,
               {:error, "stage for bracket #{s["bracket"]}, the round's bracket is #{b.score}"}}

            Enum.sort(s["vertices"]) != w.vertices ->
              {:halt,
               {:error, "bracket #{show(b.score)}: the stage's players are not the round's"}}

            true ->
              case verify_stage(w, matching, dual) do
                :ok -> {:cont, :ok}
                {:error, m} -> {:halt, {:error, "bracket #{show(b.score)}: #{m}"}}
              end
          end
        end)
      end
    end
  end

  defp feasible(pos, round) do
    case RuleCheck.legality(pos, round) do
      [] ->
        :ok

      [v | _] ->
        {:error,
         "the round is not legal: [#{v.criterion || v.article}] #{v.message} (#{Enum.join(v.players, ",")})"}
    end
  end

  @doc false
  # The LP checks for one stage. Pure integer arithmetic.
  def verify_stage(w, matching, %{y: y, sets: sets, factor: f}) do
    vertices = MapSet.new(w.vertices)
    yv = fn v -> Map.get(y, v, 0) end
    seated = MapSet.new(Enum.flat_map(matching, fn {a, b} -> [a, b] end))

    member =
      sets
      |> Enum.with_index()
      |> Enum.flat_map(fn {{vs, _}, i} -> Enum.map(vs, &{&1, i}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {v, is} -> {v, MapSet.new(is)} end)

    zs = sets |> Enum.with_index() |> Map.new(fn {{_, z}, i} -> {i, z} end)

    zsum = fn u, v ->
      MapSet.intersection(Map.get(member, u, MapSet.new()), Map.get(member, v, MapSet.new()))
      |> Enum.map(&zs[&1])
      |> Enum.sum()
    end

    rc = fn u, v -> f * (yv.(u) + yv.(v) + zsum.(u, v)) - 2 * Map.fetch!(w.edges, {u, v}) end

    cond do
      f < 1 ->
        {:error, "dual factor #{f} is not positive"}

      (bad = Enum.find(y, fn {v, d} -> d < 0 or not MapSet.member?(vertices, v) end)) != nil ->
        {:error, "dual of #{elem(bad, 0)} is negative or not a player of the stage"}

      (bad =
         Enum.find(sets, fn {vs, z} ->
           z < 0 or rem(length(vs), 2) == 0 or length(Enum.uniq(vs)) != length(vs) or
               not Enum.all?(vs, &MapSet.member?(vertices, &1))
         end)) != nil ->
        {:error, "set #{inspect(elem(bad, 0))}: z < 0, even, repeated or outside the stage"}

      (bad = Enum.find(matching, fn e -> not Map.has_key?(w.edges, e) end)) != nil ->
        {:error, "board #{inspect(bad)} is not a legal pair"}

      (bad = Enum.find(w.edges, fn {{u, v}, _} -> rc.(u, v) < 0 end)) != nil ->
        {{u, v}, _} = bad
        {:error, "dual infeasible on #{u}-#{v}: reduced cost #{rc.(u, v)}"}

      (bad = Enum.find(matching, fn {u, v} -> rc.(u, v) != 0 end)) != nil ->
        {u, v} = bad

        {:error,
         "board #{u}-#{v} is not tight: reduced cost #{rc.(u, v)} - a better pairing exists for this bracket"}

      (bad = Enum.find(y, fn {v, d} -> d > 0 and not MapSet.member?(seated, v) end)) != nil ->
        {:error, "#{elem(bad, 0)} has a positive dual and is left over"}

      (bad =
         Enum.find(sets, fn {vs, z} ->
           inside = MapSet.new(vs)

           z > 0 and
               Enum.count(matching, fn {a, b} ->
                 MapSet.member?(inside, a) and MapSet.member?(inside, b)
               end) != div(length(vs) - 1, 2)
         end)) != nil ->
        {:error, "set #{inspect(elem(bad, 0))} has z > 0 and is not full"}

      f * dual_objective(%{y: y, sets: sets}) != 2 * Weights.weight(w, matching) ->
        {:error, "primal and dual objectives differ"}

      true ->
        :ok
    end
  end

  defp dual_objective(%{y: y, sets: sets}) do
    Enum.sum(Map.values(y)) + Enum.sum(for {vs, z} <- sets, do: z * div(length(vs) - 1, 2))
  end

  defp expect(true, _), do: :ok
  defp expect(_, m), do: {:error, m}

  def sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp show(half) when rem(half, 2) == 0, do: "#{div(half, 2)}.0"
  defp show(half), do: "#{div(half, 2)}.5"

  @doc "The certificate as JSON text."
  def encode(cert), do: JSON.encode!(cert)

  @doc "A certificate from JSON text."
  def decode(text), do: JSON.decode!(text)
end

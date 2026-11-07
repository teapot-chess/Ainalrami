defmodule AinalramiLab.Tournament do
  @moduledoc """
  One simulated tournament under one variant: players `1..n`, rounds
  paired one at a time, results drawn from ratings.

  Results use **common random numbers**: the outcome of a game is a
  function of `(seed, round, the two players)` and nothing else, so when
  the baseline and the variant make the same pairing they get the same
  result, and the two trajectories only part where the rule change parts
  them. That is what makes the baseline-variant differences paired
  samples rather than two independent ones.

  The model: player `i` is rated linearly from 2500 (rank 1) down to 1700
  (rank `n`) unless `:ratings` is given. White scores
  `E = 1 / (1 + 10^((Rb - Ra) / 400))`, a draw has probability
  `0.6 * min(E, 1 - E)`, the rest is split so the expectation stays `E`.
  The model only has to make scoregroups look like a tournament's; it
  is not a claim about chess.

  Disturbances, each drawn from the same kind of hash:

    * `:absent` - per player and round from round 2, a requested bye
      (`H`, half a point, or `Z`, zero) decided before pairing;
    * `:forfeit` - per board, the game is not played (`+`/`-`);
    * `:late` - `late` players, spread evenly through the ranking (a late
      entry is given a TPN by rating, C.04.2 2.4, so it lands anywhere),
      arrive in round 3, with `Z` in rounds 1 and 2.
  """

  alias AinalramiLab.{Pairer, Variant}
  alias AinalramiVerify.{Position, Trf, TrfWriter}

  defstruct players: 10,
            rounds: 5,
            absent: 0.0,
            forfeit: 0.0,
            late: 0,
            ratings: nil,
            initial_colour: :w

  @doc """
  Play a tournament. Returns `%{history:, rounds: [record], ended:}`,
  where each record is `%{round:, trf:, pos:, result: {:ok, round} |
  {:error, _}}`. `cache` maps a TRF text to a result already known for
  it under this variant: the simulator pairs the baseline's positions
  under the variant anyway, and reuses those while the trajectories
  agree.
  """
  def play(%__MODULE__{} = spec, pairer, %Variant{} = v, seed, cache \\ %{}) do
    n = spec.players

    Enum.reduce_while(1..spec.rounds, {[], []}, fn t, {hist, recs} ->
      out = requested(spec, seed, t)
      trf = write(spec, hist ++ if(out == %{}, do: [], else: [out]))
      pos = trf |> Trf.parse() |> Position.build(t)

      result =
        cond do
          length(pos.pool) < 2 -> {:error, :no_legal_pairing}
          Map.has_key?(cache, trf) -> Map.fetch!(cache, trf)
          true -> Pairer.pair(pairer, pos, trf, v)
        end

      rec = %{round: t, trf: trf, pos: pos, result: result}

      case result do
        {:ok, round} ->
          games = play_round(spec, seed, t, round, out)
          {:cont, {hist ++ [games], [rec | recs]}}

        {:error, _} ->
          {:halt, {hist, [rec | recs]}}
      end
    end)
    |> then(fn {hist, recs} ->
      recs = Enum.reverse(recs)

      %{
        history: hist,
        rounds: recs,
        players: n,
        ended: if(match?({:error, _}, List.last(recs).result), do: :refused, else: :complete)
      }
    end)
  end

  @doc "The TRF text of a history (rounds of `rank => {opp, colour, code}`)."
  def write(%__MODULE__{} = spec, hist) do
    TrfWriter.write(spec.players, hist, spec.rounds, initial_colour: spec.initial_colour)
  end

  defp requested(spec, seed, t) do
    late =
      if spec.late > 0 and t <= 2,
        do:
          for(
            p <- late_ranks(spec),
            into: %{},
            do: {p, {nil, nil, "Z"}}
          ),
        else: %{}

    absent =
      if spec.absent > 0 and t >= 2 do
        for p <- 1..spec.players,
            not Map.has_key?(late, p),
            u = uniform({seed, :absent, t, p}),
            u < spec.absent,
            into: %{} do
          {p, {nil, nil, if(u < spec.absent / 2, do: "H", else: "Z")}}
        end
      else
        %{}
      end

    Map.merge(absent, late)
  end

  @doc "The starting ranks of the late entrants."
  def late_ranks(%__MODULE__{late: 0}), do: []

  def late_ranks(%__MODULE__{late: k, players: n}),
    do: for(i <- 1..k, into: [], do: max(round(i * n / (k + 1)), 2)) |> Enum.uniq()

  defp play_round(spec, seed, t, round, out) do
    games =
      Enum.reduce(round.pairs, out, fn {w, b}, m ->
        {rw, rb} = result(spec, seed, t, w, b)
        m |> Map.put(w, {b, :w, rw}) |> Map.put(b, {w, :b, rb})
      end)

    if round.bye, do: Map.put(games, round.bye, {nil, nil, "U"}), else: games
  end

  @doc "The result of `white`-`black` in round `t`: `{white_code, black_code}`."
  def result(spec, seed, t, w, b) do
    {lo, hi} = {min(w, b), max(w, b)}

    if spec.forfeit > 0 and uniform({seed, :forfeit, t, lo, hi}) < spec.forfeit do
      if uniform({seed, :forfeit_side, t, lo, hi}) < 0.5, do: {"+", "-"}, else: {"-", "+"}
    else
      e = 1 / (1 + :math.pow(10, (rating(spec, b) - rating(spec, w)) / 400))
      d = 0.6 * min(e, 1 - e)
      # Drawn for the unordered pair, so the same two players get the same
      # result in the same round whoever has White; the expectation is
      # then taken from the lower rank's side.
      u = uniform({seed, :game, t, lo, hi})
      e_lo = if lo == w, do: e, else: 1 - e
      win_lo = e_lo - d / 2

      {lo_code, hi_code} =
        cond do
          u < win_lo -> {"1", "0"}
          u < win_lo + d -> {"=", "="}
          true -> {"0", "1"}
        end

      if lo == w, do: {lo_code, hi_code}, else: {hi_code, lo_code}
    end
  end

  defp rating(%__MODULE__{ratings: nil, players: n}, rank),
    do: 2500 - (rank - 1) * 800 / max(n - 1, 1)

  defp rating(%__MODULE__{ratings: r}, rank), do: Map.fetch!(r, rank)

  # A uniform number in [0, 1) that depends on `term` only.
  defp uniform(term) do
    <<x::unsigned-64, _::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(term))
    x / 18_446_744_073_709_551_616
  end
end

defmodule AinalramiVerify.Engine do
  @moduledoc """
  The one module that calls Ainalrami. Everything it uses is the engine's
  public API, read-only: `Ainalrami.Trf.parse/1`,
  `Ainalrami.Pairing.pair_next_round/2`, and, for certificates only,
  `Ainalrami.WeightedMatching.new/3`, `solve/1` and `proof_export/1`.
  Nothing here changes what the engine does.
  """

  @doc "Ainalrami's version, as its application spec reports it."
  def version do
    Application.load(:ainalrami)

    case Application.spec(:ainalrami, :vsn) do
      nil -> "unknown"
      v -> to_string(v)
    end
  end

  @doc """
  Pair the TRF's next round with Ainalrami, as its command line does.
  Returns `{:ok, %{pairs: [{white, black}], bye: rank | nil}}` or
  `{:error, reason}`.
  """
  def pair(trf_text) do
    parsed = Ainalrami.Trf.parse(trf_text)
    t = parsed.tournament

    opts = [
      expected_rounds: t[:number_of_rounds],
      forbidden_pairs: t[:forbidden_pairs],
      point_system: t[:point_system],
      initial_colour: t[:initial_colour]
    ]

    result = Ainalrami.Pairing.pair_next_round(parsed.players, opts)

    {byes, pairs} = Enum.split_with(result, fn {_, b} -> b == nil end)

    bye =
      case byes do
        [] -> nil
        [{x, nil}] -> x
      end

    {:ok, %{pairs: pairs, bye: bye}}
  rescue
    e in Ainalrami.Pairing.NoValidPairingError ->
      {:error, {:no_legal_pairing, Exception.message(e)}}
  end

  @doc """
  Pair a team round (C.04.6) from its input record (a decoded
  `ainalrami-team-input`) with `Ainalrami.TeamPairing.pair_round/2`.
  Returns `{:ok, %{pairs: [%{white:, black:}], bye: tpn | nil}}` or
  `{:error, reason}`.
  """
  def team_pair(input) when is_map(input) do
    with {:ok, teams, opts} <- Ainalrami.TeamCertificate.decode_input(input),
         {:ok, result} <- Ainalrami.TeamPairing.pair_round(teams, opts) do
      {:ok, %{pairs: result.pairs, bye: result.bye}}
    end
  end

  @doc """
  The certificate `Ainalrami.TeamCertificate.certify/3` writes for `round`
  of the input record. The duals it holds are found by the engine's
  matcher; `AinalramiVerify.TeamCheck` decides whether they prove anything.
  """
  def team_certify(input, round, input_sha256),
    do: Ainalrami.TeamCertificate.certify(input, round, input_sha256)

  @doc "The pairing list of a team round, as the engine's host writes it."
  def team_output(round), do: Ainalrami.TeamCertificate.output_text(round)

  @doc """
  A maximum-weight matching of `edges` (`[{u, v, w}]`, positive integer
  weights, vertices `0..n-1`) with its dual solution, from the engine's
  matcher: `%{mate: %{u => v}, dual: %{v => y}, blossoms: [{[v], z}],
  gcd: g}`. Duals are on the matcher's scale, `2 * w / g`.
  """
  def max_weight_matching(n, edges) do
    {state, _} = n |> Ainalrami.WeightedMatching.new(edges) |> Ainalrami.WeightedMatching.solve()
    Ainalrami.WeightedMatching.proof_export(state)
  end
end

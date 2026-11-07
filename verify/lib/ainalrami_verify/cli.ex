defmodule AinalramiVerify.CLI do
  @moduledoc """
  `ainalrami-verify`, the command line:

      ainalrami-verify certify ROUND.trf [-o CERT.json]
      ainalrami-verify check ROUND.trf CERT.json
      ainalrami-verify rules ROUND.trf PAIRS [--no-colours]
      ainalrami-verify pair ROUND.trf
      ainalrami-verify exhaustive --players N --rounds R --dir DIR [--workers W] [--split S] [--results wdl|wl]
      ainalrami-verify sample --players N --rounds R --walks K --dir DIR [--seed S] [--workers W]

  Exit codes: 0 OK, 1 a finding (a failed check, a broken article, a
  disagreement, an engine round that cannot be certified), 2 a usage or
  input error.
  """

  alias AinalramiVerify.{Bracket, Certificate, Exhaustive, PairsFile, Position, RuleCheck, Trf}

  def main(argv) do
    code =
      try do
        run(argv)
      rescue
        e in [Trf.Error, File.Error, ArgumentError, JSON.DecodeError] ->
          IO.puts(:stderr, "error: " <> Exception.message(e))
          2
      end

    System.halt(code)
  end

  @doc "Run a command; returns the exit code."
  def run(["certify", trf | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [output: :string], aliases: [o: :output])
    text = File.read!(trf)

    case Certificate.certify(text) do
      {:ok, cert} ->
        json = Certificate.encode(cert)

        case opts[:output] do
          nil -> IO.puts(json)
          path -> File.write!(path, json)
        end

        IO.puts(
          :stderr,
          "certified: round #{cert["round"]}, #{length(cert["stages"])} bracket stage(s)"
        )

        0

      {:error, {:not_optimal, bracket, published, optimum}} ->
        IO.puts(
          :stderr,
          "NOT CERTIFIED: the engine's round is not best in bracket #{show(bracket)}: " <>
            "its weight is #{published}, a matching of #{optimum} exists. Run `rules` for the article."
        )

        1

      {:error, {:engine_refused, reason}} ->
        IO.puts(:stderr, "the engine refused the round: #{inspect(reason)}")
        1

      {:error, {:illegal_round, violations}} ->
        IO.puts(:stderr, "the engine's round is not legal:\n" <> RuleCheck.format(violations))
        1
    end
  end

  def run(["check", trf, cert]) do
    case Certificate.check(File.read!(trf), cert |> File.read!() |> Certificate.decode()) do
      :ok ->
        IO.puts("OK")
        0

      {:error, message} ->
        IO.puts("FAIL: " <> message)
        1
    end
  end

  def run(["rules", trf, pairs | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [no_colours: :boolean])
    text = File.read!(trf)
    pos = text |> Trf.parse() |> Position.build()

    round =
      if String.ends_with?(String.downcase(pairs), ".trf"),
        do: PairsFile.from_trf(File.read!(pairs), pos.round),
        else: PairsFile.parse(File.read!(pairs))

    violations = RuleCheck.check(pos, round, colours: not Keyword.get(opts, :no_colours, false))
    IO.puts(RuleCheck.format(violations))
    if violations == [], do: 0, else: 1
  end

  def run(["pair", trf]) do
    pos = trf |> File.read!() |> Trf.parse() |> Position.build()

    case Bracket.pair(pos) do
      {:ok, round} ->
        IO.write(PairsFile.write(round))
        0

      {:error, :no_legal_pairing} ->
        IO.puts(:stderr, "no legal pairing exists (1.9.3)")
        1
    end
  end

  def run(["exhaustive" | rest]) do
    {o, _, _} =
      OptionParser.parse(rest,
        strict: [
          players: :integer,
          rounds: :integer,
          dir: :string,
          workers: :integer,
          split: :integer,
          results: :string,
          max_jobs: :integer
        ]
      )

    need!(o, [:players, :rounds, :dir])

    s =
      Exhaustive.run(
        Keyword.take(o, [:players, :rounds, :dir, :workers, :split, :results, :max_jobs])
      )

    IO.puts(JSON.encode!(s))
    if s["disagree"] == 0, do: 0, else: 1
  end

  def run(["sample" | rest]) do
    {o, _, _} =
      OptionParser.parse(rest,
        strict: [
          players: :integer,
          rounds: :integer,
          dir: :string,
          workers: :integer,
          walks: :integer,
          seed: :integer,
          results: :string
        ]
      )

    need!(o, [:players, :rounds, :dir, :walks])
    s = Exhaustive.sample(o)
    IO.puts(JSON.encode!(s))
    if s["disagree"] == 0, do: 0, else: 1
  end

  def run(_) do
    IO.puts(:stderr, @moduledoc |> String.split("\n\n") |> Enum.at(1))
    2
  end

  defp need!(o, keys) do
    for k <- keys,
        not Keyword.has_key?(o, k),
        do: raise(ArgumentError, "--#{String.replace(to_string(k), "_", "-")} is required")
  end

  defp show(half) when rem(half, 2) == 0, do: "#{div(half, 2)}.0"
  defp show(half), do: "#{div(half, 2)}.5"
end

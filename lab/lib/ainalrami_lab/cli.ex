defmodule AinalramiLab.CLI do
  @moduledoc """
  `ainalrami-lab`, the command line:

      ainalrami-lab simulate --variant SPEC [--baseline SPEC] --corpus CORPUS [--pairer brute|hybrid|engine|auto] [--seed S] [--workers W] [--examples K] [--out DIR]
      ainalrami-lab pair ROUND.trf [--variant SPEC] [--pairer P]
      ainalrami-lab fidelity --corpus generated:... --against brute|engine [--variant SPEC] [--seed S] [--workers W]
      ainalrami-lab criteria

  CORPUS is `generated:players=10,rounds=5,count=200[,absent=0.1][,forfeit=0.05][,late=2]`
  or `trf:PATH` (a TRF file or a directory of them, searched recursively).
  SPEC is a variant, e.g. `drop:C12`, `float_memory=1`, `move:C14:before:C10`,
  `c525=tpn`, joined with `+`; see `AinalramiLab.Variant`.

  `fidelity` plays the corpus with the hybrid pairer and pairs every
  position again with the brute force or the engine.

  Exit codes: 0 done (for `fidelity`: no round differed), 1 `fidelity`
  found a differing round or `pair` found no legal pairing, 2 a usage or
  input error.
  """

  alias AinalramiLab.{Criteria, Fidelity, Pairer, Report, Simulate, Tournament, Variant}
  alias AinalramiVerify.{PairsFile, Position, Trf}

  def main(argv) do
    code =
      try do
        run(argv)
      rescue
        e in [Trf.Error, File.Error, ArgumentError] ->
          IO.puts(:stderr, "error: " <> Exception.message(e))
          2
      end

    System.halt(code)
  end

  @doc "Run a command; returns the exit code."
  def run(["simulate" | rest]) do
    {o, _, _} =
      OptionParser.parse(rest,
        strict: [
          variant: :string,
          baseline: :string,
          corpus: :string,
          pairer: :string,
          seed: :integer,
          workers: :integer,
          examples: :integer,
          out: :string
        ]
      )

    for k <- [:variant, :corpus],
        not Keyword.has_key?(o, k),
        do: raise(ArgumentError, "--#{k} is required")

    report =
      Simulate.run(
        variant: Variant.parse(o[:variant]),
        baseline: Variant.parse(Keyword.get(o, :baseline, "baseline")),
        corpus: corpus(o[:corpus]),
        pairer: pairer(Keyword.get(o, :pairer, "auto")),
        seed: Keyword.get(o, :seed, 1),
        workers: Keyword.get(o, :workers, System.schedulers_online()),
        examples: Keyword.get(o, :examples, 5)
      )

    text = Report.text(report)
    IO.write(text)

    if dir = o[:out] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "report.txt"), text)
      File.write!(Path.join(dir, "report.json"), Report.json(report))
    end

    0
  end

  def run(["pair", trf | rest]) do
    {o, _, _} = OptionParser.parse(rest, strict: [variant: :string, pairer: :string])
    text = File.read!(trf)
    pos = text |> Trf.parse() |> Position.build()
    v = Variant.parse(Keyword.get(o, :variant, "baseline"))

    case Pairer.pair(pairer(Keyword.get(o, :pairer, "auto")), pos, text, v) do
      {:ok, round} ->
        IO.write(PairsFile.write(round))
        0

      {:error, :no_legal_pairing} ->
        IO.puts(:stderr, "no legal pairing exists under this variant (1.9.3)")
        1
    end
  end

  def run(["fidelity" | rest]) do
    {o, _, _} =
      OptionParser.parse(rest,
        strict: [
          corpus: :string,
          against: :string,
          variant: :string,
          seed: :integer,
          workers: :integer
        ]
      )

    {:generated, spec, count} = corpus(o[:corpus] || raise(ArgumentError, "--corpus is required"))

    against =
      case o[:against] do
        "brute" -> :brute
        "engine" -> :engine
        _ -> raise ArgumentError, "--against brute|engine"
      end

    r =
      Fidelity.run(
        spec: spec,
        count: count,
        against: against,
        variant: Variant.parse(Keyword.get(o, :variant, "baseline")),
        seed: Keyword.get(o, :seed, 1),
        workers: Keyword.get(o, :workers, System.schedulers_online())
      )

    d = r.differ

    IO.puts(
      "hybrid vs #{against}: #{d.k} of #{d.n} rounds differ (95% upper bound #{Float.round(100 * d.hi, 4)}%)"
    )

    for f <- r.first, do: IO.puts("
--- #{f.kind}
" <> f.trf)
    if d.k == 0, do: 0, else: 1
  end

  def run(["criteria"]) do
    for c <- Variant.all_criteria() do
      extra = if c in Variant.baseline().order, do: "", else: "  (only with float_memory=3)"

      IO.puts(
        String.pad_trailing(c, 7) <>
          String.pad_trailing(Criteria.article(c), 14) <> Criteria.summary(c) <> extra
      )
    end

    0
  end

  def run(_) do
    IO.puts(:stderr, @moduledoc |> String.split("\n\n") |> Enum.at(1))
    2
  end

  @doc false
  def corpus("generated:" <> params) do
    kv =
      params
      |> String.split(",", trim: true)
      |> Map.new(fn item ->
        case String.split(item, "=", parts: 2) do
          [k, v] -> {String.trim(k), String.trim(v)}
          _ -> raise ArgumentError, "corpus parameter #{inspect(item)} is not key=value"
        end
      end)

    known = ~w(players rounds count absent forfeit late initial)

    for k <- Map.keys(kv),
        k not in known,
        do: raise(ArgumentError, "unknown corpus parameter #{k}")

    int = fn k, d -> kv |> Map.get(k, to_string(d)) |> String.to_integer() end
    flt = fn k -> kv |> Map.get(k, "0") |> parse_float() end

    spec = %Tournament{
      players: int.("players", 10),
      rounds: int.("rounds", 5),
      absent: flt.("absent"),
      forfeit: flt.("forfeit"),
      late: int.("late", 0),
      initial_colour: if(Map.get(kv, "initial", "w") == "b", do: :b, else: :w)
    }

    {:generated, spec, int.("count", 100)}
  end

  def corpus("trf:" <> path) do
    paths =
      cond do
        File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.trf"))
        File.regular?(path) -> [path]
        true -> raise ArgumentError, "no TRF file or directory at #{path}"
      end

    {:trf, Enum.sort(paths)}
  end

  def corpus(other),
    do: raise(ArgumentError, "--corpus generated:... or trf:PATH, got #{inspect(other)}")

  defp parse_float(s) do
    case Float.parse(s) do
      {f, ""} -> f
      _ -> raise ArgumentError, "not a number: #{inspect(s)}"
    end
  end

  defp pairer(s) when s in ["brute", "hybrid", "engine", "auto"], do: String.to_atom(s)
  defp pairer(s), do: raise(ArgumentError, "--pairer brute|hybrid|engine|auto, got #{inspect(s)}")
end

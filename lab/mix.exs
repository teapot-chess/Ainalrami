defmodule AinalramiLab.MixProject do
  use Mix.Project

  # A sibling of verify/, not part of it and not part of the engine. The
  # engine in `..` does not know this exists; verify/ does not know it
  # exists either. See README.md, "Where this lives, and why".
  def project do
    [
      app: :ainalrami_lab,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: AinalramiLab.CLI, name: "ainalrami-lab"]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  # verify/ by path, and through it the engine by path. The lab reuses the
  # verify suite's TRF reader, position model and brute-force search
  # primitives, and reaches the engine only through
  # `AinalramiVerify.Engine` - the same single door verify/ uses.
  defp deps do
    [{:ainalrami_verify, path: "../verify"}]
  end
end

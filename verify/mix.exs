defmodule AinalramiVerify.MixProject do
  use Mix.Project

  # A separate project on purpose: the engine in `..` does not know this
  # exists, compiles nothing from here and ships nothing from here. See
  # README.md, "Why a separate project".
  def project do
    [
      app: :ainalrami_verify,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      escript: [main_module: AinalramiVerify.CLI, name: "ainalrami-verify"],
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  # The engine is the only dependency, by path, so a verify build always
  # checks the engine in the same checkout. Only `AinalramiVerify.Engine`
  # calls into it; everything that judges a pairing is written here.
  defp deps do
    [{:ainalrami, path: ".."}]
  end
end

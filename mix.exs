defmodule Ainalrami.MixProject do
  use Mix.Project

  @version "0.49.0"
  @source_url "https://github.com/teapot-chess/Ainalrami"

  def project do
    [
      app: :ainalrami,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # Fixture data such as test/fixtures/rule_delta/manifest.exs is read by
      # the tests, never loaded as a test file.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: deps(),
      test_coverage: [summary: [threshold: 0]],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        flags: [:error_handling, :unknown, :extra_return, :missing_return]
      ],
      escript: escript(),
      releases: releases(),
      name: "Ainalrami",
      description: "A FIDE Dutch-system Swiss pairing engine, written in Elixir.",
      source_url: @source_url,
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/architecture.md",
          "docs/validation.md",
          "docs/cli-parity.md",
          "docs/conformance-c0403-2026.md",
          "docs/fide-criteria.md",
          "docs/engineering-log.md"
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # Dialyzer, for the by-hand deep-checks workflow only; never part of the
      # escript. Everything else here stays dependency-free on purpose.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # The portable release (`MIX_ENV=prod mix release`) is what the Windows zip
  # and the Linux/macOS archives are made of: ERTS included, so nothing needs
  # installing. It is started by rel/windows/launcher.c (ainalrami.exe) or
  # rel/ainalrami.sh, never by bin/ainalrami, which has no idea what a TRF is.
  defp releases do
    [
      ainalrami: [
        include_executables_for: [:windows, :unix],
        include_erts: true,
        strip_beams: true
      ]
    ]
  end

  # `mix escript.build` produces a single executable `ainalrami` file -
  # matches how JaVaFo is distributed (one runnable artifact you point a TRF
  # file at), rather than requiring `mix run` or a full release.
  defp escript do
    [
      main_module: Ainalrami.CLI,
      name: "ainalrami"
    ]
  end
end

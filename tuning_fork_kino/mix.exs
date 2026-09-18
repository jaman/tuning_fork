defmodule KinoTuningFork.MixProject do
  use Mix.Project

  @version "0.1.8"
  @source_url "https://github.com/jaman/tuning_fork"

  def project do
    [
      app: :tuning_fork_kino,
      version: @version,
      elixir: "~> 1.19",
      elixirc_options: [warnings_as_errors: true],
      description: "Livebook smart cells and a streaming stage for TuningFork.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "KinoTuningFork",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {KinoTuningFork.Application, []}
    ]
  end

  defp deps do
    [
      family(:tuning_fork, "~> 0.1.8", []),
      family(:tuning_fork_composer, "~> 0.1.8", []),
      family(:tuning_fork_samples, "~> 0.1.8", optional: true),
      family(:tuning_fork_midi, "~> 0.1.8", optional: true),
      {:kino, "~> 0.12"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp family(app, requirement, opts) do
    if System.get_env("PLUMB_HEX") == nil and System.get_env("TUNING_FORK_HEX") == nil and
         File.dir?("../#{app}") do
      {app, [path: "../#{app}"] ++ opts}
    else
      {app, requirement, opts}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib notebooks mix.exs README.md DESIGN.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/tuning_fork_kino/%{path}#L%{line}",
      extras: [
        "README.md",
        "DESIGN.md",
        "CHANGELOG.md",
        "notebooks/strudel.livemd",
        "notebooks/sonic_pi.livemd",
        "notebooks/composer.livemd"
      ]
    ]
  end
end

defmodule TuningForkDrafter.MixProject do
  use Mix.Project

  @version "0.1.6"
  @source_url "https://github.com/jaman/tuning_fork"

  def project do
    [
      app: :tuning_fork_drafter,
      version: @version,
      elixir: "~> 1.19",
      elixirc_options: [warnings_as_errors: true],
      description:
        "Terminal front ends for TuningFork: live patterns, live loops and a step sequencer, drawn with Drafter.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "TuningForkDrafter",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      family(:tuning_fork, "~> 0.1.6", []),
      family(:tuning_fork_composer, "~> 0.1.6", []),
      family(:tuning_fork_speaker, "~> 0.1.6", optional: true),
      family(:tuning_fork_samples, "~> 0.1.6", optional: true),
      family(:tuning_fork_midi, "~> 0.1.6", []),
      elsewhere(:drafter, "~> 0.4.0", "../../drafter", []),
      elsewhere(:french_curve, "~> 0.1.4", "../../french_curve", override: true),
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp elsewhere(app, requirement, path, opts) do
    if System.get_env("PLUMB_HEX") == nil and System.get_env("TUNING_FORK_HEX") == nil and
         File.dir?(path),
       do: {app, [path: path] ++ opts},
       else: {app, requirement, opts}
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
      files: ~w(lib mix.exs README.md DESIGN.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/tuning_fork_drafter/%{path}#L%{line}",
      extras: ["README.md", "DESIGN.md", "CHANGELOG.md"]
    ]
  end
end

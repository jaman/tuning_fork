defmodule TuningForkComposer.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jaman/tuning_fork"

  def project do
    [
      app: :tuning_fork_composer,
      version: @version,
      elixir: "~> 1.19",
      elixirc_options: [warnings_as_errors: true],
      description: "A headless step sequencer that writes TuningFork source.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "TuningForkComposer",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      family(:tuning_fork),
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp family(app, opts \\ []) do
    if System.get_env("TUNING_FORK_HEX") == nil and File.dir?("../#{app}") do
      {app, [path: "../#{app}"] ++ opts}
    else
      {app, "~> 0.1", opts}
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
      source_url_pattern:
        "#{@source_url}/blob/v#{@version}/tuning_fork_composer/%{path}#L%{line}",
      extras: ["README.md", "DESIGN.md", "CHANGELOG.md"]
    ]
  end
end

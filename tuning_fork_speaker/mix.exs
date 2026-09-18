defmodule TuningForkSpeaker.MixProject do
  use Mix.Project

  @version "0.1.11"
  @source_url "https://github.com/jaman/tuning_fork"

  def project do
    [
      app: :tuning_fork_speaker,
      version: @version,
      elixir: "~> 1.19",
      elixirc_options: [warnings_as_errors: true],
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_error_message: """
      tuning_fork_speaker's audio device did not build.

      This package is only the speaker. tuning_fork itself is pure Elixir and needs none of
      this: drop this dependency and everything but playback through the machine still works,
      including rendering to a buffer or a file.

      Building it needs a C compiler, and on Linux the ALSA headers (libasound2-dev).
      """,
      description: "Plays TuningFork audio through the machine's sound device.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "TuningForkSpeaker",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      family(:tuning_fork, "~> 0.1.11", []),
      {:elixir_make, "~> 0.9", runtime: false},
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
      files: ~w(lib c_src Makefile examples mix.exs README.md DESIGN.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/tuning_fork_speaker/%{path}#L%{line}",
      extras: ["README.md", "DESIGN.md", "CHANGELOG.md"]
    ]
  end
end

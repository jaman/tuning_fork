defmodule TuningForkMt32.MixProject do
  use Mix.Project

  @version "0.1.12"
  @source_url "https://github.com/jaman/tuning_fork"

  def project do
    [
      app: :tuning_fork_mt32,
      version: @version,
      elixir: "~> 1.19",
      elixirc_options: [warnings_as_errors: true],
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_error_message: """
      tuning_fork_mt32's NIF did not build.

      Building it needs only a C compiler. Munt itself is not needed to build: it is found
      at run time through MUNT_LOCATION.
      """,
      description: "Renders MIDI through the user's own Munt MT-32 emulator, found at run time.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "TuningForkMt32",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      family(:tuning_fork, "~> 0.1.12", []),
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
      files: ~w(lib c_src Makefile Makefile.win mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/tuning_fork_mt32/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end

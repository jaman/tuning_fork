defmodule TuningFork.MixProject do
  use Mix.Project

  @version "0.1.3"
  @source_url "https://github.com/jaman/tuning_fork"

  def project do
    [
      app: :tuning_fork,
      version: @version,
      elixir: "~> 1.19",
      elixirc_options: [warnings_as_errors: true],
      description:
        "Sound synthesised on the BEAM: voices, scores, live patterns and loops, pure Elixir.",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "TuningFork",
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto],
      mod: {TuningFork.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib examples mix.exs README.md DESIGN.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/tuning_fork/%{path}#L%{line}",
      extras: ["README.md", "DESIGN.md", "CHANGELOG.md"],
      groups_for_modules: [
        Writing: [
          TuningFork,
          TuningFork.Part,
          TuningFork.Part.Source,
          TuningFork.Score,
          TuningFork.Notes,
          TuningFork.Scale,
          TuningFork.Chord,
          TuningFork.Ring
        ],
        Patterns: [
          TuningFork.Pattern,
          TuningFork.Pattern.Control,
          TuningFork.Pattern.Mini,
          TuningFork.Pattern.Source,
          TuningFork.Pattern.Player,
          TuningFork.Pattern.Voicing,
          TuningFork.Strudel,
          TuningFork.Session,
          TuningFork.Session.View
        ],
        "Sonic Pi": [
          TuningFork.SonicPi,
          TuningFork.SonicPi.Buffer,
          TuningFork.SonicPi.Names,
          TuningFork.SonicPi.Synth,
          TuningFork.SonicPi.Effects,
          TuningFork.SonicPi.Thread,
          TuningFork.SonicPi.Blocks,
          TuningFork.SonicPi.Current
        ],
        Sound: [
          TuningFork.Voice,
          TuningFork.Voice.Live,
          TuningFork.Envelope,
          TuningFork.Filter,
          TuningFork.Curve,
          TuningFork.Wave,
          TuningFork.Kit,
          TuningFork.Gm,
          TuningFork.Gm.Names,
          TuningFork.Gm.Fonts,
          TuningFork.Reverb,
          TuningFork.Fx,
          TuningFork.Fx.Live,
          TuningFork.Mixer
        ],
        Recordings: [
          TuningFork.Sample,
          TuningFork.Sample.Bank,
          TuningFork.Sample.Set,
          TuningFork.Sample.Font,
          TuningFork.Sample.Fetch,
          TuningFork.Sample.Decode,
          TuningFork.Wav,
          TuningFork.Flac
        ],
        Playing: [
          TuningFork.Stage,
          TuningFork.Transport,
          TuningFork.Sink,
          TuningFork.Sink.Buffer,
          TuningFork.Sink.Silent,
          TuningFork.Tick,
          TuningFork.State,
          TuningFork.Store,
          TuningFork.Cache,
          TuningFork.Rand
        ],
        "MIDI and OSC": [
          TuningFork.Midi,
          TuningFork.Osc,
          TuningFork.Osc.Client,
          TuningFork.Osc.Out
        ],
        Tasks: [Mix.Tasks.TuningFork.Render]
      ]
    ]
  end
end

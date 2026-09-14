defmodule Mix.Tasks.TuningFork.Compose do
  @shortdoc "Compose in a terminal"

  @moduledoc """
  Runs `TuningFork.ComposerApp`, a step sequencer in a terminal.

      mix tuning_fork.compose --bpm 120 --bars 4 --meter 3 --division 8
  """

  use Mix.Task

  alias TuningFork.Composer

  @switches [
    bpm: :integer,
    bars: :integer,
    meter: :integer,
    division: :integer,
    gain: :float,
    key: :string,
    scale: :string,
    name: :string,
    empty: :boolean,
    out: :string
  ]

  @doc """
  Starts the editor and blocks until it quits.

  `argv` is the command line. An unknown switch raises; positional arguments are discarded.

    * `--bpm N`, `--bars N` — tempo and length
    * `--meter N` — beats to a bar
    * `--division N` — steps to a beat
    * `--gain N` — level per note, 0.0 to 1.0
    * `--key NOTE`, `--scale NAME` — what the pitched rows may play
    * `--name NAME` — the variable the written source binds the score to
    * `--empty` — start with no tracks instead of `TuningFork.Composer.demo/0`
    * `--out PATH` — where `w` writes, default `song.exs`
  """
  @spec run(OptionParser.argv()) :: :ok | {:error, term()}
  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    Drafter.run(TuningFork.ComposerApp, props: props(argv))
  end

  @doc """
  The command line as the map `TuningFork.ComposerApp.mount/1` is handed. Pass it to
  `Drafter.run/2` under the `:props` key.
  """
  @spec props(OptionParser.argv()) :: %{project: Composer.t(), out: Path.t()}
  def props(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    %{
      project: opts |> starting_project() |> apply_settings(opts),
      out: Keyword.get(opts, :out, "song.exs")
    }
  end

  defp starting_project(opts) do
    if opts[:empty], do: Composer.new(), else: Composer.demo()
  end

  defp apply_settings(project, opts) do
    [
      {:bpm, opts[:bpm]},
      {:bars, opts[:bars]},
      {:meter, opts[:meter]},
      {:division, opts[:division]},
      {:gain, opts[:gain]},
      {:root, opts[:key]},
      {:scale, opts[:scale]},
      {:name, opts[:name]}
    ]
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Enum.reduce(project, fn {field, value}, acc -> Composer.set(acc, field, value) end)
  end
end

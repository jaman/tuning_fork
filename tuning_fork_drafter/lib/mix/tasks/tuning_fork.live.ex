defmodule Mix.Tasks.TuningFork.Live do
  @shortdoc "Live code patterns in a terminal"

  @moduledoc """
  Runs `TuningFork.LiveCodeApp`, live coding mini-notation patterns in a terminal.

      mix tuning_fork.live --cps 0.75 --pattern "bd*4" --pattern "hh*8?"
  """

  use Mix.Task

  @switches [cps: :float, pattern: :keep, text: :boolean]

  @doc """
  Starts the editor and blocks until it quits.

  `argv` is the command line. An unknown switch raises.

    * `--cps N` — cycles per second, default 0.5
    * `--pattern S` — a slot to open on, repeatable
    * `--text` — draw with block characters even where the terminal could draw pixels
  """
  @spec run(OptionParser.argv()) :: :ok | {:error, term()}
  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    Code.ensure_loaded!(TuningFork.Drafter.Roll)
    Drafter.Widget.Registry.register(TuningFork.Drafter.Roll)

    Drafter.run(TuningFork.LiveCodeApp, props: props(argv))
  end

  @doc "The command line as the map `TuningFork.LiveCodeApp.mount/1` is handed."
  @spec props(OptionParser.argv()) :: %{
          patterns: [String.t()],
          cps: float(),
          pixels: boolean()
        }
  def props(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    patterns =
      case Keyword.get_values(opts, :pattern) do
        [] -> TuningFork.LiveCodeApp.demo()
        given -> given
      end

    %{
      patterns: patterns,
      cps: Keyword.get(opts, :cps, 0.5),
      pixels: not Keyword.get(opts, :text, false) and TuningFork.LiveCodeApp.pixels?()
    }
  end
end

defmodule Mix.Tasks.TuningFork.Midi do
  @shortdoc "A MIDI keyboard in and a pattern out, in a terminal"

  @moduledoc """
  Runs `TuningFork.MidiApp`: a keyboard played in and heard, a pattern played out with
  clock, and both shown on one key strip.

      mix tuning_fork.midi
      mix tuning_fork.midi --voice gm_epiano1 --pattern 's("bd*4")'
  """

  use Mix.Task

  @switches [voice: :string, pattern: :string]

  @doc """
  Starts the app and blocks until it quits.

  `argv` is the command line. An unknown switch raises.

    * `--voice NAME` — what the keyboard plays, default `gm_piano`
    * `--pattern ROW` — the pattern to play out, one expression
  """
  @spec run(OptionParser.argv()) :: :ok | {:error, term()}
  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    Drafter.run(TuningFork.MidiApp, props: props(argv))
  end

  @doc "The command line as the map `TuningFork.MidiApp.mount/1` is handed."
  @spec props(OptionParser.argv()) :: map()
  def props(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)
    Map.new(opts)
  end
end

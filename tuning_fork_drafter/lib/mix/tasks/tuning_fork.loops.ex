defmodule Mix.Tasks.TuningFork.Loops do
  @shortdoc "Live code named loops in a terminal"

  @moduledoc """
  Runs `TuningFork.LoopsApp`, live coding named loops in a terminal.

      mix tuning_fork.loops --loop "drums=part(bpm: 120, synth: Kit.voice(\\"bd\\", 0.3)) |> play(:c3, 1)"
  """

  use Mix.Task

  @switches [loop: :keep]

  @doc """
  Starts the editor and blocks until it quits.

  `argv` is the command line. An unknown switch raises.

    * `--loop NAME=SOURCE` — a loop to open on, repeatable. Without one
      `TuningFork.LoopsApp.demo/0` is used
  """
  @spec run(OptionParser.argv()) :: :ok | {:error, term()}
  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    Drafter.run(TuningFork.LoopsApp, props: props(argv))
  end

  @doc "The command line as the map `TuningFork.LoopsApp.mount/1` is handed."
  @spec props(OptionParser.argv()) :: %{loops: [{String.t(), String.t()}]}
  def props(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    loops =
      case Keyword.get_values(opts, :loop) do
        [] -> TuningFork.LoopsApp.demo()
        given -> Enum.map(given, &split/1)
      end

    %{loops: loops}
  end

  defp split(given) do
    case String.split(given, "=", parts: 2) do
      [name, source] -> {name, source}
      [name] -> {name, ""}
    end
  end
end

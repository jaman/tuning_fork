defmodule Mix.Tasks.TuningFork.Listen do
  @shortdoc "Play PCM arriving on a TCP port through the speaker"

  @moduledoc """
  Listen on a TCP port and play the raw signed 16-bit PCM that arrives through this
  machine's speaker, connection after connection — the far end of an ssh tunnel from a
  server sending with `TuningFork.Sink.Tcp`.

      mix tuning_fork.listen
      mix tuning_fork.listen --port 4713 --max-lag 100

  Runs until stopped with Ctrl-C.

  Options:

    * `--port N` — the port, on the loopback interface. Default 4713
    * `--rate N`, `--channels N` — the PCM format. Default 44100 and 2
    * `--max-lag N` — the most audio kept waiting to play, in milliseconds. Default 100
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [port: :integer, rate: :integer, channels: :integer, max_lag: :integer]
      )

    Mix.Task.run("app.start")

    {:ok, _listener} =
      TuningFork.Listener.start_link(
        port: Keyword.get(opts, :port, 4_713),
        rate: Keyword.get(opts, :rate, 44_100),
        channels: Keyword.get(opts, :channels, 2),
        max_lag_ms: Keyword.get(opts, :max_lag, 100)
      )

    Process.sleep(:infinity)
  end
end

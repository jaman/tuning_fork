defmodule Mix.Tasks.TuningFork.Listen do
  @shortdoc "Play PCM arriving on a TCP port through the speaker"

  @moduledoc """
  Listen on a TCP port and play the raw signed 16-bit PCM that arrives through this
  machine's speaker, connection after connection — the far end of an ssh tunnel from a
  server sending with `TuningFork.Sink.Tcp`.

      mix tuning_fork.listen
      mix tuning_fork.listen --port 5000 --max-lag 100

  Runs until stopped with Ctrl-C.

  Options:

    * `--port N` — the port to listen on. Required
    * `--ip A` — the interface, an address such as `0.0.0.0` for every one. Default `127.0.0.1`
    * `--rate N`, `--channels N` — the PCM format. Default 44100 and 2
    * `--max-lag N` — the most audio kept waiting to play, in milliseconds. Default 100
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          port: :integer,
          ip: :string,
          rate: :integer,
          channels: :integer,
          max_lag: :integer
        ]
      )

    Mix.Task.run("app.start")

    {:ok, _listener} =
      TuningFork.Listener.start_link(
        port: Keyword.get(opts, :port) || Mix.raise("--port is required"),
        ip:
          opts
          |> Keyword.get(:ip, "127.0.0.1")
          |> String.to_charlist()
          |> :inet.parse_address()
          |> elem(1),
        rate: Keyword.get(opts, :rate, 44_100),
        channels: Keyword.get(opts, :channels, 2),
        max_lag_ms: Keyword.get(opts, :max_lag, 100)
      )

    Process.sleep(:infinity)
  end
end

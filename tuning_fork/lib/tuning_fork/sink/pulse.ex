defmodule TuningFork.Sink.Pulse do
  @moduledoc """
  A sink that plays through a PulseAudio or PipeWire server by piping PCM into `pacat`.

      {:ok, _stage} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Pulse, sink_opts: [server: "tcp:127.0.0.1:<port>"])

  The server is named the way `PULSE_SERVER` is: `tcp:host:port`, or a socket path. A
  server reached through an ssh reverse tunnel is `tcp:127.0.0.1:<forwarded port>`. The
  program's own blocking write is the pacing: a write returns once the server has taken
  the bytes.

  ## Options

    * `:server` — the `PULSE_SERVER` value. Required
    * `:latency_ms` — the buffer asked of the server. Default `40`
    * `:command` — the player program. Default: `pacat` on `PATH`
    * `:args` — its arguments. Default: `player_args/1` for the stage's rate and channels
    * `:rate`, `:channels` — filled in by the stage
  """

  @behaviour TuningFork.Sink

  @type t :: port()

  @impl true
  def open(opts) do
    command = Keyword.get(opts, :command) || System.find_executable("pacat")

    with {:ok, executable} <- executable(command) do
      args = Keyword.get_lazy(opts, :args, fn -> player_args(opts) end)

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          args: args,
          env: [{~c"PULSE_SERVER", to_charlist(Keyword.fetch!(opts, :server))}]
        ])

      {:ok, port}
    end
  end

  defp executable(nil), do: {:error, {:no_such_program, "pacat"}}

  defp executable(command) do
    if File.exists?(command) or System.find_executable(command) do
      {:ok, System.find_executable(command) || command}
    else
      {:error, {:no_such_program, command}}
    end
  end

  @impl true
  def write(port, pcm) do
    if Port.info(port) do
      Port.command(port, pcm)
      :ok
    else
      {:error, :closed}
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  @impl true
  def close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The arguments that make `pacat` take raw 16-bit little-endian PCM at the given rate and channel count."
  @spec player_args(keyword()) :: [String.t()]
  def player_args(opts) do
    [
      "--raw",
      "--format=s16le",
      "--rate=#{Keyword.fetch!(opts, :rate)}",
      "--channels=#{Keyword.fetch!(opts, :channels)}",
      "--latency-msec=#{Keyword.get(opts, :latency_ms, 40)}"
    ]
  end
end

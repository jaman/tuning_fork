defmodule TuningFork.Listener do
  @moduledoc """
  Plays raw signed 16-bit little-endian PCM arriving on a TCP port through this machine's
  speaker, one connection after another — the far end of `TuningFork.Sink.Tcp` over an
  ssh tunnel.

      {:ok, listener} = TuningFork.Listener.start_link(port: 4713)

  Each connection opens the sink afresh and closes it when the connection ends; the next
  connection is accepted then. Audio that has arrived faster than it can play — a burst
  while the device was opening, a stall on the link — is dropped down to `:max_lag_ms`,
  so what is heard stays that close to what was sent.

  ## Options

    * `:port` — the TCP port to listen on, on the loopback interface. `0` picks a free
      one; `port/1` tells which. Default `4713`
    * `:rate`, `:channels` — the PCM format. Default `44_100` and `2`
    * `:sink` — the `TuningFork.Sink` to play through, as `module` or `{module, opts}`.
      Default `TuningFork.Sink.Speaker`
    * `:max_lag_ms` — the most audio kept waiting to play. Default `100`
    * `:name` — a registered name. Default: none
  """

  use GenServer

  require Logger

  @doc "Start listening."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "The port being listened on."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(listener), do: GenServer.call(listener, :port)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    port = Keyword.get(opts, :port, 4_713)

    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        {:ok, bound} = :inet.port(socket)
        Logger.info("sound: listening on 127.0.0.1:#{bound}")
        {sink, sink_opts} = sink(Keyword.get(opts, :sink, TuningFork.Sink.Speaker))

        state = %{
          socket: socket,
          port: bound,
          sink: sink,
          sink_opts:
            Keyword.merge(
              [rate: Keyword.get(opts, :rate, 44_100), channels: Keyword.get(opts, :channels, 2)],
              sink_opts
            ),
          max_lag_bytes:
            div(Keyword.get(opts, :max_lag_ms, 100) * Keyword.get(opts, :rate, 44_100), 1_000) * 2 *
              Keyword.get(opts, :channels, 2),
          acceptor: nil
        }

        {:ok, accept(state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl GenServer
  def handle_info({:EXIT, acceptor, _reason}, %{acceptor: acceptor} = state),
    do: {:noreply, accept(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    :ok
  end

  defp sink({module, opts}), do: {module, opts}
  defp sink(module) when is_atom(module), do: {module, []}

  defp accept(state), do: %{state | acceptor: spawn_link(fn -> serve(state) end)}

  defp serve(state) do
    {:ok, connection} = :gen_tcp.accept(state.socket)
    {:ok, {peer, _port}} = :inet.peername(connection)
    Logger.info("sound: playing from #{:inet.ntoa(peer)}")

    case state.sink.open(state.sink_opts) do
      {:ok, sink_state} ->
        play(connection, state, sink_state)
        state.sink.close(sink_state)

      {:error, reason} ->
        Logger.error("sound: #{inspect(state.sink)} could not open: #{inspect(reason)}")
    end

    :gen_tcp.close(connection)
    Logger.info("sound: connection ended")
  end

  defp play(connection, state, sink_state) do
    case :gen_tcp.recv(connection, 0) do
      {:ok, data} ->
        pcm = data |> drain(connection) |> latest(state.max_lag_bytes)

        case state.sink.write(sink_state, pcm) do
          :ok ->
            play(connection, state, sink_state)

          {:error, reason} ->
            Logger.error(
              "sound: #{inspect(state.sink)} stopped taking samples: #{inspect(reason)}"
            )
        end

      {:error, _closed} ->
        :ok
    end
  end

  defp drain(acc, connection) do
    case :gen_tcp.recv(connection, 0, 0) do
      {:ok, more} -> drain(acc <> more, connection)
      {:error, _nothing_waiting} -> acc
    end
  end

  defp latest(pcm, max) when byte_size(pcm) <= max, do: pcm
  defp latest(pcm, max), do: binary_part(pcm, byte_size(pcm) - max, max)
end

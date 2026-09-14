defmodule TuningFork.Test.FileServer do
  @moduledoc "A one-file HTTP server on a free port, counting how often it was asked."

  use GenServer

  @spec start(Path.t()) :: {:ok, %{pid: pid(), port: :inet.port_number()}}
  def start(path) do
    {:ok, pid} = GenServer.start_link(__MODULE__, path)
    {:ok, %{pid: pid, port: GenServer.call(pid, :port)}}
  end

  @spec hits(%{pid: pid()}) :: non_neg_integer()
  def hits(%{pid: pid}), do: GenServer.call(pid, :hits)

  @impl true
  def init(path) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    server = self()
    spawn_link(fn -> accept(listener, path, server) end)
    {:ok, %{port: port, hits: 0}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:hits, _from, state), do: {:reply, state.hits, state}

  @impl true
  def handle_cast(:hit, state), do: {:noreply, %{state | hits: state.hits + 1}}

  defp accept(listener, path, server) do
    {:ok, socket} = :gen_tcp.accept(listener)
    drain(socket)
    GenServer.cast(server, :hit)
    body = File.read!(path)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
        body
    )

    :gen_tcp.close(socket)
    accept(listener, path, server)
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, _header} -> drain(socket)
      _closed -> :ok
    end
  end
end

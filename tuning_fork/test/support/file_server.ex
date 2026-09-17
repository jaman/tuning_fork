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

  @spec last_path(%{pid: pid()}) :: String.t() | nil
  def last_path(%{pid: pid}), do: GenServer.call(pid, :last_path)

  @impl true
  def init(path) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    server = self()
    spawn_link(fn -> accept(listener, path, server) end)
    {:ok, %{port: port, hits: 0, last_path: nil}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:hits, _from, state), do: {:reply, state.hits, state}
  def handle_call(:last_path, _from, state), do: {:reply, state.last_path, state}

  @impl true
  def handle_cast({:hit, asked}, state),
    do: {:noreply, %{state | hits: state.hits + 1, last_path: asked}}

  defp accept(listener, path, server) do
    {:ok, socket} = :gen_tcp.accept(listener)
    asked = drain(socket, nil)
    GenServer.cast(server, {:hit, asked})
    body = File.read!(path)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
        body
    )

    :gen_tcp.close(socket)
    accept(listener, path, server)
  end

  defp drain(socket, asked) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, :http_eoh} -> asked
      {:ok, {:http_request, _method, {:abs_path, path}, _version}} -> drain(socket, path)
      {:ok, _header} -> drain(socket, asked)
      _closed -> asked
    end
  end
end

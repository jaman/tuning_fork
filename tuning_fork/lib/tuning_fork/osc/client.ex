defmodule TuningFork.Osc.Client do
  @moduledoc """
  A UDP socket for sending `TuningFork.Osc` messages, and reading them back.

      {:ok, client} = Osc.Client.start_link(host: "127.0.0.1", port: 57_120)
      Osc.Client.send(client, "/play", [60, 0.8])
  """

  use GenServer

  require Logger

  alias TuningFork.Osc

  @type t :: GenServer.server()

  @doc """
  Open a socket.

  With `:listen`, every message that arrives is sent to `:owner` as
  `{:osc, address, args, {from_host, from_port}}`; a packet that does not decode as a
  message is dropped.

  ## Options

    * `:host` — where to send, a charlist, binary or tuple. Default `"127.0.0.1"`
    * `:port` — which port to send to. Default 57120
    * `:listen` — bind this port and read as well as write. Default none
    * `:owner` — who to send what arrives to. Default whoever called
    * `:name` — register the client under a name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    opts = Keyword.put_new(opts, :owner, self())

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      given -> GenServer.start_link(__MODULE__, opts, name: given)
    end
  end

  @doc "Send one message."
  @spec send(t(), String.t(), [term()]) :: :ok
  def send(client, address, args \\ []) do
    GenServer.cast(client, {:send, Osc.encode(address, args)})
  end

  @doc "Send several messages as one bundle under the time tag `at`."
  @spec bundle(t(), [{String.t(), [term()]}], :now | DateTime.t()) :: :ok
  def bundle(client, messages, at \\ :now) do
    GenServer.cast(client, {:send, Osc.bundle(messages, at)})
  end

  @doc "Send bytes already encoded."
  @spec packet(t(), binary()) :: :ok
  def packet(client, bytes) when is_binary(bytes), do: GenServer.cast(client, {:send, bytes})

  @doc "Where this client is sending, as `{host, port}`."
  @spec to(t()) :: {term(), pos_integer()}
  def to(client), do: GenServer.call(client, :to)

  @doc "Point the client somewhere else."
  @spec point(t(), term(), pos_integer()) :: :ok
  def point(client, host, port), do: GenServer.cast(client, {:point, host, port})

  @impl true
  def init(opts) do
    bind = Keyword.get(opts, :listen, 0)

    case :gen_udp.open(bind, [:binary, active: true]) do
      {:ok, socket} ->
        {:ok,
         %{
           socket: socket,
           host: host(Keyword.get(opts, :host, "127.0.0.1")),
           port: Keyword.get(opts, :port, 57_120),
           owner: Keyword.fetch!(opts, :owner)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:send, bytes}, state) do
    :gen_udp.send(state.socket, state.host, state.port, bytes)

    {:noreply, state}
  end

  def handle_cast({:point, host, port}, state) do
    {:noreply, %{state | host: host(host), port: port}}
  end

  @impl true
  def handle_call(:to, _from, state), do: {:reply, {state.host, state.port}, state}

  @impl true
  def handle_info({:udp, _socket, from, port, bytes}, state) do
    case Osc.decode(bytes) do
      {:ok, address, args} ->
        Kernel.send(state.owner, {:osc, address, args, {from, port}})

      {:error, _reason} ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_udp.close(state.socket)

    :ok
  end

  defp host(name) when is_binary(name), do: String.to_charlist(name)
  defp host(name), do: name
end

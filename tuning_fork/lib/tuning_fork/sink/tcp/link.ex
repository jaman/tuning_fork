defmodule TuningFork.Sink.Tcp.Link do
  @moduledoc """
  The connection behind `TuningFork.Sink.Tcp`: a process holding the socket, the clock
  that paces writes to real time, and the time of the next connection attempt.
  """

  use GenServer

  require Logger

  @connect_timeout 300
  @prime_frames 1_024

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       host: opts |> Keyword.get(:host, "127.0.0.1") |> to_charlist(),
       port: Keyword.fetch!(opts, :port),
       rate: Keyword.fetch!(opts, :rate),
       frame: 2 * Keyword.fetch!(opts, :channels),
       lead_us: Keyword.get(opts, :lead_ms, 60) * 1_000,
       warm_up_us: Keyword.get(opts, :warm_up_ms, 0) * 1_000,
       prime_frames: Keyword.get(opts, :prime_frames, @prime_frames),
       retry_us: Keyword.get(opts, :retry_ms, 2_000) * 1_000,
       socket: nil,
       retry_at: now_us(),
       clock: nil,
       warm_until: 0,
       primed: 0
     }}
  end

  @impl GenServer
  def handle_call({:write, pcm}, _from, state) do
    state = state |> connected() |> sent(pcm) |> paced(pcm)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:tcp_closed, _socket}, state), do: {:noreply, dropped(state)}
  def handle_info({:tcp_error, _socket, _reason}, state), do: {:noreply, dropped(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{socket: socket}) do
    if socket, do: :gen_tcp.close(socket)
    :ok
  end

  defp connected(%{socket: socket} = state) when socket != nil, do: state

  defp connected(state) do
    now = now_us()

    if now < state.retry_at do
      state
    else
      case :gen_tcp.connect(
             state.host,
             state.port,
             [:binary, active: true, nodelay: true],
             @connect_timeout
           ) do
        {:ok, socket} ->
          Logger.info("tuning_fork: sending PCM to #{state.host}:#{state.port}")
          now = now_us()

          %{
            state
            | socket: socket,
              clock: {now, 0},
              warm_until: now + state.warm_up_us,
              primed: 0
          }

        {:error, reason} ->
          Logger.info(
            "tuning_fork: #{state.host}:#{state.port} #{inspect(reason)}, trying again in #{div(state.retry_us, 1_000)} ms"
          )

          %{state | retry_at: now + state.retry_us}
      end
    end
  end

  defp sent(%{socket: nil} = state, _pcm), do: state

  defp sent(state, pcm) do
    priming? = state.primed < state.prime_frames * state.frame

    if not priming? and now_us() < state.warm_until do
      state
    else
      case :gen_tcp.send(state.socket, pcm) do
        :ok -> %{state | primed: state.primed + byte_size(pcm)}
        {:error, _reason} -> dropped(state)
      end
    end
  end

  defp dropped(%{socket: nil} = state), do: state

  defp dropped(state) do
    Logger.info(
      "tuning_fork: #{state.host}:#{state.port} closed, trying again in #{div(state.retry_us, 1_000)} ms"
    )

    :gen_tcp.close(state.socket)
    %{state | socket: nil, clock: nil, retry_at: now_us() + state.retry_us}
  end

  defp paced(%{clock: nil} = state, pcm) do
    Process.sleep(div(duration_us(state, pcm), 1_000))
    state
  end

  defp paced(%{clock: {started, played}} = state, pcm) do
    played = played + duration_us(state, pcm)
    due = started + played - state.lead_us
    wait = due - now_us()
    if wait > 0, do: Process.sleep(div(wait, 1_000))
    %{state | clock: {started, played}}
  end

  defp duration_us(state, pcm), do: div(byte_size(pcm) * 1_000_000, state.frame * state.rate)

  defp now_us, do: System.monotonic_time(:microsecond)
end

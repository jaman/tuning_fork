defmodule TuningFork.Pattern.Ahead do
  @moduledoc """
  A `TuningFork.Pattern.Player` rendered ahead of time in a process of its own, so the
  stage takes its chunks ready-made and the pattern's synthesis runs on another core.

      {:ok, ahead} = TuningFork.Pattern.Ahead.start_link(player: player, chunk: 256, channels: 2)
      pcm = TuningFork.Pattern.Ahead.next(ahead)
      TuningFork.Pattern.Ahead.apply(ahead, &TuningFork.Pattern.Player.gain(&1, 0.5))

  Up to `:depth` chunks are kept rendered (default 8); `next/1` returns the oldest and
  renders one on the spot when none is ready. A change made with `apply/2` reaches the
  player at the render frontier, at most `:depth` chunks ahead of what `next/1` has
  handed out.
  """

  use GenServer

  alias TuningFork.Pattern.Player

  @depth 8

  @doc "Start rendering `:player` in chunks of `:chunk` frames for `:channels` channels, `:depth` chunks ahead."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The next chunk."
  @spec next(GenServer.server()) :: binary()
  def next(ahead), do: GenServer.call(ahead, :next)

  @doc "Change the player with `fun` from the render frontier on."
  @spec apply(GenServer.server(), (Player.t() -> Player.t())) :: :ok
  def apply(ahead, fun) when is_function(fun, 1), do: GenServer.cast(ahead, {:apply, fun})

  @doc "Where the player has reached at the render frontier, in cycles."
  @spec cycle(GenServer.server()) :: float()
  def cycle(ahead), do: GenServer.call(ahead, :cycle)

  @doc "How many chunks are rendered and waiting."
  @spec rendered(GenServer.server()) :: non_neg_integer()
  def rendered(ahead), do: GenServer.call(ahead, :rendered)

  @doc "Stop rendering."
  @spec stop(GenServer.server()) :: :ok
  def stop(ahead), do: GenServer.stop(ahead)

  @impl GenServer
  def init(opts) do
    state = %{
      player: Keyword.fetch!(opts, :player),
      chunk: Keyword.fetch!(opts, :chunk),
      channels: Keyword.get(opts, :channels, 2),
      depth: Keyword.get(opts, :depth, @depth),
      ready: :queue.new(),
      count: 0
    }

    {:ok, fill(state)}
  end

  @impl GenServer
  def handle_call(:next, _from, %{count: 0} = state) do
    {pcm, player} = Player.advance(state.player, state.chunk, state.channels)
    {:reply, pcm, fill(%{state | player: player})}
  end

  def handle_call(:next, _from, state) do
    {{:value, pcm}, ready} = :queue.out(state.ready)
    {:reply, pcm, fill(%{state | ready: ready, count: state.count - 1})}
  end

  def handle_call(:cycle, _from, state), do: {:reply, Player.cycle(state.player), state}
  def handle_call(:rendered, _from, state), do: {:reply, state.count, state}

  @impl GenServer
  def handle_cast({:apply, fun}, state), do: {:noreply, %{state | player: fun.(state.player)}}

  @impl GenServer
  def handle_info(:render, %{count: count, depth: depth} = state) when count >= depth,
    do: {:noreply, state}

  def handle_info(:render, state) do
    {pcm, player} = Player.advance(state.player, state.chunk, state.channels)

    {:noreply,
     fill(%{state | player: player, ready: :queue.in(pcm, state.ready), count: state.count + 1})}
  end

  defp fill(%{count: count, depth: depth} = state) when count < depth do
    send(self(), :render)
    state
  end

  defp fill(state), do: state
end

defmodule TuningFork.Osc.Out do
  @moduledoc """
  Plays a `TuningFork.Score` out over OSC, in time.

      {:ok, client} = TuningFork.Osc.Client.start_link(port: 57_120)
      {:ok, playing} = TuningFork.Osc.Out.play(client, score)

  """

  use GenServer

  alias TuningFork.Osc.Client
  alias TuningFork.{Score, Voice}

  @type t :: pid()

  @doc """
  Play `score` through `client`, sending one message per note when its moment arrives.

  The player stops when the calling process exits.

  ## Options

    * `:address` — what to send each note to, default `"/play"`
    * `:shape` — a function from a `TuningFork.Voice` and its length in seconds to the
      argument list. Default is `[freq, gain, seconds, pan]`, all floats
    * `:loop` — start again on reaching the end, default false
    * `:hush` — an address to send on stopping, default `"/hush"`. `nil` sends nothing
  """
  @spec play(Client.t(), Score.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def play(client, %Score{} = score, opts \\ []) do
    GenServer.start_link(__MODULE__, {client, score, opts, self()})
  end

  @doc "Stop, sending the `:hush` address first."
  @spec stop(t()) :: :ok
  def stop(player) do
    if Process.alive?(player), do: GenServer.stop(player, :normal), else: :ok
  end

  @doc """
  The messages `score` becomes, as `{seconds, address, args}`, without sending them.

  Takes `play/3`'s `:address` and `:shape` options.

      iex> score = TuningFork.Score.new(bpm: 120, beats: 4)
      iex> TuningFork.Osc.Out.messages(score)
      []
  """
  @spec messages(Score.t(), keyword()) :: [{float(), String.t(), [term()]}]
  def messages(%Score{} = score, opts \\ []) do
    address = Keyword.get(opts, :address, "/play")
    shape = Keyword.get(opts, :shape, &default_shape/2)

    score.layers
    |> Enum.reduce(score.notes, fn layer, acc -> acc ++ layer.notes end)
    |> Enum.map(fn {beat, voice} ->
      {Score.beat_to_seconds(score, beat), address, shape.(voice, Voice.duration(voice))}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp default_shape(%Voice{} = voice, seconds) do
    [voice.freq * 1.0, voice.gain * 1.0, seconds * 1.0, voice.pan * 1.0]
  end

  @impl true
  def init({client, score, opts, caller}) do
    Process.flag(:trap_exit, true)
    Process.monitor(caller)

    state = %{
      client: client,
      hush: Keyword.get(opts, :hush, "/hush"),
      loop: Keyword.get(opts, :loop, false),
      length: Score.duration(score),
      messages: messages(score, opts),
      started: System.monotonic_time(:millisecond),
      round: 0
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info({:send, address, args}, state) do
    Client.send(state.client, address, args)

    {:noreply, state}
  end

  def handle_info(:round, state) do
    if state.loop do
      {:noreply, schedule(%{state | round: state.round + 1})}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.hush && Process.alive?(state.client) do
      Client.send(state.client, state.hush, [])
    end

    :ok
  end

  defp schedule(state) do
    Enum.each(state.messages, fn {at, address, args} ->
      Process.send_after(self(), {:send, address, args}, due(state, at))
    end)

    Process.send_after(self(), :round, due(state, state.length))

    state
  end

  defp due(state, at) do
    wanted = round(state.started + (state.round * state.length + at) * 1_000)

    max(wanted - System.monotonic_time(:millisecond), 0)
  end
end

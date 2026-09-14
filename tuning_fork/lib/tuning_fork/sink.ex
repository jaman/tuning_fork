defmodule TuningFork.Sink do
  @moduledoc """
  The behaviour of an output for mixed samples: opened once, written to in chunks, closed.
  """

  @type t :: term()

  @doc """
  Open the sink with the stage's options, which always include `:rate` (samples per second)
  and `:channels` (samples per frame). Returns the state the other callbacks receive.
  """
  @callback open(keyword()) :: {:ok, t()} | {:error, term()}

  @doc """
  Take one chunk of signed 16-bit little-endian PCM.

  Must not block for longer than the audio the chunk represents. Must return
  `{:error, reason}` when the destination can no longer take samples; the stage then stops
  feeding this sink.
  """
  @callback write(t(), binary()) :: :ok | {:error, term()}

  @doc "Release the sink."
  @callback close(t()) :: :ok

  @doc "The sink named by the `:tuning_fork, :sink` setting, defaulting to `TuningFork.Sink.Silent`."
  @spec configured() :: module()
  def configured, do: Application.get_env(:tuning_fork, :sink, TuningFork.Sink.Silent)
end

defmodule TuningFork.Sink.Silent do
  @moduledoc """
  A sink that discards everything written to it.
  """

  @behaviour TuningFork.Sink

  @impl true
  def open(_opts), do: {:ok, :silent}

  @impl true
  def write(_state, _pcm), do: :ok

  @impl true
  def close(_state), do: :ok
end

defmodule TuningFork.Sink.Collect do
  @moduledoc """
  A sink that sends everything written to a process as `{:pcm, binary}`.
  """

  @behaviour TuningFork.Sink

  @doc """
  Open the sink.

  ## Options

    * `:owner` — who receives `{:pcm, binary}`, default the opening process
    * `:rate` — samples per second, default 44100
    * `:channels` — samples per frame, default 2
  """
  @impl true
  def open(opts) do
    {:ok,
     %{
       owner: Keyword.get(opts, :owner, self()),
       rate: Keyword.get(opts, :rate, 44_100),
       channels: Keyword.get(opts, :channels, 2)
     }}
  end

  @doc "Send `pcm` to the owner, then sleep for as long as the audio it holds lasts."
  @impl true
  def write(%{owner: owner, rate: rate, channels: channels}, pcm) do
    send(owner, {:pcm, pcm})
    frames = div(byte_size(pcm), channels * 2)
    Process.sleep(max(1, div(frames * 1_000, rate)))
    :ok
  end

  @impl true
  def close(_state), do: :ok
end

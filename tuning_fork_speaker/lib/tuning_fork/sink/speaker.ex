defmodule TuningFork.Sink.Speaker do
  @moduledoc """
  A `TuningFork.Sink` that plays through the machine's audio device.

      {:ok, stage} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Speaker, chunk: 256)
  """

  @behaviour TuningFork.Sink

  alias TuningFork.Speaker.Device

  @doc """
  Open the device. Returns `{:ok, state}` or `{:error, :unavailable}` when this machine has
  no audio device.

  Options:

    * `:rate` — samples per second, default 44100
    * `:channels` — default 2; `TuningFork.Stage` passes its own
    * `:lead` — frames kept queued ahead of playback, default 512
    * `:buffer` — ring size in frames, default 4096; must be larger than `:lead`
  """
  @impl true
  def open(opts) do
    rate = Keyword.get(opts, :rate, 44_100)
    channels = Keyword.get(opts, :channels, 2)
    buffer = Keyword.get(opts, :buffer, 4_096)
    lead = Keyword.get(opts, :lead, 512)

    with {:ok, device} <- Device.open(rate, channels, buffer) do
      {:ok, %{device: device, channels: channels, rate: rate, buffer: buffer, lead: lead}}
    end
  rescue
    ErlangError -> {:error, :unavailable}
  end

  @doc """
  Queue PCM for playback. Blocks until no more than `:lead` frames are queued before adding
  more, then writes all of `pcm`. Returns `:ok` or `{:error, reason}`.
  """
  @impl true
  def write(%{device: device} = state, pcm) do
    wait_for_lead(state)

    case Device.write(device, pcm) do
      {:ok, frames} ->
        taken = frames * state.channels * 2

        case pcm do
          <<_done::binary-size(taken), rest::binary>> when rest != <<>> -> write(state, rest)
          _drained -> :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def close(%{device: device}), do: Device.close(device)

  @doc "Whether this machine can play sound."
  @spec available?() :: boolean()
  defdelegate available?, to: Device

  @doc "Frames currently queued for playback."
  @spec queued(map()) :: non_neg_integer()
  def queued(%{device: device, buffer: buffer}), do: buffer - Device.space(device)

  defp wait_for_lead(state) do
    ahead = queued(state)

    if ahead > state.lead do
      Process.sleep(max(1, div((ahead - state.lead) * 1_000, state.rate)))
      wait_for_lead(state)
    end
  end
end

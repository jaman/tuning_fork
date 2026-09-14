defmodule TuningFork.Speaker.Device do
  @moduledoc """
  The playback device, as a NIF over miniaudio.

      {:ok, device} = Device.open(44_100, 2, 4_096)
      {:ok, frames} = Device.write(device, pcm)
      :ok = Device.close(device)
  """

  @on_load :load_nif

  @type t :: reference()

  @doc false
  def load_nif do
    :tuning_fork_speaker
    |> :code.priv_dir()
    |> :filename.join(~c"tuning_fork_nif")
    |> :erlang.load_nif(0)
    |> case do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Open a playback device at `rate` samples per second with `channels` channels, and start it.

  `buffer_frames` sizes the ring `write/2` fills. Returns `{:error, reason}` when no device
  opens, and raises `ErlangError` if the NIF did not build.
  """
  @spec open(pos_integer(), pos_integer(), pos_integer()) :: {:ok, t()} | {:error, atom()}
  def open(_rate, _channels, _buffer_frames), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Copy PCM into the ring, returning how many frames were taken.

  `pcm` is interleaved signed 16-bit little-endian, `channels` samples to a frame. Never
  blocks: copies what fits and leaves the rest to the caller. Raises `ErlangError` if the NIF
  did not build.
  """
  @spec write(t(), binary()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def write(_device, _pcm), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Frames the ring will accept right now. Raises `ErlangError` if the NIF did not build."
  @spec space(t()) :: non_neg_integer()
  def space(_device), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Stop the device and free it. Also happens when the reference is collected. Raises
  `ErlangError` if the NIF did not build.
  """
  @spec close(t()) :: :ok
  def close(_device), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Whether the NIF loaded and this machine will open a device.

  Never raises. The answer is computed once and kept for the life of the VM.
  """
  @spec available?() :: boolean()
  def available? do
    case :persistent_term.get(__MODULE__, :unasked) do
      :unasked ->
        answer = probe()
        :persistent_term.put(__MODULE__, answer)
        answer

      answer ->
        answer
    end
  end

  defp probe do
    case open(44_100, 2, 1_024) do
      {:ok, device} ->
        close(device)
        true

      {:error, _reason} ->
        false
    end
  rescue
    ErlangError -> false
  end
end

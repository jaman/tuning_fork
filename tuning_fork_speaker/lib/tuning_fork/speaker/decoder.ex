defmodule TuningFork.Speaker.Decoder do
  @moduledoc """
  Decodes MP3, FLAC and WAV in this process, in C (miniaudio's decoders), to signed
  16-bit little-endian interleaved PCM at the recording's own rate and channel count.
  Needs no program on the machine, so it works where none can run, such as a phone.

      {:ok, pcm, 44_100, 2} = TuningFork.Speaker.Decoder.decode(File.read!("theme.mp3"))
  """

  alias TuningFork.Speaker.Device

  @doc """
  The PCM in `encoded`, with its rate and channels. `{:error, :unsupported}` for bytes
  that are none of the formats, `{:error, :unavailable}` when the NIF did not build.
  """
  @spec decode(binary()) ::
          {:ok, binary(), pos_integer(), pos_integer()}
          | {:error, :unsupported | :out_of_memory | :unavailable}
  def decode(encoded) when is_binary(encoded) do
    Device.decode(encoded)
  rescue
    ErlangError -> {:error, :unavailable}
  end
end

defmodule TuningFork.Wma do
  @moduledoc """
  Decodes xWMA — WMA v2 audio as XACT wave banks and `.xwma` files hold it — in pure
  Elixir, as a `TuningFork.Xwma.Decoder`. With this package a dependency,
  `TuningFork.Xwma.decode/1` uses it without configuration and needs no `ffmpeg`.

      {:ok, pcm, %{rate: 44_100, channels: 2}} = TuningFork.Wma.decode(File.read!("music.xwma"))

  The decoder is a port of FFmpeg's WMA decoder (libavcodec `wmadec.c` and `wma.c`, by
  Fabrice Bellard and the FFmpeg developers, LGPL 2.1 or later) and gives the same
  samples as `ffmpeg` decoding the same file, within rounding: one frame of
  `TuningFork.Wma.Format` `frame_len` samples per frame of the stream, less the first
  two frames (the decoder's delay), plus the frame still in the output buffers at the
  end. Streams are decoded with the
  coding options every xWMA file uses: exponents coded with Huffman codes, a bit
  reservoir and variable block lengths. Mono and stereo, at up to 50 kHz.
  """

  @behaviour TuningFork.Xwma.Decoder

  alias TuningFork.Wma.Format
  alias TuningFork.Wma.Pcm
  alias TuningFork.Wma.Riff
  alias TuningFork.Wma.State
  alias TuningFork.Wma.Superframe

  @delay_frames 2

  @doc "Always `true`: the decoder needs nothing outside the BEAM."
  @impl true
  @spec available?() :: true
  def available?, do: true

  @doc """
  The audio of an `.xwma` file as signed 16-bit little-endian interleaved PCM, with its
  rate and channel count. Fails with `{:error, reason}` when the file is not RIFF/XWMA
  holding WMA v2 (`:not_xwma`, `:not_wma_v2`, `:no_format`, `:no_data`, `:bad_format`)
  or its format cannot be decoded (`:unsupported_format`). Packets whose bits are not
  valid are skipped.
  """
  @impl true
  @spec decode(binary()) ::
          {:ok, binary(), %{rate: pos_integer(), channels: pos_integer()}} | {:error, atom()}
  def decode(riff) do
    with {:ok, stream} <- Riff.parse(riff),
         {:ok, format} <- Format.new(stream) do
      {:ok, pcm(format, stream.data), %{rate: format.rate, channels: format.channels}}
    end
  end

  defp pcm(format, data) do
    {chunks, state} =
      data
      |> packets(format.block_align)
      |> Enum.flat_map_reduce(State.new(format), &packet/2)

    pcm = IO.iodata_to_binary([chunks, Pcm.frame(Superframe.flush(state))])
    delay = min(@delay_frames * format.frame_len * format.channels * 2, byte_size(pcm))
    binary_part(pcm, delay, byte_size(pcm) - delay)
  end

  defp packet(packet, state) do
    case Superframe.decode(state, packet) do
      {:ok, frames, state} -> {Enum.map(frames, &Pcm.frame/1), state}
      {:error, _reason, state} -> {[], state}
    end
  end

  defp packets(data, size),
    do: for(<<packet::binary-size(^size) <- data>>, do: packet) ++ remainder(data, size)

  defp remainder(data, size) do
    case rem(byte_size(data), size) do
      0 -> []
      left -> [binary_part(data, byte_size(data) - left, left)]
    end
  end
end

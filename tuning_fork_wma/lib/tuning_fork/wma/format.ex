defmodule TuningFork.Wma.Format do
  @moduledoc """
  The decoding parameters of a WMA v2 stream, worked out from its channel count, sample
  rate, bit rate and packet size the way the reference decoder does.

  A stream as xWMA carries it is coded with exponent Huffman codes, a bit reservoir across
  packets and variable block lengths. Its frame is `frame_len` samples per channel; a
  block is the frame length divided by `1 <<< size_index`, for `size_index` from 0 to
  `block_sizes - 1`, and `blocks` holds each block length's `TuningFork.Wma.Bands`.

      {:ok, format} = TuningFork.Wma.Format.new(%{channels: 2, rate: 44_100, bit_rate: 96_000, block_align: 4459})
      2048 = format.frame_len
  """

  import Bitwise

  alias TuningFork.Wma.Bands
  alias TuningFork.Wma.Single

  @enforce_keys [
    :channels,
    :rate,
    :block_align,
    :frame_len_bits,
    :frame_len,
    :block_sizes,
    :byte_offset_bits,
    :noise_coding,
    :codebook_pair,
    :blocks
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          channels: 1 | 2,
          rate: pos_integer(),
          block_align: pos_integer(),
          frame_len_bits: 9..11,
          frame_len: pos_integer(),
          block_sizes: pos_integer(),
          byte_offset_bits: pos_integer(),
          noise_coding: boolean(),
          codebook_pair: 0..2,
          blocks: tuple()
        }

  @type stream :: %{
          channels: pos_integer(),
          rate: pos_integer(),
          bit_rate: integer(),
          block_align: non_neg_integer()
        }

  @minimum_block_bits 7
  @size_flags 3

  @doc """
  The parameters of a stream of `channels` (1 or 2) at `rate` Hz (at most 50_000),
  `bit_rate` bits per second, in packets of `block_align` bytes.
  """
  @spec new(stream()) :: {:ok, t()} | {:error, atom()}
  def new(%{channels: channels, rate: rate, bit_rate: bit_rate, block_align: block_align})
      when channels in 1..2 and rate > 0 and rate <= 50_000 and bit_rate > 0 and
             block_align > 0 do
    frame_len_bits = frame_len_bits(rate)
    bits_per_sample = Single.round(bit_rate / (channels * rate))
    weighted = if channels == 2, do: Single.round(bits_per_sample * 1.6), else: bits_per_sample

    {noise_coding, high_freq} =
      noise_coding(normalized_rate(rate), bits_per_sample, weighted, rate)

    block_sizes = block_sizes(frame_len_bits, div(bit_rate, channels))

    {:ok,
     %__MODULE__{
       channels: channels,
       rate: rate,
       block_align: block_align,
       frame_len_bits: frame_len_bits,
       frame_len: 1 <<< frame_len_bits,
       block_sizes: block_sizes,
       byte_offset_bits: byte_offset_bits(bits_per_sample, frame_len_bits),
       noise_coding: noise_coding,
       codebook_pair: codebook_pair(rate, weighted),
       blocks:
         0..(block_sizes - 1)
         |> Enum.map(&Bands.new(rate, frame_len_bits, &1, high_freq))
         |> List.to_tuple()
     }}
  end

  def new(_stream), do: {:error, :unsupported_format}

  defp frame_len_bits(rate) when rate <= 16_000, do: 9
  defp frame_len_bits(rate) when rate <= 22_050, do: 10
  defp frame_len_bits(_rate), do: 11

  defp block_sizes(frame_len_bits, bit_rate_per_channel) do
    extra = if bit_rate_per_channel >= 32_000, do: 2, else: 0
    min(@size_flags + 1 + extra, frame_len_bits - @minimum_block_bits) + 1
  end

  defp byte_offset_bits(bits_per_sample, frame_len_bits) do
    bytes = trunc(bits_per_sample * (1 <<< frame_len_bits) / 8.0 + 0.5)
    floor_log2(bytes) + 2
  end

  defp floor_log2(value) when value < 2, do: 0
  defp floor_log2(value), do: 1 + floor_log2(value >>> 1)

  defp normalized_rate(rate) when rate >= 44_100, do: 44_100
  defp normalized_rate(rate) when rate >= 22_050, do: 22_050
  defp normalized_rate(rate) when rate >= 16_000, do: 16_000
  defp normalized_rate(rate) when rate >= 11_025, do: 11_025
  defp normalized_rate(rate) when rate >= 8_000, do: 8_000
  defp normalized_rate(rate), do: rate

  defp noise_coding(normalized, bits_per_sample, weighted, rate) do
    nyquist = Single.round(rate * 0.5)

    case high_band_share(normalized, bits_per_sample, weighted) do
      :off -> {false, nyquist}
      share -> {true, Single.round(nyquist * share)}
    end
  end

  defp high_band_share(44_100, _bps, weighted) when weighted >= 0.61, do: :off
  defp high_band_share(44_100, _bps, _weighted), do: 0.4
  defp high_band_share(22_050, _bps, weighted) when weighted >= 1.16, do: :off
  defp high_band_share(22_050, _bps, weighted) when weighted >= 0.72, do: 0.7
  defp high_band_share(22_050, _bps, _weighted), do: 0.6
  defp high_band_share(16_000, bps, _weighted) when bps > 0.5, do: 0.5
  defp high_band_share(16_000, _bps, _weighted), do: 0.3
  defp high_band_share(11_025, _bps, _weighted), do: 0.7
  defp high_band_share(8_000, bps, _weighted) when bps <= 0.625, do: 0.5
  defp high_band_share(8_000, bps, _weighted) when bps > 0.75, do: :off
  defp high_band_share(8_000, _bps, _weighted), do: 0.65
  defp high_band_share(_rate, bps, _weighted) when bps >= 0.8, do: 0.75
  defp high_band_share(_rate, bps, _weighted) when bps >= 0.6, do: 0.6
  defp high_band_share(_rate, _bps, _weighted), do: 0.5

  defp codebook_pair(rate, weighted) when rate >= 32_000 and weighted < 0.72, do: 0
  defp codebook_pair(rate, weighted) when rate >= 32_000 and weighted < 1.16, do: 1
  defp codebook_pair(_rate, _weighted), do: 2
end

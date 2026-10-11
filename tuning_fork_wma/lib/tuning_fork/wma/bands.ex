defmodule TuningFork.Wma.Bands do
  @moduledoc """
  How the coefficients of one block length divide up.

    * `exponent_bands` — the widths of the scale factor bands, each sharing one exponent;
      they add up to the block length.
    * `coefs_end` — the number of coefficients coded; those above it are zero, or noise
      when the stream uses noise coding.
    * `high_band_start` — the first coefficient of the high bands, which noise coding may
      replace with shaped noise.
    * `high_bands` — the widths of the high bands: the scale factor bands clipped to
      `high_band_start..coefs_end`.
  """

  import Bitwise

  alias TuningFork.Wma.Single
  alias TuningFork.Wma.Tables

  @enforce_keys [:block_len, :exponent_bands, :coefs_end, :high_band_start, :high_bands]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          block_len: pos_integer(),
          exponent_bands: [pos_integer()],
          coefs_end: pos_integer(),
          high_band_start: non_neg_integer(),
          high_bands: [pos_integer()]
        }

  @minimum_block_bits 7

  @doc """
  The bands of the block `1 <<< size_index` times shorter than a frame of
  `1 <<< frame_len_bits` samples, at `rate` Hz, with the high bands starting at
  `high_freq` Hz.
  """
  @spec new(pos_integer(), pos_integer(), non_neg_integer(), float()) :: t()
  def new(rate, frame_len_bits, size_index, high_freq) do
    frame_len = 1 <<< frame_len_bits
    block_len = frame_len >>> size_index
    bands = exponent_bands(rate, frame_len_bits - @minimum_block_bits - size_index, block_len)
    coefs_end = (frame_len - div(frame_len * 9, 100)) >>> size_index
    high_band_start = trunc(Single.round(Single.round(block_len * 2 * high_freq) / rate) + 0.5)

    %__MODULE__{
      block_len: block_len,
      exponent_bands: bands,
      coefs_end: coefs_end,
      high_band_start: high_band_start,
      high_bands: high_bands(bands, high_band_start, coefs_end)
    }
  end

  defp exponent_bands(rate, table, _block_len) when table < 3 and rate >= 44_100,
    do: Tables.exponent_bands(:hz_44100, table)

  defp exponent_bands(rate, table, _block_len) when table < 3 and rate >= 32_000,
    do: Tables.exponent_bands(:hz_32000, table)

  defp exponent_bands(rate, table, _block_len) when table < 3 and rate >= 22_050,
    do: Tables.exponent_bands(:hz_22050, table)

  defp exponent_bands(rate, _table, block_len),
    do: critical_bands(Tables.critical_frequencies(), rate, block_len, 0, [])

  defp critical_bands([], _rate, _block_len, _last, widths), do: Enum.reverse(widths)

  defp critical_bands([frequency | rest], rate, block_len, last, widths) do
    edge = min(div(block_len * 2 * frequency + (rate <<< 1), 4 * rate) <<< 2, block_len)
    widths = if edge > last, do: [edge - last | widths], else: widths

    if edge >= block_len,
      do: Enum.reverse(widths),
      else: critical_bands(rest, rate, block_len, edge, widths)
  end

  defp high_bands(bands, high_band_start, coefs_end) do
    bands
    |> Enum.scan({0, 0}, fn width, {_start, finish} -> {finish, finish + width} end)
    |> Enum.map(fn {start, finish} -> min(finish, coefs_end) - max(start, high_band_start) end)
    |> Enum.filter(&(&1 > 0))
  end
end

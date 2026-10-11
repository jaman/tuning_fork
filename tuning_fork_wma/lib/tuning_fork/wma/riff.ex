defmodule TuningFork.Wma.Riff do
  @moduledoc """
  Reads an `.xwma` file: `RIFF`, its size, `XWMA`, then chunks — `fmt ` with the format,
  `dpds` with the seek table (not needed to decode) and `data`, the last, with the
  packets. A `data` chunk of size 0 runs to the end of the file.

  The bit rate is the format's average bytes per second times 8, corrected for the
  values XACT writes for some mono and 22.05 or 32 kHz streams, as the reference
  demuxer does.
  """

  @wma_v2 0x0161

  @type stream :: %{
          channels: pos_integer(),
          rate: pos_integer(),
          bit_rate: non_neg_integer(),
          block_align: non_neg_integer(),
          data: binary()
        }

  @doc "The WMA v2 stream of an `.xwma` file."
  @spec parse(binary()) :: {:ok, stream()} | {:error, atom()}
  def parse(<<"RIFF", _size::little-32, "XWMA", chunks::binary>>), do: chunks(chunks, nil)
  def parse(_other), do: {:error, :not_xwma}

  defp chunks(<<"data", size::little-32, rest::binary>>, format) when is_map(format) do
    data = if size == 0 or size > byte_size(rest), do: rest, else: binary_part(rest, 0, size)
    {:ok, Map.put(format, :data, data)}
  end

  defp chunks(<<"data", _rest::binary>>, nil), do: {:error, :no_format}

  defp chunks(<<"fmt ", size::little-32, body::binary-size(size), rest::binary>>, _format) do
    with {:ok, format} <- format(body), do: chunks(rest, format)
  end

  defp chunks(
         <<_tag::binary-4, size::little-32, _body::binary-size(size), rest::binary>>,
         format
       ),
       do: chunks(rest, format)

  defp chunks(_truncated, _format), do: {:error, :no_data}

  defp format(
         <<@wma_v2::little-16, channels::little-16, rate::little-32, bytes_per_second::little-32,
           block_align::little-16, _rest::binary>>
       ) do
    {:ok,
     %{
       channels: channels,
       rate: rate,
       bit_rate: bit_rate(channels, rate, bytes_per_second * 8),
       block_align: block_align
     }}
  end

  defp format(<<_tag::little-16, _rest::binary>>), do: {:error, :not_wma_v2}
  defp format(_short), do: {:error, :bad_format}

  defp bit_rate(1, rate, bit_rate)
       when rate in [22_050, 32_000] and bit_rate in [48_000, 192_000], do: 20_000

  defp bit_rate(1, 44_100, bit_rate) when bit_rate in [96_000, 192_000], do: 48_000
  defp bit_rate(2, 22_050, bit_rate) when bit_rate in [48_000, 192_000], do: 32_000
  defp bit_rate(2, 32_000, 192_000), do: 48_000
  defp bit_rate(_channels, _rate, bit_rate), do: bit_rate
end

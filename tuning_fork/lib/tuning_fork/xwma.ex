defmodule TuningFork.Xwma do
  @moduledoc """
  xWMA audio — WMA v2 packets with a table of how much each decodes to, as XACT wave
  banks and `.xwma` files hold it — wrapped as a file and decoded to PCM.

      riff = TuningFork.Xwma.riff(packets, %{channels: 2, rate: 44_100, bytes_per_second: 12_000, block_align: 4459, seek: table})
      {:ok, pcm, %{rate: 44_100, channels: 2}} = TuningFork.Xwma.decode(riff)

  A file is `RIFF`/`XWMA` with a `fmt ` chunk (format tag `0x0161`, the channels, rate,
  average bytes per second, packet size and 16 bits per sample), a `dpds` chunk (the
  seek table: the decoded byte count at the end of each packet, little-endian 32-bit)
  and a `data` chunk of the packets.

  ## Decoders

  Decoding goes to the first available `TuningFork.Xwma.Decoder` of
  `config :tuning_fork, :xwma_decoders`. Without that setting the list is
  `TuningFork.Wma` — present when a package that decodes WMA itself is a dependency —
  then `TuningFork.Xwma.Ffmpeg`, the machine's `ffmpeg`. With none available,
  `decode/1` returns `{:error, :no_decoder}`.

  Each file is decoded once; the PCM is kept in `TuningFork.Sample.Fetch.dir/0`.
  """

  alias TuningFork.Sample.Fetch

  @wma_v2 0x0161
  @default_decoders [TuningFork.Wma, TuningFork.Xwma.Ffmpeg]

  @type format :: %{
          channels: pos_integer(),
          rate: pos_integer(),
          bytes_per_second: pos_integer(),
          block_align: pos_integer(),
          seek: [non_neg_integer()]
        }

  @doc "The decoders that can run here, in the order they are tried."
  @spec decoders() :: [module()]
  def decoders do
    :tuning_fork
    |> Application.get_env(:xwma_decoders, @default_decoders)
    |> Enum.filter(
      &(Code.ensure_loaded?(&1) and function_exported?(&1, :decode, 1) and &1.available?())
    )
  end

  @doc "Whether this machine can decode xWMA."
  @spec available?() :: boolean()
  def available?, do: decoders() != []

  @doc "An `.xwma` file of `packets` in `format`."
  @spec riff(binary(), format()) :: binary()
  def riff(packets, %{
        channels: channels,
        rate: rate,
        bytes_per_second: bytes_per_second,
        block_align: block_align,
        seek: seek
      }) do
    fmt =
      <<@wma_v2::little-16, channels::little-16, rate::little-32, bytes_per_second::little-32,
        block_align::little-16, 16::little-16, 0::little-16>>

    dpds = for value <- seek, into: <<>>, do: <<value::little-32>>
    body = "XWMA" <> chunk("fmt ", fmt) <> chunk("dpds", dpds) <> chunk("data", packets)
    "RIFF" <> <<byte_size(body)::little-32>> <> body
  end

  @doc """
  The audio of an `.xwma` file as signed 16-bit little-endian interleaved PCM, with its
  rate and channel count, from the first decoder that can run. Fails with
  `{:error, :no_decoder}` or the decoder's own error.
  """
  @spec decode(binary()) ::
          {:ok, binary(), %{rate: pos_integer(), channels: pos_integer()}} | {:error, term()}
  def decode(riff) do
    path =
      Path.join(
        Fetch.dir(),
        (:crypto.hash(:sha256, riff) |> Base.encode16(case: :lower) |> binary_part(0, 24)) <>
          ".xwma.pcm"
      )

    case File.read(path) do
      {:ok, kept} -> kept_audio(kept)
      {:error, _absent} -> riff |> decode_with(decoders()) |> keep(path)
    end
  end

  defp chunk(tag, body), do: tag <> <<byte_size(body)::little-32>> <> body

  defp decode_with(_riff, []), do: {:error, :no_decoder}
  defp decode_with(riff, [decoder | _rest]), do: decoder.decode(riff)

  defp keep({:ok, pcm, %{rate: rate, channels: channels}} = decoded, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, <<rate::little-32, channels::little-16, pcm::binary>>)
    decoded
  end

  defp keep(error, _path), do: error

  defp kept_audio(<<rate::little-32, channels::little-16, pcm::binary>>),
    do: {:ok, pcm, %{rate: rate, channels: channels}}
end

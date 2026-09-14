defmodule TuningFork.Wav do
  @moduledoc """
  16-bit little-endian PCM wrapped in a WAV header, and read back out of one.

      TuningFork.Wav.encode(pcm, rate: 44_100)
  """

  import Bitwise, only: [>>>: 2, <<<: 2]

  @doc """
  Wrap PCM in a WAV header.

  ## Options

    * `:rate` — samples per second, default 44100
    * `:channels` — samples per frame, default 2

  Both must be what the PCM was rendered at.
  """
  @spec encode(binary(), keyword()) :: binary()
  def encode(pcm, opts \\ []) when is_binary(pcm) do
    rate = Keyword.get(opts, :rate, 44_100)
    channels = Keyword.get(opts, :channels, 2)

    bits = 16
    block_align = div(channels * bits, 8)
    byte_rate = rate * block_align
    data_size = byte_size(pcm)

    <<"RIFF", 36 + data_size::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little,
      channels::16-little, rate::32-little, byte_rate::32-little, block_align::16-little,
      bits::16-little, "data", data_size::32-little, pcm::binary>>
  end

  @doc """
  Read a WAV, as `{:ok, pcm, rate, channels}`, with `pcm` as 16-bit signed samples whatever
  the file holds: 8-bit unsigned, 16-, 24- and 32-bit integers and 32-bit floats are read,
  plain or under an extensible header, and floats outside -1.0..1.0 are clipped.

  Chunks other than `fmt ` and `data` are skipped. Fails with `{:error, :not_a_wav}`,
  `{:error, :no_format_chunk}`, `{:error, :no_data_chunk}`, `{:error, :truncated}` or
  `{:error, {:unsupported_bit_depth, bits}}`. A file cut short after both `fmt ` and `data`
  have been read is not `:truncated`.
  """
  @spec decode(binary()) :: {:ok, binary(), pos_integer(), pos_integer()} | {:error, term()}
  def decode(<<"RIFF", _size::32-little, "WAVE", chunks::binary>>) do
    with {:ok, format, data} <- chunks(chunks, nil, nil) do
      case as_16(format, data) do
        {:ok, pcm} -> {:ok, pcm, format.rate, format.channels}
        :error -> {:error, {:unsupported_bit_depth, format.bits}}
      end
    end
  end

  def decode(_other), do: {:error, :not_a_wav}

  @doc """
  Read a WAV, as `{pcm, rate, channels}`.

  Raises `ArgumentError` where `decode/1` would report an error.
  """
  @spec decode!(binary()) :: {binary(), pos_integer(), pos_integer()}
  def decode!(wav) do
    case decode(wav) do
      {:ok, pcm, rate, channels} -> {pcm, rate, channels}
      {:error, reason} -> raise ArgumentError, "could not read that WAV: #{inspect(reason)}"
    end
  end

  @doc """
  Write PCM to `path` as a WAV, creating the directory if it is not there.

  `opts` are `encode/2`'s options.
  """
  @spec write!(Path.t(), binary(), keyword()) :: :ok
  def write!(path, pcm, opts \\ []) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(pcm, opts))
  end

  @doc "Read a WAV file, as `{pcm, rate, channels}`. Raises as `decode!/1` does."
  @spec read!(Path.t()) :: {binary(), pos_integer(), pos_integer()}
  def read!(path), do: path |> File.read!() |> decode!()

  @doc """
  How long a 16-bit PCM buffer lasts, in seconds.

  `rate` and `channels` must be the ones the buffer was rendered at.
  """
  @spec duration(binary(), pos_integer(), pos_integer()) :: float()
  def duration(pcm, rate \\ 44_100, channels \\ 2) do
    byte_size(pcm) / (rate * channels * 2)
  end

  defp chunks(<<>>, format, data), do: complete(format, data)

  defp chunks(<<"fmt ", size::32-little, body::binary-size(size), rest::binary>>, _format, data) do
    <<audio_format::16-little, channels::16-little, rate::32-little, _byte_rate::32-little,
      _align::16-little, bits::16-little, extra::binary>> = body

    format = %{channels: channels, rate: rate, bits: bits, kind: kind(audio_format, extra)}

    chunks(pad(rest, size), format, data)
  end

  defp chunks(<<"data", size::32-little, body::binary-size(size), rest::binary>>, format, _data) do
    chunks(pad(rest, size), format, body)
  end

  defp chunks(
         <<_id::binary-size(4), size::32-little, _body::binary-size(size), rest::binary>>,
         f,
         d
       ) do
    chunks(pad(rest, size), f, d)
  end

  defp chunks(rest, format, data) when byte_size(rest) < 8 do
    complete(format, data)
  end

  defp chunks(_truncated, format, data) when is_nil(format) or is_nil(data) do
    {:error, :truncated}
  end

  defp chunks(_truncated, format, data), do: {:ok, format, data}

  defp kind(
         0xFFFE,
         <<_size::16-little, _valid::16-little, _mask::32-little, sub::16-little, _guid::binary>>
       ),
       do: kind(sub, <<>>)

  defp kind(3, _extra), do: :float
  defp kind(_pcm, _extra), do: :integer

  defp as_16(%{bits: 16, kind: :integer}, data), do: {:ok, data}

  defp as_16(%{bits: 8, kind: :integer}, data),
    do: {:ok, for(<<byte <- data>>, into: <<>>, do: <<(byte - 128) <<< 8::16-little-signed>>)}

  defp as_16(%{bits: 24, kind: :integer}, data),
    do:
      {:ok,
       for(<<sample::24-little-signed <- data>>,
         into: <<>>,
         do: <<sample >>> 8::16-little-signed>>
       )}

  defp as_16(%{bits: 32, kind: :integer}, data),
    do:
      {:ok,
       for(<<sample::32-little-signed <- data>>,
         into: <<>>,
         do: <<sample >>> 16::16-little-signed>>
       )}

  defp as_16(%{bits: 32, kind: :float}, data),
    do:
      {:ok,
       for(<<sample::32-float-little <- data>>,
         into: <<>>,
         do: <<clipped(sample)::16-little-signed>>
       )}

  defp as_16(_format, _data), do: :error

  defp clipped(sample), do: sample |> max(-1.0) |> Kernel.*(32_768) |> round() |> min(32_767)

  defp complete(nil, _data), do: {:error, :no_format_chunk}
  defp complete(_format, nil), do: {:error, :no_data_chunk}
  defp complete(format, data), do: {:ok, format, data}

  defp pad(rest, size) when rem(size, 2) == 1 do
    case rest do
      <<_pad::8, tail::binary>> -> tail
      <<>> -> <<>>
    end
  end

  defp pad(rest, _size), do: rest
end

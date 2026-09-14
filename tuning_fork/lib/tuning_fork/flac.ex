defmodule TuningFork.Flac do
  @moduledoc """
  Reads FLAC into 16-bit PCM.

      {:ok, pcm, rate, channels} = TuningFork.Flac.decode(File.read!("bell.flac"))
  """

  import Bitwise

  @type reason :: :not_flac | :truncated | :unsupported

  @sync 0b11111111111110

  @clz_table List.to_tuple(
               for byte <- 0..255 do
                 Enum.find(0..8, fn zeros -> zeros == 8 or (byte >>> (7 - zeros) &&& 1) == 1 end)
               end
             )

  @doc """
  The PCM in a FLAC stream, with its rate and channel count.

  Returns `{:ok, pcm, rate, channels}`, or `{:error, reason}` where the reason is
  `:not_flac` for bytes that do not begin a FLAC stream, `:truncated` for a stream that ends
  mid-frame, and `:unsupported` for a channel count over two.
  """
  @spec decode(binary()) :: {:ok, binary(), pos_integer(), pos_integer()} | {:error, reason()}
  def decode(<<"fLaC", blocks::binary>>) do
    with {:ok, info, frames} <- metadata(blocks),
         :ok <- supported(info),
         {:ok, samples} <- frames(frames, info, []) do
      {:ok, interleave(samples, info), info.rate, info.channels}
    end
  end

  def decode(_other), do: {:error, :not_flac}

  @doc """
  What a FLAC stream holds, read from its header without decoding it.

  `%{rate: rate, channels: channels, bits: bits_per_sample, frames: total_frames}`, where
  `frames` is `0` for a stream whose length was not written.
  """
  @spec info(binary()) :: {:ok, map()} | {:error, reason()}
  def info(<<"fLaC", blocks::binary>>) do
    with {:ok, info, _frames} <- metadata(blocks) do
      {:ok, Map.take(info, [:rate, :channels, :bits, :frames])}
    end
  end

  def info(_other), do: {:error, :not_flac}

  @doc """
  Read a FLAC file from disk.

  Gives `{pcm, rate, channels}` as `TuningFork.Wav.read!/1` does, and raises `ArgumentError`
  for a file that is not FLAC or is cut short.
  """
  @spec read!(Path.t()) :: {binary(), pos_integer(), pos_integer()}
  def read!(path) do
    case path |> File.read!() |> decode() do
      {:ok, pcm, rate, channels} -> {pcm, rate, channels}
      {:error, :not_flac} -> raise ArgumentError, "#{path} is not FLAC"
      {:error, :truncated} -> raise ArgumentError, "#{path} is FLAC cut short"
      {:error, :unsupported} -> raise ArgumentError, "#{path} has more channels than two"
    end
  end

  defp metadata(blocks), do: metadata(blocks, nil)

  defp metadata(<<last::1, 0::7, _length::24, streaminfo::binary-size(34), rest::binary>>, nil) do
    <<_min_block::16, _max_block::16, _min_frame::24, _max_frame::24, rate::20, channels::3,
      bits::5, frames::36, _md5::128>> = streaminfo

    info = %{rate: rate, channels: channels + 1, bits: bits + 1, frames: frames}

    if last == 1, do: {:ok, info, rest}, else: metadata(rest, info)
  end

  defp metadata(<<last::1, _type::7, length::24, rest::binary>>, %{} = info) do
    case rest do
      <<_block::binary-size(length), after_block::binary>> ->
        if last == 1, do: {:ok, info, after_block}, else: metadata(after_block, info)

      _short ->
        {:error, :truncated}
    end
  end

  defp metadata(_other, nil), do: {:error, :not_flac}
  defp metadata(_other, _info), do: {:error, :truncated}

  defp supported(%{channels: channels}) when channels <= 2, do: :ok
  defp supported(_info), do: {:error, :unsupported}

  defp frames(<<>>, _info, acc), do: {:ok, Enum.reverse(acc)}

  defp frames(<<@sync::14, _reserved::1, _strategy::1, rest::bits>>, info, acc) do
    with {:ok, header, rest} <- frame_header(rest, info),
         {:ok, channels, rest} <- subframes(rest, header, []) do
      pad = rem(bit_size(rest), 8)
      <<_pad::size(pad), _crc::16, next::binary>> = rest
      frames(next, info, [decorrelate(channels, header.assignment) | acc])
    else
      _short -> {:error, :truncated}
    end
  rescue
    MatchError -> {:error, :truncated}
  end

  defp frames(_other, _info, _acc), do: {:error, :truncated}

  defp frame_header(
         <<size_code::4, rate_code::4, assignment::4, bits_code::3, _::1, rest::bits>>,
         info
       ) do
    with {:ok, rest} <- skip_utf8(rest),
         {:ok, size, rest} <- block_size(size_code, rest),
         {:ok, rest} <- skip_rate(rate_code, rest) do
      <<_crc8::8, rest::bits>> = rest

      {:ok,
       %{
         size: size,
         assignment: assignment,
         bits: sample_bits(bits_code, info.bits),
         channels: channel_count(assignment)
       }, rest}
    end
  end

  defp skip_utf8(<<0::1, _::7, rest::bits>>), do: {:ok, rest}
  defp skip_utf8(<<0b110::3, _::5, _::8, rest::bits>>), do: {:ok, rest}
  defp skip_utf8(<<0b1110::4, _::4, _::16, rest::bits>>), do: {:ok, rest}
  defp skip_utf8(<<0b11110::5, _::3, _::24, rest::bits>>), do: {:ok, rest}
  defp skip_utf8(<<0b111110::6, _::2, _::32, rest::bits>>), do: {:ok, rest}
  defp skip_utf8(<<0b1111110::7, _::1, _::40, rest::bits>>), do: {:ok, rest}
  defp skip_utf8(<<0b11111110::8, _::48, rest::bits>>), do: {:ok, rest}
  defp skip_utf8(_other), do: {:error, :truncated}

  defp block_size(1, rest), do: {:ok, 192, rest}
  defp block_size(code, rest) when code in 2..5, do: {:ok, 576 <<< (code - 2), rest}
  defp block_size(6, <<size::8, rest::bits>>), do: {:ok, size + 1, rest}
  defp block_size(7, <<size::16, rest::bits>>), do: {:ok, size + 1, rest}
  defp block_size(code, rest) when code in 8..15, do: {:ok, 256 <<< (code - 8), rest}
  defp block_size(_code, _rest), do: {:error, :truncated}

  defp skip_rate(12, <<_::8, rest::bits>>), do: {:ok, rest}
  defp skip_rate(code, <<_::16, rest::bits>>) when code in 13..14, do: {:ok, rest}
  defp skip_rate(code, rest) when code < 12, do: {:ok, rest}
  defp skip_rate(_code, _rest), do: {:error, :truncated}

  defp sample_bits(0, bits), do: bits
  defp sample_bits(1, _bits), do: 8
  defp sample_bits(2, _bits), do: 12
  defp sample_bits(4, _bits), do: 16
  defp sample_bits(5, _bits), do: 20
  defp sample_bits(6, _bits), do: 24
  defp sample_bits(7, _bits), do: 32

  defp channel_count(assignment) when assignment < 8, do: assignment + 1
  defp channel_count(_stereo), do: 2

  defp subframes(rest, %{channels: count}, acc) when length(acc) == count do
    {:ok, Enum.reverse(acc), rest}
  end

  defp subframes(rest, header, acc) do
    index = length(acc)
    bits = header.bits + side_bit(header.assignment, index)

    case subframe(rest, header.size, bits) do
      {:ok, samples, rest} -> subframes(rest, header, [samples | acc])
      error -> error
    end
  end

  defp side_bit(8, 1), do: 1
  defp side_bit(9, 0), do: 1
  defp side_bit(10, 1), do: 1
  defp side_bit(_assignment, _index), do: 0

  defp subframe(<<0::1, type::6, wasted_flag::1, rest::bits>>, size, bits) do
    with {:ok, wasted, rest} <- wasted(wasted_flag, rest),
         {:ok, samples, rest} <- subframe_of(type, rest, size, bits - wasted) do
      {:ok, unwaste(samples, wasted), rest}
    end
  end

  defp subframe(_other, _size, _bits), do: {:error, :truncated}

  defp wasted(0, rest), do: {:ok, 0, rest}

  defp wasted(1, rest) do
    case unary(rest, 0) do
      {zeros, rest} -> {:ok, zeros + 1, rest}
      error -> error
    end
  end

  defp unwaste(samples, 0), do: samples
  defp unwaste(samples, wasted), do: Enum.map(samples, &(&1 <<< wasted))

  defp subframe_of(0, rest, size, bits) do
    case rest do
      <<value::signed-size(bits), rest::bits>> -> {:ok, List.duplicate(value, size), rest}
      _short -> {:error, :truncated}
    end
  end

  defp subframe_of(1, rest, size, bits) do
    total = size * bits

    case rest do
      <<raw::bits-size(total), rest::bits>> ->
        {:ok, for(<<value::signed-size(bits) <- raw>>, do: value), rest}

      _short ->
        {:error, :truncated}
    end
  end

  defp subframe_of(type, rest, size, bits) when type in 8..12 do
    order = type - 8

    with {:ok, warmup, rest} <- warmup(rest, order, bits),
         {:ok, residual, rest} <- residual(rest, size, order) do
      {:ok, predict_fixed(order, warmup, residual), rest}
    end
  end

  defp subframe_of(type, rest, size, bits) when type >= 32 do
    order = type - 31

    with {:ok, warmup, rest} <- warmup(rest, order, bits),
         {:ok, coefficients, shift, rest} <- lpc_coefficients(rest, order),
         {:ok, residual, rest} <- residual(rest, size, order) do
      {:ok, predict_lpc(coefficients, shift, warmup, residual), rest}
    end
  end

  defp subframe_of(_reserved, _rest, _size, _bits), do: {:error, :truncated}

  defp warmup(rest, order, bits) do
    total = order * bits

    case rest do
      <<raw::bits-size(total), rest::bits>> ->
        {:ok, for(<<value::signed-size(bits) <- raw>>, do: value), rest}

      _short ->
        {:error, :truncated}
    end
  end

  defp lpc_coefficients(<<precision::4, shift::5-signed, rest::bits>>, order)
       when precision < 15 do
    bits = precision + 1
    total = order * bits

    case rest do
      <<raw::bits-size(total), rest::bits>> ->
        {:ok, for(<<value::signed-size(bits) <- raw>>, do: value), shift, rest}

      _short ->
        {:error, :truncated}
    end
  end

  defp lpc_coefficients(_other, _order), do: {:error, :truncated}

  defp residual(<<method::2, order::4, rest::bits>>, size, predictor_order) when method < 2 do
    param_bits = 4 + method
    escape = (1 <<< param_bits) - 1
    count = 1 <<< order
    per_partition = size >>> order

    partitions(rest, count, 0, per_partition, predictor_order, param_bits, escape, [])
  end

  defp residual(_other, _size, _order), do: {:error, :truncated}

  defp partitions(rest, count, count, _per, _predictor, _param_bits, _escape, acc) do
    {:ok, acc |> Enum.reverse() |> Enum.concat(), rest}
  end

  defp partitions(rest, count, index, per, predictor, param_bits, escape, acc) do
    samples = if index == 0, do: per - predictor, else: per

    outcome =
      case rest do
        <<^escape::size(param_bits), raw_bits::5, rest::bits>> -> raw(rest, samples, raw_bits)
        <<param::size(param_bits), rest::bits>> -> rice(rest, param, samples, [])
        _short -> {:error, :truncated}
      end

    with {:ok, values, rest} <- outcome do
      partitions(rest, count, index + 1, per, predictor, param_bits, escape, [values | acc])
    end
  end

  defp raw(rest, samples, raw_bits) do
    total = samples * raw_bits

    case rest do
      <<raw::bits-size(total), rest::bits>> ->
        {:ok, for(<<value::signed-size(raw_bits) <- raw>>, do: value), rest}

      _short ->
        {:error, :truncated}
    end
  end

  defp rice(rest, _param, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp rice(rest, param, remaining, acc) do
    case unary(rest, 0) do
      {quotient, <<remainder::size(param), rest::bits>>} ->
        folded = quotient <<< param ||| remainder
        value = bxor(folded >>> 1, -(folded &&& 1))
        rice(rest, param, remaining - 1, [value | acc])

      _short ->
        {:error, :truncated}
    end
  end

  defp unary(<<0::8, rest::bits>>, acc), do: unary(rest, acc + 8)

  defp unary(<<byte::8, _::bits>> = bits, acc) do
    zeros = elem(@clz_table, byte)
    <<_::size(zeros + 1), rest::bits>> = bits
    {acc + zeros, rest}
  end

  defp unary(bits, acc) when bit_size(bits) < 8 do
    case bits do
      <<0::1, rest::bits>> -> unary(rest, acc + 1)
      <<1::1, rest::bits>> -> {acc, rest}
      <<>> -> {:error, :truncated}
    end
  end

  defp predict_fixed(0, _warmup, residual), do: residual

  defp predict_fixed(order, warmup, residual) do
    history = Enum.reverse(warmup)

    residual
    |> Enum.reduce(history, fn error, [s1 | _] = history ->
      predicted =
        case {order, history} do
          {1, _} -> s1
          {2, [_, s2 | _]} -> 2 * s1 - s2
          {3, [_, s2, s3 | _]} -> 3 * s1 - 3 * s2 + s3
          {4, [_, s2, s3, s4 | _]} -> 4 * s1 - 6 * s2 + 4 * s3 - s4
        end

      [predicted + error | history]
    end)
    |> Enum.reverse()
  end

  defp predict_lpc(coefficients, shift, warmup, residual) do
    history = Enum.reverse(warmup)

    residual
    |> Enum.reduce(history, fn error, history ->
      [(dot(coefficients, history, 0) >>> shift) + error | history]
    end)
    |> Enum.reverse()
  end

  defp dot([], _history, acc), do: acc

  defp dot([coefficient | coefficients], [sample | history], acc),
    do: dot(coefficients, history, acc + coefficient * sample)

  defp decorrelate([mono], _assignment), do: [mono]
  defp decorrelate([left, right], assignment) when assignment < 8, do: [left, right]

  defp decorrelate([left, side], 8) do
    [left, Enum.zip_with(left, side, fn l, s -> l - s end)]
  end

  defp decorrelate([side, right], 9) do
    [Enum.zip_with(side, right, fn s, r -> r + s end), right]
  end

  defp decorrelate([mid, side], 10) do
    {lefts, rights} =
      mid
      |> Enum.zip_with(side, fn m, s ->
        widened = m <<< 1 ||| (s &&& 1)
        {(widened + s) >>> 1, (widened - s) >>> 1}
      end)
      |> Enum.unzip()

    [lefts, rights]
  end

  defp interleave(frames, %{bits: bits, channels: channels}) do
    scale = bits - 16

    frames
    |> Enum.flat_map(&frame_pcm(&1, channels, scale))
    |> IO.iodata_to_binary()
  end

  defp frame_pcm([mono], 1, scale), do: Enum.map(mono, &to16(&1, scale))

  defp frame_pcm([left, right], 2, scale) do
    Enum.zip_with(left, right, fn l, r -> [to16(l, scale), to16(r, scale)] end)
  end

  defp to16(sample, 0), do: <<sample::16-signed-little>>
  defp to16(sample, scale) when scale > 0, do: <<sample >>> scale::16-signed-little>>
  defp to16(sample, scale), do: <<sample <<< -scale::16-signed-little>>
end

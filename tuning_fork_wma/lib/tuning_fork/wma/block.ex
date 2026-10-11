defmodule TuningFork.Wma.Block do
  @moduledoc """
  One block of a frame: its lengths, then mid/side stereo and which channels are coded,
  and for coded channels the gain, the noise bands, the envelope and the coefficients.
  `TuningFork.Wma.Synthesis` turns the coefficients into samples.
  """

  import Bitwise

  alias TuningFork.Wma.Bits
  alias TuningFork.Wma.BlockLengths
  alias TuningFork.Wma.Codebooks
  alias TuningFork.Wma.Coefficients
  alias TuningFork.Wma.Exponents
  alias TuningFork.Wma.InvalidData
  alias TuningFork.Wma.Noise
  alias TuningFork.Wma.Spectrum
  alias TuningFork.Wma.State
  alias TuningFork.Wma.Synthesis

  @doc """
  Decodes the block at `position` samples into the frame. Returns the state, the rest of
  the stream and the position after the block.
  """
  @spec decode(State.t(), bitstring(), non_neg_integer()) ::
          {State.t(), bitstring(), pos_integer()}
  def decode(%State{format: format} = state, bits, position) do
    {state, bits} = BlockLengths.read(state, bits)
    block_len = 1 <<< state.block_bits

    if position + block_len > format.frame_len, do: raise(InvalidData, reason: :frame_overflow)

    {mid_side, bits} = mid_side(format.channels, bits)

    {coded, bits} =
      Enum.map_reduce(1..format.channels, bits, fn _channel, bits -> Bits.read_flag(bits) end)

    size_index = format.frame_len_bits - state.block_bits
    {spectra, state, bits} = content(Enum.any?(coded), coded, state, bits, mid_side, size_index)
    {Synthesis.add(state, spectra, mid_side, position), bits, position + block_len}
  end

  defp mid_side(2, bits), do: Bits.read_flag(bits)
  defp mid_side(1, bits), do: {false, bits}

  defp content(false, coded, state, bits, _mid_side, _size_index),
    do: {Enum.map(coded, fn false -> nil end), state, bits}

  defp content(true, coded, state, bits, mid_side, size_index) do
    format = state.format
    bands = elem(format.blocks, size_index)
    {total_gain, bits} = total_gain(bits, 1)
    {flags, gains, bits} = noise_bands(format.noise_coding, coded, bands, bits)
    {state, bits} = exponents(state, coded, bits, bands, size_index)
    {quantised, bits} = quantised(state, coded, flags, bands, mid_side, total_gain, bits)

    block = %{
      bands: bands,
      size_index: size_index,
      total_gain: total_gain,
      noise_coding: format.noise_coding
    }

    {spectra, noise_index} =
      [coded, quantised, state.exponents, flags, gains]
      |> Enum.zip()
      |> Enum.map_reduce(state.noise_index, &spectrum(&1, &2, block))

    {spectra, %{state | noise_index: noise_index}, bits}
  end

  defp total_gain(bits, _total) when bit_size(bits) < 7,
    do: raise(InvalidData, reason: :total_gain_past_end)

  defp total_gain(bits, total) do
    case Bits.read(bits, 7) do
      {127, bits} -> total_gain(bits, total + 127)
      {step, bits} -> {total + step, bits}
    end
  end

  defp noise_bands(false, coded, _bands, bits),
    do: {Enum.map(coded, fn _ -> [] end), Enum.map(coded, fn _ -> [] end), bits}

  defp noise_bands(true, coded, bands, bits) do
    count = length(bands.high_bands)
    {flags, bits} = Enum.map_reduce(coded, bits, &noise_flags(&1, &2, count))

    {gains, bits} =
      Enum.map_reduce(flags, bits, fn flags, bits -> Noise.read_gains(bits, flags) end)

    {flags, gains, bits}
  end

  defp noise_flags(true, bits, count), do: Noise.read_flags(bits, count)
  defp noise_flags(false, bits, _count), do: {[], bits}

  defp exponents(%State{} = state, coded, bits, bands, size_index) do
    {fresh, bits} = fresh_exponents(size_index, bits)

    {exponents, bits} =
      Enum.map_reduce(
        Enum.zip(coded, state.exponents),
        bits,
        &channel_exponents(&1, &2, fresh, bands, size_index)
      )

    {%{state | exponents: exponents}, bits}
  end

  defp fresh_exponents(0, bits), do: {true, bits}
  defp fresh_exponents(_size_index, bits), do: Bits.read_flag(bits)

  defp channel_exponents({true, _old}, bits, true, bands, size_index),
    do: Exponents.decode(bits, bands.exponent_bands, size_index)

  defp channel_exponents({true, nil}, _bits, false, _bands, _size_index),
    do: raise(InvalidData, reason: :no_exponents)

  defp channel_exponents({_coded, old}, bits, _fresh, _bands, _size_index), do: {old, bits}

  defp quantised(state, coded, flags, bands, mid_side, total_gain, bits) do
    format = state.format

    [coded, flags]
    |> Enum.zip()
    |> Enum.with_index()
    |> Enum.map_reduce(bits, fn
      {{false, _flags}, _channel}, bits ->
        {nil, bits}

      {{true, flags}, channel}, bits ->
        codebook = Codebooks.coefficients(2 * format.codebook_pair + table(channel, mid_side))
        count = bands.coefs_end - noise_width(bands.high_bands, flags)
        Coefficients.decode(bits, codebook, count, level_bits(total_gain), format.frame_len_bits)
    end)
  end

  defp table(1, true), do: 1
  defp table(_channel, _mid_side), do: 0

  defp noise_width(widths, flags) do
    widths
    |> Enum.zip(flags)
    |> Enum.reduce(0, fn {width, noise}, sum -> if noise, do: sum + width, else: sum end)
  end

  defp level_bits(total_gain) when total_gain < 15, do: 13
  defp level_bits(total_gain) when total_gain < 32, do: 12
  defp level_bits(total_gain) when total_gain < 40, do: 11
  defp level_bits(total_gain) when total_gain < 45, do: 10
  defp level_bits(_total_gain), do: 9

  defp spectrum({false, _quantised, _exponents, _flags, _gains}, noise_index, _block),
    do: {nil, noise_index}

  defp spectrum({true, quantised, exponents, flags, gains}, noise_index, block) do
    channel = %{quantised: quantised, exponents: exponents, noise_flags: flags, gains: gains}
    Spectrum.build(channel, block, noise_index)
  end
end

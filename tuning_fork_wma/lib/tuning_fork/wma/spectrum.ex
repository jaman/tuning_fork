defmodule TuningFork.Wma.Spectrum do
  @moduledoc """
  The MDCT coefficients of one channel of a block: the quantised coefficients scaled by
  the envelope and the block's gain, and, when the stream uses noise coding, noise in
  the bands sent as noise and a little noise under every coded coefficient.

  Coefficients above the coded range are zero without noise coding, and noise at the
  level of the last envelope value with it.
  """

  alias TuningFork.Wma.Bands
  alias TuningFork.Wma.Exponents
  alias TuningFork.Wma.Noise

  @type channel :: %{
          quantised: [float()],
          exponents: Exponents.t(),
          noise_flags: [boolean()],
          gains: [integer() | nil]
        }

  @type block :: %{
          bands: Bands.t(),
          size_index: non_neg_integer(),
          total_gain: pos_integer(),
          noise_coding: boolean()
        }

  @doc """
  The `bands.block_len` coefficients of `channel` in `block`, and the noise table position
  after the values it used, starting from `noise_index`.
  """
  @spec build(channel(), block(), non_neg_integer()) :: {[float()], non_neg_integer()}
  def build(channel, %{noise_coding: false} = block, noise_index) do
    %{bands: bands, size_index: size_index} = block
    mult = multiplier(channel, block)

    {values, _index} =
      Enum.map_reduce(channel.quantised, 0, fn value, index ->
        {value * Exponents.at(channel.exponents, size_index, index, 0) * mult, index + 1}
      end)

    {values ++ List.duplicate(0.0, bands.block_len - bands.coefs_end), noise_index}
  end

  def build(channel, %{noise_coding: true} = block, noise_index) do
    %{bands: bands} = block
    mult = multiplier(channel, block)
    powers = powers(channel, block)
    context = %{channel: channel, block: block, mult: mult, last_power: last_power(powers)}

    start = %{base: 0, values: [], quantised: channel.quantised, noise_index: noise_index}
    low = coded(start, context, bands.high_band_start)

    high =
      [bands.high_bands, channel.noise_flags, channel.gains, powers]
      |> Enum.zip()
      |> Enum.reduce(low, &high_band(&1, &2, context))

    finish = tail(high, context, bands.block_len - bands.coefs_end)
    {:lists.reverse(finish.values), finish.noise_index}
  end

  defp multiplier(channel, block),
    do: :math.pow(10.0, block.total_gain * 0.05) / channel.exponents.max * norm(block)

  defp norm(%{bands: %{block_len: block_len}}), do: 1.0 / (block_len / 2)

  defp high_band({width, false, _gain, _power}, state, context), do: coded(state, context, width)

  defp high_band({width, true, gain, power}, state, context) do
    %{channel: channel, block: block, last_power: last_power} = context

    mult =
      :math.sqrt(power / last_power) * :math.pow(10.0, gain * 0.05) /
        (channel.exponents.max * Noise.multiplier()) * norm(block)

    noise(state, context, width, mult)
  end

  defp coded(state, context, width) do
    %{channel: %{exponents: exponents}, block: %{size_index: size_index}, mult: mult} = context
    %{base: base, values: values, quantised: quantised, noise_index: noise_index} = state
    {taken, rest} = Enum.split(quantised, width)

    {values, _index} =
      Enum.reduce(taken, {values, 0}, fn value, {values, index} ->
        scale = Exponents.at(exponents, size_index, index, base)
        {[(value + Noise.at(noise_index + index)) * scale * mult | values], index + 1}
      end)

    %{
      base: base + Exponents.span(exponents, size_index, width),
      values: values,
      quantised: rest,
      noise_index: noise_index + width
    }
  end

  defp noise(state, context, width, mult) do
    %{channel: %{exponents: exponents}, block: %{size_index: size_index}} = context
    %{base: base, values: values, noise_index: noise_index} = state

    values =
      Enum.reduce(0..(width - 1)//1, values, fn index, values ->
        scale = Exponents.at(exponents, size_index, index, base)
        [Noise.at(noise_index + index) * scale * mult | values]
      end)

    %{
      state
      | base: base + Exponents.span(exponents, size_index, width),
        values: values,
        noise_index: noise_index + width
    }
  end

  defp tail(state, context, width) do
    %{channel: %{exponents: exponents}, block: %{size_index: size_index}, mult: mult} = context
    %{base: base, values: values, noise_index: noise_index} = state
    level = mult * Exponents.at(exponents, size_index, -1, base)

    values =
      Enum.reduce(0..(width - 1)//1, values, fn index, values ->
        [Noise.at(noise_index + index) * level | values]
      end)

    %{state | values: values, noise_index: noise_index + width}
  end

  defp powers(%{exponents: exponents, noise_flags: flags}, block) do
    %{bands: bands, size_index: size_index} = block
    start = Exponents.span(exponents, size_index, bands.high_band_start)

    bands.high_bands
    |> Enum.zip(flags)
    |> Enum.map_reduce(start, fn {width, noise}, base ->
      next = base + Exponents.span(exponents, size_index, width)
      {power(noise, exponents, size_index, base, width), next}
    end)
    |> elem(0)
  end

  defp power(false, _exponents, _size_index, _base, _width), do: nil

  defp power(true, exponents, size_index, base, width) do
    sum =
      Enum.reduce(0..(width - 1)//1, 0.0, fn index, sum ->
        value = Exponents.at(exponents, size_index, index, base)
        sum + value * value
      end)

    sum / width
  end

  defp last_power(powers), do: powers |> Enum.reject(&is_nil/1) |> List.last()
end

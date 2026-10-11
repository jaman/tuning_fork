defmodule TuningFork.Wma.Coefficients do
  @moduledoc """
  The quantised spectral coefficients of one channel of a block, coded as runs of zeros
  each followed by a signed level.

  Each code of the codebook is a run and a level, the end of the block (the remaining
  coefficients are zero), or an escape: a level of `level_bits` bits and a run of
  `run_bits` bits written out in full. A sign bit follows every level, 0 for negative.
  """

  alias TuningFork.Wma.Bits
  alias TuningFork.Wma.Codebooks
  alias TuningFork.Wma.InvalidData
  alias TuningFork.Wma.Vlc

  @escape 0
  @end_of_block 1

  @doc """
  Decodes `count` coefficients with `codebook`. Returns them in order, as floats, with the
  rest of the stream. Raises `TuningFork.Wma.InvalidData` when a run passes `count`.
  """
  @spec decode(
          bitstring(),
          Codebooks.coefficients(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) ::
          {[float()], bitstring()}
  def decode(bits, codebook, count, level_bits, run_bits) do
    context = Map.merge(codebook, %{count: count, level_bits: level_bits, run_bits: run_bits})
    {values, rest} = runs(bits, context, 0, [])
    {:lists.reverse(values), rest}
  end

  defp runs(bits, %{count: count}, position, values) when position >= count, do: {values, bits}

  defp runs(bits, context, position, values) do
    {symbol, bits} = Vlc.decode(context.vlc, bits)
    code(symbol, bits, context, position, values)
  end

  defp code(@end_of_block, bits, context, position, values),
    do: {zeros(context.count - position, values), bits}

  defp code(@escape, bits, context, position, values) do
    {level, bits} = Bits.read(bits, context.level_bits)
    {run, bits} = Bits.read(bits, context.run_bits)
    {positive, bits} = Bits.read_flag(bits)
    place(bits, context, position, run, signed(level * 1.0, positive), values)
  end

  defp code(symbol, bits, context, position, values) do
    {positive, bits} = Bits.read_flag(bits)
    value = signed(elem(context.levels, symbol), positive)
    place(bits, context, position, elem(context.runs, symbol), value, values)
  end

  defp place(_bits, %{count: count}, position, run, _value, _values) when position + run >= count,
    do: raise(InvalidData, reason: :run_past_end)

  defp place(bits, context, position, run, value, values),
    do: runs(bits, context, position + run + 1, [value | zeros(run, values)])

  defp signed(level, true), do: level
  defp signed(level, false), do: -level

  defp zeros(0, values), do: values
  defp zeros(count, values), do: zeros(count - 1, [0.0 | values])
end

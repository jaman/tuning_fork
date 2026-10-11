defmodule TuningFork.Wma.BlockLengths do
  @moduledoc """
  The lengths of the blocks of a frame. Each block states the length of the block after
  it; the first block after a reset states its own and the previous block's length too.
  A length is coded as how many times shorter than a frame the block is, as a power of
  two, in just enough bits for the stream's number of block sizes.
  """

  import Bitwise

  alias TuningFork.Wma.Bits
  alias TuningFork.Wma.InvalidData
  alias TuningFork.Wma.State

  @doc "Reads the lengths for the next block into `state`, with the rest of the stream."
  @spec read(State.t(), bitstring()) :: {State.t(), bitstring()}
  def read(%State{reset_block_lengths: true} = state, bits) do
    {prev_bits, bits} = length_bits(state, bits)
    {block_bits, bits} = length_bits(state, bits)
    {next_bits, bits} = length_bits(state, bits)

    {%{
       state
       | reset_block_lengths: false,
         prev_bits: prev_bits,
         block_bits: block_bits,
         next_bits: next_bits
     }, bits}
  end

  def read(%State{} = state, bits) do
    {next_bits, bits} = length_bits(state, bits)

    {%{state | prev_bits: state.block_bits, block_bits: state.next_bits, next_bits: next_bits},
     bits}
  end

  defp length_bits(%State{format: format}, bits) do
    {shift, bits} = Bits.read(bits, floor_log2(format.block_sizes - 1) + 1)
    if shift >= format.block_sizes, do: raise(InvalidData, reason: :block_length_out_of_range)
    {format.frame_len_bits - shift, bits}
  end

  defp floor_log2(value) when value < 2, do: 0
  defp floor_log2(value), do: 1 + floor_log2(value >>> 1)
end

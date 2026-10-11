defmodule TuningFork.Wma.Vlc do
  @moduledoc """
  Huffman code tables and decoding with them.

  A table looks up the next `index_bits` bits of the stream at once. A code no longer
  than that is found in one step; longer codes continue in a nested table indexed by the
  bits that follow.

      table = TuningFork.Wma.Vlc.from_codes([0b0, 0b10, 0b11], [1, 2, 2], 2)
      {1, <<>>} = TuningFork.Wma.Vlc.decode(table, <<0b10::2>>)
  """

  import Bitwise

  alias TuningFork.Wma.Bits
  alias TuningFork.Wma.InvalidData

  @opaque t :: {pos_integer(), tuple()}

  @doc """
  A table of the codes `codes` with lengths `lengths`, in bits; the code at position `i`
  decodes to `i`.
  """
  @spec from_codes([non_neg_integer()], [pos_integer()], pos_integer()) :: t()
  def from_codes(codes, lengths, index_bits) do
    codes
    |> Enum.zip(lengths)
    |> Enum.with_index(fn {code, length}, symbol -> {code, length, symbol} end)
    |> build(index_bits)
  end

  @doc """
  A table of canonical codes given as `{symbol, length}` pairs in code order: each code is
  the previous one plus one, at its own length. A decoded symbol is `symbol + offset`.
  """
  @spec from_lengths([{integer(), pos_integer()}], integer(), pos_integer()) :: t()
  def from_lengths(pairs, offset, index_bits) do
    pairs
    |> Enum.map_reduce(0, fn {symbol, length}, next ->
      {{next >>> (32 - length), length, symbol + offset}, next + (1 <<< (32 - length))}
    end)
    |> elem(0)
    |> build(index_bits)
  end

  @doc "The next symbol of the stream, and the rest of the stream after its code."
  @spec decode(t(), bitstring()) :: {integer(), bitstring()}
  def decode({index_bits, entries}, bits) do
    step(elem(entries, Bits.peek(bits, index_bits)), index_bits, bits)
  end

  defp step({:leaf, symbol, length}, _index_bits, bits), do: {symbol, Bits.skip(bits, length)}
  defp step({:node, table}, index_bits, bits), do: decode(table, Bits.skip(bits, index_bits))
  defp step(:invalid, _index_bits, _bits), do: raise(InvalidData, reason: :unknown_code)

  defp build(codes, index_bits) do
    {short, long} =
      Enum.split_with(codes, fn {_code, length, _symbol} -> length <= index_bits end)

    nodes = long |> Enum.group_by(&prefix(&1, index_bits)) |> Map.new(&subtable(&1, index_bits))

    leaves =
      for {code, length, symbol} <- short,
          index <- spread(code, length, index_bits),
          into: %{},
          do: {index, {:leaf, symbol, length}}

    entries =
      for index <- 0..((1 <<< index_bits) - 1) do
        Map.get(nodes, index) || Map.get(leaves, index, :invalid)
      end

    {index_bits, List.to_tuple(entries)}
  end

  defp prefix({code, length, _symbol}, index_bits), do: code >>> (length - index_bits)

  defp subtable({prefix, codes}, index_bits) do
    rest =
      for {code, length, symbol} <- codes do
        rest_length = length - index_bits
        {code &&& (1 <<< rest_length) - 1, rest_length, symbol}
      end

    longest = rest |> Enum.map(fn {_code, length, _symbol} -> length end) |> Enum.max()
    {prefix, {:node, build(rest, min(longest, index_bits))}}
  end

  defp spread(code, length, index_bits) do
    free = index_bits - length
    first = code <<< free
    first..(first + (1 <<< free) - 1)//1
  end
end

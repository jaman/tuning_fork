defmodule TuningFork.Wma.Noise do
  @moduledoc """
  Noise coding: the high bands of a block that are sent as a gain only, and filled with
  noise shaped by the envelope when decoded.

  A block lists, per coded channel, a flag for each high band saying whether it is noise.
  The gains of the noise bands follow: the first as 7 bits less 19, each next one as a
  Huffman coded difference from the one before, in dB.

  The noise itself comes from a fixed table of 8192 values, read in a cycle by every block
  and channel in turn.
  """

  import Bitwise

  alias TuningFork.Wma.Bits
  alias TuningFork.Wma.Codebooks
  alias TuningFork.Wma.Single
  alias TuningFork.Wma.Vlc

  @size 8192
  @multiplier Single.round(0.02)
  @scale Single.round(1.0 / (1 <<< 31) * :math.sqrt(3) * @multiplier)
  @table 1..@size
         |> Enum.map_reduce(1, fn _index, seed ->
           seed = seed * 314_159 + 1 &&& 0xFFFFFFFF
           signed = if seed >= 1 <<< 31, do: seed - (1 <<< 32), else: seed
           {Single.round(Single.round(signed) * @scale), seed}
         end)
         |> elem(0)
         |> List.to_tuple()

  @doc "The noise table's mean amplitude factor, by which noise bands are divided."
  @spec multiplier() :: float()
  def multiplier, do: @multiplier

  @doc "The noise value at `index`, taken modulo the table size."
  @spec at(non_neg_integer()) :: float()
  def at(index), do: elem(@table, index &&& @size - 1)

  @doc "Reads one flag per high band, `true` for a noise band."
  @spec read_flags(bitstring(), non_neg_integer()) :: {[boolean()], bitstring()}
  def read_flags(bits, count),
    do:
      Enum.map_reduce(List.duplicate(nil, count), bits, fn nil, bits -> Bits.read_flag(bits) end)

  @doc "Reads the gain of each noise band of `flags`; bands that are not noise get `nil`."
  @spec read_gains(bitstring(), [boolean()]) :: {[integer() | nil], bitstring()}
  def read_gains(bits, flags) do
    {gains, {_last, rest}} = Enum.map_reduce(flags, {nil, bits}, &gain/2)
    {gains, rest}
  end

  defp gain(false, state), do: {nil, state}

  defp gain(true, {nil, bits}) do
    {value, bits} = Bits.read(bits, 7)
    {value - 19, {value - 19, bits}}
  end

  defp gain(true, {last, bits}) do
    {difference, bits} = Vlc.decode(Codebooks.high_band_gain(), bits)
    {last + difference, {last + difference, bits}}
  end
end

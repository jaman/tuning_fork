defmodule TuningFork.Wma.Bits do
  @moduledoc """
  Reads a WMA bitstream, most significant bit first. The stream is a bitstring holding
  the bits not yet read; every function returns what it read together with the rest.

  Reading past the end raises `TuningFork.Wma.InvalidData`; `peek/2` instead pads the
  missing bits with zeros, as the code tables look further ahead than a short code needs.
  """

  alias TuningFork.Wma.InvalidData

  @doc "The next `count` bits as an unsigned integer, and the rest of the stream."
  @spec read(bitstring(), non_neg_integer()) :: {non_neg_integer(), bitstring()}
  def read(bits, count) do
    case bits do
      <<value::size(^count), rest::bitstring>> -> {value, rest}
      _short -> raise InvalidData, reason: :end_of_data
    end
  end

  @doc "The next bit as a boolean, and the rest of the stream."
  @spec read_flag(bitstring()) :: {boolean(), bitstring()}
  def read_flag(<<1::1, rest::bitstring>>), do: {true, rest}
  def read_flag(<<0::1, rest::bitstring>>), do: {false, rest}
  def read_flag(_empty), do: raise(InvalidData, reason: :end_of_data)

  @doc "The next `count` bits as an unsigned integer without consuming them, zero-padded."
  @spec peek(bitstring(), non_neg_integer()) :: non_neg_integer()
  def peek(bits, count) do
    case bits do
      <<value::size(^count), _rest::bitstring>> ->
        value

      _short ->
        available = bit_size(bits)
        <<value::size(^available)>> = bits
        Bitwise.bsl(value, count - available)
    end
  end

  @doc "The stream with its next `count` bits dropped."
  @spec skip(bitstring(), non_neg_integer()) :: bitstring()
  def skip(bits, count) do
    case bits do
      <<_skipped::size(^count), rest::bitstring>> -> rest
      _short -> raise InvalidData, reason: :end_of_data
    end
  end
end

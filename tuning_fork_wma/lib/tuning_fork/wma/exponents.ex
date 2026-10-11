defmodule TuningFork.Wma.Exponents do
  @moduledoc """
  The spectral envelope of a block: one scale per scale factor band, coded as Huffman
  coded differences in steps of 10^(1/16) (1.5 dB), starting from step 36.

  The decoded envelope holds one value per coefficient of the block it was decoded in.
  A shorter block later in the frame may reuse it; `at/4` reads it at the position of
  another block length.
  """

  import Bitwise

  alias TuningFork.Wma.Codebooks
  alias TuningFork.Wma.InvalidData
  alias TuningFork.Wma.Single
  alias TuningFork.Wma.Vlc

  @enforce_keys [:values, :size_index, :max]
  defstruct @enforce_keys

  @type t :: %__MODULE__{values: tuple(), size_index: non_neg_integer(), max: float()}

  @lowest_step -60
  @highest_step 95
  @first_step 36
  @steps (for step <- @lowest_step..@highest_step do
            Single.round(:math.pow(10.0, step / 16.0))
          end)
         |> List.to_tuple()

  @doc """
  Decodes the envelope of a block whose scale factor bands are `bands`, the block being
  `1 <<< size_index` times shorter than a frame. Returns it with the rest of the stream.
  """
  @spec decode(bitstring(), [pos_integer()], non_neg_integer()) :: {t(), bitstring()}
  def decode(bits, bands, size_index) do
    {chunks, max, rest} = decode_bands(bits, bands, @first_step, 0.0, [], Codebooks.exponent())

    values = chunks |> Enum.reverse() |> :lists.append() |> List.to_tuple()
    {%__MODULE__{values: values, size_index: size_index, max: max}, rest}
  end

  @doc """
  The envelope value at `base + (index <<< size_index >>> exponents.size_index)`, the
  position the reference decoder reads for coefficient `index` of a block of
  `size_index`, counted from `base`.
  """
  @spec at(t(), non_neg_integer(), non_neg_integer(), integer()) :: float()
  def at(%__MODULE__{values: values, size_index: decoded}, size_index, index, base) do
    elem(values, base + ((index <<< size_index) >>> decoded))
  end

  @doc """
  The offset `count` coefficients of a block of `size_index` span in the envelope, as the
  reference decoder advances it.
  """
  @spec span(t(), non_neg_integer(), integer()) :: integer()
  def span(%__MODULE__{size_index: decoded}, size_index, count),
    do: (count <<< size_index) >>> decoded

  defp decode_bands(bits, [], _step, max, chunks, _vlc), do: {chunks, max, bits}

  defp decode_bands(bits, [width | bands], step, max, chunks, vlc) do
    {code, bits} = Vlc.decode(vlc, bits)
    step = step + code - 60

    if step < @lowest_step or step > @highest_step,
      do: raise(InvalidData, reason: :exponent_out_of_range)

    value = elem(@steps, step - @lowest_step)
    decode_bands(bits, bands, step, max(value, max), [List.duplicate(value, width) | chunks], vlc)
  end
end

defmodule TuningFork.Wma.Codebooks do
  @moduledoc """
  The Huffman tables of `TuningFork.Wma.Tables`, built once at compile time, ready for
  `TuningFork.Wma.Vlc.decode/2`.

  A coefficient codebook decodes to a symbol: 0 is the escape, 1 the end of the block,
  and any other symbol stands for a run of zeros (`elem(runs, symbol)`) followed by a
  coefficient of magnitude `elem(levels, symbol)`.
  """

  alias TuningFork.Wma.Tables
  alias TuningFork.Wma.Vlc

  @type coefficients :: %{vlc: Vlc.t(), runs: tuple(), levels: tuple()}

  @exponent Vlc.from_codes(Tables.exponent_codes(), Tables.exponent_lengths(), 8)
  @high_band_gain Vlc.from_lengths(Tables.high_band_gain_lengths(), -18, 9)

  @coefficients (for index <- 0..5 do
                   %{codes: codes, lengths: lengths, levels: counts} =
                     Tables.coefficient_codebook(index)

                   pairs =
                     counts
                     |> Enum.with_index(1)
                     |> Enum.flat_map(fn {count, level} ->
                       for run <- 0..(count - 1)//1, do: {run, level * 1.0}
                     end)
                     |> Enum.take(length(codes) - 2)

                   %{
                     vlc: Vlc.from_codes(codes, lengths, 9),
                     runs: List.to_tuple([0, 0 | Enum.map(pairs, &elem(&1, 0))]),
                     levels: List.to_tuple([0.0, 0.0 | Enum.map(pairs, &elem(&1, 1))])
                   }
                 end)
                |> List.to_tuple()

  @doc "The code of the difference between successive exponents, offset by 60."
  @spec exponent() :: Vlc.t()
  def exponent, do: @exponent

  @doc "The code of the difference between successive high band gains."
  @spec high_band_gain() :: Vlc.t()
  def high_band_gain, do: @high_band_gain

  @doc "Coefficient codebook `index`, 0 to 5."
  @spec coefficients(0..5) :: coefficients()
  def coefficients(index), do: elem(@coefficients, index)
end

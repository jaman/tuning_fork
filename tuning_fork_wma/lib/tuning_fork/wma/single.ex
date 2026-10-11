defmodule TuningFork.Wma.Single do
  @moduledoc """
  Rounding to single precision, for the constants the reference decoder keeps as 32-bit
  floats.
  """

  @doc "`value` rounded to the nearest 32-bit float."
  @spec round(number()) :: float()
  def round(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end

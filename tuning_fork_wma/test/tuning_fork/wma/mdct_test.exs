defmodule TuningFork.Wma.MdctTest do
  use ExUnit.Case, async: true

  alias TuningFork.Wma.Mdct

  for length <- [128, 2048] do
    test "the inverse MDCT of #{length} coefficients is the direct sum" do
      length = unquote(length)
      coefficients = for k <- 0..(length - 1), do: :math.sin(k * 0.37) + rem(k * 7, 13) / 6 - 1

      expected =
        for i <- 0..(2 * length - 1) do
          phase = :math.pi() / length * (i + 0.5 + length / 2)

          coefficients
          |> Enum.with_index()
          |> Enum.reduce(0.0, fn {x, k}, sum -> sum - x * :math.cos(phase * (k + 0.5)) end)
        end

      worst =
        coefficients
        |> Mdct.inverse()
        |> Enum.zip(expected)
        |> Enum.map(fn {fast, direct} -> abs(fast - direct) end)
        |> Enum.max()

      assert worst < 1.0e-9
    end
  end
end

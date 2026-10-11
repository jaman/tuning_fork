defmodule TuningFork.Wma.Mdct do
  @moduledoc """
  The inverse modified discrete cosine transform, as the reference decoder's full inverse
  MDCT computes it: `n` coefficients `x` become `2 * n` samples

      y[i] = -sum(x[k] * cos(pi / n * (i + 1/2 + n/2) * (k + 1/2)), k = 0..n-1)

  for `n` a power of two from 128 to 2048, computed through a complex FFT of `n / 2`
  points.

      samples = TuningFork.Wma.Mdct.inverse(coefficients)
  """

  import Bitwise

  @lengths for bits <- 7..11, do: 1 <<< bits

  @rotations Map.new(@lengths, fn length ->
               quarter = length / 2

               {length,
                for index <- 0..(div(length, 2) - 1) do
                  angle = :math.pi() / 2 * (index + 1 / 8) / quarter
                  {:math.cos(angle), :math.sin(angle)}
                end}
             end)

  @twiddles (for bits <- 2..10, into: %{} do
               size = 1 <<< bits

               {size,
                for index <- 0..(div(size, 2) - 1) do
                  angle = 2 * :math.pi() * index / size
                  {:math.cos(angle), :math.sin(angle)}
                end}
             end)

  @doc "The `2 * n` samples of the `n` coefficients, `n` being 128, 256, 512, 1024 or 2048."
  @spec inverse([float()]) :: [float()]
  def inverse(coefficients) do
    length = length(coefficients)
    rotation = Map.fetch!(@rotations, length)
    {evens, odds} = deinterleave(coefficients, [], [])

    half =
      odds
      |> pre_rotate(:lists.reverse(evens), rotation, [])
      |> fft(div(length, 2))
      |> post_rotate(rotation)

    {low, high} = Enum.split(half, div(length, 2))
    negated = Enum.reduce(low, [], fn value, acc -> [-value | acc] end)
    negated ++ low ++ high ++ :lists.reverse(high)
  end

  defp deinterleave([], evens, odds), do: {evens, odds}

  defp deinterleave([even, odd | rest], evens, odds),
    do: deinterleave(rest, [even | evens], [odd | odds])

  defp pre_rotate([], [], [], acc), do: :lists.reverse(acc)

  defp pre_rotate([re | res], [im | ims], [{c, s} | rotation], acc),
    do: pre_rotate(res, ims, rotation, [{re * c - im * s, re * s + im * c} | acc])

  defp post_rotate(points, rotation) do
    {first, second} =
      points
      |> Enum.zip(rotation)
      |> Enum.map(fn {{re, im}, {c, s}} -> {im * s - re * c, im * c + re * s} end)
      |> Enum.unzip()

    interleave(first, :lists.reverse(second), [])
  end

  defp interleave([], [], acc), do: :lists.reverse(acc)
  defp interleave([a | as], [b | bs], acc), do: interleave(as, bs, [b, a | acc])

  defp fft([{are, aim}, {bre, bim}], 2), do: [{are + bre, aim + bim}, {are - bre, aim - bim}]

  defp fft(points, size) do
    half = div(size, 2)
    {evens, odds} = split_points(points, [], [])
    combine(fft(evens, half), fft(odds, half), Map.fetch!(@twiddles, size), [], [])
  end

  defp split_points([], evens, odds), do: {:lists.reverse(evens), :lists.reverse(odds)}

  defp split_points([even, odd | rest], evens, odds),
    do: split_points(rest, [even | evens], [odd | odds])

  defp combine([], [], [], top, bottom), do: :lists.reverse(top, :lists.reverse(bottom))

  defp combine([{ere, eim} | evens], [{ore, oim} | odds], [{c, s} | twiddles], top, bottom) do
    tre = ore * c - oim * s
    tim = ore * s + oim * c

    combine(evens, odds, twiddles, [{ere + tre, eim + tim} | top], [
      {ere - tre, eim - tim} | bottom
    ])
  end
end

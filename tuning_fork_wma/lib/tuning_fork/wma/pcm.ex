defmodule TuningFork.Wma.Pcm do
  @moduledoc """
  Decoded samples, in 16-bit units, as signed 16-bit little-endian interleaved PCM:
  rounded to the nearest integer and clipped to -32_768..32_767.
  """

  @doc "The PCM of one frame, given as a list of samples per channel (one or two)."
  @spec frame([[float()]]) :: binary()
  def frame([mono]), do: for(sample <- mono, into: <<>>, do: <<clip(sample)::little-signed-16>>)

  def frame([left, right]), do: interleave(left, right, [])

  defp interleave([], [], acc), do: acc |> :lists.reverse() |> IO.iodata_to_binary()

  defp interleave([l | left], [r | right], acc),
    do: interleave(left, right, [<<clip(l)::little-signed-16, clip(r)::little-signed-16>> | acc])

  defp clip(sample) when sample >= 32_767.0, do: 32_767
  defp clip(sample) when sample <= -32_768.0, do: -32_768
  defp clip(sample), do: round(sample)
end

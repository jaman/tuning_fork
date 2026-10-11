defmodule TuningFork.Wma.Synthesis do
  @moduledoc """
  The samples of a block: its spectra, undone from mid/side stereo when the block uses
  it, through the inverse MDCT and windowed into each channel's output buffer.

  A channel without a spectrum gives silence, except the second channel of a mid/side
  block, which repeats the first. A mid/side block whose first channel has no spectrum
  takes it as zero.
  """

  import Bitwise

  alias TuningFork.Wma.Mdct
  alias TuningFork.Wma.Overlap
  alias TuningFork.Wma.State

  @doc """
  Adds the block at `position` samples into the frame to the output buffers of `state`;
  `spectra` holds one list of coefficients, or `nil`, per channel.
  """
  @spec add(State.t(), [[float()] | nil], boolean(), non_neg_integer()) :: State.t()
  def add(%State{format: format} = state, spectra, mid_side, position) do
    block_len = 1 <<< state.block_bits

    placement = %{
      index: (format.frame_len >>> 1) + position - (block_len >>> 1),
      block_bits: state.block_bits,
      prev_bits: state.prev_bits,
      next_bits: state.next_bits
    }

    {buffers, _previous} =
      [stereo(spectra, mid_side), state.buffers]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map_reduce(nil, fn {{spectrum, buffer}, channel}, previous ->
        output = output(spectrum, channel, mid_side, previous, block_len)
        {Overlap.add(buffer, output, placement), output}
      end)

    %{state | buffers: buffers}
  end

  defp stereo([nil, side], true) when is_list(side),
    do: stereo([List.duplicate(0.0, length(side)), side], true)

  defp stereo([mid, side], true) when is_list(mid) and is_list(side) do
    {left, right} =
      mid |> Enum.zip(side) |> Enum.map(fn {m, s} -> {m + s, m - s} end) |> Enum.unzip()

    [left, right]
  end

  defp stereo(spectra, _mid_side), do: spectra

  defp output(spectrum, _channel, _mid_side, _previous, _block_len) when is_list(spectrum),
    do: Mdct.inverse(spectrum)

  defp output(nil, 1, true, previous, _block_len), do: previous

  defp output(nil, _channel, _mid_side, _previous, block_len),
    do: List.duplicate(0.0, 2 * block_len)
end

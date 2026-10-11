defmodule TuningFork.Wma.Frame do
  @moduledoc """
  One frame: blocks until they fill `frame_len` samples, then that many finished samples
  per channel out of the output buffers.
  """

  alias TuningFork.Wma.Block
  alias TuningFork.Wma.Overlap
  alias TuningFork.Wma.State

  @doc "Decodes a frame. Returns the state, the rest of the stream and the samples per channel."
  @spec decode(State.t(), bitstring()) :: {State.t(), bitstring(), [[float()]]}
  def decode(%State{format: %{frame_len: frame_len}} = state, bits) do
    {state, bits} = blocks(state, bits, 0)
    {samples, buffers} = state.buffers |> Enum.map(&Overlap.take(&1, frame_len)) |> Enum.unzip()
    {%{state | buffers: buffers}, bits, samples}
  end

  defp blocks(%State{format: %{frame_len: frame_len}} = state, bits, position)
       when position >= frame_len,
       do: {state, bits}

  defp blocks(state, bits, position) do
    {state, bits, position} = Block.decode(state, bits, position)
    blocks(state, bits, position)
  end
end

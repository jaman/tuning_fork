defmodule TuningFork.Wma.Overlap do
  @moduledoc """
  The output buffer of one channel: two frames of samples into which each block's
  inverse MDCT output is windowed and overlap-added.

  A block of `2 * len` samples lands at `index`. Its first half fades in under a sine
  window and adds to what is there; its second half fades out and replaces what is there.
  Next to a shorter block, a block's fade is as short as its neighbour's and centred, the
  rest of that half being kept as it is (fading in) or set to zero (fading out).

  When a frame's blocks are all in, `take/2` hands out the first frame of samples and
  moves the second frame to the front.
  """

  import Bitwise

  @enforce_keys [:before, :after, :cursor]
  defstruct @enforce_keys

  @type t :: %__MODULE__{before: [float()], after: [float()], cursor: non_neg_integer()}

  @type placement :: %{
          index: non_neg_integer(),
          block_bits: pos_integer(),
          prev_bits: pos_integer(),
          next_bits: pos_integer()
        }

  @windows Map.new(7..11, fn bits ->
             length = 1 <<< bits

             rising =
               for index <- 0..(length - 1),
                   do:
                     TuningFork.Wma.Single.round(
                       :math.sin((index + 0.5) * (:math.pi() / (2.0 * length)))
                     )

             {bits, {rising, Enum.reverse(rising)}}
           end)

  @doc "A silent buffer for frames of `frame_len` samples."
  @spec new(pos_integer()) :: t()
  def new(frame_len),
    do: %__MODULE__{before: [], after: List.duplicate(0.0, 2 * frame_len), cursor: 0}

  @doc "The buffer with the `2 <<< block_bits` samples of `output` windowed in at `placement`."
  @spec add(t(), [float()], placement()) :: t()
  def add(buffer, output, placement) do
    buffer
    |> move(placement.index)
    |> run(output, fade_in(placement) ++ fade_out(placement))
  end

  @doc "The first `frame_len` samples, and the buffer with its second frame moved to the front."
  @spec take(t(), pos_integer()) :: {[float()], t()}
  def take(buffer, frame_len) do
    %__MODULE__{before: front, after: back} = move(buffer, frame_len)
    {:lists.reverse(front), %__MODULE__{before: [], after: back ++ back, cursor: 0}}
  end

  @doc "The first `frame_len` samples, as they stand."
  @spec peek(t(), pos_integer()) :: [float()]
  def peek(buffer, frame_len), do: :lists.reverse(move(buffer, frame_len).before)

  defp fade_in(%{block_bits: bits, prev_bits: prev}) when bits <= prev,
    do: [{:add, rising(bits)}]

  defp fade_in(%{block_bits: bits, prev_bits: prev}) do
    margin = ((1 <<< bits) - (1 <<< prev)) >>> 1
    [{:keep, margin}, {:add, rising(prev)}, {:copy, margin}]
  end

  defp fade_out(%{block_bits: bits, next_bits: next}) when bits <= next,
    do: [{:scale, falling(bits)}]

  defp fade_out(%{block_bits: bits, next_bits: next}) do
    margin = ((1 <<< bits) - (1 <<< next)) >>> 1
    [{:copy, margin}, {:scale, falling(next)}, {:zero, margin}]
  end

  defp rising(bits), do: @windows |> Map.fetch!(bits) |> elem(0)
  defp falling(bits), do: @windows |> Map.fetch!(bits) |> elem(1)

  defp move(%__MODULE__{cursor: cursor} = buffer, index) when index == cursor, do: buffer

  defp move(%__MODULE__{before: before, after: [value | rest], cursor: cursor}, index)
       when index > cursor,
       do: move(%__MODULE__{before: [value | before], after: rest, cursor: cursor + 1}, index)

  defp move(%__MODULE__{before: [value | before], after: rest, cursor: cursor}, index),
    do: move(%__MODULE__{before: before, after: [value | rest], cursor: cursor - 1}, index)

  defp run(%__MODULE__{before: before, after: rest, cursor: cursor}, output, steps) do
    {before, rest, _output, written} =
      Enum.reduce(steps, {before, rest, output, 0}, fn step, {before, rest, output, written} ->
        {before, rest, output} = step(step, before, rest, output)
        {before, rest, output, written + width(step)}
      end)

    %__MODULE__{before: before, after: rest, cursor: cursor + written}
  end

  defp width({:add, window}), do: length(window)
  defp width({:scale, window}), do: length(window)
  defp width({_kind, count}), do: count

  defp step({:keep, count}, before, rest, output) do
    {kept, rest} = Enum.split(rest, count)
    {:lists.reverse(kept, before), rest, Enum.drop(output, count)}
  end

  defp step({:add, window}, before, rest, output), do: add(window, before, rest, output)
  defp step({:scale, window}, before, rest, output), do: scale(window, before, rest, output)
  defp step({:copy, count}, before, rest, output), do: copy(count, before, rest, output)
  defp step({:zero, count}, before, rest, output), do: zero(count, before, rest, output)

  defp add([], before, rest, output), do: {before, rest, output}

  defp add([weight | window], before, [old | rest], [sample | output]),
    do: add(window, [sample * weight + old | before], rest, output)

  defp scale([], before, rest, output), do: {before, rest, output}

  defp scale([weight | window], before, [_old | rest], [sample | output]),
    do: scale(window, [sample * weight | before], rest, output)

  defp copy(0, before, rest, output), do: {before, rest, output}

  defp copy(count, before, [_old | rest], [sample | output]),
    do: copy(count - 1, [sample | before], rest, output)

  defp zero(0, before, rest, output), do: {before, rest, output}

  defp zero(count, before, [_old | rest], [_sample | output]),
    do: zero(count - 1, [0.0 | before], rest, output)
end

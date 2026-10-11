defmodule TuningFork.Wma.Superframe do
  @moduledoc """
  One packet of a WMA v2 stream with a bit reservoir: a superframe of whole frames,
  usually led by the end of a frame begun in the packet before.

  A packet starts with a 4-bit index, a 4-bit frame count and, in `byte_offset_bits + 3`
  bits, how many bits finish the frame carried over from the packet before. The frames
  that start in the packet follow, and the bytes after the last one that ends in it begin
  the next packet's first frame.

  A packet that cannot be decoded is dropped, and the carried-over bytes with it, as the
  reference decoder does.
  """

  import Bitwise

  alias TuningFork.Wma.Bits
  alias TuningFork.Wma.Frame
  alias TuningFork.Wma.InvalidData
  alias TuningFork.Wma.Overlap
  alias TuningFork.Wma.State

  @max_superframe 32_768

  @doc """
  Decodes `packet`. Returns the frames it completes, each a list of samples per channel,
  and the state for the next packet; or the reason it was dropped, with that state.
  """
  @spec decode(State.t(), binary()) ::
          {:ok, [[[float()]]], State.t()} | {:error, atom(), State.t()}
  def decode(%State{format: %{block_align: block_align}} = state, packet)
      when byte_size(packet) < block_align,
      do: {:error, :packet_too_small, state}

  def decode(%State{format: %{block_align: block_align}} = state, packet) do
    superframe(state, binary_part(packet, 0, block_align))
  rescue
    error in InvalidData -> {:error, error.reason, %{state | reservoir: <<>>, reservoir_len: 0}}
  end

  @doc "The samples per channel still in the output buffers once the last packet is in."
  @spec flush(State.t()) :: [[float()]]
  def flush(%State{format: %{frame_len: frame_len}, buffers: buffers}),
    do: Enum.map(buffers, &Overlap.peek(&1, frame_len))

  defp superframe(state, <<_index::4, count::4, rest::bitstring>> = packet) do
    carried = if state.reservoir_len <= 0, do: 0, else: 1
    frames_in_packet(count - 1 + carried, state, packet, rest)
  end

  defp frames_in_packet(frames, state, packet, rest) when frames <= 0 do
    if frames < 0 or bit_size(rest) <= 8, do: raise(InvalidData, reason: :no_frames)

    if state.reservoir_len + byte_size(packet) - 1 > @max_superframe,
      do: raise(InvalidData, reason: :reservoir_overflow)

    reservoir = padded(state.reservoir, state.reservoir_len) <> rest

    {:ok, [],
     %{
       state
       | reservoir: reservoir,
         reservoir_len: state.reservoir_len + 8 * byte_size(packet) - 8
     }}
  end

  defp frames_in_packet(frames, state, packet, rest) do
    offset_bits = state.format.byte_offset_bits + 3
    {bit_offset, body} = Bits.read(rest, offset_bits)
    if bit_offset > bit_size(body), do: raise(InvalidData, reason: :bit_offset_past_end)

    {state, carried, frames} = carried_frame(state, body, bit_offset, frames)
    start = bit_offset + 8 + offset_bits

    if start >= @max_superframe * 8 or start > bit_size(packet),
      do: raise(InvalidData, reason: :frame_start_past_end)

    {state, bits, decoded} =
      whole_frames(%{state | reset_block_lengths: true}, Bits.skip(packet, start), frames, [])

    {:ok, carried ++ decoded, keep_rest(state, packet, bit_size(packet) - bit_size(bits))}
  end

  defp carried_frame(%State{reservoir_len: length} = state, _body, _bit_offset, frames)
       when length <= 0,
       do: {state, [], frames}

  defp carried_frame(state, body, bit_offset, frames) do
    if state.reservoir_len + ((bit_offset + 7) >>> 3) > @max_superframe,
      do: raise(InvalidData, reason: :reservoir_overflow)

    <<finish::bitstring-size(^bit_offset), _rest::bitstring>> = body

    bits =
      Bits.skip(
        <<padded(state.reservoir, state.reservoir_len)::binary, finish::bitstring>>,
        state.reservoir_skip
      )

    {state, _rest, samples} = Frame.decode(state, bits)
    {state, [samples], frames - 1}
  end

  defp whole_frames(state, bits, 0, decoded), do: {state, bits, Enum.reverse(decoded)}

  defp whole_frames(state, bits, frames, decoded) do
    {state, bits, samples} = Frame.decode(state, bits)
    whole_frames(state, bits, frames - 1, [samples | decoded])
  end

  defp keep_rest(state, packet, consumed) do
    from = consumed >>> 3
    length = byte_size(packet) - from

    if length > @max_superframe or length < 0, do: raise(InvalidData, reason: :reservoir_overflow)

    %{
      state
      | reservoir: binary_part(packet, from, length),
        reservoir_len: length,
        reservoir_skip: consumed &&& 7
    }
  end

  defp padded(reservoir, length) when byte_size(reservoir) >= length,
    do: binary_part(reservoir, 0, length)

  defp padded(reservoir, length),
    do: reservoir <> :binary.copy(<<0>>, length - byte_size(reservoir))
end

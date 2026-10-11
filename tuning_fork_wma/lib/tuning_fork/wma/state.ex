defmodule TuningFork.Wma.State do
  @moduledoc """
  Everything a WMA v2 decoder carries from one block, frame and packet to the next.

    * `prev_bits`, `block_bits`, `next_bits` — the log2 lengths of the previous, current
      and next block; `reset_block_lengths` is set when the next block states all three.
    * `exponents` — per channel, the last decoded `TuningFork.Wma.Exponents`, or `nil`.
    * `noise_index` — the position in the noise table.
    * `buffers` — per channel, the `TuningFork.Wma.Overlap` output buffer.
    * `reservoir` — the bytes at the end of the last packet that begin the next frame,
      `reservoir_len` the length the reference decoder counts for them, and
      `reservoir_skip` the bits of the first byte that belong to the frame before.
  """

  alias TuningFork.Wma.Exponents
  alias TuningFork.Wma.Format
  alias TuningFork.Wma.Overlap

  @enforce_keys [:format, :prev_bits, :block_bits, :next_bits, :exponents, :buffers]
  defstruct @enforce_keys ++
              [
                reset_block_lengths: true,
                noise_index: 0,
                reservoir: <<>>,
                reservoir_len: 0,
                reservoir_skip: 0
              ]

  @type t :: %__MODULE__{
          format: Format.t(),
          prev_bits: pos_integer(),
          block_bits: pos_integer(),
          next_bits: pos_integer(),
          reset_block_lengths: boolean(),
          exponents: [Exponents.t() | nil],
          noise_index: non_neg_integer(),
          buffers: [Overlap.t()],
          reservoir: binary(),
          reservoir_len: integer(),
          reservoir_skip: non_neg_integer()
        }

  @doc "The state before the first packet of a stream in `format`."
  @spec new(Format.t()) :: t()
  def new(%Format{channels: channels, frame_len_bits: bits, frame_len: frame_len} = format) do
    %__MODULE__{
      format: format,
      prev_bits: bits,
      block_bits: bits,
      next_bits: bits,
      exponents: List.duplicate(nil, channels),
      buffers: List.duplicate(Overlap.new(frame_len), channels)
    }
  end
end

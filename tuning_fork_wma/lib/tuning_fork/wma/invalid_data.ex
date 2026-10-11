defmodule TuningFork.Wma.InvalidData do
  @moduledoc """
  Raised inside the decoder when a packet's bits do not form a valid WMA v2 superframe.
  `TuningFork.Wma.Superframe.decode/2` rescues it, drops that packet and carries on with
  the next, so it never reaches a caller of `TuningFork.Wma.decode/1`.
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: atom()}

  @impl true
  def message(%__MODULE__{reason: reason}), do: "invalid WMA data: #{reason}"
end

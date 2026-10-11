defmodule TuningFork.Xwma.Decoder do
  @moduledoc """
  A way to decode xWMA. `TuningFork.Xwma.decode/1` asks each decoder in its list (see
  `TuningFork.Xwma`) whether it is available, and decodes with the first that is.

  A package that decodes xWMA itself provides a module implementing this behaviour; one
  named `TuningFork.Wma` is found without configuration.
  """

  @doc "Whether this decoder can run on this machine."
  @callback available?() :: boolean()

  @doc """
  The audio of an `.xwma` file (as `TuningFork.Xwma.riff/2` builds) as signed 16-bit
  little-endian interleaved PCM, with its rate and channel count.
  """
  @callback decode(riff :: binary()) ::
              {:ok, binary(), %{rate: pos_integer(), channels: pos_integer()}} | {:error, term()}
end

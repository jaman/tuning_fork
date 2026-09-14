defmodule TuningFork.Midi.Port do
  @moduledoc """
  A MIDI port, in or out, as the operating system sees it, driven by a NIF.

      {:ok, [{0, ~c"IAC Driver Bus 1"} | _rest]} = Port.outputs()
      {:ok, port} = Port.open_output(0)
      Port.send(port, <<0x90, 60, 100>>)
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    :tuning_fork_midi
    |> :code.priv_dir()
    |> Path.join("tuning_fork_midi_nif")
    |> String.to_charlist()
    |> :erlang.load_nif(0)
  end

  @typedoc "A port handle. Opaque; it is a NIF resource."
  @type t :: reference()

  @typedoc "A device, as `{index, name}`. The index is what `open_output/1` takes."
  @type device :: {non_neg_integer(), charlist()}

  @doc "Every output the machine has, listed afresh on each call. `{:error, reason}` when none can be listed."
  @spec outputs() :: {:ok, [device()]} | {:error, atom()}
  def outputs, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Every input the machine has, listed afresh on each call. `{:error, reason}` when none can be listed."
  @spec inputs() :: {:ok, [device()]} | {:error, atom()}
  def inputs, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Open an output by index, as listed by `outputs/0`. `{:error, reason}` when it cannot be opened."
  @spec open_output(non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def open_output(_index), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Open an input by index, sending what arrives to `owner`.

  Nothing is delivered until `listen/1`. Messages arrive as
  `{:midi_in, port, bytes, monotonic_nanoseconds}`, one complete message per send. The port
  is closed when `owner` dies. `{:error, reason}` when it cannot be opened.
  """
  @spec open_input(non_neg_integer(), pid()) :: {:ok, t()} | {:error, atom()}
  def open_input(_index, _owner), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Open a virtual output under `name` that other applications see in their input lists.

  Returns `{:error, :no_backend}` on Windows, which has no virtual ports.
  """
  @spec open_virtual_output(String.t()) :: {:ok, t()} | {:error, atom()}
  def open_virtual_output(name), do: open_virtual_output_nif(String.to_charlist(name))

  @doc """
  Open a virtual input under `name` that other applications see in their output lists.

  Delivers to `owner` the same way `open_input/2` does, once `listen/1` has been called.
  Returns `{:error, :no_backend}` on Windows.
  """
  @spec open_virtual_input(String.t(), pid()) :: {:ok, t()} | {:error, atom()}
  def open_virtual_input(name, owner) do
    open_virtual_input_nif(String.to_charlist(name), owner)
  end

  @doc false
  def open_virtual_output_nif(_name), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def open_virtual_input_nif(_name, _owner), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Start an input flowing to its owner. `{:error, reason}` for a port that is not an input."
  @spec listen(t()) :: :ok | {:error, atom()}
  def listen(_port), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Send bytes to an output, exactly as given: one complete MIDI message, or several one after
  another, as built by `TuningFork.Midi.Message`. `{:error, reason}` for a port that is not
  an output.
  """
  @spec send(t(), binary()) :: :ok | {:error, atom()}
  def send(_port, _bytes), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Close a port. Closing twice is not an error, and a collected port closes itself."
  @spec close(t()) :: :ok
  def close(_port), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Whether the NIF loaded, and so whether this machine can reach a MIDI device at all. Never
  raises.

      iex> is_boolean(TuningFork.Midi.Port.available?())
      true
  """
  @spec available?() :: boolean()
  def available? do
    match?({:ok, _devices}, outputs())
  rescue
    _error -> false
  end
end

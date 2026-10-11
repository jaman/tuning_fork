defmodule TuningFork.Mt32.Nif do
  @moduledoc """
  The NIF that loads a Munt library at run time and drives it.

  Callers use `TuningFork.Mt32`; these functions take the raw values it prepares. Every one
  raises `ErlangError` if the NIF did not load.
  """

  @on_load :load_nif

  @type library :: reference()
  @type synth :: reference()

  @doc false
  def load_nif do
    :tuning_fork_mt32
    |> :code.priv_dir()
    |> :filename.join(~c"tuning_fork_mt32_nif")
    |> :erlang.load_nif(0)
    |> case do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Load the shared library at `path` and find every Munt function the synth needs.

  Fails with `{:not_a_library, reason}` when the system loader refuses the file, and
  `{:missing_function, name}` when it loads but lacks a Munt function.
  """
  @spec load_library(binary()) ::
          {:ok, library()} | {:error, {:not_a_library | :missing_function, String.t()}}
  def load_library(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "The version string the loaded Munt library reports."
  @spec library_version(library()) :: String.t()
  def library_version(_library), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Start a synth from the contents of a control ROM and a PCM ROM, rendering at `rate`.

  Returns the synth and the rate it actually renders at. Fails with `{:rom_rejected, :control
  | :pcm}` when Munt does not recognise a ROM, and `{:open_failed, code}` with Munt's return
  code when the synth does not start.
  """
  @spec open(library(), binary(), binary(), pos_integer()) ::
          {:ok, synth(), pos_integer()}
          | {:error, {:rom_rejected, :control | :pcm} | {:open_failed, integer()}}
  def open(_library, _control, _pcm, _rate), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Render `frames` stereo frames, delivering each message at its frame.

  `messages` is `[{frame, bytes}]` in frame order, each `bytes` a whole short message or a
  whole sysex. Returns the PCM, signed 16-bit little-endian interleaved, and how many
  messages the synth did not accept.
  """
  @spec render(synth(), [{non_neg_integer(), binary()}], non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :closed | :out_of_memory}
  def render(_synth, _messages, _frames), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Deliver one message at the synth's current position. Fails with Munt's return code."
  @spec play(synth(), binary()) :: :ok | {:error, :closed | integer()}
  def play(_synth, _message), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stop the synth and free it. Also happens when the reference is collected."
  @spec close(synth()) :: :ok
  def close(_synth), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule TuningFork.Speaker.Keys do
  @moduledoc """
  Single keypresses from the terminal, without waiting for Enter.

      Keys.raw()
      Keys.watch(self())

      try do
        Keys.await(nil)
      after
        Keys.cooked()
      end
  """

  @quit ["q", "Q", "\e", "\003"]

  @doc """
  Turn off the terminal's line buffering and echo. A caller that calls this must call
  `cooked/0` before it finishes. Returns `:ok` and does nothing where there is no terminal.
  """
  @spec raw() :: :ok
  def raw, do: stty("raw -echo")

  @doc "Turn line buffering and echo back on. Returns `:ok` and does nothing where there is no terminal."
  @spec cooked() :: :ok
  def cooked, do: stty("-raw echo")

  @doc """
  Send `{:key, binary}` to `owner` for every keypress, until standard input ends.

  Returns the reader's pid. The reader is spawned unlinked: it neither keeps `owner` alive
  nor brings it down.
  """
  @spec watch(pid()) :: pid()
  def watch(owner), do: spawn(fn -> loop(owner) end)

  @doc "Whether a key means stop: q, Escape, or Ctrl-C."
  @spec quit?(binary()) :: boolean()
  def quit?(key), do: key in @quit

  @doc """
  Wait until a quit key or `deadline`, whichever comes first.

  `deadline` is a `System.monotonic_time(:millisecond)` value, or `nil` to wait indefinitely.
  Returns `:quit` for a key `quit?/1` accepts, `:done` when the deadline passes. Requires a
  prior `watch/1` for the calling process, otherwise no key ever arrives.
  """
  @spec await(integer() | nil) :: :quit | :done
  def await(deadline) do
    receive do
      {:key, key} ->
        if quit?(key), do: :quit, else: await(deadline)
    after
      200 ->
        if deadline && System.monotonic_time(:millisecond) >= deadline,
          do: :done,
          else: await(deadline)
    end
  end

  defp loop(owner) do
    case IO.getn("", 1) do
      :eof -> :ok
      {:error, _reason} -> :ok
      key -> send(owner, {:key, key}) && loop(owner)
    end
  end

  defp stty(args) do
    System.cmd("sh", ["-c", "stty #{args} < /dev/tty"], stderr_to_stdout: true)
    :ok
  rescue
    _no_terminal -> :ok
  end
end

defmodule TuningFork.Cache do
  @moduledoc """
  Keeps rendered audio on disk, keyed by name and fingerprint, in a directory the
  caller names — an application keeps its own — or this library's own when none is.

      Cache.fetch("dusk", Cache.fingerprint(MyApp.Music), fn -> render() end, dir: "~/.cache/myapp/music")
  """

  require Logger

  @doc """
  The stored audio for `key`, rendering and storing it when there is none.

  `key` names the audio and may contain path separators. `fingerprint` is any string that
  changes when the rendered result should change. `render` is called only on a miss, and its
  binary is both stored and returned; an earlier fingerprint of the same key is removed. A
  store that fails is logged at debug level and the binary is still returned. `:dir` is
  the directory to keep it in, default `dir/0`.
  """
  @spec fetch(String.t(), String.t(), (-> binary()), keyword()) :: binary()
  def fetch(key, fingerprint, render, opts \\ []) do
    dir = Keyword.get(opts, :dir, dir())
    path = path(key, fingerprint, dir)

    case File.read(path) do
      {:ok, pcm} when byte_size(pcm) > 0 ->
        pcm

      _missing ->
        pcm = render.()
        forget(key, fingerprint, dir)
        store(path, pcm)
        pcm
    end
  end

  defp forget(key, fingerprint, dir) do
    dir
    |> Path.join("#{key}-*.pcm")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == path(key, fingerprint, dir)))
    |> Enum.each(&File.rm/1)
  end

  @doc "Where `key` at `fingerprint` is kept, under `dir` (default `dir/0`)."
  @spec path(String.t(), String.t(), Path.t()) :: Path.t()
  def path(key, fingerprint, dir \\ dir()), do: Path.join(dir, "#{key}-#{fingerprint}.pcm")

  @doc """
  The directory audio is kept in: `$XDG_STATE_HOME/tuning_fork`, or
  `~/.local/state/tuning_fork` when that is unset or relative.
  """
  @spec dir() :: Path.t()
  def dir, do: Path.join(state_home(), "tuning_fork")

  @doc """
  A fingerprint of `module`, as a hexadecimal string.

  Changes when the compiled code of `module`, `TuningFork.Voice` or `TuningFork.Mixer` changes.
  """
  @spec fingerprint(module()) :: String.t()
  def fingerprint(module) do
    [module, TuningFork.Voice, TuningFork.Mixer]
    |> Enum.map(&vsn/1)
    |> :erlang.phash2(4_294_967_296)
    |> Integer.to_string(16)
  end

  defp vsn(module) do
    module.module_info(:attributes) |> Keyword.get(:vsn, [0])
  rescue
    _ -> [0]
  end

  @doc "Remove the cache directory and everything in it, whatever fingerprint it was stored under."
  @spec clear() :: :ok
  def clear do
    File.rm_rf(dir())
    :ok
  end

  defp store(path, pcm) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, pcm) do
      :ok
    else
      {:error, reason} ->
        Logger.debug("tuning_fork: could not keep #{path} (#{:file.format_error(reason)})")
        :ok
    end
  end

  defp state_home do
    env_dir("XDG_STATE_HOME") ||
      Path.join(System.user_home() || System.tmp_dir!(), ".local/state")
  end

  defp env_dir(name) do
    case System.get_env(name) do
      dir when is_binary(dir) and dir != "" -> if Path.type(dir) == :absolute, do: dir
      _unset -> nil
    end
  end
end

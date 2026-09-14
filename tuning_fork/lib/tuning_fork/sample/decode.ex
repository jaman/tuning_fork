defmodule TuningFork.Sample.Decode do
  @moduledoc """
  Turns a recording in a format this library does not read itself (MP3, OGG, AAC and the
  rest) into a WAV, through a converter found on the machine.

      {:ok, wav} = TuningFork.Sample.Decode.to_wav("piano/C4v8.mp3")
  """

  alias TuningFork.Sample.Fetch

  @doc """
  The path of a WAV holding `path`'s audio: `path` itself for a WAV or FLAC, otherwise a
  16-bit WAV converted once into `TuningFork.Sample.Fetch.dir/0`. `{:error, :no_decoder}`
  when no converter is installed, `{:error, {:decode_failed, output}}` when it fails.
  """
  @spec to_wav(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def to_wav(path) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 4)) do
      {:ok, "RIFF"} -> {:ok, path}
      {:ok, "fLaC"} -> {:ok, path}
      {:ok, _other} -> converted(path)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The converter this machine has: `:afconvert`, `:ffmpeg` or `nil`."
  @spec converter() :: :afconvert | :ffmpeg | nil
  def converter do
    cond do
      System.find_executable("afconvert") -> :afconvert
      System.find_executable("ffmpeg") -> :ffmpeg
      true -> nil
    end
  end

  defp converted(path) do
    target = Path.join(Fetch.dir(), name(path))

    cond do
      File.exists?(target) -> {:ok, target}
      converter() == nil -> {:error, :no_decoder}
      true -> convert(converter(), path, target)
    end
  end

  defp convert(tool, path, target) do
    File.mkdir_p!(Fetch.dir())

    case run(tool, path, target) do
      {_output, 0} -> {:ok, target}
      {output, _status} -> {:error, {:decode_failed, String.trim(output)}}
    end
  end

  defp run(:afconvert, path, target),
    do:
      System.cmd("afconvert", ["-f", "WAVE", "-d", "LEI16", path, target], stderr_to_stdout: true)

  defp run(:ffmpeg, path, target) do
    System.cmd(
      "ffmpeg",
      ["-y", "-loglevel", "error", "-i", path, "-acodec", "pcm_s16le", target],
      stderr_to_stdout: true
    )
  end

  defp name(path) do
    hash = :crypto.hash(:sha256, Path.expand(path)) |> Base.encode16(case: :lower)

    binary_part(hash, 0, 24) <> ".wav"
  end
end

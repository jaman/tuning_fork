defmodule TuningFork.Xwma.Ffmpeg do
  @moduledoc """
  Decodes xWMA with the machine's `ffmpeg`, found on the `PATH`.
  """

  @behaviour TuningFork.Xwma.Decoder

  alias TuningFork.Sample.Fetch
  alias TuningFork.Wav

  @impl true
  def available?, do: System.find_executable("ffmpeg") != nil

  @impl true
  def decode(riff) do
    name = :crypto.hash(:sha256, riff) |> Base.encode16(case: :lower) |> binary_part(0, 24)
    source = Path.join(Fetch.dir(), name <> ".xwma")
    target = Path.join(Fetch.dir(), name <> ".wav")
    File.mkdir_p!(Fetch.dir())
    File.write!(source, riff)

    result =
      with {:ok, wav} <- run(source, target),
           {:ok, pcm, rate, channels} <- Wav.decode(wav) do
        {:ok, pcm, %{rate: rate, channels: channels}}
      end

    File.rm(source)
    File.rm(target)
    result
  end

  defp run(source, target) do
    case System.cmd(
           "ffmpeg",
           [
             "-y",
             "-loglevel",
             "error",
             "-i",
             source,
             "-acodec",
             "pcm_s16le",
             "-f",
             "wav",
             target
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> File.read(target)
      {output, _status} -> {:error, {:decode_failed, String.trim(output)}}
    end
  end
end

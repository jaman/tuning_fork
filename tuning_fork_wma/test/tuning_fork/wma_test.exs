defmodule TuningFork.WmaTest do
  use ExUnit.Case, async: true

  @moduletag skip:
               (System.get_env("TUNING_FORK_WMA_XWMA") == nil and
                  "set TUNING_FORK_WMA_XWMA to an .xwma file") ||
                 (System.find_executable("ffmpeg") == nil and "needs ffmpeg on the PATH") || false

  @tag :tmp_dir
  test "decodes an .xwma file to the samples ffmpeg decodes, within rounding", %{tmp_dir: tmp_dir} do
    path = System.fetch_env!("TUNING_FORK_WMA_XWMA")
    reference = Path.join(tmp_dir, "reference.f32")

    {_output, 0} =
      System.cmd("ffmpeg", [
        "-y",
        "-loglevel",
        "error",
        "-i",
        path,
        "-f",
        "f32le",
        "-acodec",
        "pcm_f32le",
        reference
      ])

    assert {:ok, pcm, %{rate: rate, channels: channels}} = TuningFork.Wma.decode(File.read!(path))
    assert rate > 0 and channels in 1..2

    ours = for <<sample::little-signed-16 <- pcm>>, do: sample
    theirs = for <<sample::little-float-32 <- File.read!(reference)>>, do: sample * 32_768

    assert length(ours) == length(theirs)

    worst =
      ours
      |> Enum.zip(theirs)
      |> Enum.map(fn {ours, theirs} -> abs(ours - min(max(theirs, -32_768.0), 32_767.0)) end)
      |> Enum.max(fn -> 0.0 end)

    assert worst <= 1.0
  end
end

defmodule TuningFork.Sample.DecodeTest do
  use ExUnit.Case, async: false

  alias TuningFork.Sample
  alias TuningFork.Sample.Decode

  @mp3 Path.expand("../../fixtures/flac/mono.mp3", __DIR__)
  @wav Path.expand("../../fixtures/flac/mono.wav", __DIR__)

  setup %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    :ok
  end

  @tag :tmp_dir
  test "a WAV or FLAC is its own path" do
    assert {:ok, @wav} = Decode.to_wav(@wav)
  end

  @tag :tmp_dir
  test "anything else goes through the converter on this machine, once", %{tmp_dir: dir} do
    case Decode.converter() do
      nil ->
        assert {:error, :no_decoder} = Decode.to_wav(@mp3)

      _tool ->
        assert {:ok, path} = Decode.to_wav(@mp3)
        assert String.starts_with?(path, dir)
        assert String.ends_with?(path, ".wav")
        first = File.stat!(path).mtime
        assert {:ok, ^path} = Decode.to_wav(@mp3)
        assert File.stat!(path).mtime == first

        sample = Sample.load!(@mp3)
        assert sample.rate == 8_000
        assert_in_delta Sample.duration(sample), 0.375, 0.5
        assert TuningFork.Mixer.peak(sample.pcm) > 1_000
    end
  end
end

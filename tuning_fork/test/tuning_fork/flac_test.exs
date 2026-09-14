defmodule TuningFork.FlacTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Flac, Wav}

  @fixtures Path.expand("../fixtures/flac", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp reference(name) do
    {pcm, rate, channels} = Wav.read!(Path.join(@fixtures, name))
    {pcm, rate, channels}
  end

  describe "decode/1" do
    test "a mono stream of fixed predictors" do
      assert {:ok, pcm, 8_000, 1} = Flac.decode(fixture("mono_fixed.flac"))
      assert {^pcm, 8_000, 1} = reference("mono.wav")
    end

    test "a mono stream of linear predictors" do
      assert {:ok, pcm, 8_000, 1} = Flac.decode(fixture("mono_lpc.flac"))
      assert {^pcm, 8_000, 1} = reference("mono.wav")
    end

    test "verbatim subframes" do
      assert {:ok, pcm, 8_000, 1} = Flac.decode(fixture("random.flac"))
      assert {^pcm, 8_000, 1} = reference("random.wav")
    end

    test "constant subframes" do
      assert {:ok, pcm, 8_000, 1} = Flac.decode(fixture("silent.flac"))
      assert {^pcm, 8_000, 1} = reference("silent.wav")
    end

    test "stereo with independent channels" do
      assert {:ok, pcm, 8_000, 2} = Flac.decode(fixture("stereo_indep.flac"))
      assert {^pcm, 8_000, 2} = reference("stereo.wav")
    end

    test "stereo coded as mid and side" do
      assert {:ok, pcm, 8_000, 2} = Flac.decode(fixture("stereo_lpc.flac"))
      assert {^pcm, 8_000, 2} = reference("stereo.wav")
    end

    test "stereo coded as right and side" do
      assert {:ok, pcm, 8_000, 2} = Flac.decode(fixture("stereo_lean.flac"))
      assert {^pcm, 8_000, 2} = reference("stereo.wav")
    end

    test "partitioned residuals" do
      assert {:ok, pcm, 8_000, 2} = Flac.decode(fixture("noisy.flac"))
      assert {^pcm, 8_000, 2} = reference("noisy.wav")
    end

    test "24-bit samples come out as their top 16 bits" do
      raw = File.read!(Path.join(@fixtures, "stereo_24.raw"))

      expected =
        for <<sample::24-signed-little <- raw>>, into: <<>> do
          <<Bitwise.bsr(sample, 8)::16-signed-little>>
        end

      assert {:ok, ^expected, 8_000, 2} = Flac.decode(fixture("stereo_24.flac"))
    end

    test "something that is not FLAC" do
      assert {:error, :not_flac} = Flac.decode(<<"RIFF", 0, 0, 0, 0, "WAVE">>)
      assert {:error, :not_flac} = Flac.decode(<<>>)
    end

    test "a stream cut short" do
      whole = fixture("mono_lpc.flac")
      assert {:error, :truncated} = Flac.decode(binary_part(whole, 0, byte_size(whole) - 2000))
    end
  end

  describe "read!/1" do
    test "reads a file" do
      assert {pcm, 8_000, 1} = Flac.read!(Path.join(@fixtures, "mono_lpc.flac"))
      assert {^pcm, 8_000, 1} = reference("mono.wav")
    end

    test "raises on something that is not FLAC" do
      assert_raise ArgumentError, ~r/not FLAC/, fn ->
        Flac.read!(Path.join(@fixtures, "mono.wav"))
      end
    end
  end

  describe "info/1" do
    test "reads the stream's parameters without decoding it" do
      assert {:ok, %{rate: 8_000, channels: 2, bits: 24, frames: 3_000}} =
               Flac.info(fixture("stereo_24.flac"))
    end
  end
end

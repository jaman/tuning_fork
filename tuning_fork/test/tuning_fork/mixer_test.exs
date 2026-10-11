defmodule TuningFork.MixerTest do
  use ExUnit.Case, async: true

  alias TuningFork.Mixer

  defp pcm(values), do: for(v <- values, into: <<>>, do: <<v::16-signed-little>>)
  defp samples(binary), do: for(<<s::16-signed-little <- binary>>, do: s)

  describe "mixing" do
    test "voices add together" do
      assert samples(Mixer.mix(pcm([100, -200]), pcm([50, 25]))) == [150, -175]
    end

    test "a sum past full scale is clipped, not wrapped" do
      assert samples(Mixer.mix(pcm([30_000]), pcm([30_000]))) == [32_767]
      assert samples(Mixer.mix(pcm([-30_000]), pcm([-30_000]))) == [-32_768]
    end

    test "a short sound over a long one leaves the long one playing" do
      mixed = Mixer.mix(pcm([1, 2, 3, 4]), pcm([10, 10]))

      assert samples(mixed) == [11, 12, 3, 4]
    end

    test "mixing a list folds all of them" do
      assert samples(Mixer.mix([pcm([1]), pcm([2]), pcm([3])])) == [6]
    end

    test "silence is known and passed over: mixing, clipping and measuring it cost a comparison" do
      quiet = Mixer.silence(256, 2)
      loud = :binary.copy(<<20_000::16-signed-little>>, 512)
      assert Mixer.silent?(quiet)
      refute Mixer.silent?(loud)
      assert Mixer.mix([quiet, loud, quiet]) == loud
      assert Mixer.mix([quiet, quiet]) == quiet
      assert Mixer.mix([Mixer.silence(400, 2), loud]) == loud <> Mixer.silence(144, 2)
      assert Mixer.soft_clip(quiet, 0.5) == quiet
      assert Mixer.peak(quiet) == 0

      {us, _} =
        :timer.tc(fn -> for _ <- 1..1000, do: Mixer.mix([quiet, quiet, quiet, quiet, quiet]) end)

      assert us < 20_000, "five silent buffers mixed in #{div(us, 1000)} µs"
    end
  end

  describe "taking chunks" do
    test "a chunk is frames, not samples, so stereo takes twice as much" do
      {chunk, rest} = Mixer.take(pcm([1, 2, 3, 4, 5, 6]), 2, 2)

      assert samples(chunk) == [1, 2, 3, 4]
      assert samples(rest) == [5, 6]
    end

    test "a buffer shorter than the chunk is padded with silence" do
      {chunk, rest} = Mixer.take(pcm([7]), 4, 1)

      assert samples(chunk) == [7, 0, 0, 0]
      assert rest == <<>>
    end

    test "silence is the length asked for" do
      assert byte_size(Mixer.silence(512, 1)) == 1_024
      assert byte_size(Mixer.silence(512, 2)) == 2_048
      assert Enum.all?(samples(Mixer.silence(8, 2)), &(&1 == 0))
    end
  end

  describe "noticing a mix ran out of room" do
    test "samples driven to the ends are counted, both of them" do
      assert Mixer.clipped(Mixer.mix(pcm([30_000, -30_000]), pcm([30_000, -30_000]))) == 2
    end
  end

  describe "panning" do
    test "hard left puts everything in the left channel and nothing in the right" do
      assert samples(Mixer.pan(pcm([1_000]), -1.0, 2)) == [1_000, 0]
    end

    test "centred is equal and quieter than the mono it came from" do
      [left, right] = samples(Mixer.pan(pcm([1_000]), 0.0, 2))

      assert left == right
      assert_in_delta left, 1_000 * :math.sqrt(0.5), 1.0
    end

    test "the two channels square to one wherever the sound sits" do
      for pan <- [-1.0, -0.5, 0.0, 0.25, 1.0] do
        [left, right] = samples(Mixer.pan(pcm([10_000]), pan, 2))
        power = (left * left + right * right) / (10_000 * 10_000)

        assert_in_delta power, 1.0, 0.001
      end
    end

    test "past the ends is treated as the ends rather than as an error" do
      assert samples(Mixer.pan(pcm([1_000]), -4.0, 2)) ==
               samples(Mixer.pan(pcm([1_000]), -1.0, 2))
    end
  end

  describe "placing while moving" do
    test "a placement that does not move is the pan at that place" do
      mono = pcm([1_000, -2_000, 3_000])

      assert Mixer.place(mono, {1.0, -0.5}, {1.0, -0.5}, 2) == Mixer.pan(mono, -0.5, 2)
    end

    test "the level moves in a straight line from the first frame to the last" do
      placed = Mixer.place(pcm(List.duplicate(10_000, 5)), {1.0, -1.0}, {0.0, -1.0}, 2)

      assert samples(placed) == [10_000, 0, 7_500, 0, 5_000, 0, 2_500, 0, 0, 0]
    end

    test "a mono stage moves the gain alone" do
      assert samples(Mixer.place(pcm([1_000, 1_000, 1_000]), {1.0, -1.0}, {0.0, 1.0}, 1)) ==
               [1_000, 500, 0]
    end
  end

  describe "folding to mono" do
    test "the channels average" do
      assert samples(Mixer.to_mono(pcm([100, 200, -50, 50]))) == [150, 0]
    end
  end
end

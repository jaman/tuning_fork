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

    test "an empty list is silence, not a crash" do
      assert Mixer.mix([]) == <<>>
    end
  end

  describe "taking chunks" do
    test "a chunk comes off the front and the rest is left" do
      {chunk, rest} = Mixer.take(pcm([1, 2, 3, 4, 5]), 2, 1)

      assert samples(chunk) == [1, 2]
      assert samples(rest) == [3, 4, 5]
    end

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

    test "a short stereo buffer is padded out to whole frames" do
      {chunk, rest} = Mixer.take(pcm([7, 8]), 3, 2)

      assert samples(chunk) == [7, 8, 0, 0, 0, 0]
      assert rest == <<>>
    end

    test "silence is the length asked for" do
      assert byte_size(Mixer.silence(512, 1)) == 1_024
      assert byte_size(Mixer.silence(512, 2)) == 2_048
      assert Enum.all?(samples(Mixer.silence(8, 2)), &(&1 == 0))
    end
  end

  describe "noticing a mix ran out of room" do
    test "a quiet buffer has clipped nothing" do
      assert Mixer.clipped(pcm([100, -200, 3_000])) == 0
    end

    test "samples driven to the ends are counted, both of them" do
      assert Mixer.clipped(Mixer.mix(pcm([30_000, -30_000]), pcm([30_000, -30_000]))) == 2
    end

    test "silence has clipped nothing" do
      assert Mixer.clipped(Mixer.silence(64, 2)) == 0
      assert Mixer.clipped(<<>>) == 0
    end

    test "it catches what peak alone would report as merely loud" do
      mixed = Mixer.mix([pcm([20_000]), pcm([20_000]), pcm([20_000])])

      assert Mixer.peak(mixed) == 32_767
      assert Mixer.clipped(mixed) == 1
    end
  end

  describe "panning" do
    test "hard left puts everything in the left channel and nothing in the right" do
      assert samples(Mixer.pan(pcm([1_000]), -1.0, 2)) == [1_000, 0]
    end

    test "hard right is the other way round" do
      assert samples(Mixer.pan(pcm([1_000]), 1.0, 2)) == [0, 1_000]
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

    test "panning is doubling in length, one frame in becoming two samples out" do
      assert byte_size(Mixer.pan(pcm([1, 2, 3]), 0.5, 2)) == 12
    end

    test "one channel has nowhere to put it, so the buffer comes back untouched" do
      mono = pcm([1, 2, 3])

      assert Mixer.pan(mono, -1.0, 1) == mono
    end

    test "past the ends is treated as the ends rather than as an error" do
      assert samples(Mixer.pan(pcm([1_000]), -4.0, 2)) ==
               samples(Mixer.pan(pcm([1_000]), -1.0, 2))
    end
  end

  describe "folding to mono" do
    test "the channels average" do
      assert samples(Mixer.to_mono(pcm([100, 200, -50, 50]))) == [150, 0]
    end

    test "a centred sound survives the round trip at the level it was panned to" do
      [mono] = samples(Mixer.to_mono(Mixer.pan(pcm([1_000]), 0.0, 2)))

      assert_in_delta mono, 1_000 * :math.sqrt(0.5), 1.0
    end
  end
end

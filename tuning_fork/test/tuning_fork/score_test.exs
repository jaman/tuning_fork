defmodule TuningFork.ScoreTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Mixer, Score, Voice}

  @rate 44_100

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)
  defp loud?(pcm), do: pcm |> samples() |> Enum.map(&abs/1) |> Enum.max() > 500

  describe "pitch" do
    test "a4 is 440 and the octave doubles" do
      assert_in_delta Score.note(:a4), 440.0, 0.001
      assert_in_delta Score.note(:a5), 880.0, 0.001
      assert_in_delta Score.note(:a3), 220.0, 0.001
    end

    test "a semitone up from a4 is a sharp" do
      assert_in_delta Score.note(:as4), Score.note(:a4, 1), 0.001
    end

    test "c4 is below a4, which is what makes the naming worth having" do
      assert Score.note(:c4) < Score.note(:a4)
      assert Score.note(:c5) > Score.note(:a4)
    end
  end

  describe "rendering" do
    test "the buffer is exactly as long as the score" do
      score = Score.new(bpm: 120, beats: 8)
      frames = trunc(4.0 * @rate)

      assert Score.duration(score) == 4.0
      assert byte_size(Score.render(score, @rate)) == frames * 4
      assert byte_size(Score.render(score, @rate, channels: 2)) == frames * 4
      assert byte_size(Score.render(score, @rate, channels: 1)) == frames * 2
    end

    test "a note lands on its beat and not before" do
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.1), gain: 0.9)
      pcm = Score.new(bpm: 60, beats: 4) |> Score.add(2.0, voice) |> Score.render(@rate)

      {before, from_beat} = Mixer.take(pcm, @rate * 2)

      refute loud?(before)
      assert loud?(from_beat)
    end

    test "an empty score is silence of the right length" do
      pcm = Score.new(bpm: 120, beats: 4) |> Score.render(@rate)

      refute loud?(pcm)
      assert byte_size(pcm) == trunc(2.0 * @rate) * 4
    end

    test "a tail crossing the end wraps to the start, so the loop has no seam" do
      voice = Voice.new(shape: :sine, freq: 220.0, envelope: Envelope.hit(1.5), gain: 0.9)
      pcm = Score.new(bpm: 60, beats: 2) |> Score.add(1.5, voice) |> Score.render(@rate)

      {start, _rest} = Mixer.take(pcm, div(@rate, 4))

      assert loud?(start), "the tail should have wrapped round to the beginning"
    end

    test "the loop point does not click" do
      pcm =
        Score.new(bpm: 90, beats: 4)
        |> Score.add(0.0, Voice.new(shape: :sine, freq: 220.0, envelope: Envelope.hit(2.0)))
        |> Score.add(3.5, Voice.new(shape: :sine, freq: 330.0, envelope: Envelope.hit(2.0)))
        |> Score.render(@rate)

      values = samples(pcm)
      seam = abs(hd(values) - List.last(values))

      biggest_inside =
        values
        |> Enum.zip(tl(values))
        |> Enum.map(fn {a, b} -> abs(b - a) end)
        |> Enum.max()

      assert seam <= biggest_inside,
             "the join is a bigger jump (#{seam}) than anything inside the loop (#{biggest_inside})"
    end

    test "repeat places a voice all the way through and stops at the end" do
      voice = Voice.new(shape: :sine, envelope: Envelope.hit(0.05))
      score = Score.new(bpm: 120, beats: 8) |> Score.repeat(0, 2, voice)

      assert length(score.notes) == 4
    end
  end

  describe "the stereo field" do
    defp channels(pcm) do
      pairs = for <<l::16-signed-little, r::16-signed-little <- pcm>>, do: {l, r}

      {Enum.map(pairs, &elem(&1, 0)), Enum.map(pairs, &elem(&1, 1))}
    end

    defp energy(values), do: values |> Enum.map(&abs/1) |> Enum.max()

    test "a note panned left sounds on the left and not the right" do
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.2), pan: -1.0)
      pcm = Score.new(bpm: 120, beats: 2) |> Score.add(0.0, voice) |> Score.render(@rate)

      {left, right} = channels(pcm)

      assert energy(left) > 500
      assert energy(right) == 0
    end

    test "a note panned right sounds on the right and not the left" do
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.2), pan: 1.0)
      pcm = Score.new(bpm: 120, beats: 2) |> Score.add(0.0, voice) |> Score.render(@rate)

      {left, right} = channels(pcm)

      assert energy(left) == 0
      assert energy(right) > 500
    end

    test "two notes panned apart each reach only their own side" do
      low = Voice.new(shape: :sine, freq: 220.0, envelope: Envelope.hit(0.2), pan: -1.0)
      high = Voice.new(shape: :sine, freq: 880.0, envelope: Envelope.hit(0.2), pan: 1.0)

      pcm =
        Score.new(bpm: 120, beats: 2)
        |> Score.add(0.0, low)
        |> Score.add(0.0, high)
        |> Score.render(@rate)

      {left, right} = channels(pcm)

      assert energy(left) > 500
      assert energy(right) > 500
      refute left == right
    end

    test "a centred note is the same on both sides" do
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.2))
      pcm = Score.new(bpm: 120, beats: 2) |> Score.add(0.0, voice) |> Score.render(@rate)

      {left, right} = channels(pcm)

      assert left == right
    end

    test "mono renders the same music at half the size" do
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.2), pan: -0.8)
      score = Score.new(bpm: 120, beats: 2) |> Score.add(0.0, voice)

      mono = Score.render(score, @rate, channels: 1)
      stereo = Score.render(score, @rate, channels: 2)

      assert byte_size(stereo) == byte_size(mono) * 2
      assert loud?(mono)
    end

    test "where a note sits does not cost a second synthesis" do
      voices =
        for pan <- [-1.0, -0.5, 0.0, 0.5, 1.0] do
          Voice.new(shape: :saw, freq: 440.0, envelope: Envelope.hit(0.3), pan: pan)
        end

      score =
        voices
        |> Enum.with_index()
        |> Enum.reduce(Score.new(bpm: 120, beats: 8), fn {voice, index}, acc ->
          Score.add(acc, index * 1.0, voice)
        end)

      {microseconds, pcm} = :timer.tc(fn -> Score.render(score, @rate) end)

      assert loud?(pcm)
      assert microseconds < 2_000_000
    end
  end

  describe "mixing at an offset" do
    defp pcm(values), do: for(v <- values, into: <<>>, do: <<v::16-signed-little>>)

    test "a buffer lands where it is put" do
      {mixed, over} = Mixer.mix_at(pcm([0, 0, 0, 0]), pcm([5, 5]), 1, 1)

      assert samples(mixed) == [0, 5, 5, 0]
      assert over == <<>>
    end

    test "the offset is frames, so the same one lands twice as far into stereo" do
      {mixed, over} = Mixer.mix_at(pcm([0, 0, 0, 0]), pcm([5, 5]), 1, 2)

      assert samples(mixed) == [0, 0, 5, 5]
      assert over == <<>>
    end

    test "what runs off the end comes back as overflow" do
      {mixed, over} = Mixer.mix_at(pcm([0, 0]), pcm([1, 2, 3, 4]), 1, 1)

      assert samples(mixed) == [0, 1]
      assert samples(over) == [2, 3, 4]
    end

    test "an offset past the end changes nothing and hands it all back" do
      {mixed, over} = Mixer.mix_at(pcm([0, 0]), pcm([9]), 5, 1)

      assert samples(mixed) == [0, 0]
      assert samples(over) == [9]
    end
  end
end

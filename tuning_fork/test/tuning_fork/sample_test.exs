defmodule TuningFork.SampleTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Mixer, Notes, Sample, Score, Voice, Wav}

  @rate 44_100

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)
  defp peak(pcm), do: pcm |> samples() |> Enum.map(&abs/1) |> Enum.max(fn -> 0 end)
  defp seconds(pcm), do: byte_size(pcm) / 2 / @rate

  defp tone(freq \\ 220.0, length \\ 0.4) do
    Voice.new(
      shape: :saw,
      freq: freq,
      gain: 0.8,
      envelope: Envelope.new(attack: 0.002, decay: length, sustain: 0.8, release: 0.01)
    )
    |> Voice.render(@rate)
  end

  defp sample(opts \\ []) do
    Sample.from_pcm(tone(), Keyword.merge([rate: @rate, name: "tone"], opts))
  end

  defp halves(pcm) do
    at = div(div(byte_size(pcm), 2), 2) * 2

    {binary_part(pcm, 0, at), binary_part(pcm, at, byte_size(pcm) - at)}
  end

  defp crossings(pcm) do
    pcm
    |> samples()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a < 0 and b >= 0 end)
  end

  describe "loading" do
    test "what goes in comes back frame for frame" do
      pcm = tone()
      s = Sample.from_pcm(pcm, rate: @rate)

      assert s.pcm == pcm
      assert Sample.frames(s) == div(byte_size(pcm), 2)
    end

    test "stereo is folded to mono, because a voice is synthesised in mono" do
      mono = tone()
      stereo = Mixer.pan(mono, 0.0, 2)

      s = Sample.from_pcm(stereo, rate: @rate, channels: 2)

      assert Sample.frames(s) == div(byte_size(mono), 2)
    end

    test "more channels than it can fold says so" do
      assert_raise ArgumentError, ~r/fold to mono/, fn ->
        Sample.from_pcm(tone(), channels: 6)
      end
    end

    test "a gain scales the recording as it is loaded" do
      pcm = tone()

      assert Mixer.peak(Sample.from_pcm(pcm, rate: @rate, gain: 0.5).pcm) ==
               div(Mixer.peak(pcm), 2)

      assert Sample.from_pcm(pcm, rate: @rate).pcm ==
               Sample.from_pcm(pcm, rate: @rate, gain: 1.0).pcm
    end

    test "a root given as a note name becomes a frequency" do
      assert_in_delta sample(root: :a3).root, Notes.freq(:a3), 0.01
      assert_in_delta sample(root: 300.0).root, 300.0, 0.01
      assert sample().root == nil
    end

    @tag :tmp_dir
    test "read from a file, with the file's own rate", %{tmp_dir: dir} do
      path = Path.join(dir, "tone.wav")
      Wav.write!(path, tone(), rate: 22_050, channels: 1)

      s = Sample.load!(path, root: :c3)

      assert s.rate == 22_050
      assert s.name == "tone.wav"
      assert_in_delta s.root, Notes.freq(:c3), 0.01
    end

    test "read from a FLAC file" do
      path = Path.expand("../fixtures/flac/stereo_lpc.flac", __DIR__)
      {wav, 8_000, 2} = Wav.read!(Path.expand("../fixtures/flac/stereo.wav", __DIR__))

      s = Sample.load!(path)

      assert s.rate == 8_000
      assert s.name == "stereo_lpc.flac"
      assert s.pcm == Mixer.to_mono(wav)
    end

    test "a file with neither header says so" do
      path = Path.expand("../fixtures/flac/stereo_24.raw", __DIR__)

      assert_raise ArgumentError, ~r/will not decode/, fn -> Sample.load!(path) end
    end

    test "two recordings that differ are told apart, and two that match are not" do
      one = Sample.from_pcm(tone(220.0), rate: @rate, name: "a")
      same = Sample.from_pcm(tone(220.0), rate: @rate, name: "a")
      other = Sample.from_pcm(tone(330.0), rate: @rate, name: "a")

      assert one.id == same.id
      refute one.id == other.id
    end
  end

  describe "reading it" do
    test "between two frames is the curve through their neighbours, and a line where the neighbours lie on it" do
      pcm = for v <- [0, 1000], into: <<>>, do: <<v::16-signed-little>>
      s = Sample.from_pcm(pcm, rate: @rate)

      assert_in_delta Sample.at(s, 0.0), 0.0, 0.0001
      assert_in_delta Sample.at(s, 1.0), 1000 / 32_768, 0.0001
      assert Sample.at(s, 0.5) > 1000 / 32_768 / 2

      ramp = for v <- [0, 1000, 2000, 3000], into: <<>>, do: <<v::16-signed-little>>
      assert_in_delta Sample.at(Sample.from_pcm(ramp, rate: @rate), 1.5), 1500 / 32_768, 0.0001
    end

    test "past either end is silence rather than a wrap" do
      s = sample()

      assert Sample.at(s, -1.0) == 0.0
      assert Sample.at(s, Sample.frames(s) + 10.0) == 0.0
    end
  end

  describe "a loop inside the recording" do
    test "a voice keeps going round it for as long as its envelope lasts" do
      pcm = for i <- 0..99, into: <<>>, do: <<rem(i, 50) * 500::16-signed-little>>
      looped = Sample.from_pcm(pcm, rate: @rate, loop: {50, 100})
      plain = Sample.from_pcm(pcm, rate: @rate)

      envelope =
        TuningFork.Envelope.new(attack: 0.0, decay: 0.0, sustain: 1.0, hold: 0.1, release: 0.0)

      long = Voice.render(Voice.new(sample: looped, envelope: envelope), @rate)
      short = Voice.render(Voice.new(sample: plain, envelope: envelope), @rate)

      assert TuningFork.Mixer.peak(binary_part(long, 400, 200)) > 1_000
      assert TuningFork.Mixer.peak(binary_part(short, 400, 200)) == 0
      assert Sample.at(looped, 149.0) == Sample.at(looped, 99.0)
    end

    test "a voice on a looped recording is as long as the note, not the recording" do
      pcm = for i <- 0..99, into: <<>>, do: <<rem(i, 50) * 500::16-signed-little>>
      looped = Sample.from_pcm(pcm, rate: @rate, loop: {50, 100})

      assert_in_delta Voice.duration(Voice.new(sample: looped)), 100 / @rate, 0.01
    end
  end

  describe "pitch, which is also speed" do
    test "at its root it comes out as it went in" do
      s = sample(root: 220.0)
      pcm = Voice.render(Voice.new(sample: s, freq: 220.0), @rate)

      assert_in_delta seconds(pcm), Sample.duration(s), 0.02
      assert_in_delta crossings(pcm) / seconds(pcm), 220, 12
    end

    test "an octave up is twice the pitch and half the length" do
      s = sample(root: 220.0)

      low = Voice.render(Voice.new(sample: s, freq: 220.0), @rate)
      high = Voice.render(Voice.new(sample: s, freq: 440.0), @rate)

      assert_in_delta seconds(high) / seconds(low), 0.5, 0.05
      assert_in_delta crossings(high) / seconds(high), 440, 25
    end

    test "down a fifth is longer and lower" do
      s = sample(root: 220.0)

      at_root = Voice.render(Voice.new(sample: s, freq: 220.0), @rate)
      down = Voice.render(Voice.new(sample: s, freq: Notes.freq(:d3)), @rate)

      assert seconds(down) > seconds(at_root)
      assert crossings(down) / seconds(down) < crossings(at_root) / seconds(at_root)
    end

    test "with no root it plays at its own speed whatever pitch is asked for" do
      s = sample()

      one = Voice.render(Voice.new(sample: s, freq: 220.0), @rate)
      other = Voice.render(Voice.new(sample: s, freq: 880.0), @rate)

      assert one == other
    end

    test "a recording made at another rate is corrected rather than left sharp" do
      pcm = tone()
      slow = Sample.from_pcm(pcm, rate: 22_050)
      normal = Sample.from_pcm(pcm, rate: 44_100)

      assert_in_delta seconds(Voice.render(Voice.new(sample: slow), @rate)) /
                        seconds(Voice.render(Voice.new(sample: normal), @rate)),
                      2.0,
                      0.05
    end
  end

  describe "everything else a voice has still applies" do
    test "the envelope shapes it, and can cut it short" do
      s = sample()

      whole = Voice.render(Voice.new(sample: s), @rate)
      gated = Voice.render(Voice.new(sample: s, envelope: Envelope.hit(0.05)), @rate)

      assert seconds(gated) < seconds(whole) / 2
    end

    test "gain reaches it" do
      s = sample()

      loud = Voice.render(Voice.new(sample: s, gain: 1.0), @rate)
      soft = Voice.render(Voice.new(sample: s, gain: 0.2), @rate)

      assert peak(soft) < peak(loud) / 2
    end

    test "the filter reaches it" do
      s = sample()

      open = Voice.render(Voice.new(sample: s), @rate)
      shut = Voice.render(Voice.new(sample: s, cutoff: 0.01), @rate)

      assert peak(shut) < peak(open)
    end

    test "pan places it, so a recording sits in the field like anything else" do
      s = sample()
      pcm = Voice.render(Voice.new(sample: s, pan: -1.0), @rate, 2)

      pairs = for <<l::16-signed-little, r::16-signed-little <- pcm>>, do: {l, r}

      assert Enum.any?(pairs, fn {l, _r} -> abs(l) > 500 end)
      assert Enum.all?(pairs, fn {_l, r} -> r == 0 end)
    end

    test "a freq curve is varispeed, which is a recording slowing down" do
      s = sample(root: 220.0)

      steady = Voice.render(Voice.new(sample: s, freq: 220.0), @rate)
      slowing = Voice.render(Voice.new(sample: s, freq: 220.0, sweep: 0.5), @rate)

      assert seconds(slowing) == seconds(steady)

      {early_steady, late_steady} = halves(steady)
      {early_slowing, late_slowing} = halves(slowing)

      assert crossings(early_slowing) < crossings(early_steady)
      assert crossings(late_slowing) < crossings(late_steady)
    end

    test "a longer envelope is how a tape stop is given room to finish" do
      s = sample(root: 220.0)

      short = Voice.new(sample: s, freq: 220.0, sweep: 0.5)
      long = %{short | envelope: %{short.envelope | hold: short.envelope.hold * 2}}

      assert seconds(Voice.render(long, @rate)) > seconds(Voice.render(short, @rate))
    end

    test "an unset envelope is fitted to the recording rather than cutting it to a click" do
      s = sample()
      voice = Voice.new(sample: s)

      assert_in_delta Voice.duration(voice), Sample.duration(s), 0.02
    end
  end

  describe "in a score" do
    test "a sample sits alongside a synthesised note" do
      s = sample()

      score =
        Score.new(bpm: 120, beats: 4)
        |> Score.add(0.0, Voice.new(sample: s, gain: 0.5))
        |> Score.add(2.0, Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.3)))

      pcm = Score.render(score, @rate, channels: 1)

      assert peak(binary_part(pcm, 0, @rate)) > 500
      assert peak(binary_part(pcm, @rate * 2, @rate)) > 500
    end

    test "the cache holds the recording's name, not the recording" do
      s = sample()
      voice = Voice.new(sample: s, gain: 0.4)

      score =
        Enum.reduce(0..199, Score.new(bpm: 240, beats: 200), fn beat, acc ->
          Score.add(acc, beat * 1.0, voice)
        end)

      {microseconds, pcm} = :timer.tc(fn -> Score.render(score, @rate, channels: 1) end)

      assert peak(pcm) > 500
      assert microseconds < 5_000_000, "#{div(microseconds, 1000)} ms is cache-key trouble"
    end

    test "two samples are not confused for one another" do
      one = Sample.from_pcm(tone(220.0), rate: @rate, name: "low")
      other = Sample.from_pcm(tone(660.0), rate: @rate, name: "high")

      score =
        Score.new(bpm: 60, beats: 2)
        |> Score.add(0.0, Voice.new(sample: one, gain: 0.6))
        |> Score.add(1.0, Voice.new(sample: other, gain: 0.6))

      pcm = Score.render(score, @rate, channels: 1)
      half = div(byte_size(pcm), 2)

      first = binary_part(pcm, 0, half)
      second = binary_part(pcm, half, half)

      assert crossings(second) > crossings(first) * 1.5
    end
  end

  describe "cutting a recording up" do
    test "a slice is the piece asked for" do
      s = sample()
      piece = Sample.slice(s, 0.1, 0.2)

      assert_in_delta Sample.duration(piece), 0.2, 0.01
      refute piece.id == s.id
    end

    test "a slice past the end takes what is there rather than failing" do
      s = sample()
      piece = Sample.slice(s, Sample.duration(s) - 0.05, 10.0)

      assert Sample.duration(piece) > 0.0
      assert Sample.duration(piece) < 0.1
    end

    test "reversed is the same length and the same frames the other way round" do
      s =
        Sample.from_pcm(for(v <- [1, 2, 3], into: <<>>, do: <<v::16-signed-little>>), rate: @rate)

      back = Sample.reverse(s)

      assert samples(back.pcm) == [3, 2, 1]
      assert Sample.frames(back) == Sample.frames(s)
    end
  end
end

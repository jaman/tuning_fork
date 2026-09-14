defmodule TuningFork.PartTest do
  use ExUnit.Case, async: true

  import TuningFork.Part

  alias TuningFork.{Envelope, Notes, Part, Score, Voice}

  defp beats_of(part), do: part |> Part.notes() |> Enum.map(&elem(&1, 0))
  defp freqs_of(part), do: part |> Part.notes() |> Enum.map(fn {_beat, v} -> v.freq end)

  describe "the cursor" do
    test "a played note lands where the cursor is, and moves it on" do
      played = part() |> play(:a4, 1.0) |> play(:b4, 0.5) |> play(:c5, 2.0)

      assert beats_of(played) == [0.0, 1.0, 1.5]
      assert cursor(played) == 3.5
    end

    test "a rest moves the cursor without playing anything" do
      played = part() |> play(:a4, 1.0) |> rest(2.0) |> play(:b4, 1.0)

      assert beats_of(played) == [0.0, 3.0]
    end

    test "at puts the cursor exactly, forwards or back" do
      played = part() |> at(8.0) |> play(:a4, 1.0) |> at(2.0) |> play(:b4, 1.0)

      assert beats_of(played) == [8.0, 2.0]
      assert cursor(played) == 3.0
    end

    test "notes are kept in the order they were written" do
      played = part() |> play(:a4) |> play(:b4) |> play(:c5)

      assert freqs_of(played) == Enum.map([:a4, :b4, :c5], &Notes.freq/1)
    end
  end

  describe "writing music" do
    test "a chord stacks without moving the cursor, then moves on once" do
      played = part() |> chord([:a3, :c4, :e4], 4.0) |> play(:a3, 1.0)

      assert beats_of(played) == [0.0, 0.0, 0.0, 4.0]
    end

    test "under plays without moving at all" do
      played = part() |> play(:a3, 2.0) |> under(:e4) |> play(:c4, 1.0)

      assert beats_of(played) == [0.0, 2.0, 2.0]
    end

    test "a pattern spaces notes evenly" do
      played = pattern(part(), [:a4, :b4, :c5, :d5], 0.5)

      assert beats_of(played) == [0.0, 0.5, 1.0, 1.5]
      assert cursor(played) == 2.0
    end

    test "a pattern takes a list of steps and repeats it" do
      played = pattern(part(), [:a4, :b4, :c5, :d5], [1.0, 0.5])

      assert beats_of(played) == [0.0, 1.0, 1.5, 2.5]
    end

    test "repeat does the same thing over from wherever it is" do
      played = repeat(part(), 3, &play(&1, :a4, 2.0))

      assert beats_of(played) == [0.0, 2.0, 4.0]
    end

    test "repeat with a string plays on x and keeps time on a dot" do
      played = repeat(part(), "x.x", &play(&1, :a4, 2.0))

      assert beats_of(played) == [0.0, 4.0]
      assert Part.cursor(played) == 6.0
    end

    test "repeat_indexed is told which pass it is on" do
      played =
        repeat_indexed(part(), 3, fn acc, index ->
          play(acc, Enum.at([:a4, :b4, :c5], index), 1.0)
        end)

      assert freqs_of(played) == Enum.map([:a4, :b4, :c5], &Notes.freq/1)
    end
  end

  describe "voices" do
    test "a part's synth is what its notes are played with" do
      voice = Voice.new(shape: :square, gain: 0.5)
      [{_beat, played}] = part(synth: voice) |> play(:a4) |> Part.notes()

      assert played.shape == :square
      assert_in_delta played.freq, 440.0, 0.001
    end

    test "a voice can be played directly, for a sound with no pitch" do
      drum = Voice.new(shape: :noise, freq: 0.0)
      [{_beat, played}] = part() |> play(drum, 1.0) |> Part.notes()

      assert played.shape == :noise
    end

    test "a synth may be a function of the note, asked for each note and for a plain hit" do
      instrument = fn
        nil -> Voice.new(shape: :noise, freq: 0.0)
        note -> Voice.new(shape: :triangle, freq: Notes.freq(note), gain: 0.3)
      end

      [{_beat, played}] = part(synth: instrument) |> play(:a4) |> Part.notes()
      assert played.shape == :triangle
      assert_in_delta played.freq, 440.0, 0.001

      [{_beat, hit}] = part(synth: instrument) |> steps("x...") |> Part.notes()
      assert hit.shape == :noise

      [{_beat, chosen}] = part() |> play(:c4, 1.0, synth: instrument) |> Part.notes()
      assert chosen.shape == :triangle
    end

    test "synth changes the voice from that point on" do
      played =
        part(synth: Voice.new(shape: :sine))
        |> play(:a4, 1.0)
        |> synth(Voice.new(shape: :square))
        |> play(:b4, 1.0)

      assert [%{shape: :sine}, %{shape: :square}] =
               played |> Part.notes() |> Enum.map(&elem(&1, 1))
    end
  end

  describe "levels" do
    test "the part's gain and the note's gain both apply" do
      voice = Voice.new(gain: 0.8)

      [{_beat, played}] =
        part(synth: voice, gain: 0.5) |> play(:a4, 1.0, gain: 0.5) |> Part.notes()

      assert_in_delta played.gain, 0.8 * 0.5 * 0.5, 0.0001
    end
  end

  describe "how long a note rings" do
    test "release is given in beats and reaches the envelope in seconds" do
      voice = Voice.new(envelope: Envelope.new(attack: 0.0, decay: 0.1, release: 0.0))

      [{_beat, played}] =
        part(bpm: 120, synth: voice) |> play(:a4, 0.5, release: 2.0) |> Part.notes()

      assert_in_delta Voice.duration(played), 1.0, 0.001
    end

    test "a note can ring for longer than the step, so notes overlap" do
      voice = Voice.new(envelope: Envelope.new(attack: 0.0, decay: 0.1, release: 0.0))

      played =
        part(bpm: 60, synth: voice)
        |> play(:a4, 0.5, release: 4.0)
        |> play(:b4, 0.5, release: 4.0)

      [{_first, one}, {second, _two}] = Part.notes(played)

      assert Voice.duration(one) > second * 1.0, "the first note should still be sounding"
    end

    test "without a release the voice's own envelope decides" do
      voice = Voice.new(envelope: Envelope.hit(0.25))
      [{_beat, played}] = part(synth: voice) |> play(:a4, 1.0) |> Part.notes()

      assert Voice.duration(played) == Voice.duration(voice)
    end
  end

  describe "putting parts together" do
    test "a score is as long as its longest part" do
      short = part(bpm: 60) |> rest(4)
      long = part(bpm: 60) |> rest(12)

      assert Score.from_parts([short, long]).beats == 12.0
    end

    test "an explicit length wins, which is how a loop is closed" do
      assert Score.from_parts([part() |> rest(3)], beats: 64).beats == 64.0
    end

    test "every part's notes end up in the score" do
      one = part() |> play(:a3, 1.0) |> play(:b3, 1.0)
      two = part() |> rest(4) |> play(:c4, 1.0)

      assert length(Score.from_parts([one, two]).notes) == 3
    end

    test "a part that rests first comes in later" do
      late = part() |> rest(16) |> play(:a3, 1.0)

      assert [{16.0, _voice}] = Part.notes(late)
    end

    test "the tempo comes from the parts" do
      assert Score.from_parts([part(bpm: 96)]).bpm == 96.0
    end
  end

  describe "step patterns" do
    test "an x plays and a dot does not" do
      assert beats_of(part(synth: Voice.new()) |> steps("x..x")) == [0.0, 0.75]
    end

    test "the cursor moves for the rests too, so the grid keeps its shape" do
      assert Part.cursor(part(synth: Voice.new()) |> steps("....")) == 1.0
    end

    test "the step length is the caller's" do
      assert beats_of(part(synth: Voice.new()) |> steps("x.x.", 0.5)) == [0.0, 1.0]
    end

    test "digits are the same hit, quieter" do
      [full, ghost] =
        part(synth: Voice.new(gain: 0.9))
        |> steps("x1")
        |> Part.notes()
        |> Enum.map(fn {_beat, voice} -> voice.gain end)

      assert_in_delta full, 0.9, 0.001
      assert_in_delta ghost, 0.1, 0.001
      assert ghost < full
    end

    test "a nine is as loud as an x" do
      [x, nine] =
        part(synth: Voice.new())
        |> steps("x9")
        |> Part.notes()
        |> Enum.map(fn {_beat, voice} -> voice.gain end)

      assert_in_delta x, nine, 0.001
    end

    test "spaces are for reading and do not take a step" do
      assert beats_of(part(synth: Voice.new()) |> steps("x... x...")) ==
               beats_of(part(synth: Voice.new()) |> steps("x...x..."))
    end

    test "a list places a different note on each step" do
      notes =
        part()
        |> steps([:a3, nil, :c4, nil])
        |> Part.notes()

      assert Enum.map(notes, &elem(&1, 0)) == [0.0, 0.5]
      assert_in_delta elem(hd(notes), 1).freq, Notes.freq(:a3), 0.01
    end

    test "a list can hold whole voices, for a kit on one line" do
      kick = Voice.new(shape: :noise, freq: 60.0)
      hat = Voice.new(shape: :noise, freq: 400.0)

      shapes =
        part()
        |> steps([kick, hat, nil, kick])
        |> Part.notes()
        |> Enum.map(fn {_beat, voice} -> voice.freq end)

      assert shapes == [60.0, 400.0, 60.0]
    end

    test "a step can carry its own options, for a note held while its neighbours are not" do
      [{_one, held}, {_two, short}] =
        part(synth: Voice.new(), bpm: 120)
        |> steps([{:a3, release: 4.0}, :c4], 0.5)
        |> Part.notes()

      assert Voice.duration(held) > Voice.duration(short) * 3
    end

    test "a step's own options win over the row's" do
      [{_beat, voice}] =
        part(synth: Voice.new(), bpm: 120)
        |> steps([{:a3, gain: 0.1}], 0.5, gain: 1.0)
        |> Part.notes()

      assert voice.gain < 0.5
    end

    test "the row's options still reach a step that says nothing of its own" do
      [{_one, own}, {_two, inherited}] =
        part(synth: Voice.new(), bpm: 120)
        |> steps([{:a3, release: 4.0}, :c4], 0.5, gain: 0.5)
        |> Part.notes()

      assert own.gain == inherited.gain
    end

    test "options reach every hit" do
      notes =
        part(synth: Voice.new())
        |> steps("xx", 0.25, gain: 0.5)
        |> Part.notes()

      assert Enum.all?(notes, fn {_beat, voice} -> voice.gain < 0.8 end)
    end

    test "an unknown character is a gap rather than a crash" do
      assert beats_of(part(synth: Voice.new()) |> steps("x|.|x")) == [0.0, 1.0]
    end

    test "an empty pattern does nothing at all" do
      assert part(synth: Voice.new()) |> steps("") |> Part.notes() == []
    end

    test "patterns join up, so bars can be written one at a time" do
      joined = part(synth: Voice.new()) |> steps("x...") |> steps("x...")

      assert beats_of(joined) == [0.0, 1.0]
    end
  end

  describe "placing a part in the stereo field" do
    test "a part's pan reaches its notes" do
      [{_beat, voice}] = part(pan: -0.5) |> play(:a3, 1.0) |> Part.notes()

      assert voice.pan == -0.5
    end

    test "a note's pan is measured from where the part sits, not from the middle" do
      [{_beat, voice}] = part(pan: 0.5) |> play(:a3, 1.0, pan: -0.25) |> Part.notes()

      assert voice.pan == 0.25
    end

    test "past the ends is treated as the ends" do
      [{_beat, voice}] = part(pan: 0.8) |> play(:a3, 1.0, pan: 0.8) |> Part.notes()

      assert voice.pan == 1.0
    end

    test "pan/2 moves everything after it and leaves what came before" do
      [{_one, first}, {_two, second}] =
        part()
        |> play(:a3, 1.0)
        |> Part.pan(-1.0)
        |> play(:c4, 1.0)
        |> Part.notes()

      assert first.pan == 0.0
      assert second.pan == -1.0
    end

    test "a spread draws a different position for every note" do
      notes =
        part(seed: 7)
        |> pattern([:a3, :c4, :e4, :g4], 0.5, pan: {:between, -0.9, 0.9})
        |> Part.notes()

      pans = Enum.map(notes, fn {_beat, voice} -> voice.pan end)

      assert length(Enum.uniq(pans)) > 1
      assert Enum.all?(pans, &(&1 >= -1.0 and &1 <= 1.0))
    end

    test "levels multiply where positions add" do
      [{_beat, voice}] =
        part(gain: 0.5, pan: 0.2)
        |> play(:a3, 1.0, gain: 0.5, pan: 0.2)
        |> Part.notes()

      assert_in_delta voice.gain, 0.8 * 0.5 * 0.5, 0.0001
      assert_in_delta voice.pan, 0.4, 0.0001
    end
  end
end

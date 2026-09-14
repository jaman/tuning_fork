defmodule TuningFork.GmTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Gm, Midi, MidiBuilder, Score, Voice}

  @division 480

  defp base, do: Voice.new(shape: :saw, gain: 0.2, pan: 0.3, envelope: Envelope.new())

  defp file(tracks), do: tracks |> MidiBuilder.build(division: @division) |> Midi.parse!()

  describe "choosing a voice for a program" do
    test "every program number lands in a family" do
      for program <- 0..127 do
        assert Gm.family(program) in [
                 :struck,
                 :organ,
                 :guitar,
                 :bass,
                 :strings,
                 :brass,
                 :reed,
                 :pipe,
                 :lead,
                 :pad,
                 :other
               ]
      end
    end

    test "a piano is struck and a bass is not" do
      assert Gm.family(0) == :struck
      assert Gm.family(33) == :bass
      assert Gm.family(57) == :brass
    end

    test "a struck instrument does not hold, which is what makes it struck" do
      assert Gm.for_program(0, base()).envelope.sustain == 0.0
      assert Gm.for_program(19, base()).envelope.sustain > 0.5
    end

    test "a struck note rings for over a second and then stops, however long it is held" do
      long = %{base() | envelope: TuningFork.Envelope.new(hold: 5.0, sustain: 1.0)}
      piano = Gm.for_program(0, long)

      assert piano.envelope.decay > 1.0

      assert_in_delta TuningFork.Voice.duration(piano),
                      piano.envelope.attack + piano.envelope.decay,
                      0.0001

      assert TuningFork.Voice.duration(piano) < 2.0
    end

    test "a bass is filtered far harder than a lead" do
      assert Gm.for_program(33, base()).cutoff < Gm.for_program(81, base()).cutoff
    end

    test "strings come in slowly and a piano does not" do
      assert Gm.for_program(48, base()).envelope.attack >
               Gm.for_program(0, base()).envelope.attack
    end

    test "the base voice carries through, so a caller's gain and pan survive" do
      voice = Gm.for_program(33, base())

      assert voice.gain == 0.2
      assert voice.pan == 0.3
    end

    test "the result is an ordinary voice, so it can be overridden afterwards" do
      voice = %{Gm.for_program(0, base()) | shape: :sine}

      assert voice.shape == :sine
      assert %Voice{} = voice
    end

    test "sound effects at the top of the range are left alone rather than guessed at" do
      assert Gm.for_program(127, base()) == base()
    end
  end

  describe "the drum kit" do
    test "a kick is low, a hat is high, a snare is both" do
      kit = Gm.drums()

      assert kit[36].cutoff < 0.1
      assert is_nil(kit[36].highpass)
      assert is_nil(kit[42].cutoff)
      assert kit[42].highpass > 0.5
      assert kit[38].cutoff && kit[38].highpass
    end

    test "everything in it is noise" do
      assert Enum.all?(Gm.drums(), fn {_note, voice} -> voice.shape == :noise end)
    end

    test "a crash rings longer than a closed hat" do
      kit = Gm.drums()

      assert Voice.duration(kit[49]) > Voice.duration(kit[42]) * 5
    end

    test "gain scales the whole kit without pushing anything past full" do
      quiet = Gm.drums(0.5)
      loud = Gm.drums(4.0)

      assert quiet[36].gain < Gm.drums()[36].gain
      assert Enum.all?(loud, fn {_note, voice} -> voice.gain <= 1.0 end)
    end

    test "the note numbers it answers to are percussion numbers, every one from 35 to 81" do
      assert Enum.all?(Gm.drum_notes(), &(&1 in 27..87))
      assert Enum.to_list(35..81) -- Gm.drum_notes() == []
    end
  end

  describe "a whole file at once" do
    test "each channel gets the instrument it asked for" do
      midi =
        file([
          [
            {0, {:program, 0, 0}},
            {0, {:program, 1, 33}},
            {0, {:note_on, 0, 60, 90}},
            {0, {:note_on, 1, 40, 90}},
            {@division, {:note_off, 0, 60, 0}},
            {0, {:note_off, 1, 40, 0}}
          ]
        ])

      shapes =
        midi |> Gm.score() |> Map.fetch!(:notes) |> Enum.map(fn {_beat, v} -> v.shape end)

      assert Enum.sort(shapes) == [:square, :triangle]
    end

    test "a channel that never says what it is falls back to the base voice" do
      midi = file([[{0, {:note_on, 0, 60, 90}}, {@division, {:note_off, 0, 60, 0}}]])
      [{_beat, voice}] = Gm.score(midi).notes

      assert voice.shape == :saw
    end

    test "plain ignores the programs entirely" do
      midi =
        file([
          [
            {0, {:program, 0, 0}},
            {0, {:program, 1, 33}},
            {0, {:note_on, 0, 60, 90}},
            {0, {:note_on, 1, 40, 90}},
            {@division, {:note_off, 0, 60, 0}},
            {0, {:note_off, 1, 40, 0}}
          ]
        ])

      shapes =
        midi
        |> Gm.score(plain: true)
        |> Map.fetch!(:notes)
        |> Enum.map(fn {_beat, v} -> v.shape end)
        |> Enum.uniq()

      assert shapes == [:saw]
    end

    test "drums are found without being told, and played as drums" do
      midi =
        file([
          [
            {0, {:note_on, 0, 36, 100}},
            {0, {:note_on, 0, 42, 80}},
            {@division, {:note_off, 0, 36, 0}},
            {0, {:note_off, 0, 42, 0}}
          ]
        ])

      voices = midi |> Gm.score() |> Map.fetch!(:notes) |> Enum.map(&elem(&1, 1))

      assert Enum.all?(voices, &(&1.shape == :noise))
    end

    test "options meant for to_score are passed straight through" do
      midi = file([[{0, {:note_on, 0, 60, 90}}, {@division, {:note_off, 0, 60, 0}}]])

      assert Gm.score(midi, bpm: 200).bpm == 200.0

      [{_beat, voice}] = Gm.score(midi, drum_channels: [0], drums: Gm.drums()).notes
      assert voice.shape == :noise
    end

    test "gain reaches the notes" do
      midi = file([[{0, {:note_on, 0, 60, 127}}, {@division, {:note_off, 0, 60, 0}}]])

      [{_beat, loud}] = Gm.score(midi, gain: 0.8).notes
      [{_beat, soft}] = Gm.score(midi, gain: 0.1).notes

      assert loud.gain > soft.gain
    end

    test "a caller's own base voice wins over the built-in one" do
      midi = file([[{0, {:note_on, 0, 60, 90}}, {@division, {:note_off, 0, 60, 0}}]])
      mine = Voice.new(shape: :square, gain: 0.5)

      [{_beat, voice}] = Gm.score(midi, base: mine).notes

      assert voice.shape == :square
    end

    test "the result renders to audible sound" do
      midi =
        file([
          [
            {0, {:program, 0, 0}},
            {0, {:note_on, 0, 60, 100}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      pcm = midi |> Gm.score(gain: 0.6) |> Score.render(44_100)

      assert TuningFork.Mixer.peak(pcm) > 1_000
    end
  end
end

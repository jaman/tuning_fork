defmodule TuningFork.MidiTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Curve, Envelope, Midi, MidiBuilder, Score, Voice}
  alias TuningFork.Part.Source

  @division 480

  defp file(tracks, opts \\ []) do
    tracks |> MidiBuilder.build(Keyword.put_new(opts, :division, @division)) |> Midi.parse!()
  end

  defp one_note(opts \\ []) do
    channel = Keyword.get(opts, :channel, 0)
    note = Keyword.get(opts, :note, 69)
    velocity = Keyword.get(opts, :velocity, 100)
    length = Keyword.get(opts, :length, @division)

    file([[{0, {:note_on, channel, note, velocity}}, {length, {:note_off, channel, note, 0}}]])
  end

  describe "a channel as mini-notation" do
    test "notes land on their steps with their lengths, chords are stacked, rests fill the gaps, bars are cycles" do
      d = @division

      events = [
        {0, {:note_on, 0, 60, 100}},
        {d, {:note_off, 0, 60, 0}},
        {0, {:note_on, 0, 64, 100}},
        {0, {:note_on, 0, 67, 100}},
        {div(d, 2), {:note_off, 0, 64, 0}},
        {0, {:note_off, 0, 67, 0}},
        {div(d, 2) + d, {:note_on, 0, 72, 100}},
        {div(d, 4), {:note_off, 0, 72, 0}},
        {3 * d + div(d, 4) * 3, {:note_on, 0, 71, 100}},
        {d, {:note_off, 0, 71, 0}}
      ]

      midi = file([events])
      assert {2, mini} = Midi.mini(midi, channel: 0, steps_per_beat: 4)
      assert mini == "<[c4@4 [e4,g4]@2 ~@6 c5 ~@3] [~@12 b4@4]>"

      assert {1, "<[c4@4 [e4,g4]@2 ~@6 c5 ~@3]>"} =
               Midi.mini(midi, channel: 0, steps_per_beat: 4, from: 0, bars: 1)

      assert {1, "<[d4@4 [fs4,a4]@2 ~@6 d5 ~@3]>"} =
               Midi.mini(midi, channel: 0, steps_per_beat: 4, bars: 1, transpose: 2)

      assert {0, "<>"} = Midi.mini(midi, channel: 5)
    end

    test "one voice of the chords can be taken, and notes played a little late still land on their steps" do
      d = @division
      late = div(d, 7)

      events = [
        {0, {:note_on, 0, 48, 100}},
        {0, {:note_on, 0, 64, 100}},
        {d, {:note_off, 0, 48, 0}},
        {0, {:note_off, 0, 64, 0}},
        {3 * d + late, {:note_on, 0, 50, 100}},
        {0, {:note_on, 0, 65, 100}},
        {div(d, 2), {:note_off, 0, 50, 0}},
        {0, {:note_off, 0, 65, 0}},
        {div(d, 4), {:note_on, 0, 52, 100}},
        {div(d, 4), {:note_off, 0, 52, 0}}
      ]

      midi = file([events])

      assert {2, "<[[c3,e4]@4 ~@12] [[d3,f4]@2 ~ e3 ~@12]>"} =
               Midi.mini(midi, channel: 0, bars: 2)

      assert {1, "<[c3@4 ~@12]>"} = Midi.mini(midi, channel: 0, bars: 1, voice: :lowest)
      assert {1, "<[e4@4 ~@12]>"} = Midi.mini(midi, channel: 0, bars: 1, voice: :highest)

      assert {2, "<[c3@4 ~@12] [d3@2 ~@14]>"} =
               Midi.mini(midi, channel: 0, bars: 2, voice: :lowest, on: :beats)
    end
  end

  describe "the header" do
    test "format, division and track count are read" do
      midi = file([[{0, {:note_on, 0, 60, 64}}], [{0, {:note_on, 1, 62, 64}}]], division: 96)

      assert midi.format == 1
      assert midi.division == 96
      assert length(midi.tracks) == 2
    end

    test "something that is not a MIDI file says so" do
      assert {:error, :not_a_midi_file} = Midi.parse("nope, not this")
      assert {:error, :not_a_midi_file} = Midi.parse(<<>>)
    end

    test "SMPTE timing is refused by name rather than misread as ticks" do
      smpte = <<"MThd", 6::32, 0::16, 1::16, 0xE728::16>>

      assert {:error, :smpte_division_unsupported} = Midi.parse(smpte)
    end

    test "a zero division is refused rather than dividing by it" do
      assert {:error, :zero_division} = Midi.parse(<<"MThd", 6::32, 0::16, 1::16, 0::16>>)
    end

    test "parse! raises rather than reporting" do
      assert_raise ArgumentError, ~r/could not read that MIDI file/, fn -> Midi.parse!("no") end
    end
  end

  describe "reading events" do
    test "a note on and a note off pair up" do
      [note] = Midi.notes(one_note(note: 60, velocity: 90, length: @division))

      assert note.note == 60
      assert note.velocity == 90
      assert note.beat == 0.0
      assert note.beats == 1.0
    end

    test "delta times accumulate into absolute positions" do
      midi =
        file([
          [
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}},
            {@division, {:note_on, 0, 62, 64}},
            {@division, {:note_off, 0, 62, 0}}
          ]
        ])

      assert [first, second] = Midi.notes(midi)
      assert first.beat == 0.0
      assert second.beat == 2.0
    end

    test "a note on at velocity zero is a note off, as most files write one" do
      midi =
        file([[{0, {:note_on, 0, 60, 64}}, {@division, {:note_on, 0, 60, 0}}]])

      assert [note] = Midi.notes(midi)
      assert note.beats == 1.0
    end

    test "running status is followed, so a run of notes is not misread" do
      run =
        <<0x90, 60, 64>> <>
          <<120, 60, 0>> <>
          <<0, 62, 64>> <>
          <<120, 62, 0>>

      notes = Midi.notes(file([[{0, {:raw, run}}]]))

      assert length(notes) == 2
      assert Enum.map(notes, & &1.note) == [60, 62]
      assert Enum.map(notes, & &1.beat) == [0.0, 0.25]
      assert Enum.map(notes, & &1.beats) == [0.25, 0.25]
    end

    test "a variable-length delta of more than one byte is read" do
      midi = file([[{0, {:note_on, 0, 60, 64}}, {@division * 8, {:note_off, 0, 60, 0}}]])

      assert [note] = Midi.notes(midi)
      assert note.beats == 8.0
    end

    test "several tracks are merged in time order" do
      midi =
        file([
          [{0, {:note_on, 0, 60, 64}}, {@division * 4, {:note_off, 0, 60, 0}}],
          [{@division * 2, {:note_on, 1, 67, 64}}, {@division, {:note_off, 1, 67, 0}}]
        ])

      assert [first, second] = Midi.notes(midi)
      assert first.note == 60
      assert second.note == 67
      assert second.beat == 2.0
    end

    test "sysex and aftertouch are skipped without desynchronising what follows" do
      midi =
        file([
          [
            {0, {:sysex, <<0x7E, 0x00, 0x09, 0x01, 0xF7>>}},
            {0, {:aftertouch, 0, 60, 40}},
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      assert [note] = Midi.notes(midi)
      assert note.note == 60
    end

    test "unknown chunks between tracks are skipped" do
      good = MidiBuilder.track([{0, {:note_on, 0, 60, 64}}, {@division, {:note_off, 0, 60, 0}}])
      junk = <<"XYZW", 4::32, 0, 0, 0, 0>>

      binary = <<"MThd", 6::32, 1::16, 1::16, @division::16>> <> junk <> good

      assert {:ok, midi} = Midi.parse(binary)
      assert length(Midi.notes(midi)) == 1
    end

    test "a note left open at the end of the file is still given a length" do
      midi = file([[{0, {:note_on, 0, 60, 64}}]])

      assert [note] = Midi.notes(midi)
      assert note.beats > 0.0
    end

    test "striking a note already sounding closes the first rather than leaving it open" do
      midi =
        file([
          [
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      assert [first, second] = Midi.notes(midi)
      assert first.beats == 1.0
      assert second.beat == 1.0
    end

    test "a program change is remembered for the notes after it" do
      midi =
        file([
          [
            {0, {:program, 0, 42}},
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      assert [note] = Midi.notes(midi)
      assert note.program == 42
    end
  end

  describe "tempo" do
    test "with no tempo event it is the MIDI default of 120" do
      score = Midi.to_score(one_note())

      assert score.bpm == 120.0
      assert score.changes == []
    end

    test "a tempo at the start becomes the score's starting tempo" do
      midi =
        file([
          [
            {0, {:tempo, 1_000_000}},
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      score = Midi.to_score(midi)

      assert score.bpm == 60.0
      assert score.changes == []
    end

    test "a tempo change part-way through becomes a change on the score" do
      midi =
        file([
          [
            {0, {:tempo, 500_000}},
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}},
            {0, {:tempo, 1_000_000}},
            {0, {:note_on, 0, 62, 64}},
            {@division, {:note_off, 0, 62, 0}}
          ]
        ])

      score = Midi.to_score(midi)

      assert score.bpm == 120.0
      assert score.changes == [{1.0, 60.0}]
      assert Score.tempo_map(score) == [{0.0, 120.0}, {1.0, 60.0}]
    end

    test "a piece that changes speed is longer than its starting tempo would make it" do
      midi =
        file([
          [
            {0, {:tempo, 500_000}},
            {0, {:note_on, 0, 60, 64}},
            {@division * 2, {:note_off, 0, 60, 0}},
            {0, {:tempo, 1_000_000}},
            {0, {:note_on, 0, 62, 64}},
            {@division * 2, {:note_off, 0, 62, 0}}
          ]
        ])

      score = Midi.to_score(midi)

      assert_in_delta Score.duration(score), 3.0, 0.01
    end

    test "bpm overrides whatever the file says, changes and all" do
      midi =
        file([
          [
            {0, {:tempo, 500_000}},
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}},
            {0, {:tempo, 1_000_000}},
            {0, {:note_on, 0, 62, 64}},
            {@division, {:note_off, 0, 62, 0}}
          ]
        ])

      score = Midi.to_score(midi, bpm: 240)

      assert score.bpm == 240.0
      assert score.changes == []
      assert_in_delta Score.duration(score), 0.5, 0.01
    end

    test "an overridden tempo shortens the notes as well as moving them" do
      slow = Midi.to_score(one_note(length: @division), bpm: 60, quantize: nil)
      fast = Midi.to_score(one_note(length: @division), bpm: 240, quantize: nil)

      [{_beat, slow_voice}] = slow.notes
      [{_beat, fast_voice}] = fast.notes

      assert_in_delta Voice.duration(slow_voice) / Voice.duration(fast_voice), 4.0, 0.1
    end

    test "a file with no tempo at all can be given one" do
      assert Midi.to_score(one_note()).bpm == 120.0
      assert Midi.to_score(one_note(), bpm: 75).bpm == 75.0
    end

    test "a note's length follows the tempo where it sits, not the tempo at the top" do
      slow =
        file([
          [
            {0, {:tempo, 1_000_000}},
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      score = Midi.to_score(slow, quantize: nil)
      [{_beat, voice}] = score.notes

      assert_in_delta Voice.duration(voice), 1.0, 0.05
    end
  end

  describe "turning notes into voices" do
    test "pitch comes from the note number, with 69 being a4" do
      score = Midi.to_score(one_note(note: 69))
      [{_beat, voice}] = score.notes

      assert_in_delta voice.freq, 440.0, 0.001
    end

    test "an octave up doubles" do
      [{_beat, low}] = Midi.to_score(one_note(note: 57)).notes
      [{_beat, high}] = Midi.to_score(one_note(note: 69)).notes

      assert_in_delta high.freq / low.freq, 2.0, 0.001
    end

    test "velocity becomes gain, over whatever the synth was set to" do
      synth = Voice.new(gain: 0.8)

      [{_beat, loud}] =
        Midi.to_score(one_note(velocity: 127), default: synth).notes

      [{_beat, soft}] =
        Midi.to_score(one_note(velocity: 32), default: synth).notes

      assert_in_delta loud.gain, 0.8, 0.01
      assert_in_delta soft.gain, 0.8 * 32 / 127, 0.01
      assert soft.gain < loud.gain
    end

    test "a channel picks its own synth" do
      lead = Voice.new(shape: :saw)
      bass = Voice.new(shape: :square)

      midi =
        file([
          [
            {0, {:note_on, 0, 60, 64}},
            {0, {:note_on, 1, 40, 64}},
            {@division, {:note_off, 0, 60, 0}},
            {0, {:note_off, 1, 40, 0}}
          ]
        ])

      score = Midi.to_score(midi, synths: %{0 => lead, 1 => bass})
      shapes = score.notes |> Enum.map(fn {_beat, voice} -> voice.shape end) |> Enum.sort()

      assert shapes == [:saw, :square]
    end

    test "a channel with no synth named falls back to the default" do
      score = Midi.to_score(one_note(channel: 5), default: Voice.new(shape: :triangle))
      [{_beat, voice}] = score.notes

      assert voice.shape == :triangle
    end

    test "on the drum channel the note number picks a drum rather than a pitch" do
      kick = Voice.new(shape: :noise, freq: 60.0)
      snare = Voice.new(shape: :noise, freq: 200.0)

      midi =
        file([
          [
            {0, {:note_on, 9, 36, 100}},
            {@division, {:note_off, 9, 36, 0}},
            {0, {:note_on, 9, 38, 100}},
            {@division, {:note_off, 9, 38, 0}}
          ]
        ])

      score = Midi.to_score(midi, drums: %{36 => kick, 38 => snare})
      [{_one, first}, {_two, second}] = Enum.sort_by(score.notes, &elem(&1, 0))

      assert first.freq == 60.0
      assert second.freq == 200.0
    end

    test "a drum library writing on channel one is played as drums when told so" do
      kick = Voice.new(shape: :noise, freq: 60.0, envelope: Envelope.hit(0.2))
      snare = Voice.new(shape: :noise, freq: 200.0, envelope: Envelope.hit(0.1))

      midi =
        file([
          [
            {0, {:note_on, 0, 36, 100}},
            {@division, {:note_off, 0, 36, 0}},
            {0, {:note_on, 0, 38, 100}},
            {@division, {:note_off, 0, 38, 0}}
          ]
        ])

      voices =
        Midi.to_score(midi, drum_channels: [0], drums: %{36 => kick, 38 => snare})
        |> Map.fetch!(:notes)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      assert Enum.map(voices, & &1.freq) == [60.0, 200.0]
    end

    test "without being told, the same file is played as low notes rather than drums" do
      kick = Voice.new(shape: :noise, freq: 60.0, envelope: Envelope.hit(0.2))
      midi = one_note(channel: 0, note: 36)

      [{_beat, voice}] = Midi.to_score(midi, drums: %{36 => kick}).notes

      assert_in_delta voice.freq, 440.0 * :math.pow(2.0, (36 - 69) / 12.0), 0.01
    end

    test "a drum keeps its own length rather than being stretched to the note" do
      kick = Voice.new(shape: :noise, freq: 60.0, envelope: Envelope.hit(0.2))

      short = one_note(channel: 9, note: 36, length: @division)
      long = one_note(channel: 9, note: 36, length: @division * 8)

      [{_beat, from_short}] = Midi.to_score(short, drums: %{36 => kick}).notes
      [{_beat, from_long}] = Midi.to_score(long, drums: %{36 => kick}).notes

      assert Voice.duration(from_short) == Voice.duration(from_long)
      assert Voice.duration(from_short) == Voice.duration(kick)
    end

    test "drums and synths play side by side, which is what a real arrangement is" do
      piano = Voice.new(shape: :triangle)
      bass = Voice.new(shape: :square)
      kick = Voice.new(shape: :noise, freq: 60.0, envelope: Envelope.hit(0.2))
      snare = Voice.new(shape: :noise, freq: 200.0, envelope: Envelope.hit(0.1))

      midi =
        file([
          [
            {0, {:note_on, 0, 60, 90}},
            {0, {:note_on, 1, 36, 90}},
            {0, {:note_on, 9, 36, 110}},
            {0, {:note_on, 9, 38, 100}},
            {@division, {:note_off, 0, 60, 0}},
            {0, {:note_off, 1, 36, 0}},
            {0, {:note_off, 9, 36, 0}},
            {0, {:note_off, 9, 38, 0}}
          ]
        ])

      voices =
        Midi.to_score(midi,
          synths: %{0 => piano, 1 => bass},
          drums: %{36 => kick, 38 => snare}
        ).notes
        |> Enum.map(&elem(&1, 1))

      shapes = voices |> Enum.map(& &1.shape) |> Enum.frequencies()

      assert shapes == %{triangle: 1, square: 1, noise: 2}

      [bass_note] = Enum.filter(voices, &(&1.shape == :square))
      [kick_note] = Enum.filter(voices, &(&1.freq == 60.0))

      assert_in_delta bass_note.freq, 440.0 * :math.pow(2.0, (36 - 69) / 12.0), 0.01
      assert kick_note.shape == :noise
    end

    test "auto spots a loop library writing percussion on channel one" do
      midi =
        file([
          [
            {0, {:note_on, 0, 36, 100}},
            {0, {:note_on, 0, 42, 90}},
            {@division, {:note_off, 0, 36, 0}},
            {0, {:note_off, 0, 42, 0}}
          ]
        ])

      assert Midi.drum_channels(midi, drum_channels: :auto) == [0, 9]
    end

    test "auto leaves a channel alone once it has said what instrument it is" do
      midi =
        file([
          [
            {0, {:program, 0, 33}},
            {0, {:note_on, 0, 36, 100}},
            {@division, {:note_off, 0, 36, 0}}
          ]
        ])

      assert Midi.drum_channels(midi, drum_channels: :auto) == [9]
    end

    test "auto leaves a channel alone when its notes are not percussion numbers" do
      midi =
        file([[{0, {:note_on, 0, 100, 100}}, {@division, {:note_off, 0, 100, 0}}]])

      assert Midi.drum_channels(midi, drum_channels: :auto) == [9]
    end

    test "channel ten is percussion whatever else it does" do
      midi =
        file([
          [
            {0, {:program, 9, 0}},
            {0, {:note_on, 9, 100, 100}},
            {@division, {:note_off, 9, 100, 0}}
          ]
        ])

      assert 9 in Midi.drum_channels(midi, drum_channels: :auto)
    end

    test "an explicit list still wins over guessing" do
      midi = file([[{0, {:note_on, 0, 36, 100}}, {@division, {:note_off, 0, 36, 0}}]])

      assert Midi.drum_channels(midi, drum_channels: [3]) == [3]
      assert Midi.drum_channels(midi) == [9]
    end

    test "auto reaches to_score, so the notes really are played as drums" do
      kick = Voice.new(shape: :noise, freq: 60.0, envelope: Envelope.hit(0.2))
      hat = Voice.new(shape: :noise, freq: 200.0, envelope: Envelope.hit(0.05))

      midi =
        file([
          [
            {0, {:note_on, 0, 36, 100}},
            {0, {:note_on, 0, 42, 80}},
            {@division, {:note_off, 0, 36, 0}},
            {0, {:note_off, 0, 42, 0}}
          ]
        ])

      voices =
        Midi.to_score(midi, drum_channels: :auto, drums: %{36 => kick, 42 => hat}).notes
        |> Enum.map(&elem(&1, 1))

      assert Enum.map(voices, & &1.freq) |> Enum.sort() == [60.0, 200.0]
      assert Enum.all?(voices, &(&1.shape == :noise))
    end

    defp channel_playing(notes) do
      notes
      |> Enum.flat_map(&[{0, {:note_on, 0, &1, 90}}, {120, {:note_off, 0, &1, 0}}])
      |> List.wrap()
      |> then(&file([&1]))
      |> Midi.drum_channels(drum_channels: :auto)
      |> Enum.member?(0)
    end

    test "a break made only of snares is still drums" do
      assert channel_playing([38])
    end

    test "a kit with toms and cymbals is drums" do
      assert channel_playing([36, 38, 42, 41, 43, 45, 49])
    end

    test "a melody is not, even with no program change to say otherwise" do
      refute channel_playing([60, 62, 64, 65, 67])
      refute channel_playing([60, 61, 62, 63, 64, 65])
    end

    test "a bass line that stays low is not drums either" do
      refute channel_playing([28, 30, 31, 33, 35, 28, 30])
    end

    test "hand percussion above the kit is missed, and needs saying outright" do
      refute channel_playing([61, 62, 63])
    end

    test "several drum channels can be named at once" do
      kick = Voice.new(shape: :noise, freq: 60.0, envelope: Envelope.hit(0.2))

      midi =
        file([
          [
            {0, {:note_on, 0, 36, 100}},
            {0, {:note_on, 9, 36, 100}},
            {@division, {:note_off, 0, 36, 0}},
            {0, {:note_off, 9, 36, 0}}
          ]
        ])

      score = Midi.to_score(midi, drum_channels: [0, 9], drums: %{36 => kick})

      assert Enum.all?(score.notes, fn {_beat, voice} -> voice.freq == 60.0 end)
    end

    test "a note's length becomes its envelope" do
      short = Midi.to_score(one_note(length: @division), quantize: nil)
      long = Midi.to_score(one_note(length: @division * 4), quantize: nil)

      [{_beat, short_voice}] = short.notes
      [{_beat, long_voice}] = long.notes

      assert Voice.duration(long_voice) > Voice.duration(short_voice) * 3
    end

    test "the synth's own attack and release survive; only the decay stretches" do
      synth = Voice.new(envelope: Envelope.new(attack: 0.05, release: 0.1, decay: 0.01))
      score = Midi.to_score(one_note(length: @division * 2), default: synth, quantize: nil)
      [{_beat, voice}] = score.notes

      assert voice.envelope.attack == 0.05
      assert voice.envelope.release == 0.1
      assert voice.envelope.decay > 0.5
    end
  end

  describe "quantising note lengths" do
    test "lengths land on the grid, so a performance does not defeat the score's cache" do
      lengths =
        for ticks <- [471, 478, 483, 490] do
          midi =
            file([[{0, {:note_on, 0, 60, 64}}, {ticks, {:note_off, 0, 60, 0}}]])

          [{_beat, voice}] = Midi.to_score(midi, quantize: 0.05).notes
          voice.envelope.decay
        end

      assert length(Enum.uniq(lengths)) == 1,
             "four nearly-equal lengths should quantise to one render"
    end

    test "turning it off keeps every length distinct" do
      lengths =
        for ticks <- [471, 478, 483, 490] do
          midi = file([[{0, {:note_on, 0, 60, 64}}, {ticks, {:note_off, 0, 60, 0}}]])

          [{_beat, voice}] = Midi.to_score(midi, quantize: nil).notes
          voice.envelope.decay
        end

      assert length(Enum.uniq(lengths)) == 4
    end

    test "a very short note still has a length" do
      midi = file([[{0, {:note_on, 0, 60, 64}}, {1, {:note_off, 0, 60, 0}}]])
      [{_beat, voice}] = Midi.to_score(midi).notes

      assert Voice.duration(voice) > 0.0
    end
  end

  describe "pitch bend" do
    test "a bend inside a note becomes a curve on it" do
      midi =
        file([
          [
            {0, {:note_on, 0, 60, 64}},
            {@division, {:pitch_bend, 0, 8_191}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      [{_beat, voice}] = Midi.to_score(midi).notes

      assert %{freq: curve} = voice.curves
      assert_in_delta Curve.at(curve, 1.0), :math.pow(2.0, 2 / 12.0), 0.01
    end

    test "the bend range is the caller's to set" do
      midi =
        file([
          [
            {0, {:note_on, 0, 60, 64}},
            {@division, {:pitch_bend, 0, 8_191}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      [{_beat, voice}] = Midi.to_score(midi, bend_range: 12).notes

      assert_in_delta Curve.at(voice.curves.freq, 1.0), 2.0, 0.02
    end

    test "a bend on another channel does not reach this note" do
      midi =
        file([
          [
            {0, {:note_on, 0, 60, 64}},
            {@division, {:pitch_bend, 3, 8_191}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      [{_beat, voice}] = Midi.to_score(midi).notes

      assert voice.curves == %{}
    end

    test "a bend outside the note does not reach it either" do
      midi =
        file([
          [
            {0, {:note_on, 0, 60, 64}},
            {@division, {:note_off, 0, 60, 0}},
            {@division, {:pitch_bend, 0, 8_191}}
          ]
        ])

      [{_beat, voice}] = Midi.to_score(midi).notes

      assert voice.curves == %{}
    end

    test "a bend that goes nowhere leaves no curve behind" do
      midi =
        file([
          [
            {0, {:note_on, 0, 60, 64}},
            {@division, {:pitch_bend, 0, 0}},
            {@division, {:note_off, 0, 60, 0}}
          ]
        ])

      [{_beat, voice}] = Midi.to_score(midi).notes

      assert voice.curves == %{}
    end

    test "a bend already in force tunes the note rather than bending it" do
      midi =
        file([
          [
            {0, {:pitch_bend, 0, -400}},
            {0, {:note_on, 0, 69, 100}},
            {@division, {:note_off, 0, 69, 0}}
          ]
        ])

      [{_beat, voice}] = Midi.to_score(midi).notes

      assert voice.curves == %{}, "a tuning offset is not a bend and should leave no curve"
      assert_in_delta voice.freq, 440.0 * :math.pow(2.0, -400 / 8_192 * 2 / 12.0), 0.01
      assert voice.freq < 440.0
    end

    test "every later note on the channel is tuned too, not just the first" do
      midi =
        file([
          [
            {0, {:pitch_bend, 0, -400}},
            {0, {:note_on, 0, 69, 100}},
            {@division, {:note_off, 0, 69, 0}},
            {@division * 4, {:note_on, 0, 69, 100}},
            {@division, {:note_off, 0, 69, 0}}
          ]
        ])

      [{_one, first}, {_two, second}] =
        Midi.to_score(midi).notes |> Enum.sort_by(&elem(&1, 0))

      assert first.freq == second.freq
      assert second.freq < 440.0
    end

    test "channels tuned differently come out at different pitches for the same note" do
      midi =
        file([
          [
            {0, {:pitch_bend, 0, 0}},
            {0, {:pitch_bend, 1, -400}},
            {0, {:note_on, 0, 69, 100}},
            {0, {:note_on, 1, 69, 100}},
            {@division, {:note_off, 0, 69, 0}},
            {0, {:note_off, 1, 69, 0}}
          ]
        ])

      [equal, tempered] =
        Midi.to_score(midi).notes
        |> Enum.map(fn {_beat, voice} -> voice.freq end)
        |> Enum.sort(:desc)

      assert_in_delta equal, 440.0, 0.01
      assert tempered < equal
    end

    test "a bend that moves during a note is measured against where it started" do
      midi =
        file([
          [
            {0, {:pitch_bend, 0, -400}},
            {0, {:note_on, 0, 69, 100}},
            {@division, {:pitch_bend, 0, 8_191}},
            {@division, {:note_off, 0, 69, 0}}
          ]
        ])

      [{_beat, voice}] = Midi.to_score(midi).notes

      assert voice.freq < 440.0
      assert Curve.at(voice.curves.freq, 0.0) == 1.0

      assert_in_delta Curve.at(voice.curves.freq, 1.0) * voice.freq,
                      440.0 * :math.pow(2.0, 2 / 12.0),
                      0.5
    end

    test "a dense bend is thinned to the point count asked for" do
      bends = for tick <- 1..60, do: {8, {:pitch_bend, 0, tick * 100}}

      midi =
        file([
          [{0, {:note_on, 0, 60, 64}}] ++ bends ++ [{@division, {:note_off, 0, 60, 0}}]
        ])

      [{_beat, voice}] = Midi.to_score(midi, bend_points: 6).notes

      assert length(voice.curves.freq) <= 6
    end
  end

  describe "the whole way through" do
    test "a file becomes a score that renders to audio" do
      midi =
        file([
          [
            {0, {:tempo, 500_000}},
            {0, {:note_on, 0, 60, 100}},
            {@division, {:note_off, 0, 60, 0}},
            {0, {:note_on, 0, 64, 100}},
            {@division, {:note_off, 0, 64, 0}},
            {0, {:note_on, 0, 67, 100}},
            {@division, {:note_off, 0, 67, 0}}
          ]
        ])

      pcm =
        midi
        |> Midi.to_score(default: Voice.new(shape: :saw, gain: 0.8))
        |> Score.render(44_100)

      assert byte_size(pcm) > 0
      assert pcm |> then(&for(<<s::16-signed-little <- &1>>, do: abs(s))) |> Enum.max() > 1_000
    end

    test "an empty file gives an empty score rather than falling over" do
      score = Midi.to_score(file([[]]))

      assert score.notes == []
      assert Score.render(score, 44_100) |> byte_size() > 0
    end
  end

  describe "writing a file" do
    setup do
      {:ok, score} =
        Source.parse("""
        part(bpm: 120, synth: Kit.voice(%{note: "c3", shape: :saw}, 0.5))
        |> play(:c3, 1) |> play(:e3, 1) |> play(:g3, 2)
        """)

      {:ok, score: score}
    end

    test "it is a format 0 file with one track", %{score: score} do
      assert <<"MThd", 6::32, 0::16, 1::16, 480::16, "MTrk", _rest::binary>> = Midi.encode(score)
    end

    test "what is written reads back as the notes that went in", %{score: score} do
      notes = score |> Midi.encode() |> Midi.parse!() |> Midi.notes()

      assert Enum.map(notes, & &1.note) == [48, 52, 55]
      assert Enum.map(notes, & &1.beat) == [0.0, 1.0, 2.0]
      assert Enum.all?(notes, &(&1.velocity > 0))
    end

    test "the tempo goes with it", %{score: score} do
      read = score |> Midi.encode() |> Midi.parse!() |> Midi.to_score(default: Voice.new())

      assert read.bpm == 120.0
    end

    test "the channel asked for is the channel written", %{score: score} do
      notes = score |> Midi.encode(channel: 10) |> Midi.parse!() |> Midi.notes()

      assert Enum.all?(notes, &(&1.channel == 9))
    end

    test "a name is written where a reader will find it", %{score: score} do
      %{tracks: [track]} = score |> Midi.encode(name: "a tune") |> Midi.parse!()

      assert Enum.any?(track, &match?({_at, {:track_name, "a tune"}}, &1))
    end

    test "an empty score is a file with nothing in it rather than a failure" do
      read = Score.new(bpm: 100, beats: 4) |> Midi.encode() |> Midi.parse!()

      assert Midi.notes(read) == []
    end

    test "a long piece keeps its delta times, which need more than one byte", %{score: score} do
      far = Score.add(score, 400.0, Voice.new(shape: :sine, freq: 440.0))
      notes = far |> Midi.encode() |> Midi.parse!() |> Midi.notes()

      assert Enum.any?(notes, &(&1.beat == 400.0)),
             "a beat past 127 ticks needs a multi-byte delta"
    end

    test "write! puts it on disk", %{score: score} do
      path =
        Path.join(System.tmp_dir!(), "tuning_fork_test_#{System.unique_integer([:positive])}.mid")

      on_exit(fn -> File.rm(path) end)

      assert :ok = Midi.write!(score, path)
      assert Midi.read!(path) |> Midi.notes() |> length() == 3
    end
  end
end

defmodule TuningFork.Composer.ArrangementTest do
  use ExUnit.Case, async: true

  alias TuningFork.Composer.Arrangement
  alias TuningFork.Composer.Arrangement.{Bake, Clip, Flatten, Json, Render, Track}
  alias TuningFork.{Mixer, Song}

  @moduletag :tmp_dir
  @rate 8_000

  defp every_kind do
    Arrangement.new(
      name: "every kind",
      bpm: 120,
      key: %{"tonic" => "D", "mode" => "minor"},
      sections: [%{name: "a", bar: 1, bars: 2}, %{name: "b", bar: 3, bars: 1}],
      markers: [%{name: "drop", bar: 3, beat: 2.0}],
      extra: %{"written_by" => "test"},
      tracks: [
        Track.new(
          name: "Drums",
          instrument: "kick",
          gain_db: -3.0,
          extra: %{"studio_instrument" => "kick"},
          clips: [
            Clip.new(
              kind: :steps,
              beats: 8.0,
              step: 1.0,
              steps: %{"kick" => "x...", "snare" => "..x."}
            )
          ]
        ),
        Track.new(
          name: "Bass",
          instrument: "bass",
          pan: -0.5,
          send: 0.2,
          mono: true,
          clips: [
            Clip.new(kind: :pattern, beats: 4.0, pattern: "x-o.", pitches: [38, 41]),
            Clip.new(
              kind: :notes,
              bar: 2,
              beats: 4.0,
              loop_beats: 2.0,
              notes: [%{beat: 0.5, pitch: 45, length: 1.0, velocity: 0.6, sound: nil}]
            ),
            Clip.new(kind: :pattern, bar: 3, beats: 4.0, pattern: "x...", chords: [[50, 53, 57]])
          ]
        ),
        Track.new(
          name: "Sketches",
          instrument: "piano",
          mute: true,
          clips: [
            Clip.new(kind: :strudel, beats: 4.0, strudel: ~S|note("c3 e3")|),
            Clip.new(kind: :loop, bar: 2, beats: 4.0, loop: "play 60"),
            Clip.new(kind: :recording, bar: 3, beats: 2.0, recording: "rain.wav", offset: 0.5)
          ]
        )
      ]
    )
  end

  defp pcm({:ok, stems}), do: Enum.map(stems, & &1.pcm)

  defp note_at_bar_two do
    Arrangement.new(
      bpm: 120,
      bars: 3,
      tracks: [
        Track.new(
          name: "lead",
          instrument: "lead",
          clips: [
            Clip.new(
              kind: :notes,
              bar: 2,
              beats: 1.0,
              notes: [%{beat: 0.0, pitch: 69, length: 0.5, velocity: 1.0, sound: nil}]
            )
          ]
        )
      ]
    )
  end

  describe "JSON" do
    test "reads back what it writes, every kind of clip included" do
      arrangement = every_kind()

      assert arrangement |> Json.to_map() |> JSON.encode!() |> JSON.decode!() |> Json.from_map() ==
               {:ok, arrangement}
    end

    test "reads note names as the MIDI notes they are" do
      assert Json.pitch("C4") == {:ok, 60}
      assert Json.pitch("fs3") == {:ok, 54}
      assert Json.pitch("Bb2") == {:ok, 46}
    end
  end

  describe "rendering" do
    test "a note sounds from the bar its clip starts on, and not before" do
      {:ok, [stem]} = Render.stems(note_at_bar_two(), rate: @rate)
      bar_frames = round(2.0 * @rate)
      bytes = bar_frames * Mixer.bytes_per_frame(2)
      <<before::binary-size(^bytes), from_bar_two::binary>> = stem.pcm

      assert Mixer.silent?(before)
      refute Mixer.silent?(from_bar_two)
    end

    test "a pattern played as notes sounds the same as the pattern" do
      arrangement = %{every_kind() | tracks: Enum.take(every_kind().tracks, 2)}
      {:ok, flattened} = Flatten.with_notes(arrangement)

      assert Enum.all?(flattened.tracks, fn track ->
               Enum.all?(track.clips, &(&1.kind == :notes))
             end)

      assert pcm(Render.stems(flattened, rate: @rate)) ==
               pcm(Render.stems(arrangement, rate: @rate))
    end
  end

  describe "a baked bundle" do
    test "reads back, validates, and times its sections and markers by the bar", %{tmp_dir: dir} do
      arrangement = %{every_kind() | tracks: Enum.take(every_kind().tracks, 2)}

      assert {:ok, song} = Bake.bake(arrangement, dir, rate: @rate, playable: ["drums"])
      assert {:ok, read} = Song.read(dir)
      assert Song.validate(read, dir: dir) == :ok

      assert Enum.map(read.sections, &{&1.name, &1.start_s, &1.end_s}) == [
               {"a", 0.0, 4.0},
               {"b", 4.0, 6.0}
             ]

      assert read.extra["markers"] == [
               %{"name" => "drop", "bar" => 3, "beat" => 2.0, "at_s" => 5.0}
             ]

      assert song.backing == "backing.wav"
    end

    test "charts a playable drum stem's hits by bar and beat", %{tmp_dir: dir} do
      arrangement = %{every_kind() | tracks: Enum.take(every_kind().tracks, 1)}

      {:ok, song} = Bake.bake(arrangement, dir, rate: @rate, playable: ["drums"])
      hits = song.stems["drums"]["hits"]

      assert Enum.map(hits, &{&1["bar"], &1["beat"], &1["kind"]}) ==
               [{1, 1.0, "kick"}, {1, 3.0, "snare"}, {2, 1.0, "kick"}, {2, 3.0, "snare"}]
    end
  end
end

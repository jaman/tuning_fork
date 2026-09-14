defmodule TuningFork.ComposerTest do
  use ExUnit.Case, async: true

  alias TuningFork.Composer
  alias TuningFork.Composer.{Json, Source, Track}

  defp project(opts \\ []), do: Composer.new(opts)

  defp with_track(project, opts \\ []) do
    Composer.add_track(project, Keyword.merge([kind: :drum, sound: "kick"], opts))
  end

  defp steps(project, index), do: Composer.track(project, index).steps

  defp run(source) do
    source
    |> Code.eval_string()
    |> elem(0)
  end

  describe "the shape of the grid" do
    test "four beats of four is sixteen steps" do
      assert Composer.steps_per_bar(project()) == 16
    end

    test "three of eight is twenty-four" do
      assert Composer.steps_per_bar(project(meter: 3, division: 8)) == 24
    end

    test "a step is as long as the division says" do
      assert Composer.step_beats(project(division: 4)) == 0.25
      assert_in_delta Composer.step_beats(project(division: 3)), 1 / 3, 0.0001
    end

    test "the piece is bars times beats to a bar" do
      assert Composer.beats(project(bars: 4, meter: 3)) == 12
    end

    test "changing the meter brings every track with it" do
      wide = project() |> with_track() |> with_track() |> Composer.set(:meter, 3)

      assert length(steps(wide, 0)) == 12
      assert length(steps(wide, 1)) == 12
    end

    test "growing a track fills with rests and keeps what was there" do
      one = project() |> with_track() |> Composer.toggle_step(0, 0)
      wider = Composer.set(one, :meter, 8)

      assert length(steps(wider, 0)) == 32
      assert hd(steps(wider, 0)) == 1
      assert Enum.count(steps(wider, 0), &(&1 == 0)) == 31
    end

    test "shrinking loses what was past the end, which is the honest outcome" do
      one = project() |> with_track() |> Composer.toggle_step(0, 15)
      narrow = Composer.set(one, :meter, 2)

      assert length(steps(narrow, 0)) == 8
      assert Enum.all?(steps(narrow, 0), &(&1 == 0))
    end
  end

  describe "settings" do
    test "each one is taken and kept" do
      p =
        project()
        |> Composer.set(:bpm, 140)
        |> Composer.set(:bars, 4)
        |> Composer.set(:root, :c3)
        |> Composer.set(:scale, :blues)
        |> Composer.set(:gain, 0.3)

      assert p.bpm == 140
      assert p.bars == 4
      assert p.root == :c3
      assert p.scale == :blues
      assert p.gain == 0.3
    end

    test "a string becomes what the field needs, because a browser sends strings" do
      p = project() |> Composer.set(:bpm, "132") |> Composer.set(:scale, "dorian")

      assert p.bpm == 132
      assert p.scale == :dorian
    end

    test "nonsense leaves the setting as it was rather than raising or inventing a value" do
      assert Composer.set(project(), :bpm, "not a tempo").bpm == project().bpm
      assert Composer.set(project(), :gain, "loud").gain == project().gain
      assert Composer.set(project(), :bars, %{}).bars == project().bars
      assert Composer.set(project(), :nonsense, 1) == project()
    end

    test "a half-typed number does not silence the piece or stall the tempo" do
      typing = project() |> Composer.set(:gain, "") |> Composer.set(:bpm, "1")

      assert typing.gain == project().gain, "an empty box should not mean silence"
      assert typing.bpm == 1
    end

    test "counts are held at one and levels between zero and one" do
      assert Composer.set(project(), :bars, 0).bars == 1
      assert Composer.set(project(), :gain, 5.0).gain == 1.0
      assert Composer.set(project(), :gain, -1.0).gain == 0.0
    end
  end

  describe "tracks" do
    test "added at the end, the width of the grid" do
      p = project() |> with_track() |> with_track(sound: "snare")

      assert Composer.track_count(p) == 2
      assert Composer.track(p, 1).sound == "snare"
      assert length(steps(p, 1)) == 16
    end

    test "removed by position" do
      p = project() |> with_track() |> with_track(sound: "snare") |> Composer.remove_track(0)

      assert Composer.track_count(p) == 1
      assert Composer.track(p, 0).sound == "snare"
    end

    test "moved among the others" do
      p =
        project()
        |> with_track(sound: "kick")
        |> with_track(sound: "snare")
        |> Composer.move_track(1, -1)

      assert Composer.track(p, 0).sound == "snare"
    end

    test "moving past either end does nothing rather than losing one" do
      p = project() |> with_track() |> Composer.move_track(0, -1) |> Composer.move_track(0, 1)

      assert Composer.track_count(p) == 1
    end

    test "becoming a drum flattens degrees to plain hits" do
      p =
        project()
        |> with_track(kind: :pitched, sound: "bass")
        |> Composer.set_step(0, 0, 4)
        |> Composer.update_track(0, kind: :drum)

      assert hd(steps(p, 0)) == 1
    end

    test "muting and bringing it back" do
      p = project() |> with_track() |> Composer.toggle_mute(0)

      assert Composer.track(p, 0).muted
      refute Composer.toggle_mute(p, 0) |> Composer.track(0) |> Map.get(:muted)
    end

    test "cleared keeps the track and empties the steps" do
      p =
        project()
        |> with_track()
        |> Composer.toggle_step(0, 0)
        |> Composer.clear_track(0)

      assert Composer.track_count(p) == 1
      assert Enum.all?(steps(p, 0), &(&1 == 0))
    end

    test "an edit to a track that is not there changes nothing" do
      p = project() |> with_track()

      assert Composer.toggle_step(p, 9, 0) == p
      assert Composer.remove_track(p, 9) == p
    end
  end

  describe "steps" do
    test "toggled on and off" do
      p = project() |> with_track() |> Composer.toggle_step(0, 3)

      assert Enum.at(steps(p, 0), 3) == 1
      assert p |> Composer.toggle_step(0, 3) |> steps(0) |> Enum.at(3) == 0
    end

    test "walked up the scale and off the top" do
      p = project(scale: :minor_pentatonic) |> with_track(kind: :pitched, sound: "bass")
      highest = length(Composer.scale(p))

      walked = Enum.reduce(1..highest, p, fn _n, acc -> Composer.cycle_step(acc, 0, 0, 1) end)

      assert Enum.at(steps(walked, 0), 0) == highest
      assert walked |> Composer.cycle_step(0, 0, 1) |> steps(0) |> Enum.at(0) == 0
    end

    test "walked down and off the bottom" do
      p =
        project()
        |> with_track(kind: :pitched, sound: "bass")
        |> Composer.set_step(0, 0, 1)
        |> Composer.cycle_step(0, 0, -1)

      assert Enum.at(steps(p, 0), 0) == 0
    end

    test "set outright, clamped to what the scale holds" do
      p = project() |> with_track(kind: :pitched, sound: "bass")
      highest = length(Composer.scale(p))

      assert p |> Composer.set_step(0, 0, 3) |> steps(0) |> Enum.at(0) == 3
      assert p |> Composer.set_step(0, 0, 999) |> steps(0) |> Enum.at(0) == highest
    end
  end

  describe "how long a note is held" do
    test "a note stated longer is written as a pair" do
      p =
        project()
        |> with_track(kind: :pitched, sound: "bass")
        |> Composer.set_step(0, 0, 1)
        |> Composer.set_length(0, 0, 4)

      assert Enum.at(steps(p, 0), 0) == {1, 4}
    end

    test "it stops where the next note starts" do
      p =
        project()
        |> with_track(kind: :pitched, sound: "bass")
        |> Composer.set_step(0, 0, 1)
        |> Composer.set_step(0, 3, 2)
        |> Composer.set_length(0, 0, 10)

      assert Enum.at(steps(p, 0), 0) == {1, 3}
    end

    test "lengthening works from anywhere inside a note, not only its head" do
      p =
        project()
        |> with_track(kind: :pitched, sound: "bass")
        |> Composer.set_step(0, 0, 1)
        |> Composer.set_length(0, 0, 3)
        |> Composer.set_length(0, 2, 5)

      assert Enum.at(steps(p, 0), 0) == {1, 5}
    end

    test "grown and shrunk by one" do
      p =
        project()
        |> with_track(kind: :pitched, sound: "bass")
        |> Composer.set_step(0, 0, 1)
        |> Composer.grow(0, 0, 1)
        |> Composer.grow(0, 0, 1)

      assert Enum.at(steps(p, 0), 0) == {1, 3}
      assert p |> Composer.grow(0, 0, -1) |> steps(0) |> Enum.at(0) == {1, 2}
    end

    test "shrinking to one goes back to the short form" do
      p =
        project()
        |> with_track(kind: :pitched, sound: "bass")
        |> Composer.set_step(0, 0, 1)
        |> Composer.set_length(0, 0, 4)
        |> Composer.set_length(0, 0, 1)

      assert Enum.at(steps(p, 0), 0) == 1
    end

    test "lengthening an empty step does nothing" do
      p = project() |> with_track(kind: :pitched) |> Composer.set_length(0, 5, 4)

      assert Enum.all?(steps(p, 0), &(&1 == 0))
    end

    test "the steps a held note covers are known, for a front end to draw" do
      track =
        Track.new([kind: :pitched, steps: [{1, 3}, 0, 0, 1, 0, 0, 0, 0]], 8)

      assert Track.held(track) == [false, true, true, false, false, false, false, false]
    end
  end

  describe "what it writes" do
    test "nothing at all when there is nothing to hear" do
      assert Source.to_source(project()) == ""
      assert project() |> with_track() |> Source.to_source() == ""
    end

    test "a muted track is left out" do
      p =
        project()
        |> with_track(sound: "kick")
        |> Composer.toggle_step(0, 0)
        |> with_track(sound: "snare")
        |> Composer.toggle_step(1, 4)
        |> Composer.toggle_mute(1)

      source = Source.to_source(p)

      assert source =~ "drum_kick"
      refute source =~ "drum_snare"
    end

    test "it is formatted Elixir that parses, and settles under formatting" do
      source = Composer.demo() |> Source.to_source()

      assert {:ok, _ast} = Code.string_to_quoted(source)
      assert source == source |> Code.format_string!() |> IO.iodata_to_binary()
    end

    test "it aliases only what it uses" do
      drums = Composer.demo() |> Composer.remove_track(3) |> Source.to_source()

      assert drums =~ "alias TuningFork.{Gm, Score, Voice}"
      refute drums =~ "Sample"
    end

    test "two tracks on one instrument get names of their own" do
      p =
        project()
        |> with_track(sound: "kick")
        |> Composer.toggle_step(0, 0)
        |> with_track(sound: "kick")
        |> Composer.toggle_step(1, 4)

      source = Source.to_source(p)

      assert source =~ "drum_kick ="
      assert source =~ "drum_kick_2 ="
      assert source =~ "from_parts([drum_kick, drum_kick_2]"
    end

    test "the step length is a division, never a rounded decimal" do
      p =
        project(division: 3)
        |> with_track()
        |> Composer.toggle_step(0, 0)

      source = Source.to_source(p)

      assert source =~ "1 / 3"
      refute source =~ "0.333"
    end

    test "a note held longer says so, and a short one leaves it to the track" do
      p =
        project()
        |> with_track(kind: :pitched, sound: "bass", ring: 2.0)
        |> Composer.set_step(0, 0, 1)
        |> Composer.set_length(0, 0, 4)
        |> Composer.set_step(0, 8, 1)

      source = Source.to_source(p)

      assert source =~ "release: 4 / 4"
      assert source =~ "release: 2.0"
    end

    test "the score it binds is named after the project" do
      p = project(name: "groove") |> with_track() |> Composer.toggle_step(0, 0)

      assert Source.to_source(p) =~ "groove = Score.from_parts"
    end

    test "a name that would not compile falls back" do
      p = project(name: "not a name!") |> with_track() |> Composer.toggle_step(0, 0)

      assert {:ok, _ast} = Code.string_to_quoted(Source.to_source(p))
    end

    test "the last line is the caller's to choose" do
      p = Composer.demo()

      assert Source.to_source(p, output: :score) =~ ~r/song\s*$/
      assert Source.to_source(p, output: :kino) =~ "Kino.Audio.new(:wav)"
      assert Source.to_source(p, output: :wav) =~ "Wav.write!"
    end
  end

  describe "what it plays" do
    test "a score with a part for every audible track" do
      score = Composer.demo() |> Composer.to_score()

      assert score.notes != []
      assert score.bpm == 96.0
    end

    test "muted tracks are not in it" do
      full = Composer.demo() |> Composer.to_score()
      less = Composer.demo() |> Composer.toggle_mute(0) |> Composer.to_score()

      assert length(less.notes) < length(full.notes)
    end

    test "it renders to audible sound" do
      pcm = Composer.demo() |> Composer.to_score() |> TuningFork.Score.render(44_100)

      assert TuningFork.Mixer.peak(pcm) > 1_000
      assert TuningFork.Mixer.clipped(pcm) == 0
    end

    test "playing it and running what it writes agree on the length" do
      p = Composer.demo()

      played = p |> Composer.to_score() |> TuningFork.Score.render(44_100)
      written = p |> Source.to_source() |> run() |> TuningFork.Score.render(44_100)

      assert byte_size(played) == byte_size(written)
    end

    test "and on the notes" do
      p = Composer.demo() |> Composer.set(:bpm, 120)

      played = p |> Composer.to_score() |> TuningFork.Score.render(44_100)
      written = p |> Source.to_source() |> run() |> TuningFork.Score.render(44_100)

      assert TuningFork.Mixer.peak(played) == TuningFork.Mixer.peak(written)
    end
  end

  describe "as plain maps" do
    test "a round trip changes nothing" do
      p =
        Composer.demo()
        |> Composer.set_length(3, 0, 6)
        |> Composer.toggle_mute(2)
        |> Composer.set(:meter, 3)

      assert p |> Json.to_map() |> Json.from_map() == p
    end

    test "and neither does what it writes" do
      p = Composer.demo()

      assert Source.to_source(Json.from_map(Json.to_map(p))) == Source.to_source(p)
    end

    test "a map with nothing in it is a composition with nothing in it" do
      assert Json.from_map(%{}) == Composer.new()
      assert Json.from_map("not a map") == Composer.new()
    end

    test "an unknown scale falls back rather than making an atom of it" do
      assert Json.from_map(%{"scale" => "not_a_scale"}).scale == :minor_pentatonic
    end

    test "steps survive in both their forms" do
      p =
        Composer.new()
        |> Composer.add_track(kind: :pitched, sound: "bass")
        |> Composer.set_step(0, 0, 3)
        |> Composer.set_length(0, 0, 4)
        |> Composer.set_step(0, 8, 2)

      back = p |> Json.to_map() |> Json.from_map()

      assert Enum.at(Composer.track(back, 0).steps, 0) == {3, 4}
      assert Enum.at(Composer.track(back, 0).steps, 8) == 2
    end
  end
end

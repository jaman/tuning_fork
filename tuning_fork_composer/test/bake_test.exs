defmodule TuningFork.ComposerBakeTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Composer, Midi, Song, Wav}

  @moduletag :tmp_dir

  defp project do
    Composer.new(bpm: 240, bars: 1, name: "test", root: :a2)
    |> Composer.add_track(kind: :drum, sound: "kick", gain: 0.9)
    |> Composer.toggle_step(0, 0)
    |> Composer.add_track(kind: :pitched, sound: "bass", gain: 0.5)
    |> Composer.toggle_step(1, 0)
  end

  describe "a baked bundle" do
    test "holds every file the manifest names", %{tmp_dir: dir} do
      assert {:ok, song} = Composer.Bake.bake(project(), dir)

      for file <- ~w(song.json mix.wav score.mid stems/kick.wav stems/bass.wav) do
        assert File.exists?(Path.join(dir, file)), "#{file} was not written"
      end

      assert song.bpm == 240.0
      assert song.duration_s == 1.0
      assert song.stems |> Map.keys() |> Enum.sort() == ["bass", "kick"]
      assert song.key == %{"tonic" => "A", "mode" => "minor_pentatonic"}
    end

    test "reads back and validates", %{tmp_dir: dir} do
      {:ok, song} = Composer.Bake.bake(project(), dir)

      assert {:ok, read} = Song.read(dir)
      assert read.stems == song.stems
      assert read.duration_s == song.duration_s
      assert read.sections == song.sections
      assert Song.validate(read, dir: dir) == :ok
    end

    test "has every recording as long as the mix", %{tmp_dir: dir} do
      {:ok, _song} = Composer.Bake.bake(project(), dir)

      sizes =
        for file <- Path.wildcard(Path.join(dir, "**/*.wav")) do
          {pcm, rate, channels} = Wav.read!(file)
          {rate, channels, byte_size(pcm)}
        end

      assert length(Enum.uniq(sizes)) == 1
      assert {44_100, 2, 176_400} = hd(sizes)
    end

    test "scores a track per stem, drums on channel ten", %{tmp_dir: dir} do
      {:ok, _song} = Composer.Bake.bake(project(), dir)

      midi = Midi.read!(Path.join(dir, "score.mid"))
      notes = Midi.notes(midi)

      assert length(midi.tracks) == 3
      assert Enum.any?(notes, &(&1.channel == 9 and &1.note == 36))
      assert Enum.any?(notes, &(&1.channel == 0 and &1.note == 45))
    end

    test "takes the rate and channel count a game asks for", %{tmp_dir: dir} do
      {:ok, song} = Composer.Bake.bake(project(), dir, rate: 22_050, channels: 1)

      assert song.sample_rate == 22_050
      assert {_pcm, 22_050, 1} = Wav.read!(Path.join(dir, "mix.wav"))
      assert Song.validate(song, dir: dir) == :ok
    end

    test "leaves a backing when some stems are playable", %{tmp_dir: dir} do
      {:ok, song} = Composer.Bake.bake(project(), dir, playable: ["bass"])

      assert song.playable == ["bass"]
      assert song.backing == "backing.wav"
      assert {backing, 44_100, 2} = Wav.read!(Path.join(dir, "backing.wav"))
      assert {kick, 44_100, 2} = Wav.read!(Path.join(dir, "stems/kick.wav"))
      assert backing == kick
      assert Song.validate(song, dir: dir) == :ok
    end

    test "a section is where the song says it is", %{tmp_dir: dir} do
      arranged =
        project()
        |> Composer.add_section("intro", 1, tracks: [0])
        |> Composer.add_section("verse", 1)

      {:ok, song} = Composer.Bake.bake(arranged, dir)

      assert [intro, verse] = song.sections
      assert intro.name == "intro"
      assert intro.start_s == 0.0
      assert intro.end_s == 1.0
      assert verse.name == "verse"
      assert verse.start_s == 1.0
      assert verse.end_s == 2.0

      assert song.duration_s == 2.0
      assert Song.validate(song, dir: dir) == :ok

      {:ok, {bass, 44_100, 2}} = Song.pcm(song, "bass", dir)
      silent = :binary.copy(<<0>>, 44_100 * 4)

      assert binary_part(bass, 0, byte_size(silent)) == silent
      refute binary_part(bass, byte_size(silent), byte_size(silent)) == silent

      {:ok, piece} = Song.to_piece(song, dir)
      assert Map.keys(piece.sections) == ["intro", "verse"]
      assert %{"bass" => {:pcm, ^silent, 44_100, 2}} = piece.sections["intro"]
    end

    test "becomes a piece a game can cue", %{tmp_dir: dir} do
      {:ok, song} = Composer.Bake.bake(project(), dir)

      assert {:ok, piece} = Song.to_piece(song, dir)
      assert piece.bpm == 240.0
      assert piece.beats_per_bar == 4
      assert piece.layers == ["bass", "kick"]
      assert [section] = song.sections
      assert section.name == "test"
      assert section.start_s == 0.0
    end
  end

  describe "what is not a stem" do
    test "a muted track is left out", %{tmp_dir: dir} do
      muted = project() |> Composer.toggle_mute(1)
      {:ok, song} = Composer.Bake.bake(muted, dir)

      refute Map.has_key?(song.stems, "bass")
      assert Map.keys(song.stems) == ["kick"]
      assert Song.validate(song, dir: dir) == :ok
    end

    test "two tracks sharing a sound get names of their own" do
      doubled =
        project()
        |> Composer.add_track(kind: :drum, sound: "kick", gain: 0.4)
        |> Composer.toggle_step(2, 4)

      names = doubled |> Composer.Song.stems() |> Enum.map(&elem(&1, 0))

      assert "kick-0" in names
      assert "kick-2" in names
      assert "bass" in names
    end
  end

  describe "the task" do
    test "bakes a project file into a directory", %{tmp_dir: dir} do
      project_file = Path.join(dir, "song.json")
      File.write!(project_file, JSON.encode!(Composer.Json.to_map(project())))
      out = Path.join(dir, "bundle")

      Mix.Tasks.TuningFork.Bake.run([project_file, "--out", out, "--quiet"])

      assert {:ok, song} = Song.read(out)
      assert song.id == "test"
      assert File.exists?(Path.join(out, "mix.wav"))
      assert Song.validate(song, dir: out) == :ok
    end

    test "the task takes the stems a player gets", %{tmp_dir: dir} do
      project_file = Path.join(dir, "song.json")
      File.write!(project_file, JSON.encode!(Composer.Json.to_map(project())))
      out = Path.join(dir, "bundle")

      Mix.Tasks.TuningFork.Bake.run([project_file, "--out", out, "--playable", "bass", "--quiet"])

      assert {:ok, song} = Song.read(out)
      assert song.playable == ["bass"]
      assert song.backing == "backing.wav"
      assert File.exists?(Path.join(out, "backing.wav"))
      assert Song.validate(song, dir: out) == :ok
    end
  end
end

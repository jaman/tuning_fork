defmodule TuningFork.SongTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Song, Wav}

  @moduletag :tmp_dir

  defp song do
    Song.new(
      id: "night",
      title: "Night Harbour",
      bpm: 112,
      time_signature: {4, 4},
      key: %{"tonic" => "D", "mode" => "minor"},
      sample_rate: 8000,
      channels: 1,
      duration_s: 2.0,
      sections: [
        %{name: "intro", start_s: 0.0, end_s: 1.0},
        %{name: "verse", start_s: 1.0, end_s: 2.0}
      ],
      stems: %{"bass" => %{"file" => "stems/bass.wav", "gain" => 0.5}},
      playable: []
    )
  end

  defp write_bundle(dir, song) do
    File.mkdir_p!(Path.join(dir, "stems"))
    pcm = :binary.copy(<<0, 0>>, trunc(Song.duration(song) * song.sample_rate))

    File.write!(
      Path.join(dir, "mix.wav"),
      Wav.encode(pcm, rate: song.sample_rate, channels: song.channels)
    )

    File.write!(
      Path.join(dir, "stems/bass.wav"),
      Wav.encode(pcm, rate: song.sample_rate, channels: song.channels)
    )

    File.write!(
      Path.join(dir, "score.mid"),
      <<"MThd", 6::32, 0::16, 1::16, 480::16, "MTrk", 4::32, 0, 0xFF, 0x2F, 0>>
    )

    :ok = Song.write(song, dir)
    song
  end

  describe "a manifest" do
    test "round trips through maps" do
      original = song()
      round_tripped = original |> Song.to_map() |> Song.from_map()

      assert round_tripped.id == "night"
      assert round_tripped.title == "Night Harbour"
      assert round_tripped.bpm == 112.0
      assert round_tripped.time_signature == {4, 4}
      assert round_tripped.key == %{"tonic" => "D", "mode" => "minor"}
      assert round_tripped.duration_s == 2.0
      assert round_tripped.sections == original.sections
      assert round_tripped.stems["bass"]["gain"] == 0.5
    end

    test "takes atom keys as well as strings" do
      read =
        Song.from_map(%{
          id: "a",
          bpm: 90,
          time_signature: {3, 4},
          stems: %{bass: %{file: "b.wav"}}
        })

      assert read.id == "a"
      assert read.bpm == 90.0
      assert read.time_signature == {3, 4}
      assert read.stems["bass"]["file"] == "b.wav"
    end

    test "falls back to the defaults rather than raising" do
      read =
        Song.from_map(%{
          "bpm" => "fast",
          "channels" => 9,
          "sample_rate" => 0,
          "sections" => "none"
        })

      assert read.bpm == 120.0
      assert read.channels == 2
      assert read.sample_rate == 44_100
      assert read.sections == []
      assert read.format == 1
    end

    test "keeps fields it does not know, so a generator can fill them" do
      read = Song.from_map(%{"id" => "x", "beats" => [0.1, 0.6], "lyrics" => [%{"text" => "la"}]})
      written = Song.to_map(read)

      assert read.extra["beats"] == [0.1, 0.6]
      assert written["beats"] == [0.1, 0.6]
      assert written["lyrics"] == [%{"text" => "la"}]
    end

    test "keeps what it does not know about a stem" do
      read =
        Song.from_map(%{
          "stems" => %{"bass" => %{"file" => "b.wav", "notes" => [%{"pitch" => 38}]}}
        })

      assert read.stems["bass"]["notes"] == [%{"pitch" => 38}]
    end

    test "says nothing is wrong with a song that is only described" do
      assert Song.validate(song()) == :ok
    end

    test "reports a section that ends before it starts" do
      broken = %{song() | sections: [%{name: "bad", start_s: 2.0, end_s: 1.0}]}
      assert {:error, problems} = Song.validate(broken)
      assert Enum.any?(problems, &(&1 =~ "ends before it starts"))
    end

    test "reports a playable stem that is not a stem" do
      broken = %{song() | playable: ["vocals"]}
      assert {:error, problems} = Song.validate(broken)
      assert Enum.any?(problems, &(&1 =~ "not a stem"))
    end

    test "is not the format this library writes" do
      assert {:error, problems} = Song.validate(%{song() | format: 2})
      assert Enum.any?(problems, &(&1 =~ "format 2"))
    end
  end

  describe "a bundle on disk" do
    test "writes a manifest and reads it back", %{tmp_dir: dir} do
      original = write_bundle(dir, song())

      assert File.exists?(Path.join(dir, "song.json"))
      assert {:ok, read} = Song.read(dir)
      assert read.stems == original.stems
      assert Song.read!(Path.join(dir, "song.json")).id == "night"
    end

    test "writes a manifest a person can read and diff", %{tmp_dir: dir} do
      write_bundle(dir, song())
      body = File.read!(Path.join(dir, "song.json"))

      assert body =~ ~s("id": "night")
      assert body =~ ~s("duration_s": 2.0)
      assert length(String.split(body, "\n")) > 10
    end

    test "checks its files against the manifest", %{tmp_dir: dir} do
      written = write_bundle(dir, song())

      assert Song.validate(written, dir: dir) == :ok
      File.rm!(Path.join(dir, "stems/bass.wav"))
      assert {:error, problems} = Song.validate(written, dir: dir)
      assert Enum.any?(problems, &(&1 =~ "is missing" or &1 =~ "enoent"))
    end

    test "reports a recording that is not as long as the song says", %{tmp_dir: dir} do
      written = write_bundle(dir, song())
      short = Wav.encode(<<0, 0>>, rate: 8000, channels: 1)
      File.write!(Path.join(dir, "stems/bass.wav"), short)

      assert {:error, problems} = Song.validate(written, dir: dir)
      assert Enum.any?(problems, &(&1 =~ "not as long"))
    end

    test "reads a stem's recording", %{tmp_dir: dir} do
      written = write_bundle(dir, song())

      assert {:ok, {pcm, 8000, 1}} = Song.pcm(written, "bass", dir)
      assert byte_size(pcm) == 32_000
      assert {:error, {:unknown_stem, "vocals"}} = Song.pcm(written, "vocals", dir)
    end

    test "becomes a piece, section by section", %{tmp_dir: dir} do
      written = write_bundle(dir, song())

      assert {:ok, piece} = Song.to_piece(written, dir)
      assert piece.bpm == 112.0
      assert piece.beats_per_bar == 4
      assert piece.render == :ready
      assert piece.layers == ["bass"]
      assert Map.keys(piece.sections) == ["intro", "verse"]

      assert %{"bass" => {:pcm, pcm, 8000, 1}} = piece.sections["intro"]
      assert byte_size(pcm) == 16_000
    end

    test "names two sections called the same apart", %{tmp_dir: dir} do
      chorus = %{name: "chorus", start_s: 0.0, end_s: 1.0}
      again = %{name: "chorus", start_s: 1.0, end_s: 2.0}
      with_dupes = write_bundle(dir, %{song() | sections: [chorus, again]})

      assert {:ok, piece} = Song.to_piece(with_dupes, dir)
      assert Map.keys(piece.sections) == ["chorus", "chorus-2"]
    end

    test "becomes one piece when it has no sections", %{tmp_dir: dir} do
      without = write_bundle(dir, %{song() | sections: []})

      assert {:ok, piece} = Song.to_piece(without, dir)
      assert Map.keys(piece.sections) == ["night"]
    end
  end
end

defmodule TuningFork.Composer.Arrangement.Bake do
  @moduledoc """
  Renders an arrangement to a song bundle: `mix.wav`, a WAV per audible track under `stems/`,
  `backing.wav` when some stems are playable, `score.mid`, and the `song.json` that names
  them, as `SONG_BUNDLES.md` describes.

      {:ok, song} = Bake.bake(arrangement, "priv/music/river", rate: 48_000, playable: ["lead"])

  Every recording is the whole song long at one rate and channel count. The sections are the
  arrangement's, with the second each starts and ends on. The markers are kept under
  `"markers"` with their `at_s`. Every stem with notes carries them: a pitched stem as
  `"notes"` and a drum stem as `"hits"`, each with its `bar` (from 1) and `beat` (from 1.0
  within the bar), so a game can chart any stem. The manifest is checked against the files
  before it is written, so a bundle that exists is one that reads back.

  `score.mid` is a format 1 file: a conductor track with the tempo and time signature, then
  a track per stem's pitched notes and a track per stem's drums on channel 10, each note at
  its exact pitch, length and velocity.
  """

  alias TuningFork.Composer
  alias TuningFork.Composer.Arrangement
  alias TuningFork.Composer.Arrangement.{Render, Voices}
  alias TuningFork.{Envelope, Midi, Mixer, Score, Song, Voice, Wav}

  @rate 44_100
  @channels 2
  @drum_channel 10
  @hit_kinds %{
    "kick" => "kick",
    "snare" => "snare",
    "clap" => "snare",
    "hat" => "hat",
    "open_hat" => "hat",
    "tom" => "tom",
    "ride" => "cymbal",
    "crash" => "cymbal"
  }

  @doc """
  Render `arrangement` into the directory `dir`, creating it.

  ## Options

    * `:rate` — samples per second, default 44100
    * `:channels` — 1 or 2, default 2
    * `:playable` — the stems a game gives to the player, by name; the rest is `backing.wav`
    * `:id`, `:title` — the bundle's id and title, default the arrangement's name
    * `:sources` — where recordings with relative paths are read from, default the working
      directory

  Returns `{:ok, song}` once every file is written and the manifest agrees with them.
  """
  @spec bake(Arrangement.t(), Path.t(), keyword()) :: {:ok, Song.t()} | {:error, term()}
  def bake(%Arrangement{} = arrangement, dir, opts \\ []) do
    rate = Keyword.get(opts, :rate, @rate)
    channels = Keyword.get(opts, :channels, @channels)
    playable = Keyword.get(opts, :playable, [])
    render = [rate: rate, channels: channels, dir: Keyword.get(opts, :sources, ".")]

    with {:ok, stems} <- Render.stems(arrangement, render),
         :ok <- playable_known(playable, stems),
         {:ok, charted} <- charted(arrangement, stems) do
      backing = backing(stems, playable)
      song = song(arrangement, charted, playable, backing, rate, channels, opts)

      with :ok <- File.mkdir_p(Path.join(dir, "stems")),
           :ok <- File.write(Path.join(dir, "mix.wav"), wav(Render.mix(stems), rate, channels)),
           :ok <- write_backing(backing, dir, rate, channels),
           :ok <- write_stems(stems, dir, rate, channels),
           :ok <- File.write(Path.join(dir, "score.mid"), midi(arrangement, charted)),
           :ok <- Song.validate(song, dir: dir),
           :ok <- Song.write(song, dir) do
        {:ok, song}
      end
    end
  end

  defp playable_known(playable, stems) do
    names = Enum.map(stems, & &1.name)

    case Enum.reject(playable, &(&1 in names)) do
      [] ->
        :ok

      missing ->
        {:error,
         "#{Enum.join(missing, ", ")} is not a stem; the stems are #{Enum.join(names, ", ")}"}
    end
  end

  defp charted(arrangement, stems) do
    Enum.reduce_while(stems, {:ok, []}, fn stem, {:ok, acc} ->
      case Arrangement.notes(arrangement, stem.track) do
        {:ok, notes} -> {:cont, {:ok, acc ++ [Map.put(stem, :notes, notes)]}}
        error -> {:halt, error}
      end
    end)
  end

  defp backing(_stems, []), do: nil

  defp backing(stems, playable) do
    case for(stem <- stems, stem.name not in playable, do: stem.pcm) do
      [] -> nil
      buffers -> Mixer.mix(buffers)
    end
  end

  defp song(arrangement, charted, playable, backing, rate, channels, opts) do
    Song.new(
      id: Keyword.get(opts, :id, arrangement.name),
      title: Keyword.get(opts, :title, arrangement.name),
      bpm: arrangement.bpm,
      time_signature: {arrangement.metre, 4},
      key: arrangement.key,
      sample_rate: rate,
      channels: channels,
      duration_s: Arrangement.seconds(arrangement),
      sections:
        Enum.map(Arrangement.sections(arrangement), &Map.take(&1, [:name, :start_s, :end_s])),
      stems: Map.new(charted, &stem_entry(arrangement, &1)),
      playable: playable,
      mix: "mix.wav",
      backing: if(backing, do: "backing.wav"),
      score: "score.mid",
      markers: Enum.map(Arrangement.markers(arrangement), &marker_entry/1),
      provenance: %{
        "generator" => "TuningFork.Composer.Arrangement",
        "arrangement" => arrangement.name
      }
    )
  end

  defp stem_entry(arrangement, stem) do
    {drums, pitched} = Enum.split_with(stem.notes, &Voices.drum?(stem.track, &1))

    entry =
      %{
        "file" => "stems/#{stem.name}.wav",
        "gain" => 1.0,
        "muted" => false,
        "instrument" => stem.track.instrument
      }
      |> put_unless_empty("notes", Enum.map(pitched, &note_entry(arrangement, stem.track, &1)))
      |> put_unless_empty("hits", Enum.map(drums, &hit_entry(arrangement, stem.track, &1)))

    {stem.name, entry}
  end

  defp note_entry(arrangement, track, note) do
    {:pitched, instrument} = Voices.source(track, note)

    arrangement
    |> placed(note)
    |> Map.merge(%{
      "end_s" => (note.beat + note.length) * Arrangement.beat_seconds(arrangement),
      "pitch" => note.pitch || Voices.default_pitch(instrument),
      "velocity" => velocity(note)
    })
  end

  defp hit_entry(arrangement, track, note) do
    {:drum, drum} = Voices.source(track, note)

    arrangement
    |> placed(note)
    |> Map.merge(%{
      "kind" => Map.get(@hit_kinds, drum, "perc"),
      "sound" => drum,
      "velocity" => velocity(note)
    })
  end

  defp placed(arrangement, note) do
    bar = floor(note.beat / arrangement.metre)

    %{
      "start_s" => note.beat * Arrangement.beat_seconds(arrangement),
      "bar" => bar + 1,
      "beat" => note.beat - bar * arrangement.metre + 1.0
    }
  end

  defp velocity(note), do: (note.velocity * 127) |> round() |> max(1) |> min(127)

  defp marker_entry(marker),
    do: %{
      "name" => marker.name,
      "bar" => marker.bar,
      "beat" => marker.beat,
      "at_s" => marker.at_s
    }

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, list), do: Map.put(map, key, list)

  defp midi(arrangement, charted) do
    tracks =
      Enum.flat_map(charted, fn stem ->
        {drums, pitched} = Enum.split_with(stem.notes, &Voices.drum?(stem.track, &1))

        midi_track(arrangement, stem, pitched, stem.name, 1) ++
          midi_track(arrangement, stem, drums, stem.name <> " drums", @drum_channel)
      end)

    Midi.encode_tracks(tracks, time_signature: {arrangement.metre, 4})
  end

  defp midi_track(_arrangement, _stem, [], _name, _channel), do: []

  defp midi_track(arrangement, stem, notes, name, channel) do
    score =
      Enum.reduce(
        notes,
        Score.new(bpm: arrangement.bpm, beats: Arrangement.beats(arrangement)),
        fn note, score ->
          Score.add(score, note.beat, midi_voice(arrangement, stem.track, note))
        end
      )

    [{score, name: name, channel: channel}]
  end

  defp midi_voice(arrangement, track, note) do
    seconds = note.length * Arrangement.beat_seconds(arrangement)
    midi = midi_note(track, note)

    Voice.new(
      freq: 440.0 * :math.pow(2.0, (midi - 69) / 12.0),
      gain: note.velocity,
      envelope: Envelope.new(attack: 0.0, decay: 0.0, sustain: 1.0, hold: seconds, release: 0.0)
    )
  end

  defp midi_note(track, note) do
    case Voices.source(track, note) do
      {:drum, drum} -> Composer.drum_note(drum)
      {:pitched, instrument} -> note.pitch || Voices.default_pitch(instrument)
    end
  end

  defp write_stems(stems, dir, rate, channels) do
    Enum.reduce_while(stems, :ok, fn stem, :ok ->
      case File.write(
             Path.join([dir, "stems", stem.name <> ".wav"]),
             wav(stem.pcm, rate, channels)
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp write_backing(nil, _dir, _rate, _channels), do: :ok

  defp write_backing(pcm, dir, rate, channels),
    do: File.write(Path.join(dir, "backing.wav"), wav(pcm, rate, channels))

  defp wav(pcm, rate, channels), do: Wav.encode(pcm, rate: rate, channels: channels)
end

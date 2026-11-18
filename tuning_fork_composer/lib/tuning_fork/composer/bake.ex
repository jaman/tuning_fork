defmodule TuningFork.Composer.Bake do
  @moduledoc """
  Render a composition to a song bundle: `mix.wav`, a WAV per stem, `score.mid`, and the
  `song.json` that names them.

      TuningFork.Composer.Bake.bake(project, "priv/music/night")

  Every file is rendered at one rate and channel count and runs the same length, so a
  section cue mixes stems without resampling or lining anything up. The manifest is checked
  against the files before it is written, so a bundle that exists is one that reads back.

  `score.mid` is a format 1 file: a conductor track with the tempo and time signature, then
  a track per stem, with drum tracks on channel 10.
  """

  alias TuningFork.Composer
  alias TuningFork.Composer.Track
  alias TuningFork.{Midi, Mixer, Score, Song, Wav}

  @rate 44_100
  @channels 2
  @drum_channel 10

  @doc """
  Render `project` into the directory `dir`, creating it.

  ## Options

    * `:rate` — samples per second, default 44100
    * `:channels` — 1 or 2, default 2
    * `:playable` — the stems a game gives to the player, by name; the rest becomes
      `backing.wav`, default `[]`
    * `:id`, `:title`, `:section` — as `TuningFork.Composer.Song.to_song/2`

  Returns `{:ok, song}` once every file is written and the manifest agrees with them.
  """
  @spec bake(Composer.t(), Path.t(), keyword()) :: {:ok, Song.t()} | {:error, term()}
  def bake(%Composer{} = project, dir, opts \\ []) do
    rate = Keyword.get(opts, :rate, @rate)
    channels = Keyword.get(opts, :channels, @channels)
    song = Composer.Song.to_song(project, Keyword.merge(opts, rate: rate, channels: channels))
    stems = render(project, rate, channels)
    backing = backing(stems, song.playable)
    song = if backing, do: %{song | backing: "backing.wav"}, else: song

    mix = project |> Composer.to_score() |> Score.render(rate, channels: channels)

    with :ok <- File.mkdir_p(Path.join(dir, "stems")),
         :ok <- write(Path.join(dir, "mix.wav"), wav(mix, rate, channels)),
         :ok <- write_backing(backing, dir, rate, channels),
         :ok <- write_stems(stems, dir, rate, channels),
         :ok <- write(Path.join(dir, "score.mid"), score(stems, project)),
         :ok <- Song.validate(song, dir: dir),
         :ok <- Song.write(song, dir) do
      {:ok, song}
    end
  end

  defp render(project, rate, channels) do
    for {name, index, track} <- Composer.Song.stems(project) do
      score = Composer.to_score(project, tracks: [index])
      {name, track, score, Score.render(score, rate, channels: channels)}
    end
  end

  defp write_stems(stems, dir, rate, channels) do
    Enum.reduce_while(stems, :ok, fn {name, _track, _score, pcm}, :ok ->
      case write(Path.join([dir, "stems", name <> ".wav"]), wav(pcm, rate, channels)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # What a game hears under a player who is playing the stems in `playable`: everything
  # else, summed. Every stem is a whole pass of the grid at the same rate, so they add up.
  defp backing(_stems, []), do: nil

  defp backing(stems, playable) when is_list(playable) do
    rest =
      stems
      |> Enum.reject(fn {name, _track, _score, _pcm} -> name in playable end)
      |> Enum.map(fn {_name, _track, _score, pcm} -> pcm end)

    case rest do
      [] -> nil
      buffers -> Mixer.mix(buffers)
    end
  end

  defp backing(_stems, _playable), do: nil

  defp write_backing(nil, _dir, _rate, _channels), do: :ok

  defp write_backing(pcm, dir, rate, channels) do
    write(Path.join(dir, "backing.wav"), wav(pcm, rate, channels))
  end

  defp score(stems, project) do
    tracks =
      Enum.map(stems, fn {name, track, score, _pcm} ->
        {midi_score(track, score), name: name, channel: channel(track)}
      end)

    Midi.encode_tracks(tracks, time_signature: {project.meter, 4})
  end

  defp channel(%Track{kind: :drum}), do: @drum_channel
  defp channel(%Track{}), do: 1

  # A drum voice has no pitch of its own, so its recording plays at 440 Hz. On the way to
  # MIDI it takes the General MIDI note of the drum it is — 36 for a kick, 42 for a hat — so
  # a reader on channel 10 sees drums rather than one repeated note.
  defp midi_score(%Track{kind: :drum} = track, %Score{} = score) do
    freq = freq(Composer.drum_note(track.sound))

    %{
      score
      | notes: retune(score.notes, freq),
        layers: Enum.map(score.layers, &%{&1 | notes: retune(&1.notes, freq)})
    }
  end

  defp midi_score(_track, score), do: score

  defp retune(notes, freq),
    do: Enum.map(notes, fn {beat, voice} -> {beat, %{voice | freq: freq}} end)

  defp freq(note), do: 440.0 * :math.pow(2, (note - 69) / 12)

  defp wav(pcm, rate, channels), do: Wav.encode(pcm, rate: rate, channels: channels)

  defp write(path, bytes), do: File.write(path, bytes)
end

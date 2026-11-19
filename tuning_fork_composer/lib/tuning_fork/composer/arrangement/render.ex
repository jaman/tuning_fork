defmodule TuningFork.Composer.Arrangement.Render do
  @moduledoc """
  Renders an arrangement to signed 16-bit little-endian PCM: one stem per audible track, every
  stem the whole song long, and the mix of them.

      {:ok, stems} = Render.stems(arrangement, rate: 48_000)
      mix = Render.mix(stems)

  A stem holds its track's notes, played by `TuningFork.Composer.Arrangement.Voices`, and its
  Strudel, Sonic Pi and recorded clips, each placed where its clip starts. Its level and pan
  apply to all of it, and its send adds the reverb's return on top of it. Whatever still
  sounds at the song's end is folded back over its start, so the stems loop without a break
  as `TuningFork.Score.render/3` does.

  A Strudel clip plays one cycle a bar for its bars, and what it started rings on after the
  clip ends. A Sonic Pi loop keeps its own time and is cut at the clip's end with a 10 ms
  fade, as a recording is.
  """

  alias TuningFork.Composer.Arrangement
  alias TuningFork.Composer.Arrangement.{Clip, Track, Voices}
  alias TuningFork.{Fx, Mixer, Part, Pattern, Sample, Score, SonicPi, Strudel, Wav}
  alias TuningFork.Pattern.Player

  @rate 44_100
  @channels 2
  @ring_seconds 2.0
  @fade_seconds 0.01
  @block 2_048

  @typedoc "A track's stem: the name its file takes, the track, and its PCM."
  @type stem :: %{name: String.t(), track: Track.t(), pcm: binary()}

  @doc """
  The stems of every audible track, in track order.

  ## Options

    * `:rate` — samples per second, default 44100
    * `:channels` — 1 or 2, default 2
    * `:dir` — where a recording's relative path is read from, default the working directory

  Returns `{:error, message}` for an instrument nothing can play, a step or pattern that does
  not read, a Strudel chain or Sonic Pi source that does not run, or a recording that will not
  open.
  """
  @spec stems(Arrangement.t(), keyword()) :: {:ok, [stem()]} | {:error, String.t()}
  def stems(%Arrangement{} = arrangement, opts \\ []) do
    settings = %{
      rate: Keyword.get(opts, :rate, @rate),
      channels: Keyword.get(opts, :channels, @channels),
      dir: Keyword.get(opts, :dir, "."),
      frames: 0
    }

    settings = %{settings | frames: round(Arrangement.seconds(arrangement) * settings.rate)}

    with :ok <- instruments_known(arrangement) do
      arrangement
      |> Arrangement.stem_names()
      |> Enum.reduce_while({:ok, []}, &add_stem(&1, &2, arrangement, settings))
      |> case do
        {:ok, stems} -> {:ok, Enum.reverse(stems)}
        error -> error
      end
    end
  end

  defp add_stem({name, track}, {:ok, acc}, arrangement, settings) do
    case track_pcm(arrangement, track, settings) do
      {:ok, pcm} -> {:cont, {:ok, [%{name: name, track: track, pcm: pcm} | acc]}}
      {:error, message} -> {:halt, {:error, message}}
    end
  end

  @doc "The stems summed into one buffer, clipping at full scale."
  @spec mix([stem()]) :: binary()
  def mix(stems), do: stems |> Enum.map(& &1.pcm) |> Mixer.mix()

  defp instruments_known(arrangement) do
    unknown =
      for track <- Arrangement.audible(arrangement),
          not Voices.known?(track.instrument),
          do: "#{track.name} (#{inspect(track.instrument)})"

    case unknown do
      [] ->
        :ok

      names ->
        {:error,
         "no instrument plays for #{Enum.join(names, ", ")}: an instrument is a drum, one of " <>
           "TuningFork.Composer.instruments/0, a gm_ soundfont, \"sample:\" and a file, or a sample bank"}
    end
  end

  defp track_pcm(arrangement, track, settings) do
    with {:ok, notes} <- Arrangement.notes(arrangement, track),
         {:ok, clips} <- clips_pcm(arrangement, track, settings) do
      dry = Mixer.mix([notes_pcm(arrangement, track, notes, settings), clips])
      {:ok, with_send(dry, track, arrangement, settings)}
    end
  end

  defp notes_pcm(_arrangement, _track, [], settings),
    do: Mixer.silence(settings.frames, settings.channels)

  defp notes_pcm(arrangement, track, notes, settings) do
    part = Part.part(bpm: arrangement.bpm, gain: Track.gain(track), pan: track.pan)

    notes
    |> Enum.reduce(part, &play(&2, &1, arrangement, track))
    |> List.wrap()
    |> Score.from_parts(bpm: arrangement.bpm, beats: Arrangement.beats(arrangement))
    |> Score.render(settings.rate, channels: settings.channels)
    |> fit(settings)
  end

  defp play(part, note, arrangement, track) do
    case Voices.voice(arrangement, track, note) do
      nil ->
        part

      voice ->
        held = if Voices.drum?(track, note), do: [], else: [release: note.length]
        part |> Part.at(note.beat) |> Part.play(voice, 0.0, [gain: note.velocity] ++ held)
    end
  end

  defp clips_pcm(arrangement, track, settings) do
    silence = Mixer.silence(settings.frames, settings.channels)

    track.clips
    |> Enum.filter(&Clip.audio?/1)
    |> Enum.reduce_while({:ok, silence}, fn clip, {:ok, base} ->
      case clip_pcm(arrangement, clip, settings) do
        {:ok, pcm} ->
          levelled =
            pcm |> Mixer.scale(Track.gain(track)) |> balance(track.pan, settings.channels)

          offset =
            round(
              Clip.start(clip, arrangement.metre) * Arrangement.beat_seconds(arrangement) *
                settings.rate
            )

          {:cont, {:ok, wrap_into(base, levelled, offset, settings.channels)}}

        {:error, message} ->
          {:halt, {:error, "#{track.name}, the clip at bar #{clip.bar}: #{message}"}}
      end
    end)
  end

  defp clip_pcm(arrangement, %Clip{kind: :strudel} = clip, settings) do
    with {:ok, pattern} <- Strudel.pattern(clip.strudel) do
      cps = arrangement.bpm / arrangement.metre / 60.0
      frames = round(clip.beats * Arrangement.beat_seconds(arrangement) * settings.rate)
      player = Player.new(pattern, settings.rate, cps: cps)
      {body, player} = blocks(player, frames, settings.channels, <<>>)
      quiet = %{player | pattern: Pattern.silence(), next: nil}

      {ring, _player} =
        blocks(quiet, round(@ring_seconds * settings.rate), settings.channels, <<>>)

      {:ok, body <> ring}
    end
  end

  defp clip_pcm(arrangement, %Clip{kind: :loop} = clip, settings) do
    seconds = clip.beats * Arrangement.beat_seconds(arrangement)

    with {:ok, buffer} <- SonicPi.run(clip.loop) do
      pcm =
        SonicPi.render(buffer, settings.rate, seconds, channels: settings.channels, limit: nil)

      {:ok,
       pcm |> fit(%{settings | frames: round(seconds * settings.rate)}) |> fade_out(settings)}
    end
  end

  defp clip_pcm(arrangement, %Clip{kind: :recording} = clip, settings) do
    seconds = clip.beats * Arrangement.beat_seconds(arrangement)
    path = Path.expand(clip.recording || "", settings.dir)

    with {:ok, {pcm, rate, channels}} <- recording(path) do
      skip = round(clip.offset * settings.rate)

      {:ok,
       pcm
       |> Mixer.fit(rate, channels, settings.rate, settings.channels)
       |> drop_frames(skip, settings.channels)
       |> fit(%{settings | frames: round(seconds * settings.rate)})
       |> fade_out(settings)}
    end
  end

  defp recording(path) do
    case File.read(path) do
      {:ok, body} -> wav_or_other(body, path)
      {:error, reason} -> {:error, "#{path} will not open: #{:file.format_error(reason)}"}
    end
  end

  defp wav_or_other(body, path) do
    case Wav.decode(body) do
      {:ok, pcm, rate, channels} -> {:ok, {pcm, rate, channels}}
      {:error, :not_a_wav} -> decoded(path)
      {:error, reason} -> {:error, "#{path} will not decode: #{inspect(reason)}"}
    end
  end

  defp decoded(path) do
    sample = Sample.load!(path)
    {:ok, {sample.pcm, sample.rate, 1}}
  rescue
    error -> {:error, "#{path} will not decode: #{Exception.message(error)}"}
  end

  defp blocks(player, frames, _channels, acc) when frames <= 0, do: {acc, player}

  defp blocks(player, frames, channels, acc) do
    size = min(@block, frames)
    {chunk, player} = Player.advance(player, size, channels)
    blocks(player, frames - size, channels, acc <> chunk)
  end

  defp with_send(dry, %Track{send: send}, _arrangement, _settings) when send <= 0.0, do: dry

  defp with_send(dry, %Track{send: send}, arrangement, settings) do
    wet =
      Fx.reverb(dry, settings.rate,
        room: arrangement.reverb,
        mix: 1.0,
        channels: settings.channels
      )

    dry
    |> Mixer.mix(Mixer.scale(wet, send * 1.0))
    |> Mixer.fold(settings.frames, settings.channels)
  end

  defp wrap_into(base, pcm, offset, channels) do
    {placed, over} = Mixer.mix_at(base, pcm, offset, channels)

    case over do
      <<>> -> placed
      over -> placed |> Mixer.mix_at(over, 0, channels) |> elem(0)
    end
  end

  defp fit(pcm, %{frames: frames, channels: channels}) do
    pcm |> Mixer.fold(frames, channels) |> Mixer.take(frames, channels) |> elem(0)
  end

  defp drop_frames(pcm, 0, _channels), do: pcm

  defp drop_frames(pcm, frames, channels) do
    bytes = frames * Mixer.bytes_per_frame(channels)

    case pcm do
      <<_skipped::binary-size(^bytes), rest::binary>> -> rest
      _shorter -> <<>>
    end
  end

  defp balance(pcm, pan, 2) when pan != 0.0 do
    left = min(1.0, 1.0 - pan)
    right = min(1.0, 1.0 + pan)

    for <<l::signed-little-16, r::signed-little-16 <- pcm>>, into: <<>> do
      <<round(l * left)::signed-little-16, round(r * right)::signed-little-16>>
    end
  end

  defp balance(pcm, _pan, _channels), do: pcm

  defp fade_out(pcm, %{rate: rate, channels: channels}) do
    frames = div(byte_size(pcm), Mixer.bytes_per_frame(channels))
    fading = min(round(@fade_seconds * rate), frames)
    keep = (frames - fading) * Mixer.bytes_per_frame(channels)
    <<head::binary-size(^keep), tail::binary>> = pcm

    faded =
      for {sample, index} <- Enum.with_index(for <<s::signed-little-16 <- tail>>, do: s),
          into: <<>> do
        frame = div(index, channels)
        <<round(sample * (1.0 - frame / max(fading, 1)))::signed-little-16>>
      end

    head <> faded
  end
end

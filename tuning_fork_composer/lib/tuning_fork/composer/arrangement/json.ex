defmodule TuningFork.Composer.Arrangement.Json do
  @moduledoc """
  An arrangement as string-keyed maps of JSON-safe values, and back.

      map = Json.to_map(arrangement)
      {:ok, ^arrangement} = Json.from_map(map)

  The map is what any other program reads and writes, so a song can move between
  `tuning_fork` and tools that do not use it:

      {
        "format": "tuning_fork.arrangement",
        "version": 1,
        "name": "river", "bpm": 132.0, "metre": 4,
        "key": {"tonic": "D", "mode": "minor"},
        "kit": "synth", "gain": 0.5, "reverb": 0.3, "bars": null,
        "sections": [{"name": "road", "bar": 1, "bars": 8}],
        "markers": [{"name": "fall", "bar": 17, "beat": 0.0}],
        "tracks": [
          {"name": "bass", "instrument": "bass", "gain_db": -2.0, "pan": 0.0, "send": 0.0,
           "mute": false, "solo": false, "mono": false,
           "clips": [
             {"kind": "pattern", "bar": 1, "beat": 0.0, "beats": 64.0,
              "pattern": "x--.x--.", "step": 0.25, "pitches": [38, 41], "chords": []},
             {"kind": "notes", "bar": 9, "beat": 0.0, "beats": 4.0, "loop_beats": null,
              "notes": [{"beat": 0.0, "pitch": 62, "length": 1.0, "velocity": 0.8, "sound": null}]},
             {"kind": "steps", "bar": 1, "beat": 0.0, "beats": 16.0, "step": 0.25,
              "steps": {"kick": "x...x...", "snare": "....x..."}},
             {"kind": "strudel", "bar": 1, "beat": 0.0, "beats": 16.0, "strudel": "note(\\"d3 f3\\")"},
             {"kind": "loop", "bar": 1, "beat": 0.0, "beats": 16.0, "loop": "live_loop :pad do ... end"},
             {"kind": "recording", "bar": 1, "beat": 0.0, "beats": 16.0,
              "recording": "stems/rain.wav", "offset": 0.0}
           ]}
        ]
      }

  `from_map/1` also takes pitches as note names (`"C4"` is 60, `"F#3"` or `"fs3"` is 54).
  Fields it does not know, on the arrangement, a track or a clip, are kept in `:extra` and
  written back by `to_map/1`.
  """

  alias TuningFork.Composer.Arrangement
  alias TuningFork.Composer.Arrangement.{Clip, Track}

  @format "tuning_fork.arrangement"
  @version 1
  @top ~w(format version name bpm metre key kit gain reverb bars sections markers tracks)
  @track_fields ~w(name instrument gain_db pan send mute solo mono clips)
  @clip_fields ~w(kind bar beat beats notes loop_beats steps step pattern pitches chords strudel loop recording offset)
  @semitones %{"c" => 0, "d" => 2, "e" => 4, "f" => 5, "g" => 7, "a" => 9, "b" => 11}

  @doc "The value of `\"format\"` an arrangement's map carries."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The arrangement as string-keyed maps."
  @spec to_map(Arrangement.t()) :: map()
  def to_map(%Arrangement{} = arrangement) do
    Map.merge(arrangement.extra, %{
      "format" => @format,
      "version" => @version,
      "name" => arrangement.name,
      "bpm" => arrangement.bpm,
      "metre" => arrangement.metre,
      "key" => arrangement.key,
      "kit" => to_string(arrangement.kit),
      "gain" => arrangement.gain,
      "reverb" => arrangement.reverb,
      "bars" => arrangement.bars,
      "sections" => Enum.map(arrangement.sections, &section_to_map/1),
      "markers" => Enum.map(arrangement.markers, &marker_to_map/1),
      "tracks" => Enum.map(arrangement.tracks, &track_to_map/1)
    })
  end

  @doc """
  An arrangement from the maps `to_map/1` writes, or `{:error, message}` naming what is
  wrong and where.
  """
  @spec from_map(map()) :: {:ok, Arrangement.t()} | {:error, String.t()}
  def from_map(%{} = map) do
    with :ok <- format_ok(map),
         {:ok, bpm} <- positive(map, "bpm", 120.0),
         {:ok, metre} <- whole(map, "metre", 4, "the arrangement"),
         {:ok, sections} <- each(map["sections"], "sections", &section/2),
         {:ok, markers} <- each(map["markers"], "markers", &marker/2),
         {:ok, tracks} <- each(map["tracks"], "tracks", &track/2) do
      {:ok,
       Arrangement.new(
         name: to_string(map["name"] || "song"),
         bpm: bpm,
         metre: metre,
         key: map["key"],
         kit: kit(map["kit"]),
         gain: number(map["gain"], 0.5),
         reverb: number(map["reverb"], 0.3),
         bars: if(is_integer(map["bars"]) and map["bars"] > 0, do: map["bars"]),
         sections: sections,
         markers: markers,
         tracks: tracks,
         extra: Map.drop(map, @top)
       )}
    end
  end

  def from_map(other), do: {:error, "an arrangement is a map, not #{inspect(other)}"}

  @doc "The MIDI note of a pitch given as a number or a note name, or `{:error, message}`."
  @spec pitch(term()) :: {:ok, 0..127 | nil} | {:error, String.t()}
  def pitch(nil), do: {:ok, nil}
  def pitch(midi) when is_integer(midi) and midi in 0..127, do: {:ok, midi}

  def pitch(name) when is_binary(name) do
    case Regex.run(~r/^\s*([A-Ga-g])(#|s|b)?(-?\d)\s*$/, name) do
      [_whole, letter, accidental, octave] ->
        in_range((String.to_integer(octave) + 1) * 12 + semitone(letter, accidental), name)

      nil ->
        {:error, "#{inspect(name)} is not a note name or a MIDI note"}
    end
  end

  def pitch(other), do: {:error, "#{inspect(other)} is not a note name or a MIDI note"}

  defp semitone(letter, accidental) do
    @semitones[String.downcase(letter)] + Map.get(%{"#" => 1, "s" => 1, "b" => -1}, accidental, 0)
  end

  defp in_range(midi, _name) when midi in 0..127, do: {:ok, midi}
  defp in_range(_midi, name), do: {:error, "#{inspect(name)} is outside MIDI's 0 to 127"}

  defp format_ok(%{"format" => @format, "version" => @version}), do: :ok

  defp format_ok(%{"format" => @format, "version" => version}),
    do: {:error, "arrangement version #{inspect(version)} is not #{@version}"}

  defp format_ok(_map), do: {:error, "an arrangement's \"format\" is #{inspect(@format)}"}

  defp section(map, where) do
    with {:ok, bar} <- whole(map, "bar", 1, where),
         {:ok, bars} <- whole(map, "bars", 1, where) do
      {:ok, %{name: to_string(map["name"] || "section"), bar: bar, bars: bars}}
    end
  end

  defp marker(map, where) do
    with {:ok, bar} <- whole(map, "bar", 1, where) do
      {:ok, %{name: to_string(map["name"] || "marker"), bar: bar, beat: number(map["beat"], 0.0)}}
    end
  end

  defp track(map, where) do
    with {:ok, instrument} <- text(map, "instrument", where),
         {:ok, clips} <- each(map["clips"], "#{where}.clips", &clip/2) do
      {:ok,
       Track.new(
         name: to_string(map["name"] || "track"),
         instrument: instrument,
         gain_db: number(map["gain_db"], 0.0),
         pan: map |> Map.get("pan") |> number(0.0) |> max(-1.0) |> min(1.0),
         send: map |> Map.get("send") |> number(0.0) |> max(0.0) |> min(1.0),
         mute: map["mute"] == true,
         solo: map["solo"] == true,
         mono: map["mono"] == true,
         clips: clips,
         extra: Map.drop(map, @track_fields)
       )}
    end
  end

  defp clip(map, where) do
    with {:ok, kind} <- kind(map["kind"], where),
         {:ok, bar} <- whole(map, "bar", 1, where),
         {:ok, beats} <- positive(map, "beats", 4.0),
         {:ok, step} <- positive(map, "step", 0.25),
         {:ok, notes} <- each(map["notes"], "#{where}.notes", &note/2),
         {:ok, pitches} <- pitches(map["pitches"], where),
         {:ok, chords} <- chords(map["chords"], where) do
      {:ok,
       Clip.new(
         kind: kind,
         bar: bar,
         beat: number(map["beat"], 0.0),
         beats: beats,
         notes: notes,
         loop_beats: positive_or_nil(map["loop_beats"]),
         steps: steps(map["steps"]),
         step: step,
         pattern: to_string(map["pattern"] || ""),
         pitches: pitches,
         chords: chords,
         strudel: to_string(map["strudel"] || ""),
         loop: to_string(map["loop"] || ""),
         recording: map["recording"],
         offset: number(map["offset"], 0.0),
         extra: Map.drop(map, @clip_fields)
       )}
    end
  end

  defp note(map, where) do
    with {:ok, pitch} <- tagged(pitch(map["pitch"]), where) do
      {:ok,
       %{
         beat: number(map["beat"], 0.0),
         pitch: pitch,
         length: number(map["length"], 1.0),
         velocity: map |> Map.get("velocity") |> number(0.8) |> max(0.0) |> min(1.0),
         sound: map["sound"]
       }}
    end
  end

  defp kind(name, where) do
    case Enum.find(Clip.kinds(), &(Atom.to_string(&1) == name)) do
      nil ->
        {:error,
         "#{where}: kind #{inspect(name)} is not one of #{Enum.map_join(Clip.kinds(), ", ", &Atom.to_string/1)}"}

      kind ->
        {:ok, kind}
    end
  end

  defp pitches(nil, _where), do: {:ok, []}

  defp pitches(list, where) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case tagged(pitch(value), where) do
        {:ok, midi} -> {:cont, {:ok, [midi | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reversed()
  end

  defp pitches(other, where), do: {:error, "#{where}: pitches are a list, not #{inspect(other)}"}

  defp chords(nil, _where), do: {:ok, []}

  defp chords(list, where) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn chord, {:ok, acc} ->
      case pitches(chord, where) do
        {:ok, notes} -> {:cont, {:ok, [notes | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reversed()
  end

  defp chords(other, where),
    do: {:error, "#{where}: chords are a list of lists, not #{inspect(other)}"}

  defp steps(%{} = by_sound),
    do: Map.new(by_sound, fn {sound, text} -> {to_string(sound), to_string(text)} end)

  defp steps(_none), do: %{}

  defp each(nil, _where, _read), do: {:ok, []}

  defp each(list, where, read) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{} = item, index}, {:ok, acc} ->
        case read.(item, "#{where}[#{index}]") do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          error -> {:halt, error}
        end

      {other, index}, _acc ->
        {:halt, {:error, "#{where}[#{index}] is a map, not #{inspect(other)}"}}
    end)
    |> reversed()
  end

  defp each(other, where, _read), do: {:error, "#{where} is a list, not #{inspect(other)}"}

  defp reversed({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reversed(error), do: error

  defp tagged({:error, message}, where), do: {:error, "#{where}: #{message}"}
  defp tagged(ok, _where), do: ok

  defp text(map, key, where) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, "#{where}: #{key} is a name, not #{inspect(other)}"}
    end
  end

  defp whole(map, key, default, where) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= 1 -> {:ok, value}
      other -> {:error, "#{where}: #{key} is a whole number from 1, not #{inspect(other)}"}
    end
  end

  defp positive(map, key, default) do
    case Map.get(map, key, default) do
      value when is_number(value) and value > 0 -> {:ok, value * 1.0}
      other -> {:error, "#{key} is a number above 0, not #{inspect(other)}"}
    end
  end

  defp positive_or_nil(value) when is_number(value) and value > 0, do: value * 1.0
  defp positive_or_nil(_value), do: nil

  defp number(value, _default) when is_number(value), do: value * 1.0
  defp number(_value, default), do: default

  defp kit(nil), do: :synth
  defp kit("synth"), do: :synth
  defp kit(name), do: to_string(name)

  defp section_to_map(section),
    do: %{"name" => section.name, "bar" => section.bar, "bars" => section.bars}

  defp marker_to_map(marker),
    do: %{"name" => marker.name, "bar" => marker.bar, "beat" => marker.beat}

  defp track_to_map(%Track{} = track) do
    Map.merge(track.extra, %{
      "name" => track.name,
      "instrument" => track.instrument,
      "gain_db" => track.gain_db,
      "pan" => track.pan,
      "send" => track.send,
      "mute" => track.mute,
      "solo" => track.solo,
      "mono" => track.mono,
      "clips" => Enum.map(track.clips, &clip_to_map/1)
    })
  end

  defp clip_to_map(%Clip{} = clip) do
    clip.extra
    |> Map.merge(%{
      "kind" => Atom.to_string(clip.kind),
      "bar" => clip.bar,
      "beat" => clip.beat,
      "beats" => clip.beats
    })
    |> Map.merge(kind_fields(clip))
  end

  defp kind_fields(%Clip{kind: :notes} = clip),
    do: %{"loop_beats" => clip.loop_beats, "notes" => Enum.map(clip.notes, &note_to_map/1)}

  defp kind_fields(%Clip{kind: :steps} = clip), do: %{"step" => clip.step, "steps" => clip.steps}

  defp kind_fields(%Clip{kind: :pattern} = clip),
    do: %{
      "pattern" => clip.pattern,
      "step" => clip.step,
      "pitches" => clip.pitches,
      "chords" => clip.chords
    }

  defp kind_fields(%Clip{kind: :strudel} = clip), do: %{"strudel" => clip.strudel}
  defp kind_fields(%Clip{kind: :loop} = clip), do: %{"loop" => clip.loop}

  defp kind_fields(%Clip{kind: :recording} = clip),
    do: %{"recording" => clip.recording, "offset" => clip.offset}

  defp note_to_map(note) do
    %{
      "beat" => note.beat,
      "pitch" => note.pitch,
      "length" => note.length,
      "velocity" => note.velocity,
      "sound" => Map.get(note, :sound)
    }
  end
end

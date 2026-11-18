defmodule TuningFork.Song do
  @moduledoc """
  A song on disk: a manifest, the recordings it names, and the score.

  A bundle is a directory holding `song.json` and the files it names — `mix.wav`, a
  `stems/` directory, `score.mid`, and `backing.wav` when some stems are meant to be played
  rather than listened to. The manifest is plain JSON, so a song can be read, diffed and
  edited without this library; this module reads it, checks it, and turns it into the shape
  `Cauldron.Audio.Music.piece/3` takes.

      {:ok, song} = TuningFork.Song.read("priv/music/night")
      {:ok, {pcm, 44_100, 2}} = TuningFork.Song.pcm(song, "bass", "priv/music/night")
      {:ok, piece} = TuningFork.Song.to_piece(song, "priv/music/night")

      Cauldron.Audio.Music.piece(audio, "night", piece)
      Cauldron.Audio.Music.cue(audio, %{piece: "night", section: "intro"})

  A game reads a bundle with `tuning_fork` alone: no generator, no model, no decoder.

  ## The manifest

      {
        "format": 1,
        "id": "night-harbour",
        "title": "Night Harbour",
        "bpm": 112.0,
        "time_signature": [4, 4],
        "key": {"tonic": "D", "mode": "minor"},
        "sample_rate": 48000,
        "channels": 2,
        "duration_s": 94.2,
        "sections": [{"name": "intro", "start_s": 0.0, "end_s": 8.6}],
        "stems": {
          "bass": {"file": "stems/bass.wav", "gain": 1.0, "muted": false}
        },
        "playable": [],
        "mix": "mix.wav",
        "backing": null,
        "score": "score.mid",
        "provenance": {}
      }

  Sections are in the order the song plays and their times are seconds from the start of
  `mix.wav`. Stems are named by the instrument. `playable` names the stems a game gives to
  the player; the mix without them is `backing.wav`. A stem may also carry `notes` or
  `hits` — a chart read from the recording — which this module passes through untouched.

  ## Making one

  `mix tuning_fork.bake` writes a bundle from a `TuningFork.Composer` project: it renders
  the mix, a file per stem, and `score.mid`, then writes the manifest. The same directory
  is what a game reads, so nothing is generated twice and nothing is converted at load.

  ## Reading one

  `read/1` parses the manifest without touching the audio — cheap enough to do at startup.
  `validate/2` checks the files against it, and `pcm/3` and `to_piece/2` load them.
  """

  alias TuningFork.Wav

  @format 1
  @fields ~w(format id title bpm time_signature key sample_rate channels duration_s sections
             stems playable mix backing score provenance)
  @bpm 120.0
  @signature {4, 4}
  @rate 44_100
  @channels 2

  @typedoc "One named recording, with whatever the manifest says about it."
  @type stem :: map()

  @typedoc "A stretch of the song, as a game cues it."
  @type section :: %{name: String.t(), start_s: float(), end_s: float()}

  @type t :: %__MODULE__{
          format: pos_integer(),
          id: String.t(),
          title: String.t() | nil,
          bpm: float(),
          time_signature: {pos_integer(), pos_integer()},
          key: map() | nil,
          sample_rate: pos_integer(),
          channels: 1 | 2,
          duration_s: float() | nil,
          sections: [section()],
          stems: %{String.t() => stem()},
          playable: [String.t()],
          mix: String.t() | nil,
          backing: String.t() | nil,
          score: String.t() | nil,
          provenance: map() | nil,
          extra: map()
        }

  defstruct format: @format,
            id: "song",
            title: nil,
            bpm: @bpm,
            time_signature: @signature,
            key: nil,
            sample_rate: @rate,
            channels: @channels,
            duration_s: nil,
            sections: [],
            stems: %{},
            playable: [],
            mix: "mix.wav",
            backing: nil,
            score: "score.mid",
            provenance: nil,
            extra: %{}

  @doc """
  A song, with anything unset left at its default.

      TuningFork.Song.new(id: "night", bpm: 112, sections: [%{name: "intro", start_s: 0, end_s: 8}])
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts |> Map.new() |> Map.new(fn {key, value} -> {to_string(key), value} end) |> from_map()
  end

  @doc """
  Read the manifest of the bundle at `path` — a directory, or the `song.json` itself.

  Parses and normalises only; the recordings it names are not opened.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, body} <- File.read(manifest(path)) do
      decode(body)
    end
  end

  @doc "As `read/1`, raising on anything unreadable."
  @spec read!(Path.t()) :: t()
  def read!(path) do
    case read(path) do
      {:ok, song} -> song
      {:error, reason} -> raise ArgumentError, "cannot read #{manifest(path)}: #{inspect(reason)}"
    end
  end

  @doc """
  Write the manifest of `song` into the bundle at `path`.

  Creates the directory, and writes through a temporary file so a reader never sees half a
  manifest. Does not write the audio the manifest names.
  """
  @spec write(t(), Path.t()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = song, path) do
    file = manifest(path)
    temporary = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(temporary, pretty(to_map(song)) <> "\n") do
      File.rename(temporary, file)
    end
  end

  @doc "Where the manifest of the bundle at `path` is."
  @spec manifest(Path.t()) :: Path.t()
  def manifest(path) do
    if String.ends_with?(path, ".json"), do: path, else: Path.join(path, "song.json")
  end

  @doc """
  The manifest as string-keyed maps of JSON-safe values.

  Anything in `:extra` — fields the manifest carried that this module does not know, such as
  the `beats`, `downbeats` and `bars` a transcription writes — is written back out.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = song) do
    Map.merge(song.extra || %{}, %{
      "format" => song.format,
      "id" => song.id,
      "title" => song.title,
      "bpm" => song.bpm,
      "time_signature" => Tuple.to_list(song.time_signature),
      "key" => song.key,
      "sample_rate" => song.sample_rate,
      "channels" => song.channels,
      "duration_s" => song.duration_s,
      "sections" => Enum.map(song.sections, &section_to_map/1),
      "stems" => song.stems,
      "playable" => song.playable,
      "mix" => song.mix,
      "backing" => song.backing,
      "score" => song.score,
      "provenance" => song.provenance
    })
  end

  @doc """
  A song from plain maps — string keys, as JSON gives them, or atom keys.

  Missing keys fall back to the defaults and values of the wrong type are dropped, never
  raising. Unknown keys on a stem are kept as they came, so a writer can carry a field this
  module does not know about.
  """
  @spec from_map(map()) :: t()
  def from_map(attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    bpm = number(attrs["bpm"], @bpm)

    %__MODULE__{
      format: integer(attrs["format"], @format),
      id: string(attrs["id"]) || "song",
      title: string(attrs["title"]),
      bpm: if(bpm > 0, do: bpm, else: @bpm),
      time_signature: signature(attrs["time_signature"]),
      key: if(is_map(attrs["key"]), do: stringify(attrs["key"])),
      sample_rate: positive(attrs["sample_rate"], @rate),
      channels: channel_count(attrs["channels"]),
      duration_s: duration_of(attrs["duration_s"]),
      sections: sections(attrs["sections"]),
      stems: stems(attrs["stems"]),
      playable: attrs["playable"] |> List.wrap() |> Enum.filter(&is_binary/1),
      mix: optional(attrs, "mix", "mix.wav"),
      backing: optional(attrs, "backing", nil),
      score: optional(attrs, "score", "score.mid"),
      provenance: if(is_map(attrs["provenance"]), do: stringify(attrs["provenance"])),
      extra: Map.drop(attrs, @fields)
    }
  end

  def from_map(_anything_else), do: %__MODULE__{}

  @doc """
  Everything wrong with `song`, or `:ok`.

  Checks the manifest itself; with `:dir` it also checks the files it names — that each one
  exists, that the recordings decode at the song's rate and channel count, and that they
  run as long as the song says.

      TuningFork.Song.validate(song, dir: "priv/music/night")
  """
  @spec validate(t(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = song, opts \\ []) do
    problems =
      structural(song) ++
        case Keyword.get(opts, :dir) do
          nil -> []
          dir -> file_problems(song, dir)
        end

    case problems do
      [] -> :ok
      list -> {:error, list}
    end
  end

  @doc "How long the song runs, in seconds: what the manifest says, or the end of its last section."
  @spec duration(t()) :: float()
  def duration(%__MODULE__{duration_s: seconds}) when is_number(seconds) and seconds > 0,
    do: seconds * 1.0

  def duration(%__MODULE__{sections: sections}) do
    sections |> Enum.map(& &1.end_s) |> Enum.max(fn -> 0.0 end)
  end

  @doc "The section called `name`, or `nil`."
  @spec section(t(), String.t()) :: section() | nil
  def section(%__MODULE__{sections: sections}, name), do: Enum.find(sections, &(&1.name == name))

  @doc """
  The recording of the stem called `name`, as `{:ok, {pcm, rate, channels}}`.

  `dir` is the bundle's directory. Reads and decodes the WAV each time; `to_piece/2` is the
  cheaper way to load a whole song.
  """
  @spec pcm(t(), String.t(), Path.t()) ::
          {:ok, {binary(), pos_integer(), pos_integer()}} | {:error, term()}
  def pcm(%__MODULE__{} = song, name, dir \\ ".") do
    with {:ok, stem} <- fetch_stem(song, name),
         file when is_binary(file) <- stem["file"],
         {:ok, body} <- File.read(Path.join(dir, file)),
         {:ok, pcm, rate, channels} <- Wav.decode(body) do
      {:ok, {pcm, rate, channels}}
    else
      nil -> {:error, {:no_recording, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The song as the spec `Cauldron.Audio.Music.piece/3` takes, with every section's audio.

  Each section is a slice of every stem, as `{:pcm, binary, rate, channels}`, so a cue needs
  no slicing and no rendering. The spec says `render: :ready`: the audio is here, so there
  is nothing to render and nothing to keep — `Cauldron.Audio.Music` plays it as it stands.
  Section names are strings; cue them as such.

      {:ok, piece} = TuningFork.Song.to_piece(song, "priv/music/night")
      Cauldron.Audio.Music.piece(audio, song.id, piece)

  A song with no sections becomes one section named after its id, running the whole length.
  A name used more than once — two choruses — gets `-2`, `-3`, … in the order the sections
  play, because a piece cues by name.
  """
  @spec to_piece(t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def to_piece(%__MODULE__{} = song, dir \\ ".") do
    with {:ok, recordings} <- load_stems(song, dir) do
      sections =
        if song.sections == [],
          do: [%{name: song.id, start_s: 0.0, end_s: duration(song)}],
          else: song.sections

      {:ok,
       %{
         bpm: song.bpm,
         beats_per_bar: elem(song.time_signature, 0),
         layers: recordings |> Map.keys() |> Enum.sort(),
         render: :ready,
         sections:
           sections
           |> unique_names()
           |> Map.new(fn section -> {section.name, slice(recordings, section)} end)
       }}
    end
  end

  @doc "The manifest format this module writes."
  @spec format() :: pos_integer()
  def format, do: @format

  defp structural(song) do
    [
      {song.format != @format, "format #{inspect(song.format)} is not #{@format}"},
      {not (is_number(song.bpm) and song.bpm > 0), "bpm must be greater than zero"},
      {not valid_signature?(song.time_signature), "time_signature must be two positive numbers"},
      {not (is_integer(song.sample_rate) and song.sample_rate > 0),
       "sample_rate must be positive"},
      {song.channels not in [1, 2], "channels must be 1 or 2"},
      {is_nil(song.mix) and is_nil(song.score), "a song needs a mix or a score"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Kernel.++(Enum.flat_map(song.sections, &section_problems/1))
    |> Kernel.++(Enum.flat_map(song.stems, &stem_problems/1))
    |> Kernel.++(Enum.flat_map(song.playable, &playable_problems(song, &1)))
  end

  defp section_problems(%{name: name, start_s: start, end_s: stop}) do
    [
      {not is_binary(name) or name == "", "a section has no name"},
      {not (is_number(start) and is_number(stop)), "section #{inspect(name)} has no times"},
      {is_number(start) and is_number(stop) and stop <= start,
       "section #{inspect(name)} ends before it starts"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp stem_problems({name, stem}) do
    [
      {stem["file"] in [nil, ""], "stem #{inspect(name)} names no file"},
      {not is_number(stem["gain"]), "stem #{inspect(name)} has no gain"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp playable_problems(song, name) do
    if Map.has_key?(song.stems, name),
      do: [],
      else: ["playable stem #{inspect(name)} is not a stem"]
  end

  defp valid_signature?({beats, unit}),
    do: is_integer(beats) and is_integer(unit) and beats > 0 and unit > 0

  defp valid_signature?(_other), do: false

  defp file_problems(song, dir) do
    stems =
      Enum.flat_map(song.stems, fn {name, stem} ->
        case stem["file"] do
          file when is_binary(file) and file != "" ->
            check_recording(name, Path.join(dir, file), song)

          _none ->
            []
        end
      end)

    missing =
      for {what, file} <- [{"mix", song.mix}, {"backing", song.backing}, {"score", song.score}],
          is_binary(file) and file != "",
          not File.exists?(Path.join(dir, file)),
          do: "#{what} file #{inspect(file)} is missing"

    stems ++ missing
  end

  defp check_recording(name, path, song) do
    case File.read(path) do
      {:error, reason} ->
        ["stem #{inspect(name)}: #{inspect(reason)}"]

      {:ok, body} ->
        case Wav.decode(body) do
          {:ok, pcm, rate, channels} ->
            [
              {rate != song.sample_rate,
               "stem #{inspect(name)} is #{rate} Hz, not #{song.sample_rate}"},
              {channels != song.channels,
               "stem #{inspect(name)} has #{channels} channels, not #{song.channels}"},
              {frames_off?(pcm, rate, channels, song),
               "stem #{inspect(name)} is not as long as the song says"}
            ]
            |> Enum.filter(&elem(&1, 0))
            |> Enum.map(&elem(&1, 1))

          {:error, reason} ->
            ["stem #{inspect(name)}: #{inspect(reason)}"]
        end
    end
  end

  defp frames_off?(pcm, rate, channels, %{duration_s: seconds})
       when is_number(seconds) and seconds > 0 do
    frames = div(byte_size(pcm), channels * 2)
    abs(frames - seconds * rate) > 1
  end

  defp frames_off?(_pcm, _rate, _channels, _song), do: false

  defp load_stems(song, dir) do
    Enum.reduce_while(song.stems, {:ok, %{}}, fn {name, stem}, {:ok, loaded} ->
      case recording(stem, dir) do
        {:ok, recording} -> {:cont, {:ok, Map.put(loaded, name, recording)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp recording(stem, dir) do
    with file when is_binary(file) <- stem["file"],
         {:ok, body} <- File.read(Path.join(dir, file)),
         {:ok, pcm, rate, channels} <- Wav.decode(body) do
      {:ok, {pcm, rate, channels}}
    else
      nil -> {:error, :no_recording}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unique_names(sections) do
    {named, _seen} =
      Enum.map_reduce(sections, %{}, fn section, seen ->
        count = Map.get(seen, section.name, 0) + 1
        name = if count == 1, do: section.name, else: "#{section.name}-#{count}"
        {%{section | name: name}, Map.put(seen, section.name, count)}
      end)

    named
  end

  defp slice(recordings, %{start_s: start, end_s: stop}) do
    Map.new(recordings, fn {name, {pcm, rate, channels}} ->
      {name, {:pcm, between(pcm, start, stop, rate, channels), rate, channels}}
    end)
  end

  defp between(<<>>, _start, _stop, _rate, _channels), do: <<>>

  defp between(pcm, start, stop, rate, channels) do
    width = channels * 2
    frames = div(byte_size(pcm), width)
    first = start |> max(0.0) |> Kernel.*(rate) |> trunc() |> min(frames)

    last =
      if stop > start,
        do: stop |> Kernel.*(rate) |> trunc() |> min(frames),
        else: frames

    binary_part(pcm, first * width, max(last - first, 0) * width)
  end

  defp fetch_stem(song, name) do
    case Map.fetch(song.stems, name) do
      {:ok, stem} -> {:ok, stem}
      :error -> {:error, {:unknown_stem, name}}
    end
  end

  # A manifest is meant to be read and diffed, so it is written one field a line rather than
  # as one long string. JSON.encode!/1 does the escaping of every leaf.
  defp pretty(value, level \\ 0)

  defp pretty(value, _level)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: JSON.encode!(value)

  defp pretty(value, level) when is_map(value) do
    case value |> Map.to_list() |> Enum.sort() do
      [] ->
        "{}"

      pairs ->
        lines =
          Enum.map_join(pairs, ",\n", fn {key, field} ->
            pad(level + 1) <> JSON.encode!(to_string(key)) <> ": " <> pretty(field, level + 1)
          end)

        "{\n" <> lines <> "\n" <> pad(level) <> "}"
    end
  end

  defp pretty(value, level) when is_list(value) do
    case value do
      [] ->
        "[]"

      items ->
        lines = Enum.map_join(items, ",\n", &(pad(level + 1) <> pretty(&1, level + 1)))
        "[\n" <> lines <> "\n" <> pad(level) <> "]"
    end
  end

  defp pretty(value, _level), do: JSON.encode!(value)

  defp pad(level), do: String.duplicate("  ", level)

  defp section_to_map(%{name: name, start_s: start, end_s: stop}),
    do: %{"name" => name, "start_s" => start, "end_s" => stop}

  defp sections(list) when is_list(list), do: Enum.flat_map(list, &section/1)
  defp sections(_anything_else), do: []

  defp section(map) when is_map(map) do
    map = stringify(map)
    start = number(map["start_s"], 0.0)
    stop = number(map["end_s"], start)
    [%{name: string(map["name"]) || "section", start_s: start, end_s: stop}]
  end

  defp section(_anything_else), do: []

  defp stems(map) when is_map(map) do
    Map.new(map, fn {name, stem} -> {to_string(name), stem(stem)} end)
  end

  defp stems(_anything_else), do: %{}

  defp stem(map) when is_map(map) do
    map = stringify(map)

    Map.merge(map, %{
      "file" => string(map["file"]),
      "gain" => number(map["gain"], 1.0),
      "muted" => map["muted"] == true
    })
  end

  defp stem(_anything_else), do: %{"file" => nil, "gain" => 1.0, "muted" => false}

  defp signature([beats, unit])
       when is_integer(beats) and is_integer(unit) and beats > 0 and unit > 0,
       do: {beats, unit}

  defp signature({beats, unit})
       when is_integer(beats) and is_integer(unit) and beats > 0 and unit > 0,
       do: {beats, unit}

  defp signature(_anything_else), do: @signature

  defp channel_count(value) when value in [1, 2], do: value
  defp channel_count(_anything_else), do: @channels

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(value, _default) when is_float(value) and value > 0, do: trunc(value)
  defp positive(_value, default), do: default

  defp duration_of(value) when is_number(value) and value >= 0, do: value * 1.0
  defp duration_of(_anything_else), do: nil

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(_value, default), do: default

  defp number(value, _default) when is_number(value), do: value * 1.0
  defp number(_value, default), do: default * 1.0

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string(_anything_else), do: nil

  defp optional(attrs, key, default) do
    if Map.has_key?(attrs, key), do: string(attrs[key]), else: default
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, from_map(map)}
      {:ok, _not_a_map} -> {:error, :not_a_manifest}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end
end

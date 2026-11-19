defmodule TuningFork.Composer.Arrangement do
  @moduledoc """
  A song as tracks of clips placed on bars, with named sections and markers.

      alias TuningFork.Composer.Arrangement
      alias TuningFork.Composer.Arrangement.{Bake, Clip, Track}

      arrangement =
        Arrangement.new(
          name: "river",
          bpm: 132,
          key: %{"tonic" => "D", "mode" => "minor"},
          sections: [%{name: "road", bar: 1, bars: 8}, %{name: "river", bar: 9, bars: 8}],
          markers: [%{name: "fall", bar: 17, beat: 0.0}],
          tracks: [
            Track.new(
              name: "bass",
              instrument: "bass",
              clips: [Clip.new(kind: :pattern, beats: 64.0, pattern: "x--.x--.", pitches: [38, 41])]
            )
          ]
        )

      Bake.bake(arrangement, "priv/music/river")

  `metre` is beats to a bar. `kit` is `:synth`, or a drum machine's name for its recordings
  and the General MIDI soundfonts, as `TuningFork.Composer` takes it. `gain` is the level the
  instruments are made at. `reverb` is how long the reverb that tracks send to rings, `0.0`
  to `1.0`. `bars` is the song's length; left `nil`, it runs to the end of the last clip or
  section. `extra` holds fields a writer keeps that this library does not read.

  `TuningFork.Composer.Arrangement.Json` reads and writes it as JSON,
  `TuningFork.Composer.Arrangement.Render` renders it, and
  `TuningFork.Composer.Arrangement.Bake` writes it as a `TuningFork.Song` bundle.
  """

  alias TuningFork.Composer.Arrangement.{Clip, Track}

  @typedoc "A named stretch of bars, `bar` counted from 1."
  @type section :: %{name: String.t(), bar: pos_integer(), bars: pos_integer()}

  @typedoc "A named place in the song, `bar` counted from 1 and `beat` from 0 within it."
  @type marker :: %{name: String.t(), bar: pos_integer(), beat: float()}

  @type t :: %__MODULE__{
          name: String.t(),
          bpm: float(),
          metre: pos_integer(),
          key: map() | nil,
          kit: :synth | String.t(),
          gain: float(),
          reverb: float(),
          bars: pos_integer() | nil,
          tracks: [Track.t()],
          sections: [section()],
          markers: [marker()],
          extra: map()
        }

  defstruct name: "song",
            bpm: 120.0,
            metre: 4,
            key: nil,
            kit: :synth,
            gain: 0.5,
            reverb: 0.3,
            bars: nil,
            tracks: [],
            sections: [],
            markers: [],
            extra: %{}

  @doc "An arrangement. Takes any field of the struct as an option."
  @spec new(keyword() | map()) :: t()
  def new(fields \\ []) do
    arrangement = struct!(__MODULE__, fields)
    %{arrangement | bpm: arrangement.bpm * 1.0}
  end

  @doc "How many bars the song runs."
  @spec bars(t()) :: pos_integer()
  def bars(%__MODULE__{bars: bars}) when is_integer(bars) and bars > 0, do: bars

  def bars(%__MODULE__{} = arrangement) do
    clip_ends =
      for track <- arrangement.tracks,
          clip <- track.clips,
          do: Clip.finish(clip, arrangement.metre) / arrangement.metre

    section_ends = for section <- arrangement.sections, do: section.bar - 1 + section.bars

    (clip_ends ++ section_ends) |> Enum.max(fn -> 1 end) |> ceil() |> max(1)
  end

  @doc "How many beats the song runs."
  @spec beats(t()) :: float()
  def beats(%__MODULE__{} = arrangement), do: bars(arrangement) * arrangement.metre * 1.0

  @doc "How long one beat lasts, in seconds."
  @spec beat_seconds(t()) :: float()
  def beat_seconds(%__MODULE__{bpm: bpm}), do: 60.0 / bpm

  @doc "How long the song runs, in seconds."
  @spec seconds(t()) :: float()
  def seconds(%__MODULE__{} = arrangement), do: beats(arrangement) * beat_seconds(arrangement)

  @doc "The second of the song a bar (from 1) and a beat within it (from 0) fall on."
  @spec at(t(), pos_integer(), number()) :: float()
  def at(%__MODULE__{} = arrangement, bar, beat \\ 0.0),
    do: ((bar - 1) * arrangement.metre + beat) * beat_seconds(arrangement)

  @doc """
  The sections in the order they play, each with the second it starts and ends on.

  An arrangement with none is one section named after it, running the whole song.
  """
  @spec sections(t()) :: [map()]
  def sections(%__MODULE__{sections: []} = arrangement) do
    [
      %{
        name: arrangement.name,
        bar: 1,
        bars: bars(arrangement),
        start_s: 0.0,
        end_s: seconds(arrangement)
      }
    ]
  end

  def sections(%__MODULE__{} = arrangement) do
    arrangement.sections
    |> Enum.sort_by(& &1.bar)
    |> Enum.map(fn section ->
      Map.merge(section, %{
        start_s: at(arrangement, section.bar),
        end_s: at(arrangement, section.bar + section.bars)
      })
    end)
  end

  @doc "The markers in order, each with the second it falls on as `at_s`."
  @spec markers(t()) :: [map()]
  def markers(%__MODULE__{} = arrangement) do
    arrangement.markers
    |> Enum.sort_by(&{&1.bar, &1.beat})
    |> Enum.map(&Map.put(&1, :at_s, at(arrangement, &1.bar, &1.beat)))
  end

  @doc """
  The tracks that sound: none that are muted, and when any track is soloed only those.
  """
  @spec audible(t()) :: [Track.t()]
  def audible(%__MODULE__{tracks: tracks}) do
    playing = Enum.reject(tracks, & &1.mute)

    case Enum.filter(playing, & &1.solo) do
      [] -> playing
      soloed -> soloed
    end
  end

  @doc """
  The audible tracks, each with the name its stem takes: the track's name in lower case with
  anything but letters and digits as `-`, and its place appended when two would share one.
  """
  @spec stem_names(t()) :: [{String.t(), Track.t()}]
  def stem_names(%__MODULE__{} = arrangement) do
    tracks = audible(arrangement)
    bases = Enum.map(tracks, &slug(&1.name))
    counts = Enum.frequencies(bases)

    tracks
    |> Enum.zip(bases)
    |> Enum.with_index(1)
    |> Enum.map(fn {{track, base}, place} ->
      {if(counts[base] > 1, do: "#{base}-#{place}", else: base), track}
    end)
  end

  @doc """
  Every note `track` plays, each `beat` counted from the start of the song, in order.

  A `mono` track's notes are each cut where the next one starts. Returns `{:error, message}`
  naming the clip whose steps or pattern do not read.
  """
  @spec notes(t(), Track.t()) :: {:ok, [Clip.note()]} | {:error, String.t()}
  def notes(%__MODULE__{metre: metre}, %Track{} = track) do
    track.clips
    |> Enum.reduce_while({:ok, []}, fn clip, {:ok, acc} ->
      case Clip.notes(clip, metre) do
        {:ok, notes} ->
          {:cont, {:ok, acc ++ notes}}

        {:error, message} ->
          {:halt, {:error, "#{track.name}, the clip at bar #{clip.bar}: #{message}"}}
      end
    end)
    |> case do
      {:ok, notes} -> {:ok, notes |> Enum.sort_by(& &1.beat) |> monophonic(track)}
      error -> error
    end
  end

  defp monophonic(notes, %Track{mono: false}), do: notes

  defp monophonic(notes, %Track{mono: true}) do
    notes
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn
      [note, next] when next.beat > note.beat ->
        %{note | length: min(note.length, next.beat - note.beat)}

      [note | _rest] ->
        note
    end)
  end

  defp slug(name) do
    case name
         |> to_string()
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/, "-")
         |> String.trim("-") do
      "" -> "track"
      slug -> slug
    end
  end
end

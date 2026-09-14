defmodule TuningFork.Composer do
  @moduledoc """
  A step sequencer as a struct and pure functions over it.

      project =
        Composer.new(bpm: 100)
        |> Composer.add_track(kind: :drum, sound: "kick")
        |> Composer.toggle_step(0, 0)
        |> Composer.toggle_step(0, 4)

      Composer.to_source(project)
      Composer.to_score(project)
  """

  alias TuningFork.Composer.{Source, Track}
  alias TuningFork.{Gm, Notes, Sample, Score, Voice}

  @type t :: %__MODULE__{
          bpm: pos_integer(),
          bars: pos_integer(),
          meter: pos_integer(),
          division: pos_integer(),
          root: atom(),
          scale: atom(),
          gain: float(),
          reverb: float(),
          name: String.t(),
          tracks: [Track.t()]
        }

  defstruct bpm: 96,
            bars: 2,
            meter: 4,
            division: 4,
            root: :a2,
            scale: :minor_pentatonic,
            gain: 0.5,
            reverb: 0.0,
            name: "song",
            tracks: []

  @settings [:bpm, :bars, :meter, :division, :root, :scale, :gain, :reverb, :name]

  @doc """
  A composition. Takes any field of the struct as an option.

  Fields and defaults: `:bpm` (`96`), `:bars` (`2`), `:meter` beats in a bar (`4`),
  `:division` steps in a beat (`4`), `:root` note name (`:a2`), `:scale` one of `scales/0`
  (`:minor_pentatonic`), `:gain` 0.0–1.0 (`0.5`), `:reverb` room size 0.0–1.0 with `0.0` off
  (`0.0`), `:name` the variable `to_source/1` binds the score to (`"song"`), `:tracks` a list
  of `TuningFork.Composer.Track` (`[]`). Every track given is resized to the grid width.

      Composer.new()
      Composer.new(bpm: 120, meter: 3, root: :c3)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    project = struct!(__MODULE__, opts)

    %{project | tracks: Enum.map(project.tracks, &Track.resize(&1, steps_per_bar(project)))}
  end

  @doc "A four-track demo composition: kick, snare, hat and a bass line."
  @spec demo() :: t()
  def demo do
    new()
    |> add_track(kind: :drum, sound: "kick", gain: 0.9, steps: pattern("x...x...x...x..."))
    |> add_track(kind: :drum, sound: "snare", gain: 0.6, steps: pattern("....x.......x..."))
    |> add_track(kind: :drum, sound: "hat", gain: 0.35, steps: pattern("x.x.x.x.x.x.x.x."))
    |> add_track(
      kind: :pitched,
      sound: "bass",
      gain: 0.5,
      ring: 1.5,
      steps: pattern("1...1...4...3...")
    )
  end

  defp pattern(text) do
    text
    |> String.graphemes()
    |> Enum.map(fn
      "." -> 0
      "x" -> 1
      digit -> String.to_integer(digit)
    end)
  end

  @doc "How many steps wide the grid is: beats to a bar times steps to a beat."
  @spec steps_per_bar(t()) :: pos_integer()
  def steps_per_bar(%__MODULE__{meter: meter, division: division}) do
    max(meter, 1) * max(division, 1)
  end

  @doc "How long one step lasts, in beats."
  @spec step_beats(t()) :: float()
  def step_beats(%__MODULE__{division: division}), do: 1 / max(division, 1)

  @doc "How long the whole composition runs, in beats."
  @spec beats(t()) :: pos_integer()
  def beats(%__MODULE__{bars: bars, meter: meter}), do: max(bars, 1) * max(meter, 1)

  @doc "The notes a pitched track may reach, low to high."
  @spec scale(t()) :: [atom()]
  def scale(%__MODULE__{root: root, scale: scale}), do: Notes.scale(root, scale, octaves: 3)

  @doc "A track by position, or `nil`."
  @spec track(t(), non_neg_integer()) :: Track.t() | nil
  def track(%__MODULE__{tracks: tracks}, index), do: Enum.at(tracks, index)

  @doc "How many tracks there are."
  @spec track_count(t()) :: non_neg_integer()
  def track_count(%__MODULE__{tracks: tracks}), do: length(tracks)

  @doc """
  Change a setting. `field` must be one of `settings/0`; anything else is a no-op.

  `value` may be a number or a string. Nothing raises:

    * `:bpm`, `:bars`, `:meter`, `:division` are truncated to an integer and clamped to at
      least 1.
    * `:gain` and `:reverb` are clamped to 0.0–1.0.
    * A number that will not parse leaves the setting as it was.
    * `:root` and `:scale` take a string or an atom. A string becomes an atom unchecked.
    * `:name` takes anything `to_string/1` accepts.

  Setting `:meter` or `:division` resizes every track to the new grid width.

      Composer.set(project, :bpm, 120)
      Composer.set(project, :bpm, "120")
      Composer.set(project, :meter, 3)
  """
  @spec set(t(), atom(), term()) :: t()
  def set(%__MODULE__{} = project, field, value) when field in @settings do
    project
    |> Map.put(field, cast(field, value, Map.fetch!(project, field)))
    |> refit()
  end

  def set(%__MODULE__{} = project, _unknown, _value), do: project

  @doc "The settings `set/3` will accept."
  @spec settings() :: [atom()]
  def settings, do: @settings

  defp cast(field, value, current) when field in [:bpm, :bars, :meter, :division] do
    value |> to_number(current) |> trunc() |> max(1)
  end

  defp cast(field, value, current) when field in [:gain, :reverb] do
    value |> to_number(current) |> max(0.0) |> min(1.0)
  end

  defp cast(field, value, _current) when field in [:root, :scale] and is_binary(value) do
    String.to_atom(value)
  end

  defp cast(:name, value, _current), do: to_string(value)
  defp cast(_field, value, _current), do: value

  defp to_number(value, _default) when is_number(value), do: value

  defp to_number(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> default
    end
  end

  defp to_number(_value, default), do: default

  defp refit(%__MODULE__{} = project) do
    width = steps_per_bar(project)

    %{project | tracks: Enum.map(project.tracks, &Track.resize(&1, width))}
  end

  @doc "Add a track at the end."
  @spec add_track(t(), keyword()) :: t()
  def add_track(%__MODULE__{} = project, opts \\ []) do
    track = Track.new(opts, steps_per_bar(project))

    %{project | tracks: project.tracks ++ [track]}
  end

  @doc "Remove a track."
  @spec remove_track(t(), non_neg_integer()) :: t()
  def remove_track(%__MODULE__{} = project, index) do
    %{project | tracks: List.delete_at(project.tracks, index)}
  end

  @doc """
  Change a track's fields. `changes` takes any field `TuningFork.Composer.Track.new/2` accepts.

      Composer.update_track(project, 0, gain: 0.4, muted: true)

  Switching `:kind` to `:drum` flattens every degree to a plain hit.
  """
  @spec update_track(t(), non_neg_integer(), keyword() | map()) :: t()
  def update_track(%__MODULE__{} = project, index, changes) do
    edit(project, index, fn track ->
      track
      |> struct!(Map.new(changes))
      |> flatten_if_drum()
    end)
  end

  defp flatten_if_drum(%Track{kind: :drum} = track) do
    %{track | steps: Enum.map(track.steps, &if(elem(Track.read(&1), 0) > 0, do: 1, else: 0))}
  end

  defp flatten_if_drum(track), do: track

  @doc "Silence a track without losing it, or bring it back."
  @spec toggle_mute(t(), non_neg_integer()) :: t()
  def toggle_mute(%__MODULE__{} = project, index) do
    edit(project, index, &%{&1 | muted: not &1.muted})
  end

  @doc "Empty a track's steps, keeping the track."
  @spec clear_track(t(), non_neg_integer()) :: t()
  def clear_track(%__MODULE__{} = project, index) do
    edit(project, index, &%{&1 | steps: Enum.map(&1.steps, fn _step -> 0 end)})
  end

  @doc "Move a track up (`-1`) or down (`1`). A move past either end is a no-op."
  @spec move_track(t(), non_neg_integer(), -1 | 1) :: t()
  def move_track(%__MODULE__{} = project, index, direction) do
    to = index + direction

    if index in 0..(track_count(project) - 1)//1 and to in 0..(track_count(project) - 1)//1 do
      track = Enum.at(project.tracks, index)

      %{project | tracks: project.tracks |> List.delete_at(index) |> List.insert_at(to, track)}
    else
      project
    end
  end

  @doc "Turn a step on or off, keeping whatever length it had."
  @spec toggle_step(t(), non_neg_integer(), non_neg_integer()) :: t()
  def toggle_step(%__MODULE__{} = project, index, step) do
    step(project, index, step, fn {degree, length} ->
      if degree > 0, do: {0, 1}, else: {1, length}
    end)
  end

  @doc """
  Move a step one degree up (`1`) or down (`-1`), turning it off past either end.

      Composer.cycle_step(project, 0, 4, 1)
  """
  @spec cycle_step(t(), non_neg_integer(), non_neg_integer(), -1 | 1) :: t()
  def cycle_step(%__MODULE__{} = project, index, step, direction) do
    highest = length(scale(project))

    step(project, index, step, fn {degree, length} ->
      next = degree + direction

      cond do
        next <= 0 -> {0, length}
        next > highest -> {0, length}
        true -> {next, length}
      end
    end)
  end

  @doc "Set a step to a scale degree, clamped to what the scale holds. `0` silences it."
  @spec set_step(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def set_step(%__MODULE__{} = project, index, step, degree) do
    highest = length(scale(project))

    step(project, index, step, fn {_was, length} ->
      {degree |> max(0) |> min(highest), length}
    end)
  end

  @doc """
  Hold a note over `length` steps.

  `step` may be anywhere inside the note, not only its first step. Clamped so the note stops
  where the next one starts. A step with no note is left alone.
  """
  @spec set_length(t(), non_neg_integer(), non_neg_integer(), pos_integer()) :: t()
  def set_length(%__MODULE__{} = project, index, step, length) do
    case track(project, index) do
      nil ->
        project

      track ->
        start = Track.start_of(track, step)
        {degree, _was} = Track.read(Enum.at(track.steps, start, 0))

        if degree > 0 do
          room = Track.room_at(track, start)
          put_step(project, index, start, Track.write(degree, length |> max(1) |> min(room)))
        else
          project
        end
    end
  end

  @doc "Lengthen or shorten the note at `step` by one, within what room it has."
  @spec grow(t(), non_neg_integer(), non_neg_integer(), -1 | 1) :: t()
  def grow(%__MODULE__{} = project, index, step, by) do
    case track(project, index) do
      nil ->
        project

      track ->
        start = Track.start_of(track, step)
        {_degree, length} = Track.read(Enum.at(track.steps, start, 0))

        set_length(project, index, start, length + by)
    end
  end

  defp step(project, index, step, change) do
    case track(project, index) do
      nil ->
        project

      track ->
        {degree, length} = track.steps |> Enum.at(step, 0) |> Track.read()
        {next_degree, next_length} = change.({degree, length})

        put_step(project, index, step, Track.write(next_degree, next_length))
    end
  end

  defp put_step(project, index, step, value) do
    edit(project, index, &%{&1 | steps: List.replace_at(&1.steps, step, value)})
  end

  defp edit(%__MODULE__{} = project, index, change) do
    case Enum.at(project.tracks, index) do
      nil -> project
      track -> %{project | tracks: List.replace_at(project.tracks, index, change.(track))}
    end
  end

  @doc """
  The composition as `TuningFork.Part` source, or `\"\"` if nothing would sound.

  Takes `TuningFork.Composer.Source`'s options, notably `:output`.
  """
  @spec to_source(t(), keyword()) :: String.t()
  defdelegate to_source(project, opts \\ []), to: Source

  @doc """
  The composition as a `TuningFork.Score`, for playing without evaluating source.

      project |> Composer.to_score() |> TuningFork.Score.render(44_100)
  """
  @spec to_score(t()) :: Score.t()
  def to_score(%__MODULE__{} = project) do
    base = base_voice(project)
    kit = Gm.drums()
    notes = scale(project)

    parts =
      project.tracks
      |> Enum.filter(&Track.audible?/1)
      |> Enum.map(&part_for(&1, project, base, kit, notes))

    Score.from_parts(parts, bpm: project.bpm, beats: beats(project))
  end

  @doc "The voice every instrument in the piece is derived from."
  @spec base_voice(t()) :: Voice.t()
  def base_voice(%__MODULE__{gain: gain}) do
    Voice.new(
      shape: :saw,
      gain: gain,
      cutoff: 0.45,
      envelope: TuningFork.Envelope.new(attack: 0.006, sustain: 0.3, release: 0.12)
    )
  end

  @doc "The voice a track plays with."
  @spec voice_for(Track.t(), t()) :: Voice.t()
  def voice_for(%Track{kind: :drum} = track, project) do
    Map.get(Gm.drums(), drum_note(track.sound), base_voice(project))
  end

  def voice_for(%Track{kind: :pitched} = track, project) do
    Gm.for_program(program_for(track.sound), base_voice(project))
  end

  def voice_for(%Track{kind: :sample} = track, project) do
    base = base_voice(project)

    case load_sample(track) do
      nil -> base
      sample -> %{base | sample: sample}
    end
  end

  defp load_sample(%Track{path: path}) when is_binary(path) and path != "" do
    if File.exists?(path), do: Sample.load!(path), else: nil
  rescue
    _unreadable -> nil
  end

  defp load_sample(_none), do: nil

  defp part_for(track, project, base, kit, notes) do
    import TuningFork.Part

    synth =
      case track.kind do
        :drum -> Map.get(kit, drum_note(track.sound), base)
        :pitched -> Gm.for_program(program_for(track.sound), base)
        :sample -> voice_for(track, project)
      end

    started = part(bpm: project.bpm, synth: synth, gain: track.gain)

    case track.kind do
      :drum ->
        pattern = pattern_for(track)
        repeat(started, project.bars, &steps(&1, pattern, step_beats(project)))

      _pitched_or_sampled ->
        entries = entries_for(track, notes, project)

        repeat(started, project.bars, fn bar ->
          steps(bar, entries, step_beats(project), release: track.ring)
        end)
    end
  end

  defp pattern_for(%Track{steps: steps}) do
    Enum.map_join(steps, "", fn step ->
      if elem(Track.read(step), 0) > 0, do: "x", else: "."
    end)
  end

  defp entries_for(track, notes, project) do
    Enum.map(track.steps, fn step ->
      case Track.read(step) do
        {0, _length} ->
          nil

        {degree, 1} ->
          note_at(notes, degree)

        {degree, length} ->
          {note_at(notes, degree), [release: length * step_beats(project)]}
      end
    end)
  end

  defp note_at(notes, degree), do: Enum.at(notes, degree - 1, List.last(notes))

  @doc "The General MIDI note a named drum sounds on."
  @spec drum_note(String.t() | nil) :: pos_integer()
  def drum_note(sound) do
    Map.get(
      %{
        "kick" => 36,
        "snare" => 38,
        "hat" => 42,
        "open_hat" => 46,
        "tom" => 45,
        "clap" => 39,
        "ride" => 51,
        "crash" => 49
      },
      to_string(sound),
      36
    )
  end

  @doc "The General MIDI program a named instrument selects."
  @spec program_for(String.t() | nil) :: 0..127
  def program_for(sound) do
    Map.get(
      %{
        "bass" => 33,
        "piano" => 0,
        "guitar" => 27,
        "strings" => 48,
        "brass" => 57,
        "reed" => 66,
        "pipe" => 73,
        "lead" => 81,
        "pad" => 89
      },
      to_string(sound),
      0
    )
  end

  @doc "The drums a grid can reach, as `{id, label}`."
  @spec drums() :: [{String.t(), String.t()}]
  def drums do
    [
      {"kick", "Kick"},
      {"snare", "Snare"},
      {"hat", "Hat"},
      {"open_hat", "Open hat"},
      {"tom", "Tom"},
      {"clap", "Clap"},
      {"ride", "Ride"},
      {"crash", "Crash"}
    ]
  end

  @doc "The instruments a grid can reach, as `{id, label}`."
  @spec instruments() :: [{String.t(), String.t()}]
  def instruments do
    [
      {"bass", "Bass"},
      {"piano", "Piano"},
      {"guitar", "Guitar"},
      {"strings", "Strings"},
      {"brass", "Brass"},
      {"reed", "Reed"},
      {"pipe", "Pipe"},
      {"lead", "Lead"},
      {"pad", "Pad"}
    ]
  end

  @doc "The scales a grid can reach."
  @spec scales() :: [atom()]
  def scales do
    [:minor_pentatonic, :major_pentatonic, :minor, :major, :dorian, :blues, :mixolydian]
  end
end

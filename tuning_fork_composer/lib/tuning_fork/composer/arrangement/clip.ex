defmodule TuningFork.Composer.Arrangement.Clip do
  @moduledoc """
  What a track plays from one place in the song for a number of beats.

  `bar` counts from 1, `beat` from 0 within that bar, and `beats` is how long the clip
  runs. What a clip holds depends on its `kind`:

    * `:notes` — `notes`, each `%{beat:, pitch:, length:, velocity:, sound:}` with `beat`
      from the clip's start; with `loop_beats` they repeat every that many beats
    * `:steps` — `steps`, a drum name to a pattern in the notation of
      `TuningFork.Composer.Arrangement.Pattern`, `step` beats to a character
    * `:pattern` — `pattern` on the track's instrument, `step` beats to a character,
      playing `pitches` (MIDI notes) or `chords` (lists of MIDI notes) one per hit, cycling
    * `:strudel` — `strudel`, a Strudel chain, one cycle to a bar
    * `:loop` — `loop`, Sonic Pi source, which keeps its own time
    * `:recording` — `recording`, the path of a sound file, played from `offset` seconds in

  Steps and patterns repeat to fill the clip. Every note is cut at the clip's end. A
  pitch of `nil` plays the instrument's own note, or the drum named by `sound`.

      Clip.new(kind: :pattern, bar: 1, beats: 16.0, pattern: "x--.x--.", pitches: [38, 41])
  """

  alias TuningFork.Composer.Arrangement.Pattern

  @kinds [:notes, :steps, :pattern, :strudel, :loop, :recording]
  @audio_kinds [:strudel, :loop, :recording]

  @typedoc "A note, its `beat` counted from wherever the caller measures."
  @type note :: %{
          beat: float(),
          pitch: 0..127 | nil,
          length: float(),
          velocity: float(),
          sound: String.t() | nil
        }

  @type kind :: :notes | :steps | :pattern | :strudel | :loop | :recording

  @type t :: %__MODULE__{
          kind: kind(),
          bar: pos_integer(),
          beat: float(),
          beats: float(),
          notes: [note()],
          loop_beats: float() | nil,
          steps: %{String.t() => String.t()},
          step: float(),
          pattern: String.t(),
          pitches: [0..127],
          chords: [[0..127]],
          strudel: String.t(),
          loop: String.t(),
          recording: Path.t() | nil,
          offset: float(),
          extra: map()
        }

  defstruct kind: :notes,
            bar: 1,
            beat: 0.0,
            beats: 4.0,
            notes: [],
            loop_beats: nil,
            steps: %{},
            step: 0.25,
            pattern: "",
            pitches: [],
            chords: [],
            strudel: "",
            loop: "",
            recording: nil,
            offset: 0.0,
            extra: %{}

  @doc "A clip. Takes any field of the struct as an option."
  @spec new(keyword() | map()) :: t()
  def new(fields \\ []), do: struct!(__MODULE__, fields)

  @doc "The kinds of clip there are."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Whether the clip is played as rendered audio rather than as notes."
  @spec audio?(t()) :: boolean()
  def audio?(%__MODULE__{kind: kind}), do: kind in @audio_kinds

  @doc "The beat of the song the clip starts on, counted from 0, in a song of `metre` beats a bar."
  @spec start(t(), pos_integer()) :: float()
  def start(%__MODULE__{bar: bar, beat: beat}, metre), do: (bar - 1) * metre + beat * 1.0

  @doc "The beat of the song the clip ends on, counted from 0."
  @spec finish(t(), pos_integer()) :: float()
  def finish(%__MODULE__{} = clip, metre), do: start(clip, metre) + clip.beats

  @doc """
  The notes the clip plays, each `beat` counted from the start of the song, in order.

  A `:strudel`, `:loop` or `:recording` clip has none. Returns `{:error, message}` for a
  step or pattern that does not read.
  """
  @spec notes(t(), pos_integer()) :: {:ok, [note()]} | {:error, String.t()}
  def notes(%__MODULE__{kind: :notes} = clip, metre) do
    start = start(clip, metre)

    placed =
      for offset <- passes(clip.beats, clip.loop_beats),
          note <- clip.notes,
          at = offset + note.beat,
          at >= 0.0 and at < clip.beats,
          do: place(note, at, start, clip.beats)

    {:ok, Enum.sort_by(placed, & &1.beat)}
  end

  def notes(%__MODULE__{kind: :steps} = clip, metre) do
    start = start(clip, metre)

    clip.steps
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {sound, text}, {:ok, acc} ->
      case sound_notes(sound, text, clip, start) do
        {:ok, notes} -> {:cont, {:ok, acc ++ notes}}
        error -> {:halt, error}
      end
    end)
    |> sorted()
  end

  def notes(%__MODULE__{kind: :pattern} = clip, metre) do
    with {:ok, pattern} <- Pattern.parse(clip.pattern) do
      {:ok, pattern_notes(pattern, clip, start(clip, metre))}
    end
  end

  def notes(%__MODULE__{}, _metre), do: {:ok, []}

  defp sound_notes(sound, text, clip, start) do
    case Pattern.parse(text) do
      {:ok, pattern} ->
        {:ok,
         for(
           {at, hit} <- repeated(pattern, clip),
           do: hit_note(hit, start + at, nil, sound, clip, at)
         )}

      {:error, message} ->
        {:error, "#{sound}: #{message}"}
    end
  end

  defp pattern_notes(pattern, clip, start) do
    pattern
    |> repeated(clip)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{at, hit}, index} ->
      for pitch <- pitches_at(clip, index), do: hit_note(hit, start + at, pitch, nil, clip, at)
    end)
  end

  defp passes(beats, loop) when is_number(loop) and loop > 0,
    do: for(pass <- 0..max(ceil(beats / loop) - 1, 0), do: pass * loop * 1.0)

  defp passes(_beats, _loop), do: [0.0]

  defp place(note, at, start, beats) do
    %{
      beat: start + at,
      pitch: Map.get(note, :pitch),
      length: min(Map.get(note, :length, 1.0) * 1.0, beats - at),
      velocity: Map.get(note, :velocity, 0.8) * 1.0,
      sound: Map.get(note, :sound)
    }
  end

  defp repeated(%{steps: 0}, _clip), do: []

  defp repeated(%{steps: steps, hits: hits}, %__MODULE__{step: step, beats: beats}) do
    pass_beats = steps * step

    for pass <- 0..max(ceil(beats / pass_beats) - 1, 0),
        hit <- hits,
        at = pass * pass_beats + hit.step * step,
        at < beats,
        do: {at * 1.0, hit}
  end

  defp hit_note(hit, beat, pitch, sound, clip, at) do
    %{
      beat: beat,
      pitch: pitch,
      length: min(hit.length * clip.step, clip.beats - at),
      velocity: hit.velocity,
      sound: sound
    }
  end

  defp pitches_at(%__MODULE__{chords: [_ | _] = chords}, index),
    do: Enum.at(chords, rem(index, length(chords)))

  defp pitches_at(%__MODULE__{pitches: [_ | _] = pitches}, index),
    do: [Enum.at(pitches, rem(index, length(pitches)))]

  defp pitches_at(%__MODULE__{}, _index), do: [nil]

  defp sorted({:ok, notes}), do: {:ok, Enum.sort_by(notes, & &1.beat)}
  defp sorted(error), do: error
end

defmodule TuningFork.Part do
  @moduledoc """
  One line of music, written by moving a cursor measured in beats.

      import TuningFork.Part

      bass =
        part(bpm: 112, synth: soft_bass)
        |> play(:d2, 1.5)
        |> play(:a2, 0.5)
  """

  alias TuningFork.{Curve, Envelope, Notes, Rand, Voice}

  @type t :: %__MODULE__{
          bpm: float(),
          cursor: float(),
          synth: Voice.t() | instrument() | nil,
          gain: float(),
          pan: float(),
          fx: keyword(),
          rand: Rand.t(),
          notes: [{float(), Voice.t()}]
        }

  @typedoc "A voice for each note: called with the note, or `nil` for a hit with no pitch."
  @type instrument :: (atom() | number() | nil -> Voice.t())

  defstruct bpm: 120.0,
            cursor: 0.0,
            synth: nil,
            gain: 1.0,
            pan: 0.0,
            fx: [],
            rand: nil,
            notes: []

  @doc """
  An empty part with its cursor at beat zero. Every part starts from its own beat zero; one
  that comes in later begins with `rest/2`.

  ## Options

    * `:synth` — the voice its notes are played with, or a `t:instrument/0` asked for one per
      note; default `nil`, in which case `TuningFork.Voice.new/1` is used per note
    * `:bpm` — its tempo, default 120
    * `:gain` — a level over everything in it, default 1.0
    * `:pan` — where it sits, `-1.0` hard left to `1.0` hard right, default 0.0 centred
    * `:fx` — effects applied to this part alone, as `[echo: [...], reverb: [...]]`, default
      none
    * `:seed` — seeds the part's own random generator, default 1
  """
  @spec part(keyword()) :: t()
  def part(opts \\ []) do
    %__MODULE__{
      bpm: Keyword.get(opts, :bpm, 120) * 1.0,
      synth: Keyword.get(opts, :synth),
      gain: Keyword.get(opts, :gain, 1.0) * 1.0,
      pan: Keyword.get(opts, :pan, 0.0) * 1.0,
      fx: Keyword.get(opts, :fx, []),
      rand: Rand.new(Keyword.get(opts, :seed, 1))
    }
  end

  @doc """
  Play a note at the cursor and move the cursor on by `step` beats.

  `note` may be a note name, a frequency in Hz, or a whole `TuningFork.Voice`, which is
  played as it stands without being pitched. `step` is how long until the next note, in beats,
  independent of how long this note sounds.

  ## Options

    * `:release` — how long the note sounds, in beats. Longer than `step` overlaps the next
    * `:gain` — this note's level, multiplied by the part's
    * `:pan` — how far this note sits from where the part does, `-1.0` to `1.0`, added to the
      part's and clamped to that range
    * `:bend` — semitones to arrive at by the end of the note; `2` bends up a tone
    * `:curves` — modulation in full, as `TuningFork.Voice` takes it. A `:freq` curve given
      here supersedes `:bend`
    * `:synth` — a voice, or a `t:instrument/0`, for this note only, overriding the part's

  Any option value of the form `{:between, low, high}` is drawn from the part's own generator
  for each note.

      |> play(:e4, 0.5, release: 3.0)
      |> play(:e4, 1.0, bend: 2)
      |> play(:e4, 1.0, curves: %{gain: Curve.linear(0.2, 1.0)})
  """
  @spec play(t(), atom() | number() | Voice.t(), number(), keyword()) :: t()
  def play(part, note, step \\ 1.0, opts \\ [])

  def play(%__MODULE__{} = part, %Voice{} = voice, step, opts) do
    part |> place(voice, opts) |> advance(step)
  end

  def play(%__MODULE__{} = part, note, step, opts) do
    voice = voiced(Keyword.get(opts, :synth) || part.synth || Voice.new(), note)

    part |> place(voice, opts) |> advance(step)
  end

  defp voiced(instrument, note) when is_function(instrument, 1), do: instrument.(note)
  defp voiced(%Voice{} = synth, note), do: %{synth | freq: Notes.freq(note)}

  @doc "Play a note without moving the cursor, for stacking a chord. Takes `play/4`'s options."
  @spec under(t(), atom() | number() | Voice.t(), keyword()) :: t()
  def under(part, note, opts \\ []), do: play(part, note, 0.0, opts)

  @doc """
  Play every note of a chord at once, then move the cursor on by `step` beats.

  `notes` is a list of note names or frequencies. `opts` are `play/4`'s and apply to every
  note of the chord.
  """
  @spec chord(t(), [atom() | number()], number(), keyword()) :: t()
  def chord(%__MODULE__{} = part, notes, step \\ 1.0, opts \\ []) do
    notes
    |> Enum.reduce(part, &under(&2, &1, opts))
    |> advance(step)
  end

  @doc """
  Play a run of notes, each `step` beats apart.

  `step` may be a list, whose entries are used in turn and repeat: `[0.5, 0.5, 1.0]` is two
  short and one long, over and over. `opts` are `play/4`'s and apply to every note.
  """
  @spec pattern(t(), [atom() | number()], number() | [number()], keyword()) :: t()
  def pattern(%__MODULE__{} = part, notes, step \\ 1.0, opts \\ []) do
    steps = List.wrap(step)

    notes
    |> Enum.with_index()
    |> Enum.reduce(part, fn {note, index}, acc ->
      play(acc, note, Enum.at(steps, rem(index, length(steps))), opts)
    end)
  end

  @doc """
  Play a pattern of evenly spaced steps, each `step` beats apart.

  A string plays the part's own synth on `x` or `X`, plays at a ninth of full level on a digit
  `1` to `9` (multiplied into any `:gain` given), and rests on any other character. Spaces
  are ignored. `step` defaults to 0.25.

      |> steps("x..x..x.")
      |> steps("x2x2x9x2", 0.25)

  A list places a different entry on each step. An entry is anything `play/4` accepts, `nil`
  for a rest, or `{note, opts}` for one step carrying its own options merged over `opts`:

      |> steps([{:a3, release: 4.0}, nil, :c4, nil, :e4, nil, nil, nil])
  """
  @type step_entry ::
          atom() | number() | Voice.t() | nil | {atom() | number() | Voice.t(), keyword()}

  @spec steps(t(), String.t() | [step_entry()], number(), keyword()) :: t()
  def steps(part, pattern, step \\ 0.25, opts \\ [])

  def steps(%__MODULE__{} = part, pattern, step, opts) when is_binary(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.reject(&(&1 == " "))
    |> Enum.reduce(part, fn grapheme, acc -> hit(acc, grapheme, step, opts) end)
  end

  def steps(%__MODULE__{} = part, pattern, step, opts) when is_list(pattern) do
    Enum.reduce(pattern, part, fn
      nil, acc ->
        rest(acc, step)

      {note, own}, acc when is_list(own) ->
        play(acc, note, step, Keyword.merge(opts, own))

      note, acc ->
        play(acc, note, step, opts)
    end)
  end

  defp hit(part, ".", step, _opts), do: rest(part, step)
  defp hit(part, "-", step, _opts), do: rest(part, step)
  defp hit(part, "x", step, opts), do: play(part, struck(part), step, opts)
  defp hit(part, "X", step, opts), do: play(part, struck(part), step, opts)

  defp hit(part, digit, step, opts) when digit in ~w(1 2 3 4 5 6 7 8 9) do
    level = String.to_integer(digit) / 9.0
    opts = Keyword.update(opts, :gain, level, &(&1 * level))

    play(part, struck(part), step, opts)
  end

  defp hit(part, _unknown, step, _opts), do: rest(part, step)

  defp struck(%{synth: instrument}) when is_function(instrument, 1), do: instrument.(nil)
  defp struck(%{synth: synth}), do: synth || Voice.new()

  @doc "Move the cursor on by `beats` without playing anything."
  @spec rest(t(), number()) :: t()
  def rest(%__MODULE__{} = part, beats), do: advance(part, beats)

  @doc """
  Play one of `notes`, chosen by the part's own generator, and move on by `step` beats.

  The same seed picks the same notes in the same order. `opts` are `play/4`'s.
  """
  @spec play_any(t(), [atom() | number() | Voice.t()], number(), keyword()) :: t()
  def play_any(%__MODULE__{} = part, notes, step \\ 1.0, opts \\ []) do
    {note, rand} = Rand.pick(part.rand, notes)

    %{part | rand: rand} |> play(note, step, opts)
  end

  @doc """
  Call `fun` with the part with the given probability, and move on by `step` beats either
  way.

  `probability` runs 0.0 to 1.0 and is drawn from the part's own generator, which advances
  whether or not `fun` is called.
  """
  @spec maybe(t(), float(), (t() -> t()), number()) :: t()
  def maybe(%__MODULE__{} = part, probability, fun, step \\ 0.0) do
    {yes?, rand} = Rand.chance(part.rand, probability)
    part = %{part | rand: rand}

    if yes?, do: advance(fun.(part), step), else: advance(part, step)
  end

  @doc """
  `count` independent choices from `list`, and the part with its generator advanced. The
  result may repeat an element.
  """
  @spec pick(t(), [term()], non_neg_integer()) :: {[term()], t()}
  def pick(%__MODULE__{} = part, list, count \\ 1) do
    {chosen, rand} = Rand.take(part.rand, list, count)
    {chosen, %{part | rand: rand}}
  end

  @doc "A number from `low` up to but not including `high`, and the part with its generator advanced."
  @spec between(t(), number(), number()) :: {float(), t()}
  def between(%__MODULE__{} = part, low, high) do
    {value, rand} = Rand.float(part.rand, low, high)
    {value, %{part | rand: rand}}
  end

  @doc "Put the cursor at an exact beat, forwards or back."
  @spec at(t(), number()) :: t()
  def at(%__MODULE__{} = part, beat), do: %{part | cursor: beat * 1.0}

  @doc "Where the cursor is, in beats."
  @spec cursor(t()) :: float()
  def cursor(%__MODULE__{cursor: cursor}), do: cursor

  @doc """
  Apply `fun` to the part `times` over, from wherever the cursor is.

  `times` may instead be a string of `x` and `.`, one per pass: `fun` is applied on an `x`,
  and on a `.` the cursor moves on by as much as `fun` would have moved it, playing nothing.

      |> repeat(4, &steps(&1, "x...x..."))
      |> repeat("..xx", &steps(&1, "x...x..."))
  """
  @spec repeat(t(), pos_integer() | String.t(), (t() -> t())) :: t()
  def repeat(%__MODULE__{} = part, passes, fun) when is_binary(passes) do
    passes
    |> String.graphemes()
    |> Enum.reduce(part, fn
      "x", acc -> fun.(acc)
      _rest, acc -> %{acc | cursor: fun.(acc).cursor}
    end)
  end

  def repeat(%__MODULE__{} = part, times, fun) do
    Enum.reduce(1..times//1, part, fn _pass, acc -> fun.(acc) end)
  end

  @doc "Apply `fun` to the part `times` over, told which pass it is, counting from zero."
  @spec repeat_indexed(t(), pos_integer(), (t(), non_neg_integer() -> t())) :: t()
  def repeat_indexed(%__MODULE__{} = part, times, fun) do
    Enum.reduce(0..(times - 1)//1, part, fn index, acc -> fun.(acc, index) end)
  end

  @doc "Change the voice, or `t:instrument/0`, used for everything after this point."
  @spec synth(t(), Voice.t() | instrument()) :: t()
  def synth(%__MODULE__{} = part, %Voice{} = voice), do: %{part | synth: voice}

  def synth(%__MODULE__{} = part, instrument) when is_function(instrument, 1),
    do: %{part | synth: instrument}

  @doc "Change the part's level for everything after this point."
  @spec gain(t(), number()) :: t()
  def gain(%__MODULE__{} = part, gain), do: %{part | gain: gain * 1.0}

  @doc """
  Move the part in the stereo field for everything after this point.

  Clamped to `-1.0` to `1.0`.
  """
  @spec pan(t(), number()) :: t()
  def pan(%__MODULE__{} = part, pan), do: %{part | pan: clamp_pan(pan * 1.0)}

  @doc """
  How far the part runs, in beats.

  The later of the cursor and the end of its last-ringing note.
  """
  @spec beats(t()) :: float()
  def beats(%__MODULE__{} = part) do
    part.notes
    |> Enum.map(fn {beat, voice} -> beat + Voice.duration(voice) * part.bpm / 60.0 end)
    |> Enum.max(fn -> 0.0 end)
    |> max(part.cursor)
  end

  @doc "The part's notes, as `{beat, voice}`, in the order they were played."
  @spec notes(t()) :: [{float(), Voice.t()}]
  def notes(%__MODULE__{notes: notes}), do: Enum.reverse(notes)

  defp place(part, voice, opts) do
    {opts, part} = resolve(opts, part)

    voice =
      voice
      |> apply_release(Keyword.get(opts, :release), part.bpm)
      |> then(&%{&1 | gain: &1.gain * part.gain * Keyword.get(opts, :gain, 1.0)})
      |> then(&%{&1 | pan: clamp_pan(&1.pan + part.pan + Keyword.get(opts, :pan, 0.0))})
      |> then(&%{&1 | curves: curves(opts, &1.curves)})

    %{part | notes: [{part.cursor, voice} | part.notes]}
  end

  defp clamp_pan(pan), do: pan |> max(-1.0) |> min(1.0)

  defp curves(opts, existing) do
    bend =
      case Keyword.get(opts, :bend) do
        nil -> %{}
        semitones -> %{freq: Curve.linear(1.0, :math.pow(2.0, semitones / 12.0))}
      end

    existing |> Map.merge(bend) |> Map.merge(Keyword.get(opts, :curves, %{}))
  end

  defp resolve(opts, part) do
    Enum.map_reduce(opts, part, fn
      {key, {:between, low, high}}, acc ->
        {value, acc} = between(acc, low, high)
        {{key, value}, acc}

      pair, acc ->
        {pair, acc}
    end)
  end

  defp apply_release(voice, nil, _bpm), do: voice

  defp apply_release(voice, release, bpm) do
    %{voice | envelope: Envelope.spanning(voice.envelope || Envelope.new(), release * 60.0 / bpm)}
  end

  defp advance(part, beats), do: %{part | cursor: part.cursor + beats * 1.0}
end

defmodule TuningFork.SonicPi.Names do
  @moduledoc """
  Notes, chords and scales by Sonic Pi's names, as MIDI numbers.

      iex> TuningFork.SonicPi.Names.chord(:e3, :m7)
      [52, 55, 59, 62]
  """

  alias TuningFork.Notes

  @chords %{
    major: [0, 4, 7],
    M: [0, 4, 7],
    minor: [0, 3, 7],
    m: [0, 3, 7],
    major7: [0, 4, 7, 11],
    M7: [0, 4, 7, 11],
    maj7: [0, 4, 7, 11],
    dom7: [0, 4, 7, 10],
    "7": [0, 4, 7, 10],
    minor7: [0, 3, 7, 10],
    m7: [0, 3, 7, 10],
    aug: [0, 4, 8],
    augmented: [0, 4, 8],
    dim: [0, 3, 6],
    diminished: [0, 3, 6],
    dim7: [0, 3, 6, 9],
    diminished7: [0, 3, 6, 9],
    halfdim: [0, 3, 6, 10],
    m7b5: [0, 3, 6, 10],
    sus2: [0, 2, 7],
    sus4: [0, 5, 7],
    "7sus2": [0, 2, 7, 10],
    "7sus4": [0, 5, 7, 10],
    "6": [0, 4, 7, 9],
    m6: [0, 3, 7, 9],
    "9": [0, 4, 7, 10, 14],
    m9: [0, 3, 7, 10, 14],
    maj9: [0, 4, 7, 11, 14],
    major9: [0, 4, 7, 11, 14],
    add9: [0, 4, 7, 14],
    madd9: [0, 3, 7, 14],
    "11": [0, 4, 7, 10, 14, 17],
    m11: [0, 3, 7, 10, 14, 17],
    "13": [0, 4, 7, 10, 14, 17, 21],
    m13: [0, 3, 7, 10, 14, 17, 21],
    "5": [0, 7],
    "1": [0],
    i: [0, 3, 7],
    "+5": [0, 4, 8],
    "m+5": [0, 3, 8]
  }

  @scales %{
    major: [2, 2, 1, 2, 2, 2, 1],
    ionian: [2, 2, 1, 2, 2, 2, 1],
    minor: [2, 1, 2, 2, 1, 2, 2],
    aeolian: [2, 1, 2, 2, 1, 2, 2],
    dorian: [2, 1, 2, 2, 2, 1, 2],
    phrygian: [1, 2, 2, 2, 1, 2, 2],
    lydian: [2, 2, 2, 1, 2, 2, 1],
    mixolydian: [2, 2, 1, 2, 2, 1, 2],
    locrian: [1, 2, 2, 1, 2, 2, 2],
    harmonic_minor: [2, 1, 2, 2, 1, 3, 1],
    melodic_minor: [2, 1, 2, 2, 2, 2, 1],
    major_pentatonic: [2, 2, 3, 2, 3],
    minor_pentatonic: [3, 2, 2, 3, 2],
    blues_major: [2, 1, 1, 3, 2, 3],
    blues_minor: [3, 2, 1, 1, 3, 2],
    whole_tone: [2, 2, 2, 2, 2, 2],
    chromatic: List.duplicate(1, 12),
    egyptian: [2, 3, 2, 3, 2],
    hungarian_minor: [2, 1, 3, 1, 1, 3, 1],
    spanish: [1, 3, 1, 2, 1, 2, 2],
    neapolitan_minor: [1, 2, 2, 2, 1, 3, 1],
    neapolitan_major: [1, 2, 2, 2, 2, 2, 1],
    diminished: [2, 1, 2, 1, 2, 1, 2, 1],
    diminished2: [1, 2, 1, 2, 1, 2, 1, 2],
    octatonic: [2, 1, 2, 1, 2, 1, 2, 1],
    japanese: [1, 4, 2, 1, 4],
    hirajoshi: [2, 1, 4, 1, 4],
    kumoi: [2, 1, 4, 2, 3],
    yu: [3, 2, 2, 3, 2],
    zhi: [2, 3, 2, 2, 3],
    gong: [2, 2, 3, 2, 3],
    shang: [2, 3, 2, 3, 2],
    jiao: [3, 2, 3, 2, 2],
    hex_major6: [2, 2, 3, 2, 2, 1],
    hex_dorian: [2, 1, 2, 2, 3, 2],
    hex_phrygian: [1, 2, 2, 3, 2, 2],
    hex_major7: [2, 2, 3, 2, 2, 1],
    hex_sus: [2, 3, 2, 2, 3],
    hex_aeolian: [2, 1, 2, 2, 1, 4],
    bartok: [2, 2, 1, 2, 1, 2, 2],
    super_locrian: [1, 2, 1, 2, 2, 2, 2],
    ahirbhairav: [1, 3, 1, 2, 2, 1, 2],
    indian: [4, 1, 2, 3, 2],
    pelog: [1, 2, 4, 1, 4],
    prometheus: [2, 2, 2, 5, 1],
    scriabin: [1, 3, 3, 2, 3],
    ritusen: [2, 3, 2, 2, 3],
    todi: [1, 2, 3, 1, 1, 3, 1],
    marva: [1, 3, 2, 1, 2, 2, 1],
    purvi: [1, 3, 2, 1, 1, 3, 1],
    bhairav: [1, 3, 1, 2, 1, 3, 1],
    enigmatic: [1, 3, 2, 2, 2, 1, 1],
    romanian_minor: [2, 1, 3, 1, 2, 1, 2],
    lydian_minor: [2, 2, 2, 1, 1, 2, 2],
    augmented: [3, 1, 3, 1, 3, 1],
    augmented2: [1, 3, 1, 3, 1, 3],
    leading_whole: [2, 2, 2, 2, 2, 1, 1],
    minor_pentatonic_blues: [3, 2, 1, 1, 3, 2]
  }

  @doc "The MIDI number of `note`, or `nil` for `nil`. Hertz become a fractional number."
  @spec midi(term()) :: number() | nil
  def midi(nil), do: nil
  def midi(midi) when is_integer(midi), do: midi
  def midi(hz) when is_float(hz), do: hz_to_midi(hz)
  def midi(name) when is_atom(name), do: name |> Atom.to_string() |> midi()

  def midi(name) when is_binary(name) do
    Notes.semitone(normalise(name))
  end

  @doc "`midi/1`, moved to octave `octave` when one is given."
  @spec midi(term(), keyword()) :: number() | nil
  def midi(note, opts) do
    case {midi(note), Keyword.get(opts, :octave)} do
      {nil, _octave} -> nil
      {number, nil} -> number
      {number, octave} -> Integer.mod(round(number), 12) + (octave + 1) * 12
    end
  end

  @doc "The frequency of `note` in hertz. A float is already one."
  @spec hz(term()) :: float()
  def hz(hz) when is_float(hz), do: hz
  def hz(note), do: midi_to_hz(midi(note))

  @doc "The name of a MIDI number, the way `TuningFork.Notes.name_of/1` spells it."
  @spec name(number()) :: atom()
  def name(midi), do: midi |> round() |> Notes.name_of()

  @doc "Hertz for a MIDI number, which may be fractional."
  @spec midi_to_hz(number()) :: float()
  def midi_to_hz(midi), do: 440.0 * :math.pow(2.0, (midi - 69) / 12.0)

  @doc "A MIDI number, fractional, for a frequency in hertz."
  @spec hz_to_midi(number()) :: float()
  def hz_to_midi(hz), do: 69.0 + 12.0 * :math.log2(hz / 440.0)

  @doc """
  The notes of a chord, as MIDI numbers.

  `:num_octaves` repeats it up the keyboard; `:invert` moves the lowest notes up an octave that
  many times.
  """
  @spec chord(term(), atom() | String.t(), keyword()) :: [integer()]
  def chord(root, name, opts \\ []) do
    intervals =
      Map.get(@chords, to_atom(name)) || raise ArgumentError, "no chord named #{inspect(name)}"

    octaves = Keyword.get(opts, :num_octaves, 1)

    notes =
      for octave <- 0..(octaves - 1),
          interval <- intervals,
          do: midi(root) + interval + 12 * octave

    invert(notes, Keyword.get(opts, :invert, 0))
  end

  @doc "The notes of a scale as MIDI numbers, from `root` up `:num_octaves` octaves (default 1) and the note above."
  @spec scale(term(), atom() | String.t(), keyword()) :: [integer()]
  def scale(root, name, opts \\ []) do
    steps =
      Map.get(@scales, to_atom(name)) || raise ArgumentError, "no scale named #{inspect(name)}"

    octaves = Keyword.get(opts, :num_octaves, 1)
    span = Enum.sum(steps)

    climbed =
      for octave <- 0..(octaves - 1), reduce: [midi(root)] do
        acc ->
          base = midi(root) + octave * span

          {_at, notes} =
            Enum.reduce(steps, {base, []}, fn step, {at, acc} ->
              {at + step, [at + step | acc]}
            end)

          acc ++ Enum.reverse(notes)
      end

    climbed
  end

  @doc """
  A chord built on the `degree`th note of a scale: `count` notes, every other scale step.

  `:invert` as `chord/3`.
  """
  @spec chord_degree(integer(), term(), atom(), pos_integer(), keyword()) :: [integer()]
  def chord_degree(degree, tonic, scale_name, count \\ 4, opts \\ []) do
    notes = for index <- 0..(count - 1), do: degree(degree + index * 2, tonic, scale_name)
    invert(notes, Keyword.get(opts, :invert, 0))
  end

  @doc "The chord names known."
  @spec chords() :: [atom()]
  def chords, do: @chords |> Map.keys() |> Enum.sort()

  @doc "The scale names known."
  @spec scales() :: [atom()]
  def scales, do: @scales |> Map.keys() |> Enum.sort()

  @doc "The `degree`th note of a scale as a MIDI number, counting from 1."
  @spec degree(integer(), term(), atom()) :: integer()
  def degree(degree, tonic, scale_name) do
    steps =
      Map.get(@scales, to_atom(scale_name)) ||
        raise ArgumentError, "no scale named #{inspect(scale_name)}"

    count = length(steps)
    index = degree - 1
    octave = Integer.floor_div(index, count)
    within = Integer.mod(index, count)
    offset = steps |> Enum.take(within) |> Enum.sum()

    midi(tonic) + octave * Enum.sum(steps) + offset
  end

  defp invert(notes, 0), do: notes
  defp invert([lowest | rest], times) when times > 0, do: invert(rest ++ [lowest + 12], times - 1)

  defp invert(notes, times) when times < 0 do
    {front, [highest]} = Enum.split(notes, -1)
    invert([highest - 12 | front], times + 1)
  end

  defp to_atom(name) when is_atom(name), do: name
  defp to_atom(name) when is_binary(name), do: String.to_atom(name)

  defp normalise(name) do
    lowered = String.downcase(name)

    if String.match?(lowered, ~r/\d$/), do: lowered, else: lowered <> "4"
  end
end

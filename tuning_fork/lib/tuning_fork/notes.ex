defmodule TuningFork.Notes do
  @moduledoc """
  Pitches, scales and chords by note name, such as `:a4`, `:fs3` or `:eb5`.

      Notes.scale(:a3, :minor_pentatonic)
  """

  @letters %{c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11}

  @scales %{
    major: [0, 2, 4, 5, 7, 9, 11],
    minor: [0, 2, 3, 5, 7, 8, 10],
    harmonic_minor: [0, 2, 3, 5, 7, 8, 11],
    dorian: [0, 2, 3, 5, 7, 9, 10],
    phrygian: [0, 1, 3, 5, 7, 8, 10],
    mixolydian: [0, 2, 4, 5, 7, 9, 10],
    lydian: [0, 2, 4, 6, 7, 9, 11],
    major_pentatonic: [0, 2, 4, 7, 9],
    minor_pentatonic: [0, 3, 5, 7, 10],
    blues: [0, 3, 5, 6, 7, 10],
    whole_tone: [0, 2, 4, 6, 8, 10],
    chromatic: Enum.to_list(0..11)
  }

  @chords %{
    major: [0, 4, 7],
    minor: [0, 3, 7],
    diminished: [0, 3, 6],
    augmented: [0, 4, 8],
    sus2: [0, 2, 7],
    sus4: [0, 5, 7],
    major7: [0, 4, 7, 11],
    minor7: [0, 3, 7, 10],
    dominant7: [0, 4, 7, 10],
    minor9: [0, 3, 7, 10, 14],
    major9: [0, 4, 7, 11, 14],
    add9: [0, 4, 7, 14],
    fifth: [0, 7]
  }

  @doc """
  The frequency of a note name in Hz; `:a4` is 440.0.

  A note name is a letter `a` to `g`, an optional `s` for sharp or `b` for flat, then an
  octave, which may be negative. A number is returned as a float unchanged. An atom that is
  not a note name raises `ArgumentError`.
  """
  @spec freq(atom() | number()) :: float()
  def freq(hz) when is_number(hz), do: hz * 1.0

  def freq(name) when is_atom(name) do
    440.0 * :math.pow(2.0, (semitone(name) - 69) / 12.0)
  end

  @doc """
  The MIDI number of a note name, with `:a4` being 69.

  Takes the name as an atom or a string; the string need not exist as an atom. Raises `ArgumentError` on anything that is not a note name.
  """
  @spec semitone(atom() | String.t()) :: integer()
  def semitone(name) when is_atom(name), do: semitone(Atom.to_string(name))

  def semitone(name) when is_binary(name) do
    {letter, accidental, octave} = parse(name)
    Map.fetch!(@letters, letter) + accidental + (octave + 1) * 12
  end

  @doc "The frequency `interval` semitones from `name`. A negative interval goes down."
  @spec step(atom() | number(), integer()) :: float()
  def step(name, interval), do: freq(name) * :math.pow(2.0, interval / 12.0)

  @doc "The names `scale/3` accepts."
  @spec scales() :: [atom()]
  def scales, do: Map.keys(@scales)

  @doc "The names `chord/2` accepts."
  @spec chords() :: [atom()]
  def chords, do: Map.keys(@chords)

  @doc """
  A scale from `root`, as note names, ascending.

  `name` must be one of `scales/0`. `:octaves` gives that many octaves, each continuing
  upwards from the last rather than starting again; default 1.
  """
  @spec scale(atom(), atom(), keyword()) :: [atom()]
  def scale(root, name, opts \\ []) do
    intervals = Map.fetch!(@scales, name)
    octaves = Keyword.get(opts, :octaves, 1)

    for octave <- 0..(octaves - 1), interval <- intervals do
      name_of(semitone(root) + interval + octave * 12)
    end
  end

  @doc "A chord from `root`, as note names. `name` must be one of `chords/0`."
  @spec chord(atom(), atom()) :: [atom()]
  def chord(root, name) do
    for interval <- Map.fetch!(@chords, name), do: name_of(semitone(root) + interval)
  end

  @doc """
  The name of a MIDI number, using sharps: `name_of(semitone(:eb5))` is `:ds5`.
  """
  @spec name_of(integer()) :: atom()
  def name_of(midi) do
    names = ~w(c cs d ds e f fs g gs a as b)
    octave = div(midi, 12) - 1
    :"#{Enum.at(names, rem(midi, 12))}#{octave}"
  end

  defp parse(text) do
    case Regex.run(~r/^([a-g])([sb]?)(-?\d+)$/, text, capture: :all_but_first) do
      [letter, accidental, octave] ->
        {String.to_existing_atom(letter), shift(accidental), String.to_integer(octave)}

      nil ->
        raise ArgumentError, "#{inspect(text)} is not a note name, such as :a4, :fs3 or :eb5"
    end
  end

  defp shift("s"), do: 1
  defp shift("b"), do: -1
  defp shift(_natural), do: 0
end

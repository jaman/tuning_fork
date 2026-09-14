defmodule TuningFork.Scale do
  @moduledoc """
  Named scales, and the MIDI notes their degrees stand for.

      iex> TuningFork.Scale.midi("g:minor", 4)
      62
  """

  @steps %{
    major: [0, 2, 4, 5, 7, 9, 11],
    ionian: [0, 2, 4, 5, 7, 9, 11],
    minor: [0, 2, 3, 5, 7, 8, 10],
    aeolian: [0, 2, 3, 5, 7, 8, 10],
    dorian: [0, 2, 3, 5, 7, 9, 10],
    phrygian: [0, 1, 3, 5, 7, 8, 10],
    lydian: [0, 2, 4, 6, 7, 9, 11],
    mixolydian: [0, 2, 4, 5, 7, 9, 10],
    locrian: [0, 1, 3, 5, 6, 8, 10],
    harmonic_minor: [0, 2, 3, 5, 7, 8, 11],
    melodic_minor: [0, 2, 3, 5, 7, 9, 11],
    major_pentatonic: [0, 2, 4, 7, 9],
    minor_pentatonic: [0, 3, 5, 7, 10],
    blues: [0, 3, 5, 6, 7, 10],
    whole_tone: [0, 2, 4, 6, 8, 10],
    chromatic: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
  }

  @pitch_classes %{
    "c" => 0,
    "cs" => 1,
    "db" => 1,
    "d" => 2,
    "ds" => 3,
    "eb" => 3,
    "e" => 4,
    "f" => 5,
    "fs" => 6,
    "gb" => 6,
    "g" => 7,
    "gs" => 8,
    "ab" => 8,
    "a" => 9,
    "as" => 10,
    "bb" => 10,
    "b" => 11
  }

  @default_octave 3

  @type name :: atom()

  @doc "Every scale name, sorted."
  @spec names() :: [name()]
  def names, do: @steps |> Map.keys() |> Enum.sort()

  @doc """
  The semitones a scale's degrees sit on, from its root.

      iex> TuningFork.Scale.steps(:minor)
      [0, 2, 3, 5, 7, 8, 10]

  Returns `nil` for a name there is no scale for.
  """
  @spec steps(name() | String.t()) :: [non_neg_integer()] | nil
  def steps(name) when is_atom(name), do: Map.get(@steps, name)

  def steps(name) when is_binary(name) do
    case Enum.find(names(), &(Atom.to_string(&1) == name)) do
      nil -> nil
      found -> Map.get(@steps, found)
    end
  end

  @doc """
  Split `"g2:minor"` into its root note and scale.

  The root is a letter with `s` for sharp or `b` for flat and an optional octave. Returns
  `{:ok, root_midi, scale}` or `{:error, reason}`. Without an octave the root is in octave
  #{@default_octave}; without a scale it is `:major`.

      iex> TuningFork.Scale.parse("eb2:dorian")
      {:ok, 39, :dorian}
  """
  @spec parse(String.t()) :: {:ok, integer(), name()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    {root, scale} =
      case String.split(text, ":", parts: 2) do
        [root] -> {root, "major"}
        [root, scale] -> {root, scale}
      end

    with {:ok, midi} <- root(String.downcase(root)),
         {:ok, name} <- scale(String.downcase(String.trim(scale))) do
      {:ok, midi, name}
    end
  end

  defp root(text) do
    {letters, digits} = String.split_at(text, letters_in(text))

    case Map.fetch(@pitch_classes, letters) do
      :error ->
        {:error, "#{inspect(text)} is not a note; try c, fs, eb"}

      {:ok, pitch_class} ->
        octave = if digits == "", do: @default_octave, else: String.to_integer(digits)

        {:ok, 12 * (octave + 1) + pitch_class}
    end
  rescue
    ArgumentError -> {:error, "#{inspect(text)} is not a note; try c3, fs4, eb2"}
  end

  defp letters_in(text) do
    text |> String.graphemes() |> Enum.take_while(&(&1 =~ ~r/[a-z]/)) |> length()
  end

  defp scale(text) do
    case Enum.find(names(), &(Atom.to_string(&1) == text)) do
      nil -> {:error, "#{inspect(text)} is not a scale; see TuningFork.Scale.names/0"}
      found -> {:ok, found}
    end
  end

  @doc """
  The MIDI note `degree` stands for in `scale`.

  `scale` is a `"root:name"` string as `parse/1` reads it, or a `{root_midi, name}` pair.
  Degree 0 is the root; degrees past the scale's length carry into the octave above and
  negative degrees into the octave below. Returns `nil` for a scale it cannot read.

      iex> TuningFork.Scale.midi("g:minor", 7)
      67
      iex> TuningFork.Scale.midi("g:minor", -1)
      53
  """
  @spec midi(String.t() | {integer(), name()}, integer()) :: integer() | nil
  def midi(scale, degree)

  def midi({root, name}, degree) do
    case steps(name) do
      nil -> nil
      steps -> root + interval(steps, degree)
    end
  end

  def midi(text, degree) when is_binary(text) do
    case parse(text) do
      {:ok, root, name} -> midi({root, name}, degree)
      {:error, _reason} -> nil
    end
  end

  @doc """
  How many semitones above the root `degree` sits, wrapping into octaves.

      iex> TuningFork.Scale.interval([0, 2, 3, 5, 7, 8, 10], 9)
      15
  """
  @spec interval([non_neg_integer()], integer()) :: integer()
  def interval(steps, degree) do
    count = length(steps)
    octaves = Integer.floor_div(degree, count)
    index = Integer.mod(degree, count)

    Enum.at(steps, index) + 12 * octaves
  end
end

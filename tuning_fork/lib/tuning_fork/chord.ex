defmodule TuningFork.Chord do
  @moduledoc """
  Chord names to the MIDI notes that play them.

      iex> TuningFork.Chord.notes("C^7")
      [60, 64, 67, 71]
  """

  @roots %{"c" => 0, "d" => 2, "e" => 4, "f" => 5, "g" => 7, "a" => 9, "b" => 11}

  @qualities %{
    "" => [0, 4, 7],
    "M" => [0, 4, 7],
    "maj" => [0, 4, 7],
    "m" => [0, 3, 7],
    "min" => [0, 3, 7],
    "-" => [0, 3, 7],
    "+" => [0, 4, 8],
    "aug" => [0, 4, 8],
    "o" => [0, 3, 6],
    "dim" => [0, 3, 6],
    "5" => [0, 7],
    "6" => [0, 4, 7, 9],
    "m6" => [0, 3, 7, 9],
    "7" => [0, 4, 7, 10],
    "^7" => [0, 4, 7, 11],
    "maj7" => [0, 4, 7, 11],
    "M7" => [0, 4, 7, 11],
    "m7" => [0, 3, 7, 10],
    "min7" => [0, 3, 7, 10],
    "-7" => [0, 3, 7, 10],
    "o7" => [0, 3, 6, 9],
    "dim7" => [0, 3, 6, 9],
    "m7b5" => [0, 3, 6, 10],
    "ø" => [0, 3, 6, 10],
    "9" => [0, 4, 7, 10, 14],
    "^9" => [0, 4, 7, 11, 14],
    "maj9" => [0, 4, 7, 11, 14],
    "m9" => [0, 3, 7, 10, 14],
    "sus2" => [0, 2, 7],
    "sus4" => [0, 5, 7]
  }

  @middle 60

  @doc "Every quality this knows, sorted."
  @spec qualities() :: [String.t()]
  def qualities, do: @qualities |> Map.keys() |> Enum.sort()

  @doc """
  The MIDI notes of `name`, low to high, or `[]` for a name it does not know.

  `name` is a string or atom made of a root letter, an optional accidental (`#`, `s` or `b`)
  and one of `qualities/0`: `C`, `Eb`, `F#m7`, `Bb^9`. The root is read at octave 4, so `C`
  is 60.

      iex> TuningFork.Chord.notes("F#m7")
      [66, 69, 73, 76]
      iex> TuningFork.Chord.notes("nonsense")
      []
  """
  @spec notes(term()) :: [integer()]
  def notes(name) when is_binary(name) do
    with {:ok, root, rest} <- root(name),
         {:ok, intervals} <- Map.fetch(@qualities, rest) do
      Enum.map(intervals, &(@middle + root + &1))
    else
      _unknown -> []
    end
  end

  def notes(name) when is_atom(name) and not is_nil(name), do: notes(Atom.to_string(name))
  def notes(_name), do: []

  @doc """
  The same chord moved to `octave`, where 4 is where `notes/1` leaves it.

      iex> TuningFork.Chord.octave("C", 3)
      [48, 52, 55]
  """
  @spec octave(term(), integer()) :: [integer()]
  def octave(name, octave) do
    name |> notes() |> Enum.map(&(&1 + 12 * (octave - 4)))
  end

  defp root(<<letter::binary-size(1), rest::binary>>) do
    case Map.fetch(@roots, String.downcase(letter)) do
      {:ok, semitone} -> accidental(semitone, rest)
      :error -> :error
    end
  end

  defp root(_name), do: :error

  defp accidental(semitone, <<"#", rest::binary>>), do: {:ok, semitone + 1, rest}
  defp accidental(semitone, <<"s", rest::binary>>), do: {:ok, semitone + 1, rest}
  defp accidental(semitone, <<"b", rest::binary>>), do: {:ok, semitone - 1, rest}
  defp accidental(semitone, rest), do: {:ok, semitone, rest}
end

defmodule TuningFork.Pattern.Voicing do
  @moduledoc """
  Chord symbols to voicings, as Strudel renders them.

      iex> TuningFork.Pattern.Voicing.render("Cm7")
      [58, 63, 67, 70, 72]
  """

  alias TuningFork.Pattern.Voicing.Ireal

  @type mode :: :below | :above | :root | :duck

  @lefthand %{
    "m7" => ["3m 5P 7m 9M", "7m 9M 10m 12P"],
    "7" => ["3M 6M 7m 9M", "7m 9M 10M 13M"],
    "^7" => ["3M 5P 7M 9M", "7M 9M 10M 12P"],
    "69" => ["3M 5P 6A 9M"],
    "m7b5" => ["3m 5d 7m 8P", "7m 8P 10m 12d"],
    "7b9" => ["3M 6m 7m 9m", "7m 9m 10M 13m"],
    "7b13" => ["3M 6m 7m 9m", "7m 9m 10M 13m"],
    "o7" => ["1P 3m 5d 6M", "5d 6M 8P 10m"],
    "7#11" => ["7m 9M 11A 13A"],
    "7#9" => ["3M 7m 9A"],
    "mM7" => ["3m 5P 7M 9M", "7M 9M 10m 12P"],
    "m6" => ["3m 5P 6M 9M", "6M 9M 10m 12P"]
  }

  @guidetones %{
    "m7" => ["3m 7m", "7m 10m"],
    "m9" => ["3m 7m", "7m 10m"],
    "7" => ["3M 7m", "7m 10M"],
    "^7" => ["3M 7M", "7M 10M"],
    "^9" => ["3M 7M", "7M 10M"],
    "69" => ["3M 6M"],
    "6" => ["3M 6M", "6M 10M"],
    "m7b5" => ["3m 7m", "7m 10m"],
    "7b9" => ["3M 7m", "7m 10M"],
    "7b13" => ["3M 7m", "7m 10M"],
    "o7" => ["3m 6M", "6M 10m"],
    "7#11" => ["3M 7m", "7m 10M"],
    "7#9" => ["3M 7m", "7m 10M"],
    "mM7" => ["3m 7M", "7M 10m"],
    "m6" => ["3m 6M", "6M 10m"]
  }

  @triads %{
    "" => ["1P 3M 5P", "3M 5P 8P", "5P 8P 10M"],
    "M" => ["1P 3M 5P", "3M 5P 8P", "5P 8P 10M"],
    "m" => ["1P 3m 5P", "3m 5P 8P", "5P 8P 10m"],
    "o" => ["1P 3m 5d", "3m 5d 8P", "5d 8P 10m"],
    "aug" => ["1P 3m 5A", "3m 5A 8P", "5A 8P 10m"]
  }

  @legacy Map.merge(@triads, @lefthand)

  @registry %{
    ireal: %{mode: :below, anchor: "c5"},
    "ireal-ext": %{mode: :below, anchor: "c5"},
    lefthand: %{mode: :below, anchor: "a4"},
    triads: %{mode: :below, anchor: "a4"},
    guidetones: %{mode: :above, anchor: "a4"},
    legacy: %{mode: :below, anchor: "a4"}
  }

  @chromas %{"c" => 0, "d" => 2, "e" => 4, "f" => 5, "g" => 7, "a" => 9, "b" => 11}

  @base %{
    1 => 0,
    2 => 2,
    3 => 4,
    4 => 5,
    5 => 7,
    6 => 9,
    7 => 11,
    8 => 12,
    9 => 14,
    10 => 16,
    11 => 17,
    12 => 19,
    13 => 21,
    14 => 23,
    15 => 24,
    16 => 26,
    17 => 28
  }
  @perfect [1, 4, 5, 8, 11, 12, 15]

  @doc "The dictionary names `render/2` takes."
  @spec dictionaries() :: [atom()]
  def dictionaries, do: Map.keys(@registry)

  @doc """
  The MIDI notes of `chord` voiced from a dictionary, or `:error` for a symbol it lacks.

  ## Options

    * `:dictionary` — one of `dictionaries/0`, default `:ireal`
    * `:anchor` — a note name or MIDI number the voicing is placed against; default the
      dictionary's, `c5` for `:ireal`
    * `:mode` — `:below` (top note at or under the anchor), `:above` (bottom note at or over
      it), `:root` (the root at or under it), or `:duck` (below, dropping a note that lands on
      the anchor); default the dictionary's
    * `:offset` — how many voicings along the dictionary's list to move, default 0
    * `:n` — one tone of the voicing instead of all of it, counting from 0 and wrapping into
      the octaves above and below
    * `:octaves` — how far `:n` moves per wrap, default 1
  """
  @spec render(String.t(), keyword()) :: [integer()] | :error
  def render(chord, opts \\ []) do
    name = Keyword.get(opts, :dictionary, :ireal)

    settings =
      Map.get(@registry, name) ||
        raise ArgumentError, "no voicing dictionary named #{inspect(name)}"

    with {:ok, root, symbol} <- tokenize(chord),
         {:ok, voicings} <- Map.fetch(dictionary(name), symbol) do
      anchor = opts |> Keyword.get(:anchor, settings.anchor) |> to_midi(4)
      mode = Keyword.get(opts, :mode, settings.mode)
      offset = Keyword.get(opts, :offset, 0)

      voicings =
        Enum.map(voicings, fn voicing ->
          voicing |> String.split(" ") |> Enum.map(&semitones/1)
        end)

      root_chroma = chroma(root)
      anchor_chroma = Integer.mod(anchor, 12)

      diffs =
        Enum.map(voicings, fn voicing ->
          Integer.mod(anchor_chroma - target(mode, voicing) - root_chroma, 12)
        end)

      best =
        if mode == :root,
          do: 0,
          else: diffs |> Enum.with_index() |> Enum.min_by(&elem(&1, 0)) |> elem(1)

      count = length(voicings)
      octaves_up = ceil_div(offset, count) * 12
      index = Integer.mod(best + offset, count)
      voicing = Enum.at(voicings, index)
      anchor_midi = anchor - Enum.at(diffs, index) + octaves_up
      notes = Enum.map(voicing, fn step -> anchor_midi - target(mode, voicing) + step end)
      notes = if mode == :duck, do: Enum.reject(notes, &(&1 == anchor)), else: notes

      case Keyword.get(opts, :n) do
        nil -> notes
        n -> [scale_step(notes, n, Keyword.get(opts, :octaves, 1))]
      end
    else
      _missing -> :error
    end
  end

  @doc "Whether `symbol` is a chord symbol `render/2` knows in `dictionary`."
  @spec known?(String.t(), atom()) :: boolean()
  def known?(chord, dictionary \\ :ireal) do
    case tokenize(chord) do
      {:ok, _root, symbol} -> Map.has_key?(dictionary(dictionary), symbol)
      :error -> false
    end
  end

  defp dictionary(:ireal), do: Ireal.simple()
  defp dictionary(:"ireal-ext"), do: Ireal.complex()
  defp dictionary(:lefthand), do: @lefthand
  defp dictionary(:triads), do: @triads
  defp dictionary(:guidetones), do: @guidetones
  defp dictionary(:legacy), do: @legacy

  defp tokenize(chord) do
    case Regex.run(~r/^([A-G][b#]*)([^\/]*)\/?([A-G][b#]*)?$/, chord || "") do
      [_, root, symbol | _bass] -> {:ok, root, symbol}
      nil -> :error
    end
  end

  defp chroma(<<letter, rest::binary>>) do
    base = Map.fetch!(@chromas, String.downcase(<<letter>>))
    Integer.mod(base + accidentals(rest), 12)
  end

  defp accidentals(text) do
    text
    |> String.graphemes()
    |> Enum.reduce(0, fn
      "#", acc -> acc + 1
      "b", acc -> acc - 1
      _, acc -> acc
    end)
  end

  defp to_midi(midi, _default) when is_integer(midi), do: midi

  defp to_midi(name, default) when is_binary(name) do
    [_, letter, acc, octave] = Regex.run(~r/^([a-gA-G])([#bsf]*)(-?[0-9]*)$/, name)
    octave = if octave == "", do: default, else: String.to_integer(octave)
    (octave + 1) * 12 + Map.fetch!(@chromas, String.downcase(letter)) + accidentals(acc)
  end

  defp to_midi(%{note: note}, default), do: to_midi(note, default)

  defp semitones(interval) do
    case Regex.run(~r/^(\d+)([PMmAd])$/, interval) do
      [_, number, quality] -> qualified(String.to_integer(number), quality)
      nil -> String.to_integer(interval)
    end
  end

  defp qualified(number, "m"), do: Map.fetch!(@base, number) - 1
  defp qualified(number, "A"), do: Map.fetch!(@base, number) + 1
  defp qualified(number, "d") when number in @perfect, do: Map.fetch!(@base, number) - 1
  defp qualified(number, "d"), do: Map.fetch!(@base, number) - 2
  defp qualified(number, _perfect_or_major), do: Map.fetch!(@base, number)

  defp target(mode, voicing) when mode in [:below, :duck], do: List.last(voicing)
  defp target(mode, voicing) when mode in [:above, :root], do: hd(voicing)

  defp ceil_div(a, b), do: -Integer.floor_div(-a, b)

  defp scale_step(notes, n, octaves) do
    count = length(notes)
    Enum.at(notes, Integer.mod(n, count)) + Integer.floor_div(n, count) * octaves * 12
  end
end

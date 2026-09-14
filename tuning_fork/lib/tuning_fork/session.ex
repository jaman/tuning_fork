defmodule TuningFork.Session do
  @moduledoc """
  Rows of live-coded source, and the one pattern they add up to.

      rows = [%{source: "s(\\"bd*4\\")"}, %{source: "|> gain(0.8)"}, %{source: "-- hh*8"}]
      TuningFork.Session.combined(rows)
  """

  alias TuningFork.{Pattern, Strudel}
  alias TuningFork.Pattern.{Control, Source}

  @typedoc """
  A row of a session. Only `:source` is required; `checked/1` writes `:error`. Any other key
  is left alone.
  """
  @type row :: %{required(:source) => String.t(), optional(:error) => String.t() | nil}

  @typedoc "A chain of rows folded into the source it makes: `{first row, last row, source}`."
  @type chain :: {non_neg_integer(), non_neg_integer(), String.t()}

  @doc """
  The markers that switch a row off, longest first.

      iex> TuningFork.Session.off()
      ["--", "//", "_"]
  """
  @spec off() :: [String.t()]
  def off, do: ["--", "//", "_"]

  @doc """
  Whether a row is switched on and has something in it: not blank and not beginning with one
  of `off/0`.

      iex> TuningFork.Session.live?(%{source: "s(\\"bd\\")"})
      true
      iex> TuningFork.Session.live?(%{source: "_ s(\\"bd\\")"})
      false
      iex> TuningFork.Session.live?(%{source: "   "})
      false
  """
  @spec live?(row() | String.t()) :: boolean()
  def live?(%{source: source}), do: live?(source)

  def live?(source) when is_binary(source) do
    trimmed = String.trim(source)

    trimmed != "" and not String.starts_with?(trimmed, off())
  end

  @doc """
  Whether a row carries on the one above it rather than starting its own: it begins with `|>`.

      iex> TuningFork.Session.continues?(%{source: "  |> scale(\\"g:minor\\")"})
      true
      iex> TuningFork.Session.continues?(%{source: "s(\\"bd\\")"})
      false
  """
  @spec continues?(row() | String.t()) :: boolean()
  def continues?(%{source: source}), do: continues?(source)
  def continues?(source) when is_binary(source), do: Source.continues?(source)

  @doc """
  Put a row's marker on, or take off whichever of `off/0` is there.

      iex> TuningFork.Session.comment("s(\\"bd\\")")
      "-- s(\\"bd\\")"
      iex> TuningFork.Session.comment("-- s(\\"bd\\")")
      "s(\\"bd\\")"
      iex> TuningFork.Session.comment("_ s(\\"bd\\")")
      "s(\\"bd\\")"
  """
  @spec comment(String.t()) :: String.t()
  def comment(source) do
    trimmed = String.trim_leading(source)

    case Enum.find(off(), &String.starts_with?(trimmed, &1)) do
      nil -> "-- " <> source
      marker -> trimmed |> String.replace_prefix(marker, "") |> String.trim_leading()
    end
  end

  @doc """
  The rows folded into the sources they make, as `{first, last, source}` chains.

  `first` and `last` are indexes into `rows` as given. Rows that are switched off are left
  out; a continuation with nothing live above it is dropped.

  Rows that read as Strudel (`TuningFork.Strudel.strudel?/1` on all of them together) are
  translated by `TuningFork.Strudel.chains/1` instead, one chain per voice on the rows it
  came from. A piece that will not translate is one chain on the row of the fault, whose
  source is the whole text.

      iex> TuningFork.Session.joined([%{source: "s(\\"bd\\")"}, %{source: "|> gain(0.5)"}])
      [{0, 1, "s(\\"bd\\") |> gain(0.5)"}]
  """
  @spec joined([row()]) :: [chain()]
  def joined(rows) do
    case strudel(rows) do
      nil -> own(rows)
      text -> strudel_chains(text)
    end
  end

  defp strudel(rows) do
    text = Enum.map_join(rows, "\n", & &1.source)

    if Strudel.strudel?(text), do: text
  end

  defp strudel_chains(text) do
    case Strudel.chains(text) do
      {:ok, chains, _meta} -> chains
      {:error, line, _message} -> [{line, line, text}]
    end
  end

  defp own(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce([], fn {row, index}, acc ->
      cond do
        not live?(row) -> acc
        continues?(row) -> carry_on(acc, row, index)
        true -> [{index, index, String.trim(row.source)} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp carry_on([], _row, _index), do: []

  defp carry_on([{first, _last, source} | rest], row, index) do
    [{first, index, source <> " " <> String.trim(row.source)} | rest]
  end

  @doc """
  The cycles per second the rows ask for, or `nil` when they do not: Strudel's `setcps`.
  """
  @spec tempo([row()]) :: number() | nil
  def tempo(rows) do
    with text when is_binary(text) <- strudel(rows),
         {:ok, _chains, %{cps: cps}} <- Strudel.chains(text) do
      cps
    else
      _none -> nil
    end
  end

  @doc "The whole source a row belongs to, continuations and all, or `nil` when it plays nothing."
  @spec chain([row()], non_neg_integer()) :: String.t() | nil
  def chain(rows, index) do
    rows
    |> joined()
    |> Enum.find_value(fn {first, _last, source} -> if first == index, do: source end)
  end

  @doc """
  Every switched-on row stacked into one pattern. A row that will not parse is left out.
  """
  @spec combined([row()]) :: Pattern.t()
  def combined(rows) do
    rows
    |> joined()
    |> Enum.flat_map(fn {_first, _last, source} ->
      case Source.parse(source) do
        {:ok, pattern} -> [pattern]
        {:error, _reason} -> []
      end
    end)
    |> Pattern.stack()
  end

  @doc """
  The rows with `:error` set on the ones that will not parse and cleared on the ones that will.

  An error is reported on the row a chain starts, trimmed to one line of at most 70
  characters.
  """
  @spec checked([row()]) :: [row()]
  def checked(rows) do
    chains = Map.new(joined(rows), fn {first, _last, source} -> {first, source} end)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      case Map.get(chains, index) do
        nil -> Map.put(row, :error, nil)
        source -> Map.put(row, :error, fault(source))
      end
    end)
  end

  @doc """
  Why `source` will not read, in one line, or `nil` when it reads.

      iex> TuningFork.Session.fault("s(\\"bd\\")")
      nil
      iex> TuningFork.Session.fault("|> gain(0.5)")
      "|> carries on the line above, and there is none"
  """
  @spec fault(String.t()) :: String.t() | nil
  def fault(source) do
    if Strudel.strudel?(source), do: strudel_fault(source), else: source_fault(source)
  end

  defp source_fault(source) do
    case Source.parse(source) do
      {:ok, _pattern} -> nil
      {:error, message} -> trimmed(message)
    end
  end

  defp strudel_fault(text) do
    case Strudel.chains(text) do
      {:ok, _chains, _meta} -> nil
      {:error, _line, message} -> trimmed(message)
    end
  end

  defp trimmed(message) do
    message
    |> String.replace_prefix("mini-notation: ", "")
    |> String.split("\n")
    |> hd()
    |> String.slice(0, 70)
  end

  @doc """
  What a row has asked to be drawn as: `:pianoroll`, `:scope` or `nil`.

  Read from the parsed pattern, not from the text. `nil` for a row that is off or will not
  parse.

      iex> TuningFork.Session.asks?(%{source: "s(\\"bd*4\\") |> scope()"})
      :scope
      iex> TuningFork.Session.asks?(%{source: "s(\\"bd*4\\")"})
      nil
  """
  @spec asks?(row() | String.t()) :: :pianoroll | :scope | nil
  def asks?(%{source: source} = row) do
    if live?(row), do: asks?(source)
  end

  def asks?(source) when is_binary(source) do
    case Source.parse(source) do
      {:ok, pattern} -> Control.drawing(pattern)
      {:error, _reason} -> nil
    end
  end
end

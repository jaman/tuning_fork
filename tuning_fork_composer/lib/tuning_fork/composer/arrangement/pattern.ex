defmodule TuningFork.Composer.Arrangement.Pattern do
  @moduledoc """
  The compact step notation clips are written in: `x` or `X` is an accented hit, `o` or `O`
  a normal hit, `.` a rest, and `-` holds the hit before it one step longer. `|` and
  whitespace are skipped, so beats and bars can be marked for reading.

      iex> TuningFork.Composer.Arrangement.Pattern.parse("x-|o.")
      {:ok, %{steps: 4, hits: [%{step: 0, length: 2, velocity: 1.0}, %{step: 2, length: 1, velocity: 0.7}]}}
  """

  @accent 1.0
  @normal 0.7
  @skipped [" ", "\t", "\r", "\n", "|"]

  @typedoc "A hit: the step it starts on, how many steps it lasts, and its velocity, 0.0 to 1.0."
  @type hit :: %{step: non_neg_integer(), length: pos_integer(), velocity: float()}

  @typedoc "A parsed pattern: how many steps one pass runs, and its hits in order."
  @type t :: %{steps: non_neg_integer(), hits: [hit()]}

  @doc """
  The hits of `text` and the steps one pass of it runs.

  Returns `{:error, message}` naming the first character that is not part of the notation.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    characters = text |> String.graphemes() |> Enum.reject(&(&1 in @skipped))

    characters
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &read/2)
    |> case do
      {:ok, hits} -> {:ok, %{steps: length(characters), hits: Enum.reverse(hits)}}
      {:error, message} -> {:error, "#{message} in #{inspect(text)}"}
    end
  end

  @doc "The velocity of an accented hit (`x`) and of a normal one (`o`)."
  @spec velocities() :: %{accent: float(), normal: float()}
  def velocities, do: %{accent: @accent, normal: @normal}

  defp read({character, step}, {:ok, hits}) when character in ["x", "X"],
    do: {:cont, {:ok, [%{step: step, length: 1, velocity: @accent} | hits]}}

  defp read({character, step}, {:ok, hits}) when character in ["o", "O"],
    do: {:cont, {:ok, [%{step: step, length: 1, velocity: @normal} | hits]}}

  defp read({".", _step}, {:ok, hits}), do: {:cont, {:ok, hits}}
  defp read({"-", _step}, {:ok, []}), do: {:cont, {:ok, []}}

  defp read({"-", _step}, {:ok, [last | hits]}),
    do: {:cont, {:ok, [%{last | length: last.length + 1} | hits]}}

  defp read({character, step}, {:ok, _hits}),
    do: {:halt, {:error, "#{inspect(character)} at step #{step} is not x, X, o, O, ., - or |"}}
end

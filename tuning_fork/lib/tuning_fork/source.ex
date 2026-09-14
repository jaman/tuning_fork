defmodule TuningFork.Source do
  @moduledoc """
  Evaluating typed source without diagnostics on standard error, and trimming error messages.
  """

  @doc """
  Run `fun` and return its result, dropping any compiler diagnostics it would write to
  standard error.
  """
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    {result, _diagnostics} = Code.with_diagnostics(fun)

    result
  end

  @doc """
  An exception's message trimmed to one line: file, line, caret art and snippet removed, cut
  to 90 characters. An empty result is `"that will not read"`.

      iex> TuningFork.Source.one_line("error: missing terminator: )")
      "missing terminator: )"
      iex> TuningFork.Source.one_line("")
      "that will not read"
  """
  @spec one_line(String.t()) :: String.t()
  def one_line(message) do
    message
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&decoration?/1)
    |> Enum.map(&strip_position/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> String.replace_prefix("error: ", "")
    |> String.trim()
    |> case do
      "" -> "that will not read"
      said -> String.slice(said, 0, 90)
    end
  end

  defp decoration?(line) do
    line == "" or String.contains?(line, ["│", "└", "┌", "~~~"])
  end

  defp strip_position(line) do
    line
    |> String.replace(~r{^.*/(pattern|part)/source\.ex:\d+:\d+:?\s*}, "")
    |> String.replace(~r{^token missing on .*:\d+:\d+:?\s*}, "")
    |> String.replace(~r{^nofile:\d+:\d+:?\s*}, "")
    |> String.replace(~r{^nofile:\d+:?\s*}, "")
    |> String.replace(~r{^\d+\s*│.*$}, "")
    |> String.trim()
  end
end

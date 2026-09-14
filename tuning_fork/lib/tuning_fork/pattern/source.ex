defmodule TuningFork.Pattern.Source do
  @moduledoc """
  Turns a typed line of mini-notation or Elixir into a pattern.

      iex> {:ok, pattern} = TuningFork.Pattern.Source.parse("bd sn")
      iex> TuningFork.Pattern.first_cycle(pattern)
      [{0.0, 0.5, "bd"}, {0.5, 1.0, "sn"}]
  """

  alias TuningFork.{Pattern, Source}
  alias TuningFork.Pattern.Mini

  @openings (for module <- [TuningFork.Pattern, TuningFork.Pattern.Control],
                 {name, _arity} <- module.__info__(:functions),
                 uniq: true do
               "#{name}("
             end)

  @doc """
  The pattern `source` describes, or why it will not read.

  A line that `starts_code?/1` is evaluated as Elixir with `TuningFork.Pattern` and
  `TuningFork.Pattern.Control` imported, and can do whatever Elixir can; any other line is read
  as `TuningFork.Pattern.Mini` notation. Returns `{:ok, pattern}` or `{:error, message}` with
  the reason trimmed to one line. An empty line is `TuningFork.Pattern.silence/0`; a line that
  `continues?/1` is an error.

  Lines that parse:

      [bd(3,8), hh*8]
      n("<0 4 0 9 7>*16") |> scale("g:minor") |> transpose(-12) |> shape(:saw)
  """
  @spec parse(String.t()) :: {:ok, Pattern.t()} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    trimmed = String.trim(source)

    cond do
      trimmed == "" -> {:ok, Pattern.silence()}
      continues?(trimmed) -> {:error, "|> carries on the line above, and there is none"}
      starts_code?(trimmed) -> evaluate(trimmed)
      true -> Mini.parse_safe(trimmed)
    end
  end

  @doc """
  Whether this line is Elixir rather than mini-notation: it opens with one of `openings/0`.

      iex> TuningFork.Pattern.Source.starts_code?("n(\\"0 4\\")")
      true
      iex> TuningFork.Pattern.Source.starts_code?("bd*4")
      false
  """
  @spec starts_code?(String.t()) :: boolean()
  def starts_code?(source) do
    trimmed = source |> String.trim_leading() |> String.replace(" ", "")

    Enum.any?(@openings, &String.starts_with?(trimmed, &1))
  end

  @doc """
  Whether this line carries on the one above it rather than starting its own pattern.

      iex> TuningFork.Pattern.Source.continues?("|> pianoroll()")
      true
      iex> TuningFork.Pattern.Source.continues?("s(\\"bd\\")")
      false

  Join such a line to the one it follows before passing it to `parse/1`.
  """
  @spec continues?(String.t()) :: boolean()
  def continues?(source), do: source |> String.trim_leading() |> String.starts_with?("|>")

  @doc """
  The openings that mark a line as Elixir: every function name of `TuningFork.Pattern` and
  `TuningFork.Pattern.Control` followed by `(`.
  """
  @spec openings() :: [String.t()]
  def openings, do: @openings

  defp evaluate(source), do: Source.run(fn -> run(source) end)

  defp run(source) do
    wrapped = """
    import Kernel, except: [struct: 2]
    import TuningFork.Pattern
    import TuningFork.Pattern.Control
    #{source}
    """

    case Code.eval_string(wrapped, [], __ENV__) do
      {%Pattern{} = pattern, _binding} -> {:ok, pattern}
      {other, _binding} -> {:error, "that gives #{inspect(other)}, not a pattern"}
    end
  rescue
    error -> {:error, Source.one_line(Exception.message(error))}
  catch
    :exit, reason -> {:error, Source.one_line(inspect(reason))}
  end
end

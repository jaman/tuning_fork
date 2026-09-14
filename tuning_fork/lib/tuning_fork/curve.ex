defmodule TuningFork.Curve do
  @moduledoc """
  A multiplier that moves over the length of a note, as `{progress, value}` breakpoints.

      Curve.new([{0.0, 1.0}, {0.5, 1.5}, {1.0, 1.0}])
  """

  @type point :: {float(), float()}
  @type t :: [point()]

  @doc """
  A curve from `{progress, value}` pairs, sorted by progress.

  Progress runs 0.0 at the start of a note to 1.0 at its end; `value` is a multiplier over the
  field the curve is attached to. Both members of each pair are converted to floats. Raises
  `ArgumentError` on an empty list. Points outside 0.0 to 1.0 are kept rather than dropped or
  clamped.
  """
  @spec new([{number(), number()}]) :: t()
  def new(points) when is_list(points) and points != [] do
    points
    |> Enum.map(fn {at, value} -> {at * 1.0, value * 1.0} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  def new([]) do
    raise ArgumentError,
          "a curve needs at least one breakpoint; use hold/1 for a value that does not move"
  end

  @doc "A curve going straight from `from` at progress 0.0 to `to` at progress 1.0."
  @spec linear(number(), number()) :: t()
  def linear(from, to), do: new([{0.0, from}, {1.0, to}])

  @doc "A curve that stays at `value` throughout. `flat?/1` is true of it."
  @spec hold(number()) :: t()
  def hold(value), do: new([{0.0, value}])

  @doc """
  The value at `progress`, 0.0 at the start of a note and 1.0 at its end.

  Interpolated in a straight line between breakpoints; before the first breakpoint and after
  the last it is that breakpoint's value.
  """
  @spec at(t(), float()) :: float()
  def at([{_only, value}], _progress), do: value
  def at([{first, value} | _rest], progress) when progress <= first, do: value

  def at(points, progress), do: seek(points, progress)

  @doc """
  Whether a curve holds one value throughout. True of `nil` and of a single-point curve.
  """
  @spec flat?(t() | nil) :: boolean()
  def flat?(nil), do: true
  def flat?([_single]), do: true
  def flat?([{_at, value} | rest]), do: Enum.all?(rest, &(elem(&1, 1) == value))

  @doc """
  Thin a curve down to at most `count` breakpoints, keeping its shape.

  The first and last points are always kept. A curve already at or under `count` points is
  returned unchanged. Raises `ArgumentError` when `count` is under 2.
  """
  @spec simplify(t(), pos_integer()) :: t()
  def simplify(points, count) when length(points) <= count, do: points

  def simplify(points, count) when count >= 2 do
    drop_until(points, count)
  end

  def simplify(_points, count) do
    raise ArgumentError, "simplify/2 keeps at least 2 breakpoints, asked for: #{inspect(count)}"
  end

  defp drop_until(points, count) when length(points) <= count, do: points

  defp drop_until(points, count) do
    {index, _error} =
      points
      |> interior_errors()
      |> Enum.min_by(&elem(&1, 1))

    points |> List.delete_at(index) |> drop_until(count)
  end

  defp interior_errors(points) do
    points
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.with_index(1)
    |> Enum.map(fn {[{a_at, a}, {at, value}, {b_at, b}], index} ->
      span = b_at - a_at
      predicted = if span == 0.0, do: a, else: a + (b - a) * ((at - a_at) / span)

      {index, abs(value - predicted)}
    end)
  end

  defp seek([{_a_at, a_value} = _a], _progress), do: a_value

  defp seek([{a_at, a_value}, {b_at, b_value} = b | rest], progress) do
    cond do
      progress > b_at and rest != [] ->
        seek([b | rest], progress)

      progress >= b_at ->
        b_value

      b_at == a_at ->
        b_value

      true ->
        a_value + (b_value - a_value) * ((progress - a_at) / (b_at - a_at))
    end
  end
end

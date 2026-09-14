defmodule TuningFork.Drafter.Paint do
  @moduledoc """
  Pure functions drawing patterns and audio as `FrenchCurve.Raster`s.

      Paint.pianoroll(events, cycle, width: 640, height: 96)
  """

  alias FrenchCurve.{Draw, Raster}

  @background {12, 14, 20, 255}
  @note {90, 200, 240, 255}
  @dim {40, 90, 115, 255}
  @playhead {150, 160, 180, 255}
  @trace {120, 220, 250, 255}
  @grid {28, 32, 44, 255}

  @doc """
  A pianoroll: pitch up the raster, one cycle across it.

  `events` are `{from, to, midi}` with `from` and `to` in cycles from 0.0 to 1.0 and `midi` the
  note number. `cycle` is the playhead position; its fractional part is drawn, and the note
  sounding at it is drawn as an outline. The pitch range is whatever the events cover.

  Options:

    * `:width`, `:height` — the raster's size in pixels, default 640 by 96
    * `:grid` — quarter-cycle lines, default true
    * `:playhead` — draw the playhead line, default true. Which note is outlined follows the
      phase either way
  """
  @spec pianoroll([{number(), number(), number()}], number(), keyword()) :: Raster.t()
  def pianoroll(events, cycle, opts \\ []) do
    width = Keyword.get(opts, :width, 640)
    height = Keyword.get(opts, :height, 96)

    Raster.new(width, height, background: @background)
    |> maybe_grid(Keyword.get(opts, :grid, true), width, height)
    |> notes(events, width, height, cycle)
    |> maybe_playhead(Keyword.get(opts, :playhead, true), cycle, width, height)
  end

  defp maybe_playhead(raster, false, _cycle, _height, _width), do: raster

  defp maybe_playhead(raster, true, cycle, width, height),
    do: playhead(raster, cycle, width, height)

  @doc """
  Unpitched hits drawn as bars the full height of the raster.

  `hits` are `{from, to}` in cycles from 0.0 to 1.0. `cycle` is the playhead position.

  Options:

    * `:width`, `:height` — the raster's size in pixels, default 640 by 96
    * `:grid` — quarter-cycle lines, default true
    * `:playhead` — draw the playhead line, default true
  """
  @spec hits([{number(), number()}], number(), keyword()) :: Raster.t()
  def hits(hits, cycle, opts \\ []) do
    width = Keyword.get(opts, :width, 640)
    height = Keyword.get(opts, :height, 96)

    Raster.new(width, height, background: @background)
    |> maybe_grid(Keyword.get(opts, :grid, true), width, height)
    |> bars(hits, width, height)
    |> maybe_playhead(Keyword.get(opts, :playhead, true), cycle, width, height)
  end

  defp bars(raster, hits, width, height) do
    Enum.reduce(hits, raster, fn {from, to}, acc ->
      left = round(from * width)
      right = max(round(to * width) - 1, left + 2)

      Draw.fill_rect(acc, {left, 2}, {min(right, width - 1), height - 3}, @note)
    end)
  end

  defp notes(raster, [], _width, _height, _cycle), do: raster

  defp notes(raster, events, width, height, cycle) do
    pitches = Enum.map(events, fn {_from, _to, midi} -> midi end)
    {low, high} = Enum.min_max(pitches)
    span = max(high - low, 1)

    tall = max(div(height, 5), 4)
    room = height - tall - 4
    phase = cycle - Float.floor(cycle * 1.0)

    Enum.reduce(events, raster, fn {from, to, midi} = event, acc ->
      left = round(from * width)
      long = max(round((to - from) * width * 0.45), 3)
      top = 2 + round((high - midi) / span * room)
      box = {{left, top}, {min(left + long, width - 1), top + tall}}

      draw_note(acc, box, sounding?(event, phase))
    end)
  end

  defp draw_note(raster, {corner, opposite}, true) do
    Draw.rect(raster, corner, opposite, @note)
  end

  defp draw_note(raster, {corner, opposite}, false) do
    Draw.fill_rect(raster, corner, opposite, @note)
  end

  defp sounding?({from, to, _midi}, phase), do: phase >= from and phase < to

  defp maybe_grid(raster, false, _width, _height), do: raster

  defp maybe_grid(raster, true, width, height) do
    Enum.reduce(1..3, raster, fn quarter, acc ->
      at = round(quarter * width / 4)

      Draw.line(acc, {at, 0}, {at, height - 1}, @grid)
    end)
  end

  defp playhead(raster, cycle, width, height) do
    at = min(round((cycle - Float.floor(cycle * 1.0)) * width), width - 1)

    Draw.line(raster, {at, 0}, {at, height - 1}, @playhead)
  end

  @doc """
  An oscilloscope trace of `samples`, each -1.0 to 1.0, as one line across the raster over a
  zero line. An empty list draws the zero line alone.

  Options:

    * `:width`, `:height` — the raster's size in pixels, default 640 by 64
  """
  @spec scope([number()], keyword()) :: Raster.t()
  def scope(samples, opts \\ []) do
    width = Keyword.get(opts, :width, 640)
    height = Keyword.get(opts, :height, 64)
    middle = div(height, 2)

    raster =
      Raster.new(width, height, background: @background)
      |> Draw.line({0, middle}, {width - 1, middle}, @dim)

    case points(samples, width, height) do
      [] -> raster
      points -> Draw.polyline(raster, points, @trace)
    end
  end

  defp points([], _width, _height), do: []

  defp points(samples, width, height) do
    count = length(samples)
    middle = div(height, 2)
    room = middle - 2

    samples
    |> Enum.with_index()
    |> Enum.map(fn {sample, index} ->
      x = if count > 1, do: round(index * (width - 1) / (count - 1)), else: 0
      y = middle - round((sample |> max(-1.0) |> min(1.0)) * room)

      {x, y}
    end)
  end
end

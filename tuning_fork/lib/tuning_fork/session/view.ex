defmodule TuningFork.Session.View do
  @moduledoc """
  What a live-coding front end draws for a session row, as numbers rather than pictures.

      View.sounding(row, cycle)
      View.scope(row, cycle, cps)
  """

  alias TuningFork.{Kit, Pattern, Session}
  alias TuningFork.Pattern.{Mini, Player, Source}

  @scope_rate 8_000
  @scope_window 0.25
  @fade_time 0.35
  @fade_steps 12
  @fade_floor 0.12
  @columns 32

  @doc "How many columns wide a row of hits or notes is."
  @spec columns() :: pos_integer()
  def columns, do: @columns

  @doc """
  A window of what this row alone sounds like, as samples from -1.0 to 1.0.

  `row` is a map with a `:source` or a bare string. The window starts at the row's last note
  before `cycle` (see `struck/2`) and is scaled by `fade/2`. `[]` for a row that is off or
  will not parse.
  """
  @spec scope(Session.row() | String.t(), number(), number()) :: [float()]
  def scope(row, cycle, cps) do
    with source when is_binary(source) <- playable(row),
         {:ok, pattern} <- Source.parse(source) do
      frames = trunc(@scope_rate * (@scope_window / max(cps, 0.01)))
      at = struck(pattern, cycle)
      level = fade(cycle - at, cps)

      pattern
      |> Player.new(@scope_rate, cps: cps)
      |> then(&%{&1 | cycle: at})
      |> Player.advance(max(frames, 8), 1)
      |> elem(0)
      |> then(&for(<<sample::16-signed-little <- &1>>, do: sample / 32_767 * level))
    else
      _nothing -> []
    end
  end

  @doc """
  How tall a trace is drawn, `cycles` after the note that made it.

  1.0 as the note lands, falling away over about #{@fade_time} seconds to a floor of
  #{@fade_floor}, quantised to #{@fade_steps} steps.

      iex> TuningFork.Session.View.fade(0.0, 0.5)
      1.0
      iex> TuningFork.Session.View.fade(4.0, 0.5) == TuningFork.Session.View.fade(6.0, 0.5)
      true
  """
  @spec fade(number(), number()) :: float()
  def fade(cycles, cps) do
    seconds = max(cycles, 0.0) / max(cps, 0.01)
    level = @fade_floor + (1.0 - @fade_floor) * :math.exp(-seconds / @fade_time)

    Float.ceil(level * @fade_steps) / @fade_steps
  end

  @doc """
  Where the last note before `cycle` began, in cycles. `cycle` itself when nothing has started
  yet.
  """
  @spec struck(Pattern.t(), number()) :: float()
  def struck(%Pattern{} = pattern, cycle) do
    at = cycle * 1.0

    pattern
    |> Pattern.query({Float.floor(at) - 1.0, at})
    |> Enum.filter(&Pattern.onset?/1)
    |> Enum.map(fn %{whole: {began, _ends}} -> began end)
    |> Enum.filter(&(&1 <= at))
    |> Enum.max(fn -> at end)
  rescue
    _error -> cycle * 1.0
  end

  @doc """
  Where in a row's text the thing sounding right now was written, as `{from, to}`.

  Character offsets into the source. A row of plain notation is read as it stands; a row of
  code has its first quoted string read, with the answer offset to where that string sits in
  the line. `nil` for a row that is off, will not parse, or is sounding nothing at `cycle`.

      iex> TuningFork.Session.View.sounding(%{source: "~ cp ~ cp"}, 0.3)
      {2, 4}
  """
  @spec sounding(Session.row() | String.t(), number()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def sounding(row, cycle) do
    case playable(row) do
      nil -> nil
      source -> located(source, cycle)
    end
  end

  defp located(source, cycle) do
    case quoted(source) do
      nil ->
        Mini.locate(source, cycle)

      {notation, offset} ->
        case Mini.locate(notation, cycle) do
          nil -> nil
          {from, to} -> {from + offset, to + offset}
        end
    end
  end

  defp quoted(source) do
    case Regex.run(~r/"([^"]*)"/, source, return: :index, capture: :all_but_first) do
      [{at, length}] -> {String.slice(source, at, length), at}
      _none -> nil
    end
  end

  @doc """
  The notes a row plays this cycle, as `{column, midi note}`.

  `column` counts from zero up to `columns/0`. Values with no MIDI note, such as drum names,
  are left out; `hits/2` reports those.
  """
  @spec notes(Session.row() | String.t(), number()) :: [{non_neg_integer(), integer()}]
  def notes(row, cycle) do
    for {column, value} <- events(row, cycle), note = Kit.midi(value), do: {column, note}
  end

  @doc "The columns a row strikes this cycle, for a row of drums. See `notes/2`."
  @spec hits(Session.row() | String.t(), number()) :: [non_neg_integer()]
  def hits(row, cycle) do
    row |> events(cycle) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  @doc """
  Every onset this cycle, as `{column, value}` with the value the pattern carried.

  `[]` for a row that is parked or will not parse.
  """
  @spec events(Session.row() | String.t(), number()) :: [{non_neg_integer(), term()}]
  def events(row, cycle) do
    with source when is_binary(source) <- playable(row),
         {:ok, pattern} <- Source.parse(source) do
      pattern
      |> Pattern.first_cycle(trunc(cycle))
      |> Enum.map(fn {from, _to, value} -> {trunc(from * @columns), value} end)
    else
      _nothing -> []
    end
  end

  @doc """
  How long each note this cycle sounds for, as `%{column => width in columns}`. `%{}` for a
  row that is off or will not parse.
  """
  @spec widths(Session.row() | String.t(), number()) :: %{non_neg_integer() => number()}
  def widths(row, cycle) do
    with source when is_binary(source) <- playable(row),
         {:ok, pattern} <- Source.parse(source) do
      pattern
      |> Pattern.first_cycle(trunc(cycle))
      |> Map.new(fn {from, to, _value} -> {trunc(from * @columns), (to - from) * @columns} end)
    else
      _nothing -> %{}
    end
  end

  @doc """
  Which column the playhead is in, from zero to `columns/0` minus one.

      iex> TuningFork.Session.View.playhead(2.5)
      16
  """
  @spec playhead(number()) :: non_neg_integer()
  def playhead(cycle) do
    phase = cycle - Float.floor(cycle * 1.0)

    phase |> Kernel.*(@columns) |> trunc() |> min(@columns - 1)
  end

  defp playable(%{source: source} = row), do: if(Session.live?(row), do: source)
  defp playable(source) when is_binary(source), do: source
  defp playable(_row), do: nil
end

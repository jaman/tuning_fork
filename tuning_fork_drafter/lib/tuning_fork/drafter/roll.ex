defmodule TuningFork.Drafter.Roll do
  @moduledoc """
  A Drafter widget that draws a `FrenchCurve.Raster` as terminal pixels, or lines of text where
  the terminal has none.

      {:tuning_fork_roll, [id: :roll, raster: raster, text: ["█···", "·█··"], flex: 1]}
  """

  use Drafter.Widget, handles: []

  alias Drafter.Draw.{Segment, Strip}
  alias FrenchCurve.Raster

  defstruct [:raster, :widget_id, text: [], mode: nil, compress: true, background: {12, 14, 20}]

  @type t :: %__MODULE__{
          raster: Raster.t() | nil,
          widget_id: term(),
          text: [String.t()],
          mode: atom() | nil,
          compress: boolean()
        }

  @doc """
  The tag this widget answers to in a component tree: `:tuning_fork_roll`. The module must be
  loaded with `Code.ensure_loaded!/1` before Drafter's widget registry is called,
  or registration does nothing.
  """
  @spec component_tag() :: atom()
  def component_tag, do: :tuning_fork_roll

  @doc false
  @spec from_component_opts(term(), keyword()) :: map()
  def from_component_opts(_args, opts) do
    opts
    |> Keyword.take([:raster, :text, :mode, :compress, :background])
    |> Map.new()
    |> Map.put(:id, Keyword.get(opts, :__widget_id__))
  end

  @doc """
  Build the widget's state from its props.

  `props` is a map or a keyword list:

    * `:raster` — what to draw. `nil` draws the text instead
    * `:text` — lines to draw when there are no pixels to be had. Default `[]`
    * `:mode` — a `FrenchCurve.Capability` mode to force instead of detecting one. Default `nil`
    * `:compress` — zlib the kitty transmit. Default `true`
    * `:background` — an RGB tuple. Default `{12, 14, 20}`

  The raster is fitted to whatever height the caller gives the pane.
  """
  @impl true
  @spec mount(map() | keyword()) :: t()
  def mount(props) do
    props = Map.new(props)

    %__MODULE__{
      raster: Map.get(props, :raster),
      text: Map.get(props, :text) || [],
      mode: Map.get(props, :mode),
      compress: Map.get(props, :compress, true),
      background: Map.get(props, :background) || {12, 14, 20},
      widget_id: Map.get(props, :id)
    }
  end

  @doc """
  Fold re-rendered props into the widget state. A key present in `props` is used even when its
  value is `nil`; a key absent leaves that part of the state as it was.
  """
  @impl true
  @spec update(map() | keyword(), t()) :: t()
  def update(props, %__MODULE__{} = state) do
    props = Map.new(props)

    %{
      state
      | raster: fold(props, :raster, state.raster),
        text: fold(props, :text, state.text) || [],
        mode: fold(props, :mode, state.mode),
        compress: fold(props, :compress, state.compress),
        background: fold(props, :background, state.background) || {12, 14, 20}
    }
  end

  defp fold(props, key, current) do
    case Map.fetch(props, key) do
      {:ok, value} -> value
      :error -> current
    end
  end

  @doc false
  @impl true
  def render(%__MODULE__{} = state, rect) do
    if pixels?(state) do
      blank(state, rect)
    else
      written(state, rect)
    end
  end

  defp written(%__MODULE__{text: text} = state, rect) do
    height = max(rect.height, 1)
    width = max(rect.width, 1)
    style = %{bg: state.background}

    text
    |> Enum.take(height)
    |> then(&(&1 ++ List.duplicate("", height - length(&1))))
    |> Enum.map(fn line ->
      [Segment.new(line, style)] |> Strip.new() |> Strip.fit_to_width(width)
    end)
  end

  defp blank(%__MODULE__{} = state, rect) do
    filled = String.duplicate(" ", max(rect.width, 1))
    strip = Strip.new([Segment.new(filled, %{bg: state.background})])

    List.duplicate(strip, max(rect.height, 1))
  end

  @doc """
  The frame as terminal-graphics bytes: `{paint, clear, region}` as `FrenchCurve.frame/3`
  returns them, or `nil` when the terminal has no pixel protocol, there is no raster, or
  drawing raises.

  `id` identifies the image to the terminal across frames; successive calls for the same widget
  must pass the same `id`.
  """
  @spec image(t(), map(), term()) :: {iodata(), iodata(), map()} | nil
  def image(%__MODULE__{raster: nil}, _rect, _id), do: nil

  def image(%__MODULE__{} = state, rect, id) do
    case protocol(state) do
      nil -> nil
      protocol -> encode(state, rect, id, protocol)
    end
  rescue
    _error -> nil
  end

  defp encode(state, rect, id, protocol) do
    cols = max(rect.width, 1)
    rows = max(rect.height, 1)

    opts = [fit: {cols, rows}, compress: state.compress, protocol: protocol]

    case FrenchCurve.frame(state.raster, id, opts) do
      nil ->
        nil

      {paint, clear, place} ->
        {paint, clear, %{dx: 0, dy: 0, cols: cols, rows: rows, place: place}}
    end
  end

  defp pixels?(state), do: protocol(state) != nil

  defp protocol(%__MODULE__{raster: nil}), do: nil
  defp protocol(%__MODULE__{mode: :text}), do: nil
  defp protocol(%__MODULE__{mode: mode}) when mode in [:kitty, :iterm2, :sixel], do: mode

  defp protocol(%__MODULE__{}) do
    case FrenchCurve.Capability.detect() do
      protocol when protocol in [:kitty, :iterm2, :sixel] -> protocol
      _no_pixels -> nil
    end
  end
end

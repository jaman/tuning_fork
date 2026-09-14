defmodule TuningFork.Composer.Track do
  @moduledoc """
  One row of the grid: an instrument, and what it plays on each step.

      Track.new([kind: :pitched, sound: "bass", steps: [1, 0, {3, 2}, 0]], 4)
  """

  @type step :: non_neg_integer() | {pos_integer(), pos_integer()}

  @type t :: %__MODULE__{
          kind: :drum | :pitched | :sample,
          sound: String.t() | nil,
          path: String.t() | nil,
          root: atom() | nil,
          gain: float(),
          ring: float(),
          muted: boolean(),
          steps: [step()]
        }

  defstruct kind: :drum,
            sound: "kick",
            path: nil,
            root: nil,
            gain: 0.8,
            ring: 2.0,
            muted: false,
            steps: []

  @doc """
  A track `count` steps wide.

  `opts` takes any field of the struct. Fields and defaults: `:kind` one of `:drum`,
  `:pitched` or `:sample` (`:drum`), `:sound` an id from `Composer.drums/0` or
  `Composer.instruments/0` (`"kick"`), `:path` WAV file for `:sample` (`nil`), `:root` the
  pitch a `:sample` was recorded at, `nil` playing it as-is (`nil`), `:gain` 0.0–1.0 (`0.8`),
  `:ring` how long notes sound in beats, ignored by `:drum` (`2.0`), `:muted` (`false`),
  `:steps` one entry per step (`[]`). Any `:steps` given are grown with rests or cut short to
  `count`.

  A step is `0` for silence, a scale degree for a note one step long, or `{degree, length}`
  for a note held over `length` steps. A `:drum` track holds only `0` or `1`.
  """
  @spec new(keyword(), pos_integer()) :: t()
  def new(opts \\ [], count \\ 16) do
    track = struct!(__MODULE__, opts)

    %{track | steps: resize(track.steps, count)}
  end

  @doc """
  What a step holds, as `{degree, length in steps}`.

  Accepts every step form: `0` gives `{0, 1}`, `3` gives `{3, 1}`, `{3, 4}` gives `{3, 4}`.
  Anything else reads as `{0, 1}`.
  """
  @spec read(step()) :: {non_neg_integer(), pos_integer()}
  def read({degree, length}) when is_integer(degree) and is_integer(length) do
    {max(degree, 0), max(length, 1)}
  end

  def read(degree) when is_integer(degree), do: {max(degree, 0), 1}
  def read(_anything_else), do: {0, 1}

  @doc """
  A step from a degree and a length, in the shortest form: `write(3, 1)` is `3`,
  `write(3, 4)` is `{3, 4}`, and a degree of `0` is `0` whatever the length.
  """
  @spec write(non_neg_integer(), pos_integer()) :: step()
  def write(degree, _length) when degree <= 0, do: 0
  def write(degree, length) when length > 1, do: {degree, length}
  def write(degree, _one), do: degree

  @doc "Whether this track plays anything at all."
  @spec silent?(t()) :: boolean()
  def silent?(%__MODULE__{steps: steps}) do
    Enum.all?(steps, &(elem(read(&1), 0) == 0))
  end

  @doc "Whether it will be heard: it plays something, and it is not muted."
  @spec audible?(t()) :: boolean()
  def audible?(%__MODULE__{} = track), do: not track.muted and not silent?(track)

  @doc """
  Bring the track to `count` steps.

  Grown with rests, or cut short. Cutting discards whatever was past the new end.
  """
  @spec resize(t() | [step()], pos_integer()) :: t() | [step()]
  def resize(%__MODULE__{} = track, count), do: %{track | steps: resize(track.steps, count)}

  def resize(steps, count) when is_list(steps) do
    case length(steps) do
      ^count -> steps
      longer when longer > count -> Enum.take(steps, count)
      shorter -> steps ++ List.duplicate(0, count - shorter)
    end
  end

  @doc "Which steps are covered by a note that began earlier, one boolean per step."
  @spec held(t()) :: [boolean()]
  def held(%__MODULE__{steps: steps}) do
    count = length(steps)

    covered =
      steps
      |> Enum.with_index()
      |> Enum.flat_map(&covered_by(&1, count))
      |> MapSet.new()

    Enum.map(0..(count - 1)//1, &MapSet.member?(covered, &1))
  end

  defp covered_by({step, index}, count) do
    case read(step) do
      {degree, length} when degree > 0 ->
        for n <- 1..(length - 1)//1, index + n < count, do: index + n

      _rest ->
        []
    end
  end

  @doc "Which step a note covering `step` began on, or `step` itself when no note covers it."
  @spec start_of(t(), non_neg_integer()) :: non_neg_integer()
  def start_of(%__MODULE__{steps: steps}, step) do
    Enum.find(step..0//-1, step, fn candidate ->
      {degree, length} = read(Enum.at(steps, candidate, 0))
      degree > 0 and candidate + length > step
    end)
  end

  @doc """
  How many steps a note at `step` may occupy before it meets the next one, or the distance to
  the end of the track when nothing follows it.
  """
  @spec room_at(t(), non_neg_integer()) :: pos_integer()
  def room_at(%__MODULE__{steps: steps}, step) do
    count = length(steps)

    Enum.find_value(
      (step + 1)..(count - 1)//1,
      count - step,
      fn next ->
        {degree, _length} = read(Enum.at(steps, next, 0))
        if degree > 0, do: next - step
      end
    )
  end
end

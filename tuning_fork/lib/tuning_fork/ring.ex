defmodule TuningFork.Ring do
  @moduledoc """
  A list read round and round, so any integer index is in it.

      iex> TuningFork.Ring.at([:c2, :e2, :g2], 4)
      :e2
  """

  @doc """
  The element at `index`. An index past the end wraps to the start and a negative one counts
  back from the end. `nil` for an empty list.

      iex> TuningFork.Ring.at([1, 2, 3], 7)
      2
      iex> TuningFork.Ring.at([1, 2, 3], -1)
      3
      iex> TuningFork.Ring.at([], 0)
      nil
  """
  @spec at([term()], integer()) :: term() | nil
  def at([], _index), do: nil

  def at(list, index) when is_list(list) and is_integer(index) do
    Enum.at(list, Integer.mod(index, length(list)))
  end

  @doc """
  `count` elements from `index` on, wrapping.

      iex> TuningFork.Ring.take([:a, :b, :c], 1, 4)
      [:b, :c, :a, :b]
  """
  @spec take([term()], integer(), non_neg_integer()) :: [term()]
  def take([], _index, _count), do: []

  def take(list, index, count) when is_list(list) and count >= 0 do
    for step <- 0..(count - 1)//1, do: at(list, index + step)
  end

  @doc """
  The list turned so `index` is its head.

      iex> TuningFork.Ring.from([:a, :b, :c], 1)
      [:b, :c, :a]
  """
  @spec from([term()], integer()) :: [term()]
  def from([], _index), do: []
  def from(list, index) when is_list(list), do: take(list, index, length(list))
end

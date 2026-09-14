defmodule TuningFork.State do
  @moduledoc """
  Values one loop leaves for another, read as they stood at the reader's own time.

      set(:key, :d_minor)
      get(:key, :c_major)
  """

  alias TuningFork.Store

  @doc """
  Store `value` under `key`, at the time of the round doing the writing.

      iex> TuningFork.State.clear()
      iex> TuningFork.State.set(:mood, :bright)
      iex> TuningFork.State.get(:mood)
      :bright
  """
  @spec set(term(), term()) :: term()
  def set(key, value) do
    Store.put(key, Store.at(), value)

    value
  end

  @doc """
  The newest value under `key` written at or before the reading round's time, or `default`
  when there is none. Never blocks; outside a loop the time is `0`.

      iex> TuningFork.State.clear()
      iex> TuningFork.State.get(:missing, :nothing)
      :nothing
  """
  @spec get(term(), term()) :: term()
  def get(key, default \\ nil), do: Store.fetch(key, Store.at(), default)

  @doc "Every key with a value as of the reading round's time."
  @spec keys() :: [term()]
  def keys, do: Store.keys(Store.at())

  @doc "Forget every value."
  @spec clear() :: :ok
  def clear, do: Store.clear_values()
end

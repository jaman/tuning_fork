defmodule TuningFork.Tick do
  @moduledoc """
  Counters that step once each time a loop comes round.

      part(bpm: 120, synth: Kit.voice("bd", 0.3))
      |> play(Ring.at(~w(c2 e2 g2 a2)a, tick()), 1)
  """

  alias TuningFork.Store

  @doc """
  Step the counter on and give the value it was at.

      iex> TuningFork.Tick.reset()
      iex> {TuningFork.Tick.tick(:walk), TuningFork.Tick.tick(:walk)}
      {0, 1}
  """
  @spec tick(term()) :: non_neg_integer()
  def tick(name \\ nil), do: Store.step(counter(name))

  @doc """
  The counter's value, without stepping it.

      iex> TuningFork.Tick.reset()
      iex> TuningFork.Tick.tick(:look_here)
      iex> TuningFork.Tick.look(:look_here)
      1
  """
  @spec look(term()) :: non_neg_integer()
  def look(name \\ nil), do: Store.peek(counter(name))

  @doc "Put a counter at `count`. With no name, the loop's own."
  @spec set(term(), non_neg_integer()) :: :ok
  def set(name \\ nil, count), do: Store.put_tick(counter(name), count)

  @doc "Put a counter back to zero. With no name, every counter."
  @spec reset(term()) :: :ok
  def reset(name \\ :all)
  def reset(:all), do: Store.clear_ticks()
  def reset(name), do: Store.put_tick(counter(name), 0)

  defp counter(nil), do: Store.loop() || :default
  defp counter(name), do: name
end

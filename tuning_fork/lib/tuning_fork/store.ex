defmodule TuningFork.Store do
  @moduledoc """
  The ETS tables holding `TuningFork.Tick` counters and time-stamped `TuningFork.State` values.
  """

  use GenServer

  @ticks :tuning_fork_ticks
  @values :tuning_fork_state
  @context :tuning_fork_context

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@ticks, [:set, :public, :named_table, write_concurrency: true])
    :ets.new(@values, [:ordered_set, :public, :named_table, read_concurrency: true])

    {:ok, %{}}
  end

  @doc """
  Run `fun` as `name`'s body, playing at frame `at`.

  `TuningFork.Tick.tick/0` then counts on `name`'s own counter, and `TuningFork.State.set/2`
  and `get/2` read and write at `at`.
  """
  @spec as(term(), non_neg_integer(), (-> result)) :: result when result: term()
  def as(name, at, fun) when is_function(fun, 0) do
    was = Process.put(@context, {name, at})

    try do
      fun.()
    after
      if was, do: Process.put(@context, was), else: Process.delete(@context)
    end
  end

  @doc "The loop whose body is being run, or `nil` outside one."
  @spec loop() :: term() | nil
  def loop do
    case Process.get(@context) do
      {name, _at} -> name
      nil -> nil
    end
  end

  @doc "The frame the body being run is playing at, or `0` outside one."
  @spec at() :: non_neg_integer()
  def at do
    case Process.get(@context) do
      {_name, at} -> at
      nil -> 0
    end
  end

  @doc "Step a counter on and give what it was."
  @spec step(term()) :: non_neg_integer()
  def step(name) do
    ensure()

    :ets.update_counter(@ticks, name, {2, 1}, {name, 0}) - 1
  end

  @doc "A counter's value without stepping it."
  @spec peek(term()) :: non_neg_integer()
  def peek(name) do
    ensure()

    case :ets.lookup(@ticks, name) do
      [{^name, count}] -> count
      [] -> 0
    end
  end

  @doc "Set a counter."
  @spec put_tick(term(), non_neg_integer()) :: :ok
  def put_tick(name, count) do
    ensure()
    :ets.insert(@ticks, {name, count})

    :ok
  end

  @doc "Empty the counters."
  @spec clear_ticks() :: :ok
  def clear_ticks do
    ensure()
    :ets.delete_all_objects(@ticks)

    :ok
  end

  @doc "Store `value` under `key` as of frame `at`."
  @spec put(term(), non_neg_integer(), term()) :: :ok
  def put(key, at, value) do
    ensure()
    :ets.insert(@values, {{key, at}, value})

    :ok
  end

  @doc """
  The newest value stored under `key` at or before frame `at`, or `default`. A value set
  later than `at` is not seen.
  """
  @spec fetch(term(), non_neg_integer(), term()) :: term()
  def fetch(key, at, default) do
    ensure()

    case :ets.prev(@values, {key, at + 1}) do
      {^key, _when} = found -> value(found, default)
      _other -> default
    end
  end

  @doc "Every key that has a value at or before frame `at`."
  @spec keys(non_neg_integer()) :: [term()]
  def keys(at) do
    ensure()

    @values
    |> :ets.select([{{{:"$1", :"$2"}, :_}, [{:"=<", :"$2", at}], [:"$1"]}])
    |> Enum.uniq()
  end

  @doc "Empty the values."
  @spec clear_values() :: :ok
  def clear_values do
    ensure()
    :ets.delete_all_objects(@values)

    :ok
  end

  @doc "Empty both tables."
  @spec clear() :: :ok
  def clear do
    clear_ticks()
    clear_values()
  end

  defp value(found, default) do
    case :ets.lookup(@values, found) do
      [{^found, value}] -> value
      [] -> default
    end
  end

  defp ensure do
    if :ets.whereis(@ticks) == :undefined or :ets.whereis(@values) == :undefined do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end
end

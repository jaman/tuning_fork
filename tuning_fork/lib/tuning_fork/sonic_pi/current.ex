defmodule TuningFork.SonicPi.Current do
  @moduledoc "The `TuningFork.SonicPi.Thread` the calling process is running."

  alias TuningFork.SonicPi.Thread
  alias TuningFork.Store

  @key {TuningFork.SonicPi, :thread}

  @doc "The process's thread, started at time zero as an ambient thread if it has none."
  @spec get() :: Thread.t()
  def get do
    case Process.get(@key) do
      nil -> put(Thread.new({Store.loop(), Store.at()}, ambient: true))
      thread -> thread
    end
  end

  @doc "Replace the process's thread."
  @spec put(Thread.t()) :: Thread.t()
  def put(%Thread{} = thread) do
    Process.put(@key, thread)
    thread
  end

  @doc "Replace the process's thread with `fun` of it."
  @spec update((Thread.t() -> Thread.t())) :: :ok
  def update(fun) do
    put(fun.(get()))
    :ok
  end

  @doc "Draw from the thread's generator with `fun` and keep the generator it returns."
  @spec draw((TuningFork.Rand.t() -> {value, TuningFork.Rand.t()})) :: value when value: term()
  def draw(fun) do
    {value, thread} = Thread.draw(get(), fun)
    put(thread)
    value
  end

  @doc "Run `fun` with `thread` as the process's thread, then put back whatever was there."
  @spec within(Thread.t(), (-> result)) :: result when result: term()
  def within(%Thread{} = thread, fun) do
    was = Process.get(@key)
    Process.put(@key, thread)

    try do
      fun.()
    after
      if was, do: Process.put(@key, was), else: Process.delete(@key)
    end
  end
end

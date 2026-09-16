defmodule TuningFork.Sink.Process do
  @moduledoc """
  Raw signed 16-bit little-endian PCM as messages to a process, paced to real time: each
  chunk arrives as `{:pcm, chunk}`, and the sink sleeps until the audio before it has
  nearly played out, keeping `:lead_ms` in flight.

      TuningFork.Stage.start_link(sink: TuningFork.Sink.Process, sink_opts: [owner: self()])

  A write after the owner has exited returns `{:error, :owner_gone}`, which stops the
  stage feeding the sink.

  ## Options

    * `:owner` — the process the chunks go to. Required
    * `:lead_ms` — audio kept in flight ahead of real time. Default `60`
    * `:rate`, `:channels` — the PCM format, as the stage passes them
  """

  @behaviour TuningFork.Sink

  @impl true
  def open(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       frame: 2 * Keyword.fetch!(opts, :channels),
       rate: Keyword.fetch!(opts, :rate),
       lead_us: Keyword.get(opts, :lead_ms, 60) * 1_000,
       clock: :atomics.new(2, signed: true)
     }}
  end

  @impl true
  def write(%{owner: owner} = sink, pcm) do
    if Process.alive?(owner) do
      send(owner, {:pcm, pcm})
      pace(sink, pcm)
      :ok
    else
      {:error, :owner_gone}
    end
  end

  @impl true
  def close(_sink), do: :ok

  defp pace(%{clock: clock} = sink, pcm) do
    now = System.monotonic_time(:microsecond)
    started = start(clock, now)
    played = :atomics.add_get(clock, 2, div(byte_size(pcm) * 1_000_000, sink.frame * sink.rate))
    wait = started + played - sink.lead_us - now
    if wait > 0, do: Process.sleep(div(wait, 1_000))
  end

  defp start(clock, now) do
    case :atomics.get(clock, 1) do
      0 ->
        :atomics.put(clock, 1, now)
        now

      started ->
        started
    end
  end
end

defmodule KinoTuningFork.Sink do
  @moduledoc """
  A `TuningFork.Sink` that sends each chunk to a process as `{:pcm, binary}`, paced to real
  time so the receiver stays a little ahead of the clock.

      TuningFork.Stage.start_link(sink: KinoTuningFork.Sink, sink_opts: [owner: self()])
  """

  @behaviour TuningFork.Sink

  @type t :: %{owner: pid(), rate: pos_integer(), channels: pos_integer(), lead: float()}

  @doc """
  Open the sink.

  ## Options

    * `:owner` — who receives `{:pcm, binary}`, default the opening process
    * `:rate`, `:channels` — as the stage runs
    * `:lead` — how far ahead of real time chunks are sent, in seconds, default 0.75
  """
  @impl true
  def open(opts) do
    {:ok,
     %{
       owner: Keyword.get(opts, :owner, self()),
       rate: Keyword.get(opts, :rate, 44_100),
       channels: Keyword.get(opts, :channels, 2),
       lead: Keyword.get(opts, :lead, 0.75) / 1.0
     }}
  end

  @doc "Send `pcm` to the owner, then wait until the audio sent so far is `:lead` seconds ahead of the clock."
  @impl true
  def write(%{owner: owner, rate: rate, channels: channels, lead: lead}, pcm) do
    send(owner, {:pcm, pcm})

    now = System.monotonic_time(:millisecond)
    {started, sent} = Process.get(__MODULE__, {now, 0})
    sent = sent + div(byte_size(pcm), channels * 2)
    Process.put(__MODULE__, {started, sent})

    due = started + sent * 1_000 / rate - lead * 1_000
    if due > now, do: Process.sleep(round(due - now))

    :ok
  end

  @impl true
  def close(_state) do
    Process.delete(__MODULE__)
    :ok
  end
end

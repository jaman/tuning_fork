defmodule TuningFork.Sink.Buffer do
  @moduledoc """
  A sink that keeps everything written in a caller-owned process, for recording a stage.

      {:ok, tape} = TuningFork.Sink.Buffer.start_link()
      {:ok, _stage} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Buffer,
                                                  sink_opts: [into: tape])
      TuningFork.Sink.Buffer.wav(tape) |> then(&File.write!("take.wav", &1))
  """

  @behaviour TuningFork.Sink

  use Agent

  alias TuningFork.Wav

  @doc """
  Start a buffer, linked to the caller.

  `opts` are `Agent.start_link/2`'s options, such as `:name`.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{chunks: [], rate: 44_100, channels: 2} end, opts)
  end

  @doc """
  Open the sink onto a running buffer.

  ## Options

    * `:into` — the buffer to write to. Required; returns `{:error, :no_buffer_given}`
      without it
    * `:rate` — samples per second, default 44100. Kept for `wav/1` and `duration/1`
    * `:channels` — samples per frame, default 2. Kept the same way
  """
  @impl true
  def open(opts) do
    case Keyword.fetch(opts, :into) do
      {:ok, buffer} ->
        rate = Keyword.get(opts, :rate, 44_100)
        channels = Keyword.get(opts, :channels, 2)

        Agent.update(buffer, &%{&1 | rate: rate, channels: channels})
        {:ok, buffer}

      :error ->
        {:error, :no_buffer_given}
    end
  end

  @doc "Append `pcm` to the buffer. Does not sleep."
  @impl true
  def write(buffer, pcm) do
    Agent.update(buffer, &%{&1 | chunks: [pcm | &1.chunks]})
  end

  @impl true
  def close(_buffer), do: :ok

  @doc "Everything written so far as one PCM binary, in the order it was written."
  @spec take(Agent.agent()) :: binary()
  def take(buffer) do
    Agent.get(buffer, &(&1.chunks |> Enum.reverse() |> IO.iodata_to_binary()))
  end

  @doc "Everything written so far as a WAV, at the rate and channels the stage opened with."
  @spec wav(Agent.agent()) :: binary()
  def wav(buffer) do
    %{chunks: chunks, rate: rate, channels: channels} = Agent.get(buffer, & &1)

    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> Wav.encode(rate: rate, channels: channels)
  end

  @doc "How long the recording runs, in seconds."
  @spec duration(Agent.agent()) :: float()
  def duration(buffer) do
    %{rate: rate, channels: channels} = Agent.get(buffer, & &1)

    Wav.duration(take(buffer), rate, channels)
  end

  @doc "Throw away what has been recorded. The buffer keeps running."
  @spec clear(Agent.agent()) :: :ok
  def clear(buffer), do: Agent.update(buffer, &%{&1 | chunks: []})

  @doc "Stop the buffer, discarding the recording."
  @spec stop(Agent.agent()) :: :ok
  def stop(buffer), do: Agent.stop(buffer)
end

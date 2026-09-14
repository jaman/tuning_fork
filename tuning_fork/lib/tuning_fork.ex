defmodule TuningFork do
  @moduledoc """
  Sound synthesised on the BEAM: play a `TuningFork.Voice` on a `TuningFork.Stage`.

      {:ok, _pid} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Speaker)
      TuningFork.play(TuningFork.Voice.new(shape: :sine, freq: 440.0))
  """

  alias TuningFork.{Stage, Voice}

  @doc """
  Start a stage under `tuning_fork`'s own `DynamicSupervisor`.

  `opts` are `TuningFork.Stage.start_link/1`'s options. The stage is not linked to the
  caller.
  """
  @spec start_stage(keyword()) :: DynamicSupervisor.on_start_child()
  def start_stage(opts \\ []) do
    DynamicSupervisor.start_child(TuningFork.StageSupervisor, {Stage, opts})
  end

  @doc """
  Sound a voice on the stage registered as `TuningFork.Stage`.

  Returns immediately; the voice is rendered inside the stage.
  """
  @spec play(Voice.t()) :: :ok
  def play(%Voice{} = voice), do: Stage.play(Stage, voice)

  @doc """
  Render a voice to signed 16-bit little-endian PCM without playing it.

  `rate` is samples per second and `channels` is 1 for mono or 2 for stereo. Stereo applies
  the voice's `:pan`.
  """
  @spec render(Voice.t(), pos_integer(), pos_integer()) :: binary()
  def render(%Voice{} = voice, rate \\ 44_100, channels \\ 2) do
    Voice.render(voice, rate, channels)
  end

  @doc """
  Whether this machine can play sound.

  Asked of `TuningFork.Sink.Speaker`, and false when the `tuning_fork_speaker` package is
  not installed.
  """
  @spec available?() :: boolean()
  def available? do
    module = speaker()

    Code.ensure_loaded?(module) and function_exported?(module, :available?, 0) and
      module.available?()
  end

  defp speaker, do: Module.concat([:TuningFork, :Sink, :Speaker])
end

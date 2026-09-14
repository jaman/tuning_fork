defmodule TuningFork.Envelope do
  @moduledoc """
  An attack-decay-sustain-release shape in seconds, sampled by time.

      TuningFork.Envelope.new(attack: 0.01, decay: 0.2, sustain: 0.4, release: 0.3)
  """

  @type t :: %__MODULE__{
          attack: float(),
          decay: float(),
          sustain: float(),
          hold: float(),
          release: float(),
          curve: float()
        }

  defstruct attack: 0.005, decay: 0.05, sustain: 0.0, hold: 0.0, release: 0.02, curve: 2.0

  @doc """
  An envelope, with anything unset left at its default.

  ## Options

    * `:attack` — seconds from silence to full level, default 0.005
    * `:decay` — seconds from full level down to `:sustain`, default 0.05
    * `:sustain` — the level held after the decay, 0.0 to 1.0, default 0.0
    * `:hold` — seconds spent at `:sustain`, default 0.0
    * `:release` — seconds from `:sustain` back to silence, default 0.02
    * `:curve` — the exponent the decay falls by, default 2.0; 1.0 is a straight line
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc """
  A percussive envelope: a 2 ms attack, `decay` seconds of fall, and no sustain or release.
  """
  @spec hit(float()) :: t()
  def hit(decay), do: %__MODULE__{attack: 0.002, decay: decay, sustain: 0.0, release: 0.0}

  @doc """
  How long the envelope sounds, in seconds: attack, decay, hold and release together, or
  attack and decay alone when `sustain` is 0.0, since nothing is left to hold or release.

      iex> TuningFork.Envelope.duration(TuningFork.Envelope.new(attack: 0.1, decay: 0.2, sustain: 0.5, hold: 1.0, release: 0.3))
      1.6
      iex> TuningFork.Envelope.duration(TuningFork.Envelope.new(attack: 0.1, decay: 0.4, sustain: 0.0, hold: 1.0, release: 0.3))
      0.5
  """
  @spec duration(t()) :: float()
  def duration(%__MODULE__{sustain: sustain} = env) when sustain <= 0.0,
    do: (env.attack + env.decay) / 1.0

  def duration(%__MODULE__{} = env), do: env.attack + env.decay + env.hold + env.release

  @doc """
  The envelope with its decay set so the whole of it lasts `seconds`: the decay is `seconds`
  less the attack and, when there is a sustain level to release from, the release; any hold
  is dropped. The decay is never under 10 ms.

      iex> TuningFork.Envelope.spanning(TuningFork.Envelope.new(attack: 0.1, sustain: 0.5, release: 0.2), 1.0).decay
      0.7
      iex> TuningFork.Envelope.spanning(TuningFork.Envelope.new(attack: 0.1, sustain: 0.0, release: 0.2), 1.0).decay
      0.9
      iex> TuningFork.Envelope.spanning(TuningFork.Envelope.new(attack: 0.1, sustain: 1.0, hold: 2.0, release: 0.2), 1.0) |> TuningFork.Envelope.duration()
      1.0
  """
  @spec spanning(t(), number()) :: t()
  def spanning(%__MODULE__{} = env, seconds) do
    %{env | decay: max(seconds - env.attack - released(env), 0.01), hold: 0.0}
  end

  defp released(%__MODULE__{sustain: sustain}) when sustain <= 0.0, do: 0.0
  defp released(%__MODULE__{release: release}), do: release

  @doc """
  The level at `t` seconds, from 0.0 to 1.0.

  0.0 before the envelope starts and after it ends.
  """
  @spec level(t(), float()) :: float()
  def level(%__MODULE__{}, t) when t < 0, do: 0.0

  def level(%__MODULE__{} = env, t) do
    decay_end = env.attack + env.decay
    hold_end = decay_end + env.hold

    cond do
      t < env.attack and env.attack > 0 ->
        t / env.attack

      t < decay_end and env.decay > 0 ->
        fade(env, (t - env.attack) / env.decay)

      t < hold_end ->
        env.sustain

      t < hold_end + env.release and env.release > 0 ->
        env.sustain * (1 - (t - hold_end) / env.release)

      true ->
        0.0
    end
  end

  defp fade(%__MODULE__{sustain: sustain, curve: curve}, progress) do
    sustain + (1.0 - sustain) * :math.pow(1.0 - progress, curve)
  end
end

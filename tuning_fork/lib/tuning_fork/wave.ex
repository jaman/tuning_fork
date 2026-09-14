defmodule TuningFork.Wave do
  @moduledoc """
  Oscillators, as functions from phase (0.0 to 1.0 over one cycle) to amplitude (-1.0 to 1.0).

      TuningFork.Wave.sample(:sine, 0.25)
  """

  alias TuningFork.Rand

  @type shape :: :sine | :square | :saw | :triangle
  @type seed :: integer()

  @doc """
  One sample of `shape` at `phase`, with no band limiting.

  `phase` is a position in the cycle from 0.0 to 1.0. The result runs -1.0 to 1.0.
  """
  @spec sample(shape(), float()) :: float()
  def sample(shape, phase), do: sample(shape, phase, 0.0)

  @doc """
  One sample of `shape` at `phase`, band limited for a phase step of `step` per sample.

  `step` is `freq / rate`. A `step` of 0.0 gives the raw shape. `:sine` and `:triangle`
  ignore `step`.
  """
  @spec sample(shape(), float(), float()) :: float()
  def sample(:sine, phase, _step), do: :math.sin(2 * :math.pi() * phase)

  def sample(:square, phase, step) do
    raw = if phase < 0.5, do: 1.0, else: -1.0

    raw + blep(phase, step) - blep(wrap(phase + 0.5), step)
  end

  def sample(:saw, phase, step), do: 2.0 * phase - 1.0 - blep(phase, step)

  def sample(:triangle, phase, _step) do
    if phase < 0.5, do: 4.0 * phase - 1.0, else: 3.0 - 4.0 * phase
  end

  defp wrap(phase), do: phase - trunc(phase)

  defp blep(_phase, step) when step <= 0.0, do: 0.0

  defp blep(phase, step) when phase < step do
    at = phase / step

    at + at - at * at - 1.0
  end

  defp blep(phase, step) when phase > 1.0 - step do
    at = (phase - 1.0) / step

    at * at + at + at + 1.0
  end

  defp blep(_phase, _step), do: 0.0

  @doc "A seed for `noise/1`, from any term."
  @spec seed(term()) :: seed()
  def seed(term), do: Rand.new(term).state

  @doc """
  One sample of white noise, from -1.0 to 1.0, and the seed for the next. The same seed
  always gives the same sequence.
  """
  @spec noise(seed()) :: {float(), seed()}
  def noise(seed) do
    next = Rand.step(seed)
    {next / (Rand.modulus() / 2) - 1.0, next}
  end
end

defmodule TuningFork.Filter do
  @moduledoc """
  A resonant filter, cut off at a frequency in hertz.

      TuningFork.Filter.new(hz: 800, q: 6.0, poles: 4)
  """

  alias TuningFork.{Curve, Envelope}

  @type kind :: :lowpass | :highpass | :bandpass

  @type model :: :ladder | :svf

  @type t :: %__MODULE__{
          kind: kind(),
          model: model(),
          hz: float(),
          q: float(),
          drive: float(),
          poles: 2 | 4,
          envelope: Envelope.t() | nil,
          amount: float(),
          curve: Curve.t() | nil
        }

  defstruct kind: :lowpass,
            model: :ladder,
            hz: 1200.0,
            q: 1.0,
            drive: 0.69,
            poles: 4,
            envelope: nil,
            amount: 0.0,
            curve: nil

  @typedoc "What a filter carries between samples. Opaque; make one with `start/1`."
  @opaque state ::
            {float(), float(), float(), float()}
            | {float(), float(), float(), float(), float(), float(), float()}

  @doc """
  A filter from options.

  ## Options

    * `:kind` — `:lowpass`, `:highpass` or `:bandpass`, default `:lowpass`
    * `:model` — `:ladder` or `:svf`, default `:ladder`. A `:highpass` or `:bandpass` is always
      `:svf`
    * `:hz` — the cutoff in hertz, default 1200.0
    * `:q` — resonance, 0 and up; default 1.0. Values past about 62 are all as resonant as it
      goes
    * `:drive` — ladder saturation, as an exponent; default 0.69. `:svf` ignores it
    * `:poles` — 2 or 4, for `:svf` only; default 4. The ladder is always four
    * `:envelope` — a `TuningFork.Envelope` that sweeps the cutoff, or `nil`
    * `:amount` — how far the envelope sweeps, in octaves above `:hz`; default 0.0
    * `:curve` — a `TuningFork.Curve` over seconds into the note, multiplying the cutoff, or
      `nil`
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    filter = struct!(__MODULE__, opts)

    %{
      filter
      | hz: filter.hz / 1.0,
        q: max(filter.q / 1.0, 0.0),
        drive: filter.drive / 1.0,
        amount: filter.amount / 1.0,
        model: if(filter.kind == :lowpass, do: filter.model, else: :svf)
    }
  end

  @doc "The state a filter starts from, with nothing yet stored in it."
  @spec start(t() | nil) :: state()
  def start(%__MODULE__{model: :ladder} = filter),
    do: {drive(filter), feedback(filter), makeup(filter), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0}

  def start(_filter), do: {0.0, 0.0, 0.0, 0.0}

  @doc """
  One sample through the filter, and the state to carry to the next.

  `at` is how far into the note this sample is, in seconds; the envelope and curve are read
  against it. `rate` is samples per second. The cutoff is held between 20 Hz and `rate / 2.2`.
  """
  @spec step(t(), float(), state(), number(), pos_integer()) :: {float(), state()}
  def step(%__MODULE__{model: :ladder} = filter, sample, state, at, rate) do
    {drive, k, makeup, p0, p1, p2, p3, p32, p33, p34} = state
    hz = swept(filter, at) |> max(20.0) |> min(rate / 2.2)
    cutoff = min(hz * 2.0 * :math.pi() / rate, 1.0)

    out = p3 * 0.360891 + p32 * 0.41729 + p33 * 0.177896 + p34 * 0.0439725

    p0 = p0 + (tanh(sample * drive - k * out) - tanh(p0)) * cutoff
    p1 = p1 + (tanh(p0) - tanh(p1)) * cutoff
    p2 = p2 + (tanh(p1) - tanh(p2)) * cutoff
    p3 = p3 + (tanh(p2) - tanh(p3)) * cutoff

    {out * makeup, {drive, k, makeup, p0, p1, p2, p3, p3, p32, p33}}
  end

  def step(%__MODULE__{} = filter, sample, {one, two, three, four}, at, rate) do
    {g, k} = coefficients(filter, at, rate)
    level = evenness(filter)

    {first, one, two} = pole(filter.kind, sample, one, two, g, k)

    if filter.poles == 4 do
      {second, three, four} = pole(filter.kind, first, three, four, g, k)

      {second * level, {one, two, three, four}}
    else
      {first * level, {one, two, three, four}}
    end
  end

  defp evenness(%__MODULE__{kind: :lowpass}), do: 1.0
  defp evenness(%__MODULE__{q: q}) when q <= 1.0, do: 1.0
  defp evenness(%__MODULE__{q: q}), do: 1.0 / q

  @doc """
  How hard the ladder's resonance is fed back: `:q` scaled by 0.13 and held at 8.0.

      iex> TuningFork.Filter.feedback(TuningFork.Filter.new(q: 9.0))
      1.17
      iex> TuningFork.Filter.feedback(TuningFork.Filter.new(q: 200.0))
      8.0
  """
  @spec feedback(t()) :: float()
  def feedback(%__MODULE__{q: q}), do: min(8.0, q * 0.13)

  @doc """
  The gain the signal is pushed into the ladder with: `e` to the power of `:drive`, held
  between 0.1 and 2000.0.
  """
  @spec drive(t()) :: float()
  def drive(%__MODULE__{drive: drive}), do: drive |> :math.exp() |> max(0.1) |> min(2000.0)

  @doc """
  What the ladder's output is multiplied by: `1 / drive/1` times `1 + feedback/1`, the second
  factor held at 1.75.

      iex> TuningFork.Filter.makeup(TuningFork.Filter.new(drive: 0.0, q: 0.0))
      1.0
  """
  @spec makeup(t()) :: float()
  def makeup(%__MODULE__{} = filter) do
    1.0 / drive(filter) * min(1.75, 1.0 + feedback(filter))
  end

  defp tanh(x) when x > 4.0, do: 1.0
  defp tanh(x) when x < -4.0, do: -1.0

  defp tanh(x) do
    squared = x * x

    min(max(x * (27.0 + squared) / (27.0 + 9.0 * squared), -1.0), 1.0)
  end

  defp pole(kind, input, ic1, ic2, g, k) do
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2

    v3 = input - ic2
    v1 = a1 * ic1 + a2 * v3
    v2 = ic2 + a2 * ic1 + a3 * v3

    out =
      case kind do
        :lowpass -> v2
        :bandpass -> v1
        :highpass -> input - k * v1 - v2
      end

    {out, 2.0 * v1 - ic1, 2.0 * v2 - ic2}
  end

  defp coefficients(%__MODULE__{} = filter, at, rate) do
    hz = swept(filter, at) |> max(20.0) |> min(rate / 2.2)

    {:math.tan(:math.pi() * hz / rate), 1.0 / max(filter.q, 0.05)}
  end

  defp swept(%__MODULE__{envelope: nil} = filter, at), do: filter.hz * curved(filter.curve, at)

  defp swept(%__MODULE__{} = filter, at) do
    open = Envelope.level(filter.envelope, at)

    filter.hz * :math.pow(2.0, filter.amount * open) * curved(filter.curve, at)
  end

  defp curved(nil, _at), do: 1.0
  defp curved(curve, at), do: Curve.at(curve, at / 1.0)

  @doc """
  Where the cutoff sits `at` seconds into a note, in hertz, with the envelope and curve
  applied. Without either this is `:hz`.
  """
  @spec cutoff_at(t(), number()) :: float()
  def cutoff_at(%__MODULE__{} = filter, at), do: swept(filter, at)
end

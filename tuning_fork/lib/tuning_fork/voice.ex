defmodule TuningFork.Voice do
  @moduledoc """
  One sound described as a waveform, pitch, envelope and filter, rendered to 16-bit PCM.

      TuningFork.Voice.new(shape: :saw, freq: 220.0) |> TuningFork.Voice.render(44_100)
  """

  alias TuningFork.{Curve, Envelope, Filter, Mixer, Sample, Wave}

  @type t :: %__MODULE__{
          shape: Wave.shape() | :noise,
          freq: float(),
          sweep: float(),
          envelope: Envelope.t(),
          gain: float(),
          pan: float(),
          cutoff: float() | nil,
          filter: Filter.t() | nil,
          highpass: float() | nil,
          crush: float() | nil,
          distort: float() | nil,
          waveshape: float() | nil,
          vowel: atom() | nil,
          fm: float() | nil,
          fmh: float() | nil,
          fmattack: float() | nil,
          vib: float() | nil,
          vibmod: float() | nil,
          coarse: number() | nil,
          phaser: float() | nil,
          phaserdepth: float() | nil,
          curves: %{optional(:freq | :cutoff | :gain) => Curve.t()},
          sample: Sample.t() | nil,
          seed: Wave.seed()
        }

  defstruct shape: :sine,
            freq: 440.0,
            sweep: 1.0,
            envelope: nil,
            gain: 0.8,
            pan: 0.0,
            cutoff: nil,
            highpass: nil,
            filter: nil,
            crush: nil,
            distort: nil,
            waveshape: nil,
            vowel: nil,
            fm: nil,
            fmh: nil,
            fmattack: nil,
            vib: nil,
            vibmod: nil,
            coarse: nil,
            phaser: nil,
            phaserdepth: nil,
            curves: %{},
            sample: nil,
            seed: 1

  @peak 32_767

  @doc """
  A voice, with anything unset left at its default. An unknown key raises `KeyError`.

  ## Options

    * `:shape` — `:sine`, `:square`, `:saw`, `:triangle` or `:noise`, default `:sine`
    * `:freq` — starting pitch in Hz, default 440.0. Ignored by `:noise`
    * `:sweep` — pitch multiplier reached by the end of the envelope, default 1.0. A `:freq`
      curve supersedes it, even a flat one
    * `:envelope` — a `TuningFork.Envelope`. When `nil`, a voice with a `:sample` gets one
      spanning the recording at the voice's pitch with a 2 ms attack and 4 ms release, and
      any other voice gets `TuningFork.Envelope.new/1`'s defaults
    * `:gain` — 0.0 to 1.0, default 0.8
    * `:pan` — `-1.0` hard left to `1.0` hard right, default `0.0`
    * `:filter` — a `TuningFork.Filter`, or `nil` for none
    * `:cutoff` — one-pole lowpass coefficient, 0.0 to 1.0; `nil` for none
    * `:highpass` — one-pole highpass coefficient, 0.0 to 1.0; `nil` for none
    * `:crush` — round every sample to this many bits; `nil` or 16 for none
    * `:distort` — drive into a soft clipper, 0.0 upwards; `nil` for none
    * `:waveshape` — Strudel's `shape` waveshaper, 0.0 to below 1.0; `nil` for none
    * `:vowel` — `:a`, `:e`, `:i`, `:o` or `:u`; `nil` for none
    * `:fm`, `:fmh`, `:fmattack` — modulation index of a second oscillator, its frequency as
      a multiple of `:freq`, and the fraction of the note over which the index arrives
    * `:vib`, `:vibmod` — vibrato rate in hertz and depth in semitones
    * `:coarse` — hold every sample for this many; `nil` or 1 for none
    * `:phaser`, `:phaserdepth` — sweep rate in hertz and depth 0.0 to 1.0
    * `:curves` — `%{freq: curve, cutoff: curve, gain: curve}` of `TuningFork.Curve`s, each a
      multiplier over its field across the note
    * `:sample` — a `TuningFork.Sample` to play instead of an oscillator, or `nil`
    * `:seed` — the noise seed; the same seed renders the same samples
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    voice = struct!(__MODULE__, opts)
    %{voice | envelope: voice.envelope || fitted_envelope(voice)}
  end

  defp fitted_envelope(%__MODULE__{sample: nil}), do: Envelope.new()

  defp fitted_envelope(%__MODULE__{sample: %Sample{} = sample} = voice) do
    playing = Sample.duration(sample, voice.freq)

    Envelope.new(
      attack: 0.002,
      decay: 0.0,
      sustain: 1.0,
      hold: max(playing - 0.006, 0.0),
      release: 0.004
    )
  end

  @doc "How long the voice sounds for, in seconds: the length of its envelope."
  @spec duration(t()) :: float()
  def duration(%__MODULE__{envelope: envelope}), do: Envelope.duration(envelope)

  @doc """
  Render to mono signed 16-bit little-endian PCM at `rate` samples per second.

  The result is `duration/1` seconds long, and at least one frame. `:pan` is not applied.
  """
  @spec render(t(), pos_integer()) :: binary()
  def render(%__MODULE__{} = voice, rate) do
    frames = max(1, trunc(duration(voice) * rate))
    mod = modulation(voice)

    0..(frames - 1)
    |> Enum.reduce(
      {<<>>, 0.0, voice.seed, 0.0, 0.0, Filter.start(voice.filter), nil, %{}},
      &step(voice, mod, rate, frames, &1, &2)
    )
    |> elem(0)
  end

  @doc """
  The curves actually moving on this voice, as `%{freq:, cutoff:, gain:}`.

  A field whose curve holds one value is `nil` here, and so is `:freq` where `:sweep` is 1.0
  and no freq curve is given.
  """
  @spec modulation(t()) :: %{
          freq: Curve.t() | nil,
          cutoff: Curve.t() | nil,
          gain: Curve.t() | nil
        }
  def modulation(%__MODULE__{} = voice) do
    %{
      freq: freq_modulation(voice),
      cutoff: active(Map.get(voice.curves, :cutoff)),
      gain: active(Map.get(voice.curves, :gain))
    }
  end

  defp freq_modulation(%__MODULE__{} = voice) do
    case Map.fetch(voice.curves, :freq) do
      {:ok, curve} -> active(curve)
      :error -> if voice.sweep == 1.0, do: nil, else: Curve.linear(1.0, voice.sweep)
    end
  end

  defp active(curve), do: unless(Curve.flat?(curve), do: curve)

  @doc false
  @spec step(t(), map(), pos_integer(), pos_integer(), non_neg_integer(), tuple()) :: tuple()
  def step(voice, mod, rate, frames, index, {acc, phase, seed, low, high}) do
    step(voice, mod, rate, frames, index, {acc, phase, seed, low, high, nil})
  end

  @doc false
  @spec step(t(), map(), pos_integer(), pos_integer(), non_neg_integer(), tuple()) :: tuple()
  def step(voice, mod, rate, frames, index, {acc, phase, seed, low, high, tone}) do
    step(voice, mod, rate, frames, index, {acc, phase, seed, low, high, tone, nil})
  end

  @doc false
  @spec step(t(), map(), pos_integer(), pos_integer(), non_neg_integer(), tuple()) :: tuple()
  def step(voice, mod, rate, frames, index, {acc, phase, seed, low, high, tone, mouth}) do
    step(voice, mod, rate, frames, index, {acc, phase, seed, low, high, tone, mouth, %{}})
  end

  @doc false
  @spec step(t(), map(), pos_integer(), pos_integer(), non_neg_integer(), tuple()) :: tuple()
  def step(voice, mod, rate, frames, index, {acc, phase, seed, low, high, tone, mouth, extra}) do
    progress = index / frames
    at = index / rate
    {carrier, extra} = bent(voice, phase, at, progress, rate, extra)
    {raw, seed} = oscillate(voice, carrier, seed, step_of(voice, mod, progress, rate))
    {shaped, tone} = resonant(voice.filter, raw, tone, at, rate)
    {passed, low} = lowpass(cutoff_at(voice.cutoff, mod.cutoff, progress), shaped, low)
    {filtered, high} = highpass(voice.highpass, passed, high)
    {said, mouth} = spoken(formants(voice.vowel), filtered, mouth, at, rate)

    {swept, extra} = phased(voice, said, at, rate, extra)
    {held, extra} = coarsened(swept, voice.coarse, extra)

    level = Envelope.level(voice.envelope, at) * voice.gain * factor(mod.gain, progress)
    dirtied = held |> distort(voice.distort) |> waveshape(voice.waveshape) |> crush(voice.crush)
    sample = clamp(trunc(saturate(dirtied * level) * @peak))

    {<<acc::binary, sample::16-signed-little>>, advance(voice, mod, phase, progress, rate), seed,
     low, high, tone, mouth, extra}
  end

  defp bent(%__MODULE__{fm: nil, vib: nil}, phase, _at, _progress, _rate, extra) do
    {phase, extra}
  end

  defp bent(%__MODULE__{} = voice, phase, at, progress, rate, extra) do
    modulator = Map.get(extra, :fm_phase, 0.0)
    wobble = Map.get(extra, :vib_phase, 0.0)

    index = fm_index(voice, progress)
    deep = (voice.vibmod || 0.5) / 12.0

    bent =
      wrapped(
        phase + index / (2.0 * :math.pi()) * :math.sin(2.0 * :math.pi() * modulator) +
          deep * :math.sin(2.0 * :math.pi() * wobble)
      )

    extra =
      extra
      |> Map.put(:fm_phase, wrapped(modulator + voice.freq * (voice.fmh || 1.0) / rate))
      |> Map.put(:vib_phase, wrapped(wobble + (voice.vib || 0.0) / rate))

    _ = at

    {bent, extra}
  end

  defp fm_index(%__MODULE__{fm: nil}, _progress), do: 0.0

  defp fm_index(%__MODULE__{fm: index, fmattack: nil}, _progress), do: index

  defp fm_index(%__MODULE__{fm: index, fmattack: attack}, progress) when attack > 0 do
    index * min(progress / attack, 1.0)
  end

  defp fm_index(%__MODULE__{fm: index}, _progress), do: index

  defp wrapped(phase), do: phase - Float.floor(phase)

  defp phased(%__MODULE__{phaser: nil}, sample, _at, _rate, extra), do: {sample, extra}

  defp phased(%__MODULE__{} = voice, sample, at, _rate, extra) do
    depth = (voice.phaserdepth || 0.5) |> max(0.0) |> min(1.0)
    lfo = (:math.sin(2.0 * :math.pi() * voice.phaser * at) + 1.0) / 2.0
    coefficient = 0.1 + lfo * 0.8 * depth

    {h1, h2, h3, h4} =
      case Map.fetch(extra, :phaser) do
        {:ok, held} -> held
        :error -> {0.0, 0.0, 0.0, 0.0}
      end

    out1 = -coefficient * sample + h1
    out2 = -coefficient * out1 + h2
    out3 = -coefficient * out2 + h3
    out4 = -coefficient * out3 + h4

    stages =
      {sample + coefficient * out1, out1 + coefficient * out2, out2 + coefficient * out3,
       out3 + coefficient * out4}

    {(sample + out4 * depth) * 0.7, Map.put(extra, :phaser, stages)}
  end

  @doc """
  Hold each sample for `every` samples, carrying the hold in `extra`. `nil` or 1 changes
  nothing.
  """
  @spec coarsened(float(), number() | nil, map()) :: {float(), map()}
  def coarsened(sample, nil, extra), do: {sample, extra}
  def coarsened(sample, every, extra) when every <= 1, do: {sample, extra}

  def coarsened(sample, every, extra) do
    step = trunc(every)
    {count, held} = Map.get(extra, :coarse, {0, sample})

    if rem(count, step) == 0 do
      {sample, Map.put(extra, :coarse, {count + 1, sample})}
    else
      {held, Map.put(extra, :coarse, {count + 1, held})}
    end
  end

  @doc """
  Bend a sample over 0.7 softly towards full scale instead of clipping it. Samples within
  -0.7 to 0.7 are unchanged.

      iex> TuningFork.Voice.saturate(0.5)
      0.5
      iex> TuningFork.Voice.saturate(4.0) < 1.0
      true
  """
  @spec saturate(float()) :: float()
  def saturate(sample) when sample >= -0.7 and sample <= 0.7, do: sample

  def saturate(sample) do
    over = (abs(sample) - 0.7) / 0.3
    sign = if sample < 0, do: -1.0, else: 1.0

    sign * (0.7 + 0.3 * :math.tanh(over))
  end

  @doc """
  The vowels `:vowel` takes, each with its three formants as `{hz, level}` pairs.

      iex> TuningFork.Voice.vowels() |> Keyword.keys()
      [:a, :e, :i, :o, :u]
  """
  @spec vowels() :: keyword([{float(), float()}])
  def vowels do
    [
      a: [{800.0, 1.0}, {1150.0, 0.45}, {2900.0, 0.2}],
      e: [{400.0, 1.0}, {1600.0, 0.5}, {2700.0, 0.25}],
      i: [{350.0, 1.0}, {1700.0, 0.4}, {2700.0, 0.35}],
      o: [{450.0, 1.0}, {800.0, 0.6}, {2830.0, 0.12}],
      u: [{325.0, 1.0}, {700.0, 0.5}, {2530.0, 0.1}]
    ]
  end

  defp formants(nil), do: nil

  defp formants(vowel) do
    case Keyword.fetch(vowels(), vowel) do
      {:ok, peaks} -> Enum.map(peaks, fn {hz, level} -> {band(hz), level} end)
      :error -> nil
    end
  end

  @formant_q 8.0

  defp band(hz) do
    Filter.new(kind: :bandpass, model: :svf, hz: hz, q: @formant_q, poles: 2)
  end

  defp spoken(nil, sample, state, _at, _rate), do: {sample, state}

  defp spoken(peaks, sample, nil, at, rate) do
    spoken(peaks, sample, Enum.map(peaks, fn _peak -> Filter.start(nil) end), at, rate)
  end

  defp spoken(peaks, sample, states, at, rate) do
    {values, states} =
      [peaks, states]
      |> Enum.zip()
      |> Enum.map_reduce([], fn {{filter, level}, state}, done ->
        {value, state} = Filter.step(filter, sample, state, at, rate)

        {value * level, [state | done]}
      end)

    {Enum.sum(values) * @formant_q * 1.6, Enum.reverse(states)}
  end

  @doc """
  Round the sample to `bits` of resolution. `nil` or 16 and up leaves it alone; `bits` may be
  fractional.

      iex> TuningFork.Voice.crush(0.3, nil)
      0.3
      iex> TuningFork.Voice.crush(0.3, 1) in [-1.0, 0.0, 1.0]
      true
  """
  @spec crush(float(), number() | nil) :: float()
  def crush(sample, nil), do: sample
  def crush(sample, bits) when bits >= 16, do: sample

  def crush(sample, bits) do
    steps = :math.pow(2, max(bits, 1) - 1)

    Float.round(sample * steps) / steps
  end

  @doc """
  Drive the sample through a soft clipper, `amount` deciding how hard. `nil` or 0.0 leaves
  it alone; the gain is normalised out afterwards.

      iex> TuningFork.Voice.distort(0.5, 0.0)
      0.5
      iex> TuningFork.Voice.distort(0.5, 4.0) > 0.5
      true
  """
  @spec distort(float(), number() | nil) :: float()
  def distort(sample, nil), do: sample
  def distort(sample, amount) when amount <= 0, do: sample

  def distort(sample, amount) do
    drive = 1.0 + amount

    :math.tanh(sample * drive) / :math.tanh(drive)
  end

  @doc """
  Bend the sample by Strudel's `shape` curve, `amount` from 0.0 (none) towards 1.0 (hard).
  `nil` or 0.0 leaves it alone; 1.0 and above is treated as just under 1.0.

      iex> TuningFork.Voice.waveshape(0.5, 0.0)
      0.5
  """
  @spec waveshape(float(), number() | nil) :: float()
  def waveshape(sample, nil), do: sample
  def waveshape(sample, amount) when amount <= 0, do: sample

  def waveshape(sample, amount) do
    bent = min(amount, 1.0 - 4.0e-10)
    drive = 2.0 * bent / (1.0 - bent)

    (1.0 + drive) * sample / (1.0 + drive * abs(sample))
  end

  defp resonant(nil, sample, tone, _at, _rate), do: {sample, tone}

  defp resonant(filter, sample, nil, at, rate) do
    resonant(filter, sample, Filter.start(filter), at, rate)
  end

  defp resonant(filter, sample, tone, at, rate), do: Filter.step(filter, sample, tone, at, rate)

  defp factor(nil, _progress), do: 1.0
  defp factor(curve, progress), do: Curve.at(curve, progress)

  defp cutoff_at(nil, _curve, _progress), do: nil
  defp cutoff_at(cutoff, nil, _progress), do: cutoff

  defp cutoff_at(cutoff, curve, progress) do
    cutoff |> Kernel.*(Curve.at(curve, progress)) |> max(0.0) |> min(1.0)
  end

  @doc """
  Render for `channels` channels: 2 applies the voice's `:pan`, 1 is `render/2` unchanged.
  """
  @spec render(t(), pos_integer(), pos_integer()) :: binary()
  def render(%__MODULE__{} = voice, rate, channels) do
    voice |> render(rate) |> Mixer.pan(voice.pan, channels)
  end

  defp oscillate(%__MODULE__{sample: %Sample{} = sample}, position, seed, _step) do
    {Sample.at(sample, position), seed}
  end

  defp oscillate(%__MODULE__{shape: :noise}, _phase, seed, _step), do: Wave.noise(seed)

  defp oscillate(%__MODULE__{shape: shape}, phase, seed, step) do
    {Wave.sample(shape, phase, step), seed}
  end

  defp step_of(%__MODULE__{sample: %Sample{}}, _mod, _progress, _rate), do: 0.0
  defp step_of(%__MODULE__{shape: :noise}, _mod, _progress, _rate), do: 0.0

  defp step_of(%__MODULE__{freq: freq}, mod, progress, rate) do
    freq * factor(mod.freq, progress) / rate
  end

  defp advance(%__MODULE__{sample: %Sample{} = sample} = voice, mod, position, progress, rate) do
    Sample.looped(
      sample,
      position + Sample.ratio(sample, voice.freq * factor(mod.freq, progress), rate)
    )
  end

  defp advance(%__MODULE__{shape: :noise}, _mod, phase, _progress, _rate), do: phase

  defp advance(%__MODULE__{freq: freq}, mod, phase, progress, rate) do
    stepped = phase + freq * factor(mod.freq, progress) / rate
    stepped - trunc(stepped)
  end

  defp lowpass(nil, sample, state), do: {sample, state}

  defp lowpass(cutoff, sample, state) do
    next = state + cutoff * (sample - state)
    {next, next}
  end

  defp highpass(nil, sample, state), do: {sample, state}

  defp highpass(cutoff, sample, state) do
    next = state + cutoff * (sample - state)
    {sample - next, next}
  end

  defp clamp(value) when value > @peak, do: @peak
  defp clamp(value) when value < -@peak - 1, do: -@peak - 1
  defp clamp(value), do: value
end

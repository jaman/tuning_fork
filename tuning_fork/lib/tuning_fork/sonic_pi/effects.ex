defmodule TuningFork.SonicPi.Effects do
  @moduledoc """
  Sonic Pi's effects as the `TuningFork.Fx` effects that play them.

      iex> TuningFork.SonicPi.Effects.to_fx(:lpf, cutoff: 69)
      [lowpass: [hz: 440.0]]
  """

  alias TuningFork.SonicPi.{Names, Synth}

  @names ~w(reverb gverb echo slicer wobble ixi_techno panslicer pan level tremolo bitcrusher
            krush distortion tanh compressor lpf hpf rlpf rhpf nlpf nhpf nrlpf nrhpf bpf rbpf
            nbpf nrbpf flanger)a

  @waves %{0 => :saw, 1 => :square, 2 => :triangle, 3 => :sine}

  @doc "Every effect name, sorted."
  @spec names() :: [atom()]
  def names, do: Enum.sort(@names)

  @doc "Whether `name` is an effect here."
  @spec known?(atom()) :: boolean()
  def known?(name), do: name in @names

  @doc """
  The `TuningFork.Fx` effects `name` with `opts` stands for, as a keyword list.

  Usually one entry; `:krush` is two. Raises `ArgumentError` for a name that is not here.
  """
  @spec to_fx(atom(), keyword()) :: keyword()
  def to_fx(name, opts \\ []) do
    case Keyword.get(opts, :amp) do
      nil -> effect(name, opts)
      amp -> effect(name, opts) ++ [level: [amp: amp / 1.0]]
    end
  end

  defp effect(name, opts) when name in [:reverb, :gverb] do
    [
      reverb: [
        room: get(opts, :room, 0.6),
        damp: get(opts, :damp, 0.5),
        mix: get(opts, :mix, 0.4)
      ]
    ]
  end

  defp effect(:echo, opts) do
    phase = get(opts, :phase, Keyword.get(opts, :delay, 0.25))
    decay = get(opts, :decay, 2.0)

    [
      echo: [
        delay: phase,
        feedback: min(:math.pow(10.0, -3.0 * phase / max(decay, 0.001)), 0.95),
        mix: get(opts, :mix, 1.0)
      ]
    ]
  end

  defp effect(:slicer, opts) do
    [
      slicer: [
        phase: get(opts, :phase, 0.25),
        pulse_width: get(opts, :pulse_width, 0.5),
        amp_min: get(opts, :amp_min, 0.0),
        amp_max: get(opts, :amp_max, 1.0),
        wave: wave(opts, 1)
      ]
    ]
  end

  defp effect(:wobble, opts) do
    [
      wobble: [
        phase: get(opts, :phase, 0.5),
        cutoff_min: hz(opts, :cutoff_min, 60),
        cutoff_max: hz(opts, :cutoff_max, 120),
        q: Synth.resonance(get(opts, :res, 0.8)),
        pulse_width: get(opts, :pulse_width, 0.5),
        wave: wave(opts, 0)
      ]
    ]
  end

  defp effect(:ixi_techno, opts) do
    [
      wobble: [
        phase: get(opts, :phase, 4.0),
        cutoff_min: hz(opts, :cutoff_min, 60),
        cutoff_max: hz(opts, :cutoff_max, 120),
        q: Synth.resonance(get(opts, :res, 0.8)),
        wave: :sine
      ]
    ]
  end

  defp effect(:panslicer, opts) do
    [
      panslicer: [
        phase: get(opts, :phase, 0.25),
        pan_min: get(opts, :pan_min, -1.0),
        pan_max: get(opts, :pan_max, 1.0),
        pulse_width: get(opts, :pulse_width, 0.5),
        wave: wave(opts, 1)
      ]
    ]
  end

  defp effect(:pan, opts), do: [pan: [pan: get(opts, :pan, 0.0)]]

  defp effect(:level, opts), do: [level: [amp: get(opts, :amp, 1.0)]]

  defp effect(:tremolo, opts) do
    [tremolo: [phase: get(opts, :phase, 4.0), depth: get(opts, :depth, 0.5), wave: wave(opts, 3)]]
  end

  defp effect(:bitcrusher, opts) do
    [crush: [bits: get(opts, :bits, 8), sample_rate: get(opts, :sample_rate, 10_000)]]
  end

  defp effect(:krush, opts) do
    gain = get(opts, :gain, 5.0)

    [
      drive: [amount: min(gain / 10.0, 1.0)],
      lowpass: [hz: hz(opts, :cutoff, 100), q: Synth.resonance(get(opts, :res, 0.0))]
    ]
  end

  defp effect(name, opts) when name in [:distortion, :tanh] do
    [drive: [amount: get(opts, :distort, 0.5)]]
  end

  defp effect(:compressor, opts) do
    [
      compressor: [
        threshold: get(opts, :threshold, 0.2),
        clamp_time: get(opts, :clamp_time, 0.01),
        slope_above: get(opts, :slope_above, 0.5),
        slope_below: get(opts, :slope_below, 1.0),
        relax_time: get(opts, :relax_time, 0.01)
      ]
    ]
  end

  defp effect(name, opts) when name in [:lpf, :nlpf], do: [lowpass: [hz: hz(opts, :cutoff, 100)]]
  defp effect(name, opts) when name in [:hpf, :nhpf], do: [highpass: [hz: hz(opts, :cutoff, 100)]]

  defp effect(name, opts) when name in [:rlpf, :nrlpf] do
    [lowpass: [hz: hz(opts, :cutoff, 100), q: Synth.resonance(get(opts, :res, 0.5))]]
  end

  defp effect(name, opts) when name in [:rhpf, :nrhpf] do
    [highpass: [hz: hz(opts, :cutoff, 100), q: Synth.resonance(get(opts, :res, 0.5))]]
  end

  defp effect(name, opts) when name in [:bpf, :nbpf, :rbpf, :nrbpf] do
    [bandpass: [hz: hz(opts, :centre, 100), q: Synth.resonance(get(opts, :res, 0.6))]]
  end

  defp effect(:flanger, opts) do
    [
      flanger: [
        phase: get(opts, :phase, 4.0),
        delay: get(opts, :delay, 5.0),
        depth: get(opts, :depth, 5.0),
        feedback: get(opts, :feedback, 0.0),
        mix: get(opts, :mix, 1.0) * 0.5
      ]
    ]
  end

  defp effect(name, _opts),
    do: raise(ArgumentError, "no effect named #{inspect(name)}; there are #{inspect(names())}")

  defp get(opts, key, default), do: Keyword.get(opts, key, default) / 1.0

  defp hz(opts, key, default), do: opts |> Keyword.get(key, default) |> Names.midi_to_hz()

  defp wave(opts, default) do
    case Keyword.get(opts, :wave, default) do
      number when is_integer(number) -> Map.get(@waves, number, :square)
      atom when is_atom(atom) -> atom
    end
  end
end

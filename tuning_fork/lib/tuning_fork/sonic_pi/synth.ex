defmodule TuningFork.SonicPi.Synth do
  @moduledoc """
  Sonic Pi's synths as `TuningFork.Voice`s.

      Synth.voice(:tb303, 110.0, cutoff: 90, res: 0.9, release: 0.25)
  """

  alias TuningFork.{Envelope, Filter, Kit, Voice}
  alias TuningFork.SonicPi.Names

  @drums %{
    sc808_bassdrum: "bd",
    sc808_snare: "sn",
    sc808_clap: "cp",
    sc808_tomlo: "lt",
    sc808_tommid: "mt",
    sc808_tomhi: "ht",
    sc808_congalo: "lt",
    sc808_congamid: "mt",
    sc808_congahi: "ht",
    sc808_rimshot: "rim",
    sc808_claves: "rim",
    sc808_maracas: "sh",
    sc808_cowbell: "cow",
    sc808_closed_hihat: "hh",
    sc808_open_hihat: "oh",
    sc808_cymbal: "cr"
  }

  @synths %{
    beep: %{shape: :sine},
    sine: %{shape: :sine},
    saw: %{shape: :saw},
    tri: %{shape: :triangle, cutoff: 100},
    square: %{shape: :square, cutoff: 100},
    pulse: %{shape: :square, cutoff: 100},
    subpulse: %{shape: :square, cutoff: 100, sub: 1.0},
    dsaw: %{shape: :saw, cutoff: 100, detune: 0.1},
    dtri: %{shape: :triangle, cutoff: 100, detune: 0.1},
    dpulse: %{shape: :square, cutoff: 100, detune: 0.1},
    fm: %{shape: :sine, cutoff: 100, fm: 1.0, fmh: 0.5},
    mod_fm: %{shape: :sine, cutoff: 100, fm: 1.0, fmh: 0.5, mod: true},
    mod_saw: %{shape: :saw, cutoff: 100, mod: true},
    mod_dsaw: %{shape: :saw, cutoff: 100, detune: 0.1, mod: true},
    mod_sine: %{shape: :sine, cutoff: 100, mod: true},
    mod_beep: %{shape: :sine, cutoff: 100, mod: true},
    mod_tri: %{shape: :triangle, cutoff: 100, mod: true},
    mod_pulse: %{shape: :square, cutoff: 100, mod: true},
    tb303: %{
      shape: :saw,
      cutoff: 120,
      cutoff_min: 30,
      res: 0.9,
      model: :ladder,
      sweep_with_envelope: true
    },
    supersaw: %{shape: :saw, cutoff: 130, res: 0.7, voices: 3, detune: 0.12},
    tech_saws: %{shape: :saw, cutoff: 130, res: 0.7, voices: 3, detune: 0.06},
    hoover: %{
      shape: :saw,
      cutoff: 130,
      res: 0.1,
      voices: 2,
      detune: 0.2,
      attack: 0.05,
      vib: 5.0,
      vibmod: 0.2
    },
    prophet: %{shape: :saw, cutoff: 110, res: 0.7, voices: 2, detune: 0.1, vib: 0.5, vibmod: 0.05},
    blade: %{shape: :saw, cutoff: 100, vib: 6.0, vibmod: 0.3},
    pluck: %{shape: :saw, cutoff: 96, res: 0.2, pluck: true},
    kalimba: %{shape: :sine, fm: 0.4, fmh: 3.0, fmattack: 0.0, sustain: 4.0, kalimba: true},
    rodeo: %{shape: :sine, fm: 0.6, fmh: 2.0, cutoff: 72, decay: 1.0, sustain: 0.8},
    piano: %{shape: :sine, fm: 0.3, fmh: 2.0, fmattack: 0.0, piano: true},
    pretty_bell: %{shape: :sine, fm: 0.5, fmh: 3.5, fmattack: 0.0},
    dull_bell: %{shape: :sine, fm: 0.2, fmh: 2.4, fmattack: 0.0},
    growl: %{shape: :saw, cutoff: 130, res: 0.7, attack: 0.1, vib: 4.0, vibmod: 0.4, distort: 0.4},
    dark_ambience: %{
      shape: :triangle,
      cutoff: 110,
      res: 0.7,
      vib: 0.3,
      vibmod: 0.2,
      voices: 2,
      detune: 0.05
    },
    dark_sea_horn: %{
      shape: :triangle,
      attack: 1.0,
      release: 4.0,
      vib: 0.4,
      vibmod: 0.4,
      cutoff: 80
    },
    singer: %{shape: :saw, attack: 1.0, release: 4.0, vowel: :a, vib: 5.0, vibmod: 0.2},
    hollow: %{shape: :triangle, cutoff: 90, res: 0.99, vib: 0.2, vibmod: 0.1},
    zawa: %{
      shape: :saw,
      cutoff: 100,
      res: 0.9,
      vib: 8.0,
      vibmod: 0.05,
      phaser: 1.0,
      phaserdepth: 0.6
    },
    chiplead: %{shape: :square, crush: 6.0, coarse: 1},
    chipbass: %{shape: :triangle, crush: 5.0},
    chipnoise: %{shape: :noise, crush: 4.0, coarse: 8},
    noise: %{shape: :noise, cutoff: 110},
    gnoise: %{shape: :noise, cutoff: 110},
    bnoise: %{shape: :noise, cutoff: 90},
    pnoise: %{shape: :noise, cutoff: 96},
    cnoise: %{shape: :noise, cutoff: 110, crush: 3.0},
    winwood_lead: %{
      shape: :saw,
      cutoff: 119,
      res: 0.2,
      vib: 6.0,
      vibmod: 0.3,
      voices: 2,
      detune: 0.03
    },
    bass_foundation: %{shape: :saw, cutoff: 83, res: 0.5, sub: 0.6},
    bass_highend: %{shape: :saw, cutoff: 102, res: 0.9, distort: 0.3},
    organ_tonewheel: %{
      shape: :sine,
      attack: 0.01,
      sustain: 1.0,
      release: 0.01,
      harmonics: [1.0, 2.0, 3.0]
    },
    rhodey: %{shape: :sine, fm: 1.0, fmh: 1.0, attack: 0.001, decay: 1.0, fmattack: 0.0},
    gabberkick: %{
      shape: :sine,
      attack: 0.001,
      decay: 0.01,
      sustain: 0.3,
      release: 0.02,
      sweep: 0.25,
      distort: 0.8,
      cutoff: 119,
      res: 0.2
    }
  }

  @doc "Every synth name, sorted."
  @spec names() :: [atom()]
  def names, do: (Map.keys(@synths) ++ Map.keys(@drums)) |> Enum.sort()

  @doc "Whether `name` is a synth here."
  @spec known?(atom()) :: boolean()
  def known?(name), do: Map.has_key?(@synths, name) or Map.has_key?(@drums, name)

  @doc """
  The voice or voices `name` plays at `hz` with `opts`.

  `name` is one of `names/0`, a `TuningFork.Voice` used as it is with the pitch and the
  options applied, or a string `TuningFork.Kit.known?/1` accepts, played through the kit at
  the note nearest `hz`. A detuned synth gives a list of voices. Raises `ArgumentError` for a
  name that is not here.

  ## Options

    * `:amp` — level, 1 being normal; `:pan` from -1 to 1
    * `:attack`, `:decay`, `:sustain`, `:release` — seconds; `:sustain` is how long the note is
      held. Defaults 0, 0, 0 and 1
    * `:sustain_level` — the level held during `:sustain`, default 1
    * `:cutoff` — a lowpass, as a MIDI note; `:res` — its resonance, 0 to 1; `:cutoff_min` —
      where a swept filter starts
    * `:detune` — semitones between the voices of a detuned synth
    * `:divisor`, `:depth` — FM ratio and depth; `:mod_phase`, `:mod_range` — the `mod_*` synths'
      vibrato
    * `:vib`, `:vibmod`, `:crush`, `:distort`, `:coarse`, `:phaser`, `:phaserdepth`, `:vowel`,
      `:fm`, `:fmh`, `:fmattack`, `:highpass`, `:seed` — `TuningFork.Voice` fields, passed through

  Any other key is ignored.
  """
  @spec voice(atom() | String.t() | Voice.t(), float(), keyword()) :: Voice.t() | [Voice.t()]
  def voice(%Voice{} = base, hz, opts) do
    base
    |> Map.put(:freq, hz)
    |> Map.put(:envelope, envelope(opts, base.envelope))
    |> shaped(opts, %{})
  end

  def voice(name, hz, opts) when is_binary(name) do
    held = Keyword.get(opts, :sustain, 0.0) / 1.0
    midi = round(Names.hz_to_midi(hz))

    case Kit.voice(%{sound: name, note: midi}, held, wait: false) do
      nil -> raise ArgumentError, "no sound named #{inspect(name)}"
      played -> voice(%{played | envelope: %{played.envelope | release: 1.0}}, hz, opts)
    end
  end

  def voice(name, _hz, opts) when is_map_key(@drums, name) do
    seconds = Keyword.get(opts, :decay, 0.3) / 1.0
    Kit.voice(Map.fetch!(@drums, name), seconds) |> shaped(opts, %{})
  end

  def voice(name, hz, opts) when is_map_key(@synths, name) do
    preset = Map.fetch!(@synths, name)
    base = single(preset, hz, opts)

    case stacked(preset, base, hz, opts) do
      [only] -> only
      several -> several
    end
  end

  def voice(name, _hz, _opts), do: raise(ArgumentError, "no synth named #{inspect(name)}")

  defp single(preset, hz, opts) do
    envelope = envelope(opts, preset_envelope(preset))

    Voice.new(
      shape: preset.shape,
      freq: hz,
      envelope: envelope,
      sweep: Map.get(preset, :sweep, 1.0),
      fm: Map.get(preset, :fm),
      fmh: Map.get(preset, :fmh),
      fmattack: Map.get(preset, :fmattack),
      vib: Map.get(preset, :vib),
      vibmod: Map.get(preset, :vibmod),
      crush: Map.get(preset, :crush),
      coarse: Map.get(preset, :coarse),
      distort: Map.get(preset, :distort),
      vowel: Map.get(preset, :vowel),
      phaser: Map.get(preset, :phaser),
      phaserdepth: Map.get(preset, :phaserdepth)
    )
    |> modulated(preset, opts)
    |> shaped(opts, preset)
  end

  defp preset_envelope(preset) do
    Envelope.new(
      attack: Map.get(preset, :attack, 0.0),
      decay: Map.get(preset, :decay, 0.0),
      sustain: 1.0,
      hold: Map.get(preset, :sustain, 0.0),
      release: Map.get(preset, :release, 1.0)
    )
  end

  defp envelope(opts, base) do
    Envelope.new(
      attack: Keyword.get(opts, :attack, base.attack) / 1.0,
      decay: Keyword.get(opts, :decay, base.decay) / 1.0,
      sustain: Keyword.get(opts, :sustain_level, base.sustain) / 1.0,
      hold: Keyword.get(opts, :sustain, base.hold) / 1.0,
      release: Keyword.get(opts, :release, base.release) / 1.0,
      curve: base.curve
    )
  end

  defp modulated(voice, %{mod: true}, opts) do
    phase = Keyword.get(opts, :mod_phase, 0.25) / 1.0
    range = Keyword.get(opts, :mod_range, 5) / 1.0

    %{voice | vib: 1.0 / max(phase, 0.01), vibmod: range / 2.0}
  end

  defp modulated(voice, _preset, _opts), do: voice

  defp stacked(%{voices: count, detune: spread} = preset, base, hz, opts) do
    detune = Keyword.get(opts, :detune, spread) / 1.0
    each = 1.0 / count

    for index <- 0..(count - 1) do
      offset = (index - (count - 1) / 2) * detune
      %{base | freq: hz * :math.pow(2.0, offset / 12.0), gain: base.gain * each * 1.4}
    end
    |> with_sub(preset, base, hz)
  end

  defp stacked(%{detune: spread} = preset, base, hz, opts) do
    detune = Keyword.get(opts, :detune, spread) / 1.0

    [
      %{base | gain: base.gain * 0.6},
      %{base | freq: hz * :math.pow(2.0, detune / 12.0), gain: base.gain * 0.6}
    ]
    |> with_sub(preset, base, hz)
  end

  defp stacked(%{harmonics: ratios} = preset, base, hz, _opts) do
    count = length(ratios)

    ratios
    |> Enum.with_index()
    |> Enum.map(fn {ratio, index} ->
      %{base | freq: hz * ratio, gain: base.gain / count / (index + 1) * 1.5}
    end)
    |> with_sub(preset, base, hz)
  end

  defp stacked(preset, base, hz, _opts), do: with_sub([base], preset, base, hz)

  defp with_sub(voices, %{sub: level}, base, hz) do
    voices ++ [%{base | shape: :sine, freq: hz / 2.0, gain: base.gain * level * 0.7, filter: nil}]
  end

  defp with_sub(voices, _preset, _base, _hz), do: voices

  defp shaped(voice, opts, preset) do
    voice
    |> levelled(opts)
    |> panned(opts)
    |> filtered(opts, preset)
    |> plucked(preset)
    |> passed_through(opts)
  end

  defp levelled(voice, opts) do
    amp = Keyword.get(opts, :amp, 1.0) / 1.0
    %{voice | gain: min(voice.gain * amp, 1.0)}
  end

  defp panned(voice, opts) do
    case Keyword.get(opts, :pan) do
      nil -> voice
      pan -> %{voice | pan: pan / 1.0}
    end
  end

  defp filtered(voice, opts, preset) do
    cutoff = Keyword.get(opts, :cutoff, Map.get(preset, :cutoff))
    res = Keyword.get(opts, :res, Map.get(preset, :res, 0.0))

    if is_nil(cutoff) do
      voice
    else
      %{voice | filter: filter(cutoff, res, voice, opts, preset)}
    end
  end

  defp filter(cutoff, res, voice, opts, preset) do
    low = Keyword.get(opts, :cutoff_min, Map.get(preset, :cutoff_min))
    swept? = Map.get(preset, :sweep_with_envelope, false) and not is_nil(low)

    Filter.new(
      hz: if(swept?, do: Names.midi_to_hz(low), else: Names.midi_to_hz(cutoff)),
      q: resonance(res),
      model: Map.get(preset, :model, :svf),
      envelope: if(swept?, do: voice.envelope),
      amount: if(swept?, do: max((cutoff - low) / 12.0, 0.0), else: 0.0)
    )
  end

  defp plucked(voice, %{pluck: true}) do
    envelope = %{
      voice.envelope
      | attack: 0.001,
        decay: max(Envelope.duration(voice.envelope) * 0.6, 0.05),
        release: max(voice.envelope.release * 0.4, 0.05),
        sustain: 0.0
    }

    filter = %{
      voice.filter
      | envelope: Envelope.new(attack: 0.001, decay: 0.12, sustain: 0.0, release: 0.0),
        amount: 2.5
    }

    %{voice | envelope: envelope, filter: filter}
  end

  defp plucked(voice, %{piano: true}) do
    length = max(Voice.duration(voice), 0.1)

    %{
      voice
      | envelope: %{
          voice.envelope
          | attack: 0.002,
            decay: length * 0.9,
            sustain: 0.0,
            hold: 0.0,
            release: length * 0.1
        }
    }
  end

  defp plucked(voice, %{kalimba: true}) do
    length = max(Voice.duration(voice), 0.1)

    %{
      voice
      | envelope: %{
          voice.envelope
          | attack: 0.002,
            decay: length * 0.9,
            sustain: 0.0,
            hold: 0.0,
            release: length * 0.1
        }
    }
  end

  defp plucked(voice, _preset), do: voice

  @passed [
    :crush,
    :distort,
    :vowel,
    :fm,
    :fmh,
    :fmattack,
    :vib,
    :vibmod,
    :coarse,
    :phaser,
    :phaserdepth,
    :highpass,
    :seed
  ]
  @renamed [depth: :fm, divisor: :fmh]

  defp passed_through(voice, opts) do
    opts =
      Enum.reduce(@renamed, opts, fn {from, to}, acc ->
        if Keyword.has_key?(acc, from),
          do: Keyword.put(acc, to, Keyword.fetch!(acc, from) / 1.0),
          else: acc
      end)

    Enum.reduce(@passed, voice, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  @doc "The resonance a Sonic Pi `:res` from 0 to 1 stands for, as a `TuningFork.Filter` `:q`."
  @spec resonance(number()) :: float()
  def resonance(res) do
    res = res |> min(0.999) |> max(0.0)
    min(1.0 / (1.0 - res), 62.0)
  end
end

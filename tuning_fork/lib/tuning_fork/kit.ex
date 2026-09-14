defmodule TuningFork.Kit do
  @moduledoc """
  Names to voices: `voice/2` turns a drum name, a note name, a MIDI number, hertz or a map of
  controls into a `TuningFork.Voice`.

      iex> %TuningFork.Voice{} = TuningFork.Kit.voice("bd", 0.25)
      iex> TuningFork.Kit.voice("nothing here", 0.25)
      nil
  """

  alias TuningFork.{Curve, Envelope, Filter, Notes, Scale, Voice}
  alias TuningFork.Gm.{Fonts, Names}
  alias TuningFork.Sample.{Bank, Font}

  @drums ~w(bd kick sn snare rim cp clap hh hat oh open lt mt ht tom rd ride cr crash tam cow
            perc sh shaker)

  @banks %{
    "RolandTR808" => {2.2, 0.82, 0.8},
    "RolandTR909" => {1.25, 1.0, 1.35},
    "RolandTR707" => {0.75, 1.06, 1.1},
    "AkaiLinn" => {0.9, 0.95, 0.9}
  }

  @waveforms %{
    "sine" => :sine,
    "sawtooth" => :saw,
    "saw" => :saw,
    "square" => :square,
    "triangle" => :triangle,
    "tri" => :triangle,
    "white" => :noise,
    "pink" => :noise,
    "brown" => :noise,
    "noise" => :noise
  }

  @doc "The drum names `voice/2` knows, sorted."
  @spec drums() :: [String.t()]
  def drums, do: Enum.sort(@drums)

  @doc """
  Whether `voice/3` plays `name` as a sound rather than a pitch: a drum, a waveform, a GM
  instrument or a loaded bank, with or without an index after a colon.

      iex> TuningFork.Kit.known?("gm_epiano1:2")
      true
      iex> TuningFork.Kit.known?("c4")
      false
  """
  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name) do
    base = name |> String.split(":", parts: 2) |> hd()

    base in @drums or is_map_key(@waveforms, base) or Names.program(base) != nil or
      Bank.has?(base)
  end

  @doc """
  The drum names grouped by what they are, short name first.

      iex> TuningFork.Kit.families() |> Keyword.keys()
      [:kick, :snare, :hat, :tom, :cymbal, :percussion]

  Names in the same group make the same sound; `"bd"` and `"kick"` are one entry.
  """
  @spec families() :: keyword([[String.t()]])
  def families do
    [
      kick: [["bd", "kick"]],
      snare: [["sn", "snare"], ["rim"], ["cp", "clap"]],
      hat: [["hh", "hat"], ["oh", "open"]],
      tom: [["lt"], ["mt", "tom"], ["ht"]],
      cymbal: [["rd", "ride"], ["cr", "crash"]],
      percussion: [["tam"], ["cow"], ["perc"], ["sh", "shaker"]]
    ]
  end

  @doc """
  Every note name `voice/2` takes, low to high.

  A name is a letter, `s` for sharp or `b` for flat, and an octave: `c3`, `fs4`, `eb2`.
  """
  @spec notes() :: [String.t()]
  def notes do
    for octave <- 0..8, name <- ~w(c cs d ds e f fs g gs a as b), do: "#{name}#{octave}"
  end

  @doc """
  The voice for `value`, lasting `seconds`.

  Returns `nil` for a value naming nothing, so a pattern carrying words this kit does not have
  plays the ones it does rather than failing.

  ## Options

    * `:wait` — whether to wait for a recording still being fetched from the web, default
      `true`; with `false` such a value is `nil` this time and the fetch carries on behind
  """
  @spec voice(term(), number(), keyword()) :: Voice.t() | nil
  def voice(value, seconds, opts \\ [])

  def voice(%Voice{} = voice, _seconds, _opts), do: voice

  def voice(%{} = controls, seconds, opts), do: from_map(controls, seconds, opts)

  def voice(value, seconds, _opts) when is_integer(value),
    do: pitched(from_midi(value), seconds, [])

  def voice(value, seconds, _opts) when is_float(value), do: pitched(value, seconds, [])

  def voice(value, seconds, opts) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [name] -> named(name, 0, seconds, opts)
      [name, index] -> named(name, index(index), seconds, opts)
    end
  end

  def voice(value, seconds, opts) when is_atom(value) and not is_nil(value) do
    voice(Atom.to_string(value), seconds, opts)
  end

  def voice(_value, _seconds, _opts), do: nil

  @doc """
  Start fetching, in the background, every recording and soundfont the `values` would play.
  Values are what `voice/3` takes; anything else is skipped. Returns at once.
  """
  @spec prefetch([term()]) :: :ok
  def prefetch(values) when is_list(values) do
    values
    |> Enum.map(&sound_of/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.each(&warm/1)
  end

  defp sound_of(%{} = controls) do
    controls = from_bank(controls)

    Map.get(controls, :sound) || Map.get(controls, :s)
  end

  defp sound_of(name) when is_binary(name), do: name
  defp sound_of(_other), do: nil

  defp from_bank(%{bank: bank} = controls) when is_binary(bank) do
    with sound when is_binary(sound) <- Map.get(controls, :sound) || Map.get(controls, :s),
         [base | index] <- String.split(sound, ":", parts: 2),
         true <- Bank.has?(bank <> "_" <> base) do
      controls
      |> Map.drop([:bank, :s])
      |> Map.put(:sound, Enum.join([bank <> "_" <> base | index], ":"))
    else
      _not_recorded -> controls
    end
  end

  defp from_bank(controls), do: controls

  defp warm(name) do
    {base, index} =
      case String.split(name, ":", parts: 2) do
        [base] -> {base, 0}
        [base, index] -> {base, index(index)}
      end

    cond do
      Bank.has?(base) -> Bank.prefetch(base)
      Names.program(base) -> font_prefetch(base, index)
      true -> :ok
    end
  end

  defp font_prefetch(gm, index) do
    case Fonts.file(gm, index) do
      nil -> :ok
      file -> Font.prefetch(file)
    end
  end

  @doc """
  A voice from a map of controls.

  `:sound` or `:note` says what to play and is passed to `voice/2`; every other key changes the
  voice that comes back. A map with neither is `nil`. A `:bank` plays the recording registered
  as `bank_sound` when `TuningFork.Sample.Bank` has one, and is otherwise an adjustment to the
  kit's drum (`banks/0`).
  """
  @spec from_map(map(), number(), keyword()) :: Voice.t() | nil
  def from_map(controls, seconds, opts \\ []) do
    controls = from_bank(controls)
    sound = Map.get(controls, :sound) || Map.get(controls, :s)

    case indexed(sound, controls) do
      {:ok, name} ->
        case voice(name, seconds, opts) do
          nil -> nil
          voice -> shape(voice, controls)
        end

      :pitched ->
        from_pitch(controls, sound, seconds, opts)
    end
  end

  defp indexed(sound, %{degree: degree} = controls)
       when is_binary(sound) and is_integer(degree) and not is_map_key(controls, :scale) and
              not is_map_key(controls, :note) do
    base = sound |> String.split(":", parts: 2) |> hd()

    if Bank.has?(base) or base in @drums, do: {:ok, "#{base}:#{degree}"}, else: :pitched
  end

  defp indexed(_sound, _controls), do: :pitched

  defp from_pitch(controls, what, seconds, opts) do
    case pitch(controls) do
      {:ok, note} ->
        case recorded_at(what, note, opts) do
          nil ->
            controls
            |> instrument(pitched(from_midi(note), seconds, []), note, seconds, opts)
            |> shape(controls)

          voice ->
            shape(voice, controls)
        end

      :none ->
        case voice(what || Map.get(controls, :note), seconds, opts) do
          nil -> nil
          voice -> shape(voice, controls)
        end
    end
  end

  defp instrument(controls, voice, note, seconds, opts) do
    sound = Map.get(controls, :sound) || Map.get(controls, :s)

    with name when is_binary(name) <- sound,
         [base | index] <- String.split(name, ":", parts: 2) do
      cond do
        is_map_key(@waveforms, base) ->
          %{voice | shape: Map.fetch!(@waveforms, base), filter: nil}

        program = Names.program(base) ->
          font_voice(base, index, note, seconds, voice, opts) ||
            TuningFork.Gm.for_program(program, voice)

        true ->
          voice
      end
    else
      _plain -> voice
    end
  end

  @font_gain 0.3
  @sample_gain 1.0
  @synth_gain 0.3
  @sample_base 36

  defp font_voice(gm, index, note, seconds, voice, opts) do
    n = index |> List.first("0") |> index()

    with file when is_binary(file) <- Fonts.file(gm, n),
         {:ok, sample} <- Font.sample(file, note, Keyword.take(opts, [:wait])) do
      played =
        Voice.new(
          sample: sample,
          freq: voice.freq,
          pan: voice.pan,
          envelope:
            Envelope.new(attack: 0.001, decay: 0.001, sustain: 1.0, hold: seconds, release: 0.01)
        )

      %{played | gain: @font_gain}
    else
      _not_now -> nil
    end
  end

  defp pitch(controls) do
    case midi(controls) do
      nil -> :none
      note -> {:ok, note}
    end
  end

  @doc """
  The MIDI note a value stands for, or `nil` when it is not a pitch.

      iex> TuningFork.Kit.midi(%{degree: 4, scale: "g:minor"})
      62
      iex> TuningFork.Kit.midi(%{sound: "bd"})
      nil

  A drum name has no pitch, so it is `nil`. `:octave` moves the root — 3 is where a scale sits
  without one — and `:transpose` adds semitones after everything else.
  """
  @spec midi(term()) :: integer() | nil
  def midi(%{degree: degree} = controls) when is_integer(degree) do
    scale = Map.get(controls, :scale, "c:major")

    case Scale.midi(scale, degree) do
      nil -> nil
      note -> note + moved(controls)
    end
  end

  def midi(%{} = controls) do
    case Map.get(controls, :note) do
      nil -> nil
      note -> with number when is_integer(number) <- midi(note), do: number + moved(controls)
    end
  end

  def midi(value) when is_integer(value), do: value

  def midi(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [name] -> note_midi(name)
      [_drum, _index] -> nil
    end
  end

  def midi(_value), do: nil

  defp note_midi(name) do
    if name in @drums, do: nil, else: Notes.semitone(name)
  rescue
    _error -> nil
  end

  defp moved(controls) do
    octave =
      case Map.get(controls, :octave) do
        nil -> 0
        number -> 12 * (number - 3)
      end

    octave + Map.get(controls, :transpose, 0)
  end

  defp shaped(voice, amount) when is_number(amount), do: %{voice | waveshape: amount / 1.0}
  defp shaped(voice, shape), do: %{voice | shape: shape}

  defp shape(voice, controls) do
    voice
    |> put(:gain, controls[:gain], &%{&1 | gain: clamped(&2)})
    |> put(:velocity, controls[:velocity], &%{&1 | gain: clamped(&1.gain * &2)})
    |> put(:pan, controls[:pan], &%{&1 | pan: &2 / 1.0})
    |> put(:shape, controls[:shape], &shaped(&1, &2))
    |> put(:highpass, controls[:highpass], &%{&1 | highpass: clamped(&2)})
    |> put(:speed, controls[:speed], &%{&1 | freq: &1.freq * abs(&2 / 1.0)})
    |> put(:crush, controls[:crush], &%{&1 | crush: &2 / 1.0})
    |> put(:distort, controls[:distort], &%{&1 | distort: &2 / 1.0})
    |> put(:waveshape, controls[:waveshape], &%{&1 | waveshape: &2 / 1.0})
    |> put(:vowel, controls[:vowel], &%{&1 | vowel: vowel_of(&2)})
    |> put(:fm, controls[:fm], &%{&1 | fm: &2 / 1.0})
    |> put(:fmh, controls[:fmh], &%{&1 | fmh: &2 / 1.0})
    |> put(:fmattack, controls[:fmattack], &%{&1 | fmattack: &2 / 1.0})
    |> put(:vib, controls[:vib], &%{&1 | vib: &2 / 1.0})
    |> put(:vibmod, controls[:vibmod], &%{&1 | vibmod: &2 / 1.0})
    |> put(:coarse, controls[:coarse], &%{&1 | coarse: &2})
    |> put(:phaser, controls[:phaser], &%{&1 | phaser: &2 / 1.0})
    |> put(:phaserdepth, controls[:phaserdepth], &%{&1 | phaserdepth: &2 / 1.0})
    |> banked(controls[:bank])
    |> enveloped(controls)
    |> filtered(controls)
  end

  defp enveloped(voice, controls) do
    voice
    |> put(:attack, controls[:attack], &%{&1 | envelope: %{&1.envelope | attack: &2 / 1.0}})
    |> put(:decay, controls[:decay], &%{&1 | envelope: %{&1.envelope | decay: &2 / 1.0}})
    |> put(:sustain, controls[:sustain], &%{&1 | envelope: %{&1.envelope | sustain: clamped(&2)}})
    |> put(:release, controls[:release], &%{&1 | envelope: %{&1.envelope | release: &2 / 1.0}})
  end

  defp filtered(voice, controls) do
    asked = %{
      hz: controls[:cutoff] || wide_enough_for(controls),
      q: controls[:resonance],
      sweep: controls[:lpenv],
      kind: kind_of(controls[:ftype])
    }

    if Enum.all?(asked, fn {_key, value} -> is_nil(value) end) do
      voice
    else
      %{voice | filter: filter_asked(voice.filter || Filter.new(), asked, controls)}
    end
  end

  defp filter_asked(base, asked, controls) do
    kind = asked.kind || base.kind

    Filter.new(
      kind: kind,
      model: if(kind == :lowpass, do: base.model, else: :svf),
      hz: (asked.hz || base.hz) / 1.0,
      q: max((asked.q || base.q) / 1.0, 0.0),
      drive: base.drive,
      poles: base.poles,
      amount: (asked.sweep || base.amount) / 1.0,
      envelope: sweep_envelope(asked.sweep, controls, base)
    )
  end

  defp wide_enough_for(controls) do
    if is_number(controls[:fm]) and controls[:fm] > 0, do: 12_000.0
  end

  defp kind_of(nil), do: nil
  defp kind_of(kind) when kind in [:lowpass, :highpass, :bandpass], do: kind

  defp kind_of(kind) when is_binary(kind) do
    case kind do
      "lowpass" -> :lowpass
      "highpass" -> :highpass
      "bandpass" -> :bandpass
      _other -> nil
    end
  end

  defp kind_of(_kind), do: nil

  defp sweep_envelope(nil, _controls, base), do: base.envelope

  defp sweep_envelope(_sweep, controls, _base) do
    Envelope.new(
      attack: (controls[:lpattack] || 0.002) / 1.0,
      decay: (controls[:lpdecay] || 0.2) / 1.0,
      sustain: (controls[:lpsustain] || 0.0) / 1.0,
      release: (controls[:lprelease] || 0.0) / 1.0
    )
  end

  defp vowel_of(value) when is_atom(value), do: value

  defp vowel_of(value) when is_binary(value) do
    case value do
      "a" -> :a
      "e" -> :e
      "i" -> :i
      "o" -> :o
      "u" -> :u
      _other -> nil
    end
  end

  defp vowel_of(_value), do: nil

  defp put(voice, _key, nil, _fun), do: voice
  defp put(voice, _key, value, fun), do: fun.(voice, value)

  defp clamped(value), do: value |> max(0.0) |> min(1.0)

  defp from_midi(note), do: 440.0 * :math.pow(2.0, (note - 69) / 12.0)

  defp index(text) do
    case Integer.parse(text) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp named(name, index, seconds, opts) do
    cond do
      Bank.has?(name) -> recorded(name, index, @sample_base, opts)
      name in @drums -> drum(name, index)
      true -> pitched_by_name(name, index, seconds)
    end
  end

  defp recorded_at(name, midi, opts) when is_binary(name) do
    case String.split(name, ":", parts: 2) do
      [base] -> if Bank.has?(base), do: recorded(base, 0, midi, opts)
      [base, index] -> if Bank.has?(base), do: recorded(base, index(index), midi, opts)
    end
  end

  defp recorded_at(_name, _midi, _opts), do: nil

  defp recorded(name, index, midi, opts) do
    {at, root} =
      case Bank.nearest(name, midi, index) do
        {at, note} -> {at, from_midi(note)}
        nil -> {index, nil}
      end

    case Bank.fetch(name, at, Keyword.take(opts, [:wait])) do
      {:ok, sample} ->
        rooted = %{sample | root: root || sample.root || from_midi(@sample_base)}
        Voice.new(sample: rooted, freq: from_midi(midi), gain: @sample_gain)

      _not_now ->
        nil
    end
  end

  defp drum(name, index) do
    voice = built(name)

    if index == 0 do
      voice
    else
      %{voice | freq: voice.freq * :math.pow(2, rem(index, 12) / 12)}
    end
  end

  @doc """
  The sound banks `voice/2` knows, sorted.

      iex> "RolandTR909" in TuningFork.Kit.banks()
      true

  These are adjustments to the drums this kit synthesises, so `bank("RolandTR808")` gives the
  long booming kick that name is known for while the recording registered as
  `RolandTR808_bd` has not arrived, or where there is none. A name not here changes nothing,
  so a pattern written for a bank that is not loaded still plays.
  """
  @spec banks() :: [String.t()]
  def banks, do: @banks |> Map.keys() |> Enum.sort()

  defp banked(voice, nil), do: voice

  defp banked(voice, name) do
    case Map.fetch(@banks, to_string(name)) do
      :error -> voice
      {:ok, {ring, tune, bright}} -> adjusted(voice, ring, tune, bright)
    end
  end

  defp adjusted(voice, ring, tune, bright) do
    envelope = voice.envelope
    low? = voice.freq < 400.0

    %{
      voice
      | freq: voice.freq * if(low?, do: tune, else: bright),
        envelope: %{
          envelope
          | decay: envelope.decay * ring,
            hold: envelope.hold * ring,
            release: envelope.release * ring
        }
    }
  end

  defp built(name) when name in ~w(bd kick), do: kick(58.0, 0.36)
  defp built(name) when name in ~w(lt), do: kick(100.0, 0.32)
  defp built(name) when name in ~w(mt tom), do: kick(145.0, 0.28)
  defp built(name) when name in ~w(ht), do: kick(200.0, 0.24)

  defp built(name) when name in ~w(sn snare), do: snare(0.9)
  defp built(name) when name in ~w(rim), do: rattle(2_400.0, 4.0, 0.05, 0.45)
  defp built(name) when name in ~w(cp clap), do: rattle(1_300.0, 1.6, 0.11, 0.7)

  defp built(name) when name in ~w(hh hat), do: sizzle(8_000.0, 0.05, 0.4)
  defp built(name) when name in ~w(oh open), do: sizzle(7_000.0, 0.32, 0.35)
  defp built(name) when name in ~w(rd ride), do: sizzle(6_000.0, 0.70, 0.28)
  defp built(name) when name in ~w(cr crash), do: sizzle(4_500.0, 1.10, 0.34)

  defp built(name) when name in ~w(tam), do: rattle(3_200.0, 2.0, 0.14, 0.3)
  defp built(name) when name in ~w(cow), do: rattle(820.0, 6.0, 0.18, 0.45)
  defp built(name) when name in ~w(perc), do: rattle(520.0, 5.0, 0.13, 0.5)
  defp built(name) when name in ~w(sh shaker), do: sizzle(9_000.0, 0.06, 0.3)

  defp kick(from, decay) do
    Voice.new(
      shape: :sine,
      freq: from,
      gain: 0.9,
      curves: %{
        freq: Curve.new([{0.0, 6.0}, {0.02, 2.0}, {0.06, 1.2}, {0.18, 1.0}, {1.0, 1.0}]),
        gain: Curve.new([{0.0, 1.0}, {0.5, 0.55}, {1.0, 0.0}])
      },
      envelope: Envelope.new(attack: 0.0008, decay: decay, sustain: 0.0, release: 0.0)
    )
  end

  defp snare(gain) do
    Voice.new(
      shape: :noise,
      gain: gain,
      filter: Filter.new(kind: :bandpass, hz: 1_900.0, q: 1.1, poles: 2),
      highpass: 0.12,
      envelope: Envelope.new(attack: 0.001, decay: 0.16, sustain: 0.0, release: 0.0)
    )
  end

  defp rattle(hz, q, decay, gain) do
    Voice.new(
      shape: :noise,
      gain: gain,
      filter: Filter.new(kind: :bandpass, hz: hz, q: q, poles: 2),
      envelope: Envelope.new(attack: 0.001, decay: decay, sustain: 0.0, release: 0.0)
    )
  end

  defp sizzle(hz, decay, gain) do
    Voice.new(
      shape: :noise,
      gain: gain,
      filter: Filter.new(kind: :highpass, hz: hz, q: 0.8, poles: 2),
      envelope: Envelope.new(attack: 0.0005, decay: decay, sustain: 0.0, release: 0.0)
    )
  end

  defp pitched_by_name(name, index, seconds) do
    frequency = from_midi(Notes.semitone(name))

    pitched(frequency * :math.pow(2, index), seconds, [])
  rescue
    _error -> nil
  end

  defp pitched(frequency, seconds, opts) do
    length = max(seconds, 0.02)

    Voice.new(
      [
        shape: :saw,
        freq: frequency,
        filter: Filter.new(hz: max(frequency * 5, 400.0), q: 1.0),
        gain: @synth_gain,
        envelope:
          Envelope.new(
            attack: 0.001,
            decay: 0.001,
            sustain: 1.0,
            hold: length,
            release: 0.02
          )
      ] ++ opts
    )
  end
end

defmodule TuningFork.Pattern.Control do
  @moduledoc """
  Patterns of control maps, built as a chain of setters that `TuningFork.Kit` turns into voices.

      import TuningFork.Pattern.Control

      n("<0 4 0 9 7>*16") |> scale("g:minor") |> transpose(-12) |> octave(3) |> shape(:saw)
  """

  alias TuningFork.Pattern
  alias TuningFork.Pattern.{Mini, Voicing}

  @echo_repeats 4
  @echo_reach 2.0
  @slack 1.0e-9

  @doc """
  A pattern of sounds. `source` is mini-notation, a pattern, or a bare value; each value
  becomes `%{sound: value}` unless it is already a map.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.Control.s("bd sn"))
      [{0.0, 0.5, %{sound: "bd"}}, {0.5, 1.0, %{sound: "sn"}}]
  """
  @spec s(Pattern.t() | String.t() | term()) :: Pattern.t()
  def s(source), do: source |> as_pattern() |> tag(:sound)

  @doc ~S{Set the sound on an existing pattern's events, as `set/3` does: `n("0 1") |> s("hh")`.}
  @spec s(Pattern.t(), Pattern.t() | String.t() | term()) :: Pattern.t()
  def s(%Pattern{} = pattern, source), do: set(pattern, :sound, as_pattern(source))

  @doc """
  A pattern of scale degrees, 0 being the root of the `scale/2` (`"c:major"` without one).
  `source` is as for `s/1`; each value becomes `%{degree: value}`.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.Control.n("0 4"))
      [{0.0, 0.5, %{degree: 0}}, {0.5, 1.0, %{degree: 4}}]
  """
  @spec n(Pattern.t() | String.t() | term()) :: Pattern.t()
  def n(source), do: source |> as_pattern() |> tag(:degree)

  @doc "Set the degree on an existing pattern's events, as `set/3` does."
  @spec n(Pattern.t(), Pattern.t() | String.t() | term()) :: Pattern.t()
  def n(%Pattern{} = pattern, source), do: set(pattern, :degree, as_pattern(source))

  @doc """
  A pattern of notes, by name or by MIDI number. `source` is as for `s/1`; each value becomes
  `%{note: value}`.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.Control.note("c3 g3"))
      [{0.0, 0.5, %{note: "c3"}}, {0.5, 1.0, %{note: "g3"}}]
  """
  @spec note(Pattern.t() | String.t() | term()) :: Pattern.t()
  def note(source), do: source |> as_pattern() |> tag(:note)

  @doc "Set the note on an existing pattern's events, as `set/3` does."
  @spec note(Pattern.t(), Pattern.t() | String.t() | term()) :: Pattern.t()
  def note(%Pattern{} = pattern, source), do: set(pattern, :note, as_pattern(source))

  @doc "A pattern from mini-notation: `mini(\"bd*2 [~ sn]\")`."
  @spec mini(String.t()) :: Pattern.t()
  def mini(source) when is_binary(source), do: Mini.parse(source)

  @doc """
  A pattern of chord symbols, each as `%{chord: symbol}`, for `voicing/1`.

      chord(\"<Bbm9 Fm9>/4\") |> voicing()
  """
  @spec chord(Pattern.t() | String.t() | term()) :: Pattern.t()
  def chord(source), do: source |> as_pattern() |> tag(:chord)

  @doc "Which voicing dictionary `voicing/1` reads: one of `TuningFork.Pattern.Voicing.dictionaries/0`."
  @spec dict(Pattern.t(), atom() | String.t() | Pattern.t()) :: Pattern.t()
  def dict(pattern, name), do: set(pattern, :dict, name)

  @doc "The note a voicing is placed against, as `TuningFork.Pattern.Voicing.render/2`'s `:anchor`."
  @spec anchor(Pattern.t(), String.t() | integer() | Pattern.t()) :: Pattern.t()
  def anchor(pattern, note), do: set(pattern, :anchor, note)

  @doc """
  How a voicing sits against its anchor: `:below`, `:above`, `:root` or `:duck`, or a string
  such as `\"root:g2\"` naming the anchor too.
  """
  @spec mode(Pattern.t(), atom() | String.t() | Pattern.t()) :: Pattern.t()
  def mode(pattern, mode), do: set(pattern, :mode, mode)

  @doc "How many voicings along the dictionary's list `voicing/1` moves."
  @spec offset(Pattern.t(), integer() | Pattern.t()) :: Pattern.t()
  def offset(pattern, offset), do: set(pattern, :offset, offset)

  @doc """
  Keep the values of `pattern` but the structure of `source`: an event for every true step of
  `source`, carrying the value `pattern` holds at that moment. `x`, `t`, `1` are true; `~`,
  `f`, `0` are not.

      s(\"bd\") |> struct(\"x ~ x ~\")
  """
  @spec struct(Pattern.t(), Pattern.t() | String.t()) :: Pattern.t()
  def struct(%Pattern{} = pattern, source) do
    structure = as_pattern(source)

    Pattern.new(fn span ->
      structure
      |> Pattern.query(span)
      |> Enum.filter(&(truthy?(&1.value) and not is_nil(&1.whole)))
      |> Enum.flat_map(&structured(pattern, &1))
    end)
  end

  defp structured(pattern, %{whole: {from, _to}} = event) do
    case Pattern.value_at(pattern, from) do
      nil -> []
      value -> [%{event | value: value}]
    end
  end

  @doc """
  Keep only the events of `pattern` that fall where `source` is true.

      s(\"bd*8\") |> mask(\"1 0 1 1\")
  """
  @spec mask(Pattern.t(), Pattern.t() | String.t()) :: Pattern.t()
  def mask(%Pattern{} = pattern, source) do
    masking = as_pattern(source)
    Pattern.filter_events(pattern, fn event -> truthy?(sampled(masking, event)) end)
  end

  @doc "Move `pattern` later by `amount` cycles; a pattern of amounts applies each over its own span."
  @spec late(Pattern.t() | String.t(), number() | Pattern.t() | String.t()) :: Pattern.t()
  def late(pattern, %Pattern{} = amounts),
    do: Pattern.patterned(as_pattern(pattern), amounts, &late/2)

  def late(pattern, amounts) when is_binary(amounts), do: late(pattern, as_pattern(amounts))
  def late(pattern, amount), do: Pattern.shift(as_pattern(pattern), amount)

  @doc "Move `pattern` earlier by `amount` cycles; a pattern of amounts applies each over its own span."
  @spec early(Pattern.t() | String.t(), number() | Pattern.t() | String.t()) :: Pattern.t()
  def early(pattern, %Pattern{} = amounts),
    do: Pattern.patterned(as_pattern(pattern), amounts, &early/2)

  def early(pattern, amounts) when is_binary(amounts), do: early(pattern, as_pattern(amounts))
  def early(pattern, amount), do: Pattern.shift(as_pattern(pattern), -amount)

  @doc "`roomsize/2` under Strudel's shorter name."
  @spec size(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def size(pattern, size), do: roomsize(pattern, size)

  @doc """
  Which scale `n/1`'s degrees are in, as `"root:name"`; `TuningFork.Scale` lists the roots and
  names. Like every setter here, `scale` may be a plain value or a pattern; see `set/3`.
  """
  @spec scale(Pattern.t(), String.t() | Pattern.t()) :: Pattern.t()
  def scale(pattern, scale), do: set(pattern, :scale, scale)

  @doc "Move every note by `semitones`, up or down."
  @spec transpose(Pattern.t(), integer() | Pattern.t()) :: Pattern.t()
  def transpose(pattern, semitones), do: set(pattern, :transpose, semitones)

  @doc "Which octave the scale sits in. Without one it is 3."
  @spec octave(Pattern.t(), integer() | Pattern.t()) :: Pattern.t()
  def octave(pattern, octave), do: set(pattern, :octave, octave)

  @doc """
  The waveform: `:sine`, `:saw`, `:square`, `:triangle` or `:noise`. A number is Strudel's
  `shape`, a waveshaper from 0.0 to below 1.0, and goes on `:waveshape` instead.
  """
  @spec shape(Pattern.t(), atom() | number() | String.t() | Pattern.t()) :: Pattern.t()
  def shape(pattern, amount) when is_number(amount), do: set(pattern, :waveshape, amount)
  def shape(pattern, shape), do: set(pattern, :shape, shape)

  @doc "How loud, 0.0 to 1.0."
  @spec gain(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def gain(pattern, gain), do: set(pattern, :gain, gain)

  @doc "Where in the stereo field, -1.0 left to 1.0 right."
  @spec pan(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def pan(pattern, pan), do: set(pattern, :pan, pan)

  @doc "Where the filter turns over, in hertz. Lower is darker."
  @spec cutoff(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def cutoff(pattern, cutoff), do: set(pattern, :cutoff, cutoff)

  @doc "How much the filter peaks at its cutoff: 0.707 is flat, 8 is a howl."
  @spec resonance(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def resonance(pattern, resonance), do: set(pattern, :resonance, resonance)

  @doc "Octaves the filter sweeps above `cutoff/2` over the note, falling away over `lpdecay/2`."
  @spec lpenv(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def lpenv(pattern, octaves), do: set(pattern, :lpenv, octaves)

  @doc "How long the filter sweep takes to open, in seconds. Default 0.002."
  @spec lpattack(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def lpattack(pattern, seconds), do: set(pattern, :lpattack, seconds)

  @doc "How long the filter sweep takes to fall back, in seconds. Default 0.2."
  @spec lpdecay(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def lpdecay(pattern, seconds), do: set(pattern, :lpdecay, seconds)

  @doc "Where the filter sweep settles, 0.0 to 1.0 of the way up. Default 0.0."
  @spec lpsustain(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def lpsustain(pattern, level), do: set(pattern, :lpsustain, level)

  @doc """
  Set `cutoff`, `resonance`, `lpenv`, `lpsustain` and `lpdecay` together from one knob,
  `amount` from 0.0 to 1.0. Any of them set later in the chain wins.

      n("<0 4 0 9 7>*16") |> scale("g:minor") |> transpose(-12) |> shape(:saw) |> acid(0.55)
  """
  @spec acid(Pattern.t(), number()) :: Pattern.t()
  def acid(%Pattern{} = pattern, amount) do
    knob = amount |> max(0.0) |> min(1.0)

    pattern
    |> cutoff(220)
    |> resonance(4.0 + knob * 26.0)
    |> lpenv(0.5 + knob * 4.0)
    |> lpsustain(0.1)
    |> lpdecay(0.22 - knob * 0.14)
  end

  @doc "Highpass filter amount, 0.0 to 1.0. Higher is thinner."
  @spec highpass(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def highpass(pattern, highpass), do: set(pattern, :highpass, highpass)

  @doc """
  Mark this row to be drawn as a pianoroll. A row not marked is not drawn.

      n("<0 4 0 9 7>*16") |> scale("g:minor") |> acid(0.55) |> pianoroll()
  """
  @spec pianoroll(Pattern.t()) :: Pattern.t()
  def pianoroll(%Pattern{} = pattern), do: set(pattern, :draw, :pianoroll)

  @doc """
  Mark this row to be drawn as an oscilloscope of the whole mix.

      s("bd!4") |> scope()
  """
  @spec scope(Pattern.t()) :: Pattern.t()
  def scope(%Pattern{} = pattern), do: set(pattern, :draw, :scope)

  @doc """
  What a pattern has asked to be drawn as, or `nil` for nothing.

      iex> TuningFork.Pattern.Control.drawing(TuningFork.Pattern.Control.s("bd"))
      nil
      iex> TuningFork.Pattern.Control.drawing(TuningFork.Pattern.Control.scope(TuningFork.Pattern.Control.s("bd")))
      :scope
  """
  @spec drawing(Pattern.t()) :: :pianoroll | :scope | nil
  def drawing(%Pattern{} = pattern) do
    pattern
    |> Pattern.query({0.0, 1.0})
    |> Enum.find_value(fn
      %{value: %{draw: kind}} -> kind
      _other -> nil
    end)
  end

  @doc "How long the note takes to fall silent after it ends, in seconds."
  @spec release(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def release(pattern, release), do: set(pattern, :release, release)

  @doc "How long the note takes to reach full level, in seconds."
  @spec attack(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def attack(pattern, attack), do: set(pattern, :attack, attack)

  @doc "How long it takes to fall from full level to `sustain/2`, in seconds."
  @spec decay(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def decay(pattern, decay), do: set(pattern, :decay, decay)

  @doc "The level the note holds at after its decay, 0.0 to 1.0."
  @spec sustain(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def sustain(pattern, sustain), do: set(pattern, :sustain, sustain)

  @doc """
  Attack, decay, sustain and release in one go. Any of them may be `nil` to leave that part of
  the envelope as it was.

      n("0 4") |> adsr(0.01, 0.1, 0.4, 0.2)
  """
  @spec adsr(
          Pattern.t(),
          number() | nil,
          number() | nil,
          number() | nil,
          number() | nil
        ) :: Pattern.t()
  def adsr(pattern, attack, decay, sustain, release) do
    [attack: attack, decay: decay, sustain: sustain, release: release]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.reduce(pattern, fn {key, value}, acc -> set(acc, key, value) end)
  end

  @doc "The same as `cutoff/2`."
  @spec lpf(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def lpf(pattern, hz), do: cutoff(pattern, hz)

  @doc "The same as `resonance/2`."
  @spec lpq(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def lpq(pattern, q), do: resonance(pattern, q)

  @doc "How long the filter sweep takes to release. See `lpenv/2`."
  @spec lprelease(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def lprelease(pattern, seconds), do: set(pattern, :lprelease, seconds)

  @doc "The same as `highpass/2`."
  @spec hpf(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def hpf(pattern, amount), do: highpass(pattern, amount)

  @doc """
  Stack the pattern panned hard left with `fun` of it panned hard right.

      s("bd*4") |> jux(&rev/1)
  """
  @spec jux(Pattern.t(), (Pattern.t() -> Pattern.t())) :: Pattern.t()
  def jux(%Pattern{} = pattern, fun), do: jux_by(pattern, 1.0, fun)

  @doc """
  `jux/2` with the pattern panned to `-amount` and `fun` of it to `amount`: 1.0 is hard left
  and right, 0.0 leaves both in the middle.
  """
  @spec jux_by(Pattern.t(), number(), (Pattern.t() -> Pattern.t())) :: Pattern.t()
  def jux_by(%Pattern{} = pattern, amount, fun) do
    Pattern.stack([pan(pattern, -amount), pattern |> fun.() |> pan(amount)])
  end

  @doc """
  Which bank the sounds come from.

  A name in `TuningFork.Kit.banks/0` adjusts the kit's synthesised drums. Any other name is
  put in front of each sound with an underscore, as Strudel does — `s("bd") |> bank("crate")`
  plays `crate_bd` — for recordings registered under such names.
  """
  @spec bank(Pattern.t(), String.t() | Pattern.t()) :: Pattern.t()
  def bank(pattern, %Pattern{} = names), do: set(pattern, :bank, names)

  def bank(pattern, name) when is_binary(name) do
    if name in TuningFork.Kit.banks() do
      set(pattern, :bank, name)
    else
      Pattern.with_value(pattern, fn
        %{sound: sound} = controls when is_binary(sound) ->
          %{controls | sound: name <> "_" <> sound}

        other ->
          other
      end)
    end
  end

  @doc """
  How fast a sample or oscillator runs, 1.0 being as written: 2.0 is an octave up and half as
  long. A negative value is taken as its absolute value.
  """
  @spec speed(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def speed(pattern, speed), do: set(pattern, :speed, speed)

  @doc "How hard the note is struck, 0.0 to 1.0. Multiplies `gain/2`."
  @spec velocity(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def velocity(pattern, velocity), do: set(pattern, :velocity, velocity)

  @doc "Round every sample to `bits` bits: 16 is untouched, 1 is a square."
  @spec crush(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def crush(pattern, bits), do: set(pattern, :crush, bits)

  @doc """
  Filter the sound into a vowel: `"a"`, `"e"`, `"i"`, `"o"` or `"u"`, as a string or atom.
  """
  @spec vowel(Pattern.t(), String.t() | atom() | Pattern.t()) :: Pattern.t()
  def vowel(pattern, vowel), do: set(pattern, :vowel, vowel)

  @doc "How hard to drive into a soft clipper, 0.0 for clean."
  @spec distort(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def distort(pattern, amount), do: set(pattern, :distort, amount)

  @doc """
  How much of the note comes back as an echo, 0.0 to 1.0. `delaytime/2` is how far behind, in
  cycles, and `delayfeedback/2` how much of each repeat survives into the next. The echoes are
  the note played again, quieter; `echoes/1` makes them.

      s("bd rim") |> delay(0.5) |> delaytime(0.125) |> delayfeedback(0.6)
  """
  @spec delay(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def delay(pattern, amount), do: set(pattern, :delay, amount)

  @doc "How far behind the echoes fall, in cycles. Default an eighth. See `delay/2`."
  @spec delaytime(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def delaytime(pattern, cycles), do: set(pattern, :delaytime, cycles)

  @doc "How much of each echo survives into the next, 0.0 to 1.0. See `delay/2`."
  @spec delayfeedback(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def delayfeedback(pattern, amount), do: set(pattern, :delayfeedback, amount)

  @doc """
  How much reverb the bus is heard through, 0.0 to 1.0. The reverb is shared by every event on
  the bus, and the loudest `room` asked for is the one applied. `roomsize/2` says how big it is.
  """
  @spec room(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def room(pattern, amount), do: set(pattern, :room, amount)

  @doc "How long the room rings, in seconds to silence; 2 unless set. See `room/2`."
  @spec roomsize(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def roomsize(pattern, size), do: set(pattern, :roomsize, size)

  @doc """
  Frequency modulation depth, 0.0 upwards. `fmh/2` sets the modulator's ratio to the note.

      note("c3") |> fm(3) |> fmh(2)
  """
  @spec fm(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def fm(pattern, index), do: set(pattern, :fm, index)

  @doc "How high the modulator sits against the note, 1.0 being in unison. See `fm/2`."
  @spec fmh(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def fmh(pattern, ratio), do: set(pattern, :fmh, ratio)

  @doc """
  How much of the note the FM modulation takes to arrive, 0.0 to 1.0 of its length. Left out,
  the modulation is there from the first sample.
  """
  @spec fmattack(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def fmattack(pattern, portion), do: set(pattern, :fmattack, portion)

  @doc "Vibrato rate, in hertz. `vibmod/2` says how far."
  @spec vib(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def vib(pattern, hz), do: set(pattern, :vib, hz)

  @doc "Vibrato depth, in semitones. Default half a semitone. See `vib/2`."
  @spec vibmod(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def vibmod(pattern, semitones), do: set(pattern, :vibmod, semitones)

  @doc "Hold every sample for `every` samples. 1 changes nothing."
  @spec coarse(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def coarse(pattern, every), do: set(pattern, :coarse, every)

  @doc """
  Which kind of filter `cutoff/2` makes: `:lowpass` (the default), `:highpass` or `:bandpass`,
  as an atom or string.
  """
  @spec ftype(Pattern.t(), atom() | String.t() | Pattern.t()) :: Pattern.t()
  def ftype(pattern, kind), do: set(pattern, :ftype, kind)

  @doc "A bandpass at this frequency, in hertz. `cutoff/2` and `ftype/2` in one."
  @spec bpf(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def bpf(pattern, hz), do: pattern |> ftype(:bandpass) |> cutoff(hz)

  @doc "How narrow the bandpass is. See `bpf/2`."
  @spec bpq(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def bpq(pattern, q), do: resonance(pattern, q)

  @doc """
  How much the highpass peaks at its corner. Applies to `ftype(:highpass)` with `cutoff/2`,
  not to `highpass/2`.
  """
  @spec hpq(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def hpq(pattern, q), do: resonance(pattern, q)

  @doc """
  Which bus this goes to, counting from zero. `room/2`, `postgain/2`, `xfade/2` and
  `compressor/2` apply per bus.
  """
  @spec orbit(Pattern.t(), non_neg_integer() | Pattern.t()) :: Pattern.t()
  def orbit(pattern, bus), do: set(pattern, :orbit, bus)

  @doc "How loud the bus is after everything else, 0.0 upwards."
  @spec postgain(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def postgain(pattern, gain), do: set(pattern, :postgain, gain)

  @doc "Fade between this bus and the rest: 0.0 none of it, 0.5 equal, 1.0 all of it."
  @spec xfade(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def xfade(pattern, amount), do: set(pattern, :xfade, amount)

  @doc "How hard the bus is compressed, 0.0 for not at all and 1.0 for flat."
  @spec compressor(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def compressor(pattern, amount), do: set(pattern, :compressor, amount)

  @doc "Phaser rate: how many times a second the notches sweep. `phaserdepth/2` says how far."
  @spec phaser(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def phaser(pattern, hz), do: set(pattern, :phaser, hz)

  @doc "How far the phaser's notches travel, 0.0 to 1.0. Default 0.5. See `phaser/2`."
  @spec phaserdepth(Pattern.t(), number() | Pattern.t()) :: Pattern.t()
  def phaserdepth(pattern, depth), do: set(pattern, :phaserdepth, depth)

  @doc """
  Turn a pattern of chord symbols into their notes, one event per note with the symbol's
  timing and its other controls, as `TuningFork.Pattern.Voicing.render/2` voices them under
  the event's `:dict`, `:anchor`, `:mode`, `:offset` and `:degree`. A string is `chord/1`
  first. A symbol the dictionary does not know is silent.

      chord("<C^7 Dm7 G7>") |> voicing() |> shape(:saw)
  """
  @spec voicing(Pattern.t() | String.t()) :: Pattern.t()
  def voicing(source) when is_binary(source), do: source |> chord() |> voicing()

  def voicing(%Pattern{} = pattern) do
    Pattern.new(
      fn span -> pattern |> Pattern.query(span) |> Enum.flat_map(&voiced/1) end,
      pattern.steps
    )
  end

  @voicing_keys [:chord, :dict, :anchor, :mode, :offset, :degree]

  defp voiced(%{value: %{chord: symbol} = controls} = event) do
    rest = Map.drop(controls, @voicing_keys)

    case Voicing.render(symbol, voicing_options(controls)) do
      :error -> []
      notes -> Enum.map(notes, &%{event | value: Map.put(rest, :note, &1)})
    end
  end

  defp voiced(%{value: name} = event) when is_binary(name),
    do: voiced(%{event | value: %{chord: name}})

  defp voiced(_event), do: []

  defp voicing_options(controls) do
    {mode, anchor} = mode_and_anchor(Map.get(controls, :mode), Map.get(controls, :anchor))

    [
      dictionary: dictionary(Map.get(controls, :dict, :ireal)),
      offset: Map.get(controls, :offset, 0)
    ]
    |> put_option(:mode, mode)
    |> put_option(:anchor, anchor)
    |> put_option(:n, Map.get(controls, :degree))
  end

  defp mode_and_anchor(nil, anchor), do: {nil, anchor}
  defp mode_and_anchor(mode, anchor) when is_atom(mode), do: {mode, anchor}

  defp mode_and_anchor(mode, anchor) when is_binary(mode) do
    case String.split(mode, ":", parts: 2) do
      [name] -> {String.to_atom(name), anchor}
      [name, note] -> {String.to_atom(name), note}
    end
  end

  defp dictionary(name) when is_atom(name), do: name
  defp dictionary(name) when is_binary(name), do: String.to_atom(name)

  defp put_option(opts, _key, nil), do: opts
  defp put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp truthy?(value), do: value not in [false, 0, 0.0, "0", "f", "false", nil]

  @doc """
  Turn every event carrying a `:delay` above zero into itself plus four echoes: the same event
  `:delaytime` cycles later each time (default 0.125, capped at 0.5), with `:gain` scaled by
  `:delay` and then by `:delayfeedback` per repeat (default 0.5, capped at 0.95), and `:delay`
  removed. Any other event is passed straight through.
  """
  @spec echoes(Pattern.t()) :: Pattern.t()
  def echoes(%Pattern{} = pattern) do
    Pattern.new(fn {from, to} ->
      pattern
      |> Pattern.query({from - @echo_reach, to})
      |> Enum.flat_map(&repeats/1)
      |> Enum.filter(fn %{part: {at, until}} -> until > from + @slack and at < to - @slack end)
      |> Enum.map(&trim(&1, from, to))
    end)
  end

  defp repeats(event), do: [event | echoes_of(event)]

  @doc """
  The four echoes an event carrying a `:delay` above zero makes, as `echoes/1` places them,
  and `[]` for any other event.
  """
  @spec echoes_of(Pattern.event()) :: [Pattern.event()]
  def echoes_of(%{value: %{delay: amount}} = event) when is_number(amount) and amount > 0 do
    value = event.value
    time = min(abs(Map.get(value, :delaytime, 0.125)), @echo_reach / @echo_repeats)
    feedback = value |> Map.get(:delayfeedback, 0.5) |> abs() |> min(0.95)
    gain = Map.get(value, :gain, 1.0)

    for step <- 1..@echo_repeats, do: echo(event, step, time, amount, feedback, gain)
  end

  def echoes_of(_event), do: []

  defp echo(event, step, time, amount, feedback, gain) do
    level = gain * amount * :math.pow(feedback, step - 1)
    offset = step * time

    %{
      event
      | whole: moved(event.whole, offset),
        part: moved(event.part, offset),
        value: event.value |> Map.put(:gain, level) |> Map.delete(:delay)
    }
  end

  defp moved(nil, _offset), do: nil
  defp moved({from, to}, offset), do: {from + offset, to + offset}

  defp trim(%{part: {at, until}} = event, from, to) do
    %{event | part: {max(at, from), min(until, to)}}
  end

  @doc """
  Merge the controls of `other` onto every event of `pattern`, keeping `pattern`'s wholes: an
  event is cut into parts where `other` changes inside it, each part carrying `other`'s map
  merged over the event's. Where `other` has nothing, the event is left alone.

      n("0 4") |> set(chord("Bbm9")) |> voicing()
  """
  @spec set(Pattern.t(), Pattern.t() | String.t()) :: Pattern.t()
  def set(%Pattern{} = pattern, other) do
    merged = Pattern.app_left(pattern, as_pattern(other), &merge_controls/2)

    Pattern.new(fn span ->
      case Pattern.query(merged, span) do
        [] -> Pattern.query(pattern, span)
        events -> events
      end
    end)
  end

  defp merge_controls(value, %{} = controls), do: Map.merge(tag_value(value), controls)
  defp merge_controls(value, _other), do: tag_value(value)

  defp tag_value(%{} = controls), do: controls
  defp tag_value(other), do: %{sound: other}

  @doc """
  Set control `key` on every event of a pattern.

  `value` is a plain term, a pattern, or a mini-notation string. A pattern keeps the event's
  whole and cuts it into parts where the pattern changes inside it, as `Pattern.app_left/3`;
  where it has nothing the event is left out. An event whose value is not yet a map becomes
  `%{key => value, sound: old_value}`.
  """
  @spec set(Pattern.t(), atom(), term()) :: Pattern.t()
  def set(%Pattern{} = pattern, key, %Pattern{} = values) do
    Pattern.app_left(pattern, values, &put(&1, key, &2))
  end

  def set(%Pattern{} = pattern, key, source) when is_binary(source),
    do: set(pattern, key, Mini.parse(source))

  def set(%Pattern{} = pattern, key, value) do
    Pattern.with_value(pattern, &put(&1, key, value))
  end

  defp sampled(values, %{whole: {from, _to}}), do: at(values, from)
  defp sampled(values, %{part: {from, _to}}), do: at(values, from)

  defp at(values, position), do: Pattern.value_at(values, position)

  defp put(controls, _key, nil), do: controls
  defp put(controls, key, value) when is_map(controls), do: Map.put(controls, key, value)
  defp put(other, key, value), do: %{key => value, sound: other}

  defp tag(pattern, key) do
    Pattern.with_value(pattern, fn
      %{} = controls -> controls
      value -> %{key => value}
    end)
  end

  defp as_pattern(%Pattern{} = pattern), do: pattern
  defp as_pattern(source) when is_binary(source), do: Mini.parse(source)
  defp as_pattern(value), do: Pattern.pure(value)
end

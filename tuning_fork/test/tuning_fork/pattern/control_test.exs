defmodule TuningFork.Pattern.ControlTest do
  @moduledoc """
  The chain that builds patterns of controls, checked by reading a cycle of what it makes.

  Where a control ends up sounding rather than merely being set, the assertion goes through
  `TuningFork.Kit` — that is what actually reads these maps.
  """

  use ExUnit.Case, async: true

  import TuningFork.Pattern.Control

  alias TuningFork.{Kit, Pattern}

  doctest TuningFork.Pattern.Control

  defp values(pattern), do: pattern |> Pattern.first_cycle() |> Enum.map(&elem(&1, 2))

  describe "starting a pattern" do
    test "s tags sounds" do
      assert values(s("bd sn")) == [%{sound: "bd"}, %{sound: "sn"}]
    end

    test "n tags degrees" do
      assert values(n("0 4")) == [%{degree: 0}, %{degree: 4}]
    end

    test "note tags notes" do
      assert values(note("c3 g3")) == [%{note: "c3"}, %{note: "g3"}]
    end

    test "they take a pattern as readily as a string" do
      assert values(s(Pattern.fastcat(["bd", "sn"]))) == values(s("bd sn"))
    end

    test "they take a bare value" do
      assert values(s("bd")) == values(s(Pattern.pure("bd")))
    end
  end

  describe "shaping it" do
    test "each setter adds its key and leaves the rest alone" do
      [controls] = values(s("bd") |> gain(0.6) |> pan(-0.3) |> cutoff(0.4))

      assert controls == %{sound: "bd", gain: 0.6, pan: -0.3, cutoff: 0.4}
    end

    test "order does not matter" do
      one = values(s("bd") |> gain(0.6) |> pan(0.2))
      other = values(s("bd") |> pan(0.2) |> gain(0.6))

      assert one == other
    end

    test "setting the same thing twice keeps the last" do
      assert [%{gain: 0.9}] = values(s("bd") |> gain(0.2) |> gain(0.9))
    end

    test "set reaches controls the named functions do not cover" do
      assert [%{sound: "bd", wobble: 3}] = values(s("bd") |> set(:wobble, 3))
    end
  end

  describe "a pattern as the value" do
    test "it varies across the cycle rather than being pinned" do
      levels = s("bd*4") |> gain(Pattern.saw()) |> values() |> Enum.map(& &1.gain)

      assert levels == [0.0, 0.25, 0.5, 0.75]
    end

    test "a signal sampled at each event start gives each one its own value" do
      pans = s("bd*4") |> pan(Pattern.range(Pattern.saw(), -1, 1)) |> values()

      assert Enum.map(pans, & &1.pan) == [-1.0, -0.5, 0.0, 0.5]
    end

    test "where the value pattern says nothing the event is left out" do
      quiet = Pattern.filter_events(Pattern.pure(0.5), fn _event -> false end)

      assert values(s("bd") |> gain(quiet)) == []

      assert values(s("bd*4") |> gain("1 ~")) == [
               %{sound: "bd", gain: 1},
               %{sound: "bd", gain: 1}
             ]
    end
  end

  describe "degrees becoming notes" do
    test "a scale turns degrees into pitches" do
      notes = n("0 4 0 9 7") |> scale("g:minor") |> values() |> Enum.map(&Kit.midi/1)

      assert notes == [55, 62, 55, 70, 67]
    end

    test "transpose moves them all by semitones" do
      notes = n("0 4") |> scale("g:minor") |> transpose(-12) |> values() |> Enum.map(&Kit.midi/1)

      assert notes == [43, 50]
    end

    test "octave moves the scale's root" do
      up = n("0") |> scale("g:minor") |> octave(4) |> values() |> Enum.map(&Kit.midi/1)
      plain = n("0") |> scale("g:minor") |> values() |> Enum.map(&Kit.midi/1)

      assert up == Enum.map(plain, &(&1 + 12))
    end

    test "octave and transpose stack" do
      [note] = n("0") |> scale("g:minor") |> octave(4) |> transpose(-2) |> values()

      assert Kit.midi(note) == 55 + 12 - 2
    end

    test "without a scale the degrees are c major" do
      assert [note] = values(n("2"))
      assert Kit.midi(note) == 52
    end

    test "the whole chain reaches a voice that sounds" do
      [controls] = n("0") |> scale("g:minor") |> shape(:saw) |> cutoff(300) |> values()
      voice = Kit.voice(controls, 0.25)

      assert voice.shape == :saw
      assert voice.filter.hz == 300.0
      assert_in_delta voice.freq, 196.0, 1.0
    end

    test "acid sets the whole filter, so a lead needs nothing else said about it" do
      [controls] = n("0") |> scale("g:minor") |> acid(0.55) |> values()
      voice = Kit.voice(controls, 0.25)

      assert voice.filter.hz == 220.0
      assert voice.filter.q > 6.0
      assert voice.filter.amount > 2.0
      assert voice.filter.envelope.decay < 0.2
    end

    test "turning the knob up squelches harder" do
      quiet = n("0") |> acid(0.1) |> values() |> hd() |> Kit.voice(0.25)
      loud = n("0") |> acid(0.9) |> values() |> hd() |> Kit.voice(0.25)

      assert loud.filter.q > quiet.filter.q
      assert loud.filter.amount > quiet.filter.amount
      assert loud.filter.envelope.decay < quiet.filter.envelope.decay
    end

    test "a knob outside nought to one is brought back in" do
      assert n("0") |> acid(-5) |> values() == n("0") |> acid(0.0) |> values()
      assert n("0") |> acid(9) |> values() == n("0") |> acid(1.0) |> values()
    end

    test "what comes after acid overrides it" do
      [controls] = n("0") |> acid(0.5) |> lpdecay(0.3) |> cutoff(600) |> values()
      voice = Kit.voice(controls, 0.25)

      assert voice.filter.envelope.decay == 0.3
      assert voice.filter.hz == 600.0
      assert voice.filter.q > 6.0
    end

    test "the filter chain reaches the voice's filter, sweep and all" do
      [controls] =
        n("0")
        |> scale("g:minor")
        |> cutoff(300)
        |> resonance(9)
        |> lpenv(3.5)
        |> lpdecay(0.12)
        |> values()

      voice = Kit.voice(controls, 0.25)

      assert voice.filter.hz == 300.0
      assert voice.filter.q == 9.0
      assert voice.filter.amount == 3.5
      assert voice.filter.envelope.decay == 0.12
    end
  end

  describe "notes rather than degrees" do
    test "transpose moves a named note too" do
      [controls] = note("c3") |> transpose(12) |> values()

      assert Kit.midi(controls) == Kit.midi(%{note: "c3"}) + 12
    end
  end

  describe "asking to be drawn" do
    test "a row that does not ask is not drawn" do
      assert drawing(s("bd*4")) == nil
    end

    test "a row asks for a pianoroll or a scope" do
      assert drawing(pianoroll(n("0 4"))) == :pianoroll
      assert drawing(scope(s("bd*4"))) == :scope
    end

    test "asking sits at the end of a chain like anything else" do
      chained = n("<0 4>*8") |> scale("g:minor") |> acid(0.5) |> pianoroll()

      assert drawing(chained) == :pianoroll
    end

    test "the last one asked for wins" do
      assert drawing(n("0") |> pianoroll() |> scope()) == :scope
    end

    test "asking does not change what plays" do
      without = s("bd*4") |> values() |> Enum.map(&Map.delete(&1, :draw))
      with_roll = s("bd*4") |> pianoroll() |> values() |> Enum.map(&Map.delete(&1, :draw))

      assert without == with_roll
    end

    test "a row that asks still makes the same sound" do
      plain = s("bd") |> values() |> hd() |> Kit.voice(0.25)
      asked = s("bd") |> scope() |> values() |> hd() |> Kit.voice(0.25)

      assert plain == asked
    end
  end

  describe "sounds keep working" do
    test "a drum is not treated as a pitch" do
      [controls] = values(s("bd"))

      assert Kit.midi(controls) == nil
      assert %TuningFork.Voice{} = Kit.voice(controls, 0.25)
    end

    test "a drum takes gain and pan like anything else" do
      [controls] = values(s("bd") |> gain(0.5) |> pan(0.4))
      voice = Kit.voice(controls, 0.25)

      assert voice.gain == 0.5
      assert voice.pan == 0.4
    end
  end
end

defmodule TuningFork.Pattern.ControlStrudelTest do
  use ExUnit.Case, async: true

  import Kernel, except: [struct: 2]
  import TuningFork.Pattern.Control

  import TuningFork.Pattern,
    only: [
      first_cycle: 1,
      first_cycle: 2,
      pure: 1,
      fastcat: 1,
      fast: 2,
      slow: 2,
      ply: 2,
      segment: 2
    ]

  alias TuningFork.Pattern

  defp values(pattern), do: pattern |> first_cycle() |> Enum.map(&elem(&1, 2))
  defp onsets(pattern, cycle \\ 0), do: pattern |> first_cycle(cycle) |> Enum.map(&elem(&1, 0))

  describe "chained starters" do
    test "s, n and note set their control on an existing pattern's structure" do
      assert values(n("0 1") |> s("hh")) == [%{degree: 0, sound: "hh"}, %{degree: 1, sound: "hh"}]
      assert values(s("bd") |> n("<2 3>")) == [%{sound: "bd", degree: 2}]

      assert values(s("bd sn") |> note("c3")) == [
               %{sound: "bd", note: "c3"},
               %{sound: "sn", note: "c3"}
             ]
    end
  end

  describe "struct" do
    test "takes the structure of the second pattern and the values of the first" do
      pattern = s("bd") |> struct("x ~ x ~")
      assert onsets(pattern) == [0.0, 0.5]
      assert values(pattern) == [%{sound: "bd"}, %{sound: "bd"}]
    end

    test "ones and zeros, and t and f, are the same as x and ~" do
      assert onsets(s("bd") |> struct("1 0 1 0")) == [0.0, 0.5]
      assert onsets(s("bd") |> struct("t f t f")) == [0.0, 0.5]
    end

    test "samples the source at each structural event" do
      pattern = s("bd sn") |> struct("x*4")
      assert values(pattern) == [%{sound: "bd"}, %{sound: "bd"}, %{sound: "sn"}, %{sound: "sn"}]
    end

    test "keeps every note sounding at a structural event" do
      pattern = chord("Dm") |> voicing() |> struct("x ~ ~ x")
      assert onsets(pattern) == [0.0, 0.0, 0.0, 0.0, 0.0, 0.75, 0.75, 0.75, 0.75, 0.75]

      assert pattern |> values() |> Enum.map(& &1.note) |> Enum.sort() == [
               50,
               50,
               57,
               57,
               62,
               62,
               65,
               65,
               69,
               69
             ]
    end
  end

  describe "mask" do
    test "keeps the events where the mask is true" do
      pattern = s("bd sn hh cp") |> mask("1 0")
      assert values(pattern) == [%{sound: "bd"}, %{sound: "sn"}]
    end

    test "the mask may be slower than a cycle" do
      pattern = s("bd*2") |> mask("<0 1>/2")
      assert onsets(pattern, 0) == []
      assert onsets(pattern, 1) == []
      assert onsets(pattern, 2) == [0.0, 0.5]
    end
  end

  describe "a control set from a pattern" do
    test "cuts the events it is set on, keeping their wholes" do
      pattern = s("bd") |> n("0 1 2 3")

      assert values(pattern) == [%{sound: "bd", degree: 0}]
      assert length(Pattern.query(pattern, {0.0, 1.0})) == 4
    end

    test "carries the rhythm through a voicing into segment" do
      pattern = chord("Bbm9") |> n("0 ~ 2 ~") |> voicing() |> segment(4)

      assert onsets(pattern) == [0.0, 0.5]
      assert values(pattern) |> Enum.map(& &1.note) == [58, 65]
    end

    test "a string value is mini-notation" do
      pattern = s("bd*4") |> room("<0 .2>")

      assert values(pattern) |> Enum.map(& &1.room) == [0, 0, 0, 0]
      assert values(pattern |> late(1)) |> Enum.map(& &1.room) |> Enum.uniq() == [0.2]
    end
  end

  describe "early and late" do
    test "shift by cycles, in either direction" do
      assert onsets(s("bd ~ ~ ~") |> late(0.25)) == [0.25]
      assert onsets(s("~ bd ~ ~") |> early(0.25)) == [0.0]
    end

    test "take a pattern of amounts, each applying to its own span" do
      pattern = s("bd*4") |> late("[0 0.125]*2")
      assert onsets(pattern) == [0.0, 0.375, 0.5, 0.875]
    end

    test "a string is a mask or a shift pattern, as Strudel reads it" do
      assert onsets(s("bd*4") |> mask("<[0 1] 1>" |> early(0.5))) == [0.0, 0.25, 0.5, 0.75]
    end
  end

  test "size is roomsize" do
    assert values(s("bd") |> size(4)) == [%{sound: "bd", roomsize: 4}]
  end

  describe "chords and voicings" do
    test "chord tags chord symbols and voicing renders them, each note an event" do
      pattern = chord("Bbm9") |> voicing()
      notes = pattern |> values() |> Enum.map(& &1.note) |> Enum.sort()
      assert notes == [58, 61, 65, 68, 72]
    end

    test "voicing still takes chord names straight" do
      assert voicing("Bbm9") |> values() |> length() == 5
    end

    test "dict, anchor, mode and offset shape the voicing" do
      low =
        chord("Bbm9")
        |> mode("root:g2")
        |> voicing()
        |> values()
        |> Enum.map(& &1.note)
        |> Enum.sort()

      assert low == [34, 37, 41, 44, 48]

      shifted =
        chord("Bbm9") |> offset(-1) |> voicing() |> values() |> Enum.map(& &1.note) |> Enum.sort()

      assert shifted == [56, 61, 65, 70, 72]

      legacy =
        chord("C")
        |> dict(:legacy)
        |> anchor("a4")
        |> voicing()
        |> values()
        |> Enum.map(& &1.note)
        |> Enum.sort()

      assert legacy == [60, 64, 67]
    end

    test "n on a chord picks one voicing tone" do
      melody = n("0 4") |> set(chord("Bbm9")) |> voicing()
      assert values(melody) |> Enum.map(& &1.note) == [58, 72]
    end

    test "other controls ride along, and the voicing words are consumed" do
      [event | _] = chord("C") |> anchor("a4") |> voicing() |> s("piano") |> values()
      assert event.sound == "piano"
      assert Map.has_key?(event, :note)
      refute Map.has_key?(event, :chord)
      refute Map.has_key?(event, :anchor)
    end

    test "a chord it does not know is silent" do
      assert values(chord("Hx9") |> voicing()) == []
    end
  end

  describe "patterned time words" do
    test "fast and slow take patterns" do
      assert onsets(s("bd") |> fast("<1 2>"), 0) == [0.0]
      assert onsets(s("bd") |> fast("<1 2>"), 1) == [0.0, 0.5]
      assert onsets(s("bd*2") |> slow("<1 2>"), 1) == [0.0]
    end

    test "ply takes a pattern" do
      assert onsets(s("bd") |> ply("<1 2>"), 1) == [0.0, 0.5]
      assert onsets(s("bd") |> ply("2"), 0) == [0.0, 0.5]
    end

    test "euclid with patterned arguments in the mini-notation" do
      assert onsets(s("bd(<3 5>,8)"), 0) == [0.0, 0.375, 0.75]
      assert onsets(s("bd(<3 5>,8)"), 1) |> length() == 5
    end
  end

  describe "sample banks" do
    test "bank names the bank each sound comes from" do
      assert values(s("bd sd:2") |> bank("crate")) == [
               %{sound: "bd", bank: "crate"},
               %{sound: "sd:2", bank: "crate"}
             ]

      assert values(s("bd") |> bank("RolandTR808")) == [%{sound: "bd", bank: "RolandTR808"}]
    end
  end

  test "a bare value in a control pattern is still fine" do
    assert values(s("bd") |> gain(pure(0.5))) == [%{sound: "bd", gain: 0.5}]
    assert onsets(fastcat([s("bd"), s("sn")]) |> struct("x x x")) == [0.0, 0.333333, 0.666667]
  end
end

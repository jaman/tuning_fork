defmodule TuningFork.StrudelControlsTest do
  @moduledoc """
  The controls Strudel's workshop teaches, checked through to the voice they produce.

  `TuningFork.Pattern.Control` only writes keys into a map, so a control that is set but never
  read would pass a test of the pattern and do nothing at all. Every test here goes as far as
  `TuningFork.Kit`, and the ones about sound go as far as the samples.
  """

  use ExUnit.Case, async: true

  import TuningFork.Pattern.Control

  alias TuningFork.{Kit, Pattern, Voice}
  alias TuningFork.Pattern.Player

  doctest TuningFork.Reverb

  defp voiced(pattern, seconds \\ 0.5) do
    [{_from, _to, controls} | _rest] = Pattern.first_cycle(pattern)

    Kit.voice(controls, seconds)
  end

  defp peak(pcm), do: for(<<s::16-signed-little <- pcm>>, do: abs(s)) |> Enum.max(fn -> 0 end)

  describe "the amp envelope, which the workshop teaches first" do
    test "attack, decay, sustain and release all reach the voice" do
      voice = voiced(note("c3") |> adsr(0.05, 0.2, 0.6, 0.4))

      assert voice.envelope.attack == 0.05
      assert voice.envelope.decay == 0.2
      assert voice.envelope.sustain == 0.6
      assert voice.envelope.release == 0.4
    end

    test "each one can be set on its own" do
      assert voiced(note("c3") |> attack(0.3)).envelope.attack == 0.3
      assert voiced(note("c3") |> decay(0.3)).envelope.decay == 0.3
      assert voiced(note("c3") |> sustain(0.25)).envelope.sustain == 0.25
      assert voiced(note("c3") |> release(0.7)).envelope.release == 0.7
    end

    test "adsr leaves out what it is not given" do
      before = voiced(note("c3"))
      after_ = voiced(note("c3") |> adsr(nil, nil, nil, 0.9))

      assert after_.envelope.release == 0.9
      assert after_.envelope.attack == before.envelope.attack
    end

    test "a longer envelope really does sound for longer" do
      short = voiced(note("c3") |> adsr(0.001, 0.01, 0.0, 0.01))
      long = voiced(note("c3") |> adsr(0.2, 0.1, 0.8, 0.3))

      assert Voice.duration(long) > Voice.duration(short)
    end
  end

  describe "the names Strudel uses for the filter" do
    test "lpf and lpq are cutoff and resonance" do
      assert voiced(note("c3") |> lpf(400)).filter.hz ==
               voiced(note("c3") |> cutoff(400)).filter.hz

      assert voiced(note("c3") |> lpq(9)).filter.q ==
               voiced(note("c3") |> resonance(9)).filter.q
    end

    test "hpf is the highpass" do
      assert voiced(note("c3") |> hpf(0.4)).highpass == 0.4
    end

    test "lprelease reaches the filter's own envelope" do
      voice = voiced(note("c3") |> lpenv(2) |> lprelease(0.25))

      assert voice.filter.envelope.release == 0.25
    end
  end

  describe "gain, velocity and speed" do
    test "velocity multiplies the gain rather than replacing it" do
      assert_in_delta voiced(note("c3") |> gain(0.8) |> velocity(0.5)).gain, 0.4, 0.001
    end

    test "speed puts the pitch up and is never negative" do
      plain = voiced(note("c3"))

      assert_in_delta voiced(note("c3") |> speed(2)).freq, plain.freq * 2, 0.001
      assert_in_delta voiced(note("c3") |> speed(-2)).freq, plain.freq * 2, 0.001
    end
  end

  describe "dirt" do
    test "crush changes the samples and stays inside the range" do
      clean = voiced(note("c3") |> shape(:saw)) |> Voice.render(44_100)
      crushed = voiced(note("c3") |> shape(:saw) |> crush(3)) |> Voice.render(44_100)

      refute clean == crushed
      assert peak(crushed) <= 32_767
    end

    test "sixteen bits of crush is no crush at all" do
      assert Voice.crush(0.3, 16) == 0.3
      assert Voice.crush(0.3, nil) == 0.3
    end

    test "distort dirties without simply turning it up" do
      clean = voiced(note("c3") |> shape(:saw)) |> Voice.render(44_100)
      driven = voiced(note("c3") |> shape(:saw) |> distort(8)) |> Voice.render(44_100)

      refute clean == driven
      assert peak(driven) <= 32_767
    end

    test "no distortion leaves the sample alone" do
      assert Voice.distort(0.5, 0.0) == 0.5
      assert Voice.distort(0.5, nil) == 0.5
    end

    test "shape with a number is Strudel's waveshaper, not a waveform" do
      voice = voiced(note("c3") |> shape(:saw) |> shape(0.3))
      assert voice.shape == :saw
      assert voice.waveshape == 0.3

      clean = voiced(note("c3") |> shape(:saw)) |> Voice.render(44_100)
      shaped = Voice.render(voice, 44_100)
      refute clean == shaped
      assert peak(shaped) <= 32_767

      assert Voice.waveshape(0.5, nil) == 0.5
      assert Voice.waveshape(0.5, 0.0) == 0.5
      assert_in_delta Voice.waveshape(0.5, 0.3), 0.65, 0.001
      assert Voice.waveshape(1.0, 0.999) <= 1.0
      assert Voice.waveshape(-0.5, 0.3) == -Voice.waveshape(0.5, 0.3)
    end
  end

  @rate 44_100

  defp energy(pcm, freq) do
    samples = for <<sample::16-signed-little <- pcm>>, do: sample / 32_767

    {re, im} =
      samples
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {sample, index}, {re, im} ->
        angle = 2 * :math.pi() * freq * index / @rate

        {re + sample * :math.cos(angle), im - sample * :math.sin(angle)}
      end)

    :math.sqrt(re * re + im * im) / length(samples)
  end

  describe "vowels" do
    defp said(vowel) do
      %{note: "c2", shape: :saw, release: 0.4}
      |> then(&if(vowel, do: Map.put(&1, :vowel, vowel), else: &1))
      |> Kit.voice(0.4)
      |> Voice.render(@rate)
    end

    test "each vowel really does resonate where its first formant is" do
      plain = said(nil)

      for {vowel, [{hz, _level} | _rest]} <- Voice.vowels() do
        lifted = energy(said(to_string(vowel)), hz) / max(energy(plain, hz), 1.0e-9)

        assert lifted > 5.0,
               "#{vowel} should lift #{round(hz)} Hz, got #{Float.round(lifted, 1)}x"
      end
    end

    test "speaking does not push it out of range" do
      for {vowel, _formants} <- Voice.vowels() do
        assert peak(said(to_string(vowel))) <= 32_767
      end
    end

    test "a vowel it has never heard of is ignored rather than raising" do
      assert Kit.voice(%{note: "c2", vowel: "q"}, 0.4).vowel == nil
      assert Kit.voice(%{note: "c2", vowel: 7}, 0.4).vowel == nil
    end

    test "it takes an atom as readily as a string" do
      assert Kit.voice(%{note: "c2", vowel: :a}, 0.4).vowel == :a
      assert Kit.voice(%{note: "c2", vowel: "a"}, 0.4).vowel == :a
    end
  end

  describe "frequency modulation" do
    defp rendered(controls), do: controls |> Kit.voice(0.3) |> Voice.render(44_100)

    test "fm puts partials far above the note that were not there before" do
      note = 130.81

      # Both sides open the filter the same way, so the only difference between them is the
      # modulation — otherwise this would be measuring the filter rather than the FM. A plain
      # sine is not quite pure here either: the ladder saturates, which makes its own harmonics.
      # They die away quickly, so the test looks well above them.
      plain = rendered(%{note: "c3", shape: :sine, cutoff: 12_000})
      modulated = rendered(%{note: "c3", shape: :sine, cutoff: 12_000, fm: 4, fmh: 2})

      up_high = fn pcm -> Enum.reduce(7..15, 0.0, &(&2 + energy(pcm, note * &1))) end

      assert up_high.(modulated) > up_high.(plain) * 5
    end

    test "fmh decides where the sidebands land" do
      close = rendered(%{note: "c3", shape: :sine, fm: 1, fmh: 1})
      far = rendered(%{note: "c3", shape: :sine, fm: 1, fmh: 5})

      refute close == far
      assert energy(far, 130.81 * 6) > energy(close, 130.81 * 6)
    end

    test "fmattack holds the modulation back rather than having it there at once" do
      at_once = rendered(%{note: "c3", shape: :sine, fm: 6, fmh: 2})
      arriving = rendered(%{note: "c3", shape: :sine, fm: 6, fmh: 2, fmattack: 0.8})

      refute at_once == arriving
    end

    test "none of it runs out of range" do
      for controls <- [
            %{note: "c3", shape: :sine, fm: 8, fmh: 3},
            %{note: "c3", shape: :saw, fm: 12, fmh: 7},
            %{note: "c1", shape: :saw, fm: 20, fmh: 1.5}
          ] do
        assert peak(rendered(controls)) <= 32_767
      end
    end

    test "vibrato moves the pitch about without changing the level much" do
      plain = rendered(%{note: "c3", shape: :sine})
      wobbling = rendered(%{note: "c3", shape: :sine, vib: 6, vibmod: 1})

      refute plain == wobbling
      assert_in_delta peak(wobbling) / peak(plain), 1.0, 0.2
    end
  end

  describe "coarse and the phaser" do
    test "coarse holds samples, so fewer of them are distinct" do
      smooth = rendered(%{note: "c3", shape: :saw})
      grainy = rendered(%{note: "c3", shape: :saw, coarse: 16})

      distinct = fn pcm ->
        pcm |> then(&for(<<s::16-signed-little <- &1>>, do: s)) |> Enum.uniq() |> length()
      end

      assert distinct.(grainy) < distinct.(smooth)
    end

    test "a coarse of one changes nothing" do
      assert rendered(%{note: "c3", shape: :saw, coarse: 1}) ==
               rendered(%{note: "c3", shape: :saw})
    end

    test "the phaser changes the sound and stays in range" do
      plain = rendered(%{note: "c3", shape: :saw})
      swept = rendered(%{note: "c3", shape: :saw, phaser: 2, phaserdepth: 0.8})

      refute plain == swept
      assert peak(swept) <= 32_767
    end
  end

  describe "the other filter kinds" do
    test "ftype reaches the filter, and picks the clean model for the two it must" do
      assert voiced(note("c3") |> ftype(:bandpass) |> cutoff(800)).filter.kind == :bandpass
      assert voiced(note("c3") |> ftype(:bandpass) |> cutoff(800)).filter.model == :svf
      assert voiced(note("c3") |> ftype(:highpass) |> cutoff(800)).filter.model == :svf
      assert voiced(note("c3") |> cutoff(800)).filter.model == :ladder
    end

    test "bpf and bpq are ftype and cutoff and resonance in one" do
      band = voiced(note("c3") |> bpf(900) |> bpq(6))

      assert band.filter.kind == :bandpass
      assert band.filter.hz == 900.0
      assert band.filter.q == 6.0
    end

    test "a resonant band or highpass does not run out of range" do
      for kind <- [:bandpass, :highpass], q <- [4, 12, 30] do
        pcm = rendered(%{note: "c3", shape: :saw, ftype: kind, cutoff: 800, resonance: q})

        assert peak(pcm) <= 32_767, "#{kind} at resonance #{q}"
      end
    end

    test "an ftype it does not know leaves the filter a lowpass" do
      assert voiced(note("c3") |> ftype("nonsense") |> cutoff(500)).filter.kind == :lowpass
    end
  end

  describe "buses" do
    alias TuningFork.Pattern.Player

    defp bussed(pattern, blocks \\ 8) do
      Enum.reduce(1..blocks, {Player.new(pattern, 44_100, cps: 1.0), <<>>}, fn _step, {p, acc} ->
        {pcm, p} = Player.advance(p, 2048, 2)

        {p, acc <> pcm}
      end)
    end

    test "each orbit keeps its own settings" do
      pattern =
        Pattern.stack([
          s("bd*4") |> orbit(0),
          s("hh*8") |> orbit(1) |> room(0.9)
        ])

      {player, _pcm} = bussed(pattern)

      assert Player.buses(player)[0].room == 0.0
      assert Player.buses(player)[1].room == 0.9
    end

    test "postgain turns a whole bus down" do
      {_p, loud} = bussed(s("bd*4") |> gain(0.9))
      {_p, quiet} = bussed(s("bd*4") |> gain(0.9) |> postgain(0.25))

      assert_in_delta peak(quiet) / peak(loud), 0.25, 0.05
    end

    test "xfade does the same thing said as a fade" do
      {_p, loud} = bussed(s("bd*4") |> gain(0.9))
      {_p, half} = bussed(s("bd*4") |> gain(0.9) |> xfade(0.5))

      assert_in_delta peak(half) / peak(loud), 0.5, 0.05
    end

    test "the compressor pulls the peaks down" do
      {_p, loud} = bussed(s("bd*4") |> gain(1.0))
      {_p, levelled} = bussed(s("bd*4") |> gain(1.0) |> compressor(1.0))

      assert peak(levelled) < peak(loud)
    end

    test "a pattern that never mentions an orbit lands on bus zero" do
      {player, _pcm} = bussed(s("bd*4"))

      assert Map.keys(Player.buses(player)) == [0]
    end
  end

  describe "chords" do
    test "voicing turns a name into the notes that play it" do
      notes =
        voicing("C^7")
        |> Pattern.first_cycle()
        |> Enum.map(fn {_from, _to, value} -> value.note end)

      assert Enum.sort(notes) == [48, 64, 67, 71]
    end

    test "an alternation gives a different chord each cycle" do
      pattern = voicing("<C^7 Dm7>")

      assert pattern |> Pattern.first_cycle(0) |> length() == 4
      assert pattern |> Pattern.first_cycle(1) |> length() == 5

      refute Pattern.first_cycle(pattern, 0) == Pattern.first_cycle(pattern, 1)
    end

    test "a chord it does not know falls silent rather than raising" do
      assert Pattern.first_cycle(voicing("Zq9")) == []
    end

    test "arp spreads a voicing out in time" do
      spread = voicing("C^7") |> Pattern.arp(:up)
      starts = spread |> Pattern.first_cycle() |> Enum.map(&elem(&1, 0))

      assert starts == [0.0, 0.25, 0.5, 0.75]
    end
  end

  describe "delay, which is the note played again" do
    test "it becomes real repeats, each quieter than the last" do
      pattern = s("bd") |> gain(1.0) |> delay(0.5) |> delaytime(0.125) |> delayfeedback(0.5)

      events = pattern |> echoes() |> Pattern.first_cycle()
      gains = Enum.map(events, fn {_from, _to, value} -> value.gain end)

      assert length(events) == 5
      assert gains == Enum.sort(gains, :desc), "each repeat should be quieter than the last"
    end

    test "the repeats land at the delay time" do
      pattern = s("bd") |> delay(0.5) |> delaytime(0.125)

      starts = pattern |> echoes() |> Pattern.first_cycle() |> Enum.map(&elem(&1, 0))

      assert starts == [0.0, 0.125, 0.25, 0.375, 0.5]
    end

    test "a tail long enough to cross the cycle line arrives in the next one" do
      pattern = s("bd") |> delay(0.5) |> delaytime(0.4)

      starts = pattern |> echoes() |> Pattern.first_cycle(1) |> Enum.map(&elem(&1, 0))

      assert 0.2 in starts, "the previous cycle's third repeat lands here"
      assert 0.6 in starts, "and so does its fourth"
    end

    test "a pattern with no delay is passed through untouched" do
      pattern = s("bd sn")

      assert Pattern.first_cycle(echoes(pattern)) == Pattern.first_cycle(pattern)
    end

    test "the repeats carry the sound they came from" do
      pattern = s("bd") |> shape(:saw) |> delay(0.4)

      for {_from, _to, value} <- pattern |> echoes() |> Pattern.first_cycle() do
        assert value.shape == :saw
      end
    end
  end

  describe "room, which is one space everything shares" do
    test "the reverb renders the same samples it always has, call after call" do
      impulse = <<32_000::16-signed-little, 0::16>> <> :binary.copy(<<0::16>>, 8_000 * 2 - 2)
      {wet, reverb} = TuningFork.Reverb.run(TuningFork.Reverb.new(8_000), impulse, 2, 0.5, 0.7)
      {again, _reverb} = TuningFork.Reverb.run(reverb, impulse, 2, 0.5, 0.7)

      assert :erlang.phash2(wet) == 32_641_944
      assert :erlang.phash2(again) == 89_298_387
    end

    test "the loudest ask is the one that carries" do
      pattern = Pattern.stack([s("bd") |> room(0.2), s("sn") |> room(0.8)])
      {player, _pcm} = played(pattern)

      assert {0.8, _size} = Player.room(player)
    end

    test "roomsize comes along with it" do
      {player, _pcm} = played(s("bd") |> room(0.5) |> roomsize(0.9))

      assert Player.room(player) == {0.5, 0.9}
    end

    test "each note sends its own amount to the room, so a dry drum stays dry beside a wet one" do
      dry = s("bd ~") |> room(0.0)
      wet = s("sn ~") |> room(0.9) |> roomsize(2)
      render = &Player.render(&1, 8_000, cycles: 1, cps: 1.0)

      apart = TuningFork.Mixer.mix(render.(dry), render.(wet))
      together = render.(Pattern.stack([dry, wet]))
      both_wet = render.(Pattern.stack([dry |> room(0.9), wet]))

      assert difference(together, apart) < 40
      assert difference(both_wet, apart) > 200
    end

    defp difference(a, b) do
      Enum.zip(for(<<x::16-signed-little <- a>>, do: x), for(<<y::16-signed-little <- b>>, do: y))
      |> Enum.map(fn {x, y} -> abs(x - y) end)
      |> Enum.max()
    end

    test "a pattern that asks for nothing leaves the room as it was" do
      {player, _pcm} = played(s("bd"))
      {room, _size} = Player.room(player)

      assert room == 0.0
    end

    defp played(pattern) do
      player = Player.new(pattern, 44_100, cps: 1.0)
      {pcm, player} = Player.advance(player, 4096, 2)

      {player, pcm}
    end
  end

  describe "banks" do
    test "a bank changes the drum rather than replacing it" do
      plain = Kit.voice(%{sound: "bd"}, 0.5)
      eight = Kit.voice(%{sound: "bd", bank: "RolandTR808"}, 0.5)

      assert eight.freq < plain.freq, "the 808 kick is the lower one"
      assert Voice.duration(eight) > Voice.duration(plain), "and the longer one"
    end

    test "every bank it lists really does change something" do
      plain = Kit.voice(%{sound: "bd"}, 0.5)

      for name <- Kit.banks() do
        voice = Kit.voice(%{sound: "bd", bank: name}, 0.5)

        refute {voice.freq, Voice.duration(voice)} == {plain.freq, Voice.duration(plain)},
               "#{name} should sound different from no bank at all"
      end
    end

    test "a bank it has never heard of plays the sound rather than nothing" do
      voice = Kit.voice(%{sound: "bd", bank: "SomeKitFromTheFuture"}, 0.5)

      assert voice.freq == Kit.voice(%{sound: "bd"}, 0.5).freq
    end
  end

  describe "jux, which the workshop recap teaches" do
    test "it puts the pattern left and the changed copy right" do
      events = s("bd") |> jux(&Pattern.rev/1) |> Pattern.first_cycle()
      pans = events |> Enum.map(fn {_f, _t, value} -> value.pan end) |> Enum.sort()

      assert pans == [-1.0, 1.0]
    end

    test "jux_by narrows the gap" do
      pans =
        s("bd")
        |> jux_by(0.4, &Pattern.rev/1)
        |> Pattern.first_cycle()
        |> Enum.map(fn {_f, _t, value} -> value.pan end)
        |> Enum.sort()

      assert pans == [-0.4, 0.4]
    end
  end

  describe "add on control maps" do
    test "it transposes without disturbing the rest" do
      [{_from, _to, value}] =
        note("c3") |> shape(:saw) |> Pattern.add(%{transpose: 12}) |> Pattern.first_cycle()

      assert value.transpose == 12
      assert value.shape == :saw
    end
  end

  describe "cycles per minute" do
    test "it is cycles per second times sixty, both ways" do
      assert TuningFork.Stage.cps_of(120) == 2.0
      assert TuningFork.Stage.cpm_of(2) == 120.0
      assert TuningFork.Stage.cps_of(TuningFork.Stage.cpm_of(0.5)) == 0.5
    end
  end
end

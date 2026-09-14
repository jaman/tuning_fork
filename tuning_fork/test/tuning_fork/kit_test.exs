defmodule TuningFork.KitTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Kit, Voice}

  doctest TuningFork.Kit

  describe "drums" do
    test "the short names give voices" do
      for name <- ~w(bd sn hh oh cp rim lt mt ht rd cr) do
        assert %Voice{} = Kit.voice(name, 0.25), "#{name} should be a drum"
      end
    end

    test "the long names give the same voice as the short ones" do
      assert Kit.voice("kick", 0.25) == Kit.voice("bd", 0.25)
      assert Kit.voice("snare", 0.25) == Kit.voice("sn", 0.25)
      assert Kit.voice("hat", 0.25) == Kit.voice("hh", 0.25)
    end

    test "an index shifts the drum without changing anything else" do
      plain = Kit.voice("bd", 0.25)
      shifted = Kit.voice("bd:5", 0.25)

      assert shifted.freq != plain.freq
      assert shifted.shape == plain.shape
      assert shifted.gain == plain.gain
    end

    test "an index of zero is the drum as it was" do
      assert Kit.voice("bd:0", 0.25) == Kit.voice("bd", 0.25)
    end

    test "drums/0 lists what it answers to" do
      names = Kit.drums()

      assert "bd" in names
      assert "sn" in names
      assert names == Enum.sort(names)
    end

    test "known? says whether a name plays as a drum, a waveform or a GM instrument" do
      assert Kit.known?("bd")
      assert Kit.known?("sawtooth")
      assert Kit.known?("gm_epiano1")
      assert Kit.known?("gm_epiano1:2")
      refute Kit.known?("kazoo")
      refute Kit.known?("c4")
    end
  end

  describe "pitched notes" do
    test "a note name gives a voice at that pitch" do
      assert %Voice{freq: freq} = Kit.voice("a4", 0.25)
      assert_in_delta freq, 440.0, 0.5
    end

    test "sharps and flats are understood" do
      assert %Voice{} = Kit.voice("fs3", 0.25)
      assert %Voice{} = Kit.voice("eb5", 0.25)
    end

    test "a midi number gives the pitch that number means" do
      assert %Voice{freq: freq} = Kit.voice(69, 0.25)
      assert_in_delta freq, 440.0, 0.5
    end

    test "a float is taken as hertz outright" do
      assert %Voice{freq: 300.0} = Kit.voice(300.0, 0.25)
    end

    test "a name that has never been an atom still resolves" do
      name = Enum.join(["d", "s", "7"])

      assert %Voice{} = Kit.voice(name, 0.25)
      assert Kit.midi(name) == 99
    end

    test "every note name the kit lists makes a sound" do
      for name <- Enum.take_every(Kit.notes(), 7) do
        assert %Voice{} = Kit.voice(name, 0.25), "#{name} is listed but makes no sound"
        assert is_integer(Kit.midi(name)), "#{name} has no pitch"
      end
    end

    test "how long the note lasts shapes its envelope" do
      short = Kit.voice("c3", 0.05)
      long = Kit.voice("c3", 2.0)

      assert Envelope.duration(long.envelope) > Envelope.duration(short.envelope)
    end
  end

  describe "values it cannot make sound of" do
    test "a word naming nothing is nil rather than an error" do
      assert Kit.voice("wobble", 0.25) == nil
      assert Kit.voice("", 0.25) == nil
    end

    test "nil and other terms are nil" do
      assert Kit.voice(nil, 0.25) == nil
      assert Kit.voice({:odd, :thing}, 0.25) == nil
    end
  end

  describe "a voice given outright" do
    test "comes back as it was" do
      voice = Voice.new(shape: :square, freq: 123.0, envelope: Envelope.hit(0.1))

      assert Kit.voice(voice, 0.25) == voice
    end
  end

  describe "maps of controls" do
    test "sound says what to play and the rest says how" do
      voice = Kit.voice(%{sound: "bd", gain: 0.6, pan: -0.5}, 0.25)

      assert voice.gain == 0.6
      assert voice.pan == -0.5
    end

    test "note works where sound does" do
      assert %Voice{freq: freq} = Kit.voice(%{note: "a4"}, 0.25)
      assert_in_delta freq, 440.0, 0.5
    end

    test "shape and highpass carry through" do
      voice = Kit.voice(%{note: "c3", shape: :square, highpass: 0.1}, 0.25)

      assert voice.shape == :square
      assert voice.highpass == 0.1
    end

    test "cutoff is a frequency in hertz, on a filter with poles and resonance" do
      voice = Kit.voice(%{note: "c3", cutoff: 800, resonance: 6.0}, 0.25)

      assert voice.filter.hz == 800.0
      assert voice.filter.q == 6.0
      assert voice.filter.poles == 4
    end

    test "a sweep gives the filter an envelope of its own" do
      voice = Kit.voice(%{note: "c3", cutoff: 300, lpenv: 3.5, lpdecay: 0.12}, 0.25)

      assert voice.filter.amount == 3.5
      assert voice.filter.envelope.decay == 0.12
    end

    test "without any of them a pitched note still gets a filter, so it is not a raw buzz" do
      voice = Kit.voice(%{note: "c3"}, 0.25)

      assert %TuningFork.Filter{poles: 4} = voice.filter
    end

    test "release lengthens the tail without touching the rest" do
      plain = Kit.voice(%{note: "c3"}, 0.25)
      rung = Kit.voice(%{note: "c3", release: 0.9}, 0.25)

      assert rung.envelope.release == 0.9
      assert rung.envelope.attack == plain.envelope.attack
    end

    test "levels outside nought to one are brought back in" do
      assert Kit.voice(%{sound: "bd", gain: 5.0}, 0.25).gain == 1.0
      assert Kit.voice(%{sound: "bd", gain: -2.0}, 0.25).gain == 0.0
    end

    test "a map naming nothing to play is nil" do
      assert Kit.voice(%{gain: 0.5}, 0.25) == nil
    end

    test "a map naming something the kit does not have is nil" do
      assert Kit.voice(%{sound: "wobble"}, 0.25) == nil
    end
  end
end

defmodule TuningFork.KitGmTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Gm, Kit, Voice}
  alias TuningFork.Gm.{Fonts, Names}
  alias TuningFork.Sample.Font
  alias TuningFork.Test.FileServer

  setup do
    Font.clear()
    on_exit(&Font.clear/0)
  end

  test "a gm_ sound with a pitch plays the General MIDI program at that pitch, until its soundfont is there" do
    Font.source("http://127.0.0.1:1")
    voice = Kit.voice(%{s: "gm_epiano1", note: 60}, 0.5)
    expected = Gm.for_program(4, Kit.voice(60, 0.5))

    assert %Voice{} = voice
    assert voice.shape == expected.shape
    assert_in_delta voice.freq, 261.63, 0.01

    assert Kit.voice(%{s: "gm_acoustic_bass:1", note: 40}, 0.5).shape ==
             Gm.for_program(32, Kit.voice(40, 0.5)).shape
  end

  @tag :tmp_dir
  test "once the soundfont is loaded, a gm_ sound is its recording at the note", %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    pcm = for i <- 0..199, into: <<>>, do: <<rem(i, 100) * 300::16-signed-little>>

    zone =
      "{midi:0,originalPitch:6000,keyRangeLow:0,keyRangeHigh:127,loopStart:50,loopEnd:100,coarseTune:0,fineTune:0,sampleRate:8000,ahdsr:true,sample:'#{Base.encode64(pcm)}'}"

    path = Path.join(dir, Fonts.file("gm_epiano1", 1) <> ".js")
    File.write!(path, "var x={zones:[" <> zone <> "]}")
    {:ok, server} = FileServer.start(path)
    Font.source("http://127.0.0.1:#{server.port}")

    assert %Voice{sample: nil} = Kit.voice(%{s: "gm_epiano1:1", note: 64}, 0.5, wait: false)

    assert %Voice{sample: %TuningFork.Sample{loop: {50, 100}}, gain: gain} =
             voice = Kit.voice(%{s: "gm_epiano1:1", note: 64}, 0.5)

    assert_in_delta voice.freq, 329.63, 0.01
    assert_in_delta voice.sample.root, 261.63, 0.01
    assert_in_delta gain, 0.3, 0.001
    assert_in_delta Voice.duration(voice), 0.5 + 0.001 + 0.001 + 0.01, 0.001

    assert %Voice{sample: %TuningFork.Sample{}} =
             Kit.voice(%{s: "gm_epiano1:1", note: 64}, 0.5, wait: false)
  end

  test "a waveform as the sound is that oscillator, raw, at Strudel's synth level" do
    for {name, shape} <- [
          {"triangle", :triangle},
          {"tri", :triangle},
          {"sawtooth", :saw},
          {"saw", :saw},
          {"square", :square},
          {"sine", :sine}
        ] do
      voice = Kit.voice(%{s: name, note: 60}, 0.5)
      assert voice.shape == shape, name
      assert voice.filter == nil, name
      assert_in_delta voice.freq, 261.63, 0.01
    end

    assert Kit.voice(%{s: "white", note: 60}, 0.5).shape == :noise
    assert_in_delta Kit.voice(%{s: "triangle", note: 60}, 0.5).gain, 0.3, 0.001
    assert_in_delta Kit.voice(%{note: 60}, 0.5).gain, 0.3, 0.001
  end

  test "the names are Strudel's" do
    assert "gm_epiano1" in Names.names()
    assert Names.program("gm_acoustic_bass") == 32
    assert Names.program("bd") == nil
  end
end

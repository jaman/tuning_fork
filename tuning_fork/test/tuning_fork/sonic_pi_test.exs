defmodule TuningFork.SonicPiTest do
  use ExUnit.Case, async: false

  use TuningFork.SonicPi

  alias TuningFork.{Notes, Sample, Score, SonicPi, Store, Voice}
  alias TuningFork.Sample.Bank

  @flac Path.expand("../fixtures/flac/stereo_lpc.flac", __DIR__)

  setup do
    Store.clear()
    Bank.clear()
    Bank.put(:bell, @flac)
    on_exit(fn -> Bank.clear() end)
    :ok
  end

  defp all_notes(%Score{} = score) do
    (score.notes ++ Enum.flat_map(score.layers, & &1.notes))
    |> Enum.sort_by(fn {beat, _voice} -> beat end)
  end

  defp starts(score), do: score |> all_notes() |> Enum.map(fn {beat, _} -> beat end)
  defp voices(score), do: score |> all_notes() |> Enum.map(fn {_, voice} -> voice end)

  describe "a round" do
    test "play puts a note at the cursor and sleep moves it on" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          play(:e3)
          sleep(0.5)
          play(:g3)
          sleep(0.5)
        end)

      assert starts(score) == [0.0, 0.5]
      assert score.beats == 1.0
      assert score.bpm == 60.0
      assert [first, second] = voices(score)
      assert_in_delta first.freq, Notes.freq(:e3), 0.01
      assert_in_delta second.freq, Notes.freq(:g3), 0.01
    end

    test "sleep is in beats of the tempo, and the score is in seconds" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          use_bpm(120)
          play(:c4)
          sleep(1)
          play(:c4)
          sleep(1)
        end)

      assert starts(score) == [0.0, 0.5]
      assert score.beats == 1.0
    end

    test "a round that never sleeps is refused" do
      assert {:error, message} = SonicPi.run_round(fn -> play(:c4) end)
      assert message =~ "sleep"
    end

    test "a round that returns a part or a score is that" do
      {:ok, score} = SonicPi.run_round(fn -> part(bpm: 120) |> play(:c3, 1) end)
      assert starts(score) == [0.0]
      assert score.bpm == 120.0
    end

    test "notes are midi numbers, names, capitalised names, strings or hertz" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          play(60)
          play(:c4)
          play(:C4)
          play("c4")
          play(261.6256)
          play(:Fs4)
          play(:Eb4)
          sleep(1)
        end)

      freqs = score |> voices() |> Enum.map(& &1.freq)
      assert Enum.all?(Enum.take(freqs, 5), &(abs(&1 - Notes.freq(:c4)) < 0.01))
      assert_in_delta Enum.at(freqs, 5), Notes.freq(:fs4), 0.01
      assert_in_delta Enum.at(freqs, 6), Notes.freq(:ds4), 0.01
    end

    test "a name with no octave sits in octave 4" do
      {:ok, score} = SonicPi.run_round(fn -> play(:e) && sleep(1) end)
      assert_in_delta hd(voices(score)).freq, Notes.freq(:e4), 0.01
    end

    test "nil plays nothing and a list plays a chord" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          play(nil)
          sleep(1)
          play([:c4, :e4, :g4])
          sleep(1)
        end)

      assert starts(score) == [1.0, 1.0, 1.0]
    end

    test "play_chord and chord" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          play_chord(chord(:e3, :minor))
          sleep(1)
        end)

      assert length(all_notes(score)) == 3
      assert chord(:e3, :minor) == [52, 55, 59]
      assert chord(:e3, :m7) == [52, 55, 59, 62]
      assert chord(:c4, :major, num_octaves: 2) == [60, 64, 67, 72, 76, 79]
      assert chord(:c4, :major, invert: 1) == [64, 67, 72]
      assert chord_degree(1, :c4, :major, 3) == [60, 64, 67]
      assert chord_degree(2, :c4, :major, 3, invert: -1) == [57, 62, 65]
    end

    test "scale" do
      assert scale(:c4, :major) == [60, 62, 64, 65, 67, 69, 71, 72]
      assert scale(:e3, :minor_pentatonic, num_octaves: 2) |> length() == 11
      assert scale(:g2, :minor) |> hd() == 43
    end

    test "play_pattern_timed walks notes with their own gaps" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          play_pattern_timed([:c4, :d4, :e4], [0.25, 0.5])
        end)

      assert starts(score) == [0.0, 0.25, 0.75]
      assert score.beats == 1.0
    end

    test "play_pattern uses a beat a note" do
      {:ok, score} = SonicPi.run_round(fn -> play_pattern([:c4, :d4]) end)
      assert starts(score) == [0.0, 1.0]
      assert score.beats == 2.0
    end

    test "use_transpose moves everything" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          use_transpose(12)
          play(:c4)
          sleep(1)
        end)

      assert_in_delta hd(voices(score)).freq, Notes.freq(:c5), 0.01
    end
  end

  describe "how a note sounds" do
    test "amp, pan and the envelope" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          play(:c4,
            amp: 0.5,
            pan: -0.5,
            attack: 0.1,
            decay: 0.2,
            sustain: 0.3,
            release: 0.4,
            sustain_level: 0.6
          )

          sleep(1)
        end)

      [voice] = voices(score)
      assert_in_delta voice.gain, 0.4, 0.001
      assert voice.pan == -0.5
      assert voice.envelope.attack == 0.1
      assert voice.envelope.decay == 0.2
      assert voice.envelope.hold == 0.3
      assert voice.envelope.release == 0.4
      assert voice.envelope.sustain == 0.6
      assert_in_delta Voice.duration(voice), 1.0, 0.001
    end

    test "the default envelope is Sonic Pi's: a one-beat release and nothing else" do
      {:ok, score} = SonicPi.run_round(fn -> play(:c4) && sleep(1) end)
      [voice] = voices(score)

      assert voice.envelope.attack == 0.0
      assert voice.envelope.release == 1.0
      assert_in_delta Voice.duration(voice), 1.0, 0.001
    end

    test "cutoff is a midi note and res is 0 to 1" do
      {:ok, score} = SonicPi.run_round(fn -> play(:c4, cutoff: 69, res: 0.9) && sleep(1) end)
      [voice] = voices(score)

      assert_in_delta voice.filter.hz, 440.0, 0.01
      assert_in_delta voice.filter.q, 10.0, 0.01
    end

    test "use_synth picks the voice and use_synth_defaults fills in options" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          use_synth(:saw)
          use_synth_defaults(release: 0.25, amp: 0.7)
          play(:c4)
          play(:c4, release: 0.5)
          sleep(1)
        end)

      [first, second] = voices(score)
      assert first.shape == :saw
      assert first.envelope.release == 0.25
      assert second.envelope.release == 0.5
      assert_in_delta second.gain, 0.56, 0.001
    end

    test "synth plays a named synth without changing the current one" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          synth(:tb303, note: :e2, release: 0.3)
          play(:e2)
          sleep(1)
        end)

      [first, second] = voices(score)
      assert first.shape == :saw
      assert first.filter != nil
      assert second.shape == :sine
    end

    test "every named synth is a voice" do
      for name <- SonicPi.Synth.names() do
        voices = SonicPi.Synth.voice(name, 440.0, [])
        assert Enum.all?(List.wrap(voices), &match?(%Voice{}, &1)), "#{name}"
      end

      assert length(SonicPi.Synth.names()) >= 40
    end

    test "a synth it does not know says so" do
      assert_raise ArgumentError, ~r/no synth named :kazoo/, fn ->
        SonicPi.run_round(fn -> use_synth(:kazoo) && play(:c4) && sleep(1) end)
      end
    end

    test "use_synth takes a sound name, played at each note through the kit" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          use_synth("gm_epiano1")
          play(:a4, sustain: 0.5, release: 0.2, amp: 0.5)
          sleep(1)
        end)

      [voice] = voices(score)
      assert_in_delta voice.freq, 440.0, 0.01
      assert voice.envelope.hold == 0.5
      assert voice.envelope.release == 0.2
      assert_in_delta voice.gain, 0.15, 0.001
    end

    test "a sound name the kit does not know says so" do
      assert_raise ArgumentError, ~r/no sound named "kazoo"/, fn ->
        SonicPi.run_round(fn -> use_synth("kazoo") && play(:c4) && sleep(1) end)
      end
    end

    test "use_synth takes a voice of your own" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          use_synth(Voice.new(shape: :triangle, crush: 6.0))
          play(:a4)
          sleep(1)
        end)

      [voice] = voices(score)
      assert voice.shape == :triangle
      assert voice.crush == 6.0
      assert_in_delta voice.freq, 440.0, 0.01
    end
  end

  describe "samples" do
    test "sample plays a recording from the bank for its whole length" do
      {:ok, score} = SonicPi.run_round(fn -> sample(:bell) && sleep(1) end)
      [voice] = voices(score)
      {:ok, bell} = Bank.fetch(:bell)

      assert voice.sample.name == "bell"
      assert_in_delta Voice.duration(voice), Sample.duration(bell), 0.01
    end

    test "rate changes pitch and length together, and a negative rate reverses" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          sample(:bell, rate: 2)
          sample(:bell, rate: -1)
          sleep(1)
        end)

      [double, backwards] = voices(score)
      {:ok, bell} = Bank.fetch(:bell)

      assert_in_delta Voice.duration(double), Sample.duration(bell) / 2, 0.01
      assert backwards.sample.pcm == Sample.reverse(bell).pcm
    end

    test "rpitch is a rate in semitones" do
      {:ok, score} = SonicPi.run_round(fn -> sample(:bell, rpitch: 12) && sleep(1) end)
      [voice] = voices(score)
      {:ok, bell} = Bank.fetch(:bell)

      assert_in_delta Voice.duration(voice), Sample.duration(bell) / 2, 0.01
    end

    test "beat_stretch fits the recording to a number of beats" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          use_bpm(120)
          sample(:bell, beat_stretch: 2)
          sleep(2)
        end)

      [voice] = voices(score)
      assert_in_delta Voice.duration(voice), 1.0, 0.01
    end

    test "start and finish slice it, and amp, pan and attack still apply" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          sample(:bell, start: 0.25, finish: 0.5, amp: 0.5, pan: 0.3, attack: 0.05)
          sleep(1)
        end)

      [voice] = voices(score)
      {:ok, bell} = Bank.fetch(:bell)

      assert_in_delta Voice.duration(voice), Sample.duration(bell) / 4, 0.02
      assert_in_delta voice.gain, 0.4, 0.001
      assert voice.pan == 0.3
      assert voice.envelope.attack == 0.05
    end

    test "sample_duration says how long one will sound" do
      {:ok, bell} = Bank.fetch(:bell)
      assert_in_delta sample_duration(:bell), Sample.duration(bell), 0.001
      assert_in_delta sample_duration(:bell, rate: 2), Sample.duration(bell) / 2, 0.001
    end

    test "a path is a sample too" do
      {:ok, score} = SonicPi.run_round(fn -> sample(@flac) && sleep(1) end)
      assert [%Voice{sample: %Sample{}}] = voices(score)
    end

    test "a name the bank does not have says so" do
      assert_raise ArgumentError, ~r/no sample named :nothing/, fn ->
        SonicPi.run_round(fn -> sample(:nothing) && sleep(1) end)
      end
    end

    test "use_sample_defaults" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          use_sample_defaults(amp: 0.25)
          sample(:bell)
          sleep(1)
        end)

      assert_in_delta hd(voices(score)).gain, 0.2, 0.001
    end
  end

  describe "randomness" do
    test "rrand, rrand_i, rand, choose, one_in and dice draw from the round's own generator" do
      {:ok, _score} =
        SonicPi.run_round(fn ->
          sleep(1)

          Process.put(:seen, [
            rrand(1, 2),
            rrand_i(1, 6),
            rand(),
            rand_i(4),
            choose([:a, :b]),
            one_in(2),
            dice()
          ])
        end)

      [float, int, unit, small, picked, bool, die] = Process.get(:seen)
      assert float >= 1 and float < 2
      assert int in 1..6
      assert unit >= 0 and unit < 1
      assert small in 0..3
      assert picked in [:a, :b]
      assert is_boolean(bool)
      assert die in 1..6
    end

    test "the same seed gives the same numbers, and use_random_seed resets it" do
      draw = fn ->
        SonicPi.run_round(fn ->
          use_random_seed(667)
          first = rrand(0, 100)
          use_random_seed(667)
          second = rrand(0, 100)
          Process.put(:draws, {first, second})
          sleep(1)
        end)

        Process.get(:draws)
      end

      {first, second} = draw.()
      assert first == second
      assert draw.() == {first, second}
    end

    test "each round of a loop draws differently unless it seeds itself" do
      draws = fn at ->
        Store.as(:loop, at, fn ->
          {:ok, _} =
            SonicPi.run_round(fn ->
              Process.put(:draw, rrand(0, 100))
              sleep(1)
            end)

          Process.get(:draw)
        end)
      end

      refute draws.(0) == draws.(44_100)
      assert draws.(0) == draws.(0)
    end

    test "shuffle, pick and with_random_seed" do
      SonicPi.run_round(fn ->
        Process.put(:shuffled, shuffle([1, 2, 3, 4]))
        Process.put(:picked, pick([1, 2, 3], 5))
        Process.put(:seeded, with_random_seed(1, fn -> rrand(0, 1) end))
        Process.put(:seeded_again, with_random_seed(1, fn -> rrand(0, 1) end))
        sleep(1)
      end)

      assert Enum.sort(Process.get(:shuffled)) == [1, 2, 3, 4]
      assert length(Process.get(:picked)) == 5
      assert Process.get(:seeded) == Process.get(:seeded_again)
    end
  end

  describe "rings and ticks" do
    test "tick on a list walks it, look reads without stepping" do
      Store.as(:loop, 0, fn ->
        SonicPi.run_round(fn ->
          notes = ring([:c4, :e4, :g4])
          Process.put(:walk, [tick(notes), tick(notes), tick(notes), tick(notes), look(notes)])
          sleep(1)
        end)
      end)

      assert Process.get(:walk) == [:c4, :e4, :g4, :c4, :c4]
    end

    test "named ticks are separate counters" do
      Store.as(:loop, 0, fn ->
        SonicPi.run_round(fn ->
          Process.put(:ticks, [tick(:a), tick(:a), tick(:b), tick(), look(:a), look(:b), look()])
          sleep(1)
        end)
      end)

      assert Process.get(:ticks) == [0, 1, 0, 0, 1, 0, 0]
    end

    test "tick_reset and tick_set" do
      Store.as(:loop, 0, fn ->
        SonicPi.run_round(fn ->
          tick()
          tick()
          tick_reset()
          tick_set(:a, 5)
          Process.put(:after, [look(), look(:a)])
          sleep(1)
        end)
      end)

      assert Process.get(:after) == [0, 5]
    end

    test "list helpers" do
      assert range(0, 4) == [0, 1, 2, 3]
      assert range(0, 1, 0.25) == [0.0, 0.25, 0.5, 0.75]
      assert line(0, 1, steps: 5) == [0.0, 0.2, 0.4, 0.6, 0.8]
      assert line(0, 1, steps: 5, inclusive: true) == [0.0, 0.25, 0.5, 0.75, 1.0]
      assert knit(:a, 2, :b, 1) == [:a, :a, :b]
      assert spread(3, 8) == [true, false, false, true, false, false, true, false]
      assert bools(1, 0, 1) == [true, false, true]
      assert mirror([1, 2, 3]) == [1, 2, 3, 2, 1]
      assert reflect([1, 2, 3]) == [1, 2, 3, 3, 2, 1]
      assert rotate([1, 2, 3], 1) == [2, 3, 1]
      assert stretch([1, 2], 2) == [1, 1, 2, 2]
      assert ring_at([1, 2, 3], 4) == 2
    end

    test "note helpers" do
      assert note(:a4) == 69
      assert note(69) == 69
      assert note("c4") == 60
      assert note(nil) == nil
      assert_in_delta midi_to_hz(69), 440.0, 0.001
      assert hz_to_midi(440.0) == 69.0
      assert degree(1, :c4, :major) == 60
      assert degree(3, :c4, :major) == 64
      assert octs(:c4, 2) == [60, 72]
      assert note(:F, octave: 1) == 29
      assert factor?(8, 4) and not factor?(9, 4)
      assert range(90, 60, -10) == [90, 80, 70]
      assert range(0, 4, steps: 8) == [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5]
      assert rrand(0, 1, res: 0.5) in [0.0, 0.5, 1.0]
    end
  end

  describe "threads and effects" do
    test "in_thread plays alongside and does not move the cursor" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          in_thread(fn ->
            play(:c2)
            sleep(0.5)
            play(:c2)
          end)

          play(:c5)
          sleep(1)
        end)

      assert starts(score) == [0.0, 0.0, 0.5]
      assert score.beats == 1.0
    end

    test "with_fx puts the notes inside it on a layer with those effects" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          with_fx(:reverb, [mix: 0.3, room: 0.8], fn -> play(:c4) && sleep(1) end)
          play(:d4)
          sleep(1)
        end)

      assert [{first_at, _}] = score.layers |> hd() |> Map.get(:notes)
      assert first_at == 0.0
      assert [reverb: opts] = hd(score.layers).fx
      assert opts[:mix] == 0.3
      assert opts[:room] == 0.8
      assert [{second_at, _}] = score.notes
      assert second_at == 1.0
    end

    test "with_fx takes a do block too" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          with_fx :echo, phase: 0.25, decay: 2 do
            play(:c4)
            sleep(1)
          end
        end)

      assert [echo: opts] = hd(score.layers).fx
      assert_in_delta opts[:delay], 0.25, 0.001
      assert opts[:feedback] > 0.3 and opts[:feedback] < 0.5
    end

    test "nested effects apply inner first" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          with_fx :reverb do
            with_fx :distortion do
              play(:c4)
              sleep(1)
            end
          end
        end)

      assert [drive: _, reverb: _] = hd(score.layers).fx
    end

    test "every Sonic Pi effect name maps to something that runs" do
      for name <- SonicPi.Effects.names() do
        {:ok, score} =
          SonicPi.run_round(fn ->
            with_fx(name, [], fn -> play(:c4) && sleep(0.1) end)
          end)

        assert byte_size(Score.render(score, 8_000)) > 0, "#{name}"
      end

      assert length(SonicPi.Effects.names()) >= 20
    end

    test "an effect it does not have says so" do
      assert_raise ArgumentError, ~r/no effect named :warp/, fn ->
        SonicPi.run_round(fn -> with_fx(:warp, [], fn -> sleep(1) end) end)
      end
    end

    test "control on a note bends it from that moment" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          node = play(:c4, release: 2)
          sleep(1)
          control(node, note: :c5)
          sleep(1)
        end)

      [voice] = voices(score)
      curve = voice.curves.freq

      assert_in_delta TuningFork.Curve.at(curve, 0.25), 1.0, 0.001
      assert_in_delta TuningFork.Curve.at(curve, 0.75), 2.0, 0.001
    end

    test "control on an effect changes it for what comes after" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          with_fx(:reverb, [mix: 0.1], fn room ->
            play(:c4)
            sleep(1)
            control(room, mix: 0.9)
            play(:d4)
            sleep(1)
          end)
        end)

      mixes =
        score.layers
        |> Enum.map(fn layer -> {hd(layer.notes) |> elem(0), layer.fx[:reverb][:mix]} end)
        |> Enum.sort()

      assert mixes == [{0.0, 0.1}, {1.0, 0.9}]
    end

    test "density squeezes a block into less time" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          density(2, fn ->
            play(:c4)
            sleep(1)
          end)
        end)

      assert starts(score) == [0.0, 0.5]
      assert score.beats == 1.0
    end

    test "with_bpm, with_synth and with_transpose are scoped" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          with_bpm(120, fn -> play(:c4) && sleep(1) end)
          with_synth(:saw, fn -> play(:c4) end)
          with_transpose(12, fn -> play(:c4) end)
          play(:c4)
          sleep(1)
        end)

      assert starts(score) == [0.0, 0.5, 0.5, 0.5]
      assert [_, saw, up, plain] = voices(score)
      assert saw.shape == :saw
      assert plain.shape == :sine
      assert_in_delta up.freq, Notes.freq(:c5), 0.01
    end

    test "times runs a block that many times, told which" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          times(3, fn index ->
            play(60 + index)
            sleep(0.25)
          end)
        end)

      assert starts(score) == [0.0, 0.25, 0.5]
    end

    test "stop ends the round there" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          play(:c4)
          sleep(1)
          stop()
          play(:d4)
          sleep(1)
        end)

      assert starts(score) == [0.0]
      assert score.beats == 1.0
    end
  end

  describe "cue and sync" do
    test "sync waits for a cue, and goes once it has been given, with what it carried" do
      Store.as(:drums, 0, fn ->
        assert {:error, message} = SonicPi.run_round(fn -> sync(:go) && play(:c4) && sleep(1) end)
        assert message =~ "waiting for :go"
      end)

      Store.as(:lead, 0, fn -> SonicPi.run_round(fn -> cue(:go, rate: 2) && sleep(1) end) end)

      Store.as(:drums, 0, fn ->
        assert {:ok, score} =
                 SonicPi.run_round(fn ->
                   Process.put(:cued, sync(:go))
                   play(:c4)
                   sleep(1)
                 end)

        assert starts(score) == [0.0]
        assert Process.get(:cued) == [rate: 2]
      end)
    end
  end

  describe "a buffer of source" do
    test "live_loop starts a named loop, and top-level code is a score of its own" do
      source = """
      use_bpm 120

      live_loop :tick do
        sample :bell
        sleep 1
      end

      play :c4
      sleep 2
      """

      assert {:ok, buffer} = SonicPi.run(source)
      assert [{:tick, %Score{} = first, body}] = buffer.loops
      assert first.beats == 0.5
      assert {:ok, %Score{}} = body.()
      assert %Score{beats: 1.0} = buffer.score
    end

    test "a buffer with only loops has no main score" do
      {:ok, buffer} = SonicPi.run("live_loop :a do\n  play :c4\n  sleep 1\nend")
      assert buffer.score == nil
      assert [{:a, _, _}] = buffer.loops
    end

    test "a loop that will not run is reported by name" do
      assert {:error, message} = SonicPi.run("live_loop :a do\n  play :c4\nend")
      assert message =~ ":a"
      assert message =~ "sleep"
    end

    test "source that does not read is an error, not a crash" do
      assert {:error, message} = SonicPi.run("play(")
      assert is_binary(message)
    end

    test "render plays it all for a span" do
      source = """
      live_loop :a do
        play :c4, release: 0.2
        sleep 0.5
      end
      """

      pcm = SonicPi.render(source, 8_000, 2.0)
      assert byte_size(pcm) == 8_000 * 2 * 2 * 2
      assert TuningFork.Mixer.peak(pcm) > 1_000
    end

    test "live_loop with a sync waits for the loop it names" do
      source = """
      live_loop :lead do
        sync :beat
        play :c5
        sleep 1
      end

      live_loop :beat do
        cue :beat
        play :c2
        sleep 1
      end
      """

      assert {:ok, buffer} = SonicPi.run(source)
      assert length(buffer.loops) == 2
    end
  end

  describe "buffer" do
    test "a block becomes a buffer of its loops and top-level score" do
      %SonicPi.Buffer{} =
        buffer =
        buffer do
          use_bpm(120)
          play(:c4)
          sleep(2)

          live_loop :tick do
            sample(:bell)
            sleep(1)
          end
        end

      assert [{:tick, %Score{beats: 0.5}, _body}] = buffer.loops
      assert %Score{beats: 1.0} = buffer.score
      assert byte_size(SonicPi.render(buffer, 8_000, 1.0)) == 8_000 * 4
    end

    test "a loop that will not run raises" do
      assert_raise ArgumentError, ~r/:a.*sleep/, fn ->
        buffer do
          live_loop :a do
            play(:c4)
          end
        end
      end
    end
  end

  describe "on a stage" do
    test "outside a round, play sounds on the named stage at once and sleep waits" do
      {:ok, stage} =
        TuningFork.Stage.start_link(
          sink: TuningFork.Sink.Collect,
          sink_opts: [owner: self()],
          rate: 8_000,
          chunk: 256
        )

      Process.delete({TuningFork.SonicPi, :thread})

      {micros, _} =
        :timer.tc(fn ->
          play(:c4)
          sleep(0.2)
        end)

      assert micros >= 190_000
      assert_receive {:pcm, chunk}, 1_000

      loud =
        Enum.find(1..30, fn _ ->
          assert_receive({:pcm, more}, 1_000) && TuningFork.Mixer.peak(more) > 500
        end)

      assert loud || TuningFork.Mixer.peak(chunk) > 500
      GenServer.stop(stage)
    end

    test "live_loop starts a loop that is worked out again each round" do
      {:ok, stage} =
        TuningFork.Stage.start_link(sink: TuningFork.Sink.Silent, rate: 8_000, chunk: 256)

      result =
        live_loop :ticking, stage: stage do
          play(60 + tick())
          sleep(0.05)
        end

      assert result == :ok

      assert :ok = TuningFork.Stage.after_round(stage, :ticking, 5_000)
      assert %{ticking: %{rounds: rounds}} = TuningFork.Stage.loops(stage)
      assert rounds >= 1
      GenServer.stop(stage)
    end
  end

  describe "the Part vocabulary is still there" do
    test "a pipeline of parts reads as it did" do
      {:ok, score} =
        SonicPi.run_round(fn ->
          part(bpm: 120, synth: Kit.voice("bd", 0.3))
          |> play(:c3, 1)
          |> chord([:c3, :e3], 1)
          |> play(:c3)
          |> steps("x.x.")
        end)

      assert length(all_notes(score)) == 6
    end

    test "pick and synth on a part are the part's" do
      {chosen, part} = pick(part(), [:a, :b], 2)
      assert length(chosen) == 2
      assert %TuningFork.Part{} = synth(part, Voice.new())
    end
  end
end

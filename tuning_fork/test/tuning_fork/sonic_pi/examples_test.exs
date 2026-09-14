defmodule TuningFork.SonicPi.ExamplesTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Mixer, SonicPi, Store}
  alias TuningFork.Sample.Bank

  @rate 8_000
  @fixture Path.expand("../../fixtures/flac/stereo_lpc.flac", __DIR__)

  @samples ~w(perc_bell loop_amen bass_dnb_f bd_fat ambi_choir ambi_drone ambi_lunar_land
              ambi_piano drum_heavy_kick drum_snare_soft bd_haus loop_industrial loop_mika
              loop_compus bass_voxy_c bass_hit_c elec_plip guit_em9 bd_tek sn_dub loop_garzul
              ambi_soft_buzz ambi_swoosh)

  setup do
    Store.clear()
    Bank.clear()
    Enum.each(@samples, &Bank.put(&1, @fixture))
    on_exit(fn -> Bank.clear() end)
    :ok
  end

  defp sounds?(source) do
    pcm = SonicPi.render(source, @rate, 3.0)
    assert byte_size(pcm) == @rate * 3 * 4
    assert Mixer.peak(pcm) > 200, "silent"
    pcm
  end

  test "haunted" do
    sounds?("""
    live_loop :haunted do
      sample :perc_bell, rate: rrand(-1.5, 1.5)
      sleep rrand(0.1, 2)
    end
    """)
  end

  test "reich phase" do
    sounds?("""
    notes = ring([:E4, :Fs4, :B4, :Cs5, :D5, :Fs4, :E4, :Cs5, :B4, :Fs4, :D5, :Cs5])

    live_loop :slow do
      play tick(notes), release: 0.1
      sleep 0.3
    end

    live_loop :faster do
      play tick(notes), release: 0.1
      sleep 0.295
    end
    """)
  end

  test "ocean" do
    sounds?("""
    with_fx :reverb, mix: 0.5 do
      live_loop :oceans do
        s = synth choose([:bnoise, :cnoise, :gnoise]), amp: rrand(0.5, 1.5), attack: rrand(0, 4), sustain: rrand(0, 2), release: rrand(1, 5), cutoff_slide: rrand(0, 5), cutoff: rrand(60, 100), pan: rrand(-1, 1), pan_slide: rrand(1, 5)
        control s, pan: rrand(-1, 1), cutoff: rrand(60, 110)
        sleep rrand(2, 4)
      end
    end
    """)
  end

  test "jungle" do
    sounds?("""
    use_bpm 50

    with_fx :lpf, cutoff: 90 do
      with_fx :reverb, mix: 0.5 do
        with_fx :compressor, pre_amp: 40 do
          with_fx :distortion, distort: 0.4 do
            live_loop :jungle do
              use_random_seed 667
              times 4 do
                sample :loop_amen, beat_stretch: 1, rate: choose([1, 1, 1, -1]) / 2.0, finish: 0.5, amp: 0.5
                sample :loop_amen, beat_stretch: 1
                sleep 1
              end
            end
          end
        end
      end
    end
    """)
  end

  test "chord inversions" do
    sounds?("""
    Enum.each [1, 3, 6, 4], fn d ->
      Enum.each range(-3, 3), fn i ->
        play_chord chord_degree(d, :c, :major, 3, invert: i)
        sleep 0.25
      end
    end
    """)
  end

  test "filtered dnb" do
    sounds?("""
    use_sample_bpm :loop_amen

    with_fx :rlpf, [cutoff: 10, cutoff_slide: 4], fn c ->
      live_loop :dnb do
        sample :bass_dnb_f, amp: 5
        sample :loop_amen, amp: 5
        sleep 1
        control c, cutoff: rrand(40, 120), cutoff_slide: rrand(1, 4)
      end
    end
    """)
  end

  test "fm noise" do
    sounds?("""
    use_synth :fm

    live_loop :sci_fi do
      p = play choose(chord(:Eb3, :minor)) - choose([0, 12, -12]), divisor: 0.01, div_slide: rrand(0, 10), depth: rrand(0.001, 2), attack: 0.01, release: rrand(0, 5), amp: 0.5
      control p, divisor: rrand(0.001, 50)
      sleep choose([0.5, 1, 2])
    end
    """)
  end

  test "ambient experiment" do
    sounds?("""
    use_synth :hollow

    with_fx :reverb, mix: 0.7 do
      live_loop :note1 do
        play choose([:D4, :E4]), attack: 6, release: 6
        sleep 8
      end

      live_loop :note2 do
        play choose([:Fs4, :G4]), attack: 4, release: 5
        sleep 10
      end

      live_loop :note3 do
        play choose([:A4, :Cs5]), attack: 5, release: 5
        sleep 11
      end
    end
    """)
  end

  test "acid" do
    sounds?("""
    use_debug false
    load_sample :bd_fat

    times 8 do
      sample :bd_fat, amp: tick(line(0, 5, steps: 8))
      sleep 0.5
    end

    live_loop :drums do
      sample :bd_fat, amp: 5
      sleep 0.5
    end

    live_loop :acid do
      cue :foo

      times 4, fn i ->
        use_random_seed 667

        times 16 do
          use_synth :tb303
          play choose(chord(:e3, :minor)), attack: 0, release: 0.1, cutoff: rrand_i(50, 90) + i * 10
          sleep 0.125
        end
      end

      cue :bar

      times 32, fn i ->
        use_synth :tb303
        play choose(chord(:a3, :minor)), attack: 0, release: 0.05, cutoff: rrand_i(70, 98) + i, res: rrand(0.9, 0.95)
        sleep 0.125
      end

      cue :baz

      with_fx :reverb, [mix: 0.3], fn r ->
        times 32, fn m ->
          if rem(m, 8) == 0 and m != 0, do: control(r, mix: 0.3 + 0.5 * (m / 32.0))
          use_synth :prophet
          play choose(chord(:e3, :minor)), attack: 0, release: 0.08, cutoff: rrand_i(110, 130)
          sleep 0.125
        end
      end

      cue :quux

      in_thread do
        use_random_seed 668

        with_fx :echo, phase: 0.125 do
          times 16 do
            use_synth :tb303
            play choose(chord(:e3, :minor)), attack: 0, release: 0.1, cutoff: rrand(50, 100)
            sleep 0.25
          end
        end
      end

      sleep 4
    end
    """)
  end

  test "ambient" do
    sounds?("""
    load_samples sample_names(:ambi)
    sleep 2

    with_fx :reverb, mix: 0.8 do
      live_loop :foo do
        sp_name = choose sample_names(:ambi)
        sp_time = choose [1, 2]
        sp_rate = 1
        s = sample sp_name, cutoff: rrand(70, 130), rate: sp_rate * choose([0.5, 1]), pan: rrand(-1, 1), pan_slide: sp_time
        control s, pan: rrand(-1, 1)
        sleep sp_time
      end
    end
    """)
  end

  test "compus beats" do
    sounds?("""
    use_sample_bpm :loop_compus, num_beats: 4

    live_loop :loopr do
      unless one_in(10), do: sample(:loop_compus, rate: choose([0.5, 1, 1, 1, 1, 2]))
      sleep 4
    end

    live_loop :bass do
      if one_in(4), do: sample(:bass_voxy_c, amp: rrand(0.1, 0.2), rate: choose([0.5, 0.5, 1, 1, 2, 4]))
      use_synth :mod_pulse
      use_synth_defaults mod_invert_wave: 1
      play :C1, mod_range: 12, amp: rrand(0.5, 1), mod_phase: choose([0.25, 0.5, 1]), release: 1, cutoff: rrand(50, 90)
      play :C2, mod_range: choose([24, 36, 34]), amp: 0.35, mod_phase: 0.25, release: 2, cutoff: 60, pulse_width: rand()
      sleep 1
    end
    """)
  end

  test "echo drama" do
    sounds?("""
    use_synth :tb303
    use_bpm 45
    use_random_seed 3
    use_debug false

    with_fx :reverb do
      with_fx :echo, delay: 0.5, decay: 4 do
        live_loop :echoes do
          play choose(chord(choose([:b1, :b2, :e1, :e2, :b3, :e3]), :minor)), cutoff: rrand(40, 100), amp: 0.5, attack: 0, release: rrand(1, 2), cutoff_max: 110
          sleep choose([0.25, 0.5, 0.5, 0.5, 1, 1])
        end
      end
    end
    """)
  end

  test "idm breakbeat" do
    sounds?("""
    live_loop :idm_bb do
      n = choose [1, 2, 4, 8, 16]
      sample :drum_heavy_kick, amp: 2
      if one_in(8), do: sample(:ambi_drone, rate: choose([0.25, 0.5, 0.125, 1]), amp: 0.25)
      if one_in(8), do: sample(:ambi_lunar_land, rate: choose([0.5, 0.125, 1, -1, -0.5]), amp: 0.25)
      sample :loop_amen, attack: 0, release: 0.05, start: 1 - 1.0 / n, rate: choose([1, 1, 1, 1, 1, 1, -1])
      sleep sample_duration(:loop_amen) / n
    end
    """)
  end

  test "tron bike" do
    sounds?("""
    use_random_seed 10
    notes = ring [:b1, :b2, :e1, :e2, :b3, :e3]

    live_loop :tron do
      with_synth :dsaw do
        with_fx :slicer, phase: choose([0.25, 0.125]) do
          with_fx :reverb, room: 0.5, mix: 0.3 do
            n1 = choose chord(choose(notes), :minor)
            n2 = choose chord(choose(notes), :minor)
            p = play n1, amp: 2, release: 8, note_slide: 4, cutoff: 30, cutoff_slide: 4, detune: rrand(0, 0.2)
            control p, note: n2, cutoff: rrand(80, 120)
          end
        end
      end

      sleep 8
    end
    """)
  end

  test "wob rhyth" do
    sounds?("""
    use_debug false

    with_fx :reverb do
      live_loop :choral do
        r = choose ring([0.5, 1.0 / 3, 3.0 / 5])
        cue :choir, rate: r

        times 8 do
          sample :ambi_choir, rate: r, pan: rrand(-1, 1)
          sleep 0.5
        end
      end
    end

    live_loop :wub_wub do
      with_fx :wobble, phase: 2, reps: 16 do
        with_fx :echo, mix: 0.6 do
          sample :drum_heavy_kick
          sample :bass_hit_c, rate: 0.8, amp: 0.4
          sleep 1
        end
      end
    end
    """)
  end

  test "bach" do
    sounds?("""
    use_bpm 60
    use_synth_defaults release: 0.5, amp: 0.7, cutoff: 90
    use_synth :beep

    times 2 do
      in_thread do
        play_chord [55, 59]
        sleep 1
        play_pattern_timed [57], [0.5]
        play_pattern_timed [59], [1.5]
        play_pattern_timed [60], [1.5]
        play_pattern_timed [59], [1.5]
        play_pattern_timed [57], [1.5]
        play_pattern_timed [55], [1.5]
        play_pattern_timed [62, 59, 55], [0.5]
        play_pattern_timed [62], [0.5]
        play_pattern_timed [50, 60, 59, 57], [0.25]
      end

      play_pattern_timed [74], [0.5]
      play_pattern_timed [67, 69, 71, 72], [0.25]
      play_pattern_timed [74, 67, 67], [0.5]
      play_pattern_timed [76], [0.5]
      play_pattern_timed [72, 74, 76, 78], [0.25]
      play_pattern_timed [79, 67, 67], [0.5]
      play_pattern_timed [72], [0.5]
      play_pattern_timed [74, 72, 71, 69], [0.25]
      play_pattern_timed [71], [0.5]
      play_pattern_timed [72, 71, 69, 67], [0.25]
      play_pattern_timed [66], [0.5]
      play_pattern_timed [67, 69, 71, 67], [0.25]
      play_pattern_timed [71, 69], [0.5, 1]
    end
    """)
  end

  test "driving pulse" do
    sounds?("""
    load_sample :drum_heavy_kick

    live_loop :drums do
      sample :drum_heavy_kick, rate: 0.75
      sleep 0.5
      sample :drum_heavy_kick
      sleep 0.5
    end

    live_loop :synths do
      use_synth :mod_pulse
      use_synth_defaults amp: 1, mod_range: 15, cutoff: 80, pulse_width: 0.2, attack: 0.03, release: 0.6, mod_phase: 0.25, mod_invert_wave: 1
      play 30
      sleep 0.25
      play 38
      sleep 0.25
    end
    """)
  end

  test "lorezzed" do
    sounds?("""
    use_bpm 50
    notes = shuffle scale(:c1, :minor_pentatonic, num_octaves: 1)

    live_loop :lorezzed do
      with_fx :compressor, pan: -0.3, amp: 2 do
        tick_reset()
        t = 0.04
        sleep -t

        with_fx :lpf, cutoff: rrand(100, 130) do
          with_fx :krush, amp: 1.8 do
            s = synth :dsaw, note: :c3, sustain: 4, note_slide: t, release: 0

            times 7 do
              sleep 0.25
              control s, note: tick(notes)
            end
          end
        end

        sleep t
      end
    end

    with_fx :reverb, room: 1 do
      live_loop :synth_attack do
        tick()

        with_fx :compressor, amp: 1.5, pan: 0.3 do
          with_fx :lpf, cutoff: look(line(70, 131, steps: 32)) do
            times look([1, 1, 1, 1, 1, 1, 1, 4]) do
              with_fx :krush, reps: 4, amp: 3 do
                synth :fm, note: :c3, amp: 1, release: rrand(0.05, 0.3), pan: rrand(-0.5, 0.5)
                sleep choose([0.25, 0.125])
              end
            end
          end
        end
      end
    end

    with_fx :compressor do
      live_loop :industry do
        sample :loop_industrial, beat_stretch: 1, lpf: 110, rate: 1, amp: 3
        sleep 1
      end
    end

    with_fx :compressor do
      live_loop :drive do
        synth :fm, note: :c1, release: tick(knit(0.1, 8, 1, 8)), amp: 4, divisor: 1, depth: 1
        sample :bd_haus, amp: 5, lpf: 130, start: 0.14
        sleep 0.5
      end
    end

    live_loop :swirls do
      tick()
      sample :ambi_lunar_land, rate: look([-0.5, 0.5]), amp: rrand(1, 2.5)

      with_fx :compressor do
        with_fx :lpf, cutoff: look(range(100, 130, steps: 8)) do
          with_fx :krush, amp: 1.5 do
            synth :rodeo, note: chord(:c4, :minor7), release: 8, amp: 5
            synth :square, note: :c4, release: 4
          end
        end
      end

      sleep 16
    end
    """)
  end

  test "monday blues" do
    sounds?("""
    use_debug false
    load_samples [:drum_heavy_kick, :drum_snare_soft]

    live_loop :drums do
      puts "slow drums"

      times 6 do
        sample :drum_heavy_kick, rate: 0.8
        sleep 0.5
      end

      puts "fast drums"

      times 8 do
        sample :drum_heavy_kick, rate: 0.8
        sleep 0.125
      end
    end

    live_loop :synths, delay: 6 do
      puts "how does it feel?"
      use_synth :mod_saw
      use_synth_defaults amp: 0.5, attack: 0, sustain: 1, release: 0.25, mod_range: 12, mod_phase: 0.5, mod_invert_wave: 1
      notes = ring [:F, :C, :D, :D, :G, :C, :D, :D]

      Enum.each notes, fn n ->
        tick()
        play note(n, octave: 1), cutoff: look(line(90, 130, steps: 16))
        play note(n, octave: 2), cutoff: look(line(90, 130, steps: 32))
        sleep 1
      end
    end

    live_loop :snare, delay: 12.5 do
      sample :drum_snare_soft
      sleep 1
    end
    """)
  end

  test "rerezzed" do
    sounds?("""
    use_debug false
    notes = shuffle scale(:e1, :minor_pentatonic, num_octaves: 2)

    live_loop :rerezzed do
      tick_reset()
      t = 0.04
      sleep -t

      with_fx :bitcrusher do
        s = synth :dsaw, note: :e3, sustain: 8, note_slide: t, release: 0

        times 64 do
          sleep 0.125
          control s, note: tick(notes)
        end
      end

      sleep t
    end

    live_loop :industry do
      sample :loop_industrial, beat_stretch: 1
      sleep 1
    end

    live_loop :drive do
      sample :bd_haus, amp: 3
      sleep 0.5
    end
    """)
  end

  test "square skit" do
    sounds?("""
    use_debug false

    live_loop :skit do
      with_fx :slicer, phase: 1, invert_wave: 1, wave: 0 do
        with_fx :slicer, wave: 0, phase: 0.25 do
          sample :loop_mika, rate: 1, amp: 2
        end

        sleep 8
      end
    end

    live_loop :foo, auto_cue: false do
      if factor?(tick(), 4), do: tick(:note)
      use_synth :square

      density 2 do
        play look(knit(:c2, 2, :e1, 1, :f3, 1), :note), release: 0, attack: 0.25, amp: 1, cutoff: rrand_i(70, 130)
        sleep 0.5
      end
    end

    live_loop :kik, auto_cue: false do
      density 1 do
        sample :bd_haus, amp: 2
        sleep 0.5
      end
    end

    live_loop :piano, auto_cue: false do
      sleep 4

      with_fx :slicer, phase: 0.25, wave: 1 do
        sleep 4
        sample :ambi_piano, amp: 2
      end
    end
    """)
  end

  test "blimp zones" do
    sounds?("""
    use_debug false
    use_random_seed 667
    load_sample :ambi_lunar_land
    sleep 1

    live_loop :foo do
      with_fx :reverb, kill_delay: 0.2, room: 0.3 do
        times 4 do
          use_random_seed 4000

          times 8 do
            sleep 0.25
            play choose(chord(:e3, :m7)), release: 0.1, pan: rrand(-1, 1, res: 0.9), amp: 1
          end
        end
      end
    end

    live_loop :bar, auto_cue: false do
      if rand() < 0.25 do
        sample :ambi_lunar_land
        puts :comet_landing
      end

      sleep 8
    end

    live_loop :baz, auto_cue: false do
      tick()
      sleep 0.25
      cue :beat, count: look()
      sample :bd_haus, amp: if(factor?(look(), 8), do: 3, else: 2)
      sleep 0.25
      use_synth :fm
      if factor?(look(), 4), do: play(:e2, release: 1, amp: 1)
      synth :noise, release: 0.051, amp: 0.5
    end
    """)
  end

  test "blip rhythm" do
    sounds?("""
    load_samples [:drum_heavy_kick, :elec_plip, :elec_blip]
    use_bpm 100
    use_random_seed 100

    with_fx :reverb, mix: 0.6, room: 0.8 do
      with_fx :echo, room: 0.8, decay: 8, phase: 1, mix: 0.4 do
        live_loop :blip do
          n = choose [:e2, :e2, :a3]

          with_synth :dsaw do
            with_transpose -12 do
              in_thread do
                times 2 do
                  play n, attack: 0.6, release: 0.8, detune: rrand(0, 0.1), cutoff: rrand(80, 120)
                  sleep 3
                end
              end
            end
          end

          sleep 4

          with_synth :tri do
            play chord(n, :m7), amp: 5, release: 0.8
          end

          sleep 2
        end
      end
    end

    with_fx :echo, room: 0.8, decay: 8, phase: 0.25, mix: 0.4 do
      live_loop :rhythm do
        sample :drum_heavy_kick, amp: 0.5
        sample :elec_plip, rate: choose([0.5, 2, 1, 4]) * choose([1, 2, 3, 10]), amp: 0.6
        sleep 2
      end
    end
    """)
  end

  test "shufflit" do
    sounds?("""
    use_debug false
    use_random_seed 667
    load_sample :ambi_lunar_land
    sleep 1

    live_loop :travelling do
      use_synth :beep
      notes = scale(:e3, :minor_pentatonic, num_octaves: 1)
      use_random_seed 679
      tick_reset_all()

      with_fx :echo, phase: 0.125, mix: 0.4, reps: 16 do
        sleep 0.25
        play choose(notes), attack: 0, release: 0.1, pan: tick(range(-1, 1, step: 0.125)), amp: rrand(2, 2.5)
      end
    end

    live_loop :comet, auto_cue: false do
      if one_in(4) do
        sample :ambi_lunar_land
        puts :comet_landing
      end

      sleep 8
    end

    live_loop :shuff, auto_cue: false do
      with_fx :hpf, cutoff: 10, reps: 8 do
        tick()
        sleep 0.25
        sample :bd_tek, amp: if(factor?(look(), 8), do: 6, else: 4)
        sleep 0.25
        use_synth :tb303
        use_synth_defaults cutoff_attack: 1, cutoff_release: 0, env_curve: 2
        if factor?(look(), 2), do: play(look(knit(:e2, 24, :c2, 8)), release: 1.5, cutoff: look(range(70, 90)), amp: 2)
        sample :sn_dub, rate: -1, sustain: 0, release: look(knit(0.05, 3, 0.5, 1))
      end
    end
    """)
  end

  test "tilburg 2" do
    sounds?("""
    use_debug false
    load_samples [:guit_em9, :bd_haus]

    live_loop :low do
      tick()
      synth :zawa, wave: 1, phase: 0.25, release: 5, note: look(knit(:e1, 12, :c1, 4)), cutoff: look(line(60, 120, steps: 6))
      sleep 4
    end

    with_fx :reverb, room: 1 do
      live_loop :lands, auto_cue: false do
        use_synth :dsaw
        use_random_seed 310003
        ns = Enum.take(scale(:e2, :minor_pentatonic, num_octaves: 4), 4)

        times 16 do
          play choose(ns), detune: 12, release: 0.1, amp: 2, cutoff: rrand(70, 120)
          sleep 0.125
        end
      end
    end

    live_loop :fietsen do
      sleep 0.25
      sample :guit_em9, rate: -1
      sleep 7.75
    end

    live_loop :tijd do
      sample :bd_haus, amp: 2.5, cutoff: 100
      sleep 0.5
    end

    live_loop :ind do
      sample :loop_industrial, beat_stretch: 1
      sleep 1
    end
    """)
  end

  test "time machine" do
    sounds?("""
    use_debug false

    live_loop :time do
      synth :tb303, release: 8, note: :e1, cutoff: tick(range(90, 60, -10))
      sleep 8
    end

    live_loop :machine do
      sample :loop_garzul, rate: tick(knit(1, 3, -1, 1))
      sleep 8
    end

    live_loop :vortex, auto_cue: false do
      use_synth choose([:pulse, :beep])
      sleep 0.125 / 2
      play tick(scale(:e1, :minor_pentatonic)), attack: 0.125, release: 0, amp: 2, cutoff: look(ring([70, 90, 100, 130]))
      sleep 0.125 / 2
    end

    live_loop :moon_bass, auto_cue: false do
      sample :bd_haus, amp: 1.5
      sleep 0.5
    end
    """)
  end
end

defmodule TuningFork.SonicPi.MoreExamplesTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Mixer, SonicPi, Store}
  alias TuningFork.Sample.Bank

  @rate 8_000
  @fixture Path.expand("../../fixtures/flac/stereo_lpc.flac", __DIR__)

  @samples ~w(bd_tek drum_snare_hard drum_cymbal_closed drum_splash_soft vinyl_hiss sn_dub bd_haus
              elec_blip ambi_lunar_land bass_trance_c drum_heavy_kick)

  setup do
    Store.clear()
    Bank.clear()
    Enum.each(@samples, &Bank.put(&1, @fixture))
    on_exit(fn -> Bank.clear() end)
    :ok
  end

  defp sounds?(source, seconds \\ 3.0) do
    pcm = SonicPi.render(source, @rate, seconds)
    assert byte_size(pcm) == trunc(@rate * seconds) * 4
    assert Mixer.peak(pcm) > 200, "silent"
    pcm
  end

  test "blockgame" do
    sounds?(
      """
      use_bpm 130

      live_loop :met1 do
        sleep 1
      end

      cmaster1 = 130
      cmaster2 = 130
      pattern = fn pattern -> tick(String.graphemes(pattern)) == "x" end

      live_loop :kick, sync: :met1 do
        a = 1.5
        if pattern.("x--x--x---x--x--"), do: sample(:bd_tek, amp: a, cutoff: cmaster1)
        sleep 0.25
      end

      with_fx :echo, mix: 0.2 do
        with_fx :reverb, mix: 0.2, room: 0.5 do
          live_loop :clap, sync: :met1 do
            a = 0.75
            sleep 1
            sample :drum_snare_hard, rate: 2.5, cutoff: cmaster1, amp: a
            sample :drum_snare_hard, rate: 2.2, start: 0.02, cutoff: cmaster1, pan: 0.2, amp: a
            sample :drum_snare_hard, rate: 2, start: 0.04, cutoff: cmaster1, pan: -0.2, amp: a
            sleep 1
          end
        end
      end

      with_fx :reverb, mix: 0.2 do
        with_fx :panslicer, mix: 0.2 do
          live_loop :hhc1, sync: :met1 do
            a = 0.75
            p = choose [-0.3, 0.3]
            if pattern.("x-x-x-x-x-x-x-x-xxx-x-x-x-x-x-x-"), do: sample(:drum_cymbal_closed, amp: a, rate: 2.5, finish: 0.5, pan: p, cutoff: cmaster2)
            sleep 0.125
          end
        end
      end

      live_loop :hhc2, sync: :met1 do
        a = 1.25
        sleep 0.5
        sample :drum_cymbal_closed, cutoff: cmaster2, rate: 1.2, start: 0.01, finish: 0.5, amp: a
        sleep 0.5
      end

      with_fx :reverb, mix: 0.7 do
        live_loop :crash, sync: :met1 do
          a = 0.1
          c = cmaster2 - 10
          r = 1.5
          f = 0.25
          crash = :drum_splash_soft
          sleep 14.5
          sample crash, amp: a, cutoff: c, rate: r, finish: f
          sample crash, amp: a, cutoff: c, rate: r - 0.2, finish: f
          sleep 1
          sample crash, amp: a, cutoff: c, rate: r, finish: f
          sample crash, amp: a, cutoff: c, rate: r - 0.2, finish: f
          sleep 0.5
        end
      end

      with_fx :reverb, mix: 0.7 do
        live_loop :arp, sync: :met1 do
          with_fx :echo, phase: 1, mix: tick(mirror(line(0.1, 1, steps: 128))) do
            a = 0.6
            r = 0.25
            c = 130
            p = tick(mirror(line(-0.7, 0.7, steps: 64)))
            at = 0.01
            use_synth :beep
            tick()
            notes = shuffle scale(:g4, :major_pentatonic)
            play look(notes), amp: a, release: r, cutoff: c, pan: p, attack: at
            sleep 0.75
          end
        end
      end

      with_fx :panslicer, mix: 0.4 do
        with_fx :reverb, mix: 0.75 do
          live_loop :synthbass, sync: :met1 do
            c = 60
            a = 0.75
            at = 0
            use_synth :tech_saws
            play :g3, sustain: 6, cutoff: c, amp: a, attack: at
            sleep 6
            play :d3, sustain: 2, cutoff: c, amp: a, attack: at
            sleep 2
            play :e3, sustain: 8, cutoff: c, amp: a, attack: at
            sleep 8
          end
        end
      end
      """,
      4.0
    )
  end

  test "cloud beat" do
    sounds?("""
    use_bpm 100

    live_loop :hiss_loop do
      sample :vinyl_hiss, amp: 2
      sleep sample_duration(:vinyl_hiss)
    end

    hihat = fn ->
      use_synth :pnoise

      with_fx :hpf, cutoff: 120 do
        play 60, release: 0.01, amp: 13
      end
    end

    live_loop :hihat_loop do
      divisors = ring [2, 4, 2, 2, 2, 2, 2, 6]

      times tick(divisors) do
        hihat.()
        sleep 1.0 / look(divisors)
      end
    end

    live_loop :snare_loop do
      sleep ring_at([2.5, 3], tick())

      with_fx :lpf, cutoff: 100 do
        sample :sn_dub, sustain: 0, release: 0.05, amp: 3
      end

      sleep ring_at([1.5, 1], look())
    end

    bassdrum = fn note1, duration, note2 ->
      use_synth :sine

      with_fx :hpf, cutoff: 100 do
        play note1 + 24, amp: 40, release: 0.01
      end

      with_fx :distortion, distort: 0.1, mix: 0.3 do
        with_fx :lpf, cutoff: 26 do
          with_fx :hpf, cutoff: 55 do
            bass = play note1, amp: 85, release: duration, note_slide: duration
            control bass, note: note2
          end
        end
      end

      sleep duration
    end

    live_loop :bassdrum_schleife do
      bassdrum.(36, 1.5, 36)

      if ring_at(bools(0, 0, 0, 0, 0, 0, 0, 0), tick()) do
        bassdrum.(36, 0.5, 40)
        bassdrum.(38, 1, 10)
      else
        bassdrum.(36, 1.5, 36)
      end

      bassdrum.(36, 1.0, ring_at([10, 10, 10, 40], look()))
    end

    chord_1 = chord :c4, :maj9, num_octaves: 2
    chord_2 = chord :eb4, :maj9, num_octaves: 2
    chord_3 = chord :b3, :maj9, num_octaves: 2
    chord_4 = chord :d4, :maj9, num_octaves: 2
    chord_low_1 = chord :c2, :maj9
    chord_low_2 = chord :eb2, :maj9
    chord_low_3 = chord :b1, :maj9
    chord_low_4 = chord :d2, :maj9

    chord_player = fn the_chord ->
      use_synth :blade

      Enum.each the_chord, fn note ->
        play note, attack: rand(4), release: rand(6..8), cutoff: rand(50..85), vib: rrand(0.01, 2), amp: 0.55
      end
    end

    with_fx :reverb, room: 0.99, mix: 0.7 do
      live_loop :chord_loop do
        chord_high = tick(knit(chord_1, 2, chord_2, 2, chord_3, 4, chord_4, 4))
        chord_low = look(knit(chord_low_1, 2, chord_low_2, 2, chord_low_3, 4, chord_low_4, 4))
        chord_player.(pick(chord_high, 6))
        chord_player.(Enum.take(chord_low, 3))
        sleep 8
      end
    end
    """)
  end

  test "sonic dreams" do
    sounds?(
      """
      use_debug false
      load_samples [:bd_haus, :elec_blip, :ambi_lunar_land]

      ocean = fn num, amp_mul ->
        times num do
          s = synth choose([:bnoise, :cnoise, :gnoise]), amp: rrand(0.5, 1.5) * amp_mul, attack: rrand(0, 1), sustain: rrand(0, 2), release: rrand(0, 5) + 0.5, cutoff_slide: rrand(0, 5), cutoff: rrand(60, 100), pan: rrand(-1, 1), pan_slide: 1
          control s, pan: rrand(-1, 1), cutoff: rrand(60, 110)
          sleep rrand(0.5, 4)
        end
      end

      echoes = fn num, tonics, co, res, amp ->
        times num do
          play choose(chord(choose(tonics), :minor)), res: res, cutoff: rrand(co - 20, co + 20), amp: 0.5 * amp, attack: 0, release: rrand(0.5, 1.5), pan: rrand(-0.7, 0.7)
          sleep choose([0.25, 0.5, 0.5, 0.5, 1, 1])
        end
      end

      bd = fn ->
        cue :in_relentless_cycles

        times 16 do
          sample :bd_haus, amp: 4, cutoff: 100
          sleep 0.5
        end

        cue :winding_everywhichway

        times 2 do
          times 2 do
            sample :bd_haus, amp: 4, cutoff: 100
            sleep 0.25
          end

          sample :ambi_lunar_land
          sleep 0.25
        end
      end

      drums = fn level, b_level, rand_cf ->
        synth :fm, note: :e2, release: 0.1, amp: b_level * 3, cutoff: 130
        co = if rand_cf, do: rrand(110, 130), else: 130
        a = if rand_cf, do: rrand(0.3, 0.5), else: 0.6
        if level > 0, do: synth(:noise, release: 0.05, cutoff: co, res: 0.95, amp: a)
        if level > 1, do: sample(:elec_blip, amp: 2, rate: 2, pan: rrand(-0.8, 0.8))
        sleep 1
      end

      synths = fn s_name, co, n ->
        use_synth s_name
        use_transpose 0
        use_synth_defaults detune: choose([12, 24]), amp: 1, cutoff: co, pulse_width: 0.12, attack: rrand(0.2, 0.5), release: 0.5, mod_phase: 0.25, mod_invert_wave: 1
        play :e1, mod_range: choose([7, 12]), pan: rrand(-1, 1)
        sleep 0.125
        play :e3, mod_range: choose([7, 12]), pan: rrand(-1, 1)
        sleep choose([0.25, 0.5])
        play n, mod_range: 12, pan: rrand(-1, 1)
        sleep 0.5
        play choose(chord(:e2, :minor)), mod_range: 12, pan: rrand(-1, 1)
        sleep 0.25
      end

      play_synths = fn ->
        with_fx :reverb do
          with_fx :echo, phase: 0.25 do
            synth_names = [:mod_pulse, :mod_saw, :mod_dsaw, :mod_dsaw, :mod_dsaw, :mod_dsaw]
            cutoffs = [108, 78, 88, 98]

            times 4, fn t ->
              co = ring_at(cutoffs, t + 1) + t * 2
              times 7 do
                n = choose chord(ring_at([:e2, :e3, :e4, :e5], t), :minor)
                synths.(ring_at(synth_names, t + 1), co, n)
              end
              sleep 2
            end

            sleep 1
            cue :within
          end
        end
      end

      puts "Introduction"
      sleep 2
      cue :oceans

      at [7, 12], [:crash, :within_oceans], fn m -> cue m end

      uncomment do
        use_random_seed 1000

        with_bpm 45 do
          with_fx :reverb do
            with_fx :echo, delay: 0.5, decay: 4 do
              in_thread do
                use_random_seed 2
                ocean.(5, 1)
                ocean.(1, 0.5)
                ocean.(1, 0.25)
              end

              sleep 10
              use_random_seed 1200
              echoes.(5, [:b1, :b2, :e1, :e2, :b3, :e3], 100, 0.9, 1)
              cue :a_distant_object
              echoes.(5, [:b1, :e1, :e2, :e3], 100, 0.9, 1)
              cue :breathes_time
              in_thread do
                echoes.(5, [:e1, :e2, :e3], 100, 0.9, 1)
              end
              use_synth :tb303
              echoes.(1, [:e1, :e2, :e3], 60, 0.9, 0.5)
              echoes.(1, [:e1, :e2, :e3], 62, 0.9, 1)
              echoes.(1, [:e1, :e2, :e3], 64, 0.97, 1)
              cue :liminality_holds_fast
              echoes.(4, [:b1, :e1, :e2, :b3, :e3], 80, 0.9, 1)
              cue :within_reach
              echoes.(5, [:e1, :b2], 90, 0.9, 1)
            end
          end
        end
      end

      in_thread name: :bassdrums do
        use_random_seed 0
        sleep 22
        times 3, fn _ -> bd.() end
        sleep 28
        live_loop :bd do
          bd.()
        end
      end

      in_thread name: :drums do
        use_random_seed 0
        with_fx :echo do
          sleep 2
          drums.(-1, 0.1, false)
          drums.(-1, 0.2, false)
          drums.(-1, 0.4, false)
          drums.(-1, 0.7, false)

          Enum.each -1..1, fn level ->
            times 8, fn _ -> drums.(level, 0.8, false) end
            times 6, fn _ -> drums.(level, 1, false) end
            sleep 1
          end

          sleep 4
          cue :dreams
          times 8, fn _ -> drums.(1, 1, true) end

          live_loop :drums do
            times 8, fn _ -> drums.(1, 1, false) end
            times 16, fn i ->
              at 1, fn -> cue(String.to_atom(String.duplicate("x", i + 1))) end
              drums.(2, 1, false)
            end
          end
        end
      end

      in_thread name: :synths do
        use_random_seed 0
        sleep 12
        cue :the_flow_of_logic
        play_synths.()
      end

      in_thread do
        use_random_seed 0
        sync :within
        sleep 12
        use_synth_defaults phase: 0.5, res: 0.5, cutoff: 80, release: 3.3, wave: 1

        times 2 do
          Enum.each [80, 90, 100, 110], fn cf ->
            use_merged_synth_defaults cutoff: cf
            synth :zawa, note: :e2, phase: 0.25
            synth :zawa, note: :a1
            sleep 3
          end

          times 4, fn t ->
            synth :zawa, note: :e2, phase: 0.25, res: rrand(0.8, 0.9), cutoff: ring_at([100, 105, 110, 115], t)
            sleep 3
          end
        end
      end
      """,
      2.0
    )
  end

  test "crushed" do
    sounds?("""
    with_fx :bitcrusher do
      loop do
        use_synth :mod_fm
        play 50 + choose([5, 0]), mod_phase: 0.25, release: 1, mod_range: choose([24, 27, 12])
        sleep 0.5
        use_synth :mod_dsaw
        play 50, mod_phase: 0.25, release: 1.5, mod_range: choose([24, 27]), attack: 0.5
        sleep 1.5
      end
    end
    """)
  end

  test "dark neon" do
    sounds?("""
    live_loop :foo do
      sample :bd_haus, amp: 5, cutoff: 50, release: 0.1
      sleep 0.5
    end

    live_loop :mel do
      with_fx :wobble, phase: 1, invert_wave: 1, wave: 0, cutoff_max: 80, cutoff_min: 60 do
        synth :blade, note: :cs1, release: 4, cutoff: 110, amp: 1, pitch_shift: 0
      end

      with_fx :reverb, room: 1 do
        with_fx :bitcrusher, mix: 0.4 do
          sample :bass_trance_c, rate: 0.5, pitch: 0, window_size: 0.125, time_dis: 0.125, amp: 8, release: 0.2
        end
      end

      sleep 4
    end
    """)
  end

  test "mod 303 phade" do
    sounds?("""
    use_synth :tb303

    live_loop :foo do
      sleep 0.5
    end

    with_fx :reverb do
      with_fx :slicer, phase: 0.5, wave: 0, invert_wave: 1 do
        play 50 - 24, cutoff: 120, cutoff_attack: 0.3, res: 0.93, release: 60
      end
    end
    """)
  end

  test "orchard improv" do
    sounds?("""
    pent = [:Cs2, :Ds2, :Fs2, :Gs2, :As2, :B2, :Cs3, :Ds3, :Fs3, :Gs3, :As3, :B3, :Cs4, :Ds4, :Fs4, :Gs4, :As4, :B4, :Cs5, :Ds5, :Fs5, :Gs5, :As5, :B5, :Cs6, :Ds6, :Fs6, :Gs6, :As6]
    use_synth :tri

    with_fx :reverb, rate: 0.2 do
      t = 0.28
      count = length(pent)

      Enum.reduce 1..20, {15, []}, fn _pass, {i, stack} ->
        mode = rrand_i(0, 2)
        lene = rrand_i(0, 4) * 2

        if mode == 2 and lene > 0 do
          tp = t * 4 / lene
          direction = cond do
            lene + i >= count -> -1
            i - lene <= 0 -> 1
            true -> rrand_i(0, 1) * 2 - 1
          end

          {i, local} =
            Enum.reduce 1..lene, {i, []}, fn _step, {i, local} ->
              notes = [i]
              notes = if rrand_i(0, 3) == 1 and i + 4 < count, do: [i + 4 | notes], else: notes
              notes = if rrand_i(0, 3) == 1 and i - 4 >= 0, do: [i - 4 | notes], else: notes
              Enum.each notes, fn note -> play Enum.at(pent, note) end
              sleep tp
              {abs(i + direction), [{notes, tp} | local]}
            end

          {i, [Enum.reverse(local) | stack]}
        else
          transp = rrand_i(0, 4) - 2

          case stack do
            [last | _] ->
              Enum.each last, fn {notes, tp} ->
                Enum.each notes, fn note ->
                  if note + transp >= 0 and note + transp < count, do: play(Enum.at(pent, note + transp))
                end
                sleep tp
              end

            [] ->
              :ok
          end

          {i, stack}
        end
      end
    end
    """)
  end

  test "syncer" do
    sounds?("""
    in_thread do
      loop do
        cue :tick
        sleep 1
      end
    end

    in_thread do
      loop do
        sync :tick
        sample :drum_heavy_kick
        sleep 1
      end
    end

    in_thread do
      use_synth :mod_saw

      loop do
        sync :tick
        play choose(chord(:e1, :minor)), mod_phase: choose([1, 0.5, 0.25, 0.125]), cutoff: rrand(80, 110)
        sleep 1
      end
    end
    """)
  end
end

defmodule TuningFork.SonicPi.SiteExamplesTest do
  use ExUnit.Case, async: false

  use TuningFork.SonicPi

  alias TuningFork.{Mixer, SonicPi, Store}
  alias TuningFork.Sample.Bank

  @rate 8_000
  @fixture Path.expand("../../fixtures/flac/stereo_lpc.flac", __DIR__)

  @samples ~w(perc_bell ambi_choir drum_heavy_kick bass_hit_c ambi_drone ambi_lunar_land loop_amen
              drum_bass_hard elec_cymbal)

  setup do
    Store.clear()
    Bank.clear()
    Enum.each(@samples, &Bank.put(&1, @fixture))
    on_exit(fn -> Bank.clear() end)
    :ok
  end

  defp sounds?(%SonicPi.Buffer{} = buffer) do
    pcm = SonicPi.render(buffer, @rate, 3.0)
    assert byte_size(pcm) == @rate * 3 * 4
    assert Mixer.peak(pcm) > 200, "silent"
  end

  test "haunted bells" do
    sounds?(
      buffer do
        live_loop :bells do
          sample(:perc_bell, rate: rrand(0.125, 1.5))
          sleep(rrand(0, 2))
        end
      end
    )
  end

  test "pentatonic bleeps" do
    sounds?(
      buffer do
        with_fx :reverb, mix: 0.2 do
          live_loop :bleeps do
            play(choose(scale(:Eb2, :major_pentatonic, num_octaves: 3)),
              release: 0.1,
              amp: rand()
            )

            sleep(0.1)
          end
        end
      end
    )
  end

  test "tron bikes" do
    sounds?(
      buffer do
        live_loop :bikes do
          with_synth :dsaw do
            with_fx :slicer, phase: choose([0.25, 0.125]) do
              with_fx :reverb, room: 0.5, mix: 0.3 do
                start_note = choose(chord(choose([:b1, :b2, :e1, :e2, :b3, :e3]), :minor))
                final_note = choose(chord(choose([:b1, :b2, :e1, :e2, :b3, :e3]), :minor))

                p =
                  play(start_note,
                    release: 8,
                    note_slide: 4,
                    cutoff: 30,
                    cutoff_slide: 4,
                    detune: rrand(0, 0.2),
                    pan: rrand(-1, 0),
                    pan_slide: rrand(4, 8)
                  )

                control(p, note: final_note, cutoff: rrand(80, 120), pan: rrand(0, 1))
              end
            end
          end

          sleep(8)
        end
      end
    )
  end

  test "wob rhythm" do
    sounds?(
      buffer do
        with_fx :reverb do
          in_thread do
            live_loop :choir do
              r = choose([0.5, 1.0 / 3, 3.0 / 5])

              times 8 do
                sample(:ambi_choir, rate: r, pan: rrand(-1, 1))
                sleep(0.5)
              end
            end
          end
        end

        with_fx :wobble, phase: 2 do
          with_fx :echo, mix: 0.6 do
            live_loop :wub do
              sample(:drum_heavy_kick)
              sample(:bass_hit_c, rate: 0.8, amp: 0.4)
              sleep(1)
            end
          end
        end
      end
    )
  end

  test "ocean waves" do
    sounds?(
      buffer do
        with_fx :reverb, mix: 0.5 do
          live_loop :waves do
            s =
              synth(choose([:bnoise, :cnoise, :gnoise]),
                amp: rrand(0.5, 1.5),
                attack: rrand(0, 4),
                sustain: rrand(0, 2),
                release: rrand(1, 3),
                cutoff_slide: rrand(0, 3),
                cutoff: rrand(60, 80),
                pan: rrand(-1, 1),
                pan_slide: 1
              )

            control(s, pan: rrand(-1, 1), cutoff: rrand(60, 115))
            sleep(rrand(2, 3))
          end
        end
      end
    )
  end

  test "idm breakbeat" do
    sounds?(
      buffer do
        play_bb = fn n ->
          sample(:drum_heavy_kick)

          if rand() < 0.125,
            do: sample(:ambi_drone, rate: choose([0.25, 0.5, 0.125, 1]), amp: 0.25)

          if rand() < 0.125,
            do: sample(:ambi_lunar_land, rate: choose([0.5, 0.125, 1, -1, -0.5]), amp: 0.25)

          sample(:loop_amen,
            attack: 0,
            release: 0.05,
            start: 1 - 1.0 / n,
            rate: choose([1, 1, 1, 1, 1, 1, -1])
          )

          sleep(sample_duration(:loop_amen) / n)
        end

        live_loop :breaks do
          play_bb.(choose([1, 2, 4, 8, 16]))
        end
      end
    )
  end

  test "acid walk" do
    sounds?(
      buffer do
        in_thread do
          use_synth(:fm)
          sleep(2)

          live_loop :drums do
            times 28 do
              sample(:drum_bass_hard, amp: 0.8)
              sleep(0.25)
              play(:e2, release: 0.2)
              sample(:elec_cymbal, rate: 12, amp: 0.6)
              sleep(0.25)
            end

            sleep(4)
          end
        end

        use_synth(:tb303)

        with_fx(:reverb, [], fn rev ->
          live_loop :acid do
            control(rev, mix: rrand(0, 0.3))

            with_fx :slicer, phase: 0.125 do
              sample(:ambi_lunar_land, sustain: 0, release: 8, amp: 2)
            end

            control(rev, mix: rrand(0, 0.6))
            r = rrand(0.05, 0.3)

            times 64 do
              play(choose(chord(:e3, :minor)), release: r, cutoff: rrand(50, 90), amp: 0.5)
              sleep(0.125)
            end

            control(rev, mix: rrand(0, 0.6))
            r = rrand(0.1, 0.2)

            with_synth :prophet do
              times 32 do
                sleep(0.125)
                play(choose(chord(:a3, :m7)), release: r, cutoff: rrand(40, 130), amp: 0.7)
              end
            end

            control(rev, mix: rrand(0, 0.6))
            r = rrand(0.05, 0.3)

            times 32 do
              play(choose(chord(:e3, :minor)), release: r, cutoff: rrand(110, 130), amp: 0.4)
              sleep(0.125)
            end

            control(rev, mix: rrand(0, 0.6))

            with_fx :echo, phase: 0.25, decay: 8 do
              times 16 do
                play(choose(chord(choose([:e2, :e3, :e4]), :m7)),
                  release: 0.05,
                  cutoff: rrand(50, 129),
                  amp: 0.5
                )

                sleep(0.125)
              end
            end
          end
        end)
      end
    )
  end
end

use TuningFork.SonicPi

alias TuningFork.SonicPi

{:ok, buffer} =
  SonicPi.capture(fn ->
    use_bpm(120)

    live_loop :bass do
      use_synth(:tb303)
      play(:e2, release: 0.3, cutoff: rrand(60, 100), res: 0.8)
      sleep(0.5)
      play(:e2, release: 0.2, cutoff: 70, res: 0.8)
      sleep(0.5)
    end

    live_loop :arp do
      use_synth(:prophet)

      with_fx :reverb, mix: 0.3 do
        play(choose(chord(:e3, :minor7)), release: 0.2, amp: 0.6)
        sleep(0.25)
      end
    end
  end)

pcm = SonicPi.render(buffer, 44_100, 8.0)

path = Path.join(System.tmp_dir!(), "tuning_fork_sonic_pi.wav")
TuningFork.Wav.write!(path, pcm, rate: 44_100, channels: 2)
IO.puts("wrote #{path}")

import TuningFork.Pattern
import TuningFork.Pattern.Control

alias TuningFork.Pattern.Player
alias TuningFork.Wav

pattern =
  stack([
    s("bd*4") |> gain(0.9),
    s("hh*8") |> gain(0.4) |> pan(sine()),
    n("<0 4 0 9 7>*16") |> scale("g:minor") |> transpose(-12) |> shape(:saw) |> cutoff(300) |> resonance(9),
    chord("<Bbm9 Fm9>/4") |> dict("ireal") |> voicing() |> s("gm_epiano1") |> room(0.4)
  ])

pcm = Player.render(pattern, 44_100, cycles: 8, cps: 0.5)

path = Path.join(System.tmp_dir!(), "tuning_fork_pattern.wav")
Wav.write!(path, pcm, rate: 44_100, channels: 2)
IO.puts("wrote #{path} (#{Float.round(Wav.duration(pcm), 2)} s)")

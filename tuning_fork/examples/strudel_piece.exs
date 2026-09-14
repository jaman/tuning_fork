alias TuningFork.Strudel
alias TuningFork.Pattern.Player

js = """
setcps(.5)
let chords = chord("<Bbm9 Fm9>/4").dict('ireal')
$: s("bd*2, hh*4, ~ sd").gain(.8)
$: chords.voicing().s("gm_epiano1").room(.3)
$: n("<0 2 4 7>*4").set(chords).voicing().s("gm_acoustic_bass")
"""

{:ok, rows} = Strudel.to_rows(js)
IO.puts("as this library's rows:\n" <> Enum.join(rows, "\n") <> "\n")

{:ok, pattern} = Strudel.pattern(js)
pcm = Player.render(pattern, 44_100, cycles: 8, cps: 0.5)

path = Path.join(System.tmp_dir!(), "tuning_fork_strudel.wav")
TuningFork.Wav.write!(path, pcm, rate: 44_100, channels: 2)
IO.puts("wrote #{path}")

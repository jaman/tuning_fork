import TuningFork.Part

alias TuningFork.{Kit, Score, Voice, Wav}

bass =
  part(bpm: 112, synth: Voice.new(shape: :saw, cutoff: 0.2, gain: 0.5), pan: -0.3)
  |> play(:d2, 1.5)
  |> play(:d2, 1.5)
  |> play(:a2, 0.5)
  |> play(:d3, 0.5)

chords =
  part(bpm: 112, synth: Voice.new(shape: :triangle, gain: 0.3), pan: 0.3)
  |> chord([:d4, :f4, :a4], 2)
  |> chord([:c4, :e4, :g4], 2)

drums = part(bpm: 112, synth: Kit.voice("bd", 0.25)) |> steps("x..x..x.")

pcm =
  [bass, chords, drums]
  |> Score.from_parts(beats: 4)
  |> Score.render(44_100)

path = Path.join(System.tmp_dir!(), "tuning_fork_example.wav")
Wav.write!(path, pcm, rate: 44_100, channels: 2)
IO.puts("wrote #{path} (#{Float.round(Wav.duration(pcm), 2)} s)")

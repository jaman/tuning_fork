import TuningFork.Part

alias TuningFork.{Midi, Score, Voice}

melody =
  part(bpm: 100, synth: Voice.new(shape: :triangle))
  |> play(:c4, 1)
  |> play(:e4, 1)
  |> play(:g4, 1)
  |> play(:c5, 1)

score = Score.from_parts([melody], beats: 4)

path = Path.join(System.tmp_dir!(), "tuning_fork_example.mid")
Midi.write!(score, path)

read_back = path |> Midi.read!() |> Midi.to_score(default: Voice.new(shape: :saw))
IO.puts("wrote #{path}; read back #{length(read_back.notes)} notes at #{read_back.bpm} bpm")

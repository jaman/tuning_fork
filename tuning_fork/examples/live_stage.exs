import TuningFork.Pattern
import TuningFork.Pattern.Control

alias TuningFork.{Sink, Stage, Voice}

sink = if TuningFork.available?(), do: TuningFork.Sink.Speaker, else: Sink.Silent
{:ok, stage} = Stage.start_link(sink: sink, rate: 44_100)

Stage.play(stage, Voice.new(shape: :sine, freq: 440.0))
Process.sleep(500)

Stage.start_pattern(stage, s("bd*4, hh*8"), cps: 0.5)
Process.sleep(2_000)

Stage.update_pattern(stage, stack([s("bd*4, hh*8"), n("0 4 7") |> scale("c:minor") |> s("sawtooth")]), at: :cycle)
Process.sleep(2_000)

Stage.stop_pattern(stage)
IO.puts("played through #{inspect(sink)}; add tuning_fork_speaker to hear it")

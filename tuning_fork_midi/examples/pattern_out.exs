import TuningFork.Pattern, only: [stack: 1]
import TuningFork.Pattern.Control

alias TuningFork.Midi.{Out, Port}

{:ok, port} = Port.open_virtual_output("tuning_fork")
IO.puts("sending a pattern to the virtual port \"tuning_fork\" for 20 s; point a synth at it")

{:ok, live} =
  Out.pattern(port, stack([s("bd*4, hh*8"), n("0 4 7 4") |> scale("c:minor")]),
    cps: 0.5,
    clock: true
  )

Process.sleep(10_000)

Out.update_pattern(live, stack([s("bd*2, ~ cp"), n("<0 3> 7") |> scale("c:minor")]))
Process.sleep(10_000)

Out.stop(live)

alias TuningFork.Midi.{In, Port}
alias TuningFork.{Sink, Stage}

sink = if TuningFork.available?(), do: TuningFork.Sink.Speaker, else: Sink.Silent
{:ok, stage} = Stage.start_link(sink: sink)

{:ok, inputs} = Port.inputs()

case inputs do
  [] ->
    IO.puts("no MIDI inputs on this machine; a virtual one is open as \"tuning_fork\" for 30 s")

    {:ok, _listener} =
      In.start_link(port: {:virtual, "tuning_fork"}, stage: stage, voice: "gm_piano")

  [{index, name} | _rest] ->
    IO.puts("playing #{name} on #{inspect(sink)} for 30 s")
    {:ok, _listener} = In.start_link(port: index, stage: stage, voice: "gm_piano")
end

Process.sleep(30_000)

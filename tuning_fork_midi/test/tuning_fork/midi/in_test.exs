defmodule TuningFork.Midi.InTest do
  use ExUnit.Case, async: false

  alias TuningFork.Midi.{In, Message}
  alias TuningFork.{Sink, Stage}

  setup do
    stage =
      start_supervised!(
        Supervisor.child_spec({Stage, name: nil, sink: Sink.Silent, rate: 8_000, chunk: 256},
          id: make_ref()
        )
      )

    {:ok, stage: stage}
  end

  defp arrives(listener, bytes), do: send(listener, {:midi_in, nil, bytes, 0})

  test "a note on holds a voice on the stage and a note off lets it go", %{stage: stage} do
    {:ok, listener} = In.start_link(stage: stage, voice: %{shape: :sine})

    arrives(listener, Message.note_on(60, 100))
    Process.sleep(150)
    assert Stage.sounding(stage) == 1

    arrives(listener, Message.note_off(60))
    Process.sleep(300)
    assert Stage.sounding(stage) == 0
  end

  test "the sustain pedal keeps released notes going until it comes up", %{stage: stage} do
    {:ok, listener} = In.start_link(stage: stage, voice: %{shape: :sine})

    arrives(listener, Message.control(64, 127))
    arrives(listener, Message.note_on(60, 100))
    arrives(listener, Message.note_off(60))
    Process.sleep(200)
    assert Stage.sounding(stage) == 1

    arrives(listener, Message.control(64, 0))
    Process.sleep(300)
    assert Stage.sounding(stage) == 0
  end

  test "the voice may be a sound name, a map or a function of note and velocity", %{stage: stage} do
    parent = self()

    {:ok, listener} =
      In.start_link(
        stage: stage,
        voice: fn note, velocity ->
          send(parent, {:asked, note, velocity})
          TuningFork.Kit.voice(%{note: note, shape: :saw}, 1.0)
        end
      )

    arrives(listener, Message.note_on(64, 80, channel: 2))
    assert_receive {:asked, 64, 80}

    {:ok, named} = In.start_link(stage: stage, voice: "sawtooth")
    arrives(named, Message.note_on(60, 100))
    Process.sleep(150)
    assert Stage.sounding(stage) == 2
  end

  test "every event is passed on to a process that asks for them", %{stage: stage} do
    {:ok, listener} = In.start_link(stage: stage, voice: %{shape: :sine}, to: self())

    arrives(listener, Message.note_on(60, 100) <> Message.control(1, 50))

    assert_receive {:midi, {:note_on, 1, 60, 100}}
    assert_receive {:midi, {:control, 1, 1, 50}}
  end

  test "a channel filter drops the others", %{stage: stage} do
    {:ok, listener} = In.start_link(stage: stage, voice: %{shape: :sine}, channel: 1, to: self())

    arrives(listener, Message.note_on(60, 100, channel: 2))
    refute_receive {:midi, _event}, 100
    Process.sleep(100)
    assert Stage.sounding(stage) == 0
  end

  test "no stage at all still passes events on", _context do
    {:ok, listener} = In.start_link(stage: nil, to: self())

    arrives(listener, Message.program(5))
    assert_receive {:midi, {:program, 1, 5}}
  end
end

defmodule TuningFork.Midi.MonitorTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 15_000

  alias TuningFork.Midi.{Message, Monitor, Port}
  alias TuningFork.Pattern.Control

  setup do
    run = "#{System.unique_integer([:positive])}"

    case Port.open_virtual_output("TF Monitor Keys " <> run) do
      {:ok, keys} ->
        on_exit(fn -> Port.close(keys) end)
        Process.sleep(50)
        {:ok, monitor} = Monitor.start_link(stage: nil)
        {:ok, keys: keys, monitor: monitor, run: run}

      {:error, reason} ->
        {:ok, skip: reason}
    end
  end

  defp input_named(name) do
    {:ok, inputs} = Port.inputs()
    Enum.find_value(inputs, fn {index, found} -> if to_string(found) == name, do: index end)
  end

  test "it starts with nothing open and nothing held", %{monitor: monitor} do
    state = Monitor.state(monitor)

    assert state.input == nil
    assert state.output == nil
    assert state.keys == %{}
    assert state.playing == false
    assert state.events == []
  end

  test "what comes in through the input is held, reported, and listed", context do
    if keys = context[:keys] do
      monitor = context.monitor
      :ok = Monitor.subscribe(monitor, self())
      assert :ok = Monitor.open_input(monitor, input_named("TF Monitor Keys " <> context.run))
      Process.sleep(50)

      :ok = Port.send(keys, Message.note_on(60, 100))
      assert_receive {:midi_monitor, ^monitor, :in, {:note_on, 1, 60, 100}, _at}, 2_000
      assert Monitor.state(monitor).keys == %{60 => 100}

      :ok = Port.send(keys, Message.control(64, 127))
      assert_receive {:midi_monitor, ^monitor, :in, {:control, 1, 64, 127}, _at}, 2_000
      assert Monitor.state(monitor).pedal == true

      :ok = Port.send(keys, Message.note_off(60, 0))
      assert_receive {:midi_monitor, ^monitor, :in, {:note_off, 1, 60, 0}, _at}, 2_000
      assert Monitor.state(monitor).keys == %{}

      assert [{:in, {:note_off, 1, 60, 0}, _} | _rest] = Monitor.state(monitor).events
      assert {_index, "TF Monitor Keys " <> _run} = Monitor.state(monitor).input
    end
  end

  test "a pattern played out is reported and lights the notes it sends", context do
    if context[:keys] do
      monitor = context.monitor
      :ok = Monitor.subscribe(monitor, self())
      assert :ok = Monitor.open_output(monitor, {:virtual, "TF Monitor Out " <> context.run})
      Process.sleep(50)

      {:ok, listening} = Port.open_input(input_named("TF Monitor Out " <> context.run), self())
      on_exit(fn -> Port.close(listening) end)
      :ok = Port.listen(listening)
      Process.sleep(50)

      assert :ok = Monitor.play(monitor, Control.note("c3 e3"), cps: 4.0)
      assert Monitor.state(monitor).playing == true

      assert_receive {:midi_in, _p, <<0x90, 48, _::8>>, _at}, 2_000
      assert_receive {:midi_monitor, ^monitor, :out, {:note_on, 1, 48, _velocity}, _at}, 2_000

      assert Enum.any?(1..20, fn _ ->
               Process.sleep(10)
               48 in Monitor.state(monitor).sounding
             end)

      assert :ok = Monitor.stop(monitor)
      assert Monitor.state(monitor).playing == false
      assert Monitor.state(monitor).sounding == []
    end
  end

  test "a note tapped from the screen goes out and is reported", context do
    if context[:keys] do
      monitor = context.monitor
      :ok = Monitor.subscribe(monitor, self())
      assert :ok = Monitor.open_output(monitor, {:virtual, "TF Monitor Tap " <> context.run})
      Process.sleep(50)

      {:ok, listening} = Port.open_input(input_named("TF Monitor Tap " <> context.run), self())
      on_exit(fn -> Port.close(listening) end)
      :ok = Port.listen(listening)
      Process.sleep(50)

      assert :ok = Monitor.tap(monitor, 67, 90)
      assert_receive {:midi_in, _p, <<0x90, 67, 90>>, _at}, 2_000
      assert_receive {:midi_monitor, ^monitor, :out, {:note_on, 1, 67, 90}, _at}, 2_000
      assert_receive {:midi_in, _p, <<0x80, 67, 0>>, _at}, 2_000
    end
  end

  test "opening a port that is not there says so and changes nothing", %{monitor: monitor} do
    assert {:error, _reason} = Monitor.open_input(monitor, 9_999)
    assert Monitor.state(monitor).input == nil
  end
end

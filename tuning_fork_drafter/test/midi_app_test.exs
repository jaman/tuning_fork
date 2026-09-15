defmodule TuningFork.MidiAppTest do
  @moduledoc """
  The MIDI front end, driven without a terminal. Every test hands `mount/1` a
  `TuningFork.Sink.Silent`, so the stage the keyboard plays on is real but heard by nobody.
  The port tests open virtual ports, which the operating system shows to every application,
  so `async: false`.
  """

  use ExUnit.Case, async: false

  alias TuningFork.Midi.{Message, Monitor, Port}
  alias TuningFork.MidiApp, as: App
  alias TuningFork.Sink

  doctest TuningFork.MidiApp

  defp app(opts \\ []) do
    opts
    |> Keyword.new()
    |> Keyword.put_new(:sink, Sink.Silent)
    |> Keyword.put_new(:pattern, ~S{s("bd*4") |> gain(0.01)})
    |> App.mount()
  end

  defp press(state, keys) do
    keys
    |> List.wrap()
    |> Enum.reduce(state, fn key, acc -> App.update(key(key), acc) end)
  end

  defp key({key, mods}), do: {:key, key, mods}
  defp key(key), do: {:key, key}

  defp settle(state) do
    Process.sleep(80)
    App.update(:tick, state)
  end

  test "it opens with no ports, a piano, a pattern, and a running monitor" do
    state = app()

    assert is_pid(state.monitor)
    assert state.input == 0
    assert state.output == 0
    assert state.voice == "gm_piano"
    assert state.pattern =~ "bd"
    assert state.snapshot.playing == false
    assert App.render(state)
  end

  test "the input and output choices end with a virtual port" do
    state = app()

    assert List.last(state.inputs) == {:virtual, "TuningFork In"}
    assert List.last(state.outputs) == {:virtual, "TuningFork Out"}
    assert hd(state.inputs) == nil
  end

  test "? shows the keys and hides them again" do
    state = app()

    assert press(state, :"?").help
    refute state |> press(:"?") |> press(:"?") |> Map.fetch!(:help)
  end

  test "v walks the voices, and the monitor follows" do
    state = app() |> press(:v)

    assert state.voice != "gm_piano"
    assert Monitor.state(state.monitor).voice == state.voice
  end

  test "e edits the pattern until enter, esc leaves it alone" do
    state = app()
    edited = state |> press(:e) |> press([:backspace, :backspace, :x, :enter])
    assert String.ends_with?(edited.pattern, "x")
    refute edited.editing

    left = state |> press(:e) |> press([:z, :escape])
    assert left.pattern == state.pattern
  end

  test "o to the virtual output, p plays the pattern out, p again stops it" do
    state = app() |> press(:O)

    assert state.snapshot.output == {:virtual, "TuningFork Out"}

    playing = state |> press(:p) |> settle()
    assert playing.snapshot.playing
    assert Enum.any?(playing.snapshot.events, fn {side, _event, _at} -> side == :out end)

    stopped = playing |> press(:p) |> settle()
    refute stopped.snapshot.playing

    App.update({:key, :q, [:ctrl]}, stopped)
  end

  test "i to the virtual input opens it, and a key sent there lights up" do
    state = app() |> press(:I)

    assert state.snapshot.input == {:virtual, "TuningFork In"}

    {:ok, inputs} = Port.inputs()
    Process.sleep(80)
    {:ok, outputs} = Port.outputs()

    case Enum.find(outputs, fn {_i, name} -> to_string(name) == "TuningFork In" end) do
      {index, _name} ->
        {:ok, keys} = Port.open_output(index)
        :ok = Port.send(keys, Message.note_on(60, 100))
        lit = settle(state)
        assert Map.has_key?(lit.snapshot.keys, 60)
        Port.close(keys)

      nil ->
        assert is_list(inputs)
    end

    App.update({:key, :q, [:ctrl]}, state)
  end
end

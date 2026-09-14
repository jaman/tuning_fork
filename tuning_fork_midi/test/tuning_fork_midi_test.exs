defmodule TuningFork.MidiTest do
  @moduledoc """
  The ports, the messages, and a score played out of one.

  A machine running these has no MIDI hardware and no loopback bus set up, so the device tests
  make a virtual port of their own and read it back through the operating system. That is a
  real round trip: the bytes go out through CoreMIDI or ALSA and come back.

  `async: false` because a virtual port is visible to the whole machine while it is open.
  """

  use ExUnit.Case, async: false

  alias TuningFork.Midi.{In, Message, Out, Port}
  alias TuningFork.{Part, Score, Sink, Stage}
  alias TuningFork.Pattern.Control

  doctest TuningFork.Midi.Message
  doctest TuningFork.Midi.Port

  describe "messages" do
    test "a note on carries its channel in the status byte" do
      assert Message.note_on(60, 100) == <<0x90, 60, 100>>
      assert Message.note_on(60, 100, channel: 16) == <<0x9F, 60, 100>>
    end

    test "a channel outside 1..16 falls back to the first rather than wrapping" do
      assert Message.note_on(60, 100, channel: 0) == <<0x90, 60, 100>>
      assert Message.note_on(60, 100, channel: 99) == <<0x90, 60, 100>>
    end

    test "notes and velocities are clamped, so a gain over one is loud rather than quiet" do
      assert Message.note_on(300, 300) == <<0x90, 127, 127>>
      assert Message.note_on(-5, -5) == <<0x90, 0, 0>>
      assert Message.velocity(1.5) == 127
      assert Message.velocity(-1.0) == 0
    end

    test "a bend is centred at nothing and reaches both ends" do
      assert Message.bend(0.0) == <<0xE0, 0, 64>>
      assert <<0xE0, 0x7F, 0x7F>> = Message.bend(1.0)
      assert <<0xE0, 0, 0>> = Message.bend(-1.0)
    end

    test "hush lifts the pedal and stops every note" do
      bytes = Message.hush(channel: 2)

      assert bytes == <<0xB1, 64, 0>> <> <<0xB1, 123, 0>> <> <<0xB1, 120, 0>>
    end
  end

  describe "a score as messages" do
    setup do
      {:ok, score} =
        Part.Source.parse("""
        part(bpm: 120, synth: Kit.voice(%{note: "c3", shape: :saw}, 0.2))
        |> play(:c3, 1) |> play(:e3, 1)
        """)

      {:ok, score: score}
    end

    test "each note becomes an on and an off, in time order", %{score: score} do
      messages = Out.messages(score)

      assert length(messages) == 4
      assert [{+0.0, <<0x90, 48, _::8>>} | _rest] = messages
      assert messages == Enum.sort_by(messages, &elem(&1, 0))
    end

    test "the channel asked for is the channel on the wire", %{score: score} do
      assert [{_at, <<status, _::8, _::8>>} | _rest] = Out.messages(score, channel: 5)
      assert status == 0x94
    end

    test "a note off follows its own note on, not the next one", %{score: score} do
      ons = for {at, <<0x90, note, _::8>>} <- Out.messages(score), do: {note, at}
      offs = for {at, <<0x80, note, _::8>>} <- Out.messages(score), do: {note, at}

      for {note, on} <- ons do
        assert {^note, off} = Enum.find(offs, fn {other, _at} -> other == note end)
        assert off > on
      end
    end

    test "an empty score is no messages rather than a crash" do
      assert Out.messages(Score.new(bpm: 120, beats: 4)) == []
    end
  end

  describe "ports on this machine" do
    test "listing never raises, whatever hardware there is" do
      assert {:ok, outputs} = Port.outputs()
      assert {:ok, inputs} = Port.inputs()
      assert is_list(outputs) and is_list(inputs)
    end

    test "opening a device that is not there is reported rather than raised" do
      assert {:error, :out_of_range} = Port.open_output(9_999)
    end
  end

  describe "a virtual port, opened and read back" do
    setup do
      case Port.open_virtual_output("TF Test Out") do
        {:ok, out} ->
          on_exit(fn -> Port.close(out) end)
          Process.sleep(50)

          {:ok, out: out}

        {:error, reason} ->
          {:ok, skip: reason}
      end
    end

    test "it appears to the rest of the machine as something to read from", context do
      if context[:out] do
        {:ok, inputs} = Port.inputs()

        assert Enum.any?(inputs, fn {_index, name} -> to_string(name) == "TF Test Out" end)
      end
    end

    test "bytes sent to it come back through an input", context do
      if out = context[:out] do
        {:ok, inputs} = Port.inputs()
        {index, _name} = Enum.find(inputs, fn {_i, name} -> to_string(name) == "TF Test Out" end)

        {:ok, listening} = Port.open_input(index, self())
        on_exit(fn -> Port.close(listening) end)
        :ok = Port.listen(listening)
        Process.sleep(50)

        :ok = Port.send(out, Message.note_on(60, 100))

        assert_receive {:midi_in, _port, <<0x90, 60, 100>>, stamp}, 2_000
        assert is_integer(stamp)
      end
    end

    test "a closed port refuses to send rather than crashing", context do
      if out = context[:out] do
        :ok = Port.close(out)

        assert {:error, :not_open} = Port.send(out, Message.note_on(60, 100))
        assert :ok = Port.close(out)
      end
    end

    test "a score played out of it is heard note by note", context do
      if out = context[:out] do
        {:ok, inputs} = Port.inputs()
        {index, _name} = Enum.find(inputs, fn {_i, name} -> to_string(name) == "TF Test Out" end)

        {:ok, listening} = Port.open_input(index, self())
        on_exit(fn -> Port.close(listening) end)
        :ok = Port.listen(listening)
        Process.sleep(50)

        {:ok, score} =
          Part.Source.parse("""
          part(bpm: 480, synth: Kit.voice(%{note: "c3", shape: :saw}, 0.05))
          |> play(:c3, 1) |> play(:e3, 1)
          """)

        {:ok, playing} = Out.play(out, score)

        assert_receive {:midi_in, _p, <<0x90, 48, _::8>>, _at}, 2_000
        assert_receive {:midi_in, _p, <<0x90, 52, _::8>>, _at}, 2_000

        Out.stop(playing)

        assert_receive {:midi_in, _p, <<0xB0, 123, 0>>, _at}, 2_000
      end
    end

    test "a live pattern is heard cycle by cycle, swapped at the cycle line", context do
      if out = context[:out] do
        {:ok, inputs} = Port.inputs()
        {index, _name} = Enum.find(inputs, fn {_i, name} -> to_string(name) == "TF Test Out" end)

        {:ok, listening} = Port.open_input(index, self())
        on_exit(fn -> Port.close(listening) end)
        :ok = Port.listen(listening)
        Process.sleep(50)

        {:ok, live} = Out.pattern(out, Control.note("c3 e3"), cps: 4.0, clock: true)

        assert_receive {:midi_in, _p, <<0xFA>>, _at}, 2_000
        assert_receive {:midi_in, _p, <<0x90, 48, _::8>>, _at}, 2_000
        assert_receive {:midi_in, _p, <<0x90, 52, _::8>>, _at}, 2_000
        assert_receive {:midi_in, _p, <<0xF8>>, _at}, 2_000

        Out.update_pattern(live, Control.s("bd"))
        assert_receive {:midi_in, _p, <<0x99, 36, _::8>>, _at}, 2_000

        Out.stop(live)
        assert_receive {:midi_in, _p, <<0xFC>>, _at}, 2_000
      end
    end

    test "a keyboard played into a stage", context do
      if out = context[:out] do
        {:ok, inputs} = Port.inputs()
        {index, _name} = Enum.find(inputs, fn {_i, name} -> to_string(name) == "TF Test Out" end)
        {:ok, stage} = Stage.start_link(name: nil, sink: Sink.Silent, rate: 8_000, chunk: 256)
        on_exit(fn -> if Process.alive?(stage), do: GenServer.stop(stage) end)

        {:ok, listener} =
          In.start_link(port: index, stage: stage, voice: %{shape: :sine}, to: self())

        Process.sleep(50)

        :ok = Port.send(out, Message.note_on(60, 100))
        assert_receive {:midi, {:note_on, 1, 60, 100}}, 2_000
        Process.sleep(150)
        assert Stage.sounding(stage) == 1

        In.stop(listener)
        Process.sleep(300)
        assert Stage.sounding(stage) == 0
      end
    end
  end
end

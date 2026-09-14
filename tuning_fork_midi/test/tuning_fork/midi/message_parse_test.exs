defmodule TuningFork.Midi.MessageParseTest do
  use ExUnit.Case, async: true

  alias TuningFork.Midi.Message

  test "the messages it writes read back as events" do
    assert Message.parse(Message.note_on(60, 100, channel: 3)) == {:ok, {:note_on, 3, 60, 100}}
    assert Message.parse(Message.note_off(60, 10)) == {:ok, {:note_off, 1, 60, 10}}
    assert Message.parse(Message.control(64, 127, channel: 2)) == {:ok, {:control, 2, 64, 127}}
    assert Message.parse(Message.program(33)) == {:ok, {:program, 1, 33}}
    assert {:ok, {:bend, 1, amount}} = Message.parse(Message.bend(0.5))
    assert_in_delta amount, 0.5, 0.001
    assert {:ok, {:bend, 1, centre}} = Message.parse(Message.bend(0.0))
    assert_in_delta centre, 0.0, 0.001
  end

  test "a note on at velocity zero is a note off" do
    assert Message.parse(<<0x90, 60, 0>>) == {:ok, {:note_off, 1, 60, 0}}
  end

  test "aftertouch, both kinds" do
    assert Message.parse(<<0xD0, 90>>) == {:ok, {:aftertouch, 1, 90}}
    assert Message.parse(<<0xA1, 60, 90>>) == {:ok, {:poly_aftertouch, 2, 60, 90}}
  end

  test "realtime messages are single atoms" do
    assert Message.parse(<<0xF8>>) == {:ok, :clock}
    assert Message.parse(<<0xFA>>) == {:ok, :start}
    assert Message.parse(<<0xFB>>) == {:ok, :continue}
    assert Message.parse(<<0xFC>>) == {:ok, :stop}
  end

  test "what it does not read is reported, not raised" do
    assert Message.parse(<<0xF0, 1, 2, 0xF7>>) == {:error, :unknown}
    assert Message.parse(<<0x90, 60>>) == {:error, :short}
    assert Message.parse(<<>>) == {:error, :short}
  end

  test "several messages in one binary come out in order" do
    bytes = Message.note_on(60, 100) <> Message.note_off(60) <> <<0xF8>>

    assert Message.parse_all(bytes) == [{:note_on, 1, 60, 100}, {:note_off, 1, 60, 0}, :clock]
  end
end

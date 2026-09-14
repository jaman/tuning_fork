defmodule TuningFork.Midi.OutPatternTest do
  use ExUnit.Case, async: true

  import TuningFork.Pattern.Control

  alias TuningFork.Midi.{Message, Out}
  alias TuningFork.Pattern

  test "a cycle of a pattern becomes note ons and offs at their times" do
    messages =
      Out.pattern_messages(n("0 4") |> scale("c:major") |> s("sawtooth"), 0.0, 1.0, cps: 1.0)

    assert messages == [
             {0.0, Message.note_on(48, Message.velocity(0.8))},
             {0.5, Message.note_off(48)},
             {0.5, Message.note_on(55, Message.velocity(0.8))},
             {1.0, Message.note_off(55)}
           ]
  end

  test "gain is velocity, the channel comes from the options, and cps sets the seconds" do
    [{at, on} | _rest] =
      Out.pattern_messages(note("c4") |> gain(0.5), 0.0, 1.0, cps: 2.0, channel: 3)

    assert at == 0.0
    assert on == Message.note_on(60, Message.velocity(0.5), channel: 3)
    assert [{_, _}, {0.5, _}] = Out.pattern_messages(note("c4"), 0.0, 1.0, cps: 2.0, channel: 3)
  end

  test "drum names go out as General MIDI percussion on channel 10" do
    assert [{+0.0, on} | _rest] = Out.pattern_messages(s("bd ~"), 0.0, 1.0, cps: 1.0)
    assert on == Message.note_on(36, Message.velocity(0.8), channel: 10)
    assert [{_, hat} | _] = Out.pattern_messages(s("hh"), 0.0, 1.0, cps: 1.0)
    assert hat == Message.note_on(42, Message.velocity(0.8), channel: 10)
  end

  test "a value with no note and no known drum is skipped" do
    assert Out.pattern_messages(s("whatever"), 0.0, 1.0, cps: 1.0) == []
  end

  test "only onsets inside the window are taken, once each" do
    pattern = Pattern.slow(note("c4"), 2)

    assert [{+0.0, _on}, {2.0, _off}] = Out.pattern_messages(pattern, 0.0, 1.0, cps: 1.0)
    assert Out.pattern_messages(pattern, 1.0, 2.0, cps: 1.0) == []
  end
end

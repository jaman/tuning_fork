defmodule TuningFork.MusTest do
  use ExUnit.Case, async: true

  alias TuningFork.Mus

  defp lump(score),
    do:
      <<"MUS", 0x1A, byte_size(score)::little-16, 16::little-16, 1::little-16, 0::little-16,
        0::little-16, 0::little-16>> <> score

  test "events land on MIDI channels, at the ticks their delays add up to, with remembered volumes" do
    score =
      <<0x41, 0x00, 7::8>> <>
        <<0x10, 0xBC, 100, 0x9F, 0xA4, 0x40, 0x81, 0x00>> <>
        <<0x00, 60, 0x9A, 0x30, 2>> <>
        <<0x2A, 192, 0x0A, 48, 0x60>>

    assert {:ok, midi} = Mus.parse(lump(score))
    [events] = midi.tracks

    assert midi.division == 140

    assert Enum.drop(events, 1) == [
             {0, {:program, 1, 7}},
             {0, {:note_on, 0, 60, 100}},
             {0, {:note_on, 9, 36, 64}},
             {128, {:note_off, 0, 60, 0}},
             {128, {:note_on, 11, 48, 127}},
             {130, {:pitch_bend, 11, 0.5}},
             {130, {:note_off, 11, 48, 0}}
           ]
  end

  test "a lump that is not MUS is refused" do
    assert {:error, :not_mus} = Mus.parse(<<"MThd", 0, 0, 0, 6>>)
  end
end

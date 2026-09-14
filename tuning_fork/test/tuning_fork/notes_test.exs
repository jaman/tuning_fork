defmodule TuningFork.NotesTest do
  use ExUnit.Case, async: true

  alias TuningFork.Notes

  describe "pitch" do
    test "a4 is 440 and octaves double" do
      assert_in_delta Notes.freq(:a4), 440.0, 0.001
      assert_in_delta Notes.freq(:a5), 880.0, 0.001
      assert_in_delta Notes.freq(:a3), 220.0, 0.001
    end

    test "middle c is below the a above it" do
      assert Notes.freq(:c4) < Notes.freq(:a4)
      assert Notes.freq(:c5) > Notes.freq(:a4)
    end

    test "sharps and flats" do
      assert_in_delta Notes.freq(:as4), Notes.freq(:bb4), 0.001
      assert_in_delta Notes.freq(:eb4), Notes.freq(:ds4), 0.001
      assert Notes.freq(:ab4) < Notes.freq(:a4)
    end

    test "a number is a frequency and passes through" do
      assert Notes.freq(261.63) == 261.63
      assert Notes.freq(440) == 440.0
    end

    test "midi numbers line up with the usual convention" do
      assert Notes.semitone(:a4) == 69
      assert Notes.semitone(:c4) == 60
      assert Notes.semitone(:"c-1") == 0
    end

    test "a name that is not a note says so" do
      assert_raise ArgumentError, ~r/not a note name/, fn -> Notes.freq(:banana) end
      assert_raise ArgumentError, ~r/not a note name/, fn -> Notes.freq(:h4) end
    end

    test "naming a midi number is the inverse of reading one" do
      for name <- [:c4, :fs3, :a5, :ds2] do
        assert Notes.name_of(Notes.semitone(name)) == name
      end
    end

    test "a flat is named as the sharp that sounds the same" do
      assert Notes.name_of(Notes.semitone(:eb4)) == :ds4
    end
  end

  describe "scales" do
    test "a minor scale has the intervals a minor scale has" do
      assert Notes.scale(:a3, :minor) == [:a3, :b3, :c4, :d4, :e4, :f4, :g4]
    end

    test "a major scale starting on c is the white notes" do
      assert Notes.scale(:c4, :major) == [:c4, :d4, :e4, :f4, :g4, :a4, :b4]
    end

    test "a pentatonic has five notes to the octave" do
      assert length(Notes.scale(:a3, :minor_pentatonic)) == 5
      assert length(Notes.scale(:c4, :major_pentatonic)) == 5
    end

    test "more octaves keep climbing rather than starting again" do
      two = Notes.scale(:a3, :minor_pentatonic, octaves: 2)

      assert length(two) == 10
      assert Notes.freq(List.last(two)) > Notes.freq(List.first(two))
    end

    test "every scale it offers can be asked for" do
      for name <- Notes.scales(), do: assert([_ | _] = Notes.scale(:c4, name))
    end
  end

  describe "chords" do
    test "major and minor differ by the third" do
      assert Notes.chord(:a3, :major) == [:a3, :cs4, :e4]
      assert Notes.chord(:a3, :minor) == [:a3, :c4, :e4]
    end

    test "sevenths add a fourth note" do
      assert Notes.chord(:a3, :minor7) == [:a3, :c4, :e4, :g4]
      assert length(Notes.chord(:c4, :major7)) == 4
    end

    test "every chord it offers can be asked for" do
      for name <- Notes.chords(), do: assert([_ | _] = Notes.chord(:c4, name))
    end
  end
end

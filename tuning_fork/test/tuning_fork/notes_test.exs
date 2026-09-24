defmodule TuningFork.NotesTest do
  use ExUnit.Case, async: true

  alias TuningFork.Notes

  describe "pitch" do
    test "a4 is 440 and octaves double" do
      assert_in_delta Notes.freq(:a4), 440.0, 0.001
      assert_in_delta Notes.freq(:a5), 880.0, 0.001
      assert_in_delta Notes.freq(:a3), 220.0, 0.001
    end

    test "sharps and flats" do
      assert_in_delta Notes.freq(:as4), Notes.freq(:bb4), 0.001
      assert_in_delta Notes.freq(:eb4), Notes.freq(:ds4), 0.001
      assert Notes.freq(:ab4) < Notes.freq(:a4)
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
  end

  describe "scales" do
    test "a minor scale has the intervals a minor scale has" do
      assert Notes.scale(:a3, :minor) == [:a3, :b3, :c4, :d4, :e4, :f4, :g4]
    end

    test "more octaves keep climbing rather than starting again" do
      two = Notes.scale(:a3, :minor_pentatonic, octaves: 2)

      assert length(two) == 10
      assert Notes.freq(List.last(two)) > Notes.freq(List.first(two))
    end
  end

  describe "chords" do
    test "major and minor differ by the third" do
      assert Notes.chord(:a3, :major) == [:a3, :cs4, :e4]
      assert Notes.chord(:a3, :minor) == [:a3, :c4, :e4]
    end
  end
end

defmodule TuningFork.ScaleTest do
  use ExUnit.Case, async: true

  alias TuningFork.Scale

  doctest TuningFork.Scale

  describe "reading a name" do
    test "a root and a scale" do
      assert Scale.parse("g:minor") == {:ok, 55, :minor}
      assert Scale.parse("c:major") == {:ok, 48, :major}
    end

    test "an octave on the root moves it" do
      {:ok, without, _scale} = Scale.parse("g:minor")
      {:ok, lower, _scale} = Scale.parse("g2:minor")

      assert lower == without - 12
    end

    test "sharps and flats" do
      assert {:ok, root, :dorian} = Scale.parse("fs:dorian")
      assert {:ok, ^root, :dorian} = Scale.parse("gb:dorian")
    end

    test "case does not matter" do
      assert Scale.parse("G:Minor") == Scale.parse("g:minor")
    end

    test "no scale means major" do
      assert {:ok, _root, :major} = Scale.parse("d")
    end

    test "a root it does not know says so" do
      assert {:error, message} = Scale.parse("h:minor")
      assert message =~ "not a note"
    end

    test "a scale it does not know says so and points at the list" do
      assert {:error, message} = Scale.parse("c:wobbly")
      assert message =~ "not a scale"
      assert message =~ "names/0"
    end
  end

  describe "the scales themselves" do
    test "a name takes a string as well as an atom" do
      assert Scale.steps("minor") == Scale.steps(:minor)
    end

    test "a name it does not have is nil rather than a crash" do
      assert Scale.steps(:wobbly) == nil
      assert Scale.steps("wobbly") == nil
    end

    test "names lists them sorted" do
      assert Scale.names() == Enum.sort(Scale.names())
      assert :minor in Scale.names()
    end
  end

  describe "degrees to notes" do
    test "degrees walk the scale, not the semitones" do
      assert Scale.midi("c:major", 1) == 50
      assert Scale.midi("c:major", 2) == 52
      assert Scale.midi("c:major", 3) == 53
    end

    test "a degree past the end carries into the octave above" do
      assert Scale.midi("c:major", 7) == Scale.midi("c:major", 0) + 12
      assert Scale.midi("c:major", 9) == Scale.midi("c:major", 2) + 12
    end

    test "a negative degree goes down the same way" do
      assert Scale.midi("c:major", -7) == Scale.midi("c:major", 0) - 12
      assert Scale.midi("c:major", -1) == 47
    end

    test "a pentatonic wraps after five, not seven" do
      assert Scale.midi("c:minor_pentatonic", 5) == Scale.midi("c:minor_pentatonic", 0) + 12
    end

    test "a name it cannot read is nil rather than a crash" do
      assert Scale.midi("h:wobbly", 0) == nil
      assert Scale.midi({60, :wobbly}, 0) == nil
    end
  end
end

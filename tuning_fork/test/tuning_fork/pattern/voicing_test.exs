defmodule TuningFork.Pattern.VoicingTest do
  use ExUnit.Case, async: true

  alias TuningFork.Pattern.Voicing

  describe "render/2, against Strudel's renderVoicing" do
    test "the ireal dictionary, below an anchor of c5" do
      assert Voicing.render("Bbm9") == [58, 61, 65, 68, 72]
      assert Voicing.render("Fm9") == [56, 63, 65, 67, 72]
      assert Voicing.render("C") == [52, 60, 64, 67, 72]
      assert Voicing.render("Cm7") == [58, 63, 67, 70, 72]
      assert Voicing.render("G7") == [55, 62, 65, 67, 71]
    end

    test "offset walks the dictionary's voicings" do
      assert Voicing.render("Bbm9", offset: -1) == [56, 61, 65, 70, 72]
      assert Voicing.render("Bbm9", offset: 2) == [61, 68, 70, 72, 77]
    end

    test "anchor and mode" do
      assert Voicing.render("Bbm9", anchor: "D5") == [58, 61, 65, 68, 72]
      assert Voicing.render("Bbm9", mode: :root, anchor: "g2") == [34, 37, 41, 44, 48]
      assert Voicing.render("C7", mode: :above) == [72, 79, 82, 84, 88]
      assert Voicing.render("C7", mode: :duck, anchor: "e4") == [48, 55, 58, 60]
    end

    test "n picks one tone of the voicing, wrapping into the octaves around it" do
      assert Voicing.render("Bbm9", n: 0) == [58]
      assert Voicing.render("Bbm9", n: 4) == [72]
      assert Voicing.render("Bbm9", n: 7) == [77]
      assert Voicing.render("Bbm9", n: -1) == [60]
      assert Voicing.render("Fm9", mode: :root, anchor: "g2", n: 1) == [44]
    end

    test "other dictionaries" do
      assert Voicing.render("C", dictionary: :legacy, anchor: "a4") == [60, 64, 67]
      assert Voicing.render("Dm7", dictionary: :legacy, anchor: "a4") == [60, 64, 65, 69]
      assert Voicing.render("Dm7", dictionary: :lefthand, anchor: "a4") == [60, 64, 65, 69]
    end

    test "symbol spellings Strudel accepts" do
      assert Voicing.render("C^7") == Voicing.render("CM7")
      assert Voicing.render("C-7") == Voicing.render("Cm7")
      assert Voicing.render("C+") == Voicing.render("Caug")
      assert Voicing.render("Bb") == Voicing.render("Bb^")
    end

    test "a chord it does not know is :error" do
      assert Voicing.render("Cwhat") == :error
      assert Voicing.render("H7") == :error
    end
  end

  test "dictionaries/0 names what render/2 takes" do
    assert Enum.sort(Voicing.dictionaries()) == [
             :guidetones,
             :ireal,
             :"ireal-ext",
             :lefthand,
             :legacy,
             :triads
           ]
  end
end

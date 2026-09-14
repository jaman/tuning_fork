defmodule TuningFork.Pattern.MiniTest do
  @moduledoc """
  The mini-notation, checked by reading a cycle of what each string parses to.

  `cycle/2` is the whole vocabulary of these tests: give it a string, get back the onsets of
  one cycle as `{from, to, value}`.
  """

  use ExUnit.Case, async: true

  alias TuningFork.Pattern, as: P
  alias TuningFork.Pattern.Mini

  doctest TuningFork.Pattern.Mini

  defp cycle(source, at \\ 0), do: source |> Mini.parse() |> P.first_cycle(at)

  describe "words and numbers" do
    test "a word on its own fills the cycle" do
      assert cycle("bd") == [{0.0, 1.0, "bd"}]
    end

    test "words in a row share the cycle" do
      assert cycle("bd sn hh") == [
               {0.0, 0.333333, "bd"},
               {0.333333, 0.666667, "sn"},
               {0.666667, 1.0, "hh"}
             ]
    end

    test "numbers come back as numbers, not strings" do
      assert cycle("0 1 2 3") == [{0.0, 0.25, 0}, {0.25, 0.5, 1}, {0.5, 0.75, 2}, {0.75, 1.0, 3}]
    end

    test "a decimal stays a float and a minus sign is part of the number" do
      assert cycle("0.5 -2") == [{0.0, 0.5, 0.5}, {0.5, 1.0, -2}]
    end

    test "a colon index rides along on the word" do
      assert cycle("bd:3 sn:1") == [{0.0, 0.5, "bd:3"}, {0.5, 1.0, "sn:1"}]
    end

    test "words may carry the punctuation drum names use" do
      assert cycle("hi-hat bass_drum c'") == [
               {0.0, 0.333333, "hi-hat"},
               {0.333333, 0.666667, "bass_drum"},
               {0.666667, 1.0, "c'"}
             ]
    end

    test "nothing at all is silence rather than an error" do
      assert cycle("") == []
      assert cycle("   ") == []
    end
  end

  describe "rests and groups" do
    test "a tilde takes its step and stays quiet" do
      assert cycle("bd ~ sn ~") == [{0.0, 0.25, "bd"}, {0.5, 0.75, "sn"}]
    end

    test "brackets subdivide one step" do
      assert cycle("bd [sn sn]") == [
               {0.0, 0.5, "bd"},
               {0.5, 0.75, "sn"},
               {0.75, 1.0, "sn"}
             ]
    end

    test "brackets nest" do
      assert cycle("[bd [sn [hh hh]]]") == [
               {0.0, 0.5, "bd"},
               {0.5, 0.75, "sn"},
               {0.75, 0.875, "hh"},
               {0.875, 1.0, "hh"}
             ]
    end

    test "a comma stacks them at the same time" do
      assert cycle("[bd, hh hh]") == [
               {0.0, 0.5, "hh"},
               {0.0, 1.0, "bd"},
               {0.5, 1.0, "hh"}
             ]
    end

    test "a comma at the top level stacks too" do
      assert cycle("bd*2, hh") == [{0.0, 0.5, "bd"}, {0.0, 1.0, "hh"}, {0.5, 1.0, "bd"}]
    end

    test "angle brackets take one per cycle in turn" do
      assert cycle("hh <bd sn>", 0) == [{0.0, 0.5, "hh"}, {0.5, 1.0, "bd"}]
      assert cycle("hh <bd sn>", 1) == [{0.0, 0.5, "hh"}, {0.5, 1.0, "sn"}]
      assert cycle("hh <bd sn>", 2) == [{0.0, 0.5, "hh"}, {0.5, 1.0, "bd"}]
    end
  end

  describe "modifiers" do
    test "star repeats within the step" do
      assert cycle("bd*4") == [
               {0.0, 0.25, "bd"},
               {0.25, 0.5, "bd"},
               {0.5, 0.75, "bd"},
               {0.75, 1.0, "bd"}
             ]
    end

    test "slash stretches it over cycles, so the note runs past the cycle line" do
      assert cycle("bd/2", 0) == [{0.0, 2.0, "bd"}]
      assert cycle("bd/2", 1) == []
      assert cycle("bd/2", 2) == [{0.0, 2.0, "bd"}]
    end

    test "a stretched note is still sounding on the cycle it does not start" do
      pattern = Mini.parse("bd/2")

      assert [event] = P.query(pattern, {1.0, 1.5})
      assert event.whole == {0.0, 2.0}
      refute P.onset?(event)
    end

    test "bang repeats it as separate steps" do
      assert cycle("bd!3 sn") == [
               {0.0, 0.25, "bd"},
               {0.25, 0.5, "bd"},
               {0.5, 0.75, "bd"},
               {0.75, 1.0, "sn"}
             ]
    end

    test "a bare bang repeats it once more" do
      assert cycle("bd! sn") == [
               {0.0, 0.333333, "bd"},
               {0.333333, 0.666667, "bd"},
               {0.666667, 1.0, "sn"}
             ]
    end

    test "at takes that many steps' worth" do
      assert cycle("bd@3 sn") == [{0.0, 0.75, "bd"}, {0.75, 1.0, "sn"}]
    end

    test "question drops events, the same ones every run" do
      dropped = cycle("hh*16?")

      assert length(dropped) > 2 and length(dropped) < 14
      assert dropped == cycle("hh*16?")
    end

    test "question takes how much to drop" do
      assert length(cycle("hh*16?0.0")) == 16
      assert cycle("hh*16?1.0") == []
    end

    test "modifiers stack left to right" do
      assert cycle("bd*2!2") == [
               {0.0, 0.25, "bd"},
               {0.25, 0.5, "bd"},
               {0.5, 0.75, "bd"},
               {0.75, 1.0, "bd"}
             ]
    end

    test "a modifier applies to a bracketed group as well as a word" do
      assert cycle("[bd sn]*2") == [
               {0.0, 0.25, "bd"},
               {0.25, 0.5, "sn"},
               {0.5, 0.75, "bd"},
               {0.75, 1.0, "sn"}
             ]
    end
  end

  describe "euclidean rhythms" do
    test "hits and steps give the rhythm the numbers name" do
      assert cycle("bd(3,8)") == [
               {0.0, 0.125, "bd"},
               {0.375, 0.5, "bd"},
               {0.75, 0.875, "bd"}
             ]
    end

    test "a third number rotates it" do
      assert cycle("bd(3,8,2)") == [
               {0.125, 0.25, "bd"},
               {0.5, 0.625, "bd"},
               {0.75, 0.875, "bd"}
             ]
    end

    test "it stacks with another row, the rests staying silent" do
      both = cycle("[bd(3,8), hh*8]")

      assert length(both) == 11
    end
  end

  describe "strings that will not parse" do
    test "an unclosed bracket says which one" do
      assert {:error, message} = Mini.parse_safe("bd [sn")
      assert message =~ ~s(unclosed "[")
      assert message =~ ~s("bd [sn")
    end

    test "an unclosed angle bracket says so too" do
      assert {:error, message} = Mini.parse_safe("bd <sn")
      assert message =~ ~s(unclosed "<")
    end

    test "a character with no meaning is named" do
      assert {:error, message} = Mini.parse_safe("bd %")
      assert message =~ ~s("%" means nothing here)
    end

    test "a closing bracket on its own is unexpected" do
      assert {:error, message} = Mini.parse_safe("]")
      assert message =~ "unexpected"
    end

    test "euclid with the wrong number of arguments says what it takes" do
      assert {:error, message} = Mini.parse_safe("bd(3)")
      assert message =~ "(hits,steps)"
      assert message =~ "got one number"
    end

    test "parse raises where parse_safe reports" do
      assert_raise ArgumentError, ~r/unclosed/, fn -> Mini.parse("bd [sn") end
    end
  end

  describe "against the combinators it is shorthand for" do
    test "a sequence is fastcat" do
      assert cycle("bd sn") == P.first_cycle(P.fastcat(["bd", "sn"]))
    end

    test "angle brackets are slowcat" do
      alternating = P.slowcat([P.pure("bd"), P.pure("sn")])

      for at <- 0..3 do
        assert cycle("<bd sn>", at) == P.first_cycle(alternating, at)
      end
    end

    test "equal weights through timecat land where fastcat does" do
      assert cycle("a b c") == P.first_cycle(P.fastcat(["a", "b", "c"]))
    end

    test "parens are euclid" do
      assert cycle("bd(5,8)") == P.first_cycle(P.euclid(P.pure("bd"), 5, 8))
    end
  end

  describe "what a player sees" do
    test "a parsed pattern reports every onset once when read block by block" do
      pattern = Mini.parse("[bd(3,8), hh*8, <sn cp>]")

      block_by_block =
        Enum.flat_map(0..63, fn block ->
          from = block / 64
          pattern |> P.query({from, from + 1 / 64}) |> Enum.filter(&P.onset?/1)
        end)

      in_one_go = pattern |> P.query({0.0, 1.0}) |> Enum.filter(&P.onset?/1)

      assert length(block_by_block) == length(in_one_go)
    end
  end
end

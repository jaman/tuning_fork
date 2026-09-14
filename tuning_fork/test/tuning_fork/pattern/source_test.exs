defmodule TuningFork.Pattern.SourceTest.Quiet do
  @moduledoc """
  A line that will not read must not print anything.

  `Code.eval_string` writes its own diagnostics to standard error before it raises, and a
  `rescue` cannot take those back. In a terminal front end standard error *is* the screen, so a
  half-typed line would scroll over the music — which is what these check has stopped.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TuningFork.Pattern.Source

  @broken [
    "|> pianoroll()",
    "s(\"bd\") |> nosuchfunction(3)",
    "s(\"bd\"",
    "n(\"0 4\") |> scale(",
    "1 +"
  ]

  test "a line that will not read prints nothing at all" do
    printed = capture_io(:stderr, fn -> Enum.each(@broken, &Source.parse/1) end)

    assert printed == "", "a broken line should report itself, not write to the screen"
  end

  test "and it still says what was wrong" do
    for line <- @broken do
      assert {:error, why} = Source.parse(line)
      assert is_binary(why) and why != ""
      refute why =~ "\n", "the reason should be one line, to sit under the slot"
    end
  end

  test "a bare continuation says so rather than corrupting the import above it" do
    assert {:error, why} = Source.parse("|> pianoroll()")

    assert why =~ "carries on the line above"
    refute why =~ "import", "the old message blamed the import, which is not what is wrong"
  end

  test "continues? knows a continuation from a pattern" do
    assert Source.continues?("|> pianoroll()")
    assert Source.continues?("   |> scale(\"g:minor\")")
    refute Source.continues?("s(\"bd\") |> pianoroll()")
    refute Source.continues?("bd*4")
  end

  test "a chain written on one line still reads" do
    assert {:ok, _pattern} = Source.parse("s(\"bd*4\") |> gain(0.5) |> pianoroll()")
  end
end

defmodule TuningFork.Pattern.SourceTest do
  @moduledoc """
  Turning a typed line into a pattern, both kinds and both ways of failing.
  """

  use ExUnit.Case, async: true

  alias TuningFork.Pattern
  alias TuningFork.Pattern.Source

  doctest TuningFork.Pattern.Source

  defp cycle(source) do
    {:ok, pattern} = Source.parse(source)

    Pattern.first_cycle(pattern)
  end

  describe "telling the two kinds apart" do
    test "an opening that names a control function is code" do
      for opening <- Source.openings() do
        assert Source.starts_code?(opening <> "\"bd\")")
      end
    end

    test "mini-notation is not" do
      refute Source.starts_code?("bd*4")
      refute Source.starts_code?("[bd(3,8), hh*8]")
      refute Source.starts_code?("~ sn ~ sn")
    end

    test "a space before the bracket does not hide it" do
      assert Source.starts_code?("s (\"bd\")")
      assert Source.starts_code?("  n(\"0\")")
    end

    test "a word merely starting with s is not code" do
      refute Source.starts_code?("sn*4")
      refute Source.starts_code?("shaker")
    end
  end

  describe "mini-notation" do
    test "reads as it does on its own" do
      assert cycle("bd sn") == [{0.0, 0.5, "bd"}, {0.5, 1.0, "sn"}]
    end

    test "an empty line is silence" do
      assert cycle("") == []
      assert cycle("   ") == []
    end

    test "a broken one reports the parser's reason" do
      assert {:error, message} = Source.parse("bd [")
      assert message =~ "unclosed"
    end
  end

  describe "code" do
    test "a control chain builds what it says" do
      [{_from, _to, controls} | _rest] =
        cycle(~S{n("0 4") |> scale("g:minor") |> shape(:saw)})

      assert controls == %{degree: 0, scale: "g:minor", shape: :saw}
    end

    test "pattern functions are in scope without importing them" do
      assert length(cycle(~S{stack([s("bd*2"), s("hh*4")])})) == 6
      assert length(cycle("s(\"bd\") |> pure() |> then(& &1)")) == 1
    end

    test "signals are in scope too" do
      levels = "s(\"bd*4\") |> gain(saw())" |> cycle() |> Enum.map(&elem(&1, 2).gain)

      assert levels == [0.0, 0.25, 0.5, 0.75]
    end

    test "the riff from the video reads" do
      notes =
        ~S{n("<0 4 0 9 7>*16") |> scale("g:minor") |> transpose(-12)}
        |> cycle()
        |> Enum.take(5)
        |> Enum.map(fn {_from, _to, controls} -> TuningFork.Kit.midi(controls) end)

      assert notes == [43, 50, 43, 58, 55]
    end

    test "something that is not a pattern says so rather than being played" do
      assert {:error, message} = Source.parse("pure(1) |> then(fn _ -> :nope end)")
      assert message =~ "not a pattern"
    end

    test "a syntax error reports without the file and line it happened in" do
      assert {:error, message} = Source.parse("n(\"0 4\"")

      assert message =~ "missing terminator"
      refute message =~ "source.ex"
      refute message =~ "│"
    end

    test "an unknown function reports its name" do
      assert {:error, message} = Source.parse("s(\"bd\") |> wobble(3)")
      assert message =~ "wobble"
    end

    test "a mini-notation error inside code is reported too" do
      assert {:error, message} = Source.parse("s(\"bd [\")")
      assert message =~ "unclosed"
    end

    test "a raise inside a line is caught rather than taking the caller down" do
      assert {:error, _message} = Source.parse("s(\"bd\") |> gain(1 / 0)")
    end

    test "the message is one line, whatever the error was" do
      for bad <- ["n(\"0 4\"", "s(\"bd\") |> wobble(3)", "s(\"bd [\")"] do
        assert {:error, message} = Source.parse(bad)
        refute message =~ "\n"
      end
    end
  end
end

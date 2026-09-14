defmodule TuningFork.SessionTest do
  @moduledoc """
  Rows of live-coded source, with no front end around them.

  The terminal app and the notebook cells all sit on this, so what a row means — off, a
  continuation, a chain, a broken line — is settled once here rather than once per client.
  """

  use ExUnit.Case, async: true

  alias TuningFork.{Pattern, Session}
  alias TuningFork.Session.View

  doctest TuningFork.Session
  doctest TuningFork.Session.View

  describe "switching a row off" do
    test "every marker parks a row" do
      for marker <- Session.off() do
        refute Session.live?(%{source: marker <> " s(\"bd\")"})
        refute Session.live?(%{source: marker <> "s(\"bd\")"})
      end
    end

    test "an empty row is off too" do
      refute Session.live?(%{source: ""})
      refute Session.live?(%{source: "   \t "})
    end

    test "anything else is on" do
      assert Session.live?(%{source: "bd*4"})
      assert Session.live?(%{source: "  s(\"bd\")  "})
    end

    test "comment puts a marker on and takes whichever is there off" do
      assert Session.comment("bd*4") == "-- bd*4"
      assert Session.comment("-- bd*4") == "bd*4"
      assert Session.comment("// bd*4") == "bd*4"
      assert Session.comment("_bd*4") == "bd*4"
    end

    test "commenting twice comes back to where it started" do
      assert "bd*4" |> Session.comment() |> Session.comment() == "bd*4"
    end
  end

  describe "chains" do
    test "a continuation joins the row above it" do
      rows = [%{source: "s(\"bd\")"}, %{source: "|> gain(0.5)"}, %{source: "|> pianoroll()"}]

      assert Session.joined(rows) == [{0, 2, "s(\"bd\") |> gain(0.5) |> pianoroll()"}]
    end

    test "first is where to report and last is where to draw" do
      rows = [%{source: "s(\"bd\")"}, %{source: "|> scope()"}, %{source: "hh*8"}]

      assert [{0, 1, _chain}, {2, 2, "hh*8"}] = Session.joined(rows)
    end

    test "a continuation with nothing above it is dropped rather than run alone" do
      assert Session.joined([%{source: "|> gain(0.5)"}]) == []
    end

    test "a parked row is left out and the numbering still counts it" do
      assert Session.joined([%{source: "-- s(\"bd\")"}, %{source: "hh*8"}]) == [{1, 1, "hh*8"}]
    end

    test "chain finds the whole source a row starts" do
      rows = [%{source: "s(\"bd\")"}, %{source: "|> gain(0.5)"}]

      assert Session.chain(rows, 0) == "s(\"bd\") |> gain(0.5)"
      assert Session.chain(rows, 1) == nil
    end
  end

  describe "what it all adds up to" do
    test "every live row is stacked into one pattern" do
      rows = [%{source: "bd*2"}, %{source: "hh*4"}]

      assert rows |> Session.combined() |> Pattern.first_cycle() |> length() == 6
    end

    test "a row that will not parse is left out rather than failing the lot" do
      rows = [%{source: "bd*2"}, %{source: "s(\"sn\""}, %{source: "hh*4"}]

      assert rows |> Session.combined() |> Pattern.first_cycle() |> length() == 6
    end

    test "no rows at all is silence rather than a crash" do
      assert Session.combined([]) |> Pattern.first_cycle() == []
    end
  end

  describe "reporting what is wrong" do
    test "a broken row is marked and a good one cleared" do
      assert [%{error: nil}, %{error: why}] =
               Session.checked([%{source: "bd*2"}, %{source: "s(\"sn\""}])

      assert why =~ "terminator"
    end

    test "the error lands on the row the chain starts" do
      rows = [%{source: "s(\"bd\")"}, %{source: "|> nosuchthing("}]

      assert [%{error: why}, %{error: nil}] = Session.checked(rows)
      assert is_binary(why)
    end

    test "a parked row is never checked, however broken" do
      assert [%{error: nil}] = Session.checked([%{source: "_ s(\"bd\""}])
    end

    test "an error is one line and short enough to sit under a row" do
      [%{error: why}] = Session.checked([%{source: "s(\"bd\""}])

      refute why =~ "\n"
      assert String.length(why) <= 70
    end

    test "checking leaves everything else on the row alone" do
      assert [%{cursor: 4, mine: :kept, error: nil}] =
               Session.checked([%{source: "bd*2", cursor: 4, mine: :kept}])
    end
  end

  describe "rows written as Strudel" do
    test "a pasted piece is read as its chains, each on the line it came from" do
      rows = [
        %{source: "// a piece"},
        %{source: "setcps(.5)"},
        %{source: "$: s(\"bd*4\").gain(.8)"},
        %{source: "$: stack(s(\"hh*8\"), s(\"~ cp\"))"},
        %{source: "  .room(.3)"}
      ]

      assert Session.joined(rows) == [
               {2, 2, ~S{s("bd*4") |> gain(0.8)}},
               {3, 4, ~S{s("hh*8") |> room(0.3)}},
               {3, 4, ~S{s("~ cp") |> room(0.3)}}
             ]

      assert length(Pattern.first_cycle(Session.combined(rows))) == 13
      assert Session.tempo(rows) == 0.5
      assert Enum.map(Session.checked(rows), & &1.error) == [nil, nil, nil, nil, nil]
    end

    test "a piece that will not read is faulted on its line" do
      rows = [%{source: "$: s(\"bd\").nonsense(2)"}, %{source: "$: s(\"hh\")"}]

      assert [%{error: why}, %{error: nil}] = Session.checked(rows)
      assert why =~ "nonsense"
      assert Pattern.first_cycle(Session.combined(rows)) == []
    end

    test "our own rows have no tempo of their own" do
      assert Session.tempo([%{source: "s(\"bd\")"}]) == nil
    end
  end

  describe "what a row asks to be drawn as" do
    test "it reads the end of the chain" do
      assert Session.asks?(%{source: "s(\"bd\") |> scope()"}) == :scope
      assert Session.asks?(%{source: "n(\"0 4\") |> pianoroll()"}) == :pianoroll
      assert Session.asks?(%{source: "s(\"bd\")"}) == nil
    end

    test "a parked row asks for nothing" do
      assert Session.asks?(%{source: "-- s(\"bd\") |> scope()"}) == nil
    end
  end

  describe "the numbers a front end draws" do
    test "a scope traces the row and nothing else" do
      trace = View.scope(%{source: "s(\"bd*4\")"}, 0.05, 0.5)

      assert length(trace) > 100
      assert Enum.all?(trace, &(&1 >= -1.0 and &1 <= 1.0))
      assert Enum.any?(trace, &(&1 != 0.0)), "it should have something in it"
    end

    test "a parked or broken row traces nothing" do
      assert View.scope(%{source: "_ s(\"bd\")"}, 0.0, 0.5) == []
      assert View.scope(%{source: "s(\"bd\""}, 0.0, 0.5) == []
    end

    test "hits are the columns a drum row strikes" do
      assert View.hits(%{source: "bd*4"}, 0.0) == [0, 8, 16, 24]
    end

    test "notes carry the pitch as well as the column" do
      notes = View.notes(%{source: "n(\"0 4 7\") |> scale(\"c:major\")"}, 0.0)

      assert length(notes) == 3
      assert Enum.all?(notes, fn {column, note} -> column in 0..31 and is_integer(note) end)
    end

    test "a drum row has no notes and a pitched row has no bare hits to speak of" do
      assert View.notes(%{source: "bd*4"}, 0.0) == []
    end

    test "widths say how long each note lasts, in columns" do
      assert View.widths(%{source: "bd sn"}, 0.0) == %{0 => 16.0, 16 => 16.0}
    end

    test "the playhead walks the columns across the cycle" do
      assert View.playhead(0.0) == 0
      assert View.playhead(0.5) == 16
      assert View.playhead(0.999) == 31
      assert View.playhead(2.5) == 16, "it reads the phase, not the cycle number"
    end

    test "sounding points at the token playing now" do
      assert View.sounding(%{source: "~ cp ~ cp"}, 0.3) == {2, 4}
      assert View.sounding(%{source: "~ cp ~ cp"}, 0.8) == {7, 9}
    end

    test "in a code row it points inside the quoted notation" do
      assert {from, to} = View.sounding(%{source: "s(\"bd sn\")"}, 0.6)
      assert String.slice("s(\"bd sn\")", from, to - from) == "sn"
    end

    test "a parked row is not highlighted" do
      assert View.sounding(%{source: "-- ~ cp ~ cp"}, 0.3) == nil
    end
  end
end

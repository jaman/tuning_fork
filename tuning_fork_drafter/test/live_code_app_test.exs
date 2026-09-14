defmodule TuningFork.LiveCodeAppTest do
  @moduledoc """
  The live-coding front end, driven without a terminal or a sound device.

  A reducer is a function from a message and a state to a state, so every key can be pressed
  from a test. Sound is not asserted on here — that belongs to `TuningFork.Pattern.Player` —
  only what the keys do to the text, which slots are live, and what gets drawn.
  """

  use ExUnit.Case, async: true

  alias TuningFork.LiveCodeApp, as: App
  alias TuningFork.Pattern.Source

  defp app(opts \\ []), do: App.mount(opts |> Map.new() |> Map.put_new(:pixels, false))

  defp press(state, keys) do
    keys
    |> List.wrap()
    |> Enum.reduce(state, fn key, acc -> App.update(key(key), acc) end)
  end

  defp key({key, mods}), do: {:key, key, mods}
  defp key(key), do: {:key, key}

  defp type(state, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(state, fn char, acc ->
      App.update({:key, String.to_atom(char)}, acc)
    end)
  end

  defp source(state, index \\ nil) do
    Enum.at(state.slots, index || state.slot).source
  end

  defp lines(state) do
    walk = fn walk, node ->
      case node do
        {:layout, _direction, children, _opts} -> Enum.flat_map(children, &walk.(walk, &1))
        {:label, text, _opts} -> [text]
        {:header, text, _opts} -> [text]
        {:footer, text, _opts} -> [text]
        _other -> []
      end
    end

    walk.(walk, App.render(state))
  end

  describe "starting up" do
    test "it opens on something to hear, on the first row" do
      state = app()

      assert length(state.slots) > length(App.demo())
      assert state.slot == 0
      assert source(state) =~ "bd"
    end

    test "it can be given the patterns to open on" do
      state = app(patterns: ["bd*4", "hh*8"])

      assert source(state, 0) == "bd*4"
      assert source(state, 1) == "hh*8"
      assert source(state, 2) == ""
    end

    test "there is no cap on how many rows you may open with" do
      state = app(patterns: List.duplicate("bd", 20))

      assert length(state.slots) >= 20
    end

    test "the speed can be set at the start" do
      assert app(cps: 1.5).cps == 1.5
    end
  end

  describe "typing" do
    test "characters go in at the cursor" do
      state = app(patterns: [""]) |> type("bd*4")

      assert source(state) =~ "bd"
    end

    test "the arrows move along the line and typing lands where they left it" do
      state = app(patterns: [""]) |> type("bdsn") |> press([:left, :left]) |> type("_")

      assert source(state) == "bd_sn"
    end

    test "backspace rubs out behind the cursor" do
      state = app(patterns: [""]) |> type("bd*4") |> press(:backspace)

      assert source(state) == "bd*"
    end

    test "backspace at the start of the line does nothing" do
      state = app(patterns: ["bd"]) |> press([:home, :backspace])

      assert source(state) == "bd"
    end

    test "home and end go to the ends" do
      state = app(patterns: ["bd*4"]) |> press(:home)
      assert state.slots |> Enum.at(0) |> Map.get(:cursor) == 0

      assert app(patterns: ["bd*4"])
             |> press([:home, :end])
             |> Map.get(:slots)
             |> Enum.at(0)
             |> Map.get(:cursor) == 4
    end

    test "the cursor stops at the ends rather than running off" do
      state = app(patterns: ["bd"]) |> press([:left, :left, :left, :left])
      assert Enum.at(state.slots, 0).cursor == 0

      far = app(patterns: ["bd"]) |> press(List.duplicate(:right, 10))
      assert Enum.at(far.slots, 0).cursor == 2
    end

    test "characters the notation uses are all typeable" do
      state = app(patterns: [""]) |> type("[bd*2, ~ sn]")

      assert source(state) == "[bd*2, ~ sn]"
    end
  end

  describe "moving between slots" do
    test "up and down change which slot is being edited" do
      state = app() |> press([:down, :down])

      assert state.slot == 2
    end

    test "it stops at the ends" do
      assert app() |> press(List.duplicate(:up, 5)) |> Map.get(:slot) == 0
      far = app() |> press(List.duplicate(:down, 20))
      assert far.slot == 20
      assert length(far.slots) > 20, "the rows should have grown to meet the cursor"
    end

    test "typing goes into the slot the cursor is on" do
      state = app(patterns: ["a", ""]) |> press(:down) |> type("bd")

      assert source(state, 0) == "a"
      assert source(state, 1) == "bd"
    end
  end

  describe "switching slots off" do
    test "a slot starting with two dashes is not playing" do
      refute App.live?(%{source: "-- bd*4"})
      refute App.live?(%{source: "  --bd"})
    end

    test "a slash comment and an underscore park it too" do
      refute App.live?(%{source: "// bd*4"})
      refute App.live?(%{source: "_ bd*4"})
      refute App.live?(%{source: "_n(\"0 4\")"})
    end

    test "a parked line is never checked, so it reports nothing however broken" do
      state = app(patterns: ["_n(\"<0 4 0 9 7>*16\") |> scale(\"g:minor\")"]) |> App.checked()

      assert Enum.at(state.slots, 0).error == nil
    end

    test "a parked line is left out of what plays and out of what is drawn" do
      slots = [%{source: "bd*2"}, %{source: "_n(\"0 4\")"}]

      assert TuningFork.Pattern.first_cycle(App.combined(slots)) |> length() == 2
      assert App.raster(%{source: "_bd*4"}, 0.0) == nil
    end

    test "tab takes off whichever marker is there" do
      for marker <- App.off() do
        state = app(patterns: [marker <> " bd*4"]) |> press(:tab)

        assert source(state) == "bd*4", "#{marker} should come off"
      end
    end

    test "an empty slot is not playing either" do
      refute App.live?(%{source: ""})
      refute App.live?(%{source: "   "})
    end

    test "anything else is playing" do
      assert App.live?(%{source: "bd*4"})
      assert App.live?(%{source: " hh*8 "})
    end

    test "tab comments the slot out and back in" do
      state = app(patterns: ["bd*4"]) |> press(:tab)
      assert source(state) == "-- bd*4"
      refute App.live?(Enum.at(state.slots, 0))

      back = press(state, :tab)
      assert source(back) == "bd*4"
      assert App.live?(Enum.at(back.slots, 0))
    end
  end

  describe "a chain written down the screen" do
    defp chained do
      [
        %{source: "n(\"<0 4>*8\")"},
        %{source: "|> scale(\"g:minor\")"},
        %{source: "  |> transpose(-12) |> pianoroll()"},
        %{source: "s(\"bd!4\")"}
      ]
    end

    test "a row beginning with a pipe carries on the row above it" do
      assert App.continues?(%{source: "|> scale(\"g:minor\")"})
      assert App.continues?(%{source: "   |> gain(0.5)"})
      refute App.continues?(%{source: "s(\"bd\")"})
    end

    test "the rows fold into the sources they actually make" do
      assert [{0, 2, first}, {3, 3, second}] = App.joined(chained())

      assert first =~ "scale"
      assert first =~ "transpose"
      assert second == "s(\"bd!4\")"
    end

    test "the whole chain plays as one row, not as three broken ones" do
      assert TuningFork.Pattern.first_cycle(App.combined(chained())) |> length() == 12
    end

    test "what the chain asks for is read from the whole of it" do
      assert App.asks?(App.chain(chained(), 0)) == :pianoroll
    end

    test "an error anywhere in a chain is reported on the row it starts" do
      state = App.checked(app(patterns: ["n(\"0 4\")", "|> wobble(3)"]))

      assert Enum.at(state.slots, 0).error =~ "wobble"
      assert Enum.at(state.slots, 1).error == nil
    end

    test "a continuation with nothing above it is dropped rather than run alone" do
      assert App.joined([%{source: "|> gain(0.5)"}]) == []
    end

    test "parking the first row parks the whole chain" do
      slots = [%{source: "_ n(\"0 4\")"}, %{source: "|> scale(\"g:minor\")"}]

      assert App.joined(slots) == []
      assert TuningFork.Pattern.first_cycle(App.combined(slots)) == []
    end
  end

  describe "what gets played" do
    test "every live slot is stacked together" do
      slots = [%{source: "bd*2"}, %{source: "hh*4"}]

      assert TuningFork.Pattern.first_cycle(App.combined(slots)) |> length() == 6
    end

    test "commented and empty slots are left out" do
      slots = [%{source: "bd*2"}, %{source: "-- hh*4"}, %{source: ""}]

      assert TuningFork.Pattern.first_cycle(App.combined(slots)) |> length() == 2
    end

    test "a slot that will not parse is left out rather than failing the rest" do
      slots = [%{source: "bd*2"}, %{source: "hh ["}]

      assert TuningFork.Pattern.first_cycle(App.combined(slots)) |> length() == 2
    end

    test "nothing live at all is silence rather than a crash" do
      assert TuningFork.Pattern.first_cycle(App.combined([%{source: ""}])) == []
    end
  end

  describe "reporting what will not parse" do
    test "a broken slot gets its reason recorded" do
      state = app(patterns: ["bd ["]) |> App.checked()

      assert Enum.at(state.slots, 0).error =~ "unclosed"
    end

    test "a slot that parses has no error" do
      state = app(patterns: ["bd*4"]) |> App.checked()

      assert Enum.at(state.slots, 0).error == nil
    end

    test "a commented slot is not checked, however broken it looks" do
      state = app(patterns: ["-- bd ["]) |> App.checked()

      assert Enum.at(state.slots, 0).error == nil
    end

    test "the reason drops the prefix, since the screen has no room for it" do
      state = app(patterns: ["bd %"]) |> App.checked()

      refute Enum.at(state.slots, 0).error =~ "mini-notation:"
      assert Enum.at(state.slots, 0).error =~ "means nothing here"
    end
  end

  describe "the punchcard" do
    test "a note shows where it begins" do
      drawn = App.punchcard(%{source: "bd*4"}, 0.0)

      assert String.length(drawn) == 32
      assert String.at(drawn, 8) == "█"
      assert String.at(drawn, 16) == "█"
    end

    test "the playhead is where the cycle has reached" do
      drawn = App.punchcard(%{source: "~"}, 0.5)

      assert String.at(drawn, 16) == "│"
    end

    test "a note under the playhead shows as both" do
      drawn = App.punchcard(%{source: "bd*4"}, 0.25)

      assert String.at(drawn, 8) == "▓"
    end

    test "a commented slot draws nothing but the playhead" do
      drawn = App.punchcard(%{source: "-- bd*4"}, 0.0)

      refute drawn =~ "█"
    end

    test "a slot that will not parse draws nothing rather than crashing" do
      assert App.punchcard(%{source: "bd ["}, 0.0) =~ "·"
    end

    test "it follows the cycle, so a pattern that alternates changes with it" do
      first = App.punchcard(%{source: "<bd ~>"}, 0.0)
      second = App.punchcard(%{source: "<bd ~>"}, 1.0)

      refute first == second
    end
  end

  describe "what it draws" do
    test "a row and a punchcard for every slot" do
      drawn = lines(app())

      assert Enum.any?(drawn, &(&1 =~ "bd"))
      assert Enum.any?(drawn, &(&1 =~ "cycle"))
      assert Enum.any?(drawn, &(&1 =~ "cps"))
    end

    test "the slot being edited is marked and shows a cursor" do
      drawn = app() |> lines()

      assert Enum.any?(drawn, &(&1 =~ "▸"))
      assert Enum.any?(drawn, &(&1 =~ "[" or &1 =~ "█"))
    end

    test "an error is drawn under the slot it belongs to" do
      drawn = app(patterns: ["bd ["]) |> App.checked() |> lines()

      assert Enum.any?(drawn, &(&1 =~ "unclosed"))
    end

    test "the count of playing slots is what is actually live" do
      drawn = app(patterns: ["bd", "-- sn", "hh"]) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "2 on"))
    end
  end

  describe "slots that hold code" do
    defp riff, do: "n(\"<0 4 0 9 7>*16\") |> scale(\"g:minor\") |> transpose(-12)"

    test "a control chain plays as well as mini-notation does" do
      slots = [%{source: "bd*4"}, %{source: riff()}]

      assert length(TuningFork.Pattern.first_cycle(App.combined(slots))) == 20
    end

    test "the notes are the ones the chain names" do
      notes =
        [%{source: riff()}]
        |> App.combined()
        |> TuningFork.Pattern.first_cycle()
        |> Enum.take(5)
        |> Enum.map(fn {_from, _to, controls} -> TuningFork.Kit.midi(controls) end)

      assert notes == [43, 50, 43, 58, 55]
    end

    test "code that will not compile is reported, not silently dropped" do
      state = app(patterns: ["n(\"0 4\""]) |> App.checked()

      assert Enum.at(state.slots, 0).error =~ "missing terminator"
    end

    test "a broken code slot leaves the others playing" do
      slots = [%{source: "bd*2"}, %{source: "n(\"0 4\""}]

      assert length(TuningFork.Pattern.first_cycle(App.combined(slots))) == 2
    end

    test "the demo opens with both kinds, so both are visible from the start" do
      assert Enum.any?(App.demo(), &Source.starts_code?/1)
      refute Enum.all?(App.demo(), &Source.starts_code?/1)
    end
  end

  describe "the pianoroll" do
    test "pitched notes draw as a roll rather than a punchcard" do
      rows = App.pianoroll(%{source: "note(\"c3 e3 g3 c4\")"}, 0.0)

      assert length(rows) == 5
      assert Enum.any?(rows, &(&1 =~ "█"))
    end

    test "the rows are as wide as the punchcard, so they line up under it" do
      [row | _rest] = App.pianoroll(%{source: "note(\"c3 g3\")"}, 0.0)

      assert String.length(row) == String.length(App.punchcard(%{source: "bd"}, 0.0))
    end

    test "higher notes sit above lower ones" do
      rows = App.pianoroll(%{source: "note(\"c3 c5\")"}, 0.0)
      top = Enum.find_index(rows, &(&1 =~ "█"))
      bottom = rows |> Enum.reverse() |> Enum.find_index(&(&1 =~ "█"))

      assert top == 0, "the high note should be on the top row"
      assert bottom == 0, "the low note should be on the bottom row"
    end

    test "a single pitch still draws rather than dividing by nothing" do
      rows = App.pianoroll(%{source: "note(\"c3\")"}, 0.0)

      assert Enum.any?(rows, &(&1 =~ "█"))
    end

    test "drums have no pitch, so they keep their punchcard" do
      assert App.pianoroll(%{source: "bd*4"}, 0.0) == []
    end

    test "a commented or broken slot draws no roll" do
      assert App.pianoroll(%{source: "-- note(\"c3\")"}, 0.0) == []
      assert App.pianoroll(%{source: "note(\"c3\""}, 0.0) == []
    end

    test "the playhead runs through it" do
      rows = App.pianoroll(%{source: "note(\"c3 c5\")"}, 0.5)

      assert Enum.any?(rows, &(String.at(&1, 16) in ["│", "█"]))
    end

    test "a pitched slot gets a roll and no punchcard of its own" do
      drawn = app(patterns: [riff()]) |> lines()
      at = Enum.find_index(drawn, &(&1 =~ "scale("))

      under = Enum.slice(drawn, (at + 1)..(at + 5))

      assert Enum.all?(under, &(not (&1 =~ "·"))), "a roll should not be dotted like a punchcard"
      assert Enum.any?(under, &(&1 =~ "█"))
    end
  end

  describe "the pianoroll under the playhead" do
    test "the sounding note is drawn hollow and the rest filled" do
      early = App.raster(%{source: "note(\"c3 g3\")"}, 4.1)
      late = App.raster(%{source: "note(\"c3 g3\")"}, 4.9)

      refute early == late, "which note is hollow should follow the playhead"
    end

    test "a picture is drawn per cycle for an alternating pattern" do
      one = App.raster(%{source: "<bd*2 bd*4>"}, 0.5)
      other = App.raster(%{source: "<bd*2 bd*4>"}, 1.5)

      refute one == other
    end
  end

  describe "the reference" do
    test "it lists every drum family the kit has" do
      text = Enum.join(App.reference(), "\n")

      for {family, _sounds} <- TuningFork.Kit.families() do
        assert text =~ to_string(family)
      end
    end

    test "every name it lists is one the kit will actually play" do
      listed =
        App.reference()
        |> Enum.join(" ")
        |> String.split(~r/[\s\/]+/)
        |> Enum.filter(&(&1 in TuningFork.Kit.drums()))

      assert length(listed) > 10

      for name <- listed do
        assert TuningFork.Kit.voice(name, 0.25), "#{name} is listed but makes no sound"
      end
    end

    test "it covers the notation as well as the names" do
      text = Enum.join(App.reference(), "\n")

      assert text =~ "bd(3,8)"
      assert text =~ "<bd sn>"
      assert text =~ "a rest"
    end

    test "question mark opens it and closes it again" do
      opened = app() |> press(:"?")
      assert opened.help

      refute press(opened, :"?").help
    end

    test "it replaces the slots on screen rather than sitting beside them" do
      drawn = app() |> press(:"?") |> lines()

      assert Enum.any?(drawn, &(&1 =~ "euclidean"))
      refute Enum.any?(drawn, &(&1 =~ "bd(3,8)█"))
    end
  end

  describe "the speed" do
    test "it is held between sensible limits" do
      fast = app(cps: 1.0) |> press(List.duplicate({:f, [:ctrl]}, 40))
      slow = app(cps: 1.0) |> press(List.duplicate({:d, [:ctrl]}, 40))

      assert fast.cps <= 8.0
      assert slow.cps >= 0.05
    end

    test "the arrows are left to the terminal, which usually claims them" do
      state = app(cps: 1.0)

      assert App.update({:key, :up, [:ctrl]}, state).cps == 1.0
      assert App.update({:key, :down, [:ctrl]}, state).cps == 1.0
    end
  end

  describe "growing the rows" do
    test "the screen starts with room below what was opened" do
      state = app(patterns: ["bd*4"])

      assert length(state.slots) > 1
      assert Enum.at(state.slots, 1).source == ""
    end

    test "moving down onto the last row adds another" do
      state = app(patterns: ["bd*4"])
      was = length(state.slots)

      grown = press(state, List.duplicate(:down, was + 2))

      assert length(grown.slots) > was
      assert grown.slot == was + 2
    end

    test "there are always spare rows below the last one in use" do
      state = app(patterns: ["bd*4"]) |> press(List.duplicate(:down, 30)) |> App.room()
      last = state.slots |> Enum.map(& &1.source) |> Enum.find_index(&(&1 != ""))

      assert length(state.slots) - last >= App.spare()
    end

    test "typing far down still lands in the right row" do
      state = app(patterns: [""]) |> press(List.duplicate(:down, 12)) |> type("bd*4")

      assert source(state) == "bd*4"
      assert state.slot == 12
    end
  end

  describe "showing what is sounding" do
    test "a plain notation row points at the token playing now" do
      assert App.sounding(%{source: "~ cp ~ cp"}, 0.3) == {2, 4}
      assert App.sounding(%{source: "~ cp ~ cp"}, 0.8) == {7, 9}
    end

    test "a rest is nothing sounding, not the token beside it" do
      assert App.sounding(%{source: "~ cp ~ cp"}, 0.1) == nil
    end

    test "a code row points inside its notation string" do
      source = "n(\"<0 4 0 9 7>\")"

      assert {from, to} = App.sounding(%{source: source}, 1.0)
      assert String.slice(source, from, to - from) == "4"
    end

    test "an alternation moves along, cycle by cycle" do
      source = "<0 4 0 9 7>"
      seen = for at <- 0..4, do: App.sounding(%{source: source}, at * 1.0)

      assert seen == [{1, 2}, {3, 4}, {5, 6}, {7, 8}, {9, 10}]
    end

    test "a parked row points at nothing" do
      assert App.sounding(%{source: "-- ~ cp ~ cp"}, 0.3) == nil
      assert App.sounding(%{source: "_ ~ cp ~ cp"}, 0.3) == nil
    end

    test "a row that will not parse points at nothing rather than crashing" do
      assert App.sounding(%{source: "bd ["}, 0.3) == nil
      assert App.sounding(%{source: "n(\"bd [\")"}, 0.3) == nil
    end

    test "the token is bracketed in the line, like the reference does" do
      assert App.decorate("~ cp ~ cp", nil, {2, 4}) == "~ [cp] ~ cp"
      assert App.decorate("<0 4 0 9 7>", nil, {3, 4}) == "<0 [4] 0 9 7>"
    end

    test "the caret shows where the cursor is without disturbing the brackets" do
      assert App.decorate("~ cp ~ cp", 0, {2, 4}) == "▏~ [cp] ~ cp"
      assert App.decorate("~ cp ~ cp", 3, {2, 4}) == "~ [c▏p] ~ cp"
    end

    test "the caret past the end of the line still shows" do
      assert App.decorate("bd", 2, nil) == "bd▏"
    end

    test "nothing sounding and no cursor leaves the line as it was" do
      assert App.decorate("bd*4", nil, nil) == "bd*4"
    end

    test "what is drawn carries the brackets" do
      drawn = app(patterns: ["~ cp ~ cp"]) |> Map.put(:cycle, 4.3) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "[cp]"))
    end
  end

  describe "a scope of its own row" do
    test "it renders the row it is written under, not everything playing" do
      quiet = App.samples(%{source: "~"}, 0.0, 0.5)
      loud = App.samples(%{source: "s(\"bd!4\") |> scope()"}, 0.0, 0.5)

      assert Enum.all?(quiet, &(abs(&1) < 0.01)), "a row of rests should trace nothing"
      assert Enum.any?(loud, &(abs(&1) > 0.05)), "a row of kicks should trace something"
    end

    test "two different rows trace differently" do
      kick = App.samples(%{source: "s(\"bd!4\")"}, 0.0, 0.5)
      hats = App.samples(%{source: "s(\"hh*8\")"}, 0.0, 0.5)

      refute kick == hats
    end

    test "a parked or broken row traces nothing" do
      assert App.samples(%{source: "-- s(\"bd\")"}, 0.0, 0.5) == []
      assert App.samples(%{source: "s(\"bd\""}, 0.0, 0.5) == []
    end

    test "the samples stay in range" do
      trace = App.samples(%{source: "s(\"bd!4\")"}, 0.0, 0.5)

      assert Enum.all?(trace, &(&1 >= -1.0 and &1 <= 1.0))
    end

    test "it is drawn from the note rather than sliding along under the playhead" do
      slot = %{source: "s(\"bd!4\")"}

      shapes =
        for cycle <- [0.05, 0.3, 0.55, 0.8] do
          slot |> App.samples(cycle, 0.5) |> Enum.map(&(&1 / max(App.fade(0.05, 0.5), 1.0e-9)))
        end

      assert length(Enum.uniq(shapes)) == 1,
             "every beat should trace the same note, not a window that has moved on"
    end

    test "a new note redraws it" do
      first = App.samples(%{source: "s(\"bd!4\")"}, 0.13, 0.5)
      second = App.samples(%{source: "s(\"<bd sn>!4\")"}, 1.13, 0.5)

      refute first == second
    end

    test "it traces from the last note, not from the playhead" do
      assert App.struck(elem(Source.parse("s(\"bd!4\")"), 1), 0.6) == 0.5
      assert App.struck(elem(Source.parse("s(\"bd\")"), 1), 3.4) == 3.0
    end

    test "a row that has not sounded yet traces from where it is" do
      assert App.struck(elem(Source.parse("~"), 1), 2.4) == 2.4
    end
  end

  describe "the mouse" do
    defp click(state, x, y), do: App.update({:mouse, %{type: :mouse_down, x: x, y: y}}, state)

    test "clicking the transport line plays and pauses" do
      state = app()
      assert state.playing

      assert refute_playing = click(state, 1, App.transport_row())
      refute refute_playing.playing
    end

    test "clicking a row puts the cursor where it was clicked" do
      state = app(patterns: ["bd*4 sn"], pixels: false)
      [{0, top, _height}] = Enum.take(App.layout(state), 1)
      slot = Enum.at(state.slots, 0)

      {5, screen} =
        "bd*4 sn"
        |> App.columns(slot.cursor, App.sounding(slot, state.cycle))
        |> Enum.at(5)

      clicked = click(state, 1 + 4 + screen, top)

      assert clicked.slot == 0
      assert Enum.at(clicked.slots, 0).cursor == 5
    end

    test "clicking past the end of a line puts the cursor at the end" do
      state = app(patterns: ["bd"], pixels: false)
      [{0, top, _height}] = Enum.take(App.layout(state), 1)

      assert click(state, 200, top) |> Map.get(:slots) |> Enum.at(0) |> Map.get(:cursor) == 2
    end

    test "clicking a lower row moves to it" do
      state = app(patterns: ["bd", "sn", "hh"], pixels: false)
      {2, top, _height} = App.layout(state) |> Enum.at(2)

      assert click(state, 5, top).slot == 2
    end

    test "the rows a slot takes up include what it draws underneath" do
      state = app(patterns: ["bd*4", "sn"], pixels: false)
      [{0, first, height}, {1, second, _}] = Enum.take(App.layout(state), 2)

      assert first == App.rows_above()
      assert second == first + height
      assert height > 1, "a punchcard is drawn under the row in text mode"
    end

    test "a click above the first row is nothing at all" do
      assert App.spot(app(), 4, 0) == nil
    end

    test "the help screen swallows clicks rather than editing behind it" do
      state = %{app() | help: true}

      assert App.spot(state, 5, 5) == nil
    end
  end

  describe "screen columns against source columns" do
    test "a plain line maps one to one" do
      assert App.columns("bd", nil, nil) == [{0, 0}, {1, 1}, {2, 2}]
    end

    test "the brackets round what is sounding push the rest along" do
      assert App.columns("bd", nil, {0, 1}) == [{0, 1}, {1, 3}, {2, 4}]
    end

    test "the cursor bar pushes it along too" do
      assert App.columns("bd", 0, nil) == [{0, 1}, {1, 2}, {2, 3}]
    end

    test "clicking a decorated line still lands on the character clicked" do
      state = app(patterns: ["~ cp ~ cp"], pixels: false)
      [{0, top, _height}] = Enum.take(App.layout(state), 1)

      for column <- 0..9 do
        {at, screen} =
          App.columns("~ cp ~ cp", 9, App.sounding(%{source: "~ cp ~ cp"}, 0.0))
          |> Enum.at(column)

        assert click(state, 1 + 4 + screen, top)
               |> Map.get(:slots)
               |> Enum.at(0)
               |> Map.get(:cursor) == at
      end
    end
  end

  describe "the scope pulsing on the beat" do
    test "a note lands at full height" do
      assert App.fade(0.0, 0.5) == 1.0
    end

    test "it falls away as the note ages" do
      assert App.fade(0.4, 0.5) < App.fade(0.05, 0.5)
    end

    test "it never falls all the way out of sight" do
      assert App.fade(50.0, 0.5) > 0.0
    end

    test "it is quantised, so a settled row stops being redrawn" do
      assert App.fade(3.0, 0.5) == App.fade(3.05, 0.5)
    end

    test "the trace is drawn again when the next note lands" do
      slot = %{source: "s(\"bd!4\")"}
      ringing = App.samples(slot, 0.2, 0.5)
      struck = App.samples(slot, 0.25, 0.5)

      refute ringing == struck, "a hit should redraw the scope rather than leave it frozen"
    end
  end

  describe "recovering from a drawer that died" do
    test "a dead drawer does not stop the app drawing forever" do
      state = %{app() | drawing: true}

      assert App.update({:DOWN, make_ref(), :process, self(), :boom}, state).drawing == false
    end
  end

  describe "play and pause" do
    test "it starts playing" do
      assert app().playing
    end

    test "ctrl+p stops it and starts it again" do
      paused = app() |> press([{:p, [:ctrl]}])

      refute paused.playing
      assert paused.said =~ "paused"

      assert paused |> press([{:p, [:ctrl]}]) |> Map.get(:playing)
    end

    test "paused, a tick changes nothing, so nothing is redrawn" do
      paused = app() |> press([{:p, [:ctrl]}])

      assert App.update(:tick, paused) == paused
    end

    test "paused, the level reads as silence rather than sticking where it stopped" do
      paused = %{app() | level: 0.8} |> press([{:p, [:ctrl]}])

      assert paused.level == 0.0
    end

    test "the text says which it is" do
      assert Enum.any?(lines(app()), &(&1 =~ "cycle"))

      paused = app() |> press([{:p, [:ctrl]}])

      assert Enum.any?(lines(paused), &(&1 =~ "❙❙"))
    end

    test "editing still works while paused" do
      typed = app(patterns: [""]) |> press([{:p, [:ctrl]}]) |> type("bd*4")

      assert source(typed) == "bd*4"
      refute typed.playing
    end
  end

  describe "how much gets drawn" do
    test "a row is drawn only when it asks to be" do
      assert App.asks?(%{source: "bd*4"}) == nil
      assert App.asks?(%{source: "s(\"bd*4\") |> pianoroll()"}) == :pianoroll
      assert App.asks?(%{source: "s(\"bd*4\") |> scope()"}) == :scope
    end

    test "a parked row asks for nothing, however it was written" do
      assert App.asks?(%{source: "_ s(\"bd*4\") |> pianoroll()"}) == nil
    end

    test "a row that will not parse asks for nothing rather than crashing" do
      assert App.asks?(%{source: "s(\"bd\" |> pianoroll()"}) == nil
    end

    test "only the rows that ask get a picture" do
      asked = "s(\"bd*4\") |> pianoroll()"
      state = app(patterns: ["bd*4", asked, "-- " <> asked, "hh*8"], pixels: true)

      assert Map.keys(App.rasters(state, 0.0)) == [1]
    end

    test "nothing asking means nothing sent to the terminal at all" do
      state = app(patterns: ["bd*4", "hh*8", "~ cp ~ cp"], pixels: true)

      assert App.rasters(state, 0.0) == %{}
    end

    test "the pictures are built somewhere else, not on the app's own process" do
      state = app(patterns: ["s(\"bd*4\") |> pianoroll()"], pixels: true)

      assert state.rasters == %{}

      asked = App.update(:tick, state)

      assert asked.drawing, "a drawing process should have been started"
      assert asked.rasters == %{}, "the tick itself should not have built anything"

      assert_receive {:drawn, rasters}, 2_000
      assert map_size(rasters) == 1
      assert App.update({:drawn, rasters}, asked).rasters == rasters
    end

    test "drawing again while one is still going is dropped rather than piling up" do
      state = %{app(pixels: true) | drawing: true}

      assert App.update(:tick, state).drawing
      refute_receive {:drawn, _rasters}, 200
    end

    test "a finished drawing clears the flag, so the next tick draws again" do
      state = %{app(pixels: true) | drawing: true}

      refute App.update({:drawn, %{}}, state).drawing
    end
  end

  describe "a pasted Strudel piece" do
    test "evaluating takes the tempo the piece sets" do
      state =
        app(patterns: ["setcps(1.25)", "$: s(\"bd*4\").gain(.8)"], cps: 0.5)
        |> press([{:e, [:ctrl]}])

      assert state.cps == 1.25
      assert state.said =~ "evaluated"
      assert Enum.all?(state.slots, &is_nil(&1.error))
    end

    test "a piece with no setcps keeps the tempo it had" do
      state = app(patterns: ["$: s(\"bd*4\")"], cps: 0.5) |> press([{:e, [:ctrl]}])

      assert state.cps == 0.5
    end
  end

  describe "keys that a terminal will actually send" do
    test "ctrl+e evaluates, since ctrl+enter is not sent by every terminal" do
      assert App.update({:key, :e, [:ctrl]}, app()).said =~ "evaluated"
    end

    test "ctrl+r evaluates straight away" do
      assert App.update({:key, :r, [:ctrl]}, app()).said =~ "evaluated"
    end

    test "ctrl+enter still evaluates where a terminal does send it" do
      assert App.update({:key, :enter, [:ctrl]}, app()).said =~ "evaluated"
    end

    test "plain enter splits the line rather than evaluating" do
      state = app(patterns: ["bdsn"]) |> press([:home, :right, :right, :enter])

      assert source(state, 0) == "bd"
      assert source(state, 1) == "sn"
    end

    test "comma and full stop change the speed when a modifier is held" do
      quicker = app(cps: 1.0) |> press([{:., [:alt]}])
      slower = app(cps: 1.0) |> press([{:",", [:alt]}])

      assert quicker.cps > 1.0
      assert slower.cps < 1.0
    end

    test "bare comma and full stop are still typed, not swallowed" do
      state = app(patterns: [""]) |> type("bd(3,8)")

      assert source(state) == "bd(3,8)"
      assert app(patterns: [""]) |> type("0.5") |> source() == "0.5"
    end

    test "ctrl+f and ctrl+d change the speed too, for terminals with no alt" do
      assert app(cps: 1.0) |> press([{:f, [:ctrl]}]) |> Map.get(:cps) > 1.0
      assert app(cps: 1.0) |> press([{:d, [:ctrl]}]) |> Map.get(:cps) < 1.0
    end

    test "ctrl+h is left alone, being the same byte as backspace" do
      state = app(patterns: ["bd"])

      assert App.update({:key, :h, [:ctrl]}, state) == state
    end
  end

  describe "keys that do other things" do
    test "ctrl+k empties the slot" do
      state = app(patterns: ["bd*4"]) |> press([{:k, [:ctrl]}])

      assert source(state) == ""
    end

    test "ctrl+q leaves" do
      assert {:stop, :normal} = App.update({:key, :q, [:ctrl]}, app())
    end

    test "a tick moves the cycle on without touching the text" do
      before = app()
      after_tick = App.update(:tick, before)

      assert after_tick.slots == before.slots
    end

    test "messages it has no use for leave it alone" do
      state = app()

      assert App.update(:something_else, state) == state
      assert App.update({:key, :f13}, state) == state
    end
  end
end

defmodule TuningFork.LiveCodeAppTest do
  @moduledoc """
  The live-coding front end, driven without a terminal or a sound device.

  A reducer is a function from a message and a state to a state, so every key can be pressed
  from a test. Sound is not asserted on here — that belongs to `TuningFork.Pattern.Player` —
  only what the keys do to the text, which slots are live, and what gets drawn.
  """

  use ExUnit.Case, async: true

  alias TuningFork.LiveCodeApp, as: App

  defp app(opts \\ []) do
    App.mount(
      opts
      |> Map.new()
      |> Map.put_new(:pixels, false)
      |> Map.put_new(:sink, TuningFork.Sink.Silent)
    )
  end

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
  end

  describe "typing" do
    test "the arrows move along the line and typing lands where they left it" do
      state = app(patterns: [""]) |> type("bdsn") |> press([:left, :left]) |> type("_")

      assert source(state) == "bd_sn"
    end

    test "backspace rubs out behind the cursor" do
      state = app(patterns: [""]) |> type("bd*4") |> press(:backspace)

      assert source(state) == "bd*"
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
  end

  describe "switching slots off" do
    test "tab comments the slot out and back in" do
      state = app(patterns: ["bd*4"]) |> press(:tab)
      assert source(state) == "-- bd*4"
      refute App.live?(Enum.at(state.slots, 0))

      back = press(state, :tab)
      assert source(back) == "bd*4"
      assert App.live?(Enum.at(back.slots, 0))
    end
  end

  describe "reporting what will not parse" do
    test "a broken slot gets its reason recorded" do
      state = app(patterns: ["bd ["]) |> App.checked()

      assert Enum.at(state.slots, 0).error =~ "unclosed"
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
  end

  describe "what it draws" do
    test "an error is drawn under the slot it belongs to" do
      drawn = app(patterns: ["bd ["]) |> App.checked() |> lines()

      assert Enum.any?(drawn, &(&1 =~ "unclosed"))
    end

    test "the count of playing slots is what is actually live" do
      drawn = app(patterns: ["bd", "-- sn", "hh"]) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "2 on"))
    end
  end

  defp riff, do: "n(\"<0 4 0 9 7>*16\") |> scale(\"g:minor\") |> transpose(-12)"

  describe "the pianoroll" do
    test "pitched notes draw as a roll rather than a punchcard" do
      rows = App.pianoroll(%{source: "note(\"c3 e3 g3 c4\")"}, 0.0)

      assert length(rows) == 5
      assert Enum.any?(rows, &(&1 =~ "█"))
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
    test "a picture is drawn per cycle for an alternating pattern" do
      one = App.raster(%{source: "<bd*2 bd*4>"}, 0.5)
      other = App.raster(%{source: "<bd*2 bd*4>"}, 1.5)

      refute one == other
    end
  end

  describe "the reference" do
    test "question mark opens it and closes it again" do
      opened = app() |> press(:"?")
      assert opened.help

      refute press(opened, :"?").help
    end
  end

  describe "the speed" do
    test "it is held between sensible limits" do
      fast = app(cps: 1.0) |> press(List.duplicate({:f, [:ctrl]}, 40))
      slow = app(cps: 1.0) |> press(List.duplicate({:d, [:ctrl]}, 40))

      assert fast.cps <= 8.0
      assert slow.cps >= 0.05
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

    test "typing far down still lands in the right row" do
      state = app(patterns: [""]) |> press(List.duplicate(:down, 12)) |> type("bd*4")

      assert source(state) == "bd*4"
      assert state.slot == 12
    end
  end

  describe "showing what is sounding" do
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
  end

  describe "screen columns against source columns" do
    test "a plain line maps one to one" do
      assert App.columns("bd", nil, nil) == [{0, 0}, {1, 1}, {2, 2}]
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

  describe "recovering from a drawer that died" do
    test "a dead drawer does not stop the app drawing forever" do
      state = %{app() | drawing: true}

      assert App.update({:DOWN, make_ref(), :process, self(), :boom}, state).drawing == false
    end
  end

  describe "play and pause" do
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
  end

  describe "how much gets drawn" do
    test "only the rows that ask get a picture" do
      asked = "s(\"bd*4\") |> pianoroll()"
      state = app(patterns: ["bd*4", asked, "-- " <> asked, "hh*8"], pixels: true)

      assert Map.keys(App.rasters(state, 0.0)) == [1]
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
  end

  describe "keys that do other things" do
  end
end

defmodule TuningFork.LoopsAppTest do
  @moduledoc """
  The loop-coding front end, driven without a terminal.

  A reducer is a function from a message and a state to a state, so every key can be pressed
  from a test. `app/1` always hands `mount/1` a `:sink` of `TuningFork.Sink.Silent`, which is
  what makes every test deterministic: `App.playable?/1` would otherwise follow
  `TuningFork.available?/0`, which depends on whatever audio hardware the machine running the
  tests happens to have. With a sink given, `mount/1` starts a real `TuningFork.Stage` — so
  `Stage.loops/1`, `start_loop/4`, `update_loop/4` and `stop_loop/2` are all exercised for
  real — but nothing is written anywhere a person could hear it.

  `async: false` because each test starts its own `TuningFork.Stage`, a process with a writer
  of its own.
  """

  use ExUnit.Case, async: false

  alias TuningFork.LoopsApp, as: App
  alias TuningFork.Part.Source
  alias TuningFork.{Sink, Stage}

  defp app(opts \\ []) do
    opts |> Keyword.new() |> Keyword.put_new(:sink, Sink.Silent) |> App.mount()
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
    |> Enum.reduce(state, fn char, acc -> App.update({:key, String.to_atom(char)}, acc) end)
  end

  defp source(state, index \\ nil), do: Enum.at(state.loops, index || state.loop).source
  defp cursor(state, index \\ nil), do: Enum.at(state.loops, index || state.loop).cursor

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
    test "it opens on the demo loops, on the first one" do
      state = app()

      assert length(state.loops) == 2
      assert state.loop == 0
      assert Enum.map(state.loops, & &1.name) == ["drums", "bass"]
    end

    test "it can be given the loops to open on" do
      state = app(loops: [{"kick", "part(bpm: 120)"}, {"snare", ""}])

      assert source(state, 0) == "part(bpm: 120)"
      assert Enum.at(state.loops, 1).name == "snare"
    end

    test "an empty list still opens on something rather than nothing" do
      state = app(loops: [])

      assert length(state.loops) == 1
    end

    test "given a sink, it starts playing what evaluates straight away" do
      state = app(loops: [{"drums", "part(bpm: 120) |> play(:c3, 1)"}])

      assert is_pid(state.stage)
      assert Map.has_key?(Stage.loops(state.stage), "drums")
    end

    test "without a sink or a stage, playability follows the real hardware check" do
      assert TuningFork.available?() == App.playable?(%{stage: nil, sink: nil})
    end
  end

  describe "typing" do
    test "characters go in at the cursor" do
      state = app(loops: [{"a", ""}]) |> type("bd")

      assert source(state) == "bd"
    end

    test "the arrows move along the source and typing lands where they left it" do
      state = app(loops: [{"a", ""}]) |> type("ac") |> press(:left) |> type("b")

      assert source(state) == "abc"
    end

    test "backspace rubs out behind the cursor" do
      state = app(loops: [{"a", "abc"}]) |> press(:backspace)

      assert source(state) == "ab"
    end

    test "backspace at the very start does nothing" do
      state = app(loops: [{"a", "bd"}]) |> press([:home, :backspace])

      assert source(state) == "bd"
    end

    test "delete rubs out ahead of the cursor" do
      state = app(loops: [{"a", "abc"}]) |> press([:home, :delete])

      assert source(state) == "bc"
    end

    test "home and end go to the ends of a single-line source" do
      state = app(loops: [{"a", "abc"}]) |> press(:home)
      assert cursor(state) == 0

      state = app(loops: [{"a", "abc"}]) |> press([:home, :end])
      assert cursor(state) == 3
    end

    test "the cursor stops at the ends rather than running off" do
      state = app(loops: [{"a", "bd"}]) |> press(List.duplicate(:left, 10))
      assert cursor(state) == 0

      state = app(loops: [{"a", "bd"}]) |> press(List.duplicate(:right, 10))
      assert cursor(state) == 2
    end

    test "enter breaks the line rather than evaluating" do
      state = app(loops: [{"a", "ab"}]) |> press([:home, :right, :enter])

      assert source(state) == "a\nb"
      assert cursor(state) == 2
    end

    test "a new loop starts with the cursor at the end of whatever it opened with" do
      assert app(loops: [{"a", "abc"}]) |> cursor() == 3
    end
  end

  describe "moving around a multi-line loop" do
    test "up moves to the line above, clamping the column to how wide it is" do
      state = app(loops: [{"a", "abcde\nfg"}]) |> press([:home, :right, :right, :right, :down])

      assert cursor(state) == String.length("abcde") + 1 + 2,
             "column 3 on the first line is column 2 on the shorter second one"
    end

    test "up stops at the first line rather than going negative" do
      state = app(loops: [{"a", "ab\ncd"}]) |> press([:up, :up, :up])
      {row, _column} = App.position(String.split(source(state), "\n"), cursor(state))

      assert row == 0
    end

    test "down stops at the last line, where the cursor starts" do
      state = app(loops: [{"a", "ab\ncd"}])
      before = cursor(state)

      assert press(state, :down) |> cursor() == before
    end

    test "home and end work on the line the cursor is on, not the whole source" do
      assert app(loops: [{"a", "abc\ndef"}]) |> press([:up, :home]) |> cursor() == 0
      assert app(loops: [{"a", "abc\ndef"}]) |> press([:up, :end]) |> cursor() == 3

      assert app(loops: [{"a", "abc\ndef"}]) |> press(:home) |> cursor() == 4,
             "the cursor starts on the last line, so home there is not offset 0"
    end

    test "backspace at the start of a line joins it to the one above" do
      state = app(loops: [{"a", "ab\ncd"}]) |> press([:home, :backspace])

      assert source(state) == "abcd"
      assert cursor(state) == 2
    end
  end

  describe "switching loops off" do
    test "tab comments the loop out and back in" do
      state = app(loops: [{"a", "part(bpm: 120)"}]) |> press(:tab)

      assert source(state) =~ "-- "
      refute TuningFork.Session.live?(hd(state.loops))

      back = press(state, :tab)
      assert back |> source() |> String.trim() == "part(bpm: 120)"
      assert TuningFork.Session.live?(hd(back.loops))
    end

    test "a commented loop reports itself as stopped, not broken" do
      state = app(loops: [{"a", "part(bpm: 120)"}]) |> press(:tab)

      refute hd(state.loops).error
      assert Enum.at(state.loops, 0).stopped
    end

    test "commenting a running loop stops it on the stage too" do
      source = "part(bpm: 120) |> play(:c3, 1)"
      state = app(loops: [{"drums", source}])
      assert Map.has_key?(Stage.loops(state.stage), "drums")

      commented = press(state, :tab)
      refute Map.has_key?(Stage.loops(commented.stage), "drums")
    end
  end

  describe "evaluating" do
    test "valid source is kept as the loop's score" do
      source = "part(bpm: 120, synth: Kit.voice(\"bd\", 0.2)) |> play(:c3, 1)"
      state = app(loops: [{"a", source}])

      assert %TuningFork.Score{} = hd(state.loops).score
      refute hd(state.loops).error
    end

    test "a bare part is wrapped in a score" do
      source = "part(bpm: 100) |> play(:c3, 1) |> play(:e3, 1)"
      state = app(loops: [{"a", source}])

      assert %TuningFork.Score{bpm: 100.0} = hd(state.loops).score
    end

    test "source that will not compile is reported, not silently dropped" do
      state = app(loops: [{"a", "part(bpm: 120"}])

      assert hd(state.loops).error
    end

    test "source giving back something other than a score or a part is reported" do
      state = app(loops: [{"a", "1 + 1"}])

      assert hd(state.loops).error =~ "not a score or a part"
    end

    test "a broken edit does not clear a score that already evaluated, and keeps it playing" do
      good = "part(bpm: 120) |> play(:c3, 1)"
      state = app(loops: [{"drums", good}])
      good_score = hd(state.loops).score

      broken =
        state
        |> Map.update!(:loops, fn [loop] -> [%{loop | source: "part(bpm: "}] end)
        |> then(&App.update({:key, :e, [:ctrl]}, &1))

      assert hd(broken.loops).error
      assert hd(broken.loops).score == good_score
      assert Map.has_key?(Stage.loops(broken.stage), "drums")
    end

    test "the app never crashes on source that raises at runtime" do
      state = app(loops: [{"a", "raise \"boom\""}])

      assert hd(state.loops).error =~ "boom"
    end

    test "an empty loop is treated as commented out rather than an error" do
      state = app(loops: [{"a", ""}])

      refute hd(state.loops).error
      assert Enum.at(state.loops, 0).stopped
    end

    test "ctrl+r evaluates immediately, ctrl+e waits for the loop to come round" do
      source = "part(bpm: 120) |> play(:c3, 1)"

      assert app(loops: [{"a", source}]) |> press({:r, [:ctrl]}) |> Map.get(:said) =~
               "evaluated"

      assert app(loops: [{"a", source}]) |> press({:e, [:ctrl]}) |> Map.get(:said) =~
               "evaluated"
    end

    test "ctrl+enter evaluates the same as ctrl+e" do
      source = "part(bpm: 120) |> play(:c3, 1)"
      state = app(loops: [{"a", source}]) |> press({:enter, [:ctrl]})

      assert hd(state.loops).score
    end

    test "re-evaluating an already-running loop updates it rather than adding a second one" do
      first = "part(bpm: 300) |> play(:c3, 0.1)"
      second = "part(bpm: 300) |> play(:e3, 0.1)"

      state =
        app(loops: [{"drums", first}])
        |> Map.update!(:loops, fn [loop] -> [%{loop | source: second}] end)
        |> then(&App.update({:key, :r, [:ctrl]}, &1))

      assert Map.keys(Stage.loops(state.stage)) == ["drums"]
    end
  end

  describe "new loops" do
    test "ctrl+n adds an auto-named loop and selects it" do
      state = app(loops: [{"one", ""}]) |> press({:n, [:ctrl]})

      assert length(state.loops) == 2
      assert state.loop == 1
      assert Enum.at(state.loops, 1).name == "loop1"
    end

    test "the auto-name skips whatever is already taken" do
      state = app(loops: [{"loop1", ""}, {"loop2", ""}]) |> press({:n, [:ctrl]})

      assert Enum.at(state.loops, 2).name == "loop3"
    end

    test "a new loop opens on something that plays, rather than on an empty line" do
      state = app(loops: [{"one", "bd"}]) |> press({:n, [:ctrl]})

      assert source(state) == App.template()
      assert {:ok, _score} = Source.parse(source(state))
    end

    test "typing goes into the new loop, and the cursor is already at the end of it" do
      state = app(loops: [{"one", "bd"}]) |> press({:n, [:ctrl]}) |> type("!")

      assert source(state) == App.template() <> "!"
      assert source(state, 0) == "bd"
    end
  end

  describe "renaming a loop" do
    defp clear_name(state), do: press(state, List.duplicate(:backspace, 40))

    test "f2 opens the name for editing, starting from the one it has" do
      state = app(loops: [{"drums", "bd"}]) |> press(:f2)

      assert state.naming == "drums"
      assert App.footer_text(state) =~ "drums"
    end

    test "ctrl+t opens it too, for a keyboard whose function row is spoken for" do
      state = app(loops: [{"drums", "bd"}]) |> press({:t, [:ctrl]})

      assert state.naming == "drums"
    end

    test "typing and enter renames it" do
      state = app(loops: [{"drums", "bd"}]) |> press(:f2) |> type("kit") |> press(:enter)

      assert hd(state.loops).name == "drumskit"
      assert state.naming == nil
      assert state.said =~ "drums is now drumskit"
    end

    test "backspace rubs the name out rather than the source" do
      state =
        app(loops: [{"drums", "bd"}]) |> press([:f2, :backspace, :backspace]) |> press(:enter)

      assert hd(state.loops).name == "dru"
      assert hd(state.loops).source == "bd"
    end

    test "esc leaves the name as it was" do
      state = app(loops: [{"drums", "bd"}]) |> press(:f2) |> type("xxx") |> press(:escape)

      assert hd(state.loops).name == "drums"
      assert state.naming == nil
    end

    test "a name another loop already holds is refused" do
      state =
        app(loops: [{"drums", "bd"}, {"bass", "bd"}])
        |> press(:f2)
        |> clear_name()
        |> type("bass")
        |> press(:enter)

      assert hd(state.loops).name == "drums"
      assert state.said =~ "bass is taken"
    end

    test "a blank name is refused" do
      state = app(loops: [{"drums", "bd"}]) |> press(:f2) |> clear_name() |> press(:enter)

      assert hd(state.loops).name == "drums"
      assert state.said =~ "a loop needs a name"
    end

    test "a loop keeping its own name is not read as a clash" do
      state = app(loops: [{"drums", "bd"}, {"bass", "bd"}]) |> press([:f2, :enter])

      assert hd(state.loops).name == "drums"
      assert state.naming == nil
    end

    test "the sound moves to the new name rather than carrying on under the old one" do
      source = "part(bpm: 120) |> play(:c3, 1)"

      state =
        app(loops: [{"drums", source}])
        |> press([{:e, [:ctrl]}, :f2])
        |> type("2")
        |> press(:enter)

      assert Map.keys(Stage.loops(state.stage)) == ["drums2"]
    end

    test "while naming, ordinary keys go to the name and ctrl+q still quits" do
      state = app(loops: [{"drums", "bd"}]) |> press(:f2) |> type("?x")

      assert state.naming == "drums?x"
      refute state.help
      assert {:stop, :normal} = App.update({:key, :q, [:ctrl]}, state)
    end
  end

  describe "stopping a loop" do
    test "ctrl+x marks the loop stopped and takes it off the stage, without touching its source" do
      source = "part(bpm: 120) |> play(:c3, 1)"
      state = app(loops: [{"drums", source}]) |> press({:x, [:ctrl]})

      assert hd(state.loops).stopped
      assert hd(state.loops).source == source
      assert state.said =~ "stopped"
      refute Map.has_key?(Stage.loops(state.stage), "drums")
    end

    test "the loop can be evaluated again after being stopped" do
      source = "part(bpm: 120) |> play(:c3, 1)"
      state = app(loops: [{"drums", source}]) |> press([{:x, [:ctrl]}, {:e, [:ctrl]}])

      refute hd(state.loops).stopped
      assert Map.has_key?(Stage.loops(state.stage), "drums")
    end
  end

  describe "play and pause" do
    test "it starts playing" do
      assert app().playing
    end

    test "ctrl+p pauses and plays again" do
      paused = app() |> press({:p, [:ctrl]})

      refute paused.playing
      assert paused.said =~ "paused"
      assert paused |> press({:p, [:ctrl]}) |> Map.get(:playing)
    end

    test "ctrl+p stops every loop on the stage, and ctrl+p again brings them back" do
      source = "part(bpm: 300) |> play(:c3, 0.1)"
      state = app(loops: [{"drums", source}])
      assert Map.has_key?(Stage.loops(state.stage), "drums")

      paused = press(state, {:p, [:ctrl]})
      assert Stage.loops(paused.stage) == %{}

      resumed = press(paused, {:p, [:ctrl]})
      assert Map.has_key?(Stage.loops(resumed.stage), "drums")
    end

    test "a stopped loop is not brought back by ctrl+p" do
      source = "part(bpm: 300) |> play(:c3, 0.1)"

      state =
        app(loops: [{"drums", source}]) |> press([{:x, [:ctrl]}, {:p, [:ctrl]}, {:p, [:ctrl]}])

      refute Map.has_key?(Stage.loops(state.stage), "drums")
    end

    test "editing still works while paused" do
      state = app(loops: [{"a", ""}]) |> press({:p, [:ctrl]}) |> type("bd")

      assert source(state) == "bd"
      refute state.playing
    end

    test "paused, a tick changes nothing" do
      paused = app() |> press({:p, [:ctrl]})

      assert App.update(:tick, paused) == paused
    end
  end

  describe "what it draws" do
    test "every loop's name and source are on screen" do
      drawn = app(loops: [{"drums", "bd sn"}, {"bass", "c2 g2"}]) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "drums" and &1 =~ "bd sn"))
      assert Enum.any?(drawn, &(&1 =~ "bass"))
    end

    test "the summary line counts the loops" do
      drawn = app(loops: [{"a", ""}, {"b", ""}]) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "2 loops"))
    end

    test "an error is drawn under the loop it belongs to" do
      drawn = app(loops: [{"a", "1 + 1"}]) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "not a score"))
    end

    test "a continuation line lines up under where the source begins" do
      drawn = app(loops: [{"bass", "ab\ncd"}]) |> lines()
      at = Enum.find_index(drawn, &(&1 =~ "bass"))
      indent = String.length("bass") + 3

      assert Enum.at(drawn, at + 1) == String.duplicate(" ", indent) <> "cd▏"
    end

    test "a running loop shows its round and beat once the reading has been refreshed" do
      state = app(loops: [{"drums", "part(bpm: 120) |> play(:c3, 1)"}])
      drawn = :tick |> App.update(state) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "round" and &1 =~ "beat"))
    end

    test "question mark opens the help screen and closes it again" do
      opened = app() |> press(:"?")
      assert opened.help

      refute opened |> press(:"?") |> Map.get(:help)
    end

    test "the help screen replaces the loops rather than sitting beside them" do
      drawn = app() |> press(:"?") |> lines()

      assert Enum.any?(drawn, &(&1 =~ "Keys"))
      assert Enum.any?(drawn, &(&1 =~ "TuningFork.Part"))
    end
  end

  describe "the mouse" do
    defp click(state, x, y), do: App.update({:mouse, %{type: :mouse_down, x: x, y: y}}, state)

    test "clicking the summary line plays and pauses" do
      state = app()
      assert state.playing

      refute click(state, 1, App.summary_row()).playing
    end

    test "clicking a loop selects it" do
      state = app(loops: [{"a", "bd sn"}, {"b", "hh"}])
      [{1, top, _height}] = state |> App.layout() |> Enum.filter(&(elem(&1, 0) == 1))

      assert click(state, 0, top).loop == 1
    end

    test "clicking mid-line puts the cursor there" do
      state = app(loops: [{"ab", "hello"}])
      [{0, top, _height}] = App.layout(state)

      clicked = click(state, 1 + String.length("ab") + 3 + 2, top)
      assert cursor(clicked) == 2
    end

    test "a click above the first loop is nothing at all" do
      assert App.spot(app(), 4, 0) == nil
    end

    test "the help screen swallows clicks" do
      state = %{app() | help: true}

      assert App.spot(state, 5, 5) == nil
    end
  end

  describe "layout" do
    test "position and offset_of undo one another for every offset in the source" do
      lines = ["abc", "de", "fghi"]
      total = Enum.reduce(lines, length(lines) - 1, &(&2 + String.length(&1)))

      for cursor <- 0..total do
        {row, column} = App.position(lines, cursor)
        assert App.offset_of(lines, row, column) == cursor
      end
    end

    test "a loop with an error takes up an extra row" do
      [{0, _top, plain_height}] = app(loops: [{"a", "part(bpm: 120)"}]) |> App.layout()
      [{0, _top, broken_height}] = app(loops: [{"a", "1 + 1"}]) |> App.layout()

      assert broken_height == plain_height + 1
    end

    test "a two-line loop takes up more rows than a one-line loop" do
      [{0, _top, one}] = app(loops: [{"a", "bd"}]) |> App.layout()
      [{0, _top, two}] = app(loops: [{"a", "bd\nsn"}]) |> App.layout()

      assert two == one + 1
    end
  end

  describe "messages it has no use for" do
    test "leave the state alone" do
      state = app()

      assert App.update(:something_else, state) == state
      assert App.update({:key, :f13}, state) == state
    end
  end

  test "ctrl+q leaves" do
    assert {:stop, :normal} = App.update({:key, :q, [:ctrl]}, app())
  end
end

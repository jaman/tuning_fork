defmodule TuningFork.ComposerAppTest do
  @moduledoc """
  The terminal front end, driven without a terminal.

  A reducer is a function from a message and a state to a state, so every key can be pressed
  from a test. What is checked here is the front end's own business — where the cursor is,
  what the keys mean, what the screen says — and nothing about composing, which belongs to
  `TuningFork.Composer` and is tested against its own API.
  """

  use ExUnit.Case, async: true

  alias TuningFork.{Composer, ComposerApp}
  alias TuningFork.Composer.Track

  defp app(opts \\ []) do
    opts
    |> Keyword.put_new(:project, Composer.demo())
    |> Keyword.put_new(:sink, TuningFork.Sink.Silent)
    |> ComposerApp.mount()
  end

  defp press(state, keys) do
    keys
    |> List.wrap()
    |> Enum.reduce(state, fn key, acc -> ComposerApp.update({:key, key}, acc) end)
  end

  defp steps(state, index), do: Composer.track(state.project, index).steps

  defp lines(state) do
    walk = fn walk, node ->
      case node do
        {:layout, _direction, children, _opts} -> Enum.flat_map(children, &walk.(walk, &1))
        {:label, text, _opts} -> [text]
        {:header, text, _opts} -> [text]
        _other -> []
      end
    end

    walk.(walk, ComposerApp.render(state))
  end

  describe "starting up" do
    test "it opens on something to hear, with the cursor at the top left" do
      state = app()

      assert Composer.track_count(state.project) > 0
      assert state.track == 0
      assert state.step == 0
    end

    test "it can be given a composition to open on" do
      state = app(project: Composer.new())

      assert Composer.track_count(state.project) == 0
    end
  end

  describe "moving about" do
    test "the arrows move the cursor" do
      state = app() |> press([:right, :right, :down])

      assert state.step == 2
      assert state.track == 1
    end

    test "it stops at the edges rather than wrapping or running off" do
      state = app() |> press([:left, :left, :up, :up])

      assert state.step == 0
      assert state.track == 0

      far = app() |> press(List.duplicate(:right, 40) ++ List.duplicate(:down, 40))

      assert far.step == Composer.steps_per_bar(far.project) - 1
      assert far.track == Composer.track_count(far.project) - 1
    end
  end

  describe "editing" do
    test "space places a note and takes it away again" do
      state = app() |> press([:right, :space])

      assert Enum.at(steps(state, 0), 1) == 1
      assert state |> press(:space) |> steps(0) |> Enum.at(1) == 0
    end

    test "plus and minus walk a pitched note up and down the scale" do
      state = app() |> press([:down, :down, :down, :+, :+])

      assert Enum.at(steps(state, 3), 0) == 3
      assert state |> press(:-) |> steps(3) |> Enum.at(0) == 2
    end

    test "the angle brackets hold a note over the steps that follow" do
      state = app() |> press([:down, :down, :down, :>])

      assert {_degree, 2} = Track.read(Enum.at(steps(state, 3), 0))
      assert {_degree, 1} = state |> press(:<) |> steps(3) |> Enum.at(0) |> Track.read()
    end

    test "m mutes the row the cursor is on" do
      state = app() |> press([:down, :m])

      assert Composer.track(state.project, 1).muted
      refute state |> press(:m) |> Map.fetch!(:project) |> Composer.track(1) |> Map.get(:muted)
    end

    test "a adds a track and puts the cursor on it" do
      before = app()
      state = press(before, :a)

      assert Composer.track_count(state.project) == Composer.track_count(before.project) + 1
      assert state.track == Composer.track_count(state.project) - 1
    end

    test "x removes one and keeps the cursor somewhere real" do
      state = app() |> press([:down, :down, :down, :x, :x, :x, :x, :x])

      assert Composer.track_count(state.project) == 0
      assert state.track == 0
    end

    test "c empties a row without losing it" do
      state = app() |> press(:c)

      assert Composer.track_count(state.project) == Composer.track_count(app().project)
      assert Enum.all?(steps(state, 0), &(&1 == 0))
    end

    test "k cycles what kind of row it is and i cycles its instrument" do
      state = app() |> press(:k)
      assert Composer.track(state.project, 0).kind == :pitched

      sounds = app() |> press(:i) |> Map.fetch!(:project) |> Composer.track(0) |> Map.get(:sound)
      refute sounds == "kick"
    end

    test "keys the app has no use for leave it alone" do
      state = app()

      assert ComposerApp.update({:key, :z}, state) == state
      assert ComposerApp.update(:something_else, state) == state
    end

    test "q leaves" do
      assert {:stop, :normal} = ComposerApp.update({:key, :q}, app())
    end
  end

  describe "what it draws" do
    test "the settings, a ruler and a row for every track" do
      drawn = lines(app())

      assert Enum.any?(drawn, &(&1 =~ "96 bpm"))
      assert Enum.any?(drawn, &(&1 =~ "kick"))
      assert Enum.any?(drawn, &(&1 =~ "bass"))
    end

    test "the cursor is bracketed, so it shows without colour" do
      drawn = app() |> press([:right, :right]) |> lines()

      assert Enum.any?(drawn, &(&1 =~ ~r/\[.\]/u))
    end

    test "the ruler lines up with the grid, three characters to a step" do
      state = app()
      drawn = lines(state)

      ruler = Enum.find(drawn, &(&1 =~ ~r/^\s+1\s/))
      row = Enum.find(drawn, &(&1 =~ "kick"))

      assert String.length(ruler) == String.length(String.trim_trailing(row)) or
               String.length(ruler) >= String.length(row) - 3
    end

    test "a held note is drawn as one, not as a gap" do
      drawn = app() |> press([:down, :down, :down, :>, :>]) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "▬"))
    end

    test "an empty composition says how to start rather than showing nothing" do
      drawn = app(project: Composer.new()) |> lines()

      assert Enum.any?(drawn, &(&1 =~ "no tracks"))
    end
  end

  describe "the mouse" do
    defp press_at(state, x, y, type \\ :mouse_down) do
      ComposerApp.update({:mouse, %{type: type, x: x, y: y, button: :left, mods: []}}, state)
    end

    test "the rows above the grid are where the app thinks they are" do
      drawn = lines(app())
      first_track = Enum.find_index(drawn, &(&1 =~ "kick"))

      assert first_track == ComposerApp.rows_above()
    end

    test "a point on the grid is the track and step drawn there" do
      state = app()

      assert ComposerApp.hit(state, 12, ComposerApp.rows_above()) == {0, 0}
      assert ComposerApp.hit(state, 15, ComposerApp.rows_above()) == {0, 1}
      assert ComposerApp.hit(state, 12, ComposerApp.rows_above() + 2) == {2, 0}
    end

    test "anywhere else is nowhere" do
      state = app()

      assert ComposerApp.hit(state, 0, 0) == nil
      assert ComposerApp.hit(state, 5, ComposerApp.rows_above()) == nil
      assert ComposerApp.hit(state, 12, 0) == nil
      assert ComposerApp.hit(state, 999, ComposerApp.rows_above()) == nil
      assert ComposerApp.hit(state, 12, 999) == nil
    end

    test "pressing moves the cursor there and places a note" do
      state = app() |> press_at(12 + 3, ComposerApp.rows_above())

      assert state.track == 0
      assert state.step == 1
      assert Enum.at(steps(state, 0), 1) == 1
    end

    test "pressing a pitched row again walks it up the scale" do
      y = ComposerApp.rows_above() + 3
      state = app() |> press_at(12, y) |> press_at(12, y)

      assert Composer.track(state.project, 3).kind == :pitched
      assert Enum.at(steps(state, 3), 0) == 3
    end

    test "pressing a drum twice takes the note away again" do
      state = app() |> press_at(12 + 3, ComposerApp.rows_above())

      assert Enum.at(steps(state, 0), 1) == 1
      assert state |> press_at(12 + 3, ComposerApp.rows_above()) |> steps(0) |> Enum.at(1) == 0
    end

    test "pressing off the grid changes nothing" do
      state = app()

      assert press_at(state, 0, 0) == state
    end

    test "dragging right from a note holds it over the steps crossed" do
      y = ComposerApp.rows_above() + 3

      state =
        app()
        |> press_at(12, y)
        |> press_at(12 + 3 * 2, y, :move)

      assert {_degree, 3} = Track.read(Enum.at(steps(state, 3), 0))
      assert state.dragging
    end

    test "dragging onto another row leaves that row alone" do
      pressed = app() |> press_at(12, ComposerApp.rows_above() + 3)
      dragged = press_at(pressed, 12 + 9, ComposerApp.rows_above(), :move)

      assert steps(dragged, 0) == steps(pressed, 0)
      assert steps(dragged, 3) == steps(pressed, 3)
    end

    test "moving over the grid with nothing held changes nothing" do
      state = app()

      assert press_at(state, 12 + 3 * 2, ComposerApp.rows_above(), :move) == state
    end

    test "a drag that ended does not resume when the pointer moves again" do
      y = ComposerApp.rows_above() + 3

      let_go =
        app()
        |> press_at(12, y)
        |> press_at(12, y, :mouse_up)

      assert press_at(let_go, 12 + 3 * 3, y, :move) == let_go
    end

    test "letting go ends the drag" do
      state =
        app()
        |> press_at(12, ComposerApp.rows_above() + 3)
        |> press_at(12 + 6, ComposerApp.rows_above() + 3, :move)
        |> press_at(12, ComposerApp.rows_above() + 3, :mouse_up)

      refute state.dragging
    end

    test "the wheel walks a note up and down where it points" do
      y = ComposerApp.rows_above() + 3

      scroll = fn state, direction ->
        ComposerApp.update({:mouse, %{type: :scroll, direction: direction, x: 12, y: y}}, state)
      end

      up = app() |> scroll.(:up)
      assert Enum.at(steps(up, 3), 0) == 2

      assert up |> scroll.(:down) |> steps(3) |> Enum.at(0) == 1
    end

    test "a cell is three characters wide, and clicking the far one lands there" do
      last = Composer.steps_per_bar(app().project) - 1
      state = app() |> press_at(12 + 3 * last, ComposerApp.rows_above())

      assert state.step == last
    end
  end

  describe "writing it out" do
    @tag :tmp_dir
    test "w writes source that runs on its own", %{tmp_dir: dir} do
      path = Path.join(dir, "song.exs")
      state = app(out: path) |> press(:w)

      assert state.said =~ "wrote"
      assert File.exists?(path)

      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source)
      assert source =~ "import TuningFork.Part"
      refute source =~ "ComposerApp"
    end

    @tag :tmp_dir
    test "an empty composition says so rather than writing an empty file", %{tmp_dir: dir} do
      path = Path.join(dir, "nothing.exs")
      state = app(project: Composer.new(), out: path) |> press(:w)

      assert state.said =~ "nothing to write"
      refute File.exists?(path)
    end
  end

  describe "playing it" do
    test "nothing is playing to begin with" do
      assert app().playing == nil
    end

    test "an empty composition says so rather than failing" do
      state = app(project: Composer.new()) |> press(:p)

      assert state.said =~ "nothing to play"
      assert state.playing == nil
    end

    defp playing(state) do
      {:ok, stage} = Agent.start(fn -> nil end)
      %{state | playing: stage}
    end

    test "pressing p while playing stops it rather than starting a second one" do
      started = playing(app())
      stage = started.playing

      stopped = press(started, :p)

      assert stopped.playing == nil
      assert stopped.said =~ "stopped"
      refute Process.alive?(stage)
    end

    test "only ever one at a time" do
      first = playing(app())
      stage = first.playing

      _second = press(first, :p)

      refute Process.alive?(stage)
    end

    test "quitting takes the audio with it" do
      started = playing(app())
      stage = started.playing

      assert {:stop, :normal} = ComposerApp.update({:key, :q}, started)
      refute Process.alive?(stage)
    end

    test "stopping when nothing plays is harmless" do
      assert ComposerApp.stop_playing(app()).playing == nil
    end

    test "stopping a stage that already died is harmless" do
      {:ok, dead} = Agent.start(fn -> nil end)
      Agent.stop(dead)

      assert ComposerApp.stop_playing(%{app() | playing: dead}).playing == nil
    end

    test "nothing is rendered until something is played" do
      assert app().rendered == nil
    end

    test "playing again after no edit reuses the render" do
      {pcm, first} = ComposerApp.rendered(app())
      {again, second} = ComposerApp.rendered(first)

      assert {project, ^pcm} = first.rendered
      assert project == first.project
      assert again == pcm
      assert second.rendered == first.rendered
    end

    test "an edit throws the render away" do
      {_pcm, played} = ComposerApp.rendered(app())
      edited = press(played, :space)

      {_pcm, replayed} = ComposerApp.rendered(edited)

      refute elem(replayed.rendered, 0) == elem(played.rendered, 0)
    end

    test "the screen says when it is playing" do
      refute Enum.any?(lines(app()), &(&1 =~ "playing"))
      assert Enum.any?(lines(playing(app())), &(&1 =~ "▶ playing"))
    end
  end
end

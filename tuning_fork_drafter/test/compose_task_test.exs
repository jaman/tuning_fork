defmodule TuningFork.ComposeTaskTest do
  @moduledoc """
  Checks the props `mix tuning_fork.compose` builds from its command line, as `mount/1` sees them.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.TuningFork.Compose
  alias TuningFork.{Composer, ComposerApp}

  defp mounted(argv) do
    ComposerApp.mount(Drafter.Runtime.mount_props(props: Compose.props(argv)))
  end

  test "the flags reach the app rather than being dropped on the way" do
    state = mounted(~w(--bpm 140 --bars 4 --meter 3 --division 8 --key c3 --scale blues))

    assert state.project.bpm == 140
    assert state.project.bars == 4
    assert state.project.meter == 3
    assert state.project.division == 8
    assert state.project.root == :c3
    assert state.project.scale == :blues
  end

  test "--out is where w writes" do
    assert mounted(~w(--out beat.exs)).out == "beat.exs"
    assert mounted([]).out == "song.exs"
  end

  test "--empty opens on nothing, and without it there is something to hear" do
    assert Composer.track_count(mounted(~w(--empty)).project) == 0
    assert Composer.track_count(mounted([]).project) > 0
  end

  test "--gain and --name reach it too" do
    state = mounted(~w(--gain 0.8 --name riff))

    assert state.project.gain == 0.8
    assert state.project.name == "riff"
  end

  test "a switch the task does not have is refused rather than ignored" do
    assert_raise OptionParser.ParseError, fn -> Compose.props(~w(--tempo 120)) end
  end
end

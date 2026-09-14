defmodule KinoTuningFork.StageTest do
  use ExUnit.Case, async: false

  import Kino.Test
  use TuningFork.SonicPi

  alias KinoTuningFork.Stage, as: Widget
  alias TuningFork.Stage

  setup :configure_livebook_bridge

  defp widget(opts \\ []) do
    kino = Widget.new(Keyword.merge([rate: 8_000, chunk: 256, name: nil], opts))
    _data = connect(kino)
    kino
  end

  test "it starts a stage and streams what the stage mixes" do
    kino = widget()
    stage = Widget.stage(kino)

    Stage.play(stage, TuningFork.Voice.new(shape: :sine, freq: 440.0))

    assert_broadcast_event(kino, "pcm", {:binary, %{}, chunk}, 2_000)
    assert byte_size(chunk) == 256 * 4
  end

  test "readouts name every loop and its round" do
    kino = widget()
    stage = Widget.stage(kino)

    live_loop :ticking, stage: stage do
      play(60)
      sleep(0.05)
    end

    assert_broadcast_event(
      kino,
      "readouts",
      %{loops: [%{name: "ticking", rounds: _, beat: _}], cycle: nil},
      2_000
    )
  end

  test "a named stage is where a bare live_loop lands, and a second widget takes the name over" do
    first = widget(name: TuningFork.Stage)
    first_stage = Widget.stage(first)

    started =
      live_loop :bare do
        play(60)
        sleep(0.05)
      end

    assert started == :ok

    assert Map.has_key?(Stage.loops(TuningFork.Stage), :bare)

    second = widget(name: TuningFork.Stage)
    refute Process.alive?(first_stage)
    assert Widget.stage(second) == Process.whereis(TuningFork.Stage)
  end

  test "a widget whose stage has gone stays up, quiet, and says so" do
    first = widget(name: TuningFork.Stage)
    _second = widget(name: TuningFork.Stage)

    assert_broadcast_event(first, "closed", %{}, 2_000)
    Process.sleep(600)

    assert Process.alive?(first.pid)
    assert Widget.stage(first) == nil
    push_event(first, "hush", %{})
    assert Process.alive?(first.pid)
  end

  test "hush stops everything" do
    kino = widget()
    stage = Widget.stage(kino)

    live_loop :noisy, stage: stage do
      play(60)
      sleep(0.05)
    end

    push_event(kino, "hush", %{})
    Process.sleep(50)

    assert Stage.loops(stage) == %{}
  end
end

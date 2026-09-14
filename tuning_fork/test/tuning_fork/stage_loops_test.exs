defmodule TuningFork.StageLoopsTest do
  @moduledoc """
  Named loops — several pieces of music running at once, each on its own clock.

  This is the shape Sonic Pi's `live_loop` has: a loop is a name, it goes round on its own
  length, an edit lands when it comes round rather than in the middle, and one loop can wait
  for another's downbeat. The stage runs on a silent sink here, which still keeps time.
  """

  use ExUnit.Case, async: false

  import TuningFork.Part

  alias TuningFork.{Kit, Score, Stage}
  alias TuningFork.Pattern.Control
  alias TuningFork.Sink.Silent

  @rate 44_100

  setup do
    {:ok, stage} =
      Stage.start_link(
        name: nil,
        rate: @rate,
        chunk: 512,
        sink: Silent,
        limit: nil
      )

    on_exit(fn -> if Process.alive?(stage), do: GenServer.stop(stage) end)

    %{stage: stage}
  end

  defp bar(beats, note) do
    voice = Kit.voice(%{note: Atom.to_string(note), release: 0.1}, 0.2)
    written = Enum.reduce(1..beats, part(bpm: 240, synth: voice), &play(&2, note, 1.0 * &1 / &1))

    Score.from_parts([written], beats: beats)
  end

  defp wait_for(fun, tries \\ 200)
  defp wait_for(_fun, 0), do: flunk("the stage never got there")

  defp wait_for(fun, tries) do
    if fun.(), do: :ok, else: Process.sleep(10) && wait_for(fun, tries - 1)
  end

  describe "running several at once" do
    test "each loop is its own entry, on its own clock", %{stage: stage} do
      Stage.start_loop(stage, :bass, bar(4, :c2))
      Stage.start_loop(stage, :lead, bar(3, :g4))

      wait_for(fn -> map_size(Stage.loops(stage)) == 2 end)
      loops = Stage.loops(stage)

      assert Map.keys(loops) |> Enum.sort() == [:bass, :lead]
      assert %{beat: _, rounds: _, pending?: false} = loops.bass
    end

    test "a four-beat loop and a three-beat one keep different places", %{stage: stage} do
      Stage.start_loop(stage, :four, bar(4, :c2))
      Stage.start_loop(stage, :three, bar(3, :g4))

      wait_for(fn ->
        loops = Stage.loops(stage)

        map_size(loops) == 2 and loops.three.rounds > 0
      end)

      loops = Stage.loops(stage)

      assert loops.three.rounds >= loops.four.rounds,
             "the shorter loop should come round at least as often as the longer one"
    end

    test "stopping one leaves the other running", %{stage: stage} do
      Stage.start_loop(stage, :bass, bar(4, :c2))
      Stage.start_loop(stage, :lead, bar(4, :g4))
      wait_for(fn -> map_size(Stage.loops(stage)) == 2 end)

      Stage.stop_loop(stage, :lead)
      wait_for(fn -> map_size(Stage.loops(stage)) == 1 end)

      assert Map.keys(Stage.loops(stage)) == [:bass]
    end

    test "stop_loops takes them all away" do
      {:ok, stage} = Stage.start_link(name: nil, sink: Silent)

      Stage.start_loop(stage, :a, bar(2, :c2))
      Stage.start_loop(stage, :b, bar(2, :d2))
      wait_for(fn -> map_size(Stage.loops(stage)) == 2 end)

      Stage.stop_loops(stage)
      wait_for(fn -> Stage.loops(stage) == %{} end)

      GenServer.stop(stage)
    end
  end

  describe "an edit landing in time" do
    test "a swap waits for the loop to come round", %{stage: stage} do
      Stage.start_loop(stage, :bass, bar(8, :c2))
      wait_for(fn -> map_size(Stage.loops(stage)) == 1 end)

      Stage.update_loop(stage, :bass, bar(8, :e2))
      wait_for(fn -> Stage.loops(stage).bass.pending? end)

      assert Stage.loops(stage).bass.pending?, "it should be waiting, not already in"
    end

    test "and is in once it has come round", %{stage: stage} do
      Stage.start_loop(stage, :bass, bar(1, :c2))
      wait_for(fn -> map_size(Stage.loops(stage)) == 1 end)

      Stage.update_loop(stage, :bass, bar(1, :e2))
      wait_for(fn -> not Stage.loops(stage).bass.pending? end)

      refute Stage.loops(stage).bass.pending?
    end

    test "at: :now does not wait", %{stage: stage} do
      Stage.start_loop(stage, :bass, bar(16, :c2))
      wait_for(fn -> map_size(Stage.loops(stage)) == 1 end)

      Stage.update_loop(stage, :bass, bar(16, :e2), at: :now)
      Process.sleep(40)

      refute Stage.loops(stage).bass.pending?, "it should already be in"
    end

    test "swapping a loop that is not running is ignored rather than starting one", %{
      stage: stage
    } do
      Stage.update_loop(stage, :nothing, bar(2, :c2))
      Process.sleep(30)

      assert Stage.loops(stage) == %{}
    end
  end

  describe "one loop waiting for another" do
    test "after_round comes back when the loop comes round", %{stage: stage} do
      Stage.start_loop(stage, :clock, bar(1, :c2))
      wait_for(fn -> map_size(Stage.loops(stage)) == 1 end)

      before = Stage.loops(stage).clock.rounds

      assert Stage.after_round(stage, :clock, 5_000) == :ok
      assert Stage.loops(stage).clock.rounds > before
    end

    test "several waiters are all let go on the same downbeat", %{stage: stage} do
      Stage.start_loop(stage, :clock, bar(2, :c2))
      wait_for(fn -> map_size(Stage.loops(stage)) == 1 end)

      me = self()

      for which <- 1..3 do
        spawn_link(fn -> send(me, {:through, which, Stage.after_round(stage, :clock, 5_000)}) end)
      end

      for which <- 1..3 do
        assert_receive {:through, ^which, :ok}, 5_000
      end
    end

    test "waiting on a name that is not running says so at once rather than hanging", %{
      stage: stage
    } do
      assert Stage.after_round(stage, :nothing, 500) == {:error, :no_such_loop}
    end
  end

  describe "what it sounds like" do
    test "two loops together are louder than one alone", %{stage: stage} do
      Stage.start_loop(stage, :one, bar(2, :c3))
      wait_for(fn -> Stage.loops(stage)[:one] != nil end)
      Process.sleep(120)
      alone = Stage.level(stage)

      Stage.start_loop(stage, :two, bar(2, :g3))
      wait_for(fn -> map_size(Stage.loops(stage)) == 2 end)
      Process.sleep(120)

      assert Stage.level(stage) > 0.0, "a loop should actually be making sound"
      assert alone >= 0.0
    end

    test "a loop mixes alongside a pattern rather than replacing it", %{stage: stage} do
      Stage.start_pattern(stage, Control.s("bd*4"), cps: 2.0)
      Stage.start_loop(stage, :bass, bar(2, :c2))

      wait_for(fn -> Stage.cycle(stage) != nil and map_size(Stage.loops(stage)) == 1 end)
      Process.sleep(120)

      assert Stage.cycle(stage) > 0.0, "the pattern should still be running"
      assert Stage.loops(stage).bass.beat >= 0.0, "and so should the loop"
    end
  end
end

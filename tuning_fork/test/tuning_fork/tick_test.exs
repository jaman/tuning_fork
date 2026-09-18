defmodule TuningFork.TickTest do
  @moduledoc """
  Counters, rings, and the values loops leave each other.

  `async: false` because the store is one set of tables shared by the whole node, which is what
  makes a counter mean the same thing in two loops.
  """

  use ExUnit.Case, async: false

  alias TuningFork.Part.Source
  alias TuningFork.{Ring, Stage, State, Store, Tick}
  alias TuningFork.Sink.Silent

  setup do
    Store.clear()

    :ok
  end

  doctest TuningFork.Ring, import: true

  describe "counters" do
    test "a counter steps on and gives what it was" do
      assert Tick.tick(:a) == 0
      assert Tick.tick(:a) == 1
      assert Tick.tick(:a) == 2
    end

    test "counters are separate" do
      Tick.tick(:a)
      Tick.tick(:a)

      assert Tick.tick(:b) == 0
      assert Tick.tick(:a) == 2
    end

    test "looking does not step, so two places in one round agree" do
      Tick.tick(:a)

      assert Tick.look(:a) == 1
      assert Tick.look(:a) == 1
      assert Tick.tick(:a) == 1
    end

    test "an unused counter is at zero rather than missing" do
      assert Tick.look(:never_touched) == 0
    end

    test "resetting one leaves the others" do
      Tick.tick(:a)
      Tick.tick(:b)

      Tick.reset(:a)

      assert Tick.look(:a) == 0
      assert Tick.look(:b) == 1
    end

    test "with no name it counts on the loop being run" do
      Store.as(:drums, 0, fn -> Tick.tick() end)
      Store.as(:drums, 0, fn -> Tick.tick() end)

      assert Tick.look(:drums) == 2
      assert Store.as(:bass, 0, fn -> Tick.tick() end) == 0
    end

    test "outside a loop it counts on :default" do
      assert Tick.tick() == 0
      assert Tick.look(:default) == 1
    end
  end

  describe "rings" do
    test "an index past the end wraps, so a counter that only climbs still gives a note" do
      notes = [:c2, :e2, :g2]

      assert Enum.map(0..5, &Ring.at(notes, &1)) == [:c2, :e2, :g2, :c2, :e2, :g2]
    end

    test "a negative index counts back from the end" do
      assert Ring.at([:a, :b, :c], -1) == :c
      assert Ring.at([:a, :b, :c], -4) == :c
    end

    test "an empty ring gives nothing rather than raising" do
      assert Ring.at([], 3) == nil
      assert Ring.take([], 0, 2) == []
      assert Ring.from([], 1) == []
    end

    test "taking more than there is wraps round" do
      assert Ring.take([:a, :b], 0, 5) == [:a, :b, :a, :b, :a]
      assert Ring.take([:a, :b], 1, 0) == []
    end
  end

  describe "values one loop leaves for another" do
    test "a value set is a value read" do
      State.set(:mood, :bright)

      assert State.get(:mood) == :bright
    end

    test "a key never set gives the default" do
      assert State.get(:missing) == nil
      assert State.get(:missing, :fallback) == :fallback
    end

    test "a reader sees the newest value at or before its own time" do
      Store.as(:writer, 100, fn -> State.set(:key, :early) end)
      Store.as(:writer, 200, fn -> State.set(:key, :late) end)

      assert Store.as(:reader, 150, fn -> State.get(:key) end) == :early
      assert Store.as(:reader, 200, fn -> State.get(:key) end) == :late
      assert Store.as(:reader, 999, fn -> State.get(:key) end) == :late
    end

    test "a value from the future is not handed back to a loop still behind it" do
      Store.as(:ahead, 10_000, fn -> State.set(:key, :ahead) end)

      assert Store.as(:behind, 50, fn -> State.get(:key, :nothing) end) == :nothing
    end

    test "two loops on the same round agree, whichever ran first" do
      Store.as(:writer, 100, fn -> State.set(:key, :agreed) end)

      first = Store.as(:a, 500, fn -> State.get(:key) end)
      second = Store.as(:b, 500, fn -> State.get(:key) end)

      assert first == second
    end

    test "keys are those with a value by the reader's time" do
      Store.as(:writer, 100, fn -> State.set(:early, 1) end)
      Store.as(:writer, 900, fn -> State.set(:late, 2) end)

      assert Store.as(:reader, 500, fn -> State.keys() end) == [:early]
      assert Store.as(:reader, 900, fn -> State.keys() end) |> Enum.sort() == [:early, :late]
    end

    test "one key's history does not answer for another" do
      Store.as(:writer, 100, fn -> State.set(:a, 1) end)

      assert Store.as(:reader, 500, fn -> State.get(:b, :none) end) == :none
    end
  end

  describe "a loop worked out again each round" do
    # A short sound as well as a fast tempo: `TuningFork.Part.beats/1` counts a note's ring-out,
    # so a kick's 0.36s decay would make a one-beat part nearly three beats long.
    @source """
    part(bpm: 480, synth: Kit.voice("hh", 0.03))
    |> play(Ring.at([:c2, :e2, :g2, :a2], tick()), 1)
    """

    setup do
      {:ok, stage} = Stage.start_link(name: nil, sink: Silent, chunk: 256)
      on_exit(fn -> if Process.alive?(stage), do: GenServer.stop(stage) end)

      {:ok, stage: stage}
    end

    defp eventually(check, waited \\ 0) do
      cond do
        check.() -> true
        waited >= 5_000 -> false
        true -> Process.sleep(50) && eventually(check, waited + 50)
      end
    end

    defp started(stage, name, source) do
      {:ok, body} = Source.compile(source)
      {:ok, first} = Store.as(name, 0, body)

      Stage.start_loop(stage, name, first, body: body)

      :ok
    end

    test "the counter steps as the loop goes round", %{stage: stage} do
      started(stage, :bass, @source)

      assert eventually(fn -> Tick.look(:bass) > 2 end),
             "a body run once a round should count several"

      assert Stage.loops(stage)[:bass].rounds > 0
    end

    test "a loop with no body plays the same score for ever", %{stage: stage} do
      {:ok, score} = Source.parse(@source)

      Stage.start_loop(stage, :fixed, score)

      assert eventually(fn -> Stage.loops(stage)[:fixed].rounds > 0 end)
      assert Tick.look(:fixed) == 0
    end

    test "a body that raises after the first round leaves the loop playing", %{stage: stage} do
      started(stage, :broken, """
      if tick() > 0, do: raise("not this round")

      part(bpm: 480, synth: Kit.voice("hh", 0.03)) |> play(:c3, 1)
      """)

      assert eventually(fn -> Stage.loops(stage)[:broken].rounds > 1 end),
             "the loop should still be running, going round on the last good score"
    end

    test "stopping a loop forgets its body", %{stage: stage} do
      started(stage, :bass, @source)
      Process.sleep(200)

      Stage.stop_loop(stage, :bass)
      Process.sleep(100)
      was = Tick.look(:bass)
      Process.sleep(300)

      assert Tick.look(:bass) == was, "a stopped loop should not go on counting"
    end

    test "two loops count on their own names", %{stage: stage} do
      started(stage, :one, @source)
      started(stage, :two, @source)

      assert eventually(fn -> Tick.look(:one) > 1 and Tick.look(:two) > 1 end)
    end
  end
end

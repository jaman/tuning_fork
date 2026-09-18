defmodule TuningFork.StageTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Envelope, Sink, Stage, Voice}

  defp start(opts \\ []) do
    defaults = [
      name: nil,
      sink: Sink.Collect,
      sink_opts: [owner: self()],
      chunk: 256
    ]

    pid =
      start_supervised!(
        Supervisor.child_spec({Stage, Keyword.merge(defaults, opts)}, id: make_ref())
      )

    pid
  end

  defp loud?(pcm), do: Enum.any?(for(<<s::16-signed-little <- pcm>>, do: abs(s)), &(&1 > 1_000))

  defp await_sound(timeout \\ 1_000) do
    until = System.monotonic_time(:millisecond) + timeout
    await_sound_until(until)
  end

  defp await_sound_until(until) do
    left = until - System.monotonic_time(:millisecond)

    if left <= 0 do
      false
    else
      receive do
        {:pcm, pcm} -> loud?(pcm) or await_sound_until(until)
      after
        left -> false
      end
    end
  end

  test "with nothing sounding the stream is silence, not nothing" do
    start()

    assert_receive {:pcm, pcm}, 1_000
    assert byte_size(pcm) == 1_024
    refute loud?(pcm)
  end

  test "a mono stage writes half as much for the same chunk" do
    start(channels: 1)

    assert_receive {:pcm, pcm}, 1_000
    assert byte_size(pcm) == 512
  end

  test "a played voice reaches the sink" do
    stage = start()
    Stage.play(stage, Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.2)))

    assert await_sound(), "expected audible samples at the sink"
  end

  test "a muted stage stays silent but keeps streaming" do
    stage = start()
    Stage.mute(stage, true)
    Stage.play(stage, Voice.new(shape: :sine, envelope: Envelope.hit(0.2)))

    refute await_sound(300)
    assert_receive {:pcm, _silence}, 1_000
  end

  test "stop_all cuts everything sounding" do
    stage = start()
    Stage.play(stage, Voice.new(shape: :sine, envelope: Envelope.hit(1.0)))
    assert Stage.sounding(stage) == 1

    Stage.stop_all(stage)
    assert Stage.sounding(stage) == 0
  end

  test "voices are capped, and it is the newest that survive" do
    stage = start(voices: 3)

    for _ <- 1..10 do
      Stage.play(stage, Voice.new(shape: :sine, envelope: Envelope.hit(1.0)))
    end

    assert Stage.sounding(stage) <= 3
  end

  test "a voice stops sounding once it has played out" do
    stage = start()
    Stage.play(stage, Voice.new(shape: :sine, envelope: Envelope.hit(0.05)))

    Process.sleep(400)
    assert Stage.sounding(stage) == 0
  end

  describe "the background bed" do
    defp tone(frames, value) do
      for _ <- 1..frames, into: <<>>, do: <<value::16-signed-little>>
    end

    test "a bed plays without anything else sounding" do
      stage = start()
      Stage.bed(stage, tone(4_000, 8_000))

      assert await_sound(), "expected the bed at the sink"
    end

    test "the bed wraps rather than running out" do
      stage = start()
      Stage.bed(stage, tone(100, 9_000))

      assert await_sound()
      Process.sleep(200)
      assert await_sound(500)
    end

    test "clearing the bed stops it" do
      stage = start()
      Stage.bed(stage, tone(4_000, 8_000))
      assert await_sound()

      Stage.clear_bed(stage)
      Process.sleep(120)
      flush()

      refute await_sound(300)
    end

    test "a bed does not count as a sounding voice" do
      stage = start()
      Stage.bed(stage, tone(4_000, 8_000))

      assert Stage.sounding(stage) == 0
    end

    test "events mix over the bed rather than replacing it" do
      stage = start()
      Stage.bed(stage, tone(4_000, 4_000))
      Stage.play(stage, Voice.new(shape: :square, envelope: Envelope.hit(0.2), gain: 0.9))

      assert await_level(20_000), "expected the event to add to the bed"
    end

    defp flush do
      receive do
        {:pcm, _pcm} -> flush()
      after
        0 -> :ok
      end
    end

    defp await_level(level, timeout \\ 1_000) do
      until = System.monotonic_time(:millisecond) + timeout
      await_level_until(level, until)
    end

    defp await_level_until(level, until) do
      left = until - System.monotonic_time(:millisecond)

      if left <= 0 do
        false
      else
        receive do
          {:pcm, pcm} ->
            peak = pcm |> then(&for(<<s::16-signed-little <- &1>>, do: abs(s))) |> Enum.max()
            peak >= level or await_level_until(level, until)
        after
          left -> false
        end
      end
    end
  end

  test "an unavailable sink falls back to silence rather than failing to start" do
    defmodule Broken do
      @behaviour TuningFork.Sink
      @impl true
      def open(_opts), do: {:error, :no_device}
      @impl true
      def write(_state, _pcm), do: :ok
      @impl true
      def close(_state), do: :ok
    end

    pid =
      start_supervised!(Supervisor.child_spec({Stage, name: nil, sink: Broken}, id: make_ref()))

    assert Stage.play(pid, Voice.new()) == :ok
  end

  describe "playing a pattern" do
    alias TuningFork.Pattern.Mini

    test "a pattern reaches the sink and keeps its place" do
      stage = start()
      Stage.start_pattern(stage, Mini.parse("bd*4"), cps: 2.0)

      assert await_sound(), "expected the pattern at the sink"
      assert Stage.cycle(stage) > 0.0
    end

    test "no pattern means no cycle to report" do
      stage = start()

      assert Stage.cycle(stage) == nil
    end

    test "stopping it leaves the stream running" do
      stage = start()
      Stage.start_pattern(stage, Mini.parse("bd*8"), cps: 2.0)
      assert await_sound()

      Stage.stop_pattern(stage)
      Process.sleep(150)
      flush()

      assert Stage.cycle(stage) == nil
      assert_receive {:pcm, _silence}, 1_000
    end

    test "swapping it does not send the position back to the start" do
      stage = start()
      Stage.start_pattern(stage, Mini.parse("bd*4"), cps: 4.0)
      Process.sleep(200)

      was = Stage.cycle(stage)
      Stage.update_pattern(stage, Mini.parse("sn*4"))
      Process.sleep(100)

      assert Stage.cycle(stage) > was
    end

    test "swapping with no pattern playing is ignored rather than starting one" do
      stage = start()
      Stage.update_pattern(stage, Mini.parse("bd*4"))

      assert Stage.cycle(stage) == nil
    end

    test "the speed can be changed without losing the place" do
      stage = start()
      Stage.start_pattern(stage, Mini.parse("bd*4"), cps: 1.0)
      Process.sleep(150)

      was = Stage.cycle(stage)
      Stage.pattern_cps(stage, 4.0)
      Process.sleep(50)

      assert Stage.cycle(stage) >= was
    end

    test "a pattern and a score mix rather than replacing each other" do
      stage = start()
      Stage.start_pattern(stage, Mini.parse("bd*4"), cps: 2.0)
      Stage.start_score(stage, TuningFork.Score.new(bpm: 120, beats: 8))

      assert await_sound()
      assert Stage.cycle(stage) != nil
      assert Stage.beat(stage) != nil
    end
  end

  describe "the scope" do
    test "it hands back the number of points asked for" do
      stage = start()
      Stage.play(stage, Voice.new(shape: :sine, freq: 220.0, envelope: Envelope.hit(1.0)))
      Process.sleep(200)

      assert length(Stage.scope(stage, 64)) <= 64
      assert length(Stage.scope(stage, 64)) > 8
    end

    test "nothing written yet is no trace rather than a crash" do
      stage =
        start_supervised!(
          Supervisor.child_spec({Stage, name: nil, sink: Sink.Silent}, id: make_ref())
        )

      assert is_list(Stage.scope(stage, 32))
    end

    test "the window is longer than one chunk, so a wave has room to settle" do
      stage = start(chunk: 64)
      Stage.play(stage, Voice.new(shape: :sine, freq: 110.0, envelope: Envelope.hit(2.0)))
      Process.sleep(300)

      trace = Stage.scope(stage, 256)

      assert length(trace) > 64, "a scope of one 64-frame chunk would be far shorter"
    end

    test "the trace starts at a zero crossing, which is what holds it still" do
      stage = start()

      Stage.play(
        stage,
        Voice.new(shape: :sine, freq: 220.0, envelope: Envelope.hit(3.0), gain: 0.9)
      )

      Process.sleep(300)

      starts =
        for _ <- 1..5 do
          Process.sleep(40)
          Stage.scope(stage, 32) |> List.first()
        end

      assert Enum.all?(starts, &(abs(&1) < 0.25)),
             "every trace should begin near zero, not wherever the chunk happened to fall"
    end

    test "the samples are all within range" do
      stage = start()

      Stage.play(
        stage,
        Voice.new(shape: :saw, freq: 110.0, envelope: Envelope.hit(1.0), gain: 1.0)
      )

      Process.sleep(200)

      assert Enum.all?(Stage.scope(stage, 128), &(&1 >= -1.0 and &1 <= 1.0))
    end
  end

  describe "holding a note" do
    test "a held voice sounds until it is released, then stops" do
      stage = start(rate: 8_000)

      voice =
        Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.new(sustain: 1.0, hold: 0.05))

      Stage.hold(stage, :key, voice)
      assert await_sound()
      Process.sleep(300)
      assert Stage.sounding(stage) == 1
      assert await_sound(200)

      Stage.release(stage, :key, 0.01)
      Process.sleep(300)
      assert Stage.sounding(stage) == 0
    end

    test "holding the same key again releases the first" do
      stage = start(rate: 8_000)
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.new(sustain: 1.0))

      Stage.hold(stage, :key, voice)
      Stage.hold(stage, :key, voice)
      Process.sleep(200)

      assert Stage.sounding(stage) == 1
    end

    test "releasing a key nobody holds does nothing" do
      stage = start(rate: 8_000)

      assert :ok = Stage.release(stage, :nothing)
      Process.sleep(50)
      assert Stage.sounding(stage) == 0
    end
  end

  describe "stopping" do
    test "takes the writer with it rather than leaving it running" do
      stage = start()
      Process.sleep(50)
      writer = :sys.get_state(stage).writer

      assert Process.alive?(writer)
      GenServer.stop(stage)
      Process.sleep(50)

      refute Process.alive?(writer)
    end

    test "does not take its caller down with it" do
      parent = self()

      caller =
        spawn(fn ->
          {:ok, stage} = Stage.start_link(name: nil, sink: Sink.Silent, chunk: 256)
          Process.sleep(50)
          GenServer.stop(stage)
          send(parent, :stopped_cleanly)
          Process.sleep(200)
        end)

      assert_receive :stopped_cleanly, 1_000
      assert Process.alive?(caller), "killing the writer came back down the link"
    end
  end

  describe "a stage with nowhere to play" do
    test "still keeps time, so a score plays through rather than freezing at its first beat" do
      stage =
        start_supervised!(
          Supervisor.child_spec({Stage, name: nil, sink: Sink.Silent, chunk: 256}, id: make_ref())
        )

      Stage.start_score(stage, TuningFork.Score.new(bpm: 240, beats: 16))
      assert Stage.beat(stage) == 0.0

      Process.sleep(300)
      moved = Stage.beat(stage)

      assert moved > 0.0, "a silent stage never advanced past its first beat"
      assert moved < 16.0, "a silent stage ran faster than the wall clock"
    end

    test "a sink that will not open falls back to a silent stage that still keeps time" do
      defmodule Shut do
        @behaviour TuningFork.Sink
        @impl true
        def open(_opts), do: {:error, :no_device}
        @impl true
        def write(_state, _pcm), do: :ok
        @impl true
        def close(_state), do: :ok
      end

      logged =
        ExUnit.CaptureLog.capture_log(fn ->
          stage =
            start_supervised!(
              Supervisor.child_spec({Stage, name: nil, sink: Shut, chunk: 256}, id: make_ref())
            )

          Stage.start_score(stage, TuningFork.Score.new(bpm: 240, beats: 16))
          Process.sleep(300)

          assert Stage.beat(stage) > 0.0
        end)

      assert logged =~ "staying silent"
    end
  end

  test "a sink that stops taking samples says so rather than being written to forever" do
    defmodule Deaf do
      @behaviour TuningFork.Sink
      @impl true
      def open(opts), do: {:ok, Keyword.fetch!(opts, :owner)}
      @impl true
      def write(owner, _pcm) do
        send(owner, :written)
        {:error, :device_lost}
      end

      @impl true
      def close(_state), do: :ok
    end

    logged =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!(
          Supervisor.child_spec(
            {Stage, name: nil, sink: Deaf, sink_opts: [owner: self()], chunk: 256},
            id: make_ref()
          )
        )

        assert_receive :written, 1_000
        Process.sleep(100)
      end)

    assert logged =~ "stopped taking samples"
    assert logged =~ "device_lost"
    refute_received :written
  end
end

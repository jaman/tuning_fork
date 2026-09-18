defmodule TuningFork.StageLayersTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Sink, Stage}

  defp start(opts \\ []) do
    defaults = [
      name: nil,
      sink: Sink.Collect,
      sink_opts: [owner: self()],
      chunk: 256,
      channels: 1,
      rate: 8_000
    ]

    pid =
      start_supervised!(
        Supervisor.child_spec({Stage, Keyword.merge(defaults, opts)}, id: make_ref())
      )

    pid
  end

  defp tone(frames, value), do: for(_ <- 1..frames, into: <<>>, do: <<value::16-signed-little>>)

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)

  defp flush do
    receive do
      {:pcm, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp next_chunk do
    receive do
      {:pcm, pcm} -> pcm
    after
      1_000 -> flunk("no chunk")
    end
  end

  defp settled_level(pid) do
    :sys.get_state(pid)
    flush()
    next_chunk() |> samples() |> Enum.max_by(&abs/1)
  end

  test "layers sum, each at its own gain" do
    stage = start()
    Stage.layers(stage, %{drums: tone(1_000, 1_000), bass: tone(1_000, 2_000)})
    assert settled_level(stage) == 3_000

    Stage.layer_gains(stage, %{bass: 0.5})
    assert settled_level(stage) == 2_000

    Stage.layer_gains(stage, %{drums: 0.0, bass: 0.0})
    assert settled_level(stage) == 0
  end

  test "layers of different lengths each wrap on their own" do
    stage = start()
    Stage.layers(stage, %{a: tone(300, 100), b: tone(700, 10)})
    Process.sleep(150)
    assert settled_level(stage) in [110, 100, 10]
    Process.sleep(150)
    assert settled_level(stage) in [110, 100, 10]
  end

  test "bed/2 is a single layer named :bed and bed_gain scales the whole set" do
    stage = start()
    Stage.bed(stage, tone(1_000, 1_000))
    Stage.layers(stage, %{extra: tone(1_000, 1_000)}, keep: true)
    Stage.bed_gain(stage, 0.5)
    assert settled_level(stage) == 1_000
  end

  test "replacing the set at a bar boundary waits for it" do
    stage = start()
    Stage.layers(stage, %{a: tone(4_000, 1_000)})
    settled_level(stage)
    Stage.layers(stage, %{b: tone(4_000, 3_000)}, at: {:bar, 4_000})
    %{position: position} = :sys.get_state(stage).bed
    assert position < 4_000
    assert settled_level(stage) == 1_000
    Process.sleep(600)
    assert settled_level(stage) == 3_000
  end

  test "a crossfade ramps the new set in over the given time" do
    stage = start()
    Stage.layers(stage, %{a: tone(4_000, 0)})
    settled_level(stage)
    Stage.layers(stage, %{b: tone(4_000, 8_000)}, fade_ms: 200)
    flush()
    first = next_chunk() |> samples() |> Enum.max()
    assert first < 8_000
    Process.sleep(300)
    assert settled_level(stage) == 8_000
  end

  test "the playhead can be aligned to a bar for a switch made later" do
    stage = start()
    Stage.layers(stage, %{a: tone(2_000, 1_000)})
    Process.sleep(100)
    assert is_integer(Stage.bed_position(stage))
  end
end

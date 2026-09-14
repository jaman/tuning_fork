defmodule TuningFork.SpeakerTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Mixer, Sink, Stage, Voice}
  alias TuningFork.Speaker.Device

  setup_all do
    if Device.available?(), do: :ok, else: {:ok, skip: true}
  end

  setup context do
    if context[:skip], do: {:ok, skip: true}, else: :ok
  end

  describe "the device" do
    @tag :device
    test "reports itself available once the NIF has loaded", context do
      if context[:skip] do
        assert TuningFork.available?() == false
      else
        assert Device.available?()
        assert TuningFork.available?()
      end
    end

    @tag :device
    test "opens in stereo and closes cleanly", context do
      unless context[:skip] do
        assert {:ok, device} = Device.open(44_100, 2, 1_024)
        assert :ok = Device.close(device)
      end
    end

    @tag :device
    test "an opened ring has room in it and takes what it is given", context do
      unless context[:skip] do
        {:ok, device} = Device.open(44_100, 2, 1_024)

        assert Device.space(device) > 0
        assert {:ok, frames} = Device.write(device, Mixer.silence(256, 2))
        assert frames > 0

        Device.close(device)
      end
    end
  end

  describe "the sink" do
    @tag :device
    test "opens through the behaviour the stage uses", context do
      unless context[:skip] do
        assert {:ok, state} = Sink.Speaker.open(rate: 44_100, channels: 2)
        assert state.channels == 2
        assert :ok = Sink.Speaker.write(state, Mixer.silence(128, 2))
        assert :ok = Sink.Speaker.close(state)
      end
    end

    @tag :device
    test "a stage drives it end to end without falling over", context do
      unless context[:skip] do
        {:ok, stage} = Stage.start_link(name: nil, sink: Sink.Speaker, chunk: 256)

        Stage.play(stage, Voice.new(shape: :sine, freq: 440.0, gain: 0.0))
        Process.sleep(100)

        assert Process.alive?(stage)
        GenServer.stop(stage)
      end
    end
  end

  describe "without a device" do
    test "the stage falls back to silence rather than failing" do
      defmodule Refuses do
        @behaviour TuningFork.Sink

        @impl true
        def open(_opts), do: {:error, :no_device}

        @impl true
        def write(_state, _pcm), do: :ok

        @impl true
        def close(_state), do: :ok
      end

      {:ok, stage} = Stage.start_link(name: nil, sink: Refuses)

      assert Process.alive?(stage)
      assert :ok = Stage.play(stage, Voice.new())

      GenServer.stop(stage)
    end
  end
end

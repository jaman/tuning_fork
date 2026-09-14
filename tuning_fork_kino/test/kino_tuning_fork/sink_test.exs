defmodule KinoTuningFork.SinkTest do
  use ExUnit.Case, async: true

  alias KinoTuningFork.Sink

  test "every chunk arrives at the owner in order" do
    {:ok, state} = Sink.open(owner: self(), rate: 8_000, channels: 2, lead: 1.0)

    :ok = Sink.write(state, <<1, 0, 2, 0>>)
    :ok = Sink.write(state, <<3, 0, 4, 0>>)

    assert_receive {:pcm, <<1, 0, 2, 0>>}
    assert_receive {:pcm, <<3, 0, 4, 0>>}
  end

  test "writes are paced to real time, a lead ahead of the clock" do
    {:ok, state} = Sink.open(owner: self(), rate: 8_000, channels: 1, lead: 0.05)
    chunk = :binary.copy(<<0, 0>>, 800)

    {micros, :ok} = :timer.tc(fn -> Enum.each(1..6, fn _ -> Sink.write(state, chunk) end) end)

    assert micros >= 500_000
    assert micros < 900_000
    Sink.close(state)
  end

  test "a stage runs on it and its owner hears the mix" do
    {:ok, stage} =
      TuningFork.Stage.start_link(
        name: nil,
        sink: Sink,
        sink_opts: [owner: self()],
        rate: 8_000,
        chunk: 256
      )

    TuningFork.Stage.play(stage, TuningFork.Voice.new(shape: :sine, freq: 440.0))

    assert_receive {:pcm, chunk}, 1_000
    assert byte_size(chunk) == 256 * 4
    GenServer.stop(stage)
  end
end

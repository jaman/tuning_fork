defmodule TuningFork.Sink.ProcessTest do
  use ExUnit.Case, async: true

  alias TuningFork.Sink.Process, as: Sink

  test "each chunk arrives as a {:pcm, chunk} message, paced so a second of audio takes about a second" do
    {:ok, sink} = Sink.open(owner: self(), rate: 8_000, channels: 1, lead_ms: 100)
    chunk = :binary.copy(<<0, 0>>, 800)

    {us, _} = :timer.tc(fn -> for _ <- 1..10, do: :ok = Sink.write(sink, chunk) end)
    assert us > 800_000 and us < 1_300_000

    for _ <- 1..10, do: assert_receive({:pcm, ^chunk}, 100)
    :ok = Sink.close(sink)
  end

  test "an owner that is gone ends the sink" do
    owner = spawn(fn -> :ok end)
    Process.sleep(20)
    {:ok, sink} = Sink.open(owner: owner, rate: 8_000, channels: 1)
    assert {:error, :owner_gone} = Sink.write(sink, :binary.copy(<<0, 0>>, 80))
  end
end

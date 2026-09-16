defmodule TuningFork.ListenerTest do
  use ExUnit.Case, async: true

  alias TuningFork.Listener

  defmodule Tape do
    @moduledoc false
    @behaviour TuningFork.Sink

    def open(opts) do
      send(Keyword.fetch!(opts, :owner), {:opened, Keyword.take(opts, [:rate, :channels])})
      {:ok, Keyword.fetch!(opts, :owner)}
    end

    def write(owner, pcm) do
      send(owner, {:pcm, pcm})
      Process.sleep(div(byte_size(pcm), 32))
      :ok
    end

    def close(owner) do
      send(owner, :closed)
      :ok
    end
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    socket
  end

  defp collect(acc \\ "") do
    receive do
      {:pcm, pcm} -> collect(acc <> pcm)
    after
      300 -> acc
    end
  end

  test "plays one connection after another through the sink, opened per connection with the format" do
    {:ok, listener} =
      Listener.start_link(port: 0, rate: 8_000, channels: 1, sink: {Tape, owner: self()})

    port = Listener.port(listener)

    first = connect(port)
    :ok = :gen_tcp.send(first, :binary.copy(<<1, 0>>, 800))
    assert_receive {:opened, [rate: 8_000, channels: 1]}, 1_000
    assert byte_size(collect()) == 1_600
    :gen_tcp.close(first)
    assert_receive :closed, 1_000

    second = connect(port)
    :ok = :gen_tcp.send(second, :binary.copy(<<2, 0>>, 400))
    assert_receive {:opened, _}, 1_000
    assert byte_size(collect()) == 800
    :gen_tcp.close(second)
    assert_receive :closed, 1_000
  end

  test "audio that arrived faster than it plays is dropped down to the allowed lag" do
    {:ok, listener} =
      Listener.start_link(
        port: 0,
        rate: 8_000,
        channels: 1,
        sink: {Tape, owner: self()},
        max_lag_ms: 100
      )

    socket = connect(Listener.port(listener))
    assert_receive {:opened, _}, 1_000

    :ok = :gen_tcp.send(socket, :binary.copy(<<3, 0>>, 8_000 * 2))
    Process.sleep(600)
    played = collect()

    assert byte_size(played) < 8_000,
           "two seconds arrived at once yet #{byte_size(played)} bytes were played"

    :gen_tcp.close(socket)
  end
end

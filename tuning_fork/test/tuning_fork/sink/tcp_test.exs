defmodule TuningFork.Sink.TcpTest do
  use ExUnit.Case, async: true

  alias TuningFork.Sink.Tcp

  defp listener do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  defp accept_all(listen, owner) do
    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      send(owner, {:accepted, socket})
      drain(socket, owner)
    end)
  end

  defp drain(socket, owner) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        send(owner, {:data, data})
        drain(socket, owner)

      _ ->
        :ok
    end
  end

  defp second_of_silence(rate, channels), do: :binary.copy(<<0, 0>>, rate * channels)

  test "PCM reaches a listening player, paced so a second of audio takes about a second to send" do
    {listen, port} = listener()
    accept_all(listen, self())
    {:ok, sink} = Tcp.open(port: port, rate: 8_000, channels: 1, lead_ms: 100, warm_up_ms: 0)

    chunk = second_of_silence(8_000, 1) |> binary_part(0, 1_600)
    {us, _} = :timer.tc(fn -> for _ <- 1..10, do: :ok = Tcp.write(sink, chunk) end)
    assert us > 800_000 and us < 1_300_000, "ten tenths of a second took #{div(us, 1000)} ms"

    assert_receive {:accepted, _}, 1_000
    received = collect(16_000, "")
    assert byte_size(received) == 16_000
    :ok = Tcp.close(sink)
  end

  test "after connecting, the first frames go at once, the warm-up's audio is pulled at real time but not sent, then it streams" do
    {listen, port} = listener()
    accept_all(listen, self())
    {:ok, sink} = Tcp.open(port: port, rate: 8_000, channels: 1, lead_ms: 0, warm_up_ms: 300)
    chunk = second_of_silence(8_000, 1) |> binary_part(0, 160)

    {warm_us, _} = :timer.tc(fn -> for _ <- 1..30, do: :ok = Tcp.write(sink, chunk) end)

    assert warm_us > 250_000 and warm_us < 400_000,
           "thirty 10 ms chunks took #{div(warm_us, 1000)} ms"

    assert_receive {:accepted, _}, 1_000
    Process.sleep(50)
    primed = collect(2_048, "")

    assert byte_size(primed) in 2_048..2_240,
           "only the priming frames were sent during the warm-up, got #{byte_size(primed)}"

    for _ <- 1..10, do: :ok = Tcp.write(sink, chunk)
    assert byte_size(collect(1_600, "")) == 1_600
    :ok = Tcp.close(sink)
  end

  test "with no player yet, writes are dropped at real time and the player is found once it listens" do
    {listen, port} = listener()

    {:ok, sink} =
      Tcp.open(port: port, rate: 8_000, channels: 1, lead_ms: 50, retry_ms: 100, warm_up_ms: 0)

    :gen_tcp.close(listen)

    chunk = second_of_silence(8_000, 1) |> binary_part(0, 800)
    {us, _} = :timer.tc(fn -> for _ <- 1..4, do: :ok = Tcp.write(sink, chunk) end)
    assert us > 150_000, "dropped writes must still take their audio's time"

    {:ok, listen} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    accept_all(listen, self())
    Process.sleep(120)
    for _ <- 1..4, do: :ok = Tcp.write(sink, chunk)

    assert_receive {:accepted, _}, 1_000
    assert byte_size(collect(800, "")) >= 800
    :ok = Tcp.close(sink)
  end

  defp collect(wanted, acc) when byte_size(acc) >= wanted, do: acc

  defp collect(wanted, acc) do
    receive do
      {:data, data} -> collect(wanted, acc <> data)
    after
      2_000 -> acc
    end
  end
end

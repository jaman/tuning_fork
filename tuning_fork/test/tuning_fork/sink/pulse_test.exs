defmodule TuningFork.Sink.PulseTest do
  use ExUnit.Case, async: true

  alias TuningFork.Sink.Pulse

  setup do
    dir = Path.join(System.tmp_dir!(), "pulse_sink_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, out: Path.join(dir, "out.pcm")}
  end

  test "writes PCM to the player program's standard input", %{out: out} do
    {:ok, sink} =
      Pulse.open(
        rate: 8_000,
        channels: 1,
        command: "/bin/sh",
        args: ["-c", "cat > #{out}"],
        server: "tcp:127.0.0.1:1"
      )

    :ok = Pulse.write(sink, <<1, 2, 3, 4>>)
    :ok = Pulse.write(sink, <<5, 6>>)
    :ok = Pulse.close(sink)
    Process.sleep(50)
    assert File.read!(out) == <<1, 2, 3, 4, 5, 6>>
  end

  test "the player is started with the server in its environment and the format in its arguments",
       %{out: out} do
    {:ok, sink} =
      Pulse.open(
        rate: 22_050,
        channels: 2,
        command: "/bin/sh",
        args: ["-c", "echo \"$PULSE_SERVER $0 $1 $2 $3 $4\" > #{out}"],
        server: "tcp:127.0.0.1:24713"
      )

    Process.sleep(80)
    :ok = Pulse.close(sink)
    assert File.read!(out) =~ "tcp:127.0.0.1:24713"
  end

  test "pacat's arguments name the format" do
    assert Pulse.player_args(rate: 22_050, channels: 1, latency_ms: 40) ==
             ["--raw", "--format=s16le", "--rate=22050", "--channels=1", "--latency-msec=40"]
  end

  test "a missing program is an error, not a crash" do
    assert {:error, {:no_such_program, _}} =
             Pulse.open(rate: 8_000, channels: 1, command: "/nonexistent/pacat", server: "tcp:x")
  end

  test "writing after the program has gone is an error" do
    {:ok, sink} =
      Pulse.open(
        rate: 8_000,
        channels: 1,
        command: "/bin/sh",
        args: ["-c", "exit 0"],
        server: "tcp:x"
      )

    Process.sleep(100)
    assert {:error, _} = Pulse.write(sink, <<0, 0>>)
  end
end

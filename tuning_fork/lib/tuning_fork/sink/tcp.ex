defmodule TuningFork.Sink.Tcp do
  @moduledoc """
  Raw signed 16-bit little-endian PCM over a TCP connection, paced to real time, for any
  player that can take it from a socket — `ffplay`, `sox`, `pacat --raw` — on the far
  end of an ssh tunnel or across a LAN.

      TuningFork.Stage.start_link(sink: TuningFork.Sink.Tcp, sink_opts: [host: "127.0.0.1", port: 24713])

  The connection is made on the first write and remade when it drops, trying again every
  `:retry_ms`; until a player listens, samples are dropped at real time. A chunk is sent
  and then the sink sleeps until the audio before it has nearly played out, keeping
  `:lead_ms` of audio in flight, so a player that reads as fast as it can never runs
  seconds ahead. With `:warm_up_ms` set, the first 1024 frames go at once, so the player
  opens its device, and for that long after them the audio is pulled at real time but
  not sent — for a player that queues whatever arrives while it opens its device and
  keeps it as lag. `TuningFork.Listener` needs none of it: it drops such a backlog itself.

  ## Options

    * `:host` — the player's host. Default `"127.0.0.1"`
    * `:port` — the player's port. Required
    * `:lead_ms` — audio kept in flight ahead of real time. Default `60`
    * `:warm_up_ms` — how long after the first frames the audio is dropped while the
      player opens its device. Default `300`
    * `:retry_ms` — how long to wait after a failed connection before trying again.
      Default `2_000`
    * `:rate`, `:channels` — the PCM format, as the stage passes them

  ## Playing it

      mix tuning_fork.listen --port 4713
      while :; do ffplay -nodisp -autoexit -fflags nobuffer -analyzeduration 0 -probesize 32 -f s16le -ar 44100 -ch_layout stereo -i "tcp://127.0.0.1:4713?listen"; done
      sox -t raw -r 44100 -e signed -b 16 -c 2 - -d < <(nc -l 4713)
  """

  @behaviour TuningFork.Sink

  alias TuningFork.Sink.Tcp.Link

  @impl true
  def open(opts), do: Link.start_link(opts)

  @impl true
  def write(link, pcm), do: GenServer.call(link, {:write, pcm}, :infinity)

  @impl true
  def close(link) do
    if Process.alive?(link), do: GenServer.stop(link)
    :ok
  end
end

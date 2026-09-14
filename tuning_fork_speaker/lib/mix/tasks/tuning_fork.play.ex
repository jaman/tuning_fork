defmodule Mix.Tasks.TuningFork.Play do
  @shortdoc "Play a MIDI file through the speaker"

  @moduledoc """
  Play a MIDI file through this machine's speaker.

      mix tuning_fork.play song.mid
      mix tuning_fork.play loop.mid --loop --bpm 96
      mix tuning_fork.play song.mid --seconds 30

  Press q, Escape or Ctrl-C to stop.

  Requires an audio device; raises when there is none.

  Options:

    * `--loop` — start again on reaching the end
    * `--seconds N` — stop after N seconds
    * `--bpm N` — play at this tempo, ignoring the file
    * `--gain N` — level per note, default 0.2
    * `--drum-gain N` — the kit's level against everything else, default 1.0
    * `--reverb N` — room size, 0.0 to 1.0. Off by default
    * `--drums` — every channel is percussion
    * `--drum-channels 0,9` — exactly which channels are percussion
    * `--no-guess` — only channel 10 is percussion. Otherwise it is guessed
    * `--plain` — one voice for everything, rather than one per instrument
    * `--mono` — one channel out
    * `--quiet` — say nothing unless something is wrong
  """

  use Mix.Task

  alias TuningFork.{Gm, Midi, Score, Sink, Stage}
  alias TuningFork.Speaker.Keys

  @switches [
    loop: :boolean,
    seconds: :integer,
    bpm: :integer,
    gain: :float,
    drum_gain: :float,
    reverb: :float,
    drums: :boolean,
    drum_channels: :string,
    no_guess: :boolean,
    plain: :boolean,
    mono: :boolean,
    quiet: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, argv} = OptionParser.parse!(argv, strict: @switches)

    unless TuningFork.available?() do
      Mix.raise("""
      No audio device.

      tuning_fork_speaker is installed but its device would not open. Try
      `mix tuning_fork.render` instead, which writes a file and needs no device.
      """)
    end

    case argv do
      [path | _rest] -> play(path, opts)
      [] -> Mix.raise("which file? mix tuning_fork.play song.mid")
    end
  end

  defp play(path, opts) do
    unless File.exists?(path), do: Mix.raise("no such file: #{path}")

    channels = if opts[:mono], do: 1, else: 2
    midi = Midi.read!(path)
    score = Gm.score(midi, score_opts(opts))

    say(opts, describe(path, midi, score, opts))
    say(opts, "q to stop.")

    {:ok, stage} =
      Stage.start_link(
        name: nil,
        sink: Sink.Speaker,
        chunk: 256,
        channels: channels,
        voices: 32,
        fx: if(opts[:reverb], do: [reverb: [room: opts[:reverb], mix: 0.22]], else: [])
      )

    Keys.raw()
    Keys.watch(self())

    Stage.start_score(stage, score, loop: opts[:loop] == true)

    try do
      case Keys.await(deadline(score, opts)) do
        :quit -> say(opts, "\rstopped")
        :done -> :ok
      end
    after
      Keys.cooked()
      if Process.alive?(stage), do: GenServer.stop(stage)
    end
  end

  defp deadline(score, opts) do
    cond do
      opts[:seconds] -> System.monotonic_time(:millisecond) + opts[:seconds] * 1_000
      opts[:loop] -> nil
      true -> System.monotonic_time(:millisecond) + ceil(Score.duration(score) + 2) * 1_000
    end
  end

  defp score_opts(opts) do
    [gain: opts[:gain] || 0.2, drum_gain: opts[:drum_gain] || 1.0, plain: opts[:plain] == true] ++
      drum_channels(opts) ++
      if(opts[:bpm], do: [bpm: opts[:bpm]], else: [])
  end

  defp drum_channels(opts) do
    cond do
      opts[:drum_channels] -> [drum_channels: parse_channels(opts[:drum_channels])]
      opts[:drums] -> [drum_channels: Enum.to_list(0..15)]
      opts[:no_guess] -> [drum_channels: [9]]
      true -> [drum_channels: :auto]
    end
  end

  defp parse_channels(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(String.trim(part)) do
        {channel, ""} when channel in 0..15 -> channel
        _other -> Mix.raise("--drum-channels wants numbers from 0 to 15, got #{inspect(part)}")
      end
    end)
  end

  defp describe(path, midi, score, opts) do
    channels = Midi.drum_channels(midi, score_opts(opts))
    whole = round(Score.duration(score))

    "#{Path.basename(path)}: #{length(score.notes)} notes, " <>
      "#{div(whole, 60)}:#{String.pad_leading(to_string(rem(whole, 60)), 2, "0")}, " <>
      "#{round(score.bpm)} bpm, drums on #{inspect(channels, charlists: :as_lists)}"
  end

  defp say(opts, message) do
    unless opts[:quiet], do: Mix.shell().info(message)
  end
end

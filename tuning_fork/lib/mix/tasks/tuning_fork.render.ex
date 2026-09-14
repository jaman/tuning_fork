defmodule Mix.Tasks.TuningFork.Render do
  @shortdoc "Render a MIDI file to a WAV"

  @moduledoc """
  Render a MIDI file to a WAV. No audio device is opened.

      mix tuning_fork.render song.mid
      mix tuning_fork.render song.mid --out take.wav --bpm 96 --gain 0.12
      mix tuning_fork.render drums.mid --drums --loops 4

  A count of clipped samples is reported when there is one.

  ## Options

    * `--out PATH` — where to write. Defaults to the input with a `.wav` extension
    * `--bpm N` — play at this tempo, ignoring the file
    * `--gain N` — level per note, default 0.2. Lower it for dense music
    * `--drum-gain N` — the kit's level against everything else, default 1.0
    * `--loops N` — repeat the rendered audio N times, joined end to end
    * `--reverb N` — room size, 0.0 to 1.0, at a mix of 0.22. Off by default
    * `--drums` — every channel is percussion
    * `--drum-channels 0,9` — exactly which channels are percussion
    * `--no-guess` — only channel 10, as General MIDI says. Otherwise it is guessed
    * `--plain` — one voice for everything, rather than one per instrument
    * `--mono` — one channel out
    * `--rate N` — samples per second, default 44100
    * `--normalise N` — bring the result to this RMS afterwards
    * `--quiet` — say nothing unless something is wrong
  """

  use Mix.Task

  alias TuningFork.{Fx, Gm, Midi, Mixer, Score, Wav}

  @switches [
    out: :string,
    bpm: :integer,
    gain: :float,
    drum_gain: :float,
    loops: :integer,
    reverb: :float,
    drums: :boolean,
    drum_channels: :string,
    no_guess: :boolean,
    plain: :boolean,
    mono: :boolean,
    rate: :integer,
    normalise: :float,
    quiet: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, argv} = OptionParser.parse!(argv, strict: @switches)

    case argv do
      [path | _rest] -> render(path, opts)
      [] -> Mix.raise("which file? mix tuning_fork.render song.mid")
    end
  end

  defp render(path, opts) do
    unless File.exists?(path), do: Mix.raise("no such file: #{path}")

    rate = opts[:rate] || 44_100
    channels = if opts[:mono], do: 1, else: 2
    destination = opts[:out] || Path.rootname(path) <> ".wav"

    midi = Midi.read!(path)
    score = Gm.score(midi, score_opts(opts))

    say(opts, describe(path, midi, score, opts))
    say(opts, "rendering...")

    {microseconds, pcm} =
      :timer.tc(fn ->
        score
        |> Score.render(rate, channels: channels)
        |> repeat(opts[:loops] || 1)
        |> reverb(opts[:reverb], rate, channels)
        |> normalise(opts[:normalise])
      end)

    warn_if_clipped(pcm)

    Wav.write!(destination, pcm, rate: rate, channels: channels)

    say(
      opts,
      "wrote #{destination} — #{format_time(Wav.duration(pcm, rate, channels))}, " <>
        "#{Float.round(byte_size(pcm) / 1_048_576, 1)} MB, in #{Float.round(microseconds / 1_000_000, 1)}s"
    )
  end

  defp score_opts(opts) do
    [gain: opts[:gain] || 0.2, drum_gain: opts[:drum_gain] || 1.0, plain: opts[:plain] == true] ++
      drum_channels(opts) ++
      if(opts[:bpm], do: [bpm: opts[:bpm]], else: [])
  end

  defp drum_channels(opts) do
    cond do
      opts[:drum_channels] ->
        [drum_channels: parse_channels(opts[:drum_channels])]

      opts[:drums] ->
        [drum_channels: Enum.to_list(0..15)]

      opts[:no_guess] ->
        [drum_channels: [9]]

      true ->
        [drum_channels: :auto]
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

  defp repeat(pcm, times) when times <= 1, do: pcm
  defp repeat(pcm, times), do: pcm |> List.duplicate(times) |> IO.iodata_to_binary()

  defp reverb(pcm, nil, _rate, _channels), do: pcm

  defp reverb(pcm, room, rate, channels) do
    Fx.reverb(pcm, rate, room: room, mix: 0.22, channels: channels)
  end

  defp normalise(pcm, nil), do: pcm
  defp normalise(pcm, target), do: Mixer.normalise(pcm, target)

  defp warn_if_clipped(pcm) do
    case Mixer.clipped(pcm) do
      0 ->
        :ok

      count ->
        Mix.shell().info([
          :yellow,
          "#{count} samples clipped — the parts wanted more room than they were given. ",
          "Try a lower --gain.",
          :reset
        ])
    end
  end

  defp describe(path, midi, score, opts) do
    channels = Midi.drum_channels(midi, score_opts(opts))

    "#{Path.basename(path)}: #{length(score.notes)} notes, " <>
      "#{format_time(Score.duration(score))}, #{round(score.bpm)} bpm, " <>
      "drums on #{inspect(channels, charlists: :as_lists)}"
  end

  defp format_time(seconds) do
    whole = round(seconds)
    "#{div(whole, 60)}:#{String.pad_leading(to_string(rem(whole, 60)), 2, "0")}"
  end

  defp say(opts, message) do
    unless opts[:quiet], do: Mix.shell().info(message)
  end
end

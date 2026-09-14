import TuningFork.Part

alias TuningFork.{Curve, Envelope, Mixer, Notes, Score, Sink, Stage, Voice, Wav}

{opts, _argv, _bad} =
  OptionParser.parse(System.argv(), strict: [wav: :string, bars: :integer, bpm: :integer])

bars = opts[:bars] || 8
bpm = opts[:bpm] || 88

defmodule Voices do
  @moduledoc "Every instrument in the piece, as parameters rather than samples."

  def piano do
    Voice.new(
      shape: :triangle,
      gain: 0.32,
      cutoff: 0.55,
      envelope: Envelope.new(attack: 0.002, decay: 0.9, sustain: 0.0, release: 0.15, curve: 3.2)
    )
  end

  def bass do
    Voice.new(
      shape: :square,
      gain: 0.42,
      cutoff: 0.12,
      envelope: Envelope.new(attack: 0.008, decay: 0.5, sustain: 0.35, release: 0.1, curve: 2.0)
    )
  end

  def kick do
    Voice.new(shape: :noise, gain: 0.95, cutoff: 0.045, envelope: Envelope.hit(0.22))
  end

  def snare do
    Voice.new(
      shape: :noise,
      gain: 0.5,
      cutoff: 0.55,
      highpass: 0.12,
      envelope: Envelope.hit(0.16)
    )
  end

  def hat, do: Voice.new(shape: :noise, gain: 0.22, highpass: 0.72, envelope: Envelope.hit(0.045))

  def open_hat do
    Voice.new(shape: :noise, gain: 0.26, highpass: 0.66, envelope: Envelope.hit(0.3))
  end

  def tom do
    Voice.new(
      shape: :sine,
      gain: 0.5,
      envelope: Envelope.hit(0.35),
      curves: %{freq: Curve.linear(1.0, 0.5)}
    )
  end
end

drums =
  part(bpm: bpm, synth: Voices.kick(), pan: 0.0, seed: 4)
  |> repeat(bars, fn p ->
    p
    |> play(Voices.kick(), 1.0)
    |> play(Voices.snare(), 1.0)
    |> play(Voices.kick(), 0.5)
    |> play(Voices.kick(), 0.5)
    |> play(Voices.snare(), 1.0)
  end)

hats =
  part(bpm: bpm, synth: Voices.hat(), pan: 0.35, seed: 9)
  |> repeat_indexed(bars * 8, fn p, index ->
    cond do
      rem(index, 16) == 15 -> play(p, Voices.open_hat(), 0.5)
      rem(index, 2) == 0 -> play(p, Voices.hat(), 0.5, gain: 1.0)
      true -> play(p, Voices.hat(), 0.5, gain: 0.55)
    end
  end)

fills =
  part(bpm: bpm, synth: Voices.tom(), pan: -0.25, seed: 3)
  |> rest((bars - 1) * 4 + 2)
  |> pattern([220.0, 185.0, 155.0, 130.0], 0.5)

roots = [:a1, :f1, :c2, :g1]

bass =
  part(bpm: bpm, synth: Voices.bass(), pan: -0.15, seed: 1)
  |> repeat_indexed(bars, fn p, bar ->
    root = Enum.at(roots, rem(bar, 4))

    p
    |> play(root, 1.0)
    |> play(root, 0.5)
    |> play(Notes.step(root, 12), 0.5)
    |> play(root, 1.0)
    |> play(Notes.step(root, 7), 1.0)
  end)

chords = [{:a3, :minor7}, {:f3, :major7}, {:c4, :major7}, {:g3, :dominant7}]

piano =
  part(bpm: bpm, synth: Voices.piano(), pan: 0.2, seed: 12)
  |> repeat_indexed(bars, fn p, bar ->
    {root, quality} = Enum.at(chords, rem(bar, 4))

    p
    |> rest(0.5)
    |> chord(Notes.chord(root, quality), 1.5, gain: 0.8, release: 2.0)
    |> chord(Notes.chord(root, quality), 2.0, gain: 0.55, release: 2.5)
  end)

melody =
  part(bpm: bpm, synth: %{Voices.piano() | gain: 0.26}, pan: -0.3, seed: 21)
  |> rest(8)
  |> repeat(bars - 2, fn p ->
    p
    |> play_any(Notes.scale(:a4, :minor_pentatonic, octaves: 2), 0.5, release: 1.2)
    |> maybe(0.6, &play_any(&1, Notes.scale(:a4, :minor_pentatonic), 0.5, release: 0.9), 0.5)
    |> play_any(Notes.scale(:a4, :minor_pentatonic, octaves: 2), 1.0, release: 1.6)
  end)

score = Score.from_parts([drums, hats, fills, bass, piano, melody], bpm: bpm, beats: bars * 4)

IO.puts(
  "trio: #{length(score.notes)} notes, #{bars} bars at #{bpm} bpm, " <>
    "#{Float.round(Score.duration(score), 1)}s"
)

case opts[:wav] do
  nil ->
    unless TuningFork.available?() do
      IO.puts("No audio device — tuning_fork_speaker is needed to hear this. Try --wav out.wav")
      System.halt(1)
    end

    {:ok, stage} = Stage.start_link(name: nil, sink: Sink.Speaker, chunk: 256, voices: 32)

    pcm = Score.render(score, 44_100)

    if Mixer.clipped(pcm) > 0 do
      IO.puts("#{Mixer.clipped(pcm)} samples clipped")
    end

    Stage.bed(stage, pcm)
    IO.puts("looping. ctrl-c to stop.")
    Process.sleep(round(Score.duration(score) * 1_000) * 3)
    GenServer.stop(stage)

  destination ->
    pcm = Score.render(score, 44_100)
    Wav.write!(destination, pcm, rate: 44_100, channels: 2)
    IO.puts("wrote #{destination}")
end

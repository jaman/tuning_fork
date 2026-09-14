defmodule TuningFork.ModulationTest do
  use ExUnit.Case, async: true

  import TuningFork.Part

  alias TuningFork.{Curve, Envelope, Part, Voice}

  @rate 44_100

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)

  defp crossings(pcm) do
    pcm
    |> samples()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> (a < 0 and b >= 0) or (a >= 0 and b < 0) end)
  end

  defp halves(pcm) do
    values = samples(pcm)
    half = div(length(values), 2)
    {first, second} = Enum.split(values, half)

    {to_pcm(first), to_pcm(second)}
  end

  defp to_pcm(values), do: for(v <- values, into: <<>>, do: <<v::16-signed-little>>)

  defp note(opts) do
    Voice.new(
      [shape: :sine, freq: 440.0, envelope: Envelope.new(attack: 0.01, decay: 0.98, sustain: 0.9)]
      |> Keyword.merge(opts)
    )
  end

  describe "a pitch curve" do
    test "a rising curve ends higher than it started" do
      voice = note(curves: %{freq: Curve.linear(1.0, 2.0)})
      {first, second} = halves(Voice.render(voice, @rate))

      assert crossings(second) > crossings(first) * 1.3
    end

    test "a falling curve ends lower" do
      voice = note(curves: %{freq: Curve.linear(1.0, 0.5)})
      {first, second} = halves(Voice.render(voice, @rate))

      assert crossings(second) < crossings(first) * 0.8
    end

    test "a flat curve is the same as no curve, to the sample" do
      plain = note([])
      flat = note(curves: %{freq: Curve.hold(1.0)})

      assert Voice.render(plain, @rate) == Voice.render(flat, @rate)
    end

    test "a curve that goes up and comes back arrives where it began" do
      voice = note(curves: %{freq: Curve.new([{0.0, 1.0}, {0.5, 2.0}, {1.0, 1.0}])})
      pcm = Voice.render(voice, @rate)

      quarter = div(byte_size(pcm), 8) * 2
      start = binary_part(pcm, 0, quarter)
      middle = binary_part(pcm, div(byte_size(pcm), 4), quarter)
      finish = binary_part(pcm, byte_size(pcm) - quarter, quarter)

      assert crossings(middle) > crossings(start) * 1.3
      assert_in_delta crossings(finish) / crossings(start), 1.0, 0.25
    end
  end

  describe "sweep and curves together" do
    test "sweep still means what it always did" do
      swept = note(sweep: 0.5)
      curved = note(curves: %{freq: Curve.linear(1.0, 0.5)})

      assert Voice.render(swept, @rate) == Voice.render(curved, @rate)
    end

    test "a freq curve supersedes sweep rather than compounding with it" do
      voice = note(sweep: 4.0, curves: %{freq: Curve.linear(1.0, 0.5)})
      only_curve = note(curves: %{freq: Curve.linear(1.0, 0.5)})

      assert Voice.render(voice, @rate) == Voice.render(only_curve, @rate)
    end

    test "a deliberately flat freq curve turns sweep off, rather than letting it through" do
      voice = note(sweep: 4.0, curves: %{freq: Curve.hold(1.0)})

      assert Voice.render(voice, @rate) == Voice.render(note([]), @rate)
    end
  end

  describe "a gain curve" do
    test "a swell ends louder than it began" do
      voice = note(curves: %{gain: Curve.linear(0.1, 1.0)})
      {first, second} = halves(Voice.render(voice, @rate))

      assert peak(second) > peak(first) * 1.5
    end

    test "a fade ends quieter" do
      voice = note(curves: %{gain: Curve.linear(1.0, 0.1)})
      {first, second} = halves(Voice.render(voice, @rate))

      assert peak(second) < peak(first) * 0.7
    end

    defp peak(pcm), do: pcm |> samples() |> Enum.map(&abs/1) |> Enum.max()
  end

  describe "a cutoff curve" do
    test "opening a filter lets more through" do
      closed = note(shape: :saw, cutoff: 0.02)
      opening = note(shape: :saw, cutoff: 0.02, curves: %{cutoff: Curve.linear(1.0, 40.0)})

      {_first, late_closed} = halves(Voice.render(closed, @rate))
      {_first, late_open} = halves(Voice.render(opening, @rate))

      assert peak(late_open) > peak(late_closed) * 2.0
    end

    test "a filter left shut stays shut over the note" do
      closed = note(shape: :saw, cutoff: 0.02)
      {early, late} = halves(Voice.render(closed, @rate))

      assert_in_delta peak(late) / peak(early), 1.0, 0.3
    end

    test "a multiplier past full scale is held there rather than ringing" do
      voice = note(shape: :saw, cutoff: 0.5, curves: %{cutoff: Curve.hold(1_000.0)})
      pcm = Voice.render(voice, @rate)

      assert Enum.all?(samples(pcm), &(abs(&1) <= 32_768))
    end
  end

  describe "writing a bend in a part" do
    test "a bend is stated in semitones and stored as a curve" do
      [{_beat, voice}] = part() |> play(:a4, 1.0, bend: 12) |> Part.notes()

      assert %{freq: curve} = voice.curves
      assert Curve.at(curve, 0.0) == 1.0
      assert_in_delta Curve.at(curve, 1.0), 2.0, 0.0001
    end

    test "a downward bend is negative semitones" do
      [{_beat, voice}] = part() |> play(:a4, 1.0, bend: -12) |> Part.notes()

      assert_in_delta Curve.at(voice.curves.freq, 1.0), 0.5, 0.0001
    end

    test "curves given in full win over the shorthand" do
      [{_beat, voice}] =
        part()
        |> play(:a4, 1.0, bend: 12, curves: %{freq: Curve.hold(1.0)})
        |> Part.notes()

      assert Curve.flat?(voice.curves.freq)
    end

    test "a note with no bend carries no curves at all" do
      [{_beat, voice}] = part() |> play(:a4, 1.0) |> Part.notes()

      assert voice.curves == %{}
    end

    test "a bend survives into the render, which is the point of it being data" do
      synth = note([])

      pcm =
        [part(bpm: 60, synth: synth) |> play(:a3, 2.0, bend: 12)]
        |> TuningFork.Score.from_parts(beats: 2)
        |> TuningFork.Score.render(@rate, channels: 1)

      sounding = binary_part(pcm, 0, trunc(Voice.duration(synth) * @rate) * 2)
      {first, second} = halves(sounding)

      assert crossings(second) > crossings(first) * 1.3
    end
  end
end

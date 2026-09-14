defmodule TuningFork.VoiceTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Voice}

  @rate 44_100

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)
  defp loudest(pcm), do: pcm |> samples() |> Enum.map(&abs/1) |> Enum.max()

  describe "rendering" do
    test "the buffer is as long as the envelope says" do
      voice = Voice.new(envelope: Envelope.new(attack: 0.01, decay: 0.09, release: 0.0))

      assert_in_delta Voice.duration(voice), 0.1, 0.0001
      assert_in_delta byte_size(Voice.render(voice, @rate)) / 2, 0.1 * @rate, 1
    end

    test "a rendered voice actually makes a sound" do
      pcm = Voice.render(Voice.new(shape: :sine, freq: 440.0), @rate)

      assert loudest(pcm) > 10_000
    end

    test "frequency modulation stays on the waveform, with no offset, whatever the shape" do
      for shape <- [:triangle, :saw, :square, :sine] do
        pcm =
          Voice.render(
            Voice.new(
              shape: shape,
              freq: 220.0,
              fm: 8.0,
              fmh: 2.0,
              envelope: Envelope.new(sustain: 1.0, hold: 0.5)
            ),
            @rate
          )

        samples = for <<s::16-signed-little <- pcm>>, do: s / 32_768
        mean = Enum.sum(samples) / length(samples)

        assert abs(mean) < 0.02, "#{shape} drifts to #{mean}"
        assert Enum.max_by(samples, &abs/1) |> abs() <= 1.0
      end
    end

    test "the fm index is in radians of phase, as superdough drives it" do
      envelope = Envelope.new(attack: 0.0, decay: 0.0, sustain: 1.0, hold: 0.02, release: 0.0)

      pcm =
        Voice.render(
          Voice.new(shape: :sine, freq: 100.0, fm: 2.0, fmh: 1.0, gain: 1.0, envelope: envelope),
          @rate
        )

      samples = for <<s::16-signed-little <- pcm>>, do: s / 32_768

      expected =
        for i <- 0..(length(samples) - 1) do
          t = i / @rate
          :math.sin(2 * :math.pi() * 100.0 * t + 2.0 * :math.sin(2 * :math.pi() * 100.0 * t))
        end

      worst = samples |> Enum.zip(expected) |> Enum.map(fn {a, b} -> abs(a - b) end) |> Enum.max()
      assert worst < 0.1
    end

    test "the same voice renders the same samples every time" do
      voice = Voice.new(shape: :noise, cutoff: 0.2, seed: 7)

      assert Voice.render(voice, @rate) == Voice.render(voice, @rate)
    end

    test "a different seed makes different noise" do
      one = Voice.render(Voice.new(shape: :noise, seed: 1), @rate)
      two = Voice.render(Voice.new(shape: :noise, seed: 2), @rate)

      assert one != two
      assert byte_size(one) == byte_size(two)
    end

    test "gain scales the result and zero gain is silence" do
      loud = Voice.render(Voice.new(gain: 1.0), @rate)
      quiet = Voice.render(Voice.new(gain: 0.25), @rate)

      assert loudest(quiet) < loudest(loud)
      assert loudest(Voice.render(Voice.new(gain: 0.0), @rate)) == 0
    end

    test "nothing clips past full scale" do
      pcm = Voice.render(Voice.new(shape: :square, gain: 1.0), @rate)

      assert Enum.all?(samples(pcm), &(&1 >= -32_768 and &1 <= 32_767))
    end

    test "a lowpass takes the edge off" do
      open = Voice.render(Voice.new(shape: :noise, seed: 3), @rate)
      shut = Voice.render(Voice.new(shape: :noise, seed: 3, cutoff: 0.05), @rate)

      assert roughness(shut) < roughness(open)
    end

    test "a highpass takes the body out" do
      open = Voice.render(Voice.new(shape: :noise, seed: 3), @rate)
      cut = Voice.render(Voice.new(shape: :noise, seed: 3, highpass: 0.6), @rate)

      assert roughness(cut) > roughness(open)
    end

    test "a lowpass and a highpass together leave a band" do
      band = Voice.new(shape: :noise, seed: 3, cutoff: 0.5, highpass: 0.2)
      pcm = Voice.render(band, @rate)

      assert roughness(pcm) < roughness(Voice.render(%{band | cutoff: nil}, @rate))
      assert roughness(pcm) > roughness(Voice.render(%{band | highpass: nil}, @rate))
    end

    test "the envelope fades the sound out rather than cutting it" do
      pcm = Voice.render(Voice.new(shape: :sine, envelope: Envelope.hit(0.2)), @rate)
      values = samples(pcm)
      tail = values |> Enum.take(-100) |> Enum.map(&abs/1) |> Enum.max()
      middle = values |> Enum.drop(100) |> Enum.take(100) |> Enum.map(&abs/1) |> Enum.max()

      assert tail < middle
    end
  end

  defp roughness(pcm) do
    values = samples(pcm)

    jump =
      values
      |> Enum.zip(tl(values))
      |> Enum.map(fn {a, b} -> abs(b - a) end)
      |> then(&(Enum.sum(&1) / length(&1)))

    rms = :math.sqrt(Enum.reduce(values, 0, fn v, acc -> acc + v * v end) / length(values))

    jump / max(rms, 1.0)
  end
end

defmodule TuningFork.Fx.LiveTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Fx, Voice}
  alias TuningFork.Fx.Live

  @rate 44_100

  defp tone(freq, seconds \\ 0.5) do
    Voice.new(
      shape: :sine,
      freq: freq,
      gain: 0.8,
      envelope:
        Envelope.new(attack: 0.001, decay: 0.0, sustain: 1.0, hold: seconds, release: 0.001)
    )
    |> Voice.render(@rate)
  end

  defp stereo(mono), do: TuningFork.Mixer.pan(mono, 0.0, 2)

  defp run(effects, pcm, channels \\ 1) do
    {out, _state} = effects |> Live.new(@rate, channels) |> Live.advance(pcm)
    out
  end

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)

  defp rms(pcm) do
    values = samples(pcm)
    :math.sqrt(Enum.sum(Enum.map(values, &(&1 * &1))) / max(length(values), 1))
  end

  defp peak(pcm), do: pcm |> samples() |> Enum.map(&abs/1) |> Enum.max(fn -> 0 end)

  defp channel(pcm, index) do
    for <<l::16-signed-little, r::16-signed-little <- pcm>>, do: elem({l, r}, index)
  end

  defp rms_of(list), do: :math.sqrt(Enum.sum(Enum.map(list, &(&1 * &1))) / max(length(list), 1))

  defp window(pcm, from, to) do
    binary_part(pcm, from * 2, (to - from) * 2)
  end

  describe "level" do
    test "scales the whole signal" do
      dry = tone(440.0)
      assert_in_delta rms(run([level: [amp: 0.5]], dry)), rms(dry) * 0.5, rms(dry) * 0.02
    end
  end

  describe "lowpass and highpass" do
    test "a lowpass lets a low tone through and holds a high one back" do
      low = tone(110.0)
      high = tone(8_000.0)

      assert rms(run([lowpass: [hz: 500]], low)) > rms(low) * 0.8
      assert rms(run([lowpass: [hz: 500]], high)) < rms(high) * 0.2
    end

    test "a highpass does the opposite" do
      low = tone(110.0)
      high = tone(8_000.0)

      assert rms(run([highpass: [hz: 2_000]], low)) < rms(low) * 0.2
      assert rms(run([highpass: [hz: 2_000]], high)) > rms(high) * 0.8
    end

    test "each channel of a stereo signal is filtered on its own" do
      pcm = stereo(tone(8_000.0))
      out = run([lowpass: [hz: 500]], pcm, 2)

      assert rms_of(channel(out, 0)) < rms_of(channel(pcm, 0)) * 0.2
      assert rms_of(channel(out, 1)) < rms_of(channel(pcm, 1)) * 0.2
    end
  end

  describe "slicer" do
    test "chops the signal on and off at the phase" do
      dry = tone(440.0, 1.0)
      out = run([slicer: [phase: 0.5, pulse_width: 0.5]], dry)

      on = window(out, 1_000, 10_000)
      off = window(out, trunc(0.25 * @rate) + 1_000, trunc(0.5 * @rate) - 1_000)

      assert rms(on) > rms(dry) * 0.8
      assert rms(off) < 50
    end

    test "amp_min leaves something sounding in the gaps" do
      dry = tone(440.0, 1.0)
      out = run([slicer: [phase: 0.5, pulse_width: 0.5, amp_min: 0.5]], dry)

      off = window(out, trunc(0.25 * @rate) + 1_000, trunc(0.5 * @rate) - 1_000)

      assert_in_delta rms(off), rms(dry) * 0.5, rms(dry) * 0.05
    end

    test "carries its position across blocks" do
      dry = tone(440.0, 1.0)
      state = Live.new([slicer: [phase: 0.5, pulse_width: 0.5]], @rate, 1)
      half = div(byte_size(dry), 2)

      {first, state} = Live.advance(state, binary_part(dry, 0, half))
      {second, _state} = Live.advance(state, binary_part(dry, half, half))

      assert first <> second == run([slicer: [phase: 0.5, pulse_width: 0.5]], dry)
    end
  end

  describe "tremolo" do
    test "wavers the level rather than cutting it" do
      dry = tone(440.0, 1.0)
      out = run([tremolo: [phase: 0.5, depth: 0.8]], dry)

      loudest = window(out, 1_000, 4_000)
      quietest = window(out, trunc(0.25 * @rate) - 1_500, trunc(0.25 * @rate) + 1_500)

      assert rms(loudest) > rms(quietest) * 2
      assert rms(quietest) > 100
    end
  end

  describe "wobble" do
    test "sweeps a lowpass, so a high tone comes and goes" do
      dry = tone(6_000.0, 1.0)
      out = run([wobble: [phase: 1.0, cutoff_min: 200, cutoff_max: 12_000, q: 2.0]], dry)

      open = window(out, trunc(0.45 * @rate), trunc(0.5 * @rate))
      closed = window(out, trunc(0.95 * @rate), trunc(1.0 * @rate))

      assert rms(open) > rms(closed) * 3
    end
  end

  describe "crush" do
    test "fewer bits means fewer distinct values" do
      dry = tone(440.0)
      out = run([crush: [bits: 4]], dry)

      assert out |> samples() |> Enum.uniq() |> length() <= 17
    end

    test "holding samples lowers the rate" do
      dry = tone(440.0)
      out = run([crush: [hold: 8]], dry)

      assert out
             |> samples()
             |> Enum.take(64)
             |> Enum.chunk_every(8)
             |> Enum.all?(fn chunk -> length(Enum.uniq(chunk)) == 1 end)
    end
  end

  describe "compressor" do
    test "brings a loud signal down and leaves a quiet one alone" do
      loud = tone(440.0)
      quiet = TuningFork.Mixer.scale(loud, 0.05)
      effects = [compressor: [threshold: 0.3, slope_above: 0.2]]

      assert rms(run(effects, loud)) < rms(loud) * 0.7
      assert_in_delta rms(run(effects, quiet)), rms(quiet), rms(quiet) * 0.05
    end
  end

  describe "pan and panslicer" do
    test "pan moves a centred signal to one side" do
      pcm = stereo(tone(440.0))
      out = run([pan: [pan: 1.0]], pcm, 2)

      assert rms_of(channel(out, 0)) < 50
      assert rms_of(channel(out, 1)) > rms_of(channel(pcm, 1)) * 0.9
    end

    test "panslicer swings between the sides" do
      pcm = stereo(tone(440.0, 1.0))
      out = run([panslicer: [phase: 1.0, pan_min: -1.0, pan_max: 1.0, wave: :square]], pcm, 2)

      first_half = binary_part(out, 0, trunc(0.5 * @rate) * 4)
      second_half = binary_part(out, trunc(0.5 * @rate) * 4, trunc(0.5 * @rate) * 4)

      assert rms_of(channel(first_half, 0)) < 50
      assert rms_of(channel(first_half, 1)) > 1_000
      assert rms_of(channel(second_half, 1)) < 50
      assert rms_of(channel(second_half, 0)) > 1_000
    end

    test "a mono stream is left alone" do
      dry = tone(440.0)
      assert run([pan: [pan: 1.0]], dry, 1) == dry
    end
  end

  describe "flanger" do
    test "gives back as much as it was given, changed" do
      dry = tone(440.0)
      out = run([flanger: [phase: 1.0, depth: 4.0, mix: 0.5]], dry)

      assert byte_size(out) == byte_size(dry)
      refute out == dry
      assert peak(out) > 1_000
    end
  end

  describe "through Fx.apply" do
    test "the streaming effects work on a whole buffer too" do
      dry = tone(8_000.0)
      assert rms(Fx.apply(dry, @rate, [lowpass: [hz: 500]], 1)) < rms(dry) * 0.2
      assert rms(Fx.apply(dry, @rate, [level: [amp: 0.0]], 1)) == 0.0
    end

    test "an unknown effect still says so" do
      assert_raise ArgumentError, ~r/no such effect: :warble/, fn ->
        Fx.apply(tone(440.0), @rate, [warble: []], 1)
      end
    end
  end
end

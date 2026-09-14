defmodule TuningFork.FilterTest do
  @moduledoc """
  The resonant filter, measured rather than eyeballed.

  `level/2` runs a sawtooth through a filter and reports how loud one harmonic comes out, in dB
  against the fundamental. That is the only thing a filter can really be asserted on.
  """

  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Filter}

  doctest TuningFork.Filter

  @rate 44_100
  @frames 8_192
  @fundamental 110.0

  defp through(filter, at \\ 0.0) do
    {out, _state} =
      Enum.map_reduce(0..(@frames - 1), Filter.start(filter), fn index, state ->
        raw = 2.0 * :math.fmod(index * @fundamental / @rate, 1.0) - 1.0

        Filter.step(filter, raw, state, at, @rate)
      end)

    out
  end

  defp rms(samples) do
    :math.sqrt(Enum.reduce(samples, 0.0, &(&2 + &1 * &1)) / length(samples))
  end

  defp energy(samples, freq) do
    {re, im} =
      samples
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {sample, index}, {re, im} ->
        angle = 2 * :math.pi() * freq * index / @rate

        {re + sample * :math.cos(angle), im - sample * :math.sin(angle)}
      end)

    :math.sqrt(re * re + im * im) / @frames
  end

  defp level(samples, harmonic) do
    base = energy(samples, @fundamental)
    here = energy(samples, @fundamental * harmonic)

    20 * :math.log10(max(here / max(base, 1.0e-12), 1.0e-9))
  end

  describe "how steeply it rolls off" do
    test "two poles adds twelve dB an octave to the saw's own six" do
      out = through(Filter.new(model: :svf, hz: 220, q: 0.707, poles: 2))

      one = level(out, 4)
      two = level(out, 8)

      assert_in_delta two - one, -18.0, 3.0
    end

    test "four poles falls away faster than two, octave for octave" do
      two = through(Filter.new(model: :svf, hz: 220, q: 0.707, poles: 2))
      four = through(Filter.new(model: :svf, hz: 220, q: 0.707, poles: 4))

      octave_of = fn out -> level(out, 4) - level(out, 2) end

      assert octave_of.(four) < octave_of.(two) - 8.0
    end

    test "four poles is about twice as steep" do
      two = through(Filter.new(model: :svf, hz: 220, q: 0.707, poles: 2))
      four = through(Filter.new(model: :svf, hz: 220, q: 0.707, poles: 4))

      assert level(four, 8) < level(two, 8) - 8.0
    end

    test "it actually filters, unlike the one-pole it replaces" do
      out = through(Filter.new(model: :svf, hz: 400, q: 0.707, poles: 4))

      assert level(out, 8) < -40.0, "a saw's eighth harmonic should be well down"
    end

    test "the fundamental below the cutoff comes through" do
      out = through(Filter.new(model: :svf, hz: 2_000, q: 0.707, poles: 4))

      assert_in_delta level(out, 2), -6.0, 3.0
    end
  end

  describe "resonance" do
    test "it lifts what sits at the cutoff" do
      flat = through(Filter.new(model: :svf, hz: 440, q: 0.707, poles: 4))
      peaked = through(Filter.new(model: :svf, hz: 440, q: 8.0, poles: 4))

      assert level(peaked, 4) > level(flat, 4) + 15.0
    end

    test "a low q leaves the shape alone" do
      out = through(Filter.new(model: :svf, hz: 440, q: 0.707, poles: 4))

      assert level(out, 4) < 3.0, "no peak without resonance"
    end

    test "a q of nothing is no resonance rather than a division by zero" do
      assert Filter.new(q: 0.0).q == 0.0
      assert Filter.feedback(Filter.new(q: 0.0)) == 0.0

      for model <- [:ladder, :svf] do
        out = through(Filter.new(model: model, hz: 440, q: 0.0, poles: 4))

        assert Enum.all?(out, &(abs(&1) <= 1.5)), "#{model} at q of zero should stay finite"
      end
    end
  end

  describe "the ladder" do
    test "renders the same samples it always has" do
      voice =
        TuningFork.Voice.new(
          shape: :saw,
          freq: 220.0,
          filter: Filter.new(model: :ladder, hz: 900.0, q: 6.0, drive: 0.5),
          envelope: Envelope.new(hold: 0.3, sustain: 1.0)
        )

      assert :erlang.phash2(TuningFork.Voice.render(voice, 8_000)) == 100_769_882
    end

    test "it is what a lowpass is unless asked otherwise" do
      assert Filter.new(hz: 440).model == :ladder
    end

    test "a highpass is an svf however it is asked, since the ladder is a lowpass" do
      assert Filter.new(kind: :highpass, model: :ladder).model == :svf
      assert Filter.new(kind: :bandpass, model: :ladder).model == :svf
    end

    test "resonance changes the colour and not the volume" do
      levels = for q <- [0.0, 4.0, 9.0, 20.0, 62.0], do: rms(through(Filter.new(hz: 440, q: q)))

      assert Enum.max(levels) / Enum.min(levels) < 2.5,
             "a ladder should not get much louder or quieter as it resonates: #{inspect(levels)}"
    end

    test "it cannot be driven into blowing up, however hard it is pushed" do
      out = through(Filter.new(hz: 440, q: 62.0, drive: 6.0))

      assert Enum.all?(out, &(abs(&1) < 2.0)), "every stage saturates, so it stays bounded"
    end

    test "resonance is scaled the way Strudel scales it" do
      assert_in_delta Filter.feedback(Filter.new(q: 9.0)), 1.17, 0.001
      assert Filter.feedback(Filter.new(q: 1_000.0)) == 8.0
    end

    test "driving harder saturates rather than getting louder" do
      quiet = rms(through(Filter.new(hz: 880, q: 4.0, drive: 0.0)))
      hard = rms(through(Filter.new(hz: 880, q: 4.0, drive: 3.0)))

      assert hard < quiet, "the makeup takes back what the drive put in"
    end
  end

  describe "the sweep" do
    setup do
      envelope = Envelope.new(attack: 0.0, decay: 0.2, sustain: 0.0, release: 0.0)

      {:ok, filter: Filter.new(hz: 200, q: 2.0, poles: 4, envelope: envelope, amount: 3.0)}
    end

    test "the cutoff starts high and falls back", %{filter: filter} do
      assert Filter.cutoff_at(filter, 0.0) > Filter.cutoff_at(filter, 0.3)
    end

    test "it opens by the octaves it was told", %{filter: filter} do
      assert_in_delta Filter.cutoff_at(filter, 0.0), 200 * 8, 1.0
      assert_in_delta Filter.cutoff_at(filter, 1.0), 200.0, 1.0
    end

    test "the sound is brighter at the start than at the end", %{filter: filter} do
      early = level(through(filter, 0.0), 8)
      late = level(through(filter, 0.5), 8)

      assert early > late + 10.0
    end

    test "no envelope means it sits still" do
      filter = Filter.new(hz: 500, amount: 4.0)

      assert Filter.cutoff_at(filter, 0.0) == 500.0
      assert Filter.cutoff_at(filter, 9.0) == 500.0
    end
  end

  describe "staying stable" do
    test "a cutoff past Nyquist is held below it rather than blowing up" do
      out = through(Filter.new(hz: 1_000_000, q: 0.707, poles: 4))

      assert Enum.all?(out, &(abs(&1) < 10.0))
    end

    test "a cutoff at nothing is held above zero" do
      out = through(Filter.new(hz: 0, q: 0.707, poles: 4))

      assert Enum.all?(out, &(abs(&1) < 10.0))
    end

    test "high resonance rings but does not run away" do
      out = through(Filter.new(hz: 440, q: 12.0, poles: 4))

      assert Enum.all?(out, &(abs(&1) < 50.0))
    end
  end

  describe "the other kinds" do
    test "a highpass keeps what a lowpass throws away" do
      low = through(Filter.new(kind: :lowpass, hz: 880, poles: 2))
      high = through(Filter.new(kind: :highpass, hz: 880, poles: 2))

      assert level(high, 16) > level(low, 16) + 20.0
    end

    test "a bandpass keeps the middle" do
      out = through(Filter.new(kind: :bandpass, hz: 880, q: 4.0, poles: 2))

      assert level(out, 8) > level(out, 1)
      assert level(out, 8) > level(out, 32)
    end
  end
end

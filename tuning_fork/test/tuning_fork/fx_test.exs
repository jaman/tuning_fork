defmodule TuningFork.FxTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Fx, Voice}

  @rate 44_100

  defp click do
    Voice.render(
      Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.04), gain: 0.8),
      @rate
    )
  end

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)
  defp frames(pcm), do: div(byte_size(pcm), 2)

  defp after_the_sound(pcm, from) do
    pcm |> samples() |> Enum.drop(from) |> Enum.map(&abs/1) |> Enum.max(fn -> 0 end)
  end

  describe "echo" do
    test "makes the sound go on after it stopped" do
      dry = click()
      wet = Fx.echo(dry, @rate, delay: 0.1, feedback: 0.5, mix: 0.6)

      assert frames(wet) > frames(dry)
      assert after_the_sound(wet, frames(dry)) > 500
    end

    test "more feedback rings for longer" do
      short = Fx.echo(click(), @rate, delay: 0.1, feedback: 0.2, mix: 0.6)
      long = Fx.echo(click(), @rate, delay: 0.1, feedback: 0.8, mix: 0.6)

      assert frames(long) > frames(short)
    end

    test "no mix leaves the sound as it was" do
      dry = click()
      wet = Fx.echo(dry, @rate, delay: 0.1, mix: 0.0)

      assert binary_part(wet, 0, byte_size(dry)) == dry
    end

    test "the repeats are quieter than what made them" do
      wet = Fx.echo(click(), @rate, delay: 0.1, feedback: 0.5, mix: 1.0)
      values = samples(wet)
      first = values |> Enum.take(frames(click())) |> Enum.map(&abs/1) |> Enum.max()
      later = after_the_sound(wet, trunc(0.1 * @rate) + frames(click()))

      assert later < first
    end
  end

  describe "reverb" do
    test "leaves a tail behind the sound" do
      dry = click()
      wet = Fx.reverb(dry, @rate, room: 0.8, mix: 0.6)

      assert frames(wet) > frames(dry)
      assert after_the_sound(wet, frames(dry)) > 200
    end

    test "a bigger room rings for longer" do
      small = Fx.reverb(click(), @rate, room: 0.1, mix: 0.6)
      large = Fx.reverb(click(), @rate, room: 1.0, mix: 0.6)

      assert frames(large) > frames(small)
    end

    test "damping takes the top off the tail" do
      bright = Fx.reverb(click(), @rate, room: 0.8, damp: 0.0, mix: 1.0)
      dark = Fx.reverb(click(), @rate, room: 0.8, damp: 0.9, mix: 1.0)

      assert roughness(dark) < roughness(bright)
    end

    test "nothing clips" do
      wet = Fx.reverb(click(), @rate, room: 1.0, mix: 1.0)

      assert Enum.all?(samples(wet), &(&1 >= -32_768 and &1 <= 32_767))
    end
  end

  describe "drive" do
    test "squashes the peaks rather than letting them through" do
      dry = click()
      wet = Fx.drive(dry, amount: 0.8)

      quiet = samples(dry) |> Enum.map(&abs/1) |> Enum.max()
      squashed = samples(wet) |> Enum.map(&abs/1) |> Enum.max()

      assert squashed < quiet
      assert Enum.all?(samples(wet), &(&1 >= -32_768 and &1 <= 32_767))
    end

    test "does not change the length" do
      assert frames(Fx.drive(click(), amount: 0.5)) == frames(click())
    end
  end

  describe "chains" do
    test "effects run in the order they are given" do
      chained = Fx.apply(click(), @rate, echo: [delay: 0.1], reverb: [room: 0.5])

      assert frames(chained) > frames(click())
    end

    test "an unknown effect says so rather than being ignored" do
      assert_raise ArgumentError, ~r/no such effect/, fn ->
        Fx.apply(click(), @rate, chorus: [])
      end
    end

    test "an empty chain changes nothing" do
      assert Fx.apply(click(), @rate, []) == click()
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

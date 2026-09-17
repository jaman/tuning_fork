defmodule TuningFork.Pattern.AheadTest do
  use ExUnit.Case, async: true

  alias TuningFork.Pattern.{Ahead, Mini, Player}

  @rate 44_100
  @chunk 256

  defp loud?(pcm),
    do:
      pcm |> then(&for(<<s::16-signed-little <- &1>>, do: abs(s))) |> Enum.max(fn -> 0 end) > 500

  test "gives the same chunks the player would, in order, and renders ahead between calls" do
    player = Player.new(Mini.parse("bd*4"), @rate, cps: 2.0)
    {:ok, ahead} = Ahead.start_link(player: player, chunk: @chunk, channels: 2, depth: 4)

    expected =
      Enum.reduce(1..8, {[], player}, fn _, {acc, p} ->
        {pcm, p} = Player.advance(p, @chunk, 2)
        {[pcm | acc], p}
      end)
      |> elem(0)
      |> Enum.reverse()

    Process.sleep(50)
    assert Ahead.rendered(ahead) == 4
    got = for _ <- 1..8, do: Ahead.next(ahead)
    assert got == expected
    assert Enum.any?(got, &loud?/1)
    assert Ahead.cycle(ahead) > 0.0
  end

  test "a change to the player applies from the render frontier on, and stop ends it" do
    player = Player.new(Mini.parse("bd*4"), @rate, cps: 2.0)
    {:ok, ahead} = Ahead.start_link(player: player, chunk: @chunk, channels: 2, depth: 2)
    Ahead.apply(ahead, &Player.gain(&1, 0.0))
    for _ <- 1..2, do: Ahead.next(ahead)
    quiet = for _ <- 1..8, do: Ahead.next(ahead)
    refute Enum.any?(quiet, &loud?/1)
    ref = Process.monitor(ahead)
    Ahead.stop(ahead)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
  end
end

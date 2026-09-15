defmodule TuningFork.Pattern.PlayerTest do
  @moduledoc """
  The player, driven a block at a time without a sound device.

  Audio is checked by looking for loud samples where a note should be and silence where it
  should not, which is what a listener would report.
  """

  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Voice}
  alias TuningFork.Pattern, as: P
  alias TuningFork.Pattern.{Control, Mini, Player}

  @rate 44_100

  defp run(player, blocks, frames \\ 512) do
    Enum.reduce(1..blocks, {<<>>, player}, fn _block, {acc, player} ->
      {pcm, player} = Player.advance(player, frames, 2)
      {acc <> pcm, player}
    end)
  end

  defp peak(pcm) do
    pcm |> then(&for(<<s::16-signed-little <- &1>>, do: abs(s))) |> Enum.max(fn -> 0 end)
  end

  defp loud?(pcm), do: peak(pcm) > 500

  defp beep(freq \\ 440.0) do
    Voice.new(shape: :sine, freq: freq, envelope: Envelope.hit(0.05), gain: 0.9)
  end

  defp counting(agent) do
    fn value, seconds ->
      Agent.update(agent, &[{value, Float.round(seconds, 4)} | &1])
      beep()
    end
  end

  describe "walking a pattern" do
    test "it gives back exactly the frames it was asked for" do
      player = Player.new(P.pure("bd"), @rate)

      {pcm, _player} = Player.advance(player, 512, 2)

      assert byte_size(pcm) == 512 * 4
    end

    test "mono is half the bytes of stereo" do
      player = Player.new(P.pure("bd"), @rate)

      {pcm, _player} = Player.advance(player, 512, 1)

      assert byte_size(pcm) == 512 * 2
    end

    test "a pattern with nothing in it is silence, not nothing" do
      {pcm, _player} = P.silence() |> Player.new(@rate) |> run(8)

      refute loud?(pcm)
      assert byte_size(pcm) == 8 * 512 * 4
    end

    test "the position advances with the frames handed out" do
      player = Player.new(P.pure("bd"), @rate, cps: 1.0)

      assert Player.cycle(player) == 0.0

      {_pcm, player} = Player.advance(player, @rate, 2)

      assert_in_delta Player.cycle(player), 1.0, 0.0001
    end

    test "cycles per second is what decides how fast it runs" do
      {_pcm, slow} = P.pure("bd") |> Player.new(@rate, cps: 0.5) |> run(1, @rate)
      {_pcm, quick} = P.pure("bd") |> Player.new(@rate, cps: 2.0) |> run(1, @rate)

      assert_in_delta Player.cycle(slow), 0.5, 0.0001
      assert_in_delta Player.cycle(quick), 2.0, 0.0001
    end
  end

  describe "what it sounds" do
    test "a note is heard where the pattern puts it, and not before" do
      {pcm, _player} =
        P.pure("bd")
        |> Player.new(@rate, cps: 1.0, voice: fn _v, _s -> beep() end)
        |> run(1, @rate)

      first = binary_part(pcm, 0, 4_000 * 4)

      assert loud?(first), "the note on the downbeat should sound at the start"
    end

    test "a rest is silent where the pattern has nothing" do
      pattern = Mini.parse("~ bd")

      {pcm, _player} =
        pattern |> Player.new(@rate, cps: 1.0, voice: fn _v, _s -> beep() end) |> run(1, @rate)

      refute loud?(binary_part(pcm, 0, 10_000 * 4)), "the first half is a rest"
      assert loud?(binary_part(pcm, 22_050 * 4, 10_000 * 4)), "the second half is a note"
    end

    test "the kit turns names into sound without being asked to" do
      {pcm, _player} =
        "bd sn hh cp" |> Mini.parse() |> Player.new(@rate, cps: 1.0) |> run(1, @rate)

      assert loud?(pcm)
    end

    test "a name the kit does not know is skipped rather than crashing the block" do
      {pcm, _player} =
        "bd nonsense" |> Mini.parse() |> Player.new(@rate, cps: 1.0) |> run(1, @rate)

      assert loud?(binary_part(pcm, 0, 10_000 * 4))
      refute loud?(binary_part(pcm, 30_000 * 4, 10_000 * 4))
    end

    test "a note starts at its own sample, not at the block boundary" do
      quiet = fn _value, _seconds -> beep() end

      {pcm, _player} =
        P.shift(P.pure("bd"), 0.5)
        |> Player.new(@rate, cps: 1.0, voice: quiet)
        |> run(1, @rate)

      refute loud?(binary_part(pcm, 0, 20_000 * 4))
      assert loud?(binary_part(pcm, 22_050 * 4, 4_000 * 4))
    end
  end

  describe "what the voice function is told" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      {:ok, agent: agent}
    end

    test "every value in the cycle, once each", %{agent: agent} do
      {_pcm, _player} =
        "bd sn hh"
        |> Mini.parse()
        |> Player.new(@rate, cps: 1.0, voice: counting(agent))
        |> run(1, @rate)

      values = agent |> Agent.get(&Enum.reverse/1) |> Enum.map(&elem(&1, 0))

      assert values == ["bd", "sn", "hh"]
    end

    test "how long the event lasts, in seconds", %{agent: agent} do
      {_pcm, _player} =
        "bd sn"
        |> Mini.parse()
        |> Player.new(@rate, cps: 0.5, voice: counting(agent))
        |> run(1, 2 * @rate)

      lengths = agent |> Agent.get(&Enum.reverse/1) |> Enum.map(&elem(&1, 1))

      assert lengths == [1.0, 1.0], "half a cycle at half a cycle per second is one second"
    end

    test "a note is triggered once, not once per block it spans", %{agent: agent} do
      {_pcm, _player} =
        P.pure("bd")
        |> Player.new(@rate, cps: 1.0, voice: counting(agent))
        |> run(86, 512)

      assert Agent.get(agent, &length/1) == 1
    end

    test "a delayed note is played again at the delay time, each repeat once", %{agent: agent} do
      pattern =
        "bd ~ ~ ~"
        |> Mini.parse()
        |> Control.delay(0.5)
        |> Control.delaytime(0.125)

      {_pcm, player} =
        pattern
        |> Player.new(@rate, cps: 1.0, voice: counting(agent))
        |> run(86, 512)

      values = agent |> Agent.get(&Enum.reverse/1) |> Enum.map(&elem(&1, 0))
      assert length(values) == 5
      gains = Enum.map(values, &Map.get(&1, :gain, 1.0))
      assert gains == Enum.sort(gains, :desc)
      assert player.pending == []
    end

    test "a repeat still lands after the pattern is swapped out", %{agent: agent} do
      pattern =
        "bd ~ ~ ~"
        |> Mini.parse()
        |> Control.delay(0.5)
        |> Control.delaytime(0.25)

      player = Player.new(pattern, @rate, cps: 1.0, voice: counting(agent))

      {_pcm, player} = run(player, 1, 512)
      player = Player.update(player, P.silence(), at: :now)
      {_pcm, _player} = run(player, 86, 512)

      assert Agent.get(agent, &length/1) == 5
    end
  end

  describe "swapping while it plays" do
    test "at: :now takes effect on the next block" do
      player = Player.new(P.pure("bd"), @rate, cps: 1.0)
      {_pcm, player} = Player.advance(player, 512, 2)

      player = Player.update(player, P.pure("sn"), at: :now)

      refute Player.pending?(player)
    end

    test "at: :cycle waits for the cycle line" do
      player = Player.new(P.pure("bd"), @rate, cps: 1.0)
      {_pcm, player} = Player.advance(player, div(@rate, 2), 2)

      player = Player.update(player, P.pure("sn"), at: :cycle)
      assert Player.pending?(player)

      {_pcm, player} = Player.advance(player, div(@rate, 8), 2)
      assert Player.pending?(player), "still inside the cycle"

      {_pcm, player} = Player.advance(player, div(@rate, 2), 2)
      refute Player.pending?(player), "past the line, so it went in"
    end

    test "the swapped pattern is what sounds afterwards" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      player = Player.new(P.pure("bd"), @rate, cps: 1.0, voice: counting(agent))
      {_pcm, player} = Player.advance(player, div(@rate, 2), 2)

      player = Player.update(player, P.pure("sn"), at: :cycle)
      {_pcm, _player} = run(player, 1, @rate)

      values = agent |> Agent.get(&Enum.reverse/1) |> Enum.map(&elem(&1, 0))

      assert values == ["bd", "sn"]
    end

    test "a pattern counting cycles keeps counting through a swap" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      counted = P.every(2, &P.with_value(&1, fn _v -> "even" end), P.pure("odd"))

      player = Player.new(counted, @rate, cps: 1.0, voice: counting(agent))
      {_pcm, player} = run(player, 2, @rate)

      player = Player.update(player, counted, at: :cycle)
      {_pcm, _player} = run(player, 2, @rate)

      values = agent |> Agent.get(&Enum.reverse/1) |> Enum.map(&elem(&1, 0))

      assert values == ["even", "odd", "even", "odd"]
    end

    test "the position does not restart on a swap" do
      player = Player.new(P.pure("bd"), @rate, cps: 1.0)
      {_pcm, player} = run(player, 3, @rate)

      player = Player.update(player, P.pure("sn"), at: :now)
      {_pcm, player} = Player.advance(player, 512, 2)

      assert Player.cycle(player) > 3.0
    end
  end

  describe "housekeeping" do
    test "the master gain scales everything, sounding notes included, and zero is silence" do
      player = Player.new(P.pure("bd"), @rate, cps: 0.25, voice: fn _, _ -> beep() end)
      {loud, player} = Player.advance(player, 256, 2)
      assert loud?(loud)

      {half, player} = player |> Player.gain(0.5) |> Player.advance(256, 2)
      assert peak(half) < peak(loud)
      assert peak(half) > 0

      {silent, _} = player |> Player.gain(0.0) |> Player.advance(256, 2)
      assert peak(silent) == 0
    end

    test "hush stops what is sounding but keeps the place" do
      player = Player.new(P.pure("bd"), @rate, cps: 0.25)
      {_pcm, player} = Player.advance(player, 512, 2)

      assert Player.sounding(player) == 1

      hushed = Player.hush(player)

      assert Player.sounding(hushed) == 0
      assert Player.cycle(hushed) == Player.cycle(player)
    end

    test "changing speed keeps the place" do
      player = Player.new(P.pure("bd"), @rate, cps: 1.0)
      {_pcm, player} = run(player, 1, @rate)

      quickened = Player.cps(player, 4.0)

      assert Player.cycle(quickened) == Player.cycle(player)
      assert quickened.cps == 4.0
    end

    test "notes playing at once are capped" do
      player = Player.new(P.fast(P.pure("bd"), 64), @rate, cps: 4.0, voices: 4)
      {_pcm, player} = run(player, 8, 2_048)

      assert Player.playing(player) <= 4
    end

    test "the ones past the cap fade rather than being cut, so the total stays bounded" do
      player = Player.new(P.fast(P.pure("bd"), 64), @rate, cps: 4.0, voices: 4)
      {_pcm, player} = run(player, 16, 2_048)

      assert Player.sounding(player) <= 8, "fading notes should finish, not pile up"
      assert Player.sounding(player) >= Player.playing(player)
    end

    test "a fade finishes instead of being restarted every block" do
      player = Player.new(P.fast(P.pure("bd"), 32), @rate, cps: 2.0, voices: 2)
      {_pcm, busy} = run(player, 4, 1_024)

      assert Player.sounding(busy) > 0

      {_pcm, settled} = run(%{busy | pattern: P.silence()}, 40, 1_024)

      assert Player.sounding(settled) == 0,
             "a fade that restarted every block would never finish"
    end
  end

  describe "rendering to be played round and round" do
    test "it is exactly the cycles asked for, not the cycles plus a ring-out" do
      pcm = Player.render(P.pure("bd"), @rate, cycles: 4, cps: 0.5)

      assert byte_size(pcm) == trunc(4 / 0.5 * @rate) * 2 * 2
    end

    test "nothing plays twice over itself at the cycle line" do
      pattern = P.fast(P.pure("bd"), 4)
      frames = trunc(2 / 0.5 * @rate)

      folded = Player.render(pattern, @rate, cycles: 2, cps: 0.5)
      {plain, _player} = Player.advance(Player.new(pattern, @rate, cps: 0.5), frames, 2)

      assert peak(folded) <= peak(plain) * 1.05
      assert peak(folded) < 32_767
    end

    test "it is not silence" do
      assert peak(Player.render(P.pure("bd"), @rate, cycles: 1, cps: 2.0)) > 1_000
    end
  end
end

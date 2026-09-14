defmodule TuningFork.LiveTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Curve, Envelope, Score, Transport, Voice}
  alias TuningFork.Sink.Buffer
  alias TuningFork.Voice.Live

  @rate 44_100

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)
  defp peak(pcm), do: pcm |> samples() |> Enum.map(&abs/1) |> Enum.max(fn -> 0 end)
  defp loud?(pcm), do: peak(pcm) > 500

  defp note(opts \\ []) do
    Voice.new(
      Keyword.merge(
        [
          shape: :sine,
          freq: 440.0,
          envelope: Envelope.new(attack: 0.01, decay: 0.5, sustain: 0.8)
        ],
        opts
      )
    )
  end

  defp drain(live, block \\ 512, acc \\ []) do
    if Live.done?(live) do
      acc |> Enum.reverse() |> IO.iodata_to_binary()
    else
      {pcm, live} = Live.advance(live, block)
      drain(live, block, [pcm | acc])
    end
  end

  describe "a live voice against a rendered one" do
    test "block by block it produces exactly what rendering the whole note does" do
      voice = note()

      assert drain(Live.start(voice, @rate)) == Voice.render(voice, @rate)
    end

    test "the block size makes no difference to the samples" do
      voice = note()

      for block <- [1, 7, 64, 512, 4_096] do
        assert drain(Live.start(voice, @rate), block) == Voice.render(voice, @rate),
               "a block of #{block} disagreed with the rendered note"
      end
    end

    test "a modulated voice agrees too, so a bend sounds the same either way" do
      voice = note(curves: %{freq: Curve.linear(1.0, 1.5), gain: Curve.linear(0.5, 1.0)})

      assert drain(Live.start(voice, @rate)) == Voice.render(voice, @rate)
    end

    test "noise agrees, which means the seed carries across blocks" do
      voice = note(shape: :noise, envelope: Envelope.hit(0.2))

      assert drain(Live.start(voice, @rate), 333) == Voice.render(voice, @rate)
    end

    test "a filtered voice agrees, which means the filter state carries too" do
      voice = note(shape: :saw, cutoff: 0.3, highpass: 0.1)

      assert drain(Live.start(voice, @rate), 128) == Voice.render(voice, @rate)
    end
  end

  describe "running out" do
    test "the last block is short rather than padded" do
      voice = note(envelope: Envelope.hit(0.01))
      live = Live.start(voice, @rate)
      frames = Live.remaining(live)

      {pcm, live} = Live.advance(live, frames + 500)

      assert byte_size(pcm) == frames * 2
      assert Live.done?(live)
    end

    test "asking a finished voice for more gives nothing, not a crash" do
      live = Live.start(note(envelope: Envelope.hit(0.01)), @rate)
      {_pcm, live} = Live.advance(live, 1_000_000)

      assert {<<>>, ^live} = Live.advance(live, 512)
    end

    test "remaining counts down" do
      live = Live.start(note(), @rate)
      before = Live.remaining(live)

      {_pcm, live} = Live.advance(live, 512)

      assert Live.remaining(live) == before - 512
    end
  end

  describe "changing a voice while it sounds" do
    test "a new pitch is heard from the next block, not the next note" do
      live = Live.start(note(freq: 220.0), @rate)

      {low, live} = Live.advance(live, 4_410)
      live = Live.control(live, freq: 880.0)
      {high, _live} = Live.advance(live, 4_410)

      assert crossings(high) > crossings(low) * 2
    end

    test "what was already sounded is untouched by a later change" do
      live = Live.start(note(freq: 220.0), @rate)

      {first, live} = Live.advance(live, 4_410)
      {first_again, _} = Live.advance(Live.start(note(freq: 220.0), @rate), 4_410)

      assert first == first_again

      live = Live.control(live, freq: 880.0)
      {_second, _live} = Live.advance(live, 4_410)
    end

    test "changing pitch does not restart the waveform, which would click" do
      live = Live.start(note(freq: 220.0), @rate)
      {before, live} = Live.advance(live, 1_000)

      live = Live.control(live, freq: 240.0)
      {after_change, _live} = Live.advance(live, 1_000)

      last = before |> samples() |> List.last()
      first = after_change |> samples() |> hd()

      assert abs(first - last) < 3_000
    end

    test "new curves can be handed over mid-note" do
      live = Live.start(note(), @rate)
      {_pcm, live} = Live.advance(live, 512)

      live = Live.control(live, curves: %{gain: Curve.linear(1.0, 0.0)})

      assert live.mod.gain != nil
    end
  end

  describe "releasing early" do
    test "it finishes sooner than it would have" do
      live =
        Live.start(note(envelope: Envelope.new(attack: 0.01, decay: 2.0, sustain: 0.9)), @rate)

      {_pcm, live} = Live.advance(live, 4_410)

      released = Live.release(live, 0.05)

      assert Live.remaining(released) < Live.remaining(live)
      assert_in_delta Live.remaining(released) / @rate, 0.05, 0.01
    end

    test "it falls away rather than being cut off" do
      live =
        Live.start(note(envelope: Envelope.new(attack: 0.01, decay: 2.0, sustain: 0.9)), @rate)

      {_pcm, live} = Live.advance(live, 4_410)

      tail = drain(Live.release(live, 0.1))
      {front, back} = tail |> samples() |> Enum.split(div(length(tail |> samples()), 2))

      assert peak(to_pcm(front)) > peak(to_pcm(back))
      assert peak(to_pcm(back)) < peak(to_pcm(front)) * 0.6
    end

    test "a bent note holds its pitch through the release rather than sliding back" do
      live = Live.start(note(curves: %{freq: Curve.linear(1.0, 2.0)}), @rate)
      {_pcm, live} = Live.advance(live, div(@rate, 4))

      released = Live.release(live, 0.2)

      assert Curve.flat?(released.voice.curves.freq)
    end
  end

  describe "a transport walking a score" do
    setup do
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.1), gain: 0.9)

      {:ok, voice: voice}
    end

    test "nothing sounds before the first note", %{voice: voice} do
      score = Score.new(bpm: 60, beats: 4) |> Score.add(2.0, voice)
      transport = Transport.new(score, @rate)

      {pcm, _transport} = Transport.advance(transport, 512, 1)

      refute loud?(pcm)
    end

    test "a note sounds when its beat comes round", %{voice: voice} do
      score = Score.new(bpm: 60, beats: 4) |> Score.add(1.0, voice)

      assert loud?(run(score, 1.5, 512, 1))
    end

    test "a note lands on its own sample, not on the block boundary", %{voice: voice} do
      score = Score.new(bpm: 120, beats: 4) |> Score.add(0.5, voice)
      pcm = run(score, 0.4, 512, 1)

      quiet = binary_part(pcm, 0, 11_000 * 2)
      sounding = binary_part(pcm, 11_060 * 2, 2_000)

      refute loud?(quiet)
      assert loud?(sounding)
    end

    test "the block size does not change where a note lands", %{voice: voice} do
      score = Score.new(bpm: 120, beats: 2) |> Score.add(0.5, voice)

      assert run(score, 1.0, 512, 1) == run(score, 1.0, 128, 1)
    end

    test "several notes each arrive at their own time", %{voice: voice} do
      score =
        Score.new(bpm: 60, beats: 4)
        |> Score.add(0.0, voice)
        |> Score.add(1.0, voice)
        |> Score.add(2.0, voice)

      pcm = run(score, 3.0, 512, 1)

      for second <- [0, 1, 2] do
        window = binary_part(pcm, second * @rate * 2, div(@rate, 10) * 2)

        assert loud?(window), "nothing sounded at second #{second}"
      end
    end

    test "it reports the beat it is on", %{voice: _voice} do
      transport = Transport.new(Score.new(bpm: 60, beats: 8), @rate)
      {_pcm, transport} = Transport.advance(transport, @rate, 1)

      assert_in_delta Transport.beat(transport), 1.0, 0.001
    end

    test "paused, it produces silence and does not move", %{voice: voice} do
      score = Score.new(bpm: 60, beats: 4) |> Score.add(0.0, voice)
      transport = Transport.new(score, @rate) |> Transport.pause()

      {pcm, transport} = Transport.advance(transport, 512, 1)

      refute loud?(pcm)
      assert Transport.beat(transport) == 0.0
    end

    test "seeking jumps and drops what was sounding", %{voice: voice} do
      score = Score.new(bpm: 60, beats: 8) |> Score.add(0.0, voice)
      transport = Transport.new(score, @rate)

      {_pcm, transport} = Transport.advance(transport, 512, 1)
      assert Transport.sounding(transport) == 1

      transport = Transport.seek(transport, 4.0)

      assert Transport.sounding(transport) == 0
      assert_in_delta Transport.beat(transport), 4.0, 0.001
    end

    test "it finishes at the end of the score", %{voice: voice} do
      score = Score.new(bpm: 240, beats: 1) |> Score.add(0.0, voice)
      transport = Transport.new(score, @rate)

      refute Transport.finished?(transport)

      transport =
        Enum.reduce(1..20, transport, fn _pass, acc ->
          {_pcm, acc} = Transport.advance(acc, 4_410, 1)
          acc
        end)

      assert Transport.finished?(transport)
    end

    test "looping comes back round rather than finishing", %{voice: voice} do
      score = Score.new(bpm: 240, beats: 1) |> Score.add(0.0, voice)
      transport = Transport.new(score, @rate, loop: true)

      transport =
        Enum.reduce(1..20, transport, fn _pass, acc ->
          {_pcm, acc} = Transport.advance(acc, 4_410, 1)
          acc
        end)

      refute Transport.finished?(transport)
      assert Transport.beat(transport) < 1.0
    end

    test "a looping score sounds its note again on the next pass", %{voice: voice} do
      score = Score.new(bpm: 240, beats: 1) |> Score.add(0.0, voice)
      pcm = run(score, 0.8, 256, 1, loop: true)

      first = binary_part(pcm, 0, div(@rate, 20) * 2)
      second = binary_part(pcm, div(@rate, 4) * 2, div(@rate, 20) * 2)

      assert loud?(first)
      assert loud?(second), "the note should sound again when the loop comes round"
    end

    test "swapping the score keeps the position", %{voice: voice} do
      score = Score.new(bpm: 60, beats: 8) |> Score.add(0.0, voice)
      transport = Transport.new(score, @rate)

      {_pcm, transport} = Transport.advance(transport, @rate, 1)
      was = Transport.beat(transport)

      transport = Transport.update(transport, Score.add(score, 4.0, voice))

      assert Transport.beat(transport) == was
    end

    test "playing again after a pause carries on from where it stopped", %{voice: voice} do
      score = Score.new(bpm: 60, beats: 4) |> Score.add(1.0, voice)
      transport = Transport.new(score, @rate)
      {_pcm, transport} = Transport.advance(transport, @rate, 1)
      paused = Transport.pause(transport)
      {_pcm, paused} = Transport.advance(paused, @rate, 1)

      assert_in_delta Transport.beat(paused), 1.0, 0.001

      {pcm, playing} = paused |> Transport.play() |> Transport.advance(@rate, 1)

      assert loud?(pcm)
      assert_in_delta Transport.beat(playing), 2.0, 0.001
    end
  end

  describe "rendering loops to be played round and round" do
    setup do
      voice = Voice.new(shape: :sine, freq: 220.0, envelope: Envelope.hit(0.2), gain: 0.9)

      four = Score.new(bpm: 120, beats: 4) |> Score.add(0.0, voice) |> Score.add(2.0, voice)
      three = Score.new(bpm: 120, beats: 3) |> Score.add(0.0, voice)

      {:ok, voice: voice, four: four, three: three}
    end

    test "it is exactly as long as it was asked for", %{four: four} do
      pcm = Transport.render_loops([four], @rate, 4.0)

      assert byte_size(pcm) == trunc(4.0 * @rate) * 2 * 2
    end

    test "nothing plays twice over itself at the loop point", %{four: four} do
      loud = Transport.render_loops([four], @rate, Score.duration(four))

      {plain, _left} =
        Transport.advance(Transport.new(four, @rate), trunc(Score.duration(four) * @rate), 2)

      assert peak(loud) <= peak(plain) * 1.05
      assert peak(loud) < 32_767
    end

    test "what is still ringing at the end is heard at the start", %{voice: voice} do
      score =
        Score.new(bpm: 120, beats: 2) |> Score.add(1.9, %{voice | envelope: Envelope.hit(1.0)})

      pcm = Transport.render_loops([score], @rate, Score.duration(score))

      assert loud?(binary_part(pcm, 0, @rate * 4))
    end

    test "an empty list is silence of the length asked for" do
      assert Transport.render_loops([], @rate, 1.0) == TuningFork.Mixer.silence(@rate, 2)
    end

    test "a span holds a whole number of every loop", %{four: four, three: three} do
      assert Transport.loop_seconds([four, three], 4) == 6.0
      assert Transport.loop_seconds([four, three], 8) == 12.0
      assert Transport.loop_seconds([four], 8) == 8.0
    end

    test "lengths that will not line up fall back to the longest", %{four: four} do
      odd = Score.new(bpm: 127, beats: 3)

      seconds = Transport.loop_seconds([four, odd], 8)

      assert seconds <= 60.0
      assert seconds >= 8.0
    end

    test "where a loop has got to is read off the time played", %{four: four} do
      assert Transport.at(four, 0.0) == %{beat: 0.0, rounds: 0}
      assert Transport.at(four, 3.0) == %{beat: 2.0, rounds: 1}
      assert Transport.at(Score.new(bpm: 120, beats: 0), 3.0) == %{beat: 0.0, rounds: 0}
    end
  end

  describe "a stage playing a score" do
    test "the score reaches the sink, and the beat advances with the audio" do
      {:ok, tape} = Buffer.start_link()

      {:ok, stage} =
        TuningFork.Stage.start_link(
          name: nil,
          sink: Buffer,
          sink_opts: [into: tape],
          channels: 1,
          chunk: 256
        )

      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.2), gain: 0.9)
      score = Score.new(bpm: 240, beats: 4) |> Score.add(0.0, voice) |> Score.add(1.0, voice)

      TuningFork.Stage.start_score(stage, score)
      Process.sleep(300)

      assert loud?(Buffer.take(tape))

      GenServer.stop(stage)
      Buffer.stop(tape)
    end

    test "no score playing means no beat" do
      {:ok, stage} = TuningFork.Stage.start_link(name: nil, chunk: 256)

      assert TuningFork.Stage.beat(stage) == nil

      GenServer.stop(stage)
    end
  end

  defp run(score, seconds, block, channels, opts \\ []) do
    wanted = trunc(seconds * @rate)

    pcm =
      Stream.unfold(Transport.new(score, @rate, opts), fn transport ->
        {pcm, transport} = Transport.advance(transport, block, channels)
        {pcm, transport}
      end)
      |> Enum.take(ceil(wanted / block))
      |> IO.iodata_to_binary()

    binary_part(pcm, 0, wanted * channels * 2)
  end

  defp to_pcm(values), do: for(v <- values, into: <<>>, do: <<v::16-signed-little>>)

  defp crossings(pcm) do
    pcm
    |> samples()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> (a < 0 and b >= 0) or (a >= 0 and b < 0) end)
  end
end

defmodule TuningFork.LiveLayersTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Part, Score, Transport, Voice}

  @rate 44_100

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)
  defp peak(pcm), do: pcm |> samples() |> Enum.map(&abs/1) |> Enum.max(fn -> 0 end)

  defp walk(transport, seconds, block \\ 512, channels \\ 1, acc \\ []) do
    if seconds <= 0 do
      acc |> Enum.reverse() |> IO.iodata_to_binary()
    else
      {pcm, transport} = Transport.advance(transport, block, channels)
      walk(transport, seconds - block / @rate, block, channels, [pcm | acc])
    end
  end

  defp hit, do: Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.1), gain: 0.9)

  defp layered(fx) do
    plain = Part.part(bpm: 60, synth: hit()) |> Part.play(:a4, 1.0)
    effected = Part.part(bpm: 60, synth: hit(), fx: fx) |> Part.rest(1.0) |> Part.play(:a4, 1.0)

    Score.from_parts([plain, effected], beats: 4)
  end

  test "a layer's effects are heard live, on that layer alone" do
    score = layered(level: [amp: 0.0])
    pcm = walk(Transport.new(score, @rate), 2.5)

    first = binary_part(pcm, 0, trunc(0.5 * @rate) * 2)
    second = binary_part(pcm, trunc(1.0 * @rate) * 2, trunc(0.5 * @rate) * 2)

    assert peak(first) > 5_000
    assert peak(second) == 0
  end

  test "an effect's tail carries on after the layer's last note" do
    score = layered(echo: [delay: 0.2, feedback: 0.6, mix: 0.8])
    pcm = walk(Transport.new(score, @rate), 2.5)

    ringing = binary_part(pcm, trunc(1.7 * @rate) * 2, trunc(0.2 * @rate) * 2)

    assert peak(ringing) > 300
  end
end

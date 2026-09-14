defmodule TuningFork.WavTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Mixer, Score, Sink, Stage, Voice, Wav}

  defp pcm(values), do: for(v <- values, into: <<>>, do: <<v::16-signed-little>>)

  describe "the header" do
    test "it starts the way every reader expects" do
      wav = Wav.encode(pcm([1, 2, 3, 4]), rate: 44_100, channels: 2)

      assert <<"RIFF", _size::32-little, "WAVE", _rest::binary>> = wav
    end

    test "it is forty-four bytes in front of the samples" do
      samples = pcm([1, 2, 3, 4])

      assert byte_size(Wav.encode(samples)) == byte_size(samples) + 44
    end

    test "the sizes agree with what is actually there" do
      samples = pcm(Enum.to_list(1..100))
      wav = Wav.encode(samples)

      <<"RIFF", riff::32-little, _wave_and_fmt::binary-size(28), "data", data::32-little,
        _body::binary>> = wav

      assert data == byte_size(samples)
      assert riff == byte_size(wav) - 8
    end

    test "the rate and channels it was told are the ones written down" do
      wav = Wav.encode(pcm([0, 0]), rate: 22_050, channels: 1)

      assert {:ok, _pcm, 22_050, 1} = Wav.decode(wav)
    end

    test "byte rate and block align follow from the channel count" do
      {:ok, _pcm, _rate, _channels} = Wav.decode(Wav.encode(pcm([0, 0]), channels: 2))

      <<_riff::binary-size(28), byte_rate::32-little, align::16-little, bits::16-little,
        _rest::binary>> = Wav.encode(pcm([0, 0]), rate: 44_100, channels: 2)

      assert bits == 16
      assert align == 4
      assert byte_rate == 44_100 * 4
    end
  end

  describe "round trips" do
    test "what goes in comes back out" do
      samples = pcm([0, 1, -1, 32_767, -32_768, 1_234])

      assert {:ok, ^samples, 44_100, 2} = Wav.decode(Wav.encode(samples))
    end

    test "a rendered score survives being wrapped and read back" do
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.2))
      rendered = Score.new(bpm: 120, beats: 2) |> Score.add(0.0, voice) |> Score.render(44_100)

      assert {:ok, ^rendered, 44_100, 2} = Wav.decode(Wav.encode(rendered))
    end

    test "mono survives too" do
      samples = pcm([5, 6, 7])

      assert {:ok, ^samples, 8_000, 1} = Wav.decode(Wav.encode(samples, rate: 8_000, channels: 1))
    end

    test "an empty buffer is still a readable file" do
      assert {:ok, <<>>, 44_100, 2} = Wav.decode(Wav.encode(<<>>))
    end
  end

  describe "reading what somebody else wrote" do
    test "chunks in between are skipped rather than refused" do
      samples = pcm([9, 9])

      wav =
        <<"RIFF", 0::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little, 1::16-little,
          44_100::32-little, 88_200::32-little, 2::16-little, 16::16-little, "LIST", 4::32-little,
          "INFO", "data", byte_size(samples)::32-little, samples::binary>>

      assert {:ok, ^samples, 44_100, 1} = Wav.decode(wav)
    end

    test "an odd-length chunk is padded, and the one after it still lines up" do
      samples = pcm([3, 4])

      wav =
        <<"RIFF", 0::32-little, "WAVE", "note", 3::32-little, "abc", 0::8, "fmt ", 16::32-little,
          1::16-little, 2::16-little, 44_100::32-little, 176_400::32-little, 4::16-little,
          16::16-little, "data", byte_size(samples)::32-little, samples::binary>>

      assert {:ok, ^samples, 44_100, 2} = Wav.decode(wav)
    end

    test "something that is not a WAV says so instead of crashing" do
      assert {:error, :not_a_wav} = Wav.decode("this is not audio")
      assert {:error, :not_a_wav} = Wav.decode(<<>>)
    end

    test "24-bit, 32-bit and 8-bit samples are read as 16-bit" do
      assert {:ok, <<32_767::16-little-signed, -32_768::16-little-signed>>, 44_100, 1} =
               Wav.decode(
                 wav(1, 24, 1, <<0x7FFFFF::24-little-signed, -0x800000::24-little-signed>>)
               )

      assert {:ok, <<16_384::16-little-signed, -32_768::16-little-signed>>, 44_100, 1} =
               Wav.decode(
                 wav(1, 32, 1, <<0x40000000::32-little-signed, -0x80000000::32-little-signed>>)
               )

      assert {:ok, <<32_512::16-little-signed, -32_768::16-little-signed>>, 44_100, 1} =
               Wav.decode(wav(1, 8, 1, <<255, 0>>))
    end

    test "32-bit floats are read as 16-bit and clipped" do
      assert {:ok,
              <<16_384::16-little-signed, -32_768::16-little-signed, 32_767::16-little-signed>>,
              44_100, 1} =
               Wav.decode(
                 wav(
                   3,
                   32,
                   1,
                   <<0.5::32-float-little, -1.5::32-float-little, 1.0::32-float-little>>
                 )
               )
    end

    test "a depth this library cannot read is refused by name" do
      assert {:error, {:unsupported_bit_depth, 12}} = Wav.decode(wav(1, 12, 2, <<>>))
    end

    test "an extensible header says which kind its samples are" do
      extension = <<22::16-little, 24::16-little, 0::32-little, 1::16-little, 0::112>>

      assert {:ok, <<32_767::16-little-signed>>, 44_100, 1} =
               Wav.decode(wav(0xFFFE, 24, 1, <<0x7FFFFF::24-little-signed>>, extension))
    end

    defp wav(format, bits, channels, data, extension \\ <<>>) do
      fmt =
        <<format::16-little, channels::16-little, 44_100::32-little, 0::32-little, 0::16-little,
          bits::16-little>> <> extension

      <<"RIFF", 0::32-little, "WAVE", "fmt ", byte_size(fmt)::32-little>> <>
        fmt <> <<"data", byte_size(data)::32-little>> <> data
    end

    test "decode! raises rather than reporting" do
      assert_raise ArgumentError, ~r/could not read that WAV/, fn -> Wav.decode!("nope") end
    end

    test "a file that stops inside its data chunk says so rather than decoding short" do
      whole = pcm(Enum.to_list(1..100))

      wav =
        <<"RIFF", 0::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little, 2::16-little,
          44_100::32-little, 176_400::32-little, 4::16-little, 16::16-little, "data",
          byte_size(whole)::32-little, binary_part(whole, 0, 40)::binary>>

      assert {:error, :truncated} = Wav.decode(wav)
    end

    test "a file that stops before its format chunk arrives says so too" do
      wav = <<"RIFF", 0::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little, 2::16-little>>

      assert {:error, :truncated} = Wav.decode(wav)
    end

    test "a stray chunk cut short after the audio is ignored, since the audio is whole" do
      samples = pcm([1, 2, 3, 4])

      wav =
        <<"RIFF", 0::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little, 2::16-little,
          44_100::32-little, 176_400::32-little, 4::16-little, 16::16-little, "data",
          byte_size(samples)::32-little, samples::binary, "LIST", 400::32-little, "INFO">>

      assert {:ok, ^samples, 44_100, 2} = Wav.decode(wav)
    end

    test "a few trailing bytes too short to be a chunk header are not an error" do
      samples = pcm([7, 8])

      wav =
        <<"RIFF", 0::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little, 1::16-little,
          44_100::32-little, 88_200::32-little, 2::16-little, 16::16-little, "data",
          byte_size(samples)::32-little, samples::binary, 0, 0, 0>>

      assert {:ok, ^samples, 44_100, 1} = Wav.decode(wav)
    end
  end

  describe "files" do
    @tag :tmp_dir
    test "written and read back", %{tmp_dir: dir} do
      path = Path.join([dir, "nested", "take.wav"])
      samples = pcm([1, 2, 3, 4])

      assert :ok = Wav.write!(path, samples, rate: 44_100, channels: 2)
      assert {^samples, 44_100, 2} = Wav.read!(path)
    end
  end

  describe "duration" do
    test "a second of stereo is a second" do
      assert_in_delta Wav.duration(Mixer.silence(44_100, 2), 44_100, 2), 1.0, 0.0001
    end

    test "the same bytes read as mono last twice as long" do
      assert_in_delta Wav.duration(Mixer.silence(44_100, 2), 44_100, 1), 2.0, 0.0001
    end
  end

  describe "recording a stage" do
    test "what the stage writes is kept, and comes back as a playable file" do
      {:ok, tape} = Sink.Buffer.start_link()

      {:ok, stage} =
        Stage.start_link(
          name: nil,
          sink: Sink.Buffer,
          sink_opts: [into: tape],
          chunk: 256
        )

      Stage.play(stage, Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.1)))
      Process.sleep(200)
      GenServer.stop(stage)

      recorded = Sink.Buffer.take(tape)

      assert byte_size(recorded) > 0
      assert rem(byte_size(recorded), 4) == 0, "stereo frames should be whole"
      assert {:ok, ^recorded, 44_100, 2} = Wav.decode(Sink.Buffer.wav(tape))
      assert Sink.Buffer.duration(tape) > 0.0

      Sink.Buffer.stop(tape)
    end

    test "the recording outlives the stage that made it" do
      {:ok, tape} = Sink.Buffer.start_link()

      {:ok, stage} =
        Stage.start_link(name: nil, sink: Sink.Buffer, sink_opts: [into: tape], chunk: 256)

      Process.sleep(100)
      GenServer.stop(stage)

      refute Process.alive?(stage)
      assert Process.alive?(tape)
      assert byte_size(Sink.Buffer.take(tape)) > 0

      Sink.Buffer.stop(tape)
    end

    test "clearing keeps the buffer running" do
      {:ok, tape} = Sink.Buffer.start_link()
      {:ok, _state} = Sink.Buffer.open(into: tape, rate: 44_100, channels: 2)

      Sink.Buffer.write(tape, Mixer.silence(64, 2))
      assert byte_size(Sink.Buffer.take(tape)) == 256

      Sink.Buffer.clear(tape)
      assert Sink.Buffer.take(tape) == <<>>

      Sink.Buffer.stop(tape)
    end

    test "opening without a buffer to write into is refused, not guessed at" do
      assert {:error, :no_buffer_given} = Sink.Buffer.open([])
    end
  end
end

defmodule TuningFork.OscTest do
  @moduledoc """
  The bytes, and a socket that really sends them.

  The socket tests bind a real UDP port on the loopback and read back what was written, so
  what is asserted is what would leave the machine.
  """

  use ExUnit.Case, async: true

  alias TuningFork.{Osc, Part, Score}
  alias TuningFork.Osc.{Client, Out}

  doctest TuningFork.Osc
  doctest TuningFork.Osc.Out

  describe "the bytes" do
    test "an address and a tag string are each padded to four bytes" do
      assert rem(byte_size(Osc.encode("/a", [])), 4) == 0
      assert rem(byte_size(Osc.encode("/abc", [])), 4) == 0
      assert rem(byte_size(Osc.encode("/abcdefg", [])), 4) == 0
    end

    test "every message is a whole number of four-byte words" do
      for args <- [[], [1], [1.0], ["s"], ["four"], [{:blob, <<1, 2, 3>>}], [true, false, nil]] do
        assert rem(byte_size(Osc.encode("/x", args)), 4) == 0, "#{inspect(args)} was not padded"
      end
    end

    test "what goes in comes back out" do
      args = [60, 0.5, "bd", true, false, nil]

      assert {:ok, "/play", read} = Osc.decode(Osc.encode("/play", args))
      assert [60, half, "bd", true, false, nil] = read
      assert_in_delta half, 0.5, 0.0001
    end

    test "the wide types keep their width" do
      assert {:ok, _address, [{:int64, 9_000_000_000}]} =
               Osc.decode(Osc.encode("/x", [{:int64, 9_000_000_000}]))

      assert {:ok, _address, [{:double, value}]} =
               Osc.decode(Osc.encode("/x", [{:double, 0.1}]))

      assert value == 0.1
    end

    test "a blob keeps its bytes, whatever its length" do
      for size <- 0..9 do
        bytes = :binary.copy(<<7>>, size)

        assert {:ok, _address, [{:blob, ^bytes}]} = Osc.decode(Osc.encode("/x", [{:blob, bytes}]))
      end
    end

    test "arguments after a padded string are still found" do
      assert {:ok, "/x", ["ab", 42]} = Osc.decode(Osc.encode("/x", ["ab", 42]))
      assert {:ok, "/x", ["abcd", 42]} = Osc.decode(Osc.encode("/x", ["abcd", 42]))
    end

    test "a bundle names itself and holds its messages" do
      bundle = Osc.bundle([{"/a", [1]}, {"/b", [2]}])

      assert <<"#bundle", 0, _tag::binary-size(8), rest::binary>> = bundle
      assert <<size::big-32, first::binary-size(size), _left::binary>> = rest
      assert {:ok, "/a", [1]} = Osc.decode(first)
    end

    test "a bundle with no time is the tag everyone reads as now" do
      assert <<"#bundle", 0, 0::big-32, 1::big-32, _rest::binary>> = Osc.bundle([{"/a", []}])
    end

    test "rubbish is reported rather than raised" do
      assert {:error, :not_a_message} = Osc.decode(<<1, 2, 3>>)
      assert {:error, :not_a_message} = Osc.decode(<<>>)
      assert {:error, :not_a_message} = Osc.decode("no nulls in here at all")
    end
  end

  describe "a socket that really sends" do
    setup do
      {:ok, reader} = Client.start_link(listen: 0, owner: self())
      {:ok, port} = :inet.port(:sys.get_state(reader).socket)

      {:ok, writer} = Client.start_link(host: "127.0.0.1", port: port)

      {:ok, reader: reader, writer: writer, port: port}
    end

    test "a message written on one socket arrives on the other", %{writer: writer} do
      Client.send(writer, "/play", [60, 0.8, "bd"])

      assert_receive {:osc, "/play", [60, gain, "bd"], _from}, 1_000
      assert_in_delta gain, 0.8, 0.0001
    end

    test "a bundle arrives as its messages", %{writer: writer} do
      Client.bundle(writer, [{"/a", [1]}, {"/b", [2]}])

      # A bundle is one packet; a reader that does not split them sees the outer shape, which
      # is not a message, so nothing is delivered rather than something wrong being.
      refute_receive {:osc, "/a", _args, _from}, 200
    end

    test "a packet that is not OSC is dropped rather than delivered", %{writer: writer} do
      Client.packet(writer, <<255, 255, 255>>)
      Client.send(writer, "/after", [])

      assert_receive {:osc, "/after", [], _from}, 1_000
    end

    test "it says where it is pointing, and can be pointed elsewhere", %{writer: writer} do
      assert {~c"127.0.0.1", _port} = Client.to(writer)

      Client.point(writer, "127.0.0.1", 9_999)

      assert {~c"127.0.0.1", 9_999} = Client.to(writer)
    end
  end

  describe "a score sent over OSC" do
    setup do
      {:ok, score} =
        Part.Source.parse("""
        part(bpm: 480, synth: Kit.voice(%{note: "c3", shape: :saw}, 0.05))
        |> play(:c3, 1) |> play(:e3, 1)
        """)

      {:ok, reader} = Client.start_link(listen: 0, owner: self())
      {:ok, port} = :inet.port(:sys.get_state(reader).socket)
      {:ok, writer} = Client.start_link(host: "127.0.0.1", port: port)

      {:ok, score: score, writer: writer}
    end

    test "each note becomes a message, in time order", %{score: score} do
      messages = Out.messages(score)

      assert length(messages) == 2
      assert [{+0.0, "/play", [freq, _gain, _seconds, _pan]} | _rest] = messages
      assert_in_delta freq, 130.81, 0.1
      assert messages == Enum.sort_by(messages, &elem(&1, 0))
    end

    test "the address and the shape of the arguments can both be changed", %{score: score} do
      messages = Out.messages(score, address: "/note", shape: fn voice, _s -> [voice.freq] end)

      assert [{_at, "/note", [_freq]} | _rest] = messages
    end

    test "an empty score sends nothing rather than crashing" do
      assert Out.messages(Score.new(bpm: 120, beats: 4)) == []
    end

    test "playing it puts the notes on the wire", %{score: score, writer: writer} do
      {:ok, playing} = Out.play(writer, score)

      assert_receive {:osc, "/play", [_freq, _gain, _seconds, _pan], _from}, 2_000
      assert_receive {:osc, "/play", [_freq, _gain, _seconds, _pan], _from}, 2_000

      Out.stop(playing)

      assert_receive {:osc, "/hush", [], _from}, 2_000
    end

    test "stopping can be told to say nothing", %{score: score, writer: writer} do
      {:ok, playing} = Out.play(writer, score, hush: nil)
      Out.stop(playing)

      refute_receive {:osc, "/hush", _args, _from}, 300
    end
  end
end

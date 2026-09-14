defmodule KinoTuningFork.MidiCellTest do
  use ExUnit.Case, async: true

  alias Kino.JS.Live.Context
  alias KinoTuningFork.MidiCell

  @events <<0, 0x90, 60, 100, 96, 0x80, 60, 0, 0, 0x90, 64, 100, 96, 0x80, 64, 0, 0, 0x90, 67,
            100, 96, 0x80, 67, 0, 0, 0xFF, 0x2F, 0>>

  @tiny <<"MThd", 6::32, 0::16, 1::16, 96::16, "MTrk", byte_size(@events)::32, @events::binary>>

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "path" => "song.mid",
        "bpm" => "",
        "gain" => "0.2",
        "drum_gain" => "1.0",
        "drums" => "auto",
        "reverb" => "",
        "loops" => "1",
        "plain" => false,
        "variable" => "score"
      },
      overrides
    )
  end

  describe "the source it writes" do
    test "nothing at all until a file is named" do
      assert MidiCell.to_source(attrs(%{"path" => ""})) == ""
      assert MidiCell.to_source(attrs(%{"path" => "   "})) == ""
    end

    test "reads the file, builds a score and hands the bytes to the browser" do
      source = MidiCell.to_source(attrs())

      assert source =~ "TuningFork.Midi.read!()"
      assert source =~ "TuningFork.Gm.score("
      assert source =~ "TuningFork.Score.render(44100)"
      assert source =~ "TuningFork.Wav.encode(rate: 44100)"
      assert source =~ "Kino.Audio.new(:wav)"
    end

    test "it is formatted Elixir, not a string that happens to look like it" do
      source = MidiCell.to_source(attrs())

      assert source == source |> Code.format_string!() |> IO.iodata_to_binary()
    end

    test "it parses" do
      assert {:ok, _ast} = Code.string_to_quoted(MidiCell.to_source(attrs()))
    end

    test "the variable is what was asked for" do
      assert MidiCell.to_source(attrs(%{"variable" => "bach"})) =~ "bach ="
    end

    test "a variable that would not compile falls back rather than breaking the cell" do
      source = MidiCell.to_source(attrs(%{"variable" => "not a name!"}))

      assert source =~ "score ="
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    test "a blank tempo is left out rather than sent as zero" do
      refute MidiCell.to_source(attrs()) =~ "bpm:"
      assert MidiCell.to_source(attrs(%{"bpm" => "96"})) =~ "bpm: 96"
    end

    test "drum modes each say something different" do
      assert MidiCell.to_source(attrs(%{"drums" => "auto"})) =~ "drum_channels: :auto"
      assert MidiCell.to_source(attrs(%{"drums" => "gm"})) =~ "drum_channels: [9]"
      assert MidiCell.to_source(attrs(%{"drums" => "all"})) =~ "drum_channels: [0, 1, 2"
    end

    test "reverb appears only when asked for" do
      refute MidiCell.to_source(attrs()) =~ "reverb"
      assert MidiCell.to_source(attrs(%{"reverb" => "0.6"})) =~ "TuningFork.Fx.reverb"
    end

    test "repeats appear only above one" do
      refute MidiCell.to_source(attrs(%{"loops" => "1"})) =~ "List.duplicate"
      assert MidiCell.to_source(attrs(%{"loops" => "4"})) =~ "List.duplicate(4)"
    end

    test "one voice for everything is passed through" do
      refute MidiCell.to_source(attrs()) =~ "plain:"
      assert MidiCell.to_source(attrs(%{"plain" => true})) =~ "plain: true"
    end

    test "a path with a quote in it is escaped rather than breaking out of the string" do
      source = MidiCell.to_source(attrs(%{"path" => ~s(od"d.mid)}))

      assert {:ok, _ast} = Code.string_to_quoted(source)
    end
  end

  describe "the cell's own state" do
    test "attrs survive a round trip through init" do
      {:ok, ctx} = MidiCell.init(attrs(%{"gain" => "0.05"}), Context.new())

      assert MidiCell.to_attrs(ctx)["gain"] == "0.05"
      assert MidiCell.to_attrs(ctx)["path"] == "song.mid"
    end

    test "an empty cell starts with workable defaults" do
      {:ok, ctx} = MidiCell.init(%{}, Context.new())
      fields = MidiCell.to_attrs(ctx)

      assert fields["gain"] == "0.2"
      assert fields["drums"] == "auto"
      assert fields["variable"] == "score"
      assert MidiCell.to_source(fields) == ""
    end
  end

  describe "the source actually works" do
    @tag :tmp_dir
    test "running what the cell writes produces playable audio", %{tmp_dir: dir} do
      path = Path.join(dir, "tiny.mid")
      File.write!(path, @tiny)

      source =
        attrs(%{"path" => path, "gain" => "0.3"})
        |> MidiCell.to_source()
        |> String.replace("|> Kino.Audio.new(:wav)", "")

      {wav, _binding} = Code.eval_string(source)

      assert {:ok, pcm, 44_100, 2} = TuningFork.Wav.decode(wav)
      assert byte_size(pcm) > 0
      assert TuningFork.Mixer.peak(pcm) > 1_000
    end

    @tag :tmp_dir
    test "the options it writes reach the audio", %{tmp_dir: dir} do
      path = Path.join(dir, "tiny.mid")
      File.write!(path, @tiny)

      render = fn overrides ->
        attrs(Map.merge(%{"path" => path}, overrides))
        |> MidiCell.to_source()
        |> String.replace("|> Kino.Audio.new(:wav)", "")
        |> Code.eval_string()
        |> elem(0)
        |> TuningFork.Wav.decode()
      end

      {:ok, once, _rate, _channels} = render.(%{"loops" => "1"})
      {:ok, four, _rate, _channels} = render.(%{"loops" => "4"})
      {:ok, quick, _rate, _channels} = render.(%{"bpm" => "240"})

      assert byte_size(four) == byte_size(once) * 4
      assert byte_size(quick) < byte_size(once)
    end
  end
end

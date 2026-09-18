defmodule TuningFork.SfzTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Kit, Sample, Sfz, Voice}
  alias TuningFork.Sample.Bank

  @text """
  // a piano, two ways
  #define $EXT flac
  #define $DIR Samples

  <control>
  default_path=$DIR/
  <global>
  ampeg_release=0.4 // seconds
  <group>
  lovel=1 hivel=60 group_label=soft
  <region> lokey=57 hikey=59 pitch_keycenter=58 sample=soft a#3.$EXT
  <region> key=c4 sample=soft c4.$EXT
  <group>
  lovel=61 hivel=127
  <region> lokey=57 hikey=59 pitch_keycenter=58 volume=-6 tune=-50 sample=loud a#3.$EXT
  <region> key=60 sample=loud c4.$EXT loop_mode=loop_continuous loop_start=1000 loop_end=9000
  <region> key=60 seq_position=2 sample=loud c4 again.$EXT
  #include "more.sfz"
  <group> trigger=release
  <region> key=60 sample=release c4.$EXT
  <group> locc64=64
  <region> key=60 sample=pedal c4.$EXT
  """

  @more """
  <region> lokey=62 hikey=64 pitch_keycenter=62 transpose=12 sample=..\\high\\d5.$EXT
  """

  describe "parse/2" do
    test "headers, defines, comments, opcodes with spaces in their values, and includes" do
      sfz = Sfz.parse(@text, include: fn "more.sfz" -> {:ok, @more} end)
      assert sfz.control == %{"default_path" => "Samples/"}
      assert length(sfz.regions) == 8
      [soft, c4 | _] = sfz.regions

      assert soft == %{
               "ampeg_release" => "0.4",
               "lovel" => "1",
               "hivel" => "60",
               "group_label" => "soft",
               "lokey" => "57",
               "hikey" => "59",
               "pitch_keycenter" => "58",
               "sample" => "soft a#3.flac"
             }

      assert c4["key"] == "c4" and c4["sample"] == "soft c4.flac"

      assert Enum.at(sfz.regions, 5) == %{
               "ampeg_release" => "0.4",
               "lovel" => "61",
               "hivel" => "127",
               "lokey" => "62",
               "hikey" => "64",
               "pitch_keycenter" => "62",
               "transpose" => "12",
               "sample" => "..\\high\\d5.flac"
             }

      assert List.last(sfz.regions)["locc64"] == "64"
    end

    test "an include that cannot be read is left out" do
      sfz = Sfz.parse(@text, include: fn _ -> :error end)
      assert length(sfz.regions) == 7
    end
  end

  describe "bank/2" do
    test "one velocity layer, no release or pedal regions, the recorded pitch from the key centre, tune and transpose, loops and volume carried" do
      sfz = Sfz.parse(@text, include: fn _ -> {:ok, @more} end)
      bank = Sfz.bank(sfz, base: "https://host/inst/piano.sfz")

      assert Map.keys(bank) |> Enum.sort() == [50.0, 58.5, 60.0]

      assert bank[58.5] == [
               {"https://host/inst/Samples/loud%20a%233.flac", gain: 0.5011872336272722}
             ]

      assert bank[60.0] == [
               {"https://host/inst/Samples/loud%20c4.flac", loop: {1000, 9000}},
               {"https://host/inst/Samples/loud%20c4%20again.flac", []}
             ]

      assert bank[50.0] == [{"https://host/inst/high/d5.flac", []}]

      soft = Sfz.bank(sfz, base: "/inst/piano.sfz", velocity: 40)

      assert soft == %{
               58.0 => [{"/inst/Samples/soft a#3.flac", []}],
               60.0 => [{"/inst/Samples/soft c4.flac", []}]
             }
    end

    test "a region with no key centre is at its key, or middle c" do
      bank =
        Sfz.bank(Sfz.parse("<region> lokey=40 hikey=40 sample=e2.wav\n<region> sample=any.wav"),
          base: "/x.sfz"
        )

      assert bank == %{40.0 => [{"/e2.wav", []}], 60.0 => [{"/any.wav", []}]}
    end

    test "keyswitched regions play only in the default switch" do
      text =
        "<global> sw_default=24\n<region> sw_last=24 key=60 sample=a.wav\n<region> sw_last=25 key=60 sample=b.wav\n<region> key=62 sample=c.wav"

      assert Sfz.bank(Sfz.parse(text), base: "/x.sfz") == %{
               60.0 => [{"/a.wav", []}],
               62.0 => [{"/c.wav", []}]
             }
    end
  end

  describe "the instruments an application registers" do
    setup do
      on_exit(fn -> Application.delete_env(:tuning_fork, :sfz) end)
    end

    test "the library carries none of its own" do
      assert Sfz.instruments() == %{}
      refute Sfz.instrument?("fingerbass")
    end

    test "register/2 adds one by name, with its source, licence, credit and what it is" do
      assert :ok =
               Sfz.register("fingerbass", %{
                 source: "github:freepats/electric-bass-YR/master/FingerBassYR 20190930.sfz",
                 licence: "CC0 1.0",
                 credit: "FreePats, Yamaha RBX bass",
                 what: "an electric bass, fingered"
               })

      assert Sfz.instrument?("fingerbass") and not Sfz.instrument?("piano")
      assert %{"fingerbass" => %{licence: "CC0 1.0", credit: "FreePats" <> _}} = Sfz.instruments()
    end

    test "register/1 adds many, over what the config named, and a key range is kept" do
      Application.put_env(:tuning_fork, :sfz, %{
        "a" => %{source: "a.sfz", licence: "CC0 1.0", credit: "a", what: "a"}
      })

      assert :ok =
               Sfz.register(%{
                 "b" => %{
                   source: "b.sfz",
                   licence: "CC0 1.0",
                   credit: "b",
                   what: "b",
                   keys: 24..80
                 },
                 "c" => %{source: "c.sfz", licence: "CC0 1.0", credit: "c", what: "c"}
               })

      assert Map.keys(Sfz.instruments()) == ["a", "b", "c"]
      assert Sfz.instruments()["b"].keys == 24..80
    end

    test "an instrument without its licence or credit is refused" do
      assert_raise FunctionClauseError, fn ->
        Sfz.register("nameless", %{source: "x.sfz", what: "something"})
      end
    end

    test "a github: source resolves to a raw URL, escaped; a URL stands" do
      assert Sfz.url("github:freepats/electric-bass-YR/master/FingerBassYR 20190930.sfz") ==
               "https://raw.githubusercontent.com/freepats/electric-bass-YR/master/FingerBassYR%2020190930.sfz"

      assert Sfz.url("https://a.b/c.sfz") == "https://a.b/c.sfz"
    end
  end

  describe "load/2" do
    @fixtures Path.expand("../fixtures", __DIR__)

    setup do
      Bank.clear()
      on_exit(&Bank.clear/0)
    end

    test "an instrument the application adds is one the kit knows and loads itself the first time it is played" do
      Application.put_env(:tuning_fork, :sfz, %{
        "twotone_local" => %{
          source: Path.join(@fixtures, "sfz/twotone.sfz"),
          licence: "CC0 1.0",
          credit: "the tests",
          what: "two tones"
        }
      })

      on_exit(fn -> Application.delete_env(:tuning_fork, :sfz) end)

      assert Sfz.instrument?("twotone_local") and Kit.known?("twotone_local")
      refute Bank.has?("twotone_local")

      assert %Voice{sample: %Sample{loop: {100, 2000}}} =
               Kit.voice(%{s: "twotone_local", note: 60}, 0.5)

      assert Bank.has?("twotone_local")
    end

    test "a local file registers a pitched bank the kit plays, and reads its includes beside it" do
      assert {:ok, "twotone", 2} =
               Sfz.load(Path.join(@fixtures, "sfz/twotone.sfz"), name: "twotone")

      assert Bank.notes("twotone") == [48.0, 60.0]

      assert %Voice{sample: %Sample{loop: {100, 2000}}} =
               Kit.voice(%{s: "twotone", note: 60}, 0.5)

      assert %Voice{sample: %Sample{loop: nil}} =
               Kit.voice(%{s: "twotone", note: 47}, 0.5)
    end
  end
end

defmodule TuningFork.Sample.BankTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Kit, Sample, Voice}
  alias TuningFork.Sample.Bank
  alias TuningFork.Test.FileServer

  @flac Path.expand("../../fixtures/flac/stereo_lpc.flac", __DIR__)
  @wav Path.expand("../../fixtures/flac/mono.wav", __DIR__)

  setup do
    Bank.clear()
    on_exit(&Bank.clear/0)
  end

  describe "registering" do
    test "a path is loaded on first fetch and kept" do
      :ok = Bank.put(:bell, @flac)

      assert {:ok, %Sample{name: "bell", rate: 8_000} = first} = Bank.fetch(:bell)
      assert {:ok, ^first} = Bank.fetch(:bell)
    end

    test "a sample already in memory is kept as it is" do
      sample = Sample.load!(@wav, root: :c3)
      :ok = Bank.put(:tone, sample)

      assert {:ok, ^sample} = Bank.fetch(:tone)
    end

    test "a root given at registration goes on the loaded sample" do
      :ok = Bank.put(:bell, @flac, root: :a4)

      assert {:ok, %Sample{root: root}} = Bank.fetch(:bell)
      assert_in_delta root, 440.0, 0.01
    end

    test "names are strings or atoms, and the same either way" do
      :ok = Bank.put("bell", @flac)

      assert {:ok, %Sample{}} = Bank.fetch(:bell)
      assert {:ok, %Sample{}} = Bank.fetch("bell")
      assert Bank.has?(:bell)
      assert Bank.has?("bell")
    end

    test "many at once" do
      :ok = Bank.put_all(%{bell: @flac, tone: @wav})

      assert Bank.names() == ["bell", "tone"]
    end
  end

  describe "asking for what is not there" do
    test "is :error, not a crash" do
      assert :error = Bank.fetch(:nothing)
      refute Bank.has?(:nothing)
    end

    test "a path that will not load is :error and is not retried as a success" do
      :ok = Bank.put(:broken, Path.expand("../../fixtures/flac/stereo_24.raw", __DIR__))

      assert :error = Bank.fetch(:broken)
    end
  end

  describe "through the kit" do
    test "a bank name plays as a voice carrying the sample" do
      :ok = Bank.put(:bell, @flac)

      assert %Voice{sample: %Sample{name: "bell"}} = Kit.voice("bell", 0.25)
      assert %Voice{sample: %Sample{name: "bell"}} = Kit.voice(:bell, 0.25)
      assert %Voice{sample: %Sample{name: "bell"}} = Kit.voice(%{s: "bell"}, 0.25)
    end

    test "a bank in front of a sound plays the recording registered under bank_sound" do
      assert %Voice{sample: nil} = Kit.voice(%{s: "bd", bank: "crate"}, 0.25)
      :ok = Bank.put(:crate_bd, @flac)

      assert %Voice{sample: %Sample{name: "crate_bd"}} =
               Kit.voice(%{s: "bd", bank: "crate"}, 0.25)

      assert %Voice{sample: %Sample{name: "crate_bd"}} =
               Kit.voice(%{s: "bd:1", bank: "crate"}, 0.25)

      assert %Voice{sample: nil} = Kit.voice(%{s: "bd", bank: "RolandTR808"}, 0.25)
    end

    test "a bank sample wins over a synthesised drum of the same name" do
      assert %Voice{sample: nil} = Kit.voice("bd", 0.25)
      :ok = Bank.put(:bd, @flac)

      assert %Voice{sample: %Sample{name: "bd"}} = Kit.voice("bd", 0.25)
    end

    test "a note on a plain recording plays it faster or slower, from c2" do
      :ok = Bank.put(:bell, @flac)

      plain = Kit.voice(%{s: "bell"}, 0.25)
      up = Kit.voice(%{s: "bell", note: "c3"}, 0.25)
      c3 = Kit.voice(%{s: "bell", note: 36}, 0.25)

      assert %Voice{sample: %Sample{}} = up

      assert_in_delta Sample.ratio(up.sample, up.freq, 44_100),
                      2.0 * Sample.ratio(plain.sample, plain.freq, 44_100),
                      0.001

      assert_in_delta Sample.ratio(c3.sample, c3.freq, 44_100),
                      Sample.ratio(plain.sample, plain.freq, 44_100),
                      0.001
    end

    test "a bank sample sounds for its whole length, whatever the step" do
      :ok = Bank.put(:bell, @flac)
      {:ok, sample} = Bank.fetch(:bell)

      voice = Kit.voice("bell", 0.01)

      assert_in_delta Voice.duration(voice), Sample.duration(sample), 0.01
    end

    test "controls still shape it" do
      :ok = Bank.put(:bell, @flac)

      assert %Voice{gain: 0.3, pan: -0.5} = Kit.voice(%{s: "bell", gain: 0.3, pan: -0.5}, 0.25)
    end
  end
end

defmodule TuningFork.Sample.BankListsTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Kit, Mixer, Sample, Voice}
  alias TuningFork.Sample.Bank
  alias TuningFork.Test.FileServer

  @flac Path.expand("../../fixtures/flac/stereo_lpc.flac", __DIR__)
  @wav Path.expand("../../fixtures/flac/mono.wav", __DIR__)

  setup do
    Bank.clear()
    on_exit(&Bank.clear/0)
  end

  test "a map of notes to files is a pitched instrument, played from the nearest note" do
    :ok = Bank.put(:piano, %{"C3" => @flac, "Fs3" => [@wav, @flac]})

    assert Bank.count(:piano) == 3
    assert Bank.notes(:piano) == [48, 54, 54]
    assert {0, 48} = Bank.nearest(:piano, 49, 0)
    assert {1, 54} = Bank.nearest(:piano, 60, 0)
    assert {2, 54} = Bank.nearest(:piano, 60, 1)
    assert Bank.nearest(:sd, 60, 0) == nil

    voice = Kit.voice(%{s: "piano", note: "a3"}, 0.25)
    assert %Voice{sample: %Sample{rate: 8_000}} = voice
    assert_in_delta voice.sample.root, 185.0, 0.01
    assert_in_delta voice.freq, 220.0, 0.01

    low = Kit.voice("piano", 0.25)
    assert_in_delta low.sample.root, 130.81, 0.01
    assert_in_delta low.freq, 65.41, 0.01
  end

  test "notes may be MIDI numbers, fractional for a recording between two, and a file may carry its own loop and gain" do
    :ok =
      Bank.put(:cello, %{
        48 => {@wav, loop: {10, 200}, gain: 0.5},
        60.5 => [@flac, {@flac, gain: 2.0}]
      })

    assert Bank.notes(:cello) == [48, 60.5, 60.5]
    assert {0, 48} = Bank.nearest(:cello, 50, 0)
    assert {2, 60.5} = Bank.nearest(:cello, 61, 1)
    assert {:ok, %Sample{loop: {10, 200}} = halved} = Bank.fetch(:cello, 0)
    assert {:ok, %Sample{loop: nil} = plain} = Bank.fetch(:cello, 1)
    assert {:ok, %Sample{} = doubled} = Bank.fetch(:cello, 2)
    assert Mixer.peak(Sample.load!(@wav).pcm) == Mixer.peak(halved.pcm) * 2
    assert Mixer.peak(doubled.pcm) == min(32_767, Mixer.peak(plain.pcm) * 2)
  end

  test "a name may hold several files, picked by index and wrapping" do
    :ok = Bank.put(:sd, [@flac, @wav])

    assert {:ok, %Sample{name: "sd"}} = Bank.fetch(:sd)
    assert {:ok, %Sample{rate: 8_000} = first} = Bank.fetch(:sd, 0)
    assert {:ok, %Sample{rate: 8_000} = second} = Bank.fetch(:sd, 1)
    refute first.pcm == second.pcm
    assert {:ok, ^first} = Bank.fetch(:sd, 2)
    assert Bank.count(:sd) == 2
  end

  test "registering the same files again keeps what is already loaded" do
    :ok = Bank.put(:sd, [@flac, @wav])
    {:ok, first} = Bank.fetch(:sd, 1)

    :ok = Bank.put(:sd, [@flac, @wav])
    assert {:ok, ^first} = Bank.fetch(:sd, 1)

    :ok = Bank.put(:sd, [@wav])
    assert Bank.count(:sd) == 1
  end

  test "n on a recording picks which file, not a pitch, unless a scale is named" do
    :ok = Bank.put(:sd, [@flac, @wav])
    {:ok, second} = Bank.fetch(:sd, 1)

    chosen = Kit.voice(%{degree: 1, sound: "sd"}, 0.25)
    assert chosen.sample.id == second.id
    plain = Kit.voice("sd:1", 0.25)

    assert_in_delta Sample.ratio(chosen.sample, chosen.freq, 44_100),
                    Sample.ratio(plain.sample, plain.freq, 44_100),
                    0.0001

    scaled = Kit.voice(%{degree: 1, scale: "c:major", sound: "sd"}, 0.25)

    assert Sample.ratio(scaled.sample, scaled.freq, 44_100) >
             1.5 * Sample.ratio(plain.sample, plain.freq, 44_100)

    assert Kit.voice(%{degree: 3, sound: "bd"}, 0.25) == Kit.voice("bd:3", 0.25)
  end

  test "the kit reads the index after a colon as which file" do
    :ok = Bank.put(:sd, [@flac, @wav])
    {:ok, first} = Bank.fetch(:sd, 0)
    {:ok, second} = Bank.fetch(:sd, 1)

    assert Kit.voice("sd", 0.25).sample.id == first.id
    assert Kit.voice("sd:1", 0.25).sample.id == second.id
    assert Kit.voice("sd:2", 0.25).sample.id == first.id
  end

  test "an index on a single recording is the same recording, at its own pitch" do
    :ok = Bank.put(:bell, @flac)
    {:ok, bell} = Bank.fetch(:bell)

    plain = Kit.voice("bell", 0.25)
    shifted = Kit.voice("bell:3", 0.25)

    assert plain.sample.id == bell.id
    assert shifted.sample.id == bell.id
    assert plain.freq == shifted.freq
  end

  @tag :tmp_dir
  test "a file that is a URL is fetched once into the cache directory", %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)

    {:ok, server} = FileServer.start(@wav)
    url = "http://127.0.0.1:#{server.port}/mono.wav"

    :ok = Bank.put(:remote, url)
    assert {:ok, %Sample{rate: 8_000}} = Bank.fetch(:remote)
    assert [_one] = Path.wildcard(Path.join(dir, "tuning_fork/samples/*"))
    assert FileServer.hits(server) == 1

    Bank.clear()
    :ok = Bank.put(:remote, url)
    assert {:ok, %Sample{}} = Bank.fetch(:remote)
    assert FileServer.hits(server) == 1
  end

  @tag :tmp_dir
  test "the kit prefetches the recordings a list of values will need", %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    {:ok, server} = FileServer.start(@wav)
    url = "http://127.0.0.1:#{server.port}/mono.wav"
    :ok = Bank.put(:remote, [url, url <> "?2"])
    :ok = Bank.put(:other, [url <> "?3"])

    :ok = Kit.prefetch([%{sound: "remote:1", gain: 0.5}, "remote", %{note: 60}, %{s: "nothing"}])
    assert settled(fn -> FileServer.hits(server) == 2 end)
    Process.sleep(50)
    assert FileServer.hits(server) == 2
  end

  defp settled(check, tries \\ 100)
  defp settled(_check, 0), do: false

  defp settled(check, tries) do
    if check.() do
      true
    else
      Process.sleep(20)
      settled(check, tries - 1)
    end
  end

  @tag :tmp_dir
  test "asked not to wait, a file still on the web is :loading and comes later", %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    {:ok, server} = FileServer.start(@wav)
    url = "http://127.0.0.1:#{server.port}/mono.wav"
    :ok = Bank.put(:remote, url)
    :ok = Bank.put(:local, @wav)

    assert :loading = Bank.fetch(:remote, 0, wait: false)
    assert {:ok, %Sample{}} = Bank.fetch(:local, 0, wait: false)
    assert nil == Kit.voice("remote", 0.25, wait: false)
    assert %TuningFork.Voice{} = Kit.voice("local", 0.25, wait: false)

    assert {:ok, %Sample{}} = Bank.fetch(:remote)
    assert {:ok, %Sample{}} = Bank.fetch(:remote, 0, wait: false)
    assert %TuningFork.Voice{} = Kit.voice("remote", 0.25, wait: false)
    assert FileServer.hits(server) == 1
  end
end

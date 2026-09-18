defmodule TuningFork.Sample.FontTest do
  use ExUnit.Case, async: false

  alias TuningFork.Sample
  alias TuningFork.Sample.{Decode, Font}
  alias TuningFork.Test.FileServer

  @mp3 Path.expand("../../fixtures/flac/mono.mp3", __DIR__)

  setup %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    Font.clear()
    on_exit(&Font.clear/0)
    :ok
  end

  defp pcm_zone(low, high, pitch_cents, loop_from, loop_to) do
    pcm = for i <- 0..199, into: <<>>, do: <<rem(i, 100) * 300::16-signed-little>>

    """
    {
      midi:0
      ,originalPitch:#{pitch_cents}
      ,keyRangeLow:#{low}
      ,keyRangeHigh:#{high}
      ,loopStart:#{loop_from}
      ,loopEnd:#{loop_to}
      ,coarseTune:0
      ,fineTune:0
      ,sampleRate:8000
      ,ahdsr:true
      ,sample:'#{Base.encode64(pcm)}'
    }
    """
  end

  defp js(zones) do
    "console.log('load _tone_test');\nvar _tone_test={\n\tzones:[\n" <>
      Enum.join(zones, ",") <> "]\n}\n"
  end

  @tag :tmp_dir
  test "the zones of a font file are read, and a note picks the one covering it" do
    {:ok, zones} = Font.parse(js([pcm_zone(0, 59, 6000, 50, 100), pcm_zone(60, 127, 7200, 0, 0)]))

    assert length(zones) == 2
    assert %{low: 0, high: 59, loop: {50, 100}, rate: 8_000} = hd(zones)
    assert_in_delta hd(zones).root, 261.63, 0.01
    assert %{low: 60, loop: nil} = Font.zone_for(zones, 64)
    assert %{low: 0} = Font.zone_for(zones, 60)
    assert Font.zone_for(zones, 200) == nil
  end

  @tag :tmp_dir
  test "clearing waits for a load in flight, so nothing lands after it", %{tmp_dir: dir} do
    path = Path.join(dir, "slow.js")
    File.write!(path, js([pcm_zone(0, 127, 6000, 50, 100)]))
    {:ok, server} = FileServer.start(path)
    Font.source("http://127.0.0.1:#{server.port}")

    Font.prefetch("slow")
    Font.clear()

    refute Font.loaded?("slow")
    Process.sleep(50)
    refute Font.loaded?("slow")
  end

  @tag :tmp_dir
  test "a font on the web is fetched and its zones become samples with root and loop", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "font.js")
    File.write!(path, js([pcm_zone(0, 127, 6000, 50, 100)]))
    {:ok, server} = FileServer.start(path)
    Font.source("http://127.0.0.1:#{server.port}")

    assert :loading = Font.sample("font", 60, wait: false)
    assert {:ok, %Sample{loop: {50, 100}, rate: 8_000} = sample} = Font.sample("font", 60)
    assert_in_delta sample.root, 261.63, 0.01
    assert {:ok, ^sample} = Font.sample("font", 60, wait: false)
    assert :error = Font.sample("font", 200)
    assert FileServer.hits(server) == 1
  end

  @tag :tmp_dir
  test "a zone carrying an mp3 is decoded through the converter" do
    if Decode.converter() do
      zone = """
      {
        midi:0
        ,originalPitch:6900
        ,keyRangeLow:0
        ,keyRangeHigh:127
        ,loopStart:0
        ,loopEnd:0
        ,coarseTune:0
        ,fineTune:0
        ,sampleRate:8000
        ,ahdsr:true
        ,file:'#{Base.encode64(File.read!(@mp3))}'
      }
      """

      {:ok, [zone]} = Font.parse(js([zone]))
      assert {:ok, %Sample{rate: 8_000} = sample} = Font.decode(zone, "test", 0)
      assert TuningFork.Mixer.peak(sample.pcm) > 1_000
      assert_in_delta sample.root, 440.0, 0.01
    end
  end
end

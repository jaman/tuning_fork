defmodule TuningFork.SamplesTest do
  use ExUnit.Case, async: false

  alias TuningFork.{Sample, Samples}
  alias TuningFork.Sample.Bank
  alias TuningFork.Test.FileServer

  @flac Path.expand("fixtures/elec_blip.flac", __DIR__)

  setup_all do
    {:ok, server} = FileServer.start(@flac)
    Samples.source("http://127.0.0.1:#{server.port}")
    :ok
  end

  setup %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    :ok
  end

  @tag :tmp_dir
  test "names are grouped by their prefix" do
    families = Samples.families()

    assert "bd_haus" in families["bd"]
    assert "perc_bell" in families["perc"]
    assert "loop_amen" in families["loop"]
  end

  @tag :tmp_dir
  test "a url for a name, and nil for a name it does not have" do
    assert Samples.url(:perc_bell) |> String.ends_with?("/perc_bell.flac")
    assert Samples.url(:nothing) == nil
  end

  @tag :tmp_dir
  test "loading a name fetches the recording, folded to mono, and keeps it" do
    assert %Sample{rate: 44_100, name: "elec_blip"} = sample = Samples.load!(:elec_blip)
    assert Sample.frames(sample) > 1_000
    assert {:ok, ^sample} = Bank.fetch(:elec_blip)
  end
end

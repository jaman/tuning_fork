defmodule TuningFork.CacheTest do
  use ExUnit.Case, async: false

  alias TuningFork.Cache

  setup do
    dir =
      Path.join(System.tmp_dir!(), "tuning_fork_cache_test_#{System.unique_integer([:positive])}")

    previous = System.get_env("XDG_STATE_HOME")
    System.put_env("XDG_STATE_HOME", dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: System.put_env("XDG_STATE_HOME", previous),
        else: System.delete_env("XDG_STATE_HOME")
    end)

    %{dir: dir}
  end

  test "the first call renders and the second reads what was kept" do
    pcm = <<1, 0, 2, 0, 3, 0>>

    assert Cache.fetch("test/one", "abc", fn -> pcm end) == pcm
    assert Cache.fetch("test/one", "abc", fn -> flunk("should not render twice") end) == pcm
  end

  test "a different fingerprint is rendered afresh, and the old one is not kept on disk" do
    assert Cache.fetch("test/two", "v1", fn -> <<1, 0>> end) == <<1, 0>>
    assert Cache.fetch("test/two", "v2", fn -> <<2, 0>> end) == <<2, 0>>
    refute File.exists?(Cache.path("test/two", "v1"))
    assert Cache.fetch("test/two", "v1", fn -> <<3, 0>> end) == <<3, 0>>
  end

  test "a module's fingerprint changes with the module and not between calls" do
    assert Cache.fingerprint(TuningFork.Voice) == Cache.fingerprint(TuningFork.Voice)
    refute Cache.fingerprint(TuningFork.Voice) == Cache.fingerprint(TuningFork.Mixer)
  end

  test "clearing means the next call renders again" do
    Cache.fetch("test/three", "abc", fn -> <<9, 0>> end)
    Cache.clear()

    assert Cache.fetch("test/three", "abc", fn -> <<8, 0>> end) == <<8, 0>>
  end

  test "a directory that cannot be written still gives back the audio" do
    System.put_env("XDG_STATE_HOME", "/proc/nonexistent-and-unwritable")

    assert Cache.fetch("test/four", "abc", fn -> <<7, 0>> end) == <<7, 0>>
  end

  test "a relative XDG_STATE_HOME is ignored rather than resolved" do
    System.put_env("XDG_STATE_HOME", "relative/path")

    assert Path.type(Cache.dir()) == :absolute
  end
end

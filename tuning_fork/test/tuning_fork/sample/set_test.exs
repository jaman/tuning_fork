defmodule TuningFork.Sample.SetTest do
  use ExUnit.Case, async: false

  alias TuningFork.Sample.{Bank, Set}
  alias TuningFork.Test.FileServer

  @wav Path.expand("../../fixtures/flac/mono.wav", __DIR__)

  setup do
    Bank.clear()
    on_exit(&Bank.clear/0)
  end

  test "a map registers every name, files under the base" do
    assert {:ok, ["kick", "snare"]} =
             Set.load(%{
               "_base" => Path.dirname(@wav) <> "/",
               "kick" => ["mono.wav", "mono.wav"],
               "snare" => "mono.wav"
             })

    assert Bank.count("kick") == 2
    assert {:ok, %TuningFork.Sample{}} = Bank.fetch("snare")
  end

  test "a map of notes under a name is a pitched instrument" do
    base = Path.dirname(@wav) <> "/"

    assert {:ok, ["piano"]} =
             Set.load(%{"_base" => base, "piano" => %{"C3" => "mono.wav", "A3" => ["mono.wav"]}})

    assert Bank.notes("piano") == [48, 57]
    assert {1, 57} = Bank.nearest("piano", 60, 0)
  end

  @tag :tmp_dir
  test "a set may be registered without fetching anything, and only some of its names", %{
    tmp_dir: dir
  } do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    {:ok, server} = FileServer.start(@wav)
    base = "http://127.0.0.1:#{server.port}/"
    map = %{"_base" => base, "bd" => ["bd.wav"], "sd" => ["sd.wav"], "hh" => ["hh.wav"]}

    assert {:ok, ["bd", "hh"]} = Set.load(map, prefetch: false, only: ["bd", "hh"])
    Process.sleep(100)
    assert FileServer.hits(server) == 0
    assert Bank.has?("bd")
    refute Bank.has?("sd")
  end

  test "an alias map gives a machine's sounds a second name" do
    base = Path.dirname(@wav) <> "/"

    {:ok, _} =
      Set.load(%{
        "_base" => base,
        "RolandTR808_bd" => ["mono.wav"],
        "RolandTR808_sd" => ["mono.wav"]
      })

    assert :ok = Set.aliases(%{"RolandTR808" => "tr808", "Nothing" => "no"})
    assert Bank.has?("tr808_bd")
    assert Bank.has?("tr808_sd")
    assert {:ok, %TuningFork.Sample{}} = Bank.fetch("tr808_sd")
  end

  test "several sets load one after another in the background, with their aliases" do
    base = Path.dirname(@wav) <> "/"
    dir = System.tmp_dir!()
    aliases = Path.join(dir, "tuning_fork_alias_#{System.unique_integer([:positive])}.json")
    File.write!(aliases, JSON.encode!(%{"RolandTR808" => "tr808"}))
    parent = self()

    :ok =
      Set.background(
        [
          {%{"_base" => base, "bd" => ["mono.wav"]}, []},
          {%{"_base" => base, "RolandTR808_sd" => ["mono.wav"]}, [alias: aliases]}
        ],
        fn -> send(parent, :loaded) end
      )

    assert_receive :loaded, 2_000
    assert Bank.has?("bd")
    assert Bank.has?("tr808_sd")
  end

  test "a strudel.json on disk" do
    path =
      Path.join(System.tmp_dir!(), "tuning_fork_set_#{System.unique_integer([:positive])}.json")

    File.write!(path, JSON.encode!(%{"kick" => Path.basename(@wav)}))
    File.cp!(@wav, Path.join(Path.dirname(path), Path.basename(@wav)))

    assert {:ok, ["kick"]} = Set.load(path)
    assert {:ok, %TuningFork.Sample{}} = Bank.fetch("kick")
  end

  @tag :tmp_dir
  test "a set on the web is read and its files fetched on first use", %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    {:ok, server} = FileServer.start(@wav)
    map = %{"_base" => "http://127.0.0.1:#{server.port}/", "crate_bd" => ["bd.wav"]}
    path = Path.join(dir, "strudel.json")
    File.write!(path, JSON.encode!(map))

    assert {:ok, ["crate_bd"]} = Set.load(path)
    assert {:ok, %TuningFork.Sample{}} = Bank.fetch("crate_bd")
    assert FileServer.hits(server) == 1
  end

  @tag :tmp_dir
  test "loading a set starts fetching its files behind the caller", %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    {:ok, server} = FileServer.start(@wav)
    base = "http://127.0.0.1:#{server.port}/"
    map = %{"_base" => base, "crate_bd" => ["bd.wav"], "crate_sd" => ["sd.wav", "sd2.wav"]}

    assert {:ok, ["crate_bd", "crate_sd"]} = Set.load(map)
    assert settled(fn -> FileServer.hits(server) == 3 end)
    assert {:ok, ["crate_bd", "crate_sd"]} = Set.load(map)
    Process.sleep(50)
    assert FileServer.hits(server) == 3
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
  test "a strudel.json on the web is fetched once and kept", %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    json = Path.join(dir, "strudel.json")
    File.write!(json, JSON.encode!(%{"crate_bd" => [Path.basename(@wav)]}))
    {:ok, server} = FileServer.start(json)
    url = "http://127.0.0.1:#{server.port}/strudel.json"

    assert {:ok, ["crate_bd"]} = Set.load(url)
    assert {:ok, ["crate_bd"]} = Set.load(url)
    assert FileServer.hits(server) == 1
  end
end

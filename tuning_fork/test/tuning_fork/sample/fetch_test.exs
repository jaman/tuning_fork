defmodule TuningFork.Sample.FetchTest do
  use ExUnit.Case, async: false

  alias TuningFork.Sample.Fetch
  alias TuningFork.Test.FileServer

  @wav Path.expand("../../fixtures/flac/mono.wav", __DIR__)

  setup %{tmp_dir: dir} do
    System.put_env("XDG_CACHE_HOME", dir)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    {:ok, server} = FileServer.start(@wav)
    %{server: server, url: "http://127.0.0.1:#{server.port}/mono.wav"}
  end

  @tag :tmp_dir
  test "prefetch returns at once and the file arrives behind it", %{server: server, url: url} do
    refute Fetch.cached?(url)

    assert :ok = Fetch.prefetch([url])
    assert :ok = Fetch.prefetch([url])
    assert settled(fn -> Fetch.cached?(url) end)
    assert FileServer.hits(server) == 1
  end

  @tag :tmp_dir
  test "a fetch already in flight is not started again", %{server: server, url: url} do
    Fetch.prefetch([url, url])
    assert {:ok, _path} = Fetch.fetch(url)
    assert settled(fn -> Fetch.cached?(url) end)
    assert FileServer.hits(server) <= 2
  end

  @tag :tmp_dir
  test "a file name with a space in it is fetched", %{server: server} do
    url = "http://127.0.0.1:#{server.port}/Hat Open.wav"

    assert {:ok, path} = Fetch.fetch(url)
    assert File.exists?(path)
    assert Path.extname(path) == ".wav"
    assert FileServer.last_path(server) == "/Hat%20Open.wav"
  end

  @tag :tmp_dir
  test "a name already escaped is asked for as it is, so a sharp or a space in it survives", %{
    server: server
  } do
    assert {:ok, _path} = Fetch.fetch("http://127.0.0.1:#{server.port}/finger/F%23%20low.wav")
    assert FileServer.last_path(server) == "/finger/F%23%20low.wav"
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
end

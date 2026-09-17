defmodule TuningFork.Sample.Fetch do
  @moduledoc """
  Downloads a file once into the cache directory and gives its local path.

      {:ok, path} = TuningFork.Sample.Fetch.fetch("https://example.org/kick.wav")
      :ok = TuningFork.Sample.Fetch.prefetch(urls)
  """

  @registry TuningFork.Sample.Fetch.Registry
  @supervisor TuningFork.Sample.Fetch.Supervisor

  @doc false
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {Task.Supervisor, name: @supervisor}
    ]
  end

  @doc """
  The local path of `url`, fetched if it is not in the cache yet. A fetch of the same URL
  already under way is waited for rather than repeated.

  The cache is `$XDG_CACHE_HOME/tuning_fork/samples`, or `~/.cache/tuning_fork/samples`.
  `{:error, reason}` when the fetch fails or the cache cannot be written.
  """
  @spec fetch(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def fetch(url) when is_binary(url) do
    with :missing <- cached(url),
         :done <- url |> start() |> await(),
         :missing <- cached(url) do
      download(url)
    end
  end

  @doc "Whether `url` is already in the cache."
  @spec cached?(String.t()) :: boolean()
  def cached?(url) when is_binary(url), do: cached(url) != :missing

  @doc """
  Start fetching every URL not yet in the cache, one after another in the background, and
  return at once. A list already being walked is not walked again.
  """
  @spec prefetch([String.t()]) :: :ok
  def prefetch(urls) when is_list(urls) do
    Task.Supervisor.start_child(@supervisor, fn -> walk({:walk, :erlang.phash2(urls)}, urls) end)
    :ok
  end

  defp walk(key, urls) do
    case Registry.register(@registry, key, nil) do
      {:ok, _owner} -> for url <- urls, cached(url) == :missing, do: url |> start() |> await()
      {:error, _taken} -> :ok
    end
  end

  @doc """
  Run `fun` in a task registered under `key`, or wait for the one already running under
  that key, and return when it is done.
  """
  @spec once(term(), (-> term())) :: :done
  def once(key, fun) when is_function(fun, 0), do: key |> start(fun) |> await()

  @doc "Start `fun` under `key` in the background unless one is already running; return at once."
  @spec background(term(), (-> term())) :: :ok
  def background(key, fun) when is_function(fun, 0) do
    start(key, fun)
    :ok
  end

  @doc "Fetch the body of `url`. Spaces and other characters a URL cannot carry are percent-encoded; what is already percent-encoded is left as it is."
  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(url) when is_binary(url) do
    :inets.start()
    :ssl.start()

    request =
      {url |> URI.encode(&(URI.char_unescaped?(&1) or &1 == ?%)) |> String.to_charlist(),
       [{~c"user-agent", ~c"tuning_fork"}]}

    options = [
      ssl: [verify: :verify_none],
      timeout: 60_000,
      connect_timeout: 15_000,
      autoredirect: true
    ]

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_version, status, reason}, _headers, _body}} ->
        {:error, {status, to_string(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Where fetched files are kept."
  @spec dir() :: Path.t()
  def dir do
    base =
      case System.get_env("XDG_CACHE_HOME") do
        dir when is_binary(dir) and dir != "" -> dir
        _unset -> Path.join(System.user_home() || System.tmp_dir!(), ".cache")
      end

    Path.join([base, "tuning_fork", "samples"])
  end

  defp cached(url) do
    path = Path.join(dir(), name(url))

    if File.exists?(path), do: {:ok, path}, else: :missing
  end

  defp download(url) do
    path = Path.join(dir(), name(url))

    with {:ok, body} <- get(url),
         :ok <- File.mkdir_p(dir()),
         :ok <- File.write(path, body) do
      {:ok, path}
    end
  end

  defp start(url), do: start(url, fn -> download(url) end)

  defp start(key, fun) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] ->
        pid

      [] ->
        {:ok, pid} = Task.Supervisor.start_child(@supervisor, fn -> registered(key, fun) end)
        pid
    end
  end

  defp registered(key, fun) do
    case Registry.register(@registry, key, nil) do
      {:ok, _owner} -> fun.()
      {:error, {:already_registered, owner}} -> await(owner)
    end
  end

  defp await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :done
    end
  end

  defp name(url) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 24)
    hash <> Path.extname(URI.parse(url).path || "")
  end
end

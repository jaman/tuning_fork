defmodule TuningFork.Sample.Set do
  @moduledoc """
  A set of named recordings described by a `strudel.json`, registered with
  `TuningFork.Sample.Bank`.

      TuningFork.Sample.Set.load("github:eddyflux/crate")
  """

  alias TuningFork.Sample.{Bank, Fetch}

  @doc """
  Register every name in a sample set.

  `source` is `"github:user/repo"` (branch `main`) or `"github:user/repo/branch"`, the URL or
  local path of a `strudel.json`, or the decoded map itself. In the map, `"_base"` is put in
  front of every relative file, and each other key is a name holding one file or a list of
  them. Files are fetched on first use.

  ## Options

    * `:prefetch` — start fetching every file in the background, default `true`
    * `:only` — register only these names, default all of them

  Returns `{:ok, names}` or `{:error, reason}`.
  """
  @spec load(String.t() | map(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def load(source, opts \\ [])

  def load("github:" <> rest, opts) do
    {repo, branch} =
      case String.split(rest, "/") do
        [user, repo] -> {"#{user}/#{repo}", "main"}
        [user, repo, branch | _deeper] -> {"#{user}/#{repo}", branch}
        _short -> {rest, "main"}
      end

    load("https://raw.githubusercontent.com/#{repo}/#{branch}/strudel.json", opts)
  end

  def load("http" <> _ = url, opts) do
    with {:ok, path} <- Fetch.fetch(url),
         {:ok, body} <- File.read(path),
         {:ok, map} <- decode(body) do
      load(Map.put_new(map, "_base", base_of(url)), opts)
    end
  end

  def load(%{} = map, opts) do
    base = Map.get(map, "_base", "")
    only = Keyword.get(opts, :only)

    registered =
      for {name, files} <- map,
          not String.starts_with?(name, "_"),
          only == nil or name in only,
          entry = entry(files, base),
          entry != [] and entry != %{} do
        Bank.put(name, entry)
        {name, entry}
      end

    if Keyword.get(opts, :prefetch, true) do
      registered
      |> Enum.flat_map(fn
        {_name, %{} = by_note} -> by_note |> Map.values() |> List.flatten()
        {_name, files} -> files
      end)
      |> Enum.filter(&String.starts_with?(&1, "http"))
      |> Fetch.prefetch()
    end

    {:ok, registered |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
  end

  def load(path, opts) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, map} <- decode(body) do
      load(Map.put_new(map, "_base", Path.dirname(Path.expand(path)) <> "/"), opts)
    end
  end

  @doc """
  Load several sets one after another in the background and return at once, calling `done`
  when every one has been tried. Each is `{source, opts}` as `load/2` takes them, plus
  `:alias`: the URL or path of an alias map to apply with `aliases/1` after that set. No file
  is prefetched. A list already being loaded is not started again.
  """
  @spec background([{String.t() | map(), keyword()}], (-> term())) :: :ok
  def background(sets, done \\ fn -> :ok end) when is_list(sets) do
    Fetch.background({:sets, :erlang.phash2(sets)}, fn ->
      Enum.each(sets, &load_set/1)
      done.()
    end)
  end

  defp load_set({source, opts}) do
    {aliases, opts} = Keyword.pop(opts, :alias)

    with {:ok, _names} <- load(source, Keyword.put(opts, :prefetch, false)),
         source when is_binary(source) <- aliases,
         {:ok, map} <- read_map(source) do
      aliases(map)
    end
  end

  defp read_map("http" <> _ = url) do
    with {:ok, path} <- Fetch.fetch(url), {:ok, body} <- File.read(path), do: decode(body)
  end

  defp read_map(path), do: with({:ok, body} <- File.read(path), do: decode(body))

  @doc """
  Give every registered `Machine_sound` a second name `alias_sound`, from a map of machine
  names to aliases as Strudel's `tidal-drum-machines-alias.json` has it.
  """
  @spec aliases(%{String.t() => String.t()}) :: :ok
  def aliases(%{} = aliases) do
    names = Bank.names()

    for {machine, short} <- aliases,
        name <- names,
        String.starts_with?(name, machine <> "_") do
      Bank.copy(name, short <> String.replace_prefix(name, machine, ""))
    end

    :ok
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, :not_a_sample_set}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry(%{} = by_note, base) do
    for {note, files} <- by_note, located = located(files, base), located != [], into: %{} do
      {note, located}
    end
  end

  defp entry(files, base), do: located(files, base)

  defp located(files, base) when is_list(files), do: Enum.flat_map(files, &located(&1, base))
  defp located(file, base) when is_binary(file), do: [absolute(file, base)]
  defp located(_other, _base), do: []

  defp absolute("http" <> _ = url, _base), do: url
  defp absolute(file, base), do: base <> file

  defp base_of(url),
    do: url |> String.split("/") |> Enum.drop(-1) |> Enum.join("/") |> Kernel.<>("/")
end

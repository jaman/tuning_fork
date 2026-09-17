defmodule TuningFork.Sample.Bank do
  @moduledoc """
  Recordings by name, for `TuningFork.Kit` to find.

      TuningFork.Sample.Bank.put(:bell, "sounds/bell.flac", root: :a4)
      TuningFork.Sample.Bank.put(:sd, ["sd/one.wav", "sd/two.wav"])
      Kit.voice("sd:1", 0.25)
  """

  use GenServer

  alias TuningFork.Sample
  alias TuningFork.Sample.Fetch

  @table :tuning_fork_sample_bank

  @type name :: atom() | String.t()
  @type file :: Path.t() | Sample.t() | {Path.t(), keyword()}

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Register `name` as one file, a list of files, a map of note names to files, or a sample
  already loaded.

  A file is a path or an `http(s)://` URL, which is fetched into the cache on first use, or
  `{path, opts}` with options of its own for `TuningFork.Sample.load!/2` (`:loop`,
  `:gain`, `:root`). A
  list is read by index with `fetch/2`, wrapping. A map (`%{"C3" => "c3.wav", "Fs3" => [...]}`)
  is a pitched instrument: `nearest/3` picks the file for a note, and each note may hold a
  list; a note is a name or a MIDI number, fractional when the recording lies between two.
  Registering a name again with the same files and options keeps what has been
  loaded; different files start it afresh.

  ## Options, for files

    * `:root` — the pitch the recording is, as `TuningFork.Sample.load!/2` takes it
  """
  @spec put(name(), file() | [file()] | %{String.t() => file() | [file()]}, keyword()) :: :ok
  def put(name, files, opts \\ [])

  def put(name, %{} = by_note, opts) when not is_struct(by_note) do
    keyed =
      by_note
      |> Enum.reject(fn {note, _files} -> is_binary(note) and String.starts_with?(note, "_") end)
      |> Enum.flat_map(fn {note, files} -> Enum.map(List.wrap(files), &{midi(note), &1}) end)
      |> Enum.sort_by(&elem(&1, 0))

    register(name, Enum.map(keyed, &elem(&1, 1)), Enum.map(keyed, &elem(&1, 0)), opts)
  end

  def put(name, files, opts), do: register(name, List.wrap(files), nil, opts)

  defp register(name, files, notes, opts) do
    entry = %{
      files: files,
      notes: notes,
      loaded: %{},
      opts: Keyword.put_new(opts, :name, key(name))
    }

    case :ets.lookup(@table, key(name)) do
      [{_key, %{files: files, notes: notes, opts: opts} = same}]
      when files == entry.files and notes == entry.notes and opts == entry.opts ->
        :ets.insert(@table, {key(name), same})

      _other ->
        :ets.insert(@table, {key(name), entry})
    end

    :ok
  end

  @doc "Register `to` with the same files as `from`; nothing happens when `from` is not registered."
  @spec copy(name(), name()) :: :ok
  def copy(from, to) do
    case :ets.lookup(@table, key(from)) do
      [{_key, entry}] ->
        :ets.insert(@table, {key(to), %{entry | opts: Keyword.put(entry.opts, :name, key(to))}})

      [] ->
        :ok
    end

    :ok
  end

  @doc "Register every entry of a map or keyword of names to files."
  @spec put_all(Enumerable.t()) :: :ok
  def put_all(entries) do
    Enum.each(entries, fn {name, files} -> put(name, files) end)
  end

  @doc """
  The sample registered as `name`, read from disk or fetched if it has not been yet.

  `index` picks one of several files, wrapping round; default the first. `:error` for a name
  nobody registered, and for a file that will not read.

  ## Options

    * `:wait` — whether to wait for a file still to be fetched from the web, default `true`.
      With `false` the fetch is started in the background and the answer is `:loading`
      until it is there; a file on disk is read either way
  """
  @spec fetch(name(), integer(), keyword()) :: {:ok, Sample.t()} | :loading | :error
  def fetch(name, index \\ 0, opts \\ []) do
    case :ets.lookup(@table, key(name)) do
      [{key, %{files: files} = entry}] when files != [] ->
        at = Integer.mod(index, length(files))

        case Map.fetch(entry.loaded, at) do
          {:ok, sample} -> {:ok, sample}
          :error -> load(key, entry, at, Keyword.get(opts, :wait, true))
        end

      _none ->
        :error
    end
  end

  @doc """
  The MIDI note each file of a pitched `name` was recorded at, in file order; `nil` for a
  name that is not pitched or not registered.
  """
  @spec notes(name()) :: [number()] | nil
  def notes(name) do
    case :ets.lookup(@table, key(name)) do
      [{_key, %{notes: notes}}] -> notes
      [] -> nil
    end
  end

  @doc """
  Which file of a pitched `name` plays `midi`, as `{index, note}`: the file recorded nearest
  the note, and the note it was recorded at; `n` picks among files sharing that note,
  wrapping. `nil` for a name that is not pitched.
  """
  @spec nearest(name(), number(), integer()) :: {non_neg_integer(), number()} | nil
  def nearest(name, midi, n) do
    case notes(name) do
      notes when is_list(notes) and notes != [] ->
        note = Enum.min_by(notes, &abs(&1 - midi))
        indexes = for {at, index} <- Enum.with_index(notes), at == note, do: index

        {Enum.at(indexes, Integer.mod(n, length(indexes))), note}

      _plain ->
        nil
    end
  end

  @doc "Start fetching every file of `name` still on the web, in the background."
  @spec prefetch(name()) :: :ok
  def prefetch(name) do
    case :ets.lookup(@table, key(name)) do
      [{_key, %{files: files}}] ->
        files
        |> Enum.map(&path_of/1)
        |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "http")))
        |> Fetch.prefetch()

      [] ->
        :ok
    end
  end

  @doc "How many files `name` holds; 0 for a name nobody registered."
  @spec count(name()) :: non_neg_integer()
  def count(name) do
    case :ets.lookup(@table, key(name)) do
      [{_key, %{files: files}}] -> length(files)
      [] -> 0
    end
  end

  @doc "Whether `name` is registered, loaded or not."
  @spec has?(name()) :: boolean()
  def has?(name), do: :ets.member(@table, key(name))

  @doc "Every registered name, sorted."
  @spec names() :: [String.t()]
  def names, do: @table |> :ets.select([{{:"$1", :_}, [], [:"$1"]}]) |> Enum.sort()

  @doc "Forget every registration."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp load(key, entry, at, false) do
    case path_of(Enum.at(entry.files, at)) do
      "http" <> _ = url ->
        if Fetch.cached?(url), do: load(key, entry, at, true), else: loading(url)

      _local ->
        load(key, entry, at, true)
    end
  end

  defp load(key, entry, at, true) do
    sample = entry.files |> Enum.at(at) |> read(entry.opts)
    :ets.insert(@table, {key, %{entry | loaded: Map.put(entry.loaded, at, sample)}})
    {:ok, sample}
  rescue
    _error -> :error
  end

  defp loading(url) do
    Fetch.prefetch([url])
    :loading
  end

  defp path_of({path, _opts}), do: path
  defp path_of(file), do: file

  defp read(%Sample{} = sample, _opts), do: sample
  defp read({file, own}, opts), do: read(file, Keyword.merge(opts, own))

  defp read("http" <> _ = url, opts) do
    case Fetch.fetch(url) do
      {:ok, path} -> Sample.load!(path, Keyword.put_new(opts, :name, Path.basename(url)))
      {:error, reason} -> raise ArgumentError, "could not fetch #{url}: #{inspect(reason)}"
    end
  end

  defp read(path, opts), do: Sample.load!(path, opts)

  defp midi(note) when is_number(note), do: note

  defp midi(note) do
    note
    |> String.downcase()
    |> String.replace("#", "s")
    |> TuningFork.Notes.semitone()
  end

  defp key(name) when is_atom(name), do: Atom.to_string(name)
  defp key(name) when is_binary(name), do: name
end

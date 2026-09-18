defmodule TuningFork.Sample.Font do
  @moduledoc """
  Soundfont instruments as Strudel plays them: one file per instrument, a zone per key
  range, each zone a recording with its root pitch and loop.

      {:ok, sample} = TuningFork.Sample.Font.sample("0040_JCLive_sf2_file", 60)
  """

  use GenServer

  alias TuningFork.Sample
  alias TuningFork.Sample.{Decode, Fetch}

  @table :tuning_fork_fonts
  @default_source "https://felixroos.github.io/webaudiofontdata/sound"

  @type zone :: %{
          low: integer(),
          high: integer(),
          root: float(),
          rate: pos_integer(),
          loop: {non_neg_integer(), pos_integer()} | nil,
          data: {:file, binary()} | {:pcm, binary()},
          sample: Sample.t() | nil
        }

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  The recording to play `midi` on the font `name`, decoded and kept once fetched.

  ## Options

    * `:wait` — whether to fetch and decode a font not loaded yet, default `true`. With
      `false` that starts in the background and the answer is `:loading` until it is done

  `:error` for a font that cannot be fetched or a note no zone covers.
  """
  @spec sample(String.t(), number(), keyword()) :: {:ok, Sample.t()} | :loading | :error
  def sample(name, midi, opts \\ []) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{_name, zones}] -> from_zones(zones, midi)
      [] -> if Keyword.get(opts, :wait, true), do: loaded(name, midi), else: loading(name)
    end
  end

  @doc "Fetch, decode and keep the font `name`; `:ok` when it is there, `{:error, reason}` when not."
  @spec load(String.t()) :: :ok | {:error, term()}
  def load(name) when is_binary(name) do
    if :ets.member(@table, name) do
      :ok
    else
      Fetch.once({:font, name}, fn -> fetch(name) end)
      if :ets.member(@table, name), do: :ok, else: {:error, :unavailable}
    end
  end

  @doc "Start loading the font `name` in the background and return at once."
  @spec prefetch(String.t()) :: :ok
  def prefetch(name) when is_binary(name) do
    unless :ets.member(@table, name), do: Fetch.background({:font, name}, fn -> fetch(name) end)
    :ok
  end

  @doc "Whether the font `name` is loaded."
  @spec loaded?(String.t()) :: boolean()
  def loaded?(name), do: :ets.member(@table, name)

  @doc "Where font files are fetched from; `source/1` changes it."
  @spec source() :: String.t()
  def source do
    case :ets.lookup(@table, :source) do
      [{:source, url}] -> url
      [] -> @default_source
    end
  end

  @doc "Fetch font files from `url` instead of Strudel's host."
  @spec source(String.t()) :: :ok
  def source(url) when is_binary(url) do
    :ets.insert(@table, {:source, String.trim_trailing(url, "/")})
    :ok
  end

  @doc "Forget every font loaded, once any load in flight has finished."
  @spec clear() :: :ok
  def clear do
    Fetch.settle()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  The zones written in a webaudiofont file, undecoded. `{:error, reason}` for text that is
  not one.
  """
  @spec parse(String.t()) :: {:ok, [zone()]} | {:error, term()}
  def parse(text) when is_binary(text) do
    case String.split(text, "zones:[", parts: 2) do
      [_head, body] ->
        zones =
          ~r/\{[^{}]*\}/
          |> Regex.scan(body)
          |> Enum.map(fn [object] -> zone(object) end)
          |> Enum.reject(&is_nil/1)

        {:ok, zones}

      _other ->
        {:error, :not_a_font}
    end
  end

  @doc "The zone of `zones` covering `midi`, or `nil`."
  @spec zone_for([zone()], number()) :: zone() | nil
  def zone_for(zones, midi) do
    Enum.find(zones, fn %{low: low, high: high} -> low <= midi and midi <= high + 1 end)
  end

  @doc """
  The zone's recording as a `TuningFork.Sample`, decoded through
  `TuningFork.Sample.Decode` when it is a compressed file. `index` names it in the cache.
  """
  @spec decode(zone(), String.t(), non_neg_integer()) :: {:ok, Sample.t()} | {:error, term()}
  def decode(%{data: {:pcm, pcm}} = zone, name, index) do
    {:ok,
     Sample.from_pcm(pcm,
       rate: zone.rate,
       root: zone.root,
       loop: zone.loop,
       name: "#{name}:#{index}"
     )}
  end

  def decode(%{data: {:file, bytes}} = zone, name, index) do
    path = Path.join(Fetch.dir(), cached(name, index))
    unless File.exists?(path), do: File.mkdir_p!(Fetch.dir()) && File.write!(path, bytes)

    with {:ok, wav} <- Decode.to_wav(path) do
      sample = Sample.load!(wav, root: zone.root, name: "#{name}:#{index}")
      {:ok, %{sample | loop: scaled(zone.loop, sample.rate / zone.rate)}}
    end
  end

  defp from_zones(zones, midi) do
    case zone_for(zones, midi) do
      %{sample: %Sample{} = sample} -> {:ok, sample}
      _none -> :error
    end
  end

  defp loaded(name, midi) do
    case load(name) do
      :ok -> sample(name, midi)
      {:error, _reason} -> :error
    end
  end

  defp loading(name) do
    prefetch(name)
    :loading
  end

  defp fetch(name) do
    with {:ok, path} <- Fetch.fetch("#{source()}/#{name}.js"),
         {:ok, text} <- File.read(path),
         {:ok, zones} <- parse(text) do
      decoded = zones |> Enum.with_index() |> Enum.flat_map(&decoded(&1, name))
      :ets.insert(@table, {name, decoded})
      :ok
    end
  end

  defp decoded({zone, index}, name) do
    case decode(zone, name, index) do
      {:ok, sample} -> [%{zone | sample: sample, data: nil}]
      {:error, _reason} -> []
    end
  end

  defp zone(object) do
    fields =
      ~r/(\w+)\s*:\s*('(?:[^'\\]|\\.)*'|[-\w.]+)/
      |> Regex.scan(object)
      |> Map.new(fn [_all, key, value] -> {key, value} end)

    with {:ok, low} <- number(fields, "keyRangeLow"),
         {:ok, high} <- number(fields, "keyRangeHigh"),
         {:ok, pitch} <- number(fields, "originalPitch"),
         {:ok, rate} <- number(fields, "sampleRate"),
         {:ok, data} <- data(fields) do
      coarse = fields |> number("coarseTune") |> value(0)
      fine = fields |> number("fineTune") |> value(0)
      loop_from = fields |> number("loopStart") |> value(0)
      loop_to = fields |> number("loopEnd") |> value(0)

      %{
        low: low,
        high: high,
        root: hz((pitch - 100 * coarse - fine) / 100),
        rate: rate,
        loop: loop(loop_from, loop_to),
        data: data,
        sample: nil
      }
    else
      _incomplete -> nil
    end
  end

  defp number(fields, key) do
    with {:ok, text} <- Map.fetch(fields, key),
         {value, ""} <- Integer.parse(text) do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp value({:ok, value}, _default), do: value
  defp value(:error, default), do: default

  defp data(%{"file" => quoted}), do: {:ok, {:file, Base.decode64!(unquoted(quoted))}}
  defp data(%{"sample" => quoted}), do: {:ok, {:pcm, Base.decode64!(unquoted(quoted))}}
  defp data(_fields), do: :error

  defp unquoted(quoted), do: quoted |> String.trim("'") |> String.replace("\\", "")

  defp loop(from, to) when from > 1 and from < to, do: {from, to}
  defp loop(_from, _to), do: nil

  defp scaled(nil, _factor), do: nil
  defp scaled({from, to}, factor), do: {round(from * factor), round(to * factor)}

  defp hz(midi), do: 440.0 * :math.pow(2.0, (midi - 69) / 12.0)

  defp cached(name, index) do
    hash = :crypto.hash(:sha256, "#{name}:#{index}") |> Base.encode16(case: :lower)

    binary_part(hash, 0, 24) <> ".mp3"
  end
end

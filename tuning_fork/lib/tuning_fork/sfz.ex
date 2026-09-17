defmodule TuningFork.Sfz do
  @moduledoc """
  SFZ instruments: a text map of recordings by key, velocity and round robin, read into a
  pitched `TuningFork.Sample.Bank` the kit plays by name, with the recordings fetched
  one by one as notes ask for them.

      {:ok, "fingerbass", 39} = TuningFork.Sfz.load("fingerbass")
      TuningFork.Kit.voice(%{s: "fingerbass", note: "e2"}, 0.5)

  `instruments/0` is the library's own list — free instruments on GitHub, each with its
  licence and who to credit — plus whatever the application adds under the `:sfz` key of
  the `:tuning_fork` environment in the same shape; `load/2` takes one of those names, a
  `github:` source, a URL or a local path. The kit loads a listed name itself the first
  time a pattern plays it, so `s("fingerbass")` in Strudel needs nothing more.

      config :tuning_fork, sfz: %{"ours" => %{source: "priv/sfz/ours.sfz", licence: "CC0 1.0", credit: "us", what: "a bell"}}

  What is read of the format: `<control>`, `<global>`, `<master>`, `<group>` and
  `<region>` headers, opcodes on any line in any number, values with spaces, `//`
  comments, `#define` and `#include`, `default_path`, `sample`, `key`, `lokey`, `hikey`,
  `pitch_keycenter`, `lovel`, `hivel`, `tune`, `transpose`, `volume`, `loop_mode`,
  `loop_start`, `loop_end`, `trigger`, `sw_default`, `sw_last` and `locc`. A bank takes one
  velocity layer (the regions whose range holds `:velocity`, default 100), every round
  robin of a note as one of its files, and leaves out release triggers, regions that need
  a controller raised (a pedal, a keyswitch away from the default) and, with `:keys`,
  regions outside a range. Envelopes, filters, modulation and controllers are not read.
  """

  alias TuningFork.Sample.{Bank, Fetch}

  @type region :: %{String.t() => String.t()}
  @type t :: %{control: %{String.t() => String.t()}, regions: [region()]}
  @type entry :: {String.t(), keyword()}
  @type bank :: %{float() => [entry()]}

  @instruments %{
    "fingerbass" => %{
      source: "github:freepats/electric-bass-YR/master/FingerBassYR 20190930.sfz",
      licence: "CC0 1.0",
      credit: "FreePats, Yamaha RBX bass",
      what: "an electric bass, fingered"
    },
    "pickbass" => %{
      source: "github:freepats/electric-bass-YR/master/PickedBassYR 20190930.sfz",
      licence: "CC0 1.0",
      credit: "FreePats, Yamaha RBX bass",
      what: "an electric bass, picked"
    },
    "jazzguitar" => %{
      source:
        "github:freepats/electric-guitar-FSBS-jazz/master/EGuitarFSBS-jazz bridge small 20260807.sfz",
      licence: "CC0 1.0",
      credit: "FreePats, Fender Stratocaster",
      what: "a clean electric guitar with a jazz tone, the small set"
    },
    "upright" => %{
      source: "github:freepats/upright-piano-KW/master/UprightPianoKW-20220221.sfz",
      licence: "CC0 1.0",
      credit: "FreePats, Kawai upright",
      what: "an upright piano in a living room"
    },
    "grand" => %{
      source: "github:sfzinstruments/SplendidGrandPiano/master/Splendid Grand Piano.sfz",
      licence: "Public domain",
      credit: "AKAI, Splendid Grand Piano",
      what: "a Steinway grand"
    },
    "wurlitzer" => %{
      source:
        "github:sfzinstruments/GregSullivan.E-Pianos/master/Wurlitzer EP200/Wurlitzer EP200.sfz",
      licence: "CC BY 3.0",
      credit: "Greg Sullivan",
      what: "a Wurlitzer EP200 electric piano"
    },
    "cp80" => %{
      source: "github:sfzinstruments/GregSullivan.E-Pianos/master/CP80/CP80.sfz",
      licence: "CC BY 3.0",
      credit: "Greg Sullivan",
      what: "a Yamaha CP80 electric grand"
    },
    "pianet" => %{
      source: "github:sfzinstruments/GregSullivan.E-Pianos/master/Pianet T/Pianet T.sfz",
      licence: "CC BY 3.0",
      credit: "Greg Sullivan",
      what: "a Hohner Pianet T"
    },
    "cello" => %{
      source: "github:sfzinstruments/karoryfer-bigcat.cello/master/Programs/vc_arco_sus_map.sfz",
      licence: "CC0 1.0",
      credit: "Karoryfer Samples and bigcat",
      what: "a cello, bowed and sustained",
      keys: 24..80
    },
    "cello_pizz" => %{
      source: "github:sfzinstruments/karoryfer-bigcat.cello/master/Programs/vc_pizz_basic.sfz",
      licence: "CC0 1.0",
      credit: "Karoryfer Samples and bigcat",
      what: "a cello, plucked",
      keys: 24..71
    },
    "meatbass" => %{
      source: "github:sfzinstruments/karoryfer.meatbass/master/Programs/pizz_basic_map.sfz",
      licence: "CC0 1.0",
      credit: "Karoryfer Samples, a 1958 Otto Rubner double bass",
      what: "a double bass, plucked"
    },
    "sneakybass" => %{
      source:
        "github:sfzinstruments/karoryfer.sneakybass/master/Programs/02-sneakybass_pluck.sfz",
      licence: "CC0 1.0",
      credit: "Karoryfer Samples",
      what: "a double bass plucked very quietly"
    }
  }

  @doc "The instruments known by name, the library's and the application's: each a `:source` for `load/2`, its `:licence`, who to `:credit` and `:what` it is."
  @spec instruments() :: %{
          String.t() => %{
            source: String.t(),
            licence: String.t(),
            credit: String.t(),
            what: String.t()
          }
        }
  def instruments,
    do: Map.merge(@instruments, Map.new(Application.get_env(:tuning_fork, :sfz, %{})))

  @doc "Whether `name` is one of `instruments/0`."
  @spec instrument?(String.t()) :: boolean()
  def instrument?(name), do: is_map_key(instruments(), name)

  @doc """
  The URL of a source: `github:user/repo/branch/path/to/file.sfz` becomes the raw file on
  GitHub, a URL is kept, and either has its spaces and other reserved characters escaped.
  """
  @spec url(String.t()) :: String.t()
  def url("github:" <> rest) do
    [user, repo, branch | path] = String.split(rest, "/")
    url("https://raw.githubusercontent.com/#{user}/#{repo}/#{branch}/#{Enum.join(path, "/")}")
  end

  def url("http" <> _ = url), do: escape(url)

  defp escape(url) do
    %URI{path: path} = uri = URI.parse(url)

    URI.to_string(%{
      uri
      | path: path |> URI.decode() |> URI.encode(&(URI.char_unreserved?(&1) or &1 == ?/))
    })
  end

  @doc """
  Register an instrument with the bank: one of `instruments/0` by name, or a source as
  `url/1` takes it, or a local path. The file and its includes are read now; the
  recordings are fetched as they are played, or all at once with `:prefetch`.

  Returns `{:ok, name, notes}` with how many notes the bank holds, or `{:error, reason}`.

  ## Options

    * `:name` — the bank name, default the instrument's name or the file's basename
    * `:velocity`, `:keys` — as `bank/2` takes them; a listed instrument brings its own `:keys`
    * `:prefetch` — start fetching every recording in the background, default `false`
  """
  @spec load(String.t(), keyword()) :: {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def load(source, opts \\ []) do
    case Map.fetch(instruments(), source) do
      {:ok, instrument} ->
        load(
          instrument.source,
          Keyword.merge([name: source, keys: Map.get(instrument, :keys)], opts)
        )

      :error ->
        load_source(source, opts)
    end
  end

  defp load_source(source, opts) do
    base =
      if String.starts_with?(source, "github:") or String.starts_with?(source, "http"),
        do: url(source),
        else: Path.expand(source)

    with {:ok, text} <- read(base) do
      sfz = parse(text, include: fn path -> read(join(base, path)) end)

      bank =
        bank(sfz,
          base: base,
          velocity: Keyword.get(opts, :velocity, 100),
          keys: Keyword.get(opts, :keys)
        )

      name =
        Keyword.get_lazy(opts, :name, fn ->
          base |> Path.basename() |> Path.rootname() |> String.downcase()
        end)

      Bank.put(name, bank)
      if Keyword.get(opts, :prefetch, false), do: Bank.prefetch(name)
      {:ok, name, map_size(bank)}
    end
  end

  defp read("http" <> _ = url) do
    with {:ok, path} <- Fetch.fetch(url), do: File.read(path)
  end

  defp read(path), do: File.read(path)

  @doc """
  The file as headers merged down to regions: `:control` is the `<control>` opcodes, and
  each of `:regions` carries its own opcodes over its group's, master's and the global
  ones, with `#define` names replaced. `:include` is a function of an `#include` path
  returning `{:ok, text}` or `:error`; without it, or when it says `:error`, the include is
  left out.
  """
  @spec parse(String.t(), keyword()) :: t()
  def parse(text, opts \\ []) do
    include = Keyword.get(opts, :include, fn _path -> :error end)

    text
    |> prepare(include, [])
    |> tokens()
    |> Enum.reduce(
      %{control: %{}, regions: [], scope: %{global: %{}, master: %{}, group: %{}}, header: nil},
      &collect/2
    )
    |> then(fn %{control: control, regions: regions} ->
      %{control: control, regions: Enum.reverse(regions)}
    end)
  end

  defp prepare(text, include, known) do
    names =
      Regex.scan(~r/^\s*#define\s+(\$\w+)\s+(\S+)/m, text)
      |> Enum.map(fn [_, name, value] -> {name, value} end)

    names = Enum.sort_by(names ++ known, fn {name, _} -> -String.length(name) end)
    stripped = Regex.replace(~r/^\s*#define[^\n]*$/m, text, "")

    substituted =
      Enum.reduce(names, stripped, fn {name, value}, acc -> String.replace(acc, name, value) end)

    Regex.replace(~r/^\s*#include\s+"([^"]+)"[^\n]*$/m, substituted, fn _, path ->
      case include.(path) do
        {:ok, more} -> prepare(more, include, names)
        :error -> ""
      end
    end)
  end

  defp tokens(text) do
    text
    |> String.replace(~r|//[^\n]*|, "")
    |> then(&Regex.scan(~r/<(\w+)>|([\w$]+)=((?:(?!\s+[\w$]+=)[^<\n])*)/, &1))
    |> Enum.map(fn
      [_, header] -> {:header, header}
      [_, "", key, value] -> {:opcode, key, String.trim(value)}
      [_, "", key] -> {:opcode, key, ""}
    end)
  end

  defp collect({:header, "region"}, state),
    do: %{
      state
      | header: :region,
        regions: [
          Map.merge(Map.merge(state.scope.global, state.scope.master), state.scope.group)
          | state.regions
        ]
    }

  defp collect({:header, "control"}, state), do: %{state | header: :control}

  defp collect({:header, "global"}, state),
    do: %{state | header: :global, scope: %{global: %{}, master: %{}, group: %{}}}

  defp collect({:header, "master"}, state),
    do: %{state | header: :master, scope: %{state.scope | master: %{}, group: %{}}}

  defp collect({:header, "group"}, state),
    do: %{state | header: :group, scope: %{state.scope | group: %{}}}

  defp collect({:header, _other}, state), do: %{state | header: nil}
  defp collect({:opcode, _key, _value}, %{header: nil} = state), do: state

  defp collect({:opcode, key, value}, %{header: :control} = state),
    do: %{state | control: Map.put(state.control, key, value)}

  defp collect({:opcode, key, value}, %{header: :region, regions: [region | rest]} = state),
    do: %{state | regions: [Map.put(region, key, value) | rest]}

  defp collect({:opcode, key, value}, %{header: header} = state),
    do: %{state | scope: Map.update!(state.scope, header, &Map.put(&1, key, value))}

  @doc """
  The bank a parsed file maps: each recorded pitch, as a MIDI number that may be
  fractional, to its files in order of round robin, each `{file, opts}` with `:loop` and
  `:gain` as `TuningFork.Sample.Bank.put/3` takes them. Files are resolved against
  `:base`, the file's own path or URL, and `default_path`.

  ## Options

    * `:base` — required; the path or URL the file was read from
    * `:velocity` — the layer to take, default 100
    * `:keys` — a range of MIDI numbers; regions whose key centre lies outside it are left out
  """
  @spec bank(t(), keyword()) :: bank()
  def bank(%{control: control, regions: regions}, opts) do
    base = Keyword.fetch!(opts, :base)
    velocity = Keyword.get(opts, :velocity, 100)
    keys = Keyword.get(opts, :keys)
    default_path = Map.get(control, "default_path", "")

    regions
    |> Enum.filter(&plays?(&1, velocity, keys))
    |> Enum.group_by(&note/1)
    |> Map.new(fn {note, layer} ->
      {note,
       Enum.map(
         layer,
         &{join(base, default_path <> String.replace(&1["sample"], "\\", "/")), entry(&1)}
       )}
    end)
  end

  defp plays?(region, velocity, keys) do
    Map.has_key?(region, "sample") and
      Map.get(region, "trigger", "attack") in ["attack", "first"] and
      in_velocity?(region, velocity) and no_controller?(region) and switch_default?(region) and
      (keys == nil or trunc(centre(region)) in keys)
  end

  defp in_velocity?(region, velocity),
    do: number(region, "lovel", 1) <= velocity and number(region, "hivel", 127) >= velocity

  defp no_controller?(region),
    do:
      Enum.all?(region, fn {key, value} ->
        not String.starts_with?(key, "locc") or number(value) <= 0
      end)

  defp switch_default?(%{"sw_last" => last, "sw_default" => default}), do: last == default
  defp switch_default?(_region), do: true

  defp note(region),
    do: centre(region) - number(region, "transpose", 0) - number(region, "tune", 0) / 100

  defp centre(region) do
    cond do
      Map.has_key?(region, "pitch_keycenter") ->
        key_number(region["pitch_keycenter"])

      Map.has_key?(region, "key") ->
        key_number(region["key"])

      Map.has_key?(region, "lokey") and region["lokey"] == region["hikey"] ->
        key_number(region["lokey"])

      true ->
        60.0
    end
  end

  defp key_number(value) do
    case Float.parse(value) do
      {number, _} ->
        number

      :error ->
        value
        |> String.replace("#", "s")
        |> String.downcase()
        |> TuningFork.Notes.semitone()
        |> Kernel.*(1.0)
    end
  end

  defp entry(region) do
    loop =
      if Map.get(region, "loop_mode") in ["loop_continuous", "loop_sustain"] and
           Map.has_key?(region, "loop_start") and Map.has_key?(region, "loop_end"),
         do: [
           loop: {trunc(number(region, "loop_start", 0)), trunc(number(region, "loop_end", 0))}
         ],
         else: []

    gain =
      if Map.has_key?(region, "volume"),
        do: [gain: :math.pow(10, number(region, "volume", 0) / 20)],
        else: []

    loop ++ gain
  end

  defp number(region, key, default),
    do: if(Map.has_key?(region, key), do: number(region[key]), else: default * 1.0)

  defp number(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> 0.0
    end
  end

  defp join("http" <> _ = base, path) do
    %URI{path: dir} = uri = URI.parse(base)
    joined = Path.expand(path, Path.dirname(URI.decode(dir)))
    URI.to_string(%{uri | path: URI.encode(joined, &(URI.char_unreserved?(&1) or &1 == ?/))})
  end

  defp join(base, path), do: Path.expand(path, Path.dirname(base))
end

defmodule TuningFork.Samples do
  @moduledoc """
  Sonic Pi's recordings by name, registered with `TuningFork.Sample.Bank` when this
  application starts and fetched from Sonic Pi's repository the first time each is played.

      TuningFork.Samples.load!(:perc_bell)
      TuningFork.Samples.prefetch()
  """

  alias TuningFork.Sample
  alias TuningFork.Sample.{Bank, Fetch}
  alias TuningFork.Samples.Names

  @default_source "https://raw.githubusercontent.com/sonic-pi-net/sonic-pi/v4.5.1/etc/samples"

  @doc "Every sample name, sorted."
  @spec names() :: [String.t()]
  def names, do: Names.all()

  @doc """
  The names grouped by what comes before their first underscore.

      iex> TuningFork.Samples.families()["vinyl"]
      ["vinyl_backspin", "vinyl_hiss", "vinyl_rewind", "vinyl_scratch"]
  """
  @spec families() :: %{String.t() => [String.t()]}
  def families do
    Enum.group_by(Names.all(), fn name -> name |> String.split("_", parts: 2) |> hd() end)
  end

  @doc "Where the recordings are fetched from; `source/1` changes it."
  @spec source() :: String.t()
  def source, do: Application.get_env(:tuning_fork_samples, :source, @default_source)

  @doc """
  Fetch the recordings from `url` instead of Sonic Pi's repository, and register every name
  there. `url` is a directory holding `<name>.flac` files.
  """
  @spec source(String.t()) :: :ok
  def source(url) when is_binary(url) do
    Application.put_env(:tuning_fork_samples, :source, String.trim_trailing(url, "/"))
    register()
  end

  @doc "The URL `name` is fetched from, or `nil` for a name the bank does not have."
  @spec url(atom() | String.t()) :: String.t() | nil
  def url(name) do
    name = to_string(name)
    if name in Names.all(), do: "#{source()}/#{name}.flac", else: nil
  end

  @doc """
  The recording `name`, fetched and decoded the first time and kept in the bank after that.

  Raises `ArgumentError` for a name the bank does not have or a recording that cannot be
  fetched.
  """
  @spec load!(atom() | String.t()) :: Sample.t()
  def load!(name) do
    case Bank.fetch(name) do
      {:ok, sample} -> sample
      :error -> raise ArgumentError, "no sample named #{name}"
    end
  end

  @doc "Register every name with `TuningFork.Sample.Bank`. Done when the application starts."
  @spec register() :: :ok
  def register do
    Enum.each(Names.all(), fn name -> Bank.put(name, url(name)) end)
  end

  @doc """
  Start fetching every recording into `TuningFork.Sample.Fetch.dir/0` in the background,
  about 34 MB in all, and return at once. A recording already there is not fetched again.
  """
  @spec prefetch() :: :ok
  def prefetch do
    Names.all() |> Enum.map(&url/1) |> Fetch.prefetch()
  end
end

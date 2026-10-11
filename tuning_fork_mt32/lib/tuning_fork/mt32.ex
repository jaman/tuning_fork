defmodule TuningFork.Mt32 do
  @moduledoc """
  Renders MIDI as a Roland MT-32 plays it, through the user's own installation of the
  Munt emulator.

  Nothing of Munt is part of this package. `MUNT_LOCATION` names a directory holding the
  Munt library (`libmt32emu.dylib`, `libmt32emu.so` or `mt32emu.dll`, directly or under
  `lib/`) and the ROMs (`MT32_CONTROL.ROM` and `MT32_PCM.ROM`, or `CM32L_CONTROL.ROM`
  and `CM32L_PCM.ROM`); the library is loaded when a synth is opened.

      if TuningFork.Mt32.available?() do
        {:ok, synth} = TuningFork.Mt32.open()
        {:ok, sample} = TuningFork.Mt32.render_midi(synth, midi)
      else
        TuningFork.Gm.score(midi)
      end

  A synth keeps its state between renders: patches sent by sysex stay until it is reset
  or closed.
  """

  import Bitwise

  alias TuningFork.{Midi, Sample}
  alias TuningFork.Mt32.Nif

  @enforce_keys [:synth, :rate, :version]
  defstruct [:synth, :rate, :version]

  @type t :: %__MODULE__{synth: Nif.synth(), rate: pos_integer(), version: String.t()}
  @type error ::
          :no_munt
          | {:no_library, Path.t()}
          | {:missing_rom, String.t()}
          | {:not_a_library, String.t()}
          | {:missing_function, String.t()}
          | {:rom_rejected, :control | :pcm}
          | {:open_failed, integer()}

  @libraries ["libmt32emu.dylib", "libmt32emu.so", "mt32emu.dll"]
  @rom_sets [{"MT32_CONTROL.ROM", "MT32_PCM.ROM"}, {"CM32L_CONTROL.ROM", "CM32L_PCM.ROM"}]
  @default_rate 32_000
  @release_seconds 2.0
  @default_tempo 500_000

  @doc "The directory `MUNT_LOCATION` names, or `nil`."
  @spec location() :: Path.t() | nil
  def location, do: System.get_env("MUNT_LOCATION")

  @doc "Whether `MUNT_LOCATION` names a directory with a Munt library and ROMs."
  @spec available?() :: boolean()
  def available?, do: match?({:ok, _library, _roms}, find(location()))

  @doc """
  Opens a synth. Options: `:location` (default `MUNT_LOCATION`) and `:rate`, the output
  rate asked of Munt (default 32 000, the MT-32's own).
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, error()}
  def open(opts \\ []) do
    with {:ok, library_path, {control_path, pcm_path}} <-
           find(Keyword.get(opts, :location, location())),
         {:ok, library} <- Nif.load_library(library_path),
         {:ok, control} <- read_rom(control_path),
         {:ok, pcm} <- read_rom(pcm_path),
         {:ok, synth, rate} <-
           Nif.open(library, control, pcm, Keyword.get(opts, :rate, @default_rate)) do
      {:ok, %__MODULE__{synth: synth, rate: rate, version: Nif.library_version(library)}}
    end
  end

  @doc """
  Renders `seconds` of stereo audio, sending each message at its time in seconds.
  Messages are whole MIDI messages: three bytes for a note, a sysex from `0xF0` to
  `0xF7`. Returns signed 16-bit little-endian interleaved PCM at the synth's rate.
  """
  @spec render(t(), [{number(), binary()}], number()) ::
          {:ok, binary()} | {:error, :closed | :out_of_memory}
  def render(%__MODULE__{synth: synth, rate: rate}, messages, seconds) do
    timed = for {at, bytes} <- Enum.sort_by(messages, &elem(&1, 0)), do: {frame(at, rate), bytes}

    case Nif.render(synth, timed, frame(seconds, rate)) do
      {:ok, pcm, _refused} -> {:ok, pcm}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Renders a parsed MIDI file, with two seconds after its last event for notes to
  release, as a sample.
  """
  @spec render_midi(t(), Midi.t()) :: {:ok, Sample.t()} | {:error, :closed | :out_of_memory}
  def render_midi(%__MODULE__{rate: rate} = synth, %Midi{} = midi) do
    messages = messages(midi)
    length = messages |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0.0 end)

    with {:ok, pcm} <- render(synth, messages, length + @release_seconds) do
      {:ok, Sample.from_pcm(pcm, rate: rate, channels: 2, name: "mt32")}
    end
  end

  @doc "Every message of `midi` with its time in seconds, following the file's tempo changes."
  @spec messages(Midi.t()) :: [{float(), binary()}]
  def messages(%Midi{division: division, tracks: tracks}) do
    tracks
    |> Enum.concat()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({0, 0.0, @default_tempo, []}, &timed(&1, &2, division))
    |> elem(3)
    |> Enum.reverse()
  end

  @doc "Stops the synth and frees it."
  @spec close(t()) :: :ok
  def close(%__MODULE__{synth: synth}), do: Nif.close(synth)

  defp timed({tick, event}, {last_tick, seconds, tempo, acc}, division) do
    at = seconds + (tick - last_tick) * tempo / (division * 1_000_000)
    {tempo, acc} = event(event, at, tempo, acc)
    {tick, at, tempo, acc}
  end

  defp event({:tempo, microseconds}, _at, _tempo, acc), do: {microseconds, acc}

  defp event({:note_on, channel, note, velocity}, at, tempo, acc),
    do: {tempo, [{at, <<0x90 ||| channel, note, velocity>>} | acc]}

  defp event({:note_off, channel, note, velocity}, at, tempo, acc),
    do: {tempo, [{at, <<0x80 ||| channel, note, velocity>>} | acc]}

  defp event({:program, channel, program}, at, tempo, acc),
    do: {tempo, [{at, <<0xC0 ||| channel, program>>} | acc]}

  defp event({:control, channel, control, value}, at, tempo, acc),
    do: {tempo, [{at, <<0xB0 ||| channel, control, value>>} | acc]}

  defp event({:sysex, bytes}, at, tempo, acc), do: {tempo, [{at, bytes} | acc]}

  defp event({:pitch_bend, channel, bend}, at, tempo, acc) do
    raw = (bend * 8_192 + 8_192) |> round() |> max(0) |> min(16_383)
    {tempo, [{at, <<0xE0 ||| channel, raw &&& 0x7F, raw >>> 7>>} | acc]}
  end

  defp event(_other, _at, tempo, acc), do: {tempo, acc}

  defp frame(seconds, rate), do: round(seconds * rate)

  defp find(nil), do: {:error, :no_munt}

  defp find(dir) do
    with {:ok, library} <- library_in(dir),
         {:ok, roms} <- roms_in(dir) do
      {:ok, library, roms}
    end
  end

  defp library_in(dir) do
    candidates =
      for name <- @libraries, base <- [dir, Path.join(dir, "lib")], do: Path.join(base, name)

    case Enum.find(candidates, &File.regular?/1) do
      nil -> {:error, {:no_library, dir}}
      path -> {:ok, path}
    end
  end

  defp roms_in(dir) do
    case Enum.find(@rom_sets, fn {control, pcm} ->
           File.regular?(Path.join(dir, control)) and File.regular?(Path.join(dir, pcm))
         end) do
      nil -> {:error, {:missing_rom, missing_rom(dir)}}
      {control, pcm} -> {:ok, {Path.join(dir, control), Path.join(dir, pcm)}}
    end
  end

  defp missing_rom(dir) do
    {control, pcm} = hd(@rom_sets)
    if File.regular?(Path.join(dir, control)), do: pcm, else: control
  end

  defp read_rom(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, {:missing_rom, Path.basename(path)}}
    end
  end
end

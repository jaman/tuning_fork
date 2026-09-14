defmodule TuningFork.Sample do
  @moduledoc """
  Recorded audio, to be played as a `TuningFork.Voice`.

      kick = Sample.load!("kick.wav")
      part(bpm: 96, synth: Voice.new(sample: kick)) |> steps("x..x..x.")
  """

  alias TuningFork.{Flac, Mixer, Notes, Wav}
  alias TuningFork.Sample.Decode

  @type t :: %__MODULE__{
          id: term(),
          pcm: binary(),
          rate: pos_integer(),
          root: float() | nil,
          loop: {non_neg_integer(), pos_integer()} | nil,
          name: String.t()
        }

  defstruct [:id, :pcm, :rate, :root, :loop, name: "sample"]

  @doc """
  Read a recording from disk: a WAV or a FLAC as they are, anything else through
  `TuningFork.Sample.Decode`.

  Which it is comes from the file's own header, not its name. Raises if the file cannot be read
  or will not decode.

  ## Options

    * `:root` — the pitch the recording already is, as a note name or a frequency in Hz.
      Leave it out for percussion, which has no pitch to move from
    * `:name` — what to call it, default the file's basename

  `:rate` and `:channels` come from the file and are not taken here.
  """
  @spec load!(Path.t(), keyword()) :: t()
  def load!(path, opts \\ []) do
    {pcm, rate, channels} = read(path, File.read!(path))

    from_pcm(
      pcm,
      Keyword.merge([rate: rate, channels: channels, name: Path.basename(path)], opts)
    )
  end

  @doc """
  A sample from PCM already in memory.

  Stereo input is folded to mono, since a voice is synthesised in mono and panned afterwards.
  More than two channels raises `ArgumentError`.

  ## Options

    * `:rate` — samples per second of the PCM given, default 44100
    * `:channels` — 1 or 2, default 1
    * `:root` — the pitch the recording already is, as a note name or a frequency in Hz
    * `:loop` — `{from, to}` frames a voice goes round between once it reaches `to`, so a
      note can outlast the recording; default `nil`
    * `:name` — what to call it, default `"sample"`
  """
  @spec from_pcm(binary(), keyword()) :: t()
  def from_pcm(pcm, opts \\ []) do
    rate = Keyword.get(opts, :rate, 44_100)

    mono =
      case Keyword.get(opts, :channels, 1) do
        1 -> pcm
        2 -> Mixer.to_mono(pcm)
        more -> raise ArgumentError, "#{more} channels is more than this can fold to mono"
      end

    %__MODULE__{
      id: :erlang.phash2({Keyword.get(opts, :name), rate, byte_size(mono), mono}),
      pcm: mono,
      rate: rate,
      root: root(Keyword.get(opts, :root)),
      loop: Keyword.get(opts, :loop),
      name: Keyword.get(opts, :name, "sample")
    }
  end

  defp read(_path, <<"RIFF", _::binary>> = wav), do: Wav.decode!(wav)

  defp read(path, <<"fLaC", _::binary>> = flac) do
    case Flac.decode(flac) do
      {:ok, pcm, rate, channels} -> {pcm, rate, channels}
      {:error, reason} -> raise ArgumentError, "#{path} is FLAC that will not read: #{reason}"
    end
  end

  defp read(path, _other) do
    case Decode.to_wav(path) do
      {:ok, wav} -> read(wav, File.read!(wav))
      {:error, reason} -> raise ArgumentError, "#{path} will not decode: #{inspect(reason)}"
    end
  end

  defp root(nil), do: nil
  defp root(hz) when is_number(hz), do: hz * 1.0
  defp root(name) when is_atom(name), do: Notes.freq(name)

  @doc "How many frames long the recording is."
  @spec frames(t()) :: non_neg_integer()
  def frames(%__MODULE__{pcm: pcm}), do: div(byte_size(pcm), 2)

  @doc "How long the recording lasts at its own speed, in seconds."
  @spec duration(t()) :: float()
  def duration(%__MODULE__{rate: rate} = sample), do: frames(sample) / rate

  @doc """
  How long the recording lasts when played at `freq`, in seconds.

  Longer when pitched down and shorter when pitched up. A sample with no `:root`, or a `freq`
  of `nil`, gives `duration/1`.
  """
  @spec duration(t(), float() | nil) :: float()
  def duration(%__MODULE__{root: nil} = sample, _freq), do: duration(sample)
  def duration(%__MODULE__{} = sample, nil), do: duration(sample)

  def duration(%__MODULE__{root: root} = sample, freq) do
    duration(sample) * root / freq
  end

  @doc """
  How far to move through the recording per output frame to sound at `freq` through a device
  running at `rate`.

  Two ratios in one: `freq` against the sample's `:root`, and the sample's own rate against
  `rate`. A sample with no `:root`, or a `freq` of `nil`, is read at its own pitch and still
  corrected for rate.
  """
  @spec ratio(t(), float() | nil, pos_integer()) :: float()
  def ratio(%__MODULE__{} = sample, freq, rate) do
    pitch =
      case {sample.root, freq} do
        {nil, _any} -> 1.0
        {_root, nil} -> 1.0
        {root, freq} -> freq / root
      end

    pitch * sample.rate / rate
  end

  @doc """
  The value at a fractional frame position in the recording, from -1.0 to 1.0.

  Cubic Hermite interpolation through the two frames either side and their neighbours. A
  position before the start or past the end is 0.0 rather than a wrap, unless the recording
  has a loop, which `looped/2` brings it back inside.
  """
  @spec at(t(), float()) :: float()
  def at(%__MODULE__{} = sample, position) when position >= 0.0 do
    %{pcm: pcm} = sample
    position = looped(sample, position)
    index = trunc(position)
    fraction = position - index

    y1 = frame_at(pcm, index)

    if fraction == 0.0 do
      y1
    else
      y0 = frame_at(pcm, index - 1)
      y2 = frame_at(pcm, index + 1)
      y3 = frame_at(pcm, index + 2)
      c1 = 0.5 * (y2 - y0)
      c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
      c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)

      ((c3 * fraction + c2) * fraction + c1) * fraction + y1
    end
  end

  def at(%__MODULE__{}, _before_the_start), do: 0.0

  @doc """
  `position` brought back inside the loop when the recording has one and the position has
  passed its end; unchanged otherwise.
  """
  @spec looped(t(), float()) :: float()
  def looped(%__MODULE__{loop: {from, to}}, position) when to > from and position >= to do
    from + :math.fmod(position - from, to - from)
  end

  def looped(%__MODULE__{}, position), do: position

  defp frame_at(pcm, index) do
    offset = index * 2

    if offset >= 0 and offset + 2 <= byte_size(pcm) do
      <<value::16-signed-little>> = binary_part(pcm, offset, 2)
      value / 32_768.0
    else
      0.0
    end
  end

  @doc """
  A new sample cut out of this one: `length` seconds starting `from` seconds in.

  A range running past the end is truncated to what is there. The result keeps the rate and
  root of the original and gets its own `:id`, so caches tell it apart from what it came
  from.
  """
  @spec slice(t(), number(), number()) :: t()
  def slice(%__MODULE__{} = sample, from, length) do
    start = max(trunc(from * sample.rate), 0) * 2
    take = max(trunc(length * sample.rate), 0) * 2
    available = max(byte_size(sample.pcm) - start, 0)

    pcm = binary_part(sample.pcm, min(start, byte_size(sample.pcm)), min(take, available))

    from_pcm(pcm,
      rate: sample.rate,
      root: sample.root,
      name: "#{sample.name}[#{Float.round(from / 1, 3)}]"
    )
  end

  @doc "A new sample with the recording reversed, keeping its rate and root."
  @spec reverse(t()) :: t()
  def reverse(%__MODULE__{} = sample) do
    reversed =
      for <<value::16-signed-little <- sample.pcm>>, reduce: <<>> do
        acc -> <<value::16-signed-little, acc::binary>>
      end

    from_pcm(reversed, rate: sample.rate, root: sample.root, name: "#{sample.name} reversed")
  end
end

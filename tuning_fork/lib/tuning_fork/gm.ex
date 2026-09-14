defmodule TuningFork.Gm do
  @moduledoc """
  Voices for General MIDI's instrument and drum numbers.

      Gm.for_program(33, base)
  """

  alias TuningFork.{Envelope, Midi, Score, Voice}

  @type family ::
          :struck
          | :organ
          | :guitar
          | :bass
          | :strings
          | :brass
          | :reed
          | :pipe
          | :lead
          | :pad
          | :other

  @doc """
  A whole MIDI file as a score, with an instrument chosen for every channel.

  A channel is played with the voice for the last program it selected. Channels named as
  percussion by `:drum_channels` are played from `drums/1` by note number, and are guessed
  unless stated.

      "song.mid" |> TuningFork.Midi.read!() |> Gm.score() |> Score.render(44_100)

  ## Options

    * `:base` — the voice every instrument is derived from, and what an unnamed channel
      plays. Default a filtered saw
    * `:gain` — level per note, default 0.2. Used only when `:base` is not given
    * `:drum_gain` — the kit's level against everything else, default 1.0
    * `:plain` — one voice for everything, ignoring the program changes, default false
    * anything `TuningFork.Midi.to_score/2` takes — `:bpm`, `:drum_channels`, `:quantize`,
      `:bend_range`, `:bend_points`, `:beats`
  """
  @spec score(Midi.t(), keyword()) :: Score.t()
  def score(%Midi{} = midi, opts \\ []) do
    {ours, theirs} = Keyword.split(opts, [:base, :gain, :drum_gain, :plain])

    base =
      Keyword.get(ours, :base) ||
        Voice.new(
          shape: :saw,
          gain: Keyword.get(ours, :gain, 0.2),
          cutoff: 0.45,
          envelope: Envelope.new(attack: 0.006, sustain: 0.3, release: 0.12, curve: 2.4)
        )

    synths =
      if ours[:plain] do
        %{}
      else
        for {_tick, {:program, channel, program}} <- Midi.merged(midi), into: %{} do
          {channel, for_program(program, base)}
        end
      end

    Midi.to_score(
      midi,
      Keyword.merge(
        [
          default: base,
          synths: synths,
          drums: drums(Keyword.get(ours, :drum_gain, 1.0)),
          drum_channels: :auto
        ],
        theirs
      )
    )
  end

  @families %{
    organ: {:square, 0.35, 0.02, 0.9, 0.1},
    guitar: {:saw, 0.4, 0.004, 0.15, 0.12},
    bass: {:square, 0.12, 0.008, 0.35, 0.1},
    strings: {:saw, 0.3, 0.12, 0.85, 0.3},
    brass: {:saw, 0.55, 0.04, 0.8, 0.12},
    reed: {:square, 0.45, 0.05, 0.8, 0.15},
    pipe: {:sine, nil, 0.06, 0.85, 0.15},
    lead: {:saw, 0.5, 0.01, 0.75, 0.1},
    pad: {:saw, 0.25, 0.25, 0.9, 0.4}
  }

  @doc """
  A voice for a General MIDI program number, derived from `base`.

  The shape, cutoff and envelope are set from the program's `family/1`; every other field of
  `base` is kept. A program in the `:other` family returns `base` unchanged.
  """
  @spec for_program(0..127, Voice.t()) :: Voice.t()
  def for_program(program, %Voice{} = base) do
    case family(program) do
      :struck -> %{base | shape: :triangle, cutoff: 0.55, envelope: struck(base)}
      :other -> base
      family -> voiced(base, Map.fetch!(@families, family))
    end
  end

  defp voiced(base, {shape, cutoff, attack, sustain, release}) do
    %{base | shape: shape, cutoff: cutoff, envelope: env(base, attack, sustain, release)}
  end

  @doc "Which family a program number belongs to. Programs 96 to 127 are `:other`."
  @spec family(0..127) :: family()
  def family(program) when program in 0..15, do: :struck
  def family(program) when program in 16..23, do: :organ
  def family(program) when program in 24..31, do: :guitar
  def family(program) when program in 32..39, do: :bass
  def family(program) when program in 40..55, do: :strings
  def family(program) when program in 56..63, do: :brass
  def family(program) when program in 64..71, do: :reed
  def family(program) when program in 72..79, do: :pipe
  def family(program) when program in 80..87, do: :lead
  def family(program) when program in 88..95, do: :pad
  def family(program) when program in 96..127, do: :other

  @doc """
  A drum kit, as a map from General MIDI note number to voice.

  `gain` scales the whole kit; no voice exceeds a gain of 1.0. `drum_notes/0` lists the
  numbers covered.
  """
  @spec drums(number()) :: %{(0..127) => Voice.t()}
  def drums(gain \\ 1.0) do
    %{
      35 => drum(0.9 * gain, 0.04, nil, 0.22),
      36 => drum(0.9 * gain, 0.05, nil, 0.20),
      41 => drum(0.7 * gain, 0.12, nil, 0.25),
      43 => drum(0.7 * gain, 0.15, nil, 0.24),
      45 => drum(0.7 * gain, 0.20, nil, 0.22),
      47 => drum(0.7 * gain, 0.25, nil, 0.20),
      48 => drum(0.7 * gain, 0.30, nil, 0.18),
      50 => drum(0.7 * gain, 0.35, nil, 0.16),
      37 => drum(0.5 * gain, nil, 0.70, 0.04),
      38 => drum(0.6 * gain, 0.50, 0.12, 0.14),
      39 => drum(0.6 * gain, 0.50, 0.15, 0.12),
      40 => drum(0.6 * gain, 0.50, 0.12, 0.14),
      42 => drum(0.35 * gain, nil, 0.65, 0.05),
      44 => drum(0.30 * gain, nil, 0.65, 0.06),
      46 => drum(0.40 * gain, nil, 0.60, 0.28),
      49 => drum(0.45 * gain, nil, 0.45, 0.90),
      51 => drum(0.35 * gain, nil, 0.55, 0.60),
      52 => drum(0.40 * gain, nil, 0.50, 0.70),
      53 => drum(0.35 * gain, nil, 0.55, 0.50),
      55 => drum(0.45 * gain, nil, 0.50, 0.80),
      57 => drum(0.45 * gain, nil, 0.45, 0.85),
      59 => drum(0.35 * gain, nil, 0.55, 0.55),
      54 => drum(0.30 * gain, nil, 0.60, 0.12),
      56 => drum(0.35 * gain, 0.60, 0.30, 0.08),
      60 => drum(0.40 * gain, 0.45, 0.10, 0.12),
      61 => drum(0.40 * gain, 0.35, 0.08, 0.14),
      62 => drum(0.35 * gain, 0.55, 0.20, 0.08),
      63 => drum(0.35 * gain, 0.50, 0.18, 0.10),
      64 => drum(0.35 * gain, 0.40, 0.12, 0.12),
      58 => drum(0.30 * gain, nil, 0.55, 0.35),
      65 => drum(0.35 * gain, 0.55, 0.15, 0.10),
      66 => drum(0.35 * gain, 0.45, 0.15, 0.12),
      67 => drum(0.30 * gain, nil, 0.65, 0.08),
      68 => drum(0.30 * gain, nil, 0.60, 0.09),
      69 => drum(0.25 * gain, nil, 0.70, 0.10),
      70 => drum(0.25 * gain, nil, 0.75, 0.08),
      71 => drum(0.25 * gain, nil, 0.80, 0.06),
      72 => drum(0.25 * gain, nil, 0.80, 0.25),
      73 => drum(0.30 * gain, nil, 0.62, 0.05),
      74 => drum(0.30 * gain, nil, 0.62, 0.20),
      75 => drum(0.30 * gain, nil, 0.68, 0.05),
      76 => drum(0.35 * gain, 0.50, 0.25, 0.06),
      77 => drum(0.35 * gain, 0.45, 0.22, 0.07),
      78 => drum(0.30 * gain, 0.60, 0.30, 0.10),
      79 => drum(0.30 * gain, 0.60, 0.30, 0.25),
      80 => drum(0.20 * gain, nil, 0.85, 0.08),
      81 => drum(0.25 * gain, nil, 0.80, 0.30)
    }
  end

  @doc "The percussion note numbers `drums/1` answers to, ascending."
  @spec drum_notes() :: [0..127]
  def drum_notes, do: drums() |> Map.keys() |> Enum.sort()

  defp drum(gain, cutoff, highpass, decay) do
    Voice.new(
      shape: :noise,
      gain: min(gain, 1.0),
      cutoff: cutoff,
      highpass: highpass,
      envelope: Envelope.hit(decay)
    )
  end

  defp struck(base), do: %{env(base, 0.002, 0.0, 0.15) | decay: 1.2}

  defp env(%Voice{envelope: %Envelope{} = envelope}, attack, sustain, release) do
    %{envelope | attack: attack, sustain: sustain, release: release}
  end

  defp env(%Voice{}, attack, sustain, release) do
    Envelope.new(attack: attack, sustain: sustain, release: release)
  end
end

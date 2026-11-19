defmodule TuningFork.Composer.Arrangement.Track do
  @moduledoc """
  One track of an arrangement: its instrument, its clips, and how it is mixed.

    * `:instrument` — a drum (`TuningFork.Composer.Arrangement.Voices.drums/0`), an
      instrument the grid composer knows (`TuningFork.Composer.instruments/0`), a General
      MIDI soundfont by its `gm_` name, `"sample:"` and a sound file's path, or a sample
      bank's name
    * `:gain_db` — its level in decibels, `0.0` for unity
    * `:pan` — `-1.0` hard left to `1.0` hard right
    * `:send` — how much of it goes through the arrangement's reverb, `0.0` to `1.0`
    * `:mute`, `:solo` — a muted track is silent; when any track is soloed, only soloed
      tracks play. Mute wins over solo
    * `:mono` — one note at a time: each note is cut where the next one starts
    * `:extra` — fields a writer keeps on the track that this library does not read

      Track.new(name: "bass", instrument: "bass", gain_db: -3.0, clips: [clip])
  """

  alias TuningFork.Composer.Arrangement.Clip

  @type t :: %__MODULE__{
          name: String.t(),
          instrument: String.t(),
          gain_db: float(),
          pan: float(),
          send: float(),
          mute: boolean(),
          solo: boolean(),
          mono: boolean(),
          clips: [Clip.t()],
          extra: map()
        }

  defstruct name: "track",
            instrument: "piano",
            gain_db: 0.0,
            pan: 0.0,
            send: 0.0,
            mute: false,
            solo: false,
            mono: false,
            clips: [],
            extra: %{}

  @doc "A track. Takes any field of the struct as an option."
  @spec new(keyword() | map()) :: t()
  def new(fields \\ []), do: struct!(__MODULE__, fields)

  @doc "The track's level as a linear gain: `1.0` at `0.0` dB."
  @spec gain(t()) :: float()
  def gain(%__MODULE__{gain_db: db}), do: :math.pow(10.0, db / 20.0)
end

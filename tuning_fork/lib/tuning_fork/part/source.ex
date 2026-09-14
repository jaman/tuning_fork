defmodule TuningFork.Part.Source do
  @moduledoc """
  Reads a block of loop source into a score.

      iex> {:ok, score} = TuningFork.Part.Source.parse("part(bpm: 120) |> play(:c3, 1)")
      iex> %TuningFork.Score{} = score
      iex> TuningFork.Part.Source.parse("part(bpm: 120) |> nonsense(")
      {:error, "missing terminator: )"}
  """

  alias TuningFork.{Score, Source}
  alias TuningFork.SonicPi.Blocks

  @doc """
  The score `source` describes, or why it will not read.

  Returns `{:ok, %TuningFork.Score{}}` or `{:error, message}`, the message trimmed to one line
  so it fits under the loop it belongs to. Empty source is an empty score rather than an error,
  so a loop being written from scratch reports nothing until there is something to report.
  """
  @spec parse(String.t()) :: {:ok, Score.t()} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    with {:ok, body} <- compile(source), do: body.()
  end

  @doc """
  The source compiled once into a function that gives a fresh score every time it is called.

      iex> {:ok, body} = TuningFork.Part.Source.compile("part(bpm: 120) |> play(:c3, 1)")
      iex> {:ok, %TuningFork.Score{}} = body.()

  Compile once and call the function as often as needed: each call evaluates the source
  again, so `TuningFork.Tick` counters advance and `TuningFork.State` values are read as they
  stand at that call. `TuningFork.Stage` calls it once per round.

  The function returns `{:ok, score}` or `{:error, message}`; source that compiles can still
  fail on a later call.
  """
  @spec compile(String.t()) ::
          {:ok, (-> {:ok, Score.t()} | {:error, String.t()})} | {:error, String.t()}
  def compile(source) when is_binary(source) do
    case String.trim(source) do
      "" -> {:ok, fn -> {:ok, Score.new(beats: 0)} end}
      trimmed -> Source.run(fn -> build(trimmed) end)
    end
  end

  defp build(source) do
    wrapped = """
    use TuningFork.SonicPi
    fn -> #{source}
    end
    """

    case Code.eval_string(wrapped, [], file: "loop") do
      {body, _binding} when is_function(body, 0) -> {:ok, fn -> called(body) end}
      {other, _binding} -> {:error, "that gives #{inspect(other)}, not a score or a part"}
    end
  rescue
    error -> {:error, Source.one_line(Exception.message(error))}
  catch
    :exit, reason -> {:error, Source.one_line(inspect(reason))}
  end

  defp called(body) do
    Source.run(fn -> Blocks.run_round(body) end)
  rescue
    error -> {:error, Source.one_line(Exception.message(error))}
  catch
    :exit, reason -> {:error, Source.one_line(inspect(reason))}
  end

  @doc """
  Why `source` will not read, in one line, or `nil` when it reads.

  `parse/1` said the other way round, for a caller that only wants to report.
  """
  @spec fault(String.t()) :: String.t() | nil
  def fault(source) do
    case parse(source) do
      {:ok, _score} -> nil
      {:error, message} -> message
    end
  end

  @doc """
  Source a new, empty loop opens on: a four-beat drum part that plays as it stands.

      iex> {:ok, score} = TuningFork.Part.Source.parse(TuningFork.Part.Source.template())
      iex> TuningFork.Score.duration(score)
      2.0

  What `mix tuning_fork.loops` gives a loop made with `Ctrl+N`, and what the Livebook board's
  **+ loop** gives a new one.
  """
  @spec template() :: String.t()
  def template do
    "part(bpm: 120, synth: Kit.voice(\"bd\", 0.3))\n|> steps(\"x..x..x.\")"
  end

  @doc """
  What a loop may be written with, as lines of text.

  The vocabulary `parse/1` evaluates against. `TuningFork.LoopsApp.reference/0` puts the
  terminal's keys around it; the Livebook board shows it behind **?**.
  """
  @spec reference() :: [String.t()]
  def reference do
    [
      "Writing a loop the Sonic Pi way",
      "",
      "  use_bpm 120                  beats a minute for what follows",
      "  use_synth :tb303             beep saw dsaw square tb303 prophet pluck piano … (?)",
      "  play :e3, release: 0.5       a note: name, midi number or hertz",
      "  play chord(:e3, :minor)      every note at once; scale(:e3, :minor) is a scale",
      "  sample :bd_haus, rate: 0.5   a recording from the bank; rate, amp, pan, start, finish",
      "  sleep 0.5                    move on, in beats",
      "  rrand(0, 2) choose(list)     numbers from this round's own seed; rrand_i one_in dice",
      "  with_fx :reverb do … end     reverb echo slicer wobble lpf hpf distortion compressor …",
      "  in_thread do … end           alongside, without moving on",
      "  cue :go   sync :go           one loop waits for another",
      "",
      "Writing a loop — TuningFork.Part, imported already",
      "",
      "  part(bpm: 120, synth: Kit.voice(\"bd\", 0.3))",
      "  |> play(:c3, 1)              a note, and step the cursor on",
      "  |> rest(1)                   step the cursor without playing",
      "  |> chord([:c3, :e3, :g3], 2) every note at once",
      "  |> under(:e3)                stack a note without moving on",
      "  |> repeat(4, &bar/1)         a function applied four times over",
      "  |> maybe(0.3, &fill/1)       called sometimes, drawn from the part's own seed",
      "  |> gain(0.8) |> pan(-0.3)    level and stereo position",
      "  |> steps(\"x..x..x.\")         a beat pattern, x hits and . rests",
      "  |> at(4.0)                   put the cursor at an exact beat",
      "",
      "Something different each time round",
      "",
      "  tick()                       step this loop's counter, and give what it was",
      "  look()                       what the last tick gave, without stepping",
      "  Ring.at([:c2, :e2, :g2], n)  a list read round and round, so any count is a note",
      "  set(:key, :d_minor)          leave a value for another loop",
      "  get(:key, :c_major)          read one, as it stood when this round began",
      "",
      "Sounds — TuningFork.Kit, aliased already",
      "",
      "  Kit.voice(\"bd\", 0.3)                          a drum: bd sn hh cp …",
      "  Kit.voice(%{note: \"c2\", shape: :saw}, 0.4)    a synth: saw square sine tri",
      "",
      "Kit.voice/2 is what makes a sound worth hearing. A bare TuningFork.Voice is a raw",
      "oscillator at 440 Hz — a buzz, not a drum.",
      "",
      "A loop's source must come to a TuningFork.Score or a TuningFork.Part — a bare part is",
      "wrapped in a score automatically."
    ]
  end
end

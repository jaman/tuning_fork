defmodule TuningFork.SonicPi do
  @moduledoc """
  Sonic Pi's vocabulary: `play`, `sleep`, `sample`, `live_loop`, `with_fx` and the rest.

      use TuningFork.SonicPi

      live_loop :bells do
        sample :perc_bell, rate: rrand(0.125, 1.5)
        sleep rrand(0, 2)
      end
  """

  alias TuningFork.{
    Mixer,
    Part,
    Rand,
    Ring,
    Sample,
    Score,
    Stage,
    State,
    Store,
    Tick,
    Transport,
    Voice
  }

  alias TuningFork.Sample.Bank
  alias TuningFork.SonicPi.{Blocks, Current, Effects, Names, Synth, Thread}

  defmodule Handle do
    @moduledoc "A sounding note or an open effect, for `TuningFork.SonicPi.control/2`."
    @type t :: %__MODULE__{kind: :note | :fx, ref: reference()}
    defstruct [:kind, :ref]
  end

  defmodule Buffer do
    @moduledoc "What `TuningFork.SonicPi.run/1` reads out of a buffer of source."
    @type t :: %__MODULE__{score: Score.t() | nil, loops: [{atom(), Score.t(), (-> term())}]}
    defstruct score: nil, loops: []
  end

  defmacro __using__(_opts) do
    quote do
      import TuningFork.Part,
        except: [
          play: 2,
          play: 3,
          play: 4,
          chord: 2,
          chord: 3,
          chord: 4,
          pick: 2,
          pick: 3,
          synth: 2,
          at: 2
        ]

      import TuningFork.State, only: [set: 2, get: 1, get: 2]
      import TuningFork.SonicPi

      alias TuningFork.{
        Chord,
        Curve,
        Envelope,
        Filter,
        Kit,
        Notes,
        Ring,
        Sample,
        Scale,
        Score,
        Voice
      }
    end
  end

  @doc "Run `fun` as one round of a loop and give the score it played. See `TuningFork.SonicPi.Blocks.run_round/1`."
  @spec run_round((-> term())) :: {:ok, Score.t()} | {:error, String.t()}
  defdelegate run_round(fun), to: Blocks

  @doc """
  Read a buffer of Sonic Pi-shaped source.

  Top-level code becomes `score`, or `nil` when nothing was played at the top level; every
  `live_loop` becomes `{name, first_round, body}`, where `body` gives a fresh round each call
  as `TuningFork.Stage.start_loop/4` wants. `{:error, message}` when the source will not
  read or a loop will not run, naming the loop.
  """
  @spec run(String.t()) :: {:ok, Buffer.t()} | {:error, String.t()}
  def run(source) when is_binary(source) do
    capture(fn -> Code.eval_string("use TuningFork.SonicPi\n" <> source, [], file: "buffer") end)
  end

  @doc """
  Run `fun` as a buffer: what it plays at the top level becomes the score, and every
  `live_loop` it starts is collected. Returns what `run/1` returns.
  """
  @spec capture((-> term())) :: {:ok, Buffer.t()} | {:error, String.t()}
  def capture(fun) when is_function(fun, 0) do
    Current.within(Thread.new({nil, 0}, capture: true), fn ->
      with {:ok, thread} <- evaluate(fun),
           {:ok, loops} <- first_rounds(Enum.reverse(thread.loops)) do
        {:ok, %Buffer{score: top_score(thread), loops: loops}}
      end
    end)
  end

  defp top_score(thread) do
    case Thread.score(thread, :once) do
      {:ok, score} -> score
      {:error, _none} -> nil
    end
  end

  @doc """
  A block as a buffer: `buffer do … end` gives the `Buffer` for `render/4` or `play_buffer/2`.

  Raises `ArgumentError` when a loop in it will not run.
  """
  defmacro buffer(body) do
    {_opts, fun} = block([], body)

    quote do
      case TuningFork.SonicPi.capture(unquote(fun)) do
        {:ok, buffer} -> buffer
        {:error, message} -> raise ArgumentError, message
      end
    end
  end

  @doc """
  Start a buffer on a stage: its score once, and each of its loops round and round.

  Takes source or a `Buffer`. Returns `:ok`, or `{:error, message}` for source that will not
  read.
  """
  @spec play_buffer(String.t() | Buffer.t(), GenServer.server()) :: :ok | {:error, String.t()}
  def play_buffer(source, stage \\ Stage)

  def play_buffer(source, stage) when is_binary(source) do
    with {:ok, buffer} <- run(source), do: play_buffer(buffer, stage)
  end

  def play_buffer(%Buffer{} = buffer, stage) do
    if buffer.score, do: Stage.start_score(stage, buffer.score)

    Enum.each(buffer.loops, fn {name, first, body} ->
      Stage.start_loop(stage, name, first, body: body)
    end)

    :ok
  end

  @doc """
  Render a buffer to PCM for `seconds`, its loops going round and its score playing once.

  `opts` take `:channels`, default 2, and `:limit`, where peaks are rounded off as
  `TuningFork.Stage` does, default 0.7; `nil` for none. Raises `ArgumentError` for source that
  will not read.
  """
  @spec render(String.t() | Buffer.t(), pos_integer(), number(), keyword()) :: binary()
  def render(source, rate, seconds, opts \\ [])

  def render(source, rate, seconds, opts) when is_binary(source) do
    case run(source) do
      {:ok, buffer} -> render(buffer, rate, seconds, opts)
      {:error, message} -> raise ArgumentError, message
    end
  end

  def render(%Buffer{} = buffer, rate, seconds, opts) do
    channels = Keyword.get(opts, :channels, 2)
    looped = Transport.render_rounds(buffer.loops, rate, seconds, channels)

    mixed =
      case buffer.score do
        nil ->
          looped

        score ->
          Mixer.mix([
            looped,
            fitted(Score.render(score, rate, channels: channels), byte_size(looped))
          ])
      end

    case Keyword.get(opts, :limit, 0.7) do
      nil -> mixed
      threshold -> Mixer.soft_clip(mixed, threshold)
    end
  end

  @doc """
  Start a named loop that is worked out again every time round: `live_loop :name do … end`.

  Takes a `do` block or a `fn`, and an optional keyword list with `:stage`, `:delay` beats,
  `:sync` another loop's name, `:auto_cue`. On a stage this returns `:ok` or
  `{:error, message}`; inside `run/1` or `buffer/1` the loop is collected.
  """
  defmacro live_loop(name, opts \\ [], body) do
    {opts, fun} = block(opts, body)
    quote do: TuningFork.SonicPi.Blocks.live_loop(unquote(name), unquote(opts), unquote(fun))
  end

  @doc "Beats a minute for everything after this point in the thread. Default 60."
  @spec use_bpm(number()) :: :ok
  def use_bpm(bpm) when bpm > 0, do: Current.update(&%{&1 | bpm: bpm / 1.0})

  @doc "The synth `play/2` uses from here on: a name from `TuningFork.SonicPi.Synth.names/0` or a `TuningFork.Voice`."
  @spec use_synth(atom() | Voice.t()) :: :ok
  def use_synth(%Voice{} = voice), do: Current.update(&%{&1 | synth: voice})

  def use_synth(name) when is_atom(name) do
    if Synth.known?(name),
      do: Current.update(&%{&1 | synth: name}),
      else: raise(ArgumentError, "no synth named #{inspect(name)}")
  end

  @doc "Options every `play/2` from here on starts from. A `play` option overrides one here."
  @spec use_synth_defaults(keyword()) :: :ok
  def use_synth_defaults(opts), do: Current.update(&%{&1 | synth_defaults: opts})

  @doc "Options every `play/2` from here on starts from, merged over the ones there already."
  @spec use_merged_synth_defaults(keyword()) :: :ok
  def use_merged_synth_defaults(opts),
    do: Current.update(&%{&1 | synth_defaults: Keyword.merge(&1.synth_defaults, opts)})

  @doc "Options every `sample/2` from here on starts from."
  @spec use_sample_defaults(keyword()) :: :ok
  def use_sample_defaults(opts), do: Current.update(&%{&1 | sample_defaults: opts})

  @doc "Semitones added to every note from here on."
  @spec use_transpose(integer()) :: :ok
  def use_transpose(semitones), do: Current.update(&%{&1 | transpose: semitones})

  @doc "Seed the thread's generator, so what follows draws the same numbers every time."
  @spec use_random_seed(term()) :: :ok
  def use_random_seed(seed), do: Current.update(&%{&1 | rand: Rand.new(seed)})

  @doc "Accepted and ignored; there is no debug output to switch."
  @spec use_debug(boolean()) :: :ok
  def use_debug(_on), do: :ok

  @doc "Accepted and ignored; a loop cannot print."
  @spec puts(term()) :: :ok
  def puts(_term), do: :ok

  @doc "Accepted and ignored; a loop cannot print."
  @spec print(term()) :: :ok
  def print(_term), do: :ok

  @doc """
  Sound a note, or a `TuningFork.Part` note when the first argument is a part.

  `note` is a MIDI number, a name, hertz as a float, a list for a chord, or `nil` for
  nothing. `opts` are `TuningFork.SonicPi.Synth`'s. Returns a `Handle` for `control/2`.
  """
  @spec play(term(), keyword()) :: Handle.t()
  def play(note, opts \\ [])

  def play(%Part{} = part, note), do: Part.play(part, note)

  def play(note, opts) when is_list(note) do
    ref = make_ref()
    Enum.each(note, &sound(&1, opts, ref))
    %Handle{kind: :note, ref: ref}
  end

  def play(note, opts) do
    ref = make_ref()
    sound(note, opts, ref)
    %Handle{kind: :note, ref: ref}
  end

  @doc false
  def play(%Part{} = part, note, step), do: Part.play(part, note, step)

  @doc false
  def play(%Part{} = part, note, step, opts), do: Part.play(part, note, step, opts)

  @doc "Sound every note of `notes` at once."
  @spec play_chord([term()], keyword()) :: Handle.t()
  def play_chord(notes, opts \\ []), do: play(notes, opts)

  @doc "Sound `notes` one after another, a beat apart."
  @spec play_pattern([term()], keyword()) :: :ok
  def play_pattern(notes, opts \\ []), do: play_pattern_timed(notes, [1], opts)

  @doc """
  Sound `notes` one after another, each followed by the matching entry of `times` in beats.

  `times` is a list read round and round, or one number for every note.
  """
  @spec play_pattern_timed([term()], [number()] | number(), keyword()) :: :ok
  def play_pattern_timed(notes, times, opts \\ []) do
    times = List.wrap(times)

    notes
    |> Enum.with_index()
    |> Enum.each(fn {note, index} ->
      play(note, opts)
      sleep(Ring.at(times, index))
    end)
  end

  @doc "Sound a note with a named synth without changing the thread's, or set a part's synth."
  @spec synth(atom() | Part.t(), keyword() | Voice.t()) :: Handle.t() | Part.t()
  def synth(%Part{} = part, %Voice{} = voice), do: Part.synth(part, voice)

  def synth(name, opts) when is_atom(name) do
    {note, opts} = Keyword.pop(opts, :note, 52)
    was = Current.get().synth
    use_synth(name)
    node = play(note, opts)
    Current.update(&%{&1 | synth: was})
    node
  end

  @doc """
  Sound a recording: a name from `TuningFork.Sample.Bank`, a path, or a `TuningFork.Sample`.

  ## Options

    * `:rate` — speed and pitch together, 1 as recorded, negative backwards
    * `:rpitch` — the same as a number of semitones
    * `:beat_stretch` — a rate that makes it last this many beats
    * `:start`, `:finish` — the part to play, as fractions from 0 to 1
    * `:amp`, `:pan`, `:attack`, `:decay`, `:sustain`, `:release`, `:cutoff`, `:res` — as `play/2`

  Raises `ArgumentError` for a name the bank does not have.
  """
  @spec sample(atom() | String.t() | Sample.t(), keyword()) :: Handle.t()
  def sample(name, opts \\ []) do
    ref = make_ref()
    thread = Current.get()
    opts = Keyword.merge(thread.sample_defaults, opts)
    voice = sample_voice(recording(name), opts, thread)

    case live_stage(thread) do
      nil -> Current.update(&Thread.add(&1, voice, ref, amp: Keyword.get(opts, :amp, 1.0)))
      stage -> Stage.play(stage, voice)
    end

    %Handle{kind: :note, ref: ref}
  end

  @doc "How long `sample/2` would sound `name` for with `opts`, in seconds."
  @spec sample_duration(atom() | String.t() | Sample.t(), keyword()) :: float()
  def sample_duration(name, opts \\ []) do
    name |> recording() |> sample_voice(opts, Current.get()) |> Voice.duration()
  end

  @doc "Move the thread on by `beats`. Outside a round, with a stage running, this waits that long."
  @spec sleep(number()) :: :ok
  def sleep(beats) do
    thread = Current.get()

    case live_stage(thread) do
      nil -> Current.update(&Thread.sleep(&1, beats))
      _stage -> Process.sleep(max(round(Thread.seconds(thread, beats) * 1_000), 0))
    end
  end

  @doc "A float from `low` up to `high`, from the thread's generator; `res:` rounds it to a step."
  @spec rrand(number(), number(), keyword()) :: float()
  def rrand(low, high, opts \\ []) do
    value = Current.draw(&Rand.float(&1, low, high))

    case Keyword.get(opts, :res) do
      nil -> value
      step when step > 0 -> Float.round(value / step) * step
    end
  end

  @doc "A whole number from `low` to `high`, both included."
  @spec rrand_i(integer(), integer()) :: integer()
  def rrand_i(low, high), do: Current.draw(&Rand.int(&1, low, high))

  @doc "A float from 0 up to `max`, default 1; a range gives one between its ends."
  @spec rand(number() | Range.t()) :: float()
  def rand(max \\ 1.0)
  def rand(low..high//_step), do: rrand(low, high)
  def rand(max), do: Current.draw(&Rand.float(&1, 0, max))

  @doc "A whole number from 0 up to but not including `max`."
  @spec rand_i(pos_integer()) :: integer()
  def rand_i(max), do: Current.draw(&Rand.int(&1, 0, max - 1))

  @doc "One element of `list`, or a `TuningFork.Part` choice when the first argument is a part."
  @spec choose([term()]) :: term()
  def choose(list) when is_list(list), do: Current.draw(&Rand.pick(&1, list))

  @doc "True one time in `n`."
  @spec one_in(pos_integer()) :: boolean()
  def one_in(n), do: Current.draw(&Rand.one_in(&1, n))

  @doc "A whole number from 1 to `sides`, default 6."
  @spec dice(pos_integer()) :: integer()
  def dice(sides \\ 6), do: rrand_i(1, sides)

  @doc "`list` in a random order."
  @spec shuffle([term()]) :: [term()]
  def shuffle(list) when is_list(list), do: Current.draw(&Rand.shuffle(&1, list))

  @doc "`count` independent choices from `list`, or a `TuningFork.Part` pick when the first argument is a part."
  @spec pick([term()] | Part.t(), non_neg_integer() | [term()]) :: [term()] | {[term()], Part.t()}
  def pick(%Part{} = part, list), do: Part.pick(part, list)
  def pick(list, count) when is_list(list), do: Current.draw(&Rand.take(&1, list, count))

  @doc false
  def pick(%Part{} = part, list, count), do: Part.pick(part, list, count)

  @doc "A list, read round and round by `tick/1`, `look/1` and `ring_at/2`."
  @spec ring([term()]) :: [term()]
  def ring(list) when is_list(list), do: list

  @doc "The element of `list` at `index`, wrapping in both directions."
  @spec ring_at([term()], integer()) :: term()
  def ring_at(list, index), do: Ring.at(list, index)

  @doc """
  Step a counter and give what it was, or the element of a list that count picks.

  `tick()` and `tick(:name)` are `TuningFork.Tick`'s; `tick(list)` reads `list` at the default
  counter's count and `tick(list, :name)` at a named one.
  """
  @spec tick() :: non_neg_integer()
  def tick, do: Tick.tick()

  @spec tick([term()] | atom()) :: term()
  def tick(list) when is_list(list), do: Ring.at(list, Tick.tick())
  def tick(name) when is_atom(name), do: Tick.tick(name)

  @spec tick([term()], atom()) :: term()
  def tick(list, name) when is_list(list), do: Ring.at(list, Tick.tick(name))

  @doc "What the last `tick` gave, without stepping: `look()`, `look(:name)`, `look(list)`."
  @spec look() :: non_neg_integer()
  def look, do: last(Tick.look())

  @spec look([term()] | atom()) :: term()
  def look(list) when is_list(list), do: Ring.at(list, last(Tick.look()))
  def look(name) when is_atom(name), do: last(Tick.look(name))

  @spec look([term()], atom()) :: term()
  def look(list, name) when is_list(list), do: Ring.at(list, last(Tick.look(name)))

  @doc "Put the default counter, or the named one, back to zero."
  @spec tick_reset(atom() | nil) :: :ok
  def tick_reset(name \\ nil), do: Tick.reset(name)

  @doc "Put every counter back to zero."
  @spec tick_reset_all() :: :ok
  def tick_reset_all, do: Tick.reset(:all)

  @doc "Put a counter at `count`, so `look` gives `count` and the next `tick` gives one more."
  @spec tick_set(atom() | nil, non_neg_integer()) :: :ok
  def tick_set(name \\ nil, count), do: Tick.set(name, count + 1)

  @doc "The notes of a chord — `chord(:e3, :minor)` — or a `TuningFork.Part` chord when the first argument is a part."
  @spec chord(term(), atom() | String.t() | [term()], keyword() | number()) :: [term()] | Part.t()
  def chord(root, name, opts \\ [])
  def chord(%Part{} = part, notes, step), do: Part.chord(part, notes, step)
  def chord(root, name, opts), do: Names.chord(root, name, opts)

  @doc false
  def chord(%Part{} = part, notes, step, opts), do: Part.chord(part, notes, step, opts)

  @doc "The notes of a scale, one octave up from `root` and the octave note above."
  @spec scale(term(), atom() | String.t(), keyword()) :: [term()]
  def scale(root, name, opts \\ []), do: Names.scale(root, name, opts)

  @doc "The MIDI number of a note, or `nil` for `nil`; `octave:` moves it to that octave."
  @spec note(term(), keyword()) :: number() | nil
  def note(value, opts \\ []), do: Names.midi(value, opts)

  @doc "A chord on the `degree`th note of a scale: `count` notes, every other step. `invert:` as `chord/3`."
  @spec chord_degree(integer(), term(), atom(), pos_integer(), keyword()) :: [integer()]
  def chord_degree(degree, tonic, scale_name, count \\ 4, opts \\ []),
    do: Names.chord_degree(degree, tonic, scale_name, count, opts)

  @doc "Whether `number` divides by `factor` exactly."
  @spec factor?(number(), number()) :: boolean()
  def factor?(number, factor), do: factor != 0 and rem(round(number), round(factor)) == 0

  @doc "Hertz for a MIDI number."
  @spec midi_to_hz(number()) :: float()
  def midi_to_hz(midi), do: Names.midi_to_hz(midi)

  @doc "A MIDI number for hertz."
  @spec hz_to_midi(number()) :: float()
  def hz_to_midi(hz), do: Names.hz_to_midi(hz)

  @doc "The `degree`th note of `scale_name` from `tonic`, counting from 1."
  @spec degree(integer(), term(), atom()) :: term()
  def degree(degree, tonic, scale_name), do: Names.degree(degree, tonic, scale_name)

  @doc "`root` and the same note in the `count - 1` octaves above, as MIDI numbers."
  @spec octs(term(), pos_integer()) :: [integer()]
  def octs(root, count) do
    for octave <- 0..(count - 1), do: Names.midi(root) + 12 * octave
  end

  @doc """
  Numbers from `from` up to but not including `to`, `step` apart.

  A negative `step` counts down. `step` may also be a keyword list: `step: 0.5`, or
  `steps: 8` for eight numbers evenly spaced.
  """
  @spec range(number(), number(), number() | keyword()) :: [number()]
  def range(from, to, step \\ 1)

  def range(from, to, opts) when is_list(opts) do
    case Keyword.fetch(opts, :steps) do
      {:ok, steps} -> range(from, to, (to - from) / steps)
      :error -> range(from, to, Keyword.get(opts, :step, 1))
    end
  end

  def range(from, to, step) when step > 0 and from < to do
    from |> Stream.iterate(&(&1 + step)) |> Enum.take_while(&(&1 < to))
  end

  def range(from, to, step) when step < 0 and from > to do
    from |> Stream.iterate(&(&1 + step)) |> Enum.take_while(&(&1 > to))
  end

  def range(_from, _to, _step), do: []

  @doc "`steps` numbers from `from` towards `to`, excluding `to` unless `inclusive: true`."
  @spec line(number(), number(), keyword()) :: [float()]
  def line(from, to, opts \\ []) do
    steps = Keyword.get(opts, :steps, 8)
    divisor = if Keyword.get(opts, :inclusive, false), do: max(steps - 1, 1), else: steps

    for index <- 0..(steps - 1), do: from + (to - from) * index / divisor
  end

  @doc "Values repeated: `knit(:a, 2, :b, 1)` is `[:a, :a, :b]`."
  @spec knit(
          term(),
          non_neg_integer(),
          term(),
          non_neg_integer(),
          term(),
          non_neg_integer(),
          term(),
          non_neg_integer()
        ) :: [term()]
  def knit(a, na, b \\ nil, nb \\ 0, c \\ nil, nc \\ 0, d \\ nil, nd \\ 0) do
    List.duplicate(a, na) ++
      List.duplicate(b, nb) ++ List.duplicate(c, nc) ++ List.duplicate(d, nd)
  end

  @doc "`hits` beats spread as evenly as they go over `steps`, as booleans — a Euclidean rhythm."
  @spec spread(non_neg_integer(), pos_integer()) :: [boolean()]
  def spread(hits, steps) do
    for index <- 0..(steps - 1), do: rem(index * hits, steps) < hits
  end

  @doc "Numbers as booleans: zero is false."
  @spec bools(number(), number(), number(), number(), number(), number(), number(), number()) :: [
          boolean()
        ]
  def bools(a, b \\ :none, c \\ :none, d \\ :none, e \\ :none, f \\ :none, g \\ :none, h \\ :none) do
    [a, b, c, d, e, f, g, h] |> Enum.reject(&(&1 == :none)) |> Enum.map(&(&1 != 0))
  end

  @doc "`list` followed by itself backwards without repeating the last element."
  @spec mirror([term()]) :: [term()]
  def mirror(list), do: list ++ (list |> Enum.reverse() |> tl())

  @doc "`list` followed by itself backwards."
  @spec reflect([term()]) :: [term()]
  def reflect(list), do: list ++ Enum.reverse(list)

  @doc "`list` with its first `count` elements moved to the end."
  @spec rotate([term()], integer()) :: [term()]
  def rotate(list, count \\ 1), do: Ring.from(list, count)

  @doc "Each element of `list` repeated `count` times in place."
  @spec stretch([term()], pos_integer()) :: [term()]
  def stretch(list, count), do: Enum.flat_map(list, &List.duplicate(&1, count))

  @doc "Run a block alongside: `in_thread do … end`. It starts now and the thread's own time does not move. Options such as `name:` are accepted and ignored."
  defmacro in_thread(opts \\ [], body) do
    {_opts, fun} = block(opts, body)
    quote do: TuningFork.SonicPi.Blocks.in_thread(unquote(fun))
  end

  @doc "A loop with no name: `loop do … end`, the same as `live_loop` under a name of its own."
  defmacro loop(body) do
    {_opts, fun} = block([], body)
    quote do: TuningFork.SonicPi.Blocks.loop(unquote(fun))
  end

  @doc "Run a block as it is: `uncomment do … end`."
  defmacro uncomment(body) do
    {_opts, fun} = block([], body)
    quote do: unquote(fun).()
  end

  @doc "Skip a block: `comment do … end`."
  defmacro comment(body) do
    {_opts, _fun} = block([], body)
    quote do: :ok
  end

  @doc """
  Run a block `time` beats from now, alongside: `at 4 do … end`, or `at [1, 2], [:a, :b], fn arg -> … end`
  to run it at each time with the matching argument. On a `TuningFork.Part`, `at/2` is the part's.
  """
  defmacro at(times, args \\ [], body) do
    {args, fun} = block(args, body)

    quote do
      TuningFork.SonicPi.at_or_part(unquote(times), unquote(args), unquote(fun))
    end
  end

  @doc false
  def at_or_part(%Part{} = part, beat, []), do: Part.at(part, beat)
  def at_or_part(times, args, fun), do: Blocks.at(times, args, fun)

  @doc """
  Run a block with everything it plays going through an effect: `with_fx :reverb, mix: 0.3 do … end`.

  `name` is one of `fx_names/0`. A `fn` taking one argument is given the effect's `Handle`,
  for `control/2`.
  """
  defmacro with_fx(name, opts \\ [], body) do
    {opts, fun} = block(opts, body)
    quote do: TuningFork.SonicPi.Blocks.with_fx(unquote(name), unquote(opts), unquote(fun))
  end

  @doc """
  Change a sounding note or an open effect from this moment on.

  On a note, `:note`, `:amp` and `:cutoff` move to the new value — at once, or over
  `:note_slide`, `:amp_slide` or `:cutoff_slide` seconds. On an effect, the options given
  replace the ones it was opened with for everything played afterwards.
  """
  @spec control(Handle.t(), keyword()) :: :ok
  def control(%Handle{kind: :note, ref: ref}, opts),
    do: Current.update(&Thread.control_note(&1, ref, opts))

  def control(%Handle{kind: :fx, ref: ref}, opts),
    do: Current.update(&Thread.control_fx(&1, ref, opts))

  @doc "Run a block `count` times at `count` times the tempo: `density 2 do … end`."
  defmacro density(count, body) do
    {_opts, fun} = block([], body)
    quote do: TuningFork.SonicPi.Blocks.density(unquote(count), unquote(fun))
  end

  @doc "Run a block at `bpm`, then go back to the tempo before: `with_bpm 120 do … end`."
  defmacro with_bpm(bpm, body) do
    {_opts, fun} = block([], body)
    quote do: TuningFork.SonicPi.Blocks.with_bpm(unquote(bpm), unquote(fun))
  end

  @doc "Run a block with another synth, then go back: `with_synth :saw do … end`."
  defmacro with_synth(synth, body) do
    {_opts, fun} = block([], body)
    quote do: TuningFork.SonicPi.Blocks.with_synth(unquote(synth), unquote(fun))
  end

  @doc "Run a block transposed by `semitones`, then go back: `with_transpose 12 do … end`."
  defmacro with_transpose(semitones, body) do
    {_opts, fun} = block([], body)
    quote do: TuningFork.SonicPi.Blocks.with_transpose(unquote(semitones), unquote(fun))
  end

  @doc "Run a block with other synth defaults, then go back."
  defmacro with_synth_defaults(opts, body) do
    {_opts, fun} = block([], body)
    quote do: TuningFork.SonicPi.Blocks.with_synth_defaults(unquote(opts), unquote(fun))
  end

  @doc "Run a block with the generator seeded from `seed`, then carry on from where it was."
  defmacro with_random_seed(seed, body) do
    {_opts, fun} = block([], body)
    quote do: TuningFork.SonicPi.Blocks.with_random_seed(unquote(seed), unquote(fun))
  end

  @doc "Run a block `count` times: `times 4 do … end`, or `times(4, fn pass -> … end)` to be told which pass."
  defmacro times(count, body) do
    {_opts, fun} = block([], body)
    quote do: TuningFork.SonicPi.Blocks.times(unquote(count), unquote(fun))
  end

  @doc "End the round here. Nothing after it is played."
  @spec stop() :: no_return()
  def stop, do: throw({:sonic_pi, :stop})

  @doc "Tell every loop that `name` has happened, as of this round, with `data` for `sync/1` to read."
  @spec cue(atom(), keyword()) :: :ok
  def cue(name, data \\ []) do
    State.set({:cue, name}, data)
    :ok
  end

  @doc """
  Wait for `name` to have been cued, and give what it was cued with.

  Once it has, this returns at once. Until then the round is given up with
  `{:error, "waiting for name"}`, and the loop tries again next time round.
  """
  @spec sync(atom()) :: keyword()
  def sync(name) do
    case State.get({:cue, name}) do
      nil -> throw({:sonic_pi, :waiting, name})
      data -> data
    end
  end

  @doc "Every bank sample name, or those in one family: `sample_names(:ambi)`."
  @spec sample_names(atom() | nil) :: [atom()]
  def sample_names(family \\ nil) do
    Bank.names()
    |> Enum.filter(fn name -> is_nil(family) or String.starts_with?(name, "#{family}_") end)
    |> Enum.map(&String.to_atom/1)
  end

  @doc "Read a sample into memory ahead of playing it. A family atom loads the whole family."
  @spec load_sample(atom() | String.t()) :: :ok
  def load_sample(name) do
    if Bank.has?(name), do: Bank.fetch(name), else: Enum.each(sample_names(name), &Bank.fetch/1)
    :ok
  end

  @doc "`load_sample/1` for each of a list, or for one."
  @spec load_samples([atom()] | atom()) :: :ok
  def load_samples(names), do: names |> List.wrap() |> Enum.each(&load_sample/1)

  @doc "Set the tempo so that `name` lasts `num_beats:` beats, default 1."
  @spec use_sample_bpm(atom() | String.t() | Sample.t(), keyword()) :: :ok
  def use_sample_bpm(name, opts \\ []) do
    beats = Keyword.get(opts, :num_beats, 1)
    use_bpm(60.0 * beats / Sample.duration(recording(name)))
  end

  @doc "Silence a stage: every loop, pattern and sounding voice stopped. `TuningFork.Stage` by default."
  @spec hush(GenServer.server()) :: :ok
  def hush(stage \\ Stage) do
    Stage.stop_loops(stage)
    Stage.stop_pattern(stage)
    Stage.stop_all(stage)
  end

  @doc "The `TuningFork.SonicPi.Effects` names, for `with_fx/3`."
  @spec fx_names() :: [atom()]
  def fx_names, do: Effects.names()

  @doc "The `TuningFork.SonicPi.Synth` names, for `use_synth/1`."
  @spec synth_names() :: [atom()]
  def synth_names, do: Synth.names()

  defp sound(nil, _opts, _ref), do: :ok

  defp sound(note, opts, ref) do
    thread = Current.get()
    opts = Keyword.merge(thread.synth_defaults, opts)
    midi = Names.midi(note) + thread.transpose
    voices = Synth.voice(thread.synth, Names.midi_to_hz(midi), opts)

    case live_stage(thread) do
      nil ->
        Current.update(
          &Thread.add(&1, voices, ref, midi: midi, amp: Keyword.get(opts, :amp, 1.0))
        )

      stage ->
        voices |> List.wrap() |> Enum.each(&Stage.play(stage, &1))
    end
  end

  defp live_stage(%Thread{ambient: true}), do: Process.whereis(Stage)
  defp live_stage(_thread), do: nil

  defp recording(%Sample{} = sample), do: sample

  defp recording(name) when is_atom(name) do
    case Bank.fetch(name) do
      {:ok, sample} -> sample
      :error -> raise ArgumentError, "no sample named #{inspect(name)}"
    end
  end

  defp recording(path) when is_binary(path) do
    case Bank.fetch(path) do
      {:ok, sample} ->
        sample

      :error ->
        if Bank.has?(path) do
          raise ArgumentError, "#{path} will not read as a sample"
        else
          Bank.put(path, path)
          recording(path)
        end
    end
  end

  defp sample_voice(sample, opts, thread) do
    rooted = %{sample | root: sample.root || 440.0}
    sliced = slice(rooted, opts)
    rate = rate(sliced, opts, thread)
    played = if rate < 0, do: Sample.reverse(sliced), else: sliced

    opts = opts |> renamed(:lpf, :cutoff) |> renamed(:hpf, :highpass_note)

    Voice.new(sample: played, freq: rooted.root * abs(rate))
    |> enveloped(opts)
    |> then(
      &Synth.voice(
        &1,
        &1.freq,
        Keyword.drop(opts, [:attack, :decay, :sustain, :release, :sustain_level])
      )
    )
  end

  defp renamed(opts, from, to) do
    case Keyword.fetch(opts, from) do
      {:ok, value} -> Keyword.put_new(opts, to, value)
      :error -> opts
    end
  end

  defp slice(sample, opts) do
    start = opts |> Keyword.get(:start, 0.0) |> min(1.0) |> max(0.0)
    finish = opts |> Keyword.get(:finish, 1.0) |> min(1.0) |> max(0.0)

    if start == 0.0 and finish == 1.0 do
      sample
    else
      {from, to} = {min(start, finish), max(start, finish)}
      seconds = Sample.duration(sample)
      Sample.slice(sample, from * seconds, (to - from) * seconds)
    end
  end

  defp rate(sample, opts, thread) do
    base = Keyword.get(opts, :rate, 1.0) / 1.0
    pitched = base * :math.pow(2.0, Keyword.get(opts, :rpitch, 0) / 12.0)

    case Keyword.get(opts, :beat_stretch) do
      nil -> pitched
      beats -> pitched * Sample.duration(sample) / Thread.seconds(thread, beats)
    end
  end

  defp enveloped(voice, opts) do
    fitted = voice.envelope
    whole = TuningFork.Envelope.duration(fitted)
    attack = Keyword.get(opts, :attack, fitted.attack) / 1.0
    decay = Keyword.get(opts, :decay, fitted.decay) / 1.0
    release = Keyword.get(opts, :release, fitted.release) / 1.0

    envelope =
      TuningFork.Envelope.new(
        attack: attack,
        decay: decay,
        sustain: Keyword.get(opts, :sustain_level, fitted.sustain) / 1.0,
        hold: Keyword.get(opts, :sustain, max(whole - attack - decay - release, 0.0)) / 1.0,
        release: release
      )

    %{voice | envelope: envelope}
  end

  defp block(opts, body) do
    cond do
      do_block?(body) -> {Keyword.merge(opts, Keyword.delete(body, :do)), as_fun(body[:do])}
      do_block?(opts) -> {Keyword.delete(opts, :do), as_fun(opts[:do])}
      true -> {opts, body}
    end
  end

  defp do_block?(ast), do: Keyword.keyword?(ast) and Keyword.has_key?(ast, :do)

  defp as_fun(block), do: quote(do: fn -> unquote(block) end)

  defp evaluate(fun) do
    fun.()
    {:ok, Current.get()}
  rescue
    error -> {:error, TuningFork.Source.one_line(Exception.message(error))}
  catch
    {:sonic_pi, :stop} -> {:ok, Current.get()}
    {:sonic_pi, :waiting, name} -> {:error, "waiting for #{inspect(name)}"}
    :exit, reason -> {:error, TuningFork.Source.one_line(inspect(reason))}
  end

  defp first_rounds(loops) do
    Enum.reduce_while(loops, {:ok, []}, fn loop, {:ok, acc} ->
      case first_round(loop) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp first_round({name, fun, inherited, delay}) do
    body = fn -> Blocks.run_round(fun, inherited) end

    case Store.as(name, 0, fn -> Blocks.first_round(fun, inherited, delay) end) do
      {:ok, first} -> {:ok, {name, first, body}}
      {:error, "waiting for" <> _rest} -> {:ok, {name, Score.new(bpm: 60, beats: 1), body}}
      {:error, message} -> {:error, "#{inspect(name)}: #{message}"}
    end
  end

  defp last(count), do: max(count - 1, 0)

  defp fitted(pcm, size) when byte_size(pcm) >= size, do: binary_part(pcm, 0, size)
  defp fitted(pcm, size), do: pcm <> :binary.copy(<<0>>, size - byte_size(pcm))
end

defmodule TuningFork.SonicPi.Blocks do
  @moduledoc "The words of `TuningFork.SonicPi` that take a block, as functions taking a `fn`."

  alias TuningFork.{Part, Rand, Score, Stage, Store, Voice}
  alias TuningFork.SonicPi.{Current, Handle, Synth, Thread}

  @doc """
  Run `fun` as one round of a loop and give the score it played.

  `{:ok, score}` in seconds at 60 bpm, as long as the round's sleeps. `{:error, message}` when
  the round never slept, was waiting on a `sync`, or returned something that is neither a
  `TuningFork.Part` nor a `TuningFork.Score` while playing nothing. A round that returns a
  part or a score gives that instead.
  """
  @spec run_round((-> term()), map()) :: {:ok, Score.t()} | {:error, String.t()}
  def run_round(fun, inherited \\ %{}) when is_function(fun, 0) do
    Current.within(Map.merge(Thread.new({Store.loop(), Store.at()}), inherited), fn ->
      result =
        try do
          {:returned, fun.()}
        catch
          {:sonic_pi, :stop} -> :stopped
          {:sonic_pi, :waiting, name} -> {:waiting, name}
        end

      case {result, Current.get()} do
        {{:waiting, name}, _thread} ->
          {:error, "waiting for #{inspect(name)}"}

        {{:returned, %Score{} = score}, %Thread{events: []}} ->
          {:ok, score}

        {{:returned, %Part{} = part}, %Thread{events: []}} ->
          {:ok, Score.from_parts([part], beats: Part.beats(part))}

        {{:returned, other}, %Thread{events: [], now: now}} when now <= 0.0 ->
          {:error, "that gives #{inspect(other)}, not a score or a part"}

        {_result, thread} ->
          Thread.score(thread)
      end
    end)
  end

  @doc """
  Start `fun` as loop `name` on a stage, worked out again every time round.

  `:ok` once it is started, or `{:error, message}` when the first round will not run. Inside
  `TuningFork.SonicPi.run/1` the loop is collected instead and `:collected` is returned.
  `opts` may name a `:stage`, default `TuningFork.Stage`.
  """
  @spec live_loop(atom(), keyword(), (-> term())) :: :ok | {:error, String.t()} | :collected
  def live_loop(name, opts, fun) when is_function(fun, 0) do
    thread = Current.get()
    inherited = settings(thread)
    delay = Thread.seconds(thread, max(Keyword.get(opts, :delay, 0), 0))
    fun = cued(name, opts, fun)

    if thread.capture do
      Current.update(&%{&1 | loops: [{name, fun, inherited, delay} | &1.loops]})
      :collected
    else
      stage = Keyword.get(opts, :stage, Stage)

      unless GenServer.whereis(stage) do
        raise ArgumentError,
              "no stage is running for live_loop #{inspect(name)} — start one with TuningFork.Stage.start_link/1 or KinoTuningFork.stage/0"
      end

      with {:ok, first} <- first_round(fun, inherited, delay) do
        Stage.start_loop(stage, name, first, body: fn -> run_round(fun, inherited) end)
      end
    end
  end

  @doc "Start `fun` as a loop named `loop_N`, the way `live_loop/3` does."
  @spec loop((-> term())) :: :ok | {:error, String.t()} | :collected
  def loop(fun) when is_function(fun, 0) do
    live_loop(
      String.to_atom(
        "loop_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
      ),
      [auto_cue: false],
      fun
    )
  end

  @doc "Run `fun` alongside: it starts now and the thread's own time does not move."
  @spec in_thread((-> term())) :: :ok
  def in_thread(fun) when is_function(fun, 0) do
    %Thread{now: now, rand: rand} = Current.get()
    fun.()
    Current.update(&%{&1 | now: now, rand: rand})
  end

  @doc """
  Run `fun` with everything it plays going through effect `name` with `opts`.

  `fun` may take the effect's `TuningFork.SonicPi.Handle`, for `TuningFork.SonicPi.control/2`.
  """
  @spec with_fx(atom(), keyword(), (-> term()) | (Handle.t() -> term())) :: term()
  def with_fx(name, opts, fun) when is_function(fun) do
    {reps, opts} = Keyword.pop(opts, :reps, 1)
    {id, thread} = Thread.open_fx(Current.get(), name, opts)
    Current.put(thread)
    handle = %Handle{kind: :fx, ref: id}

    result =
      Enum.reduce(1..reps//1, nil, fn _pass, _last ->
        if is_function(fun, 1), do: fun.(handle), else: fun.()
      end)

    Current.update(&Thread.close_fx(&1, id))
    result
  end

  @doc "Run `fun` `count` times at `count` times the tempo, so the passes fit the time one took."
  @spec density(pos_integer(), (-> term())) :: :ok
  def density(count, fun) when is_function(fun, 0) do
    %Thread{bpm: bpm} = Current.get()
    Current.update(&%{&1 | bpm: bpm * count})
    Enum.each(1..count//1, fn _pass -> fun.() end)
    Current.update(&%{&1 | bpm: bpm})
  end

  @doc "Run `fun` at `bpm`, then go back to the tempo before."
  @spec with_bpm(number(), (-> result)) :: result when result: term()
  def with_bpm(bpm, fun), do: scoped(:bpm, bpm / 1.0, fun)

  @doc "Run `fun` with `synth` as the synth, then go back to the one before."
  @spec with_synth(atom() | Voice.t(), (-> result)) :: result when result: term()
  def with_synth(synth, fun) do
    unless match?(%Voice{}, synth) or Synth.known?(synth),
      do: raise(ArgumentError, "no synth named #{inspect(synth)}")

    scoped(:synth, synth, fun)
  end

  @doc "Run `fun` transposed by `semitones`, then go back."
  @spec with_transpose(integer(), (-> result)) :: result when result: term()
  def with_transpose(semitones, fun), do: scoped(:transpose, semitones, fun)

  @doc "Run `fun` with `opts` as the synth defaults, then go back."
  @spec with_synth_defaults(keyword(), (-> result)) :: result when result: term()
  def with_synth_defaults(opts, fun), do: scoped(:synth_defaults, opts, fun)

  @doc "Run `fun` with the generator seeded from `seed`, then carry on from where it was."
  @spec with_random_seed(term(), (-> result)) :: result when result: term()
  def with_random_seed(seed, fun), do: scoped(:rand, Rand.new(seed), fun)

  @doc "Run `fun` `count` times, passing which pass it is from zero when it takes an argument."
  @spec times(non_neg_integer(), (-> term()) | (non_neg_integer() -> term())) :: :ok
  def times(count, fun) when is_function(fun, 1), do: Enum.each(0..(count - 1)//1, fun)

  def times(count, fun) when is_function(fun, 0),
    do: Enum.each(0..(count - 1)//1, fn _pass -> fun.() end)

  @doc "The settings a loop started inside `thread` inherits: tempo, synth, defaults, transposition and open effects."
  @spec settings(Thread.t()) :: map()
  def settings(%Thread{} = thread),
    do:
      Map.take(thread, [
        :bpm,
        :synth,
        :synth_defaults,
        :sample_defaults,
        :transpose,
        :fx_stack,
        :fx,
        :segments
      ])

  @doc """
  The first round of a loop: `delay` seconds of silence when there is a delay, else the round itself.
  """
  @spec first_round((-> term()), map(), number()) :: {:ok, Score.t()} | {:error, String.t()}
  def first_round(_fun, _inherited, delay) when delay > 0,
    do: {:ok, Score.new(bpm: 60, beats: delay)}

  def first_round(fun, inherited, _delay), do: run_round(fun, inherited)

  @doc "Run `fun` once for each of `times`, each `time` beats from now, alongside the thread."
  @spec at([number()] | number(), [term()], (-> term()) | (term() -> term())) :: :ok
  def at(times, args, fun) do
    args = List.wrap(args)

    times
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.each(fn {time, index} ->
      in_thread(fn -> later(time, fun, Enum.at(args, index)) end)
    end)
  end

  defp later(time, fun, arg) do
    TuningFork.SonicPi.sleep(time)
    if is_function(fun, 1), do: fun.(arg), else: fun.()
  end

  defp cued(name, opts, fun) do
    fun =
      if Keyword.get(opts, :auto_cue, true),
        do: fn ->
          TuningFork.SonicPi.cue(name)
          fun.()
        end,
        else: fun

    case Keyword.get(opts, :sync) do
      nil ->
        fun

      other ->
        fn ->
          TuningFork.SonicPi.sync(other)
          fun.()
        end
    end
  end

  defp scoped(field, value, fun) do
    was = Map.fetch!(Current.get(), field)
    Current.update(&Map.put(&1, field, value))

    try do
      fun.()
    after
      Current.update(&Map.put(&1, field, was))
    end
  end
end

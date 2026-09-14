defmodule KinoTuningFork.LiveLoopsCell do
  @moduledoc """
  A live-coding smart cell: a board of named loops on a stage of its own, heard in the
  browser as they play.
  """

  use Kino.JS
  use Kino.JS.Live
  use Kino.SmartCell, name: "TF Loops — live coding, Sonic Pi style"

  alias TuningFork.{Part, Score, Stage, Store}

  @rate 44_100
  @channels 2
  @chunk 2_048
  @tick_ms 250

  @doc """
  The board a fresh cell opens on: a four-beat kick and a four-beat bass, as a list of
  `%{"name" => name, "source" => source}`.
  """
  @spec demo() :: [map()]
  def demo do
    [
      %{
        "name" => "drums",
        "source" => """
        part(bpm: 120, synth: Kit.voice("bd", 0.3))
        |> steps("x...x...x...x...")\
        """
      },
      %{
        "name" => "bass",
        "source" => """
        part(bpm: 120, synth: Kit.voice(%{note: "c2", shape: :saw}, 0.4))
        |> play(:c2, 2) |> play(:g2, 2)\
        """
      }
    ]
  end

  @impl true
  def init(attrs, ctx) do
    {:ok, assign(ctx, loops: attrs["loops"] || demo(), stage: nil, running: [])}
  end

  @impl true
  def handle_connect(ctx) do
    {:ok,
     %{
       loops: ctx.assigns.loops,
       rate: @rate,
       channels: @channels,
       template: Part.Source.template(),
       reference: Enum.join(Part.Source.reference(), "\n")
     }, ctx}
  end

  @impl true
  def handle_event("update_loops", %{"loops" => loops}, ctx) do
    {:noreply, assign(ctx, loops: loops)}
  end

  def handle_event("evaluate", %{"loops" => loops}, ctx) do
    ctx = assign(ctx, loops: loops)
    {errors, scores} = read_loops(loops)
    ctx = ctx |> with_stage() |> take_over(scores)

    broadcast_event(ctx, "evaluated", %{errors: errors, playing: scores != []})

    {:noreply, ctx}
  end

  def handle_event("stop", _payload, ctx) do
    if ctx.assigns.stage, do: Stage.stop_loops(ctx.assigns.stage)

    {:noreply, assign(ctx, running: [])}
  end

  @impl true
  def handle_info({:pcm, chunk}, ctx) do
    broadcast_event(ctx, "pcm", {:binary, %{}, chunk})
    {:noreply, ctx}
  end

  def handle_info(:tick, ctx) do
    Process.send_after(self(), :tick, @tick_ms)

    if ctx.assigns.stage do
      broadcast_event(ctx, "readouts", %{readouts: readouts(ctx.assigns.stage)})
    end

    {:noreply, ctx}
  end

  defp with_stage(%{assigns: %{stage: nil}} = ctx) do
    {:ok, stage} =
      Stage.start_link(
        name: nil,
        sink: KinoTuningFork.Sink,
        sink_opts: [owner: self()],
        rate: @rate,
        channels: @channels,
        chunk: @chunk
      )

    Process.send_after(self(), :tick, @tick_ms)
    assign(ctx, stage: stage)
  end

  defp with_stage(ctx), do: ctx

  defp take_over(ctx, scores) do
    stage = ctx.assigns.stage
    names = Enum.map(scores, &elem(&1, 0))

    Enum.each(ctx.assigns.running -- names, &Stage.stop_loop(stage, &1))

    Enum.each(scores, fn {name, score, body} ->
      Stage.start_loop(stage, name, score, body: body, at: :round)
    end)

    assign(ctx, running: names)
  end

  @doc """
  Read every loop on the board, as `{errors, scores}`.

  `loops` is a list of `%{"name" => name, "source" => source}`. Each score is
  `{name, score, body}` where `body` is the zero-arity function the source compiled to. An
  error is `%{loop: index, error: message}`. A loop with a blank name or blank source is
  skipped rather than reported.
  """
  @spec read_loops([map()]) :: {[map()], [{String.t(), Score.t(), (-> term())}]}
  def read_loops(loops) do
    loops
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {loop, index}, {errors, scores} ->
      name = String.trim(Map.get(loop, "name") || "")

      case {name, compiled(name, Map.get(loop, "source"))} do
        {"", _read} -> {errors, scores}
        {_name, {:error, "no source"}} -> {errors, scores}
        {name, {:ok, score, body}} -> {errors, [{name, score, body} | scores]}
        {_name, {:error, message}} -> {[%{loop: index, error: message} | errors], scores}
      end
    end)
    |> then(fn {errors, scores} -> {Enum.reverse(errors), Enum.reverse(scores)} end)
  end

  defp compiled(name, source) do
    with {:ok, body} <- eval_body(source),
         {:ok, score} <- Store.as(name, 0, body) do
      {:ok, score, body}
    end
  end

  defp eval_body(source) do
    case String.trim(source || "") do
      "" -> {:error, "no source"}
      trimmed -> Part.Source.compile(trimmed)
    end
  end

  defp readouts(stage) do
    stage
    |> Stage.loops()
    |> Enum.map(fn {name, %{beat: beat, rounds: rounds, pending?: pending?}} ->
      %{name: name, beat: Float.round(beat, 2), rounds: rounds, pending: pending?}
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  What `source` evaluates to, as `{:ok, score}` or `{:error, message}`.

  `source` is evaluated with `TuningFork.Part` imported and `TuningFork.Kit` aliased and must
  come to a `%TuningFork.Part{}` (wrapped with `TuningFork.Score.from_parts/2`) or a
  `%TuningFork.Score{}`. A blank or `nil` source is `{:error, "no source"}`.

      LiveLoopsCell.eval_source("part(bpm: 120, synth: Kit.voice(\"bd\", 0.3)) |> steps(\"x...\")")
  """
  @spec eval_source(String.t() | nil) :: {:ok, Score.t()} | {:error, String.t()}
  def eval_source(source) do
    case String.trim(source || "") do
      "" -> {:error, "no source"}
      trimmed -> Part.Source.parse(trimmed)
    end
  end

  @impl true
  def to_attrs(ctx), do: %{"loops" => ctx.assigns.loops}

  @doc """
  The cell's source from its saved attributes: a `live_loop` per loop under
  `use TuningFork.SonicPi`, started on the stage registered as `TuningFork.Stage`.

  `"loops"` is a list of `%{"name" => name, "source" => source}`; loops with a blank name
  or blank source are left out, and the result is `""` when none remain. A loop whose source
  does not read as Elixir is written as a string handed to `TuningFork.Part.Source.compile/1`.
  """
  @impl true
  def to_source(attrs) do
    case attrs["loops"] || [] do
      [] -> ""
      loops -> loops |> Enum.filter(&live_loop?/1) |> build_source()
    end
  end

  defp live_loop?(loop) do
    String.trim(Map.get(loop, "name") || "") != "" and
      String.trim(Map.get(loop, "source") || "") != ""
  end

  defp build_source([]), do: ""

  defp build_source(loops) do
    body =
      Enum.map_join(loops, "\n\n", fn loop ->
        name = loop |> Map.fetch!("name") |> String.trim()
        source = loop |> Map.fetch!("source") |> String.trim()

        """
        live_loop #{inspect(String.to_atom(name))} do
        #{indent(source)}
        end\
        """
      end)

    (stage_line() <> "use TuningFork.SonicPi\n\n" <> body)
    |> formatted(loops)
  end

  defp stage_line,
    do: "unless Process.whereis(TuningFork.Stage), do: Kino.render(KinoTuningFork.stage())\n\n"

  defp words do
    functions = TuningFork.SonicPi.__info__(:functions)
    macros = TuningFork.SonicPi.__info__(:macros)

    for {name, _arity} <- functions ++ macros, uniq: true, do: {name, :*}
  end

  defp indent(source), do: source |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  defp formatted(source, loops) do
    source |> Code.format_string!(locals_without_parens: words()) |> IO.iodata_to_binary()
  rescue
    _error -> quoted_source(loops)
  end

  defp quoted_source(loops) do
    body =
      Enum.map_join(loops, "\n\n", fn loop ->
        name = loop |> Map.fetch!("name") |> String.trim()

        """
        {:ok, body} = TuningFork.Part.Source.compile(#{inspect(Map.fetch!(loop, "source"))})
        {:ok, first} = body.()
        TuningFork.Stage.start_loop(#{inspect(String.to_atom(name))}, first, body: body)\
        """
      end)

    (stage_line() <> body) |> Code.format_string!() |> IO.iodata_to_binary()
  end

  asset "main.js" do
    """
    #{KinoTuningFork.Player.js()}

    export function init(ctx, payload) {
      ctx.importCSS("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap");
      ctx.importCSS("main.css");

      let state = { loops: payload.loops, errors: [] };
      const player = tuningForkPlayer();

      const cards = [];

      const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined) n.textContent = text;
        return n;
      };

      function pushLoops() {
        ctx.pushEvent("update_loops", { loops: state.loops });
      }

      function evaluate() {
        if (!player.playing()) player.start(payload.rate, payload.channels);
        ctx.pushEvent("evaluate", { loops: state.loops });
      }

      let board, emptyEl, transport;

      function loopCard(loop) {
        const card = el("div", "loop");
        const head = el("div", "loop-head");

        const name = el("input", "input name");
        name.type = "text";
        name.placeholder = "name";
        name.value = loop.name;
        name.addEventListener("input", () => {
          card.loop.name = name.value;
          pushLoops();
        });
        head.appendChild(name);

        const status = el("span", "loop-status", "");
        head.appendChild(status);
        head.appendChild(el("div", "spacer"));

        const remove = el("button", "button ghost", "×");
        remove.title = "remove this loop";
        remove.addEventListener("click", () => {
          state.loops = state.loops.filter((l) => l !== card.loop);
          pushLoops();
          syncCards();
        });
        head.appendChild(remove);
        card.appendChild(head);

        const source = el("textarea", "buffer");
        source.spellcheck = false;
        source.value = loop.source;
        source.addEventListener("input", () => {
          card.loop.source = source.value;
          pushLoops();
        });
        source.addEventListener("keydown", (event) => {
          if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
            event.preventDefault();
            evaluate();
          }
        });
        card.appendChild(source);

        const error = el("div", "diagnostic");
        error.style.display = "none";
        card.appendChild(error);

        card.loop = loop;
        card.status = status;
        card.error = error;

        return card;
      }

      function syncCards() {
        for (let i = cards.length - 1; i >= 0; i--) {
          if (!state.loops.includes(cards[i].loop)) {
            cards[i].remove();
            cards.splice(i, 1);
          }
        }

        state.loops.forEach((loop) => {
          if (!cards.some((c) => c.loop === loop)) {
            const card = loopCard(loop);
            cards.push(card);
            board.appendChild(card);
          }
        });

        emptyEl.style.display = state.loops.length === 0 ? "" : "none";
      }

      function showErrors() {
        cards.forEach((card) => {
          const index = state.loops.indexOf(card.loop);
          const found = state.errors.find((e) => e.loop === index);

          card.error.textContent = found ? found.error : "";
          card.error.style.display = found ? "" : "none";
        });
      }

      function showReadouts(readouts) {
        cards.forEach((card) => {
          const reading = readouts.find((r) => r.name === card.loop.name);

          card.status.textContent = reading
            ? `beat ${reading.beat.toFixed(2)} · round ${reading.rounds}${reading.pending ? " · waiting" : ""}`
            : "";
        });
      }

      function render() {
        const app = el("div", "app");

        const bar = el("div", "bar");
        bar.appendChild(el("span", "title", "Live loops"));

        const evalBtn = el("button", "button primary", "Evaluate");
        evalBtn.title = "ctrl+enter";
        evalBtn.addEventListener("click", evaluate);
        bar.appendChild(evalBtn);

        const stopBtn = el("button", "button ghost", "Stop");
        stopBtn.addEventListener("click", () => {
          ctx.pushEvent("stop", {});
          player.stop();
          showReadouts([]);
          transport.textContent = "stopped";
        });
        bar.appendChild(stopBtn);

        const addBtn = el("button", "button ghost", "+ loop");
        addBtn.addEventListener("click", () => {
          state.loops.push({ name: `loop_${state.loops.length + 1}`, source: payload.template });
          pushLoops();
          syncCards();
        });
        bar.appendChild(addBtn);

        bar.appendChild(el("div", "spacer"));

        transport = el("span", "readout", "stopped");
        bar.appendChild(transport);

        const vol = el("input", "volume");
        vol.type = "range";
        vol.min = "0";
        vol.max = "1";
        vol.step = "0.01";
        vol.value = "1";
        vol.title = "volume";
        vol.addEventListener("input", () => player.volume(Number(vol.value)));
        bar.appendChild(vol);

        const helpBtn = el("button", "button ghost", "?");
        helpBtn.title = "what a loop is written with";
        helpBtn.addEventListener("click", () => {
          help.style.display = help.style.display === "none" ? "" : "none";
        });
        bar.appendChild(helpBtn);

        app.appendChild(bar);

        const help = el("pre", "help", payload.reference);
        help.style.display = "none";
        app.appendChild(help);

        board = el("div", "board");
        app.appendChild(board);

        emptyEl = el("div", "empty", "No loops. Add one to start.");
        app.appendChild(emptyEl);

        ctx.root.appendChild(app);
        syncCards();
      }

      render();

      setInterval(() => {
        if (!player.playing()) return;
        transport.textContent = `playing · ${player.time().toFixed(1)}s`;
      }, 200);

      ctx.handleEvent("evaluated", ({ errors, playing }) => {
        state.errors = errors;
        showErrors();

        if (!playing) {
          player.stop();
          showReadouts([]);
          transport.textContent = "stopped";
        }
      });

      ctx.handleEvent("pcm", ([_info, buffer]) => player.push(buffer));

      ctx.handleEvent("readouts", ({ readouts }) => showReadouts(readouts));
    }
    """
  end

  asset "main.css" do
    """
    .app {
      font-family: "Inter", system-ui, sans-serif;
      color: #1f2937;
      padding: 4px 0 8px;
    }

    .bar {
      display: flex;
      align-items: center;
      gap: 10px;
      padding-bottom: 8px;
    }

    .title { font-size: 14px; font-weight: 500; color: #445668; }

    .button {
      padding: 5px 10px;
      border: 1px solid #e1e8f0;
      border-radius: 6px;
      background: #ffffff;
      font-size: 12px;
      font-family: inherit;
      color: #445668;
      cursor: pointer;
    }

    .button:hover { border-color: #94a3b8; }
    .button.primary { background: #6583ff; border-color: #6583ff; color: #ffffff; }
    .button.ghost { color: #7b8794; }

    .spacer { flex: 1; }

    .readout { font-size: 12px; color: #61758a; font-variant-numeric: tabular-nums; }

    .volume { width: 72px; accent-color: #6583ff; }

    .help {
      background: #f8fafc;
      border: 1px solid #e1e8f0;
      border-radius: 6px;
      padding: 8px 10px;
      margin-bottom: 8px;
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      font-size: 12px;
      line-height: 1.5;
      color: #445668;
      white-space: pre;
      overflow-x: auto;
    }

    .board { display: flex; flex-direction: column; gap: 8px; }

    .loop {
      border: 1px solid #e1e8f0;
      border-radius: 8px;
      padding: 8px;
      background: #f8fafc;
    }

    .loop-head { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }

    .input {
      padding: 5px 7px;
      background: #ffffff;
      border: 1px solid #e1e8f0;
      border-radius: 6px;
      font-size: 13px;
      font-family: inherit;
      color: #1f2937;
    }

    .input.name { width: 120px; font-weight: 500; }
    .input:focus { outline: none; border-color: #6583ff; }

    .loop-status {
      font-size: 11px;
      color: #61758a;
      font-variant-numeric: tabular-nums;
    }

    .loop-status.pending { color: #b45309; }

    .buffer {
      width: 100%;
      min-height: 84px;
      box-sizing: border-box;
      padding: 10px 12px;
      background: #0f172a;
      color: #e2e8f0;
      border: 1px solid #1f2937;
      border-radius: 8px;
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      font-size: 13px;
      line-height: 1.5;
      resize: vertical;
    }

    .buffer:focus { outline: none; border-color: #6583ff; }

    .diagnostic {
      margin-top: 6px;
      font-size: 12px;
      padding: 4px 8px;
      background: #fef2f2;
      border: 1px solid #fecaca;
      border-radius: 6px;
      color: #991b1b;
    }

    .empty {
      padding: 16px;
      text-align: center;
      color: #7b8794;
      font-size: 13px;
    }
    """
  end
end

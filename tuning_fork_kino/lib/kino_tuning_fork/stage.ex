defmodule KinoTuningFork.Stage do
  @moduledoc """
  A `TuningFork.Stage` heard in the browser: the widget starts the stage, streams what it
  mixes to the page, and shows what is looping.

      KinoTuningFork.Stage.new()

      live_loop :bells do
        sample :perc_bell, rate: rrand(0.125, 1.5)
        sleep rrand(0, 2)
      end
  """

  use Kino.JS
  use Kino.JS.Live

  alias Kino.JS.Live
  alias KinoTuningFork.Listening
  alias TuningFork.Stage

  @tick_ms 250

  @doc """
  Start a stage and the widget that plays it.

  ## Options

    * `:name` — the stage's registered name, default `TuningFork.Stage`, which is where a bare
      `live_loop` looks; `nil` for an unnamed stage
    * `:rate` — samples per second, default 44100
    * `:chunk` — frames per chunk sent to the browser, default 2048
    * any other `TuningFork.Stage.start_link/1` option

  A stage already registered under `:name` is stopped first, so re-running the cell gives a
  fresh one; the widget that stage belonged to stays on the page, silent, with its stage
  shown as closed.
  """
  @spec new(keyword()) :: Live.t()
  def new(opts \\ []) do
    Live.new(__MODULE__, opts)
  end

  @doc "The stage behind a widget, or `nil` once that stage has stopped."
  @spec stage(Live.t()) :: pid() | nil
  def stage(kino), do: Live.call(kino, :stage)

  @impl true
  def init(opts, ctx) do
    {name, opts} = Keyword.pop(opts, :name, Stage)
    rate = Keyword.get(opts, :rate, 44_100)
    channels = Keyword.get(opts, :channels, 2)

    stage_opts =
      opts
      |> Keyword.merge(
        name: name,
        sink: KinoTuningFork.Sink,
        chunk: Keyword.get(opts, :chunk, 2_048)
      )
      |> Keyword.put(:sink_opts, owner: self())

    {:ok, stage} = start_fresh(name, stage_opts)
    Process.monitor(stage)
    Process.send_after(self(), :tick, @tick_ms)

    {:ok, assign(ctx, stage: stage, rate: rate, channels: channels, level: 0.0)}
  end

  @impl true
  def handle_connect(ctx) do
    {:ok, %{rate: ctx.assigns.rate, channels: ctx.assigns.channels}, Listening.init(ctx)}
  end

  @impl true
  def handle_call(:stage, _from, ctx), do: {:reply, ctx.assigns.stage, ctx}

  @impl true
  def handle_info({:pcm, chunk}, ctx), do: {:noreply, Listening.forward(ctx, chunk)}

  def handle_info(:tick, %{assigns: %{stage: nil}} = ctx), do: {:noreply, ctx}

  def handle_info(:tick, ctx) do
    Process.send_after(self(), :tick, @tick_ms)

    case readouts_if_running(ctx.assigns.stage) do
      nil -> :ok
      readouts -> broadcast_event(ctx, "readouts", readouts)
    end

    {:noreply, ctx}
  end

  def handle_info({:DOWN, _ref, :process, stage, _reason}, %{assigns: %{stage: stage}} = ctx) do
    broadcast_event(ctx, "closed", %{})
    {:noreply, assign(ctx, stage: nil)}
  end

  @impl true
  def handle_event("listening", %{"on" => on}, ctx), do: {:noreply, Listening.set(ctx, on)}

  def handle_event("hush", _payload, %{assigns: %{stage: nil}} = ctx), do: {:noreply, ctx}

  def handle_event("hush", _payload, ctx) do
    TuningFork.SonicPi.hush(ctx.assigns.stage)
    {:noreply, ctx}
  end

  @doc """
  What the stage is playing, as `%{loops: [%{name, beat, rounds}], cycle: cycle | nil}`.
  """
  @spec readouts(GenServer.server()) :: map()
  def readouts(stage) do
    loops =
      stage
      |> Stage.loops()
      |> Enum.map(fn {name, %{beat: beat, rounds: rounds}} ->
        %{name: to_string(name), beat: Float.round(beat, 2), rounds: rounds}
      end)
      |> Enum.sort_by(& &1.name)

    %{loops: loops, cycle: Stage.cycle(stage)}
  end

  defp readouts_if_running(stage) do
    if Process.alive?(stage), do: readouts(stage)
  catch
    :exit, _stopped_meanwhile -> nil
  end

  defp start_fresh(name, stage_opts) do
    case Stage.start_link(stage_opts) do
      {:ok, stage} ->
        {:ok, stage}

      {:error, {:already_started, running}} when not is_nil(name) ->
        GenServer.stop(running)
        Stage.start_link(stage_opts)
    end
  end

  asset "main.js" do
    """
    #{KinoTuningFork.Player.js()}

    export function init(ctx, payload) {
      ctx.importCSS("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap");

      const player = tuningForkPlayer(ctx);

      const el = (tag, className, text) => {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
      };

      const app = el("div", "app");
      const bar = el("div", "bar");
      const playBtn = el("button", "button", "▶ listen");
      const hushBtn = el("button", "button ghost", "hush");
      const meter = el("div", "meter");
      const meterFill = el("div", "meter-fill");
      meter.appendChild(meterFill);
      const vol = document.createElement("input");
      vol.type = "range"; vol.min = "0"; vol.max = "1"; vol.step = "0.01"; vol.value = "0.8";
      vol.className = "volume";
      const status = el("span", "status", "stage running · not listening");

      playBtn.addEventListener("click", () => {
        if (player.playing()) {
          player.stop();
          playBtn.textContent = "▶ listen";
          status.textContent = "stage running · not listening";
        } else {
          player.start(payload.rate, payload.channels);
          player.volume(Number(vol.value));
          playBtn.textContent = "■ mute";
          status.textContent = "listening";
        }
      });

      hushBtn.addEventListener("click", () => ctx.pushEvent("hush", {}));
      vol.addEventListener("input", () => player.volume(Number(vol.value)));

      bar.appendChild(playBtn);
      bar.appendChild(hushBtn);
      bar.appendChild(meter);
      bar.appendChild(vol);
      bar.appendChild(status);
      app.appendChild(bar);

      const board = el("div", "board");
      app.appendChild(board);
      ctx.root.appendChild(app);

      ctx.handleEvent("pcm", ([_info, buffer]) => {
        const peak = player.push(buffer);
        meterFill.style.width = `${Math.min(100, Math.round(peak * 100))}%`;
      });

      ctx.handleEvent("closed", () => {
        if (player.playing()) player.stop();
        playBtn.disabled = true;
        hushBtn.disabled = true;
        status.textContent = "stage closed · a newer stage took its place";
        board.textContent = "";
      });

      ctx.handleEvent("readouts", ({ loops, cycle }) => {
        board.textContent = "";

        if (cycle !== null && cycle !== undefined) {
          board.appendChild(el("div", "row", `pattern · cycle ${Number(cycle).toFixed(2)}`));
        }

        for (const loop of loops) {
          board.appendChild(el("div", "row", `${loop.name} · round ${loop.rounds} · beat ${loop.beat.toFixed(2)}`));
        }

        if (loops.length === 0 && (cycle === null || cycle === undefined)) {
          board.appendChild(el("div", "row quiet", "nothing looping — start a live_loop"));
        }
      });
    }
    """
  end

  asset "main.css" do
    """
    .app { font-family: "Inter", system-ui, sans-serif; color: #1f2937; padding: 4px 0 8px; }
    .bar { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
    .button { font: inherit; font-weight: 500; padding: 6px 12px; border-radius: 6px; border: 1px solid #d1d5db; background: #f9fafb; cursor: pointer; }
    .button.ghost { background: transparent; }
    .meter { width: 120px; height: 8px; background: #e5e7eb; border-radius: 4px; overflow: hidden; }
    .meter-fill { height: 100%; width: 0; background: #10b981; transition: width 60ms linear; }
    .volume { width: 100px; }
    .status { font-size: 12px; color: #6b7280; }
    .board { display: flex; flex-direction: column; gap: 4px; font-variant-numeric: tabular-nums; font-size: 13px; }
    .row.quiet { color: #9ca3af; }
    """
  end
end

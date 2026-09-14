defmodule KinoTuningFork.LivePatternsCell do
  @moduledoc """
  A live-coding smart cell: a buffer of `TuningFork.Session` pattern rows on a stage of its
  own, heard in the browser as it plays. Opening the cell starts fetching strudel.cc's default
  sample sets (`TuningFork.Strudel.defaults/0`), so `s("bd") |> bank("RolandTR909")` plays the
  recording once it has arrived.
  """

  use Kino.JS
  use Kino.JS.Live
  use Kino.SmartCell, name: "TF Patterns — live coding, Strudel style"

  alias TuningFork.{Session, Stage}
  alias TuningFork.Session.View

  @rate 44_100
  @channels 2
  @chunk 2_048
  @tick_ms 100
  @default_cps 0.5

  @doc "The buffer a fresh cell opens on."
  @spec demo() :: String.t()
  def demo do
    """
    s("bd*4")
    |> gain(0.8)
    |> scope()\
    """
  end

  @impl true
  def init(attrs, ctx) do
    ctx =
      assign(ctx,
        text: attrs["text"] || demo(),
        cps: attrs["cps"] || to_string(@default_cps),
        checked: [],
        stage: nil
      )

    TuningFork.Strudel.defaults()

    {:ok, ctx}
  end

  @impl true
  def handle_connect(ctx) do
    {:ok, payload(ctx), ctx}
  end

  defp payload(ctx) do
    %{
      text: ctx.assigns.text,
      cps: ctx.assigns.cps,
      columns: View.columns(),
      rate: @rate,
      channels: @channels,
      diagnostics: diagnostics(ctx.assigns.checked)
    }
  end

  defp diagnostics(checked) do
    checked
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{error: nil}, _index} -> []
      {%{error: error}, index} -> [%{row: index, error: error}]
    end)
  end

  @impl true
  def handle_event("evaluate", %{"text" => text}, ctx) do
    rows = rows_of(text)
    checked = Session.checked(rows)
    cps = Session.tempo(rows) || number(ctx.assigns.cps, @default_cps)
    ctx = ctx |> assign(text: text, checked: checked, cps: to_string(cps)) |> with_stage()
    take_over(ctx.assigns.stage, Session.combined(rows), cps)

    broadcast_event(ctx, "evaluated", %{diagnostics: diagnostics(checked), cps: cps})

    {:noreply, ctx}
  end

  def handle_event("update_text", %{"text" => text}, ctx) do
    {:noreply, assign(ctx, text: text)}
  end

  def handle_event("set_cps", %{"cps" => cps}, ctx) do
    if ctx.assigns.stage, do: Stage.pattern_cps(ctx.assigns.stage, number(cps, @default_cps))

    {:noreply, assign(ctx, cps: cps)}
  end

  def handle_event("stop", _payload, ctx) do
    if ctx.assigns.stage, do: Stage.stop_pattern(ctx.assigns.stage)

    {:noreply, ctx}
  end

  @impl true
  def handle_info({:pcm, chunk}, ctx) do
    broadcast_event(ctx, "pcm", {:binary, %{}, chunk})
    {:noreply, ctx}
  end

  def handle_info(:tick, ctx) do
    Process.send_after(self(), :tick, @tick_ms)

    case ctx.assigns.stage && Stage.cycle(ctx.assigns.stage) do
      nil ->
        :ok

      cycle ->
        cps = number(ctx.assigns.cps, @default_cps)

        broadcast_event(ctx, "at", %{
          cycle: cycle,
          visuals: visuals(rows_of(ctx.assigns.text), cycle, cps)
        })
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

  defp take_over(stage, pattern, cps) do
    if Stage.cycle(stage) == nil do
      Stage.start_pattern(stage, pattern, cps: cps)
    else
      Stage.update_pattern(stage, pattern, at: :cycle)
    end
  end

  defp visuals(rows, cycle, cps) do
    rows
    |> Session.joined()
    |> Enum.flat_map(fn {first, _last, source} -> visual(source, first, cycle, cps) end)
  end

  defp visual(source, index, cycle, cps) do
    case Session.asks?(source) do
      :scope ->
        [%{row: index, kind: "scope", data: View.scope(source, cycle, cps)}]

      :pianoroll ->
        [%{row: index, kind: "pianoroll", notes: bars(source, cycle)}]

      nil ->
        []
    end
  end

  defp bars(row, cycle) do
    widths = View.widths(row, cycle)

    for {column, note} <- View.notes(row, cycle) do
      %{column: column, note: note, width: Map.get(widths, column, 1)}
    end
  end

  defp rows_of(text), do: text |> String.split("\n") |> Enum.map(&%{source: &1})

  defp number(value, _default) when is_number(value), do: value

  defp number(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> if number == trunc(number), do: trunc(number), else: number
      :error -> default
    end
  end

  defp number(_value, default), do: default

  @impl true
  def to_attrs(ctx) do
    %{"text" => ctx.assigns.text, "cps" => ctx.assigns.cps}
  end

  @doc """
  The cell's source from its saved attributes, or `""` when the buffer is blank or every row
  is parked.

  Attributes: `"text"` is the buffer, one row per line; `"cps"` cycles per second, default
  `"0.5"`. The source starts the pattern on the stage registered as `TuningFork.Stage`, or
  swaps it in at the next cycle when one is already playing.
  """
  @impl true
  def to_source(attrs) do
    rows = rows_of(attrs["text"] || "")

    case Session.joined(rows) do
      [] -> ""
      _chains -> build_source(rows, attrs)
    end
  end

  defp build_source(rows, attrs) do
    cps = number(attrs["cps"], @default_cps)

    """
    unless Process.whereis(TuningFork.Stage), do: Kino.render(KinoTuningFork.stage())

    rows = [
    #{Enum.map_join(rows, ",\n", &row_literal/1)}
    ]

    pattern = TuningFork.Session.combined(rows)

    if TuningFork.Stage.cycle() do
      TuningFork.Stage.update_pattern(pattern, at: :cycle)
    else
      TuningFork.Stage.start_pattern(pattern, cps: #{inspect(cps)})
    end\
    """
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  defp row_literal(%{source: source}), do: "%{source: #{inspect(source)}}"

  asset "main.js" do
    """
    #{KinoTuningFork.Player.js()}

    export function init(ctx, payload) {
      ctx.importCSS("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap");
      ctx.importCSS("main.css");

      const player = tuningForkPlayer();

      let state = {
        text: payload.text,
        cps: payload.cps,
        columns: payload.columns || 32,
        diagnostics: payload.diagnostics || [],
        cycle: 0,
        visuals: [],
      };

      const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined) n.textContent = text;
        return n;
      };

      const svgEl = (tag) => document.createElementNS("http://www.w3.org/2000/svg", tag);

      function evaluate() {
        if (!player.playing()) player.start(payload.rate, payload.channels);
        ctx.pushEvent("evaluate", { text: state.text });
      }

      let textarea, cycleEl, diagList, visualsEl, cpsInput;

      function render() {
        ctx.root.innerHTML = "";
        const app = el("div", "app");

        const bar = el("div", "bar");
        bar.appendChild(el("span", "title", "Live patterns"));

        const cpsField = el("label", "field");
        cpsField.appendChild(el("span", null, "cps"));
        cpsInput = el("input", "input small");
        cpsInput.type = "number";
        cpsInput.step = "0.05";
        cpsInput.min = "0.05";
        cpsInput.value = state.cps;
        cpsInput.addEventListener("change", () => {
          state.cps = cpsInput.value;
          ctx.pushEvent("set_cps", { cps: cpsInput.value });
        });
        cpsField.appendChild(cpsInput);
        bar.appendChild(cpsField);

        const evalBtn = el("button", "button primary", "Evaluate");
        evalBtn.title = "ctrl+enter";
        evalBtn.addEventListener("click", evaluate);
        bar.appendChild(evalBtn);

        const stopBtn = el("button", "button ghost", "Stop");
        stopBtn.addEventListener("click", () => {
          ctx.pushEvent("stop", {});
          player.stop();
          cycleEl.textContent = "stopped";
          state.visuals = [];
          renderVisuals();
        });
        bar.appendChild(stopBtn);

        bar.appendChild(el("div", "spacer"));

        cycleEl = el("span", "readout", "stopped");
        bar.appendChild(cycleEl);

        const vol = el("input", "volume");
        vol.type = "range";
        vol.min = "0";
        vol.max = "1";
        vol.step = "0.01";
        vol.value = "1";
        vol.title = "volume";
        vol.addEventListener("input", () => player.volume(Number(vol.value)));
        bar.appendChild(vol);

        app.appendChild(bar);

        textarea = el("textarea", "buffer");
        textarea.value = state.text;
        textarea.spellcheck = false;
        textarea.addEventListener("input", () => {
          state.text = textarea.value;
          ctx.pushEvent("update_text", { text: textarea.value });
        });
        textarea.addEventListener("keydown", (event) => {
          if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
            event.preventDefault();
            evaluate();
          }
        });
        app.appendChild(textarea);

        diagList = el("div", "diagnostics");
        app.appendChild(diagList);
        renderDiagnostics();

        visualsEl = el("div", "visuals");
        app.appendChild(visualsEl);
        renderVisuals();

        ctx.root.appendChild(app);
      }

      function renderDiagnostics() {
        diagList.innerHTML = "";
        const lines = state.text.split("\\n");

        for (const d of state.diagnostics) {
          const item = el("div", "diagnostic");
          item.appendChild(el("span", "diag-row", `row ${d.row + 1}`));
          item.appendChild(el("span", "diag-source", (lines[d.row] || "").trim()));
          item.appendChild(el("span", "diag-error", d.error));
          diagList.appendChild(item);
        }
      }

      function renderVisuals() {
        visualsEl.innerHTML = "";

        for (const v of state.visuals) {
          const card = el("div", "visual");
          card.appendChild(el("div", "visual-label", `row ${v.row + 1}`));
          card.appendChild(v.kind === "scope" ? scopeSvg(v.data) : pianorollSvg(v.notes));
          visualsEl.appendChild(card);
        }
      }

      function scopeSvg(data) {
        const width = 280, height = 48;
        const svg = svgEl("svg");
        svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
        svg.setAttribute("class", "scope");

        if (data.length > 0) {
          const step = width / data.length;
          const points = data
            .map((v, i) => `${(i * step).toFixed(1)},${(height / 2 - v * (height / 2 - 2)).toFixed(1)}`)
            .join(" ");
          const line = svgEl("polyline");
          line.setAttribute("points", points);
          line.setAttribute("class", "scope-line");
          svg.appendChild(line);
        }

        return svg;
      }

      function pianorollSvg(notes) {
        const width = 280, height = 48;
        const columns = state.columns;
        const colWidth = width / columns;
        const svg = svgEl("svg");
        svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
        svg.setAttribute("class", "pianoroll");

        const pitches = notes.map((n) => n.note);
        const low = pitches.length ? Math.min(...pitches) - 2 : 60;
        const high = pitches.length ? Math.max(...pitches) + 2 : 72;
        const span = Math.max(high - low, 1);

        for (const n of notes) {
          const rect = svgEl("rect");
          rect.setAttribute("x", (n.column * colWidth).toFixed(1));
          rect.setAttribute("width", Math.max((n.width || 1) * colWidth - 1, 1).toFixed(1));
          rect.setAttribute("y", (height - ((n.note - low) / span) * height - 3).toFixed(1));
          rect.setAttribute("height", 4);
          rect.setAttribute("class", "note");
          svg.appendChild(rect);
        }

        return svg;
      }

      render();

      ctx.handleEvent("evaluated", ({ diagnostics, cps }) => {
        state.diagnostics = diagnostics;
        state.cps = String(cps);
        cpsInput.value = state.cps;
        renderDiagnostics();
      });

      ctx.handleEvent("pcm", ([_info, buffer]) => player.push(buffer));

      ctx.handleEvent("at", ({ cycle, visuals }) => {
        state.cycle = cycle;
        state.visuals = visuals;
        cycleEl.textContent = `cycle ${cycle.toFixed(2)}`;
        renderVisuals();
      });
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

    .field { display: flex; align-items: center; gap: 6px; font-size: 12px; color: #61758a; }

    .input {
      padding: 5px 7px;
      background: #f8fafc;
      border: 1px solid #e1e8f0;
      border-radius: 6px;
      font-size: 13px;
      font-family: inherit;
      color: #1f2937;
    }

    .input.small { width: 64px; }
    .input:focus { outline: none; border-color: #6583ff; }

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

    .buffer {
      width: 100%;
      min-height: 160px;
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

    .diagnostics { display: flex; flex-direction: column; gap: 4px; margin-top: 8px; }

    .diagnostic {
      display: flex;
      gap: 8px;
      font-size: 12px;
      padding: 4px 8px;
      background: #fef2f2;
      border: 1px solid #fecaca;
      border-radius: 6px;
      color: #991b1b;
    }

    .diag-row { font-weight: 600; color: #b91c1c; }

    .diag-source {
      color: #7f1d1d;
      font-family: monospace;
      flex: 1;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .visuals { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }

    .visual {
      background: #f8fafc;
      border: 1px solid #e1e8f0;
      border-radius: 6px;
      padding: 6px 8px;
    }

    .visual-label { font-size: 10px; color: #94a3b8; margin-bottom: 4px; }

    .scope { width: 280px; height: 48px; }
    .scope-line { fill: none; stroke: #6583ff; stroke-width: 1.5; }

    .pianoroll { width: 280px; height: 48px; background: #0f172a; border-radius: 4px; }
    .pianoroll .note { fill: #22d3ee; }
    """
  end
end

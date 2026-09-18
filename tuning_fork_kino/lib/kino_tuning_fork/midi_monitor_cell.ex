defmodule KinoTuningFork.MidiMonitorCell do
  @moduledoc """
  A smart cell for a MIDI device: a keyboard played in and heard on a stage of the cell's
  own, a pattern played out with clock, a key strip lighting up for both directions, and a
  log of every message — over a `TuningFork.Midi.Monitor`.
  """

  use Kino.JS
  use Kino.JS.Live
  use Kino.SmartCell, name: "TF MIDI — keyboard in, pattern out"

  alias KinoTuningFork.Listening
  alias TuningFork.Midi.Monitor
  alias TuningFork.Pattern.Source
  alias TuningFork.Stage

  @rate 44_100
  @channels 2
  @chunk 2_048
  @virtual "virtual:"

  @voices ~w(gm_piano gm_epiano1 gm_acoustic_bass gm_electric_bass_finger gm_flute gm_string_ensemble_1 sawtooth square triangle sine)

  @defaults %{
    "input" => "",
    "output" => "",
    "voice" => "gm_piano",
    "pattern" => ~S{stack([s("bd*4, hh*8"), n("0 4 7 4") |> scale("c:minor")])},
    "cps" => "0.5",
    "clock" => true
  }

  @impl true
  def init(attrs, ctx) do
    fields = Map.new(@defaults, fn {field, default} -> {field, attrs[field] || default} end)

    {:ok, assign(ctx, fields: fields, stage: nil, monitor: nil, fault: nil)}
  end

  @impl true
  def handle_connect(ctx) do
    ctx = ctx |> Listening.init() |> with_monitor()

    {:ok, payload(ctx), ctx}
  end

  defp payload(ctx) do
    %{
      fields: ctx.assigns.fields,
      inputs: choices(Monitor.inputs(), "TuningFork In"),
      outputs: choices(Monitor.outputs(), "TuningFork Out"),
      voices: @voices,
      state: shown(ctx),
      fault: ctx.assigns.fault,
      rate: @rate,
      channels: @channels
    }
  end

  defp choices(ports, virtual) do
    Enum.map(ports, fn {index, name} -> %{value: to_string(index), label: name} end) ++
      [%{value: @virtual <> virtual, label: "virtual port \"#{virtual}\""}]
  end

  defp shown(%{assigns: %{monitor: nil}}) do
    %{
      input: nil,
      output: nil,
      keys: %{},
      sounding: [],
      pedal: false,
      bend: 0,
      controls: %{},
      program: nil,
      playing: false,
      cps: 0.5,
      clock: false,
      events: []
    }
  end

  defp shown(ctx), do: ctx.assigns.monitor |> Monitor.state() |> page_state()

  @doc """
  The monitor's state as the page takes it: the ports and the last twelve events as lists
  rather than tuples, clock ticks and the voice left out.
  """
  @spec page_state(Monitor.state()) :: map()
  def page_state(state) do
    state
    |> Map.delete(:voice)
    |> Map.update!(:input, &port_list/1)
    |> Map.update!(:output, &port_list/1)
    |> Map.update!(:events, fn events ->
      for {side, event, at} <- events, event != :clock, do: [side, event_list(event), at]
    end)
    |> Map.update!(:events, &Enum.take(&1, 12))
  end

  defp event_list(event) when is_tuple(event), do: Tuple.to_list(event)
  defp event_list(event) when is_atom(event), do: [event]

  defp port_list(nil), do: nil
  defp port_list({index, name}), do: [index, name]

  @impl true
  def handle_event("update_field", %{"field" => field, "value" => value}, ctx) do
    ctx =
      ctx |> with_monitor() |> then(&assign(&1, fields: Map.put(&1.assigns.fields, field, value)))

    ctx = applied(ctx, field, value)

    broadcast_event(ctx, "changed", %{
      fields: ctx.assigns.fields,
      state: shown(ctx),
      fault: ctx.assigns.fault
    })

    {:noreply, ctx}
  end

  def handle_event("play", _payload, ctx) do
    ctx = with_monitor(ctx)
    fields = ctx.assigns.fields

    fault =
      with {:ok, pattern} <- Source.parse(fields["pattern"]),
           :ok <-
             Monitor.play(ctx.assigns.monitor, pattern,
               cps: number(fields["cps"], 0.5),
               clock: fields["clock"] == true
             ) do
        nil
      else
        {:error, reason} -> describe(reason)
      end

    ctx = assign(ctx, fault: fault)
    broadcast_event(ctx, "changed", %{fields: fields, state: shown(ctx), fault: fault})

    {:noreply, ctx}
  end

  def handle_event("listening", %{"on" => on}, ctx), do: {:noreply, Listening.set(ctx, on)}

  def handle_event("stop", _payload, ctx) do
    if ctx.assigns.monitor, do: Monitor.stop(ctx.assigns.monitor)

    {:noreply, ctx}
  end

  def handle_event("tap", %{"note" => note}, ctx) do
    ctx = with_monitor(ctx)

    fault =
      case Monitor.tap(ctx.assigns.monitor, trunc(note), 100) do
        :ok -> ctx.assigns.fault
        {:error, reason} -> describe(reason)
      end

    {:noreply, assign(ctx, fault: fault)}
  end

  defp applied(ctx, "input", "") do
    :ok = Monitor.close_input(ctx.assigns.monitor)
    assign(ctx, fault: nil)
  end

  defp applied(ctx, "input", value) do
    case Monitor.open_input(ctx.assigns.monitor, choice(value)) do
      :ok -> assign(ctx, fault: nil)
      {:error, reason} -> assign(ctx, fault: "input: " <> describe(reason))
    end
  end

  defp applied(ctx, "output", "") do
    :ok = Monitor.close_output(ctx.assigns.monitor)
    assign(ctx, fault: nil)
  end

  defp applied(ctx, "output", value) do
    case Monitor.open_output(ctx.assigns.monitor, choice(value)) do
      :ok -> assign(ctx, fault: nil)
      {:error, reason} -> assign(ctx, fault: "output: " <> describe(reason))
    end
  end

  defp applied(ctx, "voice", value) do
    Monitor.voice(ctx.assigns.monitor, value)
    ctx
  end

  defp applied(ctx, "cps", value) do
    Monitor.cps(ctx.assigns.monitor, max(number(value, 0.5), 0.01))
    ctx
  end

  defp applied(ctx, _field, _value), do: ctx

  defp choice(@virtual <> name), do: {:virtual, name}
  defp choice(index), do: number(index, 0)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  @impl true
  def handle_info({:pcm, chunk}, ctx), do: {:noreply, Listening.forward(ctx, chunk)}

  def handle_info({:midi_monitor, _monitor, _side, :clock, _at}, ctx), do: {:noreply, ctx}

  def handle_info({:midi_monitor, _monitor, side, event, _at}, ctx) do
    broadcast_event(ctx, "event", %{side: side, event: event_list(event)})
    {:noreply, ctx}
  end

  def handle_info({:midi_monitor, _monitor, :changed}, ctx) do
    broadcast_event(ctx, "changed", %{
      fields: ctx.assigns.fields,
      state: shown(ctx),
      fault: ctx.assigns.fault
    })

    {:noreply, ctx}
  end

  def handle_info(_other, ctx), do: {:noreply, ctx}

  defp with_monitor(%{assigns: %{monitor: nil}} = ctx) do
    {:ok, stage} =
      Stage.start_link(
        name: nil,
        sink: KinoTuningFork.Sink,
        sink_opts: [owner: self()],
        rate: @rate,
        channels: @channels,
        chunk: @chunk
      )

    monitor = start_monitor(stage, ctx.assigns.fields["voice"])
    :ok = Monitor.subscribe(monitor, self())
    ctx = assign(ctx, stage: stage, monitor: monitor)

    ctx
    |> applied("input", ctx.assigns.fields["input"])
    |> applied("output", ctx.assigns.fields["output"])
  end

  defp with_monitor(ctx), do: ctx

  defp start_monitor(stage, voice) do
    {:ok, monitor} = Monitor.start_link(stage: stage, voice: voice)
    monitor
  end

  @impl true
  def to_attrs(ctx), do: ctx.assigns.fields

  @doc """
  The cell's source from its saved attributes, or `""` until an input or an output is chosen.

  Attributes, all strings unless noted: `"input"` and `"output"` — a port index, or
  `virtual:` and a name for a virtual port, blank for none; `"voice"` — what the input plays;
  `"pattern"` — a pattern row to play out, blank for none; `"cps"` — its cycles per second;
  `"clock"` — `true` to send MIDI clock with it.
  """
  @impl true
  def to_source(attrs) do
    fields = Map.merge(@defaults, Map.take(attrs, Map.keys(@defaults)))

    if fields["input"] == "" and fields["output"] == "" do
      ""
    else
      fields |> build_source() |> Code.format_string!() |> IO.iodata_to_binary()
    end
  end

  defp build_source(fields) do
    [
      "unless Process.whereis(TuningFork.Stage), do: Kino.render(KinoTuningFork.stage())",
      "{:ok, midi} = TuningFork.Midi.Monitor.start_link(voice: #{inspect(fields["voice"])})",
      open_line("open_input", fields["input"]),
      open_line("open_output", fields["output"]),
      play_lines(fields),
      "midi"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp open_line(_fun, ""), do: nil

  defp open_line(fun, value),
    do: ":ok = TuningFork.Midi.Monitor.#{fun}(midi, #{inspect(choice(value))})"

  defp play_lines(%{"output" => ""}), do: nil

  defp play_lines(fields) do
    case String.trim(fields["pattern"]) do
      "" ->
        nil

      pattern ->
        [
          "{:ok, pattern} = TuningFork.Pattern.Source.parse(#{inspect(pattern)})",
          ":ok = TuningFork.Midi.Monitor.play(midi, pattern, cps: #{number(fields["cps"], 0.5)}, clock: #{fields["clock"] == true})"
        ]
    end
  end

  defp number(value, _default) when is_number(value), do: value

  defp number(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> if number == trunc(number), do: trunc(number), else: number
      :error -> default
    end
  end

  defp number(_value, default), do: default

  asset "main.js" do
    """
    #{KinoTuningFork.Player.js()}

    export function init(ctx, payload) {
      ctx.importCSS("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap");
      ctx.importCSS("main.css");

      const player = tuningForkPlayer(ctx);
      let fields = payload.fields;
      let lit = { in: new Set(), out: new Set() };
      let log = [];

      const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined) n.textContent = text;
        return n;
      };

      const app = el("div", "app");
      const ports = el("div", "bar");
      const transport = el("div", "bar");
      const strip = el("div", "strip");
      const readout = el("div", "readout");
      const faultEl = el("div", "fault");
      const logEl = el("div", "log");

      const select = (name, options, onChange, blank) => {
        const s = el("select", "input");
        if (blank !== undefined) {
          const o = el("option", null, blank);
          o.value = "";
          s.appendChild(o);
        }
        for (const opt of options) {
          const o = el("option", null, opt.label ?? opt);
          o.value = opt.value ?? opt;
          s.appendChild(o);
        }
        s.value = fields[name] ?? "";
        s.addEventListener("change", () => onChange(s.value));
        return s;
      };

      const field = (label, input) => {
        const f = el("label", "field");
        f.appendChild(el("span", null, label));
        f.appendChild(input);
        return f;
      };

      const push = (name, value) => {
        fields[name] = value;
        ctx.pushEvent("update_field", { field: name, value });
      };

      ports.appendChild(field("In", select("input", payload.inputs, (v) => push("input", v), "none")));
      ports.appendChild(field("Voice", select("voice", payload.voices, (v) => push("voice", v))));
      ports.appendChild(field("Out", select("output", payload.outputs, (v) => push("output", v), "none")));

      const listen = el("button", "button", "▶ listen");
      const vol = document.createElement("input");
      vol.type = "range"; vol.min = "0"; vol.max = "1"; vol.step = "0.01"; vol.value = "0.8";
      vol.className = "volume";
      listen.addEventListener("click", () => {
        if (player.playing()) { player.stop(); listen.textContent = "▶ listen"; }
        else { player.start(payload.rate, payload.channels); player.volume(Number(vol.value)); listen.textContent = "■ mute"; }
      });
      vol.addEventListener("input", () => player.volume(Number(vol.value)));
      ports.appendChild(el("div", "spacer"));
      ports.appendChild(listen);
      ports.appendChild(vol);

      const pattern = el("input", "input pattern");
      pattern.type = "text";
      pattern.spellcheck = false;
      pattern.value = fields.pattern;
      pattern.addEventListener("change", () => push("pattern", pattern.value));
      transport.appendChild(field("Pattern out", pattern));

      const cps = el("input", "input num");
      cps.type = "number"; cps.min = "0.05"; cps.max = "4"; cps.step = "0.05";
      cps.value = fields.cps;
      cps.addEventListener("change", () => push("cps", cps.value));
      transport.appendChild(field("cps", cps));

      const clock = el("input", null);
      clock.type = "checkbox";
      clock.checked = fields.clock === true;
      clock.addEventListener("change", () => push("clock", clock.checked));
      transport.appendChild(field("clock", clock));

      const play = el("button", "button primary", "play out");
      play.addEventListener("click", () => ctx.pushEvent("play", {}));
      const stop = el("button", "button ghost", "stop");
      stop.addEventListener("click", () => ctx.pushEvent("stop", {}));
      transport.appendChild(play);
      transport.appendChild(stop);

      const keys = new Map();
      const names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
      for (let note = 36; note <= 96; note++) {
        const black = [1, 3, 6, 8, 10].includes(note % 12);
        const key = el("button", black ? "key black" : "key white");
        key.title = names[note % 12] + (Math.floor(note / 12) - 1) + " · " + note;
        if (note % 12 === 0) key.appendChild(el("span", "label", "C" + (Math.floor(note / 12) - 1)));
        key.addEventListener("mousedown", () => ctx.pushEvent("tap", { note }));
        keys.set(note, key);
        strip.appendChild(key);
      }

      app.appendChild(ports);
      app.appendChild(transport);
      app.appendChild(strip);
      app.appendChild(readout);
      app.appendChild(faultEl);
      app.appendChild(logEl);
      ctx.root.appendChild(app);

      function paint() {
        for (const [note, key] of keys) {
          key.classList.toggle("in", lit.in.has(note));
          key.classList.toggle("out", lit.out.has(note));
        }
      }

      function describe(state) {
        const port = (p) => (p === null ? "none" : Array.isArray(p) ? (p[0] === "virtual" ? "virtual \\"" + p[1] + "\\"" : p[1]) : String(p));
        const bits = [
          "in: " + port(state.input),
          "out: " + port(state.output) + (state.playing ? " · playing at " + state.cps + " cps" + (state.clock ? " with clock" : "") : ""),
          "pedal " + (state.pedal ? "down" : "up"),
          "bend " + state.bend,
        ];
        if (state.program !== null && state.program !== undefined) bits.push("program " + state.program);
        const controls = Object.entries(state.controls || {}).map(([c, v]) => "cc" + c + "=" + v);
        if (controls.length) bits.push(controls.join(" "));
        readout.textContent = bits.join("   ·   ");
      }

      function line(side, event) {
        const [kind, ...rest] = event;
        return (side === "in" ? "← " : "→ ") + kind + " " + rest.join(" ");
      }

      function showLog() {
        logEl.textContent = "";
        for (const entry of log) logEl.appendChild(el("div", "entry " + entry.side, entry.text));
      }

      function apply(state) {
        lit.in = new Set(Object.keys(state.keys || {}).map(Number));
        lit.out = new Set(state.sounding || []);
        paint();
        describe(state);
        log = (state.events || []).map(([side, event]) => ({ side, text: line(side, event) }));
        showLog();
      }

      ctx.handleEvent("pcm", ([_info, buffer]) => player.push(buffer));

      ctx.handleEvent("changed", ({ fields: next, state, fault }) => {
        fields = next;
        faultEl.textContent = fault || "";
        apply(state);
      });

      ctx.handleEvent("event", ({ side, event }) => {
        const [kind, _channel, note, velocity] = event;
        const set = side === "in" ? lit.in : lit.out;
        if (kind === "note_on" && velocity > 0) set.add(note);
        if (kind === "note_off" || (kind === "note_on" && velocity === 0)) set.delete(note);
        if (kind === "control" && note === 123) set.clear();
        paint();
        log.unshift({ side, text: line(side, event) });
        if (log.length > 12) log.pop();
        showLog();
      });

      faultEl.textContent = payload.fault || "";
      apply(payload.state);
    }
    """
  end

  asset "main.css" do
    """
    .app { font-family: "Inter", system-ui, sans-serif; color: #1f2937; padding: 4px 0 8px; }
    .bar { display: flex; align-items: center; gap: 10px; padding-bottom: 8px; flex-wrap: wrap; }
    .field { display: flex; flex-direction: column; gap: 3px; font-size: 11px; color: #7b8794; }
    .input { padding: 4px 6px; border: 1px solid #e1e8f0; border-radius: 6px; font-size: 12px; font-family: inherit; color: #1f2937; background: #ffffff; }
    .input.pattern { min-width: 360px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .input.num { width: 64px; }
    .spacer { flex: 1; }
    .volume { width: 90px; }
    .button { padding: 5px 10px; border: 1px solid #e1e8f0; border-radius: 6px; background: #ffffff; font-size: 12px; font-family: inherit; color: #445668; cursor: pointer; align-self: flex-end; }
    .button:hover { border-color: #94a3b8; }
    .button.primary { background: #6583ff; border-color: #6583ff; color: #ffffff; }
    .button.ghost { color: #7b8794; }
    .strip { display: flex; gap: 1px; padding: 6px 0; overflow-x: auto; }
    .key { position: relative; border: 1px solid #cbd5e1; border-radius: 0 0 4px 4px; cursor: pointer; padding: 0; }
    .key.white { width: 18px; height: 56px; background: #ffffff; }
    .key.black { width: 12px; height: 36px; margin: 0 -6px; background: #334155; z-index: 1; }
    .key.in { background: #6583ff; border-color: #6583ff; }
    .key.out { background: #f59e0b; border-color: #f59e0b; }
    .key.in.out { background: linear-gradient(90deg, #6583ff 50%, #f59e0b 50%); }
    .key .label { position: absolute; bottom: 2px; left: 0; right: 0; font-size: 9px; color: #7b8794; text-align: center; pointer-events: none; }
    .readout { font-size: 12px; color: #445668; padding: 4px 0; }
    .fault { font-size: 12px; color: #b91c1c; min-height: 14px; }
    .log { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: #7b8794; }
    .log .entry.in { color: #4c63d2; }
    .log .entry.out { color: #b45309; }
    """
  end
end

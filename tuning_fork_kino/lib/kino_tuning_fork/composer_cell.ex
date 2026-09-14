defmodule KinoTuningFork.ComposerCell do
  @moduledoc """
  A step-sequencer smart cell over `TuningFork.Composer` that writes `TuningFork.Part` source.
  """

  use Kino.JS
  use Kino.JS.Live
  use Kino.SmartCell, name: "Compose"

  alias TuningFork.Composer
  alias TuningFork.Composer.{Json, Source}

  @impl true
  def init(attrs, ctx) do
    project =
      case attrs["tracks"] do
        nil -> Composer.demo()
        _saved -> Json.from_map(attrs)
      end

    {:ok, assign(ctx, project: project)}
  end

  @impl true
  def handle_connect(ctx) do
    {:ok, payload(ctx.assigns.project), ctx}
  end

  defp payload(project) do
    %{
      fields: Json.to_map(project) |> Map.delete("tracks"),
      tracks: Json.to_map(project)["tracks"],
      drums: Enum.map(Composer.drums(), fn {id, label} -> %{id: id, label: label} end),
      instruments:
        Enum.map(Composer.instruments(), fn {id, label} -> %{id: id, label: label} end),
      scales: Enum.map(Composer.scales(), &to_string/1),
      kits: kits()
    }
  end

  defp kits do
    [%{value: "synth", label: "synth"}] ++
      Enum.map(TuningFork.Kit.banks(), &%{value: &1, label: &1})
  end

  @impl true
  def handle_event("update_field", %{"field" => field, "value" => value}, ctx) do
    case field_atom(field) do
      nil ->
        {:noreply, ctx}

      setting ->
        project = Composer.set(ctx.assigns.project, setting, value)

        broadcast_event(ctx, "update_all", payload(project))

        {:noreply, assign(ctx, project: project)}
    end
  end

  def handle_event("update_tracks", %{"tracks" => tracks}, ctx) do
    project = Json.from_map(Map.put(Json.to_map(ctx.assigns.project), "tracks", tracks))

    broadcast_event(ctx, "update_tracks", %{"tracks" => Json.to_map(project)["tracks"]})

    {:noreply, assign(ctx, project: project)}
  end

  defp field_atom(field) do
    Enum.find(Composer.settings(), &(to_string(&1) == field))
  end

  @impl true
  def to_attrs(ctx), do: Json.to_map(ctx.assigns.project)

  @impl true
  def to_source(attrs), do: attrs |> Json.from_map() |> Source.to_source(output: :kino)

  asset "main.js" do
    """
    export function init(ctx, payload) {
      ctx.importCSS("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap");
      ctx.importCSS("main.css");

      let state = {
        fields: payload.fields,
        tracks: payload.tracks,
        drums: payload.drums,
        instruments: payload.instruments,
        scales: payload.scales,
        kits: payload.kits,
      };

      const meter = () => Math.max(Number(state.fields.meter) || 4, 1);
      const division = () => Math.max(Number(state.fields.division) || 4, 1);
      const stepCount = () => meter() * division();


      const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined) n.textContent = text;
        return n;
      };

      function pushTracks() {
        ctx.pushEvent("update_tracks", { tracks: state.tracks });
      }

      function readStep(value) {
        if (value && typeof value === "object") {
          return { degree: value.d || 0, length: Math.max(value.n || 1, 1) };
        }
        return { degree: value || 0, length: 1 };
      }

      function writeStep(degree, length) {
        if (degree <= 0) return 0;
        return length > 1 ? { d: degree, n: length } : degree;
      }

      function startOf(steps, step) {
        for (let s = step; s >= 0; s--) {
          const { degree, length } = readStep(steps[s]);
          if (degree > 0 && s + length > step) return s;
        }
        return step;
      }

      let dragging = null;
      let suppressClick = false;
      let gridEls = {};

      function resize(index, start, length) {
        const track = state.tracks[index];
        if (!track) return;

        const { degree } = readStep(track.steps[start]);
        if (degree <= 0) return;

        let room = track.steps.length - start;
        for (let s = start + 1; s < track.steps.length; s++) {
          if (readStep(track.steps[s]).degree > 0) {
            room = s - start;
            break;
          }
        }

        track.steps[start] = writeStep(degree, Math.min(length, room));
        paint(index);
      }

      function paint(index) {
        const track = state.tracks[index];
        const grid = gridEls[index];
        if (!track || !grid) return;

        const held = coveredBy(track.steps);

        [...grid.children].forEach((cell, step) => {
          const { degree, length } = readStep(track.steps[step]);
          cell.classList.toggle("on", degree > 0);
          cell.classList.toggle("held", held[step]);
          cell.classList.toggle("start", degree > 0 && length > 1);
          cell.textContent = track.kind === "pitched" && degree > 0 ? degree : "";
        });
      }

      function coveredBy(steps) {
        const held = new Array(steps.length).fill(false);

        steps.forEach((value, step) => {
          const { degree, length } = readStep(value);
          if (degree > 0) {
            for (let n = 1; n < length && step + n < held.length; n++) held[step + n] = true;
          }
        });

        return held;
      }

      window.addEventListener("mouseup", () => {
        if (!dragging) return;

        suppressClick = dragging.moved;
        const changed = dragging.moved;
        dragging = null;

        if (changed) pushTracks();
      });

      function header() {
        const bar = el("div", "bar");

        const add = (label, name, type, opts) => {
          const field = el("label", "field");
          field.appendChild(el("span", null, label));

          let input;
          if (type === "select") {
            input = el("select", "input");
            for (const o of opts) {
              const option = el("option", null, o.label);
              option.value = o.value;
              input.appendChild(option);
            }
          } else {
            input = el("input", "input num");
            input.type = "number";
            if (opts) Object.assign(input, opts);
          }

          input.value = state.fields[name];
          input.addEventListener("change", () => {
            const value = type === "select" ? input.value : Number(input.value);
            state.fields[name] = value;
            ctx.pushEvent("update_field", { field: name, value });
          });

          field.appendChild(input);
          bar.appendChild(field);
        };

        add("Tempo", "bpm", "number", { min: 30, max: 300, step: 1 });
        add("Bars", "bars", "number", { min: 1, max: 8, step: 1 });
        add("Beats/bar", "meter", "number", { min: 1, max: 16, step: 1 });
        add("Steps/beat", "division", "number", { min: 1, max: 8, step: 1 });
        add("Key", "root", "select", noteOptions());
        add("Scale", "scale", "select", state.scales.map((s) => ({ value: s, label: s.replace(/_/g, " ") })));
        add("Kit", "kit", "select", state.kits);
        add("Gain", "gain", "number", { min: 0, max: 1, step: 0.05 });
        add("Reverb", "reverb", "number", { min: 0, max: 1, step: 0.1 });

        const spacer = el("div", "spacer");
        bar.appendChild(spacer);

        const hint = el("div", "hint");
        hint.innerHTML = 'click a step to place it · right-click to lower · <b>ctrl + enter</b> to hear it';
        bar.appendChild(hint);

        const addTrack = el("button", "button", "+ track");
        addTrack.addEventListener("click", () => {
          state.tracks.push({
            kind: "drum",
            sound: state.drums[0].id,
            gain: 0.7,
            ring: 2,
            steps: new Array(stepCount()).fill(0),
          });
          pushTracks();
          render();
        });
        bar.appendChild(addTrack);

        return bar;
      }

      function noteOptions() {
        const names = [];
        for (let octave = 1; octave <= 5; octave++) {
          for (const n of ["c","cs","d","ds","e","f","fs","g","gs","a","as","b"]) {
            names.push({ value: `${n}${octave}`, label: `${n.toUpperCase().replace("S", "#")}${octave}` });
          }
        }
        return names;
      }

      function trackRow(track, index) {
        const row = el("div", "track");

        const controls = el("div", "controls");
        row.appendChild(controls);

        const edit = (change) => {
          const current = state.tracks[index];
          if (current) change(current);
          pushTracks();
        };

        const mute = el("button", "button mute", "M");
        mute.title = track.muted ? "muted — click to hear it again" : "mute this track";
        if (track.muted) {
          mute.classList.add("off");
          row.classList.add("dimmed");
        }
        mute.addEventListener("click", () => {
          edit((t) => (t.muted = !t.muted));
          render();
        });
        controls.appendChild(mute);

        const kind = el("select", "input kind");
        for (const k of ["drum", "pitched", "sample"]) {
          const o = el("option", null, k);
          o.value = k;
          kind.appendChild(o);
        }
        kind.value = track.kind;
        kind.addEventListener("change", () => {
          edit((t) => {
            t.kind = kind.value;
            const list = t.kind === "drum" ? state.drums : state.instruments;
            if (t.kind !== "sample") t.sound = list[0].id;
            if (t.kind === "drum") {
              t.steps = t.steps.map((s) => (readStep(s).degree > 0 ? 1 : 0));
            }
          });
          render();
        });
        controls.appendChild(kind);

        let sound;

        if (track.kind === "sample") {
          sound = el("input", "input sound");
          sound.type = "text";
          sound.placeholder = "path/to.wav";
          sound.title = track.path || "path to a WAV file";
          sound.value = track.path || "";
          sound.addEventListener("change", () => edit((t) => (t.path = sound.value)));
        } else {
          sound = el("select", "input sound");
          const list = track.kind === "drum" ? state.drums : state.instruments;

          for (const s of list) {
            const o = el("option", null, s.label);
            o.value = s.id;
            sound.appendChild(o);
          }

          sound.value = track.sound;
          sound.addEventListener("change", () => edit((t) => (t.sound = sound.value)));
        }

        controls.appendChild(sound);

        const root = el("select", "input root");
        const none = el("option", null, "as-is");
        none.value = "";
        root.appendChild(none);

        for (const n of noteOptions()) {
          const o = el("option", null, n.label);
          o.value = n.value;
          root.appendChild(o);
        }

        root.value = track.root || "";
        root.title = "the pitch the recording already is";
        root.disabled = track.kind !== "sample";
        root.addEventListener("change", () => {
          edit((t) => (t.root = root.value));
          render();
        });
        controls.appendChild(root);

        const gain = el("input", "input gain");
        gain.type = "number";
        gain.min = 0; gain.max = 1; gain.step = 0.05;
        gain.value = track.gain;
        gain.addEventListener("change", () => edit((t) => (t.gain = Number(gain.value))));
        controls.appendChild(gain);

        const ring = el("input", "input ring");
        ring.type = "number";
        ring.min = 0.05; ring.max = 16; ring.step = 0.25;
        ring.title = "how long a note rings, in beats";
        ring.value = track.ring === undefined ? 2 : track.ring;
        ring.disabled = track.kind === "drum";
        ring.addEventListener("change", () => edit((t) => (t.ring = Number(ring.value))));
        controls.appendChild(ring);

        const grid = el("div", "grid");
        gridEls[index] = grid;

        const held = coveredBy(track.steps);

        track.steps.forEach((value, step) => {
          const { degree, length } = readStep(value);
          const cell = el("button", "cell");
          if (degree > 0) cell.classList.add("on");
          if (held[step]) cell.classList.add("held");
          if (degree > 0 && length > 1) cell.classList.add("start");
          if (step % division() === 0) cell.classList.add("downbeat");
          if (track.kind === "pitched" && degree > 0) cell.textContent = degree;

          const setStep = (next) => {
            const current = state.tracks[index];
            if (!current) return;
            current.steps[step] = next(readStep(current.steps[step]));
            pushTracks();
            render();
          };

          cell.addEventListener("click", (event) => {
            event.preventDefault();
            if (suppressClick) { suppressClick = false; return; }
            setStep(({ degree, length }) => {
              const next =
                track.kind === "drum"
                  ? degree > 0 ? 0 : 1
                  : degree >= 8 ? 0 : degree + 1;
              return writeStep(next, length);
            });
          });

          cell.addEventListener("contextmenu", (event) => {
            event.preventDefault();
            setStep(({ degree, length }) => {
              const next =
                track.kind === "drum"
                  ? degree > 0 ? 0 : 1
                  : degree <= 0 ? 8 : degree - 1;
              return writeStep(next, length);
            });
          });

          if (track.kind === "pitched") {
            cell.addEventListener("mousedown", (event) => {
              if (event.button !== 0) return;
              const start = held[step] ? startOf(track.steps, step) : step;
              const { degree } = readStep(track.steps[start]);
              if (degree <= 0) return;

              dragging = { index, start, moved: false };
              event.preventDefault();
            });

            cell.addEventListener("mouseenter", () => {
              if (!dragging || dragging.index !== index) return;
              if (step < dragging.start) return;

              dragging.moved = true;
              resize(index, dragging.start, step - dragging.start + 1);
            });
          }

          grid.appendChild(cell);
        });
        row.appendChild(grid);

        const tail = el("div", "tail");

        const clear = el("button", "button ghost", "clear");
        clear.addEventListener("click", () => {
          edit((t) => (t.steps = t.steps.map(() => 0)));
          render();
        });
        tail.appendChild(clear);

        const remove = el("button", "button ghost", "×");
        remove.addEventListener("click", () => {
          state.tracks.splice(index, 1);
          pushTracks();
          render();
        });
        tail.appendChild(remove);
        row.appendChild(tail);

        return row;
      }

      function ruler() {
        const row = el("div", "track ruler");

        const controls = el("div", "controls");

        const spacers =
          ["button mute", "input kind", "input sound", "input root", "input gain", "input ring"];

        for (const cls of spacers) {
          controls.appendChild(el("div", cls + " hidden"));
        }

        row.appendChild(controls);

        const grid = el("div", "grid");

        for (let step = 0; step < stepCount(); step++) {
          const beat = step % division() === 0 ? String(step / division() + 1) : "";
          grid.appendChild(el("div", "tick", beat));
        }

        row.appendChild(grid);

        const tail = el("div", "tail");
        tail.appendChild(el("div", "button hidden", "clear"));
        tail.appendChild(el("div", "button ghost hidden", "×"));
        row.appendChild(tail);

        return row;
      }

      function render() {
        ctx.root.innerHTML = "";
        gridEls = {};
        const app = el("div", "app");
        app.appendChild(header());

        const tracks = el("div", "tracks");
        if (state.tracks.length > 0) tracks.appendChild(ruler());
        state.tracks.forEach((t, i) => tracks.appendChild(trackRow(t, i)));
        app.appendChild(tracks);

        if (state.tracks.length === 0) {
          app.appendChild(el("div", "empty", "No tracks. Add one to start."));
        }

        ctx.root.appendChild(app);
      }

      ctx.handleEvent("update_all", (next) => {
        state.fields = next.fields;
        state.tracks = next.tracks;
        render();
      });

      ctx.handleEvent("update_tracks", ({ tracks }) => {
        state.tracks = tracks;
      });

      render();
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
      gap: 10px;
      align-items: flex-end;
      flex-wrap: wrap;
      padding-bottom: 10px;
      border-bottom: 1px solid #e8edf3;
      margin-bottom: 10px;
    }

    .spacer { flex: 1; }

    .field { display: flex; flex-direction: column; gap: 3px; }
    .field > span { font-size: 11px; color: #7b8794; }

    .input, .button, .cell { box-sizing: border-box; }

    .input {
      padding: 5px 7px;
      background: #f8fafc;
      border: 1px solid #e1e8f0;
      border-radius: 6px;
      font-size: 13px;
      font-family: inherit;
      color: #1f2937;
    }

    .input:focus { outline: none; border-color: #6583ff; }
    .input.num { width: 72px; }
    .input.kind { width: 88px; }
    .input.sound { width: 104px; }
    .input.gain { width: 64px; }
    .input.root { width: 72px; }
    .input.ring { width: 64px; }
    .input:disabled { background: #f1f5f9; color: #cbd5e1; }

    .tracks {
      display: flex;
      flex-direction: column;
      gap: 5px;
      overflow-x: auto;
      overflow-y: hidden;
      padding-bottom: 4px;
    }

    .track {
      display: flex;
      align-items: center;
      gap: 6px;
      width: max-content;
    }

    .controls {
      position: sticky;
      left: 0;
      z-index: 2;
      display: flex;
      align-items: center;
      gap: 6px;
      padding-right: 6px;
      background: #ffffff;
      box-shadow: 6px 0 6px -6px rgba(15, 23, 42, 0.18);
    }

    .tail { display: flex; align-items: center; gap: 6px; }

    .grid {
      display: grid;
      grid-auto-flow: column;
      grid-auto-columns: 24px;
      gap: 3px;
    }

    .cell {
      height: 26px;
      border: 1px solid #e1e8f0;
      border-radius: 4px;
      background: #f8fafc;
      cursor: pointer;
      padding: 0;
      font-size: 11px;
      font-family: inherit;
      color: #445668;
      transition: background 80ms, border-color 80ms;
    }

    .cell.downbeat { border-color: #cbd5e1; background: #f1f5f9; }
    .cell:hover { border-color: #94a3b8; }

    .cell.on {
      background: #6583ff;
      border-color: #6583ff;
      color: #ffffff;
      font-weight: 500;
    }

    .cell.held {
      background: #a5b4ff;
      border-color: #a5b4ff;
      border-left-color: #a5b4ff;
      border-radius: 0 4px 4px 0;
      margin-left: -4px;
      padding-left: 4px;
    }

    .cell.start { border-radius: 4px 0 0 4px; }

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
    .button.ghost { padding: 5px 8px; color: #7b8794; }

    .button.mute {
      width: 28px;
      padding: 5px 0;
      text-align: center;
      font-weight: 500;
      color: #94a3b8;
    }

    .button.mute.off {
      background: #fee2e2;
      border-color: #fca5a5;
      color: #b91c1c;
    }

    .track.dimmed .cell.on { background: #c7d2e4; border-color: #c7d2e4; }
    .track.dimmed .cell.held { background: #e2e8f0; border-color: #e2e8f0; }
    .track.dimmed .input { color: #94a3b8; }

    .empty {
      padding: 16px;
      text-align: center;
      color: #7b8794;
      font-size: 13px;
    }

    .hint {
      font-size: 11px;
      color: #7b8794;
      padding-bottom: 6px;
    }

    .hint b { color: #445668; font-weight: 600; }

    .ruler { height: 16px; }

    .ruler .input, .ruler .button {
      height: 0;
      padding-top: 0;
      padding-bottom: 0;
      border-top-width: 0;
      border-bottom-width: 0;
    }

    .hidden { visibility: hidden; }

    .tick {
      font-size: 10px;
      color: #94a3b8;
      text-align: center;
      line-height: 14px;
    }
    """
  end
end

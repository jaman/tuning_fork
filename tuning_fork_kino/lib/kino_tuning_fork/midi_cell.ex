defmodule KinoTuningFork.MidiCell do
  @moduledoc """
  A smart cell that writes source rendering a MIDI file to browser-playable audio.
  """

  use Kino.JS
  use Kino.JS.Live
  use Kino.SmartCell, name: "MIDI to audio"

  @rate 44_100

  @impl true
  @defaults %{
    "path" => "",
    "bpm" => "",
    "gain" => "0.2",
    "drum_gain" => "1.0",
    "drums" => "auto",
    "reverb" => "",
    "loops" => "1",
    "plain" => false,
    "variable" => "score"
  }

  def init(attrs, ctx) do
    fields = Map.new(@defaults, fn {field, default} -> {field, attrs[field] || default} end)

    {:ok, assign(ctx, fields: fields)}
  end

  @impl true
  def handle_connect(ctx) do
    {:ok, %{fields: ctx.assigns.fields}, ctx}
  end

  @impl true
  def handle_event("update_field", %{"field" => field, "value" => value}, ctx) do
    fields = Map.put(ctx.assigns.fields, field, value)

    broadcast_event(ctx, "update", %{"fields" => %{field => value}})

    {:noreply, assign(ctx, fields: fields)}
  end

  @impl true
  def to_attrs(ctx), do: ctx.assigns.fields

  @doc """
  The cell's source from its saved attributes, or `""` while `"path"` is blank.

  Attributes, all strings unless noted:

    * `"path"` — the MIDI file to read; a relative path is taken from the notebook's directory.
    * `"variable"` — the variable the score is bound to, default `"score"`. A name that would
      not compile falls back to `"score"`.
    * `"bpm"` — tempo to play at. Blank uses the file's own.
    * `"gain"` — level per note, default `"0.2"`.
    * `"drum_gain"` — the kit's level against everything else, default `"1.0"`.
    * `"drums"` — `"auto"`, `"gm"` for channel 10 only, or `"all"` for every channel.
    * `"reverb"` — room size, 0.0 to 1.0. Blank leaves it out.
    * `"loops"` — how many times the rendered audio repeats, default `"1"`.
    * `"plain"` — `true` for one voice for everything rather than one per instrument.
  """
  @impl true
  def to_source(attrs) do
    case String.trim(attrs["path"] || "") do
      "" -> ""
      path -> build_source(path, attrs)
    end
  end

  defp build_source(path, attrs) do
    variable = variable_name(attrs["variable"])

    """
    #{variable} =
      #{located(path)}
      |> TuningFork.Midi.read!()
      |> TuningFork.Gm.score(#{score_opts(attrs)})

    #{variable}
    |> TuningFork.Score.render(#{@rate})#{render_pipeline(attrs)}
    |> TuningFork.Wav.encode(rate: #{@rate})
    |> Kino.Audio.new(:wav)\
    """
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  defp located(path) do
    case Path.type(path) do
      :absolute -> inspect(path)
      _relative -> "Path.expand(#{inspect(path)}, __DIR__)"
    end
  end

  defp score_opts(attrs) do
    [
      {"gain", number(attrs["gain"], 0.2)},
      {"drum_gain", number(attrs["drum_gain"], 1.0)},
      {"bpm", number(attrs["bpm"], nil)},
      {"drum_channels", drum_channels(attrs["drums"])},
      {"plain", if(attrs["plain"] in [true, "true"], do: true)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join(", ", fn {key, value} ->
      "#{key}: #{inspect(value, charlists: :as_lists)}"
    end)
  end

  defp render_pipeline(attrs) do
    reverb =
      case number(attrs["reverb"], nil) do
        nil -> ""
        room -> "\n|> TuningFork.Fx.reverb(#{@rate}, room: #{room}, mix: 0.22)"
      end

    loops =
      case number(attrs["loops"], 1) do
        count when is_number(count) and count > 1 ->
          "\n|> List.duplicate(#{trunc(count)}) |> IO.iodata_to_binary()"

        _once ->
          ""
      end

    loops <> reverb
  end

  defp drum_channels("all"), do: Enum.to_list(0..15)
  defp drum_channels("gm"), do: [9]
  defp drum_channels(_auto), do: :auto

  defp number(value, _default) when is_number(value), do: value

  defp number(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> if number == trunc(number), do: trunc(number), else: number
      :error -> default
    end
  end

  defp number(_value, default), do: default

  defp variable_name(name) do
    case String.trim(name || "") do
      "" -> "score"
      trimmed -> if Kino.SmartCell.valid_variable_name?(trimmed), do: trimmed, else: "score"
    end
  end

  asset "main.js" do
    """
    export function init(ctx, payload) {
      ctx.importCSS("https://fonts.googleapis.com/css2?family=Inter:wght@400;500&display=swap");

      ctx.root.innerHTML = `
        <div class="app">
          <div class="header">
            <span class="title">MIDI to audio</span>
          </div>
          <div class="row">
            <label class="field grow">
              <span>MIDI file</span>
              <input class="input" type="text" name="path" placeholder="path/to/song.mid" />
            </label>
            <label class="field">
              <span>Assign to</span>
              <input class="input small" type="text" name="variable" />
            </label>
          </div>
          <div class="row">
            <label class="field">
              <span>Tempo</span>
              <input class="input small" type="number" name="bpm" placeholder="file" />
            </label>
            <label class="field">
              <span>Gain</span>
              <input class="input small" type="number" name="gain" step="0.01" />
            </label>
            <label class="field">
              <span>Drum gain</span>
              <input class="input small" type="number" name="drum_gain" step="0.05" />
            </label>
            <label class="field">
              <span>Drums on</span>
              <select class="input" name="drums">
                <option value="auto">guess</option>
                <option value="gm">channel 10</option>
                <option value="all">every channel</option>
              </select>
            </label>
            <label class="field">
              <span>Reverb</span>
              <input class="input small" type="number" name="reverb" step="0.1" min="0" max="1" placeholder="none" />
            </label>
            <label class="field">
              <span>Repeats</span>
              <input class="input small" type="number" name="loops" min="1" />
            </label>
            <label class="field check">
              <span>One voice</span>
              <input type="checkbox" name="plain" />
            </label>
          </div>
        </div>
      `;

      const fieldEls = ctx.root.querySelectorAll("[name]");

      fieldEls.forEach((el) => {
        const name = el.getAttribute("name");
        const value = payload.fields[name];

        if (el.type === "checkbox") {
          el.checked = value === true || value === "true";
        } else {
          el.value = value ?? "";
        }

        const event = el.tagName === "SELECT" || el.type === "checkbox" ? "input" : "change";

        el.addEventListener(event, () => {
          const next = el.type === "checkbox" ? el.checked : el.value;
          ctx.pushEvent("update_field", { field: name, value: next });
        });
      });

      ctx.handleEvent("update", ({ fields }) => {
        for (const [name, value] of Object.entries(fields)) {
          const el = ctx.root.querySelector(`[name="${name}"]`);
          if (!el) continue;
          if (el.type === "checkbox") {
            el.checked = value === true;
          } else if (el.value !== value) {
            el.value = value ?? "";
          }
        }
      });
    }
    """
  end

  asset "main.css" do
    """
    .app {
      font-family: "Inter", system-ui, sans-serif;
      padding: 8px 0;
    }

    .header { margin-bottom: 8px; }

    .title {
      font-size: 14px;
      font-weight: 500;
      color: #445668;
    }

    .row {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: flex-end;
      margin-bottom: 8px;
    }

    .field { display: flex; flex-direction: column; gap: 4px; }
    .field.grow { flex: 1; min-width: 220px; }

    .field > span {
      font-size: 12px;
      color: #61758a;
    }

    .field.check {
      flex-direction: row;
      align-items: center;
      gap: 6px;
      padding-bottom: 8px;
    }

    .input {
      padding: 6px 8px;
      background: #f8fafc;
      border: 1px solid #e1e8f0;
      border-radius: 6px;
      font-size: 13px;
      color: #1f2937;
      min-width: 0;
    }

    .input.small { width: 88px; }
    .input:focus { outline: none; border-color: #6583ff; }
    """
  end
end

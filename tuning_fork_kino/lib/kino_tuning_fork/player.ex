defmodule KinoTuningFork.Player do
  @moduledoc """
  The streaming audio player the live-coding cells and `KinoTuningFork.Stage` embed, as
  JavaScript.

      main_js = KinoTuningFork.Player.js() <> "export function init(ctx, payload) { const player = tuningForkPlayer(ctx); }"
  """

  @doc """
  The player, as JavaScript source defining a `tuningForkPlayer(ctx)` factory to interpolate
  into a cell's `main.js`. Each call to the factory gives one independent player, which
  tells the cell through `ctx` when it starts and stops listening (`"listening"`, `%{"on"
  => boolean}`), so the cell streams PCM only while a page can play it.

  A player has:

    * `start(rate, channels)` — make or resume the `AudioContext` and begin taking chunks.
      Must be called from a click handler.
    * `push(arrayBuffer)` — schedule a chunk of signed 16-bit little-endian interleaved PCM
      right after the last one. Dropped while stopped. Returns the chunk's peak, 0 to 1.
    * `stop()` — cut everything scheduled and stop taking chunks.
    * `playing()` — whether it is taking chunks.
    * `time()` — seconds since `start`.
    * `volume(level)` — 0 to 1.
  """
  @spec js() :: String.t()
  def js do
    """
    function tuningForkPlayer(ctx) {
      let context = null;
      let gain = null;
      let rate = 44100;
      let channels = 2;
      let running = false;
      let next = 0;
      let startedAt = 0;
      let scheduled = [];

      function prime() {
        if (!context) {
          const Context = window.AudioContext || window.webkitAudioContext;
          context = new Context();
          gain = context.createGain();
          gain.connect(context.destination);
        }

        if (context.state === "suspended") context.resume();

        return context;
      }

      function cut() {
        for (const source of scheduled) {
          try { source.stop(); } catch (ignored) {}
          source.disconnect();
        }

        scheduled = [];
      }

      return {
        start: function (sampleRate, channelCount) {
          prime();
          rate = sampleRate || rate;
          channels = channelCount || channels;
          running = true;
          next = 0;
          startedAt = context.currentTime;
          if (ctx) ctx.pushEvent("listening", { on: true });
        },

        push: function (arrayBuffer) {
          if (!running) return 0;

          const view = new DataView(arrayBuffer);
          const frames = Math.floor(arrayBuffer.byteLength / (2 * channels));
          if (frames === 0) return 0;

          const buffer = context.createBuffer(channels, frames, rate);
          let peak = 0;

          for (let channel = 0; channel < channels; channel++) {
            const data = buffer.getChannelData(channel);

            for (let frame = 0; frame < frames; frame++) {
              const sample = view.getInt16((frame * channels + channel) * 2, true) / 32768;
              data[frame] = sample;
              if (Math.abs(sample) > peak) peak = Math.abs(sample);
            }
          }

          const source = context.createBufferSource();
          source.buffer = buffer;
          source.connect(gain);

          const at = Math.max(next, context.currentTime + 0.05);
          source.start(at);
          next = at + buffer.duration;

          scheduled.push(source);
          scheduled = scheduled.filter((kept) => kept === source || !kept.done);
          source.onended = () => { source.done = true; };

          return peak;
        },

        stop: function () {
          running = false;
          next = 0;
          cut();
          if (ctx) ctx.pushEvent("listening", { on: false });
        },

        playing: function () {
          return running;
        },

        time: function () {
          return running && context ? context.currentTime - startedAt : 0;
        },

        volume: function (level) {
          if (gain) gain.gain.value = level;
        },
      };
    }
    """
  end
end

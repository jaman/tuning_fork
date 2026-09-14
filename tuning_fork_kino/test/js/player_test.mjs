import { tuningForkPlayer } from "./player.mjs";
import assert from "node:assert";

let now = 0;
const started = [];
const stopped = [];

class FakeBuffer {
  constructor(channels, frames, rate) { this.channels = channels; this.length = frames; this.duration = frames / rate; this.data = Array.from({ length: channels }, () => new Float32Array(frames)); }
  getChannelData(channel) { return this.data[channel]; }
}

class FakeSource {
  constructor() { this.buffer = null; }
  connect() {}
  disconnect() {}
  start(when) { started.push({ at: when, duration: this.buffer.duration, buffer: this.buffer }); this.running = true; }
  stop() { if (!this.running) throw new Error("not started"); stopped.push(now); this.running = false; }
}

class FakeGain { constructor() { this.gain = { value: 1 }; } connect() {} }

global.window = {
  AudioContext: class {
    constructor() { this.state = "running"; this.destination = {}; }
    get currentTime() { return now; }
    createGain() { return new FakeGain(); }
    createBuffer(channels, frames, rate) { return new FakeBuffer(channels, frames, rate); }
    createBufferSource() { return new FakeSource(); }
    resume() { this.state = "running"; }
  },
};

const chunk = (frames, value) => {
  const bytes = new ArrayBuffer(frames * 2 * 2);
  const view = new DataView(bytes);
  for (let i = 0; i < frames * 2; i++) view.setInt16(i * 2, value, true);
  return bytes;
};

const player = tuningForkPlayer();

assert.equal(player.playing(), false, "nothing plays before it is asked to");
assert.equal(player.push(chunk(100, 1000)), 0, "a chunk pushed while stopped is dropped");
assert.equal(started.length, 0);

player.start(1000, 2);
assert.equal(player.playing(), true);

const peak = player.push(chunk(100, 16384));
assert.equal(started.length, 1, "a chunk is scheduled");
assert.ok(Math.abs(peak - 0.5) < 0.001, "the peak comes back, 0 to 1");
assert.ok(started[0].at >= now + 0.05, "the first chunk starts a little ahead of now");
assert.equal(started[0].duration, 0.1, "frames over the rate is the duration");
assert.ok(Math.abs(started[0].buffer.getChannelData(1)[3] - 0.5) < 0.001, "interleaved samples land in their channel");

player.push(chunk(100, 0));
assert.ok(Math.abs(started[1].at - (started[0].at + 0.1)) < 1e-9, "the next chunk follows on exactly");

now = 5;
player.push(chunk(100, 0));
assert.ok(started[2].at >= 5.05, "a chunk arriving late is not scheduled in the past");
assert.equal(player.time(), 5, "time counts from start");

player.stop();
assert.equal(player.playing(), false);
assert.equal(stopped.length, 3, "stopping cuts everything scheduled");
assert.equal(player.push(chunk(100, 0)), 0, "and takes nothing more");
player.stop();

player.volume(0.5);

console.log("player: " + started.length + " chunks scheduled, " + stopped.length + " cut, as expected");

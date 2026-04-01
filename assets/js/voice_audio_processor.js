// Voice audio processing pipeline using Web Audio API.
//
// Processing chain:
//   mic stream → high-pass (80Hz) → low-pass (14kHz) → noise gate → compressor → output stream
//
// Fixes:
//   - Low-frequency rumble (desk bumps, HVAC, footsteps) — high-pass filter
//   - High-frequency hiss/whine (electronics, aliasing) — low-pass filter
//   - Keyboard/mouse clicks, breathing during silence — noise gate
//   - Volume spikes from yelling/laughing — compressor/limiter
//   - Quiet speech from being far from mic — compressor makeup gain
//   - Inconsistent volume from head movement — compressor
//   - Speaking detection for UI indicators — analyser node

export class VoiceAudioProcessor {
  constructor() {
    this.ctx = null;
    this.nodes = {};
    this.speaking = false;
    this.onSpeakingChange = null;
    this._animFrame = null;
  }

  // Takes a raw mic MediaStream, returns a processed MediaStream.
  process(sourceStream) {
    this.ctx = new AudioContext({ sampleRate: 48000 });
    // AudioContext may start suspended if created outside a direct user gesture
    if (this.ctx.state === "suspended") {
      this.ctx.resume();
    }
    const source = this.ctx.createMediaStreamSource(sourceStream);
    const destination = this.ctx.createMediaStreamDestination();

    // High-pass filter — cuts rumble below 80Hz
    const highpass = this.ctx.createBiquadFilter();
    highpass.type = "highpass";
    highpass.frequency.value = 80;
    highpass.Q.value = 0.7;

    // Low-pass filter — cuts hiss above 14kHz
    const lowpass = this.ctx.createBiquadFilter();
    lowpass.type = "lowpass";
    lowpass.frequency.value = 14000;
    lowpass.Q.value = 0.7;

    // Analyser — monitors volume for noise gate + speaking detection
    const analyser = this.ctx.createAnalyser();
    analyser.fftSize = 2048;
    analyser.smoothingTimeConstant = 0.3;

    // Noise gate — silences mic when not speaking
    // Start open (gain=1) so audio passes immediately; gate closes during silence
    const gate = this.ctx.createGain();
    gate.gain.value = 1;

    // Compressor — evens out volume, prevents clipping
    const compressor = this.ctx.createDynamicsCompressor();
    compressor.threshold.value = -24;
    compressor.knee.value = 30;
    compressor.ratio.value = 4;
    compressor.attack.value = 0.003;
    compressor.release.value = 0.25;

    // Chain: source → highpass → lowpass → gate → compressor → destination
    //                                 ↘ analyser (side-chain, no audio output)
    source.connect(highpass);
    highpass.connect(lowpass);
    lowpass.connect(gate);
    lowpass.connect(analyser);
    gate.connect(compressor);
    compressor.connect(destination);

    this.nodes = { source, highpass, lowpass, analyser, gate, compressor, destination };
    this._startNoiseGate();

    return destination.stream;
  }

  _startNoiseGate() {
    const { analyser, gate } = this.nodes;
    const dataArray = new Float32Array(analyser.fftSize);

    const THRESHOLD_DB = -50;
    const OPEN_TIME = 0.01;   // 10ms — fast open so words aren't clipped
    const CLOSE_TIME = 0.2;   // 200ms — slow close to keep word tails

    let gateOpen = true;

    const tick = () => {
      analyser.getFloatTimeDomainData(dataArray);

      // RMS volume in dB
      let sum = 0;
      for (let i = 0; i < dataArray.length; i++) {
        sum += dataArray[i] * dataArray[i];
      }
      const rms = Math.sqrt(sum / dataArray.length);
      const db = 20 * Math.log10(Math.max(rms, 1e-10));

      const shouldOpen = db > THRESHOLD_DB;

      if (shouldOpen && !gateOpen) {
        gate.gain.setTargetAtTime(1, this.ctx.currentTime, OPEN_TIME);
        gateOpen = true;
      } else if (!shouldOpen && gateOpen) {
        gate.gain.setTargetAtTime(0, this.ctx.currentTime, CLOSE_TIME);
        gateOpen = false;
      }

      // Emit speaking state changes for UI (green border, etc.)
      if (gateOpen !== this.speaking) {
        this.speaking = gateOpen;
        if (this.onSpeakingChange) this.onSpeakingChange(gateOpen);
      }

      this._animFrame = requestAnimationFrame(tick);
    };

    this._animFrame = requestAnimationFrame(tick);
  }

  destroy() {
    if (this._animFrame) {
      cancelAnimationFrame(this._animFrame);
      this._animFrame = null;
    }
    Object.values(this.nodes).forEach(node => {
      try { node.disconnect(); } catch (_) {}
    });
    this.nodes = {};
    if (this.ctx && this.ctx.state !== "closed") {
      this.ctx.close();
    }
    this.ctx = null;
    this.speaking = false;
  }
}

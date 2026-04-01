// ICE servers — STUN for discovery, TURN for relay when direct connection fails.
// TURN credentials are injected by the server via window.__TURN__ (set in root.html.heex
// from environment variables, so no credentials appear in source code).
const turn = window.__TURN__;
const iceServers = [
  { urls: "stun:stun.l.google.com:19302" },
  ...(turn
    ? [{ urls: ["turn:global.relay.metered.ca:80", "turn:global.relay.metered.ca:443"], username: turn.username, credential: turn.credential }]
    : []),
];

const Hooks = {};

// VoiceChannel hook — one per voice session, handles the full WebRTC lifecycle.
//
// Flow:
//   1. mounted() → getUserMedia → create RTCPeerConnection → addTrack → createOffer
//   2. pushEvent("voice_offer") → server processes it → pushes "voice_answer"
//   3. setRemoteDescription(answer) → ICE exchange completes → audio flows
//
// Renegotiation (when participants join/leave):
//   Server sends "voice_offer" → we createAnswer → pushEvent("voice_answer")
//
// Mute/deafen come through "voice_mute_changed" / "voice_deafen_changed" events.
Hooks.VoiceChannel = {
  async mounted() {
    this.pc = null;
    this.audioEl = null;
    this.remoteStream = null;
    this.localStream = null;

    try {
      await this.setupWebRTC();
    } catch (err) {
      console.error("[VoiceChannel] setup failed:", err);
    }
  },

  async setupWebRTC() {
    // 1. Capture mic — use raw stream so system AEC/NS/AGC works correctly.
    // NOTE: routing mic audio through a custom AudioContext (Web Audio API) breaks
    // system-level Acoustic Echo Cancellation on mobile, causing feedback loops.
    this.localStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });

    // 2. Shared MediaStream for all incoming remote audio tracks
    this.remoteStream = new MediaStream();
    this.audioEl = new Audio();
    this.audioEl.autoplay = true;
    this.audioEl.srcObject = this.remoteStream;
    document.body.appendChild(this.audioEl);
    // iOS Safari requires an explicit play() call — autoplay alone is not enough
    this.audioEl.play().catch(() => {
      // Autoplay blocked; will retry when first remote track arrives
    });

    // 3. Create PeerConnection
    this.pc = new RTCPeerConnection({ iceServers });

    // Local mic tracks → server
    for (const track of this.localStream.getAudioTracks()) {
      this.pc.addTrack(track, this.localStream);
    }

    // ICE candidates → server
    this.pc.onicecandidate = ({ candidate }) => {
      if (!candidate) return;
      this.pushEvent("voice_ice_candidate", {
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      });
    };

    // Incoming audio tracks from server (one per other participant).
    // Re-call play() on each new track — required on iOS when tracks arrive after renegotiation.
    this.pc.ontrack = ({ track }) => {
      this.remoteStream.addTrack(track);
      if (this.audioEl) {
        this.audioEl.play().catch(() => {});
      }
    };

    this.pc.onconnectionstatechange = () => {
      console.log("[VoiceChannel] connection:", this.pc.connectionState);
    };

    // Server-initiated offer (renegotiation when participant joins/leaves)
    this.handleEvent("voice_offer", async ({ type, sdp }) => {
      try {
        await this.pc.setRemoteDescription({ type, sdp });
        const answer = await this.pc.createAnswer();
        await this.pc.setLocalDescription(answer);
        this.pushEvent("voice_answer", { type: answer.type, sdp: answer.sdp });
      } catch (err) {
        console.error("[VoiceChannel] renegotiation failed:", err);
      }
    });

    // Server answer to our initial offer
    this.handleEvent("voice_answer", async ({ type, sdp }) => {
      try {
        await this.pc.setRemoteDescription({ type, sdp });
      } catch (err) {
        console.error("[VoiceChannel] setRemoteDescription(answer) failed:", err);
      }
    });

    // ICE candidate from server
    this.handleEvent("voice_ice_candidate", async ({ candidate, sdpMid, sdpMLineIndex }) => {
      try {
        await this.pc.addIceCandidate({ candidate, sdpMid, sdpMLineIndex });
      } catch (err) {
        console.error("[VoiceChannel] addIceCandidate failed:", err);
      }
    });

    // Mute: disable/enable mic tracks
    this.handleEvent("voice_mute_changed", ({ muted }) => {
      this.localStream.getAudioTracks().forEach((t) => (t.enabled = !muted));
    });

    // Deafen: mute/unmute audio output
    this.handleEvent("voice_deafen_changed", ({ deafened }) => {
      if (this.audioEl) this.audioEl.muted = deafened;
    });

    // 4. Browser-initiated offer (initial connection)
    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);
    this.pushEvent("voice_offer", { type: offer.type, sdp: offer.sdp });
  },

  destroyed() {
    if (this.localStream) {
      this.localStream.getTracks().forEach(t => t.stop());
    }
    if (this.pc) {
      this.pc.close();
      this.pc = null;
    }
    if (this.audioEl) {
      this.audioEl.pause();
      this.audioEl.srcObject = null;
      document.body.removeChild(this.audioEl);
      this.audioEl = null;
    }
    this.remoteStream = null;
    this.localStream = null;
  },
};

Hooks.MessageFeed = {
  mounted() {
    this.loadingMore = false;
    this.scrollToBottom();

    this.el.addEventListener("scroll", () => {
      if (
        this.el.scrollTop < 200 &&
        !this.loadingMore &&
        this.el.dataset.hasMore === "true"
      ) {
        this.loadingMore = true;
        this.pushEvent("load_more_messages", {});
      }
    });

    this.handleEvent("scroll_to_bottom", () => {
      if (this.isNearBottom()) {
        requestAnimationFrame(() => this.scrollToBottom());
      }
    });
  },

  beforeUpdate() {
    this._oldScrollHeight = this.el.scrollHeight;
    this._oldScrollTop = this.el.scrollTop;
    this._wasNearBottom = this.isNearBottom();
    this._oldChannelId = this.el.dataset.channelId;
  },

  updated() {
    const channelChanged = this.el.dataset.channelId !== this._oldChannelId;

    if (channelChanged) {
      this.loadingMore = false;
      this.scrollToBottom();
    } else if (this.loadingMore) {
      const addedHeight = this.el.scrollHeight - this._oldScrollHeight;
      this.el.scrollTop = this._oldScrollTop + addedHeight;
      this.loadingMore = false;
    } else if (this._wasNearBottom) {
      this.scrollToBottom();
    }
  },

  isNearBottom() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 200;
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

export default Hooks;

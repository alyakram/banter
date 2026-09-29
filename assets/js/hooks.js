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
//   1. start() → getUserMedia → create RTCPeerConnection → addTrack → createOffer
//   2. pushEvent("voice_offer") → server processes it → pushes "voice_answer"
//   3. setRemoteDescription(answer) → ICE exchange completes → audio flows
//
// Renegotiation (when participants join/leave):
//   Server sends "voice_offer" → we createAnswer → pushEvent("voice_answer")
//
// If the connection is lost, the server brings up a new Peer and pushes
// "voice_restart"; start() tears this side down and runs the flow again
// against it. Anything that stops the flow starting is reported as
// "voice_failed".
//
// Mute/deafen come through "voice_mute_changed" / "voice_deafen_changed".
Hooks.VoiceChannel = {
  mounted() {
    this.pc = null;
    this.audioEl = null;
    this.remoteStream = null;
    this.localStream = null;
    // Which start() is current; an older one still awaiting the mic stands
    // down when it resumes.
    this.generation = 0;
    // What the server last asked for. Kept here and applied whenever there's a
    // stream to apply it to: the server pushes these as soon as the Peer
    // exists, which is before the mic is open.
    this.muted = false;
    this.deafened = false;

    // Registered once, not per start(): a restart would otherwise register
    // each a second time. They act on whichever connection is current.
    this.handleEvent("voice_offer", async ({ type, sdp }) => {
      if (!this.pc) return;
      try {
        await this.pc.setRemoteDescription({ type, sdp });
        const answer = await this.pc.createAnswer();
        await this.pc.setLocalDescription(answer);
        this.pushEvent("voice_answer", { type: answer.type, sdp: answer.sdp });
      } catch (err) {
        console.error("[VoiceChannel] renegotiation failed:", err);
      }
    });

    this.handleEvent("voice_answer", async ({ type, sdp }) => {
      if (!this.pc) return;
      try {
        await this.pc.setRemoteDescription({ type, sdp });
      } catch (err) {
        console.error("[VoiceChannel] setRemoteDescription(answer) failed:", err);
      }
    });

    this.handleEvent("voice_ice_candidate", async ({ candidate, sdpMid, sdpMLineIndex }) => {
      if (!this.pc) return;
      try {
        await this.pc.addIceCandidate({ candidate, sdpMid, sdpMLineIndex });
      } catch (err) {
        console.error("[VoiceChannel] addIceCandidate failed:", err);
      }
    });

    this.handleEvent("voice_mute_changed", ({ muted }) => {
      this.muted = muted;
      this.applyMute();
    });

    this.handleEvent("voice_deafen_changed", ({ deafened }) => {
      this.deafened = deafened;
      this.applyDeafen();
    });

    this.handleEvent("voice_restart", () => this.start());

    this.start();
  },

  async start() {
    const generation = ++this.generation;
    this.teardown();

    try {
      await this.setupWebRTC(generation);
    } catch (err) {
      if (generation !== this.generation) return;
      console.error("[VoiceChannel] setup failed:", err);
      // Nothing reached the server, so it can't find out any other way. The
      // error name (NotAllowedError for a denied mic, NotFoundError for none)
      // picks the message the user sees.
      this.pushEvent("voice_failed", { reason: err?.name || "Error" });
    }
  },

  async setupWebRTC(generation) {
    // 1. Capture mic — use raw stream so system AEC/NS/AGC works correctly.
    // NOTE: routing mic audio through a custom AudioContext (Web Audio API) breaks
    // system-level Acoustic Echo Cancellation on mobile, causing feedback loops.
    const localStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });

    // A newer start() began while the mic prompt was open; it owns the session.
    if (generation !== this.generation) {
      localStream.getTracks().forEach((t) => t.stop());
      return;
    }

    this.localStream = localStream;
    this.applyMute();

    // 2. Shared MediaStream for all incoming remote audio tracks
    this.remoteStream = new MediaStream();
    this.audioEl = new Audio();
    this.audioEl.autoplay = true;
    this.audioEl.srcObject = this.remoteStream;
    this.applyDeafen();
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
      console.log("[VoiceChannel] connection:", this.pc?.connectionState);
    };

    // 4. Browser-initiated offer (initial connection)
    const pc = this.pc;
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    if (generation !== this.generation) return;
    this.pushEvent("voice_offer", { type: offer.type, sdp: offer.sdp });
  },

  applyMute() {
    this.localStream?.getAudioTracks().forEach((t) => (t.enabled = !this.muted));
  },

  applyDeafen() {
    if (this.audioEl) this.audioEl.muted = this.deafened;
  },

  teardown() {
    if (this.localStream) {
      this.localStream.getTracks().forEach((t) => t.stop());
    }
    if (this.pc) {
      this.pc.onicecandidate = null;
      this.pc.close();
    }
    if (this.audioEl) {
      this.audioEl.pause();
      this.audioEl.srcObject = null;
      this.audioEl.remove();
    }
    this.pc = null;
    this.audioEl = null;
    this.remoteStream = null;
    this.localStream = null;
  },

  destroyed() {
    // Any start() still awaiting the mic stands down when it resumes.
    this.generation++;
    this.teardown();
  },
};

Hooks.MessageFeed = {
  mounted() {
    this.loadingMore = false;
    this.loadingNewer = false;
    this.scrollToBottom();
    this.remember();

    this.el.addEventListener("scroll", () => {
      this.maybeLoad();
      this.remember();
    });

    // Every change to the list — a page of older messages, a message deleted
    // or redrawn, the top trimmed — arrives here after LiveView has applied it
    // and before the browser paints. Not beforeUpdate/updated: LiveView removes
    // stream items before those run, and may not run them at all for a
    // delete-only patch, so they'd measure a position that has already moved.
    this.mutations = new MutationObserver(() => this.keepPlace());
    this.mutations.observe(this.el.querySelector("#messages"), {
      childList: true,
      subtree: true,
      characterData: true,
    });

    this.handleEvent("scroll_to_bottom", () => {
      if (this.isNearBottom()) {
        requestAnimationFrame(() => this.scrollToBottom());
      }
    });

    // "Jump to present" replaced the feed with the newest page.
    this.handleEvent("scroll_to_present", () => {
      this.scrollToBottom();
      this.remember();
    });
  },

  beforeUpdate() {
    this._oldChannelId = this.el.dataset.channelId;
  },

  updated() {
    this.loadingMore = false;
    this.loadingNewer = false;

    if (this.el.dataset.channelId !== this._oldChannelId) {
      this.scrollToBottom();
      this.remember();
    }
  },

  // Asks for the page above near the top, or — while the feed is detached from
  // the present — the page below near the bottom. Never both at once: each
  // push locks this element until its reply, and a page that arrives while
  // the other request holds the lock is patched in without its position.
  maybeLoad() {
    if (this.loadingMore || this.loadingNewer) return;

    const { hasMore, hasNewer } = this.el.dataset;

    if (this.el.scrollTop < 200 && hasMore === "true") {
      this.loadingMore = true;
      this.pushEvent("load_more_messages", {});
    } else if (this.isNearBottom() && hasNewer === "true") {
      this.loadingNewer = true;
      this.pushEvent("load_newer_messages", {});
    }
  },

  destroyed() {
    this.mutations.disconnect();
  },

  // A reader at the bottom of an attached feed follows new messages down.
  // Anyone else — including someone at the bottom of a detached feed, who is
  // about to get the next page below — stays on the message they were looking
  // at, wherever the list changed around it.
  keepPlace() {
    if (this.wasFollowing) {
      this.scrollToBottom();
    } else if (this.anchor?.isConnected) {
      this.el.scrollTop += this.anchor.getBoundingClientRect().top - this.anchorTop;
    }

    this.remember();
  },

  // Where the reader is, as of the last scroll or change: following the
  // present or not, and which message they're looking at and where it sits.
  remember() {
    this.wasFollowing = this.isNearBottom() && this.el.dataset.hasNewer !== "true";
    this.anchor = this.anchorMessage();
    this.anchorTop = this.anchor?.getBoundingClientRect().top;
  },

  // The first message that starts inside the view. Messages stack top to
  // bottom, so a binary search finds it in a handful of reads — cheap enough
  // to run on every scroll event.
  //
  // Skips the feed's very first message when it can: loading older messages
  // regroups that one (drops its header), and anchoring on it would shift its
  // text by the header's height.
  anchorMessage() {
    const viewTop = this.el.getBoundingClientRect().top;
    const messages = this.el.querySelectorAll("#messages > [data-layout]");
    let lo = 0;
    let hi = messages.length;

    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (messages[mid].getBoundingClientRect().top >= viewTop) hi = mid;
      else lo = mid + 1;
    }

    if (lo === messages.length) return null;
    return lo === 0 && messages[1] ? messages[1] : messages[lo];
  },

  isNearBottom() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 200;
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

// Tells the server whether the reader is at the bottom of the message feed —
// it trims old messages off the top only then, so history someone is reading
// is never pulled away. Sits on an empty element at the end of the feed and
// counts as "at the bottom" within the same 200px MessageFeed uses.
//
// Deliberately not part of MessageFeed: LiveView locks the element that pushed
// an event until its reply arrives, and a page of older messages patched in
// while a second event holds that lock loses its stream position and lands at
// the bottom. Reporting from this element leaves the feed's lock to
// load_more_messages alone.
Hooks.FeedEnd = {
  mounted() {
    // The server starts at the bottom too: a channel opens scrolled there.
    this.atBottom = true;

    this.observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting !== this.atBottom) {
          this.atBottom = entry.isIntersecting;
          this.pushEvent("feed_at_bottom", { at_bottom: this.atBottom });
        }
      },
      { root: this.el.parentElement, rootMargin: "0px 0px 200px 0px" }
    );

    this.observer.observe(this.el);
  },

  destroyed() {
    this.observer.disconnect();
  },
};

// Announces that the user is typing: on the first keystroke, then at most
// once every 3s while they keep going. Receivers keep "X is typing…" up for 5s
// after each announcement (ChatLive's @typing_ttl), so a steady typist stays
// shown without an event per keystroke. The server enforces its own minimum
// interval as well; this keeps the events from being sent in the first place.
Hooks.TypingSignal = {
  mounted() {
    this.lastSent = 0;

    this.el.addEventListener("input", () => {
      if (this.el.value.trim() === "") return;

      const now = Date.now();
      if (now - this.lastSent < 3000) return;

      this.lastSent = now;
      this.pushEvent("typing", {});
    });

    // Sending ends this bout of typing; the next keystroke starts a new one.
    this.el.form?.addEventListener("submit", () => {
      this.lastSent = 0;
    });
  },
};

export default Hooks;

// The equalizer, for a browser.
//
// A browser has no equalizer, but it will play an <audio> element through filters of
// any shape (Web Audio). The player makes its element with document.createElement, so
// that is watched for; nothing else about the player is touched.
//
// The rule this is written around: a browser where any of this goes wrong must be a
// browser with no equalizer, never one with no sound. So —
//   * nothing is routed anywhere until the equalizer is first switched ON. Until then
//     the element plays exactly as it always has;
//   * an element is only routed once the audio context is actually running. A context
//     made without a tap or a key press starts suspended, and an element routed into a
//     suspended context is silent. If it is suspended, the first tap anywhere wakes it
//     and the routing happens then;
//   * sound from another address is left alone: the browser hands filters silence for
//     cross-origin media, which would be "no sound" again;
//   * not on an iPhone or iPad's browser at all: there, filtered sound stops when the
//     screen locks. The app has its own equalizer.
//
// Switched OFF after having been on, the filters stay where they are, set flat: taking
// an element back out of a graph is not something a browser lets you do.
(function () {
  'use strict';
  var elements = [];
  var made = document.createElement;
  document.createElement = function (tag) {
    var el = made.apply(this, arguments);
    try {
      if (String(tag).toLowerCase() === 'audio') elements.push(el);
    } catch (e) {}
    return el;
  };

  var ctx = null;
  var chains = new Map();          // element -> {pre, filters}
  var wanted = { enabled: false, hz: [], gains: [], preamp: 0 };
  var waitingForATap = false;

  function onAnIPhone() {
    var ua = navigator.userAgent || '';
    return /iPad|iPhone|iPod/.test(ua) ||
        (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  }

  function fromHere(el) {
    var src = el.currentSrc || el.src;
    if (!src) return null;                       // nothing loaded yet: not known
    try {
      return new URL(src, location.href).origin === location.origin;
    } catch (e) {
      return false;
    }
  }

  function route(el) {
    if (chains.has(el)) return true;
    if (fromHere(el) !== true) return false;
    var source = ctx.createMediaElementSource(el);
    var pre = ctx.createGain();
    var filters = wanted.hz.map(function (hz, i) {
      var f = ctx.createBiquadFilter();
      // A shelf at either end, so "more bass" is everything down there rather than a
      // bump at 31 Hz; bells an octave wide in between.
      f.type = i === 0 ? 'lowshelf' : i === wanted.hz.length - 1 ? 'highshelf' : 'peaking';
      f.frequency.value = hz;
      f.Q.value = 1.41;
      f.gain.value = 0;
      return f;
    });
    var last = source;
    [pre].concat(filters).forEach(function (node) {
      last.connect(node);
      last = node;
    });
    last.connect(ctx.destination);
    chains.set(el, { pre: pre, filters: filters });
    return true;
  }

  function set() {
    var now = ctx.currentTime;
    chains.forEach(function (chain) {
      var on = wanted.enabled;
      chain.pre.gain.setTargetAtTime(
          on ? Math.pow(10, wanted.preamp / 20) : 1, now, 0.03);
      chain.filters.forEach(function (f, i) {
        f.gain.setTargetAtTime(on ? (wanted.gains[i] || 0) : 0, now, 0.03);
      });
    });
  }

  function routeWhatThereIs() {
    if (!ctx || ctx.state !== 'running') return;
    elements.forEach(function (el) {
      try {
        if (el.__wetowlBooth) return;            // a deck's: the booth routes those
        if (!route(el) && !el.__wetowlEqWatching) {
          // Not loaded yet, or from elsewhere: look again when it loads something.
          el.__wetowlEqWatching = true;
          el.addEventListener('loadedmetadata', routeWhatThereIs);
        }
      } catch (e) {}
    });
    set();
  }

  function wake() {
    if (!ctx) return;
    ctx.resume().then(routeWhatThereIs, function () {});
  }

  function onATap() {
    waitingForATap = false;
    document.removeEventListener('pointerdown', onATap, true);
    document.removeEventListener('keydown', onATap, true);
    wake();
  }

  window.wetowlEq = {
    // Null when it took, a sentence when it could not.
    apply: function (enabled, hz, gains, preamp) {
      wanted = { enabled: !!enabled, hz: hz || [], gains: gains || [], preamp: preamp || 0 };
      if (!wanted.enabled && !ctx) return null;  // never been on: leave everything be
      if (onAnIPhone()) {
        return "In a browser on an iPhone, filtered sound stops when the screen " +
            "locks. The app has its own equalizer.";
      }
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return 'This browser cannot filter sound.';
      try {
        if (!ctx) {
          ctx = new Ctx({ latencyHint: 'playback' });
          // A context the browser put to sleep is a silent player: wake it.
          ctx.onstatechange = function () {
            if (ctx.state === 'suspended' && chains.size > 0) wake();
          };
        }
        if (ctx.state === 'running') {
          routeWhatThereIs();
        } else {
          wake();
          if (!waitingForATap) {
            waitingForATap = true;
            document.addEventListener('pointerdown', onATap, true);
            document.addEventListener('keydown', onATap, true);
          }
        }
      } catch (e) {
        return 'The browser would not start its audio filters: ' + e;
      }
      var elsewhere = elements.some(function (el) { return fromHere(el) === false; });
      if (elsewhere && chains.size === 0) {
        return "The music is coming from another address than this page, and a " +
            "browser will not let that be filtered. Open the app at its server's " +
            "own address.";
      }
      return null;
    },
  };
})();

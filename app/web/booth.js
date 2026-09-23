// The booth, for a browser: two decks, each through a gain, three bands, a filter and
// the crossfader, every change scheduled on the audio clock.
//
// The same rule as eq.js, which this sits beside: nothing is routed until the booth is
// used, and a browser where any of this goes wrong is a browser with no booth, never
// one with no sound. The app tells the script which deck is about to make its audio
// element (expect), the element is recognised as it is made, and it is only routed
// once the context is running and the element plays something from this origin.
(function () {
  'use strict';
  var Ctx = window.AudioContext || window.webkitAudioContext;
  var ctx = null;
  var expecting = null;              // the deck name the next audio element belongs to
  var decks = {};                    // name -> {el, chain}
  var made = document.createElement;
  document.createElement = function (tag) {
    var el = made.apply(this, arguments);
    try {
      if (String(tag).toLowerCase() === 'audio' && expecting) {
        el.__wetowlBooth = expecting;        // eq.js leaves these alone
        decks[expecting] = { el: el, chain: null, wanted: { level: 1, low: 0, mid: 0, high: 0, filter: 0 } };
        expecting = null;
      }
    } catch (e) {}
    return el;
  };

  function fromHere(el) {
    var src = el.currentSrc || el.src;
    if (!src) return null;
    try { return new URL(src, location.href).origin === location.origin; } catch (e) { return false; }
  }

  function chainFor(deck) {
    if (deck.chain) return deck.chain;
    if (!ctx || ctx.state !== 'running' || fromHere(deck.el) !== true) return null;
    var source = ctx.createMediaElementSource(deck.el);
    var low = ctx.createBiquadFilter(); low.type = 'lowshelf'; low.frequency.value = 250; low.gain.value = 0;
    var mid = ctx.createBiquadFilter(); mid.type = 'peaking'; mid.frequency.value = 1000; mid.Q.value = 0.7; mid.gain.value = 0;
    var high = ctx.createBiquadFilter(); high.type = 'highshelf'; high.frequency.value = 4000; high.gain.value = 0;
    var lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 22000; lp.Q.value = 0.9;
    var hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 10; hp.Q.value = 0.9;
    var level = ctx.createGain(); level.gain.value = deck.wanted.level;
    [low, mid, high, lp, hp, level].reduce(function (a, b) { a.connect(b); return b; }, source);
    level.connect(ctx.destination);
    deck.chain = { low: low, mid: mid, high: high, lp: lp, hp: hp, level: level };
    apply(deck);
    return deck.chain;
  }

  // The three bands, in decibels as the app sets them: 0 is flat and -40 is a kill,
  // gone to the ear and back without a click.
  function apply(deck) {
    var c = deck.chain, w = deck.wanted;
    if (!c) return;
    var now = ctx.currentTime;
    c.low.gain.setTargetAtTime(w.low, now, 0.02);
    c.mid.gain.setTargetAtTime(w.mid, now, 0.02);
    c.high.gain.setTargetAtTime(w.high, now, 0.02);
    // The filter: one knob, closing a low-pass to the left and a high-pass to the
    // right, on a log scale so the middle of the travel is the middle of the ear.
    var f = w.filter;
    var lpHz = f < 0 ? 22000 * Math.pow(60 / 22000, -f) : 22000;
    var hpHz = f > 0 ? 10 * Math.pow(8000 / 10, f) : 10;
    c.lp.frequency.setTargetAtTime(lpHz, now, 0.02);
    c.hp.frequency.setTargetAtTime(hpHz, now, 0.02);
  }

  function routeWhatThereIs() {
    Object.keys(decks).forEach(function (name) {
      var deck = decks[name];
      if (!chainFor(deck) && !deck.el.__wetowlBoothWatching) {
        deck.el.__wetowlBoothWatching = true;
        deck.el.addEventListener('loadedmetadata', routeWhatThereIs);
      }
    });
  }

  function wake() {
    if (!ctx) {
      if (!Ctx) return 'This browser cannot mix sound.';
      ctx = new Ctx({ latencyHint: 'interactive' });
      ctx.onstatechange = function () { if (ctx.state === 'suspended') wake(); };
    }
    if (ctx.state === 'running') { routeWhatThereIs(); return null; }
    ctx.resume().then(routeWhatThereIs, function () {});
    var onATap = function () {
      document.removeEventListener('pointerdown', onATap, true);
      document.removeEventListener('keydown', onATap, true);
      ctx.resume().then(routeWhatThereIs, function () {});
    };
    document.addEventListener('pointerdown', onATap, true);
    document.addEventListener('keydown', onATap, true);
    return null;
  }

  window.wetowlBooth = {
    expect: function (name) { expecting = String(name); },
    has: function (name) { var d = decks[name]; return !!(d && chainFor(d)); },
    ready: function () { return wake(); },
    // The deck's level, ramped over so many seconds on the audio clock.
    levels: function (name, level, seconds) {
      var d = decks[name]; if (!d) return;
      d.wanted.level = level;
      var c = chainFor(d); if (!c) { d.el.volume = level; return; }
      var now = ctx.currentTime;
      c.level.gain.cancelScheduledValues(now);
      c.level.gain.setValueAtTime(c.level.gain.value, now);
      if (seconds > 0) c.level.gain.linearRampToValueAtTime(level, now + seconds);
      else c.level.gain.setTargetAtTime(level, now, 0.01);
    },
    eq: function (name, low, mid, high) {
      var d = decks[name]; if (!d) return;
      d.wanted.low = low || 0; d.wanted.mid = mid || 0; d.wanted.high = high || 0;
      if (chainFor(d)) apply(d);
    },
    filter: function (name, value) {
      var d = decks[name]; if (!d) return;
      d.wanted.filter = Math.max(-1, Math.min(1, value || 0));
      if (chainFor(d)) apply(d);
    }
  };
})();

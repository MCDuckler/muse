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
        // A deck is handed a new element every time it is handed a new record, and
        // what the mixer was set to is about the deck rather than about the record:
        // it is kept, or the fader and the bands would spring back to nothing every
        // time a record went on.
        var was = decks[expecting];
        decks[expecting] = {
          el: el,
          chain: null,
          wanted: was ? was.wanted : { level: 1, low: 0, mid: 0, high: 0, filter: 0 }
        };
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
    // The record split three ways, each band with a level of its own, added back —
    // a mixer's EQ, not a tone control. A shelf/bell/shelf stack was measured
    // killing LOW at the cost of 7 dB at 700 Hz, and all three down left -33 dB of
    // signal where three knobs at the bottom should be silence.
    //
    // Fourth-order Linkwitz-Riley either side of each crossover — two cascaded
    // Butterworth biquads, which is what a pair has to be to sum flat.
    var LOW_X = 300, HIGH_X = 3000;
    function pass(kind, hz) {
      var f = ctx.createBiquadFilter();
      f.type = kind; f.frequency.value = hz; f.Q.value = Math.SQRT1_2;
      return f;
    }
    var lowA = pass('lowpass', LOW_X), lowB = pass('lowpass', LOW_X);
    var midA = pass('highpass', LOW_X), midB = pass('highpass', LOW_X);
    var midC = pass('lowpass', HIGH_X), midD = pass('lowpass', HIGH_X);
    var highA = pass('highpass', HIGH_X), highB = pass('highpass', HIGH_X);
    var low = ctx.createGain(); low.gain.value = 1;
    var mid = ctx.createGain(); mid.gain.value = 1;
    var high = ctx.createGain(); high.gain.value = 1;
    var sum = ctx.createGain(); sum.gain.value = 1;
    var lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 22000; lp.Q.value = 0.9;
    var hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 10; hp.Q.value = 0.9;
    var level = ctx.createGain(); level.gain.value = deck.wanted.level;
    // The chop: a gain the LFO rides, sitting between the passes and the level. The
    // oscillator runs from the moment the graph is built and is never stopped — only
    // its depth is moved — because an oscillator started again is an oscillator whose
    // phase has moved, and a chop whose phase moves is not on the beat any more.
    var gate = ctx.createGain(); gate.gain.value = 1;
    var lfo = ctx.createOscillator(); lfo.type = 'sine'; lfo.frequency.value = 4;
    var depth = ctx.createGain(); depth.gain.value = 0;
    lfo.connect(depth); depth.connect(gate.gain);
    lfo.start();
    // And the element's own volume is let go of: from here the gain is the level, and
    // a volume left at half from before it was routed would halve it twice.
    try { deck.el.volume = 1; } catch (e) {}
    source.connect(lowA); lowA.connect(lowB); lowB.connect(low); low.connect(sum);
    source.connect(midA); midA.connect(midB); midB.connect(midC); midC.connect(midD);
    midD.connect(mid); mid.connect(sum);
    source.connect(highA); highA.connect(highB); highB.connect(high); high.connect(sum);
    [lp, hp, gate, level].reduce(function (a, b) { a.connect(b); return b; }, sum);
    level.connect(ctx.destination);
    deck.chain = { low: low, mid: mid, high: high, lp: lp, hp: hp, level: level,
                   gate: gate, lfo: lfo, depth: depth };
    apply(deck);
    return deck.chain;
  }

  // The three bands, in decibels as the app sets them: 0 is flat and -40 is a kill,
  // gone to the ear and back without a click. A band's *level* now, not a filter's
  // gain, so the decibels have to be turned into one.
  function gainOf(db) { return db <= -40 ? 0 : Math.pow(10, db / 20); }

  function apply(deck) {
    var c = deck.chain, w = deck.wanted;
    if (!c) return;
    var now = ctx.currentTime;
    c.low.gain.setTargetAtTime(gainOf(w.low), now, 0.02);
    c.mid.gain.setTargetAtTime(gainOf(w.mid), now, 0.02);
    c.high.gain.setTargetAtTime(gainOf(w.high), now, 0.02);
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
    },
    // The chop: [deep] of the level taken away at the bottom of each cycle, [hz]
    // cycles a second. The gain swings between 1 - deep and 1, so a depth of 1 is
    // silence at the bottom and the record untouched at the top.
    gate: function (name, deep, hz) {
      var d = decks[name]; if (!d) return;
      var c = chainFor(d); if (!c) return;
      var now = ctx.currentTime;
      deep = Math.max(0, Math.min(1, deep || 0));
      c.lfo.frequency.setTargetAtTime(Math.max(0.1, hz || 4), now, 0.01);
      c.gate.gain.setTargetAtTime(1 - deep / 2, now, 0.02);
      c.depth.gain.setTargetAtTime(deep / 2, now, 0.02);
    }
  };
})();

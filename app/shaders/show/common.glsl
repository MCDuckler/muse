// What every scene shader is handed, in this order — the stage sets them by
// position, so the block is the same in each .frag (impellerc has no include of our
// own files that survives both backends, so it is pasted, and this file is the one
// to copy from). Values are 0..1 unless said.
//
//   uniform vec2 uResolution;   // the pass's size in pixels
//   uniform float uTime;        // seconds, running
//   uniform float uBeat;        // through the beat
//   uniform float uBar;         // through the bar
//   uniform float uPhrase;      // through the four-bar phrase
//   uniform float uEnergy;      // the bar's energy, through the fader
//   uniform float uIntensity;   // everything, with the hands over it
//   uniform float uKick;        // the kick drum, now
//   uniform float uLow;         // the bands, now, through the mixer
//   uniform float uMid;
//   uniform float uHigh;
//   uniform float uAir;
//   uniform float uOnset;
//   uniform float uHue;         // the palette's primary, round the wheel
//   uniform float uHue2;        // its secondary
//   uniform float uDropNear;    // 1 as a drop lands, 0 thirty-two beats off
//   uniform float uBuild;       // up a build
//   uniform float uHit;         // the performer's hit, falling
//   uniform float uVocal;       // the voice's share
//   uniform float uM1;          // four knobs each scene reads its own way
//   uniform float uM2;
//   uniform float uM3;
//   uniform float uM4;
//   uniform float uHitKick;    // the kick's hit: 1 as it lands, gone in ~0.2 s
//   uniform float uHitSnare;   // the middle's
//   uniform float uHitTop;     // the top's
//   uniform float uBeatDecay;  // exp fall from each beat of the GRID
//   uniform float uBarDecay;   // the same from each bar
//   uniform float uBarSaw;     // 0..1 through the bar (grid)
//   uniform float uPhraseSaw;  // 0..1 through the phrase
//   uniform float uDownbeat;   // the bar decay on beat one only
//   uniform float uExposure;   // 0.35..1.2, follows the loudness slowly
//   uniform float uBandLow;    // the bands against the record's own loud, 0..1
//   uniform float uBandMid;
//   uniform float uBandHigh;
//   uniform float uBarIndex;   // the bar, counted from the record's first downbeat
//
// Then any samplers the scene asks for, in the order its JSON lists them.

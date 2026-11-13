// WetOwl's booth engine: every deck rendered in one audio callback, off one sample
// clock, from records decoded whole into memory. See engine.cpp for how; this is
// what Dart sees (lib/src/audio/engine.dart binds it through dart:ffi).
//
// Times are seconds. A deck's "source" time is the record's own, as the beat grid
// counts it. "Heard" is where the record is at the moment the sound card plays it.
// Every call is safe from any one thread (Dart's); commands are applied by the audio
// thread at the start of its next block, in the order given.
#pragma once
#include <stdint.h>

#ifdef _WIN32
#define WE_API __declspec(dllexport)
#else
#define WE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define WE_DECKS 4
#define WE_SOURCES 6

// ---- the engine ------------------------------------------------------------------

// Starts the engine. rate 0 asks the sound card for its own; device 0 runs it with
// no sound card at all, rendered on demand by we_render (the tests). Returns 0 when
// it is running, else an error number (and we_error says what).
WE_API int we_start(int rate, int device);
WE_API void we_stop(void);
WE_API const char* we_error(void);
WE_API int we_rate(void);
// How long from the engine handing a block over to the sound card playing it.
WE_API double we_latency(void);
// The engine's clock, the one positions are stamped with (monotonic; offline: the
// frames rendered so far).
WE_API double we_now(void);
// How the audio thread is keeping up: its load, the time a call took over the time
// it had (an average over about a second, and the worst since the last ask); the calls
// that ran late (each a gap in the sound) since the start; whether keylocked decks
// were moved to Rubber Band's faster engine for it; the period asked of the device.
typedef struct {
  double average, worst;
  int64_t late;
  int32_t faster, period;
} we_load_state;
WE_API void we_load(we_load_state* out);
// Keylocked decks on Rubber Band's faster engine (1) or its finer one (0) from now on,
// moved over where they are heard; the load no longer chooses.
WE_API void we_stretch(int faster);
// Offline only: render frames of the stereo master (interleaved floats) into out,
// and each deck's own output (post fader, stereo) into decks[d] when not null.
WE_API void we_render(float* out, int frames, float** decks);
// Offline only: the master as we_render does, and the headphones (the cue bus, stereo)
// into cue — rendered once we_route asked for headphones.
WE_API void we_render_cue(float* out, float* cue, int frames);

// ---- the outputs: the master, and the headphones ---------------------------------

// The system's outputs: up to max into out; returns how many there are. channels: the
// most each takes (0 when not known).
typedef struct {
  char name[256];
  int32_t channels;
  int32_t is_default;
} we_device_info;
WE_API int we_devices(we_device_info* out, int max);
// Where the sound goes. master: an output's name ("" or null: the system's own), the
// master on its channels master_ch and master_ch + 1. cue: the headphones' output (null:
// none; the master's own name: on the same device, a DJ console's channels 3/4 with
// cue_ch 2; another: a second sound card, kept in step with the first). split: one
// stereo pair, the headphones in the left ear and the master in the right, each mono.
// The decks play on through it. Returns 0, else an error number (we_error says what);
// a main output that would not open falls back on the system's own, stereo.
typedef struct {
  const char* master;
  int32_t master_ch;
  const char* cue;
  int32_t cue_ch;
  int32_t split;
} we_route_cfg;
WE_API int we_route(const we_route_cfg* route);
// How it went: the main output's channels (0: none open); where the headphones are (0
// nowhere, 1 split, 2 the same device, 3 a second card) and that card's channels; lost /
// cue_lost: an output stopped by itself (unplugged); gaps: the second card ran dry.
typedef struct {
  int32_t channels, cue, cue_channels, lost, cue_lost;
  int64_t gaps;
} we_route_state;
WE_API void we_route_read(we_route_state* out);
// The headphones' blend: mix 0 the cued decks alone .. 1 the master alone; level a gain.
WE_API void we_cue_mix(float mix, float level);

// ---- sources: decoded records in memory -------------------------------------------

// A new empty source of channels (2, or 6 for a record's stems) at the engine's rate,
// room for about frames_hint frames to begin with. Returns its id (> 0), or 0.
WE_API int we_source_new(int channels, int64_t frames_hint);
// Appends frames of 16-bit interleaved samples. The audio thread may play what is
// in already. Returns 0, or -1 when out of memory.
WE_API int we_source_append(int source, const int16_t* pcm, int64_t frames);
WE_API void we_source_done(int source);
WE_API int64_t we_source_frames(int source);
// Lets go of a source: freed once no deck plays it.
WE_API void we_source_free(int source);

// ---- decks -----------------------------------------------------------------------

// What a deck plays: up to WE_SOURCES sources on one timeline, each at its gain,
// a 6-channel one's three pairs (drums, bass+other, vocals) each at its own. Gains
// slide over ramp seconds.
WE_API void we_deck_source(int deck, int slot, int source);
WE_API void we_deck_source_gain(int deck, int slot, float gain, float drums, float rest, float vocals, double ramp);

WE_API void we_deck_play(int deck, int playing);
// Puts the deck at source time t at once (a short crossfade from where it was).
WE_API void we_deck_seek(int deck, double t);
// The tempo: source seconds per second, 1 = as recorded.
WE_API void we_deck_rate(int deck, double rate);
// A temporary bend on top of the rate (the jog wheel, a nudge): 1 = none. A synced
// deck keeps the place a bend leaves it in.
WE_API void we_deck_bend(int deck, double factor);
WE_API void we_deck_keylock(int deck, int on);
// A hand on the record (on 1) or off it (0): scratching. Under the hand the record
// goes where the hand takes it — held still it stops, pulled back it plays backwards,
// its pitch with its speed, as vinyl; playing or parked alike. Let go, a playing deck
// spins back up to its speed and goes on as it was (key lock and all); a parked one
// stops where it was left. A synced deck keeps the place the hand leaves it in.
WE_API void we_deck_scratch(int deck, int on);
// The hand moved the record by `seconds` of it (+ on, - back). Ignored with no hand on.
WE_API void we_deck_scratch_by(int deck, double seconds);
WE_API void we_deck_shift(int deck, double semitones);
// The beat grid: the times of the record's beats, ascending. A deck with none can
// play, loop by seconds and be a master of nothing.
WE_API void we_deck_beats(int deck, const double* times, int count);

// Sync: deck follows master's tempo (folded to within half/double time of its own),
// with its beats on the master's, so that `every` master beats line up with whole
// beats of its own (1 = any beat, 4 = bars counted from both records' first beats
// of a bar given by `bar_one`). offset is how far ahead of the master's beat it
// sits, seconds of its own record (a nudge). master -1 lets go. Engaging jumps it
// into place at once; held, the engine trims its rate a hair as needed.
WE_API void we_deck_sync(int deck, int master, int every, double offset);
WE_API void we_deck_bar_one(int deck, int beat_index);
// Starts the deck playing in step with master. With at < 0: now, put wherever its
// beat matches the master's (`every` as for sync) nearest where it is parked. With
// at >= 0: from exactly where it is parked, at the moment the master is heard at
// source time `at` (a beat, a bar: wherever the booth parked it to meet).
WE_API void we_deck_start(int deck, int master, int every, double at, double offset);
// A synced deck's offset changed (a nudge by ear) without jumping it there: it is
// eased there by the hold.
WE_API void we_deck_sync_offset(int deck, double offset);
// On top of SYNC's own fold: the follower locked at half (0.5) or double (2) the
// beat it would choose, its tempo moved there at once and its beat put in step.
WE_API void we_deck_sync_octave(int deck, double octave);
// Puts the deck's beat on the master's once, now, without holding it there.
WE_API void we_deck_align(int deck, int master, int every, double offset);

// Loops in source time. b <= a lets go.
WE_API void we_deck_loop(int deck, double a, double b);
// A loop of beats beats from the beat the deck is on (bar = 1: from the bar's first
// beat if it was passed within a beat, else the next), sample-exact on the grid.
WE_API void we_deck_loop_beats(int deck, double beats, int bar);

// The channel: gain after the EQ (fader × crossfader × trim), as a plain gain.
WE_API void we_deck_level(int deck, float gain, double ramp);
// The deck in the headphones (pre-fader listening): its sound after EQ, filter and
// effects, before its fader, at gain (0: not in them).
WE_API void we_deck_cue(int deck, float gain, double ramp);
// The bands in decibels (kill at -40), and the filter knob -1 (low pass) .. 1 (high).
WE_API void we_deck_eq(int deck, float low, float mid, float high, double ramp);
WE_API void we_deck_filter(int deck, float knob);
// The chop: a cosine dip depth deep every period seconds of the record, from origin.
WE_API void we_deck_gate(int deck, float depth, double period, double origin);
// The echo: send into a dotted-eighth / dotted-quarter echo of the beat, and the dry.
WE_API void we_deck_echo(int deck, float send, float dry, double beat);
// The brake: the record slowed to a stop over seconds, pitch going down with it.
WE_API void we_deck_brake(int deck, double seconds);
WE_API void we_master_level(float gain);

// ---- pads (the board) ------------------------------------------------------------

// A pool of short sounds over the decks: each slot a source played from `from` to `to`
// source seconds (to <= from: to its end), once or round and round, at a gain, from the
// moment `at` is heard (we_now() time; now or past: at once) — so a pad meant for the
// next beat sounds on it. Summed into the master under the board's level, before the
// master's level and its limiter. The slots (0..WE_PADS-1) are the caller's to choose;
// playing a slot again starts it over.
#define WE_PADS 24
WE_API void we_pad_play(int slot, int source, double at, double from, double to, int loop, float gain);
// Let go, faded over `fade` seconds (0: at once).
WE_API void we_pad_stop(int slot, double fade);
WE_API void we_pad_gain(int slot, float gain, double ramp);
WE_API void we_pads_level(float gain, double ramp);
// Whether a slot sounds (or waits for its moment), and where in its source it is, seconds.
WE_API int we_pad_playing(int slot, double* at);

// ---- what a deck is doing --------------------------------------------------------

typedef struct {
  double heard;      // source time heard at `at`
  double at;         // we_now() time of it
  double rate;       // source seconds per second now (rate × bend × trim)
  double length;     // source seconds decoded so far
  double loop_a, loop_b;
  double phase_error;  // synced: seconds its beat is off the master's (heard)
  int64_t moves;     // counts every jump, seek and loop wrap
  int32_t playing, looping, synced, braking;
  int32_t ended;     // ran off the end of its record (counts up each time)
  float peak_l, peak_r;  // since the last read
} we_deck_state;

WE_API void we_deck_read(int deck, we_deck_state* out);

// ---- what is heard, measured (tap.h) ----------------------------------------

// Buses: a deck (0..WE_DECKS-1, its output post fader) or the master (WE_MASTER).
#define WE_MASTER WE_DECKS
#define WE_SPECTRUM 32
// Each 0..1 against a fixed scale (a mastered record's loud near 1). The levels are
// the latest row heard by `to`; the hits (kick, snare, hat, onset) and the peak the
// most of every row heard in (from, to], so a hit between two reads is still seen.
typedef struct {
  double at;            // when the latest row is heard, we_now() time
  float sub, low, mid, high, air;
  float kick, snare, hat, onset;
  float rms, peak;
  float spectrum[WE_SPECTRUM];  // the master's only: 30 Hz .. 16 kHz, log-spaced
  int32_t rows;         // rows in the span
} we_features_state;
// Measuring is on while asked: from the first call, until ten seconds after the
// last. Returns 1 when there was a row heard by `to`, else 0 (and out zeroed).
WE_API int we_features(int bus, double from, double to, we_features_state* out);
// The last n mono samples of a bus heard by `at` (we_now() time), at the engine's
// rate. Returns n, or 0 where they are not (or no longer) there.
WE_API int we_scope(int bus, double at, float* out, int n);
// Where the deck is heard right now (heard + time since × rate), source seconds. Under
// a hand the rate is the record's own speed, backwards negative.
WE_API double we_deck_position(int deck);

#ifdef __cplusplus
}
#endif

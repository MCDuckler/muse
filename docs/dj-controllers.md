# DJ hardware in the booth

Plan and design notes for driving the booth from a physical controller. First target:
the **Hercules DJ Console RMX** over USB. Written before any hardware was plugged in;
the parts that could only be checked with the real thing are marked **[hw]**.

## What the RMX actually is on the wire

- A class-compliant **USB audio** device (2 stereo in / 2 stereo out) plus a **USB HID**
  device. It has **no USB-MIDI class interface**. USB id `06f8:b101` (Guillemot).
- With Hercules' own driver (Windows, macOS) the driver exposes a MIDI port and
  translates HID ⇄ MIDI. Without the driver (Linux, Android, a Mac without it) the
  controls are only reachable as **HID reports**. Mixxx ships both a MIDI and a HID
  mapping for exactly this reason.
- Consequence per platform:

  | platform | path | status |
  |---|---|---|
  | Linux | HID via `/dev/hidrawN` (needs a udev rule) | implemented; scan tested on a fake sysfs, open/read needs **[hw]** |
  | Android | HID via `UsbManager` interrupt endpoint (USB host / OTG) | implemented (Hid.kt), needs **[hw]** |
  | Linux, MIDI | `flutter_midi_command` over the ALSA sequencer | **verified end to end** with `tool/fake_midi_controller.c` |
  | Windows / macOS + Hercules driver | MIDI via `flutter_midi_command` | implemented, needs **[hw]** |
  | macOS / Windows without driver | HID (IOHIDManager / hid.dll) | not yet — transport stub |
  | iOS / iPadOS | no public USB-HID API; CoreMIDI only | **RMX cannot work**; class-compliant MIDI controllers do |
  | web | Web MIDI through `flutter_midi_command` | MIDI controllers only |
  | a phone, a tablet, the board's own window | `Protocol.remote`: JSON lines over a WebSocket on the local network, or the server's relay | **verified on the loopback** (`test/board_link_test.dart`); see `state/booth/board/link_server.dart` |

  So "RMX on iPhone" is off the table by Apple's rules, not ours. Any *MIDI-class*
  controller (DDJ-200/400/FLX4, Mixtrack, DJControl Inpulse/Starlight…) will work on
  iOS/Android/desktop through the same engine once it has a layout file.

## Architecture

```
 transport (bytes)        decoder (layout JSON)        binding (one, shared)        booth
 ──────────────────   →   ────────────────────────  →  ───────────────────────  →  ─────
 MidiTransport            MidiDecoder                  BoothBinding                Booth
 HidTransport(linux)      HidDecoder                     shift / scratch / pitch   Deck a,b
 HidTransport(android)                                   soft take-over            AutoMix
                       ←  encoder (LEDs)             ←   feedback                ←  listeners
```

- **`SurfaceControl`** — a fixed vocabulary of control ids every layout maps onto:
  `deck.a.play`, `deck.a.cue`, `deck.a.jog`, `deck.a.pitch`, `deck.a.eq.low`,
  `deck.a.kill.low`, `deck.a.pad.1`…`6`, `deck.a.sync`, `deck.a.keylock`,
  `deck.a.pitchReset`, `deck.a.load`, `deck.a.prev/next`, `deck.a.stop` (= shift),
  `deck.a.pfl`, `deck.a.source`, `deck.a.fx`, `deck.a.gain`, `deck.a.volume`,
  `mixer.crossfader`, `mixer.master`, `mixer.balance`, `mixer.headMix`,
  `mixer.scratch`, `browse.up/down/left/right`, `mic`. Same vocabulary for `b`.
  The board (the soundboard beside the decks): `board.pad.1`…`16` (the bank on
  show; a pad's release matters — a hold pad plays while held), `board.bank.1`…`4`,
  `board.bank.prev/next`, `board.stop`, `board.level` (no soft take-over). Lights:
  `board.pad.N` while it sounds, `board.stop` while anything does.
- **`ControllerLayout`** (JSON under `assets/controllers/`) — one file per device per
  protocol: how to recognise the device (USB vid/pid, HID/MIDI name patterns), each
  input (address → control id, kind, range, centre), each output (control id → LED
  address). Adding a controller = adding a JSON file. Quirks that are genuinely code
  (14-bit faders, sysex init, odd jog encodings) go behind a named `quirk` string.
- **`BoothBinding`** — the one place hardware intent becomes booth calls. Knows
  nothing about bytes. Holds modifier state (STOP held = shift; SCRATCH toggles jog
  mode; pitch range cycles ±8/16/50 %). Listens to booth/decks and pushes LED states
  back (play, cue, sync, keylock, pfl, scratch, pitch-reset-at-zero, loop/pad lit).
- **`SoftTakeover`** — a knob/fader on connect is wherever it was left; its first
  move must not yank the software value. Mixxx's rule: ignore moves until the
  hardware comes within reach of the software value or crosses it.
- **`ControllerManager`** (ChangeNotifier) — owns transports, scans, matches devices
  to layouts, connects, survives unplug/replug, remembers the chosen layout per
  device id, and keeps a short **monitor log** (raw + decoded) for mapping work and
  for the day the hardware arrives.

## Booth gaps the hardware exposes

Things a controller expects that the booth did not have; added alongside:

- **CUE button** (classic): press while paused → set cue at position (or jump back
  to it if already there); hold while paused → preview from cue, release → back to
  cue; press while playing → stop + jump to cue.
- **Jog wheel**: paused → `seekByHand` by ticks; playing → temporary bend
  (`Deck.bend`) proportional to tick rate, decays to `pitch` when the wheel stops;
  scratch mode while playing → coarser bend (no reverse playback: mpv cannot).
- **Loop in / out** (pads 5/6): manual loop points on top of the existing beat loops.
- **Master volume**: a multiplier in `Booth.levels`.
- **Keylock**: deck flag → engine `audio-pitch-correction` where the engine has it.
- **PFL / headphone**: no second output exists in the app → LED only, documented.

## Hercules RMX layout (from Mixxx, both protocols)

MIDI (Hercules driver): everything is **CC on channel 1 (`0xB0`)**, buttons send
`0x7F` press / `0x00` release, pots 0..127 (EQ/pitch centre `0x3F`, first-gen firmware
`0x40`), jog relative `0x01..0x3F` cw, `0x7F..0x40` ccw (signed 7-bit). LEDs: send
`0xB0 cc 0x7F` / `0x00` on the button's own CC.

| control | deck A | deck B |   | master |
|---|---|---|---|---|
| play | 0x0B | 0x23 | crossfader | 0x39 |
| cue | 0x0C | 0x24 | master vol | 0x38 |
| stop (shift) | 0x0D | 0x25 | balance | 0x37 |
| prev / next | 0x09/0x0A | 0x21/0x22 | head mix | 0x3A |
| load | 0x12 | 0x16 | scratch | 0x29 |
| source | 0x13 | 0x17 | browse ↑↓←→ | 0x2A 0x2B 0x2C 0x2D |
| pfl (cue select) | 0x14 | 0x18 | | |
| sync | 0x07 | 0x1F | | |
| keylock | 0x08 | 0x15 | | |
| pitch reset | 0x11 | 0x20 | | |
| pads 1-6 | 0x01-0x06 | 0x19-0x1E | | |
| kill hi/mid/lo | 0x0E/0x0F/0x10 | 0x26/0x27/0x28 | | |
| fx / flanger | 0x01 (Mixxx) | 0x19 | | |
| jog | 0x2F | 0x30 | | |
| pitch fader | 0x31 | 0x3B | | |
| volume fader | 0x32 | 0x3C | | |
| gain | 0x33 | 0x3D | | |
| treble / medium / bass | 0x34/0x35/0x36 | 0x3E/0x3F/0x40 | | |

HID (no driver): input report id `0x01`, 24 bytes after the id. Bytes 1–6 button
bitmasks, bytes 7–8 jog position counters (0..255 wrapping, delta = movement),
bytes 9–24 8-bit faders/pots (centre `0x80`). Output report id `0x00`, 2 LED
bytes: bit masks per LED. Full tables live in `assets/controllers/
hercules_dj_console_rmx.hid.json`.

## Testing without the hardware

- Unit tests feed MIDI bytes / HID packets through the decoders and a `BoothBinding`
  bound to a `Booth` on the fake engine, and assert on the booth: `test/controller_*`.
- The Controllers dialog has a **monitor** (every raw packet, its decoding, what the
  binding did) so the first minutes with the real unit are "watch the log, fix the
  JSON".
- Linux end-to-end for the MIDI transport: `test/controller_linux_midi_test.dart`
  compiles `tool/fake_midi_controller.c` (a pretend RMX on the ALSA sequencer), lets
  the real transport find it, presses PLAY, sees deck A play and the PLAY light come
  back, then pulls the plug. By hand: `gcc -o fake tool/fake_midi_controller.c
  -lasound && ./fake`, open the booth, type `B0 0B 7F`.
- The HID transport's open/read path would need a `uhid` virtual device;
  `/dev/uhid` is root-only on this box, so that waits for the real console
  (`test/controller_hidraw_test.dart` covers the sysfs scan).

## First contact checklist [hw]

1. Linux: `sudo cp deploy/udev/99-wetowl-dj.rules /etc/udev/rules.d/ && sudo udevadm
   control --reload`, replug. `ls -l /dev/hidraw*` should show the RMX node as
   `0660` with your ACL. Open the booth → the controller light in the bar comes on.
2. Controllers page → monitor: turn each knob, press each button. Anything
   `unmapped`/wrong goes into `assets/controllers/hercules_dj_console_rmx.hid.json`
   (byte/mask) — no Dart change needed.
3. Check centres: EQ knobs at detent should read `0.500`; if they read ~0.496
   the firmware centres on 0x7F/0x40 — change `center` in the JSON.
4. Jog: paused, one notch should move ~20 ms; playing, a flick should bend and
   settle. Tune `_JogFeel.parkedTick` / `k` in `binding.dart`.
5. Lights: PLAY/CUE/SYNC/KEYLOCK/pitch-reset/SCRATCH should follow the booth. If
   nothing lights on HID, the output report may want the report id byte dropped
   (hidraw wants it; Android's SET_REPORT path already strips it).
6. Android: OTG cable, accept the USB permission dialog (or launch via the
   plug-in prompt), same monitor.

## Phases

1. Engine: vocabulary, layouts, decoders, soft take-over, binding, manager, tests.
2. Booth additions: cue point, jog, loop in/out, master, keylock.
3. Transports: MIDI (`flutter_midi_command`), HID Linux (hidraw), HID Android (Kotlin).
4. UI: light in the bar, Controllers dialog with monitor, phone menu entry, key sheet row.
5. Platform plumbing: pubspec, Android manifest + device filter, `deploy/99-wetowl-dj.rules`.
6. **[hw]** first contact: fix centres/polarity/jog scale, verify LEDs, tune jog feel.

// MilkDrop's preset text, read and written; the reactions as lines; what a preset
// is handed of the show.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/milk_feed.dart';
import 'package:muse/src/state/show/milk_library.dart';
import 'package:muse/src/state/show/milk_preset_text.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  group('preset text', () {
    test('a file read is written the same, numbers first and code after', () {
      final t = MilkText.parse('[preset00]\nzoom=1.01\nper_frame_1=zoom = zoom + 0.1*bass;\nrot=0\nper_frame_2=rot = rot + 0.01;\nwarp_1=shader_body {\n');
      expect(t.num('zoom'), 1.01);
      expect(t.code('per_frame_'), 'zoom = zoom + 0.1*bass;\nrot = rot + 0.01;');
      expect(t.toString(), '[preset00]\nzoom=1.01\nrot=0\nper_frame_1=zoom = zoom + 0.1*bass;\nper_frame_2=rot = rot + 0.01;\nwarp_1=shader_body {\n');
    });

    test('code set replaces its lines and renumbers them', () {
      final t = MilkText.parse('[preset00]\nper_frame_1=a = 1;\nper_frame_2=b = 2;\nper_frame_init_1=c = 3;');
      t.setCode('per_frame_', 'x = 1;\n\n\ny = 2;');
      expect(t.code('per_frame_'), 'x = 1;\ny = 2;');
      expect(t.code('per_frame_init_'), 'c = 3;', reason: 'the init code is another kind');
      expect(t.keys.keys.where((k) => k.startsWith('per_frame_')).length, 3);
    });

    test('a blank preset has every number the maker shows', () {
      final t = MilkText.blank();
      for (final k in ['zoom', 'rot', 'warp', 'fDecay', 'fGammaAdj', 'nWaveMode', 'wave_r', 'ob_size', 'ib_size', 'nMotionVectorsX']) {
        expect(t.keys.containsKey(k), isTrue, reason: k);
      }
      expect(t.hasShaders, isFalse);
    });

    test('a shape is given every key once, and keeps what it had', () {
      final t = MilkText.parse('[preset00]\nshapecode_1_sides=7\nshapecode_1_rad=0.3');
      final s = MilkShape(t, 1)..ensure();
      expect(s.sides, 7);
      expect(s.rad, 0.3);
      expect(s.enabled, isFalse);
      s.enabled = true;
      s.inner = [1, 0.5, 0, 1];
      expect(t.keys['shapecode_1_enabled'], '1');
      expect(t.keys['shapecode_1_g'], '0.5');
      expect(t.keys['shapecode_1_x'], '0.5', reason: 'the default, where it had none');
    });

    test('numbers are written short', () {
      final t = MilkText.blank();
      t.set('zoom', 1.0);
      t.set('rot', 0.123456789);
      t.set('warp', 0.5);
      expect(t.keys['zoom'], '1');
      expect(t.keys['rot'], '0.123457');
      expect(t.keys['warp'], '0.5');
    });
  });

  group('reactions', () {
    test('each shape is a line, and the line reads back', () {
      for (final r in const [
        MilkReaction(target: 'zoom', source: 'wo_hit_kick', amount: 0.06),
        MilkReaction(target: 'rot', source: 'wo_bar', amount: -0.03, shape: 'sin'),
        MilkReaction(target: 'warp', source: 'wo_drop', amount: 1.5, shape: 'step'),
      ]) {
        final back = MilkReaction.parse(r.line);
        expect(back, isNotNull, reason: r.line);
        expect(back!.target, r.target);
        expect(back.source, r.source);
        expect(back.amount, closeTo(r.amount, 0.001));
        expect(back.shape, r.shape);
      }
      expect(const MilkReaction(target: 'zoom', source: 'wo_hit_kick', amount: 0.06).line, 'zoom = zoom + 0.060*wo_hit_kick;');
    });

    test('a line of somebody else\'s code is not a reaction', () {
      expect(MilkReaction.parse('zoom = zoom + 0.1*bass*treb;'), isNull);
      expect(MilkReaction.parse('q1 = wo_drop;'), isNull);
    });

    test('every target and source has a word', () {
      expect(MilkReaction.targets.values.every((v) => v.isNotEmpty), isTrue);
      expect(MilkReaction.sources.keys.where((k) => k.startsWith('wo_')).length, greaterThan(20));
    });
  });

  group('the show, by name', () {
    test('the numbers a preset reads', () {
      final st = ShowState(
        now: DateTime(2026),
        a: const ShowDeck(name: 'A', trackId: 1, playing: true, bpm: 132, beatPhase: 0.25, barPhase: 0.5, barIndex: 17, beatInBar: 2, section: 'drop', breakdown: false, buildK: 0, energy: 0.8, level: 1, dropBeatsAway: 0),
        b: const ShowDeck(name: 'B'),
        masterName: 'A',
      );
      final v = MilkFeed.varsOf(st);
      expect(v['wo_beat'], 0.25);
      expect(v['wo_bar'], 0.5);
      expect(v['wo_bar_index'], 17);
      expect(v['wo_beat_in_bar'], 2);
      expect(v['wo_bpm'], 132);
      expect(v['wo_playing'], 1);
      expect(v['wo_section'], 4, reason: 'a drop');
      expect(v['wo_drop'], 1, reason: 'landing now');
      expect(v['wo_energy'], 0.8);
      expect(v['wo_level_a'], 1);
      expect(v['wo_level_b'], 0);
      expect(v.keys.every((k) => k.startsWith('wo_')), isTrue);
      expect(v.values.every((x) => x.isFinite), isTrue);
    });

    test('a vars line is one line', () {
      final st = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'));
      final line = MilkFeed.varsOf(st).entries.map((e) => '${e.key}=${e.value.toStringAsFixed(4)}').join(' ');
      expect(line.contains('\n'), isFalse);
      expect(line.split(' ').length, MilkFeed.varsOf(st).length);
    });
  });

  group('the library', () {
    test('a preset is named by the convention', () {
      final p = MilkPreset.of('/x/Geiss - Cosmic Dust 2.milk', 'shipped');
      expect(p.author, 'Geiss');
      expect(p.name, 'Cosmic Dust 2');
      expect(p.fullName, 'Geiss - Cosmic Dust 2');
      final q = MilkPreset.of('/x/plain.milk', 'mine');
      expect(q.author, '');
      expect(q.name, 'plain');
      expect(q.fullName, 'plain');
    });

    MilkLibrary three() => MilkLibrary()
      ..presets.addAll([
        MilkPreset.of('/x/A - one.milk', 'shipped', rating: 4),
        MilkPreset.of('/x/B - two.milk', 'shipped', rating: 4),
        MilkPreset.of('/x/C - three.milk', 'shipped', rating: 4),
      ]);

    test('a preset switched off is never in the pool, but still listed', () {
      final lib = three();
      final two = lib.byName('B - two')!;
      lib.off.add(two.fullName);
      expect(lib.isOff(two), isTrue);
      expect([for (final p in lib.pool()) p.name], ['one', 'three']);
      expect([for (final p in lib.pool(favouritesOnly: true)) p.name], ['one', 'three']);
      lib.favourites.add(two.fullName);
      expect([for (final p in lib.pool(favouritesOnly: true)) p.name], ['one', 'three'], reason: 'a favourite switched off is still off');
      expect(lib.search('').length, 3);
      expect([for (final p in lib.search('', hideOff: true)) p.name], ['one', 'three']);
      expect([for (final p in lib.search('', offOnly: true)) p.name], ['two']);
    });

    test('all of them off is none off', () {
      final lib = three();
      for (final p in lib.presets) {
        lib.off.add(p.fullName);
      }
      expect(lib.pool().length, 3);
    });
  });
}

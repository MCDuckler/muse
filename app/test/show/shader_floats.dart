// A shader's float uniforms as Dart sets them: by name, each with its count of floats,
// in the order the file declares them. A vec4 that packs four floats (Metal's 31
// uniform slots: `uniform vec4 uW00;` with `#define uTime uW00.x` …) reads as the
// four floats it holds, by their names.
import 'dart:io';

List<(String, int)> shaderFloats(String path) {
  final src = File(path).readAsStringSync();
  final packed = <String, List<String>>{};
  for (final m in RegExp(r'^#define\s+(\w+)\s+(\w+)\.([xyzw])\s*$', multiLine: true).allMatches(src)) {
    final names = packed.putIfAbsent(m.group(2)!, () => List.filled(4, ''));
    names['xyzw'.indexOf(m.group(3)!)] = m.group(1)!;
  }
  final out = <(String, int)>[];
  for (final m in RegExp(r'^\s*uniform\s+(float|vec2|vec3|vec4)\s+(\w+)\s*;', multiLine: true).allMatches(src)) {
    final names = m.group(1) == 'vec4' ? packed[m.group(2)] : null;
    if (names != null) {
      out.addAll([for (final n in names) (n, 1)]);
    } else {
      out.add((m.group(2)!, switch (m.group(1)) { 'vec2' => 2, 'vec3' => 3, 'vec4' => 4, _ => 1 }));
    }
  }
  return out;
}

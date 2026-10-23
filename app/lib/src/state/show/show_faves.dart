// The favourites: what was on the stage at a moment, kept as it was — the
// combination (background, scene, style, mask, blend), the MilkDrop preset under it,
// the camera's framing, the 3D text's motion, look and bends — whatever the rules say
// of it since. Put back on in a tap (held, as PLAY IT holds a combination), rated one
// to five stars, browsed on the FAVES tab (ui/show/show_faves.dart).
//
// Kept in the show's document (show_store.dart), newest first; each one's picture, a
// small PNG of the stage as it was, beside it on disk (`show_faves/<id>.png`).
import 'show_combos.dart';
import 'show_rig.dart';
import 'show_type3d.dart';

class ShowFave {
  const ShowFave({
    required this.id,
    required this.at,
    required this.combo,
    this.milk,
    this.shot,
    this.type3d,
    this.stars = 0,
    this.name = '',
  });

  final String id;
  final DateTime at;
  final Combo combo;

  /// The MilkDrop preset on (its full name), where the combination shows MilkDrop.
  final String? milk;

  /// The figure's framing as `figure.shot` (`dancers.fisheye`), where it has a camera.
  final String? shot;

  /// The 3D text as it was: the hands' words and knobs, narrowed to the motion, the
  /// look and the bends on at the moment.
  final TypeSpec? type3d;

  /// 0 (not rated) to 5.
  final int stars;

  /// The hands' own name for it; empty: said by what it is ([describe]).
  final String name;

  ShowFave copyWith({int? stars, String? name}) =>
      ShowFave(id: id, at: at, combo: combo, milk: milk, shot: shot, type3d: type3d, stars: stars ?? this.stars, name: name ?? this.name);

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toUtc().toIso8601String(),
        'c': combo.key,
        if (milk != null) 'milk': milk,
        if (shot != null) 'shot': shot,
        if (type3d != null) 'type3d': type3d!.toJson(),
        if (stars > 0) 'stars': stars,
        if (name.isNotEmpty) 'name': name,
      };

  static ShowFave? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], c = j['c'];
    final combo = c is String ? Combo.fromKey(c) : null;
    if (id is! String || combo == null) return null;
    final s = j['stars'];
    return ShowFave(
      id: id,
      at: DateTime.tryParse('${j['at']}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
      combo: combo,
      milk: j['milk'] is String ? j['milk'] as String : null,
      shot: j['shot'] is String ? j['shot'] as String : null,
      type3d: j['type3d'] is Map ? TypeSpec.fromJson(j['type3d']) : null,
      stars: s is num ? s.toInt().clamp(0, 5) : 0,
      name: j['name'] is String ? j['name'] as String : '',
    );
  }

  /// A new one's id: the moment, to the millisecond, and a little more.
  static String newId(DateTime at) => '${at.millisecondsSinceEpoch.toRadixString(36)}${(at.microsecond % 1000).toRadixString(36)}';
}

/// What a figure's camera, by its clock, and the 3D text are showing at the moment —
/// the parts of the picture that are not in the combination — for a favourite.
/// Narrowed: the 3D text's motion, look and bends as the only ones.
TypeSpec narrowedType(TypeSpec spec, ({TypeMotion motion, TypeLook look, Set<TypeDeform> bends}) now) =>
    spec.copyWith(motions: {now.motion}, looks: {now.look}, deforms: now.bends);

/// The figure whose framing a favourite keeps: the dancers' and the birds'.
bool hasCamera(Figure f) => f == Figure.dancers || f == Figure.birds;

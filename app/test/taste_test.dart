// What this person thought of the booth's mixes, as leanings: a thumb is a word, a
// steer a smaller one, and none of it says much until there are a few.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/taste.dart';

Map<String, dynamic> row(String event, {String? kind, int? rating, String? was, int from = 1, int to = 2}) => {
      'event': event,
      'from_track': from,
      'to_track': to,
      'kind': kind,
      'rating': rating,
      'detail': {if (was != null) 'was': was},
    };

void main() {
  test('nothing said, nothing leaned', () {
    final t = Taste.fromFeedback(const []);
    expect(t.isEmpty, isTrue);
    expect(t.ofKind(Transition.blend), 0);
    expect(t.ofPair(1, 2), 0);
    expect(t.favourite, isNull);
  });

  test('thumbs lean a kind, more the more of them, never past the cap', () {
    final one = Taste.fromFeedback([row('rating', kind: 'dropSwap', rating: 1)]);
    final three = Taste.fromFeedback([for (var i = 0; i < 3; i++) row('rating', kind: 'dropSwap', rating: 1, to: 2 + i)]);
    final many = Taste.fromFeedback([for (var i = 0; i < 40; i++) row('rating', kind: 'dropSwap', rating: 1, to: 2 + i)]);
    expect(one.ofKind(Transition.dropSwap), greaterThan(0));
    expect(three.ofKind(Transition.dropSwap), greaterThan(one.ofKind(Transition.dropSwap)));
    expect(many.ofKind(Transition.dropSwap), closeTo(0.12, 0.01));
    expect(many.favourite, 'dropSwap');
    expect(many.ofKind(Transition.blend), 0, reason: 'nothing said of the blend');
  });

  test('a thumb down on a pair marks the pair, both thumbs cap', () {
    final t = Taste.fromFeedback([row('rating', kind: 'blend', rating: -1), row('rating', kind: 'blend', rating: -1),
        row('rating', kind: 'blend', rating: -1)]);
    expect(t.ofPair(1, 2), -0.3);
    expect(t.ofPair(2, 1), 0);
  });

  test('a steer from one move to another leans a little each way; a zero says nothing', () {
    final t = Taste.fromFeedback([
      row('steer', kind: 'stemBlend', was: 'fade'),
      row('steer', kind: 'stemBlend', was: 'stemBlend'),
      row('rating', kind: 'fade', rating: 0),
      row('replay', kind: 'fade'),
    ]);
    expect(t.count, 1);
    expect(t.ofKind(Transition.stemBlend), greaterThan(0));
    expect(t.ofKind(Transition.fade), lessThan(0));
    expect(t.ofKind(Transition.stemBlend).abs(), lessThan(0.12));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guard that decides whether a keypress is a shortcut or typing.
///
/// It used to test `primaryFocus.context.widget is EditableText`, which is never true:
/// the focused node lives on a Focus widget *inside* EditableText. So every letter
/// typed into the search box also fired a shortcut.
bool isTyping() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  var typing = false;
  ctx.visitAncestorElements((element) {
    if (element.widget is EditableText) {
      typing = true;
      return false;
    }
    return true;
  });
  return typing;
}

void main() {
  testWidgets('a focused text field counts as typing', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TextField(autofocus: true)),
    ));
    await tester.pumpAndSettle();

    expect(isTyping(), isTrue,
        reason: 'letters typed in the search box must not trigger shortcuts');

    // The naive check that shipped first — kept to show why it was replaced.
    final focusedWidget = FocusManager.instance.primaryFocus?.context?.widget;
    expect(focusedWidget is EditableText, isFalse,
        reason: 'the focused node is inside EditableText, not EditableText itself');
  });

  testWidgets('a focused button does not count as typing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ElevatedButton(
            autofocus: true, onPressed: () {}, child: const Text('Play')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(isTyping(), isFalse, reason: 'shortcuts must still work elsewhere');
  });

  testWidgets('nothing focused is not typing', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('idle'))));
    await tester.pumpAndSettle();
    expect(isTyping(), isFalse);
  });
}

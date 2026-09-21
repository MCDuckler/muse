import 'package:flutter/widgets.dart';

/// Dropping a file onto the app, where there is nothing to drop onto.
///
/// A phone has no pointer and no desktop to drag from, so this is the whole of it
/// there: the app carries on being the app.
class DropToAdd extends StatelessWidget {
  const DropToAdd({super.key, required this.child, required this.onFiles});

  final Widget child;
  final Future<void> Function(List<({String name, List<int> bytes})>) onFiles;

  @override
  Widget build(BuildContext context) => child;
}

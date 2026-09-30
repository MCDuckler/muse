import 'dart:ffi' show Abi;
import 'dart:io';

/// The build stamp that ships with the program running this: the build's own number,
/// which the app, the helper beside it and the updater all compare.
///
/// Beside the program on Linux and Windows. In a Mac's app bundle the programs are in
/// Contents/MacOS and the stamp is in Contents/Resources: anything in Contents/MacOS
/// that is not a program has its signature kept in extended attributes, which a zip
/// does not carry, and a bundle whose seal is broken is one macOS will not open.
File buildStampFile({String? program, bool? mac}) {
  final dir = File(program ?? Platform.resolvedExecutable).parent;
  if (mac ?? Platform.isMacOS) {
    return File('${dir.parent.path}/Resources/build-stamp.txt');
  }
  return File('${dir.path}${Platform.pathSeparator}build-stamp.txt');
}

/// What it says, or null where there is none (a build run from the source tree).
String? readBuildStamp({String? program}) {
  try {
    final s = buildStampFile(program: program).readAsStringSync().trim();
    return s.isEmpty ? null : s;
  } catch (_) {
    return null;
  }
}

/// The file name one of the programs that ship beside the app ([name]: wetowl-fetch,
/// wetowl-separate, wetowl-update) has on this computer.
///
/// On a Mac the bundle carries two of each: Dart builds a program for one processor
/// only, and one joined into a single file for both (lipo) no longer finds the code it
/// carries inside itself. The Apple silicon one has the plain name; an Intel Mac's has
/// -x86_64 after it.
String programFile(String name) {
  if (Platform.isWindows) return '$name.exe';
  if (Platform.isMacOS && Abi.current() == Abi.macosX64) return '$name-x86_64';
  return name;
}

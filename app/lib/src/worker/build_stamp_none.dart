/// A browser has no program beside it and no stamp: see build_stamp.dart, which needs
/// dart:io and dart:ffi and is what every other platform gets.
String? readBuildStamp({String? program}) => null;

String programFile(String name) => name;

/// What to call this device, before anybody has named it.
///
/// Every device used to sign in as "flutter" — the name the login form was written
/// with and nobody ever changed — so the list of your devices was a column of the
/// word flutter, and "hand the music to the desk" meant guessing which one that was.
/// This is the best guess the app can make on its own: the browser and the system it
/// is in, the computer's own name, or the kind of phone. A name somebody gives it in
/// the list wins over this and is kept.
library;

export 'device_name_none.dart'
    if (dart.library.io) 'device_name_io.dart'
    if (dart.library.js_interop) 'device_name_web.dart';

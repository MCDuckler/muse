# tray_manager 0.5.3, with AppIndicator loaded rather than linked

This is `tray_manager` 0.5.3 from pub.dev (MIT, see LICENSE), vendored for one change
on Linux. The example, screenshots and tests are left out. Nothing else is changed.

| File | Change |
|---|---|
| `linux/CMakeLists.txt` | No `pkg_check_modules` for AppIndicator and nothing linked against it: only `${CMAKE_DL_LIBS}`. Upstream refused to build without the headers and linked the library, so a Linux without it could not start the app at all — the dynamic linker refuses before a line of it runs. |
| `linux/tray_manager_plugin.cc` | The five AppIndicator calls the plugin uses are looked up with `dlopen` the first time a tray is asked for (Ayatana's library first, then the older libappindicator). Without either, `setIcon` answers `no_appindicator` and the app goes on with no icon (`app/lib/src/ui/tray.dart` then keeps the close button closing). `setTitle` and `setContextMenu` answer the same before there is an indicator, where upstream handed AppIndicator a null. |

Every change is marked with a `WetOwl:` comment. The tray itself is
`app/lib/src/ui/tray.dart`; the runners' one-instance start is in
`app/linux/runner/my_application.cc` and `app/windows/runner/main.cpp`.

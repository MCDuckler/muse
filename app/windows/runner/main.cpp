#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

#ifndef _DEBUG
  // One WetOwl at a time in a built app. Started again while it runs — from the Start
  // menu, most often, with its window shut into the tray — the window it has is shown
  // and brought forward, rather than a second app with a second player in it. The
  // mutex is held for the life of the process and let go of by Windows when it ends.
  // A debug build stays as many as are started, beside the app in daily use.
  // The board's and the stage's own windows (started by the app with --board and
  // --stage, and WETOWL_NON_UNIQUE set, as on Linux) are second processes on
  // purpose, beside the one WetOwl.
  const bool own_window = ::wcsstr(command_line, L"--board") != nullptr ||
                          ::wcsstr(command_line, L"--stage") != nullptr ||
                          ::GetEnvironmentVariableW(L"WETOWL_NON_UNIQUE", nullptr, 0) > 0;
  HANDLE only_one = own_window ? nullptr : ::CreateMutexW(nullptr, TRUE, L"Local\\io.wetowl.muse");
  if (only_one != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND there = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"WetOwl");
    if (there != nullptr) {
      ::ShowWindow(there, ::IsIconic(there) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(there);
    }
    ::CloseHandle(only_one);
    return EXIT_SUCCESS;
  }
#endif

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // The fast GPU where a laptop has two: Windows hands a program the one that saves
  // power unless it asks, and the booth and the stage are a program that wants the
  // other.
  project.set_gpu_preference(
      flutter::DartProject::GpuPreference::HighPerformancePreference);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1360, 860);
  if (!window.Create(L"WetOwl", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

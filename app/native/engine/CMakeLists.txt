# The booth's engine (src/engine.cpp): a shared library the app loads through
# dart:ffi (lib/src/audio/engine.dart), with miniaudio for the sound card and Rubber
# Band (GPL, like the libmpv the app ships) for key lock, both vendored.
cmake_minimum_required(VERSION 3.14)
project(wetowl_engine CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(RB ${CMAKE_CURRENT_SOURCE_DIR}/vendor/rubberband)
add_library(wetowl_engine SHARED
  src/engine.cpp
  src/miniaudio.c
  ${RB}/single/RubberBandSingle.cpp)
target_include_directories(wetowl_engine PRIVATE src vendor ${RB})
set_target_properties(wetowl_engine PROPERTIES CXX_VISIBILITY_PRESET hidden C_VISIBILITY_PRESET hidden
  DEBUG_POSTFIX "" OUTPUT_NAME wetowl_engine)
# The engine is the booth's sound: never build it without optimisation, even in a
# debug app (a debug Rubber Band cannot keep up with real time).
if(MSVC)
  # A debug configuration's run-time checks (/RTC1) refuse /O2 outright (D8016).
  foreach(v CMAKE_CXX_FLAGS_DEBUG CMAKE_C_FLAGS_DEBUG)
    string(REGEX REPLACE "/RTC[1csu]+" "" ${v} "${${v}}")
  endforeach()
  target_compile_options(wetowl_engine PRIVATE /O2)
  target_compile_definitions(wetowl_engine PRIVATE _USE_MATH_DEFINES NOMINMAX)
else()
  target_compile_options(wetowl_engine PRIVATE -O2)
endif()
find_package(Threads REQUIRED)
target_link_libraries(wetowl_engine PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
if(UNIX AND NOT APPLE)
  target_link_libraries(wetowl_engine PRIVATE m)
  # Every symbol found at link time, not when the booth first plays: CI's clang once
  # left Rubber Band's atomic<double>::is_lock_free() to a libatomic the library did
  # not link, and every Linux build died on its first keylocked deck. (Rubber Band's
  # own checks now ask is_always_lock_free, at compile time: the one change to it.)
  target_link_options(wetowl_engine PRIVATE -Wl,--no-undefined)
endif()

option(WETOWL_ENGINE_TESTS "Build the engine's own tests" OFF)
if(WETOWL_ENGINE_TESTS)
  add_executable(engine_test test/engine_test.cpp)
  target_include_directories(engine_test PRIVATE src)
  target_link_libraries(engine_test PRIVATE wetowl_engine)
endif()

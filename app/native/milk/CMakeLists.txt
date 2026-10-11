cmake_minimum_required(VERSION 3.22)
project(wetowl-milk LANGUAGES C CXX)

# wetowl-milk: MilkDrop, as a helper the booth talks to over pipes.
#
# projectM (the open MilkDrop) is fetched at this tag and built here with WetOwl's
# patch, which lets the booth set values preset code can read by name (wo_kick,
# wo_drop, ...). The helper renders offscreen through EGL and writes raw frames to
# its stdout; see wetowl-milk.cpp for the protocol. Built on its own:
#
#   cmake -S app/native/milk -B app/native/milk/build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build app/native/milk/build
#
# or as part of `flutter build linux` (linux/CMakeLists.txt adds this directory and
# puts the helper and the library beside the app).

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)

set(ENABLE_PLAYLIST OFF CACHE BOOL "" FORCE)
set(ENABLE_SDL_UI OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(ENABLE_INSTALL OFF CACHE BOOL "" FORCE)

FetchContent_Declare(projectm
  GIT_REPOSITORY https://github.com/projectM-visualizer/projectm.git
  GIT_TAG        v4.1.6
  GIT_SHALLOW    TRUE
  GIT_SUBMODULES vendor/projectm-eval
  GIT_SUBMODULES_RECURSE FALSE
  PATCH_COMMAND  git apply --ignore-whitespace "${CMAKE_CURRENT_SOURCE_DIR}/projectm-wetowl.patch"
  UPDATE_DISCONNECTED TRUE
)
# projectM stamps its version header from the top-level project's version, which
# is ours (or the Flutter runner's, which has none): told its own here.
set(CMAKE_PROJECT_VERSION 4.1.6)
set(CMAKE_PROJECT_VERSION_MAJOR 4)
set(CMAKE_PROJECT_VERSION_MINOR 1)
set(CMAKE_PROJECT_VERSION_PATCH 6)
FetchContent_MakeAvailable(projectm)

set(OpenGL_GL_PREFERENCE GLVND)
find_package(OpenGL REQUIRED COMPONENTS EGL OpenGL)

add_executable(wetowl-milk wetowl-milk.cpp)
target_link_libraries(wetowl-milk PRIVATE libprojectM::projectM OpenGL::EGL OpenGL::OpenGL)
target_include_directories(wetowl-milk PRIVATE
  "${projectm_SOURCE_DIR}/src/api/include"
  "${projectm_BINARY_DIR}/src/api/include"
  "${projectm_BINARY_DIR}/include")
# The library beside the helper, wherever the two are put.
set_target_properties(wetowl-milk PROPERTIES
  BUILD_RPATH "$ORIGIN;$ORIGIN/lib"
  INSTALL_RPATH "$ORIGIN;$ORIGIN/lib")

# Where the built pieces are, for whoever bundles them.
set(WETOWL_MILK_HELPER $<TARGET_FILE:wetowl-milk> PARENT_SCOPE)
set(WETOWL_MILK_LIBRARY $<TARGET_FILE:projectM> PARENT_SCOPE)

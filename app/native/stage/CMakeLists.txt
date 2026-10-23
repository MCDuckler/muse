# The native stage (src/): the show drawn in OpenGL ES 3 on a thread of its own, into
# textures a Flutter view shows (linux/runner/stage_texture.cc) or with no window at
# all (tools/stage_bench.cpp). See src/ws_stage.h.
cmake_minimum_required(VERSION 3.14)
project(wetowl_stage C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_library(wetowl_stage SHARED src/stage.cpp)
target_include_directories(wetowl_stage PUBLIC src)
set_target_properties(wetowl_stage PROPERTIES CXX_VISIBILITY_PRESET hidden DEBUG_POSTFIX "" OUTPUT_NAME wetowl_stage)
if(WIN32)
  # OpenGL ES 3 through ANGLE, on Direct3D 11 (vcpkg install angle:x64-windows, with
  # vcpkg's toolchain in CMAKE_TOOLCHAIN_FILE); the frames go to Flutter's own
  # Direct3D as textures shared by handle (windows/runner/stage_texture.cpp).
  find_package(unofficial-angle CONFIG REQUIRED)
  target_link_libraries(wetowl_stage PRIVATE unofficial::angle::libEGL unofficial::angle::libGLESv2)
  # The EGL and GLES 3 headers are vcpkg's too (ANGLE's own, or the registries'),
  # which the targets above do not say.
  find_path(WS_GLES_INCLUDE NAMES GLES3/gl3.h REQUIRED)
  find_path(WS_EGL_INCLUDE NAMES EGL/egl.h REQUIRED)
  target_include_directories(wetowl_stage PRIVATE "${WS_GLES_INCLUDE}" "${WS_EGL_INCLUDE}")
  target_compile_definitions(wetowl_stage PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _USE_MATH_DEFINES _CRT_SECURE_NO_WARNINGS)
  target_compile_options(wetowl_stage PRIVATE /EHsc /bigobj /utf-8)
else()
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(WS_GL REQUIRED IMPORTED_TARGET egl glesv2)
  target_link_libraries(wetowl_stage PRIVATE PkgConfig::WS_GL)
  target_compile_options(wetowl_stage PRIVATE -O2)
  target_link_options(wetowl_stage PRIVATE -Wl,--no-undefined -Wl,--exclude-libs,ALL)
endif()
find_package(Threads REQUIRED)
target_link_libraries(wetowl_stage PRIVATE Threads::Threads)

# MilkDrop in the stage's own context: projectM again, for GLES this time and static
# (the helper's, native/milk/, is desktop GL and a library of its own), with the same
# patch; and the helper's command core (native/milk/milk_core.h). Not on Windows yet:
# projectM for GLES has not been built with MSVC against ANGLE; the helper's frames
# come up as a texture there instead (ws_stage.h, ws_features).
if(WIN32)
  option(WETOWL_STAGE_MILK "MilkDrop in the stage's own context" OFF)
else()
  option(WETOWL_STAGE_MILK "MilkDrop in the stage's own context" ON)
endif()
if(WETOWL_STAGE_MILK)
target_compile_definitions(wetowl_stage PRIVATE WS_MILK)
include(ExternalProject)
# Kept under the patch's hash, as the helper's is: a changed patch is a fresh fetch
# (ExternalProject applies a patch once, at the clone).
file(SHA1 "${CMAKE_CURRENT_SOURCE_DIR}/../milk/projectm-wetowl.patch" WS_PM_PATCH_HASH)
string(SUBSTRING "${WS_PM_PATCH_HASH}" 0 10 WS_PM_PATCH_HASH)
set(WS_PM "${CMAKE_CURRENT_BINARY_DIR}/projectm-gles-${WS_PM_PATCH_HASH}")
set(WS_PM_ARGS
  -DCMAKE_BUILD_TYPE=Release -DENABLE_GLES=ON -DBUILD_SHARED_LIBS=OFF -DENABLE_PLAYLIST=OFF -DENABLE_SDL_UI=OFF
  -DBUILD_TESTING=OFF -DENABLE_INSTALL=ON -DENABLE_SYSTEM_PROJECTM_EVAL=OFF -DENABLE_DEBUG_POSTFIX=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=${WS_PM} -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER})
if(CMAKE_C_COMPILER)
  list(APPEND WS_PM_ARGS -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER})
endif()
ExternalProject_Add(projectm_gles
  PREFIX         "${CMAKE_CURRENT_BINARY_DIR}/projectm_gles-${WS_PM_PATCH_HASH}"
  GIT_REPOSITORY https://github.com/projectM-visualizer/projectm.git
  GIT_TAG        v4.1.6
  GIT_SHALLOW    TRUE
  GIT_SUBMODULES vendor/projectm-eval
  GIT_SUBMODULES_RECURSE FALSE
  PATCH_COMMAND  git apply --ignore-whitespace "${CMAKE_CURRENT_SOURCE_DIR}/../milk/projectm-wetowl.patch"
  UPDATE_DISCONNECTED TRUE
  CMAKE_ARGS ${WS_PM_ARGS}
  BUILD_BYPRODUCTS "${WS_PM}/lib/libprojectM-4.a")
file(MAKE_DIRECTORY "${WS_PM}/include")
add_dependencies(wetowl_stage projectm_gles)
target_include_directories(wetowl_stage PRIVATE "${WS_PM}/include" "${CMAKE_CURRENT_SOURCE_DIR}/../milk")
target_link_libraries(wetowl_stage PRIVATE "${WS_PM}/lib/libprojectM-4.a")
endif()

option(WETOWL_STAGE_TOOLS "Build the stage's bench" OFF)
if(WETOWL_STAGE_TOOLS AND NOT WIN32)
  add_executable(stage_bench tools/stage_bench.cpp)
  target_link_libraries(stage_bench PRIVATE wetowl_stage PkgConfig::WS_GL)
endif()

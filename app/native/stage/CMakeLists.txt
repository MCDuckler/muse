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

find_package(PkgConfig REQUIRED)
pkg_check_modules(WS_GL REQUIRED IMPORTED_TARGET egl glesv2)

add_library(wetowl_stage SHARED src/stage.cpp)
target_include_directories(wetowl_stage PUBLIC src)
target_link_libraries(wetowl_stage PRIVATE PkgConfig::WS_GL)
set_target_properties(wetowl_stage PROPERTIES CXX_VISIBILITY_PRESET hidden DEBUG_POSTFIX "" OUTPUT_NAME wetowl_stage)
target_compile_options(wetowl_stage PRIVATE -O2)
find_package(Threads REQUIRED)
target_link_libraries(wetowl_stage PRIVATE Threads::Threads)
target_link_options(wetowl_stage PRIVATE -Wl,--no-undefined -Wl,--exclude-libs,ALL)

# MilkDrop in the stage's own context: projectM again, for GLES this time and static
# (the helper's, native/milk/, is desktop GL and a library of its own), with the same
# patch; and the helper's command core (native/milk/milk_core.h).
include(ExternalProject)
set(WS_PM "${CMAKE_CURRENT_BINARY_DIR}/projectm-gles")
set(WS_PM_ARGS
  -DCMAKE_BUILD_TYPE=Release -DENABLE_GLES=ON -DBUILD_SHARED_LIBS=OFF -DENABLE_PLAYLIST=OFF -DENABLE_SDL_UI=OFF
  -DBUILD_TESTING=OFF -DENABLE_INSTALL=ON -DENABLE_SYSTEM_PROJECTM_EVAL=OFF -DENABLE_DEBUG_POSTFIX=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=${WS_PM} -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER})
if(CMAKE_C_COMPILER)
  list(APPEND WS_PM_ARGS -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER})
endif()
ExternalProject_Add(projectm_gles
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

option(WETOWL_STAGE_TOOLS "Build the stage's bench" OFF)
if(WETOWL_STAGE_TOOLS)
  add_executable(stage_bench tools/stage_bench.cpp)
  target_link_libraries(stage_bench PRIVATE wetowl_stage PkgConfig::WS_GL)
endif()

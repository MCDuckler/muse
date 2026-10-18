# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(muse LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "wetowl")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# The booth's engine (native/engine/): see the Linux CMakeLists.
option(WETOWL_ENGINE "Build the booth's engine" ON)
if(WETOWL_ENGINE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../native/engine/CMakeLists.txt")
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native/engine" engine)
  install(TARGETS wetowl_engine
    RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# MilkDrop: the wetowl-milk helper and the projectM it carries (native/milk/), put
# beside the app. Needs GLEW (vcpkg install glew:x64-windows, with vcpkg's toolchain
# in CMAKE_TOOLCHAIN_FILE); without it the app is built without MilkDrop.
option(WETOWL_MILK "Build the MilkDrop helper" ON)
find_package(GLEW QUIET)
if(WETOWL_MILK AND GLEW_FOUND AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../native/milk/CMakeLists.txt")
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native/milk" milk)
  install(TARGETS wetowl-milk projectM
    RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
  install(FILES $<TARGET_RUNTIME_DLLS:wetowl-milk> DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endif()

# The native stage (native/stage/): the show in OpenGL ES 3 on a thread of its own,
# through ANGLE on Direct3D 11 here (vcpkg install angle:x64-windows, with vcpkg's
# toolchain in CMAKE_TOOLCHAIN_FILE), shown in the app through runner/stage_texture.cpp,
# and the scenes' sources beside it. Without ANGLE the app is built without it, and
# the show draws on its Flutter stage as before.
option(WETOWL_STAGE "Build the native stage" ON)
find_package(unofficial-angle CONFIG QUIET)
if(WETOWL_STAGE AND unofficial-angle_FOUND AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../native/stage/CMakeLists.txt")
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native/stage" stage)
  install(TARGETS wetowl_stage
    RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
  install(FILES $<TARGET_RUNTIME_DLLS:wetowl_stage> DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  # ANGLE's own need — zlib, which libGLESv2.dll imports and the target's list of
  # DLLs leaves out — from beside the release libGLESv2.dll. Not found by name:
  # vcpkg's debug tree comes first on the prefix path of a build with no
  # CMAKE_BUILD_TYPE, as Visual Studio's is, and the debug DLLs want zlibd1.dll and
  # the debug runtime, which no desk has.
  get_target_property(WETOWL_GLES_DLL unofficial::angle::libGLESv2 IMPORTED_LOCATION_RELEASE)
  if(NOT WETOWL_GLES_DLL)
    get_target_property(WETOWL_GLES_DLL unofficial::angle::libGLESv2 IMPORTED_LOCATION)
  endif()
  if(WETOWL_GLES_DLL)
    get_filename_component(WETOWL_ANGLE_BIN "${WETOWL_GLES_DLL}" DIRECTORY)
    # vcpkg's zlib is z.dll (libGLESv2.dll imports it by that name); zlib1.dll in
    # other years.
    file(GLOB WETOWL_ZLIB_DLLS "${WETOWL_ANGLE_BIN}/z.dll" "${WETOWL_ANGLE_BIN}/zlib1.dll" "${WETOWL_ANGLE_BIN}/zlib.dll")
    if(WETOWL_ZLIB_DLLS)
      message(STATUS "stage: ${WETOWL_ZLIB_DLLS} go beside the app")
      install(FILES ${WETOWL_ZLIB_DLLS} DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
    else()
      message(WARNING "stage: no zlib beside ${WETOWL_GLES_DLL}")
    endif()
  else()
    message(WARNING "stage: ANGLE's libGLESv2 has no location to take zlib from")
  endif()
  install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../shaders/show/"
    DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/stage"
    COMPONENT Runtime
    FILES_MATCHING PATTERN "*.frag" PATTERN "*.glsl")
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

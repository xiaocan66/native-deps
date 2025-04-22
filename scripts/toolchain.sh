#!/usr/bin/env bash

set -euo pipefail

if [ -z "${TARGET:-}" ]; then
  echo "Missing TARGET envvar" >&2
  exit 1
fi

if ! [ -d "${SYSROOT:-}" ]; then
  echo "Invalid sysroot provided: ${2:-}" >&2
  exit 1
fi

if ! [ -d "${PREFIX:-}" ]; then
  echo "Invalid prefix provided: ${3:-}" >&2
  exit 1
fi

# The the target system name (*-middle-*) from the target triple
SYSTEM_NAME="${TARGET#*-}"
SYSTEM_NAME="${SYSTEM_NAME%-*}"

# On windows this should be AMD64 or ARM64 or i686
# On macOS aarch64 is called arm64
# However most projects don't check for the windows/macOS specific names
# Considering this we will just use the generic names, and patch any specific issues for those platforms
SYSTEM_PROCESSOR="${TARGET%%-*}"

# Wheter to build iOS versions instead of macOS
OS_IPHONE="${OS_IPHONE:-0}"

# Check if target last part (*-*-last) is android
OS_ANDROID="$(case "${TARGET##*-}" in android*) echo 1 ;; *) echo 0 ;; esac)"

case "$SYSTEM_NAME" in
  windows)
    KERNEL="nt"
    SUBSYSTEM="windows"
    SYSTEM_VERSION=""
    ;;
  darwin)
    KERNEL="xnu"
    # https://theapplewiki.com/wiki/Kernel
    if [ "$OS_IPHONE" -eq 1 ]; then
      SDKROOT="${IOS_SDKROOT:?Missing iOS SDK}"
      SUBSYSTEM="ios"
      # iOS 14
      SYSTEM_VERSION="20.0.0"
    elif [ "$OS_IPHONE" -eq 2 ]; then
      SDKROOT="${IOS_SIMULATOR_SDKROOT:?Missing iOS simulator SDK}"
      SUBSYSTEM="ios-simulator"
      # iOS 14
      SYSTEM_VERSION="20.0.0"
    else
      SDKROOT="${MACOS_SDKROOT:?Missing macOS SDK}"
      SUBSYSTEM="macos"
      case "$SYSTEM_PROCESSOR" in
        x86_64)
          # macOS 10.15
          SYSTEM_VERSION="19.0.0"
          ;;
        aarch64)
          # macOS 11
          SYSTEM_VERSION="20.1.0"
          ;;
      esac
    fi
    ;;
  linux)
    KERNEL="linux"
    if [ "$OS_ANDROID" -eq 1 ]; then
      SDKROOT="${NDK_SDKROOT:?Missing ndk sysroot}"
      SUBSYSTEM="android"
      SYSTEM_NAME="android"
      SYSTEM_VERSION="${ANDROID_API_LEVEL:?Missing android api level}"
    else
      SUBSYSTEM="linux"
      # Linux kernel shipped with CentOS 7
      SYSTEM_VERSION="3.10.0"
    fi
    ;;
esac

cat <<EOF >/srv/cross.meson
[binaries]
c = ['cc']
ar = ['ar']
cpp = ['c++']
lib = ['lib']
strip = ['strip']
ranlib = ['ranlib']
windres = ['rc']
dlltool = ['dlltool']
objcopy = ['objcopy']
objdump = ['objdump']
readelf = ['readelf']

[properties]
cmake_defaults = false
pkg_config_libdir = ['${PREFIX}/lib/pkgconfig', '${PREFIX}/share/pkgconfig']
cmake_toolchain_file = '/srv/toolchain.cmake'

[host_machine]
cpu = '${SYSTEM_PROCESSOR}'
kernel = '${KERNEL}'
endian = 'little'
system = '${SYSTEM_NAME}'
subsystem = '${SUBSYSTEM}'
cpu_family = '${SYSTEM_PROCESSOR}'

EOF

cat <<EOF >/srv/toolchain.cmake
$(
  if [ "$SYSTEM_NAME" = 'darwin' ] && [ "$OS_IPHONE" -ge 1 ]; then
    echo 'set(CMAKE_SYSTEM_NAME iOS)'
  else
    echo "set(CMAKE_SYSTEM_NAME ${SYSTEM_NAME^})"
  fi
)
set(CMAKE_SYSTEM_VERSION ${SYSTEM_VERSION})
set(CMAKE_SYSTEM_PROCESSOR ${SYSTEM_PROCESSOR})

$(
  case "$TARGET" in
    x86_64-darwin*)
      echo 'set(CMAKE_OSX_ARCHITECTURES "x86_64" CACHE STRING "")'
      ;;
    aarch64-darwin*)
      echo 'set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")'
      ;;
    x86_64-linux-android)
      echo 'set(CMAKE_ANDROID_ARCH_ABI x86_64)'
      ;;
    aarch64-linux-android)
      echo 'set(CMAKE_ANDROID_ARCH_ABI arm64-v8a)'
      ;;
  esac
)

$(
  if [ "$OS_ANDROID" -eq 1 ]; then
    echo 'set(CMAKE_ANDROID_STL_TYPE c++-fexceptions)'
    echo 'set(CMAKE_ANDROID_RTTI TRUE)'
    echo 'set(CMAKE_ANDROID_EXCEPTIONS TRUE)'
    echo "set(ANDROID_PLATFORM android-${SYSTEM_VERSION})"
    echo "set(CMAKE_ANDROID_STANDALONE_TOOLCHAIN ${SYSROOT})"
  fi
)

$(if [ -n "${SDKROOT:-}" ]; then echo "set(CMAKE_SYSROOT ${SDKROOT})"; fi)

set(CMAKE_CROSSCOMPILING TRUE)

# Do a no-op access on the CMAKE_TOOLCHAIN_FILE variable so that CMake will not
# issue a warning on it being unused.
if (CMAKE_TOOLCHAIN_FILE)
endif()

set(CMAKE_C_COMPILER cc)
set(CMAKE_CXX_COMPILER c++)
set(CMAKE_RANLIB ranlib)
set(CMAKE_C_COMPILER_RANLIB ranlib)
set(CMAKE_CXX_COMPILER_RANLIB ranlib)
set(CMAKE_AR ar)
set(CMAKE_OBJCOPY objcopy)
set(CMAKE_OBJDUMP objdump)
set(CMAKE_READELF readelf)
set(CMAKE_C_COMPILER_AR ar)
set(CMAKE_CXX_COMPILER_AR ar)
set(CMAKE_RC_COMPILER rc)

set(CMAKE_FIND_ROOT_PATH ${PREFIX} ${SYSROOT})
set(CMAKE_SYSTEM_PREFIX_PATH /)

if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${PREFIX}" CACHE PATH
    "Install path prefix, prepended onto install directories." FORCE)
endif()

# To find programs to execute during CMake run time with find_program(), e.g.
# 'git' or so, we allow looking into system paths.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)

if (NOT CMAKE_FIND_ROOT_PATH_MODE_LIBRARY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
endif()
if (NOT CMAKE_FIND_ROOT_PATH_MODE_INCLUDE)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()
if (NOT CMAKE_FIND_ROOT_PATH_MODE_PACKAGE)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
endif()

if ("\${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES}" STREQUAL "")
  set(CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES ${PREFIX}/include)
endif()
if ("\${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES}" STREQUAL "")
  set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES ${PREFIX}/include)
endif()
EOF

mkdir -p "${PREFIX}/lib/pkgconfig"

case "$TARGET" in
  *darwin*) ;;
  *)
    # Zig has internal support for libunwind
    cat <<EOF >"${PREFIX}/lib/pkgconfig/unwind.pc"
prefix=${SYSROOT}/lib/libunwind
includedir=\${prefix}/include

Name: Libunwind
Description: Zig has internal support for libunwind
Version: 9999
Cflags: -I\${includedir}
Libs: -lunwind
EOF

    ln -s "unwind.pc" "${PREFIX}/lib/pkgconfig/libunwind.pc"

    # Replace libgcc_s with libunwind
    ln -s "unwind.pc" "${PREFIX}/lib/pkgconfig/gcc_s.pc"
    ln -s "unwind.pc" "${PREFIX}/lib/pkgconfig/libgcc_s.pc"

    # zig doesn't provide libgcc_eh
    # As an alternative use libc++ to replace it on windows gnu targets
    cat <<EOF >"${PREFIX}/lib/pkgconfig/gcc_eh.pc"
Name: libgcc_eh
Description: Replace libgcc_eh with libc++
Version: 9999
Libs.private: -lc++
EOF

    ln -s "gcc_eh.pc.pc" "${PREFIX}/lib/pkgconfig/libgcc_eh.pc"
    ;;
esac

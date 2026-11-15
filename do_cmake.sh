#!/bin/sh
set -eu

jobs=${CMAKE_BUILD_PARALLEL_LEVEL:-2}
case "$jobs" in
    1|2) ;;
    *) echo 'CMAKE_BUILD_PARALLEL_LEVEL must be 1 or 2' >&2; exit 2 ;;
esac
export CMAKE_BUILD_PARALLEL_LEVEL=$jobs
# Keep configure-time try-compiles free of inherited recursive make controls.
if [ -n "${MAKEFLAGS+x}${MFLAGS+x}${GNUMAKEFLAGS+x}${MAKEOVERRIDES+x}${MAKEFILES+x}${MAKE+x}${MAKELEVEL+x}" ]; then
    echo 'Inherited make controls replaced by the compiler job budget' >&2
fi
unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKEFILES MAKE MAKELEVEL

mkdir -p _build/cmake
cd _build/cmake

if type cmake3 > /dev/null 2>&1 ; then
    CMAKE=cmake3
else
    CMAKE=cmake
fi

${CMAKE} "$@" ../../c_src || exit 1

echo done.

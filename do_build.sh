#!/bin/sh
set -eu

# The environment is a ceiling, including when a caller supplies -j.
jobs=${CMAKE_BUILD_PARALLEL_LEVEL:-2}
case "$jobs" in
    1|2) ;;
    *) echo 'CMAKE_BUILD_PARALLEL_LEVEL must be 1 or 2' >&2; exit 2 ;;
esac
case "${1-}" in
    -j)
        [ "$#" -ge 2 ] || { echo '-j requires 1 or 2' >&2; exit 2; }
        requested=$2
        shift 2
        ;;
    -j1|-j2) requested=${1#-j}; shift ;;
    -j*|--jobs*|--parallel*)
        echo 'Use -j 1 or -j 2; unbounded or larger job counts are forbidden' >&2
        exit 2
        ;;
    *) requested=$jobs ;;
esac
case "$requested" in
    1|2) ;;
    *) echo '-j requires 1 or 2' >&2; exit 2 ;;
esac
[ "$requested" -ge "$jobs" ] || jobs=$requested
# Project hooks use only no arguments or one bounded -j option. Do not expose
# make's CLI: clusters, abbreviations and variable assignments can undo -j.
if [ "$#" -ne 0 ]; then
    echo 'Unsupported build arguments; use no arguments, -j1, -j2, -j 1 or -j 2' >&2
    exit 2
fi
# Inherited make controls can carry variable redefinitions into recursive make.
# CMake's explicit parallel budget is the sole source of job control here.
if [ -n "${MAKEFLAGS+x}${MFLAGS+x}${GNUMAKEFLAGS+x}${MAKEOVERRIDES+x}${MAKEFILES+x}${MAKE+x}${MAKELEVEL+x}" ]; then
    echo 'Inherited make controls replaced by the compiler job budget' >&2
fi
unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKEFILES MAKE MAKELEVEL

cd _build/cmake
if command -v cmake3 > /dev/null 2>&1; then
    CMAKE=cmake3
else
    CMAKE=cmake
fi
exec "$CMAKE" --build . --parallel "$jobs"

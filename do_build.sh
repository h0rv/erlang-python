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
# Do not permit later native-tool options to override the ceiling.
for argument do
    case "$argument" in
        *-j*|*--jobs*|*--parallel*)
            echo 'Additional parallelism options are forbidden' >&2; exit 2 ;;
    esac
done

cd _build/cmake
if command -v cmake3 > /dev/null 2>&1; then
    CMAKE=cmake3
else
    CMAKE=cmake
fi
exec "$CMAKE" --build . --parallel "$jobs" -- "$@"

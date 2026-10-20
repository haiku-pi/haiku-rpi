#!/usr/bin/env bash
# make-icu-shim.sh — artifacts/packages/icu74_bootstrap-74.1-1-any.hpkg: the arm64 icu74 bootstrap
# package (the build's icu74-74.1_bootstrap-1) was built with its data directory as
# /packages/icu74_bootstrap-74.1-1/.self/data/icu/74.1, so ICU finds no data (time zones, collation,
# break iterators: U_MISSING_RESOURCE_ERROR) in any process without this shim
# (scripts/make-bootstrap-shim.sh). Remove it once icu74 is rebuilt for arm64.
#
#   scripts/make-icu-shim.sh
exec "$(dirname "$0")/make-bootstrap-shim.sh" icu74_bootstrap 74.1-1 icu74 "ICU's data (data/icu/74.1)"

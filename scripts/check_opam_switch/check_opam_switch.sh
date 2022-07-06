#!/usr/bin/env bash

# This script checks that the ocaml packages specified in the
# src/opam.export file are installed in the current switch.

set -e 

CHECK_OPAM_DIR="$(dirname "$0")"

temp_file=$(mktemp /tmp/opam.export.XXXXXX)
trap "rm -f $temp_file" 0 2 3 15

opam switch export "$temp_file"

pushd "$CHECK_OPAM_DIR"
dune exec ./check_opam_switch.exe ../../src/opam.export "$temp_file"
popd


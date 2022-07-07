#!/usr/bin/env bash

# This script checks that the ocaml packages specified in the
# src/opam.export file are installed in the current switch.

set -e

if [ "$DISABLE_CHECK_OPAM_SWITCH_SCRIPT" = true ] ; then
    touch checked_switch
    exit 0
fi

temp_file=$(mktemp /tmp/opam.export.XXXXXX)
trap "rm -f $temp_file" 0 2 3 15

opam switch export "$temp_file"

./check_opam_switch.exe ../../src/opam.export "$temp_file"

# because we use "set -e", the checked_switch file will only be created if check_opam_switch.exe succeeds
touch checked_switch

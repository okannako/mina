#!/usr/bin/env bash
# This script records the last time the opam switch was modified to a file.

stat -c "%y %n" "$OPAM_SWITCH_PREFIX/.opam-switch/switch-state" > opam_update_time

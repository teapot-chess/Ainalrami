#!/bin/bash
# usage: run_chunk.sh AXIS FROM TO     (AXIS = a | h)
cd "$(dirname "$0")/../.." || exit 1
export ELIXIR_ERL_OPTIONS="+S 8:8" MIX_ENV=test MATCH_GEN=8 MATCH_PY=8 MATCH_CHUNK=1000
export BBPPAIRINGS_EXE="${BBPPAIRINGS_EXE:?set BBPPAIRINGS_EXE to a bbpPairings binary}"
export TMP="$PWD/tmp/refusal_big/tmpdir" TEMP="$PWD/tmp/refusal_big/tmpdir"
axis=$1; from=$2; to=$3
free_kb=$(df -k /c | tail -1 | awk '{print $4}')
if [ "$free_kb" -lt 3145728 ]; then echo "REFUSING: only $free_kb KB free on C: (need 3 GB)" | tee -a tmp/refusal_big/results.txt; exit 3; fi
res=tmp/refusal_big/results.txt
if [ "$axis" = "a" ]; then
  args="$from $to 16 11 20 tmp/refusal_big/dumps_a"
else
  export PAIRING_FUZZ_BYE_PCT=12 PAIRING_FUZZ_FORFEIT_PCT=12 PAIRING_FUZZ_FORBIDDEN_PCT=25 PAIRING_FUZZ_ACCEL=mixed PAIRING_FUZZ_POINT_SYSTEM=mixed
  args="$from $to 20 13 40 tmp/refusal_big/dumps_h"
fi
echo "##### axis $axis seeds $from-$to start $(date +%FT%T)" >> $res
mix run tools/exhaustion_matching.exs $args 2>&1 | tee -a $res
echo "##### axis $axis seeds $from-$to end $(date +%FT%T)" >> $res

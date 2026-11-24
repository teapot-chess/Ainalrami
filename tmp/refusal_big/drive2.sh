#!/bin/bash
cd "$(dirname "$0")/../.." || exit 1
res=tmp/refusal_big/results.txt; log=tmp/refusal_big/drive2.log
while ! grep -q "AXIS_A_DONE\|STOP" tmp/refusal_big/drive.log 2>/dev/null; do sleep 30; done
grep -q STOP tmp/refusal_big/drive.log && { echo "axis a stopped" >> $log; exit 1; }
echo "##### NOTE: patch run of seed 45597 alone (harness error from the full disk in chunk 39501-46000)" >> $res
tmp/refusal_big/run_chunk.sh a 45597 45597 >/dev/null 2>&1
git add -A tmp/refusal_big/results.txt; git commit -qm "Refusal proof big run: 11-20 axis complete, seed 45597 patched" >/dev/null 2>&1
start=$(date +%s); deadline=$((start+2*3600)); from=4701; size=400
while [ $(date +%s) -lt $deadline ]; do
  to=$((from+size-1)); t0=$(date +%s)
  tmp/refusal_big/run_chunk.sh h $from $to >/dev/null 2>&1
  el=$(( $(date +%s)-t0 ))
  if tail -60 $res | grep -E "flagged positions: *[1-9]|harness errors: *[1-9]|EXISTS: *[1-9]|strict\): *[1-9]|REFUSING" | grep -q .; then echo "STOP harsh $from-$to" >> $log; exit 1; fi
  git add -A tmp/refusal_big/results.txt; git commit -qm "Refusal proof big run: harsh axis to seed $to" >/dev/null 2>&1
  from=$((to+1)); size=$(( size*1500/(el>60?el:60) )); [ $size -gt 3000 ] && size=3000; [ $size -lt 100 ] && size=100
done
echo "HARSH_DONE next=$from" >> $log

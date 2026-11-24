#!/bin/bash
cd "$(dirname "$0")/../.." || exit 1
res=tmp/refusal_big/results.txt
# wait for chunk already running
while tasklist | grep -q "erl.exe"; do sleep 5; done
n=0
chk() { # stop on any disagreement
  if tail -60 $res | grep -E "EXISTS|too strict|harness err" | grep -vE " 0( |$)" | grep -q .; then echo STOP >> tmp/refusal_big/drive.log; return 1; fi
  if tail -60 $res | grep -E "flagged [1-9]" | grep -q .; then echo STOP >> tmp/refusal_big/drive.log; return 1; fi
  if tail -3 $res | grep -q REFUSING; then echo STOP >> tmp/refusal_big/drive.log; return 1; fi
  return 0; }
for r in "51501 57000" "57001 62500" "62501 68000" "68001 73500" "73501 79000" "79001 80000"; do
  chk || exit 1
  git add -A tmp/refusal_big/results.txt tmp/refusal_big/run_chunk.sh tmp/refusal_big/drive.sh >/dev/null 2>&1; git commit -qm "Refusal proof big run: progress to seed ${r% *}" >/dev/null 2>&1
  tmp/refusal_big/run_chunk.sh a $r >/dev/null 2>&1
done
chk || exit 1
git add -A tmp/refusal_big/results.txt; git commit -qm "Refusal proof big run: 11-20 axis complete" >/dev/null 2>&1
echo AXIS_A_DONE >> tmp/refusal_big/drive.log

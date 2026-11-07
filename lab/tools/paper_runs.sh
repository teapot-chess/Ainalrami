#!/usr/bin/env bash
# The simulator runs behind docs/fide-rules-evidence-draft.md.
#
#   tools/paper_runs.sh OUT_DIR SCALE WORKERS
#
# SCALE multiplies every corpus's tournament count: 1 is the sample run
# on a desktop (minutes per variant), 20 is the VM run. Every run writes
# OUT_DIR/<corpus>/<variant>/report.{txt,json}; a run whose report.json
# exists is skipped, so a stopped script resumes where it stopped.
set -euo pipefail

out=${1:?OUT_DIR}
scale=${2:-1}
workers=${3:-$(nproc)}
here=$(cd "$(dirname "$0")/.." && pwd)
lab="$here/ainalrami-lab"

run() {
  local corpus_name=$1 corpus=$2 pairer=$3 variant=$4
  local dir="$out/$corpus_name/${variant//[:+=,]/_}"
  if [ -f "$dir/report.json" ]; then return; fi
  mkdir -p "$dir"
  echo "== $corpus_name  $variant"
  "$lab" simulate --variant "$variant" --corpus "$corpus" --pairer "$pairer" \
    --workers "$workers" --examples 3 --out "$dir" > /dev/null
}

small="generated:players=10,rounds=7,count=$((1000 * scale)),absent=0.05,forfeit=0.03"
large="generated:players=40,rounds=9,count=$((300 * scale)),absent=0.05,forfeit=0.03"
late="generated:players=10,rounds=6,count=$((1000 * scale)),absent=0.1,forfeit=0.15,late=2"

variants=(
  baseline
  drop:C12
  drop:C13
  move:C14:before:C10
  move:C12:after:C21
  float_memory=1
  float_memory=3
  absolute_cd=2
  streak=3
  c3=off
  drop:C8
  drop:C9
  c18=paired
  c13=strong_only
  rematches=allowed
)

for v in "${variants[@]}"; do run small "$small" brute "$v"; done
for v in "${variants[@]}"; do run large "$large" hybrid "$v"; done
for v in baseline c525=tpn c525=initial; do run late "$late" brute "$v"; done

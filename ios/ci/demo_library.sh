#!/bin/bash
# Builds a neutral demo library for CI screenshots (colour cards + test-pattern clips).
set -e
LIB="$1"; mkdir -p "$LIB"; cd "$LIB"
i=0
for d in "풍경/여름/산책" "풍경/겨울/산책" "풍경/여름" "동물/고양이/짧은 영상" "동물/강아지/산책" "음식/디저트" "자동감시/@sample_account" "자동감시/@another_one" "좋아요"; do
  mkdir -p "$d"
  for n in 1 2 3 4 5; do
    i=$((i+1)); h=$(( (i*47) % 360 ))
    stamp=$(printf "202610%02d1200%02d" $(( (i % 28) + 1 )) $n)
    if [ $((n % 2)) = 0 ]; then
      ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=720x1280:rate=30" -t 4 -vf "hue=h=$h" -pix_fmt yuv420p "$d/user${i}_${stamp}_001.mp4"
      ffmpeg -loglevel error -y -ss 1 -i "$d/user${i}_${stamp}_001.mp4" -frames:v 1 "$d/user${i}_${stamp}_001.jpg"
    else
      ffmpeg -loglevel error -y -f lavfi -i "gradients=size=1080x1350:seed=$i:speed=0" -frames:v 1 "$d/photo${i}_${stamp}_001.jpg" 2>/dev/null \
        || ffmpeg -loglevel error -y -f lavfi -i "color=c=0x$(printf '%02x%02x%02x' $((i*40%255)) $((i*90%255)) $((i*20%255))):size=1080x1350" -frames:v 1 "$d/photo${i}_${stamp}_001.jpg"
    fi
  done
done
find . -type f | wc -l

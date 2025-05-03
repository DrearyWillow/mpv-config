#!/bin/bash

file="$1"
if [ ! -e "$file" ]; then
    echo "Received audio filepath does not exist: $file"
    exit 1
fi
# url="$(mediainfo --Output=JSON "$file" | jq -r '.media.track[0].extra.Official_audio_file_webpage')"
# url="$(mediainfo --Output=JSON "$file" | jq -r '.media.track[] | select(."@type" == "General").extra.Official_audio_file_webpage')"
url="$(mediainfo --Output=JSON "$file" | jq -r '.media.track[] | select(.extra.Official_audio_file_webpage != null) | .extra.Official_audio_file_webpage' | head -n 1)"
echo "WOAF URL: $url"

if [ -z "$url" ]; then
    exit 1
else
    xdg-open "$url"
fi
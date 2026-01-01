#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title EzPlayer
# @raycast.mode silent
# @raycast.packageName EzPlayer

# Optional parameters:
# @raycast.icon 🎵

# Documentation:
# @raycast.description Open audio/video file in EzPlayer (mp4 auto-converts to wav)
# @raycast.author ruipu

# ============================================================
# Configuration - Update this path after installation
# ============================================================
# Default: looks for EzPlayer.app in the same directory as this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${SCRIPT_DIR}/../EzPlayer.app"

# Alternative: specify your custom installation path
# APP_PATH="$HOME/Applications/EzPlayer.app"
# ============================================================

# Get the selected file from Finder
FILE_PATH=$(osascript -e 'tell application "Finder"
    try
        set theSelection to selection
        if (count of theSelection) > 0 then
            return POSIX path of (item 1 of theSelection as alias)
        else
            return ""
        end if
    on error
        return ""
    end try
end tell' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
    osascript -e 'display notification "Please select an audio/video file in Finder first" with title "EzPlayer"'
    exit 1
fi

# Remove trailing newline/slash if any
FILE_PATH=$(echo "$FILE_PATH" | tr -d '\n' | sed 's:/$::')

# Check if file exists
if [ ! -f "$FILE_PATH" ]; then
    osascript -e "display notification \"File not found: $FILE_PATH\" with title \"EzPlayer\""
    exit 1
fi

# Check file extension
EXT="${FILE_PATH##*.}"
EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')

# Handle video files - convert to wav first
if [[ "$EXT_LOWER" == "mp4" || "$EXT_LOWER" == "m4v" || "$EXT_LOWER" == "mov" || "$EXT_LOWER" == "mkv" || "$EXT_LOWER" == "webm" ]]; then
    BASENAME=$(basename "$FILE_PATH" ".$EXT")
    OUTPUT_DIR=$(dirname "$FILE_PATH")
    WAV_PATH="$OUTPUT_DIR/${BASENAME}.wav"
    
    # Check if ffmpeg is available
    if ! command -v ffmpeg &> /dev/null; then
        osascript -e 'display notification "ffmpeg not found. Install with: brew install ffmpeg" with title "EzPlayer"'
        exit 1
    fi
    
    osascript -e 'display notification "Converting video to audio..." with title "EzPlayer"'
    
    # Convert to wav using ffmpeg
    ffmpeg -i "$FILE_PATH" -vn -acodec pcm_s16le -ar 44100 -ac 2 "$WAV_PATH" -y 2>/dev/null
    
    if [ $? -ne 0 ]; then
        osascript -e 'display notification "Failed to convert video to audio" with title "EzPlayer"'
        exit 1
    fi
    
    FILE_PATH="$WAV_PATH"
elif [[ "$EXT_LOWER" != "mp3" && "$EXT_LOWER" != "wav" && "$EXT_LOWER" != "m4a" && "$EXT_LOWER" != "aac" && "$EXT_LOWER" != "aiff" && "$EXT_LOWER" != "flac" ]]; then
    osascript -e 'display notification "Unsupported format. Use mp3, wav, m4a, aac, aiff, flac, or video files" with title "EzPlayer"'
    exit 1
fi

# Launch EzPlayer with the file
if [ -d "$APP_PATH" ]; then
    open -a "$APP_PATH" "$FILE_PATH"
    echo "Opening: $(basename "$FILE_PATH")"
else
    osascript -e "display notification \"EzPlayer.app not found at: $APP_PATH\" with title \"EzPlayer\""
    echo "Error: EzPlayer.app not found. Please build it first or update APP_PATH in this script."
    exit 1
fi

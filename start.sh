#!/bin/bash
set -e

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HOST_BIN="/Applications/TabScreen.app/Contents/MacOS/TabScreenHost"
if [ ! -f "$HOST_BIN" ]; then
    HOST_BIN="$DIR/mac-host/.build/release/TabScreenHost"
fi

if [ ! -f "$HOST_BIN" ]; then
    echo "Building TabScreen Host..."
    "$DIR/build-app.sh"
    HOST_BIN="/Applications/TabScreen.app/Contents/MacOS/TabScreenHost"
fi

echo "Starting TabScreen Host..."
exec "$HOST_BIN" "$@"

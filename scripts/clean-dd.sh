#!/bin/zsh
# Removes THIS checkout's DerivedData folder (frees disk; the Mac is low on space).
cd "$(git rev-parse --show-toplevel)"
[ -d FANBOXClient.xcodeproj ] || exit 0
DIR=$(xcodebuild -project FANBOXClient.xcodeproj -scheme FANBOXClient -showBuildSettings 2>/dev/null | awk -F' = ' '/ OBJROOT = /{print $2; exit}')
case "$DIR" in
  */DerivedData/FANBOXClient-*) ROOT=${DIR%%/Build/*}; echo "removing $ROOT"; rm -rf "$ROOT";;
  *) echo "no derived data found ($DIR)";;
esac

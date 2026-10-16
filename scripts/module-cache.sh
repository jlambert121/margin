# Sourced by the build and test scripts from the repository root.
# Compiled module caches embed the absolute path they were built under, so a
# moved or renamed checkout fails every compile until the cache is rebuilt.
MODULE_CACHE="$PWD/build/module-cache"
if [ "$(cat build/.module-cache-root 2>/dev/null)" != "$PWD" ]; then
  rm -rf "$MODULE_CACHE"
fi
mkdir -p "$MODULE_CACHE"
printf '%s' "$PWD" > build/.module-cache-root

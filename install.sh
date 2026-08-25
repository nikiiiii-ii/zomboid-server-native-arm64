#!/data/data/com.termux/files/usr/bin/bash
#
# zomboid-server-native-arm64 — installer
#
# Sets up a Project Zomboid B42 dedicated server running natively on
# ARM64 Android via Termux. No box64, no FEX, no QEMU.
#
# Usage:  bash install.sh
#
set -e

PZ_DIR="$HOME/pzserver"
DD_DIR="$HOME/dd"
GAME_DIR="$HOME/pzgame"
NATIVES_DIR="$PZ_DIR/arm64"
LWJGL_VERSION="3.4.1"
ZOMDROID_URL="https://github.com/udarmolota/zomdroid/releases/download/v1.4.8/zomdroid-release-1.4.8v3.apk"
DD_URL="https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-framework.zip"
RAM="3g"

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mxx\033[0m %s\n' "$1" >&2; exit 1; }

# Discard anything typed while a long task was running, so a stray Enter
# doesn't get consumed as the answer to the next prompt.
flush_input() {
  while read -r -t 0.1 -n 10000 _ < /dev/tty; do :; done 2>/dev/null || true
}

# --- sanity checks ------------------------------------------------------

[ "$(uname -m)" = "aarch64" ] || die "This script is for ARM64 devices. Detected: $(uname -m)"
[ -d "/data/data/com.termux" ] || die "Termux not detected. This script runs inside Termux, not proot."

say "Project Zomboid native ARM64 server installer"
echo "    Install dir : $PZ_DIR"
echo "    Heap size   : $RAM  (edit RAM= at the top to change)"

# --- packages -----------------------------------------------------------

say "Installing packages (Java 25, .NET 9, unzip, tmux)"
pkg update -y >/dev/null
pkg install -y openjdk-25 dotnet-runtime-9.0 unzip tmux curl

JAVA_VER=$(java -version 2>&1 | head -1)
echo "    $JAVA_VER"
case "$JAVA_VER" in
  *\"25*) ;;
  *) warn "Expected Java 25. PZ 42.20+ is compiled for class file version 69 and will not load on older JVMs." ;;
esac

# --- DepotDownloader ----------------------------------------------------
# SteamCMD cannot run on Android: the kernel lacks set_robust_list, so it
# aborts with "futex robust_list not initialized by pthreads" even under
# emulation. The framework build of DepotDownloader uses the system .NET,
# which matters because the linux-arm64 build links glibc and Termux is bionic.

if [ ! -f "$DD_DIR/DepotDownloader.dll" ]; then
  say "Installing DepotDownloader"
  cd "$HOME"
  curl -Lo dd.zip "$DD_URL"
  mkdir -p "$DD_DIR"
  unzip -q -o dd.zip -d "$DD_DIR"
  rm -f dd.zip
fi
dotnet "$DD_DIR/DepotDownloader.dll" --version

# --- ARM natives from the game depot ------------------------------------
# The game ships ARM64 builds of its native libraries at
# projectzomboid/natives/android/arm64-v8a/ — but only in the GAME depot
# (app 108600), not the dedicated server depot. Requires owning the game.
#
# Done before the 7 GB download so the login prompt isn't buried under it.

SRC="$GAME_DIR/projectzomboid/natives/android/arm64-v8a"

if [ ! -f "$NATIVES_DIR/libRakNet64.so" ]; then
  say "ARM64 natives — this step needs your Steam account"
  echo "    Only ~95 MB is downloaded (the android/ folder)."
  echo "    Steam Guard will prompt on your phone or email."

  echo "regex:.*android.*" > "$HOME/.pz-filter.txt"

  # Retry rather than abort: a mistyped password shouldn't cost you the run.
  until [ -f "$SRC/libRakNet64.so" ]; do
    flush_input
    STEAM_USER=""
    while [ -z "$STEAM_USER" ]; do
      printf '    Steam username: '
      read -r STEAM_USER < /dev/tty
    done

    if ! dotnet "$DD_DIR/DepotDownloader.dll" -app 108600 -os linux -osarch 64 \
        -dir "$GAME_DIR" -filelist "$HOME/.pz-filter.txt" -username "$STEAM_USER"; then
      warn "Steam login failed. Check the password and try again."
    fi
  done

  mkdir -p "$NATIVES_DIR"
  cp "$SRC"/*.so "$NATIVES_DIR/"
  rm -f "$HOME/.pz-filter.txt"
else
  say "ARM64 natives already present, skipping"
fi

# --- LWJGL --------------------------------------------------------------
# The server initialises its gamepad subsystem at boot, which loads LWJGL.
# The jar only bundles x86_64 natives; LWJGL's own linux-arm64 build is
# glibc. Zomdroid ships a bionic-compatible build — credit to that project.

if [ ! -f "$NATIVES_DIR/liblwjgl.so" ]; then
  say "Extracting ARM LWJGL $LWJGL_VERSION from the Zomdroid APK"
  cd "$HOME"
  curl -Lo zomdroid.apk "$ZOMDROID_URL"
  unzip -q -o zomdroid.apk "assets/bundles/libs.tar.xz" -d "$HOME/zomdroid-extract"
  cd "$HOME/zomdroid-extract"
  tar -xf assets/bundles/libs.tar.xz

  LW="android-arm64-v8a/lwjgl-$LWJGL_VERSION"
  if [ ! -d "$LW" ]; then
    warn "lwjgl-$LWJGL_VERSION is not in this APK. Available:"
    ls -d android-arm64-v8a/lwjgl-* 2>/dev/null || true
    die "Set LWJGL_VERSION at the top of this script to match your game build."
  fi
  cp "$LW"/*.so "$NATIVES_DIR/"
  cd "$HOME" && rm -f zomdroid.apk
else
  say "LWJGL already present, skipping"
fi

say "Native libraries in place:"
ls -1 "$NATIVES_DIR"

# --- server files -------------------------------------------------------

if [ ! -f "$PZ_DIR/java/projectzomboid.jar" ]; then
  say "Downloading server files — about 7 GB, this takes a while"
  echo "    Anonymous login, no account needed for this part."
  dotnet "$DD_DIR/DepotDownloader.dll" -app 380870 -os linux -osarch 64 -dir "$PZ_DIR"
else
  say "Server files already present, skipping"
fi

# --- data dirs ----------------------------------------------------------
# The server watches ~/Zomboid/mods at boot and throws a NoSuchFileException
# if it doesn't exist. Harmless, but it clutters the log — create it upfront.

mkdir -p "$HOME/Zomboid/mods"

# --- launcher -----------------------------------------------------------

say "Writing launcher to $HOME/start-pz.sh"
cat > "$HOME/start-pz.sh" <<LAUNCHER
#!/data/data/com.termux/files/usr/bin/bash
cd "$PZ_DIR"
exec java \\
  -Djava.awt.headless=true \\
  -Xmx$RAM \\
  -Dzomboid.steam=0 \\
  -Djava.library.path=$NATIVES_DIR \\
  -Dorg.lwjgl.librarypath=$NATIVES_DIR \\
  -XX:+UseSerialGC \\
  -cp "java/:java/projectzomboid.jar" \\
  zombie.network.GameServer -nosteam
LAUNCHER
chmod +x "$HOME/start-pz.sh"

# --- done ---------------------------------------------------------------

say "Done."
cat <<'NOTES'

First run — do this in the foreground so you can set the admin password:

    ~/start-pz.sh

Wait for *** SERVER STARTED ****, then Ctrl+C to stop.

After that, run it detached so it survives closing your SSH session:

    termux-wake-lock
    tmux new -d -s pz ~/start-pz.sh

Check on it without attaching:

    tmux capture-pane -pt pz | tail -20

Players connect to your LAN IP on UDP 16261 and need -nosteam in their
Steam launch options. For access outside your network, see the README.

NOTES#!/data/data/com.termux/files/usr/bin/bash
#
# zomboid-server-native-arm64 — installer
#
# Sets up a Project Zomboid B42 dedicated server running natively on
# ARM64 Android via Termux. No box64, no FEX, no QEMU.
#
# Usage:  bash install.sh
#
set -e

PZ_DIR="$HOME/pzserver"
DD_DIR="$HOME/dd"
GAME_DIR="$HOME/pzgame"
NATIVES_DIR="$PZ_DIR/arm64"
LWJGL_VERSION="3.4.1"
ZOMDROID_URL="https://github.com/udarmolota/zomdroid/releases/download/v1.4.8/zomdroid-release-1.4.8v3.apk"
DD_URL="https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-framework.zip"
RAM="3g"

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mxx\033[0m %s\n' "$1" >&2; exit 1; }

# Discard anything typed while a long task was running, so a stray Enter
# doesn't get consumed as the answer to the next prompt.
flush_input() {
  while read -r -t 0.1 -n 10000 _ < /dev/tty; do :; done 2>/dev/null || true
}

# --- sanity checks ------------------------------------------------------

[ "$(uname -m)" = "aarch64" ] || die "This script is for ARM64 devices. Detected: $(uname -m)"
[ -d "/data/data/com.termux" ] || die "Termux not detected. This script runs inside Termux, not proot."

say "Project Zomboid native ARM64 server installer"
echo "    Install dir : $PZ_DIR"
echo "    Heap size   : $RAM  (edit RAM= at the top to change)"

# --- packages -----------------------------------------------------------

say "Installing packages (Java 25, .NET 9, unzip, tmux)"
pkg update -y >/dev/null
pkg install -y openjdk-25 dotnet-runtime-9.0 unzip tmux curl

JAVA_VER=$(java -version 2>&1 | head -1)
echo "    $JAVA_VER"
case "$JAVA_VER" in
  *\"25*) ;;
  *) warn "Expected Java 25. PZ 42.20+ is compiled for class file version 69 and will not load on older JVMs." ;;
esac

# --- DepotDownloader ----------------------------------------------------
# SteamCMD cannot run on Android: the kernel lacks set_robust_list, so it
# aborts with "futex robust_list not initialized by pthreads" even under
# emulation. The framework build of DepotDownloader uses the system .NET,
# which matters because the linux-arm64 build links glibc and Termux is bionic.

if [ ! -f "$DD_DIR/DepotDownloader.dll" ]; then
  say "Installing DepotDownloader"
  cd "$HOME"
  curl -Lo dd.zip "$DD_URL"
  mkdir -p "$DD_DIR"
  unzip -q -o dd.zip -d "$DD_DIR"
  rm -f dd.zip
fi
dotnet "$DD_DIR/DepotDownloader.dll" --version

# --- ARM natives from the game depot ------------------------------------
# The game ships ARM64 builds of its native libraries at
# projectzomboid/natives/android/arm64-v8a/ — but only in the GAME depot
# (app 108600), not the dedicated server depot. Requires owning the game.
#
# Done before the 7 GB download so the login prompt isn't buried under it.

SRC="$GAME_DIR/projectzomboid/natives/android/arm64-v8a"

if [ ! -f "$NATIVES_DIR/libRakNet64.so" ]; then
  say "ARM64 natives — this step needs your Steam account"
  echo "    Only ~95 MB is downloaded (the android/ folder)."
  echo "    Steam Guard will prompt on your phone or email."

  echo "regex:.*android.*" > "$HOME/.pz-filter.txt"

  # Retry rather than abort: a mistyped password shouldn't cost you the run.
  until [ -f "$SRC/libRakNet64.so" ]; do
    flush_input
    STEAM_USER=""
    while [ -z "$STEAM_USER" ]; do
      printf '    Steam username: '
      read -r STEAM_USER < /dev/tty
    done

    if ! dotnet "$DD_DIR/DepotDownloader.dll" -app 108600 -os linux -osarch 64 \
        -dir "$GAME_DIR" -filelist "$HOME/.pz-filter.txt" -username "$STEAM_USER"; then
      warn "Steam login failed. Check the password and try again."
    fi
  done

  mkdir -p "$NATIVES_DIR"
  cp "$SRC"/*.so "$NATIVES_DIR/"
  rm -f "$HOME/.pz-filter.txt"
else
  say "ARM64 natives already present, skipping"
fi

# --- LWJGL --------------------------------------------------------------
# The server initialises its gamepad subsystem at boot, which loads LWJGL.
# The jar only bundles x86_64 natives; LWJGL's own linux-arm64 build is
# glibc. Zomdroid ships a bionic-compatible build — credit to that project.

if [ ! -f "$NATIVES_DIR/liblwjgl.so" ]; then
  say "Extracting ARM LWJGL $LWJGL_VERSION from the Zomdroid APK"
  cd "$HOME"
  curl -Lo zomdroid.apk "$ZOMDROID_URL"
  unzip -q -o zomdroid.apk "assets/bundles/libs.tar.xz" -d "$HOME/zomdroid-extract"
  cd "$HOME/zomdroid-extract"
  tar -xf assets/bundles/libs.tar.xz

  LW="android-arm64-v8a/lwjgl-$LWJGL_VERSION"
  if [ ! -d "$LW" ]; then
    warn "lwjgl-$LWJGL_VERSION is not in this APK. Available:"
    ls -d android-arm64-v8a/lwjgl-* 2>/dev/null || true
    die "Set LWJGL_VERSION at the top of this script to match your game build."
  fi
  cp "$LW"/*.so "$NATIVES_DIR/"
  cd "$HOME" && rm -f zomdroid.apk
else
  say "LWJGL already present, skipping"
fi

say "Native libraries in place:"
ls -1 "$NATIVES_DIR"

# --- server files -------------------------------------------------------

if [ ! -f "$PZ_DIR/java/projectzomboid.jar" ]; then
  say "Downloading server files — about 7 GB, this takes a while"
  echo "    Anonymous login, no account needed for this part."
  dotnet "$DD_DIR/DepotDownloader.dll" -app 380870 -os linux -osarch 64 -dir "$PZ_DIR"
else
  say "Server files already present, skipping"
fi

# --- data dirs ----------------------------------------------------------
# The server watches ~/Zomboid/mods at boot and throws a NoSuchFileException
# if it doesn't exist. Harmless, but it clutters the log — create it upfront.

mkdir -p "$HOME/Zomboid/mods"

# --- launcher -----------------------------------------------------------

say "Writing launcher to $HOME/start-pz.sh"
cat > "$HOME/start-pz.sh" <<LAUNCHER
#!/data/data/com.termux/files/usr/bin/bash
cd "$PZ_DIR"
exec java \\
  -Djava.awt.headless=true \\
  -Xmx$RAM \\
  -Dzomboid.steam=0 \\
  -Djava.library.path=$NATIVES_DIR \\
  -Dorg.lwjgl.librarypath=$NATIVES_DIR \\
  -XX:+UseSerialGC \\
  -cp "java/:java/projectzomboid.jar" \\
  zombie.network.GameServer -nosteam
LAUNCHER
chmod +x "$HOME/start-pz.sh"

# --- done ---------------------------------------------------------------

say "Done."
cat <<'NOTES'

First run — do this in the foreground so you can set the admin password:

    ~/start-pz.sh

Wait for *** SERVER STARTED ****, then Ctrl+C to stop.

After that, run it detached so it survives closing your SSH session:

    termux-wake-lock
    tmux new -d -s pz ~/start-pz.sh

Check on it without attaching:

    tmux capture-pane -pt pz | tail -20

Players connect to your LAN IP on UDP 16261 and need -nosteam in their
Steam launch options. For access outside your network, see the README.

NOTES

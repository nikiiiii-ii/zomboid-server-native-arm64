# zomboid-server-native-arm64

Run a **Project Zomboid Build 42 dedicated server natively on ARM64** — no box64, no FEX, no QEMU, no emulation of any kind.

Tested on a **Poco X3 Pro** (Snapdragon 860, 8 GB RAM) running Termux on Android 12, hosting **PZ 42.20.3**.

---

## The short version

Everyone hosting PZ on ARM emulates the x86 server. They do this because of a shared assumption, stated plainly in the most complete ARM project available:

> *"The PZ server is x86-only, so on ARM it runs through box64 emulation."*

**That assumption is outdated.** The Indie Stone ships ARM64 native libraries inside the game depot, at:

```
projectzomboid/natives/android/arm64-v8a/
```

Nine `.so` files, built with Android NDK r23c for `arm64-v8a`:

```
libRakNet64.so          libZNetNoSteam64.so     libPZPathFind64.so
libPZPopMan64.so        libPZBullet64.so        libPZClipper64.so
libjassimp64.so         libLighting64.so        libfmodintegration64.so
```

Combine those with a **native ARM64 JVM** and the game's own `projectzomboid.jar` (architecture-independent Java bytecode), and the server runs natively. The emulation layer disappears entirely.


## Benchmarks

Same phone, same game version, same world. Emulated run used box64 with `-Xint` (the only configuration that didn't crash).

| Stage | box64 + `-Xint` | Native ARM64 | Speedup |
| --- | --- | --- | --- |
| `IsoMetaGrid` (map load) | 479 s | **8.5 s** | 56× |
| `LOADING ASSETS` | ~6 min | **23 s** | ~15× |
| World backup | 2174 ms | **180 ms** | 12× |
| Save on shutdown | 4004 ms | **495 ms** | 8× |
| Full startup to `SERVER STARTED` | ~50 min | **< 1 min** | ~50× |

Runtime with one player connected: **20 % CPU**, 60 °C peak, 2.7 GB resident.

The emulated run reached `SERVER STARTED` but was unplayable — hundreds of `chunk was not generated in 30000 ms` warnings meant the client never received terrain. The native run has none.

---

## Requirements

- ARM64 Android device, **6 GB RAM minimum** (8 GB comfortable)
- ~10 GB free storage
- [Termux](https://f-droid.org/packages/com.termux/) from **F-Droid or GitHub** — the Play Store build is abandoned and broken
- A Steam account that **owns Project Zomboid** (needed to pull the ARM natives from the game depot; the server files themselves download anonymously)

No root. No proot. No Docker.

---

## Install

### 1. Base packages

```bash
pkg update && pkg upgrade -y
pkg install openjdk-25 dotnet-runtime-9.0 unzip tmux -y
```

`openjdk-25` matters: PZ 42.20.3 is compiled for Java 25 (class file version 69). Java 17 and 21 will refuse to load its classes.

Verify it's native:

```bash
java -version   # should print 25.x, mixed mode, with no emulator banner
```

### 2. DepotDownloader

SteamCMD cannot run here — the Android kernel doesn't implement the `set_robust_list` syscall it depends on, so it aborts with `futex robust_list not initialized by pthreads` even under box64. DepotDownloader replaces it.

Use the **framework** build, not `linux-arm64`: the latter links against glibc, and Termux is bionic.

```bash
cd ~
curl -Lo dd.zip https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-framework.zip
mkdir -p ~/dd && unzip -q dd.zip -d ~/dd
dotnet ~/dd/DepotDownloader.dll --version
```

### 3. Server files (anonymous, ~7 GB)

```bash
dotnet ~/dd/DepotDownloader.dll -app 380870 -os linux -osarch 64 -dir ~/pzserver
```

### 4. ARM64 natives (requires your Steam login)

```bash
echo "regex:.*android.*" > ~/filter.txt
dotnet ~/dd/DepotDownloader.dll -app 108600 -os linux -osarch 64 \
  -dir ~/pzgame -filelist ~/filter.txt -username YOUR_STEAM_USER
```

That pulls ~95 MB — only the `android/` folder. Then:

```bash
cp -r ~/pzgame/projectzomboid/natives/android/arm64-v8a ~/pzserver/arm64
```

### 5. LWJGL for ARM

The server initialises its gamepad subsystem at boot (`GamepadState` → `ControllerState` → `Input`), which pulls in LWJGL. The jar only bundles x86_64 natives, so it dies with:

```
UnsatisfiedLinkError: Failed to locate library: liblwjgl.so
```

LWJGL's official `natives-linux-arm64` build is glibc, so it won't load in Termux either. The [Zomdroid](https://github.com/udarmolota/zomdroid) APK ships a bionic-compatible build of the matching version (3.4.1):

```bash
cd ~
curl -Lo zomdroid.apk https://github.com/udarmolota/zomdroid/releases/download/v1.4.8/zomdroid-release-1.4.8v3.apk
unzip -o zomdroid.apk "assets/bundles/libs.tar.xz" -d ~/zomdroid-extract
cd ~/zomdroid-extract && tar -xf assets/bundles/libs.tar.xz
cp android-arm64-v8a/lwjgl-3.4.1/*.so ~/pzserver/arm64/
```

Match the LWJGL version to your game build — check the log line `/tmp/lwjgl_root/<version>/` on a failed run.

### 6. Launch

```bash
cd ~/pzserver && java \
  -Djava.awt.headless=true \
  -Xmx3g \
  -Dzomboid.steam=0 \
  -Djava.library.path=$HOME/pzserver/arm64 \
  -Dorg.lwjgl.librarypath=$HOME/pzserver/arm64 \
  -XX:+UseSerialGC \
  -cp "java/:java/projectzomboid.jar" \
  zombie.network.GameServer -nosteam
```

Note what's **absent**: no `box64`, no `BOX64_DYNAREC_*` tuning, no `-Xint`, no `LD_PRELOAD`, no `LD_LIBRARY_PATH` pointing at x86 directories. Plain `java`.

First run prompts for an admin password.

### 7. Keep it alive

```bash
termux-wake-lock
tmux new -d -s pz ~/start-pz.sh
```

Without `termux-wake-lock`, Android suspends the process when the screen turns off.

---

## Known limitation

```
UnsatisfiedLinkError: 'void zombie.popman.ZombiePopulationManager.n_saveCell(int, int)'
```

The ARM build of `libPZPopMan64.so` is missing `n_saveCell`. This is expected — those libraries were built for the **client** (Zomdroid), and clients don't persist zombie cell state; the server does.

**Effect:** zombies spawn, path, and behave normally during play, but their per-cell state isn't written to disk. After a restart they repopulate from world rules rather than resuming exactly where they were. The map, buildings, loot, vehicles and player data all save correctly.

If The Indie Stone ever ships the full server-side symbol set for ARM, this disappears.

---

## Connecting from outside

`-nosteam` means Steam's relay and server browser are unavailable. Clients must add the server manually and set `-nosteam` in their Steam launch options.

Steam P2P is not reachable from this setup, and not for lack of trying:

- `libsteam_api.so` has no aarch64 build — [open request since 2023](https://github.com/ValveSoftware/steam-for-linux/issues/9331)
- Steam's client uses the same `set_robust_list` syscall Android lacks
- Tellingly, the ARM natives include `libZNetNoSteam64.so` and **no** Steam variant

For CGNAT connections without router access, a tunnel like [playit.gg](https://playit.gg) works — the agent is glibc, so run it inside `proot-distro debian` while the server runs natively in Termux.

---

## What was ruled out

For anyone tempted to retry the emulation path on Android specifically:

| Emulator | Result |
| --- | --- |
| **box64** 0.4.3 | Server boots, but the dynarec miscompiles JIT-generated code. Crashes in `SafepointMechanism::update_poll_values` (Zulu 25) or inside C1 output (Temurin 25). `-Xint` avoids it at ~5 % of native speed — unplayable. Matches [box64#3864](https://github.com/ptitSeb/box64/issues). |
| **FEX-Emu** 2608 | Won't start: `Couldn't allocate memory region`. FEX assumes a 48-bit address space; Android exposes 39. |
| **QEMU** 10.2 / 11.0 | Emulates fine (`uname` works), but no JVM initialises — `SEGV_MAPERR` in `Assembler::push` during `VM_Version_init`. Reproduced with Java 17 and 25, with a manual `-L` rootfs and with `proot-distro -a x86_64`. |

All three ultimately collide with the same fact: Android's kernel gives 39 bits of address space where an x86_64 JVM expects 48.

---

## Prior art

These projects all take the emulation route, and their groundwork is what made the comparison possible:

- [kaanzapkinus/ZomboidServer-arm](https://github.com/kaanzapkinus/ZomboidServer-arm) — the most complete box64 setup, with a full control panel
- [Dyarven/zomboid-server-on-arm](https://github.com/Dyarven/zomboid-server-on-arm) — the original ARM installer script
- [The five-year Steam thread](https://steamcommunity.com/app/108600/discussions/1/3415433168012191380/) — the community's collected attempts
- [Zomdroid](https://github.com/udarmolota/zomdroid) — the PZ client on Android, and the source of the ARM LWJGL build

Interestingly, several of the box64 workarounds documented in this repo's history were independently rediscovered here before finding kaanzapkinus's list: `BOX64_DYNAREC_STRONGMEM=3` for JVM boot deadlocks, `-XX:+UseSerialGC` because ZGC deadlocks under box64. Convergent debugging.

---

## Credits

Developed through an extended troubleshooting session with Claude (Anthropic), working from the emulation dead-ends toward the native approach.

MIT licensed. Not affiliated with The Indie Stone.

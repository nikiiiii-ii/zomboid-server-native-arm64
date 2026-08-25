# zomboid-server-native-arm64

Run a **Project Zomboid Build 42 dedicated server natively on ARM64**, with no box64, no FEX, no QEMU.

Tested on a **Poco X3 Pro** (Snapdragon 860, 8 GB RAM) running Termux on Android 12, hosting **PZ 42.20.3**.

---

## How it works

Project Zomboid ships ARM64 native libraries inside the game depot, at:

```
projectzomboid/natives/android/arm64-v8a/
```

Nine `.so` files, built with Android NDK r23c for `arm64-v8a`:

```
libRakNet64.so          libZNetNoSteam64.so     libPZPathFind64.so
libPZPopMan64.so        libPZBullet64.so        libPZClipper64.so
libjassimp64.so         libLighting64.so        libfmodintegration64.so
```

Pair those with a **native ARM64 JVM** and the game's own `projectzomboid.jar` (architecture-independent bytecode), and the server runs without any translation layer.

Note that the `android/` folder lives in the **game** depot (app `108600`), not the **dedicated server** depot (app `380870`), so you need to own the game to pull it.

---

## Benchmarks

Same phone, same game version, same world. The emulated run used box64 with `-Xint`, the only configuration that didn't crash.

| Stage | box64 + `-Xint` | Native ARM64 | Speedup |
| --- | --- | --- | --- |
| `IsoMetaGrid` (map load) | 479 s | **8.5 s** | 56× |
| `LOADING ASSETS` | ~6 min | **23 s** | ~15× |
| World backup | 2174 ms | **180 ms** | 12× |
| Save on shutdown | 4004 ms | **495 ms** | 8× |
| Full startup to `SERVER STARTED` | ~50 min | **< 1 min** | ~50× |

Runtime with one player connected: **20 % CPU**, 60 °C peak, 2.7 GB resident.

The emulated run reached `SERVER STARTED` but was unplayable. Hundreds of `chunk was not generated in 30000 ms` warnings meant the client never received terrain. The native run has none.

---

## Requirements

- ARM64 Android device, **6 GB RAM minimum** (8 GB comfortable)
- ~10 GB free storage
- [Termux](https://f-droid.org/packages/com.termux/) from **F-Droid or GitHub**, since the Play Store build is abandoned and broken
- A Steam account that **owns Project Zomboid** (for the ARM natives; the server files themselves download anonymously)

No root. No proot. No Docker.

---

## Quick start

**0. Set up SSH.** Skip this if you already have it, or if you don't mind typing on the phone.

Everything below is easier from a computer. In Termux:

```bash
pkg install openssh -y
passwd          # set a password
whoami          # note the username, e.g. u0_a309
sshd            # start the server, listens on port 8022
```

Get the phone's LAN IP from Android settings (Wi-Fi → your network), then from your computer:

```bash
ssh -p 8022 u0_a309@192.168.1.x
```

Port 8022, not 22, because Termux can't bind privileged ports without root.

`sshd` doesn't survive a reboot on its own. To start it automatically, install the [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) addon from the same source as Termux, then create a startup script:

```bash
mkdir -p ~/.termux/boot
nano ~/.termux/boot/start-sshd
```

Put this in the file:

```sh
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
sshd
```

Save with `Ctrl+O`, `Enter`, then `Ctrl+X`. Make it executable:

```bash
chmod +x ~/.termux/boot/start-sshd
```

**1. Install.** Inside Termux:

```bash
pkg install git -y && git clone https://github.com/nikiiiii-ii/zomboid-server-native-arm64 && cd zomboid-server-native-arm64 && bash install.sh
```

Or without git:

```bash
curl -Lo install.sh https://raw.githubusercontent.com/nikiiiii-ii/zomboid-server-native-arm64/main/install.sh && bash install.sh
```

The script asks for your Steam username early on, only to fetch the ~95 MB `android/` folder, and Steam Guard will prompt on your phone. Everything after that is unattended, including the ~7 GB server download.

Run it in Termux itself, **not** inside proot, because the native libraries are bionic, and proot distros are glibc.

**2. First run**, in the foreground, so you can set the admin password:

```bash
~/start-pz.sh
```

Wait for `*** SERVER STARTED ****`, then `Ctrl+C` to stop.

**3. Run it detached** so it survives closing your terminal:

```bash
termux-wake-lock
tmux new -d -s pz ~/start-pz.sh
```

`termux-wake-lock` is not optional. Without it, Android suspends the process when the screen turns off, and the server dies silently.

**4. Check on it** without attaching:

```bash
tmux capture-pane -pt pz | tail -20
```

At this point you can close your terminal. The server keeps running on the phone.

To stop it: `tmux kill-session -t pz`. To restart: repeat step 3.

---

## Manual install

If you'd rather do it step by step.

### 1. Base packages

```bash
pkg update && pkg upgrade -y
pkg install openjdk-25 dotnet-runtime-9.0 unzip tmux -y
```

`openjdk-25` matters: PZ 42.20.3 is compiled for Java 25 (class file version 69). Java 17 and 21 refuse to load its classes.

### 2. DepotDownloader

SteamCMD can't run here, because the Android kernel doesn't implement `set_robust_list`, so it aborts with `futex robust_list not initialized by pthreads` even under emulation.

Use the **framework** build, not `linux-arm64`: the latter links glibc, and Termux is bionic.

```bash
cd ~
curl -Lo dd.zip https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-framework.zip
mkdir -p ~/dd && unzip -q dd.zip -d ~/dd
dotnet ~/dd/DepotDownloader.dll --version
```

### 3. ARM64 natives (requires Steam login)

```bash
echo "regex:.*android.*" > ~/filter.txt
dotnet ~/dd/DepotDownloader.dll -app 108600 -os linux -osarch 64 \
  -dir ~/pzgame -filelist ~/filter.txt -username YOUR_STEAM_USER

mkdir -p ~/pzserver/arm64
cp ~/pzgame/projectzomboid/natives/android/arm64-v8a/*.so ~/pzserver/arm64/
```

### 4. LWJGL for ARM

The server initialises its gamepad subsystem at boot (`GamepadState` → `ControllerState` → `Input`), pulling in LWJGL. The jar only bundles x86_64 natives, so it dies with:

```
UnsatisfiedLinkError: Failed to locate library: liblwjgl.so
```

LWJGL's official `natives-linux-arm64` build is glibc and won't load in Termux. The [Zomdroid](https://github.com/udarmolota/zomdroid) APK ships a bionic build of the matching version, and that project's work is what makes this step possible:

```bash
cd ~
curl -Lo zomdroid.apk https://github.com/udarmolota/zomdroid/releases/download/v1.4.8/zomdroid-release-1.4.8v3.apk
unzip -o zomdroid.apk "assets/bundles/libs.tar.xz" -d ~/zomdroid-extract
cd ~/zomdroid-extract && tar -xf assets/bundles/libs.tar.xz
cp android-arm64-v8a/lwjgl-3.4.1/*.so ~/pzserver/arm64/
```

Match the LWJGL version to your game build. Check the `/tmp/lwjgl_root/<version>/` path in a failed run's log.

### 5. Server files (anonymous, ~7 GB)

```bash
dotnet ~/dd/DepotDownloader.dll -app 380870 -os linux -osarch 64 -dir ~/pzserver
```

### 6. Launch

```bash
cd ~/pzserver && java -Djava.awt.headless=true -Xmx3g -Dzomboid.steam=0 -Djava.library.path=$HOME/pzserver/arm64 -Dorg.lwjgl.librarypath=$HOME/pzserver/arm64 -XX:+UseSerialGC -cp "java/:java/projectzomboid.jar" zombie.network.GameServer -nosteam
```

What each flag does:

| Flag | Why |
| --- | --- |
| `-Djava.library.path=.../arm64` | Where the ARM natives live. Without this it looks in `linux64/`, which holds the x86 ones. |
| `-Dorg.lwjgl.librarypath=.../arm64` | Stops LWJGL from unpacking its bundled x86 build to `/tmp`. |
| `-Dzomboid.steam=0` + `-nosteam` | Skips `steamclient.so`, which has no ARM build. |
| `-XX:+UseSerialGC` | Lighter than G1 on a phone; also what the emulated setups end up needing. |
| `-Xmx3g` | Heap ceiling. Raise or lower to fit your RAM. |

Note what's absent: no `box64`, no `BOX64_DYNAREC_*` tuning, no `-Xint`, no `LD_PRELOAD`. Plain `java`.

---

## Configuration

Settings live in `~/Zomboid/Server/`. Changes require a restart.

**Zombie density.** In `servertest_SandboxVars.lua`, the variable `Zombies`. The scale is inverted:

| Value | Meaning |
| --- | --- |
| 1 | Insane |
| 2 | High |
| 3 | Moderate |
| 4 | Normal (default) |
| 5 | Low |
| 6 | None |

```bash
sed -i 's/Zombies = 4,/Zombies = 2,/' ~/Zomboid/Server/servertest_SandboxVars.lua
```

**Player limit, server name, passwords.** In `servertest.ini`.

**Heap size.** Edit `-Xmx` in `~/start-pz.sh`. Leave headroom: Android's low-memory killer takes the process without warning if you claim too much. On 8 GB, 3–3.5 GB works.

**Temperature.** Worth checking on long sessions:

```bash
for i in /sys/class/thermal/thermal_zone*/temp; do cat $i 2>/dev/null; done | sort -n | tail -5
```

Around 60 °C under load is normal. Keep the phone out of its case and off soft surfaces.

---

## Known limitation

```
UnsatisfiedLinkError: 'void zombie.popman.ZombiePopulationManager.n_saveCell(int, int)'
```

The ARM build of `libPZPopMan64.so` is missing `n_saveCell`. This is expected, since those libraries were built for the client, and clients don't persist zombie cell state; the server does.

**Effect:** zombies spawn, path and behave normally during play, but their per-cell state isn't written to disk. After a restart they repopulate from world rules rather than resuming exactly where they were. Map, buildings, loot, vehicles and player data all save correctly.

---

## Connecting from outside

`-nosteam` means Steam's relay and server browser are unavailable. Clients add the server manually and need `-nosteam` in their Steam launch options.

Steam P2P isn't reachable from this setup:

- `libsteam_api.so` has no aarch64 build, an [open request since 2023](https://github.com/ValveSoftware/steam-for-linux/issues/9331)
- Steam's client uses the same `set_robust_list` syscall Android lacks
- The ARM natives include `libZNetNoSteam64.so` and no Steam variant

### Tunnelling through CGNAT

If your ISP puts you behind CGNAT, with no public IP and no port forwarding, a tunnel service works. [playit.gg](https://playit.gg) has a free tier and players don't install anything.

Its agent is a glibc binary, so it won't run in Termux directly (DNS resolution fails). Run it inside a proot distro instead, while the server stays native:

```bash
pkg install proot-distro -y
proot-distro install debian
proot-distro login debian
```

Then inside Debian:

```bash
apt update && apt install -y curl
cd /root
curl -Lo playit https://github.com/playit-cloud/playit-agent/releases/download/v0.15.26/playit-linux-aarch64
chmod +x playit
./playit
```

It prints a claim URL. Open it in a browser, sign in, and create a tunnel of type **Project Zomboid** pointing at `127.0.0.1:16261`. You get an address like `something.tun.ply.gg:2914` to hand out.

To keep it running alongside the server:

```bash
cat > ~/start-playit.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login debian -- /root/playit
EOF
chmod +x ~/start-playit.sh
tmux new -d -s playit ~/start-playit.sh
```

Newer agent versions (1.x) split the daemon from a GUI frontend and can't be claimed from a terminal, which is why this pins 0.15.26.

---

## Updating

When Project Zomboid gets a new build, re-run both downloads:

```bash
dotnet ~/dd/DepotDownloader.dll -app 380870 -os linux -osarch 64 -dir ~/pzserver

echo "regex:.*android.*" > ~/filter.txt
dotnet ~/dd/DepotDownloader.dll -app 108600 -os linux -osarch 64 \
  -dir ~/pzgame -filelist ~/filter.txt -username YOUR_STEAM_USER
cp ~/pzgame/projectzomboid/natives/android/arm64-v8a/*.so ~/pzserver/arm64/
```

Things worth checking after an update:

- **Java version.** If the server dies with `UnsupportedClassVersionError`, the game moved to a newer JDK. Check `pkg search openjdk` for a matching build.
- **LWJGL version.** If `liblwjgl.so` fails to load again, the game bumped LWJGL. The version it wants shows up as `/tmp/lwjgl_root/<version>/` in the log; look for that version in a current Zomdroid APK.
- **The `android/` folder itself.** This whole approach depends on The Indie Stone continuing to ship it. If a future build drops it, keep a copy of the working `.so` files, though they may or may not still load, or they may not.

Back up `~/Zomboid` before updating:

```bash
tar -czf ~/zomboid-backup.tar.gz ~/Zomboid
```

---

## Emulation, for reference

Results from testing the emulation path on Android specifically:

| Emulator | Result |
| --- | --- |
| **box64** 0.4.3 | Server boots, but the dynarec miscompiles JIT-generated code. Crashes in `SafepointMechanism::update_poll_values` (Zulu 25) or inside C1 output (Temurin 25). `-Xint` avoids it at roughly 5 % of native speed. Related issues on the [box64 tracker](https://github.com/ptitSeb/box64/issues). |
| **FEX-Emu** 2608 | Won't start: `Couldn't allocate memory region`. FEX assumes a 48-bit address space; Android exposes 39. |
| **QEMU** 10.2 / 11.0 | Emulates fine (`uname` works), but no JVM initialises. You get `SEGV_MAPERR` in `Assembler::push` during `VM_Version_init`. Reproduced with Java 17 and 25, with a manual `-L` rootfs and with `proot-distro -a x86_64`. |

All three collide with the same constraint: Android's kernel gives 39 bits of address space where an x86_64 JVM expects 48.

---

## Credits

This project stands on other people's work.

**[Zomdroid](https://github.com/udarmolota/zomdroid)**, by [udarmolota](https://github.com/udarmolota), forked from [liamelui/zomdroid](https://github.com/liamelui/zomdroid) (archived). Two things here come directly from it:

- **The ARM LWJGL build.** `liblwjgl.so` and `liblwjgl_opengl.so` are extracted from the Zomdroid APK (`assets/bundles/libs.tar.xz`). They compiled LWJGL against bionic for Android; without that, the server can't get past its gamepad init. Nothing in this repo rebuilds them; it just unpacks theirs.
- **Knowing the natives existed at all.** A Zomdroid release note pointed at `natives/android/arm64-v8a/` inside the game files. That's the whole basis of this approach.

**[The Indie Stone](https://projectzomboid.com/)**, for shipping ARM64 builds of the engine's native libraries in the game depot in the first place, presumably for their own Android work.

**[DepotDownloader](https://github.com/SteamRE/DepotDownloader)** (SteamRE), the only practical way to pull Steam depots on a platform where SteamCMD refuses to run.

**[playit.gg](https://playit.gg)**, the tunnel used in the CGNAT instructions.

---

## Related projects

- [kaanzapkinus/ZomboidServer-arm](https://github.com/kaanzapkinus/ZomboidServer-arm), a box64 setup with a control panel, mod management and auto-updates. Their documented box64 workarounds (`BOX64_DYNAREC_STRONGMEM=3`, `UseSerialGC`) match what the emulation testing here ran into independently.
- [Dyarven/zomboid-server-on-arm](https://github.com/Dyarven/zomboid-server-on-arm), an ARM installer script using box86/box64
- [etheth888/project-zomboid-arm64](https://hub.docker.com/r/etheth888/project-zomboid-arm64), a Docker image, also emulated
- [Steam thread on ARM64 server binaries](https://steamcommunity.com/app/108600/discussions/1/3415433168012191380/), years of community attempts at this

---

MIT licensed. Not affiliated with The Indie Stone.

# AirPlay2Bridge — LMS plugin for HomePods on HomePodOS 27+

Workaround for the **HomePodOS 27 silence bug**: Apple stopped rendering legacy
RAOP (AirPlay 1) audio — LMS's RaopBridge connects, RTP flows, but the HomePod
stays silent ([philippe44/LMS-Raop#57](https://github.com/philippe44/LMS-Raop/issues/57);
upstream declined to implement AirPlay 2). This plugin streams via **AirPlay 2**
using [pyatv](https://github.com/postlund/pyatv), based on
[cayco's bridge](https://github.com/cayco/cayco-squeezelite-airplay2-bridge) recipe:

```
LMS → squeezelite (patched: PCM to stdout, silent when idle)
    → bridge.py (python, per-speaker process, plugin-managed)
    → pyatv (AirPlay 2, HAP transient pairing)
    → HomePod
```

HomePods become **regular squeezelite players** in LMS — sync groups, favorites,
home-integration and automation keep working. Idle 30 s → clean teardown (HomePod
released); volume is forwarded from LMS; settings page has a discovery scan +
checkboxes UI like RaopBridge. See [AirPlay2Bridge/README.md](AirPlay2Bridge/README.md)
for details, behavior and pitfalls.

## Install

**Requirements** (Debian/Ubuntu host running LMS):
```sh
apt-get install -y squeezelite python3-pip
pip3 install --break-system-packages pyatv==0.18.0
# patched squeezelite (skip-silence stdout patch):
cd AirPlay2Bridge/patches && bash build_squeezelite.sh   # -> /usr/local/bin/squeezelite-ap2
```

**From this repository** (LMS 8+):
1. LMS Settings → Plugins → Additional Repositories, add:
   `https://raw.githubusercontent.com/knovash/airplay2/main/repo.xml`
2. Find **AirPlay 2 Bridge (HomePodOS 27+)** in the plugin list → Install.
3. LMS Settings → Plugins → AirPlay 2 Bridge → **Start Discovery Scan** →
   tick your HomePods → Save. Done.

**Manual**: copy `AirPlay2Bridge/` to `/usr/share/squeezeboxserver/Plugins/`
(chown squeezeboxserver:nogroup), restart LMS.

> Migrating from RaopBridge: give the new players the **MACs of the old
> RaopBridge players** (editable via the plugin's `devices` pref or by seeding
> `players` first) so playlists/sync groups/room bindings are inherited, and
> disable RaopBridge to avoid duplicate players.

## Credits

- [cayco/cayco-squeezelite-airplay2-bridge](https://github.com/cayco/cayco-squeezelite-airplay2-bridge) — the recipe: architecture, stdout patch, AP2 flags, buffering/volume handling
- [postlund/pyatv](https://github.com/postlund/pyatv) (MIT) — the actual AirPlay 2 implementation
- [philippe44/LMS-Raop](https://github.com/philippe44/LMS-Raop) — RaopBridge: settings UI model, issue #57 context
- toralt — original squeezelite | pyatv idea from the #57 thread
- squeezelite (Adrian Smith, Ralph Irving) — base of the stdout patch (**GPLv3**)

## Status

v1.1 — works on HomePodOS 27.0 (1 HomePod + 2 HomePod mini), tested daily.
Python bridges ~60–80 MB RSS each, ~0 CPU idle / ~15% per active stream (aarch64).

## Releases

`./make_dist.sh` → `dist/AirPlay2Bridge-v<ver>.zip` (sha1 printed) → attach to a
GitHub release, update `sha=`/`url=` in `repo.xml`.
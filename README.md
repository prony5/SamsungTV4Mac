# SamsungTV4Mac

Play any video from your Mac on a Samsung Smart TV (Tizen) over your local network — no apps on the TV, no media server setup. Built with SwiftUI for macOS 14+.

<p align="center">
English | <a href="README_RU.md">Русский</a>
</p>

<p align="center"><img src="assets/icon.png" width="128" alt="SamsungTV4Mac icon"></p>

## Features

- **Finds TVs automatically** via SSDP/UPnP — also works with a VPN enabled — or add a TV by IP address
- **Drag & drop** a video file (or *Open With → SamsungTV4Mac* in Finder) and press **Play on TV**
- **Checks compatibility** with ffprobe and tells you whether the TV can play the file as is
- **Converts on the fly when needed** — Xvid/DivX, DTS, AVI and other formats the TV rejects ("The selected file is currently not supported") are converted with the Apple Silicon hardware encoder, typically 50–100× faster than real time. Audio, other tracks and text subtitles are kept; compatible streams are copied untouched
- **Remote control from the Mac** — play/pause, seek, ±30 s, stop, TV volume
- **Keeps the Mac awake** while it streams to the TV
- English and Russian UI

## How It Works

The TV acts as a DLNA *Media Renderer*. SamsungTV4Mac runs a tiny HTTP server (with Range support, so seeking works), and tells the TV via UPnP AVTransport to play the file's URL. Files the TV can't decode are first remuxed or transcoded with [ffmpeg](https://ffmpeg.org) into a TV-friendly MKV (H.264 + AC3), cached in `~/Library/Caches/SamsungTV4Mac`.

| Plays directly | Converted automatically |
|---|---|
| Video: H.264, HEVC, VP9, MPEG-2 | MPEG-4 Part 2 (Xvid/DivX), 10-bit H.264, others → H.264 |
| Audio: AAC, AC3, E-AC3, MP3 | DTS, TrueHD, FLAC, Opus, … → AC3 |
| Containers: MP4, MKV, WebM, TS | AVI, WMV, FLV, … → MKV |

Other DLNA renderers (LG, Sony, Kodi, …) will most likely work too, but Samsung is what it is tested with.

## Requirements

| | |
|---|---|
| **macOS** | 14 Sonoma or newer (tested on macOS 26 Tahoe, Apple Silicon) |
| **TV** | Samsung Smart TV with Tizen (2016+), on the same network as the Mac |
| **ffmpeg** | Needed for compatibility checks and conversion: `brew install ffmpeg` |

## Installation

### Download

1. Download the latest `SamsungTV4Mac-x.y.z.dmg` from [Releases](https://github.com/prony5/SamsungTV4Mac/releases) and drag the app to *Applications*.
2. The app is not notarized, so on the first launch macOS will block it. Either right-click the app → **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/SamsungTV4Mac.app
   ```
3. Install ffmpeg: `brew install ffmpeg`
4. Allow **Local Network** access when macOS asks (needed to find and control the TV).

### Build from source

Only the Xcode Command Line Tools are required (full Xcode is optional):

```bash
git clone https://github.com/prony5/SamsungTV4Mac.git
cd SamsungTV4Mac
./build-dmg.sh            # → .build/release/SamsungTV4Mac.app and .dmg
./scripts/test.sh         # run the tests
```

Use `UNIVERSAL=1 ./build-dmg.sh` for an arm64 + x86_64 build.

## Troubleshooting

- **TV not found** — make sure the TV is on and on the same Wi-Fi/LAN. Add it manually with **+** using the IP from *Settings → General → Network → Network Status*. Guest networks and "client isolation" on routers block discovery and streaming.
- **"Could not determine this Mac's address"** — the Mac and the TV are on different networks.
- **Playback stops after a while** — the Mac must stay on while the TV is streaming from it; the app prevents idle sleep, but closing the lid on battery will still sleep the Mac.
- **Local network permission** — if it was denied, enable it in *System Settings → Privacy & Security → Local Network*.

## License

[MIT](LICENSE)

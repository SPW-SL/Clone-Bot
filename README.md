<div align="center">

```text
  ____   ___ _____ ____    ____  __   __  ____  ______        __
 | __ ) / _ \_   _/ ___|  | __ ) \ \ / / / ___||  _ \ \      / /
 |  _ \| | | || | \___ \  |  _ \  \ V /  \___ \| |_) \ \ /\ / / 
 | |_) | |_| || |  ___) | | |_) |  | |    ___) |  __/ \ V  V /  
 |____/ \___/ |_| |____/  |____/   |_|   |____/|_|     \_/\_/   
```

# ⚡ Telegram Perfect-Order Channel, Album & Restricted Bot Cloner

[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)](https://github.com/SPW-SL)
[![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://github.com/SPW-SL)
[![Telethon](https://img.shields.io/badge/MTProto-Telethon%20%2B%20Cryptg-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)](https://github.com/SPW-SL)
[![FFmpeg](https://img.shields.io/badge/Media-FFmpeg-007808?style=for-the-badge&logo=ffmpeg&logoColor=white)](https://github.com/SPW-SL)
[![Maintained](https://img.shields.io/badge/Bots%20By-SPW--SL-00C853?style=for-the-badge)](https://github.com/SPW-SL)

**An high-speed, self-hosted Telegram cloner bot for Ubuntu VPS that creates an exact `1 → 2 → 3 → 4` sequential replica of any public/private channel, group, or save-restricted Telegram bot.**  
Built on a 3-stage Producer-Consumer pipeline: parallel workers pre-upload media and multi-item albums to Telegram's cloud buffer while a single-threaded sequential publisher posts them in strict chronological order with zero VPS disk bloat (`0.00 B` left behind).

[🚀 One-Line Install](#-one-line-vps-installation) • [✨ Key Features](#-key-features) • [🧠 Pipeline Architecture](#-3-stage-perfect-order-architecture) • [📖 Usage Guide](#-interactive-usage-guide) • [⌨️ Bot Commands](#️-bot-commands)

</div>

## ✨ Key Features

| Feature | Description |
| :--- | :--- |
| 🔢 **Guaranteed `1 → 2 → 3 → 4` Order** | Uses `iter_messages(reverse=True)` to stream source posts in ascending order (skipping deleted ID gaps like `4–8` automatically) and maps them into a clean `1, 2, 3, 4` sequence at the destination. |
| 🔓 **Restricted Bot & Channel Unlocker (`/bots`)** | Extracts save-restricted (`noforwards=True`) and view-once (`ttl_seconds`) media from other Telegram bots and private channels via your logged-in User Session cache. |
| 🖼️ **100% Album & Grid Preservation** | Detects consecutive messages sharing a `grouped_id` (up to 10 items), stages them concurrently, and publishes them as a single combined album with original captions and formatting intact. |
| ☁️ **Parallel Cloud Pre-Uploading (`1x`–`8x`)** | Multiple background workers download files, extract FFmpeg video duration/thumbnails, and pre-upload raw `InputFile` handles to Telegram's cloud buffer before their turn in the publish queue. |
| 📡 **Live Download & Upload Bandwidth Meter** | Real-time dashboard displays active Download (`⬇️ MB/s`), Upload (`⬆️ MB/s`), Peak speeds, and Total Data Transferred (`GB`) across all concurrent workers. |
| 📏 **Pre-Download File Size Filter (`150 MB`)** | Inspects Telegram file metadata before downloading and automatically skips files larger than `150 MB` (adjustable anytime via `/maxsize <MB>`). |
| 🧹 **Zero-Storage Auto-Cleanup** | Each message or album is processed inside `/opt/clonebot/cache/unit_<id>/` and deleted immediately inside a `finally:` block the moment it is published. |

## 🚀 One-Line VPS Installation

Run on any **Ubuntu 20.04 / 22.04 / 24.04** server as `root`:

```bash
curl -sSL https://raw.githubusercontent.com/SPW-SL/Clone-Bot/main/install.sh -o install.sh && sudo bash install.sh
```

<details>
<summary><b>🔽 Click to view Manual Git Clone Installation</b></summary>

```bash
git clone [https://github.com/SPW-SL/Clone-Bot.git](https://github.com/SPW-SL/Clone-Bot.git)
cd Clone-Bot
chmod +x install.sh
sudo ./install.sh
```

</details>

## 🧠 3-Stage Perfect-Order Architecture

```text
[Source Channel / Private Group / Restricted Bot Chat]
         │
         ├──► STAGE 1: Chronological Streamer & Filter
         │      • Streams existing messages in ascending order (1 → 2 → 3 → 9...)
         │      • Skips deleted gaps instantly & filters out files > 150 MB
         │      • Bundles consecutive grouped_id items into Album Units
         │
         ├──► STAGE 2: Parallel Producer Pool (1x to 8x Concurrent Workers)
         │      • Downloads media to /opt/clonebot/cache/unit_<id>/
         │      • Extracts FFmpeg video duration, dimensions & thumbnail
         │      • Pre-uploads InputFile handles to Telegram's cloud buffer
         │      • Places ready payload into numbered Slot[0], Slot[1], Slot[2]...
         │
         └──► STAGE 3: Single-Threaded Sequential Publisher (Consumer)
                • Waits strictly for Slot[0] ──► Publishes Post #1 ──► Wipes Cache
                • Waits strictly for Slot[1] ──► Publishes Post #2 ──► Wipes Cache
                • Guarantees 100% linear 1, 2, 3, 4 order at the destination
```

## 📖 Interactive Usage Guide

<details open>
<summary><b>1. Initial Setup (One-Time)</b></summary>

1. Open your bot on Telegram and send **`/start`**.
2. Connect your Telegram User Session (required for private channels and restricted bots) by sending **`/qr`** and scanning the QR code in **Telegram → Settings → Devices → Link Desktop Device**.
3. Make your bot an **Admin** in your destination channel or group, then set the destination:
   ```text
   /setdest [https://t.me/your_destination_channel](https://t.me/your_destination_channel)
   ```
   *(Or for a private destination channel/group: `/setdest -1001234567890`)*

</details>

<details open>
<summary><b>2. Cloning a Public or Private Channel/Group in Exact Order</b></summary>

1. Paste any post link from the source channel/group (e.g., `https://t.me/c/2152391268/1`), or paste two links to define a custom range:
   ```text
   [https://t.me/c/2152391268/1](https://t.me/c/2152391268/1) [https://t.me/c/2152391268/500](https://t.me/c/2152391268/500)
   ```
2. Select your desired parallel worker speed (`1x` to `8x`) and tap **`🔄 Full History (Oldest→End)`** or **`🔢 Custom ID Range`**.
3. Tap **`🔓 Unlock & Clone Media + Albums`** to start cloning.

</details>

<details open>
<summary><b>3. Unlocking Save-Restricted Media From Another Bot (`/bots`)</b></summary>

1. Send **`/bots`** (or tap **`🤖 Clone From a Bot Chat (Restricted Save)`** on the `/start` menu).
2. The bot scans your recent dialogs and displays clickable buttons for every bot you have interacted with (or simply paste `@target_bot_username` in chat).
3. Tap **`📥 Last 10 Msgs`**, **`📥 Last 25 Msgs`**, **`📥 Last 100 Msgs`**, or **`🔄 Full History`**.
4. Tap **`🔓 Unlock & Clone Media + Albums`**. Your User Session downloads the protected media into temporary cache and re-uploads it permanently to your destination channel.

</details>

## ⌨️ Bot Commands

| Command | Description |
| :--- | :--- |
| `/start` | Open the main dashboard, view active settings, or resume a saved job. |
| `/bots` | Scan your recent Telegram dialogs and pick a Bot chat to unlock & clone restricted media. |
| `/setdest <link/id>` | Set the destination channel or group where cloned content will be published. |
| `/clone <link> [start] [end]` | Open the setup menu for a channel, group, or `@bot_username` with an optional ID range. |
| `/maxsize <MB>` | Set the maximum file size limit in MB (default: `150` — skips larger files automatically). |
| `/workers <1-10>` | Set the default number of concurrent pre-upload workers (`3x` recommended). |
| `/delay <seconds>` | Set the delay between sequential publishes (default: `0.4s`). |
| `/qr` | Log in to your Telegram User Session via QR code (no SMS OTP required). |
| `/login` / `/logout` | Log in via phone number OTP or log out of the active User Session. |
| `/resume` | Resume an interrupted clone job from the exact last published message ID. |
| `/clearresume` | Delete the saved resume checkpoint. |
| `/cleancache` or `/clean` | Force-wipe `/opt/clonebot/cache` and verify `0.00 B` disk usage. |

## 🖥️ Terminal SSH Manager (`clone-bot`)

Type **`clone-bot`** anywhere in your Ubuntu VPS terminal to open the interactive service manager:

```text
======================================================================
                 CLONER BOT - SSH MANAGEMENT MENU
======================================================================
1) Check Service Status
2) View Live Logs (Ctrl+C to exit)
3) Restart Bot Service
4) Stop Bot Service
5) Force Clean Cache Folder (/opt/clonebot/cache)
6) Edit config.json Credentials
7) Uninstall Cloner Bot
0) Exit
======================================================================
```

<div align="center">
  <b>Developed & Maintained by <a href="https://github.com/SPW-SL">BOTS BY SPW (SPW-SL)</a></b>
</div>

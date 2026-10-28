<div align="center">

```text
  ____   ___ _____ ____    ____  __   __  ____  ______        __
 | __ ) / _ \_   _/ ___|  | __ ) \ \ / / / ___||  _ \ \      / /
 |  _ \| | | || | \___ \  |  _ \  \ V /  \___ \| |_) \ \ /\ / / 
 | |_) | |_| || |  ___) | | |_) |  | |    ___) |  __/ \ V  V /  
 |____/ \___/ |_| |____/  |____/   |_|   |____/|_|     \_/\_/   
```

# ⚡ Telegram Parallel Temp-Cache, Album & Range Cloner Bot

[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)](https://github.com/SPW-SL/Clone-Bot)
[![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://github.com/SPW-SL/Clone-Bot)
[![Telethon](https://img.shields.io/badge/MTProto-Telethon-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://github.com/SPW-SL/Clone-Bot)
[![Systemd](https://img.shields.io/badge/Service-systemd-222222?style=for-the-badge&logo=linux&logoColor=white)](https://github.com/SPW-SL/Clone-Bot)
[![Maintained](https://img.shields.io/badge/Bots%20By-SPW--SL-00C853?style=for-the-badge)](https://github.com/SPW-SL)

**A high-speed, zero-bloat Telegram Channel & Group Mass Cloner engineered for Ubuntu VPS.**  
Clone **5,000+ messages**, preserve **multi-file Albums (`grouped_id`)**, select **custom message ID ranges**, and bypass **"Restrict saving content"** locks using an automated **Parallel Temp-Cache Pipeline** that leaves **`0.00 B`** behind on your server.

[🚀 One-Line Install](#-one-line-vps-installation) • [✨ Key Features](#-key-features) • [📖 Interactive Usage Guide](#-interactive-usage-guide) • [⌨️ Bot Commands](#️-bot-commands) • [🖥️ SSH Manager](#️-terminal-ssh-manager-clone-bot)

</div>

---

## ✨ Key Features

| Feature | Description |
| :--- | :--- |
| 💾 **Zero-Bloat Temp-Cache Engine** | Bypasses `ChatForwardsRestrictedError` ("Restrict saving content") by caching media to `/opt/clonebot/cache`, extracting video metadata/thumbnails via `ffmpeg`, uploading to your destination, and **deleting the local cache file immediately**. |
| ⚡ **Multi-Worker Parallelism (`1x`–`10x`)** | Choose how many files download and upload simultaneously (`1x` to `8x` via inline buttons, or up to `10x` via `/workers`). Each worker operates in an isolated cache directory. |
| 🖼️ **Smart Album Preservation** | Automatically detects Telegram media groups (`grouped_id`) and peeks across batch boundaries so albums are never split in half—re-uploading them as combined albums. |
| 🔢 **Custom Message ID Ranges** | Clone an entire channel or pick an exact `Start ID → End ID` slice via the interactive **`🔢 Set Custom ID Range`** button, two post links, or `/clone`. |
| 📱 **Instant QR Code Login (`/qr`)** | Bypass datacenter/VPS SMS OTP blocks completely. Generate a live QR code inside Telegram chat and scan it via **Settings → Devices → Link Desktop Device**. |
| 🔄 **Crash-Safe Auto-Resume** | Continuously tracks all in-flight parallel workers and saves the lowest unfinished message ID to `resume.json` so you can pause, cancel, or `/resume` without skipping a single file. |
| 🧹 **Instant Cache Wiper (`/cleancache`)** | Automatic `finally:` block cleanup after every file, plus a manual `/cleancache` command and button showing live cache disk usage. |

---

## 🚀 One-Line VPS Installation

Run the following command as `root` on any **Ubuntu 20.04 / 22.04 / 24.04** VPS:

```bash
curl -sSL [https://raw.githubusercontent.com/SPW-SL/Clone-Bot/main/install.sh](https://raw.githubusercontent.com/SPW-SL/Clone-Bot/main/install.sh) -o install.sh && sudo bash install.sh
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

<details>
<summary><b>🔑 What credentials do I need during setup?</b></summary>

During installation, the script will interactively prompt you for:
1. **`API_ID` & `API_HASH`**: Get these from [my.telegram.org](https://my.telegram.org) under **API development tools**.
2. **`BOT_TOKEN`**: Create a new bot via [@BotFather](https://t.me/BotFather) and copy the HTTP API token.
3. **`ADMIN_IDS`**: Your numeric Telegram User ID(s) separated by spaces (get yours from [@userinfobot](https://t.me/userinfobot)).

> 🔒 *Your credentials are saved locally in `/opt/clonebot/config.json` with `chmod 600` root-only permissions.*

</details>

---

## 🧠 How the Parallel Temp-Cache Pipeline Works

<details open>
<summary><b>🔍 Click to expand/collapse architecture workflow</b></summary>

```text
[Source Group / Restricted Channel]
         │
         ├──► Scanner fetches batch & groups Albums (grouped_id) + Boundary Peek
         │
         ▼
   [Asyncio Semaphore Pool (1x - 10x Parallel Workers)]
         │
         ├──► Worker 1: Caches to /opt/clonebot/cache/unit_101/ ──► FFmpeg Meta/Thumb ──► Uploads to Destination ──► Wipes unit_101/ (0.00 B)
         ├──► Worker 2: Caches to /opt/clonebot/cache/unit_102/ ──► FFmpeg Meta/Thumb ──► Uploads Combined Album ──► Wipes unit_102/ (0.00 B)
         └──► Worker N: Caches to /opt/clonebot/cache/unit_103/ ──► FFmpeg Meta/Thumb ──► Uploads to Destination ──► Wipes unit_103/ (0.00 B)
```

### Transfer Modes Comparison

| Mode | Speed | Bypasses "Restrict Saving Content"? | Preserves Albums? | VPS Disk Used |
| :--- | :--- | :---: | :---: | :---: |
| **💾 Cache & Upload Media + Albums** | Fast (`1x`–`10x` Parallel) | ✅ **Yes (100%)** | ✅ **Yes** | `0.00 B` Permanent (Auto-wiped per file) |
| **💾 Cache & Upload All (Media + Text)** | Fast (`1x`–`10x` Parallel) | ✅ **Yes (100%)** | ✅ **Yes** | `0.00 B` Permanent (Auto-wiped per file) |
| **📨 Direct Forward / 📋 Direct Copy** | Instant (Server-Side) | ⚠️ Auto-falls back to Cache mode if restricted | ✅ **Yes** | `0.00 B` |

</details>

---

## 📖 Interactive Usage Guide

<details open>
<summary><b>1️⃣ Step 1: Connect a Telegram User Session (QR Code or Phone)</b></summary>

To clone private groups, restricted channels, or external public channels, link a Telegram account that is a member of the source chat:
1. Open your bot on Telegram and send **`/qr`** *(Recommended — no SMS/OTP needed)*.
2. On your phone, open **Telegram → Settings → Devices → Link Desktop Device** and scan the QR image sent by the bot.
3. Alternatively, use **`/login`** to sign in using your international phone number (`+1234567890`) and in-app OTP code.

</details>

<details>
<summary><b>2️⃣ Step 2: Set Your Destination Channel or Group</b></summary>

1. Add your Cloner Bot as an **Administrator** (with *Post Messages* permission) in your destination Channel or Group.
2. Set the destination using any of these formats:
   ```text
   /setdest [https://t.me/your_destination_channel](https://t.me/your_destination_channel)
   ```
   ```text
   /setdest -1001234567890
   ```
   *(Or simply type `/setdest` directly inside your destination group).*

</details>

<details>
<summary><b>3️⃣ Step 3: Select Your Message Range & Parallel Speed</b></summary>

You can trigger a clone job and select custom ranges in **three ways**:

* **Method A — Interactive Setup Menu:**  
  Paste any channel/group link (or the link to the last message, e.g., `https://t.me/c/123456789/5000`).  
  Tap **`🔢 Set Custom ID Range (Start - End)`** and reply with `100 - 500` (or `250` to start at ID 250 and clone to the end).
* **Method B — Paste Two Message Links at Once:**  
  Copy the link of the **first post** and the **last post** you want to clone, and send both in a single message:
  ```text
  [https://t.me/c/123456789/100](https://t.me/c/123456789/100) [https://t.me/c/123456789/500](https://t.me/c/123456789/500)
  ```
* **Method C — Direct Command:**  
  ```text
  /clone [https://t.me/c/123456789/5000](https://t.me/c/123456789/5000) 100 500
  ```

Next, tap your desired **Parallel Worker Count (`1x`–`8x`)** and select **`💾 Cache & Upload Media + Albums`**!

</details>

---

## ⌨️ Bot Commands

| Command | Description |
| :--- | :--- |
| `/start` | Open the main dashboard, view live cache size, user session status, and quick-action buttons. |
| `/help` | Display the in-bot step-by-step usage and troubleshooting guide. |
| `/qr` | Generate a scannable Telegram QR code to log in any user account without needing an SMS/app OTP. |
| `/login` | Log in a user session using an international phone number and OTP code. |
| `/logout` | Log out the active user session and wipe `user_session.session` clean. |
| `/setdest <link/id>` | Set the target destination Channel or Group (e.g., `/setdest https://t.me/my_channel`). |
| `/clone <link> [start] [end]` | Start a clone setup with an optional custom message ID range. |
| `/workers <1-10>` | Set the default number of parallel download/upload workers (`2` to `4` recommended). |
| `/delay <seconds>` | Set the anti-flood delay between worker batches (default: `1.5` seconds). |
| `/resume` | Resume an interrupted or cancelled clone job from the exact last saved message ID. |
| `/clearresume` | Delete the saved `resume.json` checkpoint. |
| `/cleancache` or `/clean` | Force-delete all temporary files inside `/opt/clonebot/cache` and show freed space. |

---

## 🖥️ Terminal SSH Manager (`clone-bot`)

After installation, type **`clone-bot`** from anywhere in your VPS SSH terminal to open the interactive management menu:

```text
======================================================================
  ____   ___ _____ ____    ____  __   __  ____  ______        __
 | __ ) / _ \_   _/ ___|  | __ ) \ \ / / / ___||  _ \ \      / /
 |  _ \| | | || | \___ \  |  _ \  \ V /  \___ \| |_) \ \ /\ / / 
 | |_) | |_| || |  ___) | | |_) |  | |    ___) |  __/ \ V  V /  
 |____/ \___/ |_| |____/  |____/   |_|   |____/|_|     \_/\_/   
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

---

## 💡 Recommended Best Practices

* **Optimal Parallel Workers (`2x`–`4x`):** While the bot supports up to `10x` concurrent workers, `2x` to `4x` provides fast throughput while minimizing Telegram `FloodWaitError` pauses.
* **Separate Bot Tokens:** If you run multiple bots on the same VPS (such as a Leech Bot and Cloner Bot), generate a separate `@BotFather` token for each bot so their sessions never conflict.
* **Disclaimer:** Use this tool responsibly for personal backups and channels/groups where you have permission. Excessive automated scraping may trigger Telegram rate limits on the connected user account.

---

<div align="center">
  <b>Developed & Maintained by <a href="https://github.com/SPW-SL">BOTS BY SPW (SPW-SL)</a></b>
</div>

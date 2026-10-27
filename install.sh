#!/bin/bash
set -e

INSTALL_DIR="/opt/clonebot"
CACHE_DIR="$INSTALL_DIR/cache"
CONFIG_FILE="$INSTALL_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/clonebot.service"
CLI_BIN="/usr/local/bin/clone-bot"

clear
echo "=========================================================="
echo "          🤖 BOTS BY SPW - PARALLEL CLONER BOT            "
echo "=========================================================="
echo "          Mass Channel & Group Temp-Cache Cloner          "
echo "=========================================================="

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this installer as root (sudo bash install.sh)."
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$CACHE_DIR"

# 1. Interactive Configuration
USE_EXISTING="n"
if [ -f "$CONFIG_FILE" ]; then
    read -rp "⚙️ Existing config.json found. Keep current credentials? [Y/n]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
fi

if [[ ! "$USE_EXISTING" =~ ^[Yy]$ ]]; then
    echo ""
    echo "🔑 Please enter your Telegram API credentials (from my.telegram.org) & Bot Token (@BotFather):"
    read -rp "👉 Enter APP API_ID (e.g. 11872337): " INPUT_API_ID
    read -rp "👉 Enter API_HASH: " INPUT_API_HASH
    read -rp "👉 Enter BOT_TOKEN: " INPUT_BOT_TOKEN
    read -rp "👉 Enter ADMIN_IDS (space-separated, e.g. 1551433194 5190391120): " INPUT_ADMINS

    ADMIN_JSON=$(echo "$INPUT_ADMINS" | tr ',' ' ' | awk '{
        printf "[";
        for(i=1;i<=NF;i++) {
            printf "%s%s", $i, (i<NF ? ", " : "");
        }
        printf "]";
    }')

    cat << CONFIG_EOF > "$CONFIG_FILE"
{
    "api_id": $INPUT_API_ID,
    "api_hash": "$INPUT_API_HASH",
    "bot_token": "$INPUT_BOT_TOKEN",
    "admin_ids": $ADMIN_JSON,
    "dest_chat": null,
    "delay_seconds": 1.5,
    "parallel_workers": 2
}
CONFIG_EOF
    chmod 600 "$CONFIG_FILE"
    echo "✅ Configuration saved to $CONFIG_FILE"
fi

echo "=========================================================="
echo " 📦 Installing System Dependencies (ffmpeg, python)..."
echo "=========================================================="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip ffmpeg git curl build-essential

echo "=========================================================="
echo " 🐍 Setting Up Python Virtual Environment & Packages..."
echo "=========================================================="
cd "$INSTALL_DIR"
if [ ! -f "$INSTALL_DIR/venv/bin/python3" ]; then
    python3 -m venv venv
fi
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --upgrade telethon cryptg qrcode pillow

echo "=========================================================="
echo " 🤖 Writing Cloner Application Application Code..."
echo "=========================================================="
cat << 'PY_EOF' > "$INSTALL_DIR/cloner.py"
import os
import io
import re
import json
import time
import shutil
import asyncio
import logging
import subprocess
from pathlib import Path

import qrcode
from telethon import TelegramClient, events, Button
from telethon.errors import (
    FloodWaitError,
    SessionPasswordNeededError,
    ChatForwardsRestrictedError,
)
from telethon.tl.types import (
    MessageService,
    DocumentAttributeVideo,
    MessageMediaPhoto,
    MessageMediaDocument,
)

BASE_DIR = Path("/opt/clonebot")
CACHE_DIR = BASE_DIR / "cache"
CONFIG_FILE = BASE_DIR / "config.json"
RESUME_FILE = BASE_DIR / "resume.json"
USER_SESSION_PATH = str(BASE_DIR / "user_session")
BOT_SESSION_PATH = str(BASE_DIR / "bot_session")

shutil.rmtree(CACHE_DIR, ignore_errors=True)
CACHE_DIR.mkdir(parents=True, exist_ok=True)

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".webm"}
MAX_WORKERS_LIMIT = 10

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

def load_config():
    with open(CONFIG_FILE, "r") as f:
        data = json.load(f)
    data.setdefault("dest_chat", None)
    data.setdefault("delay_seconds", 1.5)
    data.setdefault("parallel_workers", 2)
    return data

def save_config(data):
    with open(CONFIG_FILE, "w") as f:
        json.dump(data, f, indent=4)

def load_resume():
    if RESUME_FILE.exists():
        try:
            with open(RESUME_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return None

def save_resume(state):
    with open(RESUME_FILE, "w") as f:
        json.dump(state, f, indent=4)

CFG = load_config()
API_ID = int(CFG["api_id"])
API_HASH = CFG["api_hash"]
BOT_TOKEN = CFG["bot_token"]
ADMINS = set(CFG["admin_ids"])

loop = asyncio.new_event_loop()
asyncio.set_event_loop(loop)

def create_user_client():
    return TelegramClient(
        USER_SESSION_PATH,
        API_ID,
        API_HASH,
        loop=loop,
        device_model="Telegram Desktop",
        system_version="Windows 11 x64",
        app_version="5.6.3 x64",
        lang_code="en",
        system_lang_code="en-US"
    )

bot = TelegramClient(BOT_SESSION_PATH, API_ID, API_HASH, loop=loop)
user_client = create_user_client()

ACTIVE_CLONE = {
    "running": False,
    "paused": False,
    "cancelled": False,
    "task": None
}
PENDING_SETUP = {}
LOGIN_STATE = {}
WORKER_STATUS = {}

def is_admin(uid: int) -> bool:
    return uid in ADMINS

def fmt_size(b: float) -> str:
    if b <= 0:
        return "0.00 B"
    for u in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024.0:
            return f"{b:.2f} {u}"
        b /= 1024.0
    return f"{b:.2f} PB"

def get_dir_size(path_obj: Path) -> int:
    total = 0
    if not path_obj.exists():
        return 0
    for root, _, files in os.walk(path_obj):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total

def wipe_cache_folder() -> tuple[int, int]:
    freed_bytes = get_dir_size(CACHE_DIR)
    file_count = 0
    if CACHE_DIR.exists():
        for root, _, files in os.walk(CACHE_DIR):
            file_count += len(files)
        shutil.rmtree(CACHE_DIR, ignore_errors=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return freed_bytes, file_count

def progress_bar(curr: float, tot: float, length: int = 10) -> str:
    if tot <= 0:
        return "░" * length
    filled = max(0, min(length, int(round((curr / tot) * length))))
    return "█" * filled + "░" * (length - filled)

def fmt_time(seconds: float) -> str:
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h > 0:
        return f"{h}h {m}m {s}s"
    if m > 0:
        return f"{m}m {s}s"
    return f"{s}s"

def make_qr_png(url: str) -> io.BytesIO:
    qr = qrcode.QRCode(version=1, box_size=10, border=4)
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    bio = io.BytesIO()
    bio.name = "qr_login.png"
    img.save(bio, "PNG")
    bio.seek(0)
    return bio

async def reset_user_session():
    global user_client
    try:
        if user_client.is_connected():
            await user_client.disconnect()
    except Exception:
        pass
    for ext in ("", ".session", ".session-journal"):
        p = Path(f"{USER_SESSION_PATH}{ext}")
        if p.exists():
            p.unlink(missing_ok=True)
    user_client = create_user_client()
    await user_client.connect()

def parse_tg_target(raw: str):
    text = raw.strip()
    if re.match(r"^-?\d+$", text):
        return int(text), None

    m_priv = re.search(r"t\.me/c/(\d+)(?:/(\d+))?", text)
    if m_priv:
        chat_id = int(f"-100{m_priv.group(1)}")
        max_id = int(m_priv.group(2)) if m_priv.group(2) else None
        return chat_id, max_id

    m_pub = re.search(r"t\.me/([a-zA-Z0-9_]+)(?:/(\d+))?", text)
    if m_pub and m_pub.group(1).lower() not in ("c", "joinchat"):
        uname = m_pub.group(1)
        max_id = int(m_pub.group(2)) if m_pub.group(2) else None
        return uname, max_id

    return text, None

async def is_user_logged_in() -> bool:
    try:
        if not user_client.is_connected():
            await user_client.connect()
        return await user_client.is_user_authorized()
    except Exception:
        return False

def control_buttons():
    pause_label = "▶️ Resume" if ACTIVE_CLONE["paused"] else "⏸️ Pause"
    return [
        [
            Button.inline(pause_label, b"ctrl:toggle_pause"),
            Button.inline("❌ Cancel & Clean Cache", b"ctrl:cancel")
        ]
    ]

def build_setup_buttons(key: str, selected_workers: int):
    worker_opts = [1, 2, 3, 4, 5, 8]
    w_row = []
    for w in worker_opts:
        label = f"✅ {w}x" if w == selected_workers else f"⚡ {w}x"
        w_row.append(Button.inline(label, f"setw:{key}:{w}".encode()))

    return [
        w_row[:3],
        w_row[3:],
        [Button.inline(f"💾 Cache & Upload Media Only ({selected_workers}x Parallel)", f"go:{key}:media:cache".encode())],
        [Button.inline(f"💾 Cache & Upload All Media+Text ({selected_workers}x Parallel)", f"go:{key}:all:cache".encode())],
        [
            Button.inline("📨 Direct Forward (Keep Tag)", f"go:{key}:media:fwd".encode()),
            Button.inline("📋 Direct Copy (No Tag)", f"go:{key}:media:copy".encode())
        ],
        [Button.inline("❌ Cancel", b"ctrl:close")]
    ]

def build_setup_text(setup: dict) -> str:
    end_id = setup.get("end_id", 0)
    range_txt = f"`{setup.get('start_id', 1)}` → `{end_id}`" if end_id > 0 else "`All History (Auto-Detect)`"
    w = setup.get("workers", 2)
    return (
        f"🎯 **Source Group/Channel Ready!**\n\n"
        f"📤 **Source:** `{setup['source']}`\n"
        f"📥 **Destination:** `{setup['dest']}`\n"
        f"🔢 **Message Range:** {range_txt}\n"
        f"⚡ **Parallel Files (Download/Upload):** `{w}x Concurrent`\n\n"
        "👇 **First choose your Parallel Speed (`1x`–`8x`), then tap a Transfer Mode:**"
    )

def get_video_meta(path: str):
    try:
        cmd = [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height:format=duration", "-of", "json", path
        ]
        data = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout)
        s = data.get("streams", [{}])[0]
        dur = int(float(data.get("format", {}).get("duration", 0)))
        return dur, int(s.get("width", 1280)), int(s.get("height", 720))
    except Exception:
        return 0, 1280, 720

def make_thumb(vpath: str, tpath: str):
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-ss", "00:00:02", "-i", vpath, "-vframes", "1", "-q:v", "4", tpath],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True
        )
        return tpath if (os.path.exists(tpath) and os.path.getsize(tpath) > 0) else None
    except Exception:
        return None

async def cache_and_upload_message(dl_client, up_client, dest_entity, msg) -> bool:
    job_cache_dir = CACHE_DIR / f"msg_{msg.id}"
    job_cache_dir.mkdir(parents=True, exist_ok=True)
    cached_file = None
    thumb_file = None

    try:
        while ACTIVE_CLONE["paused"] and not ACTIVE_CLONE["cancelled"]:
            await asyncio.sleep(1)
        if ACTIVE_CLONE["cancelled"]:
            return False

        if msg.media:
            if not isinstance(msg.media, (MessageMediaPhoto, MessageMediaDocument)):
                if msg.text:
                    await up_client.send_message(dest_entity, msg.text, formatting_entities=msg.entities)
                    return True
                return False

            t0 = time.time()
            WORKER_STATUS[msg.id] = {"stage": "📥 Caching", "curr": 0, "tot": 0, "speed": 0.0}

            def dl_prog(curr, tot):
                if ACTIVE_CLONE["cancelled"]:
                    raise asyncio.CancelledError()
                now = time.time()
                spd = curr / max(0.1, now - t0)
                WORKER_STATUS[msg.id] = {"stage": "📥 Caching", "curr": curr, "tot": tot, "speed": spd}

            while True:
                try:
                    cached_file = await dl_client.download_media(
                        msg,
                        file=str(job_cache_dir) + "/",
                        progress_callback=dl_prog
                    )
                    break
                except FloodWaitError as fw:
                    WORKER_STATUS[msg.id] = {"stage": f"⏳ FloodWait ({fw.seconds}s)", "curr": 0, "tot": 0, "speed": 0.0}
                    await asyncio.sleep(fw.seconds + 2)

            if not cached_file or not os.path.exists(cached_file):
                return False

            ext = os.path.splitext(cached_file)[1].lower()
            attrs = []
            is_video = ext in VIDEO_EXTS
            if is_video:
                d, w, h = await asyncio.to_thread(get_video_meta, cached_file)
                attrs.append(DocumentAttributeVideo(duration=d, w=w, h=h, supports_streaming=True))
                thumb_file = await asyncio.to_thread(
                    make_thumb, cached_file, str(job_cache_dir / "thumb.jpg")
                )

            while ACTIVE_CLONE["paused"] and not ACTIVE_CLONE["cancelled"]:
                await asyncio.sleep(1)
            if ACTIVE_CLONE["cancelled"]:
                return False

            up_t0 = time.time()
            fsize = os.path.getsize(cached_file)
            WORKER_STATUS[msg.id] = {"stage": "📤 Uploading", "curr": 0, "tot": fsize, "speed": 0.0}

            def up_prog(curr, tot):
                if ACTIVE_CLONE["cancelled"]:
                    raise asyncio.CancelledError()
                now = time.time()
                spd = curr / max(0.1, now - up_t0)
                WORKER_STATUS[msg.id] = {"stage": "📤 Uploading", "curr": curr, "tot": tot, "speed": spd}

            while True:
                try:
                    await up_client.send_file(
                        dest_entity,
                        file=cached_file,
                        caption=msg.text or "",
                        formatting_entities=msg.entities,
                        thumb=thumb_file,
                        attributes=attrs if attrs else None,
                        supports_streaming=is_video,
                        progress_callback=up_prog
                    )
                    break
                except FloodWaitError as fw:
                    WORKER_STATUS[msg.id] = {"stage": f"⏳ FloodWait ({fw.seconds}s)", "curr": 0, "tot": fsize, "speed": 0.0}
                    await asyncio.sleep(fw.seconds + 2)

            return True

        elif msg.text:
            while True:
                try:
                    await up_client.send_message(
                        dest_entity,
                        msg.text,
                        formatting_entities=msg.entities
                    )
                    break
                except FloodWaitError as fw:
                    await asyncio.sleep(fw.seconds + 2)
            return True

        return False
    finally:
        WORKER_STATUS.pop(msg.id, None)
        shutil.rmtree(job_cache_dir, ignore_errors=True)

async def run_clone_job(chat_id: int, status_msg, job_cfg: dict):
    ACTIVE_CLONE["running"] = True
    ACTIVE_CLONE["paused"] = False
    ACTIVE_CLONE["cancelled"] = False
    WORKER_STATUS.clear()

    src_target = job_cfg["source"]
    dest_target = job_cfg["dest"]
    start_id = int(job_cfg.get("start_id", 1))
    end_id = int(job_cfg.get("end_id") or 0)
    media_only = bool(job_cfg.get("media_only", True))
    mode = job_cfg.get("mode", "cache")
    drop_author = bool(job_cfg.get("drop_author", False))
    workers = max(1, min(MAX_WORKERS_LIMIT, int(job_cfg.get("workers", load_config().get("parallel_workers", 2)))))
    delay_sec = float(load_config().get("delay_seconds", 1.5))

    use_user = await is_user_logged_in()
    dl_client = user_client if use_user else bot

    forwarded_total = int(job_cfg.get("forwarded_total", 0))
    skipped_total = int(job_cfg.get("skipped_total", 0))
    t_start = time.time()
    current_scan_id = start_id
    in_flight_ids = set()
    ui_running = True

    async def ui_updater_loop(total_range: int):
        while ui_running and not ACTIVE_CLONE["cancelled"]:
            await asyncio.sleep(3.5)
            if not ui_running:
                break
            done_ids = max(0, current_scan_id - start_id)
            pct = min(100.0, (done_ids / max(1, total_range)) * 100)
            elapsed = time.time() - t_start
            rate = done_ids / max(0.1, elapsed)
            eta = max(0, end_id - current_scan_id) / max(0.01, rate)

            worker_lines = []
            for mid, st in sorted(WORKER_STATUS.items()):
                c_bytes = st.get("curr", 0)
                t_bytes = st.get("tot", 0)
                w_pct = (c_bytes / t_bytes * 100) if t_bytes else 0
                spd = st.get("speed", 0.0)
                worker_lines.append(
                    f"• `ID {mid}` {st['stage']}: `[{progress_bar(c_bytes, t_bytes, 8)}] {w_pct:.0f}%` (`{fmt_size(spd)}/s`)"
                )

            active_block = "\n".join(worker_lines) if worker_lines else "• *Waiting for next batch...*"
            state_banner = "⏸️ **PAUSED**" if ACTIVE_CLONE["paused"] else f"🔄 **Cloning in Progress ({workers}x Parallel)...**"

            text = (
                f"{state_banner}\n"
                f"`[{progress_bar(done_ids, total_range, 12)}] {pct:.1f}%`\n\n"
                f"✅ **Uploaded:** `{forwarded_total}` | ⏭️ **Skipped:** `{skipped_total}`\n"
                f"🔢 **Progress ID:** `{current_scan_id} / {end_id}`\n"
                f"🧹 **Active Temp Cache:** `{fmt_size(get_dir_size(CACHE_DIR))}`\n"
                f"⏱️ **Elapsed:** `{fmt_time(elapsed)}` • **ETA:** `{fmt_time(eta)}`\n\n"
                f"⚡ **Active Parallel Workers ({len(WORKER_STATUS)}/{workers}):**\n"
                f"{active_block}"
            )
            try:
                await status_msg.edit(text, buttons=control_buttons())
            except Exception:
                pass

    ui_task = None
    try:
        src_entity = await dl_client.get_entity(src_target)

        try:
            dest_entity = await bot.get_entity(dest_target)
            up_client = bot
        except Exception:
            dest_entity = await dl_client.get_entity(dest_target)
            up_client = dl_client

        if end_id <= 0:
            if use_user:
                latest = await dl_client.get_messages(src_entity, limit=1)
                end_id = latest[0].id if latest else 5000
            else:
                end_id = 6000

        total_range = max(1, end_id - start_id + 1)
        ui_task = asyncio.create_task(ui_updater_loop(total_range))

        sem = asyncio.Semaphore(workers)
        fetch_chunk_size = max(30, workers * 10)

        async def process_one_message(m):
            nonlocal forwarded_total, skipped_total
            async with sem:
                if ACTIVE_CLONE["cancelled"]:
                    in_flight_ids.discard(m.id)
                    return
                while ACTIVE_CLONE["paused"] and not ACTIVE_CLONE["cancelled"]:
                    await asyncio.sleep(1)
                if ACTIVE_CLONE["cancelled"]:
                    in_flight_ids.discard(m.id)
                    return

                try:
                    if mode == "cache":
                        ok = await cache_and_upload_message(dl_client, up_client, dest_entity, m)
                        if ok:
                            forwarded_total += 1
                        else:
                            skipped_total += 1
                    else:
                        try:
                            await dl_client.forward_messages(
                                entity=dest_entity,
                                messages=m.id,
                                from_peer=src_entity,
                                drop_author=drop_author
                            )
                            forwarded_total += 1
                        except ChatForwardsRestrictedError:
                            ok = await cache_and_upload_message(dl_client, up_client, dest_entity, m)
                            if ok:
                                forwarded_total += 1
                            else:
                                skipped_total += 1
                        except FloodWaitError as fw:
                            await asyncio.sleep(fw.seconds + 2)
                except asyncio.CancelledError:
                    pass
                except Exception as e:
                    logging.warning(f"Message {m.id} failed: {e}")
                    skipped_total += 1
                finally:
                    in_flight_ids.discard(m.id)
                    safe_next_id = min(in_flight_ids) if in_flight_ids else (m.id + 1)
                    job_cfg["start_id"] = safe_next_id
                    job_cfg["end_id"] = end_id
                    job_cfg["forwarded_total"] = forwarded_total
                    job_cfg["skipped_total"] = skipped_total
                    job_cfg["workers"] = workers
                    save_resume(job_cfg)
                    await asyncio.sleep(delay_sec)

        for batch_start in range(start_id, end_id + 1, fetch_chunk_size):
            if ACTIVE_CLONE["cancelled"]:
                break
            while ACTIVE_CLONE["paused"] and not ACTIVE_CLONE["cancelled"]:
                await asyncio.sleep(1)

            batch_end = min(end_id, batch_start + fetch_chunk_size - 1)
            id_list = list(range(batch_start, batch_end + 1))

            while True:
                try:
                    msgs = await dl_client.get_messages(src_entity, ids=id_list)
                    break
                except FloodWaitError as fw:
                    await asyncio.sleep(fw.seconds + 2)

            valid_msgs = []
            for m in (msgs or []):
                if m is None or isinstance(m, MessageService):
                    skipped_total += 1
                    continue
                if media_only and not m.media:
                    skipped_total += 1
                    continue
                if not m.media and not m.text:
                    skipped_total += 1
                    continue
                valid_msgs.append(m)
                in_flight_ids.add(m.id)

            if valid_msgs:
                tasks = [asyncio.create_task(process_one_message(m)) for m in valid_msgs]
                await asyncio.gather(*tasks, return_exceptions=True)

            current_scan_id = batch_end + 1
            if not in_flight_ids:
                job_cfg["start_id"] = current_scan_id
                job_cfg["end_id"] = end_id
                job_cfg["forwarded_total"] = forwarded_total
                job_cfg["skipped_total"] = skipped_total
                job_cfg["workers"] = workers
                save_resume(job_cfg)

        ui_running = False
        if ui_task:
            ui_task.cancel()

        wipe_cache_folder()

        if ACTIVE_CLONE["cancelled"]:
            await status_msg.edit(
                f"🛑 **Stopped at Message ID `{job_cfg['start_id']}` & Cache Wiped (`0.00 B`).**\n"
                f"✅ **Total Uploaded:** `{forwarded_total}`\n"
                "💡 *Send `/resume` anytime to continue from this exact message!*",
                buttons=None
            )
        else:
            if RESUME_FILE.exists():
                RESUME_FILE.unlink(missing_ok=True)
            await status_msg.edit(
                f"🎉 **Cloning 100% Complete ({workers}x Parallel)!**\n\n"
                f"✅ **Total Uploaded:** `{forwarded_total}`\n"
                f"⏭️ **Skipped:** `{skipped_total}`\n"
                f"🧹 **VPS Cache Folder:** `0.00 B (Clean)`\n"
                f"⏱️ **Total Time:** `{fmt_time(time.time() - t_start)}`",
                buttons=None
            )
    except Exception as e:
        ui_running = False
        if ui_task:
            ui_task.cancel()
        wipe_cache_folder()
        await status_msg.edit(f"❌ **Cloning Error:** `{e}`\n🧹 *Leftover cache automatically cleaned.*", buttons=None)
    finally:
        ui_running = False
        if ui_task:
            ui_task.cancel()
        WORKER_STATUS.clear()
        wipe_cache_folder()
        ACTIVE_CLONE["running"] = False
        ACTIVE_CLONE["paused"] = False
        ACTIVE_CLONE["cancelled"] = False
        ACTIVE_CLONE["task"] = None

# ================= COMMAND HANDLERS & BOT INSTRUCTIONS =================

HELP_INSTRUCTIONS = (
    "📖 **BOTS BY SPW — Cloner Bot Instructions**\n\n"
    "**1. How to Log In (User Account):**\n"
    "• Send **`/qr`** to generate a scannable QR code. Open Telegram on your phone → **Settings → Devices → Link Desktop Device** and scan it (No OTP required!).\n"
    "• Or send **`/login`** to sign in via phone number and OTP.\n\n"
    "**2. How to Set Your Destination:**\n"
    "• Add this bot as an **Admin** in your target Channel or Group.\n"
    "• Send: `/setdest https://t.me/your_channel` (or run `/setdest` inside the destination channel/group).\n\n"
    "**3. How to Clone Channels & Groups (Even Restricted Content):**\n"
    "• Paste **any public or private source link** (or last message link `https://t.me/c/12345/5000`) into this chat.\n"
    "• Pick your **Parallel Speed (`1x` to `8x`)**.\n"
    "• Choose **💾 Cache & Upload** (automatically downloads each file, streams it into your channel, and deletes VPS cache instantly) or **📨 Direct Forward**.\n\n"
    "**4. Useful Commands:**\n"
    "• `/cleancache` (or `/clean`) — Force-wipes `/opt/clonebot/cache`\n"
    "• `/clearresume` — Clears saved resume checkpoints\n"
    "• `/workers <1-10>` — Sets default parallel speed\n"
    "• `/logout` — Logs out the user session"
)

@bot.on(events.NewMessage(pattern=r"^/start"))
async def start_h(event):
    if not is_admin(event.sender_id):
        return
    cfg = load_config()
    dest = cfg.get("dest_chat") or "Not Set ❌ (Use /setdest)"
    workers = cfg.get("parallel_workers", 2)
    cache_bytes = get_dir_size(CACHE_DIR)
    logged = await is_user_logged_in()
    if logged:
        me = await user_client.get_me()
        u_stat = f"Connected ✅ ({me.first_name} | {me.id})"
    else:
        u_stat = "Not Logged In ⚠️ (Use /qr)"
    res = load_resume()

    btns = [
        [
            Button.inline("⚡ 1x", b"defw:1"),
            Button.inline("⚡ 2x", b"defw:2"),
            Button.inline("⚡ 3x", b"defw:3"),
            Button.inline("⚡ 5x", b"defw:5"),
            Button.inline("⚡ 8x", b"defw:8")
        ],
        [Button.inline("📖 Instructions", b"menu:help"), Button.inline("🧹 Clean Cache", b"menu:cleancache")],
        [Button.inline("📱 QR Login (No OTP)", b"menu:qr"), Button.inline("🗑️ Logout User", b"menu:logout")]
    ]
    if res:
        btns.insert(0, [Button.inline(f"▶️ Resume Saved Job (ID {res.get('start_id')})", b"menu:resume")])

    await event.reply(
        "🤖 **BOTS BY SPW — Parallel Cloner Bot**\n\n"
        f"📥 **Destination:** `{dest}`\n"
        f"👤 **User Session:** `{u_stat}`\n"
        f"⚡ **Parallel Speed:** `{workers}x Concurrent`\n"
        f"🧹 **Cache Size:** `{fmt_size(cache_bytes)}`\n\n"
        "👇 *Paste any channel/group link below to start cloning!*",
        buttons=btns
    )

@bot.on(events.NewMessage(pattern=r"^/help"))
async def help_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    await event.reply(HELP_INSTRUCTIONS)

@bot.on(events.NewMessage(pattern=r"^/(?:cleancache|clean)"))
async def cleancache_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    if ACTIVE_CLONE["running"]:
        ACTIVE_CLONE["cancelled"] = True
        ACTIVE_CLONE["paused"] = False
        await asyncio.sleep(1.5)
    freed_bytes, files_removed = wipe_cache_folder()
    await event.reply(
        f"🧹 **Cache Folder Cleaned!**\n\n"
        f"🗑️ **Files Removed:** `{files_removed}`\n"
        f"💾 **Disk Space Freed:** `{fmt_size(freed_bytes)}`\n"
        f"📂 **Current Cache Size:** `0.00 B`"
    )

@bot.on(events.NewMessage(pattern=r"^/clearresume"))
async def clearresume_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    if RESUME_FILE.exists():
        RESUME_FILE.unlink(missing_ok=True)
        await event.reply("🗑️ **Saved resume checkpoint deleted.**")
    else:
        await event.reply("ℹ️ **No saved resume checkpoint found.**")

@bot.on(events.NewMessage(pattern=r"^/workers\s+(\d+)"))
async def workers_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    val = max(1, min(MAX_WORKERS_LIMIT, int(event.pattern_match.group(1))))
    cfg = load_config()
    cfg["parallel_workers"] = val
    save_config(cfg)
    await event.reply(f"⚡ **Default parallel workers set to:** `{val}x`")

@bot.on(events.NewMessage(pattern=r"^/setdest(?:\s+(.+))?"))
async def setdest_h(event):
    if not is_admin(event.sender_id):
        return
    arg = event.pattern_match.group(1)
    if not arg:
        if event.chat_id != event.sender_id:
            target = event.chat_id
        else:
            return await event.reply("⚠️ Send `/setdest https://t.me/your_channel` or `/setdest -100123456789`")
    else:
        target, _ = parse_tg_target(arg)

    cfg = load_config()
    cfg["dest_chat"] = target
    save_config(cfg)
    await event.reply(f"✅ **Destination saved as:** `{target}`")

@bot.on(events.NewMessage(pattern=r"^/resume"))
async def resume_h(event):
    if not is_admin(event.sender_id):
        return
    if ACTIVE_CLONE["running"]:
        return await event.reply("⚠️ **A clone job is already running!**")
    res = load_resume()
    if not res:
        return await event.reply("ℹ️ **No saved job to resume.**")
    status_msg = await event.reply("⏳ **Resuming saved clone job...**")
    ACTIVE_CLONE["task"] = asyncio.create_task(run_clone_job(event.chat_id, status_msg, res))

@bot.on(events.NewMessage(pattern=r"^/qr"))
async def qr_login_h(event):
    if not is_admin(event.sender_id):
        return
    uid = event.sender_id
    LOGIN_STATE.pop(uid, None)
    await reset_user_session()
    status = await event.reply("⏳ **Generating Login QR Code...**")

    try:
        qr_login = await user_client.qr_login()
        qr_img = make_qr_png(qr_login.url)
        await status.delete()
        qr_msg = await bot.send_file(
            event.chat_id,
            file=qr_img,
            caption="📱 **Scan this QR Code in Telegram → Settings → Devices → Link Desktop Device**"
        )
        try:
            await qr_login.wait(timeout=60)
            me = await user_client.get_me()
            await qr_msg.delete()
            await event.respond(f"✅ **Logged in as `{me.first_name}` (`{me.id}`)!**")
        except SessionPasswordNeededError:
            await qr_msg.delete()
            LOGIN_STATE[uid] = {"step": "2fa"}
            await event.respond("🔒 **2FA enabled. Send your password:**")
        except asyncio.TimeoutError:
            await qr_msg.delete()
            await event.respond("⏱️ **QR expired. Send `/qr` to try again.**")
    except Exception as e:
        await event.respond(f"❌ **QR Error:** `{e}`")

@bot.on(events.NewMessage(pattern=r"^/login"))
async def login_h(event):
    if not is_admin(event.sender_id):
        return
    await reset_user_session()
    LOGIN_STATE[event.sender_id] = {"step": "phone"}
    await event.reply("🔑 Send your **Phone Number** (e.g. `+94771234567`):")

@bot.on(events.NewMessage(pattern=r"^/logout"))
async def logout_h(event):
    if not is_admin(event.sender_id):
        return
    LOGIN_STATE.pop(event.sender_id, None)
    try:
        if await is_user_logged_in():
            await user_client.log_out()
    except Exception:
        pass
    await reset_user_session()
    await event.reply("🗑️ **User Session logged out.**")

@bot.on(events.NewMessage(func=lambda e: e.sender_id in LOGIN_STATE and e.raw_text and not e.raw_text.startswith("/")))
async def login_flow_h(event):
    uid = event.sender_id
    st = LOGIN_STATE.get(uid)
    if not st:
        return
    text = event.raw_text.strip()
    if not user_client.is_connected():
        await user_client.connect()

    try:
        if st["step"] == "phone":
            phone = text.replace(" ", "")
            sent = await user_client.send_code_request(phone)
            st["phone"] = phone
            st["hash"] = sent.phone_code_hash
            st["step"] = "code"
            await event.reply("📲 **OTP sent!** Send the code with spaces (e.g. `1 2 3 4 5`):")
        elif st["step"] == "code":
            code = text.replace(" ", "").replace("-", "")
            try:
                await user_client.sign_in(phone=st["phone"], code=code, phone_code_hash=st["hash"])
                LOGIN_STATE.pop(uid, None)
                me = await user_client.get_me()
                await event.reply(f"✅ **Logged in as `{me.first_name}`!**")
            except SessionPasswordNeededError:
                st["step"] = "2fa"
                await event.reply("🔒 **Send 2FA password:**")
        elif st["step"] == "2fa":
            await user_client.sign_in(password=text)
            LOGIN_STATE.pop(uid, None)
            me = await user_client.get_me()
            await event.respond(f"✅ **Logged in as `{me.first_name}`!**")
    except Exception as e:
        LOGIN_STATE.pop(uid, None)
        await event.reply(f"❌ **Login Error:** `{e}`")

@bot.on(events.NewMessage(func=lambda e: is_admin(e.sender_id) and e.sender_id not in LOGIN_STATE and e.raw_text and ("t.me/" in e.raw_text or re.match(r"^-100\d+$", e.raw_text.strip())) and not e.raw_text.startswith("/")))
async def link_paste_h(event):
    if ACTIVE_CLONE["running"]:
        return await event.reply("⚠️ **A clone job is already running!**")

    cfg = load_config()
    dest = cfg.get("dest_chat")
    if not dest:
        return await event.reply("⚠️ **First set your destination:** `/setdest <link or -100id>`")

    src_target, parsed_max_id = parse_tg_target(event.raw_text.strip())
    end_id = parsed_max_id or 0
    default_w = int(cfg.get("parallel_workers", 2))

    key = str(int(time.time() * 1000))
    setup = {
        "source": src_target,
        "dest": dest,
        "start_id": 1,
        "end_id": end_id,
        "workers": default_w
    }
    PENDING_SETUP[key] = setup

    await event.reply(
        build_setup_text(setup),
        buttons=build_setup_buttons(key, default_w)
    )

@bot.on(events.CallbackQuery)
async def cb_h(event):
    if not is_admin(event.sender_id):
        return await event.answer("⛔ Admin only.", alert=True)

    data = event.data.decode("utf-8").replace(" ", "")

    if data == "ctrl:close":
        return await event.delete()

    if data == "menu:help":
        await event.answer()
        return await event.respond(HELP_INSTRUCTIONS)

    if data == "menu:cleancache":
        if ACTIVE_CLONE["running"]:
            ACTIVE_CLONE["cancelled"] = True
            ACTIVE_CLONE["paused"] = False
            await asyncio.sleep(1.5)
        freed_bytes, files_removed = wipe_cache_folder()
        await event.answer(f"🧹 Cleaned {files_removed} files ({fmt_size(freed_bytes)})!", alert=True)
        await event.delete()
        return await start_h(event)

    if data.startswith("defw:"):
        w = int(data.split(":")[1])
        cfg = load_config()
        cfg["parallel_workers"] = w
        save_config(cfg)
        await event.answer(f"⚡ Default parallel workers set to {w}x!", alert=True)
        await event.delete()
        return await start_h(event)

    if data.startswith("setw:"):
        _, key, w_str = data.split(":")
        w = int(w_str)
        setup = PENDING_SETUP.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired, paste link again.", alert=True)
        setup["workers"] = w
        cfg = load_config()
        cfg["parallel_workers"] = w
        save_config(cfg)
        await event.answer(f"⚡ Parallel speed set to {w}x")
        return await event.edit(build_setup_text(setup), buttons=build_setup_buttons(key, w))

    if data == "menu:qr":
        await event.answer()
        return await qr_login_h(event)
    if data == "menu:login":
        await event.answer()
        return await login_h(event)
    if data == "menu:logout":
        await event.answer()
        return await logout_h(event)
    if data == "menu:resume":
        res = load_resume()
        if not res:
            return await event.answer("No saved job.", alert=True)
        msg = await event.get_message()
        ACTIVE_CLONE["task"] = asyncio.create_task(run_clone_job(event.chat_id, msg, res))
        return

    if data == "ctrl:toggle_pause":
        ACTIVE_CLONE["paused"] = not ACTIVE_CLONE["paused"]
        await event.answer("⏸️ Paused" if ACTIVE_CLONE["paused"] else "▶️ Resumed")
        msg = await event.get_message()
        try:
            await msg.edit(msg.text, buttons=control_buttons())
        except Exception:
            pass
        return

    if data == "ctrl:cancel":
        ACTIVE_CLONE["cancelled"] = True
        ACTIVE_CLONE["paused"] = False
        return await event.answer("🛑 Stopping workers & wiping cache...", alert=True)

    if data.startswith("go:"):
        _, key, filter_mode, action_mode = data.split(":")
        setup = PENDING_SETUP.pop(key, None)
        if not setup:
            return await event.answer("⚠️ Expired, paste link again.", alert=True)
        setup["media_only"] = (filter_mode == "media")
        setup["mode"] = "cache" if action_mode == "cache" else "forward"
        setup["drop_author"] = (action_mode == "copy")
        msg = await event.get_message()
        ACTIVE_CLONE["task"] = asyncio.create_task(run_clone_job(event.chat_id, msg, setup))

if __name__ == "__main__":
    bot.start(bot_token=BOT_TOKEN)
    bot.run_until_disconnected()
PY_EOF

echo "=========================================================="
echo " 🛠️ Creating Terminal SSH Manager (clone-bot)..."
echo "=========================================================="
cat << 'CLI_EOF' > "$CLI_BIN"
#!/bin/bash
while true; do
    clear
    echo "=================================================="
    echo "       🤖 BOTS BY SPW - CLONER SSH MANAGER        "
    echo "=================================================="
    echo "1) Check Service Status"
    echo "2) View Live Logs (Ctrl+C to exit)"
    echo "3) Restart Bot Service"
    echo "4) Stop Bot Service"
    echo "5) Force Clean Cache Folder (/opt/clonebot/cache)"
    echo "6) Edit config.json Credentials"
    echo "7) Uninstall Cloner Bot"
    echo "0) Exit"
    echo "=================================================="
    read -rp "Select an option [0-7]: " choice
    case $choice in
        1) systemctl status clonebot --no-pager; read -rp "Press Enter..." ;;
        2) journalctl -u clonebot -f ;;
        3) systemctl restart clonebot && echo "✅ Restarted!" && sleep 1 ;;
        4) systemctl stop clonebot && echo "🛑 Stopped." && sleep 1 ;;
        5) rm -rf /opt/clonebot/cache/* && echo "🧹 Cache wiped clean!" && sleep 1 ;;
        6) nano /opt/clonebot/config.json && systemctl restart clonebot ;;
        7)
            read -rp "⚠️ Uninstall Cloner Bot? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                systemctl stop clonebot || true
                systemctl disable clonebot || true
                rm -f /etc/systemd/system/clonebot.service /usr/local/bin/clone-bot
                rm -rf /opt/clonebot
                systemctl daemon-reload
                echo "🗑️ Uninstalled."
                exit 0
            fi
            ;;
        0) exit 0 ;;
        *) echo "Invalid option." && sleep 1 ;;
    esac
done
CLI_EOF
chmod +x "$CLI_BIN"

echo "=========================================================="
echo " ⚡ Configuring & Starting systemd Service..."
echo "=========================================================="
/opt/clonebot/venv/bin/python -m py_compile "$INSTALL_DIR/cloner.py"

cat << 'SVC_EOF' > "$SERVICE_FILE"
[Unit]
Description=BOTS BY SPW Telegram Mass Cloner Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/clonebot
ExecStart=/opt/clonebot/venv/bin/python /opt/clonebot/cloner.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable clonebot
systemctl restart clonebot

echo ""
echo "=========================================================="
echo " ✅ BOTS BY SPW — INSTALLATION COMPLETE!"
echo "=========================================================="
echo " • Bot Status : $(systemctl is-active clonebot)"
echo " • SSH Menu   : Type 'clone-bot' anytime in terminal"
echo "=========================================================="

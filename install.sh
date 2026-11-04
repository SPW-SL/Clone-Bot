#!/bin/bash
set -e

INSTALL_DIR="/opt/clonebot"
CACHE_DIR="$INSTALL_DIR/cache"
CONFIG_FILE="$INSTALL_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/clonebot.service"
CLI_BIN="/usr/local/bin/clone-bot"

clear
cat << "BANNER_EOF"
======================================================================
  ____   ___ _____ ____    ____  __   __  ____  ______        __
 | __ ) / _ \_   _/ ___|  | __ ) \ \ / / / ___||  _ \ \      / /
 |  _ \| | | || | \___ \  |  _ \  \ V /  \___ \| |_) \ \ /\ / / 
 | |_) | |_| || |  ___) | | |_) |  | |    ___) |  __/ \ V  V /  
 |____/ \___/ |_| |____/  |____/   |_|   |____/|_|     \_/\_/   
                                                                
   ⚡ PERFECT-ORDER & RESTRICTED BOT CLONER + BANDWIDTH METER ⚡
======================================================================
BANNER_EOF

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this installer as root (sudo bash install.sh)."
    exit 1
fi

echo ""
echo "💡 KEY FEATURES & ENGINE OVERVIEW:"
echo " • Strict 1->N Order : Streams and publishes posts in exact sequential order."
echo " • Bot Chat Unlocker : Extracts save-restricted media from other Telegram bots (/bots)."
echo " • Parallel Staging  : Pre-uploads media & albums in parallel (1x to 8x)."
echo " • Album Preservation: Keeps multi-photo/video grids & captions grouped."
echo " • Size Filter       : Automatically skips files larger than your MB limit."
echo " • Bandwidth Meter   : Real-time Download/Upload speeds, Peak & Total GB."
echo " • Zero Disk Bloat   : Cached files are wiped immediately after each post."
echo "======================================================================"

mkdir -p "$INSTALL_DIR" "$CACHE_DIR"

USE_EXISTING="n"
if [ -f "$CONFIG_FILE" ]; then
    read -rp "⚙️  Existing config.json found. Keep current credentials? [Y/n]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
fi

if [[ ! "$USE_EXISTING" =~ ^[Yy]$ ]]; then
    echo ""
    echo "🔑 Enter your Telegram Credentials (from https://my.telegram.org & @BotFather):"
    read -rp "👉 Enter APP API_ID (e.g. 12345678): " INPUT_API_ID
    read -rp "👉 Enter API_HASH (e.g. a1b2c3d4e5f6...): " INPUT_API_HASH
    read -rp "👉 Enter BOT_TOKEN (from @BotFather): " INPUT_BOT_TOKEN
    read -rp "👉 Enter ADMIN_IDS (space-separated, e.g. 111111111 222222222): " INPUT_ADMINS
    read -rp "👉 Enter Max File Size Limit in MB [default: 150]: " INPUT_MAX_MB
    INPUT_MAX_MB=${INPUT_MAX_MB:-150}

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
    "delay_seconds": 0.4,
    "parallel_workers": 3,
    "max_file_size_mb": $INPUT_MAX_MB
}
CONFIG_EOF
    chmod 600 "$CONFIG_FILE"
    echo "✅ Configuration saved to $CONFIG_FILE"
fi

echo ""
echo "======================================================================"
echo " 📦 Installing System Dependencies (Python, FFmpeg, Build Tools)..."
echo "======================================================================"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip ffmpeg git curl build-essential

echo "======================================================================"
echo " 🐍 Building Python Virtual Environment & Installing Libraries..."
echo "======================================================================"
cd "$INSTALL_DIR"
if [ ! -f "$INSTALL_DIR/venv/bin/python3" ]; then
    python3 -m venv venv
fi
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --upgrade telethon cryptg qrcode pillow

echo "======================================================================"
echo " 🤖 Deploying Cloner Bot Application ($INSTALL_DIR/cloner.py)..."
echo "======================================================================"
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
from collections import deque
from pathlib import Path

import qrcode
from telethon import TelegramClient, events, Button
from telethon.errors import (
    FloodWaitError,
    SessionPasswordNeededError,
    ChatForwardsRestrictedError,
)
from telethon.tl.types import (
    User,
    MessageService,
    DocumentAttributeVideo,
    DocumentAttributeFilename,
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

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".m4v"}
PHOTO_EXTS = {".jpg", ".jpeg", ".png"}
MAX_WORKERS_LIMIT = 10

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

def load_config():
    with open(CONFIG_FILE, "r") as f:
        data = json.load(f)
    data.setdefault("dest_chat", None)
    data.setdefault("delay_seconds", 0.4)
    data.setdefault("parallel_workers", 3)
    data.setdefault("max_file_size_mb", 150)
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
RANGE_WAIT_STATE = {}
WORKER_STATUS = {}

# ================= LIVE DOWNLOAD & UPLOAD BANDWIDTH METER =================

class BandwidthMeter:
    def __init__(self, window_sec: float = 4.0):
        self.window_sec = window_sec
        self.dl_samples = deque()
        self.ul_samples = deque()
        self.total_dl_bytes = 0
        self.total_ul_bytes = 0
        self.peak_dl_bps = 0.0
        self.peak_ul_bps = 0.0

    def reset_job(self):
        self.dl_samples.clear()
        self.ul_samples.clear()
        self.total_dl_bytes = 0
        self.total_ul_bytes = 0
        self.peak_dl_bps = 0.0
        self.peak_ul_bps = 0.0

    def record_dl(self, delta_bytes: int):
        if delta_bytes <= 0:
            return
        now = time.time()
        self.total_dl_bytes += delta_bytes
        self.dl_samples.append((now, delta_bytes))
        self._prune(self.dl_samples, now)

    def record_ul(self, delta_bytes: int):
        if delta_bytes <= 0:
            return
        now = time.time()
        self.total_ul_bytes += delta_bytes
        self.ul_samples.append((now, delta_bytes))
        self._prune(self.ul_samples, now)

    def _prune(self, dq: deque, now: float):
        cutoff = now - self.window_sec
        while dq and dq[0][0] < cutoff:
            dq.popleft()

    def get_dl_speed(self) -> float:
        now = time.time()
        self._prune(self.dl_samples, now)
        if not self.dl_samples:
            return 0.0
        span = max(0.5, now - self.dl_samples[0][0])
        spd = sum(b for _, b in self.dl_samples) / span
        if spd > self.peak_dl_bps:
            self.peak_dl_bps = spd
        return spd

    def get_ul_speed(self) -> float:
        now = time.time()
        self._prune(self.ul_samples, now)
        if not self.ul_samples:
            return 0.0
        span = max(0.5, now - self.ul_samples[0][0])
        spd = sum(b for _, b in self.ul_samples) / span
        if spd > self.peak_ul_bps:
            self.peak_ul_bps = spd
        return spd

BW = BandwidthMeter()

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

def get_media_size_bytes(msg) -> int:
    if not msg or not getattr(msg, "media", None):
        return 0
    if getattr(msg, "file", None) and getattr(msg.file, "size", None):
        return int(msg.file.size)
    if isinstance(msg.media, MessageMediaDocument) and getattr(msg.media, "document", None):
        return int(getattr(msg.media.document, "size", 0) or 0)
    return 0

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

    if text.startswith("@") and len(text) > 1:
        return text[1:], None

    m_priv = re.search(r"t\.me/c/(\d+)(?:/(\d+))?", text)
    if m_priv:
        chat_id = int(f"-100{m_priv.group(1)}")
        msg_id = int(m_priv.group(2)) if m_priv.group(2) else None
        return chat_id, msg_id

    m_pub = re.search(r"t\.me/([a-zA-Z0-9_]+)(?:/(\d+))?", text)
    if m_pub and m_pub.group(1).lower() not in ("c", "joinchat"):
        uname = m_pub.group(1)
        msg_id = int(m_pub.group(2)) if m_pub.group(2) else None
        return uname, msg_id

    return text, None

def parse_input_with_range(raw_text: str):
    tokens = raw_text.strip().split()
    links = [t for t in tokens if "t.me/" in t or t.startswith("@") or re.match(r"^-?\d+$", t)]
    if not links:
        target, mid = parse_tg_target(tokens[0])
        end_val = 0 if (mid is None or mid <= 1) else mid
        return target, 1, end_val

    if len(links) >= 2 and ("t.me/" in links[0] and "t.me/" in links[1]):
        t1, id1 = parse_tg_target(links[0])
        _, id2 = parse_tg_target(links[1])
        if id1 and id2:
            return t1, min(id1, id2), max(id1, id2)

    target, link_msg_id = parse_tg_target(links[0])
    remainder = raw_text.replace(links[0], " ", 1)
    nums = [int(x) for x in re.findall(r"\b\d+\b", remainder)]

    if len(nums) >= 2:
        s_id, e_id = min(nums[0], nums[1]), max(nums[0], nums[1])
        return target, max(1, s_id), e_id
    elif len(nums) == 1:
        if link_msg_id and nums[0] < link_msg_id:
            return target, max(1, nums[0]), link_msg_id
        return target, max(1, nums[0]), 0

    end_val = 0 if (link_msg_id is None or link_msg_id <= 1) else link_msg_id
    return target, 1, end_val

async def is_user_logged_in() -> bool:
    try:
        if not user_client.is_connected():
            await user_client.connect()
        return await user_client.is_user_authorized()
    except Exception:
        return False

async def inspect_source_bounds(src_target):
    info = {
        "is_private_or_bot": False,
        "title": str(src_target),
        "first_id": 1,
        "last_id": 0
    }
    if not await is_user_logged_in():
        return info
    try:
        entity = await user_client.get_entity(src_target)
        if isinstance(entity, User):
            info["is_private_or_bot"] = True
            uname = f"@{entity.username}" if getattr(entity, "username", None) else ""
            tag = "🤖 Bot" if getattr(entity, "bot", False) else "👤 Chat"
            info["title"] = f"{tag}: {entity.first_name or ''} {uname}".strip()
        else:
            info["title"] = getattr(entity, "title", str(src_target))

        latest = await user_client.get_messages(entity, limit=1)
        if latest and latest[0]:
            info["last_id"] = latest[0].id

        oldest = await user_client.get_messages(entity, limit=1, reverse=True)
        if oldest and oldest[0]:
            info["first_id"] = oldest[0].id
    except Exception as e:
        logging.warning(f"Could not inspect source bounds for {src_target}: {e}")
    return info

def control_buttons():
    pause_label = "▶️ Resume" if ACTIVE_CLONE["paused"] else "⏸️ Pause"
    return [
        [
            Button.inline(pause_label, b"ctrl:toggle_pause"),
            Button.inline("❌ Cancel & Clean Cache", b"ctrl:cancel")
        ]
    ]

def build_setup_buttons(key: str, selected_workers: int, is_bot_dm: bool = False):
    worker_opts = [1, 2, 3, 4, 5, 8]
    w_row = []
    for w in worker_opts:
        label = f"✅ {w}x" if w == selected_workers else f"⚡ {w}x"
        w_row.append(Button.inline(label, f"setw:{key}:{w}".encode()))

    rows = [
        w_row[:3],
        w_row[3:],
        [
            Button.inline("🔢 Custom ID Range", f"setr:{key}".encode()),
            Button.inline("🔄 Full History (Oldest→End)", f"setfull:{key}".encode())
        ]
    ]
    if is_bot_dm:
        rows.append([
            Button.inline("📥 Last 10 Msgs", f"setlast:{key}:10".encode()),
            Button.inline("📥 Last 25 Msgs", f"setlast:{key}:25".encode()),
            Button.inline("📥 Last 100 Msgs", f"setlast:{key}:100".encode())
        ])

    rows.extend([
        [Button.inline(f"🔓 Unlock & Clone Media + Albums ({selected_workers}x)", f"go:{key}:media:cache".encode())],
        [Button.inline(f"🔓 Unlock & Clone All + Text ({selected_workers}x)", f"go:{key}:all:cache".encode())],
        [
            Button.inline("📨 Ordered Forward (Tag)", f"go:{key}:media:fwd".encode()),
            Button.inline("📋 Ordered Copy (No Tag)", f"go:{key}:media:copy".encode())
        ],
        [Button.inline("❌ Cancel", b"ctrl:close")]
    ])
    return rows

def build_setup_text(setup: dict) -> str:
    cfg = load_config()
    max_mb = cfg.get("max_file_size_mb", 150)
    s_id = setup.get("start_id", 1)
    end_id = setup.get("end_id", 0)
    title = setup.get("title", setup["source"])
    range_txt = f"`{s_id}` → `{end_id}`" if end_id > 0 else f"`{s_id}` → `Latest`"
    w = setup.get("workers", 3)
    return (
        f"🎯 **Source Ready: {title}**\n\n"
        f"📤 **Source ID/Handle:** `{setup['source']}`\n"
        f"📥 **Destination:** `{setup['dest']}`\n"
        f"🔢 **Message ID Range:** {range_txt}\n"
        f"🔓 **Restricted Save (`noforwards`):** `Auto-Bypass via User Cache ✅`\n"
        f"📏 **Max File Size Limit:** `Skip > {max_mb} MB`\n"
        f"🖼️ **Albums & Captions:** `100% Preserved in Exact Order`\n"
        f"⚡ **Parallel Staging Workers:** `{w}x Concurrent`\n\n"
        "💡 *Protected bot/channel media is downloaded through your User Session cache and re-uploaded permanently in exact 1→2→3→4 order:*"
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

def group_messages_into_units(msgs: list) -> list[list]:
    units = []
    current_unit = []
    current_gid = None

    for m in sorted(msgs, key=lambda x: x.id):
        gid = getattr(m, "grouped_id", None)
        if gid is not None:
            if current_gid == gid and len(current_unit) < 10:
                current_unit.append(m)
            else:
                if current_unit:
                    units.append(sorted(current_unit, key=lambda x: x.id))
                current_unit = [m]
                current_gid = gid
        else:
            if current_unit:
                units.append(sorted(current_unit, key=lambda x: x.id))
                current_unit = []
                current_gid = None
            units.append([m])

    if current_unit:
        units.append(sorted(current_unit, key=lambda x: x.id))
    return units

# ================= STAGE 2: PARALLEL DOWNLOAD & CLOUD PRE-UPLOAD =================

async def stage_unit_files(dl_client, up_client, unit: list) -> dict | None:
    first_id = unit[0].id
    is_album = len(unit) > 1
    unit_cache_dir = CACHE_DIR / f"unit_{first_id}"
    unit_cache_dir.mkdir(parents=True, exist_ok=True)

    while ACTIVE_CLONE["paused"] and not ACTIVE_CLONE["cancelled"]:
        await asyncio.sleep(1)
    if ACTIVE_CLONE["cancelled"]:
        return None

    if is_album:
        valid_album_msgs = [
            m for m in sorted(unit, key=lambda x: x.id)
            if isinstance(m.media, (MessageMediaPhoto, MessageMediaDocument))
        ]
        if not valid_album_msgs:
            return None

        total_items = len(valid_album_msgs)
        album_sem = asyncio.Semaphore(3)
        local_paths = [None] * total_items
        preuploaded_handles = [None] * total_items
        is_photo_flags = [False] * total_items
        captions = [(m.message if getattr(m, "message", None) is not None else (m.text or "")) for m in valid_album_msgs]

        async def dl_and_stage_album_item(idx: int, m):
            async with album_sem:
                if ACTIVE_CLONE["cancelled"]:
                    return
                item_prefix = unit_cache_dir / f"{idx:02d}_msg_{m.id}"
                t0 = time.time()
                last_dl = 0

                def dl_prog(curr, tot):
                    nonlocal last_dl
                    if ACTIVE_CLONE["cancelled"]:
                        raise asyncio.CancelledError()
                    BW.record_dl(curr - last_dl)
                    last_dl = curr
                    spd = curr / max(0.1, time.time() - t0)
                    WORKER_STATUS[first_id] = {
                        "stage": f"📥 Album ({idx + 1}/{total_items})",
                        "curr": curr,
                        "tot": tot,
                        "speed": spd
                    }

                while True:
                    try:
                        fpath = await dl_client.download_media(
                            m,
                            file=str(item_prefix),
                            progress_callback=dl_prog
                        )
                        break
                    except FloodWaitError as fw:
                        WORKER_STATUS[first_id] = {
                            "stage": f"⏳ FloodWait ({fw.seconds}s)",
                            "curr": 0,
                            "tot": 0,
                            "speed": 0.0
                        }
                        await asyncio.sleep(fw.seconds + 2)

                if not fpath or not os.path.exists(fpath) or os.path.getsize(fpath) == 0:
                    return

                local_paths[idx] = fpath
                ext = os.path.splitext(fpath)[1].lower()
                is_photo = isinstance(m.media, MessageMediaPhoto) or (ext in PHOTO_EXTS and not isinstance(m.media, MessageMediaDocument))
                is_photo_flags[idx] = is_photo

                if is_photo:
                    up_t0 = time.time()
                    last_ul = 0

                    def up_prog(curr, tot):
                        nonlocal last_ul
                        if ACTIVE_CLONE["cancelled"]:
                            raise asyncio.CancelledError()
                        BW.record_ul(curr - last_ul)
                        last_ul = curr
                        spd = curr / max(0.1, time.time() - up_t0)
                        WORKER_STATUS[first_id] = {
                            "stage": f"☁️ Pre-Upload ({idx + 1}/{total_items})",
                            "curr": curr,
                            "tot": tot,
                            "speed": spd
                        }

                    while True:
                        try:
                            handle = await up_client.upload_file(
                                fpath,
                                file_name=os.path.basename(fpath),
                                progress_callback=up_prog
                            )
                            preuploaded_handles[idx] = handle
                            break
                        except FloodWaitError as fw:
                            await asyncio.sleep(fw.seconds + 2)

        await asyncio.gather(
            *(dl_and_stage_album_item(i, m) for i, m in enumerate(valid_album_msgs))
        )

        final_local = []
        final_handles = []
        final_captions = []
        all_preuploaded_photos = True

        for lp, fh, is_ph, cap in zip(local_paths, preuploaded_handles, is_photo_flags, captions):
            if lp and os.path.exists(lp):
                final_local.append(lp)
                final_captions.append(cap)
                if is_ph and fh is not None:
                    final_handles.append(fh)
                else:
                    all_preuploaded_photos = False

        if not final_local:
            return None

        WORKER_STATUS[first_id] = {
            "stage": f"✅ Album Ready ({len(final_local)} items)",
            "curr": 1,
            "tot": 1,
            "speed": 0.0
        }
        return {
            "kind": "album",
            "unit_cache_dir": unit_cache_dir,
            "local_paths": final_local,
            "input_files": final_handles if all_preuploaded_photos else None,
            "captions": final_captions,
            "count": len(final_local)
        }

    msg = unit[0]
    if msg.media:
        if not isinstance(msg.media, (MessageMediaPhoto, MessageMediaDocument)):
            if msg.message or msg.text:
                return {
                    "kind": "text",
                    "unit_cache_dir": unit_cache_dir,
                    "text": msg.message or msg.text,
                    "entities": msg.entities,
                    "count": 1
                }
            return None

        item_prefix = unit_cache_dir / f"msg_{msg.id}"
        t0 = time.time()
        last_dl = 0

        def dl_prog(curr, tot):
            nonlocal last_dl
            if ACTIVE_CLONE["cancelled"]:
                raise asyncio.CancelledError()
            BW.record_dl(curr - last_dl)
            last_dl = curr
            spd = curr / max(0.1, time.time() - t0)
            WORKER_STATUS[first_id] = {
                "stage": "📥 Caching Restricted Media",
                "curr": curr,
                "tot": tot,
                "speed": spd
            }

        while True:
            try:
                cached_file = await dl_client.download_media(
                    msg,
                    file=str(item_prefix),
                    progress_callback=dl_prog
                )
                break
            except FloodWaitError as fw:
                WORKER_STATUS[first_id] = {
                    "stage": f"⏳ FloodWait ({fw.seconds}s)",
                    "curr": 0,
                    "tot": 0,
                    "speed": 0.0
                }
                await asyncio.sleep(fw.seconds + 2)

        if not cached_file or not os.path.exists(cached_file) or os.path.getsize(cached_file) == 0:
            return None

        ext = os.path.splitext(cached_file)[1].lower()
        is_video = ext in VIDEO_EXTS
        is_force_doc = (
            isinstance(msg.media, MessageMediaDocument)
            and not is_video
            and not isinstance(msg.media, MessageMediaPhoto)
        )

        attrs = []
        thumb_file = None
        if is_video:
            d, w, h = await asyncio.to_thread(get_video_meta, cached_file)
            attrs.append(DocumentAttributeVideo(duration=d, w=w, h=h, supports_streaming=True))
            thumb_file = await asyncio.to_thread(
                make_thumb, cached_file, str(unit_cache_dir / f"thumb_{msg.id}.jpg")
            )

        fsize = os.path.getsize(cached_file)
        up_t0 = time.time()
        last_ul = 0

        def up_prog(curr, tot):
            nonlocal last_ul
            if ACTIVE_CLONE["cancelled"]:
                raise asyncio.CancelledError()
            BW.record_ul(curr - last_ul)
            last_ul = curr
            spd = curr / max(0.1, time.time() - up_t0)
            WORKER_STATUS[first_id] = {
                "stage": "☁️ Pre-Uploading",
                "curr": curr,
                "tot": tot,
                "speed": spd
            }

        while True:
            try:
                input_file_handle = await up_client.upload_file(
                    cached_file,
                    file_name=os.path.basename(cached_file),
                    progress_callback=up_prog
                )
                break
            except FloodWaitError as fw:
                WORKER_STATUS[first_id] = {
                    "stage": f"⏳ FloodWait ({fw.seconds}s)",
                    "curr": 0,
                    "tot": fsize,
                    "speed": 0.0
                }
                await asyncio.sleep(fw.seconds + 2)

        WORKER_STATUS[first_id] = {
            "stage": "✅ Pre-Uploaded (In Queue)",
            "curr": 1,
            "tot": 1,
            "speed": 0.0
        }
        return {
            "kind": "single_media",
            "unit_cache_dir": unit_cache_dir,
            "local_path": cached_file,
            "input_file": input_file_handle,
            "thumb": thumb_file,
            "attrs": attrs if attrs else None,
            "is_video": is_video,
            "force_document": is_force_doc,
            "caption": msg.message if getattr(msg, "message", None) is not None else (msg.text or ""),
            "entities": msg.entities,
            "count": 1
        }

    elif msg.message or msg.text:
        return {
            "kind": "text",
            "unit_cache_dir": unit_cache_dir,
            "text": msg.message if getattr(msg, "message", None) is not None else msg.text,
            "entities": msg.entities,
            "count": 1
        }

    return None

# ================= STAGE 3: STRICT 1->N SEQUENTIAL PUBLISHER =================

async def publish_staged_slot(up_client, dest_entity, first_id: int, payload: dict) -> int:
    if not payload:
        return 0
    unit_cache_dir = payload.get("unit_cache_dir")

    try:
        while ACTIVE_CLONE["paused"] and not ACTIVE_CLONE["cancelled"]:
            await asyncio.sleep(1)
        if ACTIVE_CLONE["cancelled"]:
            return 0

        kind = payload["kind"]

        if kind == "album":
            captions = payload["captions"]
            input_files = payload.get("input_files")
            local_paths = payload["local_paths"]

            if input_files:
                WORKER_STATUS[first_id] = {
                    "stage": f"📤 Publishing Album ({len(input_files)} items)",
                    "curr": 1,
                    "tot": 1,
                    "speed": 0.0
                }
                try:
                    while True:
                        try:
                            await up_client.send_file(
                                dest_entity,
                                file=input_files,
                                caption=captions
                            )
                            return int(payload["count"])
                        except FloodWaitError as fw:
                            await asyncio.sleep(fw.seconds + 2)
                except Exception as e:
                    logging.info(f"Album pre-upload handle fallback to local paths for {first_id}: {e}")

            total_bytes = sum(os.path.getsize(p) for p in local_paths if os.path.exists(p))
            up_t0 = time.time()
            last_ul = 0

            def alb_up_prog(curr, tot):
                nonlocal last_ul
                if ACTIVE_CLONE["cancelled"]:
                    raise asyncio.CancelledError()
                if curr > last_ul:
                    BW.record_ul(curr - last_ul)
                last_ul = curr
                spd = curr / max(0.1, time.time() - up_t0)
                WORKER_STATUS[first_id] = {
                    "stage": f"📤 Uploading Album ({len(local_paths)} items)",
                    "curr": curr,
                    "tot": tot or total_bytes,
                    "speed": spd
                }

            while True:
                try:
                    await up_client.send_file(
                        dest_entity,
                        file=local_paths,
                        caption=captions,
                        supports_streaming=True,
                        progress_callback=alb_up_prog
                    )
                    return int(payload["count"])
                except FloodWaitError as fw:
                    await asyncio.sleep(fw.seconds + 2)

        elif kind == "single_media":
            WORKER_STATUS[first_id] = {
                "stage": "📤 Publishing in Order...",
                "curr": 1,
                "tot": 1,
                "speed": 0.0
            }
            try:
                while True:
                    try:
                        await up_client.send_file(
                            dest_entity,
                            file=payload["input_file"],
                            caption=payload["caption"],
                            formatting_entities=payload["entities"],
                            thumb=payload["thumb"],
                            attributes=payload["attrs"],
                            supports_streaming=payload["is_video"],
                            force_document=payload["force_document"]
                        )
                        return 1
                    except FloodWaitError as fw:
                        await asyncio.sleep(fw.seconds + 2)
            except Exception as e:
                logging.info(f"Single pre-upload fallback to local path for {first_id}: {e}")
                while True:
                    try:
                        await up_client.send_file(
                            dest_entity,
                            file=payload["local_path"],
                            caption=payload["caption"],
                            formatting_entities=payload["entities"],
                            thumb=payload["thumb"],
                            attributes=payload["attrs"],
                            supports_streaming=payload["is_video"],
                            force_document=payload["force_document"]
                        )
                        return 1
                    except FloodWaitError as fw:
                        await asyncio.sleep(fw.seconds + 2)

        elif kind == "text":
            WORKER_STATUS[first_id] = {
                "stage": "📤 Sending Text Post...",
                "curr": 1,
                "tot": 1,
                "speed": 0.0
            }
            while True:
                try:
                    await up_client.send_message(
                        dest_entity,
                        payload["text"],
                        formatting_entities=payload["entities"]
                    )
                    return 1
                except FloodWaitError as fw:
                    await asyncio.sleep(fw.seconds + 2)

        return 0
    finally:
        if unit_cache_dir and os.path.exists(unit_cache_dir):
            shutil.rmtree(unit_cache_dir, ignore_errors=True)

# ================= MAIN CLONE RUNNER =================

async def fetch_ordered_units_batch(
    dl_client,
    src_entity,
    use_user: bool,
    cursor_id: int,
    end_id: int,
    target_units_count: int,
    media_only: bool,
    max_bytes: int
) -> tuple[list[list], int, int, int]:
    skipped_other = 0
    skipped_size = 0
    collected_msgs = []
    last_seen_id = cursor_id - 1

    if use_user:
        active_gid = None
        iter_kwargs = {
            "min_id": max(0, cursor_id - 1),
            "reverse": True,
        }
        if end_id > 0:
            iter_kwargs["max_id"] = end_id + 10

        unit_counter = 0
        async for m in dl_client.iter_messages(src_entity, **iter_kwargs):
            if ACTIVE_CLONE["cancelled"]:
                break
            if m is None:
                continue

            gid = getattr(m, "grouped_id", None)
            if end_id > 0 and m.id > end_id:
                if gid is not None and gid == active_gid:
                    pass
                else:
                    break

            if unit_counter >= target_units_count and (gid is None or gid != active_gid):
                break

            last_seen_id = max(last_seen_id, m.id)

            if isinstance(m, MessageService):
                skipped_other += 1
                continue
            if media_only and not m.media:
                skipped_other += 1
                continue
            if not m.media and not (m.message or m.text):
                skipped_other += 1
                continue

            fsize_b = get_media_size_bytes(m)
            if fsize_b > max_bytes:
                skipped_size += 1
                continue

            if gid is None or gid != active_gid:
                unit_counter += 1
                active_gid = gid

            collected_msgs.append(m)

        units = group_messages_into_units(collected_msgs)
        if not collected_msgs and unit_counter == 0:
            return [], (end_id + 1 if end_id > 0 else last_seen_id + 1), skipped_other, skipped_size
        return units, last_seen_id + 1, skipped_other, skipped_size

    else:
        chunk_span = max(50, target_units_count * 15)
        batch_end = min(end_id, cursor_id + chunk_span - 1) if end_id > 0 else (cursor_id + chunk_span - 1)
        id_list = list(range(cursor_id, batch_end + 1))

        while True:
            try:
                msgs = await dl_client.get_messages(src_entity, ids=id_list)
                break
            except FloodWaitError as fw:
                await asyncio.sleep(fw.seconds + 2)

        sorted_msgs = sorted([m for m in (msgs or []) if m is not None], key=lambda x: x.id)
        for m in sorted_msgs:
            if isinstance(m, MessageService):
                skipped_other += 1
                continue
            if media_only and not m.media:
                skipped_other += 1
                continue
            if not m.media and not (m.message or m.text):
                skipped_other += 1
                continue
            if get_media_size_bytes(m) > max_bytes:
                skipped_size += 1
                continue
            collected_msgs.append(m)

        if collected_msgs and getattr(collected_msgs[-1], "grouped_id", None) is not None:
            last_gid = collected_msgs[-1].grouped_id
            peek_ids = list(range(batch_end + 1, batch_end + 11))
            while True:
                try:
                    peek_msgs = await dl_client.get_messages(src_entity, ids=peek_ids)
                    break
                except FloodWaitError as fw:
                    await asyncio.sleep(fw.seconds + 2)
            for pm in sorted([p for p in (peek_msgs or []) if p is not None], key=lambda x: x.id):
                if getattr(pm, "grouped_id", None) == last_gid:
                    batch_end = max(batch_end, pm.id)
                    if get_media_size_bytes(pm) <= max_bytes:
                        collected_msgs.append(pm)
                    else:
                        skipped_size += 1
                else:
                    break

        units = group_messages_into_units(collected_msgs)
        return units, batch_end + 1, skipped_other, skipped_size

async def run_clone_job(chat_id: int, status_msg, job_cfg: dict):
    ACTIVE_CLONE["running"] = True
    ACTIVE_CLONE["paused"] = False
    ACTIVE_CLONE["cancelled"] = False
    WORKER_STATUS.clear()
    BW.reset_job()

    cfg = load_config()
    src_target = job_cfg["source"]
    dest_target = job_cfg["dest"]
    start_id = max(1, int(job_cfg.get("start_id", 1)))
    end_id = int(job_cfg.get("end_id") or 0)
    media_only = bool(job_cfg.get("media_only", True))
    mode = job_cfg.get("mode", "cache")
    drop_author = bool(job_cfg.get("drop_author", False))
    workers = max(1, min(MAX_WORKERS_LIMIT, int(job_cfg.get("workers", cfg.get("parallel_workers", 3)))))
    delay_sec = float(cfg.get("delay_seconds", 0.4))
    max_mb = float(cfg.get("max_file_size_mb", 150))
    max_bytes = int(max_mb * 1024 * 1024)

    use_user = await is_user_logged_in()
    dl_client = user_client if use_user else bot

    forwarded_total = int(job_cfg.get("forwarded_total", 0))
    albums_total = int(job_cfg.get("albums_total", 0))
    skipped_total = int(job_cfg.get("skipped_total", 0))
    skipped_size_total = int(job_cfg.get("skipped_size_total", 0))
    t_start = time.time()
    current_scan_id = start_id
    ui_running = True

    async def ui_updater_loop(total_range: int):
        while ui_running and not ACTIVE_CLONE["cancelled"]:
            await asyncio.sleep(3.0)
            if not ui_running:
                break
            done_ids = max(0, current_scan_id - start_id)
            pct = min(100.0, (done_ids / max(1, total_range)) * 100)
            elapsed = time.time() - t_start
            rate = done_ids / max(0.1, elapsed)
            eta = max(0, end_id - current_scan_id) / max(0.01, rate)

            dl_spd = BW.get_dl_speed()
            ul_spd = BW.get_ul_speed()

            worker_lines = []
            for mid, st in sorted(WORKER_STATUS.items()):
                c_bytes = st.get("curr", 0)
                t_bytes = st.get("tot", 0)
                w_pct = (c_bytes / t_bytes * 100) if t_bytes else 0
                spd = st.get("speed", 0.0)
                worker_lines.append(
                    f"• `ID {mid}` {st['stage']}: `[{progress_bar(c_bytes, t_bytes, 8)}] {w_pct:.0f}%` (`{fmt_size(spd)}/s`)"
                )

            active_block = "\n".join(worker_lines) if worker_lines else "• *Streaming next ordered batch...*"
            state_banner = "⏸️ **PAUSED**" if ACTIVE_CLONE["paused"] else f"🚀 **Perfect-Order Cloning ({workers}x Parallel)...**"

            text = (
                f"{state_banner}\n"
                f"`[{progress_bar(done_ids, total_range, 12)}] {pct:.1f}%`\n\n"
                f"✅ **Published (1→N Order):** `{forwarded_total}` (🖼️ **Albums:** `{albums_total}`)\n"
                f"📏 **Skipped (>{max_mb:.0f} MB):** `{skipped_size_total}` | ⏭️ **Skipped Other:** `{skipped_total}`\n"
                f"🔢 **Source Progress:** `{current_scan_id}` / `{end_id}`\n\n"
                f"📡 **Live Bandwidth Meter:**\n"
                f"⬇️ **DL:** `{fmt_size(dl_spd)}/s` (Peak: `{fmt_size(BW.peak_dl_bps)}/s` | Total: `{fmt_size(BW.total_dl_bytes)}`)\n"
                f"⬆️ **UL:** `{fmt_size(ul_spd)}/s` (Peak: `{fmt_size(BW.peak_ul_bps)}/s` | Total: `{fmt_size(BW.total_ul_bytes)}`)\n"
                f"🧹 **VPS Cache:** `{fmt_size(get_dir_size(CACHE_DIR))}` | ⏱️ **ETA:** `{fmt_time(eta)}`\n\n"
                f"⚡ **Active Workers ({len(WORKER_STATUS)}/{workers}):**\n"
                f"{active_block}"
            )
            try:
                await status_msg.edit(text, buttons=control_buttons())
            except Exception:
                pass

    ui_task = None
    try:
        src_entity = await dl_client.get_entity(src_target)
        chat_noforwards = bool(getattr(src_entity, "noforwards", False))

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

        if start_id > end_id:
            start_id, end_id = end_id, start_id

        total_range = max(1, end_id - start_id + 1)
        ui_task = asyncio.create_task(ui_updater_loop(total_range))

        target_units_per_batch = max(12, workers * 4)

        while current_scan_id <= end_id:
            if ACTIVE_CLONE["cancelled"]:
                break
            while ACTIVE_CLONE["paused"] and not ACTIVE_CLONE["cancelled"]:
                await asyncio.sleep(1)

            units, next_cursor_id, sk_other, sk_size = await fetch_ordered_units_batch(
                dl_client=dl_client,
                src_entity=src_entity,
                use_user=use_user,
                cursor_id=current_scan_id,
                end_id=end_id,
                target_units_count=target_units_per_batch,
                media_only=media_only,
                max_bytes=max_bytes
            )
            skipped_total += sk_other
            skipped_size_total += sk_size

            if not units:
                if next_cursor_id <= current_scan_id:
                    break
                current_scan_id = next_cursor_id
                continue

            slots = [
                {
                    "unit": u,
                    "first_id": u[0].id,
                    "last_id": max(m.id for m in u),
                    "is_album": len(u) > 1,
                    "has_protected": chat_noforwards or any(
                        bool(getattr(m, "noforwards", False)) or bool(getattr(getattr(m, "media", None), "ttl_seconds", None))
                        for m in u
                    ),
                    "done": asyncio.Event(),
                    "payload": None
                }
                for u in units
            ]

            preupload_sem = asyncio.Semaphore(workers)

            async def producer_worker(slot: dict):
                try:
                    if mode == "cache" or slot["has_protected"]:
                        slot["payload"] = await stage_unit_files(dl_client, up_client, slot["unit"])
                    else:
                        slot["payload"] = {"kind": "forward"}
                except asyncio.CancelledError:
                    slot["payload"] = None
                except Exception as e:
                    logging.warning(f"Staging unit {slot['first_id']} failed: {e}")
                    slot["payload"] = None
                finally:
                    slot["done"].set()

            async def launch_producers():
                tasks = []
                for s in slots:
                    if ACTIVE_CLONE["cancelled"]:
                        s["done"].set()
                        continue
                    await preupload_sem.acquire()
                    if ACTIVE_CLONE["cancelled"]:
                        preupload_sem.release()
                        s["done"].set()
                        continue
                    tasks.append(asyncio.create_task(producer_worker(s)))
                if tasks:
                    await asyncio.gather(*tasks, return_exceptions=True)

            producer_launcher = asyncio.create_task(launch_producers())

            for slot in slots:
                if ACTIVE_CLONE["cancelled"]:
                    break
                await slot["done"].wait()
                first_id = slot["first_id"]
                unit = slot["unit"]
                unit_ids = [m.id for m in unit]
                is_album = slot["is_album"]

                try:
                    if ACTIVE_CLONE["cancelled"]:
                        break
                    while ACTIVE_CLONE["paused"] and not ACTIVE_CLONE["cancelled"]:
                        await asyncio.sleep(1)
                    if ACTIVE_CLONE["cancelled"]:
                        break

                    payload = slot["payload"]
                    if payload is None:
                        skipped_total += len(unit)
                    elif payload.get("kind") == "forward":
                        try:
                            while True:
                                try:
                                    await dl_client.forward_messages(
                                        entity=dest_entity,
                                        messages=unit_ids,
                                        from_peer=src_entity,
                                        drop_author=drop_author
                                    )
                                    break
                                except FloodWaitError as fw:
                                    await asyncio.sleep(fw.seconds + 2)
                            forwarded_total += len(unit_ids)
                            if is_album:
                                albums_total += 1
                        except ChatForwardsRestrictedError:
                            fallback_payload = await stage_unit_files(dl_client, up_client, unit)
                            sent_cnt = await publish_staged_slot(up_client, dest_entity, first_id, fallback_payload)
                            if sent_cnt > 0:
                                forwarded_total += sent_cnt
                                if is_album:
                                    albums_total += 1
                            else:
                                skipped_total += len(unit)
                    else:
                        sent_cnt = await publish_staged_slot(up_client, dest_entity, first_id, payload)
                        if sent_cnt > 0:
                            forwarded_total += sent_cnt
                            if is_album:
                                albums_total += 1
                        else:
                            skipped_total += len(unit)
                except Exception as e:
                    logging.warning(f"Sequential publish failed for unit {unit_ids}: {e}")
                    skipped_total += len(unit)
                finally:
                    if payload and payload.get("unit_cache_dir"):
                        shutil.rmtree(payload["unit_cache_dir"], ignore_errors=True)
                    WORKER_STATUS.pop(first_id, None)
                    preupload_sem.release()
                    current_scan_id = slot["last_id"] + 1
                    job_cfg["start_id"] = current_scan_id
                    job_cfg["end_id"] = end_id
                    job_cfg["forwarded_total"] = forwarded_total
                    job_cfg["albums_total"] = albums_total
                    job_cfg["skipped_total"] = skipped_total
                    job_cfg["skipped_size_total"] = skipped_size_total
                    job_cfg["workers"] = workers
                    save_resume(job_cfg)
                    await asyncio.sleep(delay_sec)

            producer_launcher.cancel()
            current_scan_id = max(current_scan_id, next_cursor_id)
            job_cfg["start_id"] = current_scan_id
            save_resume(job_cfg)

        ui_running = False
        if ui_task:
            ui_task.cancel()

        wipe_cache_folder()
        total_elapsed = max(0.1, time.time() - t_start)

        if ACTIVE_CLONE["cancelled"]:
            await status_msg.edit(
                f"🛑 **Stopped at Message ID `{job_cfg['start_id']}` & Cache Wiped (`0.00 B`).**\n\n"
                f"✅ **Published (In Order):** `{forwarded_total}` (🖼️ **Albums:** `{albums_total}`)\n"
                f"📏 **Skipped (>{max_mb:.0f} MB):** `{skipped_size_total}`\n"
                f"📡 **Total Transferred:** ⬇️ `{fmt_size(BW.total_dl_bytes)}` | ⬆️ `{fmt_size(BW.total_ul_bytes)}`\n"
                "💡 *Send `/resume` anytime to continue from this exact message!*",
                buttons=None
            )
        else:
            if RESUME_FILE.exists():
                RESUME_FILE.unlink(missing_ok=True)
            await status_msg.edit(
                f"🎉 **Perfect-Order Cloning 100% Complete ({workers}x Parallel)!**\n\n"
                f"🔢 **Cloned Range (1→N Order):** `{start_id}` → `{end_id}`\n"
                f"✅ **Total Published Files:** `{forwarded_total}`\n"
                f"🖼️ **Combined Albums Published:** `{albums_total}`\n"
                f"📏 **Skipped (>{max_mb:.0f} MB):** `{skipped_size_total}` | ⏭️ **Other Skipped:** `{skipped_total}`\n\n"
                f"📡 **Bandwidth Summary:**\n"
                f"⬇️ **Downloaded:** `{fmt_size(BW.total_dl_bytes)}` (Peak: `{fmt_size(BW.peak_dl_bps)}/s`)\n"
                f"⬆️ **Uploaded:** `{fmt_size(BW.total_ul_bytes)}` (Peak: `{fmt_size(BW.peak_ul_bps)}/s`)\n"
                f"🧹 **VPS Cache Folder:** `0.00 B (Clean)`\n"
                f"⏱️ **Total Time:** `{fmt_time(total_elapsed)}`",
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

HELP_INSTRUCTIONS = (
    "📖 **BOTS BY SPW: Restricted Bot & Channel Cloner Guide**\n\n"
    "**1. Connect Your User Account (Required for Restricted Content):**\n"
    "• Send **`/qr`** and scan the QR code in **Telegram → Settings → Devices → Link Desktop Device**.\n\n"
    "**2. How to Clone Restricted Media From Another Bot (`noforwards`):**\n"
    "• Tap **🤖 Clone From a Bot Chat** on `/start` (or send **`/bots`**) to pick any bot you recently chatted with.\n"
    "• Or paste the bot's username directly (`@example_bot` or `https://t.me/example_bot`).\n"
    "• Choose **📥 Last 10 / 25 / 100 Msgs** or **🔄 Full History**, then tap **🔓 Unlock & Clone Media**!\n\n"
    "**3. Guaranteed 1→2→3→4 Order & Album Preservation:**\n"
    "• Streams messages in ascending order, extracts restricted/view-once media through `/opt/clonebot/cache`, and wipes the cache immediately."
)

@bot.on(events.NewMessage(pattern=r"^/start"))
async def start_h(event):
    if not is_admin(event.sender_id):
        return
    cfg = load_config()
    dest = cfg.get("dest_chat") or "Not Set ❌ (Use /setdest)"
    workers = cfg.get("parallel_workers", 3)
    max_mb = cfg.get("max_file_size_mb", 150)
    cache_bytes = get_dir_size(CACHE_DIR)
    logged = await is_user_logged_in()
    if logged:
        me = await user_client.get_me()
        u_stat = f"Connected ✅ ({me.first_name} | {me.id})"
    else:
        u_stat = "Not Logged In ⚠️ (Use /qr)"
    res = load_resume()

    btns = [
        [Button.inline("🤖 Clone From a Bot Chat (Restricted Save)", b"menu:bots")],
        [
            Button.inline("⚡ 1x", b"defw:1"),
            Button.inline("⚡ 2x", b"defw:2"),
            Button.inline("⚡ 3x", b"defw:3"),
            Button.inline("⚡ 5x", b"defw:5"),
            Button.inline("⚡ 8x", b"defw:8")
        ],
        [Button.inline("📖 How to Use", b"menu:help"), Button.inline("🧹 Clean Cache", b"menu:cleancache")],
        [Button.inline("📱 QR Login (No OTP)", b"menu:qr"), Button.inline("🗑️ Clear Resume", b"menu:clearresume")],
        [Button.inline("🚪 Logout User", b"menu:logout")]
    ]
    if res:
        btns.insert(0, [Button.inline(f"▶️ Resume Saved Job (ID {res.get('start_id')} → {res.get('end_id')})", b"menu:resume")])

    await event.reply(
        "🤖 **BOTS BY SPW: Perfect-Order & Restricted Bot Cloner**\n\n"
        f"📥 **Destination:** `{dest}`\n"
        f"👤 **User Session:** `{u_stat}`\n"
        f"🔓 **Restricted Bot/Channel Save:** `Auto-Unlock via User Cache ✅`\n"
        f"🔢 **Order Engine:** `Strict 1→2→3→4 Stream + Album Lock ✅`\n"
        f"📏 **Max File Size:** `Skip > {max_mb} MB` *(Change via `/maxsize`)*\n"
        f"📡 **Bandwidth Meter:** `Live DL/UL Speed & Peak Tracker ✅`\n"
        f"⚡ **Parallel Staging Workers:** `{workers}x Concurrent`\n"
        f"🧹 **Temp Cache Size:** `{fmt_size(cache_bytes)}`\n\n"
        "👇 *Paste any channel post link, paste a `@bot_username`, or tap **🤖 Clone From a Bot Chat** below!*",
        buttons=btns
    )

@bot.on(events.NewMessage(pattern=r"^/bots"))
async def list_bots_h(event):
    if not is_admin(event.sender_id):
        return
    await show_recent_bots_menu(event)

async def show_recent_bots_menu(event):
    if not await is_user_logged_in():
        return await event.respond("⚠️ **Please connect your User Session first using `/qr` so the bot can read your bot chats!**")

    status = await event.respond("🔍 **Scanning your recent Telegram dialogs for Bot chats...**")
    bot_Rows = []
    try:
        async for d in user_client.iter_dialogs(limit=150):
            ent = d.entity
            if isinstance(ent, User) and getattr(ent, "bot", False):
                if ent.id == (await bot.get_me()).id:
                    continue
                uname = f"@{ent.username}" if getattr(ent, "username", None) else str(ent.id)
                label = f"🤖 {ent.first_name or uname} ({uname})"
                target_val = f"@{ent.username}" if getattr(ent, "username", None) else str(ent.id)
                bot_Rows.append([Button.inline(label[:45], f"pickbot:{target_val}".encode())])
                if len(bot_Rows) >= 12:
                    break
    except Exception as e:
        return await status.edit(f"❌ **Error scanning bot dialogs:** `{e}`")

    if not bot_Rows:
        return await status.edit("ℹ️ **No recent bot chats found in your dialogs.** You can also paste any `@bot_username` directly in chat!")

    bot_Rows.append([Button.inline("❌ Close", b"ctrl:close")])
    await status.edit(
        "🤖 **Select a Bot Chat to Unlock & Clone Restricted Media:**\n"
        "*(Or send any `@bot_username` / `https://t.me/bot_username` directly in chat)*",
        buttons=bot_Rows
    )

@bot.on(events.NewMessage(pattern=r"^/help"))
async def help_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    await event.reply(HELP_INSTRUCTIONS)

@bot.on(events.NewMessage(pattern=r"^/maxsize\s+(\d+(?:\.\d+)?)"))
async def maxsize_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    val = max(1.0, float(event.pattern_match.group(1)))
    cfg = load_config()
    cfg["max_file_size_mb"] = val
    save_config(cfg)
    await event.reply(f"📏 **Max file size limit updated:** Files larger than `{val:.0f} MB` will be skipped automatically.")

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

@bot.on(events.NewMessage(pattern=r"^/delay\s+(\d+(?:\.\d+)?)"))
async def delay_h(event):
    if not is_admin(event.sender_id):
        return
    val = max(0.1, float(event.pattern_match.group(1)))
    cfg = load_config()
    cfg["delay_seconds"] = val
    save_config(cfg)
    await event.reply(f"⏱️ **Publisher delay updated to:** `{val}s`")

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
    RANGE_WAIT_STATE.pop(uid, None)
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
    RANGE_WAIT_STATE.pop(event.sender_id, None)
    await reset_user_session()
    LOGIN_STATE[event.sender_id] = {"step": "phone"}
    await event.reply("🔑 Send your **Phone Number** in international format (e.g. `+1234567890`):")

@bot.on(events.NewMessage(pattern=r"^/logout"))
async def logout_h(event):
    if not is_admin(event.sender_id):
        return
    LOGIN_STATE.pop(event.sender_id, None)
    RANGE_WAIT_STATE.pop(event.sender_id, None)
    try:
        if await is_user_logged_in():
            await user_client.log_out()
    except Exception:
        pass
    await reset_user_session()
    await event.reply("🗑️ **User Session logged out.**")

@bot.on(events.NewMessage(func=lambda e: e.sender_id in RANGE_WAIT_STATE and e.raw_text and not e.raw_text.startswith("/")))
async def range_input_flow_h(event):
    uid = event.sender_id
    st = RANGE_WAIT_STATE.pop(uid, None)
    if not st:
        return
    key = st["key"]
    setup_msg = st["setup_msg"]
    setup = PENDING_SETUP.get(key)
    if not setup:
        return await event.reply("⚠️ **Session expired. Please paste the link again.**")

    text = event.raw_text.strip()
    link_ids = [int(x) for x in re.findall(r"t\.me/(?:c/\d+|[a-zA-Z0-9_]+)/(\d+)", text)]
    if len(link_ids) >= 2:
        s_id, e_id = min(link_ids[0], link_ids[1]), max(link_ids[0], link_ids[1])
    else:
        nums = [int(x) for x in re.findall(r"\b\d+\b", text)]
        if not nums:
            return await event.reply("⚠️ **Invalid range.** Send two numbers like `1 500` or `100-500`.")
        if len(nums) >= 2:
            s_id, e_id = min(nums[0], nums[1]), max(nums[0], nums[1])
        else:
            s_id = nums[0]
            e_id = setup.get("last_id", 0)

    setup["start_id"] = max(1, s_id)
    setup["end_id"] = max(0, e_id)

    try:
        await event.delete()
    except Exception:
        pass

    await setup_msg.edit(
        build_setup_text(setup),
        buttons=build_setup_buttons(key, setup["workers"], setup.get("is_bot_dm", False))
    )

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

@bot.on(events.NewMessage(pattern=r"^/clone\s+(.+)"))
async def clone_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    await open_clone_setup(event, event.pattern_match.group(1))

@bot.on(events.NewMessage(func=lambda e: is_admin(e.sender_id) and e.sender_id not in LOGIN_STATE and e.sender_id not in RANGE_WAIT_STATE and e.raw_text and ("t.me/" in e.raw_text or e.raw_text.strip().startswith("@") or re.match(r"^-?\d+$", e.raw_text.strip())) and not e.raw_text.startswith("/")))
async def link_paste_h(event):
    await open_clone_setup(event, event.raw_text.strip())

async def open_clone_setup(event, raw_input: str):
    if ACTIVE_CLONE["running"]:
        return await event.reply("⚠️ **A clone job is already running!**")

    cfg = load_config()
    dest = cfg.get("dest_chat")
    if not dest:
        return await event.reply("⚠️ **First set your destination:** `/setdest <link or -100id>`")

    src_target, start_id, end_id = parse_input_with_range(raw_input)
    bounds = await inspect_source_bounds(src_target)

    if bounds["is_private_or_bot"] and start_id == 1 and end_id == 0:
        start_id = bounds["first_id"]
        end_id = bounds["last_id"]

    default_w = int(cfg.get("parallel_workers", 3))
    key = str(int(time.time() * 1000))
    setup = {
        "source": src_target,
        "title": bounds["title"],
        "is_bot_dm": bounds["is_private_or_bot"],
        "first_id": bounds["first_id"],
        "last_id": bounds["last_id"],
        "dest": dest,
        "start_id": start_id,
        "end_id": end_id,
        "workers": default_w
    }
    PENDING_SETUP[key] = setup

    await event.respond(
        build_setup_text(setup),
        buttons=build_setup_buttons(key, default_w, bounds["is_private_or_bot"])
    )

@bot.on(events.CallbackQuery)
async def cb_h(event):
    if not is_admin(event.sender_id):
        return await event.answer("⛔ Admin only.", alert=True)

    uid = event.sender_id
    data = event.data.decode("utf-8").replace(" ", "")

    if data == "ctrl:close":
        RANGE_WAIT_STATE.pop(uid, None)
        return await event.delete()

    if data == "menu:bots":
        await event.answer()
        return await show_recent_bots_menu(event)

    if data.startswith("pickbot:"):
        target_bot = data.split(":", 1)[1]
        await event.answer(f"Selected {target_bot}")
        await event.delete()
        return await open_clone_setup(event, target_bot)

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

    if data == "menu:clearresume":
        RESUME_FILE.unlink(missing_ok=True)
        await event.answer("🗑️ Saved resume checkpoint cleared!", alert=True)
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
        return await event.edit(
            build_setup_text(setup),
            buttons=build_setup_buttons(key, w, setup.get("is_bot_dm", False))
        )

    if data.startswith("setfull:"):
        _, key = data.split(":")
        setup = PENDING_SETUP.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired, paste link again.", alert=True)
        setup["start_id"] = setup.get("first_id", 1) if setup.get("is_bot_dm") else 1
        setup["end_id"] = setup.get("last_id", 0) if setup.get("is_bot_dm") else 0
        await event.answer("🔄 Set to Full History (Oldest → Latest)")
        return await event.edit(
            build_setup_text(setup),
            buttons=build_setup_buttons(key, setup["workers"], setup.get("is_bot_dm", False))
        )

    if data.startswith("setlast:"):
        _, key, count_str = data.split(":")
        cnt = int(count_str)
        setup = PENDING_SETUP.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired, paste link again.", alert=True)
        last_id = setup.get("last_id") or 0
        first_id = setup.get("first_id") or 1
        if last_id > 0:
            setup["start_id"] = max(first_id, last_id - cnt + 1)
            setup["end_id"] = last_id
        await event.answer(f"📥 Set to Last {cnt} messages")
        return await event.edit(
            build_setup_text(setup),
            buttons=build_setup_buttons(key, setup["workers"], setup.get("is_bot_dm", False))
        )

    if data.startswith("setr:"):
        _, key = data.split(":")
        setup = PENDING_SETUP.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired, paste link again.", alert=True)
        msg = await event.get_message()
        RANGE_WAIT_STATE[uid] = {"key": key, "setup_msg": msg}
        await event.answer("🔢 Send Start and End ID")
        return await event.edit(
            f"🔢 **Set Custom Message ID Range for `{setup['source']}`**\n\n"
            f"Current Range: `{setup.get('start_id', 1)}` → `{setup.get('end_id') or 'Latest'}`\n"
            f"Detected Bounds: `{setup.get('first_id', 1)}` → `{setup.get('last_id') or 'Auto'}`\n\n"
            "👇 **Send your desired range now in any format:**\n"
            "• `1 - 500` or `1 500` *(Clones from ID 1 to 500)*\n"
            "• `250` *(Starts at ID 250 and clones to the end)*\n"
            "• Or paste two post links (`https://t.me/c/xxx/1 https://t.me/c/xxx/500`)",
            buttons=[[Button.inline("🔙 Back to Setup Menu", f"backr:{key}".encode())]]
        )

    if data.startswith("backr:"):
        _, key = data.split(":")
        RANGE_WAIT_STATE.pop(uid, None)
        setup = PENDING_SETUP.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired.", alert=True)
        return await event.edit(
            build_setup_text(setup),
            buttons=build_setup_buttons(key, setup["workers"], setup.get("is_bot_dm", False))
        )

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
        RANGE_WAIT_STATE.pop(uid, None)
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

echo "======================================================================"
echo " 🛠️ Creating Terminal SSH Manager (clone-bot)..."
echo "======================================================================"
cat << 'CLI_EOF' > "$CLI_BIN"
#!/bin/bash
while true; do
    clear
    cat << "BANNER"
======================================================================
  ____   ___ _____ ____    ____  __   __  ____  ______        __
 | __ ) / _ \_   _/ ___|  | __ ) \ \ / / / ___||  _ \ \      / /
 |  _ \| | | || | \___ \  |  _ \  \ V /  \___ \| |_) \ \ /\ / / 
 | |_) | |_| || |  ___) | | |_) |  | |    ___) |  __/ \ V  V /  
 |____/ \___/ |_| |____/  |____/   |_|   |____/|_|     \_/\_/   
                 CLONER BOT - SSH MANAGEMENT MENU
======================================================================
BANNER
    echo "1) Check Service Status"
    echo "2) View Live Logs (Ctrl+C to exit)"
    echo "3) Restart Bot Service"
    echo "4) Stop Bot Service"
    echo "5) Force Clean Cache Folder (/opt/clonebot/cache)"
    echo "6) Edit config.json Credentials"
    echo "7) Uninstall Cloner Bot"
    echo "0) Exit"
    echo "======================================================================"
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

echo "======================================================================"
echo " ⚡ Configuring & Starting systemd Service..."
echo "======================================================================"
/opt/clonebot/venv/bin/python -m py_compile "$INSTALL_DIR/cloner.py"

cat << 'SVC_EOF' > "$SERVICE_FILE"
[Unit]
Description=BOTS BY SPW Telegram Perfect-Order & Restricted Bot Cloner
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
echo "======================================================================"
echo " ✅ BOTS BY SPW — PERFECT-ORDER & RESTRICTED BOT CLONER INSTALLED!"
echo "======================================================================"
echo " • Bot Status : $(systemctl is-active clonebot)"
echo " • SSH Menu   : Type 'clone-bot' anytime in terminal"
echo " • In-Bot Help: Send /start or /bots to your bot on Telegram"
echo "======================================================================"

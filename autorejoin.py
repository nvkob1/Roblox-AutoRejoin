#!/usr/bin/env python3
# autorejoin_server.py
import asyncio
import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import websockets

# ============================================================
# Config file
# ============================================================
CONFIG_PATH = Path.home() / "autorejoin_config.json"

DEFAULT_CONFIG = {
    "host": "0.0.0.0",
    "port": 5242,
    "path": "/AutoRejoin",
    "place_id": 1818,
    "ping_timeout": 20,
    "check_interval": 5,
    "relaunch_cooldown": 30,
    "use_termux_open_url": False,
    "force_stop_first": True,
}


def load_config() -> dict:
    """โหลด config จากไฟล์ ถ้าไม่มีให้ใช้ค่า default"""
    if CONFIG_PATH.exists():
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            # merge กับ default เผื่อมี key ใหม่
            merged = {**DEFAULT_CONFIG, **data}
            return merged
        except Exception as e:
            print(f"⚠️  อ่าน config ไม่ได้: {e}")
    return dict(DEFAULT_CONFIG)


def save_config(cfg: dict):
    """บันทึก config ลงไฟล์"""
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        print(f"💾 บันทึก config ที่ {CONFIG_PATH}")
    except Exception as e:
        print(f"⚠️  บันทึก config ไม่ได้: {e}")


# ============================================================
# Setup wizard
# ============================================================
def ask(prompt: str, default, cast=str):
    """ถามค่าจากผู้ใช้ พร้อมแสดง default"""
    if isinstance(default, bool):
        default_str = "y" if default else "n"
        hint = f"[{'Y' if default else 'y'}/{'N' if not default else 'n'}]"
    else:
        default_str = str(default)
        hint = f"[{default_str}]"

    try:
        raw = input(f"{prompt} {hint}: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(0)

    if raw == "":
        return default

    try:
        if isinstance(default, bool):
            return raw.lower() in ("y", "yes", "1", "true", "t")
        return cast(raw)
    except (ValueError, TypeError):
        print(f"  ⚠️  ค่าไม่ถูกต้อง ใช้ค่า default: {default}")
        return default


def setup_wizard(cfg: dict) -> dict:
    """ถามค่าตั้งต้นจากผู้ใช้"""
    print()
    print("=" * 60)
    print("  🔧 AutoRejoin Server — Setup")
    print("=" * 60)
    print(f"  กด Enter เพื่อใช้ค่า default (ในวงเล็บ)")
    print(f"  ไฟล์ config: {CONFIG_PATH}")
    print("=" * 60)
    print()

    cfg["place_id"] = ask(
        "🎯 Place ID ที่จะปลุก",
        cfg.get("place_id", 1818),
        int,
    )
    cfg["port"] = ask(
        "🔌 Port ของ WebSocket server",
        cfg.get("port", 5242),
        int,
    )
    cfg["ping_timeout"] = ask(
        "⏱️  กี่วินาทีไม่ได้รับ ping ถือว่า Roblox ปิด",
        cfg.get("ping_timeout", 20),
        int,
    )
    cfg["check_interval"] = ask(
        "🔍 ตรวจสอบทุกกี่วินาที",
        cfg.get("check_interval", 5),
        int,
    )
    cfg["relaunch_cooldown"] = ask(
        "⏳ หน่วงก่อนปลุกรอบใหม่ (วินาที)",
        cfg.get("relaunch_cooldown", 30),
        int,
    )
    cfg["force_stop_first"] = ask(
        "💀 สั่ง force-stop Roblox ก่อนเปิดใหม่ไหม (กันเปิดซ้อน)",
        cfg.get("force_stop_first", True),
        bool,
    )
    cfg["use_termux_open_url"] = ask(
        "🔗 ใช้ termux-open-url แทน am start ไหม (ถ้า am ใช้ไม่ได้)",
        cfg.get("use_termux_open_url", False),
        bool,
    )

    print()
    return cfg


# ============================================================
# Logging
# ============================================================
def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
        handlers=[
            logging.StreamHandler(),
            logging.FileHandler(
                Path.home() / "autorejoin.log",
                encoding="utf-8",
            ),
        ],
    )


log = logging.getLogger("autorejoin")


# ============================================================
# Runtime state (โหลดจาก config)
# ============================================================
CFG = {}
clients: dict = {}
last_launch_time = 0.0
launch_in_progress = False
launch_count = 0


# ============================================================
# Helpers
# ============================================================
def any_client_alive() -> bool:
    now = time.time()
    timeout = CFG["ping_timeout"]
    for info in clients.values():
        if now - info["last_ping"] <= timeout:
            return True
    return False


def build_launch_cmd() -> list:
    """สร้างคำสั่งปลุก Roblox ตาม config"""
    place_id = CFG["place_id"]

    if CFG["use_termux_open_url"]:
        base_cmd = ["termux-open-url", f"roblox://placeId={place_id}"]
    else:
        base_cmd = [
            "am", "start",
            "-a", "android.intent.action.VIEW",
            "-d", f"roblox://placeId={place_id}",
        ]

    if CFG["force_stop_first"]:
        # ห่อด้วย sh -c
        inner = (
            f"am force-stop com.roblox.client; "
            f"sleep 1; "
            + " ".join(base_cmd)
        )
        return ["sh", "-c", inner]

    return base_cmd


def launch_roblox():
    global last_launch_time, launch_in_progress, launch_count

    now = time.time()
    if now - last_launch_time < CFG["relaunch_cooldown"]:
        left = CFG["relaunch_cooldown"] - (now - last_launch_time)
        log.info(f"⏳ Cooldown, skip ({left:.0f}s left)")
        return

    launch_in_progress = True
    last_launch_time = now
    launch_count += 1

    cmd = build_launch_cmd()
    log.warning(f"🚀 Launch #{launch_count} → place {CFG['place_id']}")
    log.info(f"   cmd: {' '.join(cmd)}")

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            log.info(f"✅ Launch OK")
            if result.stdout.strip():
                log.info(f"   {result.stdout.strip()}")
        else:
            log.error(f"❌ Launch failed rc={result.returncode}")
            if result.stderr.strip():
                log.error(f"   {result.stderr.strip()}")
    except FileNotFoundError as e:
        log.error(f"❌ Command not found: {e}")
        log.error("   ลองเปิดใช้ termux-open-url ใน config")
    except subprocess.TimeoutExpired:
        log.error("❌ Launch timed out")
    except Exception as e:
        log.exception(f"❌ Launch error: {e}")
    finally:
        launch_in_progress = False


async def wait_for_reconnect(timeout=60) -> bool:
    """รอให้ client เชื่อมต่อกลับหลังปลุก"""
    start = time.time()
    while time.time() - start < timeout:
        if clients and any_client_alive():
            return True
        await asyncio.sleep(1)
    return False


# ============================================================
# Watchdog
# ============================================================
async def watchdog():
    log.info(
        f"👀 Watchdog started "
        f"(timeout={CFG['ping_timeout']}s, interval={CFG['check_interval']}s)"
    )

    while True:
        await asyncio.sleep(CFG["check_interval"])

        if launch_in_progress:
            continue

        # ลบ client ที่ตาย
        now = time.time()
        dead = [
            ws for ws, info in clients.items()
            if now - info["last_ping"] > CFG["ping_timeout"]
        ]
        for ws in dead:
            clients.pop(ws, None)
            log.info(f"   🧹 Removed stale client")

        if clients and not any_client_alive():
            log.warning(f"⚠️  ไม่ได้รับ ping เกิน {CFG['ping_timeout']}s")
            launch_roblox()

            ok = await wait_for_reconnect(timeout=60)
            if ok:
                log.info("✅ Reconnected")
            else:
                log.error("❌ Reconnect timeout — ตรวจสอบด้วยตนเอง")

        elif not clients:
            log.info("💤 No clients — ปลุก Roblox")
            launch_roblox()
            await wait_for_reconnect(timeout=60)


# ============================================================
# Connection handler
# ============================================================
async def handle_client(websocket):
    parsed = urlparse(websocket.request.path)

    if parsed.path != CFG["path"]:
        await websocket.close(1008, "Wrong path")
        return

    params = parse_qs(parsed.query)
    info = {
        "name":       params.get("name",  ["?"])[0],
        "id":         params.get("id",    ["?"])[0],
        "jobId":      params.get("jobId", ["?"])[0],
        "last_ping":  time.time(),
        "ping_count": 0,
    }
    clients[websocket] = info

    log.info(
        f"🟢 Connected: {info['name']} "
        f"(id={info['id']}, job={info['jobId'] or 'N/A'}) "
        f"[total: {len(clients)}]"
    )

    try:
        async for raw in websocket:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue

            cmd = msg.get("Name", "")
            payload = msg.get("Payload") or {}

            if cmd == "ping":
                info["last_ping"] = time.time()
                info["ping_count"] += 1
                await websocket.send(json.dumps({"Name": "pong"}))

                if info["ping_count"] % 30 == 0:
                    log.info(f"   🏓 [{info['name']}] ping #{info['ping_count']}")
                continue

            if cmd == "Log":
                log.info(f"   💬 [{info['name']}] {payload.get('Content', '')}")
                continue

            if cmd == "Echo":
                log.info(f"   🔁 [{info['name']}] {payload.get('Content', '')}")
                continue

    except websockets.ConnectionClosed:
        pass
    finally:
        clients.pop(websocket, None)
        log.info(f"🔴 Disconnected: {info['name']} [total: {len(clients)}]")


# ============================================================
# Main
# ============================================================
async def run_server():
    log.info(f"🚀 AutoRejoin server on ws://{CFG['host']}:{CFG['port']}{CFG['path']}")
    log.info(f"🎯 Target Place ID: {CFG['place_id']}")
    log.info(f"⏱️  ping_timeout={CFG['ping_timeout']}s, check={CFG['check_interval']}s, cooldown={CFG['relaunch_cooldown']}s")

    asyncio.create_task(watchdog())

    async with websockets.serve(
        handle_client,
        CFG["host"],
        CFG["port"],
        ping_interval=None,
        max_size=2 ** 20,
    ):
        await asyncio.Future()


def main():
    global CFG

    setup_logging()

    # --- โหลด config ---
    CFG = load_config()

    # --- ตรวจ argument ---
    args = sys.argv[1:]

    if "--reset" in args or "-r" in args:
        # ลบ config แล้วเริ่มใหม่
        if CONFIG_PATH.exists():
            CONFIG_PATH.unlink()
            print(f"🗑️  ลบ config เก่าแล้ว")
        CFG = dict(DEFAULT_CONFIG)
        CFG = setup_wizard(CFG)
        save_config(CFG)
    elif "--setup" in args or "-s" in args:
        # แก้ config
        CFG = setup_wizard(CFG)
        save_config(CFG)
    elif "--no-setup" in args or "-n" in args:
        # ข้าม setup ใช้ค่าเดิม
        print(f"⚡ ข้าม setup — ใช้ config เดิม")
        print(f"   place_id = {CFG['place_id']}")
    else:
        # ถ้าไม่มี config → setup / ถ้ามีแล้ว → แค่แสดงค่า
        if not CONFIG_PATH.exists():
            print(f"📄 ไม่พบ config — เริ่ม setup ครั้งแรก")
            CFG = setup_wizard(CFG)
            save_config(CFG)
        else:
            print(f"📄 โหลด config จาก {CONFIG_PATH}")
            print(f"   place_id = {CFG['place_id']}  port = {CFG['port']}")
            print(f"   (แก้ด้วย --setup, เริ่มใหม่ด้วย --reset, ข้ามด้วย --no-setup)")

    print()

    try:
        asyncio.run(run_server())
    except KeyboardInterrupt:
        log.info("👋 Shutdown")


if __name__ == "__main__":
    main()

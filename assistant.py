#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LEAH.OS v4.1 - Offline Assistant
Raspberry Pi 3 Model B / Raspbian Stretch / Python 3.5.3

Features:
- Persistent terminal chat
- Local JSON chat history
- Avatar served to the browser from ~/Leah/assets/leah_avatar.png
- System diagnostics
- Read-only (passive) network diagnostics
- Network device baseline
- Notes and tasks
- Local iPhone / browser web interface
- Browser speech output
- No LLM connected yet

SECURITY NOTICE
---------------
The web interface has NO AUTHENTICATION. It listens on all network
interfaces (0.0.0.0) so that a phone on the same network can reach it.
Only run LEAH.OS on a trusted local network. Never expose port 8080 to the
public internet (no port forwarding, no public hosting).

Python 3.5 compatibility: no f-strings, standard library only.
"""

import io
import os
import sys
import json
import socket
import threading
import subprocess
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

try:
    # Gives the terminal prompt working line editing and history.
    import readline  # noqa: F401
    HAVE_READLINE = True
except ImportError:
    HAVE_READLINE = False

# ============================================================
# CONFIGURATION
# ============================================================

HOME = os.path.expanduser("~")
LEAH_DIR = os.path.join(HOME, "Leah")
DATA_DIR = os.path.join(LEAH_DIR, "data")
ASSET_DIR = os.path.join(LEAH_DIR, "assets")

CHAT_FILE = os.path.join(DATA_DIR, "chat.json")
NOTES_FILE = os.path.join(DATA_DIR, "notes.json")
TASKS_FILE = os.path.join(DATA_DIR, "tasks.json")
BASELINE_FILE = os.path.join(DATA_DIR, "network_baseline.json")
AVATAR_FILE = os.path.join(ASSET_DIR, "leah_avatar.png")

WEB_HOST = "0.0.0.0"
WEB_PORT = 8080
VERSION = "4.1"

# The ONLY static file the web server will ever serve.
AVATAR_ROUTE = "/assets/leah_avatar.png"
MAX_BODY_BYTES = 4096                   # largest accepted chat request body
MAX_AVATAR_BYTES = 5 * 1024 * 1024      # refuse to load absurdly large images
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

PURPLE = "\033[38;5;135m"
CYAN = "\033[38;5;45m"
GREEN = "\033[38;5;46m"
YELLOW = "\033[38;5;220m"
RED = "\033[38;5;196m"
WHITE = "\033[97m"
RESET = "\033[0m"

os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(ASSET_DIR, exist_ok=True)

# Only print the heart symbol if the terminal can display it.
_ENCODING = (getattr(sys.stdout, "encoding", None) or "").lower()
HEART = u"\u2661" if _ENCODING.replace("-", "") == "utf8" else "<3"

# \001 and \002 tell readline that the colour codes take no screen width.
if HAVE_READLINE and sys.stdin.isatty():
    PROMPT = "\001" + CYAN + "\002you > \001" + RESET + "\002"
else:
    PROMPT = CYAN + "you > " + RESET

# Chat history is written by both the terminal and the web threads.
STORAGE_LOCK = threading.Lock()


# ============================================================
# STORAGE
# ============================================================

def load_json(path, default):
    """Load JSON from path. Return default if missing, unreadable,
    malformed, or of a different type than default."""
    try:
        with io.open(path, "r", encoding="utf-8") as file:
            data = json.load(file)
    except (IOError, OSError, ValueError):
        return default
    if default is not None and not isinstance(data, type(default)):
        return default
    return data


def save_json(path, data):
    temporary = path + ".tmp"
    with io.open(temporary, "w", encoding="utf-8") as file:
        file.write(json.dumps(data, indent=2))
    os.replace(temporary, path)


def timestamp():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def save_message(role, message):
    with STORAGE_LOCK:
        history = load_json(CHAT_FILE, [])
        history.append({
            "time": timestamp(),
            "role": role,
            "message": message
        })
        # Keep the most recent 200 messages.
        history = history[-200:]
        save_json(CHAT_FILE, history)


# ============================================================
# SYSTEM INFORMATION
# ============================================================

def run_command(command):
    try:
        result = subprocess.check_output(
            command,
            stderr=subprocess.STDOUT
        )
        return result.decode("utf-8", errors="replace").strip()
    except Exception:
        return "Unavailable"


def read_temperature():
    """Raspberry Pi temperature via vcgencmd, falling back to sysfs."""
    value = run_command(["vcgencmd", "measure_temp"])
    if value != "Unavailable":
        return value
    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r") as file:
            millidegrees = int(file.read().strip())
        return "temp={0:.1f}'C".format(millidegrees / 1000.0)
    except (IOError, OSError, ValueError):
        return "Unavailable"


def system_status():
    return {
        "hostname": socket.gethostname(),
        "architecture": run_command(["uname", "-m"]),
        "os": run_command(["uname", "-r"]),
        "uptime": run_command(["uptime", "-p"]),
        "memory": run_command(["free", "-h"]),
        "storage": run_command(["df", "-h", "/"]),
        "temperature": read_temperature()
    }


def display_status():
    status = system_status()
    print(PURPLE + "\n========== LEAH SYSTEM STATUS ==========" + RESET)
    for key, value in status.items():
        print(CYAN + key.upper() + RESET)
        print(value)
        print()
    print(PURPLE + "========================================" + RESET)


# ============================================================
# NETWORK SENTINEL (passive / read-only)
# ============================================================

def get_gateway():
    """
    Read the default gateway from /proc/net/route.
    """
    try:
        with open("/proc/net/route", "r") as file:
            lines = file.readlines()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 4 and parts[1] == "00000000":
                gateway_hex = parts[2]
                gateway = socket.inet_ntoa(
                    bytes.fromhex(gateway_hex)[::-1]
                )
                return gateway
    except Exception:
        pass
    return "Unknown"


def get_dns_servers():
    servers = []
    try:
        with open("/etc/resolv.conf", "r") as file:
            for line in file:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "nameserver":
                    servers.append(parts[1])
    except IOError:
        pass
    return servers


def get_arp_devices():
    """
    Read the kernel ARP table.
    This does not actively scan other networks.
    """
    devices = []
    try:
        with open("/proc/net/arp", "r") as file:
            lines = file.readlines()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 6:
                devices.append({
                    "ip": parts[0],
                    "mac": parts[3],
                    "interface": parts[5]
                })
    except IOError:
        pass
    return devices


def network_snapshot():
    return {
        "time": timestamp(),
        "gateway": get_gateway(),
        "dns": get_dns_servers(),
        "devices": get_arp_devices()
    }


def _mac_set(devices):
    macs = set()
    for item in devices:
        if not isinstance(item, dict):
            continue
        mac = item.get("mac")
        if mac and mac != "00:00:00:00:00:00":
            macs.add(mac)
    return macs


def sentinel_scan():
    print(PURPLE + "\n========== LEAH SENTINEL ==========" + RESET)

    current = network_snapshot()

    print(CYAN + "Default gateway:" + RESET, current["gateway"])

    print(CYAN + "\nDNS servers:" + RESET)
    if current["dns"]:
        for server in current["dns"]:
            print("  " + server)
    else:
        print("  No DNS servers found.")

    print(CYAN + "\nDevices in local ARP table:" + RESET)
    if current["devices"]:
        for device in current["devices"]:
            print(
                "  {0} | {1} | {2}".format(
                    device["ip"],
                    device["mac"],
                    device["interface"]
                )
            )
    else:
        print("  No devices currently recorded.")

    baseline = load_json(BASELINE_FILE, None)
    if not isinstance(baseline, dict):
        baseline = None

    if baseline is None:
        print(YELLOW + "\nNo network baseline exists." + RESET)
        print("Use 'baseline' after checking your own network.")
    else:
        print(CYAN + "\nBaseline comparison:" + RESET)

        if current["gateway"] != baseline.get("gateway"):
            print(RED + "[WARNING] Gateway has changed." + RESET)
        else:
            print(GREEN + "[OK] Gateway unchanged." + RESET)

        if current["dns"] != baseline.get("dns"):
            print(RED + "[WARNING] DNS configuration has changed." + RESET)
        else:
            print(GREEN + "[OK] DNS configuration unchanged." + RESET)

        old_macs = _mac_set(baseline.get("devices", []))
        new_macs = _mac_set(current["devices"])

        for mac in new_macs - old_macs:
            print(YELLOW + "[NEW DEVICE] " + mac + RESET)

        for mac in old_macs - new_macs:
            print(YELLOW + "[DEVICE NOT CURRENTLY SEEN] " + mac + RESET)

    print(PURPLE + "\n===================================" + RESET)
    print(
        YELLOW +
        "Note: These are indicators, not proof of network compromise."
        + RESET
    )


def save_network_baseline():
    current = network_snapshot()
    save_json(BASELINE_FILE, current)
    print(GREEN + "\nNetwork baseline saved." + RESET)
    print("Only use this after verifying your own network devices.")


# ============================================================
# NOTES AND TASKS
# ============================================================

def add_note(note):
    notes = load_json(NOTES_FILE, [])
    notes.append({
        "time": timestamp(),
        "note": note
    })
    save_json(NOTES_FILE, notes)
    print(GREEN + "Note saved." + RESET)


def show_notes():
    notes = load_json(NOTES_FILE, [])
    print(PURPLE + "\n========== NOTES ==========" + RESET)
    if not notes:
        print("No notes saved.")
        return
    for index, note in enumerate(notes, 1):
        print(
            "{0}. [{1}] {2}".format(
                index, note["time"], note["note"]
            )
        )


def add_task(task):
    tasks = load_json(TASKS_FILE, [])
    tasks.append({
        "task": task,
        "created": timestamp(),
        "completed": False
    })
    save_json(TASKS_FILE, tasks)
    print(GREEN + "Task added." + RESET)


def show_tasks():
    tasks = load_json(TASKS_FILE, [])
    print(PURPLE + "\n========== TASKS ==========" + RESET)
    if not tasks:
        print("No tasks.")
        return
    for index, task in enumerate(tasks, 1):
        state = "DONE" if task["completed"] else "PENDING"
        print(
            "{0}. [{1}] {2}".format(
                index, state, task["task"]
            )
        )


def complete_task(number):
    tasks = load_json(TASKS_FILE, [])
    if number < 1 or number > len(tasks):
        print("Invalid task number.")
        return
    tasks[number - 1]["completed"] = True
    save_json(TASKS_FILE, tasks)
    print(GREEN + "Task completed." + RESET)


# ============================================================
# RESPONSE ENGINE - DEMO MODE
# ============================================================

def ask_leah(prompt):
    text = prompt.lower().strip()

    if text in ["hello", "hi", "hey", "hello leah"]:
        return "Hello, operator. LEAH is online. How can I help?"

    if "creator" in text or "who made you" in text:
        return "My creator is DezTheJackal."

    if "time" in text:
        return "The current local time is " + datetime.now().strftime("%H:%M:%S")

    if "date" in text:
        return "Today's date is " + datetime.now().strftime("%d %B %Y")

    if "network" in text or "sentinel" in text:
        return "You can use the sentinel command to inspect your local network."

    if "status" in text or "diagnostic" in text:
        return "Use the status command for Raspberry Pi diagnostics."

    if "help" in text:
        return "Use the help command to see my available functions."

    return (
        "I received your message: '{0}'. "
        "My current response engine is in demonstration mode. "
        "My local LLM has not been connected yet."
    ).format(prompt)


# ============================================================
# IPHONE / BROWSER WEB INTERFACE
# ============================================================

HTML_PAGE = r"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LEAH.OS</title>
<style>
* { box-sizing: border-box; }
body {
    background: #080510;
    color: #eee;
    font-family: Arial, sans-serif;
    margin: 0;
    padding: 18px;
}
.wrap {
    max-width: 760px;
    margin: 0 auto;
}
.hero {
    display: flex;
    align-items: center;
    margin-bottom: 16px;
}
.avatar-wrap {
    position: relative;
    width: 140px;
    height: 140px;
    flex: 0 0 140px;
    margin-right: 16px;
    border-radius: 50%;
    border: 2px solid #8e42d9;
    background: #120b20;
    box-shadow: 0 0 22px rgba(142, 66, 217, 0.65);
    overflow: hidden;
}
.avatar {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
}
.avatar-wrap.missing::after {
    content: "L";
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    line-height: 136px;
    text-align: center;
    font-size: 64px;
    color: #bd72ff;
}
h1 { color: #bd72ff; margin: 0 0 6px 0; }
.panel {
    border: 1px solid #8e42d9;
    border-radius: 14px;
    padding: 14px;
    margin-bottom: 14px;
    background: #120b20;
}
.panel p { margin: 6px 0 0 0; }
#chat {
    height: 45vh;
    min-height: 220px;
    overflow-y: auto;
}
.message {
    padding: 12px;
    border-radius: 10px;
    margin: 10px 0;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
}
.leah {
    background: #28133e;
    border: 1px solid #9b54df;
}
.user {
    background: #102747;
    border: 1px solid #347bc4;
    text-align: right;
}
.row { display: flex; align-items: center; }
input {
    flex: 1;
    min-width: 0;
    font-size: 16px;
    padding: 13px;
    background: #080510;
    color: white;
    border: 1px solid #9b54df;
    border-radius: 8px;
}
button {
    background: #8e42d9;
    color: white;
    border: 0;
    border-radius: 8px;
    padding: 13px;
    margin: 3px;
    font-size: 15px;
}
small { color: #a98bc8; }
@media (max-width: 480px) {
    body { padding: 12px; }
    .avatar-wrap {
        width: 112px;
        height: 112px;
        flex-basis: 112px;
        margin-right: 12px;
    }
    .avatar-wrap.missing::after { line-height: 108px; font-size: 52px; }
    h1 { font-size: 24px; }
}
</style>
</head>
<body>
<div class="wrap">

<div class="hero">
    <div class="avatar-wrap">
        <img class="avatar" src="/assets/leah_avatar.png" alt="LEAH avatar"
             onerror="this.style.display='none';this.parentNode.className+=' missing';">
    </div>
    <div>
        <h1>LEAH.OS &#9825;</h1>
        <small>Personal assistant // Raspberry Pi local node</small>
    </div>
</div>

<div class="panel">
    <strong>Local connection</strong>
    <p>Connected to your LEAH assistant.</p>
</div>

<div class="panel" id="chat">
    <div class="message leah">
        Hello! I'm LEAH. I'm ready to help.
    </div>
</div>

<div class="panel">
    <div class="row">
        <input id="message" placeholder="Talk to LEAH...">
        <button onclick="sendMessage()">Send</button>
        <button onclick="speakLast()">Listen</button>
    </div>
</div>

<div class="panel">
    <button onclick="quickCommand('status')">System status</button>
    <button onclick="quickCommand('sentinel')">Network check</button>
    <button onclick="quickCommand('help')">Help</button>
</div>

</div>

<script>
var lastReply = "";

function addMessage(text, cls) {
    var chat = document.getElementById("chat");
    var item = document.createElement("div");
    item.className = "message " + cls;
    item.textContent = text;
    chat.appendChild(item);
    chat.scrollTop = chat.scrollHeight;
}

function sendMessage() {
    var input = document.getElementById("message");
    var text = input.value.trim();
    if (!text) return;
    input.value = "";
    addMessage(text, "user");

    fetch("/chat", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({message: text})
    })
    .then(function(response) { return response.json(); })
    .then(function(data) {
        lastReply = data.reply || "";
        addMessage(lastReply, "leah");
    })
    .catch(function() {
        addMessage("Could not connect to LEAH.", "leah");
    });
}

function quickCommand(command) {
    document.getElementById("message").value = command;
    sendMessage();
}

function speakLast() {
    if (!lastReply || !window.speechSynthesis) return;
    window.speechSynthesis.cancel();
    var utterance = new SpeechSynthesisUtterance(lastReply);
    utterance.lang = "en-US";
    window.speechSynthesis.speak(utterance);
}

document.getElementById("message").addEventListener(
    "keydown", function(event) {
        if (event.key === "Enter") sendMessage();
    }
);
</script>
</body>
</html>
"""


def read_avatar():
    """Return the avatar PNG bytes, or None if it is missing or invalid."""
    try:
        if os.path.getsize(AVATAR_FILE) > MAX_AVATAR_BYTES:
            return None
        with open(AVATAR_FILE, "rb") as file:
            data = file.read(MAX_AVATAR_BYTES + 1)
    except (IOError, OSError):
        return None
    if len(data) > MAX_AVATAR_BYTES:
        return None
    if not data.startswith(PNG_SIGNATURE):
        return None
    return data


class LeahWebHandler(BaseHTTPRequestHandler):

    # Drop clients that connect and then stall (seconds).
    timeout = 15
    server_version = "LEAHOS/" + VERSION
    sys_version = ""

    def log_message(self, format_string, *args):
        # Keep routine HTTP requests out of the terminal.
        pass

    def send_binary(self, code, body, content_type, extra_headers=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        if extra_headers:
            for name, value in extra_headers:
                self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def send_response_data(self, code, content, content_type):
        self.send_binary(code, content.encode("utf-8"), content_type)

    def send_json(self, code, reply):
        self.send_response_data(
            code,
            json.dumps({"reply": reply}),
            "application/json; charset=utf-8"
        )

    def do_GET(self):
        # Ignore any query string (e.g. /assets/leah_avatar.png?v=2).
        path = self.path.split("?", 1)[0].split("#", 1)[0]

        if path == "/":
            self.send_response_data(
                200, HTML_PAGE, "text/html; charset=utf-8"
            )
        elif path == AVATAR_ROUTE:
            # Exact match only: the file location is fixed in AVATAR_FILE
            # and nothing from the request is ever used to build a path.
            data = read_avatar()
            if data is None:
                self.send_response_data(
                    404, "Avatar not found", "text/plain; charset=utf-8"
                )
            else:
                self.send_binary(
                    200, data, "image/png",
                    [("Cache-Control", "max-age=60")]
                )
        else:
            self.send_response_data(
                404, "Not found", "text/plain; charset=utf-8"
            )

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/chat":
            self.send_response_data(
                404, "Not found", "text/plain; charset=utf-8"
            )
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(400, "Invalid request.")
            return

        if length < 0:
            self.send_json(400, "Invalid request.")
            return

        if length > MAX_BODY_BYTES:
            self.send_json(413, "Message too large.")
            return

        try:
            body = self.rfile.read(length).decode("utf-8")
            data = json.loads(body)
        except ValueError:
            # Covers bad UTF-8 and malformed JSON.
            self.send_json(400, "Invalid request.")
            return

        message = ""
        if isinstance(data, dict):
            candidate = data.get("message", "")
            if isinstance(candidate, str):
                message = candidate.strip()

        try:
            if not message:
                reply = "Please send a message."
            else:
                save_message("user", message)
                reply = ask_leah(message)
                save_message("leah", reply)
        except Exception:
            self.send_json(500, "LEAH could not process that request.")
            return

        self.send_json(200, reply)


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """One short-lived thread per request so a slow client cannot block
    the others. Python 3.5 has no ThreadingHTTPServer, so build it here."""
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Disconnects, timeouts and bad requests are expected noise.
        # Staying silent keeps the terminal prompt clean.
        pass


def start_web_server():
    try:
        server = ThreadedHTTPServer((WEB_HOST, WEB_PORT), LeahWebHandler)
        thread = threading.Thread(
            target=server.serve_forever
        )
        thread.daemon = True
        thread.start()
        return server
    except Exception as error:
        print(RED + "[WEB ERROR] " + str(error) + RESET)
        return None


def get_local_ip():
    try:
        connection = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        connection.connect(("192.0.2.1", 80))
        address = connection.getsockname()[0]
        connection.close()
        return address
    except Exception:
        return "Check your Pi's IP using hostname -I"


# ============================================================
# HELP
# ============================================================

def show_help():
    print(PURPLE + "\n========== LEAH COMMANDS ==========" + RESET)
    commands = [
        ("help", "Show available commands"),
        ("status", "Show Pi system information"),
        ("sentinel", "Inspect your local network"),
        ("baseline", "Save your verified network baseline"),
        ("note <text>", "Save a note"),
        ("notes", "Display saved notes"),
        ("task <text>", "Create a task"),
        ("tasks", "Display tasks"),
        ("done <number>", "Complete a task"),
        ("history", "Display recent chat messages"),
        ("clear", "Clear terminal display"),
        ("web", "Display iPhone connection address"),
        ("exit", "Close LEAH")
    ]
    for command, description in commands:
        print(CYAN + command.ljust(20) + RESET + description)
    print(PURPLE + "===================================" + RESET)


def show_history():
    history = load_json(CHAT_FILE, [])
    print(PURPLE + "\n========== CHAT HISTORY ==========" + RESET)
    for item in history[-20:]:
        print(
            "[{0}] {1}: {2}".format(
                item["time"], item["role"], item["message"]
            )
        )


# ============================================================
# MAIN INTERFACE
# ============================================================

def main():
    print(PURPLE)
    print("==========================================")
    print("   LEAH.OS v" + VERSION)
    print("   PERSONAL ASSISTANT NODE")
    print("==========================================")
    print(RESET)

    print(CYAN + "LEAH neural core: ONLINE" + RESET)

    if os.path.isfile(AVATAR_FILE):
        print(GREEN + "Avatar asset detected." + RESET)
    else:
        print(YELLOW + "Avatar not installed yet." + RESET)
        print("Place your portrait at:")
        print(AVATAR_FILE)

    server = start_web_server()

    if server:
        print(GREEN + "\nLEAH iPhone interface available at:" + RESET)
        print("http://{0}:{1}".format(get_local_ip(), WEB_PORT))
        print(
            YELLOW +
            "WARNING: the web interface has no authentication. "
            "Use it on a trusted local network only." + RESET
        )

    print("\nType 'help' to see commands.")
    print("Your messages will remain visible during the session.\n")

    while True:
        try:
            user_input = input(PROMPT)

            if not user_input.strip():
                continue

            command = user_input.strip()
            lower = command.lower()

            if lower in ["exit", "quit"]:
                print(PURPLE + "LEAH node shutting down." + RESET)
                break

            elif lower == "help":
                show_help()

            elif lower == "status":
                display_status()

            elif lower in ["sentinel", "network"]:
                sentinel_scan()

            elif lower == "baseline":
                save_network_baseline()

            elif lower == "notes":
                show_notes()

            elif lower == "tasks":
                show_tasks()

            elif lower == "history":
                show_history()

            elif lower == "clear":
                os.system("clear")

            elif lower == "web":
                print(
                    "Open http://{0}:{1} on your iPhone.".format(
                        get_local_ip(), WEB_PORT
                    )
                )

            elif lower == "note":
                print("Use: note <text>")

            elif lower == "task":
                print("Use: task <text>")

            elif lower == "done":
                print("Use: done 1")

            elif lower.startswith("note "):
                add_note(command[5:].strip())

            elif lower.startswith("task "):
                add_task(command[5:].strip())

            elif lower.startswith("done "):
                try:
                    complete_task(int(command[5:].strip()))
                except ValueError:
                    print("Use: done 1")

            else:
                save_message("user", command)
                reply = ask_leah(command)
                save_message("leah", reply)

                print("\n" + PURPLE + "LEAH " + HEART + RESET)
                print(reply + "\n")

        except KeyboardInterrupt:
            print("\nUse 'exit' to close LEAH.")

        except EOFError:
            break

        except Exception as error:
            print(RED + "[SYSTEM ERROR] " + str(error) + RESET)

    if server:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()

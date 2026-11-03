#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
LEAH.OS v4.0 - Offline Assistant
Raspberry Pi 3 Model B / Raspbian Stretch

Features:
- Persistent terminal chat
- Local chat history
- Avatar support (optional Pillow)
- System diagnostics
- Read-only network diagnostics
- Network device baseline
- Notes and tasks
- Reminders
- Local iPhone web interface
- Browser speech output
- No LLM connected yet
"""

import os
import sys
import json
import time
import socket
import shutil
import threading
import subprocess
import webbrowser

from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs


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

AVATAR_FILE = os.path.join(ASSET_DIR, "leah_avatar.jpg")

WEB_HOST = "0.0.0.0"
WEB_PORT = 8080

VERSION = "4.0"

PURPLE = "\033[38;5;135m"
CYAN = "\033[38;5;45m"
GREEN = "\033[38;5;46m"
YELLOW = "\033[38;5;220m"
RED = "\033[38;5;196m"
WHITE = "\033[97m"
RESET = "\033[0m"

os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(ASSET_DIR, exist_ok=True)


# ============================================================
# STORAGE
# ============================================================

def load_json(path, default):
    try:
        with open(path, "r") as file:
            return json.load(file)
    except (IOError, ValueError):
        return default


def save_json(path, data):
    temporary = path + ".tmp"

    with open(temporary, "w") as file:
        json.dump(data, file, indent=2)

    os.rename(temporary, path)


def timestamp():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def save_message(role, message):
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

        return result.decode(
            "utf-8", errors="replace"
        ).strip()

    except Exception:
        return "Unavailable"


def system_status():
    return {
        "hostname": socket.gethostname(),
        "architecture": run_command(["uname", "-m"]),
        "os": run_command(["uname", "-r"]),
        "uptime": run_command(["uptime", "-p"]),
        "memory": run_command(["free", "-h"]),
        "storage": run_command(["df", "-h", "/"]),
        "temperature": run_command([
            "bash", "-c",
            "vcgencmd measure_temp"
        ])
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
# NETWORK SENTINEL
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


def sentinel_scan():
    print(PURPLE + "\n========== LEAH SENTINEL ==========" + RESET)

    current = network_snapshot()

    print(CYAN + "Default gateway:" + RESET,
          current["gateway"])

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

    if baseline is None:
        print(YELLOW + "\nNo network baseline exists." + RESET)
        print("Use 'baseline' after checking your own network.")
    else:
        print(CYAN + "\nBaseline comparison:" + RESET)

        if current["gateway"] != baseline["gateway"]:
            print(RED + "[WARNING] Gateway has changed." + RESET)
        else:
            print(GREEN + "[OK] Gateway unchanged." + RESET)

        if current["dns"] != baseline["dns"]:
            print(RED + "[WARNING] DNS configuration has changed." + RESET)
        else:
            print(GREEN + "[OK] DNS configuration unchanged." + RESET)

        old_macs = set(
            item["mac"] for item in baseline["devices"]
            if item["mac"] != "00:00:00:00:00:00"
        )

        new_macs = set(
            item["mac"] for item in current["devices"]
            if item["mac"] != "00:00:00:00:00:00"
        )

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
# IPHONE WEB INTERFACE
# ============================================================

HTML_PAGE = r"""
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta charset="utf-8">
<title>LEAH.OS</title>

<style>
body {
    background: #080510;
    color: #eee;
    font-family: Arial, sans-serif;
    margin: 0;
    padding: 18px;
}
h1 { color: #bd72ff; }
.panel {
    border: 1px solid #8e42d9;
    border-radius: 14px;
    padding: 14px;
    margin-bottom: 14px;
    background: #120b20;
}
#chat {
    height: 55vh;
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
input {
    width: 72%;
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
}
small { color: #a98bc8; }
</style>
</head>

<body>

<h1>LEAH.OS ♡</h1>
<small>Personal assistant // Raspberry Pi local node</small>

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
    <input id="message" placeholder="Talk to LEAH...">
    <button onclick="sendMessage()">Send</button>
    <button onclick="speakLast()">Listen</button>
</div>

<div class="panel">
    <button onclick="quickCommand('status')">System status</button>
    <button onclick="quickCommand('sentinel')">Network check</button>
    <button onclick="quickCommand('help')">Help</button>
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
        lastReply = data.reply;
        addMessage(data.reply, "leah");
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


class LeahWebHandler(BaseHTTPRequestHandler):

    def log_message(self, format_string, *args):
        # Keep routine HTTP requests out of the terminal.
        pass

    def send_response_data(self, code, content, content_type):
        encoded = content.encode("utf-8")

        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/":
            self.send_response_data(
                200, HTML_PAGE, "text/html; charset=utf-8"
            )
        else:
            self.send_response_data(404, "Not found", "text/plain")

    def do_POST(self):
        if self.path != "/chat":
            self.send_response_data(404, "Not found", "text/plain")
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))

            if length > 4096:
                self.send_response_data(413, "Message too large", "text/plain")
                return

            body = self.rfile.read(length).decode("utf-8")
            data = json.loads(body)

            message = data.get("message", "").strip()

            if not message:
                reply = "Please send a message."
            else:
                save_message("user", message)
                reply = ask_leah(message)
                save_message("leah", reply)

            result = json.dumps({"reply": reply})

            self.send_response_data(
                200, result, "application/json; charset=utf-8"
            )

        except Exception:
            self.send_response_data(
                400, '{"reply":"Invalid request."}',
                "application/json"
            )


def start_web_server():
    try:
        server = HTTPServer((WEB_HOST, WEB_PORT), LeahWebHandler)

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
    print("             LEAH.OS v" + VERSION)
    print("        PERSONAL ASSISTANT NODE")
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

    print("\nType 'help' to see commands.")
    print("Your messages will remain visible during the session.\n")

    while True:

        try:
            user_input = input(
                AMBER if False else CYAN
            )

            # The prompt is deliberately kept simple for old terminals.
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

                print("\n" + PURPLE + "LEAH ♡" + RESET)
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

# LEAH.OS

**Local • Offline-First • Personal AI Assistant**

LEAH.OS is an experimental, privacy-first personal assistant that runs on hardware you own. It combines a local assistant interface, productivity tools, passive network monitoring and, as a work in progress, local language-model inference with llama.cpp.

> **Status: experimental / active development.** This is a learning and development project. Features are added and tested incrementally, and the tables below say plainly what works, what is in progress and what is only planned.

## Two installations, one codebase (design)

| Installation | Hardware | Intended role |
|---|---|---|
| **LEAH HOME** | Debian laptop (Intel Core i7-8565U, x86_64, about 12 GB RAM) | Primary AI host and development machine: reasoning, memory, controlled research, home network monitoring, dashboard |
| **LEAH DRIVE** | Raspberry Pi 3 Model B (1 GB RAM, ARMv7) | Lightweight, offline-capable field node: monitoring, event recording, later vehicle-related features |

The goal is a single version-controlled codebase deployed separately to each machine with hardware-specific configuration. The Pi is a limited device and is not expected to run the same model or services as the laptop.

## Current status

| Area | Status |
|---|---|
| Terminal assistant (persistent chat, JSON history, notes, tasks) | Working on the Raspberry Pi |
| System diagnostics (CPU, memory, storage, temperature) | Working on the Raspberry Pi |
| LEAH Sentinel (passive, read-only network observations and baseline comparison) | Working on the Raspberry Pi; indicators only |
| Local web interface for phone browsers, with browser speech output | In progress; no authentication (see Privacy and Security) |
| Avatar display in the web interface | In progress |
| Local AI via llama.cpp (`SmolLM2-360M-Instruct`, GGUF) | Has produced local responses on the Pi through a per-message subprocess; see AI status |
| Persistent inference server, streaming, longer responses | Planned |
| Laptop (LEAH HOME) AI build | Not yet verified |
| Persistent local memory, document retrieval | Planned |
| Controlled internet research gateway | Planned |
| Navigation, voice input and offline speech, vehicle node | Planned |

Nothing marked "Planned" exists yet.

## Features

### Assistant interface
- Persistent terminal conversation
- Local conversation history (JSON)
- Offline demonstration responses for greetings, date and time, help and similar commands

### Productivity
- Personal notes
- Task management and completion
- System diagnostics and Raspberry Pi temperature

### LEAH Sentinel
Designed for networks you own or are authorised to administer. It is **passive and read-only**: it reads the kernel's gateway, DNS and ARP information and compares it with a baseline you save yourself.

- Gateway and DNS changes
- Local ARP device observations
- Baseline comparison and unknown-device indicators

These are security *indicators*, not guarantees that a network is safe or compromised.

### Mobile integration (in progress)
A local web interface for phone browsers over your own network, with browser text-to-speech. Voice input is planned.

## Installation

Clone the repository:

```bash
git clone https://github.com/DezTheJackal/Leah.git
cd Leah
```

Run the installer:

```bash
chmod +x leah_installer.sh
./leah_installer.sh
```

Launch LEAH:

```bash
./run_leah.sh
```

Model files are **not** stored in this repository. Place any GGUF model in `models/` yourself and check the model's own licence before using or redistributing it.

## Project structure

```
Leah/
├── assistant.py
├── leah_installer.sh
├── run_leah.sh
├── requirements.txt
├── assets/
├── data/              (private, git-ignored)
├── models/            (model files, git-ignored)
├── voices/            (git-ignored)
├── llm/
├── docs/
└── tools/
    └── audit/         (read-only audit tooling, see below)
```

## AI status

- The default response engine uses predefined demonstration responses.
- llama.cpp (tag `b4206`) with the SmolLM2-360M-Instruct GGUF model has generated local responses on the Raspberry Pi. The current integration starts a new llama.cpp process for every message and applies a short generation limit, so it is slow and truncates answers.
- Planned improvements: a persistent inference process or server, streaming output, configurable generation limits with safe continuation, and measured performance on both machines.
- A local language model is not yet a supported, tested part of the release.

## Audit tooling (`tools/audit/`)

Three small tools support a safe, repeatable inventory of an installation before larger changes are made.

| File | Purpose |
|---|---|
| `leah_audit.sh` | Read-only audit of a LEAH installation: system, toolchain, git state, file manifest, model and llama.cpp inventory, secret-pattern findings (category and location only), host security posture |
| `leah_compare.py` | Compares audit manifests from the laptop, the Pi and a backup, and optionally a GitHub tree |
| `leah_selftest.sh` | Synthetic test suite that exercises both tools inside a temporary folder |

Usage:

```bash
bash tools/audit/leah_audit.sh                 # offline, nothing executed, nothing fetched
bash tools/audit/leah_audit.sh --hash-models   # also hash model files (slow on a Pi)
bash tools/audit/leah_audit.sh --remote        # optional: ask the remote for main's current hash
bash tools/audit/leah_audit.sh --probe         # optional: runs llama.cpp (uses CPU and memory)

python3 tools/audit/leah_compare.py laptop=<dir>/manifest_repo.tsv pi=<dir>/manifest_repo.tsv

bash tools/audit/leah_selftest.sh              # isolated; never touches your real files
```

What the audit is designed to do:
- Create one new report folder in your home directory and never overwrite an existing one.
- Avoid modifying the repository, backup, git state or system configuration. It uses only plain read-only git commands and never runs `git status`, `fetch`, `pull`, `push` or `commit`.
- Run binaries only with `--probe`, and use the network only with `--remote`.
- Redact credentials, tokens, process arguments and home paths from the report. Secret scanning is heuristic and can miss things, so review a report before sharing it.

What has and has not been tested: the self-test passes on Debian-family Linux with Python 3.12, bash 5.2 and git 2.43. Python 3.5 and 3.7 are checked for syntax only, and Raspberry Pi OS Buster has not been run yet. Manifests and report folders contain file and host names, so do not publish them.

## Development roadmap

1. Complete the audit of both installations and reconcile differences.
2. Persistent llama.cpp inference with streaming and complete responses (laptop first, lightweight profile for the Pi).
3. Local conversation memory and document retrieval.
4. Permission manager, audit logging and application hardening (including authentication for the web interface).
5. Controlled, allow-listed internet research gateway.
6. Expanded Sentinel: device inventory, cached scans, alerts.
7. Vehicle node: offline event recording and secure laptop-to-Pi synchronisation.
8. Counter-surveillance awareness (detection and inspection support only).
9. Offline navigation.
10. Offline voice input and speech output.

## Privacy and security

LEAH.OS is built local-first.

- Personal notes, chat history and network baselines stay on your machines. They are git-ignored; do not publish them.
- **The experimental web interface has no authentication.** Use it only on a trusted local network and never expose it to the public internet (no port forwarding, no public hosting).
- Network monitoring is for networks you own or are authorised to administer. LEAH does not attack, exploit, jam or disrupt anything.
- Do not commit credentials, private keys, logs, model files or personal data. Review `.gitignore` before staging files.
- Internet access for the AI is planned to be off by default and routed through a controlled gateway.

## Contributing and reporting issues

This is an early personal project. Please open an issue for bugs or ideas. Do not post private logs, network baselines or credentials in issues.

## Licence

Apache-2.0. See [LICENSE](LICENSE).

---

Created and developed by **DezTheJackal**.

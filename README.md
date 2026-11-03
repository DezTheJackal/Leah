# LEAH.OS

**Local • Offline-First • Personal AI Assistant**

LEAH.OS is an experimental personal assistant project designed to run on low-cost hardware, initially targeting the Raspberry Pi 3 Model B.

The project aims to combine a local assistant interface, voice interaction, personal productivity tools and network security monitoring.

## Current Hardware

- Raspberry Pi 3 Model B Rev 1.2
- 1 GB RAM
- Raspbian GNU/Linux 9 (Stretch)
- Python 3

## Features

### Assistant Interface
- Persistent terminal conversation
- Local conversation history
- Avatar support
- Basic offline demonstration responses

### Productivity
- Personal notes
- Task management
- System diagnostics
- Date and time queries

### LEAH Sentinel
Designed for monitoring networks owned or administered by the user.

Planned checks include:
- Local ARP device observations
- Gateway changes
- DNS configuration changes
- Network baseline comparisons
- Unknown device indicators

These checks provide security indicators, not guarantees that a network is safe.

### Mobile Integration
A local web interface is being developed for iPhone access through Safari.

Planned capabilities:
- Mobile messaging
- Browser speech output
- Voice input
- Local network connectivity

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

## Project Structure

```text
Leah/
├── assistant.py
├── leah_installer.sh
├── run_leah.sh
├── requirements.txt
├── assets/
├── data/
├── models/
├── voices/
└── docs/
```

## Development Roadmap

1. Stabilise the terminal assistant.
2. Improve the avatar and cyberpunk interface.
3. Implement persistent conversation history.
4. Complete iPhone voice integration.
5. Expand LEAH Sentinel network monitoring.
6. Add local language-model inference.
7. Improve offline operation and resource efficiency.

## AI Status

The current response engine uses predefined demonstration responses.

A local language model has not yet been integrated.

The long-term objective is to support local inference using llama.cpp and a suitably lightweight GGUF model.

## Privacy and Security

LEAH.OS is designed with local-first operation in mind.

- Personal notes and chat history should remain local.
- Do not publish private network baselines.
- Do not expose the experimental mobile web interface to the public internet.
- Network monitoring should only be performed on networks you own or are authorised to administer.

## Project Status

**Experimental / Active Development**

LEAH.OS is a learning and development project. Features are being implemented and tested incrementally.

---

Created and developed by **DezTheJackal**.

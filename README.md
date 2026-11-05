# LEAH.OS

**Local • Offline-First • Personal AI Assistant**

LEAH.OS is an experimental personal AI assistant project focused on local AI processing, privacy, and practical digital security.

Initially developed for low-cost hardware, LEAH aims to bring together personal AI assistance, productivity tools, voice interaction, and defensive security monitoring in one locally operated environment.

The project is built around a simple principle: **your assistant, your hardware, your data.**

## Current Platform

The initial development platform is the Raspberry Pi 3 Model B.

- Raspberry Pi 3 Model B Rev 1.2
- 1 GB RAM
- Raspberry Pi OS (original development environment: Raspbian GNU/Linux 9)
- Python 3
- Integrated local language model using llama.cpp

Hardware and software configurations may change as development progresses.

## Current Features

### Local AI Assistant
- Integrated local language model.
- Local model inference.
- Terminal-based assistant interface.
- Basic conversational interaction.
- Offline operation for supported functionality.

### Assistant Interface
- Persistent terminal conversation.
- Local conversation history.
- Avatar support.
- Basic offline demonstration responses.

### Productivity
- Personal notes.
- Task management.
- System diagnostics.
- Date and time queries.

### LEAH Sentinel

A developing defensive security component intended to provide visibility into networks owned or administered by the user.

Planned monitoring capabilities include:
- Local network device observations.
- Gateway and DNS configuration changes.
- Network baseline comparisons.
- Indicators of unfamiliar devices.
- Basic network security awareness.

Sentinel is intended as a monitoring and awareness tool, not a guarantee of network security.

### Mobile Integration

A local web interface is being developed to make LEAH accessible from mobile devices.

Planned capabilities include:
- Mobile messaging.
- Browser-based voice interaction.
- Local network access.
- Improved assistant accessibility.

## Development Roadmap

LEAH is under active development, with work progressing across several areas:

- **Local AI:** Improving the assistant's capabilities and inference experience.
- **Memory & Privacy:** Developing locally managed memory and information retrieval.
- **Security Monitoring:** Expanding defensive monitoring and awareness features.
- **Multi-Device Support:** Exploring dedicated home and mobile/field environments.
- **Voice & Interaction:** Developing more natural interaction methods.
- **Reliability & Hardening:** Improving stability, security and system performance.

Development is incremental, with privacy, reliability and user control taking priority over rapid feature expansion.

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

Installation requirements and compatibility may vary depending on the hardware and operating system.

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

## Project Status

<text>LEAH.OS is an experimental project under active development. Existing functionality and planned features are not necessarily production-ready.</text>

Features, hardware support and system architecture may evolve as development continues.

## Development Philosophy

LEAH is being developed with an emphasis on:

- Local-first processing.
- User privacy and data ownership.
- Offline-capable functionality.
- Responsible security monitoring.
- Affordable and accessible hardware.
- Incremental testing and improvement.

## License

See the repository's [LICENSE](LICENSE) file for licensing information.

---

Created and developed by **DezTheJackal**.

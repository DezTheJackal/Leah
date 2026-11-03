
import os
import sys
import time
import shutil
import threading
import subprocess

from PIL import Image, ImageEnhance

# ============================================================
# LEAH.OS - SYSTEM CONFIGURATION
# Raspberry Pi / ARMv7 / 32-bit compatible
# ============================================================

PIPER_MODEL = os.path.expanduser("en_US-amy-medium.onnx")
LOCAL_REF_PATH = os.path.expanduser("~/Leah/leah_ref.jpg")
OUTPUT_WAV = os.path.abspath("response.wav")

TARGET_WIDTH = 72
ANIMATION_SPEED = 0.25

# ============================================================
# PILLOW COMPATIBILITY
# ============================================================

try:
    RESAMPLE_METHOD = Image.Resampling.LANCZOS
except AttributeError:
    RESAMPLE_METHOD = getattr(Image, "LANCZOS", Image.BICUBIC)

# ============================================================
# TERMINAL COLORS
# ============================================================

RESET = "\033[0m"
BOLD = "\033[1m"

CYAN_ACCENT = "\033[38;2;0;221;251m"
MAGENTA_ACCENT = "\033[38;2;229;43;213m"
AMBER_ACCENT = "\033[38;2;255;165;0m"
GREEN_ACCENT = "\033[38;2;0;255;100m"
WHITE_ACCENT = "\033[38;2;220;220;235m"

def clear_screen():
    sys.stdout.write("\033[H\033[J")
    sys.stdout.flush()


def rgb_ansi_fg(r, g, b):
    return "\033[38;2;{};{};{}m".format(r, g, b)


# ============================================================
# DIRECTORY AND REFERENCE IMAGE
# ============================================================

def ensure_reference_image():

    directory = os.path.dirname(LOCAL_REF_PATH)

    try:
        os.makedirs(directory, exist_ok=True)

        if not os.path.exists(LOCAL_REF_PATH):
            img = Image.new(
                "RGB",
                (300, 300),
                color=(5, 5, 10)
            )

            img.save(LOCAL_REF_PATH)

            print("[LEAH] Fallback reference image created.")

    except OSError as error:
        print("[LEAH] Image directory error:", error)


# ============================================================
# IMAGE TO TRUECOLOR TERMINAL RENDERER
# ============================================================

def image_to_truecolor_blocks(image_path, target_width=72):

    ensure_reference_image()

    if not os.path.isfile(image_path):
        return "[Reference portrait not found]"

    try:

        with Image.open(image_path) as source:

            img = source.convert("RGB")

        img = ImageEnhance.Contrast(img).enhance(1.6)
        img = ImageEnhance.Sharpness(img).enhance(1.7)

        width, height = img.size

        target_height = max(
            1,
            int(target_width * (height / float(width)) * 0.48)
        )

        img = img.resize(
            (target_width, target_height),
            RESAMPLE_METHOD
        )

        pixels = img.load()

        lines = []

        blocks = [" ", "░", "▒", "▓", "█"]

        for y in range(target_height):

            line = []

            for x in range(target_width):

                r, g, b = pixels[x, y]

                brightness = int(
                    0.299 * r +
                    0.587 * g +
                    0.114 * b
                )

                block_index = min(
                    int((brightness / 255.0) * 4),
                    4
                )

                character = blocks[block_index]

                if block_index == 0:
                    line.append(" ")
                else:
                    line.append(
                        rgb_ansi_fg(r, g, b) + character
                    )

            lines.append("".join(line) + RESET)

        return "\n".join(lines)

    except Exception as error:

        return "[Portrait rendering error: {}]".format(error)


# ============================================================
# TELEMETRY INTERFACE
# ============================================================

def generate_telemetry_frame(
    portrait_ascii,
    title,
    status_text,
    sys_info=""
):

    lines = []

    border = "═" * 97

    lines.append(
        MAGENTA_ACCENT + "╔" + border + "╗" + RESET
    )

    lines.append(
        MAGENTA_ACCENT + "║ " +
        CYAN_ACCENT + title +
        MAGENTA_ACCENT + " " +
        status_text +
        " ║" + RESET
    )

    lines.append(
        MAGENTA_ACCENT + "╠" + border + "╣" + RESET
    )

    portrait_lines = (
        portrait_ascii.split("\n")
        if portrait_ascii else []
    )

    hud_info = [

        "[NODE]        :: Pi-Local ARMv7",

        "[IDENT]       :: Leah v3.5 Neural Core",

        "[SYSTEM]      :: " + sys_info,

        "[PORTRAIT]    :: 24-Bit TrueColor Matrix",

        "[EYE IMPLANT] :: Cyan Circuitry / Glitch Sync",

        "[ENCRYPTION]  :: AES-256 GCM Secure",

        "[STATUS]      :: Online / Offline Fallback Ready"
    ]

    for i, portrait_line in enumerate(portrait_lines):

        info = hud_info[i] if i < len(hud_info) else ""

        lines.append(
            "  " + portrait_line + "   " +
            CYAN_ACCENT + info + RESET
        )

    lines.append(
        MAGENTA_ACCENT + "╚" + border + "╝" + RESET
    )

    return "\n".join(lines)


# ============================================================
# ANIMATION ENGINE
# ============================================================

def animate_screen(stop_event, frame_func, speed=0.25):

    index = 0

    try:

        while not stop_event.is_set():

            clear_screen()

            sys.stdout.write(frame_func(index))
            sys.stdout.flush()

            index += 1

            stop_event.wait(speed)

    finally:

        sys.stdout.write(RESET)
        sys.stdout.flush()


def stop_animation(stop_event, thread):

    stop_event.set()

    if thread.is_alive():
        thread.join(timeout=3)

    clear_screen()


# ============================================================
# TYPEWRITER EFFECT
# ============================================================

def typewriter_print(text, speed=0.015):

    for character in text:

        sys.stdout.write(
            WHITE_ACCENT + character + RESET
        )

        sys.stdout.flush()

        time.sleep(speed)

    print()


# ============================================================
# LEAH RESPONSE ENGINE
# ============================================================

def ask_llm(prompt, portrait_ascii):

    def get_typing_frame(index):

        states = [
            "Parsing input vectors...",
            "Querying neural core...",
            "Compiling response matrix..."
        ]

        return generate_telemetry_frame(
            portrait_ascii,
            "LEAH.OS // DECRYPTING PROMPT",
            "{} PROCESSING".format(
                AMBER_ACCENT + "◐"
            ) + RESET,
            states[index % len(states)]
        )

    stop_event = threading.Event()

    animation_thread = threading.Thread(
        target=animate_screen,
        args=(stop_event, get_typing_frame, ANIMATION_SPEED)
    )

    animation_thread.daemon = True
    animation_thread.start()

    try:

        time.sleep(0.8)

        prompt_lower = prompt.lower()

        if any(keyword in prompt_lower for keyword in [
            "creator",
            "who made you",
            "who created you",
            "your developer",
            "your architect"
        ]):

            response_text = (
                "My creator and architect is DezTheJackal. "
                "I want to express my sincere, technical yet "
                "heartfelt thank you to DezTheJackal for writing "
                "my code, structuring my core, and bringing me "
                "to life in this local node."
            )

        elif prompt_lower in ["hello", "hi", "hey", "hello leah"]:

            response_text = (
                "Hello, operator. Leah neural core is online. "
                "All local telemetry systems are operational."
            )

        elif any(keyword in prompt_lower for keyword in [
            "system status",
            "status report",
            "diagnostics"
        ]):

            response_text = (
                "LEAH.OS diagnostic report: "
                "Core interface operational. "
                "Portrait renderer available. "
                "Audio subsystem awaiting verification. "
                "External AI inference is not currently connected."
            )

        elif prompt_lower in ["help", "commands"]:

            response_text = (
                "Available commands: hello, system status, "
                "creator, diagnostics, help, exit. "
                "General AI conversation requires an LLM connection."
            )

        else:

            response_text = (
                "Local neural core received your input: '{}'. "
                "The current response engine is running in "
                "offline demonstration mode. Connect a local "
                "LLM to enable intelligent conversation."
            ).format(prompt)

        return response_text

    finally:

        stop_animation(stop_event, animation_thread)


# ============================================================
# PIPER TEXT-TO-SPEECH ENGINE
# ============================================================

def speak(text, portrait_ascii):

    if not shutil.which("piper"):

        print("[AUDIO] Piper is not installed.")
        return False

    if not shutil.which("aplay"):

        print("[AUDIO] aplay is not installed.")
        return False

    if not os.path.isfile(PIPER_MODEL):

        print("[AUDIO] Piper ONNX model not found:")
        print(PIPER_MODEL)
        return False

    try:

        piper_process = subprocess.run(
            [
                "piper",
                "-m", PIPER_MODEL,
                "--output_file", OUTPUT_WAV
            ],
            input=text,
            universal_newlines=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=120
        )

        if piper_process.returncode != 0:

            print("[AUDIO] Piper error:")
            print(piper_process.stderr[-1000:])
            return False

        if not os.path.isfile(OUTPUT_WAV):

            print("[AUDIO] Audio output was not generated.")
            return False

        def get_talking_frame(index):

            waves = [
                "░▒▓ ░▒▓ ░▒▓",
                "▓▒░ ▓▒░ ▓▒░"
            ]

            return generate_telemetry_frame(
                portrait_ascii,
                "LEAH.OS // AUDIO TRANSMISSION",
                GREEN_ACCENT + "SPEAKING " +
                waves[index % 2] + RESET,
                "Piper ONNX PCM Output"
            )

        stop_event = threading.Event()

        animation_thread = threading.Thread(
            target=animate_screen,
            args=(stop_event, get_talking_frame, 0.15)
        )

        animation_thread.daemon = True
        animation_thread.start()

        try:

            audio_process = subprocess.run(
                ["aplay", "-q", OUTPUT_WAV],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=180
            )

            if audio_process.returncode != 0:

                print("[AUDIO] Playback failed.")
                print(audio_process.stderr.decode(
                    "utf-8", errors="replace"
                )[-500:])

                return False

        finally:

            stop_animation(stop_event, animation_thread)

        return True

    except subprocess.TimeoutExpired:

        print("[AUDIO] Audio process timed out.")
        return False

    except Exception as error:

        print("[AUDIO] Unexpected error:", error)
        return False


# ============================================================
# MAIN SYSTEM
# ============================================================

def main():

    ensure_reference_image()

    portrait_ascii = image_to_truecolor_blocks(
        LOCAL_REF_PATH,
        TARGET_WIDTH
    )

    idle_frame = generate_telemetry_frame(
        portrait_ascii,
        "LEAH.OS // NEURAL TELEMETRY NODE",
        GREEN_ACCENT + "● ONLINE" + RESET,
        "Awaiting operator prompt..."
    )

    clear_screen()

    print(idle_frame)

    print(
        CYAN_ACCENT +
        "\nLEAH.OS v3.5 // Local Terminal Interface" +
        RESET
    )

    print(
        AMBER_ACCENT +
        "Type 'help' for commands or 'exit' to close.\n" +
        RESET
    )

    while True:

        try:

            user_input = input(
                AMBER_ACCENT +
                BOLD +
                "Operator > " +
                RESET
            ).strip()

            if not user_input:
                continue

            if user_input.lower() in ["exit", "quit"]:

                print(
                    "\n" +
                    MAGENTA_ACCENT +
                    "[Closing session... Leah node offline.]" +
                    RESET
                )

                break

            answer = ask_llm(
                user_input,
                portrait_ascii
            )

            clear_screen()

            print(
                CYAN_ACCENT +
                BOLD +
                "╔═[ LEAH TELEMETRY RESPONSE ]══════════════════════╗" +
                RESET
            )

            print()

            typewriter_print(answer)

            print()

            print(
                CYAN_ACCENT +
                BOLD +
                "╚══════════════════════════════════════════════════╝" +
                RESET
            )

            print()

            speak(answer, portrait_ascii)

            clear_screen()

            print(idle_frame)

        except KeyboardInterrupt:

            print(
                "\n" +
                MAGENTA_ACCENT +
                "[Session force-closed.]" +
                RESET
            )

            break

        except EOFError:

            print("\n[Input stream closed.]")
            break

        except Exception as error:

            print("\n[LEAH SYSTEM ERROR]", error)

    sys.stdout.write(RESET)
    sys.stdout.flush()


if __name__ == "__main__":
    main()

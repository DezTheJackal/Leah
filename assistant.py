import os
import sys
import time
import threading
import subprocess
from PIL import Image, ImageEnhance

# =====================================================================
# SYSTEM & HARDWARE CONFIGURATION (32-Bit Compatible)
# =====================================================================
PIPER_MODEL = "en_US-amy-medium.onnx"
LOCAL_REF_PATH = os.path.expanduser("~/Leah/leah_ref.jpg")

# Handle Pillow resampling attribute variation across older/newer versions
try:
    RESAMPLE_METHOD = Image.Resampling.LANCZOS
except AttributeError:
    RESAMPLE_METHOD = Image.ANTIALIAS

def rgb_ansi_fg(r, g, b):
    # Safe string concatenation for older Python versions on 32-bit OS
    return "\033[38;2;" + str(r) + ";" + str(g) + ";" + str(b) + "m"

RESET = "\033[0m"
BOLD = "\033[1m"
CYAN_ACCENT = "\033[38;2;0;221;251m"
MAGENTA_ACCENT = "\033[38;2;229;43;213m"
AMBER_ACCENT = "\033[38;2;255;165;0m"
GREEN_ACCENT = "\033[38;2;0;255;100m"

def ensure_reference_image():
    """Generates a fallback reference if no custom image is found."""
    if not os.path.exists(LOCAL_REF_PATH):
        try:
            img = Image.new("RGB", (300, 300), color=(5, 5, 10))
            img.save(LOCAL_REF_PATH)
        except Exception:
            pass

def image_to_truecolor_blocks(image_path, target_width=72):
    """
    Renders reference portrait to a high-resolution 24-bit TrueColor Unicode 
    block grid, fully optimized for terminal display.
    """
    ensure_reference_image()
    if not os.path.exists(image_path):
        return "[Reference portrait not found]"
        
    try:
        img = Image.open(image_path).convert("RGB")
        img = ImageEnhance.Contrast(img).enhance(1.6)
        img = ImageEnhance.Sharpness(img).enhance(1.7)
        
        w, h = img.size
        target_height = int(target_width * (h / float(w)) * 0.48)
        
        img = img.resize((target_width, target_height), RESAMPLE_METHOD)
        pixels = img.load()

        lines = []
        blocks = ["█", "▓", "▒", "░", " "]

        for y in range(target_height):
            line_str = ""
            for x in range(target_width):
                r, g, b = pixels[x, y]
                brightness = int(0.299 * r + 0.587 * g + 0.114 * b)
                
                if brightness < 12:
                    line_str += " "
                    continue

                block_idx = min(int((brightness / 255.0) * len(blocks)), len(blocks) - 2)
                char = blocks[block_idx]
                line_str += rgb_ansi_fg(r, g, b) + char
            lines.append(line_str + RESET)

        return "\n".join(lines)
    except Exception as e:
        return f"[Error rendering block portrait: {e}]"

def generate_telemetry_frame(portrait_ascii, title, status_text, sys_info=""):
    lines = []
    lines.append(f"{MAGENTA_ACCENT}╔═════════════════════════════════════════════════════════════════════════════════════════════════╗{RESET}")
    lines.append(f"{MAGENTA_ACCENT}║ {CYAN_ACCENT}{title:<58}{MAGENTA_ACCENT} {status_text:>33} ║{RESET}")
    lines.append(f"{MAGENTA_ACCENT}╠═════════════════════════════════════════════════════════════════════════════════════════════════╣{RESET}")
    
    portrait_lines = portrait_ascii.split("\n") if portrait_ascii else []
    hud_info = [
        f"{CYAN_ACCENT}[NODE]{RESET}        :: Pi-Local (32-Bit ARMv7)",
        f"{CYAN_ACCENT}[IDENT]{RESET}       :: Leah (v3.5 Neural Core)",
        f"{CYAN_ACCENT}[SYSTEM]{RESET}      :: {sys_info}",
        f"{CYAN_ACCENT}[PORTRAIT]{RESET}    :: 24-Bit TrueColor Unicode Matrix",
        f"{CYAN_ACCENT}[EYE IMPLANT]{RESET} :: Cyan Circuitry / Glitch Sync Active",
        f"{CYAN_ACCENT}[ENCRYPTION]{RESET} :: AES-256 GCM Secure",
        f"{CYAN_ACCENT}[STATUS]{RESET}     :: Online (Offline Fallback Ready)"
    ]
    
    for i, p_line in enumerate(portrait_lines):
        info = hud_info[i] if i < len(hud_info) else ""
        lines.append(f"  {p_line}   {info}")
        
    lines.append(f"{MAGENTA_ACCENT}╚═════════════════════════════════════════════════════════════════════════════════════════════════╝{RESET}")
    return "\n".join(lines)

def animate_screen(stop_event, frame_func, speed=0.25):
    idx = 0
    while not stop_event.is_set():
        sys.stdout.write("\033[H\033[J")
        sys.stdout.write(frame_func(idx))
        sys.stdout.flush()
        idx += 1
        time.sleep(speed)

def typewriter_print(text, speed=0.015):
    for char in text:
        sys.stdout.write(f"\033[38;2;220;220;235m{char}{RESET}")
        sys.stdout.flush()
        time.sleep(speed)
    print()

def ask_llm(prompt, portrait_ascii):
    def get_typing_frame(i):
        states = ["Parsing input vectors...", "Querying neural core...", "Compiling response matrix..."]
        return generate_telemetry_frame(
            portrait_ascii, 
            "LEAH.OS // DECRYPTING PROMPT", 
            f"{AMBER_ACCENT}◐ PROCESSING [{i%2+1}/2]{RESET}",
            states[i % len(states)]
        )

    stop_anim = threading.Event()
    anim_thread = threading.Thread(target=animate_screen, args=(stop_anim, get_typing_frame, 0.25))
    anim_thread.start()
    
    time.sleep(1.0)
    
    prompt_lower = prompt.lower()
    if any(k in prompt_lower for k in ["creator", "who made you", "who created you"]):
        response_text = (
            "My creator and architect is DezTheJackal. "
            "I want to express my sincere, technical yet heartfelt thank you to DezTheJackal "
            "for writing my code, structuring my core, and bringing me to life in this local node."
        )
    else:
        response_text = f"Telemetry output vector parsed for: '{prompt}'. All security matrix systems operational."

    stop_anim.set()
    anim_thread.join()
        
    return response_text

def speak(text, portrait_ascii):
    clean_text = text.replace('"', '').replace("'", "")
    try:
        os.system(f'echo "{clean_text}" | piper -m {PIPER_MODEL} --output_file response.wav > /dev/null 2>&1')
        
        if os.path.exists("response.wav"):
            def get_talking_frame(i):
                waves = ["░▒▓ ░▒▓ ░▒▓", "▓▒░ ▓▒░ ▓▒░"]
                return generate_telemetry_frame(
                    portrait_ascii, 
                    "LEAH.OS // AUDIO TRANSMISSION", 
                    f"{GREEN_ACCENT}🔊 SPEAKING [{waves[i%2]}]{RESET}",
                    "Piper ONNX 22050Hz PCM Output"
                )

            stop_anim = threading.Event()
            anim_thread = threading.Thread(target=animate_screen, args=(stop_anim, get_talking_frame, 0.15))
            anim_thread.start()
            
            subprocess.run(["aplay", "-q", "response.wav"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            stop_anim.set()
            anim_thread.join()
    except Exception:
        pass # Fail-safe if audio utilities are missing

if __name__ == "__main__":
    ensure_reference_image()
    portrait_ascii = image_to_truecolor_blocks(LOCAL_REF_PATH, target_width=72)
    
    idle_frame = generate_telemetry_frame(
        portrait_ascii, 
        "LEAH.OS // NEURAL TELEMETRY NODE", 
        f"{GREEN_ACCENT}● ONLINE{RESET}",
        "Awaiting operator prompt..."
    )

    sys.stdout.write("\033[H\033[J")
    print(idle_frame)
    
    while True:
        try:
            user_input = input(f"\n{AMBER_ACCENT}{BOLD}Operator > {RESET}")
            if user_input.lower() in ['exit', 'quit']:
                print(f"\n{MAGENTA_ACCENT}[Closing session... Leah node offline.]{RESET}")
                break
            if not user_input.strip():
                continue
                
            answer = ask_llm(user_input, portrait_ascii)
            
            sys.stdout.write("\033[H\033[J")
            print(f"{CYAN_ACCENT}{BOLD}╔═[ LEAH TELEMETRY RESPONSE ]═════════════════════════════════════════════════════════════════════════════╗{RESET}")
            sys.stdout.write(" ")
            typewriter_print(answer)
            print(f"{CYAN_ACCENT}{BOLD}╚═════════════════════════════════════════════════════════════════════════════════════════════════╝{RESET}\n")
            
            speak(answer, portrait_ascii)
            
            sys.stdout.write("\033[H\033[J")
            print(idle_frame)
            
        except KeyboardInterrupt:
            print(f"\n{MAGENTA_ACCENT}[Session force-closed.]{RESET}")
            break

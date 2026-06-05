"""
DOOM Clone — CrashTech VLSI-2026 Challenge 8
Raycaster game controlled by the DE10-Lite board via serial.

Controls (from board):
  SW[0]  Move forward       SW[1]  Move backward
  SW[2]  Turn left          SW[3]  Turn right
  SW[4]  Strafe left        SW[5]  Strafe right
  SW[6]  Open door/use      SW[7]  God mode
  SW[8]  Hard mode          SW[9]  Debug minimap
  KEY[0] Shoot              KEY[1] Pause / Restart

Keyboard fallback (no board connected):
  WASD / arrows to move, Space to shoot, P to pause, R to restart

Usage:
  python game.py            # keyboard only
  python game.py COM3       # board on COM3  (Linux: /dev/ttyUSB0)
"""

import sys
import math
import time
import struct
import threading
import pygame
import pygame.sndarray
import numpy as np
import doom_assets

# ── window ──────────────────────────────────────────────────────────────────
W, H         = 960, 600
HALF_H       = H // 2
FOV          = math.pi / 3          # 60°
NUM_RAYS     = W // 2               # cast one ray per 2 px for speed
MAX_DEPTH    = 20.0
CELL         = 1.0

# ── colours ─────────────────────────────────────────────────────────────────
C_SKY        = (20,  20,  40)
C_FLOOR      = (50,  40,  30)
C_HUD_BG     = (0,   0,   0)
C_WHITE      = (255, 255, 255)
C_RED        = (220,  40,  40)
C_YELLOW     = (240, 200,  40)
C_GREEN      = (60,  200,  60)
C_DARK_GREEN = (20,   80,  20)
C_GREY       = (120, 120, 120)
C_DARK_GREY  = (60,   60,  60)
C_ORANGE     = (220, 140,  40)
C_BLOOD      = (140,   0,   0)

# Wall colours indexed by tile value (1-5)
WALL_COLORS  = {
    1: (180, 120,  60),   # stone
    2: (100, 100, 180),   # blue brick
    3: (180,  60,  60),   # red brick
    4: (60,  160,  60),   # moss
    5: (160, 160,  60),   # tan
    6: (220, 180, 100),   # door (open  = 0)
}

# ── level map ────────────────────────────────────────────────────────────────
# 0 = open, 1-5 = walls, 6 = door (closed), 9 = exit trigger
MAP = [
    [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
    [1,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,1],
    [1,0,1,1,0,0,0,0,0,1,0,0,0,2,0,0,0,0,0,1],
    [1,0,1,0,0,0,0,0,0,6,0,0,0,2,0,0,0,0,0,1],
    [1,0,1,0,0,3,3,0,0,1,0,0,0,2,0,0,0,0,0,1],
    [1,0,0,0,0,3,0,0,0,1,0,0,0,0,0,4,4,4,0,1],
    [1,0,0,0,0,3,0,0,0,1,1,6,1,1,0,4,0,4,0,1],
    [1,0,0,0,0,0,0,0,0,0,0,0,0,1,0,4,0,4,0,1],
    [1,0,0,5,5,5,0,0,0,0,0,0,0,1,0,0,0,0,0,1],
    [1,0,0,5,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,1],
    [1,0,0,5,0,0,0,0,0,5,0,0,0,1,0,0,0,0,0,1],
    [1,0,0,0,0,0,0,0,0,5,0,0,0,1,1,1,6,1,1,1],
    [1,0,0,0,0,0,0,0,0,5,0,0,0,0,0,0,0,0,0,1],
    [1,0,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,9,1],
    [1,0,1,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],
    [1,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,5,5,5,1],
    [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],
    [1,0,0,0,0,0,0,0,3,3,3,0,0,0,0,0,0,0,0,1],
    [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],
    [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
]
MAP_W = len(MAP[0])
MAP_H = len(MAP)

DOOR_TILES = set()  # tracks (x,y) of currently-open doors

PLAYER_START = (1.5, 1.5, 0.0)   # x, y, angle

# ── enemy definition ─────────────────────────────────────────────────────────
ENEMY_SPAWN = [
    (3.5, 5.5), (7.5, 2.5), (11.5, 4.5), (15.5, 2.5),
    (16.5, 6.5), (3.5, 10.5), (9.5, 10.5), (17.5, 13.5),
    (6.5, 14.5), (13.5, 15.5),
]

class Enemy:
    def __init__(self, x, y, hp=1):
        self.x   = x
        self.y   = y
        self.hp  = hp
        self.max_hp = hp
        self.alive = True
        self.dist  = 0.0
        self.anim  = 0
        self.anim_t = 0.0
        self.alert  = False
        self.attack_t = 0.0
        self.death_frame = 0   # index into death animation frames
        self.death_t     = 0.0 # accumulator for death frame timer

# ── sound synthesis ──────────────────────────────────────────────────────────
SAMPLE_RATE = 22050

def _make_sound(freq, duration, wave='square', decay=0.5):
    """Generate a simple mono sound and return a pygame.Sound."""
    n = int(SAMPLE_RATE * duration)
    t = np.linspace(0, duration, n, endpoint=False)
    if wave == 'square':
        samples = np.sign(np.sin(2 * np.pi * freq * t))
    elif wave == 'noise':
        samples = np.random.uniform(-1, 1, n)
    elif wave == 'sine':
        samples = np.sin(2 * np.pi * freq * t)
    else:
        samples = np.sin(2 * np.pi * freq * t)
    env = np.exp(-decay * t / duration * 10)
    samples = (samples * env * 16000).astype(np.int16)
    stereo = np.column_stack([samples, samples])
    sound = pygame.sndarray.make_sound(stereo)
    return sound

def build_sounds():
    pygame.mixer.init(frequency=SAMPLE_RATE, size=-16, channels=2, buffer=512)
    return {
        'shoot':    _make_sound(200,  0.18, 'noise',  1.0),
        'hit':      _make_sound(150,  0.12, 'noise',  2.0),
        'death':    _make_sound(80,   0.40, 'square', 0.8),
        'start':    _make_sound(440,  0.60, 'sine',   0.3),
        'win':      _make_sound(880,  0.80, 'sine',   0.2),
        'gameover': _make_sound(100,  0.90, 'square', 0.5),
        'door':     _make_sound(300,  0.20, 'square', 1.5),
        'pain':     _make_sound(250,  0.15, 'noise',  2.0),
    }

# ── serial reader thread ─────────────────────────────────────────────────────
class BoardReader:
    def __init__(self, port):
        import serial
        self._ser = serial.Serial(port, 115200, timeout=0.05)
        self._sw   = 0      # SW[9:0]
        self._keys = 0      # bit0=KEY0, bit1=KEY1
        self._lock = threading.Lock()
        self._running = True
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    def _run(self):
        buf = bytearray()
        while self._running:
            data = self._ser.read(64)
            if not data:
                continue
            buf.extend(data)
            while len(buf) >= 6:
                idx = -1
                for i in range(len(buf) - 1):
                    if buf[i] == 0xA5 and buf[i+1] == 0x5A:
                        idx = i
                        break
                if idx < 0:
                    buf = buf[-1:]
                    continue
                if idx > 0:
                    buf = buf[idx:]
                if len(buf) < 6:
                    break
                sw_lo, sw_hi, keys, cksum = buf[2], buf[3], buf[4], buf[5]
                expected = (sw_lo + sw_hi + keys) & 0xFF
                if cksum == expected:
                    sw = sw_lo | ((sw_hi & 0x03) << 8)
                    with self._lock:
                        self._sw   = sw
                        self._keys = keys & 0x03
                buf = buf[6:]

    def get(self):
        with self._lock:
            return self._sw, self._keys

    def close(self):
        self._running = False
        self._ser.close()

# ── raycasting ───────────────────────────────────────────────────────────────
def cast_ray(px, py, angle):
    """DDA ray cast. Returns (dist, tile_val, side) or (MAX_DEPTH, 0, 0)."""
    dx = math.cos(angle)
    dy = math.sin(angle)

    map_x = int(px)
    map_y = int(py)

    delta_x = abs(1.0 / dx) if dx != 0 else 1e30
    delta_y = abs(1.0 / dy) if dy != 0 else 1e30

    if dx < 0:
        step_x = -1
        side_dist_x = (px - map_x) * delta_x
    else:
        step_x = 1
        side_dist_x = (map_x + 1.0 - px) * delta_x

    if dy < 0:
        step_y = -1
        side_dist_y = (py - map_y) * delta_y
    else:
        step_y = 1
        side_dist_y = (map_y + 1.0 - py) * delta_y

    side = 0
    for _ in range(int(MAX_DEPTH) * 2):
        if side_dist_x < side_dist_y:
            side_dist_x += delta_x
            map_x += step_x
            side = 0
        else:
            side_dist_y += delta_y
            map_y += step_y
            side = 1

        if not (0 <= map_x < MAP_W and 0 <= map_y < MAP_H):
            return MAX_DEPTH, 0, side, 0.0

        tile = MAP[map_y][map_x]
        if (tile >= 1 and tile <= 5) or (tile == 6 and (map_x, map_y) not in DOOR_TILES):
            dist = (side_dist_x - delta_x) if side == 0 else (side_dist_y - delta_y)
            dist = max(dist, 0.01)
            if side == 0:
                wall_x = (py + dist * dy) % 1.0
                if dx < 0: wall_x = 1.0 - wall_x
            else:
                wall_x = (px + dist * dx) % 1.0
                if dy > 0: wall_x = 1.0 - wall_x
            return dist, tile if tile != 6 else 6, side, wall_x

    return MAX_DEPTH, 0, side, 0.0

def wall_color(tile, side, dist):
    base = WALL_COLORS.get(tile, C_GREY)
    # Darken far walls and side faces
    factor = min(1.0, 4.0 / (dist + 0.5))
    if side == 1:
        factor *= 0.65
    r = int(base[0] * factor)
    g = int(base[1] * factor)
    b = int(base[2] * factor)
    return (max(0,min(255,r)), max(0,min(255,g)), max(0,min(255,b)))

# ── sprite / enemy rendering ─────────────────────────────────────────────────
def draw_sprites(surf, px, py, angle, enemies, zbuf):
    """Simple sprite billboard renderer."""
    visible = []
    for e in enemies:
        if not e.alive:
            continue
        dx = e.x - px
        dy = e.y - py
        e.dist = math.hypot(dx, dy)
        if e.dist < 0.3:
            continue
        visible.append(e)

    visible.sort(key=lambda e: -e.dist)

    for e in visible:
        dx = e.x - px
        dy = e.y - py
        sprite_angle = math.atan2(dy, dx) - angle
        # Normalise to [-pi, pi]
        while sprite_angle > math.pi:  sprite_angle -= 2 * math.pi
        while sprite_angle < -math.pi: sprite_angle += 2 * math.pi

        if abs(sprite_angle) > FOV * 0.7:
            continue

        proj_dist = e.dist * math.cos(sprite_angle)
        if proj_dist <= 0.1:
            continue

        proj_h = int(H / proj_dist)
        proj_w = proj_h

        screen_x = int((0.5 + sprite_angle / FOV) * W) - proj_w // 2
        top_y    = HALF_H - proj_h // 2

        # Body colour (green zombie-ish)
        body_col = C_DARK_GREEN if e.alive else C_BLOOD
        for sx in range(max(0, screen_x), min(W, screen_x + proj_w)):
            col_idx = sx // 2  # zbuf indexed at half resolution
            if col_idx >= len(zbuf):
                continue
            if zbuf[col_idx] < proj_dist:
                continue
            # Torso
            pygame.draw.line(surf, body_col,
                             (sx, max(0, top_y + proj_h//4)),
                             (sx, min(H-1, top_y + proj_h*3//4)))
        # Head dot
        head_x = screen_x + proj_w // 2
        head_r = max(2, proj_w // 6)
        if 0 <= head_x < W:
            pygame.draw.circle(surf, C_ORANGE, (head_x, max(head_r, top_y + head_r)), head_r)

# ── gun flash ────────────────────────────────────────────────────────────────
GUN_FRAMES = 4
def draw_gun(surf, firing_t):
    gw, gh = 120, 100
    gx = W // 2 - gw // 2
    gy = H - gh - 10
    bob = int(math.sin(time.time() * 4) * 3)
    gy += bob

    col = C_DARK_GREY
    # Barrel
    pygame.draw.rect(surf, col, (gx + gw//2 - 8, gy, 16, gh - 20))
    # Handle
    pygame.draw.rect(surf, C_GREY, (gx + gw//2 - 14, gy + gh - 40, 28, 40))
    if firing_t > 0:
        flash_r = int(firing_t * 30)
        pygame.draw.circle(surf, C_YELLOW, (W//2, gy - 4), flash_r)
        pygame.draw.circle(surf, C_WHITE,  (W//2, gy - 4), flash_r // 2)

# ── HUD ──────────────────────────────────────────────────────────────────────
def draw_hud(surf, font, health, ammo, kills, total_enemies, god_mode, hard_mode, debug):
    pygame.draw.rect(surf, C_HUD_BG, (0, H - 40, W, 40))
    hcol = C_GREEN if health > 50 else (C_YELLOW if health > 25 else C_RED)
    if god_mode:
        hcol = C_YELLOW
        health = 100
    surf.blit(font.render(f"HP: {health:3d}%", True, hcol),          (10,  H - 32))
    surf.blit(font.render(f"AMMO: {ammo:3d}",  True, C_YELLOW),      (160, H - 32))
    surf.blit(font.render(f"KILLS: {kills}/{total_enemies}", True, C_WHITE), (310, H - 32))
    mods = []
    if god_mode:  mods.append("GOD")
    if hard_mode: mods.append("HARD")
    if debug:     mods.append("DEBUG")
    if mods:
        surf.blit(font.render(" ".join(mods), True, C_ORANGE), (W - 160, H - 32))

def draw_minimap(surf, px, py, enemies):
    scale = 6
    ox, oy = 10, 10
    for row in range(MAP_H):
        for col in range(MAP_W):
            t = MAP[row][col]
            if t == 0 or t == 9:
                col_ = C_DARK_GREY
            elif t == 6:
                col_ = C_YELLOW if (col, row) in DOOR_TILES else C_ORANGE
            else:
                col_ = C_GREY
            pygame.draw.rect(surf, col_,
                             (ox + col*scale, oy + row*scale, scale-1, scale-1))
    # player
    pygame.draw.circle(surf, C_GREEN,
                       (ox + int(px*scale), oy + int(py*scale)), 3)
    # direction line
    dx = math.cos(py) * 8  # reuse py intentionally? No, angle from game state
    # enemies
    for e in enemies:
        if e.alive:
            pygame.draw.circle(surf, C_RED,
                               (ox + int(e.x*scale), oy + int(e.y*scale)), 2)

def draw_minimap_with_angle(surf, px, py, pa, enemies):
    scale = 6
    ox, oy = 10, 10
    for row in range(MAP_H):
        for col in range(MAP_W):
            t = MAP[row][col]
            if t == 0 or t == 9:
                col_ = C_DARK_GREY
            elif t == 6:
                col_ = C_YELLOW if (col, row) in DOOR_TILES else C_ORANGE
            else:
                col_ = C_GREY
            pygame.draw.rect(surf, col_,
                             (ox + col*scale, oy + row*scale, scale-1, scale-1))
    pygame.draw.circle(surf, C_GREEN, (ox + int(px*scale), oy + int(py*scale)), 3)
    ex = ox + int(px*scale) + int(math.cos(pa) * 8)
    ey = oy + int(py*scale) + int(math.sin(pa) * 8)
    pygame.draw.line(surf, C_GREEN, (ox+int(px*scale), oy+int(py*scale)), (ex, ey), 1)
    for e in enemies:
        if e.alive:
            pygame.draw.circle(surf, C_RED, (ox + int(e.x*scale), oy + int(e.y*scale)), 2)

# ── title / start screen ─────────────────────────────────────────────────────
def draw_title_screen(surf, W, H, big_f, med_f, font):
    surf.fill((5, 5, 12))
    # Atmospheric red bands
    for y in range(0, H, 3):
        dist = abs(y - H * 0.38) / (H * 0.38)
        intensity = max(0, int(45 * (1.0 - dist)))
        if intensity:
            pygame.draw.line(surf, (intensity, 0, 0), (0, y), (W, y))
    # Title
    title  = big_f.render("DOOM CLONE", True, (210, 28, 28))
    shadow = big_f.render("DOOM CLONE", True, (70,  0,  0))
    ty = H // 3 - title.get_height() // 2
    surf.blit(shadow, (W // 2 - title.get_width() // 2 + 4, ty + 4))
    surf.blit(title,  (W // 2 - title.get_width() // 2,     ty))
    # Subtitle
    sub = med_f.render("CrashTech VLSI-2026  ·  Challenge 8", True, (195, 135, 40))
    surf.blit(sub, (W // 2 - sub.get_width() // 2, ty + title.get_height() + 14))
    # Pulsing prompt — driven by real clock so it works before the loop starts
    pulse = abs(math.sin(pygame.time.get_ticks() / 600.0))
    pc = (int(230 * pulse + 25),) * 3
    prompt = med_f.render("PRESS SPACE / KEY[0] TO START", True, pc)
    surf.blit(prompt, (W // 2 - prompt.get_width() // 2, H * 2 // 3))
    # Control hints
    hf = pygame.font.SysFont("monospace", 13, bold=True)
    hints = [
        "BOARD: SW[0-5] move/strafe  SW[6] door  SW[7] god  SW[8] hard  SW[9] map",
        "KB:    WASD/arrows  Space shoot  P pause  F door  G god  H hard  Tab map",
    ]
    for i, line in enumerate(hints):
        hs = hf.render(line, True, (85, 85, 85))
        surf.blit(hs, (W // 2 - hs.get_width() // 2, H - 52 + i * 22))


# ── overlay screens ──────────────────────────────────────────────────────────
def draw_center_text(surf, big_font, font, title, subtitle, color=C_RED):
    overlay = pygame.Surface((W, H), pygame.SRCALPHA)
    overlay.fill((0, 0, 0, 160))
    surf.blit(overlay, (0, 0))
    t1 = big_font.render(title, True, color)
    t2 = font.render(subtitle, True, C_WHITE)
    surf.blit(t1, (W//2 - t1.get_width()//2, H//2 - 60))
    surf.blit(t2, (W//2 - t2.get_width()//2, H//2 + 10))

# ── collision helpers ────────────────────────────────────────────────────────
PLAYER_RADIUS = 0.25

def is_solid(tx, ty):
    if not (0 <= tx < MAP_W and 0 <= ty < MAP_H):
        return True
    t = MAP[ty][tx]
    if t == 0 or t == 9:
        return False
    if t == 6 and (tx, ty) in DOOR_TILES:
        return False
    return True

def try_move(px, py, dx, dy):
    nx = px + dx
    ny = py + dy
    r = PLAYER_RADIUS
    # Check corners
    if not is_solid(int(nx + r), int(py    )) and \
       not is_solid(int(nx - r), int(py    )):
        px = nx
    if not is_solid(int(px    ), int(ny + r)) and \
       not is_solid(int(px    ), int(ny - r)):
        py = ny
    return px, py

def try_open_door(px, py, pa):
    """Open a door cell ~1 step in front of the player."""
    tx = int(px + math.cos(pa) * 1.2)
    ty = int(py + math.sin(pa) * 1.2)
    if 0 <= tx < MAP_W and 0 <= ty < MAP_H and MAP[ty][tx] == 6:
        if (tx, ty) not in DOOR_TILES:
            DOOR_TILES.add((tx, ty))
            return True
    return False

def shoot_ray(px, py, pa, enemies, god_mode):
    """Check if the shoot ray hits an enemy within range."""
    hit_enemy = None
    hit_dist  = MAX_DEPTH
    for e in enemies:
        if not e.alive:
            continue
        dx = e.x - px
        dy = e.y - py
        dist = math.hypot(dx, dy)
        if dist > 12:
            continue
        enemy_angle = math.atan2(dy, dx)
        diff = (enemy_angle - pa + math.pi) % (2*math.pi) - math.pi
        # Half-width of enemy at that distance (0.4 rad at dist=1, less further)
        half_w = math.atan2(0.4, dist)
        if abs(diff) < half_w and dist < hit_dist:
            hit_dist  = dist
            hit_enemy = e
    return hit_enemy

# ── enemy AI ─────────────────────────────────────────────────────────────────
_DEATH_FRAME_DT = 0.10   # seconds between death animation frames

def update_enemies(enemies, px, py, dt, hard_mode, health, sounds):
    speed = 1.8 if hard_mode else 1.2
    damage = 15 if hard_mode else 10
    player_hurt = False

    for e in enemies:
        if not e.alive:
            # Advance death animation; cap so we don't drift past the last frame
            if e.death_frame < 20:
                e.death_t += dt
                while e.death_t >= _DEATH_FRAME_DT:
                    e.death_t -= _DEATH_FRAME_DT
                    e.death_frame += 1
            continue
        dx = e.x - px
        dy = e.y - py
        dist = math.hypot(dx, dy)

        # Alert when close or line-of-sight (simplified: always alert within 8)
        if dist < 8:
            e.alert = True

        if not e.alert:
            continue

        # Move toward player
        if dist > 0.6:
            nx = e.x - dx / dist * speed * dt
            ny = e.y - dy / dist * speed * dt
            if not is_solid(int(nx), int(e.y)):
                e.x = nx
            if not is_solid(int(e.x), int(ny)):
                e.y = ny

        # Attack player when close
        if dist < 0.8:
            e.attack_t += dt
            if e.attack_t > 0.8:
                e.attack_t = 0
                player_hurt = True

        # Walk animation
        e.anim_t += dt * 4
        e.anim = int(e.anim_t) % 4

    return player_hurt

# ── main game ────────────────────────────────────────────────────────────────
def main():
    port = sys.argv[1] if len(sys.argv) > 1 else None

    board = None
    if port:
        try:
            board = BoardReader(port)
            print(f"[serial] connected on {port}")
        except Exception as ex:
            print(f"[serial] failed to open {port}: {ex}")
            board = None

    pygame.init()
    surf = pygame.display.set_mode((W, H))
    pygame.display.set_caption("DOOM Clone — CrashTech 2026")
    clock  = pygame.time.Clock()
    font   = pygame.font.SysFont("monospace", 16, bold=True)
    big_f  = pygame.font.SysFont("monospace", 64, bold=True)
    med_f  = pygame.font.SysFont("monospace", 32, bold=True)

    sounds = build_sounds()

    textures      = doom_assets.build_textures()
    tex_strips    = doom_assets.build_tex_strips(textures)
    enemy_sprites = doom_assets.build_enemy_sprites()
    weapon_sprites= doom_assets.build_weapon_sprites()
    faces         = doom_assets.build_faces()
    digits        = doom_assets.build_digits()
    hud_bg        = doom_assets.build_hud_bg(W)

    def reset_game():
        global DOOR_TILES
        DOOR_TILES = set()
        px, py, pa = PLAYER_START
        health = 100
        ammo   = 50
        enemies = []
        for ex, ey in ENEMY_SPAWN:
            hp = 2 if hard_mode else 1
            enemies.append(Enemy(ex, ey, hp))
        return px, py, pa, health, ammo, enemies, 0

    # Game state
    hard_mode  = False
    god_mode   = False
    debug_mode = True
    # Don't call reset_game() yet — wait for the player to press start
    px, py, pa = PLAYER_START
    health, ammo, kills = 100, 50, 0
    enemies = []

    STATE_MENU     = 4
    STATE_PLAYING  = 0
    STATE_DEAD     = 1
    STATE_WON      = 2
    STATE_PAUSED   = 3
    game_state     = STATE_MENU

    firing_t  = 0.0
    shoot_cd  = 0.0
    door_cd   = 0.0
    kb_key1_prev      = False
    board_key1_prev   = 0
    menu_shoot_prev   = False  # edge-detect for menu start

    MOVE_SPEED = 3.0
    TURN_SPEED = 2.2

    zbuf = [MAX_DEPTH] * NUM_RAYS

    while True:
        dt = clock.tick(60) / 1000.0
        dt = min(dt, 0.05)

        # ── input ──────────────────────────────────────────────────────────
        sw   = 0        # SW[9:0]
        keys = 0        # bit0=KEY0 shoot, bit1=KEY1 pause/restart

        if board:
            sw, keys = board.get()

        # ===== TEMP_DEBUG: keyboard controls — remove this block once the board is wired up =====
        # W/↑ fwd  S/↓ back  A/← turn-L  D/→ turn-R  Q strafe-L  E strafe-R
        # F door   G god     H hard       Tab minimap  Space shoot  P/R pause-restart
        kb = pygame.key.get_pressed()
        if kb[pygame.K_w] or kb[pygame.K_UP]:    sw   |= (1 << 0)  # forward
        if kb[pygame.K_s] or kb[pygame.K_DOWN]:  sw   |= (1 << 1)  # backward
        if kb[pygame.K_LEFT]  or kb[pygame.K_a]: sw   |= (1 << 2)  # turn left
        if kb[pygame.K_RIGHT] or kb[pygame.K_d]: sw   |= (1 << 3)  # turn right
        if kb[pygame.K_q]:                        sw   |= (1 << 4)  # strafe left
        if kb[pygame.K_e]:                        sw   |= (1 << 5)  # strafe right
        if kb[pygame.K_f]:                        sw   |= (1 << 6)  # open door
        if kb[pygame.K_g]:                        sw   |= (1 << 7)  # god mode (SW[7])
        if kb[pygame.K_h]:                        sw   |= (1 << 8)  # hard mode (SW[8])
        if kb[pygame.K_TAB]:                      sw   |= (1 << 9)  # hide minimap (SW[9])
        if kb[pygame.K_SPACE]:                    keys |= 1          # shoot (KEY[0])
        kb_key1 = kb[pygame.K_p] or kb[pygame.K_r]
        if kb_key1 and not kb_key1_prev:          keys |= 2          # pause/restart (KEY[1], edge)
        kb_key1_prev = kb_key1
        # ===== END TEMP_DEBUG =====

        # Read switch effects
        god_mode   = bool(sw & (1 << 7))
        hard_mode  = bool(sw & (1 << 8))
        debug_mode = not bool(sw & (1 << 9))   # SW[9]/Tab now hides; default is shown

        # KEY[1] edge-detect (pause/restart)
        key1_now  = bool(keys & 2)
        key1_edge = key1_now and not bool(board_key1_prev & 2)
        board_key1_prev = keys

        # pygame event pump
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                if board: board.close()
                pygame.quit()
                sys.exit()
            if event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    if board: board.close()
                    pygame.quit()
                    sys.exit()

        # ── state transitions ───────────────────────────────────────────────
        if game_state == STATE_MENU:
            shoot_now = bool(keys & 1)
            if shoot_now and not menu_shoot_prev:
                px, py, pa, health, ammo, enemies, kills = reset_game()
                game_state = STATE_PLAYING
                sounds['start'].play()
            menu_shoot_prev = shoot_now
        elif game_state in (STATE_DEAD, STATE_WON):
            if key1_edge:
                px, py, pa, health, ammo, enemies, kills = reset_game()
                game_state = STATE_PLAYING
                sounds['start'].play()
        elif game_state == STATE_PAUSED:
            if key1_edge:
                game_state = STATE_PLAYING
        elif game_state == STATE_PLAYING:
            if key1_edge:
                game_state = STATE_PAUSED

        # ── gameplay update (only when playing) ────────────────────────────
        if game_state == STATE_PLAYING:
            # Movement
            move_speed = MOVE_SPEED * dt
            turn_speed = TURN_SPEED * dt

            if sw & (1 << 2): pa -= turn_speed        # turn left
            if sw & (1 << 3): pa += turn_speed        # turn right
            if sw & (1 << 0):                          # forward
                px, py = try_move(px, py,
                                  math.cos(pa) * move_speed,
                                  math.sin(pa) * move_speed)
            if sw & (1 << 1):                          # backward
                px, py = try_move(px, py,
                                  -math.cos(pa) * move_speed,
                                  -math.sin(pa) * move_speed)
            if sw & (1 << 4):                          # strafe left
                px, py = try_move(px, py,
                                   math.cos(pa - math.pi/2) * move_speed,
                                   math.sin(pa - math.pi/2) * move_speed)
            if sw & (1 << 5):                          # strafe right
                px, py = try_move(px, py,
                                   math.cos(pa + math.pi/2) * move_speed,
                                   math.sin(pa + math.pi/2) * move_speed)

            # Door
            door_cd -= dt
            if (sw & (1 << 6)) and door_cd <= 0:
                if try_open_door(px, py, pa):
                    sounds['door'].play()
                door_cd = 0.5

            # Shoot
            shoot_cd -= dt
            firing_t -= dt
            if (keys & 1) and shoot_cd <= 0 and ammo > 0:
                ammo -= 1
                shoot_cd = 0.25
                firing_t = 0.12
                sounds['shoot'].play()
                hit = shoot_ray(px, py, pa, enemies, god_mode)
                if hit:
                    hit.hp -= 1
                    sounds['hit'].play()
                    if hit.hp <= 0:
                        hit.alive = False
                        kills += 1
                        sounds['death'].play()

            # Enemies
            hurt = update_enemies(enemies, px, py, dt, hard_mode, health, sounds)
            if hurt and not god_mode:
                health -= (20 if hard_mode else 10)
                sounds['pain'].play()
                if health <= 0:
                    health = 0
                    game_state = STATE_DEAD
                    sounds['gameover'].play()

            # Exit trigger
            if MAP[int(py)][int(px)] == 9:
                game_state = STATE_WON
                sounds['win'].play()

        # ── render ──────────────────────────────────────────────────────────
        if game_state == STATE_MENU:
            draw_title_screen(surf, W, H, big_f, med_f, font)
            pygame.display.flip()
            continue

        # Sky + floor
        surf.fill(C_SKY, (0, 0, W, HALF_H))
        surf.fill(C_FLOOR, (0, HALF_H, W, HALF_H))

        # Walls
        ray_angle_step = FOV / NUM_RAYS
        for i in range(NUM_RAYS):
            ray_angle = pa - FOV / 2 + i * ray_angle_step
            dist, tile, side, wall_x = cast_ray(px, py, ray_angle)
            corr_dist = dist * math.cos(ray_angle - pa)
            zbuf[i] = corr_dist

            if tile == 0:
                continue

            # Cap at 3× screen height to prevent scaling huge surfaces while
            # keeping correct perspective at typical play distances.  The texture
            # centre row always lands at the horizon regardless of the cap.
            wall_h = min(H / corr_dist, H * 3.0) if corr_dist > 0.01 else H * 3.0
            top    = HALF_H - wall_h / 2

            vis_top  = max(0, int(top))
            vis_bot  = min(int(top + wall_h) + 1, H)   # HUD draws on top of overflow
            vis_h    = vis_bot - vis_top
            x_screen = i * 2

            if vis_h <= 0:
                continue

            if tile in tex_strips:
                tex_x = int(wall_x * doom_assets.TEX_SIZE) % doom_assets.TEX_SIZE
                src   = tex_strips[tile][tex_x]
                ts    = doom_assets.TEX_SIZE
                if wall_h > vis_h:
                    # Crop texture to only the rows mapped to the visible strip.
                    # Use float division to avoid integer-truncation at extreme
                    # close range (wall_h >> vis_h would give t1-t0 = 0 with //).
                    t0 = max(0,  int((vis_top - top) / wall_h * ts))
                    t1 = min(ts, int((vis_bot - top) / wall_h * ts) + 1)
                    crop = pygame.Surface((1, max(1, t1 - t0)))
                    crop.blit(src, (0, -t0))
                    strip = pygame.transform.scale(crop, (2, vis_h))
                else:
                    strip = pygame.transform.scale(src, (2, max(1, vis_h)))
                factor = max(0, min(1.0, 4.0 / (corr_dist + 0.5)))
                if side == 1:
                    factor *= 0.60
                shade = int(factor * 255)
                strip.fill((shade, shade, shade), special_flags=pygame.BLEND_RGB_MULT)
                surf.blit(strip, (x_screen, vis_top))
            else:
                col = wall_color(tile, side, corr_dist)
                pygame.draw.rect(surf, col, (x_screen, vis_top, 2, vis_h))

        # Sprites
        doom_assets.draw_enemies(surf, px, py, pa, enemies, zbuf,
                                 enemy_sprites, NUM_RAYS, FOV, W, H)

        # Gun
        doom_assets.draw_weapon(surf, weapon_sprites, firing_t, W, H)

        # HUD
        doom_assets.draw_hud(surf, hud_bg, faces, digits, W, H,
                             health, ammo, kills, len(enemies),
                             god_mode, hard_mode, debug_mode)

        # Minimap — on by default; auto-hides during high-input moments (moving+shooting).
        # Hold Tab / flip SW[9] to manually hide it completely.
        _moving     = bool(sw & 0b111111)   # any of SW[0-5] (move/turn/strafe)
        _high_input = _moving and (firing_t > 0 or bool(keys & 1))
        if debug_mode and not _high_input:
            draw_minimap_with_angle(surf, px, py, pa, enemies)

        # Crosshair
        cx, cy = W//2, HALF_H
        pygame.draw.line(surf, C_WHITE, (cx-8, cy), (cx+8, cy), 1)
        pygame.draw.line(surf, C_WHITE, (cx, cy-8), (cx, cy+8), 1)

        # Overlays
        if game_state == STATE_DEAD:
            draw_center_text(surf, big_f, font,
                             "YOU DIED",
                             "KEY[1] / P to restart",
                             C_RED)
        elif game_state == STATE_WON:
            draw_center_text(surf, big_f, font,
                             "LEVEL CLEAR!",
                             f"Kills: {kills}/{len(enemies)}  —  KEY[1] / P to play again",
                             C_YELLOW)
        elif game_state == STATE_PAUSED:
            draw_center_text(surf, big_f, med_f,
                             "PAUSED",
                             "KEY[1] / P to resume",
                             C_WHITE)

        pygame.display.flip()

    if board:
        board.close()

if __name__ == "__main__":
    main()

"""
doom_assets.py — DOOM-style assets: FreeDoom PNG sprites + procedural fallbacks.
Run fetch_assets.py first to populate assets/ (BSD 3-Clause FreeDoom assets).
"""
import math
import os
import pygame
import numpy as np

# HUD height matches original DOOM proportion: 32/200 of screen height.
# For H=600: 600 * 32 // 200 = 96 px.
HUD_H    = 96
TEX_SIZE = 64

ASSETS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _try_load(fname):
    """Return a pygame SRCALPHA Surface from assets/fname, or None."""
    path = os.path.join(ASSETS_DIR, fname)
    if not os.path.exists(path):
        return None
    try:
        return pygame.image.load(path).convert_alpha()
    except Exception:
        return None

def _surf(arr):
    return pygame.surfarray.make_surface(arr.transpose(1, 0, 2).copy())

def _noise(arr, amp):
    n = np.random.default_rng(int(arr.sum()) & 0xFFFF).integers(
        -amp, amp + 1, arr.shape, dtype=np.int16)
    return np.clip(arr.astype(np.int16) + n, 0, 255).astype(np.uint8)


# ─────────────────────────────────────────────────────────────────────────────
# Wall textures  (procedural — kept from previous version)
# ─────────────────────────────────────────────────────────────────────────────

def _brick(base, mortar, bw=16, bh=8):
    T = TEX_SIZE
    arr = np.full((T, T, 3), base, dtype=np.uint8)
    arr = _noise(arr, 14)
    for y in range(0, T, bh):
        arr[y:y+2, :] = mortar
    for row in range(T // bh):
        y0, y1 = row * bh + 2, (row + 1) * bh
        off = (row % 2) * (bw // 2)
        for x in range(off, T, bw):
            arr[y0:y1, x:x+2] = mortar
    hl = np.clip(np.array(base, np.int16) + 40, 0, 255).astype(np.uint8).tolist()
    for row in range(T // bh):
        y0 = row * bh + 2
        off = (row % 2) * (bw // 2)
        for x in range(off + 2, T, bw):
            x1 = min(T, x + bw - 2)
            arr[y0:y0+1, x:x1] = hl
            arr[y0:y0+5, x:x+1] = hl
    return _surf(arr)

def _stone(base, mortar, bw=32, bh=16):
    T = TEX_SIZE
    arr = np.full((T, T, 3), base, dtype=np.uint8)
    arr = _noise(arr, 22)
    for y in range(0, T, bh):
        arr[y:y+2, :] = mortar
    for row in range(T // bh):
        y0, y1 = row * bh + 2, (row + 1) * bh
        off = (row % 2) * (bw // 2)
        for x in range(off, T, bw):
            arr[y0:y1, x:x+2] = mortar
    return _surf(arr)

def _wood():
    T = TEX_SIZE
    arr = np.full((T, T, 3), (115, 72, 42), dtype=np.uint8)
    arr = _noise(arr, 8)
    rng2 = np.random.default_rng(7)
    for x in range(0, T, 3):
        v = int(rng2.integers(-22, 23))
        col = np.clip([115 + v, 72 + v // 2, 42], 0, 255).astype(np.uint8)
        arr[:, x:x+2] = col
    for y in range(0, T, 10):
        arr[y:y+1, :] = np.clip(arr[y:y+1].astype(np.int16) - 18, 0, 255).astype(np.uint8)
    return _surf(arr)

def _door():
    T = TEX_SIZE
    arr = np.full((T, T, 3), (105, 105, 115), dtype=np.uint8)
    arr[:3, :]   = (55, 55, 65);  arr[-3:, :] = (55, 55, 65)
    arr[:, :3]   = (55, 55, 65);  arr[:, -3:] = (55, 55, 65)
    arr[5:T-5, 5:T-5]   = (128, 128, 138)
    arr[5:7,   5:T-5]   = (75, 75, 85)
    arr[T-7:T-5, 5:T-5] = (75, 75, 85)
    arr[5:T-5, 5:7]     = (75, 75, 85)
    arr[5:T-5, T-7:T-5] = (75, 75, 85)
    arr[0:2, :]  = (170, 170, 180)
    arr[:, 0:2]  = (170, 170, 180)
    arr = _noise(arr, 5)
    return _surf(arr)

def build_textures():
    return {
        1: _brick((132, 102, 66),  (52, 40, 26)),
        2: _stone((98,  100, 122), (42, 44, 56)),
        3: _brick((128, 38,  28),  (52, 14, 10)),
        4: _stone((68,  92,  58),  (32, 48, 28)),
        5: _wood(),
        6: _door(),
    }

def build_tex_strips(textures):
    strips = {}
    for tile, tex in textures.items():
        cols = []
        for x in range(TEX_SIZE):
            s = pygame.Surface((1, TEX_SIZE))
            s.blit(tex, (-x, 0))
            cols.append(s)
        strips[tile] = cols
    return strips


# ─────────────────────────────────────────────────────────────────────────────
# HUD digits  — FreeDoom ammnum*.png (DOOM yellow status-bar font)
# ─────────────────────────────────────────────────────────────────────────────

def _digit_fallback(d, dw=22, dh=34):
    """Procedural 7-segment fallback digit."""
    s = pygame.Surface((dw, dh), pygame.SRCALPHA)
    c, t = (180, 215, 48), 4
    segs = [
        [1,1,1,0,1,1,1],[0,0,1,0,0,1,0],[1,0,1,1,1,0,1],[1,0,1,1,0,1,1],
        [0,1,1,1,0,1,0],[1,1,0,1,0,1,1],[1,1,0,1,1,1,1],[1,0,1,0,0,1,0],
        [1,1,1,1,1,1,1],[1,1,1,1,0,1,1],
    ]
    if not (0 <= d <= 9):
        return s
    top, tl, tr, mid, bl, br, bot = segs[d]
    if top: pygame.draw.rect(s, c, (t,    0,       dw-t*2, t))
    if bot: pygame.draw.rect(s, c, (t,    dh-t,    dw-t*2, t))
    if mid: pygame.draw.rect(s, c, (t,    dh//2-1, dw-t*2, t))
    if tl:  pygame.draw.rect(s, c, (0,    t,       t, dh//2-t))
    if tr:  pygame.draw.rect(s, c, (dw-t, t,       t, dh//2-t))
    if bl:  pygame.draw.rect(s, c, (0,    dh//2,   t, dh//2-t))
    if br:  pygame.draw.rect(s, c, (dw-t, dh//2,   t, dh//2-t))
    return s


def build_digits():
    """Load FreeDoom ammnum*.png digits scaled to fit HUD_H, or fall back to 7-seg."""
    # DOOM's ammnum glyphs are ~15/32 of the status bar height.
    target_h = HUD_H * 15 // 32   # = 45 for HUD_H=96
    out = {}
    for d in range(10):
        raw = _try_load(f"ammnum{d}.png")
        if raw is None:
            return {i: _digit_fallback(i) for i in range(10)}
        rw, rh = raw.get_size()
        dw = max(1, rw * target_h // max(rh, 1))
        out[d] = pygame.transform.scale(raw, (dw, target_h))
    return out


def _blit_number(surf, digits, n, right_x, y, ndigits=3):
    """Blit n right-aligned: the rightmost digit's right edge is at right_x."""
    n   = max(0, min(n, 10**ndigits - 1))
    dw  = digits[0].get_width()
    gap = max(1, dw // 10)
    s   = str(n)
    # Start from the rightmost digit and work left
    x = right_x - dw
    for ch in reversed(s):
        surf.blit(digits[int(ch)], (x, y))
        x -= (dw + gap)


# ─────────────────────────────────────────────────────────────────────────────
# HUD background  — FreeDoom stbar.png or procedural fallback
# ─────────────────────────────────────────────────────────────────────────────

def _procedural_hud_bg(screen_w):
    s = pygame.Surface((screen_w, HUD_H))
    s.fill((68, 68, 68))
    pygame.draw.line(s, (150, 150, 150), (0, 0), (screen_w, 0))
    pygame.draw.line(s, (120, 120, 120), (0, 1), (screen_w, 1))
    mid = screen_w // 2
    # Left ammo panel
    pygame.draw.rect(s, (42, 42, 42), (0, 0, 145, HUD_H))
    pygame.draw.line(s, (110, 110, 110), (145, 0), (145, HUD_H))
    # Right kills panel
    pygame.draw.rect(s, (42, 42, 42), (screen_w - 165, 0, 165, HUD_H))
    pygame.draw.line(s, (110, 110, 110), (screen_w - 165, 0), (screen_w - 165, HUD_H))
    # Center face panel
    pygame.draw.rect(s, (50, 50, 50), (mid - 34, 2, 68, HUD_H - 4))
    pygame.draw.rect(s, (35, 35, 35), (mid - 34, 2, 68, HUD_H - 4), 1)
    return s


def build_hud_bg(screen_w):
    """
    Returns (Surface, doom_style: bool).
    doom_style=True  → stbar.png background; use DOOM-accurate pixel positions.
    doom_style=False → procedural grey bars; use labelled positions.
    """
    raw = _try_load("stbar.png")
    if raw:
        s = pygame.transform.scale(raw, (screen_w, HUD_H))
        return s, True
    return _procedural_hud_bg(screen_w), False


# ─────────────────────────────────────────────────────────────────────────────
# HUD face  — FreeDoom stfst*.png sprites
# ─────────────────────────────────────────────────────────────────────────────

def _face_fallback(health, god=False):
    FW, FH = 56, 50
    s = pygame.Surface((FW, FH), pygame.SRCALPHA)
    cx, cy = FW // 2, FH // 2
    skin = (215, 172, 128) if health > 0 else (145, 105, 82)
    pygame.draw.ellipse(s, skin, (3, 3, FW-6, FH-6))
    if god:
        pygame.draw.ellipse(s, (255, 220, 50), (1, 1, FW-2, FH-2), 3)
        ec = (255, 210, 0)
    elif health > 60: ec = (55,  55, 210)
    elif health > 30: ec = (200, 110, 50)
    else:             ec = (210,  30, 30)
    if health > 0:
        pygame.draw.ellipse(s, (255,255,255), (cx-14, cy-10, 10, 9))
        pygame.draw.ellipse(s, (255,255,255), (cx+4,  cy-10, 10, 9))
        pygame.draw.circle(s, ec, (cx-10, cy-7), 3)
        pygame.draw.circle(s, ec, (cx+8,  cy-7), 3)
        if health > 60:
            pygame.draw.arc(s, (90,55,55), pygame.Rect(cx-7,cy+4,14,10), 0, math.pi, 2)
        elif health > 30:
            pygame.draw.lines(s, (100,55,55), False,
                              [(cx-8,cy+10),(cx,cy+6),(cx+8,cy+10)], 2)
        else:
            pygame.draw.ellipse(s, (75,35,35),   (cx-7, cy+3, 14, 11))
            pygame.draw.ellipse(s, (140,18,18),  (cx-5, cy+4, 10,  8))
    else:
        for ox in [-10, 4]:
            pygame.draw.line(s, (200,30,30), (cx+ox,cy-12), (cx+ox+8,cy-4), 2)
            pygame.draw.line(s, (200,30,30), (cx+ox+8,cy-12), (cx+ox,cy-4), 2)
        pygame.draw.arc(s, (90,55,55), pygame.Rect(cx-8,cy+3,16,11), 0, math.pi, 2)
    return s


def build_faces():
    # Scale FreeDoom face sprites to fill the face widget slot in the stbar.
    # Original DOOM face is 34×32 pixels; at 3× → 102×96.
    # We use a slightly smaller blit so it doesn't bleed into neighbour slots.
    FACE_W = HUD_H * 34 // 32   # proportional: 102 for HUD_H=96
    FACE_H = HUD_H               # full height of the status bar
    face_files = {
        100: "stfst00.png",
        70:  "stfst10.png",
        50:  "stfst20.png",
        30:  "stfst30.png",
        10:  "stfst40.png",
        0:   "stfdead0.png",
    }
    out = {}
    for hp, fname in face_files.items():
        raw = _try_load(fname)
        out[hp] = pygame.transform.scale(raw, (FACE_W, FACE_H)) if raw else _face_fallback(hp)
    raw_god = _try_load("stfgod0.png")
    out["god"] = (pygame.transform.scale(raw_god, (FACE_W, FACE_H))
                  if raw_god else _face_fallback(100, god=True))
    return out


def get_face(faces, health, god_mode):
    if god_mode:
        return faces["god"]
    for t in [100, 70, 50, 30, 10, 0]:
        if health >= t:
            return faces[t]
    return faces[0]


# ─────────────────────────────────────────────────────────────────────────────
# Enemy sprites  — FreeDoom poss* walk & death chain
# ─────────────────────────────────────────────────────────────────────────────

def _enemy_fallback(sz, frame=0, dead=False):
    s = pygame.Surface((sz, sz), pygame.SRCALPHA)
    if sz < 6:
        s.fill((180, 50, 50, 200))
        return s
    cx, cy = sz // 2, sz // 2
    if dead:
        pygame.draw.ellipse(s, (150, 20, 20, 210),
                            (cx - sz//3, cy + sz//6, sz*2//3, sz//5))
        return s
    sc = sz / 48.0
    def r(x, y, w, h, col):
        pygame.draw.rect(s, col,
            (int(cx + x*sc), int(cy + y*sc), max(1, int(w*sc)), max(1, int(h*sc))))
    lo = (frame % 2) * int(4 * sc)
    r(-8,  18+lo,  7,  4, (55, 38, 28));  r( 1, 18-lo,  7,  4, (55, 38, 28))
    r(-7,   8+lo,  6, 12, (95, 90, 60));  r( 1,  8-lo,  6, 12, (95, 90, 60))
    r(-10, -8,    20, 17, (55, 75, 55))
    r(-10, -8,     4,  5, (80, 100, 75)); r(6, -8,  4, 5, (80, 100, 75))
    r(-10,  7,    20,  3, (45, 35, 22))
    arm = int(3 * sc)
    r(-16, -6+arm, 6, 12, (55, 75, 55)); r(10, -6-arm, 6, 12, (55, 75, 55))
    r( 14, -2-arm,10,  4, (35, 35, 38)); r(22, -4-arm, 3,  3, (25, 25, 28))
    r(-3,  -12,    6,  5, (185, 155, 120))
    r(-9,  -22,   18, 12, (185, 155, 120))
    r(-10, -24,   20,  5, (45, 55, 45)); r(-8, -26, 16, 4, (40, 50, 40))
    r(-7,  -19,    4,  4, (220, 40, 40)); r(3, -19,  4, 4, (220, 40, 40))
    r(-5,  -12,   10,  2, (70, 35, 35))
    return s


def build_enemy_sprites():
    """
    Returns {sz: {'walk': [f0, f1], 'death': [d0, d1, d2, d3]}}.
    Walk frames cycle for the alive animation.
    Death frames play in sequence then hold on the last (corpse).
    """
    raw_walk = [_try_load("possa1.png"), _try_load("possb1.png")]
    raw_death = []
    for name in ("possh0.png", "possi0.png", "possj0.png", "possk0.png", "possl0.png"):
        s = _try_load(name)
        if s:
            raw_death.append(s)

    sizes = [8, 16, 24, 32, 48, 64, 96]
    out   = {}
    for sz in sizes:
        walk = []
        for i, rw in enumerate(raw_walk):
            walk.append(pygame.transform.scale(rw, (sz, sz)) if rw
                        else _enemy_fallback(sz, i))
        if raw_death:
            death = [pygame.transform.scale(rd, (sz, sz)) for rd in raw_death]
        else:
            death = [_enemy_fallback(sz, dead=True)]
        out[sz] = {'walk': walk, 'death': death}
    return out


def pick_enemy_size(enemy_sprites, proj_h):
    sizes = sorted(enemy_sprites)
    for s in sizes:
        if s >= proj_h:
            return s
    return sizes[-1]


def draw_enemies(surf, px, py, pa, enemies, zbuf, enemy_sprites, ray_count, fov, W, H):
    HALF_H = H // 2
    visible = []
    for e in enemies:
        dx = e.x - px; dy = e.y - py
        e.dist = math.hypot(dx, dy)
        if e.dist >= 0.3:
            visible.append(e)
    visible.sort(key=lambda e: -e.dist)

    for e in visible:
        dx = e.x - px; dy = e.y - py
        angle_to = math.atan2(dy, dx) - pa
        while angle_to >  math.pi: angle_to -= 2 * math.pi
        while angle_to < -math.pi: angle_to += 2 * math.pi
        if abs(angle_to) > fov * 0.65:
            continue
        proj_dist = e.dist * math.cos(angle_to)
        if proj_dist <= 0.15:
            continue

        proj_h   = int(H / proj_dist)
        proj_w   = proj_h
        screen_x = int((0.5 + angle_to / fov) * W) - proj_w // 2
        top_y    = HALF_H - proj_h // 2

        center_col = max(0, min(ray_count - 1,
                                (screen_x + proj_w // 2) // (W // ray_count)))
        if zbuf[center_col] < proj_dist:
            continue

        sz = pick_enemy_size(enemy_sprites, max(4, proj_h))
        if not e.alive:
            death_list = enemy_sprites[sz]['death']
            fi = min(getattr(e, 'death_frame', len(death_list) - 1),
                     len(death_list) - 1)
            frame_surf = death_list[fi]
        else:
            walk_list  = enemy_sprites[sz]['walk']
            frame_surf = walk_list[e.anim % len(walk_list)]

        scaled = pygame.transform.scale(frame_surf, (max(1, proj_w), max(1, proj_h)))
        col_w  = W // ray_count
        for col_off in range(0, proj_w, col_w):
            col_idx = (screen_x + col_off) // col_w
            if 0 <= col_idx < len(zbuf) and zbuf[col_idx] >= proj_dist:
                blit_x = screen_x + col_off
                if 0 <= blit_x < W:
                    surf.blit(scaled, (blit_x, top_y),
                              area=pygame.Rect(col_off, 0, col_w, max(1, proj_h)))


# ─────────────────────────────────────────────────────────────────────────────
# Weapon sprite  — FreeDoom pisga0 / pisfa0
# ─────────────────────────────────────────────────────────────────────────────

def _pistol_fallback(fire=False):
    W, H = 220, 170
    s = pygame.Surface((W, H), pygame.SRCALPHA)
    cx = W // 2
    pygame.draw.rect(s, (205, 162, 118), (cx-22, H-62, 44, 42))
    pygame.draw.rect(s, (200, 156, 112), (cx-26, H-48, 12, 22))
    for fx, fw in [(-20,10),(-9,10),(2,10),(13,10)]:
        pygame.draw.rect(s, (198, 158, 114), (cx+fx, H-78, fw, 18))
    pygame.draw.rect(s, (58, 58, 64),  (cx-9,  H-96, 18, 38))
    pygame.draw.rect(s, (70, 70, 76),  (cx-8,  H-95,  4, 36))
    pygame.draw.rect(s, (45, 45, 50),  (cx+2,  H-85,  5, 10))
    pygame.draw.rect(s, (42, 42, 46),  (cx-5,  H-108, 10, 16))
    pygame.draw.rect(s, (32, 32, 36),  (cx-3,  H-112,  6,  6))
    pygame.draw.rect(s, (52, 52, 58),  (cx-11, H-70, 22,  4))
    pygame.draw.rect(s, (52, 52, 58),  (cx-11, H-70,  4, 12))
    pygame.draw.rect(s, (52, 52, 58),  (cx+7,  H-70,  4, 12))
    if fire:
        pygame.draw.circle(s, (255, 218,  70, 240), (cx, H-116), 16)
        pygame.draw.circle(s, (255, 255, 180, 220), (cx, H-116),  9)
        for sx, sy in [(cx,H-134),(cx-18,H-116),(cx+18,H-116),(cx-12,H-130),(cx+12,H-130)]:
            pygame.draw.line(s, (255, 200, 50, 180), (cx, H-116), (sx, sy), 3)
    return s


def build_weapon_sprites():
    raw_idle = _try_load("pisga0.png")
    raw_fire = _try_load("pisfa0.png")
    out = {}
    for key, raw, fire in [("idle", raw_idle, False), ("fire", raw_fire, True)]:
        if raw:
            rw, rh = raw.get_size()
            scale  = max(3, 160 // max(rh, 1))
            scaled = pygame.transform.scale(raw, (rw * scale, rh * scale))
            if fire:
                # Overlay muzzle flash
                flash = pygame.Surface(scaled.get_size(), pygame.SRCALPHA)
                cx2, cy2 = scaled.get_width() // 2, scaled.get_height() // 5
                pygame.draw.circle(flash, (255, 218,  70, 200), (cx2, cy2), 22)
                pygame.draw.circle(flash, (255, 255, 180, 160), (cx2, cy2), 13)
                combined = scaled.copy()
                combined.blit(flash, (0, 0))
                out[key] = combined
            else:
                out[key] = scaled
        else:
            out[key] = _pistol_fallback(fire)
    return out


def draw_weapon(surf, weapon_sprites, firing_t, W, H):
    frame = weapon_sprites["fire"] if firing_t > 0 else weapon_sprites["idle"]
    fw, fh = frame.get_size()
    bob = int(math.sin(pygame.time.get_ticks() / 250.0) * 4)
    x = W // 2 - fw // 2
    y = H - HUD_H - fh + 20 + bob
    surf.blit(frame, (x, y))


# ─────────────────────────────────────────────────────────────────────────────
# HUD draw  — DOOM-accurate layout when stbar.png present
# ─────────────────────────────────────────────────────────────────────────────

def draw_hud(surf, hud_bg_info, faces, digits, W, H,
             health, ammo, kills, total, god_mode, hard_mode, debug_mode):
    hud_surf, doom_style = hud_bg_info
    y0 = H - HUD_H
    surf.blit(hud_surf, (0, y0))

    dh = digits[0].get_height()
    dw = digits[0].get_width()
    # Vertically center numbers in the bar (original DOOM digits sit ~3px from top
    # of the 32px stbar → proportionally scaled)
    ny = y0 + HUD_H * 3 // 32 + 3   # +3 px: aligns digits with stbar number slots

    if doom_style:
        # ── DOOM-accurate positions (right-edge of each 3-digit field) ────
        # All coordinates are in the classic 320×32 STBAR pixel space, scaled
        # to our window.  Right-edge values come from the Doom source / wiki:
        #   ammo field right  ≈ x=70  (field starts at x=44, 3×~9px digits)
        #   health field right≈ x=107
        #   frags/kills right ≈ x=141 (just left of face at x=143)
        #   face left edge      x=143, width=34
        #   armor field right ≈ x=234
        sc = W / 320          # = 3.0 for W=960
        _blit_number(surf, digits, ammo,   int( 30 * sc), ny, 3)
        _blit_number(surf, digits, health, int( 91 * sc), ny, 3)
        # Kills in the frags slot (2-digit display, right-aligned just before face)
        _blit_number(surf, digits, kills,  int(135 * sc), ny, 2)
        # Face widget — scaled to fill the stbar face slot exactly
        face      = get_face(faces, health, god_mode)
        face_x    = int(143 * sc)
        face_w    = int(34  * sc)
        face_blit = pygame.transform.scale(face, (face_w, HUD_H))
        surf.blit(face_blit, (face_x, y0))
        # Armor
        _blit_number(surf, digits, 0,      int(234 * sc), ny, 3)
        # Mode flags — bottom-right corner of the bar
        sf = pygame.font.SysFont("monospace", 11, bold=True)
        flags = []
        if god_mode:   flags.append(("GOD",  (255, 215, 45)))
        if hard_mode:  flags.append(("HARD", (220,  70, 70)))
        if debug_mode: flags.append(("DBG",  (100, 180, 220)))
        for i, (txt, col) in enumerate(flags):
            surf.blit(sf.render(txt, True, col), (W - 112 + i * 40, y0 + HUD_H - 14))

    else:
        # ── Procedural layout ─────────────────────────────────────────────
        lbl = pygame.font.SysFont("monospace", 13, bold=True)
        mid = W // 2
        ly  = y0 + HUD_H - 16
        surf.blit(lbl.render("AMMO", True, (155, 155, 95)), (8, ly))
        _blit_number(surf, digits, ammo,   0,        ny, 3)
        surf.blit(lbl.render("HLTH", True, (155, 155, 95)), (158, ly))
        _blit_number(surf, digits, health, 150,      ny, 3)
        face = get_face(faces, health, god_mode)
        surf.blit(face, (mid - face.get_width() // 2,
                         y0 + (HUD_H - face.get_height()) // 2))
        surf.blit(lbl.render("ARMR", True, (155, 155, 95)), (mid + 44, ly))
        _blit_number(surf, digits, 0,       mid + 150, ny, 3)
        surf.blit(lbl.render("KILL", True, (155, 155, 95)), (W - 155, y0 + 6))
        surf.blit(lbl.render(f"{kills}/{total}", True, (180, 215, 48)),
                  (W - 155, y0 + 24))
        flags = []
        if god_mode:   flags.append(("GOD",  (255, 215, 45)))
        if hard_mode:  flags.append(("HARD", (220,  70, 70)))
        if debug_mode: flags.append(("DBG",  (100, 180, 220)))
        for i, (txt, col) in enumerate(flags):
            surf.blit(lbl.render(txt, True, col), (W - 155 + i * 52, y0 + 42))

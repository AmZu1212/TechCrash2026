#!/usr/bin/env python3
"""
fetch_assets.py — Download FreeDoom sprite assets for the DOOM Clone game.
Run once before playing:  python fetch_assets.py

License: FreeDoom assets are BSD 3-Clause
         https://github.com/freedoom/freedoom/blob/master/COPYING
"""
import os
import urllib.request

BASE  = "https://raw.githubusercontent.com/freedoom/freedoom/master/"
OUT   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")

# local filename → path within the freedoom repo
ASSETS = {
    # Status-bar faces  (graphics/)
    "stfst00.png":  "graphics/stfst00.png",   # neutral  (>60 HP)
    "stfst10.png":  "graphics/stfst10.png",   # grimace  (>40 HP)
    "stfst20.png":  "graphics/stfst20.png",   # hurt     (>20 HP)
    "stfst30.png":  "graphics/stfst30.png",   # bad hurt (>10 HP)
    "stfst40.png":  "graphics/stfst40.png",   # nearly dead
    "stfdead0.png": "graphics/stfdead0.png",  # dead
    "stfgod0.png":  "graphics/stfgod0.png",   # god mode
    # Pistol weapon  (sprites/)
    "pisga0.png":   "sprites/pisga0.png",     # idle
    "pisfa0.png":   "sprites/pisfa0.png",     # fire
    # Former-human enemy  (sprites/)
    "possa1.png":   "sprites/possa1.png",     # walk frame A
    "possb1.png":   "sprites/possb1.png",     # walk frame B
    "possh0.png":   "sprites/possh0.png",     # death frame 1
    "possi0.png":   "sprites/possi0.png",     # death frame 2
    "possj0.png":   "sprites/possj0.png",     # death frame 3
    "possk0.png":   "sprites/possk0.png",     # death frame 4
    "possl0.png":   "sprites/possl0.png",     # death frame 5 (flat corpse)
    # Status bar background
    "stbar.png":    "graphics/stbar.png",
    # Ammo-digit font (DOOM yellow numbers for the HUD)
    "ammnum0.png":  "graphics/ammnum0.png",
    "ammnum1.png":  "graphics/ammnum1.png",
    "ammnum2.png":  "graphics/ammnum2.png",
    "ammnum3.png":  "graphics/ammnum3.png",
    "ammnum4.png":  "graphics/ammnum4.png",
    "ammnum5.png":  "graphics/ammnum5.png",
    "ammnum6.png":  "graphics/ammnum6.png",
    "ammnum7.png":  "graphics/ammnum7.png",
    "ammnum8.png":  "graphics/ammnum8.png",
    "ammnum9.png":  "graphics/ammnum9.png",
}


def main():
    os.makedirs(OUT, exist_ok=True)
    ok = skipped = failed = 0
    for fname, path in ASSETS.items():
        dest = os.path.join(OUT, fname)
        if os.path.exists(dest):
            print(f"  skip  {fname}")
            skipped += 1
            continue
        url = BASE + path
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "doom-clone-fetcher/1.0"})
            with urllib.request.urlopen(req, timeout=15) as r:
                data = r.read()
            with open(dest, "wb") as f:
                f.write(data)
            print(f"  got   {fname}  ({len(data):,} bytes)")
            ok += 1
        except Exception as e:
            print(f"  miss  {fname}  ({e})")
            failed += 1

    print(f"\n  {ok} downloaded, {skipped} already present, {failed} not found")
    print(f"  assets -> {OUT}")
    if failed:
        print("  (missing files will use procedural fallbacks — game still works)")


if __name__ == "__main__":
    main()

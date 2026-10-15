# dmgbuild settings for the Stint release DMG (used by scripts/release.sh).
#   dmgbuild -s scripts/dmg/settings.py -D app=<Stint.app> -D background=<bg.tiff> "Stint" <out.dmg>
import os.path

app = defines["app"]            # noqa: F821  (dmgbuild injects `defines`)
background = defines["background"]  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# window: 600 × 400 points; scripts/dmg/background.swift draws the arrow for these positions
window_rect = ((200, 120), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {app_name: (160, 190), "Applications": (440, 190)}

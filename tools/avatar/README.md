# 3D replay check (MediaPipe world landmarks)

How far the app's 3D figure can be trusted, measured on GolfDB (60 down-the-line + 59 face-on, 160 px) and 40 HD down-the-line pro swings.

    python tools/avatar/w3d.py <out> golfdb <golfdb data dir> down-the-line 0 60
    python tools/avatar/w3d.py <out> golfdb <golfdb data dir> face-on 0 60
    python tools/avatar/w3d.py <out> hd <hd_pipeline out dirs...>
    python tools/avatar/w3d_stats.py <out>     # shoulder/hip turn, bone-length CV, real-time vs slow-mo
    python tools/avatar/w3d_ll.py <out> 0.15   # WorldDisplaySmoother prototype

Results (2026-11-08):
- Depth is view-dependent. Shoulder turn at the top has a median of 94° filmed down the line but 39° filmed face-on, on the same tour players (about 90° expected). The 3D replay therefore stays at the original camera, with no rotation and no angle numbers.
- Raw forearm length varies by about 13% within a swing. The app's avatar (GolfAvatarPose) already draws fixed bone lengths, so arms do not stretch on screen.
- WorldDisplaySmoother (σt 0.045 s, σs 0.15 m) roughly halves hand jitter (35 to 17 mm down the line, 65 to 25 mm face-on) and cuts the real-time vs slow-mo shoulder-turn difference from p90 39° to 20°. Hands at impact move 2 cm (median).

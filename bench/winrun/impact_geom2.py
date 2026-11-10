import numpy as np
W, H = 1080, 1920


def ground(u, v, f, yh):
    cx, cy = W / 2, H / 2
    phi = np.arctan2(cy - yh, f)
    d = np.array([(u - cx) / f, (v - cy) / f, 1.0])
    c, s = np.cos(phi), np.sin(phi)
    dw = np.array([d[0], c * d[1] + s * d[2], -s * d[1] + c * d[2]])
    t = 1.0 / dw[1]
    return np.array([dw[0] * t, dw[2] * t])


def ang(p, q, f, yh=715):
    v = ground(*q, f, yh) - ground(*p, f, yh)
    return round(float(np.degrees(np.arctan2(v[0], v[1]))), 1)


for name, p, q in [("shoulders", (353.6, 812.0), (325.3, 787.7)), ("hips", (227.6, 1022.0), (210.7, 1007.6)),
                   ("toes_eye", (330, 1430), (310, 1360)), ("ball_to_post", (730, 1320), (668, 818))]:
    print(name, [ang(p, q, f) for f in (1150, 1390, 1650)])

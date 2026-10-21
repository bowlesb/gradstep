"""Small synthetic figures with known panels for geometry tests."""
import numpy as np


def canvas(W=400, H=200):
    return np.full((H, W, 3), 255, np.uint8)


def draw_box(img, b, v=0, fill=False):
    x0, y0, x1, y1 = b
    if fill:
        img[y0:y1, x0:x1] = v
    else:
        img[y0, x0:x1] = v; img[y1 - 1, x0:x1] = v
        img[y0:y1, x0] = v; img[y0:y1, x1 - 1] = v
    return img


def two_panel():
    """Two framed 'plots' side by side, each with a letter above and tick labels below."""
    img = canvas()
    panels = []
    for x in (20, 220):
        draw_box(img, (x, 30, x + 160, 150))            # axes frame
        draw_box(img, (x, 10, x + 10, 22), fill=True)    # letter above
        draw_box(img, (x + 20, 160, x + 140, 168), fill=True)  # tick labels below
        panels.append([x, 10, x + 160, 168])
    return img, panels

// Original deterministic fixture artwork. Pixel-letter shapes are authored here;
// no external fonts, images, drawing package, or network input are used.
import { writeFileSync } from 'node:fs';
import { encodePNG } from '../../../workers/reader-renderer/png.mjs';
const glyphs = {
  A:['01110','10001','10001','11111','10001','10001','10001'], C:['01111','10000','10000','10000','10000','10000','01111'],
  D:['11110','10001','10001','10001','10001','10001','11110'], E:['11111','10000','10000','11110','10000','10000','11111'],
  G:['01111','10000','10000','10111','10001','10001','01111'], H:['10001','10001','10001','11111','10001','10001','10001'],
  I:['11111','00100','00100','00100','00100','00100','11111'], K:['10001','10010','10100','11000','10100','10010','10001'],
  L:['10000','10000','10000','10000','10000','10000','11111'], M:['10001','11011','10101','10101','10001','10001','10001'],
  O:['01110','10001','10001','10001','10001','10001','01110'], P:['11110','10001','10001','11110','10000','10000','10000'],
  Q:['01110','10001','10001','10001','10101','10010','01101'], S:['01111','10000','10000','01110','00001','00001','11110'],
  T:['11111','00100','00100','00100','00100','00100','00100'], U:['10001','10001','10001','10001','10001','10001','01110'],
  V:['10001','10001','10001','10001','10001','01010','00100'], W:['10001','10001','10001','10101','10101','11011','10001'],
  '+':['00000','00100','00100','11111','00100','00100','00000'], ' ':['00000','00000','00000','00000','00000','00000','00000'],
};
const width = 1000, height = 360, ink = [69, 73, 161], pale = [239, 240, 252], green = [228, 245, 237];
function canvas() {
  const pixels = Buffer.alloc(width * height * 4, 255);
  const box = (x, y, w, h, color) => { for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) { const i = (yy * width + xx) * 4; pixels[i] = color[0]; pixels[i + 1] = color[1]; pixels[i + 2] = color[2]; } };
  const panel = (x, y, w, h, color) => { box(x, y, w, h, ink); box(x + 3, y + 3, w - 6, h - 6, color); };
  const arrow = (x, y, length) => { box(x, y - 3, length - 12, 6, ink); for (let k = 0; k < 13; k++) box(x + length - 13 + k, y - (12 - k), 1, 2 * (12 - k) + 1, ink); };
  const text = (value, center, y, scale = 5) => { let x = Math.round(center - (value.length * 6 - 1) * scale / 2); for (const c of value) { for (let row = 0; row < 7; row++) for (let col = 0; col < 5; col++) if (glyphs[c][row][col] === '1') box(x + col * scale, y + row * scale, scale, scale, ink); x += 6 * scale; } };
  return { pixels, box, panel, arrow, text };
}
const a = canvas();
a.panel(22, 38, 175, 88, pale); a.panel(22, 222, 175, 88, green); a.panel(380, 115, 238, 124, pale); a.panel(805, 115, 173, 124, green);
a.arrow(197, 82, 96); a.box(287, 82, 6, 86, ink); a.arrow(287, 165, 93); a.arrow(618, 165, 187); a.arrow(197, 266, 524); a.box(715, 204, 6, 65, ink); a.arrow(715, 207, 90);
a.text('Q + K', 110, 66, 4); a.text('V', 110, 246, 6); a.text('WEIGHTS', 499, 145, 5); a.text('OUT', 891, 158, 6);
for (let i = 0; i < 4; i++) a.box(422 + i * 42, 201, 25, 14, [151, 155, 218]);
writeFileSync(new URL('./assets/attention.png', import.meta.url), encodePNG(width, height, a.pixels));
const b = canvas();
b.panel(25, 100, 250, 150, pale); b.panel(375, 100, 250, 150, green); b.panel(725, 100, 250, 150, pale); b.arrow(275, 174, 100); b.arrow(625, 174, 100);
b.text('DATA', 150, 130, 6); b.text('MODEL', 500, 130, 6); b.text('CHECK', 850, 130, 6);
for (let i = 0; i < 3; i++) { b.box(68 + i * 54, 199, 32, 22, [151, 155, 218]); b.box(417 + i * 54, 199, 32, 22, [98, 163, 136]); b.box(770 + i * 52, 199, 32, 22, [151, 155, 218]); }
writeFileSync(new URL('./assets/evaluation.png', import.meta.url), encodePNG(width, height, b.pixels));

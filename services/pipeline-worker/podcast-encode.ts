// Mono AAC-LC (~64 kbit/s) in MP4 with chapter markers, via ffmpeg in the worker
// container, then verified with ffprobe. Runs as an awaited subprocess inside the
// bounded podcast worker thread; temporary files live in the request's /tmp and
// are always removed. Nothing from the audio or transcript is logged.
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AudioEncoder, EncodedAudio } from '../../supabase/functions/_shared/podcast-worker.ts';

export const ENCODER_SETTINGS = Object.freeze({ codec: 'aac', bitrate: '64k', channels: 1, sample_rate: 24000,
  loudness: 'loudnorm=I=-16:TP=-1.5:LRA=11', container: 'mp4', version: 'podcast-encoder-v1' });

export type Spawner = typeof spawn;

/** Run a binary with no shell, a bounded output buffer and a hard deadline. */
export function run(spawner: Spawner, binary: string, args: string[], signal: AbortSignal, maxOutput = 1_048_576): Promise<string> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(new Error('encoder_deadline'));
    const child = spawner(binary, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { PATH: process.env.PATH ?? '/usr/bin:/bin' } });
    let out = '', size = 0, settled = false;
    const done = (error: Error | null) => {
      if (settled) return; settled = true;
      signal.removeEventListener('abort', abort);
      if (error) reject(error); else resolve(out);
    };
    const abort = () => { child.kill('SIGKILL'); done(new Error('encoder_deadline')); };
    signal.addEventListener('abort', abort, { once: true });
    child.stdout?.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > maxOutput) { child.kill('SIGKILL'); done(new Error('encoder_output_too_large')); return; }
      out += chunk.toString('utf8');
    });
    child.stderr?.on('data', () => { /* diagnostics may describe the file; never logged */ });
    child.on('error', () => done(new Error('encoder_unavailable')));
    child.on('close', status => done(status === 0 ? null : new Error('encoder_failed')));
  });
}

/** FFMETADATA1 escaping for chapter titles (=, ;, #, backslash, newline). */
export function ffmetadata(chapters: { title: string; start_ms: number; end_ms: number }[], title: string): string {
  const escape = (value: string) => value.replace(/[\r\n]+/g, ' ').replace(/([=;#\\])/g, '\\$1').slice(0, 200);
  return [';FFMETADATA1', `title=${escape(title)}`, 'comment=AI-generated audio from Gradstep',
    ...chapters.flatMap(c => ['[CHAPTER]', 'TIMEBASE=1/1000', `START=${Math.max(0, Math.round(c.start_ms))}`,
      `END=${Math.max(Math.round(c.start_ms) + 1, Math.round(c.end_ms))}`, `title=${escape(c.title)}`]), ''].join('\n');
}

export function ffmpegArguments(input: string, metadata: string, output: string): string[] {
  return ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-i', input, '-i', metadata,
    '-map', '0:a:0', '-map_metadata', '1', '-map_chapters', '1', '-af', ENCODER_SETTINGS.loudness,
    '-ac', '1', '-ar', String(ENCODER_SETTINGS.sample_rate), '-c:a', 'aac', '-b:a', ENCODER_SETTINGS.bitrate,
    '-movflags', '+faststart', '-f', 'mp4', output];
}

interface Probe { streams?: { codec_type?: string; codec_name?: string; codec_tag_string?: string; channels?: number; sample_rate?: string }[];
  format?: { duration?: string; format_name?: string }; chapters?: unknown[] }

/**
 * The probe must show exactly one mono 24 kHz AAC stream, the chapters and a duration. The MP4 muxer stores
 * chapters as a QuickTime text track (a `data` stream tagged `text`, which AVFoundation reads); nothing else is allowed.
 */
export function verifyProbe(json: string, chapterCount: number): number {
  let probe: Probe;
  try { probe = JSON.parse(json) as Probe; } catch { throw new Error('encoding_invalid'); }
  const streams = probe.streams ?? [];
  const audio = streams.filter(s => s.codec_type === 'audio');
  const others = streams.filter(s => s.codec_type !== 'audio');
  const duration = Number(probe.format?.duration);
  if (audio.length !== 1 || audio[0].codec_name !== 'aac' || audio[0].channels !== 1 || audio[0].sample_rate !== String(ENCODER_SETTINGS.sample_rate)
    || others.length > 1 || others.some(s => s.codec_type !== 'data' || s.codec_tag_string !== 'text')
    || !Number.isFinite(duration) || duration <= 0 || (probe.chapters ?? []).length !== chapterCount
    || !(probe.format?.format_name ?? '').includes('mp4')) throw new Error('encoding_invalid');
  return Math.round(duration * 1000);
}

export function ffmpegEncoder(options: { ffmpeg?: string; ffprobe?: string; spawner?: Spawner } = {}): AudioEncoder {
  const spawner = options.spawner ?? spawn, ffmpeg = options.ffmpeg ?? 'ffmpeg', ffprobe = options.ffprobe ?? 'ffprobe';
  return {
    async encode(wav, chapters, title, signal): Promise<EncodedAudio> {
      const dir = await mkdtemp(join(tmpdir(), 'gradstep-podcast-'));
      try {
        const input = join(dir, 'input.wav'), metadata = join(dir, 'chapters.txt'), output = join(dir, 'output.m4a');
        await writeFile(input, wav, { mode: 0o600 });
        await writeFile(metadata, ffmetadata(chapters, title), { mode: 0o600 });
        await run(spawner, ffmpeg, ffmpegArguments(input, metadata, output), signal);
        const durationMs = verifyProbe(await run(spawner, ffprobe, ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams',
          '-show_chapters', output], signal), chapters.length);
        const bytes = new Uint8Array(await readFile(output));
        return { bytes, durationMs, mediaType: 'audio/mp4', encoder: { ...ENCODER_SETTINGS } };
      } finally { await rm(dir, { recursive: true, force: true }); }
    },
  };
}

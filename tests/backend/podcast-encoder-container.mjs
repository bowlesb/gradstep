// Real-encoder check inside the worker image (ffmpeg/ffprobe from its Dockerfile). Run by
// scripts/check-podcast-encoder.py; zero spend: the input is labeled synthetic fixture audio.
import { checkScript, fixtureScript } from '../../supabase/functions/_shared/podcast-script.ts';
import { fixtureAudio, parseWav } from '../../supabase/functions/_shared/podcast-speech.ts';
import { ffmpegEncoder } from '../../services/pipeline-worker/podcast-encode.ts';

const paper = 'A synthetic paper body used only to exercise the encoder. It has a few sentences that are long enough to quote. '
  + 'The method section explains nothing real but provides verbatim passages for the fixture transcript. '
  + 'The results section claims nothing; it is only here for the encoder check in the worker image.';
const checked = checkScript(fixtureScript(paper, 'Encoder check'), paper, { fixture: true });
if (!checked.ok) throw new Error('fixture_invalid');
const wav = fixtureAudio(checked.script);
const pcm = parseWav(wav);
const third = Math.round(pcm.durationMs / 3);
const chapters = [{ title: 'One; =#\\ escaped', start_ms: 0, end_ms: third }, { title: 'Two', start_ms: third, end_ms: 2 * third },
  { title: 'Three', start_ms: 2 * third, end_ms: pcm.durationMs }];
const started = Date.now();
const encoded = await ffmpegEncoder().encode(wav, chapters, 'Encoder check', AbortSignal.timeout(120_000));
const bitsPerSecond = Math.round(encoded.bytes.byteLength * 8 / (encoded.durationMs / 1000));
console.log(JSON.stringify({ wav_ms: pcm.durationMs, encoded_ms: encoded.durationMs, bytes: encoded.bytes.byteLength,
  kbit_per_s: Math.round(bitsPerSecond / 1000), ms_to_encode: Date.now() - started, header: Buffer.from(encoded.bytes.subarray(4, 8)).toString('latin1') }));
if (Math.abs(encoded.durationMs - pcm.durationMs) > 1500) throw new Error('duration_mismatch');
if (bitsPerSecond > 90_000) throw new Error('bitrate_too_high');

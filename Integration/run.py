#!/usr/bin/env python3
"""Reproducible native integration suite. Run only AFTER independent review.
python3 Integration/run.py --binary /absolute/path/to/voice-remove
All fixtures live in a fresh temporary folder; no project media is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import queue
import threading
import subprocess
import tempfile
import time
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True, type=Path)
settings, remaining = parser.parse_known_args()
BINARY = settings.binary.resolve()
FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'


def run(args, timeout=90, check=True):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise AssertionError(f'{args}\nexit={result.returncode}\n{result.stderr[-12000:]}')
    return result


def probe(path):
    return json.loads(run([FFPROBE, '-v', 'error', '-show_streams', '-show_format', '-show_chapters', '-of', 'json', path]).stdout)


def content_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def video_hash(path, index):
    return run([FFMPEG, '-nostdin', '-v', 'error', '-i', path, '-map', f'0:{index}', '-c', 'copy', '-f', 'hash', '-hash', 'sha256', '-']).stdout


class NativeIntegration(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='voice-remove-integration-')
        self.root = Path(self.work.name)

    def tearDown(self):
        self.work.cleanup()

    def fixture(self, name='clip.MP4', channels=2, offset=0, duration=2.137, audio=True):
        path = self.root / name
        args = [FFMPEG, '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=128x72:rate=25:duration=2']
        if audio:
            expression = '0.08*sin(2*PI*220*t)' if channels == 1 else '0.08*sin(2*PI*220*t)|0.06*sin(2*PI*731*t)'
            source = f'aevalsrc={expression}:s=48000:d={duration}'
            if channels == 6:
                source = f'anullsrc=r=48000:cl=5.1:d={duration}'
            args += ['-itsoffset', str(offset), '-f', 'lavfi', '-i', source]
        args += ['-map', '0:v', '-c:v', 'libx264', '-threads', '1', '-pix_fmt', 'yuv420p']
        if audio:
            args += ['-map', '1:a', '-c:a', 'aac', '-b:a', '160k', '-metadata:s:a:0', 'language=deu']
        args += ['-metadata:s:v:0', 'language=eng', '-metadata', 'title=Keep this title', '-metadata', 'comment=Conversation suppression fixture', path]
        run(args)
        return path

    def output(self, source):
        return source.with_name(source.stem + '_voiceremoved' + source.suffix)

    def assert_clean(self):
        self.assertEqual(list(self.root.glob('.voiceremoved-*')), [])

    def assert_success(self, source, *flags):
        original = content_hash(source)
        stat = source.stat()
        result = run([BINARY, source, *flags])
        output = self.output(source)
        self.assertEqual(result.stdout.strip(), str(output))
        self.assertEqual(content_hash(source), original)
        self.assertEqual(source.stat().st_mtime_ns, stat.st_mtime_ns)
        self.assertTrue(output.is_file())
        self.assert_clean()
        before, after = probe(source), probe(output)
        for stream in before['streams']:
            if stream['codec_type'] == 'data':
                self.assertIn(f"DROP unsupported data stream {stream['index']}", result.stderr)
        source_video = [s for s in before['streams'] if s['codec_type'] == 'video']
        result_video = [s for s in after['streams'] if s['codec_type'] == 'video']
        self.assertEqual(len(source_video), len(result_video))
        for a, b in zip(source_video, result_video):
            self.assertEqual(video_hash(source, a['index']), video_hash(output, b['index']))
            self.assertEqual(a['disposition'], b['disposition'])
        a = next(s for s in before['streams'] if s['codec_type'] == 'audio')
        b = next(s for s in after['streams'] if s['codec_type'] == 'audio')
        self.assertEqual(a['channels'], b['channels'])
        self.assertEqual(b['codec_name'], 'aac')
        self.assertEqual(b['sample_rate'], '48000')
        self.assertLess(abs(float(a['start_time']) - float(b['start_time'])), 0.05)
        self.assertLess(abs(float(a['duration']) - float(b['duration'])), 0.05)
        self.assertEqual(b['tags']['language'], 'deu')
        self.assertEqual(before['format']['tags']['title'], after['format']['tags']['title'])
        return output

    def test_two_pass_distinct_stereo_audio_longer_than_video(self):
        source = self.fixture()
        output = self.assert_success(source, '--verify')
        audio = next(s for s in probe(output)['streams'] if s['codec_type'] == 'audio')
        self.assertGreater(float(audio['duration']), 2.10)
        # Native output need not be repeatable, but it must not silently become mono.
        pcm = subprocess.run([FFMPEG, '-v', 'error', '-i', str(output), '-map', '0:a:0', '-f', 'f32le', '-'], capture_output=True, check=True).stdout
        import array
        samples = array.array('f')
        samples.frombytes(pcm)
        self.assertTrue(any(abs(l - r) > 1e-6 for l, r in zip(samples[::2], samples[1::2])))

    def test_mono_one_pass_faststart(self):
        self.assert_success(self.fixture(channels=1), '--passes', '1', '--faststart', '--verify')

    def test_nonzero_audio_start(self):
        self.assert_success(self.fixture(offset=1.25), '--verify')

    def test_mov_extension(self):
        self.assert_success(self.fixture(name='clip.MOV'), '--verify')

    def test_rotation_chapters_custom_metadata_and_attached_picture(self):
        source = self.fixture(name='base.MP4')
        chapter = self.root / 'chapters.txt'
        chapter.write_text(';FFMETADATA1\nproject_note=Keep custom metadata\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1900\ntitle=Chapter one\n')
        picture = self.root / 'cover.jpg'
        run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'color=blue:size=64x64', '-frames:v', '1', '-threads', '1', '-update', '1', picture])
        decorated = self.root / 'decorated.MP4'
        run([FFMPEG, '-v', 'error', '-i', source, '-i', picture, '-f', 'ffmetadata', '-i', chapter,
             '-map', '0:v:0', '-map', '0:a:0', '-map', '1:v', '-c', 'copy', '-map_metadata', '0',
             '-metadata', 'project_note=Keep custom metadata', '-map_chapters', '2', '-metadata:s:v:0', 'rotate=90',
             '-disposition:v:1', 'attached_pic', '-movflags', '+use_metadata_tags', decorated])
        output = self.assert_success(decorated, '--verify')
        before, after = probe(decorated), probe(output)
        self.assertEqual(before['chapters'], after['chapters'])
        self.assertEqual(after['format']['tags']['project_note'], 'Keep custom metadata')
        before_main = next(s for s in before['streams'] if s['codec_type'] == 'video' and not s['disposition']['attached_pic'])
        after_main = next(s for s in after['streams'] if s['codec_type'] == 'video' and not s['disposition']['attached_pic'])
        self.assertEqual(before_main.get('side_data_list'), after_main.get('side_data_list'))

    def test_no_overwrite_and_dangling_symlink_collision(self):
        source = self.fixture()
        output = self.output(source)
        output.write_bytes(b'never replace')
        result = run([BINARY, source], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_bytes(), b'never replace')
        output.unlink()
        output.symlink_to(self.root / 'missing')
        result = run([BINARY, source], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(output.is_symlink())
        self.assert_clean()

    def test_rejected_track_layouts(self):
        no_audio = self.fixture(name='silent.MP4', audio=False)
        surround = self.fixture(name='surround.MP4', channels=6)
        base = self.fixture(name='base.MP4')
        multiple = self.root / 'multiple.MP4'
        run([FFMPEG, '-v', 'error', '-i', base, '-map', '0:v', '-map', '0:a', '-map', '0:a', '-c', 'copy', multiple])
        for source in [no_audio, surround, multiple]:
            result = run([BINARY, source], check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertFalse(self.output(source).exists())
        self.assert_clean()

    def test_folder_two_jobs_excludes_generated_outputs(self):
        one = self.fixture(name='one.MP4')
        two = self.fixture(name='two.mov', channels=1)
        ignored = self.root / 'old_voiceremoved.MP4'
        ignored.write_bytes(b'not an input')
        before = {p: content_hash(p) for p in [one, two, ignored]}
        result = run([BINARY, self.root, '--jobs', '2', '--passes', '1'])
        self.assertEqual(set(result.stdout.splitlines()), {str(self.output(one)), str(self.output(two))})
        for path, digest in before.items():
            self.assertEqual(content_hash(path), digest)
        self.assert_clean()

    def test_sigterm_cleans_up_and_reaps_children(self):
        self.cancel_run(signal.SIGTERM)

    def test_sigint_cleans_up_and_reaps_children(self):
        self.cancel_run(signal.SIGINT)

    def cancel_run(self, number):
        source = self.fixture(duration=600)
        before = content_hash(source)
        process = subprocess.Popen([str(BINARY), str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        child_pids = []
        lines = queue.Queue()
        diagnostics = []
        def drain():
            for line in process.stderr:
                diagnostics.append(line)
                lines.put(line)
            lines.put(None)
        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        try:
            # Wait for both units, then allow FFmpeg children to start.
            units = 0
            deadline = time.monotonic() + 20
            while units < 2 and time.monotonic() < deadline:
                line = lines.get(timeout=max(0.1, deadline - time.monotonic()))
                if line is None:
                    self.fail('pipeline exited before cancellation: ' + ''.join(diagnostics))
                if 'AUSoundIsolation:' in line:
                    units += 1
            self.assertEqual(units, 2)
            time.sleep(0.2)
            ps = run(['/bin/ps', '-axo', 'pid=,ppid=']).stdout
            child_pids = [int(parts[0]) for line in ps.splitlines() if len(parts := line.split()) == 2 and int(parts[1]) == process.pid]
            self.assertTrue(child_pids, 'no active FFmpeg child found')
            process.send_signal(number)
            process.wait(timeout=15)
            reader.join(timeout=5)
            stdout = process.stdout.read()
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(stdout, '')
            self.assertFalse(self.output(source).exists())
            self.assert_clean()
            self.assertEqual(content_hash(source), before)
            for pid in child_pids:
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            reader.join(timeout=5)
            process.stdout.close()
            process.stderr.close()


if __name__ == '__main__':
    if not BINARY.is_file():
        parser.error(f'compiled binary not found: {BINARY}')
    unittest.main(argv=['Integration/run.py', *remaining])

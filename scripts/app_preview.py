#!/usr/bin/env python3
"""Records the App Store preview for one language, and the product page's copy of it.

    app_preview.py LANG OUT_DIR [--site SITE_DIR]

Run by `make previews`, after a `build-for-testing`: this only runs the walk. It records
the simulator's screen around `AppPreviewTests`, cuts the recording at the two marks the
walk prints, and encodes what App Store Connect accepts for a 6.9" iPhone preview:

- 886x1920 portrait (one size serves every iPhone slot), 30 fps constant
- H.264 High, level 4.0, progressive
- a stereo AAC track at 256 kbps — required even though a walk has nothing to say, so
  it is silence
- 15 to 30 seconds

The simulator is erased before every take: the walk changes a book's type settings, and
the next take (or the next language) would otherwise open on the page the last one left.

Environment: SIM_NAME, SIM_TYPE (the simulator to record on), STATUS_BAR (simctl
status_bar override flags), PROJECT, SCHEME, CONFIGURATION, DERIVED — all set by make.
"""
import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

WIDTH, HEIGHT, FPS = 886, 1920, 30
# Before the first mark and after the last: the app is on screen and still, so a
# viewer's first frame is the app rather than a cut into the middle of a movement.
LEAD, TAIL = 0.3, 0.6

parser = argparse.ArgumentParser()
parser.add_argument("lang")
parser.add_argument("out", type=Path)
parser.add_argument("--site", type=Path)
args = parser.parse_args()
env = os.environ
args.out.mkdir(parents=True, exist_ok=True)
raw = args.out / "raw.mov"
log = args.out / "walk.log"


def run(*cmd: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def fail(message: str) -> None:
    sys.exit(f"app_preview [{args.lang}]: {message}")


udid = run("python3", "scripts/simulator_udid.py", env["SIM_NAME"], env["SIM_TYPE"])
if udid.returncode:
    fail(udid.stderr.strip())
udid = udid.stdout.strip()

run("xcrun", "simctl", "shutdown", udid)  # fails harmlessly when it is already down
for step in (["erase", udid], ["bootstatus", udid, "-b"],
             ["status_bar", udid, "override", *shlex.split(env["STATUS_BAR"])]):
    done = run("xcrun", "simctl", *step)
    if done.returncode:
        fail(f"simctl {step[0]}: {done.stderr.strip()}")
# A just-booted simulator is still settling its home screen for a few seconds; the walk
# waits for the app anyway, but the recording would open on the springboard's churn.
time.sleep(5)

recorder = subprocess.Popen(
    ["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", str(raw)],
    stderr=subprocess.PIPE, text=True,
)
started = threading.Event()


def watch() -> None:
    for line in recorder.stderr:
        if "Recording started" in line:
            started.set()


threading.Thread(target=watch, daemon=True).start()
if not started.wait(30):
    recorder.kill()
    fail("the recorder never said it had started")


def status_bar(**changes: str) -> float:
    """Re-applies the status bar with some values changed; returns when it took effect."""
    flags = shlex.split(env["STATUS_BAR"])
    for key, value in changes.items():
        flags[flags.index(f"--{key}") + 1] = value
    done = run("xcrun", "simctl", "status_bar", udid, "override", *flags)
    if done.returncode:
        fail(f"simctl status_bar: {done.stderr.strip()}")
    return time.time()


# A clock the video can be lined up against. "Recording started" is not the video's
# zero: the recorder writes a frame only when the screen changes, so on a still home
# screen its first frame can come seconds later — one take was cut two and a half
# seconds late that way, opening mid-scroll. Instead the status bar's clock is moved
# to 9:42 at a known moment and found again in the video (`sync_offset` below).
#
# The battery goes first, and on the other side of the bar: it forces a frame that
# still reads 9:41, so the first change the clock's corner shows is the one timed here.
time.sleep(0.5)
status_bar(batteryLevel="99")
time.sleep(1.0)
synced_at = status_bar(time="9:42")
time.sleep(1.0)
status_bar()

# xcodebuild refuses to write over the last take's result bundle.
result = args.out / "walk.xcresult"
shutil.rmtree(result, ignore_errors=True)
with open(log, "w") as out:
    walk = subprocess.run(
        ["xcodebuild", "test-without-building",
         "-project", env["PROJECT"], "-scheme", env["SCHEME"],
         "-configuration", env["CONFIGURATION"], "-derivedDataPath", env["DERIVED"],
         "-destination", f"id={udid}",
         "-resultBundlePath", str(result),
         "-only-testing:NovelReaderUITests/AppPreviewTests"],
        stdout=out, stderr=subprocess.STDOUT,
        env={**env, "TEST_RUNNER_NOVELREADER_PREVIEW": "1",
             "TEST_RUNNER_NOVELREADER_SHOT_LANG": args.lang},
    )
recorder.send_signal(signal.SIGINT)
recorder.wait(60)
if walk.returncode:
    fail(f"the walk failed (exit {walk.returncode}); see {log}")

# The recorder writes B-frames, so every frame's decode stamp runs seconds behind its
# presentation stamp, and now and then two frames share a presentation stamp. ffmpeg
# takes the shared stamp for a broken clock and switches to the decode stamps partway
# through — six to thirty-seven seconds off in three takes — and AVFoundation's
# `avconvert --start` lands seconds off too, early in one take and late in the next.
# With the decode stamps dropped, every frame's time is its presentation stamp exactly
# (checked frame by frame on the same three takes), so the recording is only ever read
# this way, from its start: nothing seeks in it.
READ_RAW = ["-fflags", "+igndts", "-i", str(raw)]


def sync_offset() -> float:
    """The wall-clock time of the video's zero, from where the 9:42 shows up in it.

    Only the clock's corner of the status bar is compared, against the first frame, and
    by pixels that moved a long way: compression noise makes no two frames identical,
    so a hash sees a "change" at the second frame whatever it shows — which is what the
    first takes were synced to. The mark must also be seen to go back to 9:41 about a
    second later. A recorder that started late shows only that return, and a cut timed
    from it would be a second off, so that fails here rather than being guessed at.
    """
    width, height = 160, 40
    done = subprocess.run(
        # Cut short by `trim`, not `-t`: `-t` drops the frame that crosses it only after
        # `showinfo` has counted it, and the times no longer line up with the frames.
        ["ffmpeg", "-v", "info", *READ_RAW, "-an", "-fps_mode", "passthrough",
         "-vf", f"trim=end=15,crop=iw*0.35:ih*0.05:0:0,scale={width}:{height},format=gray,"
                "showinfo",
         "-f", "rawvideo", "-"],
        capture_output=True,
    )
    times = [float(t) for t in re.findall(rb"pts_time:([\d.]+)", done.stderr)]
    size = width * height
    frames = [done.stdout[i:i + size] for i in range(0, len(done.stdout), size)]
    if done.returncode or not frames or len(frames) != len(times):
        fail("could not read the opening of the recording")
    # 9:41 to 9:42 moves about 235 of these pixels; noise moves none.
    moved = [sum(abs(a - b) > 64 for a, b in zip(frame, frames[0])) > 20 for frame in frames]
    on = next((i for i, m in enumerate(moved) if m), None)
    back = next((i for i in range(on + 1, len(frames)) if not moved[i]), None) \
        if on is not None else None
    if back is None or not 0.5 < times[back] - times[on] < 2.5:
        fail("the 9:42 sync mark did not show, then clear, in the recording's opening seconds")
    print(f"[{args.lang}] sync mark {times[on]:.2f}s into the recording")
    return synced_at - times[on]


text = log.read_text()
marks = dict(re.findall(r"PREVIEW-MARK (\w+) ([\d.]+)", text))
if "begin" not in marks or "end" not in marks:
    fail(f"the walk printed no marks; see {log}")
begin = float(marks["begin"]) - sync_offset() - LEAD
length = float(marks["end"]) - float(marks["begin"]) + LEAD + TAIL
print(f"[{args.lang}] walk {length:.1f}s, starting {begin:.1f}s into the recording")
# The store rejects anything outside 15-30s. Failing here rather than cutting the end
# off: the end of the walk is its last scene, and silently losing it is worse than a
# walk someone has to shorten.
if not 15 <= length <= 30:
    fail(f"the walk runs {length:.1f}s; the store takes 15-30s — change AppPreviewTests")

store = args.out / "preview.mp4"
encode = run(
    "ffmpeg", "-y", "-v", "error",
    *READ_RAW,
    "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
    # The recorder writes a frame only when the screen changes, so a still stretch is one
    # frame held. `fps` lays the frames on the 30fps grid first, holds and all, and the
    # cut is taken from the grid: trimming first drops the frame held across the start.
    # The last frame is cloned past the end for the same reason — `fps` stops at its
    # start, and the first takes' picture ran two seconds short of their sound.
    #
    # Scaled to the width and cropped to the height: the phone is a hair taller than
    # 886x1920, and three rows off each edge beats stretching every glyph.
    "-vf", f"tpad=stop_mode=clone:stop_duration={length:.3f},fps={FPS},"
           f"trim=start={begin:.3f}:duration={length:.3f},setpts=PTS-STARTPTS,"
           f"scale={WIDTH}:-2:flags=lanczos,crop={WIDTH}:{HEIGHT},setsar=1",
    "-map", "0:v", "-map", "1:a", "-t", f"{length:.3f}",
    "-c:v", "libx264", "-profile:v", "high", "-level:v", "4.0", "-pix_fmt", "yuv420p",
    "-b:v", "10M", "-maxrate", "12M", "-bufsize", "20M", "-r", str(FPS),
    "-c:a", "aac", "-b:a", "256k", "-ar", "44100", "-ac", "2",
    "-movflags", "+faststart", str(store),
)
if encode.returncode:
    fail(f"ffmpeg: {encode.stderr.strip()}")

# Checked against the spec rather than trusted: a flag ffmpeg quietly overrides is a
# rejection that only surfaces after the upload.
probe = json.loads(run(
    "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(store)
).stdout)
video = next(s for s in probe["streams"] if s["codec_type"] == "video")
audio = next((s for s in probe["streams"] if s["codec_type"] == "audio"), None)
duration = float(probe["format"]["duration"])
problems = []
if (video["width"], video["height"]) != (WIDTH, HEIGHT):
    problems.append(f"size {video['width']}x{video['height']}")
if video["codec_name"] != "h264" or video.get("profile") != "High" or video.get("level", 99) > 40:
    problems.append(f"codec {video['codec_name']} {video.get('profile')} {video.get('level')}")
if video.get("r_frame_rate") != f"{FPS}/1":
    problems.append(f"frame rate {video.get('r_frame_rate')}")
if not audio or audio["codec_name"] != "aac" or audio.get("channels") != 2:
    problems.append("no stereo AAC track")
if not 15 <= duration <= 30:
    problems.append(f"duration {duration:.2f}s")
# The file's duration is the longer of its tracks, and the silent one alone can make it.
if abs(float(video["duration"]) - duration) > 0.1:
    problems.append(f"picture {float(video['duration']):.2f}s of {duration:.2f}s")
if problems:
    fail("preview does not meet the store's spec: " + ", ".join(problems))
print(f"[{args.lang}] {store}: {WIDTH}x{HEIGHT} h264 High@4.0 {FPS}fps + AAC stereo, "
      f"{duration:.2f}s, {store.stat().st_size / 1e6:.1f}MB")

if args.site:
    # The product page plays it muted, looping, inline — so no audio track, and the
    # width the page's other phone images are made at (see site_images.sh). CRF 28 because
    # it autoplays on a phone's data: about 3MB against nearly 5MB at 24, with the text
    # still clean.
    args.site.mkdir(parents=True, exist_ok=True)
    web = args.site / "preview.mp4"
    poster = args.out / "poster.png"
    for cmd in (
        ["ffmpeg", "-y", "-v", "error", "-i", str(store), "-an", "-vf", "scale=720:-2",
         "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-crf", "28",
         "-preset", "slow", "-movflags", "+faststart", str(web)],
        ["ffmpeg", "-y", "-v", "error", "-ss", "0.1", "-i", str(store),
         "-frames:v", "1", str(poster)],
        ["cwebp", "-quiet", "-q", "82", "-sharp_yuv", "-resize", "720", "0",
         str(poster), "-o", str(args.site / "preview.webp")],
    ):
        done = run(*cmd)
        if done.returncode:
            fail(f"{cmd[0]}: {done.stderr.strip()}")
    print(f"[{args.lang}] {web}: {web.stat().st_size / 1e6:.1f}MB")

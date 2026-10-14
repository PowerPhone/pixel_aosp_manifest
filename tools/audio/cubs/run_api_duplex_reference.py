#!/usr/bin/env python3
"""Actual Cubs AudioTrack/AAudio output plus Java AudioRecord reference.

Default: exact192-kHz speaker BUS. --ordinary-rate48000 instead selects the
built-in bottom speaker through Java AudioTrack, retaining the192-kHz BUS
microphone reference. Framework geometry is collected before/after, never
with an active AudioFlinger dump during the tone.

Requires already-rooted userdebug adbd for read-only firmware-generation checks,
and an installed, microphone-granted PowerPhoneLab. Does not root, install,
grant permissions, change gain/mixers, or stop/restart any audio service.
"""
import argparse
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import wave
from wait_api_exclusive_pcm import wait_exclusive_pcm

REPO = Path(__file__).resolve().parents[3]
PACKAGE = "com.csr460.powerphone"
PROFILE = "mono192-edge0-mcps112-d5-two-slot-v5"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output-dir", required=True, type=Path)
    p.add_argument("--output-api", choices=("java", "aaudio"), required=True)
    p.add_argument("--speaker", choices=("bottom", "top"), required=True)
    p.add_argument("--ordinary-rate", type=int, choices=(48000,),
                   help="Java built-in bottom speaker client rate; omit for192-kHz research BUS")
    p.add_argument("--mic", type=int, choices=(0, 1, 2), default=0)
    p.add_argument("--duration", type=int, default=8)
    p.add_argument("--tone", type=int, default=20731)
    p.add_argument("--peak", type=float, default=.08)
    p.add_argument("--adb", default=str(REPO / "work/toolchains/platform-tools/adb"))
    p.add_argument("--adb-server-port", type=int, default=5038)
    p.add_argument("--serial")
    a = p.parse_args()
    if not 5 <= a.duration <= 120 or not 15000 <= a.tone < 95000 or not 0 < a.peak <= .25:
        p.error("duration 5..120 seconds; tone 15000..94999 Hz; peak (0,.25]")
    if not 1 <= a.adb_server_port <= 65535:
        p.error("invalid ADB server port")
    if a.ordinary_rate and (a.output_api != "java" or a.speaker != "bottom"):
        p.error("--ordinary-rate requires --output-api java --speaker bottom")
    output_rate = a.ordinary_rate or 192000
    if a.tone >= output_rate / 2:
        p.error("tone must be strictly below the output client's Nyquist frequency")
    out = a.output_dir.resolve()
    if out.exists():
        p.error("output directory must be new")
    out.mkdir(parents=True)
    adb = [a.adb, "-P", str(a.adb_server_port)]
    if a.serial:
        adb += ["-s", a.serial]
    environment = dict(os.environ, ADB_LIBUSB=os.environ.get("ADB_LIBUSB", "1"))
    output_address = None if a.ordinary_rate else f"POWERPHONE_CUBS_C0_D5_{a.speaker.upper()}"
    input_address = f"POWERPHONE_CUBS_C0_D10_MIC{a.mic}"
    errors = []
    logger = None
    log_stream = None
    launch_epoch = None
    app_pid = None
    native_run_id = None
    capture_path = None
    completed = False
    started_app = False
    before = None
    ordinary_before = None
    ordinary_after = None
    (out / "parameters.json").write_text(json.dumps({
        "output_api": a.output_api, "reference_api": "Java AudioRecord UNPROCESSED",
        "output_address": output_address, "input_address": input_address,
        "output_route": "BUILTIN_SPEAKER" if a.ordinary_rate else "research BUS",
        "rate_requested_hz": output_rate, "reference_rate_requested_hz": 192000,
        "expected_hal_output_rate_hz": 192000,
        "tone_hz": a.tone, "duration_seconds": a.duration,
        "peak_level": a.peak, "volume_policy": "unchanged", "firmware_profile": PROFILE,
        "capture_note": "Original API WAV retained; header/frame counts are not bandwidth proof."
    }, indent=2) + "\n")

    def call(arguments, *, name=None, timeout=12, check=True):
        result = subprocess.run(adb + arguments, env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout, text=True)
        text = result.stdout.replace("\r", "")
        if name:
            (out / name).write_text(text)
        if check and result.returncode:
            raise RuntimeError(f"ADB {arguments[:2]} failed with {result.returncode}; {name or text}")
        return text

    def shell(command, **kwargs):
        return call(["shell", command], **kwargs)

    def state(name):
        commands = ["printf 'boot_id='; cat /proc/sys/kernel/random/boot_id",
                    "printf 'uid='; id -u", "printf 'device='; getprop ro.product.device"]
        keys = {"profile": "vendor.powerphone.cubs.profile",
                "certified_boot": "vendor.powerphone.cubs.boot_id",
                "capture_ready": "vendor.powerphone.cubs.capture.ready",
                "playback_ready": "vendor.powerphone.cubs.playback.ready",
                "hal": "init.svc.vendor.audio-hal-powerphone-cubs",
                "stock_hal": "init.svc.vendor.audio-hal-aidl",
                "audioserver": "init.svc.audioserver"}
        commands += [f"printf '{key}='; getprop {value}" for key, value in keys.items()]
        commands += [f"printf '{key}='; cat /sys/devices/platform/a800000.aoc/{key}"
                     for key in ("restart_count", "coredump_count")]
        commands += ["if test -e /dev/powerphone-cubs-raw3-192; then echo raw3=yes; else echo raw3=no; fi",
                     "printf 'boot_id_end='; cat /proc/sys/kernel/random/boot_id"]
        text = shell("; ".join(commands), name=name)
        values = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
        expected = {"uid": "0", "device": "cubs", "profile": PROFILE,
                    "capture_ready": "1", "playback_ready": "1", "hal": "running",
                    "audioserver": "running", "restart_count": "0", "coredump_count": "0", "raw3": "no"}
        for key, value in expected.items():
            if values.get(key) != value:
                raise RuntimeError(f"{name}: {key}={values.get(key)!r}, expected {value!r}")
        if (not re.fullmatch(r"[0-9a-f-]{36}", values.get("boot_id", ""))
                or values["boot_id"] != values.get("certified_boot")
                or values["boot_id"] != values.get("boot_id_end")
                or values.get("stock_hal") not in ("", "stopped")):
            raise RuntimeError(f"{name}: invalid generation or competing HAL ownership")
        return values

    def live_text():
        return (out / "logcat-live.txt").read_text(errors="replace") if (out / "logcat-live.txt").exists() else ""

    def foreground(name):
        evidence = shell("dumpsys power; dumpsys activity activities; cmd appops get "
                         + PACKAGE + " RECORD_AUDIO", name=name, timeout=15)
        if not re.search(r"mWakefulness=Awake", evidence):
            raise RuntimeError(name + ": device is not awake")
        if not re.search(r"(?:mResumedActivity|topResumedActivity|mTopResumedActivity).*com\.csr460\.powerphone/\.StockPlaybackActivity", evidence):
            raise RuntimeError(name + ": diagnostic activity is not resumed")
        if re.search(r"RECORD_AUDIO:\s*(?:ignore|deny|errored)", evidence):
            raise RuntimeError(name + ": RECORD_AUDIO app-op denied; no policy override attempted")

    def app_lines(text):
        if not app_pid:
            return ""
        return "\n".join(line for line in text.splitlines()
                         if re.search(r"\s" + app_pid + r"\s+\d+\s+[A-Z]\s+PowerPhoneStock\s*:", line))

    def ordinary_thread(name):
        # Persistent primary thread inventory outside the measured interval.
        # This is framework/HAL geometry and frame-accounting evidence, not
        # an active ALSA hw_params or acoustic-bandwidth measurement.
        dump = shell("dumpsys media.audio_flinger", name=name, timeout=15)
        sections = re.findall(r"^Output thread .*?(?=^Output thread |\Z)",
                              dump, re.M | re.S)
        primary = [section for section in sections if re.search(
            r"^  Output devices: 0x2 \(AUDIO_DEVICE_OUT_SPEAKER\)$", section, re.M)]
        if len(primary) != 1:
            raise RuntimeError(name + ": missing/ambiguous built-in-speaker output thread")
        section = primary[0]
        fields = {}
        for key, pattern in (
                ("io_handle", r"^  I/O handle: (\d+)$"),
                ("rate", r"^  Sample rate: (\d+) Hz$"),
                ("channels", r"^  Channel count: (\d+)$"),
                ("hal_frame_count", r"^  HAL frame count: (\d+)$"),
                ("frames_written", r"^  Frames written: (\d+)$")):
            matches = re.findall(pattern, section, re.M)
            if len(matches) != 1:
                raise RuntimeError(name + ": missing/ambiguous primary " + key)
            fields[key] = int(matches[0])
        if (fields["rate"] != 192000 or fields["channels"] != 2
                or fields["hal_frame_count"] != 1920
                or not re.search(r"^  HAL format: 0x3 \(AUDIO_FORMAT_PCM_32_BIT\)$",
                                 section, re.M)):
            raise RuntimeError(name + ": primary does not retain192-kHz stereo S32/1920 HAL geometry")
        return fields

    try:
        before = state("state-before.txt")
        shell(f"am force-stop {PACKAGE}", name="stop-previous-app.txt")
        if a.ordinary_rate:
            ordinary_before = ordinary_thread("audio-flinger-before.txt")
        shell("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard", name="awake.txt")
        wait_exclusive_pcm(adb, environment, out / "exclusive-pcm-preflight")
        log_stream = (out / "logcat-live.txt").open("w")
        logger = subprocess.Popen(adb + ["logcat", "-v", "threadtime", "-T", "1",
                                 "PowerPhoneStock:V", "PowerPhoneEffectsCmd:V",
                                 "AHAL_Powerphone:V", "AudioFlinger:V", "*:E"],
                                  env=environment, stdout=log_stream, stderr=subprocess.STDOUT)
        command = ["am", "start", "-W", "-n", PACKAGE + "/.StockPlaybackActivity",
                   "--es", "output_api", a.output_api, "--ei", "output_rate", str(output_rate),
                   "--ei", "tone_hz", str(a.tone), "--ei", "duration_seconds", str(a.duration),
                   "--ef", "peak_level", str(a.peak),
                   "--ez", "record_reference", "true", "--ez", "research_reference", "true",
                   "--es", "reference_address", input_address]
        if output_address is not None:
            command += ["--es", "output_address", output_address]
        (out / "launch-command.txt").write_text(shlex.join(adb + ["shell", shlex.join(command)]) + "\n")
        launch = shell("date '+before_launch_epoch=%s.%N'; " + shlex.join(command),
                       name="launch.txt", timeout=25)
        started_app = True
        epoch_match = re.search(r"^before_launch_epoch=([0-9.]+)$", launch, re.M)
        if not epoch_match or "Status: ok" not in launch:
            raise RuntimeError("Activity launch or launch timestamp missing")
        launch_epoch = Decimal(epoch_match[1]) * 1000
        app_pid = shell(f"pidof {PACKAGE}", name="app-pid.txt").strip()
        if not re.fullmatch(r"\d+", app_pid):
            raise RuntimeError("expected one fresh app PID")
        foreground("foreground-at-launch.txt")
        deadline = time.monotonic() + a.duration + 18
        while time.monotonic() < deadline:
            if logger.poll() is not None:
                raise RuntimeError("live logcat exited before run completion")
            app = app_lines(live_text())
            if "STOCK_PLAYBACK_FAILED" in app or "STOCK_REFERENCE_FAILED" in app:
                raise RuntimeError("application reported playback/reference failure")
            if "STOCK_PLAYBACK_COMPLETE" in app:
                completed = True
                break
            time.sleep(.25)
        if not completed:
            raise RuntimeError("app completion deadline exceeded")
        # Retain HAL idle failures after the app closes both API streams.
        time.sleep(4)
        foreground("foreground-after.txt")
    except Exception as error:
        errors.append(str(error))
    finally:
        if started_app and not completed:
            try:
                shell(f"am force-stop {PACKAGE}", name="stop-incomplete-app.txt")
            except Exception as error:
                errors.append("incomplete app cleanup: " + str(error))
        if logger is not None:
            if logger.poll() is not None:
                errors.append("live logger ended unexpectedly")
            else:
                logger.terminate()
                try:
                    logger.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    logger.kill()
                    logger.wait(timeout=3)
        if log_stream:
            log_stream.close()
        try:
            after = state("state-after.txt")
            if before is None or before != after:
                errors.append("device state or firmware generation changed")
        except Exception as error:
            errors.append(str(error))
        if a.ordinary_rate:
            try:
                ordinary_after = ordinary_thread("audio-flinger-after.txt")
                if (ordinary_before is None
                        or ordinary_before["io_handle"] != ordinary_after["io_handle"]
                        or ordinary_after["frames_written"] - ordinary_before["frames_written"]
                        < a.duration * 192000 - 7680):
                    errors.append("ordinary primary handle or192-kHz output frame accounting mismatch")
            except Exception as error:
                errors.append(str(error))

    text = live_text()
    app = app_lines(text)
    (out / "app.txt").write_text(app + "\n")
    if "Invalid filter expression" in text:
        errors.append("invalid live logcat filter")
    hal_errors = [line for line in text.splitlines() if re.search(
        r"\sE\s+AHAL_Powerphone\s*:|AHAL_Powerphone.*(PCM ring (?:read|write) failed|integrity.*fail|ownership.*fault|refusing invalid|generation.*changed)|AudioStreamOutSink.*Error while writing data to HAL", line)]
    (out / "hal-errors.txt").write_text("\n".join(hal_errors) + "\n")
    if hal_errors:
        errors.append("live HAL data-path error")
    if not completed:
        errors.append("no fresh playback completion")
    beginnings = re.findall(r"STOCK_REFERENCE_BEGIN file=(\S*research-reference-(\d+)\.wav) rate=192000 channels=1 encoding=PCM16 source=UNPROCESSED unprocessed_supported=true preferred=([^\n]+)", app)
    if len(beginnings) == 1 and launch_epoch is not None and Decimal(beginnings[0][1]) >= launch_epoch:
        capture_path = beginnings[0][0]
        if input_address not in beginnings[0][2]:
            errors.append("wrong reference preferred endpoint")
        if not re.fullmatch(r"/storage/emulated/0/Android/data/com\.csr460\.powerphone/files/Music/research-reference-\d+\.wav", capture_path):
            errors.append("unexpected app capture path")
            capture_path = None
    else:
        errors.append("missing/ambiguous/stale reference begin")
    if capture_path:
        try:
            call(["pull", capture_path, str(out / "capture.wav")], name="capture-pull.txt", timeout=45)
        except Exception as error:
            errors.append("capture pull: " + str(error))
    if a.output_api == "aaudio":
        ids = re.findall(r"STOCK_AAUDIO_REPORT_BEGIN file=\S+ run_id=(\d+-\d+)", app)
        if len(ids) == 1 and launch_epoch is not None and Decimal(ids[0].split("-")[0]) >= launch_epoch:
            native_run_id = ids[0]
            try:
                call(["pull", f"/sdcard/Android/data/{PACKAGE}/files/stock-aaudio-latest.txt",
                      str(out / "native-report.txt")], name="native-report-pull.txt")
                report = (out / "native-report.txt").read_text()
                required = (f"run_id={native_run_id}\n", "native_report_state=RETURNED", "AAUDIO_RUN_OK",
                            f"frames transferred/target: {a.duration * 192000} / {a.duration * 192000}",
                            f"output_address={output_address}", "output_rate=192000", f"tone_hz={a.tone}")
                if any(item not in report for item in required) or "AAUDIO_RUN_FAILED" in report:
                    errors.append("native report missing/stale/failed/incomplete")
            except Exception as error:
                errors.append("native report: " + str(error))
        else:
            errors.append("missing/ambiguous/stale native report run ID")
    else:
        requested_builtin = None
        if a.ordinary_rate:
            devices = re.findall(r"BUILTIN_SPEAKER (id=(\d+) type=2 address=\S* name=[^\n]+)", app)
            if len(devices) != 1 or int(devices[0][1]) <= 0:
                errors.append("missing/ambiguous default built-in speaker selection")
            else:
                requested_builtin = devices[0][0]
                begin = re.findall(r"STOCK_PLAYBACK_BEGIN rate=(\d+) channels=2 encoding=PCM16 "
                                   r"tone_hz=(\d+) peak=\S+ frames=(\d+) duration_seconds=(\d+) "
                                   r"requested=(.*?) client_rate=(\d+) buffer_frames=", app)
                if (len(begin) != 1 or begin[0] != (str(output_rate), str(a.tone),
                        str(a.duration * output_rate), str(a.duration), requested_builtin, str(output_rate))):
                    errors.append("ordinary requested/client format, duration or preferred route mismatch")
        results = re.findall(r"STOCK_PLAYBACK_RESULT written_frames=(\d+) played_frames=(\d+) elapsed_ms=(\d+) requested_duration_seconds=(\d+) underruns=(\d+) route=([^\n]+)", app)
        if len(results) != 1:
            errors.append("missing/ambiguous Java playback result")
        else:
            written, played, elapsed, duration, underruns, route = results[0]
            route_matches = (requested_builtin is not None and route.startswith(requested_builtin + " ")) \
                if a.ordinary_rate else output_address in route
            if not (int(written) == a.duration * output_rate and int(played) >= int(written)
                    and a.duration * 1000 - 500 <= int(elapsed) <= (a.duration + 4) * 1000
                    and int(duration) == a.duration and int(underruns) == 0 and route_matches):
                errors.append("Java frame/time/underrun/route mismatch")
    if "silenced=true" in app or re.search(r"App op\s*27.*silenc|active recording client silenced:\s*true", text, re.I):
        errors.append("reference was framework-silenced")
    finished = re.findall(r"STOCK_REFERENCE_COMPLETE file=(\S+) frames=(\d+) duration_seconds=([0-9.]+) route=([^\n]+)", app)
    tone_start = re.findall(r"STOCK_REFERENCE_TONE_START capture_frame=(\d+)", app)
    tone_end = re.findall(r"STOCK_REFERENCE_TONE_END capture_frame=(\d+)", app)
    wav_info = None
    try:
        with wave.open(str(out / "capture.wav"), "rb") as wav:
            wav_info = dict(rate=wav.getframerate(), channels=wav.getnchannels(),
                            sample_bytes=wav.getsampwidth(), frames=wav.getnframes())
            if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (192000, 1, 2):
                errors.append("reference WAV format mismatch")
            if not (len(finished) == 1 and finished[0][0] == capture_path
                    and int(finished[0][1]) == wav.getnframes() and input_address in finished[0][3]):
                errors.append("reference completion/path/frame/route mismatch")
            if not (len(tone_start) == len(tone_end) == 1
                    and int(tone_start[0]) >= 192000
                    and int(tone_end[0]) - int(tone_start[0]) >= (a.duration - .5) * 192000
                    and wav.getnframes() - int(tone_end[0]) >= 192000):
                errors.append("reference lead/full stimulus/tail accounting failed")
    except Exception as error:
        errors.append("reference WAV: " + str(error))
    qualification = dict(api_transport_status="FAIL" if errors else "PASS", errors=errors,
                         reference_api="Java AudioRecord UNPROCESSED", output_api=a.output_api,
                         output_client_rate_hz=output_rate,
                         output_route="BUILTIN_SPEAKER" if a.ordinary_rate else output_address,
                         ordinary_framework_before=ordinary_before,
                         ordinary_framework_after=ordinary_after,
                         capture_device_path=capture_path, fresh_app_pid=app_pid,
                         native_run_id=native_run_id, wav=wav_info,
                         capture_tone_start_frames=tone_start, capture_tone_end_frames=tone_end,
                         acoustic_status="NOT_ANALYZED",
                         limits="API transport success alone proves neither acoustic pitch/continuity nor passband. Native AAudio input duplex is not implemented by this app mode.")
    if wav_info and (wav_info["rate"], wav_info["channels"], wav_info["sample_bytes"]) == (192000, 1, 2) and wav_info["frames"] > 192000:
        analysis_dir = out / "tone-analysis"
        with (out / "tone-analysis.log").open("w") as log:
            result = subprocess.run([sys.executable, str(REPO / "tools/audio/analyze_cubs_baseline_tone.py"),
                                     str(out / "capture.wav"), "--tone", str(a.tone),
                                     "--expected-duration", str(a.duration), "--output-dir", str(analysis_dir)],
                                    stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            qualification["acoustic_status"] = "ANALYSIS_FAILED"
        else:
            metrics = json.loads((analysis_dir / "metrics.json").read_text())
            active = metrics["full_active_interval"]
            qualified = (active.get("measurable", False)
                         and abs(active.get("analyzed_duration_seconds", 0) - (a.duration - .1)) <= .15
                         and abs(active.get("measured_carrier_peak_hz", 0) - a.tone) <= 1
                         and abs(active.get("phase_fit_hz", 0) - a.tone) <= 1
                         and active.get("phase_step_over_035rad_count", -1) == 0
                         and active.get("amplitude_dropout_blocks", -1) == 0
                         and metrics["saturated_samples"] == 0
                         and metrics.get("active_requested_line_over_quiet_db", -999) >= 10)
            qualification["acoustic_status"] = "SINGLE_TONE_CONTINUITY_PASS" if qualified else "SINGLE_TONE_CONTINUITY_FAIL"
        # Fixed quiet sample interval, in the declared API sample coordinate.
        # Do not name this an independently measured physical clock/passband.
        try:
            import numpy as np
            from scipy import signal
            from scipy.io import wavfile
            rate, pcm = wavfile.read(out / "capture.wav")
            lo, hi = round(.2 * rate), round(.8 * rate)
            quiet = pcm[lo:hi].astype(np.float64) / 32768
            frequencies, psd = signal.welch(quiet, rate, window="hann", nperseg=16384,
                                            noverlap=8192, detrend="constant", scaling="density")
            density = lambda low, high: float(10 * np.log10(max(1e-30, np.median(psd[(frequencies >= low) & (frequencies < high)]))))
            low, high = density(48000, 60000), density(84000, 95000)
            quiet_report = dict(original_wav_unmodified=True, sample_bounds=[lo, hi],
                                api_coordinate_seconds=[.2, .8], declared_sample_rate_hz=rate,
                                median_psd_48_60k_dbfs_per_hz=low, median_psd_84_95k_dbfs_per_hz=high,
                                high_minus_low_db=high-low, welch_window="hann", nperseg=16384,
                                overlap=8192, resolution_hz=rate/16384,
                                limits="A rising floor is compatible with noise shaping, but neither proves acoustic sensitivity to 96 kHz nor independently verifies the hardware clock. No resampling/normalization.")
            (out / "quiet-noise-ramp.json").write_text(json.dumps(quiet_report, indent=2) + "\n")
            np.savetxt(out / "quiet-psd.csv", np.column_stack([frequencies, psd]), delimiter=",",
                       header="api_coordinate_hz,linear_psd_fs_squared_per_hz", comments="")
        except Exception as error:
            qualification["quiet_analysis_error"] = str(error)
    (out / "qualification.json").write_text(json.dumps(qualification, indent=2) + "\n")
    print(json.dumps(qualification, indent=2))
    return int(bool(errors) or qualification["acoustic_status"] != "SINGLE_TONE_CONTINUITY_PASS"
               or "quiet_analysis_error" in qualification)


if __name__ == "__main__":
    raise SystemExit(main())

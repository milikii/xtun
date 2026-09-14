#!/usr/bin/env python3
"""PTY checks for installed task menus, editing, cancellation and recovery."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

WORKER = Path(__file__).with_name("task-menu-worker.sh")


def run_case(evidence, outcome):
    case = evidence / outcome
    case.mkdir(parents=True)
    sandbox = case / "sandbox"
    env = dict(os.environ, TEST_MENU_ROOT=str(case), TEST_MENU_OUTCOME=outcome,
               TEST_SANDBOX_ROOT=str(sandbox), COLUMNS="80", LINES="24", TERM="xterm")
    subprocess.run(["bash", str(WORKER), "seed"], env=env, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    state = sandbox / "usr/local/etc/xray/node-meta.env"
    before = hashlib.sha256(state.read_bytes()).hexdigest()
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe("bash", ["bash", str(WORKER)], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    transcript = bytearray()
    pending = bytearray()
    waited = False

    def expect(token, timeout=10):
        nonlocal pending
        wanted = token.encode()
        deadline = time.monotonic() + timeout
        while wanted not in pending:
            if time.monotonic() > deadline:
                raise AssertionError(f"timeout waiting for {token!r}")
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    raise AssertionError(f"process ended before {token!r}")
                transcript.extend(chunk)
                pending.extend(chunk)
        pending = pending[pending.index(wanted) + len(wanted):]

    def send(value):
        os.write(fd, value.encode() if isinstance(value, str) else value)

    def choose(group, item):
        expect("请选择: ")
        send(group + "\n")
        expect("请选择: ")
        send(item + "\n")

    def check_status_and_exit():
        expect("请选择: ")
        send("0\n")
        choose("2", "1")
        expect("STATUS-OK")
        expect("按回车继续")
        send("\n")
        expect("请选择: ")
        send("0\n")
        expect("请选择: ")
        send("0\n")

    try:
        if outcome == "node":
            choose("1", "1")
            expect("vless://fixture@example.test:443#FIRST")
            expect("按回车继续")
            send("\n")
            check_status_and_exit()
        elif outcome == "two-warp-choices":
            choose("5", "1")
            for index, mode in enumerate(("enable", "disable")):
                expect("请选择 WARP 操作")
                send(mode + "\n")
                expect("确认应用？")
                send("y\n")
                expect("按回车继续")
                send("\n")
                if index == 0:
                    expect("请选择: ")
                    send("1\n")
            check_status_and_exit()
        else:
            choose("3", "3")
            expect("新的 XHTTP 路径")
            if outcome == "eof":
                send(b"\x04")
            elif outcome in ("cancel", "input-int"):
                send(":cancel\n" if outcome == "cancel" else b"\x03")
                expect("当前动作已取消")
                check_status_and_exit()
            else:
                if outcome == "invalid-back-noop":
                    send("bad path\n")
                    expect("输入不合法")
                    expect("新的 XHTTP 路径")
                send("/new\n")
                expect("确认应用？")
                if outcome == "invalid-back-noop":
                    send(":back\n")
                    expect("返回编辑")
                    send("/old\n")
                    expect("确认应用？")
                send("y\n")
                if outcome in ("execute-int", "execute-term"):
                    expect("EXECUTION-WAIT: ")
                    if outcome == "execute-int":
                        send(b"\x03")
                    else:
                        os.kill(pid, signal.SIGTERM)
                    expect("已回退到操作前的文件与服务")
                if outcome != "execute-term":
                    if outcome != "execute-int":
                        expect("按回车继续")
                        send("\n")
                    check_status_and_exit()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                code = os.waitstatus_to_exitcode(status)
                break
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    transcript.extend(os.read(fd, 65536))
                except OSError:
                    pass
        else:
            raise AssertionError("menu failed to exit")
        assert code == (143 if outcome == "execute-term" else 0), code
        assert not (sandbox / "var/lib/xtun/pending-op.tsv").exists()
        if outcome == "two-warp-choices":
            assert (case / "applied.tsv").read_text() == "/old\tyes\n/old\tno\n"
        else:
            assert hashlib.sha256(state.read_bytes()).hexdigest() == before, "state changed"
            assert not (case / "applied.tsv").exists(), "unexpected apply"
        if outcome in ("node", "cancel", "eof", "input-int", "invalid-back-noop"):
            assert not (sandbox / "root/xtun-backups").exists(), "backup before change"
        return code
    finally:
        if not waited:
            try:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except ProcessLookupError:
                pass
        os.close(fd)
        (case / "transcript.txt").write_bytes(transcript)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("PTY tests exercise the real root guard; run with sudo python3 tests/task-menu-boundary.py")
    evidence = args.evidence or Path(tempfile.mkdtemp(prefix="xtun-task-menu."))
    results = []
    for outcome in ("node", "cancel", "eof", "input-int", "invalid-back-noop",
                    "two-warp-choices", "execute-fail", "execute-int", "execute-term"):
        try:
            code = run_case(evidence, outcome)
            results.append(dict(case=outcome, passed=True, exit=code))
            print(f"PASS {outcome} exit={code}", flush=True)
        except Exception as exc:
            results.append(dict(case=outcome, passed=False, error=str(exc)))
            print(f"FAIL {outcome}: {exc}", flush=True)
            if os.environ.get("GITHUB_ACTIONS") == "true":
                message = f"{outcome}: {exc}".replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
                print(f"::error title=Task menu PTY failure::{message}", flush=True)
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "results.json").write_text(json.dumps(results, indent=2))
    print(f"task menu evidence: {evidence}", flush=True)
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

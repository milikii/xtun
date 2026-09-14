#!/usr/bin/env python3
"""用真实 PTY 验证安装任务的取消、EOF、Ctrl-C、返回与最终确认。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import stat
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "tests/install-boundary-worker.sh"
IDENTITY_KEYS = {
    "REALITY_UUID", "XHTTP_UUID", "REALITY_SHORT_ID", "REALITY_PRIVATE_KEY",
    "REALITY_PUBLIC_KEY", "XHTTP_PATH", "XHTTP_VLESS_DECRYPTION", "XHTTP_VLESS_ENCRYPTION",
}


def snapshot(root):
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        info = path.lstat()
        value = [stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid]
        if path.is_symlink():
            value += ["link", os.readlink(path)]
        elif path.is_file():
            value += ["file", hashlib.sha256(path.read_bytes()).hexdigest()]
        else:
            value += ["directory"]
        result[str(path.relative_to(root))] = value
    return result


def identity(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines()
                if "=" in line and line.split("=", 1)[0] in IDENTITY_KEYS)


def run_case(evidence, task, entry, outcome):
    case = evidence / f"{task}-{entry}-{outcome}"
    sandbox = case / "sandbox"
    sandbox.mkdir(parents=True)
    env = dict(os.environ, TEST_BOUNDARY_ROOT=str(case), TEST_BOUNDARY_TASK=task,
               TEST_BOUNDARY_OUTCOME=outcome, TEST_SANDBOX_ROOT=str(sandbox))
    subprocess.run(["bash", str(WORKER), "seed"], env=env, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    before = snapshot(sandbox)
    (case / "before.json").write_text(json.dumps(before, indent=2))
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe("bash", ["bash", str(WORKER), entry], env)
    transcript = bytearray()
    pending = b""
    deadline = time.monotonic() + 35
    waited = False
    status = None
    back_sent = False
    prompt_count = 0
    confirmation_count = 0
    prompts = [
        "请选择任务", "REALITY 直连节点地址或 IP", "REALITY 可见 SNI",
        "REALITY 目标地址 host:port", "XHTTP CDN 域名", "TLS 证书模式序号", "确认开始？", "执行中断测试",
    ]
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.15)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    # PTY 可先于 waitpid 可见的进程退出关闭。给子进程同一个截止时间
                    # 完成退出，不能将这几毫秒的窗口误报成超时再 SIGKILL。
                    while time.monotonic() < deadline:
                        done, status = os.waitpid(pid, os.WNOHANG)
                        if done:
                            waited = True
                            break
                        time.sleep(0.01)
                    break
                transcript.extend(chunk)
                pending += chunk
                text = pending.decode(errors="replace")
                # read 的提示以 ': ' 结束，避免把前面的摘要当成输入请求。
                if text.endswith(": "):
                    prompt = next((item for item in reversed(prompts) if item in text), None)
                    if prompt is None:
                        raise AssertionError(f"unexpected prompt: {text[-250:]}")
                    prompt_count += 1
                    if prompt == "请选择任务":
                        answer = b"3\n" if task == "rotate" else b"1\n"
                        if outcome == "task-cancel":
                            answer = b"0\n"
                    elif prompt == "确认开始？":
                        confirmation_count += 1
                        if outcome == "back-confirm" and not back_sent:
                            back_sent = True
                            answer = b"back\n"
                        elif outcome in ("confirm", "back-confirm") or outcome.startswith("execute-"):
                            answer = b"y\n"
                        elif outcome == "eof":
                            answer = b"\x04"
                        elif outcome == "interrupt":
                            answer = b"\x03"
                        else:
                            answer = b"n\n"
                    elif prompt == "执行中断测试":
                        if outcome == "execute-term":
                            os.kill(pid, signal.SIGTERM)
                            pending = b""
                            continue
                        answer = b"\x03"
                    elif prompt == "REALITY 可见 SNI":
                        answer = b"reality.example.com\n"
                    elif prompt == "XHTTP CDN 域名":
                        answer = b"changed.example.test\n" if back_sent else b"cdn.example.test\n"
                    else:
                        answer = b"\n"
                    os.write(fd, answer)
                    pending = b""
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                break
        if not waited:
            done, status = os.waitpid(pid, os.WNOHANG)
            if not done:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                waited = True
                raise AssertionError("PTY process exceeded deadline")
            waited = True
        code = os.waitstatus_to_exitcode(status)
    finally:
        if not waited:
            try:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except ProcessLookupError:
                pass
        os.close(fd)
        (case / "transcript.txt").write_bytes(transcript)
    after = snapshot(sandbox)
    (case / "after.json").write_text(json.dumps(after, indent=2))
    assert not (case / "side-effects.log").exists(), "external mutation called"
    assert prompt_count > 0, "did not reach real input"
    if outcome != "task-cancel":
        assert confirmation_count > 0, "did not reach final confirmation"
    if outcome in ("confirm", "back-confirm") or outcome.startswith("execute-"):
        expected = {"execute-int": 130, "execute-term": 143, "execute-exit": 7}.get(outcome, 1)
        assert code == expected, f"post-confirm injected failure returned {code}, expected {expected}"
        assert (case / "execution.log").read_text() == "confirmed\n", "execution count differs"
        draft = sandbox / "root/.xtun-install-draft.env"
        assert draft.is_file() and stat.S_IMODE(draft.stat().st_mode) == 0o600
        assert identity(draft) == identity(case / "preview-1.env"), "identity changed after preview"
        if outcome.startswith("execute-"):
            assert "已回退到操作前的文件与服务" in transcript.decode(errors="replace")
            assert not (sandbox / "var/lib/xtun/pending-op.tsv").exists()
            for prefix in ("usr/local", "etc", "root/xtun-output.md", "root/xtun-qr"):
                expected_files = {k: v for k, v in before.items() if k == prefix or k.startswith(prefix + "/")}
                actual_files = {k: v for k, v in after.items() if k == prefix or k.startswith(prefix + "/")}
                # 仅含路径前缀的空父目录可以保留；文件/链接和既有目录必须一致。
                assert all(actual_files.get(k) == v for k, v in expected_files.items()), prefix
                assert all(k in expected_files or v[-1] == "directory" for k, v in actual_files.items()), prefix
        if back_sent:
            assert identity(case / "preview-2.env") == identity(case / "preview-1.env")
            assert "changed.example.test" in draft.read_text()
    else:
        expected = (0,) if outcome == "task-cancel" else ((-signal.SIGINT, 130) if outcome == "interrupt" else (1,))
        assert code in expected, f"unexpected cancellation exit {code}"
        assert before == after, "persistent sandbox changed before confirmation"
        assert not (case / "execution.log").exists(), "execution started before confirmation"
    return code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("PTY tests exercise the real root guard; run with sudo python3 tests/install-boundary.py")
    evidence = args.evidence or Path(tempfile.mkdtemp(prefix="xtun-install-boundary."))
    evidence.mkdir(parents=True, exist_ok=True)
    results = []
    for task in ("fresh", "resume", "rebuild", "rotate"):
        for entry in ("cli", "menu"):
            outcomes = ["cancel", "eof", "interrupt", "confirm", "back-confirm", "execute-int", "execute-term", "execute-exit"]
            if entry == "menu":
                outcomes.append("task-cancel")
            for outcome in outcomes:
                name = f"{task}-{entry}-{outcome}"
                try:
                    code = run_case(evidence, task, entry, outcome)
                    results.append({"case": name, "passed": True, "exit": code})
                    print(f"PASS {name} exit={code}", flush=True)
                except Exception as exc:
                    results.append({"case": name, "passed": False, "error": str(exc)})
                    print(f"FAIL {name}: {exc}", flush=True)
                    if os.environ.get("GITHUB_ACTIONS") == "true":
                        message = f"{name}: {exc}".replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
                        print(f"::error title=Installation PTY failure::{message}", flush=True)
    (evidence / "results.json").write_text(json.dumps(results, indent=2))
    print(f"install boundary evidence: {evidence}", flush=True)
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

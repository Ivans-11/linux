#!/usr/bin/env python3
"""Run one declarative AxVisor-on-Linux case.

The case manifest owns guest/test details.  This runner only performs the
common mechanics shared by all cases: stage assets, build the Linux host,
launch QEMU, drive the serial shell, and report pass/fail from the declared
markers.  It deliberately does not contain Firecracker/gVisor-specific code.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pty
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import tty
from pathlib import Path


ROOT = Path(__file__).resolve().parent
CASES = ROOT / "tests" / "cases"
HOSTS = ROOT / "tests" / "hosts"
ASSET_CATALOG = ROOT / "tests" / "assets.toml"
WORK = ROOT / ".work"
X86_ACCEL_ENV = "AXVISOR_X86_ACCEL"


def load(path: Path) -> dict:
    with path.open("rb") as stream:
        return tomllib.load(stream)


def find_case(name: str) -> Path:
    candidate = Path(name)
    if candidate.is_file():
        return candidate.resolve()
    matches = []
    for path in CASES.rglob("case.toml"):
        manifest = load(path)
        if manifest.get("case") == name or path.parent.name == name:
            matches.append(path)
    if len(matches) != 1:
        if not matches:
            raise SystemExit(f"case not found: {name}")
        raise SystemExit("case name is ambiguous: " + ", ".join(map(str, matches)))
    return matches[0].resolve()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate(case_path: Path, case: dict, host: dict) -> None:
    for key in ("arch", "mode", "case", "host_profile"):
        if not case.get(key):
            raise SystemExit(f"{case_path}: missing `{key}`")
    if case["arch"] != host.get("arch"):
        raise SystemExit(f"{case_path}: case/host architecture mismatch")
    if case.get("status", "active") not in ("active", "planned"):
        raise SystemExit(f"{case_path}: invalid status")
    for key in ("payload_files", "payload_assets", "host_initramfs_assets"):
        values = case.get(key, [])
        labels = [item if isinstance(item, str) else item.get("name", item.get("asset")) for item in values]
        if any(not isinstance(label, str) for label in labels) or len(labels) != len(set(labels)):
            raise SystemExit(f"{case_path}: invalid or duplicate entries in `{key}`")
        for value in values if key == "payload_files" else []:
            path = Path(value)
            if path.is_absolute() or ".." in path.parts:
                raise SystemExit(f"{case_path}: invalid payload path: {value}")
    seen_targets = set()
    for item in case.get("test_files", []):
        if not isinstance(item, dict) or not isinstance(item.get("source"), str) or not isinstance(item.get("target"), str):
            raise SystemExit(f"{case_path}: test_files entries must have source and target")
        source = Path(item["source"])
        target = Path(item["target"])
        if source.is_absolute() or ".." in source.parts or target.is_absolute() or ".." in target.parts:
            raise SystemExit(f"{case_path}: invalid test file path")
        if target.as_posix() in seen_targets:
            raise SystemExit(f"{case_path}: duplicate test file target: {target}")
        seen_targets.add(target.as_posix())
        if not (ROOT / source).is_file():
            raise SystemExit(f"{case_path}: test source is missing: {source}")
    init_source = case.get("initramfs_init")
    if init_source is not None:
        init_path = Path(init_source)
        if init_path.is_absolute() or ".." in init_path.parts or not (ROOT / init_path).is_file():
            raise SystemExit(f"{case_path}: initramfs_init is missing or invalid: {init_source}")
    if not ASSET_CATALOG.is_file():
        raise SystemExit(f"asset catalog is missing: {ASSET_CATALOG}")
    assets = load(ASSET_CATALOG).get("assets", {})
    for key in ("payload_assets", "host_initramfs_assets"):
        for item in case.get(key, []):
            label = item if isinstance(item, str) else item.get("name", item.get("asset"))
            if label not in assets:
                raise SystemExit(f"{case_path}: undefined asset `{label}`")
            asset_arch = assets[label].get("arch")
            if asset_arch and asset_arch != case["arch"]:
                raise SystemExit(f"{case_path}: asset `{label}` is for {asset_arch}, not {case['arch']}")
            target = item.get("target") if isinstance(item, dict) else assets[label].get("target")
            if not isinstance(target, str):
                raise SystemExit(f"{case_path}: asset `{label}` has no target")
            target_path = Path(target)
            if target_path.is_absolute() or ".." in target_path.parts:
                raise SystemExit(f"{case_path}: invalid asset target: {target}")
    command = case.get("run_command")
    if command is not None and (not isinstance(command, list) or not all(isinstance(x, str) for x in command)):
        raise SystemExit(f"{case_path}: run_command must be an argv array")
    for key in ("success_regex", "fail_regex"):
        for pattern in case.get(key, []):
            try:
                re.compile(pattern)
            except re.error as exc:
                raise SystemExit(f"{case_path}: invalid {key} regex {pattern!r}: {exc}")


def copy_tree(source: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        destination = target / entry.name
        if entry.is_dir():
            copy_tree(entry, destination)
        else:
            shutil.copy2(entry, destination)


def ensure_image(name: str) -> Path:
    """Resolve a guest image directory from the unified asset catalog."""
    candidates = []
    if os.environ.get("AXVISOR_IMAGE_ROOT"):
        candidates.append(Path(os.environ["AXVISOR_IMAGE_ROOT"]) / name)
    candidates.append(ROOT / "tests" / "images" / name)
    for candidate in candidates:
        if candidate.is_dir():
            return candidate.resolve()

    if not ASSET_CATALOG.is_file():
        raise SystemExit(f"guest image `{name}` is not available; set AXVISOR_IMAGE_ROOT")
    entries = load(ASSET_CATALOG).get("assets", {})
    spec = entries.get(name)
    if not spec:
        raise SystemExit(f"guest image `{name}` is not defined in {ASSET_CATALOG}")
    if spec.get("kind") != "download" or not spec.get("archive"):
        raise SystemExit(f"asset `{name}` is not a downloadable guest-image archive")
    archive = declared_download(name, spec)
    image_root = WORK / "assets" / "images" / name
    extracted = image_root / "extracted"
    if extracted.is_dir():
        children = [item for item in extracted.iterdir() if item.is_dir()]
        return children[0] if len(children) == 1 else extracted
    extracted.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:*") as tar:
        for member in tar.getmembers():
            member_path = Path(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise SystemExit(f"unsafe path in guest image archive: {member.name}")
        tar.extractall(extracted)
    children = [item for item in extracted.iterdir() if item.is_dir()]
    return children[0] if len(children) == 1 else extracted


def declared_download(name: str, spec: dict) -> Path:
    """Use the generic asset resolver for a catalogued download."""
    command = [sys.executable, str(ROOT / "build-assets.py"), "--arch", spec.get("arch", "riscv64"), "--asset", name]
    output = subprocess.check_output(command, cwd=ROOT, text=True)
    label, artifact = output.strip().splitlines()[-1].split("\t", 1)
    if label != name:
        raise SystemExit(f"asset resolver returned an unexpected asset: {label}")
    return Path(artifact)


def copy_artifact(source: Path, destination: Path) -> None:
    """Copy either a single asset or a directory asset into a staging tree."""
    if source.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        copy_tree(source, destination)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def declared_assets(case: dict, key: str) -> list[tuple[str, str]]:
    """Return (resolved artifact, target) for a case asset list."""
    entries = case.get(key, [])
    if not entries:
        return []
    labels = [item if isinstance(item, str) else item.get("name", item.get("asset")) for item in entries]
    command = [sys.executable, str(ROOT / "build-assets.py"), "--arch", case["arch"]]
    for label in labels:
        command += ["--asset", label]
    output = subprocess.check_output(command, cwd=ROOT, text=True)
    resolved = {}
    for line in output.splitlines():
        label, path = line.split("\t", 1)
        resolved[label] = Path(path)
    catalog = load(ASSET_CATALOG)["assets"]
    result = []
    for item in entries:
        label = item if isinstance(item, str) else item.get("name", item.get("asset"))
        target = item.get("target") if isinstance(item, dict) else catalog[label].get("target")
        result.append((resolved[label], target))
    return result


def stage_assets(case: dict, key: str, destination: Path) -> list[tuple[Path, str]]:
    staged = []
    for artifact, target in declared_assets(case, key):
        target_path = Path(target)
        if target_path.is_absolute() or ".." in target_path.parts:
            raise SystemExit(f"invalid asset target: {target}")
        output = destination / target_path
        copy_artifact(artifact, output)
        staged.append((output, target_path.as_posix()))
    return staged


def make_ext2(source: Path, image: Path, extra_bytes: int = 0) -> Path:
    size = max(64 * 1024 * 1024, sum(p.stat().st_size for p in source.rglob("*") if p.is_file()) * 2 + 16 * 1024 * 1024 + extra_bytes)
    size = (size + 1024 * 1024 - 1) // (1024 * 1024) * (1024 * 1024)
    image.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["truncate", "-s", str(size), str(image)], check=True)
    subprocess.run(["mkfs.ext2", "-F", str(image)], stdout=subprocess.DEVNULL, check=True)
    commands = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        target = "/" + str(relative)
        if path.is_dir():
            commands.append(f"mkdir {target}")
        else:
            commands.append(f"write {path} {target}")
            if path.stat().st_mode & 0o111:
                # debugfs replaces the complete inode mode, including its file
                # type.  Preserve S_IFREG instead of turning executables into
                # typeless inodes by writing permission bits alone.
                commands.append(f"set_inode_field {target} mode 0{path.stat().st_mode:o}")
    subprocess.run(["debugfs", "-w", "-f", "-", str(image)], input=("\n".join(commands) + "\n").encode(), check=True, stdout=subprocess.DEVNULL)
    return image


def inject_initramfs_files(initramfs: Path, files: list[dict], case_dir: Path) -> None:
    """Add declarative guest files to a staged compressed initramfs.

    This is used for commands that would otherwise have to cross a nested
    serial console byte-by-byte.  The guest still executes the same shell
    operations; only their transport is moved into an initramfs script.
    """
    if not files:
        return
    with tempfile.TemporaryDirectory(prefix="axvisor-initramfs-") as temp:
        tree = Path(temp)
        with initramfs.open("rb") as stream:
            data = subprocess.check_output(["gzip", "-dc"], stdin=stream)
        subprocess.run(["cpio", "-idmu"], cwd=tree, input=data,
                       stdout=subprocess.DEVNULL, check=True)
        for spec in files:
            source = case_dir / spec["source"]
            target = Path(spec["target"])
            if target.is_absolute():
                target = Path(str(target).lstrip("/"))
            if target.is_absolute() or ".." in target.parts:
                raise SystemExit(f"invalid guest initramfs target: {spec['target']}")
            if not source.is_file():
                raise SystemExit(f"missing guest initramfs source: {source}")
            destination = tree / target
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            destination.chmod(source.stat().st_mode & 0o7777)
        listing = subprocess.check_output(["find", ".", "-print"], cwd=tree)
        cpio = subprocess.run(["cpio", "-o", "-H", "newc"], cwd=tree,
                              input=listing, stdout=subprocess.PIPE, check=True)
        raw = initramfs.with_suffix("")
        raw.write_bytes(cpio.stdout)
        with raw.open("rb") as src, initramfs.open("wb") as dst:
            subprocess.run(["gzip", "-c"], stdin=src, stdout=dst, check=True)
        raw.unlink(missing_ok=True)


def stage_case(case_path: Path, case: dict) -> tuple[Path, Path | None, list[tuple[Path, str]]]:
    stage = WORK / "cases" / case["case"]
    if stage.exists():
        shutil.rmtree(stage)
    payload = stage / "payload"
    payload.mkdir(parents=True)
    image_dir = ensure_image(case["guest_image"]) if case.get("guest_image") else None
    if image_dir:
        copy_tree(image_dir, payload)
    local_payload = case_path.parent / "payload"
    if local_payload.is_dir():
        copy_tree(local_payload, payload)
    stage_assets(case, "payload_assets", payload)
    guest_files = case.get("guest_initramfs_files", [])
    if guest_files:
        initramfs = payload / case.get("guest_initramfs", "initramfs.cpio.gz")
        if not initramfs.is_file():
            raise SystemExit(f"guest initramfs is missing: {initramfs}")
        inject_initramfs_files(initramfs, guest_files, case_path.parent)
    for name in case.get("payload_files", []):
        if not (payload / name).is_file():
            raise SystemExit(f"{case_path}: staged payload is missing {name}")
    payload_image = None
    if "{control_payload_image}" in " ".join(case.get("extra_qemu_args", [])):
        payload_image = make_ext2(payload, stage / "payload.ext2.img", int(case.get("payload_extra_bytes", 0)))
    host_assets = declared_assets(case, "host_initramfs_assets")
    return stage, payload_image, host_assets


def stage_vm_config(case_path: Path, case: dict, stage: Path, image_dir: Path | None) -> Path | None:
    name = case.get("vm_config")
    if not name:
        return None
    source = case_path.parent / name
    if not source.is_file():
        raise SystemExit(f"{case_path}: vm_config is missing: {source}")
    text = source.read_text()
    text = text.replace("{case_dir}", str(stage))
    if image_dir:
        text = text.replace("{guest_dir}", str(image_dir))
    destination = stage / "vm.toml"
    # axvisor_core's build script watches this file. Preserve its mtime when
    # the rendered contents are unchanged so repeated runs remain incremental.
    if not destination.is_file() or destination.read_text() != text:
        destination.write_text(text)
    return destination


def prepare_initramfs(case: dict, host_assets: list[tuple[Path, str]]) -> Path | None:
    if not case.get("test_files") and not host_assets and case.get("mode") != "static":
        return None
    tests = ",".join(
        f"{item['source']}:{item['target'].lstrip('/')}"
        for item in case.get("test_files", [])
    )
    init_source = case.get("initramfs_init")
    builder = ROOT / "build-test-initramfs.sh"
    if not builder.is_file():
        raise SystemExit(f"test initramfs builder is missing: {builder}")
    assets = ",".join(f"{source}:{target}" for source, target in host_assets)
    command = [str(builder), case["arch"], tests, init_source or "", assets]
    output = subprocess.check_output(command, cwd=ROOT, text=True)
    image = Path(output.strip().splitlines()[-1])
    if not image.is_file():
        raise SystemExit(f"test initramfs builder produced no image: {image}")
    return image.resolve()


def cpuinfo_has_flag(cpuinfo: str, flag: str) -> bool:
    for line in cpuinfo.splitlines():
        _, separator, value = line.partition(":")
        if separator and flag in value.split():
            return True
    return False


def detect_x86_accel() -> str:
    try:
        cpuinfo = Path("/proc/cpuinfo").read_text()
    except OSError as exc:
        raise SystemExit(f"failed to read /proc/cpuinfo: {exc}") from exc
    if cpuinfo_has_flag(cpuinfo, "vmx"):
        return "vmx"
    if cpuinfo_has_flag(cpuinfo, "svm"):
        return "svm"
    raise SystemExit(
        f"x86 CPU does not advertise VMX or SVM; set {X86_ACCEL_ENV}=vmx or svm to force"
    )


def resolve_x86_accel() -> str:
    value = os.environ.get(X86_ACCEL_ENV, "auto").strip()
    if value in ("", "auto"):
        return detect_x86_accel()
    if value in ("vmx", "svm"):
        return value
    raise SystemExit(
        f"invalid {X86_ACCEL_ENV} value `{value}`; expected `auto`, `vmx`, or `svm`"
    )


def add_feature(features: list[str], feature: str) -> None:
    if feature not in features:
        features.append(feature)


def select_core_features(case: dict, configured: str) -> list[str]:
    features = [feature.strip() for feature in configured.split(",") if feature.strip()]
    if case["mode"] == "control":
        add_feature(features, "control")
    if case["mode"] == "conformance":
        add_feature(features, "conformance-test")
    if case["arch"] == "riscv64":
        add_feature(features, "sstc")
        return features

    accel = resolve_x86_accel()
    opposite = "svm" if accel == "vmx" else "vmx"
    if opposite in features:
        raise SystemExit(
            f"{X86_ACCEL_ENV} selected `{accel}`, but AXVISOR_CORE_FEATURES already contains `{opposite}`"
        )
    add_feature(features, accel)
    print(f"[runner] x86 virtualization backend: {accel}")
    return features


def build_host(case: dict, initramfs: Path | None, vm_config: Path | None) -> Path:
    env = os.environ.copy()
    if initramfs:
        env["AXVISOR_INITRAMFS"] = str(initramfs)
    if vm_config:
        env["AXVISOR_VM_CONFIGS"] = str(vm_config)
    core_features = select_core_features(case, env.get("AXVISOR_CORE_FEATURES", ""))
    env["AXVISOR_CORE_FEATURES"] = ",".join(core_features)
    if case["mode"] == "control":
        env["AXVISOR_HOST_FEATURES"] = "control"
    subprocess.run([str(ROOT / "build-host.sh"), "--arch", case["arch"]], cwd=ROOT, env=env, check=True)
    build_dir = WORK / ("build-riscv" if case["arch"] == "riscv64" else "build-x86")
    image = build_dir / ("arch/riscv/boot/Image" if case["arch"] == "riscv64" else "arch/x86/boot/bzImage")
    if not image.is_file():
        raise SystemExit(f"host kernel was not built: {image}")
    return image


def render_args(args: list[str], stage: Path, image_dir: Path | None, payload_image: Path | None) -> list[str]:
    values = []
    for value in args:
        value = value.replace("{case_dir}", str(stage))
        if image_dir:
            value = value.replace("{guest_dir}", str(image_dir))
        if payload_image:
            value = value.replace("{control_payload_image}", str(payload_image))
        values.append(value)
    return values


def run_process(command: list[str], case: dict, log_path: Path) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    success = [re.compile(pattern) for pattern in case.get("success_regex", [])]
    failure = [re.compile(pattern) for pattern in case.get("fail_regex", [])]
    if not success:
        raise SystemExit(f"{case['case']}: success_regex is required")
    prompt = case.get("shell_prompt")
    steps = []
    if prompt and case.get("shell_init_cmd"):
        steps.append((prompt, case["shell_init_cmd"]))
    steps.extend((item["expect"], item["send"]) for item in case.get("interactions", []))
    timeout = int(case.get("timeout_secs", 120))
    started = time.monotonic()
    raw_match_output = ""
    raw_interaction_output = ""
    match_output = ""
    interaction_output = ""
    step = 0

    # Guest UART bytes are routed through the Linux host printk console on
    # x86.  printk prefixes each byte with its own timestamp, unlike a
    # direct serial stream.  Keep the raw log,
    # but also feed prompt/marker matching a stream with those per-byte
    # prefixes removed.
    # Keep the payload's carriage return/newline bytes.  printk can emit
    # either byte as an individual record, and dropping empty/CR records
    # prevents ordinary guest lines from being reconstructed for matching.
    printk_byte = re.compile(r"^\[[^\]]+\] (.*)\n$")
    normalize_pending = ""

    def normalize_serial(text: str) -> str:
        nonlocal normalize_pending
        normalize_pending += text
        normalized = []
        # Keep an incomplete final line for the next pipe read.  QEMU may
        # split a host printk record at any byte boundary.
        lines = []
        while "\n" in normalize_pending:
            line, normalize_pending = normalize_pending.split("\n", 1)
            lines.append(line + "\n")
        for line in lines:
            match = printk_byte.match(line)
            if not match:
                normalized.append(line)
                continue
            payload = match.group(1).rstrip("\r")
            # printk emits each guest UART byte as a separate record.  Join
            # ordinary bytes directly; represent CR/empty records as a line
            # break so shell prompts and command output retain boundaries.
            if not payload:
                normalized.append("\n")
            else:
                normalized.append(payload if len(payload) == 1 else payload + "\n")
        # A normal control-console prompt is not newline-terminated.  Pass it
        # through immediately; only a possible timestamp-prefixed printk
        # record needs to remain buffered across pipe reads.
        if normalize_pending and not normalize_pending.startswith("["):
            normalized.append(normalize_pending)
            normalize_pending = ""
        return "".join(normalized)

    def send_interaction(stream, command_text: str) -> None:
        payload = (command_text + "\n").encode()
        # Write the complete command in one pipe operation. Fragmenting bytes
        # lets guest echo/output race
        # with input and can lose characters on the nested serial path.
        stream.write(payload)
        stream.flush()

    with log_path.open("w") as log:
        # QEMU's stdio chardev expects stdin and stdout to refer to the same
        # terminal.  A raw PTY preserves that contract without applying echo
        # or newline conversion to the runner's byte stream.
        master_fd, slave_fd = pty.openpty()
        tty.setraw(slave_fd)
        try:
            process = subprocess.Popen(
                command,
                cwd=ROOT,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                start_new_session=True,
            )
        finally:
            os.close(slave_fd)
        serial = os.fdopen(master_fd, "r+b", buffering=0)
        selector = selectors.DefaultSelector()
        selector.register(serial, selectors.EVENT_READ)
        while True:
            if time.monotonic() - started > timeout:
                os.killpg(process.pid, signal.SIGKILL)
                log.write("\n[runner] timeout\n")
                process.wait()
                serial.close()
                return 124
            events = selector.select(0.25)
            if not events:
                if process.poll() is not None:
                    break
                continue
            for key, _ in events:
                try:
                    data = os.read(key.fileobj.fileno(), 4096)
                except OSError:
                    data = b""
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                text = data.decode(errors="replace")
                print(text, end="")
                log.write(text)
                log.flush()
                normalized = normalize_serial(text)
                raw_match_output = (raw_match_output + text)[-65536:]
                raw_interaction_output = (raw_interaction_output + text)[-65536:]
                match_output = (match_output + normalized)[-65536:]
                interaction_output = (interaction_output + normalized)[-65536:]
                if any(regex.search(match_output) or regex.search(raw_match_output)
                       for regex in failure):
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait()
                    serial.close()
                    return 1
                while step < len(steps) and (
                    steps[step][0] in interaction_output
                    or steps[step][0] in raw_interaction_output
                ):
                    try:
                        send_interaction(serial, steps[step][1])
                    except (BrokenPipeError, OSError):
                        serial.close()
                        return 1
                    step += 1
                    interaction_output = ""
                    raw_interaction_output = ""
                if any(regex.search(match_output) or regex.search(raw_match_output)
                       for regex in success):
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait()
                    serial.close()
                    return 0
            if process.poll() is not None and not selector.get_map():
                break
        serial.close()
        return 0 if any(
            regex.search(match_output) or regex.search(raw_match_output)
            for regex in success
        ) else 1


def list_cases() -> int:
    for path in sorted(CASES.rglob("case.toml")):
        case = load(path)
        print(f"{case.get('case', path.parent.name)}\t{case.get('arch', '?')}\t{case.get('mode', '?')}\t{case.get('status', 'active')}\t{path.relative_to(ROOT)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--case", help="case name or case.toml path")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="validate only; do not build or run")
    args = parser.parse_args()
    if args.list:
        return list_cases()
    if not args.case:
        parser.error("--case is required unless --list is used")
    case_path = find_case(args.case)
    case = load(case_path)
    host_path = HOSTS / f"{case['host_profile']}.toml"
    if not host_path.is_file():
        raise SystemExit(f"host profile not found: {host_path}")
    host = load(host_path)
    validate(case_path, case, host)
    if args.dry_run:
        print(f"validated {case['case']}")
        return 0
    if case.get("status", "active") == "planned":
        raise SystemExit(f"case is planned but has no executable backend: {case['case']}")

    stage, payload_image, host_assets = stage_case(case_path, case)
    image_dir = ensure_image(case["guest_image"]) if case.get("guest_image") else None
    vm_config = stage_vm_config(case_path, case, stage, image_dir)
    initramfs = prepare_initramfs(case, host_assets)
    if case.get("run_command"):
        command = render_args(case["run_command"], stage, None, payload_image)
    else:
        kernel = build_host(case, initramfs, vm_config)
        command = [host["qemu_binary"], *host.get("qemu_args", [])]
        command += ["-kernel", str(kernel)]
        cmdline = case.get("host_cmdline", "console=ttyS0 earlycon=sbi panic=-1 init=/bin/sh")
        if case["mode"] == "control":
            cmdline += " axvisor_linux.control=1"
        if case["mode"] == "conformance":
            cmdline += " axvisor_linux.conformance=1"
        command += ["-append", cmdline]
        command += render_args(case.get("extra_qemu_args", []), stage, image_dir, payload_image)
    log_path = WORK / "logs" / f"{case['case']}.log"
    result = run_process(command, case, log_path)
    status = "pass" if result == 0 else ("timeout" if result == 124 else "fail")
    (WORK / "logs" / f"{case['case']}.status").write_text(status + "\n")
    return result


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(141)

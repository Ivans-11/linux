#!/usr/bin/env python3
"""Resolve case-declared test assets into the repository .work cache.

The catalog describes immutable downloads or source repositories.  Building is
deliberately generic: an asset's recipe is selected by its catalog entry, not
by a runner branch for lkvm/Firecracker/gVisor.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WORK = ROOT / ".work" / "assets"
CATALOG_PATH = ROOT / "tests" / "assets.toml"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def fetch_download(label: str, spec: dict) -> Path:
    expected = spec.get("sha256")
    if not expected:
        raise SystemExit(f"download asset {label} must declare sha256")
    directory = WORK / "downloads" / label
    directory.mkdir(parents=True, exist_ok=True)
    filename = Path(spec["url"].split("?", 1)[0]).name or "artifact"
    artifact = directory / filename
    if not artifact.is_file() or sha256(artifact) != expected:
        part = artifact.with_name(artifact.name + ".part")
        subprocess.run(
            ["curl", "--fail", "--location", "--retry", "3", "-o", str(part), spec["url"]],
            check=True,
        )
        if sha256(part) != expected:
            part.unlink(missing_ok=True)
            raise SystemExit(f"asset checksum mismatch: {label}")
        part.replace(artifact)
    return artifact


def fetch_source(label: str, spec: dict) -> tuple[Path, str]:
    if spec.get("source_type") == "archive":
        source_url = spec.get("source")
        expected = spec.get("source_sha256")
        if not source_url or not expected:
            raise SystemExit(f"archive source asset {label} needs source and source_sha256")
        directory = WORK / "sources" / label
        archive = directory / Path(source_url.split("?", 1)[0]).name
        extracted = directory / "extracted"
        directory.mkdir(parents=True, exist_ok=True)
        if not archive.is_file() or sha256(archive) != expected:
            part = archive.with_name(archive.name + ".part")
            subprocess.run(["curl", "--fail", "--location", "--retry", "3", "-o", str(part), source_url], check=True)
            if sha256(part) != expected:
                part.unlink(missing_ok=True)
                raise SystemExit(f"source checksum mismatch: {label}")
            part.replace(archive)
        if not extracted.is_dir():
            extracted.mkdir()
            with tarfile.open(archive, "r:*") as tar:
                for member in tar.getmembers():
                    member_path = Path(member.name)
                    if member_path.is_absolute() or ".." in member_path.parts:
                        raise SystemExit(f"unsafe path in source archive {label}: {member.name}")
                tar.extractall(extracted)
        children = [item for item in extracted.iterdir() if item.is_dir()]
        source = children[0] if len(children) == 1 else extracted
        return source, expected
    revision = spec.get("revision")
    source_url = spec.get("source")
    if not revision or not source_url:
        raise SystemExit(f"source-build asset {label} needs source and revision")
    source = WORK / "sources" / label
    source.parent.mkdir(parents=True, exist_ok=True)
    if not (source / ".git").is_dir():
        if source.exists():
            shutil.rmtree(source)
        subprocess.run(["git", "clone", "--no-checkout", source_url, str(source)], check=True)
    # Reuse an already populated immutable checkout without requiring network
    # access.  Fetch only when the requested object is not present locally.
    have_revision = subprocess.run(
        ["git", "-C", str(source), "cat-file", "-e", f"{revision}^{{commit}}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0
    if not have_revision:
        subprocess.run(["git", "-C", str(source), "fetch", "--tags", "--force", "origin"], check=True)
    subprocess.run(["git", "-C", str(source), "checkout", "--force", revision], check=True)
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    # A full hash must match exactly.  Tags/branches are accepted for
    # convenience, but the resolved commit is recorded in the build metadata.
    if len(revision) == 40 and actual != revision:
        raise SystemExit(f"source revision mismatch for {label}: {actual} != {revision}")
    return source, actual


def build_asset(label: str, spec: dict, arch: str) -> Path:
    kind = spec.get("kind")
    if kind == "download":
        return fetch_download(label, spec)
    if kind == "nix":
        expression = ROOT / spec.get("expression", "")
        attribute = spec.get("attribute")
        if not expression.is_file() or not attribute:
            raise SystemExit(f"nix asset {label} needs expression and attribute")
        recipe_files = sorted(expression.parent.rglob("*.nix"))
        recipe_hash = hashlib.sha256()
        for recipe in recipe_files:
            recipe_hash.update(str(recipe.relative_to(ROOT)).encode())
            recipe_hash.update(recipe.read_bytes())
        out_dir = WORK / "nix" / label
        out_dir.mkdir(parents=True, exist_ok=True)
        metadata = out_dir / "metadata.json"
        wanted = {
            "arch": arch,
            "expression": str(expression.relative_to(ROOT)),
            "attribute": attribute,
            "recipe": recipe_hash.hexdigest(),
        }
        cached = out_dir / "path"
        if cached.is_symlink() or cached.is_file():
            cached_path = Path(cached.read_text().strip())
            if cached_path.exists() and metadata.is_file():
                try:
                    if json.loads(metadata.read_text()) == wanted:
                        return cached_path
                except (OSError, ValueError):
                    pass
        command = [
            "nix-build",
            str(expression),
            "--no-out-link",
            "--argstr",
            "target",
            arch,
            "-A",
            attribute,
        ]
        output = subprocess.check_output(command, cwd=ROOT, text=True, stderr=None)
        result = Path(output.strip().splitlines()[-1])
        if not result.exists():
            raise SystemExit(f"nix asset produced no output: {label}")
        cached.write_text(str(result) + "\n")
        metadata.write_text(json.dumps(wanted, sort_keys=True) + "\n")
        return result
    if kind != "source-build":
        raise SystemExit(f"unsupported asset kind for {label}: {kind!r}")
    source, source_id = fetch_source(label, spec)
    recipe = ROOT / spec.get("build", "")
    if not recipe.is_file():
        raise SystemExit(f"asset build recipe is missing: {recipe}")
    recipe_hash = sha256(recipe)
    out_dir = WORK / "built" / label
    out_dir.mkdir(parents=True, exist_ok=True)
    artifact = out_dir / "artifact"
    metadata = out_dir / "metadata.json"
    wanted = {"arch": arch, "source": source_id, "recipe": recipe_hash}
    if artifact.is_file() and metadata.is_file():
        try:
            if json.loads(metadata.read_text()) == wanted:
                return artifact
        except (OSError, ValueError):
            pass
    temporary = artifact.with_name("artifact.part")
    temporary.unlink(missing_ok=True)
    env = os.environ.copy()
    env.update({
        "ASSET_LABEL": label,
        "ASSET_ARCH": arch,
        "ASSET_SOURCE": str(source),
        "ASSET_OUTPUT": str(temporary),
    })
    subprocess.run([str(recipe)], cwd=ROOT, env=env, check=True)
    if not temporary.is_file():
        raise SystemExit(f"asset recipe produced no output: {label}")
    temporary.replace(artifact)
    metadata.write_text(json.dumps(wanted, sort_keys=True) + "\n")
    return artifact


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", required=True, choices=("riscv64", "x86_64"))
    parser.add_argument("--asset", action="append", required=True)
    args = parser.parse_args()
    catalog = tomllib.loads(CATALOG_PATH.read_text())
    entries = catalog.get("assets", {})
    for label in args.asset:
        spec = entries.get(label)
        if not spec:
            raise SystemExit(f"undefined asset: {label}")
        if spec.get("arch") and spec["arch"] != args.arch:
            raise SystemExit(f"asset {label} is for {spec['arch']}, not {args.arch}")
        path = build_asset(label, spec, args.arch)
        print(f"{label}\t{path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOP = [
    "install.sh", "install.ps1", "uninstall.sh", "uninstall.ps1", "backend.sh", "backend.ps1",
    "README.md", "LICENSE", ".github/workflows/build.yml"
]
DIRECTORIES = ["extension", "scripts", "tests"]
SUFFIXES = {".js", ".cjs", ".html", ".css", ".json", ".sh", ".ps1", ".py", ".png", ".svg", ".ico"}
PREFIX = "amnezia-web-extension-main/"

class References(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = []
    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "script" and "src" in values: self.paths.append(values["src"])
        if tag == "link" and "href" in values: self.paths.append(values["href"])

def validate(archive):
    with zipfile.ZipFile(archive) as package:
        if package.testzip() is not None:
            raise ValueError("ZIP CRC validation failed")
        names = package.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate archive entries")
        for name in names:
            parts = PurePosixPath(name).parts
            if ".." in parts or name.startswith("/") or not name.startswith(PREFIX):
                raise ValueError("Unsafe archive path")
        for name in TOP:
            if PREFIX + name not in names: raise ValueError("Missing required file: " + name)
        extension = PREFIX + "extension/"
        manifest = json.loads(package.read(extension + "manifest.json"))
        json.loads(package.read(extension + "release.json"))
        for name in [manifest["background"]["service_worker"], manifest["action"]["default_popup"], manifest["options_ui"]["page"]]:
            if extension + name not in names: raise ValueError("Missing extension entry: " + name)
        for name in names:
            if name.endswith(".json"): json.loads(package.read(name))
            if name.endswith(".html"):
                parser = References()
                parser.feed(package.read(name).decode())
                for reference in parser.paths:
                    if (PurePosixPath(name).parent / reference).as_posix() not in names:
                        raise ValueError("Missing HTML asset: " + reference)
            if name.endswith(".sh") and not package.getinfo(name).external_attr >> 16 & stat.S_IXUSR:
                raise ValueError("Shell executable bit missing: " + name)
        return manifest["version"], len(names)

def build(output, repository=None, version=None):
    manifest = json.loads((ROOT / "extension/manifest.json").read_text())
    actual = manifest["version"]
    if not re.fullmatch(r"(0|[1-9][0-9]{0,4})(\.(0|[1-9][0-9]{0,4})){0,3}", actual):
        raise ValueError("Invalid Chrome version")
    numbers = list(map(int, actual.split(".")))
    if max(numbers) > 65535 or not any(numbers): raise ValueError("Invalid Chrome version")
    if version is not None and version.removeprefix("v") != actual:
        raise ValueError("Tag must match manifest version; packaging never changes it")
    if repository is not None and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid release repository")
    files = [ROOT / name for name in TOP]
    for directory in DIRECTORIES:
        files.extend(file for file in (ROOT / directory).rglob("*")
                     if file.is_file() and file.suffix in SUFFIXES
                     and not any(part in {"__pycache__", "node_modules", ".git"} for part in file.relative_to(ROOT).parts))
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as package:
            for file in sorted(set(files)):
                if file.is_symlink(): raise ValueError("Symlinks are not packaged")
                relative = file.relative_to(ROOT).as_posix()
                data = file.read_bytes()
                if relative == "extension/release.json" and repository is not None:
                    data = (json.dumps({"repository": repository}, separators=(",", ":")) + "\n").encode()
                entry = zipfile.ZipInfo(PREFIX + relative, date_time=(2026, 9, 7, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | (0o755 if file.suffix == ".sh" else 0o644)) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                package.writestr(entry, data)
        actual, count = validate(temporary)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(digest + "  " + output.name + "\n")
    print(json.dumps({"archive": str(output), "version": actual, "files": count, "sha256": digest}))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--repository")
    parser.add_argument("--version")
    args = parser.parse_args()
    build(args.output, args.repository, args.version)

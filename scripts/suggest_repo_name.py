import json
import os
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path


MAX_TEXT_CHARS = 4000
MODEL_FALLBACK = "gpt-4.1-mini"
LOCAL_CMD_ENV = "REPO_NAME_LOCAL_AI_CMD"


def read_text_file(path: Path, limit: int = MAX_TEXT_CHARS) -> str:
    try:
        content = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        try:
            content = path.read_text(encoding="gbk")
        except Exception:
            return ""
    except Exception:
        return ""

    return content.lstrip("\ufeff")[:limit].strip()


def find_first(root: Path, patterns: list[str]) -> list[Path]:
    found: list[Path] = []
    for pattern in patterns:
        found.extend(root.glob(pattern))
        if found:
            return found
    return found


def summarize_project(project_path: Path) -> str:
    parts: list[str] = [f"Project folder name: {project_path.name}"]

    top_level_entries = sorted(
        [
            entry.name
            for entry in project_path.iterdir()
            if entry.name not in {".git", ".venv", "node_modules", "__pycache__"}
        ]
    )[:20]
    if top_level_entries:
        parts.append("Top-level entries: " + ", ".join(top_level_entries))

    readme_candidates = find_first(project_path, ["README.md", "readme.md", "README.txt"])
    if readme_candidates:
        readme_text = read_text_file(readme_candidates[0])
        if readme_text:
            parts.append(f"README excerpt:\n{readme_text}")

    manifest_patterns = [
        "package.json",
        "pyproject.toml",
        "Cargo.toml",
        "*.csproj",
        "*.fsproj",
        "*.vbproj",
        "go.mod",
    ]
    manifest_candidates = find_first(project_path, manifest_patterns)
    if manifest_candidates:
        manifest_text = read_text_file(manifest_candidates[0], limit=2500)
        if manifest_text:
            parts.append(f"Manifest excerpt from {manifest_candidates[0].name}:\n{manifest_text}")

    return "\n\n".join(parts)


def sanitize_slug(value: str) -> str:
    slug = value.strip().lower()
    slug = re.sub(r"```.*?```", "", slug, flags=re.S)
    slug = re.sub(r"[^a-z0-9]+", "-", slug)
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    return slug[:100].strip("-")


def extract_message_content(response_payload: dict) -> str:
    choices = response_payload.get("choices") or []
    if not choices:
        return ""

    message = choices[0].get("message") or {}
    content = message.get("content", "")
    if isinstance(content, str):
        return content

    if isinstance(content, list):
        text_parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text_parts.append(item.get("text", ""))
        return "\n".join(text_parts)

    return ""


def request_repo_name(summary: str) -> str:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        return ""

    base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
    model = os.environ.get("OPENAI_MODEL", MODEL_FALLBACK)
    endpoint = f"{base_url}/chat/completions"

    system_prompt = (
        "You generate short GitHub repository names. "
        "Return only one repository slug using lowercase english words, digits, and hyphens. "
        "No explanation, no punctuation other than hyphens, no code fences, no owner prefix."
    )
    user_prompt = (
        "Suggest a concise English GitHub repository name for this software project.\n"
        "Prefer 2 to 5 words.\n"
        "Avoid generic names like project-app-tool unless necessary.\n\n"
        f"{summary}"
    )

    body = json.dumps(
        {
            "model": model,
            "temperature": 0.2,
            "max_tokens": 30,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        }
    ).encode("utf-8")

    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return ""

    return extract_message_content(payload)


def request_repo_name_from_local_ai(summary: str, project_path: Path) -> str:
    command_template = os.environ.get(LOCAL_CMD_ENV, "").strip()
    if not command_template:
        return ""

    project_name = project_path.name
    try:
        command_parts = shlex.split(command_template, posix=False)
    except ValueError:
        return ""

    command = [
        part.replace("{project_path}", str(project_path)).replace("{project_name}", project_name)
        for part in command_parts
    ]
    if not command:
        return ""

    prompt = (
        "Suggest one concise English GitHub repository name for this software project.\n"
        "Return only one slug using lowercase letters, digits, and hyphens.\n"
        "No explanation.\n\n"
        f"{summary}\n"
    )

    try:
        completed = subprocess.run(
            command,
            input=prompt,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="ignore",
            timeout=60,
            shell=False,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""

    if completed.returncode != 0:
        return ""

    return completed.stdout.strip()


def main() -> int:
    if len(sys.argv) < 2:
        return 1

    project_path = Path(sys.argv[1]).resolve()
    if not project_path.exists() or not project_path.is_dir():
        return 1

    summary = summarize_project(project_path)
    suggestion = request_repo_name(summary)
    if not suggestion:
        suggestion = request_repo_name_from_local_ai(summary, project_path)
    slug = sanitize_slug(suggestion)
    if not slug:
        return 1

    print(slug)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

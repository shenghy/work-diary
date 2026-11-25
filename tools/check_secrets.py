# 密钥扫描工具（推送公开仓前强制运行）
# 用法：
#   python tools/check_secrets.py                # 扫描当前 git 索引中的文件
#   python tools/check_secrets.py --ref public   # 扫描指定 git 分支的完整文件树
#
# 真实凭据字面量存放在 tools/check_secrets.local.txt（已被 .gitignore 忽略，
# 永不入库）；没有该文件时仅执行通用模式扫描并给出提示。
import re
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO_ROOT = Path(__file__).resolve().parent.parent
LOCAL_LITERALS_FILE = REPO_ROOT / "tools" / "check_secrets.local.txt"

FORBIDDEN_PATTERNS = [
    re.compile(r"(?<![A-Za-z0-9_])sk-[A-Za-z0-9]{20,}"),
    re.compile(r"(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{30,}"),
    re.compile(r"(?<![A-Za-z0-9_])AKLT[A-Za-z0-9]{16,}"),
]

# 仅本地保留、不进入公开快照的文件/目录（以 / 结尾表示整个目录）。
# --ref 模式下这些路径本就不存在；工作区模式跳过并提示。
LOCAL_ONLY = [
    "MySql.md",
    "Plan.md",
    "newPlan.md",
    "upyun.md",
    "create_tables.py",
    "setup_remote_db.py",
    "init_remote_db.sql",
    "email_server.py",
    "服务架构图.html",
    "服务架构图.png",
    "项目架构总览.html",
    "bubble_styles.html",
    "new_dialog_styles.html",
    "theme_switch_mockup.html",
    "字体预览.html",
    "后台版本管理版面方案.html",
    "官网Hero版面方案.html",
    "官网玻璃主题设计稿.html",
    "附件拟物样式方案.html",
    "官网改版方案.md",
    "plan/",
    "docs/",
    "work_diary_app_android/",
    "图标方案/",
    "备忘卡片设计方案/",
    "备忘界面方案/",
    "新建弹窗设计方案/",
    "过期印章设计方案/",
    "宣传配图/",
]

SKIP_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".ttf", ".woff", ".woff2",
                 ".exe", ".zip", ".apk", ".msi", ".lock", ".pyc", ".dill")


def load_literals() -> list[str]:
    if not LOCAL_LITERALS_FILE.exists():
        print("  [提示] 缺少 tools/check_secrets.local.txt，仅执行通用模式扫描")
        return []
    lines = []
    for raw in LOCAL_LITERALS_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return lines


def is_local_only(rel: str) -> bool:
    for e in LOCAL_ONLY:
        if e.endswith("/") and rel.startswith(e):
            return True
        if rel == e:
            return True
    return False


def scan_text(rel: str, text: str, literals: list[str]) -> list[str]:
    hits = []
    low = text.lower()
    for lit in literals:
        if lit.lower() in low:
            hits.append(f"{rel}: 命中字面量 [{lit[:6]}...]")
    for pat in FORBIDDEN_PATTERNS:
        for m in pat.finditer(text):
            hits.append(f"{rel}: 命中模式 [{m.group(0)[:16]}...]")
    return hits


def iter_ref(ref: str):
    files = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", ref],
        cwd=REPO_ROOT, capture_output=True, text=True, encoding="utf-8", check=True
    ).stdout.splitlines()
    for f in files:
        yield f, subprocess.run(
            ["git", "show", f"{ref}:{f}"],
            cwd=REPO_ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace"
        ).stdout


def iter_index():
    files = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO_ROOT, capture_output=True, check=True
    ).stdout.decode("utf-8").split("\0")
    for f in files:
        if not f:
            continue
        if is_local_only(f):
            print(f"  [跳过本地专属] {f}")
            continue
        p = REPO_ROOT / f
        if p.exists():
            yield f, p.read_text(encoding="utf-8", errors="replace")


def main() -> int:
    literals = load_literals()
    ref = None
    if "--ref" in sys.argv:
        ref = sys.argv[sys.argv.index("--ref") + 1]
    source = iter_ref(ref) if ref else iter_index()
    hits = []
    for rel, text in source:
        if rel.lower().endswith(SKIP_SUFFIXES):
            continue
        hits.extend(scan_text(rel, text, literals))
    if hits:
        print(f"✗ 发现 {len(hits)} 处敏感内容，禁止推送：")
        for h in hits:
            print("  -", h)
        return 1
    print("✓ 密钥扫描通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

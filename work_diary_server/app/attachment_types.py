"""附件类型白名单：三端（桌面 / 小程序 / 服务端）统一的判定口径。

只允许"文档 + 图片"。可执行文件、视频、音频、压缩包一律拒绝——服务端必须自己
再判一次：客户端的校验用户可以绕过（改扩展名、直接调接口），而中转文件最终会被
另一台机器一键打开，这是真正的安全边界。
"""
from pathlib import Path

IMAGE_EXTS = {
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp",
}

DOC_EXTS = {
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".txt", ".md", ".csv", ".rtf", ".ofd", ".wps", ".et", ".dps",
}

# 拒绝原因按类别给不同文案，用户才知道该换什么，而不是笼统一句"不支持"。
EXECUTABLE_EXTS = {
    ".exe", ".msi", ".msp", ".bat", ".cmd", ".com", ".scr", ".ps1", ".psm1",
    ".vbs", ".vbe", ".js", ".jse", ".wsf", ".wsh", ".dll", ".sys", ".drv",
    ".reg", ".lnk", ".apk", ".jar", ".sh", ".msu", ".cpl", ".msiexec",
}
VIDEO_EXTS = {
    ".mp4", ".mov", ".avi", ".mkv", ".flv", ".wmv", ".webm", ".m4v", ".mpg",
    ".mpeg", ".3gp", ".ts", ".vob", ".rmvb", ".asf",
}
AUDIO_EXTS = {
    ".mp3", ".wav", ".m4a", ".flac", ".aac", ".ogg", ".wma", ".amr", ".opus",
    ".mid", ".midi",
}
ARCHIVE_EXTS = {
    ".zip", ".rar", ".7z", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".iso",
}

MIME_BY_EXT = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".bmp": "image/bmp",
    ".pdf": "application/pdf",
    ".doc": "application/msword",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xls": "application/vnd.ms-excel",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".ppt": "application/vnd.ms-powerpoint",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".txt": "text/plain",
    ".md": "text/markdown",
    ".csv": "text/csv",
    ".rtf": "application/rtf",
    ".ofd": "application/ofd",
    ".wps": "application/wps-office.doc",
    ".et": "application/wps-office.xlsx",
    ".dps": "application/wps-office.pptx",
}

ALLOWED_HINT = "仅支持图片和文档（jpg/png/gif/webp/bmp、pdf/word/excel/ppt/txt/md/csv 等）"


def classify(filename: str) -> tuple[bool, str, str]:
    """返回 (是否允许, MIME, 拒绝原因)。"""
    ext = Path(filename or "").suffix.lower()
    if ext in IMAGE_EXTS or ext in DOC_EXTS:
        return True, MIME_BY_EXT.get(ext, "application/octet-stream"), ""
    if ext in EXECUTABLE_EXTS:
        return False, "", f"可执行文件（{ext}）不支持保存，{ALLOWED_HINT}"
    if ext in VIDEO_EXTS:
        return False, "", f"视频文件（{ext}）不支持保存，{ALLOWED_HINT}"
    if ext in AUDIO_EXTS:
        return False, "", f"音频文件（{ext}）不支持保存，{ALLOWED_HINT}"
    if ext in ARCHIVE_EXTS:
        return False, "", f"压缩包（{ext}）不支持保存，{ALLOWED_HINT}"
    return False, "", f"该类型（{ext or '无扩展名'}）不支持保存，{ALLOWED_HINT}"


def looks_executable(head: bytes) -> bool:
    """按文件头判断是否可执行文件，拦住"把 exe 改名成 pdf"的绕过。

    只需要看前两位：PE 的 MZ、Linux 的 ELF。其它二进制格式即使混进来，
    也不会因为改名变成可执行程序。
    """
    return head.startswith(b"MZ") or head.startswith(b"\x7fELF")

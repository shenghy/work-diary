"""版本管理：Windows（ZIP 免安装包 + EXE 安装包）与微信小程序（仅版本号 + 更新说明）。

- 客户端自动升级接口保持兼容：/api/version/latest
- 官网联动：/api/website/downloads（一次拉取 Windows / 小程序 / 统计 / 二维码）
- 管理后台：Windows、小程序各自独立版本管理；站点设置上传入群二维码
- Android 版已停止维护（2026-11 起由微信小程序替代），相关接口已下线，
  历史数据仍保留在 app_versions_android 表中。
"""
import re
import shutil
import zipfile
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

from ..config import settings
from ..database import get_conn
from .deps import require_admin

router = APIRouter(tags=["version"])

# 升级包存放目录（服务端根目录/downloads）
_DOWNLOAD_DIR = Path(__file__).resolve().parent.parent.parent / "downloads"
_DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
# 站点图片上传目录（官网二维码等，挂在 /static/uploads 下）
_STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
_UPLOAD_DIR = _STATIC_DIR / "uploads"
_UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

# 版本号白名单：x.y.z，禁止任何其他字符（防路径穿越）
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")
# 升级包大小上限 200MB
MAX_FILE_SIZE = 200 * 1024 * 1024
# 图片上传大小上限 5MB
MAX_IMAGE_SIZE = 5 * 1024 * 1024
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp"}

_QR_KEY = "group_qrcode"
_AUTHOR_KEY = "author_qrcode"
_AUTHOR_ACCOUNT_KEY = "author_account"
DEFAULT_AUTHOR_ACCOUNT = "php100"


def _version_tuple(v: str) -> tuple[int, ...]:
    """把 '1.2.3' 转成 (1,2,3) 用于比较。"""
    try:
        return tuple(int(x) for x in v.strip().split("."))
    except (ValueError, AttributeError):
        return (0,)


def _mb(size):
    return round(size / 1024 / 1024, 2) if size else 0


def _fmt(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S") if dt else ""


def _save_upload(file: UploadFile, save_path: Path, max_size: int, exts: set[str], need_zip_check: bool = False):
    """通用文件落盘：大小限制 + 扩展名校验（可选 zip 内容校验）。返回文件字节数。"""
    if not file.filename:
        raise HTTPException(status_code=400, detail="文件名为空")
    ext = Path(file.filename).suffix.lower()
    if ext not in exts:
        raise HTTPException(status_code=400, detail=f"不支持的文件类型：{ext}")
    file.file.seek(0, 2)
    file_len = file.file.tell()
    file.file.seek(0)
    if file_len > max_size:
        raise HTTPException(status_code=400, detail=f"文件超过大小限制（{max_size // (1024 * 1024)}MB）")
    with save_path.open("wb") as f:
        shutil.copyfileobj(file.file, f)
    size = save_path.stat().st_size
    if need_zip_check:
        try:
            with zipfile.ZipFile(save_path) as zf:
                bad = zf.testzip()
                if bad is not None:
                    save_path.unlink(missing_ok=True)
                    raise HTTPException(status_code=400, detail=f"压缩包内容损坏：{bad}")
        except zipfile.BadZipFile:
            save_path.unlink(missing_ok=True)
            raise HTTPException(status_code=400, detail="上传文件不是有效的 zip 压缩包")
    return size


def _get_site_value(cur, key: str):
    cur.execute("SELECT site_value FROM site_settings WHERE site_key = %s", (key,))
    row = cur.fetchone()
    return row["site_value"] if row else None


def _get_site_updated(cur, key: str):
    """读取站点设置项的上次更新时间（未设置时返回 None）。"""
    cur.execute("SELECT updated_at FROM site_settings WHERE site_key = %s", (key,))
    row = cur.fetchone()
    return _fmt(row["updated_at"]) if row and row["updated_at"] else None


def _set_site_value(cur, key: str, value):
    cur.execute(
        "INSERT INTO site_settings (site_key, site_value) VALUES (%s, %s) "
        "ON DUPLICATE KEY UPDATE site_value = VALUES(site_value)",
        (key, value),
    )


# ======================================================================
# 公开接口：客户端自动升级 + 官网联动
# ======================================================================

@router.get("/api/version/latest")
def latest_version():
    """Windows 客户端查询最新生效版本（无需登录），兼容旧客户端。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT version, download_url, exe_url, release_notes, force_update, "
                "file_size, exe_file_size, created_at "
                "FROM app_versions WHERE is_active = 1 ORDER BY id DESC LIMIT 1"
            )
            row = cur.fetchone()
    if not row:
        return JSONResponse({"has_update": False})
    return JSONResponse({
        "has_update": True,
        "version": row["version"],
        "download_url": row["download_url"],
        "exe_url": row["exe_url"],
        "release_notes": row["release_notes"] or "",
        "force_update": bool(row["force_update"]),
        "file_size": row["file_size"],
        "exe_file_size": row["exe_file_size"],
        "published_at": _fmt(row["created_at"]),
    })


@router.get("/api/website/changelog")
def website_changelog():
    """官网更新日志：返回 Windows / 小程序全部版本记录（按发布时间倒序，最新在前）。

    供官网「更新日志」面板使用，无需登录。每个平台最多返回最近 30 条。
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT version, release_notes, force_update, is_active, file_size, created_at "
                "FROM app_versions ORDER BY created_at DESC, id DESC LIMIT 30"
            )
            win_rows = cur.fetchall()
            cur.execute(
                "SELECT version, release_notes, is_active, created_at "
                "FROM app_versions_miniprogram ORDER BY created_at DESC, id DESC LIMIT 30"
            )
            mp_rows = cur.fetchall()

    def fmt_list(rows):
        return [
            {
                "version": r["version"],
                "release_notes": r["release_notes"] or "",
                "force_update": bool(r.get("force_update", 0)),
                "is_active": bool(r["is_active"]),
                "file_size": r.get("file_size"),
                "file_size_mb": _mb(r.get("file_size")),
                "published_at": _fmt(r["created_at"]),
            }
            for r in rows
        ]

    return JSONResponse({"windows": fmt_list(win_rows),
                         "miniprogram": fmt_list(mp_rows)})


@router.get("/api/website/downloads")
def website_downloads():
    """官网首页联动：一次拉取 Windows / 小程序当前生效版本 + 统计 + 入群二维码。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT version, download_url, exe_url, release_notes, force_update, "
                "file_size, exe_file_size, created_at "
                "FROM app_versions WHERE is_active = 1 ORDER BY id DESC LIMIT 1"
            )
            win = cur.fetchone()
            cur.execute(
                "SELECT version, release_notes, created_at "
                "FROM app_versions_miniprogram WHERE is_active = 1 ORDER BY id DESC LIMIT 1"
            )
            mp = cur.fetchone()
            # 官网数据带统计：累计更新次数 / 最近更新 / 维护起点（Windows + 小程序两表合并）
            cur.execute(
                "SELECT COUNT(*) AS cnt, MIN(created_at) AS first_at, MAX(created_at) AS last_at FROM ("
                "  SELECT created_at FROM app_versions UNION ALL SELECT created_at FROM app_versions_miniprogram"
                ") t"
            )
            stats_row = cur.fetchone()
            qr = _get_site_value(cur, _QR_KEY)
            author_qr = _get_site_value(cur, _AUTHOR_KEY)
            author_account = _get_site_value(cur, _AUTHOR_ACCOUNT_KEY) or DEFAULT_AUTHOR_ACCOUNT

    def win_json(r):
        return {
            "version": r["version"],
            "zip_url": r["download_url"],
            "zip_size": r["file_size"],
            "zip_size_mb": _mb(r["file_size"]),
            "exe_url": r["exe_url"],
            "exe_size": r["exe_file_size"],
            "exe_size_mb": _mb(r["exe_file_size"]),
            "release_notes": r["release_notes"] or "",
            "force_update": bool(r["force_update"]),
            "published_at": _fmt(r["created_at"]),
        }

    def mp_json(r):
        return {
            "version": r["version"],
            "release_notes": r["release_notes"] or "",
            "published_at": _fmt(r["created_at"]),
        }

    stats = None
    if stats_row and stats_row["cnt"]:
        first_at, last_at = stats_row["first_at"], stats_row["last_at"]
        stats = {
            "update_count": stats_row["cnt"],
            "last_updated": _fmt(last_at)[:10] if last_at else "",
            "maintenance_start": _fmt(first_at)[:10] if first_at else "",
            "maintenance_days": (last_at.date() - first_at.date()).days + 1 if first_at and last_at else 0,
        }

    return JSONResponse({
        "windows": win_json(win) if win else None,
        "miniprogram": mp_json(mp) if mp else None,
        "stats": stats,
        "qrcode_url": f"/static/{qr}" if qr else None,
        "author_qrcode_url": f"/static/{author_qr}" if author_qr else None,
        "author_account": author_account,
    })


# ======================================================================
# Windows 版本管理
# ======================================================================

@router.get("/admin/api/versions")
def admin_list_versions(_: None = Depends(require_admin)):
    """管理后台：获取 Windows 所有版本列表（含 ZIP / EXE）。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, version, download_url, exe_url, release_notes, force_update, is_active, "
                "file_size, exe_file_size, created_at FROM app_versions ORDER BY id DESC LIMIT 50"
            )
            rows = cur.fetchall()
    return JSONResponse({
        "versions": [
            {
                "id": r["id"],
                "version": r["version"],
                "download_url": r["download_url"],
                "zip_url": r["download_url"],
                "zip_size": r["file_size"],
                "zip_size_mb": _mb(r["file_size"]),
                "exe_url": r["exe_url"],
                "exe_size": r["exe_file_size"],
                "exe_size_mb": _mb(r["exe_file_size"]),
                "release_notes": r["release_notes"] or "",
                "force_update": bool(r["force_update"]),
                "is_active": bool(r["is_active"]),
                "file_size_mb": _mb(r["file_size"]),
                "created_at": _fmt(r["created_at"]),
            }
            for r in rows
        ]
    })


@router.post("/admin/api/versions")
async def admin_create_version(
    version: str = Form(...),
    release_notes: str = Form(""),
    force_update: int = Form(0),
    zip_file: UploadFile | None = File(None),
    exe_file: UploadFile | None = File(None),
    file: UploadFile | None = File(None),
    _: None = Depends(require_admin),
):
    """管理后台：上传 Windows 新版本（ZIP 免安装包 + EXE 安装包，至少上传一个）。

    兼容旧后台：`file` 字段视作 ZIP 包上传。
    同一版本号重复上传时，自动替换旧记录（保留原生效状态），方便重新打包上传。
    安全校验：版本号格式白名单（防路径穿越）、文件大小上限、zip 内容合法性。
    """
    version = version.strip()
    if not VERSION_PATTERN.match(version):
        raise HTTPException(status_code=400, detail="版本号格式不正确，应为 x.y.z（如 1.1.0）")
    if zip_file is None and exe_file is None and file is None:
        raise HTTPException(status_code=400, detail="请至少上传一个文件（ZIP 免安装包或 EXE 安装包）")

    zip_url = exe_url = None
    zip_size = exe_size = None

    # ZIP：兼容旧字段 file 与新字段 zip_file
    zip_src = zip_file if zip_file is not None else file
    if zip_src is not None:
        if not zip_src.filename or not zip_src.filename.lower().endswith(".zip"):
            raise HTTPException(status_code=400, detail="ZIP 包必须是 .zip 格式")
        zip_name = f"work_diary_app_v{version}.zip"
        zip_size = _save_upload(zip_src, _DOWNLOAD_DIR / zip_name, MAX_FILE_SIZE, {".zip"}, need_zip_check=True)
        zip_url = f"/downloads/{zip_name}"

    if exe_file is not None:
        if not exe_file.filename or not exe_file.filename.lower().endswith(".exe"):
            raise HTTPException(status_code=400, detail="EXE 包必须是 .exe 格式")
        exe_name = f"work_diary_app_v{version}.exe"
        exe_size = _save_upload(exe_file, _DOWNLOAD_DIR / exe_name, MAX_FILE_SIZE, {".exe"})
        exe_url = f"/downloads/{exe_name}"

    with get_conn() as conn:
        with conn.cursor() as cur:
            # 同一版本号已存在 → 更新旧记录（保留 is_active 状态，只覆盖本次上传的文件）
            cur.execute(
                "SELECT id, is_active, download_url, exe_url FROM app_versions WHERE version = %s ORDER BY id DESC LIMIT 1",
                (version,),
            )
            existing = cur.fetchone()
            if existing:
                old_zip_url = existing["download_url"]
                old_exe_url = existing["exe_url"]
                # 本次未重新上传的包沿用旧文件
                if zip_url is None and old_zip_url:
                    zip_url, zip_size = old_zip_url, _path_size(_DOWNLOAD_DIR / old_zip_url[len("/downloads/"):])
                if exe_url is None and old_exe_url:
                    exe_url, exe_size = old_exe_url, _path_size(_DOWNLOAD_DIR / old_exe_url[len("/downloads/"):])
                cur.execute(
                    "UPDATE app_versions SET download_url = %s, exe_url = %s, release_notes = %s, "
                    "force_update = %s, file_size = %s, exe_file_size = %s WHERE id = %s",
                    (
                        zip_url or "", exe_url or "",
                        release_notes.strip(), 1 if force_update else 0,
                        zip_size, exe_size,
                        existing["id"],
                    ),
                )
                new_id = existing["id"]
                replaced = True
            else:
                cur.execute(
                    "INSERT INTO app_versions (version, download_url, exe_url, release_notes, force_update, is_active, file_size, exe_file_size) "
                    "VALUES (%s, %s, %s, %s, %s, 0, %s, %s)",
                    (
                        version, zip_url or "", exe_url or "",
                        release_notes.strip(), 1 if force_update else 0,
                        zip_size, exe_size,
                    ),
                )
                new_id = cur.lastrowid
                replaced = False
        conn.commit()

    return JSONResponse({
        "id": new_id,
        "version": version,
        "zip_url": zip_url,
        "exe_url": exe_url,
        "file_size": zip_size,
        "replaced": replaced,
    })


def _path_size(p: Path):
    try:
        return p.stat().st_size if p.exists() else None
    except OSError:
        return None


def _delete_download_file(url_path: str | None):
    """根据下载 URL 删除对应文件，忽略不存在的情况。"""
    if not url_path:
        return
    if url_path.startswith("/downloads/"):
        fname = url_path[len("/downloads/"):]
        fpath = _DOWNLOAD_DIR / fname
        try:
            if fpath.exists():
                fpath.unlink()
        except OSError:
            pass


@router.post("/admin/api/versions/{version_id}/activate")
def admin_activate_version(version_id: int, _: None = Depends(require_admin)):
    """管理后台：将某个 Windows 版本设为当前生效版本（其他版本自动失效）。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM app_versions WHERE id = %s", (version_id,))
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail="版本不存在")
            cur.execute("UPDATE app_versions SET is_active = 0")
            cur.execute("UPDATE app_versions SET is_active = 1 WHERE id = %s", (version_id,))
        conn.commit()
    return JSONResponse({"ok": True, "activated_id": version_id})


@router.delete("/admin/api/versions/{version_id}")
def admin_delete_version(version_id: int, _: None = Depends(require_admin)):
    """管理后台：删除 Windows 版本记录（同时删除服务器上的 ZIP / EXE 文件）。

    允许删除当前生效版本（删除后该版本即失效，客户端检测不到该更新）。
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT download_url, exe_url FROM app_versions WHERE id = %s", (version_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="版本不存在")
            _delete_download_file(row["download_url"])
            _delete_download_file(row["exe_url"])
            cur.execute("DELETE FROM app_versions WHERE id = %s", (version_id,))
        conn.commit()
    return JSONResponse({"ok": True})


# ======================================================================
# 微信小程序版本管理（无安装包，仅版本号 + 更新说明）
# ======================================================================

@router.get("/admin/api/versions/miniprogram")
def admin_list_miniprogram_versions(_: None = Depends(require_admin)):
    """管理后台：获取微信小程序所有版本记录。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, version, release_notes, is_active, created_at "
                "FROM app_versions_miniprogram ORDER BY id DESC LIMIT 50"
            )
            rows = cur.fetchall()
    return JSONResponse({
        "versions": [
            {
                "id": r["id"],
                "version": r["version"],
                "release_notes": r["release_notes"] or "",
                "is_active": bool(r["is_active"]),
                "created_at": _fmt(r["created_at"]),
            }
            for r in rows
        ]
    })


@router.post("/admin/api/versions/miniprogram")
def admin_create_miniprogram_version(
    version: str = Form(...),
    release_notes: str = Form(""),
    _: None = Depends(require_admin),
):
    """管理后台：新增/更新一条小程序版本记录（同版本号覆盖说明）。"""
    version = version.strip()
    if not VERSION_PATTERN.match(version):
        raise HTTPException(status_code=400, detail="版本号格式不正确，应为 x.y.z（如 1.1.0）")
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM app_versions_miniprogram WHERE version = %s ORDER BY id DESC LIMIT 1", (version,))
            existing = cur.fetchone()
            if existing:
                cur.execute(
                    "UPDATE app_versions_miniprogram SET release_notes = %s WHERE id = %s",
                    (release_notes.strip(), existing["id"]),
                )
                new_id = existing["id"]
                replaced = True
            else:
                cur.execute(
                    "INSERT INTO app_versions_miniprogram (version, release_notes, is_active) VALUES (%s, %s, 0)",
                    (version, release_notes.strip()),
                )
                new_id = cur.lastrowid
                replaced = False
        conn.commit()
    return JSONResponse({"id": new_id, "version": version, "replaced": replaced})


@router.post("/admin/api/versions/miniprogram/{version_id}/activate")
def admin_activate_miniprogram_version(version_id: int, _: None = Depends(require_admin)):
    """管理后台：将某条小程序版本设为当前生效版本。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM app_versions_miniprogram WHERE id = %s", (version_id,))
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail="版本不存在")
            cur.execute("UPDATE app_versions_miniprogram SET is_active = 0")
            cur.execute("UPDATE app_versions_miniprogram SET is_active = 1 WHERE id = %s", (version_id,))
        conn.commit()
    return JSONResponse({"ok": True, "activated_id": version_id})


@router.delete("/admin/api/versions/miniprogram/{version_id}")
def admin_delete_miniprogram_version(version_id: int, _: None = Depends(require_admin)):
    """管理后台：删除小程序版本记录。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM app_versions_miniprogram WHERE id = %s", (version_id,))
        conn.commit()
    return JSONResponse({"ok": True})


# ======================================================================
# 站点设置：入群二维码
# ======================================================================

@router.get("/api/site/qrcode")
def site_qrcode():
    """公开：获取入群二维码图片地址与上次更新时间（未设置时返回 url=null）。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            qr = _get_site_value(cur, _QR_KEY)
            ts = _get_site_updated(cur, _QR_KEY)
    return JSONResponse({"url": f"/static/{qr}" if qr else None, "updated_at": ts})


@router.get("/api/site/qrcode/author")
def site_author_qrcode():
    """公开：获取作者微信二维码与微信号（未设置时 url=null、账号取默认 php100）。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            qr = _get_site_value(cur, _AUTHOR_KEY)
            ts = _get_site_updated(cur, _AUTHOR_KEY)
            account = _get_site_value(cur, _AUTHOR_ACCOUNT_KEY) or DEFAULT_AUTHOR_ACCOUNT
    return JSONResponse({"url": f"/static/{qr}" if qr else None, "updated_at": ts, "account": account})


@router.post("/admin/api/site/qrcode/author")
async def admin_upload_author_qrcode(file: UploadFile = File(...), _: None = Depends(require_admin)):
    """管理后台：上传作者微信二维码图片（自动替换旧图）。"""
    if not file.filename:
        raise HTTPException(status_code=400, detail="请选择二维码图片")
    ext = Path(file.filename).suffix.lower()
    if ext not in IMAGE_EXTS:
        raise HTTPException(status_code=400, detail="仅支持 png / jpg / jpeg / webp 格式")
    qr_name = f"author_qrcode{ext}"
    save_path = _UPLOAD_DIR / qr_name
    _save_upload(file, save_path, MAX_IMAGE_SIZE, IMAGE_EXTS)

    with get_conn() as conn:
        with conn.cursor() as cur:
            old = _get_site_value(cur, _AUTHOR_KEY)
            if old and old != f"uploads/{qr_name}":
                try:
                    old_path = _STATIC_DIR / old
                    if old_path.exists():
                        old_path.unlink()
                except OSError:
                    pass
            _set_site_value(cur, _AUTHOR_KEY, f"uploads/{qr_name}")
        conn.commit()

    return JSONResponse({"ok": True, "url": f"/static/uploads/{qr_name}"})


@router.delete("/admin/api/site/qrcode/author")
def admin_clear_author_qrcode(_: None = Depends(require_admin)):
    """管理后台：清除作者微信二维码（删除图片与设置）。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            old = _get_site_value(cur, _AUTHOR_KEY)
            if old:
                try:
                    old_path = _STATIC_DIR / old
                    if old_path.exists():
                        old_path.unlink()
                except OSError:
                    pass
            cur.execute("DELETE FROM site_settings WHERE site_key = %s", (_AUTHOR_KEY,))
        conn.commit()
    return JSONResponse({"ok": True})


@router.post("/admin/api/site/author-account")
def admin_set_author_account(account: str = Form(...), _: None = Depends(require_admin)):
    """管理后台：设置官网展示的作者微信号。"""
    account = account.strip()
    if not account:
        raise HTTPException(status_code=400, detail="微信号不能为空")
    if len(account) > 50:
        raise HTTPException(status_code=400, detail="微信号过长")
    with get_conn() as conn:
        with conn.cursor() as cur:
            _set_site_value(cur, _AUTHOR_ACCOUNT_KEY, account)
        conn.commit()
    return JSONResponse({"ok": True, "account": account})


@router.post("/admin/api/site/qrcode")
async def admin_upload_qrcode(file: UploadFile = File(...), _: None = Depends(require_admin)):
    """管理后台：上传入群二维码图片（自动替换旧图）。"""
    if not file.filename:
        raise HTTPException(status_code=400, detail="请选择二维码图片")
    ext = Path(file.filename).suffix.lower()
    if ext not in IMAGE_EXTS:
        raise HTTPException(status_code=400, detail="仅支持 png / jpg / jpeg / webp 格式")
    qr_name = f"group_qrcode{ext}"
    save_path = _UPLOAD_DIR / qr_name
    _save_upload(file, save_path, MAX_IMAGE_SIZE, IMAGE_EXTS)

    with get_conn() as conn:
        with conn.cursor() as cur:
            old = _get_site_value(cur, _QR_KEY)
            # 删除旧图（扩展名可能不同）
            if old and old != f"uploads/{qr_name}":
                try:
                    old_path = _STATIC_DIR / old
                    if old_path.exists():
                        old_path.unlink()
                except OSError:
                    pass
            _set_site_value(cur, _QR_KEY, f"uploads/{qr_name}")
        conn.commit()

    return JSONResponse({"ok": True, "url": f"/static/uploads/{qr_name}"})


@router.delete("/admin/api/site/qrcode")
def admin_clear_qrcode(_: None = Depends(require_admin)):
    """管理后台：清除入群二维码（删除图片与设置）。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            old = _get_site_value(cur, _QR_KEY)
            if old:
                try:
                    old_path = _STATIC_DIR / old
                    if old_path.exists():
                        old_path.unlink()
                except OSError:
                    pass
            cur.execute("DELETE FROM site_settings WHERE site_key = %s", (_QR_KEY,))
        conn.commit()
    return JSONResponse({"ok": True})

"""Pydantic 请求/响应模型。"""
from datetime import datetime

from pydantic import BaseModel, Field


# ---------- 认证 ----------
class SendCodeRequest(BaseModel):
    email: str


class VerifyCodeRequest(BaseModel):
    email: str
    code: str


class RegisterRequest(BaseModel):
    email: str
    code: str
    password: str = Field(min_length=6, max_length=72)


class LoginRequest(BaseModel):
    email: str
    password: str


class ResetPasswordRequest(BaseModel):
    email: str
    code: str
    password: str = Field(min_length=6, max_length=72)


class UserOut(BaseModel):
    id: int
    email: str
    created_at: str


class AuthResponse(BaseModel):
    token: str
    user: UserOut


# ---------- 任务 ----------
class TaskIn(BaseModel):
    """同步时客户端上报的任务（字段与客户端 Task.toMap 对应）。"""

    id: int | None = None          # 客户端本地 id
    remote_id: int | None = None   # 云端 id
    title: str
    status: int = Field(ge=0, le=2)
    urgency: int = Field(ge=0, le=2)
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None
    plan_start_at: datetime | None = None
    due_at: datetime | None = None
    sort_order: int = 0
    task_type: int = Field(default=1, ge=0, le=1)
    repeat_type: int = Field(default=0, ge=0, le=3)  # 0正常 1日 2周 3月
    repeat_week_days: str | None = None               # 周任务：逗号分隔周几，如 "1,3,5"
    repeat_month_day: int | None = Field(default=None, ge=1, le=31)
    repeat_group_id: str | None = None                # 循环任务族ID
    instance_date: str | None = None                  # 实例所属日期 YYYY-MM-DD
    updated_at: datetime | None = None


class TaskOut(BaseModel):
    id: int | None                 # 客户端本地 id（local_id）
    remote_id: int                 # 云端 id
    title: str
    status: int
    urgency: int
    created_at: str
    started_at: str | None
    completed_at: str | None
    plan_start_at: str | None
    due_at: str | None
    sort_order: int
    task_type: int
    repeat_type: int = 0
    repeat_week_days: str | None = None
    repeat_month_day: int | None = None
    repeat_group_id: str | None = None
    instance_date: str | None = None
    updated_at: str


class DeletionItem(BaseModel):
    local_id: int
    # 允许为空：客户端"新建后未同步即删除"时拿不到云端 id。服务端跳过即可，
    # 否则整批同步会因 422 失败，而客户端会一直重试同一条记录（同步永久卡死）。
    remote_id: int | None = None
    deleted_at: datetime


class RepeatGroupIn(BaseModel):
    """同步时客户端上报的循环任务规则（日/周/月任务）。

    `plan_start_at` / `due_at` 只用时分秒，日期部分无意义；保留 datetime 是为了
    和任务字段的时间格式统一（客户端传 UTC ISO，服务端转 naive UTC 存储）。
    """

    group_id: str
    title: str = ""
    urgency: int = Field(default=0, ge=0, le=2)
    task_type: int = Field(default=1, ge=0, le=1)
    repeat_type: int = Field(default=1, ge=0, le=3)  # 0 表示无效规则，服务端跳过
    repeat_week_days: str | None = None
    repeat_month_day: int | None = Field(default=None, ge=1, le=31)
    plan_start_at: datetime | None = None
    due_at: datetime | None = None
    stopped: bool = False
    deleted: bool = False
    updated_at: datetime | None = None


class RepeatGroupOut(BaseModel):
    """下发给客户端的循环规则（时间统一转成带 Z 的 ISO 字符串）。"""

    group_id: str
    title: str
    urgency: int
    task_type: int
    repeat_type: int
    repeat_week_days: str | None = None
    repeat_month_day: int | None = None
    plan_start_at: str | None = None
    due_at: str | None = None
    stopped: bool = False
    deleted: bool = False
    updated_at: str


class SyncRequest(BaseModel):
    tasks: list[TaskIn] = []
    deletions: list[DeletionItem] = []
    # 本机全部循环规则（数量很小，每轮全量上报，服务端按 updated_at 做 LWW）
    repeat_groups: list[RepeatGroupIn] = []


class SkipItem(BaseModel):
    """循环任务里被用户删掉的某一期（跨设备共享，避免互相补生成）。"""

    repeat_group_id: str
    instance_date: str  # YYYY-MM-DD


class SyncResponse(BaseModel):
    tasks: list[TaskOut]
    # 本用户所有被删除的循环实例；客户端写进跳过账本，补生成时跳过这些日期
    skips: list[SkipItem] = []
    # 本用户全部循环规则（含 stopped 状态）；客户端按 updated_at 合并
    repeat_groups: list[RepeatGroupOut] = []


# 直连式任务 CRUD（与同步接口并存）
class TaskCreate(BaseModel):
    title: str
    status: int = Field(default=0, ge=0, le=2)
    urgency: int = Field(default=0, ge=0, le=2)
    created_at: datetime | None = None
    plan_start_at: datetime | None = None
    due_at: datetime | None = None
    sort_order: int = 0
    task_type: int = Field(default=1, ge=0, le=1)
    repeat_type: int = Field(default=0, ge=0, le=3)
    repeat_week_days: str | None = None
    repeat_month_day: int | None = Field(default=None, ge=1, le=31)
    repeat_group_id: str | None = None
    instance_date: str | None = None


class TaskUpdate(BaseModel):
    title: str | None = None
    status: int | None = Field(default=None, ge=0, le=2)
    urgency: int | None = Field(default=None, ge=0, le=2)
    started_at: datetime | None = None
    completed_at: datetime | None = None
    plan_start_at: datetime | None = None
    due_at: datetime | None = None
    sort_order: int | None = None
    task_type: int | None = Field(default=None, ge=0, le=1)
    repeat_type: int | None = Field(default=None, ge=0, le=3)
    repeat_week_days: str | None = None
    repeat_month_day: int | None = Field(default=None, ge=1, le=31)
    repeat_group_id: str | None = None
    instance_date: str | None = None
    updated_at: datetime | None = None


# ---------- 备忘 ----------
class MemoIn(BaseModel):
    """同步时客户端上报的备忘（字段与客户端 Memo.toMap 对应）。"""

    id: int | None = None          # 客户端本地 id
    remote_id: int | None = None   # 云端 id
    content: str
    created_at: datetime
    updated_at: datetime | None = None


class MemoOut(BaseModel):
    id: int | None                 # 客户端本地 id（local_id）
    remote_id: int                 # 云端 id
    content: str
    created_at: str
    updated_at: str


class MemoDeletionItem(BaseModel):
    local_id: int
    remote_id: int
    deleted_at: datetime


class MemoSyncRequest(BaseModel):
    memos: list[MemoIn] = []
    deletions: list[MemoDeletionItem] = []


class MemoSyncResponse(BaseModel):
    memos: list[MemoOut]
    # 云端已软删除的备忘 remote_id 列表：客户端据此删除本地对应条目
    deleted_ids: list[int] = []


# ---------- 附件（任务/备忘的文件，服务器只做一次性中转）----------
class AttachmentIn(BaseModel):
    """同步时客户端上报的附件元数据（不含文件内容）。"""

    uid: str = Field(min_length=8, max_length=64)
    parent_kind: str = Field(pattern="^(task|memo)$")
    parent_remote_id: int | None = None
    owner_device_id: str = Field(default="", max_length=64)
    owner_device_name: str = Field(default="", max_length=128)
    file_name: str = Field(min_length=1, max_length=255)
    file_size: int = Field(ge=1)
    sha256: str = Field(pattern=r"^[0-9a-fA-F]{64}$")
    mime: str = Field(default="", max_length=128)
    is_screenshot: bool = False
    orphaned: bool = False
    created_at: datetime
    updated_at: datetime | None = None


class AttachmentDeletionItem(BaseModel):
    uid: str
    deleted_at: datetime


class AttachmentSyncRequest(BaseModel):
    attachments: list[AttachmentIn] = []
    deletions: list[AttachmentDeletionItem] = []


class AttachmentOut(BaseModel):
    uid: str
    parent_kind: str
    parent_remote_id: int | None
    owner_device_id: str
    owner_device_name: str
    file_name: str
    file_size: int
    sha256: str
    mime: str
    is_screenshot: bool
    orphaned: bool
    # none=服务器上没有文件；ready=正在中转等下载；taken=已取走删除
    blob_state: str
    created_at: str
    updated_at: str


class AttachmentSyncResponse(BaseModel):
    attachments: list[AttachmentOut]
    deleted_uids: list[str] = []
    # 超出"每个任务/备忘最多 5 个"而被拒绝入库的新附件：客户端据此提示，
    # 不能静默丢弃，否则用户以为已经保存了。
    rejected_uids: list[str] = []


class AttachmentDeviceIn(BaseModel):
    device_id: str = Field(min_length=1, max_length=64)
    device_name: str = Field(default="", max_length=128)


class AttachmentRequestOut(BaseModel):
    # requested=已通知其它设备上传；ready=服务器已有文件可直接下载；
    # done=本机此前已经取过这份文件
    state: str
    sources: int = 0
    message: str = ""


class AttachmentUploadInitOut(BaseModel):
    # ready=服务器已有完整文件（无需再传）；upload=从 next_offset 继续传
    state: str
    next_offset: int = 0
    chunk_size: int = 0
    file_size: int = 0
    sha256: str = ""


class AttachmentAckOut(BaseModel):
    remaining: int
    blob_deleted: bool


class AttachmentStateOut(BaseModel):
    blob_state: str
    transfers: list[dict] = []


# ---------- 管理后台 ----------
class AdminLogin(BaseModel):
    username: str
    password: str


# ---------- AI 截图识别 ----------
class RecognizeRequest(BaseModel):
    """截图识别请求：image 为 base64 编码的图片（不含 data:image/... 前缀）。"""
    image: str


class RecognizedTask(BaseModel):
    """AI 识别出的单条任务。"""
    title: str
    urgency: str = "一般"          # 一般 / 重要 / 紧急
    plan_start_at: str | None = None  # YYYY-MM-DD，无则 null
    due_at: str | None = None         # YYYY-MM-DD，无则 null


class RecognizeResponse(BaseModel):
    tasks: list[RecognizedTask] = []


# ---------- AI 工作日志总结 ----------
class SummarizeTask(BaseModel):
    """客户端上报的单条任务（本地过滤后上传，服务端不查库）。"""
    title: str
    status: int = Field(ge=0, le=2)        # 0计划中 1执行中 2已完成
    urgency: int = Field(ge=0, le=2)       # 0一般 1紧急 2重要
    task_type: int = Field(default=1, ge=0, le=1)  # 0个人 1工作
    created_at: datetime | None = None
    started_at: datetime | None = None
    completed_at: datetime | None = None


class SummarizeRequest(BaseModel):
    """AI 工作日志总结请求。

    range: day=当日总结 / week=期间总结
    scope: all=全部 / work=仅工作 / personal=仅个人
    start_date / end_date: YYYY-MM-DD，闭区间
    tasks: 客户端按范围过滤后的任务列表（可为空）
    """
    range: str = Field(pattern="^(day|week)$")
    scope: str = Field(pattern="^(all|work|personal)$")
    start_date: str
    end_date: str
    tasks: list[SummarizeTask] = []


class SummarizeResponse(BaseModel):
    summary: str


class ExportDocxRequest(BaseModel):
    """把 AI 总结的 Markdown 导出为 Word(.docx) 文件。"""
    markdown: str
    filename: str = "工作日志"

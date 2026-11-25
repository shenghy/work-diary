# 极简工作日记 · 后端 API 服务 + 管理后台

一个独立的 FastAPI 服务端项目，负责：

- **登录 / 注册 / 找回密码**（邮箱 + 验证码，密码服务端 PBKDF2 加盐哈希）
- **发送邮箱验证码**（163 SMTP，验证码入库、10 分钟有效、60 秒冷却、限次）
- **任务增删改查 + 云端同步**（与客户端逐条合并，`updated_at` 最后写入胜出 LWW）
- **管理后台**（`/admin`）：查看注册总人数、今日/昨日新增、14 天注册趋势、任务统计、最近注册用户

客户端（Flutter）不再直连 MySQL，只保存一个 API 地址（见 `work_diary_app/lib/services/api_config.dart`）。

---

## 一、目录结构

```
work_diary_server/
├── app/
│   ├── main.py                # FastAPI 入口
│   ├── config.py              # 配置（.env）
│   ├── database.py            # MySQL 连接 + 自动建表/迁移
│   ├── security.py            # 密码哈希 / JWT
│   ├── emailer.py             # 163 SMTP 发信
│   ├── utils.py               # 时间/校验工具
│   ├── models.py              # 请求/响应模型
│   ├── admin_login.html       # 后台登录页
│   ├── admin_dashboard.html   # 后台数据看板
│   └── routers/
│       ├── auth.py            # /api/auth/*  验证码、注册、登录、找回
│       ├── tasks.py           # /api/tasks/* 增删改查 + 同步
│       ├── admin.py           # /admin/*     后台登录、统计
│       └── deps.py            # 鉴权依赖
├── requirements.txt
├── .env.example               # 配置模板
├── .env                       # 实际配置（已按你的服务器信息填好，注意保密）
├── start.ps1                  # Windows 启动脚本
├── start.sh                   # Linux 启动脚本（后台运行，写 .server.pid）
├── stop.sh                    # Linux 停止脚本（与 start.sh 配套）
└── Dockerfile                 # 可选：Docker 部署
```

## 二、接口一览

| 方法 | 路径 | 说明 | 鉴权 |
|------|------|------|------|
| POST | `/api/auth/send-code` | 发送邮箱验证码 | 否 |
| POST | `/api/auth/verify-code` | 校验验证码（不消费） | 否 |
| POST | `/api/auth/register` | 注册（服务端校验验证码） | 否 |
| POST | `/api/auth/login` | 登录，返回 token | 否 |
| POST | `/api/auth/reset-password` | 找回密码（校验验证码） | 否 |
| GET  | `/api/auth/email-status?email=` | 查询邮箱是否已注册 | 否 |
| GET  | `/api/auth/me` | 当前用户信息 | Bearer |
| POST | `/api/tasks/sync` | 全量同步（LWW 合并） | Bearer |
| GET  | `/api/tasks` | 任务列表 | Bearer |
| POST | `/api/tasks` | 创建任务 | Bearer |
| PATCH| `/api/tasks/{id}` | 修改任务 | Bearer |
| DELETE | `/api/tasks/{id}` | 删除任务（软删除） | Bearer |
| GET  | `/api/stats/me?from=&to=&granularity=&tz=` | 个人数据看板聚合（限流 30 次/分钟/IP，不占 AI 额度） | Bearer |
| GET  | `/admin` | 管理后台看板 | Cookie |
| GET  | `/admin/api/stats` | 后台统计数据 JSON | Cookie |
| GET  | `/api/health` | 健康检查 | 否 |

接口文档（Swagger）：`http://<服务器>:8000/docs`

### 循环任务（日/周/月）相关字段

`/api/tasks/sync` 的请求与响应各增加了 `repeat_groups` 一段，规则按 `updated_at` 做 LWW：

```jsonc
// 请求
{
  "tasks": [...],
  "deletions": [...],
  "repeat_groups": [
    {
      "group_id": "18f3c0a2d1b4e5f6",   // 客户端生成的循环族 ID
      "title": "每天走路 1 小时",
      "urgency": 0, "task_type": 1,
      "repeat_type": 1,                  // 1日 2周 3月
      "repeat_week_days": "1,3,5",       // 周任务
      "repeat_month_day": null,          // 月任务
      "plan_start_at": "2026-11-02T01:00:00.000Z",
      "due_at": null,
      "stopped": false,                  // true = 已停止，不再生成新一期
      "updated_at": "2026-11-02T01:00:00.000Z"
    }
  ]
}
// 响应额外包含
{ "tasks": [...], "skips": [...], "repeat_groups": [ ...同上，updated_at 为 ISO 字符串... ] }
```

老客户端不带 `repeat_groups` 不受影响（服务端按空数组处理）；新客户端连到老服务端时，
响应里没有这一段，本地规则会保持"待同步"状态，补生成逻辑仍按旧行为工作。

## 三、部署到服务器

### 方式 1：直接运行（推荐，简单）

```bash
cd work_diary_server

# 1. 创建虚拟环境并安装依赖
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 2. 配置 .env（数据库 / SMTP / 后台账号密码）
cp .env.example .env
#    按注释修改，JWT_SECRET 用下面命令生成随机值：
python -c "import secrets; print(secrets.token_hex(32))"

# 3. 启动
./start.sh            # 后台启动（日志 server.log），停止用 ./stop.sh
#    或手动：uvicorn app.main:app --host 0.0.0.0 --port 8010
```

> 首次启动会自动建表（`users`、`tasks`、`memos`、`email_codes`、`repeat_skips`、`repeat_groups` 等），
> 老库自动补缺失字段/索引，不会动已有数据。**升级后必须重启一次服务**，否则新表不会被创建。

### 方式 2：systemd 常驻（服务器开机自启）

编辑 `/etc/systemd/system/workdiary.service`：

```ini
[Unit]
Description=Work Diary API
After=network.target

[Service]
WorkingDirectory=/opt/work_diary_server
ExecStart=/opt/work_diary_server/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
User=root

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now workdiary
systemctl status workdiary        # 查看状态
journalctl -u workdiary -f        # 查看日志
```

### 方式 3：Docker（可选）

```bash
docker build -t workdiary-server .
docker run -d --name workdiary-server \
  -p 8000:8000 --env-file .env \
  --restart unless-stopped workdiary-server
```

## 四、管理后台使用

1. 浏览器打开 `http://<服务器>:8000/admin`
2. 用 `.env` 里的 `ADMIN_USERNAME` / `ADMIN_PASSWORD` 登录
3. 看板展示：注册总人数、今日/昨日新增、14 天注册趋势图、任务统计、最近注册用户

## 五、安全注意事项（务必看）

- **立即修改 `.env` 里的 `ADMIN_PASSWORD`**，不要把默认占位值留到生产环境
- 服务器公网开放 8000 端口前，建议用 Nginx 反代 + HTTPS（管理后台 Cookie 仅 HttpOnly，如启用 HTTPS 可将 `admin.py` 里 `secure=False` 改为 `True`）
- 数据库账号建议用最小权限账号，不要用 root；`.env` 不要提交到代码仓库
- 密码以 PBKDF2 加盐哈希存储；登录旧版客户端注册的账号（SHA256 老哈希）会自动平滑升级

## 六、与旧版本的关系

- 旧的 `email_server.py`（Flask 验证码服务）已被本服务的 `/api/auth/send-code` 取代，不再需要启动
- 客户端原来直连 MySQL 的 `RemoteSyncService` 已改为全部走本 API，客户端只保存一个 API 地址（`api_config.dart`）

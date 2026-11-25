# 极简工作日记（WorkDiary）

一款极简的任务/工作日记管理工具：本地优先、多端云同步。支持 Windows 桌面端、微信小程序端与自托管服务端。

三种任务状态（计划中 → 执行中 → 已完成）、紧急程度标记、循环任务、备忘卡片、附件跨端中转、热键截图、多端实时同步（WebSocket）。

## 目录结构

| 目录 | 说明 |
|---|---|
| `work_diary_app/` | Flutter 桌面客户端（Windows 为主，兼容 Linux/macOS/Web） |
| `work_diary_server/` | FastAPI + MySQL 服务端（账号、验证码、任务同步、附件中转、管理后台） |
| `work_diary_miniprogram/` | uni-app 微信小程序端 |
| `tools/` | 仓库级辅助脚本（图标构建、密钥扫描等） |

Android 端已退役，不再维护。

## 快速开始

### 服务端

```bash
cd work_diary_server
python -m venv .venv && .venv\Scripts\activate   # Windows
pip install -r requirements.txt
copy .env.example .env    # 按注释填写数据库、SMTP、JWT 密钥等
# 启动（需本机 MySQL，或修改 .env 指向你的数据库）
uvicorn app.main:app --host 0.0.0.0 --port 8010
```

所有密钥、密码、域名都通过 `.env` 配置，代码中不包含任何真实凭据。

### 桌面客户端

```bash
cd work_diary_app
flutter pub get
flutter run -d windows
```

API 地址默认指向内置线上服务；如需连自己的服务器，在可执行文件同目录放置 `api_url.txt`（一行地址）即可，无需重新编译。

### 小程序端

```bash
cd work_diary_miniprogram
npm install
npm run dev:mp-weixin   # 用微信开发者工具打开 dist/dev/mp-weixin
```

## 测试

- 服务端：`work_diary_server/tests/`（pytest）
- 桌面端：`cd work_diary_app && flutter test`
- 小程序：`cd work_diary_miniprogram && npm test`

## 版本与发布

版本号遵循语义化版本（`v1.0.x`），发布记录见 Git 提交历史与 GitHub Releases。

## 开源协议

[MIT](LICENSE)。你可以自由使用、修改、商用，保留版权声明即可。

## 免责声明

本软件按「现状」开源，作者不对因使用本软件或自建服务造成的数据丢失承担责任。

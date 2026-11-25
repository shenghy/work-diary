"""数据库连接与建表。"""
from contextlib import contextmanager

import pymysql

from .config import settings

_TABLES = [
    # users 表：与旧版客户端建表保持一致，username 字段存邮箱
    """
    CREATE TABLE IF NOT EXISTS users (
        id INT AUTO_INCREMENT PRIMARY KEY,
        username VARCHAR(50) NOT NULL UNIQUE,
        password_hash VARCHAR(255) NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # tasks 表
    """
    CREATE TABLE IF NOT EXISTS tasks (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        local_id INT NULL COMMENT '客户端本地ID，用于同步映射',
        title TEXT NOT NULL,
        status TINYINT NOT NULL DEFAULT 0 COMMENT '0计划中 1执行中 2已完成',
        urgency TINYINT NOT NULL DEFAULT 0 COMMENT '0一般 1紧急 2重要',
        created_at DATETIME NOT NULL,
        started_at DATETIME NULL,
        completed_at DATETIME NULL,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        is_deleted TINYINT NOT NULL DEFAULT 0,
        plan_start_at DATETIME NULL COMMENT '计划开始执行时间',
        due_at DATETIME NULL COMMENT '预计交付/完成时间',
        sort_order INT NOT NULL DEFAULT 0 COMMENT '拖拽排序顺序，组内升序',
        task_type TINYINT NOT NULL DEFAULT 1 COMMENT '0个人任务 1工作任务',
        repeat_type TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1日任务 2周任务 3月任务',
        repeat_week_days VARCHAR(32) NULL COMMENT '周任务：逗号分隔周几，如 1,3,5（1=周一）',
        repeat_month_day TINYINT NULL COMMENT '月任务：每月几号（1-31）',
        repeat_group_id VARCHAR(64) NULL COMMENT '循环任务族ID，同族实例共享',
        instance_date DATE NULL COMMENT '实例所属日期（YYYY-MM-DD）',
        INDEX idx_user (user_id),
        INDEX idx_user_local (user_id, local_id),
        INDEX idx_user_plan (user_id, plan_start_at),
        UNIQUE KEY uk_repeat (repeat_group_id, instance_date),
        CONSTRAINT fk_tasks_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # 循环任务「已删除的期」：用户删掉某一期后写一条，所有设备同步后都不再补生成。
    # 独立于 tasks：tasks 的软删除行会占用 uk_repeat 唯一键，导致同一期无法重新落库。
    """
    CREATE TABLE IF NOT EXISTS repeat_skips (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        repeat_group_id VARCHAR(64) NOT NULL COMMENT '循环任务族ID',
        instance_date DATE NOT NULL COMMENT '被删除的实例日期',
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE KEY uk_user_group_date (user_id, repeat_group_id, instance_date),
        INDEX idx_user (user_id),
        CONSTRAINT fk_repeat_skips_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # 循环任务规则表：日/周/月任务的"规则"上云。
    # 作用：换设备后规则不丢（否则引擎只能拿现存实例当模板），
    #       "停止循环"能同步到所有设备，多端改规则按 updated_at 走 LWW。
    """
    CREATE TABLE IF NOT EXISTS repeat_groups (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        group_id VARCHAR(64) NOT NULL COMMENT '客户端生成的循环族ID',
        title TEXT NOT NULL,
        urgency TINYINT NOT NULL DEFAULT 0 COMMENT '0一般 1紧急 2重要',
        task_type TINYINT NOT NULL DEFAULT 1 COMMENT '0个人任务 1工作任务',
        repeat_type TINYINT NOT NULL DEFAULT 1 COMMENT '1日任务 2周任务 3月任务',
        repeat_week_days VARCHAR(32) NULL COMMENT '周任务：逗号分隔周几，如 1,3,5',
        repeat_month_day TINYINT NULL COMMENT '月任务：每月几号（1-31）',
        plan_start_at DATETIME NULL COMMENT '计划开始的时分秒（跨期沿用）',
        due_at DATETIME NULL COMMENT '预计完成的时分秒（跨期沿用）',
        stopped TINYINT NOT NULL DEFAULT 0 COMMENT '1=已停止循环，不再生成新一期',
        deleted TINYINT NOT NULL DEFAULT 0 COMMENT '1=已永久删除（规则+全部期次），终态墓碑',
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE KEY uk_user_group (user_id, group_id),
        INDEX idx_user (user_id),
        CONSTRAINT fk_repeat_groups_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # 邮箱验证码表
    """
    CREATE TABLE IF NOT EXISTS email_codes (
        id BIGINT AUTO_INCREMENT PRIMARY KEY,
        email VARCHAR(191) NOT NULL,
        purpose VARCHAR(20) NOT NULL DEFAULT 'auth',
        code CHAR(6) NOT NULL,
        attempts TINYINT NOT NULL DEFAULT 0,
        expires_at DATETIME NOT NULL,
        created_at DATETIME NOT NULL,
        INDEX idx_email (email, purpose)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # AI 调用记录表：记录每个用户的 AI 截图识别调用次数，用于限流和统计
    """
    CREATE TABLE IF NOT EXISTS ai_usage (
        id BIGINT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        task_count INT NOT NULL DEFAULT 0 COMMENT '本次识别出的任务数量',
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_user_time (user_id, created_at),
        CONSTRAINT fk_ai_usage_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # 应用版本表：管理客户端自动升级版本（Windows：ZIP 免安装包 + EXE 安装包）
    """
    CREATE TABLE IF NOT EXISTS app_versions (
        id INT AUTO_INCREMENT PRIMARY KEY,
        version VARCHAR(20) NOT NULL COMMENT '版本号，如 1.1.0',
        download_url VARCHAR(500) NOT NULL COMMENT 'ZIP免安装包下载地址',
        exe_url VARCHAR(500) NULL COMMENT 'EXE安装包下载地址',
        release_notes TEXT COMMENT '更新说明',
        force_update TINYINT NOT NULL DEFAULT 0 COMMENT '是否强制升级 0否 1是',
        is_active TINYINT NOT NULL DEFAULT 0 COMMENT '是否为当前生效版本 0否 1是',
        file_size BIGINT NULL COMMENT 'ZIP文件大小（字节）',
        exe_file_size BIGINT NULL COMMENT 'EXE文件大小（字节）',
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_active (is_active),
        UNIQUE KEY uk_version (version)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # 微信小程序版本表：小程序无安装包，仅维护版本号 + 更新说明（供官网「小程序版」日志）
    """
    CREATE TABLE IF NOT EXISTS app_versions_miniprogram (
        id INT AUTO_INCREMENT PRIMARY KEY,
        version VARCHAR(20) NOT NULL COMMENT '版本号，如 1.1.0',
        release_notes TEXT COMMENT '更新说明',
        is_active TINYINT NOT NULL DEFAULT 0 COMMENT '是否为当前生效版本 0否 1是',
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_active (is_active),
        UNIQUE KEY uk_version (version)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # memos 表：备忘录（纯记录，不参与任务状态/提醒；IF NOT EXISTS 不影响老库）
    """
    CREATE TABLE IF NOT EXISTS memos (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        local_id INT NULL COMMENT '客户端本地ID，用于同步映射',
        content TEXT NOT NULL,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        is_deleted TINYINT NOT NULL DEFAULT 0,
        INDEX idx_user (user_id),
        INDEX idx_user_local (user_id, local_id),
        CONSTRAINT fk_memos_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # 站点设置表：官网展示配置（入群二维码等）
    """
    CREATE TABLE IF NOT EXISTS site_settings (
        site_key VARCHAR(50) PRIMARY KEY,
        site_value TEXT NULL,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # 附件元数据表：文件本身不在数据库里，也不长期存服务器。
    # uid 由创建附件的客户端生成（UUID），跨设备靠它对齐同一份附件；
    # parent_remote_id 指向 tasks.id / memos.id，客户端各自映射回本机 local_id。
    # blob_state 只描述"中转状态"：none=服务器上没有文件，ready=正在暂存等下载，
    # taken=已被取走删除。
    """
    CREATE TABLE IF NOT EXISTS attachments (
        id BIGINT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        uid VARCHAR(64) NOT NULL COMMENT '客户端生成的附件UUID，跨设备对齐用',
        parent_kind VARCHAR(10) NOT NULL DEFAULT 'task' COMMENT 'task / memo',
        parent_remote_id INT NULL COMMENT '所属任务/备忘的云端ID；游离附件保留原值',
        owner_device_id VARCHAR(64) NOT NULL COMMENT '创建该附件的设备ID',
        owner_device_name VARCHAR(128) NOT NULL DEFAULT '' COMMENT '创建设备的主机名，用于"文件在 XXX"',
        file_name VARCHAR(255) NOT NULL,
        file_size BIGINT NOT NULL,
        sha256 CHAR(64) NOT NULL COMMENT '内容哈希，下载后校验',
        mime VARCHAR(128) NOT NULL DEFAULT '',
        is_screenshot TINYINT NOT NULL DEFAULT 0 COMMENT '1=截图生成的附件（删任务时连带删图）',
        orphaned TINYINT NOT NULL DEFAULT 0 COMMENT '1=所属任务/备忘已删除，仅保留记录',
        blob_state VARCHAR(10) NOT NULL DEFAULT 'none' COMMENT 'none / ready / taken',
        blob_expires_at DATETIME NULL COMMENT '中转文件过期时间（超时未取走则删）',
        is_deleted TINYINT NOT NULL DEFAULT 0,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        UNIQUE KEY uk_user_uid (user_id, uid),
        INDEX idx_user_parent (user_id, parent_kind, parent_remote_id),
        INDEX idx_blob_expiry (blob_state, blob_expires_at),
        CONSTRAINT fk_attachments_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
    # 附件拉取请求表：一行 = 一台设备请求过一次中转。
    # 删除条件靠它判断：所有请求方都 ack 下载完，服务器立刻删文件；
    # 没人确认的按 expires_at 兜底清理。
    """
    CREATE TABLE IF NOT EXISTS attachment_transfers (
        id BIGINT AUTO_INCREMENT PRIMARY KEY,
        user_id INT NOT NULL,
        attachment_uid VARCHAR(64) NOT NULL,
        requester_device_id VARCHAR(64) NOT NULL,
        requester_device_name VARCHAR(128) NOT NULL DEFAULT '',
        status VARCHAR(16) NOT NULL DEFAULT 'pending' COMMENT 'pending / downloaded / expired',
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL,
        expires_at DATETIME NOT NULL,
        UNIQUE KEY uk_transfer (user_id, attachment_uid, requester_device_id),
        INDEX idx_uid_status (attachment_uid, status),
        INDEX idx_expiry (status, expires_at),
        CONSTRAINT fk_transfers_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """,
]


@contextmanager
def get_conn():
    """每次请求一个短连接，用完后关闭。"""
    conn = pymysql.connect(
        host=settings.db_host,
        port=settings.db_port,
        user=settings.db_user,
        password=settings.db_password,
        database=settings.db_name,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=10,
        init_command="SET time_zone = '+00:00'",
        autocommit=False,
    )
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def transaction(conn):
    """显式事务：成功提交、失败回滚。"""
    try:
        yield
        conn.commit()
    except BaseException:
        conn.rollback()
        raise


def init_db() -> None:
    """建表（幂等）+ 老库字段迁移。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            for ddl in _TABLES:
                cur.execute(ddl)
            conn.commit()

            # 老库 users 表可能没有 last_login_at（管理后台展示最近登录用）
            cur.execute(
                "SELECT COUNT(*) AS n FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'users' "
                "AND COLUMN_NAME = 'last_login_at'",
                (settings.db_name,),
            )
            if cur.fetchone()["n"] == 0:
                cur.execute(
                    "ALTER TABLE users ADD COLUMN last_login_at DATETIME NULL"
                )
                conn.commit()

            # 老库 tasks 表迁移：计划开始 / 预计完成时间
            for col, comment in (
                ("plan_start_at", "计划开始执行时间"),
                ("due_at", "预计交付/完成时间"),
            ):
                cur.execute(
                    "SELECT COUNT(*) AS n FROM information_schema.COLUMNS "
                    "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'tasks' "
                    "AND COLUMN_NAME = %s",
                    (settings.db_name, col),
                )
                if cur.fetchone()["n"] == 0:
                    cur.execute(
                        f"ALTER TABLE tasks ADD COLUMN {col} DATETIME NULL COMMENT %s",
                        (comment,),
                    )
                    conn.commit()

            # 老库 tasks 表迁移：拖拽排序顺序
            cur.execute(
                "SELECT COUNT(*) AS n FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'tasks' "
                "AND COLUMN_NAME = 'sort_order'",
                (settings.db_name,),
            )
            if cur.fetchone()["n"] == 0:
                cur.execute(
                    "ALTER TABLE tasks ADD COLUMN sort_order INT NOT NULL DEFAULT 0 COMMENT '拖拽排序顺序，组内升序'"
                )
                conn.commit()

            # 老库 tasks 表迁移：任务类型（个人/工作）
            cur.execute(
                "SELECT COUNT(*) AS n FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'tasks' "
                "AND COLUMN_NAME = 'task_type'",
                (settings.db_name,),
            )
            if cur.fetchone()["n"] == 0:
                cur.execute(
                    "ALTER TABLE tasks ADD COLUMN task_type TINYINT NOT NULL DEFAULT 1 COMMENT '0个人任务 1工作任务'"
                )
                conn.commit()

            # 老库 tasks 表迁移：循环任务字段（日/周/月任务）
            repeat_columns = (
                ("repeat_type", "ALTER TABLE tasks ADD COLUMN repeat_type TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1日任务 2周任务 3月任务'"),
                ("repeat_week_days", "ALTER TABLE tasks ADD COLUMN repeat_week_days VARCHAR(32) NULL COMMENT '周任务：逗号分隔周几，如 1,3,5（1=周一）'"),
                ("repeat_month_day", "ALTER TABLE tasks ADD COLUMN repeat_month_day TINYINT NULL COMMENT '月任务：每月几号（1-31）'"),
                ("repeat_group_id", "ALTER TABLE tasks ADD COLUMN repeat_group_id VARCHAR(64) NULL COMMENT '循环任务族ID，同族实例共享'"),
                ("instance_date", "ALTER TABLE tasks ADD COLUMN instance_date DATE NULL COMMENT '实例所属日期（YYYY-MM-DD）'"),
            )
            for col, sql in repeat_columns:
                cur.execute(
                    "SELECT COUNT(*) AS n FROM information_schema.COLUMNS "
                    "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'tasks' "
                    "AND COLUMN_NAME = %s",
                    (settings.db_name, col),
                )
                if cur.fetchone()["n"] == 0:
                    cur.execute(sql)
                    conn.commit()

            # 老库 repeat_groups 迁移：永久删除墓碑（规则 + 全部期次，终态）
            cur.execute(
                "SELECT COUNT(*) AS n FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'repeat_groups' "
                "AND COLUMN_NAME = 'deleted'",
                (settings.db_name,),
            )
            if cur.fetchone()["n"] == 0:
                cur.execute(
                    "ALTER TABLE repeat_groups ADD COLUMN deleted TINYINT NOT NULL DEFAULT 0 "
                    "COMMENT '1=已永久删除（规则+全部期次），终态墓碑'"
                )
                conn.commit()

            # 老库 tasks 表迁移：循环任务实例唯一索引（幂等，多端不重复生成）
            cur.execute(
                "SELECT COUNT(*) AS n FROM information_schema.STATISTICS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'tasks' "
                "AND INDEX_NAME = 'uk_repeat'",
                (settings.db_name,),
            )
            if cur.fetchone()["n"] == 0:
                cur.execute(
                    "ALTER TABLE tasks ADD UNIQUE KEY uk_repeat (repeat_group_id, instance_date)"
                )
                conn.commit()

            # 老库 ai_usage 表迁移：调用类型（ocr 截图识别 / summarize 总结），默认 ocr
            cur.execute(
                "SELECT COUNT(*) AS n FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'ai_usage' "
                "AND COLUMN_NAME = 'kind'",
                (settings.db_name,),
            )
            if cur.fetchone()["n"] == 0:
                cur.execute(
                    "ALTER TABLE ai_usage ADD COLUMN kind VARCHAR(20) NOT NULL DEFAULT 'ocr' "
                    "COMMENT '调用类型：ocr截图识别 / summarize总结'"
                )
                conn.commit()
            # 老库 app_versions 迁移：版本号唯一约束（先清理重复版本号，保留最新一条）
            cur.execute(
                "SELECT COUNT(*) AS n FROM information_schema.STATISTICS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'app_versions' "
                "AND INDEX_NAME = 'uk_version'",
                (settings.db_name,),
            )
            if cur.fetchone()["n"] == 0:
                cur.execute(
                    "DELETE v1 FROM app_versions v1 INNER JOIN app_versions v2 "
                    "ON v1.version = v2.version AND v1.id < v2.id"
                )
                cur.execute(
                    "ALTER TABLE app_versions ADD UNIQUE KEY uk_version (version)"
                )
                conn.commit()

            # 老库 app_versions 迁移：EXE 安装包字段（download_url 仅存 ZIP，扩展 exe_url）
            for col, sql in (
                ("exe_url", "ALTER TABLE app_versions ADD COLUMN exe_url VARCHAR(500) NULL COMMENT 'EXE安装包下载地址'"),
                ("exe_file_size", "ALTER TABLE app_versions ADD COLUMN exe_file_size BIGINT NULL COMMENT 'EXE文件大小（字节）'"),
            ):
                cur.execute(
                    "SELECT COUNT(*) AS n FROM information_schema.COLUMNS "
                    "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'app_versions' "
                    "AND COLUMN_NAME = %s",
                    (settings.db_name, col),
                )
                if cur.fetchone()["n"] == 0:
                    cur.execute(sql)
                    conn.commit()

            # 历史数据修复（幂等）：软删除的循环实例仍占着 uk_repeat 唯一槽位，
            # 导致同一期永远无法重新落库 —— 客户端每轮补生成都被静默丢弃，
            # 形成「生成 → 同步覆盖 → 再生成」的死循环。清空软删行的 instance_date 即释放。
            cur.execute(
                "UPDATE tasks SET instance_date = NULL "
                "WHERE is_deleted = 1 AND instance_date IS NOT NULL"
            )
            if cur.rowcount > 0:
                print(f"[init_db] 已释放 {cur.rowcount} 条软删除循环实例占用的唯一键")
            conn.commit()

    print("[init_db] 数据表就绪")

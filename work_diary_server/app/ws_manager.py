"""WebSocket 连接管理：按 userId 维护在线连接，广播数据变更、定向推送附件中转消息。

除了 client_id（每次启动随机，用于排除自己），这里还记录 device_id / device_name：
附件"按需中转"要知道同一用户的其它设备是否在线、由谁来应答拉取请求。
"""
from dataclasses import dataclass

from fastapi import WebSocket


@dataclass
class Conn:
    ws: WebSocket
    device_id: str = ""
    device_name: str = ""
    catchup_done: bool = False


class WsManager:
    def __init__(self):
        # userId -> {client_id: Conn}
        self._conns: dict[int, dict[str, Conn]] = {}

    async def connect(
        self,
        user_id: int,
        client_id: str,
        ws: WebSocket,
        device_id: str = "",
        device_name: str = "",
    ) -> Conn:
        await ws.accept()
        conn = Conn(ws=ws, device_id=device_id or "", device_name=device_name or "")
        self._conns.setdefault(user_id, {})[client_id] = conn
        return conn

    def disconnect(self, user_id: int, client_id: str, ws: WebSocket | None = None):
        if user_id not in self._conns:
            return
        # 如果传了 ws，只有当当前存储的连接就是这个 ws 时才删除（防止旧连接误删新连接）
        if ws is not None:
            current = self._conns[user_id].get(client_id)
            if current is not None and current.ws is not ws:
                return
        self._conns[user_id].pop(client_id, None)
        if not self._conns[user_id]:
            del self._conns[user_id]

    def set_device(
        self, user_id: int, client_id: str, device_id: str, device_name: str = ""
    ) -> None:
        """客户端连上后发 hello 补齐设备信息（URL 参数是可选的旧入口）。"""
        conn = self._conns.get(user_id, {}).get(client_id)
        if conn is None:
            return
        if device_id:
            conn.device_id = device_id[:64]
        if device_name:
            conn.device_name = device_name[:128]

    async def notify_data_changed(self, user_id: int, exclude_client_id: str | None = None):
        """通知某用户的其他设备数据变了，排除 exclude_client_id。"""
        await self.send_to_user(user_id, {"type": "data_changed"}, exclude_client_id)

    async def send_to_user(
        self,
        user_id: int,
        payload: dict,
        exclude_client_id: str | None = None,
        only_device_id: str | None = None,
    ) -> int:
        """给某用户的连接推送一条消息，返回成功送达的连接数。

        only_device_id 用于定向发给某台设备；exclude_client_id 用于排除发起方。
        """
        conns = self._conns.get(user_id, {})
        sent = 0
        dead: list[str] = []
        for cid, conn in conns.items():
            if cid == exclude_client_id:
                continue
            if only_device_id is not None and conn.device_id != only_device_id:
                continue
            try:
                await conn.ws.send_json(payload)
                sent += 1
            except Exception:
                dead.append(cid)
        for cid in dead:
            self.disconnect(user_id, cid)
        return sent

    async def send_to_conn(self, conn: Conn, payload: dict) -> bool:
        try:
            await conn.ws.send_json(payload)
            return True
        except Exception:
            return False

    def other_connection_count(self, user_id: int, exclude_client_id: str | None = None) -> int:
        """该用户当前还有几台设备在线（排除发起方）——决定"有没有人能应答拉取"。"""
        conns = self._conns.get(user_id, {})
        if exclude_client_id is None:
            return len(conns)
        return len([cid for cid in conns if cid != exclude_client_id])


ws_manager = WsManager()

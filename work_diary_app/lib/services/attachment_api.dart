import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/attachment.dart';
import 'api_config.dart';
import 'auth_service.dart';
import 'sync_websocket.dart';

/// 附件接口的原始 HTTP 调用：元数据同步 + 按需中转的分片上传/下载。
///
/// 与 `RemoteSyncService._request` 的区别只有两点：这里要传二进制（PUT 分片、
/// GET 整个文件），大文件必须流式落盘，不能进内存。鉴权头、错误解析保持一致，
/// 改任何一边记得同步另一边。
class AttachmentApi {
  static const Duration _jsonTimeout = Duration(seconds: 20);
  static const Duration _chunkTimeout = Duration(seconds: 120);

  static String? get _token => AuthService.token;

  static Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        'X-Client-Id': SyncClientId.instance,
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  static Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${ApiConfig.baseUrl}$path')
          .replace(queryParameters: query == null || query.isEmpty ? null : query);

  static Future<Map<String, dynamic>> _json(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    http.Response resp;
    try {
      final request = http.Request(method, uri)..headers.addAll(_headers());
      if (body != null) request.body = jsonEncode(body);
      resp = await http.Response.fromStream(
          await _client.send(request).timeout(_jsonTimeout));
    } catch (_) {
      throw const AttachmentApiException(0, '网络错误，请检查网络或服务器地址');
    }
    return _decode(resp);
  }

  static final http.Client _client = http.Client();

  static Map<String, dynamic> _decode(http.Response resp) {
    dynamic data;
    try {
      // 与 RemoteSyncService 一致：按 UTF-8 解字节，否则中文错误提示会变乱码
      data = resp.bodyBytes.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    } catch (_) {
      data = <String, dynamic>{};
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }
    final detail = data is Map && data['detail'] != null
        ? data['detail'].toString()
        : '请求失败(${resp.statusCode})';
    throw AttachmentApiException(resp.statusCode, detail);
  }

  // ---------------- 元数据 ----------------

  /// 全量上报本机附件元数据 + 删除墓碑，返回云端全量列表。
  static Future<AttachmentSyncPayload> sync({
    required List<Attachment> attachments,
    required List<({String uid, DateTime deletedAt})> deletions,
  }) async {
    final data = await _json('POST', _uri('/api/attachments/sync'), body: {
      'attachments': attachments.map((a) => a.toApi()).toList(),
      'deletions': deletions
          .map((d) => {
                'uid': d.uid,
                'deleted_at': d.deletedAt.toUtc().toIso8601String(),
              })
          .toList(),
    });
    return AttachmentSyncPayload(
      attachments: (data['attachments'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Attachment.fromApi(Map<String, dynamic>.from(e)))
          .toList(),
      deletedUids: (data['deleted_uids'] as List? ?? []).map((e) => '$e').toList(),
      rejectedUids: (data['rejected_uids'] as List? ?? []).map((e) => '$e').toList(),
    );
  }

  // ---------------- 中转 ----------------

  /// 目标端发起拉取。state: requested / waiting / ready / done
  static Future<AttachmentRequestResult> request(
      String uid, String deviceId, String deviceName) async {
    final data = await _json('POST', _uri('/api/attachments/$uid/request'),
        body: {'device_id': deviceId, 'device_name': deviceName});
    return AttachmentRequestResult(
      state: '${data['state'] ?? ''}',
      sources: data['sources'] is int ? data['sources'] as int : 0,
      message: '${data['message'] ?? ''}',
    );
  }

  /// 源端初始化/续传定位。state: upload / ready
  static Future<AttachmentUploadInit> uploadInit(
      String uid, String deviceId, String deviceName) async {
    final data = await _json('POST', _uri('/api/attachments/$uid/upload/init'),
        body: {'device_id': deviceId, 'device_name': deviceName});
    return AttachmentUploadInit(
      state: '${data['state'] ?? ''}',
      nextOffset: data['next_offset'] is int ? data['next_offset'] as int : 0,
      chunkSize: data['chunk_size'] is int ? data['chunk_size'] as int : 0,
      fileSize: data['file_size'] is int ? data['file_size'] as int : 0,
      sha256: '${data['sha256'] ?? ''}',
    );
  }

  /// 写入一个分片，返回服务器认定的下一个偏移（偏移不对时服务器会纠正）。
  static Future<({String state, int nextOffset})> uploadChunk(
      String uid, int offset, Uint8List bytes) async {
    final uri = _uri('/api/attachments/$uid/upload', {'offset': '$offset'});
    final request = http.Request('PUT', uri)
      ..headers.addAll(_headers(json: false))
      ..bodyBytes = bytes;
    http.Response resp;
    try {
      resp = await http.Response.fromStream(
          await _client.send(request).timeout(_chunkTimeout));
    } catch (_) {
      throw const AttachmentApiException(0, '网络错误，分片上传失败');
    }
    final data = _decode(resp);
    return (
      state: '${data['state'] ?? ''}',
      nextOffset: data['next_offset'] is int ? data['next_offset'] as int : offset,
    );
  }

  static Future<void> uploadComplete(String uid, String deviceId, String deviceName) async {
    await _json('POST', _uri('/api/attachments/$uid/upload/complete'),
        body: {'device_id': deviceId, 'device_name': deviceName});
  }

  /// 下载中转文件到指定路径（流式，内存里只有一片）。
  static Future<void> download(String uid, String deviceId, String saveTo) async {
    final uri = _uri('/api/attachments/$uid/blob', {'device_id': deviceId});
    final request = http.Request('GET', uri)..headers.addAll(_headers(json: false));
    http.StreamedResponse resp;
    try {
      resp = await _client.send(request).timeout(_jsonTimeout);
    } catch (_) {
      throw const AttachmentApiException(0, '网络错误，下载失败');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final body = await resp.stream.bytesToString();
      String detail = '请求失败(${resp.statusCode})';
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['detail'] != null) detail = decoded['detail'].toString();
      } catch (_) {}
      throw AttachmentApiException(resp.statusCode, detail);
    }
    final file = File(saveTo);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    try {
      // 分片体不加整体超时：100MB 在慢网络下几分钟才算正常，
      // 真正断流时 http 的 socket 错误会自己冒出来。
      await resp.stream.forEach(sink.add);
      await sink.flush();
    } catch (e) {
      throw e is AttachmentApiException
          ? e
          : const AttachmentApiException(0, '下载中断，请重试');
    } finally {
      await sink.close();
    }
  }

  /// 下载完成确认：所有请求方都确认后服务器立刻删掉中转文件。
  static Future<({int remaining, bool blobDeleted})> ack(
      String uid, String deviceId, String deviceName) async {
    final data = await _json('POST', _uri('/api/attachments/$uid/ack'),
        body: {'device_id': deviceId, 'device_name': deviceName});
    return (
      remaining: data['remaining'] is int ? data['remaining'] as int : 0,
      blobDeleted: data['blob_deleted'] == true,
    );
  }

  /// 中转状态查询（WebSocket 掉线时的兜底，以及"这份文件是不是我要的"确认）
  static Future<AttachmentStatePayload> state(String uid) async {
    final data = await _json('GET', _uri('/api/attachments/$uid/state'));
    return AttachmentStatePayload(
      blobState: '${data['blob_state'] ?? 'none'}',
      transfers: (data['transfers'] as List? ?? [])
          .whereType<Map>()
          .map((t) => AttachmentTransferRow(
                deviceId: '${t['device_id'] ?? ''}',
                status: '${t['status'] ?? ''}',
              ))
          .toList(),
    );
  }
}

class AttachmentApiException implements Exception {
  const AttachmentApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  /// 410=服务器上的中转副本已过期，404=附件已不存在：都属于"重新点一次同步"
  bool get retryable => statusCode == 410 || statusCode == 404 || statusCode == 0;

  @override
  String toString() => message;
}

class AttachmentSyncPayload {
  const AttachmentSyncPayload({
    required this.attachments,
    required this.deletedUids,
    required this.rejectedUids,
  });

  final List<Attachment> attachments;
  final List<String> deletedUids;
  final List<String> rejectedUids;
}

class AttachmentRequestResult {
  const AttachmentRequestResult({
    required this.state,
    required this.sources,
    required this.message,
  });

  final String state;
  final int sources;
  final String message;
}

class AttachmentUploadInit {
  const AttachmentUploadInit({
    required this.state,
    required this.nextOffset,
    required this.chunkSize,
    required this.fileSize,
    required this.sha256,
  });

  final String state;
  final int nextOffset;
  final int chunkSize;
  final int fileSize;
  final String sha256;
}

class AttachmentTransferRow {
  const AttachmentTransferRow({required this.deviceId, required this.status});

  final String deviceId;
  final String status;

  bool get pending => status == 'pending';
}

class AttachmentStatePayload {
  const AttachmentStatePayload({required this.blobState, required this.transfers});

  final String blobState;
  final List<AttachmentTransferRow> transfers;

  bool thisDeviceRequested(String deviceId) =>
      transfers.any((t) => t.deviceId == deviceId && t.pending);
}

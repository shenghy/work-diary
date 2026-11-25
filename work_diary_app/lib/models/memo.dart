/// 备忘数据模型（纯记录型，无状态/紧急度/计划时间）
class Memo {
  final int? id;
  final int? remoteId; // 远端数据库ID，用于同步
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt; // 最后修改时间，用于同步冲突判断

  Memo({
    this.id,
    this.remoteId,
    required this.content,
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  Memo copyWith({
    int? id,
    int? remoteId,
    String? content,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Memo(
      id: id ?? this.id,
      remoteId: remoteId ?? this.remoteId,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'remote_id': remoteId,
      'content': content,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Memo.fromMap(Map<String, dynamic> map) {
    // 容错解析：一条脏记录不能让整批备忘读取失败
    final createdAt = map['created_at'] is String
        ? (DateTime.tryParse(map['created_at'] as String) ?? DateTime.now())
        : DateTime.now();
    final updatedAt = map['updated_at'] is String
        ? DateTime.tryParse(map['updated_at'] as String)
        : null;
    return Memo(
      id: map['id'] as int?,
      remoteId: map['remote_id'] as int?,
      content: (map['content'] as String?) ?? '',
      createdAt: createdAt,
      updatedAt: updatedAt ?? createdAt,
    );
  }
}

# -*- coding: utf-8 -*-
"""Windows：已完成/全部 tab 分页 + 搜索 + 筛选"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1. 字段
old1 = """  bool _animateNextMemo = false; // 切换备忘 tab 后，加载完成时重放入场动画
  int _loadSeq = 0; // 加载序号：只允许最后一次加载触发动画（防连续切换竞态）"""
new1 = """  bool _animateNextMemo = false; // 切换备忘 tab 后，加载完成时重放入场动画
  int _loadSeq = 0; // 加载序号：只允许最后一次加载触发动画（防连续切换竞态）
  // ===== 已完成/全部 tab：分页 + 搜索 + 筛选 =====
  List<Task> _allTasks = []; // 全量任务缓存（已完成/全部的搜索与筛选基于它）
  final TextEditingController _taskSearchCtrl = TextEditingController();
  Urgency? _filterUrgency; // 紧急度筛选，null=全部
  int? _filterType; // 类型筛选，null=全部，0=个人，1=工作
  int _visibleCount = 10; // 分页当前显示条数
  static const int _pageSize = 10; // 每页条数"""
if old1 in c:
    c = c.replace(old1, new1, 1); print("1 ok")
else:
    print("1 FAIL")

# 2. dispose
old2 = """    _memoSearchCtrl.dispose();
    _traySub?.cancel();"""
new2 = """    _memoSearchCtrl.dispose();
    _taskSearchCtrl.dispose();
    _traySub?.cancel();"""
if old2 in c:
    c = c.replace(old2, new2, 1); print("2 ok")
else:
    print("2 FAIL")

# 3. _loadTasks 缓存全量
old3 = """    final tasks = _filter == null
        ? all
        : all.where((t) => t.status == _filter).toList();
    if (seq != _loadSeq) return; // 已被更新的加载取代，丢弃本次结果
    if (mounted) setState(() => _tasks = tasks);"""
new3 = """    final tasks = _filter == null
        ? all
        : all.where((t) => t.status == _filter).toList();
    if (seq != _loadSeq) return; // 已被更新的加载取代，丢弃本次结果
    if (mounted) {
      setState(() {
        _allTasks = all; // 缓存全量，供已完成/全部的搜索与筛选
        _tasks = tasks;
      });
    }"""
if old3 in c:
    c = c.replace(old3, new3, 1); print("3 ok")
else:
    print("3 FAIL")

# 4. 任务 tab 切换重置搜索/筛选/分页
old4 = """            } else {
              setState(() {
                _showMemoView = false;
                _filter = status;
              });
              _animateNextList = true; // 切换任务 tab 后重放入场动画
              _loadTasks();
            }"""
new4 = """            } else {
              setState(() {
                _showMemoView = false;
                _filter = status;
              });
              // 切换任务 tab：重置搜索词、筛选条件和分页
              _taskSearchCtrl.clear();
              _filterUrgency = null;
              _filterType = null;
              _visibleCount = _pageSize;
              _animateNextList = true; // 切换任务 tab 后重放入场动画
              _loadTasks();
            }"""
if old4 in c:
    c = c.replace(old4, new4, 1); print("4 ok")
else:
    print("4 FAIL")

# 5. body 三态：分页模式走独立视图
old5 = """              _showMemoView
                  ? _buildMemoView()
                  : _tasks.isEmpty
                  ? const Center(
                      child: Text(
                        '还没有任务，点击右下角 + 创建',
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    )
                  : ListView.builder("""
new5 = """              _showMemoView
                  ? _buildMemoView()
                  : _isPagedTab
                  ? _buildPagedTaskView()
                  : _tasks.isEmpty
                  ? const Center(
                      child: Text(
                        '还没有任务，点击右下角 + 创建',
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    )
                  : ListView.builder("""
if old5 in c:
    c = c.replace(old5, new5, 1); print("5 ok")
else:
    print("5 FAIL")

# 6. 现有 itemBuilder 抽取为 _buildTaskItem
old6 = """                      itemBuilder: (context, i) {
                        // 确保 cardKeys 长度匹配
                        while (_cardKeys.length < _tasks.length) {
                          _cardKeys.add(GlobalKey());
                        }
                        while (_cardKeys.length > _tasks.length) {
                          _cardKeys.removeLast();
                        }

                        final isDragging = _draggingIndex == i && _isDragging;
                        final showInsertGap =
                            _insertIndex == i &&
                            _isDragging &&
                            _draggingIndex != i;

                        return _EntranceItem(
                          controller: _entranceCtrl,
                          index: i,
                          total: _tasks.length,
                          child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: ["""
new6 = """                      itemBuilder: (context, i) =>
                          _buildTaskItem(i, _tasks[i], _tasks.length),"""
if old6 in c:
    c = c.replace(old6, new6, 1); print("6 ok")
else:
    print("6 FAIL")

# 7. 在 _buildMemoView 之前插入新方法（_isPagedTab / _buildPagedTaskView / _filteredTasks / _buildTaskItem / _buildLoadMoreButton / _filterChip）
anchor = """  Widget _buildMemoView() {"""
new_methods = """  /// 是否处于分页模式（已完成 / 全部 tab）
  bool get _isPagedTab =>
      !_showMemoView && (_filter == TaskStatus.completed || _filter == null);

  /// 已完成/全部：全量缓存 → 状态 → 搜索 → 紧急度 → 类型 过滤
  List<Task> _filteredTasks() {
    List<Task> list = _filter == null
        ? List.of(_allTasks)
        : _allTasks.where((t) => t.status == _filter).toList();
    final kw = _taskSearchCtrl.text.trim().toLowerCase();
    if (kw.isNotEmpty) {
      list = list
          .where((t) => t.title.toLowerCase().contains(kw))
          .toList();
    }
    if (_filterUrgency != null) {
      list = list.where((t) => t.urgency == _filterUrgency).toList();
    }
    if (_filterType != null) {
      list = list.where((t) => t.taskType == _filterType).toList();
    }
    return list;
  }

  /// 已完成/全部 tab 视图：搜索框 + 筛选条 + 分页列表
  Widget _buildPagedTaskView() {
    final filtered = _filteredTasks();
    final visible = filtered.take(_visibleCount).toList();
    final hasMore = filtered.length > _visibleCount;
    return Column(
      children: [
        // 搜索框
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            controller: _taskSearchCtrl,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: '搜索任务标题 / 子任务内容…',
              hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _taskSearchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _taskSearchCtrl.clear();
                        setState(() {});
                      },
                    ),
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey.shade200),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey.shade200),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
        // 筛选条
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              _filterChip('紧急度', null, _filterUrgency, '全部',
                  () => setState(() => _filterUrgency = null)),
              _filterChip('紧急度', Urgency.normal, _filterUrgency, '一般',
                  () => setState(() => _filterUrgency = Urgency.normal)),
              _filterChip('紧急度', Urgency.important, _filterUrgency, '重要',
                  () => setState(() => _filterUrgency = Urgency.important)),
              _filterChip('紧急度', Urgency.urgent, _filterUrgency, '紧急',
                  () => setState(() => _filterUrgency = Urgency.urgent)),
              const SizedBox(width: 6),
              const Text('|', style: TextStyle(fontSize: 12, color: Color(0xFFD1D5DB))),
              const SizedBox(width: 6),
              _filterChip('类型', null, _filterType, '全部',
                  () => setState(() => _filterType = null)),
              _filterChip('类型', 1, _filterType, '工作',
                  () => setState(() => _filterType = 1)),
              _filterChip('类型', 0, _filterType, '个人',
                  () => setState(() => _filterType = 0)),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    _allTasks.isEmpty
                        ? '还没有任务，点击右下角 + 创建'
                        : '没有找到匹配的任务',
                    style: const TextStyle(color: Colors.grey, fontSize: 14),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 8, bottom: 108),
                  itemCount: visible.length + (hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == visible.length) {
                      return _buildLoadMoreButton(
                          filtered.length - visible.length);
                    }
                    return _buildTaskItem(i, visible[i], visible.length);
                  },
                ),
        ),
      ],
    );
  }

  /// 加载更多按钮
  Widget _buildLoadMoreButton(int remaining) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: OutlinedButton(
          onPressed: () =>
              setState(() => _visibleCount += _pageSize),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            side: const BorderSide(color: Color(0xFF3B82F6)),
          ),
          child: Text(
            '还有 $remaining 条，点击加载更多',
            style: const TextStyle(fontSize: 12, color: Color(0xFF3B82F6)),
          ),
        ),
      ),
    );
  }

  /// 筛选胶囊
  Widget _filterChip(String group, dynamic value, dynamic current, String label,
      VoidCallback onTap) {
    final selected = value == current;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : Colors.grey,
          ),
        ),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: const Color(0xFF3B82F6),
        backgroundColor: Colors.grey.shade100,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),
    );
  }

  /// 任务卡片条目（供普通列表与分页列表共用）
  Widget _buildTaskItem(int i, Task task, int total) {
    // 确保 cardKeys 长度匹配
    while (_cardKeys.length < total) {
      _cardKeys.add(GlobalKey());
    }
    while (_cardKeys.length > total) {
      _cardKeys.removeLast();
    }

    final isDragging = _draggingIndex == i && _isDragging;
    final showInsertGap =
        _insertIndex == i && _isDragging && _draggingIndex != i;

    return _EntranceItem(
      controller: _entranceCtrl,
      index: i,
      total: total,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showInsertGap)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          Listener(
            key: _cardKeys[i],
            onPointerDown: (e) => _onPointerDown(i, e),
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            child: Opacity(
              opacity: isDragging ? 0.3 : 1.0,
              child: TaskCard(
                task: task,
                isDragging: _isDragging,
                onStatusToggle: (ctx) => _animateStatusChange(task, ctx),
                onDelete: () => _deleteTask(task),
                onDoubleTap: () => _showEditDialog(task),
                onEdit: () => _showEditDialog(task),
                onSubTaskChanged: (updated) => _onSubTaskChanged(updated),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoView() {"""
if anchor in c:
    c = c.replace(anchor, new_methods, 1); print("7 ok")
else:
    print("7 FAIL")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")

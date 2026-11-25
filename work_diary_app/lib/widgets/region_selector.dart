import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/glass_palette.dart';

/// 全屏区域选择页面：1:1 显示原始截图（不缩放），上层半透明遮罩，选中区域挖空。
///
/// 返回裁剪后的 PNG 字节（Uint8List）。
///
/// 用法：
/// ```dart
/// final cropped = await Navigator.push<Uint8List>(
///   context,
///   MaterialPageRoute(
///     fullscreenDialog: true,
///     builder: (_) => RegionSelector(screenshot: pngBytes),
///   ),
/// );
/// ```
class RegionSelector extends StatefulWidget {
  final Uint8List screenshot;

  const RegionSelector({super.key, required this.screenshot});

  @override
  State<RegionSelector> createState() => _RegionSelectorState();
}

class _RegionSelectorState extends State<RegionSelector> {
  ui.Image? _decodedImage;
  Rect? _selection;
  Offset? _dragStart;
  bool _visible = false; // 淡入动画控制

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.screenshot);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _decodedImage = frame.image);
      // 图片解码完成后，延迟一小段时间触发淡入，掩盖窗口渲染切换
      await Future.delayed(const Duration(milliseconds: 50));
      if (mounted) setState(() => _visible = true);
    }
  }

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _dragStart = details.globalPosition;
      _selection = Rect.fromPoints(details.globalPosition, details.globalPosition);
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragStart == null) return;
    setState(() {
      _selection = Rect.fromPoints(_dragStart!, details.globalPosition);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _dragStart = null;
  }

  /// 裁剪选中区域，返回 PNG 字节
  Future<Uint8List?> _cropSelection() async {
    if (_selection == null || _decodedImage == null) return null;
    final rect = _selection!;
    if (rect.width < 5 || rect.height < 5) return null;

    final srcRect = Rect.fromLTWH(
      rect.left,
      rect.top,
      rect.width,
      rect.height,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint();

    canvas.drawImageRect(
      _decodedImage!,
      srcRect,
      Rect.fromLTWH(0, 0, rect.width, rect.height),
      paint,
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(
      rect.width.toInt(),
      rect.height.toInt(),
    );
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    img.dispose();

    return byteData?.buffer.asUint8List();
  }

  Future<void> _confirm() async {
    if (_selection == null) return;
    if (_selection!.width < 5 || _selection!.height < 5) return;
    final cropped = await _cropSelection();
    if (cropped == null) return;

    // 保存到系统临时目录
    try {
      final tempDir = Directory.systemTemp;
      final fileName = 'workdiary_screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File('${tempDir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(cropped);
      debugPrint('[截图] 已保存到临时目录: ${file.path}');
    } catch (e) {
      debugPrint('[截图] 保存临时文件失败: $e');
    }

    if (mounted) Navigator.of(context).pop(cropped);
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final screenSize = MediaQuery.of(context).size;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // ESC 取消截图
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        // 截图覆盖层：底色与遮罩固定压黑，不跟主题走，否则浅底叠在浅色截图上
        // 就看不出选区边界了。
        backgroundColor: Colors.black,
        body: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onDoubleTap: _confirm,
          onSecondaryTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            // 底层：1:1 显示原始截图（不缩放，窗口大小=截图大小）
            Positioned.fill(
              child: _decodedImage != null
                  ? RawImage(
                      image: _decodedImage,
                      fit: BoxFit.none, // 不缩放，1:1 显示
                      alignment: Alignment.topLeft,
                    )
                  : const Center(child: CircularProgressIndicator(color: Colors.white)),
            ),
            // 上层：半透明遮罩，选中区域挖空（显示底层截图）
            Positioned.fill(
              child: CustomPaint(
                size: screenSize,
                painter: _MaskPainter(selection: _selection),
              ),
            ),
            // 选中区域边框
            if (_selection != null)
              Positioned(
                left: _selection!.left,
                top: _selection!.top,
                width: _selection!.width,
                height: _selection!.height,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: g.accent, width: 2),
                  ),
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      color: g.accent,
                      child: Text(
                        '${_selection!.width.toInt()} × ${_selection!.height.toInt()}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // 顶部提示
            Positioned(
              top: 20,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    // 提示胶囊压在任意桌面截图上，底色必须固定压黑才读得出来，
                    // 所以这里不跟主题走：两档都是黑底白字。
                    color: Colors.black.withAlpha(179),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '拖拽鼠标框选区域，松开后点「确认」；右键取消',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
            // 底部操作按钮
            if (_selection != null && _selection!.width > 5 && _selection!.height > 5)
              Positioned(
                bottom: 30,
                left: 0,
                right: 0,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildButton('取消', g.statusPlanned, () => Navigator.of(context).pop()),
                      const SizedBox(width: 16),
                      _buildButton('确认', g.accent, _confirm),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
    ),
  );
  }

  Widget _buildButton(String text, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

/// 遮罩绘制：全屏半透明黑色，选中区域挖空（显示底层截图）
class _MaskPainter extends CustomPainter {
  final Rect? selection;

  _MaskPainter({this.selection});

  @override
  void paint(Canvas canvas, Size size) {
    // 遮罩固定在黑上：叠在任何截图上都要压暗，浅色档同样不能变白，
    // 因此这里有意不走 [GlassPalette]（见 RegionSelector 的说明）。
    final maskPaint = Paint()..color = Colors.black.withAlpha(140);

    if (selection == null) {
      canvas.drawRect(Offset.zero & size, maskPaint);
      return;
    }

    // 用 Path.combine 挖空选中区域：全屏路径 - 选中区域 = 遮罩路径
    final fullPath = Path()..addRect(Offset.zero & size);
    final selPath = Path()..addRect(selection!);
    final maskPath = Path.combine(PathOperation.difference, fullPath, selPath);
    canvas.drawPath(maskPath, maskPaint);
  }

  @override
  bool shouldRepaint(covariant _MaskPainter oldDelegate) {
    return oldDelegate.selection != selection;
  }
}

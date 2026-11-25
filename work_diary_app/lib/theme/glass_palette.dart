import 'package:flutter/material.dart';

/// 玻璃外观的唯一调色板，深色 / 浅色两份取值。
///
/// 背景、玻璃层、卡片、文字、胶囊、输入框全部从这里取色；想整体调深浅，
/// 只改这个文件，不要在页面里散落十六进制。
///
/// 用法：`GlassPalette.of(context).ink`。走 Theme.of 是为了让每个用到令牌的
/// widget 自动登记主题依赖——切主题时整窗才会重建，而不是只有个别卡片变。
@immutable
class GlassPalette extends ThemeExtension<GlassPalette> {
  const GlassPalette({
    required this.isLight,
    required this.bgTop,
    required this.bgBottom,
    required this.blobIndigo,
    required this.blobPeriwinkle,
    required this.blobSky,
    required this.blobViolet,
    required this.blobOrchid,
    required this.blobAqua,
    required this.blobHighlight,
    required this.auroraGlow,
    required this.auroraGlowAlpha,
    required this.auroraShade,
    required this.auroraShadeAlpha,
    required this.glassTop,
    required this.glassMid,
    required this.glassBottom,
    required this.cardTop,
    required this.cardBottom,
    required this.cardBorder,
    required this.cardEdgeTop,
    required this.cardEdgeBottom,
    required this.shadow,
    required this.shadowSoft,
    required this.tintTop,
    required this.tintBottom,
    required this.tintTopAlpha,
    required this.tintBottomAlpha,
    required this.glassEdgeColor,
    required this.edgeAlpha,
    required this.shadeColor,
    required this.shadeAlpha,
    required this.liftBase,
    required this.liftAlpha,
    required this.rimTopLine,
    required this.rimGlowTop,
    required this.rimBottomLine,
    required this.rimCornerGlow,
    required this.rimDiagonal,
    required this.sheenGlare,
    required this.sheenAlpha,
    required this.ink,
    required this.inkSecondary,
    required this.inkTertiary,
    required this.inkFaint,
    required this.chipBg,
    required this.chipBorder,
    required this.fieldBg,
    required this.fieldBorder,
    required this.trackBg,
    required this.opaqueControl,
    required this.divider,
    required this.gridLine,
    required this.disabledFg,
    required this.surface,
    required this.menuText,
    required this.menuTextFaint,
    required this.menuDivider,
    required this.tabBg,
    required this.tabBorder,
    required this.tabFg,
    required this.tabActiveBg,
    required this.tabActiveFg,
    required this.searchRing,
    required this.searchRingGlow,
    required this.overdueFg,
    required this.overdueBorder,
    required this.overdueFill,
    required this.urgencyNormal,
    required this.urgencyImportant,
    required this.urgencyUrgent,
    required this.urgencyBgNormal,
    required this.urgencyBgImportant,
    required this.urgencyBgUrgent,
    required this.statusPlanned,
    required this.statusExecuting,
    required this.statusCompleted,
    required this.repeatChipBg,
    required this.repeatChipBorder,
    required this.repeatChipIcon,
    required this.repeatChipText,
    required this.accentText,
    required this.successSoft,
    required this.dangerSoft,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
    required this.statsPrimary,
    required this.statsPrimarySoft,
    required this.statsTeal,
    required this.statsAmber,
    required this.statsPink,
    required this.statsBlue,
    required this.decoInk,
    required this.heatScale,
    required this.memoPaperTop,
    required this.memoPaperBottom,
  });

  /// 当前是不是浅色档。少数地方（备忘哈希取色、印章描边）需要按档位换算法，
  /// 用它判断，不要再去看某个具体色值。
  final bool isLight;

  // ===== 底板 =====
  final Color bgTop;
  final Color bgBottom;

  // ===== 底板色团（带 alpha，叠在底色上） =====
  final Color blobIndigo;
  final Color blobPeriwinkle;
  final Color blobSky;
  final Color blobViolet;
  final Color blobOrchid;
  final Color blobAqua;
  final Color blobHighlight;

  /// 极光迎光面 / 右下压暗：深色靠白 26 + 黑 30，浅色要提亮所以白得多、压得淡。
  final Color auroraGlow;
  final int auroraGlowAlpha;
  final Color auroraShade;
  final int auroraShadeAlpha;

  // ===== 全窗玻璃层 =====
  /// 压 blur 之后那一层渐变：深色是暗 scrim，浅色是白雾。
  final Color glassTop;
  final Color glassMid;
  final Color glassBottom;

  // ===== 任务卡片 =====
  final Color cardTop;
  final Color cardBottom;
  final Color cardBorder;
  final Color cardEdgeTop;
  final Color cardEdgeBottom;
  final Color shadow;
  final Color shadowSoft;

  // ===== 玻璃材质（GlassStyle） =====
  final Color tintTop;
  final Color tintBottom;
  final int tintTopAlpha;
  final int tintBottomAlpha;
  final Color glassEdgeColor;
  final int edgeAlpha;

  /// 卡片压层：深色压黑 72 把卡片「按」进背景，浅色压白 190 把卡片「抬」起来。
  final Color shadeColor;
  final int shadeAlpha;
  final Color liftBase;
  final int liftAlpha;

  // ===== 边光 =====
  final Color rimTopLine;
  final Color rimGlowTop;
  final Color rimBottomLine;
  final Color rimCornerGlow;
  final Color rimDiagonal;
  final Color sheenGlare;
  final int sheenAlpha;

  // ===== 文字 =====
  final Color ink;
  final Color inkSecondary;
  final Color inkTertiary;
  final Color inkFaint;

  /// 装饰线 / 淡影的基色：深色档是纯白（改造前的写法是 `Colors.white.withAlpha(N)`，
  /// 逐位对齐才不会动已经录好的 golden），浅色档跟着墨色翻。
  /// alpha 一律留在调用点——同一根线在不同图上浓淡本来就不一样。
  final Color decoInk;

  // ===== 胶囊 / 输入框 =====
  final Color chipBg;
  final Color chipBorder;
  final Color fieldBg;
  final Color fieldBorder;

  /// 进度条 / 紧急度条的空槽：比卡片亮一小档，让「完成到哪儿」一眼能读出来。
  final Color trackBg;

  /// 不透明的悬浮控件底色（左下角菜单按钮等）。
  /// 任务卡会从按钮后面滚过，透明/半透明会透出卡片文字，必须实色。
  final Color opaqueControl;

  final Color divider;
  final Color gridLine;
  final Color disabledFg;

  // ===== 浮层表面：菜单、对话框、弹出面板共用的实色底 =====
  final Color surface;
  final Color menuText;
  final Color menuTextFaint;
  final Color menuDivider;

  // ===== tab 胶囊 =====
  final Color tabBg;
  final Color tabBorder;
  final Color tabFg;
  final Color tabActiveBg;
  final Color tabActiveFg;

  // ===== 搜索框 / 过期印章 =====
  final Color searchRing;
  final Color searchRingGlow;
  final Color overdueFg;
  final Color overdueBorder;
  final Color overdueFill;

  // ===== 状态色 =====
  final Color urgencyNormal;
  final Color urgencyImportant;
  final Color urgencyUrgent;
  final Color urgencyBgNormal;
  final Color urgencyBgImportant;
  final Color urgencyBgUrgent;
  final Color statusPlanned;
  final Color statusExecuting;
  final Color statusCompleted;

  // ===== 循环任务角标 =====
  final Color repeatChipBg;
  final Color repeatChipBorder;
  final Color repeatChipIcon;
  final Color repeatChipText;

  // ===== 链接 / 语义强调文字 =====
  final Color accentText;
  final Color successSoft;
  final Color dangerSoft;

  // ===== 强调色 =====
  final Color accent;
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color danger;

  // ===== 数据看板 =====
  // 看板是"数据色"，和任务卡的"状态色"分开：柱状图、环形图、热力图共用这一组，
  // 页面里不允许再出现写死的十六进制。
  final Color statsPrimary;
  final Color statsPrimarySoft;
  final Color statsTeal;
  final Color statsAmber;
  final Color statsPink;
  final Color statsBlue;

  /// 热力图 5 档色阶：下标 = level（0 表示当天没有完成）。
  final List<Color> heatScale;

  /// 备忘卡纸面染色：色相由 [memoTones] 按内容哈希决定，明度/透明度看这一档。
  final Color memoPaperTop;
  final Color memoPaperBottom;

  /// 备忘卡的 6 组内容色带（深→浅，给渐变用）。深浅两档同值：这是「内容色」，
  /// 用来区分不同备忘，不跟着主题翻。
  static const List<List<Color>> memoTones = [
    [Color(0xFF3B82F6), Color(0xFF93C5FD)], // 蓝
    [Color(0xFF8B5CF6), Color(0xFFC4B5FD)], // 紫
    [Color(0xFF10B981), Color(0xFF6EE7B7)], // 绿
    [Color(0xFFF59E0B), Color(0xFFFCD34D)], // 橙
    [Color(0xFFEF4444), Color(0xFFFCA5A5)], // 红
    [Color(0xFF06B6D4), Color(0xFF67E8F9)], // 青
  ];

  /// 备忘卡按内容哈希取色：浅色档要把色相压深，否则彩字白底看不清。
  Color memoStripe(Color base) =>
      isLight ? Color.lerp(base, const Color(0xFF14213D), 0.28)! : base;

  static const List<Color> _heatDark = [
    Color(0x14FFFFFF), // 0：几乎透明
    Color(0x4D7B6CFF),
    Color(0x8C7B6CFF),
    Color(0xC4A99CFF),
    Color(0xFFF0EBFF),
  ];

  static const List<Color> _heatLight = [
    Color(0xFFE6EAF3),
    Color(0xFFC9C6F5),
    Color(0xFFA9A3EF),
    Color(0xFF8779E6),
    Color(0xFF5B4BE0),
  ];

  /// 深色档：逐条对应改造前的常量取值，渲染结果必须和 v1.0.19 完全一致。
  static const GlassPalette dark = GlassPalette(
    isLight: false,
    bgTop: Color(0xFF101B36),
    bgBottom: Color(0xFF18264D),
    blobIndigo: Color(0x664F46E5),
    blobPeriwinkle: Color(0x5A818CF8),
    blobSky: Color(0x4D38BDF8),
    blobViolet: Color(0x66A855F7),
    blobOrchid: Color(0x30E879F9),
    blobAqua: Color(0x402DD4BF),
    blobHighlight: Color(0x14DBEAFE),
    auroraGlow: Color(0xFFFFFFFF),
    auroraGlowAlpha: 26,
    auroraShade: Color(0xFF000000),
    auroraShadeAlpha: 30,
    glassTop: Color(0x0FFFFFFF),
    glassMid: Color(0x140A0A1E),
    glassBottom: Color(0x26000000),
    cardTop: Color(0x1FFFFFFF),
    cardBottom: Color(0x0AFFFFFF),
    cardBorder: Color(0x30FFFFFF),
    cardEdgeTop: Color(0x66FFFFFF),
    cardEdgeBottom: Color(0x14FFFFFF),
    shadow: Color(0x73000000),
    shadowSoft: Color(0x3D000000),
    tintTop: Color(0xFF7C8CFF),
    tintBottom: Color(0xFF5B3FE0),
    tintTopAlpha: 16,
    tintBottomAlpha: 8,
    glassEdgeColor: Color(0xFFFFFFFF),
    edgeAlpha: 66,
    shadeColor: Color(0xFF000000),
    shadeAlpha: 72,
    liftBase: Color(0xFF8062E0),
    liftAlpha: 90,
    rimTopLine: Color(0xD2FFFFFF),
    rimGlowTop: Color(0x22FFFFFF),
    rimBottomLine: Color(0x33000000),
    rimCornerGlow: Color(0x22FFFFFF),
    rimDiagonal: Color(0x1AFFFFFF),
    sheenGlare: Color(0xFFFFFFFF),
    sheenAlpha: 26,
    ink: Color(0xFFF3F6FC),
    inkSecondary: Color(0xD9FFFFFF),
    inkTertiary: Color(0xB3FFFFFF),
    decoInk: Color(0xFFFFFFFF),
    inkFaint: Color(0x4DFFFFFF),
    chipBg: Color(0x14FFFFFF),
    chipBorder: Color(0x26FFFFFF),
    fieldBg: Color(0x0FFFFFFF),
    fieldBorder: Color(0x2EFFFFFF),
    trackBg: Color(0x229FE8FF),
    opaqueControl: Color(0xFF2F3A6B),
    divider: Color(0x1FFFFFFF),
    gridLine: Color(0x14FFFFFF),
    disabledFg: Color(0x4DFFFFFF),
    surface: Color(0xFF161E30),
    menuText: Color(0xFFFFFFFF),
    menuTextFaint: Color(0xFF9CA3AF),
    menuDivider: Color(0x1FFFFFFF),
    tabBg: Color(0x14FFFFFF),
    tabBorder: Color(0x26FFFFFF),
    tabFg: Color(0xD9FFFFFF),
    tabActiveBg: Color(0xFF3B82F6),
    tabActiveFg: Color(0xFFFFFFFF),
    searchRing: Color(0xFF3B82F6),
    searchRingGlow: Color(0x293B82F6),
    overdueFg: Color(0xFFF87171),
    overdueBorder: Color(0x8CF87171),
    overdueFill: Color(0x1FF87171),
    urgencyNormal: Color(0xFF10B981),
    urgencyImportant: Color(0xFFEA6668),
    urgencyUrgent: Color(0xFFFAAD14),
    urgencyBgNormal: Color(0xFFECFDF5),
    urgencyBgImportant: Color(0xFFFEE2E2),
    urgencyBgUrgent: Color(0xFFFFF7E6),
    statusPlanned: Color(0xFF64748B),
    statusExecuting: Color(0xFF3B82F6),
    statusCompleted: Color(0xFF22C55E),
    repeatChipBg: Color(0x293B82F6),
    repeatChipBorder: Color(0x9960A5FA),
    repeatChipIcon: Color(0xFF93C5FD),
    repeatChipText: Color(0xFFBFDBFE),
    accentText: Color(0xFF60A5FA),
    successSoft: Color(0xFF6EE7B7),
    dangerSoft: Color(0xFFFCA5A5),
    accent: Color(0xFF3B82F6),
    accentSoft: Color(0xFF93C5FD),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    danger: Color(0xFFF87171),
    statsPrimary: Color(0xFF7B6CFF),
    statsPrimarySoft: Color(0xFFA99CFF),
    statsTeal: Color(0xFF4BE0C8),
    statsAmber: Color(0xFFFFB45C),
    statsPink: Color(0xFFFF6B8A),
    statsBlue: Color(0xFF5AA9FF),
    heatScale: _heatDark,
    memoPaperTop: Color(0x339DB4FF),
    memoPaperBottom: Color(0x147C6BFF),
  );

  /// 浅色档：不是把黑换白。层次靠「白雾卡片 + 冷灰描边 + 大范围低透明投影」
  /// 三件事拉开，色团反而提饱和、降 alpha，让颜色还能透过玻璃渗上来。
  static const GlassPalette light = GlassPalette(
    isLight: true,
    bgTop: Color(0xFFEEF2FB),
    bgBottom: Color(0xFFE2E9F7),
    blobIndigo: Color(0x6B6366E8),
    blobPeriwinkle: Color(0x6693A6F9),
    blobSky: Color(0x5C60C2FA),
    blobViolet: Color(0x4CA45CF8),
    blobOrchid: Color(0x42F08BFC),
    blobAqua: Color(0x4D2DD4BF),
    blobHighlight: Color(0x8CFFFFFF),
    auroraGlow: Color(0xFFFFFFFF),
    auroraGlowAlpha: 90,
    auroraShade: Color(0xFF172B54),
    auroraShadeAlpha: 26,
    glassTop: Color(0x40FFFFFF),
    glassMid: Color(0x38FFFFFF),
    glassBottom: Color(0x59FFFFFF),
    cardTop: Color(0xB8FFFFFF),
    cardBottom: Color(0x80FFFFFF),
    cardBorder: Color(0x6B96A6C4),
    cardEdgeTop: Color(0xF5FFFFFF),
    cardEdgeBottom: Color(0x42788AAA),
    shadow: Color(0x24172B54),
    shadowSoft: Color(0x14172B54),
    tintTop: Color(0xFFFFFFFF),
    tintBottom: Color(0xFFEAF0FB),
    tintTopAlpha: 210,
    tintBottomAlpha: 150,
    glassEdgeColor: Color(0xFF96A6C4),
    edgeAlpha: 108,
    shadeColor: Color(0xFFFFFFFF),
    shadeAlpha: 190,
    liftBase: Color(0xFFFFFFFF),
    liftAlpha: 205,
    rimTopLine: Color(0xFFFFFFFF),
    rimGlowTop: Color(0x50FFFFFF),
    rimBottomLine: Color(0x42788AAA),
    rimCornerGlow: Color(0x4CFFFFFF),
    rimDiagonal: Color(0x3CFFFFFF),
    sheenGlare: Color(0xFFE9F1FF),
    sheenAlpha: 120,
    ink: Color(0xFF14213D),
    inkSecondary: Color(0xC714213D),
    inkTertiary: Color(0x9414213D),
    decoInk: Color(0xFF14213D),
    inkFaint: Color(0x5C14213D),
    chipBg: Color(0xADFFFFFF),
    chipBorder: Color(0x6896A6C4),
    fieldBg: Color(0xCCFFFFFF),
    fieldBorder: Color(0x8096A6C4),
    trackBg: Color(0x387891BE),
    opaqueControl: Color(0xFFFFFFFF),
    divider: Color(0x1F14213D),
    gridLine: Color(0x14172B54),
    disabledFg: Color(0x5C14213D),
    surface: Color(0xFFFFFFFF),
    menuText: Color(0xFF14213D),
    menuTextFaint: Color(0x8C14213D),
    menuDivider: Color(0x1F14213D),
    tabBg: Color(0x9EFFFFFF),
    tabBorder: Color(0x5796A6C4),
    tabFg: Color(0xC714213D),
    tabActiveBg: Color(0xFF2563EB),
    tabActiveFg: Color(0xFFFFFFFF),
    searchRing: Color(0xFF2563EB),
    searchRingGlow: Color(0x1F2563EB),
    overdueFg: Color(0xFFDC2626),
    overdueBorder: Color(0x6BDC2626),
    overdueFill: Color(0x1FDC2626),
    urgencyNormal: Color(0xFF0E9F6E),
    urgencyImportant: Color(0xFFC43A55),
    urgencyUrgent: Color(0xFFC2711B),
    urgencyBgNormal: Color(0xFFE7F7F0),
    urgencyBgImportant: Color(0xFFFDECEE),
    urgencyBgUrgent: Color(0xFFFCF3E4),
    statusPlanned: Color(0xFF5B6B84),
    statusExecuting: Color(0xFF2563EB),
    statusCompleted: Color(0xFF0E9F6E),
    repeatChipBg: Color(0x1F2563EB),
    repeatChipBorder: Color(0x6B60A5FA),
    repeatChipIcon: Color(0xFF2563EB),
    repeatChipText: Color(0xFF1D4ED8),
    accentText: Color(0xFF2563EB),
    successSoft: Color(0xFF0E9F6E),
    dangerSoft: Color(0xFFDC2626),
    accent: Color(0xFF2563EB),
    accentSoft: Color(0xFF3B82F6),
    success: Color(0xFF0E9F6E),
    warning: Color(0xFFC2711B),
    danger: Color(0xFFDC2626),
    statsPrimary: Color(0xFF5B4BE0),
    statsPrimarySoft: Color(0xFF7B6CFF),
    statsTeal: Color(0xFF12A88E),
    statsAmber: Color(0xFFE08A2E),
    statsPink: Color(0xFFE44B6E),
    statsBlue: Color(0xFF2C86E8),
    heatScale: _heatLight,
    memoPaperTop: Color(0xE0F4F7FF),
    memoPaperBottom: Color(0xCCDFE6FF),
  );

  /// 从主题里取当前档令牌。取不到时回落深色：测试环境和未接主题的浮层
  /// （如原生气泡的 Flutter 侧）不该因此报错。
  static GlassPalette of(BuildContext context) =>
      Theme.of(context).extension<GlassPalette>() ?? dark;

  @override
  GlassPalette copyWith({bool? lerpTween}) => this;

  // 主题切换走 MaterialApp 的 themeMode，不做颜色插值：整窗是自定义绘制 +
  // 单次 backdrop blur，插值期间会出现半深半浅的糊色，直接切档更干净。
  @override
  ThemeExtension<GlassPalette> lerp(covariant GlassPalette? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';

void main() => runApp(const PlanetApp());

// ===================== Google Sheet 設定 =====================

const SHEET_ID = '1zLEO75SNjkLQO4LwA4xZoiy3yIHe_l2Msms-jWKr-74';

// 可按需要把新的分頁名加到各清單最前面
const PLANETS_SHEETS = ['星球價值'];
const TICKER_SHEETS  = ['戰爭與併購紀錄'];
const ASSETS_SHEETS  = ['各小保存資產'];
const PRODUCTION_SHEETS = ['每回合生產結果'];
const ORDERS_SHEETS  = ['星球訂購紀錄'];

// 新增：各紀錄分頁
const TECH_DEPLOY_SHEETS   = ['科技點部署紀錄'];
const WEAPON_DEPLOY_SHEETS = ['武器值部署紀錄'];
const MISSION_LOG_SHEETS   = ['任務紀錄'];
const CASINO_LOG_SHEETS    = ['賭場紀錄'];

// 生產表找不到「下回合/Next」欄時，退而使用 I 欄(含)之後
const int PRODUCTION_FALLBACK_FROM_COL = 8; // A=0, ..., I=8

// ===== 星系密碼（依指示互換 1↔2、3↔4、5↔6；原始只有 1~7） =====
const Map<String, String> TEAM_PASSWORDS = {
  '3840985028501834': '2',
  '9228832979541839': '1',
  '3927183277455893': '4',
  '7492283017398639': '3',
  '2968395073010185': '6',
  '5758297310578390': '5',
  '9630638484027291': '7',
};

// ============================================================

String buildCsvUrl(String sheetName) {
  final encoded = Uri.encodeQueryComponent(sheetName);
  return 'https://docs.google.com/spreadsheets/d/$SHEET_ID/gviz/tq?tqx=out:csv&sheet=$encoded';
}

Future<List<List<String>>> _fetchCsvByCandidates(List<String> sheetCandidates) async {
  Object? lastErr;
  for (final name in sheetCandidates) {
    try {
      final resp = await http.get(Uri.parse(buildCsvUrl(name)));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final csvRaw = const Utf8Decoder().convert(resp.bodyBytes);
      final list = const CsvToListConverter(eol: '\n').convert(csvRaw);
      if (list.isEmpty) throw Exception('CSV 為空 (sheet="$name")');
      return list.map((row) => row.map((e) => (e ?? '').toString().trim()).toList()).toList();
    } catch (e) {
      lastErr = e;
    }
  }
  throw Exception('所有候選分頁皆讀取失敗：${sheetCandidates.join(" / ")}，原因：$lastErr');
}

// 標頭正規化（小寫、移除空白與符號，保留中英文與數字）
String _normLabel(String s) {
  final lower = s.toLowerCase();
  final buf = StringBuffer();
  for (final r in lower.runes) {
    final c = String.fromCharCode(r);
    final isAsciiLetter = (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122);
    final isDigit = (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57);
    final isChinese = r >= 0x4E00 && r <= 0x9FFF;
    if (isAsciiLetter || isDigit || isChinese) buf.write(c);
  }
  return buf.toString();
}

int? _findIndexLike(List<String> headers, List<String> patterns) {
  final normHeaders = headers.map(_normLabel).toList();
  final normPatterns = patterns.map(_normLabel).toList();
  for (int i = 0; i < normHeaders.length; i++) {
    for (final p in normPatterns) {
      if (p.isEmpty) continue;
      if (normHeaders[i].contains(p)) return i;
    }
  }
  return null;
}

// ===================== App =====================

class PlanetApp extends StatelessWidget {
  const PlanetApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '星際爭BA戰',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6A7BFF)),
        useMaterial3: true,
      ),
      home: const PlanetPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class PlanetPage extends StatefulWidget {
  const PlanetPage({super.key});
  @override
  State<PlanetPage> createState() => _PlanetPageState();
}

class _PlanetPageState extends State<PlanetPage> {
  // 星球資料
  List<String> headers = [];
  List<List<String>> rows = [];
  bool loading = true;
  String? error;
  int? idxId, idxValue, idxOwner;

  // 公告
  String tickerSentence = '';

  // 星圖：目前篩選的星系（null = 全部）
  int? _galaxyFilter;

  // 資產頁登入的星系
  String? currentTeam;

  // 資產表
  List<String> assetHeaders = [];
  List<List<String>> assetRows = [];
  String? assetError;
  int? aIdxOwner, aIdxMoney, aIdxFood, aIdxWeapons, aIdxTech, aIdxEdu;

  // 生產表
  List<String> prodHeaders = [];
  List<List<String>> prodRows = [];
  String? prodError;
  int? pIdxOwner;

  // 星球 → 生產物資
  Map<String, String> planetProduction = {};
  String? ordersError;

  // 科技/武器/任務/賭場 紀錄
  List<String> techHeaders = [];
  List<List<String>> techRows = [];
  String? techError;

  List<String> weaponHeaders = [];
  List<List<String>> weaponRows = [];
  String? weaponError;

  List<String> missionHeaders = [];
  List<List<String>> missionRows = [];
  String? missionError;

  List<String> casinoHeaders = [];
  List<List<String>> casinoRows = [];
  String? casinoError;

  // 戰爭與併購紀錄（用於兩個抽屜）
  List<String> warHeaders = [];
  List<List<String>> warRows = [];
  String? warError;

  Timer? autoTimer;

  @override
  void initState() {
    super.initState();
    _refreshAll();
    autoTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshAll());
  }

  @override
  void dispose() {
    autoTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      fetchPlanets(),
      fetchTickerSentence(),
      fetchAssets(),
      fetchProduction(),
      fetchOrders(),
      fetchTechDeploy(),
      fetchWeaponDeploy(),
      fetchMissionLogs(),
      fetchCasinoLogs(),
      fetchWarLogs(),
    ]);
  }

  // ====== 讀取各資料 ======
  Future<void> fetchPlanets() async {
    setState(() { loading = true; error = null; });
    try {
      final list = await _fetchCsvByCandidates(PLANETS_SHEETS);
      final h = list.first;
      final r = list.skip(1).toList();

      idxId    = _findIndexLike(h, ['星球編號','planet','id']);
      idxValue = _findIndexLike(h, ['價值','value','score']);
      idxOwner = _findIndexLike(h, ['星系','小隊','team','system']);

      setState(() {
        headers  = h;
        rows     = r;
        idxId    = idxId ?? 0;
        loading  = false;
      });
    } catch (e) {
      setState(() { error = '讀取星球資料失敗：$e'; loading = false; });
    }
  }

  Future<void> fetchTickerSentence() async {
    try {
      final list = await _fetchCsvByCandidates(TICKER_SHEETS);
      final h = list.first;
      final rs = list.skip(1).toList();
      if (rs.isEmpty) { setState(() => tickerSentence = ''); return; }

      final idxInitiator = _findIndexLike(h, ['發起','攻方','initiator','發起星系','攻擊方']);
      final idxType      = _findIndexLike(h, ['戰爭','併購','行動','type','戰爭1 併購2','戰爭1併購2']);
      final idxTarget    = _findIndexLike(h, ['原主','守方','target','原主星系','防守方']);
      final idxPlanet    = _findIndexLike(h, ['星球編號','planet','planet id']);
      final idxResult    = _findIndexLike(h, ['結果','outcome','result','勝負','結論']);

      List<String>? last;
      bool meaningful(List<String> r) {
        final hasType = (idxType != null && idxType! < r.length && r[idxType!].trim().isNotEmpty) || _guessTypeFromRow(r) != null;
        final hasSide = (idxInitiator != null && idxInitiator! < r.length && r[idxInitiator!].trim().isNotEmpty)
                     || (idxTarget != null && idxTarget! < r.length && r[idxTarget!].trim().isNotEmpty);
        final hasPlanet = idxPlanet != null && idxPlanet! < r.length && r[idxPlanet!].trim().isNotEmpty;
        return hasType && (hasSide || hasPlanet);
      }
      for (int i = rs.length - 1; i >= 0; i--) {
        if (meaningful(rs[i])) { last = rs[i]; break; }
      }
      if (last == null) { setState(() => tickerSentence = ''); return; }

      String safe(int? idx) => (idx == null || idx < 0 || idx >= last!.length) ? '' : last![idx].trim();

      final rawInitiator = safe(idxInitiator);
      final rawTarget    = safe(idxTarget);
      final rawPlanet    = safe(idxPlanet);
      final rawType      = safe(idxType);
      final rawResult    = safe(idxResult);

      final type = _normalizeType(rawType) ?? _guessTypeFromRow(last) ?? '行動';
      final verb = (type == '戰爭') ? '發動戰爭' : (type == '併購') ? '提出併購' : '發起行動';

      final initiator = _fmtGalaxy(rawInitiator);
      final target    = _fmtGalaxy(rawTarget);
      final planetId  = _fmtPlanetId(rawPlanet);
      final left  = initiator.isEmpty ? '某星系' : initiator;
      final right = target.isNotEmpty ? target : '對手星系';
      final ptext = planetId.isEmpty ? '目標星球' : '$planetId 號星球';
      final res   = rawResult.isEmpty ? '待定' : rawResult;

      final suffix = (type == '戰爭' || type == '併購') ? '（$type）' : '';
      setState(() => tickerSentence = '📣 $left 對 $right 之 $ptext $verb，結果：$res。$suffix');
    } catch (e) {
      setState(() => tickerSentence = '');
    }
  }

  String? _normalizeType(String s) {
    final t = s.trim().toLowerCase();
    if (t.isEmpty) return null;
    if (t == '1' || t == '1.0') return '戰爭';
    if (t == '2' || t == '2.0') return '併購';
    if (t.contains('戰')) return '戰爭';
    if (t.contains('併') || t.contains('m&a') || t.contains('acq') || t.contains('merge')) return '併購';
    return null;
  }

  String? _guessTypeFromRow(List<String> r) {
    for (final cell in r) {
      final t = _normalizeType(cell);
      if (t != null) return t;
    }
    return null;
  }

  Future<void> fetchAssets() async {
    try {
      final list = await _fetchCsvByCandidates(ASSETS_SHEETS);
      final h = list.first;
      final r = list.skip(1).toList();

      aIdxOwner   = _findIndexLike(h, ['星系','team','小隊','小隊編號','隊伍']);
      aIdxMoney   = _findIndexLike(h, ['金錢','money','資金','現金','金幣','gold']);
      aIdxFood    = _findIndexLike(h, ['糧食','food']);
      aIdxWeapons = _findIndexLike(h, ['武器','weapons','arms']);
      aIdxTech    = _findIndexLike(h, ['科技點','科技值','tech','science']);
      aIdxEdu     = _findIndexLike(h, ['教育值','education','edu']);

      setState(() {
        assetHeaders = h;
        assetRows = r;
        assetError = null;
      });
    } catch (e) {
      setState(() {
        assetError = '讀取資產表失敗：$e';
        assetHeaders = [];
        assetRows = [];
      });
    }
  }

  Future<void> fetchProduction() async {
    try {
      final list = await _fetchCsvByCandidates(PRODUCTION_SHEETS);
      final h = list.first;
      final r = list.skip(1).toList();
      pIdxOwner = _findIndexLike(h, ['星系','team','小隊','小隊編號','隊伍']);
      setState(() {
        prodHeaders = h;
        prodRows    = r;
        prodError   = null;
      });
    } catch (e) {
      setState(() {
        prodError   = '讀取生產表失敗：$e';
        prodHeaders = [];
        prodRows    = [];
      });
    }
  }

  Future<void> fetchOrders() async {
    try {
      final list = await _fetchCsvByCandidates(ORDERS_SHEETS);
      final h = list.first;
      final r = list.skip(1).toList();

      final idxPid  = _findIndexLike(h, ['星球編號','planet','planetid','編號']);
      final idxKind = _findIndexLike(h, ['星球種類','個星球種類','各星球種類','種類','類型','type','生產物資','產出']);
      final map = <String, String>{};

      if (idxPid != null && idxKind != null) {
        for (final row in r) {
          if (idxPid < row.length && idxKind < row.length) {
            final id = _fmtPlanetId(row[idxPid]);
            final kind = row[idxKind].trim();
            if (id.isNotEmpty && kind.isNotEmpty) map[id] = kind;
          }
        }
      }
      setState(() {
        planetProduction = map;
        ordersError = null;
      });
    } catch (e) {
      setState(() {
        planetProduction = {};
        ordersError = '讀取星球訂購紀錄失敗：$e';
      });
    }
  }

  // ====== 新增：各紀錄表 ======
  Future<void> fetchTechDeploy() async {
    try {
      final list = await _fetchCsvByCandidates(TECH_DEPLOY_SHEETS);
      setState(() {
        techHeaders = list.first;
        techRows    = list.skip(1).toList();
        techError   = null;
      });
    } catch (e) {
      setState(() { techHeaders = []; techRows = []; techError = '讀取科技點部署紀錄失敗：$e'; });
    }
  }

  Future<void> fetchWeaponDeploy() async {
    try {
      final list = await _fetchCsvByCandidates(WEAPON_DEPLOY_SHEETS);
      setState(() {
        weaponHeaders = list.first;
        weaponRows    = list.skip(1).toList();
        weaponError   = null;
      });
    } catch (e) {
      setState(() { weaponHeaders = []; weaponRows = []; weaponError = '讀取武器值部署紀錄失敗：$e'; });
    }
  }

  Future<void> fetchMissionLogs() async {
    try {
      final list = await _fetchCsvByCandidates(MISSION_LOG_SHEETS);
      setState(() {
        missionHeaders = list.first;
        missionRows    = list.skip(1).toList();
        missionError   = null;
      });
    } catch (e) {
      setState(() { missionHeaders = []; missionRows = []; missionError = '讀取任務紀錄失敗：$e'; });
    }
  }

  Future<void> fetchCasinoLogs() async {
    try {
      final list = await _fetchCsvByCandidates(CASINO_LOG_SHEETS);
      setState(() {
        casinoHeaders = list.first;
        casinoRows    = list.skip(1).toList();
        casinoError   = null;
      });
    } catch (e) {
      setState(() { casinoHeaders = []; casinoRows = []; casinoError = '讀取賭場紀錄失敗：$e'; });
    }
  }

  Future<void> fetchWarLogs() async {
    try {
      final list = await _fetchCsvByCandidates(TICKER_SHEETS);
      setState(() {
        warHeaders = list.first;
        warRows    = list.skip(1).toList();
        warError   = null;
      });
    } catch (e) {
      setState(() { warHeaders = []; warRows = []; warError = '讀取戰爭與併購紀錄失敗：$e'; });
    }
  }

  // ===== UI建構 =====

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('星際爭BA戰'),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshAll, tooltip: '同步'),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(36 + kTextTabBarHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TickerBanner(
                  height: 36,
                  speed: 90,
                  showTopDivider: false,
                  showBottomDivider: true,
                  messages: [
                    TextSpan(
                      text: tickerSentence.isEmpty
                          ? '📢 尚無公告或公告資料格式不符。'
                          : tickerSentence,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.public),  text: '星圖'),
                    Tab(icon: Icon(Icons.savings), text: '資產'),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: TabBarView(
          children: [
            _buildGalaxyTab(),
            _buildAssetsTab(),
          ],
        ),
      ),
    );
  }

  // ========= 星圖 =========
  Widget _buildGalaxyTab() {
    if (loading) return const LinearProgressIndicator().paddingAll(16);
    if (error != null) {
      return Center(child: Text(error!, style: const TextStyle(color: Colors.red)));
    }

    // 篩選按鈕列（可橫向捲動）
    final filters = <int?>[null, 1, 2, 3, 4, 5, 6, 7]; // null = 全部
    final filterLabels = <int?, String>{
      null: '全部', 1: '第1星系', 2: '第2星系', 3: '第3星系', 4: '第4星系',
      5: '第5星系', 6: '第6星系', 7: '第7星系',
    };

    // 依篩選過濾星球
    final all = planets;
    final items = (_galaxyFilter == null)
        ? all
        : all.where((p) => _ownerAsInt(p.owner) == _galaxyFilter).toList();

    return Column(
      children: [
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: filters.map((f) {
                final selected = _galaxyFilter == f;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(filterLabels[f]!, style: const TextStyle(fontWeight: FontWeight.w600)),
                    selected: selected,
                    onSelected: (_) => setState(() => _galaxyFilter = f),
                    selectedColor: Theme.of(context).colorScheme.primaryContainer,
                    showCheckmark: false,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final width = c.maxWidth;
              final cross = (width ~/ 92).clamp(3, 20);

              // 為了大小依價值而變化
              double minV = double.infinity, maxV = -double.infinity;
              for (final p in items) {
                if (p.value != null) {
                  minV = math.min(minV, p.value!);
                  maxV = math.max(maxV, p.value!);
                }
              }
              if (minV == double.infinity) { minV = 0; maxV = 0; }

              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cross,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final p = items[i];
                  final color = _colorForGalaxy(p.owner);

                  double size = 48;
                  if (p.value != null && maxV > minV) {
                    final t = ((p.value! - minV) / (maxV - minV)).clamp(0, 1);
                    size = 40 + t * 28; // 40~68
                  }

                  return PlanetDot(
                    planet: p,
                    color: color,
                    diameter: size,
                    onTap: () => _showPlanetSheet(context, p, color),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // 將 owner 文字轉成星系數字（1~7），失敗回 null
  int? _ownerAsInt(String owner) {
    var s = owner.trim();
    s = s.replaceAll(RegExp(r'\s+'), '');
    s = s.replaceAll('星系', '');
    s = s.replaceAll(RegExp(r'^第'), '');
    s = s.replaceAll(RegExp(r'\.0+$'), '');
    final n = int.tryParse(s);
    if (n == null) return null;
    if (n < 1 || n > 7) return null;
    return n;
  }

  // 點擊星球顯示資訊
  void _showPlanetSheet(BuildContext context, Planet p, Color color) {
    // 計算各星系擁有的星球數
    final ownerIdx = idxOwner;
    final Map<String, int> counts = {};
    if (ownerIdx != null) {
      for (final r in rows) {
        if (ownerIdx < r.length) {
          final o = r[ownerIdx].trim();
          if (o.isEmpty) continue;
          counts[o] = (counts[o] ?? 0) + 1;
        }
      }
    }

    final team = p.owner.trim();
    final teamCount = counts[team] ?? 0;

    // dense rank（以星球數）
    int teamRank = 0;
    if (counts.isNotEmpty && team.isNotEmpty) {
      final entries = counts.entries.toList()
        ..sort((a, b) {
          final c = b.value.compareTo(a.value);
          if (c != 0) return c;
          return a.key.compareTo(b.key);
        });
      int currentRank = 0;
      int? lastValue;
      for (final e in entries) {
        if (lastValue == null || e.value != lastValue) {
          currentRank += 1;
          lastValue = e.value;
        }
        if (e.key == team) {
          teamRank = currentRank;
          break;
        }
      }
    }

    // 生產物資
    final produce = planetProduction[p.id]?.trim();
    final produceText = (produce == null || produce.isEmpty) ? '-' : produce;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 16, height: 16,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(p.id, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (p.value != null)
                    Chip(label: Text('價值 ${_pretty(p.value!)}')),
                ],
              ),
              const SizedBox(height: 12),
              // 刪掉「星球編號」與「星球價值」卡片
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _InfoCard(title: '生產物資', value: produceText),
                  _InfoCard(title: '所屬星系', value: team.isEmpty ? '-' : team),
                  _InfoCard(title: '星系星球數', value: teamCount.toString()),
                  _InfoCard(title: '星系名次', value: teamRank == 0 ? '-' : '#$teamRank'),
                ],
              ),
              const SizedBox(height: 8),
              if (ordersError != null) Text(ordersError!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        );
      },
    );
  }

  // ========= 資產 =========
  Widget _buildAssetsTab() {
    // 未登入
    if (currentTeam == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('請輸入密碼以查看你的星系資產', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 12),
                _PasswordInput(
                  onSubmit: (pw) {
                    final team = TEAM_PASSWORDS[pw.trim()];
                    if (team != null) {
                      setState(() => currentTeam = team);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('密碼錯誤')),
                      );
                    }
                  },
                ),
                if (assetError != null) ...[
                  const SizedBox(height: 12),
                  Text(assetError!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      );
    }

    // 已登入
    final team = currentTeam!;
    final teamAssets = _assetsForTeam(team);

    if (teamAssets == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            children: [
              Text('找不到「$team」在資產分頁的資料', style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => setState(() => currentTeam = null),
                icon: const Icon(Icons.logout),
                label: const Text('切換星系'),
              ),
            ],
          ),
        ),
      );
    }

    final color = _colorForGalaxy(team);

    // 各表只顯示「當前登入星系」，且移除小隊欄位
    final filteredTech    = _filterRowsByTeam(techHeaders,    techRows,    team);
    final filteredWeapon  = _filterRowsByTeam(weaponHeaders,  weaponRows,  team);
    final filteredMission = _filterRowsByTeam(missionHeaders, missionRows, team);
    final filteredCasino  = _filterRowsByTeam(casinoHeaders,  casinoRows,  team);

    // 戰爭與併購：主動（發起方==team）、被動（原主/守方==team）
    final warIdxInitiator = _teamLikeIndex(warHeaders, initiatorLike: true);
    final warIdxTarget    = _teamLikeIndex(warHeaders, initiatorLike: false);
    final warInitiated = (warIdxInitiator == null) ? <List<String>>[] :
      warRows.where((r) => warIdxInitiator < r.length && _sameTeam(r[warIdxInitiator], team)).toList();
    final warTargeted = (warIdxTarget == null) ? <List<String>>[] :
      warRows.where((r) => warIdxTarget < r.length && _sameTeam(r[warIdxTarget], team)).toList();

    // 要移除的「小隊欄位」索引（表格內若存在）
    final removeTeamColsFromTech    = _collectTeamColumns(techHeaders);
    final removeTeamColsFromWeapon  = _collectTeamColumns(weaponHeaders);
    final removeTeamColsFromMission = _collectTeamColumns(missionHeaders);
    final removeTeamColsFromCasino  = _collectTeamColumns(casinoHeaders);

    // 戰爭表：同時把發起/原主這些欄位也移除（避免重複露出小隊編號）
    final removeColsFromWar = _collectTeamColumns(warHeaders);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text('星系：$team', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(() => currentTeam = null),
              icon: const Icon(Icons.logout),
              label: const Text('切換星系'),
            ),
          ]),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12, runSpacing: 12,
            children: [
              _StatCard(title: '金錢',   value: _pretty(teamAssets.money)),
              _StatCard(title: '糧食',   value: _pretty(teamAssets.food)),
              _StatCard(title: '武器',   value: _pretty(teamAssets.weapons)),
              _StatCard(title: '科技點', value: _pretty(teamAssets.tech)),
              _StatCard(title: '教育值', value: _pretty(teamAssets.edu)),
            ],
          ),
          const SizedBox(height: 16),

          if (prodError != null) Text(prodError!, style: const TextStyle(color: Colors.red)),
          if (prodHeaders.isNotEmpty)
            Material(
              elevation: 1,
              borderRadius: BorderRadius.circular(12),
              child: ExpansionTile(
                initiallyExpanded: false,
                title: const Text('本階段生產'),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: () {
                  final map = _productionForTeam(team);
                  if (map == null) {
                    return const [Padding(padding: EdgeInsets.only(bottom: 12), child: Text('無生產資料'))];
                  }
                  // 固定五個產品橫向：金錢、糧食、武器、科技點、教育值
                  const keys = ['金錢', '糧食', '武器', '科技點', '教育值'];
                  final cells = keys.map((k) => map[k]?.trim().isNotEmpty == true ? map[k]! : '-').toList();

                  return [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: keys.map((k) => DataColumn(label: Text(k))).toList(),
                        rows: [
                          DataRow(cells: cells.map((v) => DataCell(Text(v))).toList()),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ];
                }(),
              ),
            ),

          const SizedBox(height: 16),

          // 科技點部署紀錄
          if (techError != null) Text(techError!, style: const TextStyle(color: Colors.red)),
          if (techHeaders.isNotEmpty)
            _buildLogPanel(
              title: '科技點部署紀錄',
              headers: techHeaders,
              rows: filteredTech,
              removeColIdxs: removeTeamColsFromTech,
            ),

          const SizedBox(height: 16),

          // 武器值部署紀錄
          if (weaponError != null) Text(weaponError!, style: const TextStyle(color: Colors.red)),
          if (weaponHeaders.isNotEmpty)
            _buildLogPanel(
              title: '武器值部署紀錄',
              headers: weaponHeaders,
              rows: filteredWeapon,
              removeColIdxs: removeTeamColsFromWeapon,
            ),

          const SizedBox(height: 16),

          // 任務紀錄
          if (missionError != null) Text(missionError!, style: const TextStyle(color: Colors.red)),
          if (missionHeaders.isNotEmpty)
            _buildLogPanel(
              title: '任務紀錄',
              headers: missionHeaders,
              rows: filteredMission,
              removeColIdxs: removeTeamColsFromMission,
            ),

          const SizedBox(height: 16),

          // 賭場紀錄
          if (casinoError != null) Text(casinoError!, style: const TextStyle(color: Colors.red)),
          if (casinoHeaders.isNotEmpty)
            _buildLogPanel(
              title: '賭場紀錄',
              headers: casinoHeaders,
              rows: filteredCasino,
              removeColIdxs: removeTeamColsFromCasino,
            ),

          const SizedBox(height: 16),

          // 戰爭與併購紀錄（主動）
          if (warError != null) Text(warError!, style: const TextStyle(color: Colors.red)),
          if (warHeaders.isNotEmpty)
            _buildLogPanel(
              title: '戰爭與併購紀錄（主動）',
              headers: warHeaders,
              rows: warInitiated,
              removeColIdxs: removeColsFromWar,
            ),

          const SizedBox(height: 16),

          // 被戰爭與併購紀錄（被動）
          if (warHeaders.isNotEmpty)
            _buildLogPanel(
              title: '被戰爭與併購紀錄（被動）',
              headers: warHeaders,
              rows: warTargeted,
              removeColIdxs: removeColsFromWar,
            ),
        ],
      ),
    );
  }

  // ===== 資料工具 =====

  List<Planet> get planets {
    if (idxId == null) return [];
    final idI = idxId!;
    final ownI = idxOwner;
    final valI = idxValue;

    return rows.map((r) {
      final id = idI < r.length ? _fmtPlanetId(r[idI]) : '';
      final owner = (ownI != null && ownI < r.length) ? r[ownI] : '';
      double? value;
      if (valI != null && valI < r.length) {
        final raw = r[valI].replaceAll(',', '');
        value = double.tryParse(raw);
      }
      return Planet(id: id, owner: owner, value: value, raw: r);
    }).where((p) => p.id.isNotEmpty).toList();
  }

  TeamAssets? _assetsForTeam(String team) {
    if (assetRows.isEmpty || aIdxOwner == null) return null;
    List<String>? row;
    for (final r in assetRows) {
      if (aIdxOwner! < r.length && _sameTeam(r[aIdxOwner!], team)) { row = r; break; }
    }
    if (row == null) return null;

    double parseNum(int? idx) {
      if (idx == null || idx >= row!.length) return 0;
      final s = row![idx].replaceAll(',', '').trim();
      return double.tryParse(s) ?? 0;
    }

    return TeamAssets(
      team: team,
      money:   parseNum(aIdxMoney),
      food:    parseNum(aIdxFood),
      weapons: parseNum(aIdxWeapons),
      tech:    parseNum(aIdxTech),
      edu:     parseNum(aIdxEdu),
      raw: row!,
    );
  }

  /// 取得某星系的「下回合/本階段生產」欄位（key=顯示名, value=數值）
  Map<String, String>? _productionForTeam(String team) {
    if (prodRows.isEmpty || pIdxOwner == null) return null;

    List<String>? row;
    for (final r in prodRows) {
      if (pIdxOwner! < r.length && _sameTeam(r[pIdxOwner!], team)) { row = r; break; }
    }
    if (row == null) return null;

    final Map<String, String> nextOnly = {};
    for (int i = 0; i < prodHeaders.length; i++) {
      final key = prodHeaders[i];
      if (key.isEmpty) continue;
      final lowerKey = key.toLowerCase();
      if (key.contains('星系') || key.contains('小隊') || lowerKey.contains('team')) continue;

      final hit = key.contains('下回合') || key.contains('下輪') ||
                  lowerKey.contains('next') || lowerKey.contains('nextturn') || lowerKey.contains('next turn');
      if (hit) {
        final val = i < row.length ? row[i].toString().trim() : '';
        if (val.isNotEmpty) nextOnly[_beautifyProdTitle(key)] = val;
      }
    }
    if (nextOnly.isNotEmpty) return nextOnly;

    final Map<String, String> all = {};
    for (int i = 0; i < prodHeaders.length; i++) {
      if (i < PRODUCTION_FALLBACK_FROM_COL) continue;
      final key = prodHeaders[i];
      if (key.isEmpty) continue;
      final lowerKey = key.toLowerCase();
      if (key.contains('星系') || key.contains('小隊') || lowerKey.contains('team')) continue;

      final val = i < row.length ? row[i].toString().trim() : '';
      if (val.isEmpty) continue;

      all[_beautifyProdTitle(key)] = val;
    }
    return all.isEmpty ? null : all;
  }

  String _beautifyProdTitle(String key) {
    String k = key.replaceAll(RegExp(r'\s+'), '');
    k = k.replaceAll(RegExp(r'^(下回合|下輪|NextTurn|Next)', caseSensitive: false), '');
    if (k.contains('糧食數目')) return '糧食';
    if (k.contains('金礦數目') || k.contains('金幣')) return '金錢';
    if (k.contains('武器數目')) return '武器';
    if (k.contains('科技數目')) return '科技點';
    if (k.contains('教育數目')) return '教育值';
    if (k == '糧食' || k == '金錢' || k == '武器' || k == '科技點' || k == '教育值') return k;
    return k;
  }

  // ======= 篩選與欄位移除工具 =======

  // 找出小隊欄位的 index（科技/武器/任務/賭場用）
  int? _teamColumnIndex(List<String> headers) {
    return _findIndexLike(headers, ['星系','team','小隊','小隊編號','隊伍','隊伍編號']);
  }

  // 找出戰爭表的「發起」或「原主」欄 index
  int? _teamLikeIndex(List<String> headers, {required bool initiatorLike}) {
    return initiatorLike
      ? _findIndexLike(headers, ['發起','攻方','initiator','發起星系','攻擊方'])
      : _findIndexLike(headers, ['原主','守方','target','原主星系','防守方']);
  }

  // 規格化 team 值（把「第」「星系」與小數 .0 去掉）
  String _normTeamText(String v) {
    var s = v.trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'\s+'), '');
    s = s.replaceAll('星系', '');
    s = s.replaceAll(RegExp(r'^第'), '');
    s = s.replaceAll(RegExp(r'\.0+$'), '');
    return s;
  }

  bool _sameTeam(String cell, String team) => _normTeamText(cell) == _normTeamText(team);

  // 只保留當前登入星系的列
  List<List<String>> _filterRowsByTeam(List<String> headers, List<List<String>> rows, String team) {
    if (headers.isEmpty || rows.isEmpty) return const [];
    final idx = _teamColumnIndex(headers);
    if (idx == null) return const [];
    return rows.where((r) => idx < r.length && _sameTeam(r[idx], team)).toList();
  }

  // 收集要移除的「小隊欄位」index（包含一般 Team 欄與戰爭表的發起/原主欄）
  Set<int> _collectTeamColumns(List<String> headers) {
    final set = <int>{};
    final a = _teamColumnIndex(headers);
    if (a != null) set.add(a);
    final b = _teamLikeIndex(headers, initiatorLike: true);
    if (b != null) set.add(b);
    final c = _teamLikeIndex(headers, initiatorLike: false);
    if (c != null) set.add(c);
    return set;
  }

  // 生成紀錄抽屜（DataTable），並移除指定欄位
  Widget _buildLogPanel({
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
    Set<int> removeColIdxs = const {},
  }) {
    // 建立保留欄位索引清單（從 0..n-1 移除 removeColIdxs）
    final keptIdxs = <int>[];
    for (int i = 0; i < headers.length; i++) {
      if (!removeColIdxs.contains(i)) keptIdxs.add(i);
    }

    return Material(
      elevation: 1,
      borderRadius: BorderRadius.circular(12),
      child: ExpansionTile(
        initiallyExpanded: false,
        title: Text(title),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('目前沒有資料'),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: keptIdxs.map((i) => DataColumn(label: Text(headers[i]))).toList(),
                rows: rows.map((r) => DataRow(
                  cells: keptIdxs.map((i) => DataCell(Text(i < r.length ? r[i] : ''))).toList(),
                )).toList(),
              ),
            ),
        ],
      ),
    );
  }

  // ===== 小工具 =====
  String _fmtGalaxy(String v) {
    var s = v.trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'\s+'), '');
    s = s.replaceAll('星系', '');
    s = s.replaceAll(RegExp(r'^第'), '');
    s = s.replaceAll(RegExp(r'\.0+$'), '');
    return '第$s 星系';
  }

  String _fmtPlanetId(String v) {
    var s = v.trim();
    if (s.isEmpty) return '';
    if (RegExp(r'^\d+(\.0+)?$').hasMatch(s)) s = s.replaceAll(RegExp(r'\.0+$'), '');
    return s;
  }

  Color _colorForGalaxy(String owner) {
    var s = owner.trim();
    s = s.replaceAll(RegExp(r'\s+'), '');
    s = s.replaceAll('星系', '');
    s = s.replaceAll(RegExp(r'^第'), '');
    s = s.replaceAll(RegExp(r'\.0+$'), '');
    final n = int.tryParse(s);
    if (n != null && n >= 1 && n <= 7) {
      const palette = <Color>[
        Colors.red,    // 1
        Colors.purple, // 2
        Colors.green,  // 3
        Colors.pink,   // 4
        Colors.yellow, // 5
        Colors.blue,   // 6
        Colors.brown,  // 7
      ];
      return palette[n - 1];
    }
    return Colors.grey.shade400;
  }

  static String _pretty(double v) {
    if (v >= 1000000) return '${(v/1000000).toStringAsFixed(2)}M';
    if (v >= 1000)    return '${(v/1000).toStringAsFixed(2)}k';
    return v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
  }
}

// ===== 小型 UI 元件 =====
// 統一卡片縮放：寬度再縮小 20%
const double cardWidthFactor = 0.8;
const double cardHeightFactor = 0.9;

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  const _StatCard({required this.title, required this.value});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: SizedBox(
        width: 180 * cardWidthFactor,
        height: 88 * cardHeightFactor,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: Theme.of(context).hintColor)),
              const Spacer(),
              Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PasswordInput extends StatefulWidget {
  final void Function(String) onSubmit;
  const _PasswordInput({required this.onSubmit});
  @override
  State<_PasswordInput> createState() => _PasswordInputState();
}
class _PasswordInputState extends State<_PasswordInput> {
  final _controller = TextEditingController();
  bool _obscure = true;
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      obscureText: _obscure,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: '密碼',
        suffixIcon: IconButton(
          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
      onSubmitted: widget.onSubmit,
    );
  }
}

class Planet {
  final String id;
  final String owner;
  final double? value;
  final List<String> raw;
  const Planet({required this.id, required this.owner, required this.value, required this.raw});
}

class TeamAssets {
  final String team;
  final double money;
  final double food;
  final double weapons;
  final double tech;
  final double edu;
  final List<String> raw;
  const TeamAssets({
    required this.team,
    required this.money,
    required this.food,
    required this.weapons,
    required this.tech,
    required this.edu,
    required this.raw,
  });
}

class PlanetDot extends StatelessWidget {
  final Planet planet;
  final Color color;
  final double diameter;
  final VoidCallback onTap;
  const PlanetDot({required this.planet, required this.color, required this.diameter, required this.onTap, super.key});

  Color _onColor(Color bg) => bg.computeLuminance() > 0.5 ? Colors.black : Colors.white;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Center(
          child: Container(
            width: diameter,
            height: diameter,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: const [BoxShadow(blurRadius: 8, offset: Offset(0,2), color: Colors.black26)],
              border: Border.all(color: Colors.white, width: 2),
            ),
            padding: const EdgeInsets.all(6),
            child: FittedBox(
              child: Text(
                planet.id,
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700, color: _onColor(color)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final String value;
  final double width;
  final double height;

  const _InfoCard({
    super.key,
    required this.title,
    required this.value,
    this.width = 180 * cardWidthFactor,   // 只縮寬 20%
    this.height = 88 * cardHeightFactor,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: hint)),
              const Spacer(),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== 跑馬燈（無底色、細線分隔） =====
class TickerBanner extends StatefulWidget implements PreferredSizeWidget {
  final List<InlineSpan> messages;
  final double height;
  final double gap;
  final double speed;
  final EdgeInsets padding;
  final bool pauseOnHover;
  final bool pauseOnLongPress;
  final bool showTopDivider;
  final bool showBottomDivider;
  final double dividerThickness;
  final Color? dividerColor;

  const TickerBanner({
    super.key,
    required this.messages,
    this.height = 36,
    this.gap = 48,
    this.speed = 80,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.pauseOnHover = true,
    this.pauseOnLongPress = true,
    this.showTopDivider = false,
    this.showBottomDivider = true,
    this.dividerThickness = 1,
    this.dividerColor,
  });

  @override
  State<TickerBanner> createState() => _TickerBannerState();
  @override
  Size get preferredSize => Size.fromHeight(height);
}

class _TickerBannerState extends State<TickerBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _offset = 0;
  bool _paused = false;

  final GlobalKey _measureKey = GlobalKey();
  double _contentWidth = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        if (!_paused && _contentWidth > 0) {
          setState(() {
            _offset -= widget.speed / 60; // ~60fps
            if (_offset.abs() > _contentWidth + widget.gap) {
              _offset += _contentWidth + widget.gap; // 無縫循環
            }
          });
        }
      });
    _ctrl.repeat(min: 0, max: 1, period: const Duration(milliseconds: 16));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _setPaused(bool v) { if (v != _paused) setState(() => _paused = v); }

  @override
  Widget build(BuildContext context) {
    final dividerColor =
        widget.dividerColor ?? Theme.of(context).dividerColor.withOpacity(0.6);

    final content = Row(
      key: _measureKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        _TickerChunk(messages: widget.messages),
        SizedBox(width: widget.gap),
        _TickerChunk(messages: widget.messages),
      ],
    );

    Widget body = Container(
      height: widget.height,
      padding: widget.padding,
      decoration: BoxDecoration(
        border: Border(
          top: widget.showTopDivider
              ? BorderSide(color: dividerColor, width: widget.dividerThickness)
              : BorderSide.none,
          bottom: widget.showBottomDivider
              ? BorderSide(color: dividerColor, width: widget.dividerThickness)
              : BorderSide.none,
        ),
      ),
      child: LayoutBuilder(
        builder: (ctx, cons) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final render = _measureKey.currentContext?.findRenderObject();
            if (render is RenderBox) {
              final total = render.size.width;
              final single = (total - widget.gap) / 2;
              if ((single - _contentWidth).abs() > 0.5) {
                setState(() => _contentWidth = single);
              }
            }
          });

          return ClipRect(
            child: Stack(
              children: [
                Transform.translate(offset: Offset(_offset, 0), child: content),
              ],
            ),
          );
        },
      ),
    );

    if (widget.pauseOnHover) {
      body = MouseRegion(onEnter: (_) => _setPaused(true), onExit: (_) => _setPaused(false), child: body);
    }
    if (widget.pauseOnLongPress) {
      body = GestureDetector(onLongPressStart: (_) => _setPaused(true), onLongPressEnd: (_) => _setPaused(false), child: body);
    }
    return body;
  }
}

class _TickerChunk extends StatelessWidget {
  final List<InlineSpan> messages;
  const _TickerChunk({required this.messages});

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(fontSize: 14);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(messages.length, (i) {
        final span = messages[i];
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(text: TextSpan(style: baseStyle, children: [span])),
            if (i != messages.length - 1) const SizedBox(width: 24),
          ],
        );
      }),
    );
  }
}

// 小工具：語法糖
extension on Widget {
  Widget paddingAll(double v) => Padding(padding: EdgeInsets.all(v), child: this);
}

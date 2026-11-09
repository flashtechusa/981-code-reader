import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/session.dart';
import '../app/settings.dart';
import '../core/obd_pids.dart';
import 'theme.dart';

/// Live OBD-II Mode 01 data from the DME: gauges, table, scrolling graph.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final Session _session;

  /// PIDs drawn on the graph (subset of enabled PIDs).
  final Set<int> _graphPids = {0x0C, 0x05, 0x11};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _session = context.read<Session>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_session.connected && !_session.liveRunning) _session.startLive();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    // Leaving the dashboard stops the Mode 01 poll so other tiles can run.
    scheduleMicrotask(_session.stopLive);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: s.liveRunning ? 'Pause' : 'Resume',
            icon: Icon(s.liveRunning ? Icons.pause : Icons.play_arrow),
            onPressed: !s.connected
                ? null
                : () => s.liveRunning ? s.stopLive() : s.startLive(),
          ),
          IconButton(
            tooltip: 'Clear history',
            icon: const Icon(Icons.clear_all),
            onPressed: s.clearSamples,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.accent,
          labelColor: AppColors.text,
          unselectedLabelColor: AppColors.textDim,
          tabs: const [
            Tab(text: 'Gauges'),
            Tab(text: 'Table'),
            Tab(text: 'Graph'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _GaugesView(latest: s.latest),
          _TableView(session: s),
          _GraphView(
            session: s,
            graphPids: _graphPids,
            onToggle: (pid, on) => setState(() {
              if (on) {
                _graphPids.add(pid);
              } else {
                _graphPids.remove(pid);
              }
            }),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _GaugesView extends StatelessWidget {
  const _GaugesView({required this.latest});
  final Map<int, double> latest;

  @override
  Widget build(BuildContext context) {
    final shown = livePids;
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.15,
      ),
      itemCount: shown.length,
      itemBuilder: (_, i) {
        final p = shown[i];
        return _Gauge(pid: p, value: latest[p.pid]);
      },
    );
  }
}

class _Gauge extends StatelessWidget {
  const _Gauge({required this.pid, required this.value});
  final ObdPid pid;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final units = context.watch<Settings>().units;
    final v = value;
    final frac = v == null
        ? 0.0
        : ((v - pid.min) / (pid.max - pid.min)).clamp(0.0, 1.0).toDouble();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.tile,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Text(pid.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textDim, fontSize: 12)),
          Expanded(
            child: CustomPaint(
              painter: _ArcPainter(frac, v == null),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    v == null ? '--' : units.format(pid, v),
                    style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
              ),
            ),
          ),
          Text(units.label(pid),
              style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.frac, this.empty);
  final double frac;
  final bool empty;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 - 4;
    final c = Offset(size.width / 2, size.height / 2 + r * 0.25);
    const start = math.pi * 0.75;
    const sweep = math.pi * 1.5;
    final track = Paint()
      ..color = AppColors.pane
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep, false,
        track);
    if (!empty) {
      final fill = Paint()
        ..color = frac > 0.9 ? AppColors.warn : AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), start,
          sweep * frac, false, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.frac != frac || old.empty != empty;
}

// ---------------------------------------------------------------------------

class _TableView extends StatelessWidget {
  const _TableView({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final units = context.watch<Settings>().units;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final p in livePids)
          SwitchListTile(
            dense: true,
            value: s.enabledPids.contains(p.pid),
            onChanged: (on) => s.togglePid(p.pid, on),
            title: Text(p.name),
            subtitle: Text('PID 0x${p.hex}',
                style: monoStyle.copyWith(color: AppColors.textDim)),
            secondary: SizedBox(
              width: 92,
              child: Text(
                s.latest[p.pid] == null
                    ? '--'
                    : '${units.format(p, s.latest[p.pid]!)} ${units.label(p)}',
                textAlign: TextAlign.right,
                style: monoStyle.copyWith(
                    fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Polled from the DME at 0x7E0 (OBD-II Mode 01). '
            'Disable PIDs you do not need to raise the sample rate; '
            '${s.samples.length} samples buffered.',
            style: const TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

const List<Color> _seriesColors = [
  Color(0xFF4A90D9),
  Color(0xFFD9A54A),
  Color(0xFF7ED37E),
  Color(0xFFD94A4A),
  Color(0xFFB07AD9),
  Color(0xFF4AD9C9),
  Color(0xFFD97A4A),
  Color(0xFF9AD94A),
  Color(0xFFD94AA5),
  Color(0xFF8899AA),
  Color(0xFFE8E8E8),
];

Color _colorFor(int pid) {
  final i = livePids.indexWhere((p) => p.pid == pid);
  return _seriesColors[(i < 0 ? 0 : i) % _seriesColors.length];
}

class _GraphView extends StatelessWidget {
  const _GraphView({
    required this.session,
    required this.graphPids,
    required this.onToggle,
  });
  final Session session;
  final Set<int> graphPids;
  final void Function(int pid, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final samples = session.samples;
    const window = 300; // samples shown
    final start = samples.length > window ? samples.length - window : 0;
    final visible = samples.sublist(start);

    final bars = <LineChartBarData>[];
    for (final pid in graphPids) {
      final p = pidByNumber(pid);
      if (p == null) continue;
      final spots = <FlSpot>[];
      for (var i = 0; i < visible.length; i++) {
        final v = visible[i].values[pid];
        if (v == null) continue;
        // normalise each series to 0..100 so different units share one axis
        final n = ((v - p.min) / (p.max - p.min) * 100).clamp(0.0, 100.0);
        spots.add(FlSpot(i.toDouble(), n.toDouble()));
      }
      if (spots.isEmpty) continue;
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: false,
        color: _colorFor(pid),
        barWidth: 2,
        dotData: FlDotData(show: false),
      ));
    }

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: bars.isEmpty
                ? const Center(
                    child: Text('waiting for samples ...',
                        style: TextStyle(color: AppColors.textDim)),
                  )
                : LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: math.max(10, (visible.length - 1).toDouble()),
                      minY: 0,
                      maxY: 100,
                      lineBarsData: bars,
                      backgroundColor: AppColors.pane,
                      gridData: FlGridData(
                        show: true,
                        horizontalInterval: 25,
                        verticalInterval: 50,
                        getDrawingHorizontalLine: (_) =>
                            FlLine(color: AppColors.tile, strokeWidth: 1),
                        getDrawingVerticalLine: (_) =>
                            FlLine(color: AppColors.tile, strokeWidth: 1),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        leftTitles: const AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 32,
                            interval: 25,
                          ),
                        ),
                      ),
                      lineTouchData: LineTouchData(enabled: false),
                    ),
                    duration: Duration.zero,
                  ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Each series is scaled to 0-100 % of its own range. Tap a chip to toggle.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              for (final p in livePids)
                FilterChip(
                  selected: graphPids.contains(p.pid),
                  onSelected: (on) => onToggle(p.pid, on),
                  label: Text(
                    session.latest[p.pid] == null
                        ? p.shortName
                        : '${p.shortName} ${context.watch<Settings>().units.format(p, session.latest[p.pid]!)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  avatar: CircleAvatar(
                      backgroundColor: _colorFor(p.pid), radius: 5),
                  selectedColor: AppColors.tile,
                  backgroundColor: AppColors.pane,
                  showCheckmark: false,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

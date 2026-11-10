import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/session.dart';
import '../core/module.dart';
import 'dashboard_screen.dart';
import 'errors_screen.dart';
import 'log_screen.dart';
import 'settings_sheet.dart';
import 'theme.dart';
import 'vehicle_screen.dart';
import 'widgets/confirm_clear_sheet.dart';
import 'widgets/tile.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _hint(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _onVehicle(Session s) async {
    if (!s.connected) {
      _hint('Tap CONNECT first');
      return;
    }
    if (s.busy) {
      _hint('Still working ...');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const VehicleScreen()),
    );
    await s.scan();
    if (!mounted || !s.msScanOffered) return;
    await _offerMsScan(s);
  }

  /// FORScan-style second bus: ask the user to flip the adapter's HS/MS
  /// switch, scan MS-CAN, then ask them to flip it back.
  Future<void> _offerMsScan(Session s) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Scan MS-CAN too?'),
        content: const Text(
          'HS-CAN scan finished.\n\n'
          'Ford vehicles have a second bus (MS-CAN: cluster, HVAC, doors, '
          'audio ...). To scan it:\n\n'
          '1. Flip the switch on the adapter to MS-CAN.\n'
          '2. Tap Scan MS-CAN.\n\n'
          'Porsche and most other makes have no MS-CAN - tap Skip.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Switch is on MS - scan'),
          ),
        ],
      ),
    );
    if (go != true) {
      s.msScanOffered = false;
      return;
    }
    await s.scanMs();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Flip the switch back to HS-CAN'),
        content: const Text(
          'MS-CAN scan done. Set the adapter switch back to HS-CAN now - '
          'live data, the engine and airbag modules all live there.\n\n'
          'MS-CAN modules stay in the list; to re-read or clear one of them '
          'later the app will ask you to flip the switch again.',
        ),
        actions: [
          FilledButton(
            onPressed: () {
              s.setAdapterBus(CanBus.hs);
              Navigator.of(ctx).pop();
            },
            child: const Text('Switch is back on HS'),
          ),
        ],
      ),
    );
  }


  void _onErrors(Session s) {
    if (!s.connected) {
      _hint('Tap CONNECT first');
      return;
    }
    if (s.modules.isEmpty) {
      _hint('Run Vehicle first');
      return;
    }
    if (s.busy) {
      _hint('Still working ...');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ErrorsScreen()),
    );
  }

  Future<void> _onClearSrs(Session s) async {
    if (!s.connected) {
      _hint('Tap CONNECT first');
      return;
    }
    final m = s.soleAirbagModule;
    if (m == null) {
      _hint('Run Vehicle first; exactly one module must be flagged AIRBAG');
      return;
    }
    if (s.busy) {
      _hint('Still working ...');
      return;
    }
    final ok = await showConfirmClearSheet(context, module: m, isSrs: true);
    if (!ok) return;
    await s.clearSrs();
  }

  void _onDashboard(Session s) {
    if (!s.connected) {
      _hint('Tap CONNECT first');
      return;
    }
    if (s.busy && !s.liveRunning) {
      _hint('Still working ...');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DashboardScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    _scrollToEnd();
    final airbag = s.soleAirbagModule;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Boxster SRS',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Log',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LogScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: s.state == ConnState.disconnected
                ? () => showSettingsSheet(context)
                : () => _hint('Disconnect to change settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: Column(
            children: [
              SizedBox(
                height: 2 * 92 + 14,
                child: GridView(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    mainAxisExtent: 92,
                  ),
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    HomeTile(
                      title: 'Vehicle',
                      icon: Icons.directions_car_filled_outlined,
                      subtitle: s.modules.isEmpty
                          ? 'scan modules'
                          : '${s.modules.length} module(s)',
                      onTap: () => _onVehicle(s),
                    ),
                    HomeTile(
                      title: 'Errors',
                      icon: Icons.warning_amber_rounded,
                      subtitle: 'read DTCs',
                      enabled: s.modules.isNotEmpty,
                      onTap: () => _onErrors(s),
                    ),
                    HomeTile(
                      title: 'Clear SRS',
                      icon: Icons.airline_seat_recline_extra,
                      color: AppColors.tileDanger,
                      subtitle: airbag == null
                          ? 'needs one airbag module'
                          : airbag.address,
                      enabled: airbag != null,
                      onTap: () => _onClearSrs(s),
                    ),
                    HomeTile(
                      title: 'Dashboard',
                      icon: Icons.speed,
                      subtitle: 'live data',
                      onTap: () => _onDashboard(s),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppColors.pane,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: s.output.isEmpty
                      ? const Center(
                          child: Text(
                            'Switch adapter to HS-CAN, ignition ON,\n'
                            'join Wi-Fi "WiFi_OBDII", then CONNECT.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textDim),
                          ),
                        )
                      : SelectionArea(
                          child: ListView.builder(
                            controller: _scroll,
                            itemCount: s.output.length,
                            itemBuilder: (_, i) =>
                                Text(s.output[i], style: monoStyle),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (s.state == ConnState.connecting || s.busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      s.status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: s.statusIsError
                            ? AppColors.warn
                            : (s.connected ? AppColors.ok : AppColors.textDim),
                      ),
                    ),
                  ),
                  if (kMock)
                    const Text('MOCK',
                        style: TextStyle(
                            color: AppColors.badge,
                            fontSize: 11,
                            fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: BarButton(
                      label: 'CONNECT',
                      color: AppColors.connect,
                      onPressed: s.state == ConnState.disconnected
                          ? () => s.connect()
                          : null,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: BarButton(
                      label: 'DISCONNECT',
                      color: AppColors.disconnect,
                      onPressed: s.state == ConnState.disconnected
                          ? null
                          : () => s.disconnect(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/session.dart';
import '../core/module.dart';
import '../core/uds.dart';
import 'theme.dart';
import 'widgets/confirm_clear_sheet.dart';
import 'widgets/module_card.dart';

/// Re-reads DTCs for every found module and lists them grouped per module.
class ErrorsScreen extends StatefulWidget {
  const ErrorsScreen({super.key});

  @override
  State<ErrorsScreen> createState() => _ErrorsScreenState();
}

class _ErrorsScreenState extends State<ErrorsScreen> {
  bool _showInactive = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = context.read<Session>();
      if (s.connected && !s.busy) s.readAllDtcs();
    });
  }

  Future<void> _showDetail(Module m, Dtc d) async {
    final s = context.read<Session>();
    if (s.busy) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DtcDetailSheet(module: m, dtc: d),
    );
  }

  Future<void> _clear(Module m) async {
    final s = context.read<Session>();
    if (s.busy) return;
    final ok = await showConfirmClearSheet(context, module: m, isSrs: m.isAirbag);
    if (!ok) return;
    final r = await s.clearModuleCodes(m);
    if (!mounted) return;
    final msg = r == null
        ? 'Clear refused: ${s.status}'
        : (r.error != null
            ? 'Clear failed: ${r.error}'
            : (r.stillFailed
                ? 'Cleared, but a fault is still testFailed'
                : 'Codes cleared on ${m.address}'));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final active = s.modules.fold<int>(0, (n, m) => n + m.activeDtcs.length);
    final total = s.modules.fold<int>(0, (n, m) => n + m.dtcs.length);
    return Scaffold(
      appBar: AppBar(
        title: Text(_showInactive ? 'Errors  ($total)' : 'Errors  ($active)'),
        actions: [
          IconButton(
            tooltip: _showInactive
                ? 'Hide inactive (test-not-run) entries'
                : 'Show all ${total - active} inactive entries',
            icon: Icon(_showInactive
                ? Icons.filter_alt_off_outlined
                : Icons.filter_alt_outlined),
            onPressed: () => setState(() => _showInactive = !_showInactive),
          ),
          IconButton(
            tooltip: 'Re-read',
            icon: const Icon(Icons.refresh),
            onPressed:
                s.busy || !s.connected ? null : () => s.readAllDtcs(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (s.busy)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(s.status,
                        style: monoStyle.copyWith(fontSize: 12)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: s.modules.length,
              itemBuilder: (_, i) {
                final m = s.modules[i];
                return ModuleCard(
                  module: m,
                  showDtcs: true,
                  showInactive: _showInactive,
                  onDtcTap: (d) => _showDetail(m, d),
                  onClear: s.busy ? null : () => _clear(m),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DtcDetailSheet extends StatefulWidget {
  const _DtcDetailSheet({required this.module, required this.dtc});
  final Module module;
  final Dtc dtc;

  @override
  State<_DtcDetailSheet> createState() => _DtcDetailSheetState();
}

class _DtcDetailSheetState extends State<_DtcDetailSheet> {
  Map<String, String>? _detail;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final s = context.read<Session>();
      final d = await s.dtcDetail(widget.module, widget.dtc);
      if (mounted) setState(() => _detail = d);
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.dtc;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${d.sae}   ${d.raw}',
                style: monoStyle.copyWith(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Text(
                d.description ??
                    'Manufacturer-specific code - not in the SAE generic table',
                style: TextStyle(
                    fontSize: 14,
                    color: d.description == null
                        ? AppColors.textDim
                        : AppColors.text),
              ),
            ),
            Text(
              'module ${widget.module.address}  ${widget.module.displayName}',
              style: const TextStyle(color: AppColors.textDim),
            ),
            const SizedBox(height: 8),
            Text(
              'status 0x${d.status.toRadixString(16).toUpperCase().padLeft(2, '0')}',
              style: monoStyle.copyWith(fontSize: 13),
            ),
            for (var i = 0; i < dtcStatusNames.length; i++)
              Row(
                children: [
                  Icon(
                    (d.status & (1 << i)) != 0
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 16,
                    color: (d.status & (1 << i)) != 0
                        ? AppColors.badge
                        : AppColors.textDim,
                  ),
                  const SizedBox(width: 6),
                  Text('bit $i  ${dtcStatusNames[i]}',
                      style: monoStyle.copyWith(fontSize: 12)),
                ],
              ),
            const Divider(height: 20, color: AppColors.bg),
            if (_detail == null)
              const Row(
                children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('reading 19 04 / 19 06 ...'),
                ],
              )
            else
              for (final e in _detail!.entries) ...[
                Text(e.key,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 2),
                SelectableText(e.value, style: monoStyle),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

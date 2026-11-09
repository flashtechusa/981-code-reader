import 'package:flutter/material.dart';

import '../../core/module.dart';
import '../theme.dart';

/// Typed-CLEAR confirmation. Resolves true only when the user typed CLEAR.
Future<bool> showConfirmClearSheet(
  BuildContext context, {
  required Module module,
  required bool isSrs,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _ConfirmClearSheet(module: module, isSrs: isSrs),
  );
  return result ?? false;
}

class _ConfirmClearSheet extends StatefulWidget {
  const _ConfirmClearSheet({required this.module, required this.isSrs});
  final Module module;
  final bool isSrs;

  @override
  State<_ConfirmClearSheet> createState() => _ConfirmClearSheetState();
}

class _ConfirmClearSheetState extends State<_ConfirmClearSheet> {
  final _ctrl = TextEditingController();
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final ok = _ctrl.text.trim() == 'CLEAR';
      if (ok != _ok) setState(() => _ok = ok);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: AppColors.warn),
              const SizedBox(width: 8),
              Text(
                widget.isSrs ? 'Clear SRS codes' : 'Clear codes',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Module ${m.address}  (resp ${m.responseAddress})',
              style: monoStyle.copyWith(fontSize: 13)),
          if (m.systemName.isNotEmpty)
            Text(m.systemName, style: monoStyle.copyWith(fontSize: 13)),
          if (m.partNumber.isNotEmpty)
            Text(m.partNumber, style: monoStyle.copyWith(fontSize: 13)),
          const SizedBox(height: 12),
          Text(
            'This sends ClearDiagnosticInformation (14 FF FF FF) to this module '
            'ONLY. Clearing does not fix anything.',
            style: TextStyle(color: AppColors.text.withAlpha(220)),
          ),
          const SizedBox(height: 8),
          if (widget.isSrs)
            const Text(
              'If the seat airbag plug is still disconnected the lamp returns '
              'immediately: the POSIP re-detects the open squib circuit on the '
              'next self-test.',
              style: TextStyle(color: AppColors.badge, fontWeight: FontWeight.w600),
            )
          else if (m.isPowertrain)
            const Text(
              'This is a powertrain (DME / PDK) address. Clearing here also '
              'resets readiness monitors.',
              style: TextStyle(color: AppColors.badge, fontWeight: FontWeight.w600),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Type CLEAR to continue',
            ),
            onSubmitted: (_) {
              if (_ok) Navigator.of(context).pop(true);
            },
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warn,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _ok ? () => Navigator.of(context).pop(true) : null,
                  child: const Text('CLEAR'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

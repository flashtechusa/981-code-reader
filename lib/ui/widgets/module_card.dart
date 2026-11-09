import 'package:flutter/material.dart';

import '../../core/module.dart';
import '../../core/uds.dart';
import '../theme.dart';

/// Card for one found module. [onDtcTap] and [onClear] are optional so the
/// Vehicle screen can show a plain card and the Errors screen a live one.
class ModuleCard extends StatelessWidget {
  const ModuleCard({
    super.key,
    required this.module,
    this.showDtcs = false,
    this.onDtcTap,
    this.onClear,
  });

  final Module module;
  final bool showDtcs;
  final void Function(Dtc dtc)? onDtcTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final m = module;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.tile,
        borderRadius: BorderRadius.circular(12),
        border: m.isAirbag
            ? Border.all(color: AppColors.badge, width: 1.2)
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  m.address,
                  style: monoStyle.copyWith(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Text(
                  '→ ${m.responseAddress}  ${m.bits}-bit',
                  style: const TextStyle(
                      color: AppColors.textDim, fontSize: 12),
                ),
                const Spacer(),
                if (m.isAirbag) _badge('AIRBAG / POSIP', AppColors.badge),
                if (m.isPowertrain) _badge('POWERTRAIN', AppColors.accent),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              m.displayName,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (m.partNumber.isNotEmpty && m.systemName.isNotEmpty)
              Text('Part no. ${m.partNumber}',
                  style: monoStyle.copyWith(color: AppColors.textDim)),
            for (final e in m.info.entries)
              if (e.key != 'system name' && e.key != 'spare part number')
                Text('${e.key}: ${e.value}',
                    style: monoStyle.copyWith(color: AppColors.textDim)),
            if (m.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(m.note!,
                    style: monoStyle.copyWith(color: AppColors.warn)),
              ),
            if (showDtcs) ...[
              const Divider(height: 18, color: AppColors.bg),
              if (m.dtcs.isEmpty)
                const Text('no DTCs stored',
                    style: TextStyle(color: AppColors.ok))
              else
                for (final d in m.dtcs) _DtcRow(dtc: d, onTap: onDtcTap),
              if (onClear != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onClear,
                    icon: const Icon(Icons.delete_sweep_outlined,
                        color: AppColors.warn),
                    label: const Text('Clear codes',
                        style: TextStyle(color: AppColors.warn)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
          ),
        ),
      );
}

class _DtcRow extends StatelessWidget {
  const _DtcRow({required this.dtc, this.onTap});
  final Dtc dtc;
  final void Function(Dtc dtc)? onTap;

  @override
  Widget build(BuildContext context) {
    final failed = dtc.testFailed;
    return InkWell(
      onTap: onTap == null ? null : () => onTap!(dtc),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              failed ? Icons.error : Icons.history,
              size: 18,
              color: failed ? AppColors.warn : AppColors.textDim,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${dtc.sae}   ${dtc.raw}',
                    style: monoStyle.copyWith(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'status 0x${dtc.status.toRadixString(16).toUpperCase().padLeft(2, '0')}  ${dtc.statusNames}',
                    style: monoStyle.copyWith(color: AppColors.textDim),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right, color: AppColors.textDim),
          ],
        ),
      ),
    );
  }
}

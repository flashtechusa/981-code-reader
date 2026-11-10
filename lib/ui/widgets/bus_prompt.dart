import 'package:flutter/material.dart';

import '../../app/session.dart';
import '../../core/module.dart';

/// Ask the user to flip the adapter's HS/MS switch so [m] can be reached.
/// Returns true when they confirmed (and the session now assumes that bus).
Future<bool> ensureBusFor(BuildContext context, Session s, Module m) async {
  if (s.legacyMode || m.bus == s.adapterBus) return true;
  final want = m.bus;
  final name = want == CanBus.ms ? 'MS-CAN' : 'HS-CAN';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Flip the switch to $name'),
      content: Text('[${m.address}] ${m.displayName} is on $name. Flip the '
          'adapter switch to $name, then confirm.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('Switch is on $name'),
        ),
      ],
    ),
  );
  if (ok == true) s.setAdapterBus(want);
  return ok == true;
}

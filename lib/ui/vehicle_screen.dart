import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/session.dart';
import 'theme.dart';
import 'widgets/module_card.dart';

/// Lists every module found by the scan (read-only).
class VehicleScreen extends StatelessWidget {
  const VehicleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vehicle'),
        actions: [
          IconButton(
            tooltip: 'Rescan',
            icon: const Icon(Icons.refresh),
            onPressed: s.busy || !s.connected ? null : () => s.scan(),
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle.copyWith(fontSize: 12)),
                  ),
                  if (s.scanning)
                    TextButton(
                      onPressed: s.stopScan,
                      child: const Text('STOP'),
                    ),
                ],
              ),
            ),
          Expanded(
            child: s.modules.isEmpty
                ? Center(
                    child: Text(
                      s.busy
                          ? 'Scanning ... (STOP keeps what was found so far)'
                          : 'No modules found.\nIgnition on? Switch on HS-CAN?',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textDim),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: s.modules.length,
                    itemBuilder: (_, i) => ModuleCard(module: s.modules[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

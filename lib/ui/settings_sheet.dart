import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/settings.dart';
import '../core/dtc_text.dart';
import '../core/units.dart';
import 'theme.dart';

Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late bool _powertrain;
  late UnitSystem _units;
  late VehicleBus _bus;
  late bool _msSwitch;
  late MakeCodeText _codeText;

  @override
  void initState() {
    super.initState();
    final s = context.read<Settings>();
    _host = TextEditingController(text: s.host);
    _port = TextEditingController(text: s.port.toString());
    _powertrain = s.includePowertrain;
    _units = s.unitSystem;
    _bus = s.bus;
    _msSwitch = s.hasMsSwitch;
    _codeText = s.codeText;
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = context.read<Settings>();
    final port = int.tryParse(_port.text.trim());
    await s.update(
      host: _host.text,
      port: port,
      includePowertrain: _powertrain,
      unitSystem: _units,
      bus: _bus,
      hasMsSwitch: _msSwitch,
      codeText: _codeText,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Adapter host'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'bbfly / ELM327 Wi-Fi default is 192.168.0.10 : 35000',
            style: TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
          const SizedBox(height: 14),
          const Text('Vehicle bus', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<VehicleBus>(
              segments: const [
                ButtonSegment(
                  value: VehicleBus.can,
                  label: Text('CAN  (2008+)'),
                ),
                ButtonSegment(
                  value: VehicleBus.legacy,
                  label: Text('K-line legacy'),
                ),
              ],
              selected: {_bus},
              onSelectionChanged: (sel) => setState(() => _bus = sel.first),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _bus == VehicleBus.can
                ? 'Porsche 981, Ford F-150 and other CAN cars: every module, UDS.'
                : 'Pre-CAN cars (e.g. 2004 Maserati 4200): engine ECU only via '
                    'generic OBD-II - codes, clear, live data. First connect '
                    'takes ~15 s while the adapter finds the protocol.',
            style: const TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
          const SizedBox(height: 14),
          const Text('Units', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<UnitSystem>(
              segments: const [
                ButtonSegment(
                  value: UnitSystem.us,
                  label: Text('US  (mph, °F)'),
                ),
                ButtonSegment(
                  value: UnitSystem.metric,
                  label: Text('Metric  (km/h, °C)'),
                ),
              ],
              selected: {_units},
              onSelectionChanged: (sel) => setState(() => _units = sel.first),
            ),
          ),
          const SizedBox(height: 14),
          const Text('Manufacturer code text',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<MakeCodeText>(
              segments: const [
                ButtonSegment(value: MakeCodeText.auto, label: Text('Auto')),
                ButtonSegment(
                    value: MakeCodeText.ford, label: Text('Ford family')),
                ButtonSegment(value: MakeCodeText.off, label: Text('Off')),
              ],
              selected: {_codeText},
              onSelectionChanged: (sel) => setState(() => _codeText = sel.first),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            switch (_codeText) {
              MakeCodeText.auto =>
                'Uses the Ford code list when a module reports a Ford, Lincoln, '
                    'Mercury or Mazda VIN (or Ford MS-CAN modules answer). '
                    'Never on a Porsche or Maserati.',
              MakeCodeText.ford =>
                'Always use the Ford code list for manufacturer codes - for a '
                    'Ford-family car whose modules report no VIN.',
              MakeCodeText.off => 'SAE generic text only.',
            },
            style: const TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _powertrain,
            onChanged: (v) => setState(() => _powertrain = v),
            title: const Text('Include powertrain in scan'),
            subtitle: const Text(
              'Probe DME / PDK at 0x7E0-0x7E7 and 29-bit targets 0x10 / 0x18. '
              'Clear SRS never touches these.',
              style: TextStyle(fontSize: 12),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Adapter has HS / MS-CAN switch'),
            subtitle: const Text(
                'bbfly, OBDLink MX etc. After the HS scan you will be asked to '
                'flip it so Ford MS-CAN modules (cluster, HVAC, doors) can be '
                'scanned too.'),
            value: _msSwitch,
            onChanged: (v) => setState(() => _msSwitch = v),
          ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

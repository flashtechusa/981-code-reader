/// Well-known 11-bit diagnostic request IDs, used to LABEL a module when it
/// does not answer the identification DIDs (Ford modules, for example, do not
/// implement the VW/Porsche F187/F197 DIDs). These are conventions, not facts
/// read from the car, so the UI marks them "by address".
///
/// Sources: FORScan module lists (Ford HS-CAN), VW/Audi MQB conventions.
/// Only entries with a single, widely-agreed meaning are included.
class KnownModule {
  const KnownModule(this.abbr, this.name, this.make, {this.airbag = false});
  final String abbr;
  final String name;
  final String make;

  /// True when this address is the restraints / airbag controller.
  final bool airbag;

  String get label => '$abbr - $name ($make convention)';
}

const Map<int, KnownModule> knownModules11 = {
  // ---- Ford / Lincoln HS-CAN (FORScan naming) ---------------------------------
  0x706: KnownModule('IPMA', 'Image Processing Module A (camera)', 'Ford'),
  0x716: KnownModule('GWM', 'Gateway Module', 'Ford'),
  0x720: KnownModule('IPC', 'Instrument Panel Cluster', 'Ford'),
  0x726: KnownModule('BCM', 'Body Control Module', 'Ford'),
  0x727: KnownModule('ACM', 'Audio Control Module', 'Ford'),
  0x730: KnownModule('PSCM', 'Power Steering Control Module', 'Ford'),
  0x731: KnownModule('RFA', 'Remote Function Actuator', 'Ford'),
  0x733: KnownModule('HVAC', 'Heating, Ventilation & A/C Module', 'Ford'),
  0x734: KnownModule('HCM', 'Headlamp Control Module', 'Ford'),
  0x736: KnownModule('PAM', 'Parking Aid Module', 'Ford'),
  0x737: KnownModule('RCM', 'Restraints Control Module (airbag)', 'Ford',
      airbag: true),
  0x740: KnownModule('DDM', 'Driver Door Module', 'Ford'),
  0x741: KnownModule('PDM', 'Passenger Door Module', 'Ford'),
  0x754: KnownModule('TCU', 'Telematics Control Unit', 'Ford'),
  0x760: KnownModule('ABS', 'Anti-lock Brake System', 'Ford'),
  0x764: KnownModule('CCM', 'Cruise Control Module (radar)', 'Ford'),
  0x765: KnownModule('OCSM', 'Occupant Classification System Module', 'Ford'),
  0x7A7: KnownModule('FCIM', 'Front Controls Interface Module', 'Ford'),
  0x7C4: KnownModule('SODL', 'Side Obstacle Detection - Left', 'Ford'),
  0x7C6: KnownModule('SODR', 'Side Obstacle Detection - Right', 'Ford'),
  0x7D0: KnownModule('APIM', 'SYNC / Accessory Protocol Interface Module', 'Ford'),
  0x7E0: KnownModule('PCM', 'Powertrain Control Module', 'OBD-II'),
  0x7E1: KnownModule('TCM', 'Transmission Control Module', 'OBD-II'),

  // ---- VW group (MQB-era) -----------------------------------------------------
  0x70E: KnownModule('17', 'Instrument Cluster', 'VW'),
  0x713: KnownModule('03', 'ABS / ESC', 'VW'),
  0x715: KnownModule('15', 'Airbag', 'VW', airbag: true),
  0x746: KnownModule('09', 'Central Electronics (BCM)', 'VW'),
  0x773: KnownModule('19', 'Gateway', 'VW'),
};

/// Ford MS-CAN (pins 3/11, 125 kbps) addresses. Several modules answer on
/// both buses (BCM, PAM ...); these are the ones usually ONLY on MS-CAN.
const Map<int, KnownModule> knownModulesMs = {
  0x720: KnownModule('IPC', 'Instrument Panel Cluster', 'Ford'),
  0x726: KnownModule('BCM', 'Body Control Module', 'Ford'),
  0x727: KnownModule('ACM', 'Audio Control Module', 'Ford'),
  0x731: KnownModule('RFA', 'Remote Function Actuator', 'Ford'),
  0x733: KnownModule('HVAC', 'Heating, Ventilation & A/C Module', 'Ford'),
  0x734: KnownModule('HCM', 'Headlamp Control Module', 'Ford'),
  0x736: KnownModule('PAM', 'Parking Aid Module', 'Ford'),
  0x740: KnownModule('DDM', 'Driver Door Module', 'Ford'),
  0x741: KnownModule('PDM', 'Passenger Door Module', 'Ford'),
  0x744: KnownModule('DSM', 'Driver Seat Module', 'Ford'),
  0x754: KnownModule('TCU', 'Telematics Control Unit', 'Ford'),
  0x7A7: KnownModule('FCIM', 'Front Controls Interface Module', 'Ford'),
  0x7C4: KnownModule('SODL', 'Side Obstacle Detection - Left', 'Ford'),
  0x7C6: KnownModule('SODR', 'Side Obstacle Detection - Right', 'Ford'),
  0x7D0: KnownModule('APIM', 'SYNC / Accessory Protocol Interface Module', 'Ford'),
  0x7E7: KnownModule('TRM', 'Trailer Module', 'Ford'),
};

KnownModule? knownModule11(int reqId) => knownModules11[reqId];

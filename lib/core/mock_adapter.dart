import 'dart:math' show sin;

import 'transport.dart';

/// Scripted bbfly/ELM327 stand-in for the simulator (`--dart-define=MOCK=true`).
///
/// Simulates:
///  * an airbag module (POSIP) at 11-bit request 0x715 / response 0x77F with
///    two stored B-codes, one still testFailed until "cleared" twice
///  * a DME at 0x7E0 / 0x7E8 answering Mode 01 live data with wobbling values
///  * a 29-bit module at 18DA40F1 that only answers TesterPresent / ReadDTC
class MockAdapter {
  MockAdapter({this.latency = const Duration(milliseconds: 2)});

  /// Simulated adapter response delay.
  final Duration latency;

  int _bits = 11;
  String _sh = '';
  int _clearCount = 0;
  bool _pendingClear = false;
  double _t = 0;

  MockTransport transport() => MockTransport(respond, latency: latency);

  String respond(String cmd) {
    final c = cmd.trim().toUpperCase();
    if (c.startsWith('AT')) return _at(c);
    final bytes = c.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (bytes.isEmpty) return '?\r>';
    if (_bits == 11) return _can11(bytes);
    return _can29(bytes);
  }

  String _at(String c) {
    if (c == 'ATZ') return '\r\rELM327 v1.5\r>';
    if (c == 'ATI') return 'ELM327 v1.5\r>';
    if (c == 'ATRV') return '12.6V\r>';
    if (c == 'ATSP6') {
      _bits = 11;
      return 'OK\r>';
    }
    if (c == 'ATSP7') {
      _bits = 29;
      return 'OK\r>';
    }
    if (c.startsWith('ATSH')) {
      _sh = c.substring(4);
      return 'OK\r>';
    }
    return 'OK\r>';
  }

  String _frame(String hdr, List<String> payload) {
    final f = <String>[payload.length.toRadixString(16).padLeft(2, '0').toUpperCase(), ...payload];
    while (f.length < 8) {
      f.add('00');
    }
    return '$hdr ${f.join(' ')}\r';
  }

  String _can11(List<String> b) {
    final pci = int.parse(b[0], radix: 16);
    final len = pci & 0x0F;
    final p = b.sublist(1, 1 + len);
    final sid = p[0];
    if (_sh == '715') return _airbag('77F', p, sid);
    if (_sh == '7E0' || _sh == '7DF') return _dme('7E8', p, sid);
    if (_sh == '7A5' && sid == '3E') {
      // a module that answers TesterPresent but nothing else
      return '${_frame('7AD', ['7E', '00'])}>';
    }
    return 'NO DATA\r>';
  }

  String _can29(List<String> b) {
    final pci = int.parse(b[0], radix: 16);
    final len = pci & 0x0F;
    final p = b.sublist(1, 1 + len);
    if (_sh == 'DA40F1' && p[0] == '3E') {
      return '${_frame('18DAF140', ['7E', '00'])}>';
    }
    if (_sh == 'DA40F1' && p[0] == '22') {
      return '${_frame('18DAF140', ['7F', '22', '31'])}>';
    }
    if (_sh == 'DA40F1' && p[0] == '19') {
      return '${_frame('18DAF140', ['59', '02', 'FF'])}>';
    }
    return 'NO DATA\r>';
  }

  String _airbag(String hdr, List<String> p, String sid) {
    switch (sid) {
      case '3E':
        if (_pendingClear) {
          // the final 0x54 arrives on the TesterPresent poll
          _pendingClear = false;
          return '${_frame(hdr, ['54'])}>';
        }
        return '${_frame(hdr, ['7E', '00'])}>';
      case '10':
        return '${_frame(hdr, ['50', p[1], '00', '32', '01', 'F4'])}>';
      case '22':
        final did = '${p[1]}${p[2]}';
        if (did == 'F197') {
          return '$hdr 10 0B 62 F1 97 41 49 52 42\r$hdr 21 41 47 20 20 00 00 00 00\r>';
        }
        if (did == 'F187') {
          // "99161800107" -> 991 618 001 07
          return '$hdr 10 0E 62 F1 87 39 39 31\r$hdr 21 36 31 38 30 30 31 30\r'
              '$hdr 22 37 00 00 00 00 00 00 00\r>';
        }
        if (did == 'F189') {
          return '${_frame(hdr, ['62', 'F1', '89', '30', '31', '30', '35'])}>';
        }
        return '${_frame(hdr, ['7F', '22', '31'])}>';
      case '19':
        if (p[1] == '02') {
          if (_clearCount >= 2) {
            return '${_frame(hdr, ['59', '02', 'FF'])}>';
          }
          if (_clearCount == 1) {
            // after one clear the unplugged squib fault returns immediately
            return '${_frame(hdr, ['59', '02', 'FF', '80', '01', '04', '2F'])}>';
          }
          return '$hdr 10 0E 59 02 FF 80 01 04 2F 80 02\r$hdr 21 05 09 90 10 00 08 00 00\r>';
        }
        if (p[1] == '04') {
          return '$hdr 10 10 59 04 ${p[2]} ${p[3]} ${p[4]} 2F\r'
              '$hdr 21 01 02 F4 01 1A 00 00\r$hdr 22 12 45 3B 00 00 00 00\r>';
        }
        if (p[1] == '06') {
          return '$hdr 10 0C 59 06 ${p[2]} ${p[3]} ${p[4]} 2F\r'
              '$hdr 21 01 03 02 FF 00 00 00\r>';
        }
        return '${_frame(hdr, ['7F', '19', '12'])}>';
      case '14':
        _clearCount++;
        if (_clearCount == 1) {
          // first attempt: pending, then positive on the TP poll
          _pendingClear = true;
          return '${_frame(hdr, ['7F', '14', '78'])}>';
        }
        return '${_frame(hdr, ['54'])}>';
      default:
        return '${_frame(hdr, ['7F', sid, '11'])}>';
    }
  }

  String _dme(String hdr, List<String> p, String sid) {
    if (sid == '3E') return '${_frame(hdr, ['7E', '00'])}>';
    if (sid == '22') return '${_frame(hdr, ['7F', '22', '31'])}>';
    if (sid == '19') return '${_frame(hdr, ['59', '02', 'FF'])}>';
    if (sid == '14') return '${_frame(hdr, ['54'])}>';
    if (sid == '01') {
      _t += 0.2;
      final pid = p[1];
      List<String> data;
      switch (pid) {
        case '0C':
          final rpm = (820 + 60 * sin(_t)) * 4;
          final v = rpm.round();
          data = [_h(v >> 8), _h(v & 0xFF)];
          break;
        case '0D':
          data = ['00'];
          break;
        case '05':
          data = [_h((88 + 40).round())];
          break;
        case '0F':
          data = [_h((31 + 40 + 2 * sin(_t / 3)).round())];
          break;
        case '04':
          data = [_h(((22 + 3 * sin(_t)) * 255 / 100).round())];
          break;
        case '06':
        case '08':
          data = [_h((128 + 4 * sin(_t * 1.3)).round())];
          break;
        case '07':
        case '09':
          data = [_h(131)];
          break;
        case '11':
          data = [_h((14 * 255 / 100).round())];
          break;
        case '42':
          final mv = (14050 + 60 * sin(_t / 2)).round();
          data = [_h(mv >> 8), _h(mv & 0xFF)];
          break;
        default:
          return 'NO DATA\r>';
      }
      return '${_frame(hdr, ['41', pid, ...data])}>';
    }
    return '${_frame(hdr, ['7F', sid, '11'])}>';
  }

  static String _h(int v) =>
      (v & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
}

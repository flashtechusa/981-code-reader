import 'dart:typed_data';

/// Upper-case hex, zero-padded to [width] characters.
String hexN(int value, int width) =>
    value.toRadixString(16).toUpperCase().padLeft(width, '0');

/// "41 49 52" style dump.
String toHex(List<int> bytes, {String separator = ' '}) =>
    bytes.map((b) => hexN(b & 0xFF, 2)).join(separator);

/// "414952" style dump.
String toHexCompact(List<int> bytes) => toHex(bytes, separator: '');

/// Parses a hex string (spaces allowed). Throws [FormatException] on odd
/// length or non-hex characters.
Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  if (clean.length.isOdd) {
    throw FormatException('odd-length hex string', hex);
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Printable ASCII with '.' for non-printables; falls back to a hex dump when
/// nothing printable is present (same rule as the Python `ascii_or_hex`).
String asciiOrHex(List<int> bytes) {
  final s = String.fromCharCodes(
    bytes.map((c) => c >= 32 && c < 127 ? c : 0x2E),
  );
  return s.replaceAll('.', '').isNotEmpty ? s : toHex(bytes);
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/session.dart';
import 'theme.dart';

/// Raw AT / CAN transcript with share-as-.txt.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _scroll = ScrollController();
  bool _follow = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  final _shareKey = GlobalKey();

  /// Where the share sheet should anchor (required on iPad, harmless on iPhone).
  Rect? _origin() {
    final box = _shareKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _share(Session s) async {
    final text = s.logText();
    final origin = _origin();
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .substring(0, 15);
      final f = File('${dir.path}/boxster_srs_$stamp.txt');
      await f.writeAsString(text, flush: true);
      final r = await Share.shareXFiles(
        [XFile(f.path, mimeType: 'text/plain', name: 'boxster_srs_$stamp.txt')],
        subject: 'Boxster SRS log',
        sharePositionOrigin: origin,
      );
      if (r.status == ShareResultStatus.unavailable) {
        await Clipboard.setData(ClipboardData(text: text));
        _toast('Share sheet unavailable - log copied to clipboard');
      }
    } catch (e) {
      try {
        await Share.share(text,
            subject: 'Boxster SRS log', sharePositionOrigin: origin);
      } catch (_) {
        await Clipboard.setData(ClipboardData(text: text));
        _toast('Could not open share sheet ($e) - log copied to clipboard');
      }
    }
  }

  Future<void> _copy(Session s) async {
    await Clipboard.setData(ClipboardData(text: s.logText()));
    _toast('Log copied to clipboard (${s.log.length} lines)');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final entries = s.log;
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('Log  (${entries.length})'),
        actions: [
          IconButton(
            tooltip: _follow ? 'Stop following' : 'Follow tail',
            icon: Icon(_follow
                ? Icons.vertical_align_bottom
                : Icons.vertical_align_center),
            onPressed: () => setState(() => _follow = !_follow),
          ),
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy_all),
            onPressed: entries.isEmpty ? null : () => _copy(s),
          ),
          IconButton(
            key: _shareKey,
            tooltip: 'Share .txt',
            icon: const Icon(Icons.ios_share),
            onPressed: entries.isEmpty ? null : () => _share(s),
          ),
        ],
      ),
      body: Container(
        color: AppColors.pane,
        child: entries.isEmpty
            ? const Center(
                child: Text('Nothing logged yet',
                    style: TextStyle(color: AppColors.textDim)),
              )
            : SelectionArea(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(10),
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    final color = e.direction == '>>'
                        ? AppColors.accent
                        : (e.direction == '--'
                            ? AppColors.warn
                            : AppColors.text);
                    return Text(e.toString(),
                        style: monoStyle.copyWith(color: color));
                  },
                ),
              ),
      ),
    );
  }
}

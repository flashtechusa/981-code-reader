import 'dart:io';

import 'package:flutter/material.dart';
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

  Future<void> _share(Session s) async {
    final text = s.logText();
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .substring(0, 15);
      final f = File('${dir.path}/boxster_srs_$stamp.txt');
      await f.writeAsString(text);
      await Share.shareXFiles([XFile(f.path, mimeType: 'text/plain')],
          subject: 'Boxster SRS log');
    } catch (_) {
      await Share.share(text, subject: 'Boxster SRS log');
    }
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

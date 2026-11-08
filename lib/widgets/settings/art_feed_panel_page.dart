/*
 * FLauncher
 * Copyright (C) 2021  Étienne Fesser
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'package:flauncher/providers/settings_service.dart';
import 'package:flauncher/providers/wallpaper_service.dart';
import 'package:flauncher/widgets/settings/focusable_settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ArtFeedPanelPage extends StatefulWidget {
  static const String routeName = "art_feed_panel";

  @override
  State<ArtFeedPanelPage> createState() => _ArtFeedPanelPageState();
}

class _ArtFeedPanelPageState extends State<ArtFeedPanelPage> {
  late Future<List<ArtFeed>> _feeds;

  @override
  void initState() {
    super.initState();
    _feeds = context.read<WallpaperService>().fetchArtFeeds();
  }

  Future<void> _select(String url) async {
    final settings = context.read<SettingsService>();
    // Day and night pictures would hide the feed picture.
    await settings.setTimeBasedWallpaperEnabled(false);
    await settings.setWallpaperFeedUrl(url);
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text("Art feed", style: Theme.of(context).textTheme.titleLarge),
          const Divider(),
          Expanded(
            child: FutureBuilder<List<ArtFeed>>(
              future: _feeds,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final feeds = snapshot.data ?? [];
                return Consumer<SettingsService>(
                  builder: (_, settings, __) => ListView(
                    children: [
                      _tile("Off", "", settings.wallpaperFeedUrl, autofocus: true),
                      for (final feed in feeds) _tile(feed.name, feed.url, settings.wallpaperFeedUrl),
                      if (snapshot.hasError)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text("Could not load the feed list. Check the network connection.",
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      );

  Widget _tile(String name, String url, String selectedUrl, {bool autofocus = false}) => FocusableSettingsTile(
        autofocus: autofocus,
        leading: Icon(url.isEmpty ? Icons.block : Icons.palette_outlined),
        title: Text(name, style: Theme.of(context).textTheme.bodyMedium),
        trailing: url == selectedUrl ? const Icon(Icons.check) : null,
        onPressed: () => _select(url),
      );
}

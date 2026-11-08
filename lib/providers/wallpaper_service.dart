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

import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/gradients.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Index of art feeds published by https://github.com/crankyMagician/tv-art
const String artFeedIndexUrl = "https://crankymagician.github.io/tv-art/index.json";

class ArtFeed {
  final String name;
  final String url;

  ArtFeed(this.name, this.url);
}

class WallpaperService extends ChangeNotifier {
  final FLauncherChannel _fLauncherChannel;
  final SettingsService _settingsService;

  late File _wallpaperFile;
  late File _wallpaperDayFile;
  late File _wallpaperNightFile;
  late File _feedSourceFile;
  Timer? _timer;
  Timer? _feedTimer;
  String _lastFeedUrl = "";

  ImageProvider? _wallpaper;
  int _version = 0;
  int _updateWallpaperCallCount = 0;

  ImageProvider?  get wallpaper     => _wallpaper;
  int             get version       => _version;

  FLauncherGradient get gradient => FLauncherGradients.all.firstWhere(
        (gradient) => gradient.uuid == _settingsService.gradientUuid,
        orElse: () => FLauncherGradients.pitchBlack,
      );

  WallpaperService(this._fLauncherChannel, this._settingsService) :
    _wallpaper = null
  {
    _settingsService.addListener(_onSettingsChanged);
    _init();
  }

  bool _lastTimeBasedEnabled = false;

  void _onSettingsChanged() {
    final feedUrl = _settingsService.wallpaperFeedUrl;
    if (feedUrl != _lastFeedUrl) {
      _lastFeedUrl = feedUrl;
      _updateFeedTimerState();
      syncFeed(force: true);
    }

    final enabled = _settingsService.timeBasedWallpaperEnabled;
    if (enabled != _lastTimeBasedEnabled) {
      _lastTimeBasedEnabled = enabled;
      _updateTimerState();
      _updateWallpaper();
    }
  }

  @override
  void dispose() {
    _settingsService.removeListener(_onSettingsChanged);
    _timer?.cancel();
    _feedTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final directory = await getApplicationDocumentsDirectory();
    _wallpaperFile = File("${directory.path}/wallpaper");
    _wallpaperDayFile = File("${directory.path}/wallpaper_day");
    _wallpaperNightFile = File("${directory.path}/wallpaper_night");
    _feedSourceFile = File("${directory.path}/wallpaper_feed_source");

    _lastTimeBasedEnabled = _settingsService.timeBasedWallpaperEnabled;
    _lastFeedUrl = _settingsService.wallpaperFeedUrl;
    await _updateWallpaper();
    _updateTimerState();
    _updateFeedTimerState();
    await syncFeed();
  }

  void _updateFeedTimerState() {
    if (_settingsService.wallpaperFeedUrl.isNotEmpty) {
      _feedTimer ??= Timer.periodic(const Duration(hours: 6), (_) => syncFeed());
    } else {
      _feedTimer?.cancel();
      _feedTimer = null;
    }
  }

  Future<dynamic> _getJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException("HTTP ${response.statusCode}", uri: Uri.parse(url));
      }
      return jsonDecode(await response.transform(utf8.decoder).join());
    } finally {
      client.close();
    }
  }

  Future<List<ArtFeed>> fetchArtFeeds() async {
    final index = await _getJson(artFeedIndexUrl);
    return [
      for (final feed in index["feeds"] as List) ArtFeed(feed["name"] as String, feed["url"] as String),
    ];
  }

  /// Shows one picture a day from the selected feed. Errors keep the current wallpaper.
  Future<void> syncFeed({bool force = false}) async {
    final feedUrl = _settingsService.wallpaperFeedUrl;
    if (feedUrl.isEmpty) {
      return;
    }

    try {
      final images = (await _getJson(feedUrl))["images"] as List;
      if (images.isEmpty) {
        return;
      }
      final now = DateTime.now();
      final dayOfYear = now.difference(DateTime(now.year)).inDays;
      final imageUrl = images[dayOfYear % images.length]["url"] as String;

      if (!force && await _wallpaperFile.exists() && await _feedSourceFile.exists()
          && await _feedSourceFile.readAsString() == imageUrl) {
        return;
      }

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      final tempFile = File("${_wallpaperFile.path}.download");
      try {
        final response = await (await client.getUrl(Uri.parse(imageUrl))).close().timeout(const Duration(seconds: 60));
        if (response.statusCode != 200) {
          return;
        }
        await response.pipe(tempFile.openWrite());
      } finally {
        client.close();
      }

      // The user may have switched feeds or picked a picture while this ran.
      if (_settingsService.wallpaperFeedUrl != feedUrl) {
        await tempFile.delete();
        return;
      }
      await tempFile.rename(_wallpaperFile.path);
      await _feedSourceFile.writeAsString(imageUrl);
      await FileImage(_wallpaperFile).evict();
      _version++;
      await _updateWallpaper(force: true);
    } catch (e) {
      debugPrint("Art feed sync failed: $e");
    }
  }

  void _updateTimerState() {
    final enabled = _settingsService.timeBasedWallpaperEnabled;
    if (enabled && (_timer == null || !_timer!.isActive)) {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => _updateWallpaper());
    } else if (!enabled && _timer != null) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _updateWallpaper({bool force = false}) async {
    final callId = ++_updateWallpaperCallCount;
    final now = DateTime.now();
    final isDay = now.hour >= 6 && now.hour < 18;
    final enabled = _settingsService.timeBasedWallpaperEnabled;

    ImageProvider? newWallpaper;

    if (enabled) {
      if (isDay && await _wallpaperDayFile.exists()) {
        newWallpaper = FileImage(_wallpaperDayFile);
      } else if (!isDay && await _wallpaperNightFile.exists()) {
        newWallpaper = FileImage(_wallpaperNightFile);
      } else if (await _wallpaperFile.exists()) {
        newWallpaper = FileImage(_wallpaperFile); // Fallback
      }
    } else {
      if (await _wallpaperFile.exists()) {
        newWallpaper = FileImage(_wallpaperFile);
      }
    }

    if (callId == _updateWallpaperCallCount) {
      if (_wallpaper != newWallpaper || force) {
        _wallpaper = newWallpaper;
        notifyListeners();
      }
    }
  }

  Future<void> pickWallpaper() async {
    await _settingsService.setWallpaperFeedUrl("");
    await _pickAndSave(_wallpaperFile);
  }

  Future<void> pickWallpaperDay() async {
    await _pickAndSave(_wallpaperDayFile);
  }

  Future<void> pickWallpaperNight() async {
    await _pickAndSave(_wallpaperNightFile);
  }

  Future<void> _pickAndSave(File targetFile) async {
    if (!await _fLauncherChannel.checkForGetContentAvailability()) {
      throw NoFileExplorerException();
    }

    final imagePicker = ImagePicker();
    final pickedFile = await imagePicker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      // Use stream for memory efficiency
      final readStream = pickedFile.openRead();
      final writeStream = targetFile.openWrite();
      await readStream.cast<List<int>>().pipe(writeStream);

      // Evict from cache to ensure UI updates
      await FileImage(targetFile).evict();

      _version++;
      await _updateWallpaper(force: true);
    }
  }

  Future<void> setGradient(FLauncherGradient fLauncherGradient) async {
    await _settingsService.setWallpaperFeedUrl("");
    if (await _wallpaperFile.exists()) {
      await _wallpaperFile.delete();
    }

    _settingsService.setGradientUuid(fLauncherGradient.uuid);
    notifyListeners();
  }
}

class NoFileExplorerException implements Exception {}

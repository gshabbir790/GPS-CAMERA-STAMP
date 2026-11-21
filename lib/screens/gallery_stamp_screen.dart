import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/strings.dart';
import '../models/app_settings.dart';
import '../models/stamp_data.dart';
import '../services/location_service.dart';
import '../services/photo_queue.dart';
import '../services/photo_store.dart';
import '../widgets/ad_banner.dart';
import '../widgets/stamp_widget.dart';

/// گیلری سے کوئی بھی تصویر چنیں اور اس پر اسٹیمپ لگائیں:
///  - تاریخ اور وقت: آج کی تاریخ اور فون پر چلنے والا موجودہ وقت (محفوظ کرتے لمحے کا)
///  - لوکیشن: صارف خود (دستی) لکھتا ہے
class GalleryStampScreen extends StatefulWidget {
  const GalleryStampScreen({super.key});

  @override
  State<GalleryStampScreen> createState() => _GalleryStampScreenState();
}

class _GalleryStampScreenState extends State<GalleryStampScreen> {
  final s = AppSettings.instance;
  final loc = LocationService();
  final _picker = ImagePicker();
  final _stampKey = GlobalKey();
  final _scroll = ScrollController();

  final _titleC = TextEditingController();
  final _addrC = TextEditingController();
  final _latC = TextEditingController();
  final _lonC = TextEditingController();

  File? _file; // منتخب تصویر
  double _aspect = 0.75; // چوڑائی / اونچائی (EXIF گھماؤ کے بعد)
  DateTime _now = DateTime.now();
  Timer? _tick;
  StreamSubscription<QueueResult>? _sub;

  bool _saving = false;
  bool _locating = false;
  String? _pendingOut; // جس تصویر کا نتیجہ ہم سن رہے ہیں
  String? _savedPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    // پہلے سے محفوظ دستی لوکیشن (کیمرے والی) ہو تو خانے بھر دیں
    _titleC.text = s.mTitle;
    _addrC.text = s.mAddress;
    if (s.mLat != 0 || s.mLon != 0) {
      _latC.text = s.mLat.toStringAsFixed(6);
      _lonC.text = s.mLon.toStringAsFixed(6);
      loc.setMapType(s.mapType);
      loc.setManual(s.mLat, s.mLon, title: s.mTitle, address: s.mAddress);
    }

    // وقت ہر سیکنڈ فون کی گھڑی سے تازہ ہوتا رہے
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_saving) setState(() => _now = DateTime.now());
    });

    _sub = PhotoQueue.instance.results.listen(_onResult);

    // اسکرین کھلتے ہی گیلری کھل جائے
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    loc.dispose();
    _titleC.dispose();
    _addrC.dispose();
    _latC.dispose();
    _lonC.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
  }

  // ---------------- تصویر منتخب کرنا ----------------
  Future<void> _pick() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.gallery);
      if (x == null) return;
      final f = File(x.path);
      final a = await _imageAspect(f);
      if (!mounted) return;
      setState(() {
        _file = f;
        _aspect = a;
        _savedPath = null;
        _pendingOut = null;
        _error = null;
        _now = DateTime.now();
      });
    } catch (e) {
      _msg(S.t('Could not open photo: $e', 'تصویر نہیں کھل سکی: $e'));
    }
  }

  /// تصویر کا اصل ریشو (چھوٹا ڈی کوڈ کر کے، تاکہ میموری کم لگے)
  Future<double> _imageAspect(File f) {
    final c = Completer<double>();
    final stream = ResizeImage(FileImage(f), width: 600).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (!c.isCompleted) c.complete(info.image.width / info.image.height);
      stream.removeListener(l);
    }, onError: (e, st) {
      if (!c.isCompleted) c.completeError(e);
      stream.removeListener(l);
    });
    stream.addListener(l);
    return c.future;
  }

  // ---------------- لوکیشن ----------------
  /// خانوں سے لوکیشن پڑھ کر لاگو کریں؛ غلط ہو تو false
  bool _applyLocation({bool quiet = false, bool remember = true}) {
    final lat = double.tryParse(_latC.text.trim());
    final lon = double.tryParse(_lonC.text.trim());
    if (lat == null || lon == null || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      if (!quiet) {
        _msg(S.t('Enter valid Latitude and Longitude', 'درست Latitude اور Longitude لکھیں'));
      }
      return false;
    }
    loc.setMapType(s.mapType);
    loc.setManual(lat, lon, title: _titleC.text.trim(), address: _addrC.text.trim());
    // اگلی بار کے لیے یاد رکھیں (کیمرے کی دستی لوکیشن آن/آف کو نہیں چھیڑتے)
    if (remember) {
      s.update(() {
        s.mLat = lat;
        s.mLon = lon;
        s.mTitle = _titleC.text.trim();
        s.mAddress = _addrC.text.trim();
      });
    }
    FocusScope.of(context).unfocus();
    return true;
  }

  /// موجودہ GPS سے لوکیشن خود لینا؛ نام اور پتہ انٹرنیٹ سے خود نکلتا ہے
  Future<void> _fetchGps() async {
    if (_locating || _saving) return;
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _msg(S.t('Turn on phone location (GPS)', 'فون کی لوکیشن (GPS) آن کریں'));
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _msg(S.t('Allow location permission', 'لوکیشن کی اجازت دیں'));
        return;
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 25),
        ),
      );
      _latC.text = p.latitude.toStringAsFixed(6);
      _lonC.text = p.longitude.toStringAsFixed(6);
      _titleC.clear();
      _addrC.clear();
      _applyLocation(remember: false);
    } catch (e) {
      _msg(S.t('GPS location not available yet', 'GPS لوکیشن ابھی نہیں ملی'));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// نقشہ اور پتہ (انٹرنیٹ سے) آنے کا تھوڑا انتظار، زیادہ سے زیادہ 7 سیکنڈ
  Future<void> _waitReady() async {
    final needMap = s.showMap && _template != 1;
    final needTitle = _titleC.text.trim().isEmpty;
    for (var i = 0; i < 35; i++) {
      final g = loc.state.value;
      final mapOk = !needMap || g.tile != null;
      final titleOk = !needTitle || g.title.isNotEmpty;
      if (mapOk && titleOk) return;
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  // ---------------- اسٹیمپ ----------------
  int get _template => s.template == 3 ? 0 : s.template; // کمپاس تصویر کی سمت کے لیے ہے، یہاں بے معنی

  StampData _data(GeoState g) => StampData(
        title: g.title.isNotEmpty ? g.title : (g.hasFix ? g.plusCode : ''),
        address: g.fullAddress,
        latLon: g.hasFix ? g.latLonText : '',
        dateLine: StampData.fullLine(_now), // آج کی تاریخ + فون کا وقت
        note: s.showNote ? s.note : '',
        flag: g.flag,
        time: _now,
        map: g.tile,
        mapOverlay: g.overlay,
        mapFx: g.fx,
        mapFy: g.fy,
        qrData: g.hasFix ? 'https://maps.google.com/?q=${g.lat},${g.lon}' : '',
      );

  Future<void> _save() async {
    final f = _file;
    if (f == null || _saving) return;
    if (!_applyLocation()) return;

    setState(() {
      _saving = true;
      _error = null;
      _savedPath = null;
    });

    try {
      await _waitReady();

      // پریویو (اسٹیمپ) سکرین پر ہو تاکہ صحیح رینڈر ہو
      if (_scroll.hasClients) _scroll.jumpTo(0);

      // محفوظ کرنے کے عین لمحے کا وقت
      _now = DateTime.now();
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;

      final boundary = _stampKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final maxW = AppSettings.maxWidths[s.quality];
      final ui.Image stampImg = await boundary.toImage(pixelRatio: maxW / boundary.size.width);
      final bd = await stampImg.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) throw Exception(S.t('Could not create stamp', 'اسٹیمپ نہیں بن سکا'));
      final stampPng = Uint8List.fromList(bd.buffer.asUint8List());

      // قطار اصل فائل کو اپنی جگہ لے جاتی ہے، اس لیے کاپی دیں تاکہ منتخب تصویر قائم رہے
      final tmp = await getTemporaryDirectory();
      final srcCopy = '${tmp.path}/gs_${DateTime.now().microsecondsSinceEpoch}.jpg';
      f.copySync(srcCopy);

      final g = loc.state.value;
      final snapTime = _now;
      final photos = PhotoStore.saveDir();
      final name = s.buildFileName(snapTime, g.lat, g.lon);
      var outPath = '${photos.path}/$name';
      var n = 1;
      while (File(outPath).existsSync() || PhotoQueue.instance.reserved.contains(outPath)) {
        final base = name.substring(0, name.length - 4);
        outPath = '${photos.path}/${base}_$n.jpg';
        n++;
      }
      s.update(() => s.seq++);

      // کراپ نہ ہو: تصویر کا اپنا ریشو دیں (آڑی تصویر کے لیے قطار خود الٹ لیتی ہے)
      final ratio = _aspect > 1 ? 1 / _aspect : _aspect;

      _pendingOut = outPath;
      await PhotoQueue.instance.enqueue(
        srcPath: srcCopy,
        stamp: stampPng,
        outPath: outPath,
        ratio: ratio,
        maxWidth: maxW,
        quality: AppSettings.jpgQuality[s.quality],
        mirror: false,
        lat: g.lat,
        lon: g.lon,
        time: snapTime,
        title: g.title,
        saveOriginal: false, // گیلری سے لی گئی تصویر کی دوسری کاپی نہیں بنانی
        saveGallery: s.saveGallery,
        shareAfter: false,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _pendingOut = null;
          _error = S.t('Error: $e', 'خرابی: $e');
        });
      }
    }
  }

  void _onResult(QueueResult r) {
    if (!mounted || r.outPath != _pendingOut) return;
    setState(() {
      _saving = false;
      _pendingOut = null;
      if (r.ok) {
        _savedPath = r.outPath;
      } else {
        _error = S.t('Photo could not be processed', 'تصویر پروسیس نہیں ہو سکی');
      }
    });
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.t('Stamp a gallery photo', 'گیلری کی تصویر پر اسٹیمپ'))),
      bottomNavigationBar: const SafeArea(child: AdBanner()),
      body: _file == null ? _empty() : _editor(),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.add_photo_alternate_outlined, size: 72, color: Colors.black38),
            const SizedBox(height: 12),
            Text(
              S.t('Choose a photo from your gallery', 'اپنی گیلری سے تصویر منتخب کریں'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.photo_library),
              label: Text(S.t('Select photo', 'تصویر منتخب کریں')),
            ),
          ]),
        ),
      );

  Widget _editor() {
    return ListenableBuilder(
      listenable: Listenable.merge([s, loc.state]),
      builder: (context, _) {
        final g = loc.state.value;
        return SingleChildScrollView(
          controller: _scroll,
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // تصویر + اسٹیمپ کا پریویو
            AspectRatio(
              aspectRatio: _aspect,
              child: Stack(fit: StackFit.expand, children: [
                Image.file(_file!, fit: BoxFit.cover, cacheWidth: 1400, gaplessPlayback: true),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: RepaintBoundary(
                    key: _stampKey,
                    child: StampWidget(
                      d: _data(g),
                      template: _template,
                      showMap: s.showMap,
                      showLogo: s.showLogo,
                    ),
                  ),
                ),
                if (_saving)
                  const ColoredBox(
                    color: Colors.black45,
                    child: Center(child: CircularProgressIndicator(color: Color(0xFFFFC400))),
                  ),
              ]),
            ),

            // تاریخ و وقت (خودکار)
            Container(
              color: const Color(0xFFFFF4CC),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(children: [
                const Icon(Icons.access_time, size: 18, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      StampData.fullLine(_now),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
              child: Text(
                S.t('Date and time are taken from your phone when you press Save.',
                    'تاریخ اور وقت فون سے، محفوظ کرنے کے لمحے کا لگے گا۔'),
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ),

            // دستی لوکیشن
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Column(children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: (_saving || _locating) ? null : _fetchGps,
                    icon: _locating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location),
                    label: Text(_locating
                        ? S.t('Getting location...', 'لوکیشن لی جا رہی ہے...')
                        : S.t('Get location automatically (GPS)', 'لوکیشن خودکار لیں (GPS)')),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _titleC,
                  decoration: InputDecoration(
                    labelText: S.t('Place name', 'جگہ کا نام'),
                  ),
                ),
                TextField(
                  controller: _addrC,
                  maxLines: 2,
                  decoration: InputDecoration(labelText: S.t('Address', 'پتہ')),
                ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _latC,
                      textDirection: TextDirection.ltr,
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                      decoration: const InputDecoration(labelText: 'Latitude'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _lonC,
                      textDirection: TextDirection.ltr,
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                      decoration: const InputDecoration(labelText: 'Longitude'),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    S.t('Leave place name empty to find it automatically from internet.',
                        'جگہ کا نام خالی چھوڑیں تو انٹرنیٹ سے خود نکل آئے گا۔'),
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : () => _applyLocation(),
                    icon: const Icon(Icons.edit_location_alt),
                    label: Text(S.t('Apply location to preview', 'لوکیشن پریویو میں لگائیں')),
                  ),
                ),
              ]),
            ),

            // محفوظ کرنا
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _pick,
                    icon: const Icon(Icons.photo_library),
                    label: Text(S.t('Change photo', 'دوسری تصویر')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_alt),
                    label: Text(_saving
                        ? S.t('Saving...', 'محفوظ ہو رہی ہے...')
                        : S.t('Stamp & Save', 'اسٹیمپ لگا کر محفوظ کریں')),
                  ),
                ),
              ]),
            ),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_savedPath != null)
              Container(
                margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F6EA),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(S.t('Photo saved ✓', 'تصویر محفوظ ہو گئی ✓'),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  TextButton.icon(
                    onPressed: () => Share.shareXFiles([XFile(_savedPath!)]),
                    icon: const Icon(Icons.share, size: 18),
                    label: Text(S.t('Share', 'شیئر')),
                  ),
                ]),
              ),
            const SizedBox(height: 16),
          ],
          ),
        );
      },
    );
  }
}

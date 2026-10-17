import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Desktop "go back": the Esc key, and a two-finger swipe to the right on the
/// laptop touchpad (the browser way). [onBack] does the actual step back.
///
/// Esc inside a dialog or menu never reaches this -- those are separate
/// routes and close themselves first.
class BackGestures extends StatefulWidget {
  const BackGestures({super.key, required this.onBack, required this.child});

  final VoidCallback onBack;
  final Widget child;

  /// How far (logical px) the fingers must travel sideways for one step back.
  static const double swipeDistance = 90;

  /// A touchpad keeps sending scroll events for a moment after the fingers
  /// lift (inertia). One swipe is one step back, so after it fires we wait
  /// for this much quiet before listening again.
  static const Duration quiet = Duration(milliseconds: 350);

  @override
  State<BackGestures> createState() => _BackGesturesState();
}

class _BackGesturesState extends State<BackGestures> {
  double _sideways = 0;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _fired = false;

  /// [dx] is how far the fingers moved to the right (+) or left (-);
  /// [dy] the same, up/down. Returns nothing: it only decides when to fire.
  void _fingers(double dx, double dy, DateTime now) {
    if (now.difference(_last) > BackGestures.quiet) {
      _sideways = 0;
      _fired = false;
    }
    _last = now;
    if (_fired) return;
    // Mostly-vertical movement is an ordinary scroll, not a swipe.
    if (dx.abs() <= dy.abs() * 1.5) {
      _sideways = 0;
      return;
    }
    _sideways += dx;
    if (_sideways >= BackGestures.swipeDistance) {
      _fired = true;
      widget.onBack();
    } else if (_sideways < 0) {
      _sideways = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onBack,
      },
      child: Listener(
        // Two fingers on a touchpad arrive as scroll events. The content
        // follows the fingers, so fingers moving right = a negative dx.
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            _fingers(
              -event.scrollDelta.dx,
              -event.scrollDelta.dy,
              DateTime.now(),
            );
          }
        },
        // Some platforms report the same gesture as a pan instead.
        onPointerPanZoomUpdate: (event) {
          _fingers(event.panDelta.dx, event.panDelta.dy, DateTime.now());
        },
        child: widget.child,
      ),
    );
  }
}

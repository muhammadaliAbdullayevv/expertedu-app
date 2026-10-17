import 'package:flutter/widgets.dart';

/// Material 3's "expanded" window class. From here on the app uses its
/// desktop layout: a side rail instead of the bottom bar, the full-width
/// home dashboard, and the desktop-only screens (Qarzdorlar). Decided by
/// window width rather than OS, so a narrow desktop window gets the phone
/// layout and a landscape tablet gets the desktop one.
const double kWideLayoutBreakpoint = 840;

bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;

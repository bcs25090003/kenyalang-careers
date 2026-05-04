import 'package:flutter/material.dart';

import 'auth_google_button_stub.dart'
    if (dart.library.html) 'auth_google_button_web.dart' as impl;

/// Platform Google auth control: GIS [renderButton] on web, Material button elsewhere.
Widget buildAuthGoogleButton({
  required bool busy,
  required bool isLogin,
  required VoidCallback onMobilePressed,
}) {
  return impl.buildAuthGoogleButton(
    busy: busy,
    isLogin: isLogin,
    onMobilePressed: onMobilePressed,
  );
}

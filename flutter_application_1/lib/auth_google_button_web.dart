import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart';

/// GIS button built once per [State] so [renderButton] is not recreated every parent rebuild
/// (avoids extra DOM / duplicate client work when login vs register toggles).
class _WebGsiButtonHost extends StatefulWidget {
  const _WebGsiButtonHost({required this.busy});

  final bool busy;

  @override
  State<_WebGsiButtonHost> createState() => _WebGsiButtonHostState();
}

class _WebGsiButtonHostState extends State<_WebGsiButtonHost> {
  /// Stable label avoids rebuilding GIS with a new configuration key on each frame.
  late final Widget _gsiButton = renderButton(
    configuration: GSIButtonConfiguration(
      type: GSIButtonType.standard,
      theme: GSIButtonTheme.outline,
      size: GSIButtonSize.large,
      text: GSIButtonText.continueWith,
      shape: GSIButtonShape.rectangular,
      minimumWidth: 320,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            ignoring: widget.busy,
            child: Opacity(
              opacity: widget.busy ? 0.55 : 1,
              child: Center(child: _gsiButton),
            ),
          ),
          if (widget.busy)
            const IgnorePointer(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

Widget buildAuthGoogleButton({
  required bool busy,
  required bool isLogin,
  required VoidCallback onMobilePressed,
}) {
  return _WebGsiButtonHost(busy: busy);
}

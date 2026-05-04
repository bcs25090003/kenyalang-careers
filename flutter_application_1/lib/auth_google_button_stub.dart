import 'package:flutter/material.dart';

Widget buildAuthGoogleButton({
  required bool busy,
  required bool isLogin,
  required VoidCallback onMobilePressed,
}) {
  final label = isLogin ? "Sign in with Google" : "Sign up with Google";
  return SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      onPressed: busy ? null : onMobilePressed,
      icon: const Icon(Icons.g_mobiledata, color: Colors.white, size: 30),
      label: Text(label, style: const TextStyle(color: Colors.white)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Colors.white),
        padding: const EdgeInsets.all(15),
      ),
    ),
  );
}

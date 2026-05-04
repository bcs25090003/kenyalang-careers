import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'auth_google_button.dart';
import 'open_doc_stub.dart' if (dart.library.html) 'open_doc_web.dart' as open_doc;

void main() {
  runApp(const KenyalangCareersApp());
}

// ==========================================
// GLOBAL DATABASES & STATE (BLANK SLATE)
// ==========================================
List<Map<String, dynamic>> notifications = [];
List<Map<String, dynamic>> talentPool = [];

// User's Resume Data
Map<String, String> myResumeData = {
  "name": "", "phone": "", "edu": "", "exp": "", "skills": "",
  "id": "", "age": "", "address": "", "personalWord": "", 
  "ic_doc": "", "transcript_doc": ""
};

// User's Profile Account Data
Map<String, String> myProfileData = {
  "name": "", "email": "", "password": "", "phone": "", "address": "", "govId": "", "about": "", "idDocName": "",
};

// Global App States
bool isVerifiedEmployer = true; 
bool isOpenToWork = false; 

// ==========================================
// API CLIENT (Flutter -> REST API -> MySQL)
// ==========================================
/// Force API base (highest priority), e.g. `flutter run --dart-define=API_BASE_URL=http://192.168.1.10:4000`
const String _kApiBaseUrlOverride = String.fromEnvironment("API_BASE_URL", defaultValue: "");

/// Default production API when [API_BASE_URL] is empty. Override per deploy, e.g.
/// `flutter build web --dart-define=API_BASE_URL_DEFAULT=https://your-api.onrender.com`
const String _kApiProdDefault = String.fromEnvironment(
  "API_BASE_URL_DEFAULT",
  defaultValue: "https://kenyalang-careers-backend.onrender.com",
);

/// Web OAuth client ID (Google Cloud → Credentials → Web application). Same value as `web/index.html` meta and backend `GOOGLE_OAUTH_WEB_CLIENT_ID`.
const String _kGoogleWebClientId = "77589502545-jr7a3gfsmrh41oq9igcap9du2uf4n0af.apps.googleusercontent.com";

/// Single [GoogleSignIn] for the app — web GIS must not call `id.initialize` more than once per page load.
final GoogleSignIn googleSignInAuth = GoogleSignIn(
  scopes: const ["email", "profile", "openid"],
  clientId: kIsWeb ? _kGoogleWebClientId.trim() : null,
);

String apiBaseUrl() {
  final o = _kApiBaseUrlOverride.trim();
  if (o.isNotEmpty) {
    return o.replaceAll(RegExp(r"/+$"), "");
  }
  return _kApiProdDefault.trim().replaceAll(RegExp(r"/+$"), "");
}

String friendlyApiError(Object e) {
  final s = e.toString();
  if (s.contains("Failed to fetch") ||
      s.contains("ClientException") ||
      s.contains("SocketException") ||
      s.contains("Connection refused") ||
      s.contains("Network is unreachable")) {
    return "Cannot reach the server at ${apiBaseUrl()}.\n\n"
        "• Local dev: start the API (`cd backend` → `npm start`) and/or set\n"
        "  `--dart-define=API_BASE_URL=http://127.0.0.1:4000`.\n"
        "• Production: set `--dart-define=API_BASE_URL_DEFAULT=https://your-api.onrender.com` on `flutter build web`.\n"
        "• **Physical phone** on LAN: `--dart-define=API_BASE_URL=http://192.168.x.x:4000`.";
  }
  return s;
}

int? currentUserId;

/// Mirrors server role after login / role selection.
bool sessionIsEmployer = false;

/// Raw base64 (no `data:` prefix required) for profile photo; set from login + `/users/:id/full`.
String? userAvatarBase64;

void _applyAvatarFromUserMap(Map<String, dynamic>? u) {
  if (u == null) return;
  final av = u["avatarBase64"]?.toString();
  userAvatarBase64 = (av != null && av.isNotEmpty) ? av : null;
}

Uint8List? decodeAvatarBytes(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    var s = raw.trim();
    if (s.contains(',')) s = s.split(',').last;
    return base64Decode(s);
  } catch (_) {
    return null;
  }
}

/// Profile / resume header photo. [onTap] e.g. pick a new image.
Widget userAvatarCircle({
  double radius = 50,
  VoidCallback? onTap,
  IconData fallbackIcon = Icons.person,
}) {
  final bytes = decodeAvatarBytes(userAvatarBase64);
  Widget inner;
  if (bytes != null) {
    inner = ClipOval(
      child: Image.memory(
        bytes,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => ColoredBox(
          color: Colors.white,
          child: Icon(fallbackIcon, size: radius * 0.85, color: const Color(0xFF3D4370)),
        ),
      ),
    );
  } else {
    inner = CircleAvatar(
      radius: radius,
      backgroundColor: Colors.white,
      child: Icon(fallbackIcon, size: radius * 0.85, color: const Color(0xFF3D4370)),
    );
  }
  if (onTap == null) return inner;
  return Material(
    type: MaterialType.transparency,
    child: InkWell(onTap: onTap, customBorder: const CircleBorder(), child: inner),
  );
}

void clearAppSession() {
  currentUserId = null;
  sessionIsEmployer = false;
  userAvatarBase64 = null;
  myProfileData = {
    "name": "",
    "email": "",
    "password": "",
    "phone": "",
    "address": "",
    "govId": "",
    "about": "",
    "idDocName": "",
  };
  myResumeData = {
    "name": "",
    "phone": "",
    "edu": "",
    "exp": "",
    "skills": "",
    "id": "",
    "age": "",
    "address": "",
    "personalWord": "",
    "ic_doc": "",
    "transcript_doc": "",
  };
  notifications.clear();
  talentPool.clear();
  isOpenToWork = false;
}

void applySessionFromLogin(Map<String, dynamic> u) {
  currentUserId = (u["id"] as num).toInt();
  sessionIsEmployer = u["role"]?.toString() == "EMPLOYER";
  _applyAvatarFromUserMap(u);
  myProfileData = {
    "name": u["name"]?.toString() ?? "",
    "email": u["email"]?.toString() ?? "",
    "password": "",
    "phone": u["phone"]?.toString() ?? "",
    "address": u["address"]?.toString() ?? "",
    "govId": u["govId"]?.toString() ?? "",
    "about": u["aboutText"]?.toString() ?? "",
    "idDocName": "",
  };
}

Future<Map<String, dynamic>> fetchUserFullApi(int userId) async {
  final uri = Uri.parse("${apiBaseUrl()}/users/$userId/full");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("fetchUserFull failed: ${res.statusCode} ${res.body}");
  }
  return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
}

Future<void> refreshSessionFromServer() async {
  final id = currentUserId;
  if (id == null) return;
  try {
    final data = await fetchUserFullApi(id);
    final u = data["user"] as Map<String, dynamic>?;
    final sp = data["seekerProfile"] as Map<String, dynamic>?;
    if (u != null) {
      sessionIsEmployer = u["role"]?.toString() == "EMPLOYER";
      _applyAvatarFromUserMap(u);
      myProfileData = {
        "name": u["name"]?.toString() ?? "",
        "email": u["email"]?.toString() ?? "",
        "password": "",
        "phone": u["phone"]?.toString() ?? "",
        "address": u["address"]?.toString() ?? "",
        "govId": u["govId"]?.toString() ?? "",
        "about": u["aboutText"]?.toString() ?? "",
        "idDocName": u["idDocFilename"]?.toString() ?? "",
      };
    }
    if (sp != null) {
      myResumeData["name"] = myProfileData["name"] ?? "";
      myResumeData["id"] = sp["icNumber"]?.toString() ?? "";
      myResumeData["age"] = sp["age"]?.toString() ?? "";
      myResumeData["phone"] = sp["profilePhone"]?.toString() ?? myProfileData["phone"] ?? "";
      myResumeData["address"] = sp["profileAddress"]?.toString() ?? myProfileData["address"] ?? "";
      myResumeData["edu"] = sp["education"]?.toString() ?? "";
      myResumeData["exp"] = sp["experience"]?.toString() ?? "";
      myResumeData["skills"] = sp["skills"]?.toString() ?? "";
      myResumeData["personalWord"] = sp["personalWord"]?.toString() ?? "";
      final icf = sp["icDocFilename"]?.toString();
      myResumeData["ic_doc"] = (icf != null && icf.isNotEmpty) ? icf : "";
      final tf = sp["transcriptDocFilename"]?.toString();
      myResumeData["transcript_doc"] = (tf != null && tf.isNotEmpty) ? tf : "";
      isOpenToWork = (sp["openToWork"] as num?)?.toInt() == 1;
    }
  } catch (_) {
    /* offline */
  }
}

Future<Map<String, dynamic>> registerApi({
  required String email,
  required String password,
  required String name,
  String? phone,
  String? govId,
  bool employer = false,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/auth/register");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "email": email.trim(),
      "password": password,
      "name": name.trim(),
      "role": employer ? "EMPLOYER" : "SEEKER",
      "phone": (phone == null || phone.trim().isEmpty) ? null : phone.trim(),
      "govId": (govId == null || govId.trim().isEmpty) ? null : govId.trim(),
    }),
  );
  if (res.statusCode == 409) {
    final err = jsonDecode(res.body);
    throw Exception(err["error"]?.toString() ?? "Registration conflict");
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("Register failed: ${res.statusCode} ${res.body}");
  }
  return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
}

Future<Map<String, dynamic>> loginApi({required String emailOrPhone, required String password}) async {
  final uri = Uri.parse("${apiBaseUrl()}/auth/login");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"emailOrPhone": emailOrPhone.trim(), "password": password}),
  );
  if (res.statusCode == 401) {
    var msg = "Invalid credentials";
    try {
      final err = jsonDecode(res.body);
      if (err is Map && err["error"] != null) msg = err["error"].toString();
    } catch (_) {}
    throw Exception(msg);
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("Login failed: ${res.statusCode} ${res.body}");
  }
  return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
}

Future<Map<String, dynamic>> googleAuthApi({required String idToken}) async {
  final uri = Uri.parse("${apiBaseUrl()}/auth/google");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"idToken": idToken}),
  );
  if (res.statusCode == 400 || res.statusCode == 401 || res.statusCode == 409 || res.statusCode == 503) {
    var msg = res.body;
    try {
      final err = jsonDecode(res.body);
      if (err is Map && err["error"] != null) msg = err["error"].toString();
    } catch (_) {}
    if (res.statusCode == 503) {
      msg = "$msg\n\nIf this URL is Render: open the service → Logs (503 often means sleeping dyno, crash on boot, or bad env).";
    }
    throw Exception(msg);
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("Google sign-in failed: ${res.statusCode} ${res.body}");
  }
  return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
}

Future<Map<String, dynamic>?> forgotPasswordApi(String emailOrPhone) async {
  final uri = Uri.parse("${apiBaseUrl()}/auth/forgot-password");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"emailOrPhone": emailOrPhone.trim()}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("Request failed: ${res.statusCode} ${res.body}");
  }
  return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
}

Future<void> resetPasswordApi({required String token, required String newPassword}) async {
  final uri = Uri.parse("${apiBaseUrl()}/auth/reset-password");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"token": token, "newPassword": newPassword}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("Reset failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> setUserRoleApi({required int userId, required bool employer}) async {
  final uri = Uri.parse("${apiBaseUrl()}/users/set-role");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"userId": userId, "role": employer ? "EMPLOYER" : "SEEKER"}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("set-role failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> profileUpdateApi({
  required int userId,
  String? name,
  String? phone,
  String? address,
  String? govId,
  String? aboutText,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/users/profile-update");
  final body = <String, dynamic>{"userId": userId};
  if (name != null) body["name"] = name;
  if (phone != null) body["phone"] = phone;
  if (address != null) body["address"] = address;
  if (govId != null) body["govId"] = govId;
  if (aboutText != null) body["aboutText"] = aboutText;
  final res = await http.post(uri, headers: {"Content-Type": "application/json"}, body: jsonEncode(body));
  if (res.statusCode == 409) {
    final err = jsonDecode(res.body);
    throw Exception(err["error"]?.toString() ?? "Profile conflict");
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("profile-update failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> changePasswordApi({
  required int userId,
  required String currentPassword,
  required String newPassword,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/auth/change-password");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "userId": userId,
      "currentPassword": currentPassword,
      "newPassword": newPassword,
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    try {
      final err = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(err["error"]?.toString() ?? res.body);
    } catch (_) {
      throw Exception(res.body);
    }
  }
}

Future<void> uploadSeekerDocsApi({
  required int userId,
  String? icBase64,
  String? icFilename,
  String? transcriptBase64,
  String? transcriptFilename,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/seeker-profiles/upload-docs");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "userId": userId,
      "icBase64": icBase64,
      "icFilename": icFilename,
      "transcriptBase64": transcriptBase64,
      "transcriptFilename": transcriptFilename,
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("upload-docs failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> uploadAvatarApi({required int userId, required String imageBase64}) async {
  final uri = Uri.parse("${apiBaseUrl()}/users/avatar");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"userId": userId, "imageBase64": imageBase64}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("avatar upload failed: ${res.statusCode} ${res.body}");
  }
}

Future<int> ensureUser({required bool isEmployer}) async {
  final uri = Uri.parse("${apiBaseUrl()}/users/ensure");
  final email = (myProfileData["email"] ?? "").trim();
  final name = (myProfileData["name"] ?? "").trim().isNotEmpty
      ? (myProfileData["name"] ?? "").trim()
      : (myResumeData["name"] ?? "").trim();

  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "email": email.isEmpty ? null : email,
      "name": name.isEmpty ? null : name,
      "role": isEmployer ? "EMPLOYER" : "SEEKER",
    }),
  );

  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("ensureUser failed: ${res.statusCode} ${res.body}");
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data["id"] as num).toInt();
}

Future<int> ensureNamedUser({required String name, required String role}) async {
  final uri = Uri.parse("${apiBaseUrl()}/users/ensure");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "email": null,
      "name": name.trim().isEmpty ? "Anonymous" : name.trim(),
      "role": role,
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("ensureNamedUser failed: ${res.statusCode} ${res.body}");
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data["id"] as num).toInt();
}

Future<List<Map<String, dynamic>>> fetchJobs() async {
  final uri = Uri.parse("${apiBaseUrl()}/jobs");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("fetchJobs failed: ${res.statusCode} ${res.body}");
  }
  final list = jsonDecode(res.body) as List;
  return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

Future<void> postJobToApi(Map<String, dynamic> payload) async {
  final uri = Uri.parse("${apiBaseUrl()}/jobs");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode(payload),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("postJob failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> updateJobToApi({
  required int jobId,
  required int employerUserId,
  required String title,
  required String co,
  required String bossName,
  required String loc,
  required String sal,
  required String desc,
  required String employmentType,
  required int maxApps,
  required int maxSlots,
  String? imageBase64,
  String? applicationRequirements,
  String? payBasis,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/jobs/$jobId");
  final enc = <String, dynamic>{
    "employerUserId": employerUserId,
    "title": title,
    "co": co,
    "bossName": bossName,
    "loc": loc,
    "sal": sal,
    "desc": desc,
    "employmentType": employmentType,
    "maxApps": maxApps,
    "maxSlots": maxSlots,
  };
  if (imageBase64 != null) enc["imageBase64"] = imageBase64;
  if (applicationRequirements != null) enc["applicationRequirements"] = applicationRequirements;
  if (payBasis != null) enc["payBasis"] = payBasis;
  final res = await http.patch(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode(enc),
  );
  if (res.statusCode == 403 || res.statusCode == 404) {
    throw Exception("Cannot edit this job (${res.statusCode})");
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("updateJob failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> deleteJobApi({required int jobId, required int employerUserId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/jobs/remove");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"jobId": jobId, "employerUserId": employerUserId}),
  );
  if (res.statusCode == 403 || res.statusCode == 404) {
    throw Exception("Cannot remove this job (${res.statusCode})");
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("deleteJob failed: ${res.statusCode} ${res.body}");
  }
}

String employmentTypeLabel(dynamic raw) {
  switch (raw?.toString()) {
    case "PART_TIME":
      return "Part-time";
    case "INTERNSHIP":
      return "Internship";
    default:
      return "Full-time";
  }
}

/// Backend / JSON often uses 0/1 for flags; `v != true` wrongly treats `1` as unread.
bool apiReadBool(dynamic isReadField) {
  if (isReadField == true) return true;
  if (isReadField == false || isReadField == null) return false;
  if (isReadField is num) return isReadField.toInt() != 0;
  return false;
}

String payBasisLabel(dynamic raw) {
  switch (raw?.toString()) {
    case "HOURLY":
      return "per hour";
    case "DAILY":
      return "per day";
    case "MONTHLY":
      return "per month";
    case "OTHER":
      return "other / negotiated";
    default:
      return "";
  }
}

String payAmountLine(Map<String, dynamic> job) {
  final sal = (job["sal"]?.toString() ?? "").trim();
  final pb = payBasisLabel(job["payBasis"]);
  if (sal.isEmpty) return pb.isEmpty ? "—" : pb;
  if (pb.isEmpty) return sal;
  return "$sal ($pb)";
}

/// Stores salary as "MYR …" only. Legacy SGD/USD/EUR prefixes are replaced with MYR on save.
String formatPayForApi(String amountRaw) {
  const myr = "MYR";
  final amt = amountRaw.trim();
  if (amt.isEmpty) return myr;
  if (RegExp(r"^MYR\b", caseSensitive: false).hasMatch(amt)) {
    final rest = amt.replaceFirst(RegExp(r"^MYR\b\s*", caseSensitive: false), "").trim();
    return rest.isEmpty ? myr : "$myr $rest";
  }
  if (RegExp(r"^RM\b", caseSensitive: false).hasMatch(amt)) {
    final rest = amt.replaceFirst(RegExp(r"^RM\b\s*", caseSensitive: false), "").trim();
    return rest.isEmpty ? myr : "$myr $rest";
  }
  if (RegExp(r"^(SGD|USD|EUR)\b", caseSensitive: false).hasMatch(amt)) {
    final rest = amt.replaceFirst(RegExp(r"^(SGD|USD|EUR)\b\s*", caseSensitive: false), "").trim();
    return rest.isEmpty ? myr : "$myr $rest";
  }
  return "$myr $amt";
}

/// Amount text for editing; strips any stored currency prefix (including legacy foreign codes).
String parsePayAmountForEdit(String sal) {
  final t = sal.trim();
  if (t.isEmpty) return "";
  if (RegExp(r"^(MYR|SGD|USD|EUR|RM)\b", caseSensitive: false).hasMatch(t)) {
    return t.replaceFirst(RegExp(r"^(MYR|SGD|USD|EUR|RM)\b\s*", caseSensitive: false), "").trim();
  }
  return t;
}

Future<String> generateJobDescriptionApi({
  required String title,
  required String co,
  required String loc,
  required String sal,
  required String employmentType,
  String extraNotes = "",
  String payBasis = "UNSPECIFIED",
  String applicationRequirements = "",
  String hiringManagerName = "",
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/ai/job-description");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "title": title,
      "jobTitle": title,
      "co": co,
      "loc": loc,
      "sal": sal,
      "employmentType": employmentType,
      "extraNotes": extraNotes,
      "payBasis": payBasis,
      if (applicationRequirements.trim().isNotEmpty) "applicationRequirements": applicationRequirements.trim(),
      if (hiringManagerName.trim().isNotEmpty) "hiringManagerName": hiringManagerName.trim(),
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    var detail = res.body;
    try {
      final err = jsonDecode(res.body);
      if (err is Map) {
        final m = err["message"]?.toString();
        final code = err["error"]?.toString();
        if (m != null && m.isNotEmpty) {
          detail = code != null && code.isNotEmpty ? "$code: $m" : m;
        } else if (code != null && code.isNotEmpty) {
          detail = code;
        }
      }
    } catch (_) {}
    throw Exception("AI job description failed (${res.statusCode}): $detail");
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return data["text"]?.toString() ?? "";
}

Future<Map<String, dynamic>> fetchProfileReadyApi(int userId) async {
  final uri = Uri.parse("${apiBaseUrl()}/users/$userId/profile-ready");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("profile-ready failed: ${res.statusCode} ${res.body}");
  }
  return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
}

Future<Map<String, String>> generateFormalInboxDraftApi({
  required String jobTitle,
  required String company,
  required String recipientLabel,
  required String intent,
  required String notes,
  required bool isEmployer,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/ai/formal-message");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "jobTitle": jobTitle,
      "company": company,
      "recipientLabel": recipientLabel,
      "intent": intent,
      "notes": notes,
      "isEmployer": isEmployer,
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("AI formal message failed: ${res.statusCode} ${res.body}");
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return {
    "title": data["title"]?.toString() ?? "",
    "body": data["body"]?.toString() ?? "",
  };
}

Future<void> uploadUserIdDocApi({required int userId, required String imageBase64, String filename = "id"}) async {
  final uri = Uri.parse("${apiBaseUrl()}/users/id-doc");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"userId": userId, "imageBase64": imageBase64, "filename": filename}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("id-doc failed: ${res.statusCode} ${res.body}");
  }
}

Future<Map<String, dynamic>> fetchJobContactForSeekerApi({required int jobId, required int seekerUserId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/jobs/$jobId/contact-for-seeker?seekerUserId=$seekerUserId");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("contact failed: ${res.statusCode} ${res.body}");
  }
  return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
}

Future<void> rejectApplicationApi({required int applicationId, required int employerUserId, String reason = ""}) async {
  final uri = Uri.parse("${apiBaseUrl()}/applications/$applicationId/reject");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"employerUserId": employerUserId, "reason": reason}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("reject failed: ${res.statusCode} ${res.body}");
  }
}

Future<List<Map<String, dynamic>>> fetchInboxApi({required int userId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/inbox?userId=$userId");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("inbox failed: ${res.statusCode} ${res.body}");
  }
  final list = jsonDecode(res.body) as List;
  return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

Future<void> markInboxReadApi({required int userId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/inbox/mark-read");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"userId": userId}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("inbox mark-read failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> markOneInboxReadApi({required int userId, required int messageId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/inbox/mark-one-read");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"userId": userId, "messageId": messageId}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("inbox mark-one-read failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> deleteInboxMessageApi({required int userId, required int messageId}) async {
  final base = apiBaseUrl();
  final headers = {"Content-Type": "application/json"};
  final body = jsonEncode({"userId": userId, "messageId": messageId});

  Future<http.Response> postPath(String path) => http.post(Uri.parse("$base$path"), headers: headers, body: body);

  // Try every POST path the backend may expose (stale servers often miss one route).
  const postPaths = [
    "/inbox/delete",
    "/formal-inbox/remove",
    "/inbox/remove",
    "/formalinbox/remove",
  ];
  final tried = <String>[];
  for (final p in postPaths) {
    final r = await postPath(p);
    tried.add("$p→${r.statusCode}");
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    if (r.statusCode != 404 && r.statusCode != 405) {
      throw Exception("inbox delete failed ($p): ${r.statusCode} ${r.body}");
    }
  }
  final del = await http.delete(
    Uri.parse("$base/inbox/$messageId"),
    headers: headers,
    body: jsonEncode({"userId": userId}),
  );
  tried.add("DELETE/inbox/$messageId→${del.statusCode}");
  if (del.statusCode >= 200 && del.statusCode < 300) return;
  throw Exception(
    "inbox delete failed. Tried: ${tried.join(" ")}\n"
    "Last body: ${del.body}\n\n"
    "Restart the API: cd backend && npm start — then open $base/health "
    "(apiBuild should be 2026-05-03-inbox-delete-routes or newer). "
    "If the API uses another port, run Flutter with --dart-define=API_BASE_URL=…",
  );
}

Future<void> sendFormalInboxApi({
  required int senderUserId,
  required int recipientUserId,
  required int jobId,
  required String body,
  String? title,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/inbox/send");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "senderUserId": senderUserId,
      "recipientUserId": recipientUserId,
      "jobId": jobId,
      "title": title,
      "body": body,
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("inbox send failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> applyToJobApi({
  required int jobId,
  required int seekerUserId,
  String? personalWord,
  List<Map<String, dynamic>>? applicantExtras,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/jobs/$jobId/apply");
  final payload = <String, dynamic>{"seekerUserId": seekerUserId};
  if (personalWord != null && personalWord.trim().isNotEmpty) payload["personalWord"] = personalWord.trim();
  if (applicantExtras != null && applicantExtras.isNotEmpty) payload["applicantExtras"] = applicantExtras;
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode(payload),
  );
  if (res.statusCode == 409) {
    throw Exception("Already applied / job full");
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("apply failed: ${res.statusCode} ${res.body}");
  }
}

Future<List<Map<String, dynamic>>> fetchNotificationsApi({required int userId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/notifications?userId=$userId");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("fetchNotifications failed: ${res.statusCode} ${res.body}");
  }
  final list = jsonDecode(res.body) as List;
  return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

Future<void> markNotificationsReadApi({required int userId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/notifications/mark-read");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"userId": userId}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("mark-read failed: ${res.statusCode} ${res.body}");
  }
}

Future<void> deleteNotificationApi({required int userId, required int notificationId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/notification/remove");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"userId": userId, "notificationId": notificationId}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("notification delete failed: ${res.statusCode} ${res.body}");
  }
}

Future<List<Map<String, dynamic>>> fetchInterviewsApi({required int userId, required bool isEmployer}) async {
  final role = isEmployer ? "EMPLOYER" : "SEEKER";
  final uri = Uri.parse("${apiBaseUrl()}/interviews?userId=$userId&role=$role");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("fetchInterviews failed: ${res.statusCode} ${res.body}");
  }
  final list = jsonDecode(res.body) as List;
  return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

Future<void> markInterviewMessagesReadApi({required int interviewId, required int userId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/interviews/$interviewId/messages/mark-read");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"userId": userId}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("mark-read failed: ${res.statusCode} ${res.body}");
  }
}

Future<int> createInterviewApi({
  required int employerUserId,
  required int seekerUserId,
  int? jobId,
  required String platform,
  required String datetime,
  required String link,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/interviews");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "jobId": jobId,
      "employerUserId": employerUserId,
      "seekerUserId": seekerUserId,
      "platform": platform,
      "datetime": datetime,
      "link": link,
      "status": "Pending Seeker",
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("createInterview failed: ${res.statusCode} ${res.body}");
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data["id"] as num).toInt();
}

Future<void> updateInterviewApi({
  required int interviewId,
  required int actorUserId,
  String? datetime,
  String? proposedDatetime,
  String? link,
  String? status,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/interviews/$interviewId/update");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "actorUserId": actorUserId,
      "datetime": datetime,
      "proposedDatetime": proposedDatetime,
      "link": link,
      "status": status,
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("updateInterview failed: ${res.statusCode} ${res.body}");
  }
}

Future<List<Map<String, dynamic>>> fetchInterviewMessagesApi({required int interviewId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/interviews/$interviewId/messages");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("fetchMessages failed: ${res.statusCode} ${res.body}");
  }
  final list = jsonDecode(res.body) as List;
  return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

Future<void> sendInterviewMessageApi({required int interviewId, required int senderUserId, required String text}) async {
  final uri = Uri.parse("${apiBaseUrl()}/interviews/$interviewId/messages");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({"senderUserId": senderUserId, "text": text}),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("sendMessage failed: ${res.statusCode} ${res.body}");
  }
}

Future<bool> hasAppliedApi({required int jobId, required int seekerUserId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/applications/has-applied?jobId=$jobId&seekerUserId=$seekerUserId");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("hasApplied failed: ${res.statusCode} ${res.body}");
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return data["applied"] == true;
}

Future<List<Map<String, dynamic>>> fetchEmployerApplicationsApi({required int employerUserId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/applications/for-employer?employerUserId=$employerUserId");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("fetchEmployerApplications failed: ${res.statusCode} ${res.body}");
  }
  final list = jsonDecode(res.body) as List;
  return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

Future<Map<String, dynamic>> fetchApplicationDocumentsForEmployerApi({
  required int applicationId,
  required int employerUserId,
}) async {
  final uri = Uri.parse(
    "${apiBaseUrl()}/applications/$applicationId/documents-for-employer?employerUserId=$employerUserId",
  );
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("fetchApplicationDocuments failed: ${res.statusCode} ${res.body}");
  }
  return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
}

Future<List<Map<String, dynamic>>> fetchSeekerApplicationsApi({required int seekerUserId}) async {
  final uri = Uri.parse("${apiBaseUrl()}/applications/for-seeker?seekerUserId=$seekerUserId");
  final res = await http.get(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("fetchSeekerApplications failed: ${res.statusCode} ${res.body}");
  }
  final list = jsonDecode(res.body) as List;
  return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

Future<void> upsertSeekerProfileApi({
  required int userId,
  String? name,
  String? icNumber,
  String? age,
  String? phone,
  String? address,
  String? education,
  String? experience,
  String? skills,
  String? personalWord,
  required bool openToWork,
}) async {
  final uri = Uri.parse("${apiBaseUrl()}/seeker-profiles/upsert");
  final res = await http.post(
    uri,
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "userId": userId,
      "name": name,
      "icNumber": icNumber,
      "age": age,
      "phone": phone,
      "address": address,
      "education": education,
      "experience": experience,
      "skills": skills,
      "personalWord": personalWord,
      "openToWork": openToWork ? 1 : 0,
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception("upsertSeekerProfile failed: ${res.statusCode} ${res.body}");
  }
}

// Notification Engine (with unread tracking)
void addNotification(String title, String time, {String? type, Map<String, dynamic>? data}) {
  notifications.insert(0, {
    "title": title,
    "time": time,
    "type": type ?? "info",
    "isRead": false,
    "data": data ?? {},
  });
}

int unreadNotificationCount() {
  return notifications.where((n) => !apiReadBool(n["isRead"])).length;
}

void markAllNotificationsRead() {
  for (final n in notifications) {
    n["isRead"] = true;
  }
}

class KenyalangCareersApp extends StatefulWidget {
  const KenyalangCareersApp({super.key});

  @override
  State<KenyalangCareersApp> createState() => _KenyalangCareersAppState();
}

class _KenyalangCareersAppState extends State<KenyalangCareersApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Kenyalang Careers',
      theme: ThemeData(
        primaryColor: const Color(0xFF3D4370),
        scaffoldBackgroundColor: const Color(0xFF1A1C2C),
        fontFamily: 'Roboto',
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const AuthPage(),
        '/role': (context) => const RoleSelectionPage(),
        '/onboarding-seeker': (context) => const SeekerOnboardingPage(),
        '/home': (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          var emp = sessionIsEmployer;
          if (args is Map && args['isEmployer'] is bool) {
            emp = args['isEmployer'] as bool;
          }
          return HomePage(isEmployer: emp);
        },
        '/notifications': (context) => const NotificationHub(),
      },
    );
  }
}

// Universal Gradient Background
Widget _bg({required Widget child}) {
  return Container(
    width: double.infinity, 
    height: double.infinity,
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter, 
        end: Alignment.bottomCenter, 
        colors: [Color(0xFF1A1C2C), Color(0xFF2D3436)]
      )
    ),
    child: child,
  );
}

// ==========================================
// 1. AUTHENTICATION & SECURITY
// ==========================================
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  bool isLogin = true;
  bool _busy = false;
  bool _hidePassword = true;
  bool _hideConfirmPassword = true;
  /// Sign-up only: account type (employers skip the role picker).
  bool _registerAsEmployer = false;

  StreamSubscription<GoogleSignInAccount?>? _googleWebUserSub;
  bool _handlingGoogleWeb = false;

  final _emailOrPhoneC = TextEditingController();
  final _passwordC = TextEditingController();
  final _nameC = TextEditingController();
  final _phoneC = TextEditingController();
  final _govIdC = TextEditingController();
  final _confirmPassC = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _googleWebUserSub = googleSignInAuth.onCurrentUserChanged.listen(_onGoogleWebUserChanged);
    }
  }

  @override
  void dispose() {
    _googleWebUserSub?.cancel();
    _emailOrPhoneC.dispose();
    _passwordC.dispose();
    _nameC.dispose();
    _phoneC.dispose();
    _govIdC.dispose();
    _confirmPassC.dispose();
    super.dispose();
  }

  Future<void> _afterAuthNavigate() async {
    await refreshSessionFromServer();
    if (!mounted) return;
    final u = await _routeAfterAuth();
    if (!mounted) return;
    if (u == _AuthRoute.homeEmployer) {
      Navigator.pushReplacementNamed(context, '/home', arguments: {'isEmployer': true});
    } else if (u == _AuthRoute.homeSeeker) {
      Navigator.pushReplacementNamed(context, '/home', arguments: {'isEmployer': false});
    } else if (u == _AuthRoute.role) {
      Navigator.pushReplacementNamed(context, '/role');
    } else if (u == _AuthRoute.onboarding) {
      Navigator.pushReplacementNamed(context, '/onboarding-seeker');
    }
  }

  /// Post-login routing using server role and seeker profile completeness.
  Future<_AuthRoute> _routeAfterAuth() async {
    if (currentUserId == null) return _AuthRoute.role;
    if (sessionIsEmployer) return _AuthRoute.homeEmployer;
    try {
      final data = await fetchUserFullApi(currentUserId!);
      final sp = data["seekerProfile"] as Map<String, dynamic>?;
      final ic = sp?["icNumber"]?.toString().trim() ?? "";
      final age = sp?["age"]?.toString().trim() ?? "";
      if (ic.isEmpty || age.isEmpty) return _AuthRoute.onboarding;
    } catch (_) {
      return _AuthRoute.onboarding;
    }
    return _AuthRoute.homeSeeker;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (isLogin) {
        if (_emailOrPhoneC.text.trim().isEmpty || _passwordC.text.isEmpty) {
          throw Exception("Enter email or phone and password");
        }
        final row = await loginApi(emailOrPhone: _emailOrPhoneC.text, password: _passwordC.text);
        applySessionFromLogin(row);
        await _afterAuthNavigate();
      } else {
        if (_nameC.text.trim().isEmpty || _emailOrPhoneC.text.trim().isEmpty || _passwordC.text.isEmpty) {
          throw Exception("Name, email, and password are required");
        }
        if (!_emailOrPhoneC.text.contains("@")) {
          throw Exception("Use a valid email to register (phone-only sign-up is not enabled yet)");
        }
        if (_passwordC.text.length < 8) throw Exception("Password must be at least 8 characters");
        if (_passwordC.text != _confirmPassC.text) throw Exception("Passwords do not match");
        final row = await registerApi(
          email: _emailOrPhoneC.text,
          password: _passwordC.text,
          name: _nameC.text,
          phone: _phoneC.text,
          govId: _govIdC.text,
          employer: _registerAsEmployer,
        );
        applySessionFromLogin(row);
        if (!mounted) return;
        await refreshSessionFromServer();
        if (!mounted) return;
        if (_registerAsEmployer) {
          sessionIsEmployer = true;
          addNotification("Welcome to Kenyalang Careers, Employer!", "Just now");
          Navigator.pushReplacementNamed(context, '/home', arguments: {'isEmployer': true});
        } else {
          Navigator.pushReplacementNamed(context, '/role');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyApiError(e)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _authFieldDeco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.grey.shade600),
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF1A1C2C), width: 2),
      ),
    );
  }

  Widget _authLineField({
    required TextEditingController controller,
    required String hint,
    TextInputType? keyboardType,
    bool obscure = false,
    Widget? suffixIcon,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      minLines: 1,
      maxLines: 1,
      textAlignVertical: TextAlignVertical.center,
      style: const TextStyle(fontSize: 16, color: Color(0xFF1a1a2e)),
      decoration: suffixIcon == null ? _authFieldDeco(hint) : _authFieldDeco(hint).copyWith(suffixIcon: suffixIcon),
    );
  }

  Future<void> _forgotPassword() async {
    final emailC = TextEditingController(text: _emailOrPhoneC.text.contains("@") ? _emailOrPhoneC.text : "");
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Reset password"),
        content: TextField(
          controller: emailC,
          decoration: const InputDecoration(
            labelText: "Email or phone number",
            hintText: "Use the email or phone on your account",
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Send link")),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final ident = emailC.text.trim();
    if (ident.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Enter email or phone for your account"), backgroundColor: Colors.red),
      );
      return;
    }
    try {
      final res = await forgotPasswordApi(ident);
      if (!mounted) return;
      final devTok = res?["devResetToken"]?.toString();
      if (devTok != null && devTok.isNotEmpty) {
        final newPassC = TextEditingController();
        final tokC = TextEditingController(text: devTok);
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx2) {
            var hideNewPw = true;
            return StatefulBuilder(
              builder: (ctx3, setLocal) => AlertDialog(
                title: const Text("Development reset"),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        "Email delivery is not configured. Paste the token below and choose a new password (dev only).",
                        style: TextStyle(fontSize: 13),
                      ),
                      TextField(controller: tokC, decoration: const InputDecoration(labelText: "Token")),
                      TextField(
                        controller: newPassC,
                        obscureText: hideNewPw,
                        decoration: InputDecoration(
                          labelText: "New password (8+ chars)",
                          suffixIcon: IconButton(
                            tooltip: hideNewPw ? "Show password" : "Hide password",
                            icon: Icon(hideNewPw ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setLocal(() => hideNewPw = !hideNewPw),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx2, false), child: const Text("Close")),
                  TextButton(onPressed: () => Navigator.pop(ctx2, true), child: const Text("Set password")),
                ],
              ),
            );
          },
        );
        if (go == true && mounted) {
          await resetPasswordApi(token: tokC.text.trim(), newPassword: newPassC.text);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Password updated. You can log in."), backgroundColor: Colors.green),
            );
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res?["message"]?.toString() ?? "Request submitted")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyApiError(e)), backgroundColor: Colors.red, duration: const Duration(seconds: 10)),
        );
      }
    }
  }

  Future<void> _onGoogleWebUserChanged(GoogleSignInAccount? account) async {
    if (!kIsWeb || account == null) return;
    if (_handlingGoogleWeb) return;
    _handlingGoogleWeb = true;
    if (mounted) setState(() => _busy = true);
    try {
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw Exception("Google did not return an ID token. Check OAuth client IDs and consent screen.");
      }
      final row = await googleAuthApi(idToken: idToken);
      applySessionFromLogin(row);
      await _afterAuthNavigate();
    } catch (e) {
      try {
        await googleSignInAuth.signOut();
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyApiError(e)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 12),
          ),
        );
      }
    } finally {
      _handlingGoogleWeb = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Android / iOS: interactive sign-in. Web uses GIS [renderButton] + [onCurrentUserChanged].
  Future<void> _googleSignInMobile() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final account = await googleSignInAuth.signIn();
      if (account == null) {
        return;
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw Exception("Google did not return an ID token. Check OAuth client IDs and consent screen.");
      }
      final row = await googleAuthApi(idToken: idToken);
      applySessionFromLogin(row);
      await _afterAuthNavigate();
    } catch (e) {
      try {
        await googleSignInAuth.signOut();
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyApiError(e)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 12),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _bg(
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 80),
              Text(
                isLogin ? "Login" : "Register",
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(35),
                decoration: const BoxDecoration(
                  color: Color(0xFF3D4370),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(60)),
                ),
                child: Column(
                  children: [
                    if (!isLogin) ...[
                      _authLineField(controller: _nameC, hint: "Full name"),
                      const SizedBox(height: 12),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "I am signing up as a:",
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: const Text("Job seeker"),
                              selected: !_registerAsEmployer,
                              onSelected: _busy ? null : (_) => setState(() => _registerAsEmployer = false),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ChoiceChip(
                              label: const Text("Employer"),
                              selected: _registerAsEmployer,
                              onSelected: _busy ? null : (_) => setState(() => _registerAsEmployer = true),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      _authLineField(
                        controller: _phoneC,
                        hint: "Phone (optional, must be unique if set)",
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 15),
                      _authLineField(controller: _govIdC, hint: "Identity card number (optional, unique)"),
                      const SizedBox(height: 15),
                    ],
                    _authLineField(
                      controller: _emailOrPhoneC,
                      hint: isLogin ? "Email or phone" : "Email",
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 15),
                    _authLineField(
                      controller: _passwordC,
                      hint: "Password (min. 8 characters)",
                      obscure: _hidePassword,
                      suffixIcon: IconButton(
                        tooltip: _hidePassword ? "Show password" : "Hide password",
                        icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hidePassword = !_hidePassword),
                      ),
                    ),
                    if (!isLogin) ...[
                      const SizedBox(height: 15),
                      _authLineField(
                        controller: _confirmPassC,
                        hint: "Confirm password",
                        obscure: _hideConfirmPassword,
                        suffixIcon: IconButton(
                          tooltip: _hideConfirmPassword ? "Show password" : "Hide password",
                          icon: Icon(_hideConfirmPassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _hideConfirmPassword = !_hideConfirmPassword),
                        ),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: isLogin ? _forgotPassword : null,
                        child: const Text("Forgot Password?", style: TextStyle(color: Colors.white70)),
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF3D4370),
                          padding: const EdgeInsets.all(18),
                        ),
                        child: _busy
                            ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(isLogin ? "LOG IN" : "SIGN UP", style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(height: 15),
                    buildAuthGoogleButton(
                      busy: _busy,
                      isLogin: isLogin,
                      onMobilePressed: _googleSignInMobile,
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                isLogin = !isLogin;
                                _hidePassword = true;
                                _hideConfirmPassword = true;
                              }),
                      child: Text(
                        isLogin ? "Create an account" : "Back to Login",
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _AuthRoute { role, onboarding, homeSeeker, homeEmployer }

class RoleSelectionPage extends StatelessWidget {
  const RoleSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _bg(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Employer or job seeker?",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          "Pick one. Job seekers fill in ID, age, and contact details next before using the app.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, height: 1.35),
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: () async {
                          final uid = currentUserId;
                          if (uid == null) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Session missing — log in again"), backgroundColor: Colors.red),
                              );
                            }
                            return;
                          }
                          try {
                            await setUserRoleApi(userId: uid, employer: false);
                            sessionIsEmployer = false;
                            if (!context.mounted) return;
                            Navigator.pushReplacementNamed(context, '/onboarding-seeker');
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("$e"), backgroundColor: Colors.red),
                              );
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF3D4370),
                          minimumSize: const Size(280, 60),
                        ),
                        child: const Text("I am a Job Seeker"),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: () async {
                          final uid = currentUserId;
                          if (uid == null) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Session missing — log in again"), backgroundColor: Colors.red),
                              );
                            }
                            return;
                          }
                          try {
                            await setUserRoleApi(userId: uid, employer: true);
                            sessionIsEmployer = true;
                            addNotification("Welcome to Kenyalang Careers, Employer!", "Just now");
                            if (!context.mounted) return;
                            Navigator.pushReplacementNamed(context, '/home', arguments: {'isEmployer': true});
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("$e"), backgroundColor: Colors.red),
                              );
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF524D66),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(280, 60),
                        ),
                        child: const Text("I am an Employer"),
                      ),
                      const SizedBox(height: 24),
                      TextButton(
                        onPressed: () => Navigator.pushReplacementNamed(context, '/'),
                        child: const Text("Back to login", style: TextStyle(color: Colors.white54)),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class SeekerOnboardingPage extends StatefulWidget {
  const SeekerOnboardingPage({super.key});

  @override
  State<SeekerOnboardingPage> createState() => _SeekerOnboardingPageState();
}

class _SeekerOnboardingPageState extends State<SeekerOnboardingPage> {
  late final TextEditingController _name;
  late final TextEditingController _ic;
  late final TextEditingController _age;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: myProfileData["name"] ?? "");
    _ic = TextEditingController(text: myResumeData["id"] ?? "");
    _age = TextEditingController(text: myResumeData["age"] ?? "");
    _phone = TextEditingController(text: myProfileData["phone"] ?? myResumeData["phone"] ?? "");
    _address = TextEditingController(text: myProfileData["address"] ?? myResumeData["address"] ?? "");
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeSkip());
  }

  Future<void> _maybeSkip() async {
    final uid = currentUserId;
    if (uid == null) return;
    try {
      final data = await fetchUserFullApi(uid);
      final sp = data["seekerProfile"] as Map<String, dynamic>?;
      final ic = sp?["icNumber"]?.toString().trim() ?? "";
      final age = sp?["age"]?.toString().trim() ?? "";
      if (ic.isNotEmpty && age.isNotEmpty && mounted) {
        await refreshSessionFromServer();
        if (mounted) {
          Navigator.pushReplacementNamed(context, '/home', arguments: {'isEmployer': false});
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _name.dispose();
    _ic.dispose();
    _age.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _saveAndContinue() async {
    final uid = currentUserId;
    if (uid == null) return;
    if (_name.text.trim().isEmpty || _ic.text.trim().isEmpty || _age.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Name, identity card number, and age are required"), backgroundColor: Colors.red),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await profileUpdateApi(
        userId: uid,
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        address: _address.text.trim(),
        govId: _ic.text.trim(),
      );
      await upsertSeekerProfileApi(
        userId: uid,
        name: _name.text.trim(),
        icNumber: _ic.text.trim(),
        age: _age.text.trim(),
        phone: _phone.text.trim(),
        address: _address.text.trim(),
        education: myResumeData["edu"],
        experience: myResumeData["exp"],
        skills: myResumeData["skills"],
        personalWord: myResumeData["personalWord"],
        openToWork: isOpenToWork,
      );
      await refreshSessionFromServer();
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/home', arguments: {'isEmployer': false});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _bg(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              const Text(
                "Your details",
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                "We store this in MySQL and use it for applications and your profile.",
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _name,
                style: const TextStyle(color: Colors.white),
                decoration: _onboardDeco("Full name"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ic,
                style: const TextStyle(color: Colors.white),
                decoration: _onboardDeco("Identity card number (one account per number)"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _age,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: _onboardDeco("Age"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                decoration: _onboardDeco("Phone"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _address,
                maxLines: 2,
                style: const TextStyle(color: Colors.white),
                decoration: _onboardDeco("Address"),
              ),
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: _busy ? null : _saveAndContinue,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF3D4370),
                  padding: const EdgeInsets.all(16),
                ),
                child: _busy
                    ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text("Save and continue", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _onboardDeco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white54),
      filled: true,
      fillColor: Colors.white12,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

// ==========================================
// FORMAL INBOX (hire notices & employer messages)
// ==========================================

class FormalInboxMessageScreen extends StatefulWidget {
  final Map<String, dynamic> row;
  final Future<void> Function(Map<String, dynamic> row)? onReply;
  final VoidCallback? onInboxChanged;

  const FormalInboxMessageScreen({
    super.key,
    required this.row,
    this.onReply,
    this.onInboxChanged,
  });

  @override
  State<FormalInboxMessageScreen> createState() => _FormalInboxMessageScreenState();
}

class _FormalInboxMessageScreenState extends State<FormalInboxMessageScreen> {
  @override
  void initState() {
    super.initState();
    final uid = currentUserId;
    final mid = (widget.row["id"] as num?)?.toInt();
    if (uid != null && mid != null && !apiReadBool(widget.row["isRead"])) {
      markOneInboxReadApi(userId: uid, messageId: mid).then((_) {
        widget.onInboxChanged?.call();
      }).catchError((_) {});
    }
  }

  Future<void> _confirmDelete() async {
    final uid = currentUserId;
    final mid = (widget.row["id"] as num?)?.toInt();
    if (uid == null || mid == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete message?"),
        content: const Text("This removes the message from your inbox only."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Delete", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await deleteInboxMessageApi(userId: uid, messageId: mid);
      if (!mounted) return;
      widget.onInboxChanged?.call();
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.row["kind"]?.toString() ?? "";
    final canReply = kind != "rejection_summary" && widget.row["jobId"] != null && widget.row["senderUserId"] != null;
    final jobLine = (widget.row["jobTitle"]?.toString() ?? "").trim();
    final subj = widget.row["title"]?.toString() ?? "Message";
    final body = widget.row["body"]?.toString() ?? "";
    final from = (widget.row["senderName"]?.toString() ?? "").trim();
    final when = (widget.row["createdAt"]?.toString() ?? "").trim();

    return Scaffold(
      backgroundColor: const Color(0xFF1A1C2C),
      appBar: AppBar(
        backgroundColor: const Color(0xFF3D4370),
        foregroundColor: Colors.white,
        title: const Text("Message", style: TextStyle(fontSize: 18)),
        actions: [
          IconButton(tooltip: "Delete", onPressed: _confirmDelete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(subj, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1C2C), height: 1.25)),
                  const SizedBox(height: 12),
                  if (from.isNotEmpty)
                    Text("From: $from", style: const TextStyle(fontSize: 15, color: Color(0xFF3D4370), fontWeight: FontWeight.w600)),
                  if (when.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(when, style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
                    ),
                  if (jobLine.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text("Job: $jobLine", style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Container(
                color: Colors.white,
                width: double.infinity,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                  child: SelectableText(
                    body,
                    style: const TextStyle(fontSize: 17, height: 1.55, color: Color(0xFF222222)),
                  ),
                ),
              ),
            ),
            Material(
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Close"),
                      ),
                    ),
                    if (canReply && widget.onReply != null) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            Navigator.pop(context);
                            await widget.onReply!(widget.row);
                          },
                          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3D4370)),
                          child: const Text("Reply"),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen compose / reply (email-style), not a small dialog.
class FormalComposeScreen extends StatefulWidget {
  final int senderUserId;
  final List<Map<String, dynamic>>? applications;
  final int? replyJobId;
  final int? replyRecipientUserId;
  final String initialSubject;

  const FormalComposeScreen.compose({
    super.key,
    required this.senderUserId,
    required this.applications,
    this.initialSubject = "Formal update",
    this.replyJobId,
    this.replyRecipientUserId,
  }) : assert(replyJobId == null && replyRecipientUserId == null);

  const FormalComposeScreen.reply({
    super.key,
    required this.senderUserId,
    required this.replyJobId,
    required this.replyRecipientUserId,
    required this.initialSubject,
    this.applications,
  }) : assert(applications == null);

  bool get isReply => applications == null;

  @override
  State<FormalComposeScreen> createState() => _FormalComposeScreenState();
}

class _FormalComposeScreenState extends State<FormalComposeScreen> {
  late int _pickIdx;
  late final TextEditingController _titleC;
  late final TextEditingController _bodyC;
  late final TextEditingController _aiNotesC;
  String _aiIntent = "general_update";
  bool _aiBusy = false;
  bool _sendBusy = false;

  @override
  void initState() {
    super.initState();
    _pickIdx = 0;
    _titleC = TextEditingController(text: widget.initialSubject);
    _bodyC = TextEditingController();
    _aiNotesC = TextEditingController();
  }

  @override
  void dispose() {
    _titleC.dispose();
    _bodyC.dispose();
    _aiNotesC.dispose();
    super.dispose();
  }

  Map<String, dynamic> _selectedApp() => widget.applications![_pickIdx];

  String _appLabel(Map<String, dynamic> a) {
    if (sessionIsEmployer) {
      return "${a["jobTitle"]} — ${a["name"]}";
    }
    return "${a["jobTitle"]} — ${a["employerName"] ?? "Employer"}";
  }

  Future<void> _runAi() async {
    setState(() => _aiBusy = true);
    try {
      if (widget.isReply) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("AI draft is available when composing a new message from +."), backgroundColor: Colors.orange),
        );
        return;
      }
      final s = _selectedApp();
      final jobTitle = s["jobTitle"]?.toString() ?? "";
      final company = (s["companyName"]?.toString() ?? "").trim();
      final recipientLabel = sessionIsEmployer
          ? (s["name"]?.toString() ?? "Applicant")
          : (s["employerName"]?.toString() ?? "Hiring team");
      final draft = await generateFormalInboxDraftApi(
        jobTitle: jobTitle,
        company: company.isEmpty ? "Company" : company,
        recipientLabel: recipientLabel,
        intent: _aiIntent,
        notes: _aiNotesC.text,
        isEmployer: sessionIsEmployer,
      );
      final t = draft["title"]?.trim();
      final b = draft["body"]?.trim();
      if (t != null && t.isNotEmpty) _titleC.text = t;
      if (b != null && b.isNotEmpty) _bodyC.text = b;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Future<void> _send() async {
    if (_bodyC.text.trim().isEmpty) return;
    setState(() => _sendBusy = true);
    try {
      int jobId;
      int recipient;
      if (widget.isReply) {
        jobId = widget.replyJobId!;
        recipient = widget.replyRecipientUserId!;
      } else {
        final s = _selectedApp();
        jobId = (s["jobId"] as num?)?.toInt() ?? 0;
        recipient = sessionIsEmployer ? (s["seekerUserId"] as num?)?.toInt() ?? 0 : (s["employerUserId"] as num?)?.toInt() ?? 0;
      }
      if (jobId == 0 || recipient == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Missing job or recipient."), backgroundColor: Colors.red));
        }
        return;
      }
      await sendFormalInboxApi(
        senderUserId: widget.senderUserId,
        recipientUserId: recipient,
        jobId: jobId,
        title: _titleC.text.trim().isEmpty ? null : _titleC.text.trim(),
        body: _bodyC.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.isReply ? "Reply sent" : "Message sent"), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _sendBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const header = Color(0xFF3D4370);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        backgroundColor: header,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.maybePop(context),
          tooltip: "Close",
        ),
        title: Text(widget.isReply ? "Reply" : "New message", style: const TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          TextButton(
            onPressed: _sendBusy ? null : _send,
            child: _sendBusy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text("Send", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!widget.isReply) ...[
                  const Text("To (application)", style: TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<int>(
                    initialValue: _pickIdx,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, filled: true, fillColor: Color(0xFFF9F9F9)),
                    items: List.generate(
                      widget.applications!.length,
                      (i) => DropdownMenuItem(value: i, child: Text(_appLabel(widget.applications![i]), overflow: TextOverflow.ellipsis)),
                    ),
                    onChanged: (v) => setState(() => _pickIdx = v ?? 0),
                  ),
                  const SizedBox(height: 14),
                ],
                const Text("Subject", style: TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                TextField(
                  controller: _titleC,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, filled: true, fillColor: Color(0xFFF9F9F9)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Container(
              color: Colors.white,
              width: double.infinity,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  const Text("Message", style: TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _bodyC,
                    minLines: 12,
                    maxLines: 24,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                      filled: true,
                      fillColor: Color(0xFFFAFAFA),
                      hintText: "Write your message…",
                    ),
                  ),
                  if (!widget.isReply) ...[
                    const SizedBox(height: 28),
                    const Text("Draft with AI (optional)", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _aiIntent,
                      decoration: const InputDecoration(labelText: "Intent", border: OutlineInputBorder(), isDense: true),
                      items: const [
                        DropdownMenuItem(value: "general_update", child: Text("General update")),
                        DropdownMenuItem(value: "interview", child: Text("Interview coordination")),
                        DropdownMenuItem(value: "offer", child: Text("Offer / next steps")),
                        DropdownMenuItem(value: "documents", child: Text("Documents requested")),
                      ],
                      onChanged: (v) => setState(() => _aiIntent = v ?? "general_update"),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _aiNotesC,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: "Notes for AI",
                        hintText: "e.g. propose Tuesday 2pm…",
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _aiBusy
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                          : OutlinedButton.icon(
                              onPressed: _runAi,
                              icon: const Icon(Icons.auto_awesome),
                              label: const Text("Generate subject & body"),
                            ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FormalInboxView extends StatefulWidget {
  final VoidCallback? onInboxChanged;

  const FormalInboxView({super.key, this.onInboxChanged});

  @override
  State<FormalInboxView> createState() => _FormalInboxViewState();
}

class _FormalInboxViewState extends State<FormalInboxView> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final uid = currentUserId;
    if (uid == null) return [];
    return fetchInboxApi(userId: uid);
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _composeNew() async {
    final me = currentUserId;
    if (me == null) return;
    List<Map<String, dynamic>> apps;
    try {
      if (sessionIsEmployer) {
        apps = await fetchEmployerApplicationsApi(employerUserId: me);
      } else {
        apps = await fetchSeekerApplicationsApi(seekerUserId: me);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
      return;
    }
    final open = apps.where((a) => a["status"]?.toString() != "REJECTED").toList();
    if (open.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You need at least one active (non-rejected) application to send a formal message.")),
        );
      }
      return;
    }
    if (!mounted) return;

    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => FormalComposeScreen.compose(senderUserId: me, applications: open),
      ),
    );
    if (mounted) {
      _reload();
      widget.onInboxChanged?.call();
    }
  }

  Future<void> _reply(Map<String, dynamic> r) async {
    final me = currentUserId;
    if (me == null) return;
    final other = (r["senderUserId"] as num?)?.toInt();
    final jobId = (r["jobId"] as num?)?.toInt();
    if (other == null || jobId == null || other == me) return;

    final subj = "Re: ${r["title"] ?? "message"}";
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => FormalComposeScreen.reply(
          senderUserId: me,
          replyJobId: jobId,
          replyRecipientUserId: other,
          initialSubject: subj,
        ),
      ),
    );
    if (mounted) {
      _reload();
      widget.onInboxChanged?.call();
    }
  }

  Future<void> _openDetail(Map<String, dynamic> r) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => FormalInboxMessageScreen(
          row: r,
          onReply: (row) => _reply(row),
          onInboxChanged: widget.onInboxChanged,
        ),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _deleteRow(Map<String, dynamic> r) async {
    final uid = currentUserId;
    final mid = (r["id"] as num?)?.toInt();
    if (uid == null || mid == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete message?"),
        content: const Text("Remove this message from your inbox."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Delete", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await deleteInboxMessageApi(userId: uid, messageId: mid);
      widget.onInboxChanged?.call();
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = currentUserId;
    if (uid == null) {
      return const Center(child: Text("Please log in.", style: TextStyle(color: Colors.white70)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  "Formal inbox",
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: "New formal message",
                onPressed: _composeNew,
                icon: const Icon(Icons.edit_square, color: Colors.white),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            "Hire letters, employer updates, and your formal replies. Use + to start a new thread for an active application.",
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text("Could not load inbox.\n${snap.error}", style: const TextStyle(color: Colors.white70)));
                }
                final rows = snap.data ?? [];
                if (rows.isEmpty) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 48),
                      Center(
                        child: Column(
                          children: [
                            const Text(
                              "No messages yet.\nTap + to send a formal message for an active application.",
                              style: TextStyle(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: _composeNew,
                              icon: const Icon(Icons.add, color: Colors.white),
                              label: const Text("Compose", style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    final kind = r["kind"]?.toString() ?? "";
                    final unread = !apiReadBool(r["isRead"]);
                    Color accent = const Color(0xFF3D4370);
                    if (kind == "hire_congrats") accent = Colors.green.shade800;
                    if (kind == "rejection_summary") accent = Colors.deepOrange;
                    final jt = (r["jobTitle"]?.toString() ?? "").trim();
                    final from = (r["senderName"]?.toString() ?? "").trim();
                    final when = (r["createdAt"]?.toString() ?? "").trim();
                    final subj = r["title"]?.toString() ?? "Message";
                    final preview = (r["body"]?.toString() ?? "").replaceAll("\n", " ");
                    const prevMax = 120;
                    final prevShort = preview.length > prevMax ? "${preview.substring(0, prevMax)}…" : preview;

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      color: Colors.white,
                      child: InkWell(
                        onTap: () => _openDetail(r),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2, right: 10),
                                child: Icon(
                                  kind == "hire_congrats" ? Icons.workspace_premium : Icons.mail_outline,
                                  color: accent,
                                  size: 28,
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        if (unread)
                                          const Padding(
                                            padding: EdgeInsets.only(right: 6, top: 4),
                                            child: Icon(Icons.circle, color: Colors.red, size: 10),
                                        ),
                                        Expanded(
                                          child: Text(
                                            subj,
                                            style: TextStyle(
                                              fontWeight: unread ? FontWeight.bold : FontWeight.w600,
                                              fontSize: 16,
                                              color: const Color(0xFF1A1C2C),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (from.isNotEmpty)
                                      Text("From: $from", style: TextStyle(fontSize: 13, color: Colors.grey.shade800)),
                                    if (when.isNotEmpty)
                                      Text(when, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                    if (jt.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text("Re: $jt", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                      ),
                                    const SizedBox(height: 6),
                                    Text(
                                      prevShort,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 14, color: Colors.grey.shade800, height: 1.35),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: "Delete",
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                onPressed: () => _deleteRow(r),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ==========================================
// 2. MAIN HUB & NOTIFICATION BELL
// ==========================================
class HomePage extends StatefulWidget {
  final bool isEmployer;
  const HomePage({super.key, required this.isEmployer});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  int _inboxUnread = 0;

  @override
  void initState() {
    super.initState();
    _bootstrapHome();
  }

  Future<void> _reloadInboxUnread() async {
    final uid = currentUserId;
    if (uid == null) return;
    try {
      final rows = await fetchInboxApi(userId: uid);
      _inboxUnread = rows.where((r) => !apiReadBool(r["isRead"])).length;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _bootstrapHome() async {
    await refreshSessionFromServer();
    if (mounted) setState(() {});
    await _reloadNotifications();
    await _reloadInboxUnread();
  }

  Future<void> _reloadNotifications() async {
    try {
      final uid = currentUserId;
      if (uid == null) return;
      final rows = await fetchNotificationsApi(userId: uid);
      notifications
        ..clear()
        ..addAll(rows.map((r) {
          // Normalize fields for existing UI.
          final createdAt = r["createdAt"]?.toString() ?? "";
          return {
            "id": r["id"],
            "title": r["title"]?.toString() ?? "",
            "time": createdAt.isEmpty ? "" : createdAt,
            "type": r["type"]?.toString() ?? "info",
            "isRead": apiReadBool(r["isRead"]),
            "data": {"id": r["id"]},
            "body": r["body"]?.toString() ?? "",
          };
        }).toList());
      if (mounted) setState(() {});
    } catch (_) {
      // keep local notifications if API fails
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> pages = widget.isEmployer 
      ? [
          SharedJobFeed(isEmployer: true), 
          const OrganizedTalentDashboard(), 
          const ScheduleView(isEmployer: true), 
          FormalInboxView(onInboxChanged: _reloadInboxUnread),
          ProfileView(isEmployer: widget.isEmployer)
        ]
      : [
          SharedJobFeed(isEmployer: false), 
          const ResumeMaker(), 
          const ScheduleView(isEmployer: false), 
          FormalInboxView(onInboxChanged: _reloadInboxUnread),
          ProfileView(isEmployer: widget.isEmployer)
        ];

    String nameDisp = myProfileData['name']!.isNotEmpty ? ", ${myProfileData['name']}!" : "!";

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white, 
        elevation: 0, 
        automaticallyImplyLeading: false,
        title: Text(
          "Welcome$nameDisp", 
          style: const TextStyle(color: Color(0xFF3D4370), fontWeight: FontWeight.bold)
        ),
        actions: [
          IconButton(
            icon: Stack(
              children: [
                const Icon(Icons.notifications, color: Color(0xFF3D4370), size: 28),
                if (unreadNotificationCount() > 0)
                  Positioned(
                    right: 0, top: 0, 
                    child: Container(
                      padding: const EdgeInsets.all(2), 
                      decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle), 
                      constraints: const BoxConstraints(minWidth: 12, minHeight: 12)
                    )
                  ),
              ]
            ),
            onPressed: () async {
              await Navigator.pushNamed(context, '/notifications');
              await _reloadNotifications();
            },
          )
        ],
      ),
      body: _bg(child: pages[_currentIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex, 
        onTap: (index) async {
          setState(() => _currentIndex = index);
          if (index == 3) {
            final uid = currentUserId;
            if (uid != null) {
              try {
                await markInboxReadApi(userId: uid);
              } catch (_) {}
              await _reloadInboxUnread();
            }
          }
        },
        selectedItemColor: const Color(0xFF3D4370), 
        unselectedItemColor: Colors.grey, 
        type: BottomNavigationBarType.fixed,
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.business_center), label: "Jobs"),
          BottomNavigationBarItem(icon: Icon(widget.isEmployer ? Icons.groups : Icons.article), label: widget.isEmployer ? "Talent" : "Resume"),
          const BottomNavigationBarItem(icon: Icon(Icons.event), label: "Schedule"),
          BottomNavigationBarItem(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.inbox),
                if (_inboxUnread > 0)
                  const Positioned(right: -6, top: -4, child: Icon(Icons.circle, color: Colors.red, size: 10)),
              ],
            ),
            label: "Inbox",
          ),
          const BottomNavigationBarItem(icon: Icon(Icons.account_circle), label: "Profile"),
        ],
      ),
    );
  }
}

class NotificationHub extends StatefulWidget {
  const NotificationHub({super.key});

  @override
  State<NotificationHub> createState() => _NotificationHubState();
}

class _NotificationHubState extends State<NotificationHub> {
  @override
  void initState() {
    super.initState();
    markAllNotificationsRead();
    final uid = currentUserId;
    if (uid != null) {
      markNotificationsReadApi(userId: uid).catchError((_) {});
    }
  }

  Future<void> _removeAt(int index) async {
    final uid = currentUserId;
    final nid = (notifications[index]["id"] as num?)?.toInt();
    if (uid == null || nid == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete notification?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Delete", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await deleteNotificationApi(userId: uid, notificationId: nid);
      notifications.removeAt(index);
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Notifications"),
        backgroundColor: const Color(0xFF3D4370),
        foregroundColor: Colors.white,
      ),
      body: _bg(
        child: notifications.isEmpty
            ? const Center(child: Text("No notifications.", style: TextStyle(color: Colors.white70)))
            : ListView.builder(
                itemCount: notifications.length,
                itemBuilder: (context, i) => Card(
                  margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  color: Colors.white.withValues(alpha: 0.95),
                  child: ListTile(
                    leading: const Icon(Icons.notifications_active, color: Color(0xFF3D4370)),
                    title: Text(notifications[i]["title"]?.toString() ?? "", style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      [
                        notifications[i]["body"]?.toString(),
                        notifications[i]["time"]?.toString(),
                      ].where((s) => (s ?? "").toString().isNotEmpty).join("\n"),
                    ),
                    trailing: IconButton(
                      tooltip: "Delete",
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                      onPressed: () => _removeAt(i),
                    ),
                    onTap: () async {
                      final body = notifications[i]["body"]?.toString() ?? "";
                      final title = notifications[i]["title"]?.toString() ?? "Notification";
                      await Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          fullscreenDialog: true,
                          builder: (ctx) => Scaffold(
                            backgroundColor: const Color(0xFF1A1C2C),
                            appBar: AppBar(
                              title: const Text("Notification"),
                              backgroundColor: const Color(0xFF3D4370),
                              foregroundColor: Colors.white,
                            ),
                            body: SafeArea(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(20),
                                    color: Colors.white,
                                    child: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                                  ),
                                  Expanded(
                                    child: Container(
                                      color: Colors.white,
                                      padding: const EdgeInsets.all(20),
                                      child: SingleChildScrollView(
                                        child: SelectableText(
                                          body.isEmpty ? "(No details)" : body,
                                          style: const TextStyle(fontSize: 17, height: 1.55),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: FilledButton(
                                      onPressed: () => Navigator.pop(context),
                                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3D4370)),
                                      child: const Text("Close"),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

// ==========================================
// POST JOB (full screen)
// ==========================================
class PostJobScreen extends StatefulWidget {
  final VoidCallback onPosted;
  const PostJobScreen({super.key, required this.onPosted});

  @override
  State<PostJobScreen> createState() => _PostJobScreenState();
}

class _PostJobScreenState extends State<PostJobScreen> {
  final _titleC = TextEditingController();
  final _coC = TextEditingController();
  final _bossC = TextEditingController();
  final _locC = TextEditingController();
  final _salC = TextEditingController();
  final _descC = TextEditingController();
  final _maxAppsC = TextEditingController(text: "50");
  final _maxSlotsC = TextEditingController(text: "10");
  final _reqC = TextEditingController();
  String _employmentType = "FULL_TIME";
  String _payBasis = "MONTHLY";
  bool _aiBusy = false;
  bool _postBusy = false;
  String? _imageB64;

  @override
  void dispose() {
    _titleC.dispose();
    _coC.dispose();
    _bossC.dispose();
    _locC.dispose();
    _salC.dispose();
    _descC.dispose();
    _maxAppsC.dispose();
    _maxSlotsC.dispose();
    _reqC.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final file = res?.files.single;
    if (file?.bytes == null) return;
    setState(() => _imageB64 = base64Encode(file!.bytes!));
  }

  Future<void> _submit(BuildContext context) async {
    if (_titleC.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Job title required")));
      return;
    }
    setState(() => _postBusy = true);
    try {
      final uid = currentUserId ?? await ensureUser(isEmployer: true);
      currentUserId = uid;
      final pr = await fetchProfileReadyApi(uid);
      if (pr["ok"] != true) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(pr["message"]?.toString() ?? "Complete your profile first."), backgroundColor: Colors.red),
          );
        }
        return;
      }
      await postJobToApi({
        "employerUserId": uid,
        "title": _titleC.text.trim(),
        "co": _coC.text.trim().isEmpty ? "Company" : _coC.text.trim(),
        "bossName": _bossC.text.trim().isEmpty ? "Hiring Manager" : _bossC.text.trim(),
        "loc": _locC.text.trim().isEmpty ? "Location" : _locC.text.trim(),
        "sal": formatPayForApi(_salC.text),
        "desc": _descC.text.trim().isEmpty ? "-" : _descC.text.trim(),
        "employmentType": _employmentType,
        "payBasis": _payBasis,
        "maxApps": int.tryParse(_maxAppsC.text) ?? 50,
        "maxSlots": int.tryParse(_maxSlotsC.text) ?? 10,
        if (_imageB64 != null) "imageBase64": _imageB64,
        if (_reqC.text.trim().isNotEmpty) "applicationRequirements": _reqC.text.trim(),
      });
      widget.onPosted();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Job posted!"), backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _postBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("Post a new job"),
        backgroundColor: const Color(0xFF3D4370),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_imageB64 != null && decodeAvatarBytes(_imageB64) != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(decodeAvatarBytes(_imageB64)!, height: 140, width: double.infinity, fit: BoxFit.cover),
              )
            else
              OutlinedButton.icon(onPressed: _pickImage, icon: const Icon(Icons.add_photo_alternate), label: const Text("Add company logo / building photo (optional)")),
            if (_imageB64 != null)
              TextButton(onPressed: () => setState(() => _imageB64 = null), child: const Text("Remove image")),
            const SizedBox(height: 12),
            TextField(controller: _titleC, decoration: const InputDecoration(labelText: "Job title", border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: _coC, decoration: const InputDecoration(labelText: "Company name", border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: _bossC, decoration: const InputDecoration(labelText: "Hiring manager name", border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: _locC, decoration: const InputDecoration(labelText: "Location", border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
              controller: _salC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: "Pay (MYR)",
                hintText: "e.g. 3500 or 25.50",
                prefixText: "MYR ",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _payBasis,
              decoration: const InputDecoration(labelText: "Pay is quoted", border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: "HOURLY", child: Text("Per hour")),
                DropdownMenuItem(value: "DAILY", child: Text("Per day")),
                DropdownMenuItem(value: "MONTHLY", child: Text("Per month")),
                DropdownMenuItem(value: "OTHER", child: Text("Other / project")),
                DropdownMenuItem(value: "UNSPECIFIED", child: Text("Not specified")),
              ],
              onChanged: (v) => setState(() => _payBasis = v ?? "MONTHLY"),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _employmentType,
              decoration: const InputDecoration(labelText: "Employment type", border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: "FULL_TIME", child: Text("Full-time")),
                DropdownMenuItem(value: "PART_TIME", child: Text("Part-time")),
                DropdownMenuItem(value: "INTERNSHIP", child: Text("Internship")),
              ],
              onChanged: (v) => setState(() => _employmentType = v ?? "FULL_TIME"),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: TextField(controller: _maxAppsC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "Max applicants", border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _maxSlotsC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "Job slots", border: OutlineInputBorder()))),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _reqC,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: "What applicants must submit (one line per item)",
                hintText: "Fill this before AI if you can — it will be reflected in the generated description.\ne.g.\nIdentity card scan (PDF)\nLatest transcript",
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descC,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: "Job description / scope",
                hintText: "Optional rough notes or bullets — Generate with AI expands using title, company, location, pay, and required submissions above.",
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: _aiBusy
                  ? const Row(
                      children: [
                        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text("Generating…"),
                      ],
                    )
                  : TextButton.icon(
                      onPressed: () async {
                        if (_titleC.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Enter job title first")));
                          return;
                        }
                        setState(() => _aiBusy = true);
                        try {
                          final text = await generateJobDescriptionApi(
                            title: _titleC.text.trim(),
                            co: _coC.text.trim().isEmpty ? "Company" : _coC.text.trim(),
                            loc: _locC.text.trim().isEmpty ? "Location" : _locC.text.trim(),
                            sal: formatPayForApi(_salC.text),
                            employmentType: _employmentType,
                            extraNotes: _descC.text.trim(),
                            payBasis: _payBasis,
                            applicationRequirements: _reqC.text.trim(),
                            hiringManagerName: _bossC.text.trim(),
                          );
                          _descC.text = text;
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
                        } finally {
                          if (context.mounted) setState(() => _aiBusy = false);
                        }
                      },
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text("Generate with AI"),
                    ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _postBusy ? null : () => _submit(context),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3D4370), foregroundColor: Colors.white, padding: const EdgeInsets.all(16)),
              child: _postBusy
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text("PUBLISH JOB", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 4. JOB FEED & JOB DETAILS PAGE
// ==========================================
class SharedJobFeed extends StatefulWidget {
  final bool isEmployer;
  const SharedJobFeed({super.key, required this.isEmployer});

  @override
  State<SharedJobFeed> createState() => _SharedJobFeedState();
}

class _SharedJobFeedState extends State<SharedJobFeed> {
  late Future<List<Map<String, dynamic>>> _jobsFuture;

  @override
  void initState() {
    super.initState();
    _jobsFuture = fetchJobs();
  }

  void _refreshJobs() {
    setState(() {
      _jobsFuture = fetchJobs();
    });
  }

  Future<void> _confirmDeleteJob(BuildContext context, Map<String, dynamic> job) async {
    final jobId = (job["id"] as num?)?.toInt();
    if (jobId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Remove job listing?"),
        content: Text("Delete \"${job["title"]}\" from the feed? This cannot be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Remove", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final uid = currentUserId ?? await ensureUser(isEmployer: true);
      currentUserId = uid;
      await deleteJobApi(jobId: jobId, employerUserId: uid);
      _refreshJobs();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Job removed"), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Remove failed: $e"), backgroundColor: Colors.red));
      }
    }
  }

  void _openPostJobScreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => PostJobScreen(onPosted: _refreshJobs),
      ),
    );
  }

  void _showEditJobDialog(Map<String, dynamic> job) {
    final jobId = (job["id"] as num?)?.toInt();
    if (jobId == null) return;

    final titleC = TextEditingController(text: job["title"]?.toString() ?? "");
    final coC = TextEditingController(text: job["co"]?.toString() ?? "");
    final bossC = TextEditingController(text: job["bossName"]?.toString() ?? "");
    final locC = TextEditingController(text: job["loc"]?.toString() ?? "");
    final salC = TextEditingController(text: parsePayAmountForEdit(job["sal"]?.toString() ?? ""));
    final descC = TextEditingController(text: job["desc"]?.toString() ?? "");
    final maxAppsC = TextEditingController(text: "${(job["maxApps"] as num?)?.toInt() ?? 50}");
    final maxSlotsC = TextEditingController(text: "${(job["maxSlots"] as num?)?.toInt() ?? 10}");
    final reqC = TextEditingController(text: job["applicationRequirements"]?.toString() ?? "");
    String? editImageB64 = job["imageBase64"]?.toString();

    showDialog(
      context: context,
      builder: (dialogContext) {
        String employmentType = job["employmentType"]?.toString() ?? "FULL_TIME";
        if (!["FULL_TIME", "PART_TIME", "INTERNSHIP"].contains(employmentType)) employmentType = "FULL_TIME";
        String payBasis = job["payBasis"]?.toString() ?? "UNSPECIFIED";
        if (!["HOURLY", "DAILY", "MONTHLY", "OTHER", "UNSPECIFIED"].contains(payBasis)) payBasis = "UNSPECIFIED";
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Edit job listing"),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: titleC, decoration: const InputDecoration(labelText: "Job Title")),
                    TextField(controller: coC, decoration: const InputDecoration(labelText: "Company Name")),
                    TextField(controller: bossC, decoration: const InputDecoration(labelText: "Hiring Manager Name")),
                    TextField(controller: locC, decoration: const InputDecoration(labelText: "Location")),
                    TextField(
                      controller: salC,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: "Pay (MYR)",
                        prefixText: "MYR ",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: "Pay is quoted",
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: payBasis,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(value: "HOURLY", child: Text("Per hour")),
                            DropdownMenuItem(value: "DAILY", child: Text("Per day")),
                            DropdownMenuItem(value: "MONTHLY", child: Text("Per month")),
                            DropdownMenuItem(value: "OTHER", child: Text("Other / project")),
                            DropdownMenuItem(value: "UNSPECIFIED", child: Text("Not specified")),
                          ],
                          onChanged: (v) {
                            if (v != null) setDialogState(() => payBasis = v);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: "Employment type",
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: employmentType,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(value: "FULL_TIME", child: Text("Full-time")),
                            DropdownMenuItem(value: "PART_TIME", child: Text("Part-time")),
                            DropdownMenuItem(value: "INTERNSHIP", child: Text("Internship")),
                          ],
                          onChanged: (v) {
                            if (v != null) setDialogState(() => employmentType = v);
                          },
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: maxAppsC,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: "Max Applicants"),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: maxSlotsC,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: "Job Slots Available"),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descC,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: "Job description / scope",
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: reqC,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: "Application requirements (one per line)",
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (editImageB64 != null && decodeAvatarBytes(editImageB64) != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(decodeAvatarBytes(editImageB64)!, height: 80, fit: BoxFit.cover),
                      ),
                    TextButton.icon(
                      onPressed: () async {
                        final res = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
                        final file = res?.files.single;
                        if (file?.bytes == null) return;
                        setDialogState(() => editImageB64 = base64Encode(file!.bytes!));
                      },
                      icon: const Icon(Icons.image),
                      label: const Text("Update listing image"),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Cancel")),
                ElevatedButton(
                  onPressed: () async {
                    if (titleC.text.trim().isEmpty) return;
                    try {
                      final uid = currentUserId ?? await ensureUser(isEmployer: true);
                      currentUserId = uid;
                      await updateJobToApi(
                        jobId: jobId,
                        employerUserId: uid,
                        title: titleC.text.trim(),
                        co: coC.text.trim().isEmpty ? "Company" : coC.text.trim(),
                        bossName: bossC.text.trim().isEmpty ? "Hiring Manager" : bossC.text.trim(),
                        loc: locC.text.trim().isEmpty ? "Location" : locC.text.trim(),
                        sal: formatPayForApi(salC.text),
                        desc: descC.text.trim().isEmpty ? "-" : descC.text.trim(),
                        employmentType: employmentType,
                        maxApps: int.tryParse(maxAppsC.text) ?? 50,
                        maxSlots: int.tryParse(maxSlotsC.text) ?? 10,
                        imageBase64: editImageB64,
                        applicationRequirements: reqC.text.trim().isEmpty ? null : reqC.text.trim(),
                        payBasis: payBasis,
                      );
                      if (!dialogContext.mounted) return;
                      Navigator.pop(dialogContext);
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text("Job updated — applicants were notified."),
                          backgroundColor: Colors.green,
                        ),
                      );
                      _refreshJobs();
                    } catch (e) {
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text("Update failed: $e"), backgroundColor: Colors.red),
                        );
                      }
                    }
                  },
                  child: const Text("SAVE"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _jobsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                "Failed to load jobs.\n${snapshot.error}",
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            );
          }
          final jobs = snapshot.data ?? [];
          if (jobs.isEmpty) {
            return const Center(child: Text("No jobs listed. Bosses, post a job!", style: TextStyle(color: Colors.white70)));
          }

          return RefreshIndicator(
            onRefresh: () async => _refreshJobs(),
            child: ListView.builder(
              itemCount: jobs.length,
              itemBuilder: (context, i) {
                final job = jobs[i];
                final maxApps = (job["maxApps"] as num?)?.toDouble() ?? 0.0;
                final applied = (job["appliedCount"] as num?)?.toDouble() ?? 0.0;
                final accepted = (job["acceptedCount"] as num?)?.toDouble() ?? 0.0;
                final maxSlots = (job["maxSlots"] as num?)?.toDouble() ?? 0.0;

                double progressValue = (maxApps > 0) ? (applied / maxApps).clamp(0.0, 1.0) : 0.0;
                bool isFull = applied >= maxApps || accepted >= maxSlots || (job["status"]?.toString() ?? "OPEN") != "OPEN";

                final empId = (job["employerUserId"] as num?)?.toInt();
                final myId = currentUserId;
                final ownJob = widget.isEmployer && empId != null && myId != null && empId == myId;

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  child: ListTile(
                    leading: () {
                      final b = decodeAvatarBytes(job["imageBase64"]?.toString());
                      if (b != null) {
                        return CircleAvatar(backgroundImage: MemoryImage(b));
                      }
                      return CircleAvatar(
                        backgroundColor: Colors.grey[300],
                        child: const Icon(Icons.business, color: Color(0xFF3D4370)),
                      );
                    }(),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            job["title"]?.toString() ?? "",
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3D4370)),
                          ),
                        ),
                        if (isVerifiedEmployer) const Icon(Icons.verified, color: Colors.blue, size: 16)
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("${employmentTypeLabel(job["employmentType"])} • ${job["co"]} • Boss: ${job["bossName"]}"),
                        const SizedBox(height: 4),
                        Text(
                          payAmountLine(job),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.green),
                        ),
                        const SizedBox(height: 5),
                        LinearProgressIndicator(value: progressValue, color: isFull ? Colors.red : const Color(0xFF3D4370)),
                        Text(
                          isFull
                              ? "JOB CLOSED (Slots Full)"
                              : "${applied.toInt()}/${maxApps.toInt()} Applicants | ${(maxSlots - accepted).toInt()} Slots Left",
                          style: TextStyle(
                            fontSize: 12,
                            color: isFull ? Colors.red : Colors.black87,
                            fontWeight: isFull ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                    trailing: widget.isEmployer
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (ownJob)
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, color: Color(0xFF3D4370)),
                                  tooltip: "Edit listing",
                                  onPressed: () => _showEditJobDialog(job),
                                ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                tooltip: "Remove listing",
                                onPressed: ownJob ? () => _confirmDeleteJob(context, job) : null,
                              ),
                            ],
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: () async {
                      if (!widget.isEmployer) {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (c) => JobDetailsPage(
                              job: job,
                              onUpdate: _refreshJobs,
                            ),
                          ),
                        );
                        _refreshJobs();
                      }
                    },
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: widget.isEmployer 
        ? FloatingActionButton(
            onPressed: _openPostJobScreen, 
            backgroundColor: const Color(0xFF3D4370), 
            child: const Icon(Icons.add, color: Colors.white)
          ) 
        : null,
    );
  }
}

class JobDetailsPage extends StatefulWidget {
  final Map<String, dynamic> job;
  final VoidCallback onUpdate;
  const JobDetailsPage({super.key, required this.job, required this.onUpdate});

  @override
  State<JobDetailsPage> createState() => _JobDetailsPageState();
}

class _JobDetailsPageState extends State<JobDetailsPage> {
  bool? _hasApplied;
  bool _loadingApplied = true;
  bool _applyBusy = false;
  late TextEditingController _wordC;
  final List<Map<String, dynamic>> _extraSlots = [];
  Map<String, dynamic>? _employerContact;

  @override
  void initState() {
    super.initState();
    _wordC = TextEditingController(text: myResumeData["personalWord"] ?? "");
    _initExtraSlots();
    _loadApplied();
    _loadEmployerContact();
  }

  void _initExtraSlots() {
    final t = widget.job["applicationRequirements"]?.toString() ?? "";
    final lines = t.split(RegExp(r'\r?\n')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    _extraSlots
      ..clear()
      ..addAll(lines.map((line) => <String, dynamic>{"label": line, "filename": "", "base64": ""}));
  }

  @override
  void dispose() {
    _wordC.dispose();
    super.dispose();
  }

  Future<void> _loadEmployerContact() async {
    final jobId = (widget.job["id"] as num?)?.toInt();
    final uid = currentUserId;
    if (jobId == null || uid == null) return;
    try {
      final c = await fetchJobContactForSeekerApi(jobId: jobId, seekerUserId: uid);
      if (mounted) setState(() => _employerContact = c);
    } catch (_) {}
  }

  Future<void> _loadApplied() async {
    final jobId = (widget.job["id"] as num?)?.toInt();
    if (jobId == null) {
      setState(() {
        _hasApplied = false;
        _loadingApplied = false;
      });
      return;
    }
    try {
      final uid = currentUserId ?? await ensureUser(isEmployer: false);
      currentUserId = uid;
      final applied = await hasAppliedApi(jobId: jobId, seekerUserId: uid);
      if (mounted) {
        setState(() {
          _hasApplied = applied;
          _loadingApplied = false;
        });
        await _loadEmployerContact();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _hasApplied = false;
          _loadingApplied = false;
        });
      }
    }
  }

  Future<void> _pickExtra(int i) async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ["pdf", "png", "jpg", "jpeg"], withData: true);
      final file = res?.files.single;
      if (file?.bytes == null) return;
      setState(() {
        _extraSlots[i]["filename"] = file!.name;
        _extraSlots[i]["base64"] = base64Encode(file.bytes!);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Pick failed: $e"), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final appliedCount = (job["appliedCount"] as num?)?.toInt() ?? 0;
    final maxApps = (job["maxApps"] as num?)?.toInt() ?? 0;
    final acceptedCount = (job["acceptedCount"] as num?)?.toInt() ?? 0;
    final maxSlots = (job["maxSlots"] as num?)?.toInt() ?? 0;
    final isFull = appliedCount >= maxApps || acceptedCount >= maxSlots;
    final alreadyApplied = _hasApplied == true;
    final jobId = (job["id"] as num?)?.toInt();
    final logoBytes = decodeAvatarBytes(job["imageBase64"]?.toString());

    final vis = _employerContact;
    final showEmployer = vis != null && vis["visible"] == true && vis["employer"] != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(job["title"]?.toString() ?? "Job"),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF3D4370),
      ),
      body: _bg(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (logoBytes != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(logoBytes, height: 160, width: double.infinity, fit: BoxFit.cover),
                  ),
                ),
              Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: Colors.grey[300],
                    backgroundImage: logoBytes != null ? MemoryImage(logoBytes) : null,
                    child: logoBytes == null ? const Icon(Icons.business, size: 30, color: Color(0xFF3D4370)) : null,
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(job["co"]?.toString() ?? "", style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold)),
                        Text("Hiring Manager: ${job["bossName"]}", style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 16)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                "Pay: ${payAmountLine(job)}",
                style: const TextStyle(color: Colors.greenAccent, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              Text("Location: ${job['loc']}", style: const TextStyle(color: Colors.white70, fontSize: 16)),
              const SizedBox(height: 6),
              Text(
                employmentTypeLabel(job["employmentType"]),
                style: const TextStyle(color: Colors.amberAccent, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                child: Text("Job Scope:\n${job["desc"]}", style: const TextStyle(color: Colors.white, height: 1.5, fontSize: 16)),
              ),
              if ((job["applicationRequirements"]?.toString() ?? "").trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                  child: Text(
                    "Employer requests:\n${job["applicationRequirements"]}",
                    style: const TextStyle(color: Colors.white, height: 1.4),
                  ),
                ),
              ],
              if (showEmployer) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Employer contact (visible after you apply)", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                      Text("Name: ${vis["employer"]["name"]}", style: const TextStyle(color: Colors.white)),
                      Text("Email: ${vis["employer"]["email"] ?? "-"}", style: const TextStyle(color: Colors.white)),
                      Text("Phone: ${vis["employer"]["phone"] ?? "-"}", style: const TextStyle(color: Colors.white)),
                      if ((vis["employer"]["aboutText"]?.toString() ?? "").isNotEmpty)
                        Text("About: ${vis["employer"]["aboutText"]}", style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
              ],
              if (vis != null && vis["rejected"] == true) ...[
                const SizedBox(height: 12),
                const Text("Employer contact is hidden because this application was not successful.", style: TextStyle(color: Colors.deepOrangeAccent)),
              ],
              if (!_loadingApplied && !alreadyApplied && !isFull) ...[
                const SizedBox(height: 20),
                const Text("Personal message to the employer (optional)", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: _wordC,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Introduce yourself or highlight fit for this role",
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                if (_extraSlots.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text("Required uploads (one file per line from employer)", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  ...List.generate(_extraSlots.length, (i) {
                    final s = _extraSlots[i];
                    final done = (s["base64"] as String).isNotEmpty;
                    return Card(
                      color: Colors.white.withValues(alpha: 0.9),
                      child: ListTile(
                        title: Text(s["label"]?.toString() ?? "", style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3D4370))),
                        subtitle: Text(done ? "Attached: ${s["filename"]}" : "No file yet"),
                        trailing: IconButton(icon: const Icon(Icons.upload_file), onPressed: () => _pickExtra(i)),
                      ),
                    );
                  }),
                ],
              ],
              const SizedBox(height: 24),
              if (_loadingApplied)
                const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
              else
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: (isFull || alreadyApplied || _applyBusy)
                        ? null
                        : () async {
                            if (myResumeData["name"]!.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Fill out your Profile/Resume first!"), backgroundColor: Colors.red),
                              );
                              return;
                            }
                            if (jobId == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Invalid job id"), backgroundColor: Colors.red),
                              );
                              return;
                            }
                            for (final s in _extraSlots) {
                              if ((s["base64"] as String).isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text("Upload every required document before applying."),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                            }
                            setState(() => _applyBusy = true);
                            try {
                              final uid = currentUserId ?? await ensureUser(isEmployer: false);
                              currentUserId = uid;
                              final pr = await fetchProfileReadyApi(uid);
                              if (pr["ok"] != true) {
                                if (!context.mounted) return;
                                setState(() => _applyBusy = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(pr["message"]?.toString() ?? "Complete profile (photo, ID, phone, documents)."),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                              final extras = _extraSlots
                                  .map((s) => {
                                        "label": s["label"],
                                        "filename": s["filename"],
                                        "dataBase64": s["base64"],
                                      })
                                  .toList();
                              myResumeData["personalWord"] = _wordC.text;
                              await applyToJobApi(
                                jobId: jobId,
                                seekerUserId: uid,
                                personalWord: _wordC.text.trim().isEmpty ? null : _wordC.text.trim(),
                                applicantExtras: extras.isEmpty ? null : extras,
                              );
                              addNotification("You applied for ${job['title']}!", "Just now");
                              widget.onUpdate();
                              if (!context.mounted) return;
                              setState(() {
                                _hasApplied = true;
                                _applyBusy = false;
                              });
                              await _loadEmployerContact();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Applied successfully!"), backgroundColor: Colors.green),
                              );
                              Navigator.pop(context);
                            } catch (e) {
                              final msg = e.toString();
                              if (msg.contains("Already applied")) {
                                if (!context.mounted) return;
                                setState(() {
                                  _hasApplied = true;
                                  _applyBusy = false;
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text("You already applied to this job."), backgroundColor: Colors.orange),
                                );
                                return;
                              }
                              if (!context.mounted) return;
                              setState(() => _applyBusy = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Apply failed: $e"), backgroundColor: Colors.red),
                              );
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: (isFull || alreadyApplied || _applyBusy) ? Colors.grey : const Color(0xFF3D4370),
                      padding: const EdgeInsets.all(20),
                    ),
                    child: _applyBusy
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(
                            isFull ? "JOB CLOSED / FULL" : (alreadyApplied ? "ALREADY APPLIED" : "APPLY NOW"),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 5. RESUME MAKER & DOCUMENT VAULT
// ==========================================
class ResumeMaker extends StatefulWidget {
  const ResumeMaker({super.key});

  @override
  State<ResumeMaker> createState() => _ResumeMakerState();
}

class _ResumeMakerState extends State<ResumeMaker> {
  late TextEditingController _n, _p, _e, _x, _s, _id, _age, _add;

  @override
  void initState() {
    super.initState();
    _n = TextEditingController(text: myResumeData["name"]); 
    _p = TextEditingController(text: myResumeData["phone"]);
    _e = TextEditingController(text: myResumeData["edu"]); 
    _x = TextEditingController(text: myResumeData["exp"]);
    _s = TextEditingController(text: myResumeData["skills"]); 
    _id = TextEditingController(text: myResumeData["id"]);
    _age = TextEditingController(text: myResumeData["age"]); 
    _add = TextEditingController(text: myResumeData["address"]);
  }

  int _calculateProgress() {
    int filled = 0;
    if (_n.text.isNotEmpty) filled++; 
    if (_id.text.isNotEmpty) filled++;
    if (_p.text.isNotEmpty) filled++; 
    if (_e.text.isNotEmpty) filled++;
    if (_s.text.isNotEmpty) filled++; 
    if (myResumeData["ic_doc"]!.isNotEmpty) filled++;
    return (filled / 6 * 100).toInt();
  }

  Future<void> _uploadDoc(String type) async {
    final uid = currentUserId;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Log in to upload documents"), backgroundColor: Colors.red),
      );
      return;
    }
    try {
      final res = await FilePicker.platform.pickFiles(
        type: type == "ic_doc" || type == "transcript_doc" ? FileType.custom : FileType.image,
        allowedExtensions: (type == "ic_doc" || type == "transcript_doc") ? ["pdf", "png", "jpg", "jpeg"] : null,
        withData: true,
      );
      final file = res?.files.single;
      if (file == null || file.bytes == null) return;
      final b64 = base64Encode(file.bytes!);
      final name = file.name;
      if (type == "ic_doc") {
        await uploadSeekerDocsApi(userId: uid, icBase64: b64, icFilename: name);
        setState(() => myResumeData["ic_doc"] = name);
      } else if (type == "transcript_doc") {
        await uploadSeekerDocsApi(userId: uid, transcriptBase64: b64, transcriptFilename: name);
        setState(() => myResumeData["transcript_doc"] = name);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Uploaded to server"), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Upload failed: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _pickAvatar() async {
    final uid = currentUserId;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Log in to set a photo"), backgroundColor: Colors.red),
      );
      return;
    }
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
      final file = res?.files.single;
      if (file?.bytes == null) return;
      final b64 = base64Encode(file!.bytes!);
      await uploadAvatarApi(userId: uid, imageBase64: b64);
      await refreshSessionFromServer();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Profile photo saved"), backgroundColor: Colors.green),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Photo upload failed: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildField(String hint, TextEditingController controller, {int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10), 
      child: TextField(
        controller: controller, 
        maxLines: lines, 
        decoration: InputDecoration(
          hintText: hint, 
          filled: true, 
          fillColor: Colors.white, 
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))
        )
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(15), 
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Column(
              children: [
                Text("Profile Strength: ${_calculateProgress()}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                LinearProgressIndicator(value: _calculateProgress() / 100, color: Colors.green, backgroundColor: Colors.grey),
              ]
            ),
          ),
          const SizedBox(height: 20),
          userAvatarCircle(radius: 50, onTap: _pickAvatar, fallbackIcon: Icons.camera_alt),
          TextButton(
            onPressed: _pickAvatar,
            child: const Text("Upload profile photo", style: TextStyle(color: Colors.lightBlueAccent)),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center, 
            children: [
              const Text("Open to Work (Talent Pool)", style: TextStyle(color: Colors.white)),
              Switch(
                value: isOpenToWork, 
                onChanged: (v) {
                  setState(() {
                    isOpenToWork = v;
                    if (isOpenToWork) {
                      talentPool.add({
                        "name": _n.text.isEmpty ? "Anonymous" : _n.text,
                        "skills": _s.text.isEmpty ? "Unspecified" : _s.text,
                        "edu": _e.text.isEmpty ? "Unspecified" : _e.text,
                        "status": "Open to Work",
                        "resume": Map.from(myResumeData)
                      });
                    } else {
                      talentPool.removeWhere((t) => t["name"] == (_n.text.isEmpty ? "Anonymous" : _n.text));
                    }
                  });
                }, 
                activeThumbColor: Colors.green
              ),
            ]
          ),
          _buildField("Full Name", _n), 
          _buildField("Identity card number", _id), 
          _buildField("Age", _age), 
          _buildField("Phone", _p), 
          _buildField("Address", _add),
          _buildField("Education", _e), 
          _buildField("Experience", _x, lines: 2), 
          _buildField("Skills", _s), 
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              "Tip: your personal message to employers is entered on each job’s detail screen before you apply.",
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          
          Card(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  const Text("Secure Document Vault", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ListTile(
                    leading: const Icon(Icons.picture_as_pdf, color: Colors.red), 
                    title: const Text("Identity card copy"), 
                    trailing: IconButton(icon: const Icon(Icons.upload), onPressed: () => _uploadDoc("ic_doc"))
                  ),
                  ListTile(
                    leading: const Icon(Icons.picture_as_pdf, color: Colors.blue), 
                    title: const Text("Academic Transcripts"), 
                    trailing: IconButton(icon: const Icon(Icons.upload), onPressed: () => _uploadDoc("transcript_doc"))
                  ),
                ]
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () { 
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Exported to PDF!"))); 
                  }, 
                  icon: const Icon(Icons.download), 
                  label: const Text("Export PDF"), 
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue)
                )
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    myResumeData = {
                      "name": _n.text, "phone": _p.text, "edu": _e.text, "exp": _x.text,
                      "skills": _s.text, "id": _id.text, "age": _age.text, "address": _add.text,
                      "personalWord": myResumeData["personalWord"] ?? "",
                      "ic_doc": myResumeData["ic_doc"]!, "transcript_doc": myResumeData["transcript_doc"]!
                    };
                    setState(() {});
                    try {
                      final uid = currentUserId ?? await ensureUser(isEmployer: false);
                      currentUserId = uid;
                      await upsertSeekerProfileApi(
                        userId: uid,
                        name: _n.text,
                        icNumber: _id.text,
                        age: _age.text,
                        phone: _p.text,
                        address: _add.text,
                        education: _e.text,
                        experience: _x.text,
                        skills: _s.text,
                        personalWord: myResumeData["personalWord"],
                        openToWork: isOpenToWork,
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Saved!"), backgroundColor: Colors.green));
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("Saved locally; server sync failed: $e"), backgroundColor: Colors.orange),
                        );
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF3D4370)),
                  child: const Text("SAVE"),
                )
              ),
            ]
          )
        ]
      ),
    );
  }
}

// ==========================================
// 6. TALENT DASHBOARD & BOSS SCHEDULER
// ==========================================
class OrganizedTalentDashboard extends StatefulWidget {
  const OrganizedTalentDashboard({super.key});

  @override
  State<OrganizedTalentDashboard> createState() => _OrganizedTalentDashboardState();
}

class _OrganizedTalentDashboardState extends State<OrganizedTalentDashboard> {
  String searchQuery = "";
  bool showTalentPool = false;
  late Future<List<Map<String, dynamic>>> _appsFuture;

  @override
  void initState() {
    super.initState();
    _appsFuture = _loadApplications();
  }

  Future<List<Map<String, dynamic>>> _loadApplications() async {
    final uid = currentUserId;
    if (uid == null) return [];
    try {
      final rows = await fetchEmployerApplicationsApi(employerUserId: uid);
      return rows.map(_normalizeApplicantRow).toList();
    } catch (_) {
      return [];
    }
  }

  Map<String, dynamic> _normalizeApplicantRow(Map<String, dynamic> r) {
    final m = Map<String, dynamic>.from(r);
    m["resume"] = {
      "skills": r["skills"]?.toString() ?? "",
      "edu": r["edu"]?.toString() ?? "",
      "personalWord": r["personalWord"]?.toString() ?? "",
      "phone": r["phone"]?.toString() ?? "",
      "exp": r["exp"]?.toString() ?? "",
      "icNumber": r["icNumber"]?.toString() ?? "",
      "profileAddress": r["profileAddress"]?.toString() ?? "",
      "govId": r["govId"]?.toString() ?? "",
      "email": r["email"]?.toString() ?? "",
      "avatarBase64": r["seekerAvatarBase64"]?.toString() ?? "",
    };
    return m;
  }

  void _refreshApplications() {
    setState(() {
      _appsFuture = _loadApplications();
    });
  }

  Future<void> _refreshApplicationsAsync() async {
    final f = _loadApplications();
    setState(() {
      _appsFuture = f;
    });
    await f;
  }

  void _scheduleDialog(String applicantName, String jobTitle, {int? jobId, int? seekerUserId}) async {
    String platform = "Google Meet";
    final linkController = TextEditingController();
    
    DateTime? date = await showDatePicker(
      context: context, 
      initialDate: DateTime.now(), 
      firstDate: DateTime.now(), 
      lastDate: DateTime(2030)
    );
    if (date == null) return;

    if (!mounted) return;
    
    TimeOfDay? time = await showTimePicker(
      context: context, 
      initialTime: TimeOfDay.now()
    );
    if (time == null) return;

    if (!mounted) return;
    String finalDateTime = "${date.month}/${date.day}/${date.year} at ${time.format(context)}";

    showDialog(
      context: context, 
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Finalize Schedule"),
          content: Column(
            mainAxisSize: MainAxisSize.min, 
            children: [
              Text("Date & Time: $finalDateTime", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
              const SizedBox(height: 10),
              DropdownButton<String>(
                value: platform, 
                isExpanded: true, 
                items: ["Google Meet", "Zoom", "Discord", "Physical Interview"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(), 
                onChanged: (v) => setDialogState(() => platform = v!)
              ),
              TextField(
                controller: linkController, 
                decoration: const InputDecoration(labelText: "Paste Meeting Link or Office Address")
              ),
            ]
          ),
          actions: [
            ElevatedButton(
              onPressed: () async {
                try {
                  final bossId = currentUserId ?? await ensureUser(isEmployer: true);
                  currentUserId = bossId;
                  final seekerId = seekerUserId ?? await ensureNamedUser(name: applicantName, role: "SEEKER");
                  await createInterviewApi(
                    employerUserId: bossId,
                    seekerUserId: seekerId,
                    jobId: jobId,
                    platform: platform,
                    datetime: finalDateTime,
                    link: linkController.text.isEmpty ? "Pending Details" : linkController.text,
                  );

                  if (!context.mounted) return;
                  Navigator.pop(context); // close schedule dialog
                  Navigator.pop(context); // close resume pop-up
                  addNotification("You invited $applicantName to interview!", "Just now");
                  _refreshApplications();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Invite Sent Successfully!"), backgroundColor: Colors.green),
                  );
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Send invite failed: $e"), backgroundColor: Colors.red),
                  );
                }
              },
              child: const Text("SEND INVITE")
            )
          ],
        )
      )
    );
  }

  Future<void> _openEmployerApplicationDocuments(BuildContext outerCtx, Map<String, dynamic> app) async {
    final appId = (app["applicationId"] as num?)?.toInt();
    if (appId == null) return;
    var loadDialogOpen = false;
    try {
      final bossId = currentUserId ?? await ensureUser(isEmployer: true);
      currentUserId = bossId;
      if (!outerCtx.mounted) return;
      showDialog<void>(
        context: outerCtx,
        barrierDismissible: false,
        builder: (lc) => const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 16),
              Expanded(child: Text("Loading documents…")),
            ],
          ),
        ),
      );
      loadDialogOpen = true;
      final data = await fetchApplicationDocumentsForEmployerApi(applicationId: appId, employerUserId: bossId);
      if (outerCtx.mounted) {
        Navigator.of(outerCtx).pop();
        loadDialogOpen = false;
      }

      final tiles = <Widget>[];
      void addNamedDoc(String title, dynamic raw) {
        if (raw is! Map) return;
        final doc = Map<String, dynamic>.from(raw);
        final fn = doc["filename"]?.toString() ?? "document";
        final b64 = doc["dataBase64"]?.toString() ?? "";
        if (b64.isEmpty) return;
        tiles.add(
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(title),
            subtitle: Text(fn, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => open_doc.openDownloadableBase64(filename: fn, dataBase64: b64, context: outerCtx),
          ),
        );
      }

      addNamedDoc("Account ID document", data["idDocument"]);
      addNamedDoc("IC scan (profile)", data["icDocument"]);
      addNamedDoc("Transcript / certificate", data["transcriptDocument"]);

      final extras = data["applicationAttachments"];
      if (extras is List) {
        for (final e in extras) {
          if (e is! Map) continue;
          final m = Map<String, dynamic>.from(e);
          final label = m["label"]?.toString() ?? "Application upload";
          final fn = m["filename"]?.toString() ?? "file";
          final b64 = m["dataBase64"]?.toString() ?? "";
          if (b64.isEmpty) continue;
          tiles.add(
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: Text(label),
              subtitle: Text(fn, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => open_doc.openDownloadableBase64(filename: fn, dataBase64: b64, context: outerCtx),
            ),
          );
        }
      }

      if (!outerCtx.mounted) return;
      await showDialog<void>(
        context: outerCtx,
        builder: (dc) => AlertDialog(
          title: const Text("Documents for this application"),
          content: SizedBox(
            width: double.maxFinite,
            child: tiles.isEmpty
                ? const Text("No files on record for this applicant yet.")
                : ListView(shrinkWrap: true, children: tiles),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(dc), child: const Text("Close"))],
        ),
      );
    } catch (e) {
      if (outerCtx.mounted) {
        ScaffoldMessenger.of(outerCtx).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    } finally {
      if (loadDialogOpen && outerCtx.mounted) {
        Navigator.of(outerCtx).pop();
      }
    }
  }

  void _reviewResume(Map<String, dynamic> app) {
    final canView = app["canViewSensitive"] != false;
    final appId = (app["applicationId"] as num?)?.toInt();
    final st = app["status"]?.toString() ?? "";
    final showDecline = canView && appId != null && st != "REJECTED";

    showDialog(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        child: Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            title: Text("${app['name']}'s application"),
            backgroundColor: const Color(0xFF3D4370),
            foregroundColor: Colors.white,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!canView) ...[
                  const Text(
                    "Sensitive details are hidden — this application is no longer active.",
                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                  ),
                  if ((app["rejectionReason"]?.toString() ?? "").isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text("Reason: ${app["rejectionReason"]}", style: const TextStyle(color: Colors.black87)),
                    ),
                ] else ...[
                  Builder(
                    builder: (bc) {
                      final resume = Map<String, dynamic>.from(app["resume"] as Map? ?? {});
                      final avatarBytes = decodeAvatarBytes(resume["avatarBase64"]?.toString());
                      final name = app["name"]?.toString() ?? "Applicant";
                      final jobTitle = app["jobTitle"]?.toString() ?? "";
                      final email = resume["email"]?.toString().trim().isNotEmpty == true ? resume["email"].toString() : "—";
                      final phone = resume["phone"]?.toString().trim().isNotEmpty == true ? resume["phone"].toString() : "—";
                      final address = resume["profileAddress"]?.toString().trim().isNotEmpty == true ? resume["profileAddress"].toString() : "—";
                      final ic = resume["icNumber"]?.toString().trim() ?? "";
                      final gov = resume["govId"]?.toString().trim() ?? "";
                      final idDisplay = ic.isNotEmpty ? ic : (gov.isNotEmpty ? gov : "—");
                      final skills = (resume["skills"] ?? app["skills"] ?? "").toString().trim();
                      final edu = (resume["edu"] ?? app["edu"] ?? "").toString().trim();
                      final exp = (resume["exp"] ?? "").toString().trim();
                      final personal = resume["personalWord"]?.toString().trim() ?? "";

                      Widget sectionTitle(String t) => Padding(
                            padding: const EdgeInsets.only(top: 22, bottom: 8),
                            child: Text(
                              t.toUpperCase(),
                              style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w700,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          );
                      Widget bodyLine(String t) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(t, style: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xFF222222))),
                          );

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8F9FC),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFE2E6EF)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 52,
                                  backgroundColor: const Color(0xFFE2E6EF),
                                  backgroundImage: avatarBytes != null ? MemoryImage(avatarBytes) : null,
                                  child: avatarBytes == null
                                      ? const Icon(Icons.person, size: 48, color: Color(0xFF3D4370))
                                      : null,
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF1A1C2C), height: 1.2),
                                      ),
                                      const SizedBox(height: 8),
                                      if (jobTitle.isNotEmpty)
                                        Text(
                                          "Applied for: $jobTitle",
                                          style: TextStyle(fontSize: 15, color: Colors.grey.shade800, fontWeight: FontWeight.w600),
                                        ),
                                      const SizedBox(height: 6),
                                      Text("Status: $st", style: TextStyle(fontSize: 14, color: Colors.blueGrey.shade700)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          sectionTitle("Contact"),
                          bodyLine("Email: $email"),
                          bodyLine("Phone: $phone"),
                          bodyLine("Address: $address"),
                          sectionTitle("Identity card number"),
                          bodyLine(idDisplay),
                          if (ic.isNotEmpty && gov.isNotEmpty && ic != gov)
                            bodyLine("Account reference: $gov"),
                          if (personal.isNotEmpty) ...[
                            sectionTitle("Professional summary"),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFFBF0),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFFFE0B2)),
                              ),
                              child: Text(personal, style: const TextStyle(fontSize: 16, height: 1.55, color: Color(0xFF333333))),
                            ),
                          ],
                          if (exp.isNotEmpty) ...[
                            sectionTitle("Experience"),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFE2E6EF)),
                              ),
                              child: Text(exp, style: const TextStyle(fontSize: 16, height: 1.55)),
                            ),
                          ],
                          if (edu.isNotEmpty) ...[
                            sectionTitle("Education"),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFE2E6EF)),
                              ),
                              child: Text(edu, style: const TextStyle(fontSize: 16, height: 1.55)),
                            ),
                          ],
                          if (skills.isNotEmpty) ...[
                            sectionTitle("Skills"),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFE2E6EF)),
                              ),
                              child: Text(skills, style: const TextStyle(fontSize: 16, height: 1.55)),
                            ),
                          ],
                          const SizedBox(height: 20),
                          OutlinedButton.icon(
                            onPressed: () => _openEmployerApplicationDocuments(ctx, app),
                            icon: const Icon(Icons.folder_copy_outlined),
                            label: const Text("Documents on file"),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              "Tap to view ID, IC scan, transcript, and any files submitted for this job.",
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                            ),
                          ),
                          if (showDecline) ...[
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: () async {
                                final reason = TextEditingController();
                                final ok = await showDialog<bool>(
                                  context: ctx,
                                  builder: (dctx) => AlertDialog(
                                    title: const Text("Reject applicant"),
                                    content: TextField(
                                      controller: reason,
                                      maxLines: 4,
                                      decoration: const InputDecoration(
                                        labelText: "Reason (sent to seeker)",
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text("Cancel")),
                                      TextButton(
                                        onPressed: () => Navigator.pop(dctx, true),
                                        child: const Text("Reject", style: TextStyle(color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok != true || !ctx.mounted) return;
                                try {
                                  final bossId = currentUserId ?? await ensureUser(isEmployer: true);
                                  currentUserId = bossId;
                                  await rejectApplicationApi(applicationId: appId, employerUserId: bossId, reason: reason.text.trim());
                                  if (!ctx.mounted) return;
                                  Navigator.pop(ctx);
                                  _refreshApplications();
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(content: Text("Applicant rejected."), backgroundColor: Colors.orange),
                                  );
                                } catch (e) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
                                  }
                                }
                              },
                              icon: const Icon(Icons.cancel_outlined, color: Colors.red),
                              label: const Text("Reject applicant", style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: canView
                        ? () => _scheduleDialog(
                              app['name']?.toString() ?? "Applicant",
                              app['jobTitle']?.toString() ?? "Direct Hire",
                              jobId: (app['jobId'] as num?)?.toInt(),
                              seekerUserId: (app['seekerUserId'] as num?)?.toInt(),
                            )
                        : null,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.all(15)),
                    child: const Text("SET UP INTERVIEW", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: TextField(
            onChanged: (v) => setState(() => searchQuery = v),
            decoration: InputDecoration(
              hintText: "Search skills",
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ChoiceChip(
              label: const Text("Applicants"),
              selected: !showTalentPool,
              onSelected: (v) {
                setState(() {
                  showTalentPool = false;
                  _appsFuture = _loadApplications();
                });
              },
            ),
            const SizedBox(width: 10),
            ChoiceChip(
              label: const Text("Open Talent Pool"),
              selected: showTalentPool,
              onSelected: (v) => setState(() => showTalentPool = true),
            ),
          ],
        ),
        Expanded(
          child: showTalentPool
              ? _buildTalentPoolList()
              : FutureBuilder<List<Map<String, dynamic>>>(
                  future: _appsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          "Could not load applicants.\n${snapshot.error}",
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    final apps = snapshot.data ?? [];
                    final filteredList = apps.where((a) {
                      final q = searchQuery.toLowerCase();
                      return a["name"].toString().toLowerCase().contains(q) ||
                          (a["resume"]?["skills"] ?? a["skills"] ?? "").toString().toLowerCase().contains(q);
                    }).toList();

                    if (filteredList.isEmpty) {
                      return RefreshIndicator(
                        onRefresh: _refreshApplicationsAsync,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            Center(child: Text("No applicants yet.", style: TextStyle(color: Colors.white70))),
                          ],
                        ),
                      );
                    }

                    final jobTitles = filteredList.map((a) => (a["jobTitle"] ?? "Unknown Job").toString()).toSet();

                    return RefreshIndicator(
                      onRefresh: _refreshApplicationsAsync,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: jobTitles.map((jobTitle) {
                          final applicantsInFolder = filteredList.where((a) => (a["jobTitle"] ?? "Unknown Job").toString() == jobTitle).toList();
                          return Card(
                            margin: const EdgeInsets.all(10),
                            child: ExpansionTile(
                              title: Text(
                                "$jobTitle (${applicantsInFolder.length} Applicants)",
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3D4370)),
                              ),
                              children: applicantsInFolder
                                  .map(
                                    (app) => ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: app["status"] == "New" ? Colors.red : Colors.grey,
                                        radius: 8,
                                      ),
                                      title: Text(app["name"]?.toString() ?? "", style: const TextStyle(fontWeight: FontWeight.bold)),
                                      subtitle: Text("Status: ${app["status"]}"),
                                      trailing: const Icon(Icons.visibility, color: Color(0xFF3D4370)),
                                      onTap: () => _reviewResume(app),
                                    ),
                                  )
                                  .toList(),
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTalentPoolList() {
    var filteredList = talentPool.where((a) {
      final q = searchQuery.toLowerCase();
      return a["name"].toString().toLowerCase().contains(q) ||
          (a["resume"]?["skills"] ?? a["skills"] ?? "").toString().toLowerCase().contains(q);
    }).toList();

    if (filteredList.isEmpty) {
      return const Center(child: Text("Talent Pool is currently empty.", style: TextStyle(color: Colors.white70)));
    }
    return ListView.builder(
      itemCount: filteredList.length,
      itemBuilder: (context, i) => Card(
        margin: const EdgeInsets.all(10),
        child: ListTile(
          title: Text(filteredList[i]["name"], style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3D4370))),
          subtitle: Text("Skills: ${filteredList[i]['skills']}"),
          trailing: const Icon(Icons.visibility),
          onTap: () => _reviewResume(filteredList[i]),
        ),
      ),
    );
  }
}

// ==========================================
// 7. SCHEDULE & NEGOTIATION
// ==========================================
class InterviewDirectCommsScreen extends StatefulWidget {
  final int interviewId;
  final bool isEmployer;

  const InterviewDirectCommsScreen({super.key, required this.interviewId, required this.isEmployer});

  @override
  State<InterviewDirectCommsScreen> createState() => _InterviewDirectCommsScreenState();
}

class _InterviewDirectCommsScreenState extends State<InterviewDirectCommsScreen> {
  final _chatC = TextEditingController();
  late Future<List<Map<String, dynamic>>> _msgsFuture;

  @override
  void initState() {
    super.initState();
    _msgsFuture = fetchInterviewMessagesApi(interviewId: widget.interviewId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = currentUserId;
      if (uid == null) return;
      markInterviewMessagesReadApi(interviewId: widget.interviewId, userId: uid).catchError((_) {});
    });
  }

  void _reloadMessages() {
    setState(() {
      _msgsFuture = fetchInterviewMessagesApi(interviewId: widget.interviewId);
    });
  }

  Future<void> _send() async {
    if (_chatC.text.trim().isEmpty) return;
    final uid = currentUserId;
    if (uid == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Log in again"), backgroundColor: Colors.red),
        );
      }
      return;
    }
    try {
      await sendInterviewMessageApi(
        interviewId: widget.interviewId,
        senderUserId: uid,
        text: _chatC.text.trim(),
      );
      addNotification("New message on interview card!", "Just now");
      _chatC.clear();
      _reloadMessages();
      await markInterviewMessagesReadApi(interviewId: widget.interviewId, userId: uid).catchError((_) {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Send failed: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    _chatC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bar = Color(0xFF3D4370);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text("Direct Comms"),
        backgroundColor: bar,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
          tooltip: "Close",
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _msgsFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("Could not load messages.\n${snap.error}", textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
                    ),
                  );
                }
                final msgs = snap.data ?? [];
                if (msgs.isEmpty) {
                  return const Center(
                    child: Text("No messages yet.\nSay hello below.", textAlign: TextAlign.center, style: TextStyle(color: Colors.black54, height: 1.4)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    final sender = (m["senderUserId"] as num?)?.toInt();
                    final mine = sender != null && sender == currentUserId;
                    final label = mine
                        ? (widget.isEmployer ? "You (employer)" : "You")
                        : (widget.isEmployer ? "Seeker" : "Employer");
                    final text = m["text"]?.toString() ?? "";
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.88),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: mine ? const Color(0xFF3D4370) : Colors.white,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(14),
                            topRight: const Radius.circular(14),
                            bottomLeft: Radius.circular(mine ? 14 : 4),
                            bottomRight: Radius.circular(mine ? 4 : 14),
                          ),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6, offset: const Offset(0, 2))],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: mine ? Colors.white70 : Colors.black45),
                            ),
                            const SizedBox(height: 4),
                            Text(text, style: TextStyle(fontSize: 15, height: 1.45, color: mine ? Colors.white : const Color(0xFF222222))),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Material(
            elevation: 12,
            color: Colors.white,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 10, 12, 10 + keyboard),
              child: SafeArea(
                top: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _chatC,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: "Type a message…",
                          filled: true,
                          fillColor: const Color(0xFFF5F6FA),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _send,
                      style: FilledButton.styleFrom(
                        backgroundColor: bar,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                      ),
                      child: const Text("Send"),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ScheduleView extends StatefulWidget {
  final bool isEmployer;
  const ScheduleView({super.key, required this.isEmployer});

  @override
  State<ScheduleView> createState() => _ScheduleViewState();
}

class _ScheduleViewState extends State<ScheduleView> {
  late Future<List<Map<String, dynamic>>> _interviewsFuture;

  @override
  void initState() {
    super.initState();
    _interviewsFuture = _loadInterviews();
  }

  Future<List<Map<String, dynamic>>> _loadInterviews() async {
    final uid = currentUserId;
    if (uid == null) return [];
    try {
      return await fetchInterviewsApi(userId: uid, isEmployer: widget.isEmployer);
    } catch (_) {
      return [];
    }
  }

  Future<void> _reloadInterviews() async {
    final f = _loadInterviews();
    setState(() {
      _interviewsFuture = f;
    });
    await f;
  }

  Future<void> _openChat(Map<String, dynamic> invite) async {
    if (invite["applicationStatus"]?.toString() == "REJECTED") {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Messaging is closed for declined applications."), backgroundColor: Colors.red),
      );
      return;
    }
    final interviewId = (invite["id"] as num?)?.toInt();
    if (interviewId == null) return;
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => InterviewDirectCommsScreen(
          interviewId: interviewId,
          isEmployer: widget.isEmployer,
        ),
      ),
    );
    if (mounted) await _reloadInterviews();
  }

  Future<void> _pickNewDatetimeAndUpdate(Map<String, dynamic> inv) async {
    DateTime? date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2030),
    );
    if (date == null) return;
    if (!mounted) return;

    TimeOfDay? time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    if (!mounted) return;

    final newDatetime = "${date.month}/${date.day}/${date.year} at ${time.format(context)}";

    final linkC = TextEditingController(text: inv['link']?.toString() ?? "");
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Update Interview Details"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("New Time: $newDatetime", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
            TextField(controller: linkC, decoration: const InputDecoration(labelText: "Meeting Link / Location")),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () async {
              try {
                final uid = currentUserId ?? await ensureUser(isEmployer: widget.isEmployer);
                currentUserId = uid;
                final interviewId = (inv["id"] as num?)?.toInt();
                if (interviewId == null) return;
                await updateInterviewApi(
                  interviewId: interviewId,
                  actorUserId: uid,
                  datetime: newDatetime,
                  proposedDatetime: "",
                  link: linkC.text,
                  status: "Pending Seeker",
                );
                addNotification("Interview details updated!", "Just now", type: "interview_change");
                if (!context.mounted) return;
                Navigator.pop(context);
                if (mounted) await _reloadInterviews();
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Update failed: $e"), backgroundColor: Colors.red),
                );
              }
            },
            child: const Text("UPDATE"),
          ),
        ],
      ),
    );
  }

  Future<void> _seekerReschedule(Map<String, dynamic> inv) async {
    DateTime? date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2030),
    );
    if (date == null) return;
    if (!mounted) return;

    TimeOfDay? time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    if (!mounted) return;

    final proposed = "${date.month}/${date.day}/${date.year} at ${time.format(context)}";
    try {
      final uid = currentUserId ?? await ensureUser(isEmployer: false);
      currentUserId = uid;
      final interviewId = (inv["id"] as num?)?.toInt();
      if (interviewId == null) return;
      await updateInterviewApi(
        interviewId: interviewId,
        actorUserId: uid,
        proposedDatetime: proposed,
        status: "Rescheduled by Seeker",
      );
      addNotification("You requested a reschedule: $proposed", "Just now", type: "reschedule_request");
      if (mounted) await _reloadInterviews();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Reschedule failed: $e"), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = currentUserId;
    if (uid == null) {
      return const Center(child: Text("Please select a role first.", style: TextStyle(color: Colors.white70)));
    }

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _interviewsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text("Failed to load interviews.\n${snap.error}", style: const TextStyle(color: Colors.white70)));
        }
        final interviews = snap.data ?? [];
        if (interviews.isEmpty) {
          return const Center(child: Text("No interviews scheduled.", style: TextStyle(color: Colors.white70)));
        }

        return RefreshIndicator(
          onRefresh: _reloadInterviews,
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: interviews.length,
            itemBuilder: (context, i) {
              final inv = interviews[i];
              final unread = (inv["unreadMessageCount"] as num?)?.toInt() ?? 0;
              return Card(
                margin: const EdgeInsets.all(10),
                child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.grey[300],
                            child: Icon(widget.isEmployer ? Icons.person : Icons.business, color: const Color(0xFF3D4370)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              widget.isEmployer
                                  ? "Applicant: ${inv['seekerName'] ?? inv['seekerUserId']}"
                                  : "Job: ${inv['jobTitle'] ?? inv['jobId'] ?? '-'}",
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                            ),
                          ),
                          IconButton(
                            tooltip: unread > 0 ? "New messages" : "Messages",
                            onPressed: () => _openChat(inv),
                            icon: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                const Icon(Icons.chat, color: Colors.blue),
                                if (unread > 0)
                                  Positioned(
                                    right: -2,
                                    top: -2,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (widget.isEmployer)
                            IconButton(icon: const Icon(Icons.edit, color: Colors.orange), onPressed: () => _pickNewDatetimeAndUpdate(inv)),
                        ],
                      ),
                const SizedBox(height: 10),
                Text("Platform: ${inv['platform']} | Time: ${inv['datetime']}", style: const TextStyle(fontWeight: FontWeight.bold)),
                if (inv["proposedDatetime"] != null)
                  Text("Proposed (Seeker): ${inv['proposedDatetime']}", style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold)),
                Text("Link/Address: ${inv['link']}"),
                const SizedBox(height: 5),
                Text(
                  "Status: ${inv['status']}", 
                  style: TextStyle(fontWeight: FontWeight.bold, color: inv['status'].contains("Accepted") ? Colors.green : Colors.orange)
                ),
                
                const SizedBox(height: 10),
                if (!widget.isEmployer && inv["status"] == "Pending Seeker") 
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            try {
                              final uid2 = currentUserId ?? await ensureUser(isEmployer: false);
                              currentUserId = uid2;
                              final interviewId = (inv["id"] as num?)?.toInt();
                              if (interviewId == null) return;
                              await updateInterviewApi(interviewId: interviewId, actorUserId: uid2, status: "Accepted");
                              if (mounted) await _reloadInterviews();
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Accept failed: $e"), backgroundColor: Colors.red),
                              );
                            }
                          }, 
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green), 
                          child: const Text("ACCEPT", style: TextStyle(color: Colors.white))
                        )
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _seekerReschedule(inv),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange), 
                          child: const Text("RESCHEDULE", style: TextStyle(color: Colors.white))
                        )
                      ),
                    ]
                  ),

                if (widget.isEmployer && inv["status"] == "Rescheduled by Seeker") 
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            try {
                              final uid2 = currentUserId ?? await ensureUser(isEmployer: true);
                              currentUserId = uid2;
                              final interviewId = (inv["id"] as num?)?.toInt();
                              if (interviewId == null) return;
                              await updateInterviewApi(interviewId: interviewId, actorUserId: uid2, status: "Accepted", proposedDatetime: "");
                              if (mounted) await _reloadInterviews();
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Accept time failed: $e"), backgroundColor: Colors.red),
                              );
                            }
                          }, 
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green), 
                          child: const Text("ACCEPT TIME", style: TextStyle(color: Colors.white, fontSize: 12))
                        )
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _pickNewDatetimeAndUpdate(inv), 
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange), 
                          child: const Text("CHANGE", style: TextStyle(color: Colors.white, fontSize: 12))
                        )
                      ),
                    ]
                  ),
                
                if (widget.isEmployer && inv["status"] == "Accepted") 
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            try {
                              final uid2 = currentUserId ?? await ensureUser(isEmployer: true);
                              currentUserId = uid2;
                              final interviewId = (inv["id"] as num?)?.toInt();
                              if (interviewId == null) return;
                              await updateInterviewApi(interviewId: interviewId, actorUserId: uid2, status: "HIRED");
                              if (mounted) await _reloadInterviews();
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Hire failed: $e"), backgroundColor: Colors.red),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green), 
                          child: const Text("HIRE", style: TextStyle(color: Colors.white))
                        )
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            final aid = (inv["applicationId"] as num?)?.toInt();
                            if (aid == null) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Missing application link — refresh the schedule."), backgroundColor: Colors.red),
                              );
                              return;
                            }
                            final reasonC = TextEditingController();
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (dctx) => AlertDialog(
                                title: const Text("Reject candidate"),
                                content: TextField(
                                  controller: reasonC,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                    labelText: "Reason (sent to seeker)",
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text("Cancel")),
                                  TextButton(onPressed: () => Navigator.pop(dctx, true), child: const Text("Reject", style: TextStyle(color: Colors.red))),
                                ],
                              ),
                            );
                            if (ok != true || !context.mounted) return;
                            try {
                              final uid2 = currentUserId ?? await ensureUser(isEmployer: true);
                              currentUserId = uid2;
                              await rejectApplicationApi(applicationId: aid, employerUserId: uid2, reason: reasonC.text.trim());
                              if (mounted) await _reloadInterviews();
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Reject failed: $e"), backgroundColor: Colors.red),
                              );
                            }
                          }, 
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red), 
                          child: const Text("REJECT", style: TextStyle(color: Colors.white))
                        )
                      ),
                    ]
                  ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ==========================================
// 8. PROFILE PAGE
// ==========================================
class ProfileView extends StatefulWidget {
  final bool isEmployer;
  const ProfileView({super.key, required this.isEmployer});

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  late TextEditingController _nameC, _emailC, _phoneC, _addC, _govC, _aboutC, _curPassC, _newPassC;
  bool _saving = false;
  bool _hideCurPass = true;
  bool _hideNewPass = true;

  @override
  void initState() {
    super.initState();
    _nameC = TextEditingController(text: myProfileData["name"]);
    _emailC = TextEditingController(text: myProfileData["email"]);
    _phoneC = TextEditingController(text: myProfileData["phone"]);
    _addC = TextEditingController(text: myProfileData["address"]);
    _govC = TextEditingController(text: myProfileData["govId"]);
    _aboutC = TextEditingController(text: myProfileData["about"]);
    _curPassC = TextEditingController();
    _newPassC = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await refreshSessionFromServer();
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _pickProfilePhoto() async {
    final uid = currentUserId;
    if (uid == null) return;
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
      final file = res?.files.single;
      if (file?.bytes == null) return;
      await uploadAvatarApi(userId: uid, imageBase64: base64Encode(file!.bytes!));
      await refreshSessionFromServer();
      if (mounted) setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Profile photo updated"), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Photo failed: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameC.dispose();
    _emailC.dispose();
    _phoneC.dispose();
    _addC.dispose();
    _govC.dispose();
    _aboutC.dispose();
    _curPassC.dispose();
    _newPassC.dispose();
    super.dispose();
  }

  Widget _buildProfileField(
    String label,
    TextEditingController controller, {
    bool readOnly = false,
    int maxLines = 1,
    bool passwordHidden = false,
    VoidCallback? onTogglePasswordVisibility,
  }) {
    final isPassword = onTogglePasswordVisibility != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            obscureText: isPassword ? passwordHidden : false,
            readOnly: readOnly,
            maxLines: maxLines,
            style: const TextStyle(color: Color(0xFF1a1a2e), fontSize: 16),
            decoration: InputDecoration(
              hintText: label,
              hintStyle: TextStyle(color: Colors.grey.shade500),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF3D4370), width: 2),
              ),
              suffixIcon: isPassword
                  ? IconButton(
                      tooltip: passwordHidden ? "Show password" : "Hide password",
                      icon: Icon(passwordHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: onTogglePasswordVisibility,
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickIdDocument() async {
    final uid = currentUserId;
    if (uid == null) return;
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ["pdf", "png", "jpg", "jpeg"],
        withData: true,
      );
      final file = res?.files.single;
      if (file?.bytes == null) return;
      await uploadUserIdDocApi(userId: uid, imageBase64: base64Encode(file!.bytes!), filename: file.name);
      myProfileData["idDocName"] = file.name;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("ID document saved"), backgroundColor: Colors.green));
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _save() async {
    final uid = currentUserId;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Not logged in"), backgroundColor: Colors.red),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await profileUpdateApi(
        userId: uid,
        name: _nameC.text.trim(),
        phone: _phoneC.text.trim(),
        address: _addC.text.trim(),
        govId: _govC.text.trim(),
        aboutText: _aboutC.text.trim(),
      );
      myProfileData["about"] = _aboutC.text.trim();
      if (!widget.isEmployer) {
        await upsertSeekerProfileApi(
          userId: uid,
          name: _nameC.text.trim(),
          icNumber: _govC.text.trim().isEmpty ? myResumeData["id"] : _govC.text.trim(),
          age: myResumeData["age"],
          phone: _phoneC.text.trim(),
          address: _addC.text.trim(),
          education: myResumeData["edu"],
          experience: myResumeData["exp"],
          skills: myResumeData["skills"],
          personalWord: myResumeData["personalWord"],
          openToWork: isOpenToWork,
        );
      }
      if (_newPassC.text.isNotEmpty) {
        if (_curPassC.text.isEmpty) {
          throw Exception("Enter your current password to set a new one");
        }
        if (_newPassC.text.length < 8) throw Exception("New password must be at least 8 characters");
        await changePasswordApi(userId: uid, currentPassword: _curPassC.text, newPassword: _newPassC.text);
        _curPassC.clear();
        _newPassC.clear();
        _hideCurPass = true;
        _hideNewPass = true;
      }
      await refreshSessionFromServer();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Profile saved to server"), backgroundColor: Colors.green),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          userAvatarCircle(radius: 50, onTap: _pickProfilePhoto),
          TextButton(
            onPressed: _pickProfilePhoto,
            child: const Text("Change photo", style: TextStyle(color: Colors.lightBlueAccent)),
          ),
          if (widget.isEmployer && isVerifiedEmployer)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Chip(
                label: Text("Verified Company", style: TextStyle(color: Colors.white)),
                backgroundColor: Colors.blue,
              ),
            ),
          const SizedBox(height: 20),
          _buildProfileField("Full Name", _nameC),
          _buildProfileField("Identity card number", _govC),
          _buildProfileField("Phone Number", _phoneC),
          _buildProfileField("Home Address", _addC),
          _buildProfileField(
            widget.isEmployer ? "About the company" : "About you",
            _aboutC,
            maxLines: 4,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _pickIdDocument,
              icon: const Icon(Icons.upload_file, color: Colors.lightBlueAccent),
              label: Text(
                myProfileData["idDocName"]!.isEmpty ? "Upload identity card document (PDF / image)" : "ID on file: ${myProfileData["idDocName"]}",
                style: const TextStyle(color: Colors.lightBlueAccent),
              ),
            ),
          ),
          const Text(
            "Photo, phone, identity card number, and this ID upload are required before you can post jobs or apply.",
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 8),
          _buildProfileField("Email (login)", _emailC, readOnly: true),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text("To change email, create a new account or contact support.", style: TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          const SizedBox(height: 8),
          _buildProfileField(
            "Current password (only if changing)",
            _curPassC,
            passwordHidden: _hideCurPass,
            onTogglePasswordVisibility: () => setState(() => _hideCurPass = !_hideCurPass),
          ),
          _buildProfileField(
            "New password (optional, 8+ chars)",
            _newPassC,
            passwordHidden: _hideNewPass,
            onTogglePasswordVisibility: () => setState(() => _hideNewPass = !_hideNewPass),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF3D4370),
              minimumSize: const Size(double.infinity, 50),
            ),
            child: _saving
                ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text("SAVE PROFILE", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          TextButton.icon(
            onPressed: () {
              clearAppSession();
              Navigator.pushNamedAndRemoveUntil(context, '/', (r) => false);
            },
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            label: const Text("Log Out", style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
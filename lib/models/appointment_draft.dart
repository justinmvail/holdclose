import 'package:flutter/material.dart' show TimeOfDay;

import '../services/medication_supply.dart' show parseUsLabelDate;
import 'appointment.dart' show ProviderRole;

/// The AI's proposed appointment, read off a photographed appointment card
/// or after-visit slip — a **transient** draft, never persisted. The scan
/// pre-fills the existing appointment form with this; the caregiver edits
/// and approves there (provider find-or-create, date/time, reminders all
/// handled by the form). Pure transcription, never medical advice.
class AppointmentDraft {
  const AppointmentDraft({
    this.providerName,
    this.providerRole,
    this.providerPhone,
    this.providerAddress,
    this.location,
    this.dateText,
    this.timeText,
    this.durationMinutes,
    this.reason,
    this.notes,
  });

  final String? providerName;
  final ProviderRole? providerRole;
  final String? providerPhone;
  final String? providerAddress;

  /// Where the visit happens (may differ from the provider's address —
  /// telehealth, a hospital wing).
  final String? location;

  /// Date/time as printed; parsed into [startsAt].
  final String? dateText;
  final String? timeText;

  final int? durationMinutes;

  /// Visit purpose / chief complaint — becomes an agenda item.
  final String? reason;
  final String? notes;

  bool get isEmpty =>
      _blank(providerName) &&
      _blank(providerPhone) &&
      _blank(location) &&
      _blank(dateText) &&
      _blank(timeText) &&
      _blank(reason) &&
      _blank(notes);

  static bool _blank(String? v) => v == null || v.trim().isEmpty;

  /// Parsed appointment start, combining the date + time text. Null when
  /// the date can't be read; falls back to 9:00 AM when only the date is
  /// legible (the caregiver adjusts the time on the form).
  DateTime? get startsAt {
    final DateTime? day = parseUsLabelDate(dateText);
    if (day == null) return null;
    final TimeOfDay? t = parseClockTime(timeText);
    return DateTime(day.year, day.month, day.day, t?.hour ?? 9, t?.minute ?? 0);
  }

  factory AppointmentDraft.fromModelJson(Map<String, dynamic> json) {
    String? str(Object? v) {
      if (v is String) {
        final String t = v.trim();
        return t.isEmpty ? null : t;
      }
      return null;
    }

    int? intOf(Object? v) {
      final String? s = str(v);
      if (s == null) return null;
      final Match? m = RegExp(r'\d+').firstMatch(s);
      return m == null ? null : int.tryParse(m.group(0)!);
    }

    return AppointmentDraft(
      providerName:
          str(json['providerName']) ?? str(json['provider']) ?? str(json['doctor']),
      providerRole: parseRole(str(json['providerRole']) ?? str(json['role'])),
      providerPhone: str(json['providerPhone']) ??
          str(json['provider_phone']) ??
          str(json['phone']),
      providerAddress: str(json['providerAddress']) ??
          str(json['provider_address']) ??
          str(json['address']),
      location: str(json['location']),
      dateText: str(json['date']),
      timeText: str(json['time']),
      durationMinutes: intOf(json['durationMinutes']) ?? intOf(json['duration']),
      reason: str(json['reason']) ?? str(json['purpose']) ?? str(json['visitReason']),
      notes: str(json['notes']),
    );
  }

  /// Map a free-text role word onto a [ProviderRole]; null only for a null
  /// input (an unrecognised-but-present role collapses to [ProviderRole.other]).
  static ProviderRole? parseRole(String? raw) {
    if (raw == null) return null;
    final String r = raw.toLowerCase();
    if (r.contains('neuro')) return ProviderRole.neurologist;
    if (r.contains('social')) return ProviderRole.socialWorker;
    if (r.contains('doctor') ||
        r.contains('physician') ||
        r.contains('md') ||
        r.contains('dr')) {
      return ProviderRole.doctor;
    }
    return ProviderRole.other;
  }
}

/// Parse a clock time ("2:30 PM", "2 pm", "14:30") into a [TimeOfDay];
/// null on anything it can't read. Visible for tests.
TimeOfDay? parseClockTime(String? s) {
  if (s == null) return null;
  final Match? m = RegExp(
    r'(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\.?',
    caseSensitive: false,
  ).firstMatch(s.trim());
  if (m != null) {
    int hour = int.parse(m.group(1)!);
    final int minute = m.group(2) == null ? 0 : int.parse(m.group(2)!);
    final bool pm = m.group(3)!.toLowerCase() == 'p';
    if (hour == 12) hour = 0;
    if (pm) hour += 12;
    if (hour > 23 || minute > 59) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }
  // 24-hour "14:30".
  final Match? m24 = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s.trim());
  if (m24 != null) {
    final int hour = int.parse(m24.group(1)!);
    final int minute = int.parse(m24.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }
  return null;
}

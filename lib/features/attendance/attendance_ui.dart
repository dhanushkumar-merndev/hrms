import 'package:flutter/material.dart';

import '../../core/widgets/cards.dart';

/// Status text + tone for a day row. Meaning is always carried in text.
(String, ChipTone, IconData) dayStatus(Map<String, dynamic> r) {
  final status = r['status'] as String?;
  return switch (status) {
    'present' => r['is_late'] == true
        ? ('Present · late', ChipTone.warning, Icons.schedule_rounded)
        : ('Present', ChipTone.success, Icons.check_circle_outline_rounded),
    'in_progress' => ('In progress', ChipTone.info, Icons.timelapse_rounded),
    'needs_correction' => ('Needs correction', ChipTone.error, Icons.report_problem_outlined),
    'absent' => ('Absent', ChipTone.error, Icons.cancel_outlined),
    'leave' => ('Leave', ChipTone.info, Icons.beach_access_outlined),
    'holiday' => ('Holiday', ChipTone.neutral, Icons.celebration_outlined),
    'weekly_off' => ('Weekly off', ChipTone.neutral, Icons.weekend_outlined),
    'day_off' => ('Day off', ChipTone.neutral, Icons.event_busy_outlined),
    'not_yet_in' => ('Not yet in', ChipTone.warning, Icons.hourglass_empty_rounded),
    'upcoming' => ('Upcoming', ChipTone.neutral, Icons.event_outlined),
    _ => (status ?? '—', ChipTone.neutral, Icons.help_outline_rounded),
  };
}

String leaveSlotLabel(int slots) => switch (slots) {
      1 => 'AM leave',
      2 => 'PM leave',
      3 => 'Full-day leave',
      _ => '',
    };

String sourceLabel(String? source) => switch (source) {
      'manual' => 'Manual (approved correction)',
      'mixed' => 'Corrected',
      _ => 'Location verified',
    };

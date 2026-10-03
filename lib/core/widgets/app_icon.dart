import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Colourful illustrations used in place of meaningful icons
/// (`assets/illus/<name>.svg`, drawn untinted), plus the tinted status dot
/// (`assets/icons/dot.svg`). Small control glyphs (arrows, close, plus…) are
/// not listed and stay Material icons.
const appIconNames = [
  'admin_panel_settings',
  'alt_route',
  'archive',
  'assignment',
  'attach_file',
  'badge',
  'bank',
  'beach',
  'bolt',
  'build_circle',
  'calendar',
  'campaign',
  'cancel',
  'celebration',
  'check_circle',
  'cloud_done',
  'cloud_off',
  'cloud_upload',
  'construction',
  'credit_card',
  'date_range',
  'description',
  'dot',
  'edit_calendar',
  'edit_note',
  'error',
  'event_available',
  'event_busy',
  'event_note',
  'event_repeat',
  'exposure',
  'fact_check',
  'fingerprint',
  'flight_takeoff',
  'folder',
  'folder_open',
  'folder_zip',
  'gps_fixed',
  'gps_not_fixed',
  'grid_view',
  'groups',
  'help',
  'history',
  'history_edu',
  'home',
  'hourglass',
  'image',
  'inbox',
  'info',
  'insights',
  'inventory_2',
  'location',
  'location_add',
  'location_city',
  'location_off',
  'lock',
  'lock_open',
  'lock_reset',
  'login',
  'logout',
  'meeting_room',
  'my_location',
  'notifications',
  'password',
  'pause_circle',
  'person',
  'person_add',
  'person_off',
  'person_search',
  'phonelink_erase',
  'phonelink_lock',
  'photo_camera',
  'picture_as_pdf',
  'playlist_add',
  'policy',
  'preview',
  'receipt_long',
  'savings',
  'schedule',
  'settings',
  'settings_backup_restore',
  'shield',
  'shield_check',
  'smartphone',
  'table_chart',
  'table_view',
  'task_alt',
  'timelapse',
  'timer',
  'upload_file',
  'verified',
  'view_list',
  'view_week',
  'wallet',
  'warning',
  'wb_sunny',
  'weekend',
  'wifi',
  'wifi_off',
  'work',
];

/// Material icon -> illustration. Several Material variants share one drawing.
final Map<IconData, String> appIconAssets = {
  Icons.account_balance_outlined: 'bank',
  Icons.account_balance_wallet_outlined: 'wallet',
  Icons.add_location_alt_outlined: 'location_add',
  Icons.admin_panel_settings_outlined: 'admin_panel_settings',
  Icons.alt_route_rounded: 'alt_route',
  Icons.archive_outlined: 'archive',
  Icons.assignment_outlined: 'assignment',
  Icons.attach_file_rounded: 'attach_file',
  Icons.badge_outlined: 'badge',
  Icons.beach_access_outlined: 'beach',
  Icons.beach_access_rounded: 'beach',
  Icons.bolt_outlined: 'bolt',
  Icons.bolt_rounded: 'bolt',
  Icons.build_circle_outlined: 'build_circle',
  Icons.calendar_month_outlined: 'calendar',
  Icons.calendar_month_rounded: 'calendar',
  Icons.calendar_today_rounded: 'calendar',
  Icons.campaign_outlined: 'campaign',
  Icons.cancel_outlined: 'cancel',
  Icons.cancel_rounded: 'cancel',
  Icons.celebration_outlined: 'celebration',
  Icons.celebration_rounded: 'celebration',
  Icons.check_circle_outline_rounded: 'check_circle',
  Icons.check_circle_rounded: 'check_circle',
  Icons.circle: 'dot',
  Icons.cloud_done_rounded: 'cloud_done',
  Icons.cloud_off_rounded: 'cloud_off',
  Icons.cloud_upload_outlined: 'cloud_upload',
  Icons.construction_rounded: 'construction',
  Icons.credit_card_rounded: 'credit_card',
  Icons.date_range_rounded: 'date_range',
  Icons.description_outlined: 'description',
  Icons.edit_calendar_outlined: 'edit_calendar',
  Icons.edit_note_rounded: 'edit_note',
  Icons.error_outline_rounded: 'error',
  Icons.event_available_outlined: 'event_available',
  Icons.event_available_rounded: 'event_available',
  Icons.event_busy_outlined: 'event_busy',
  Icons.event_busy_rounded: 'event_busy',
  Icons.event_note_outlined: 'event_note',
  Icons.event_outlined: 'calendar',
  Icons.event_repeat_rounded: 'event_repeat',
  Icons.exposure_rounded: 'exposure',
  Icons.fact_check_outlined: 'fact_check',
  Icons.fingerprint: 'fingerprint',
  Icons.fingerprint_rounded: 'fingerprint',
  Icons.flight_takeoff_rounded: 'flight_takeoff',
  Icons.folder_open_rounded: 'folder_open',
  Icons.folder_outlined: 'folder',
  Icons.folder_zip_outlined: 'folder_zip',
  Icons.gps_fixed_rounded: 'gps_fixed',
  Icons.gps_not_fixed_rounded: 'gps_not_fixed',
  Icons.grid_view_outlined: 'grid_view',
  Icons.grid_view_rounded: 'grid_view',
  Icons.groups_2_outlined: 'groups',
  Icons.groups_outlined: 'groups',
  Icons.help_outline_rounded: 'help',
  Icons.history_edu_rounded: 'history_edu',
  Icons.history_rounded: 'history',
  Icons.home_outlined: 'home',
  Icons.home_rounded: 'home',
  Icons.hourglass_empty_rounded: 'hourglass',
  Icons.hourglass_top_rounded: 'hourglass',
  Icons.image_outlined: 'image',
  Icons.inbox_outlined: 'inbox',
  Icons.info_outline_rounded: 'info',
  Icons.insights_rounded: 'insights',
  Icons.inventory_2_outlined: 'inventory_2',
  Icons.location_city_outlined: 'location_city',
  Icons.location_disabled_outlined: 'location_off',
  Icons.location_off_outlined: 'location_off',
  Icons.location_on_outlined: 'location',
  Icons.lock_open_rounded: 'lock_open',
  Icons.lock_outline_rounded: 'lock',
  Icons.lock_reset_rounded: 'lock_reset',
  Icons.login_rounded: 'login',
  Icons.logout_rounded: 'logout',
  Icons.meeting_room_outlined: 'meeting_room',
  Icons.my_location_outlined: 'my_location',
  Icons.my_location_rounded: 'my_location',
  Icons.notifications_none_rounded: 'notifications',
  Icons.password_rounded: 'password',
  Icons.pause_circle_outline_rounded: 'pause_circle',
  Icons.people_alt_outlined: 'groups',
  Icons.person_add_alt_1_outlined: 'person_add',
  Icons.person_add_alt_1_rounded: 'person_add',
  Icons.person_off_outlined: 'person_off',
  Icons.person_outline_rounded: 'person',
  Icons.person_search_outlined: 'person_search',
  Icons.phonelink_erase_rounded: 'phonelink_erase',
  Icons.phonelink_lock_rounded: 'phonelink_lock',
  Icons.photo_camera_outlined: 'photo_camera',
  Icons.picture_as_pdf_outlined: 'picture_as_pdf',
  Icons.playlist_add_rounded: 'playlist_add',
  Icons.policy_outlined: 'policy',
  Icons.preview_outlined: 'preview',
  Icons.receipt_long_outlined: 'receipt_long',
  Icons.report_problem_outlined: 'warning',
  Icons.savings_outlined: 'savings',
  Icons.schedule_rounded: 'schedule',
  Icons.security_rounded: 'shield_check',
  Icons.settings_backup_restore_rounded: 'settings_backup_restore',
  Icons.settings_outlined: 'settings',
  Icons.shield_outlined: 'shield',
  Icons.smartphone_rounded: 'smartphone',
  Icons.supervisor_account_outlined: 'groups',
  Icons.table_chart_outlined: 'table_chart',
  Icons.table_view_rounded: 'table_view',
  Icons.task_alt_rounded: 'task_alt',
  Icons.timelapse_rounded: 'timelapse',
  Icons.timer_outlined: 'timer',
  Icons.upload_file_rounded: 'upload_file',
  Icons.verified_outlined: 'verified',
  Icons.verified_rounded: 'verified',
  Icons.verified_user_outlined: 'shield_check',
  Icons.view_list_rounded: 'view_list',
  Icons.view_week_outlined: 'view_week',
  Icons.warning_amber_rounded: 'warning',
  Icons.wb_sunny_rounded: 'wb_sunny',
  Icons.weekend_outlined: 'weekend',
  Icons.weekend_rounded: 'weekend',
  Icons.wifi_off_rounded: 'wifi_off',
  Icons.wifi_rounded: 'wifi',
  Icons.work_outline_rounded: 'work',
};

/// Drop-in replacement for [Icon]: draws the illustration for [icon] at the
/// given or themed size. Only the status dot is tinted (by [color] or the
/// [IconTheme]); icons without an illustration fall back to the Material glyph.
class AppIcon extends StatelessWidget {
  const AppIcon(this.icon, {super.key, this.size, this.color, this.semanticLabel});
  final IconData? icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final name = icon == null ? null : appIconAssets[icon];
    if (name == null) return Icon(icon, size: size, color: color, semanticLabel: semanticLabel);
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    var c = color ?? theme.color ?? const Color(0xFF263342);
    if (color == null && theme.opacity != null) c = c.withValues(alpha: c.a * theme.opacity!);
    final tinted = name == 'dot';
    final picture = SvgPicture.asset(
      _path(name),
      width: s,
      height: s,
      colorFilter: tinted ? ColorFilter.mode(c, BlendMode.srcIn) : null,
      placeholderBuilder: (_) => SizedBox.square(dimension: s),
      errorBuilder: (_, _, _) => Icon(icon, size: s, color: c),
    );
    // Like Icon: when a parent forces a bigger box (an input's 48 px icon
    // slot), stay at the requested size and centre instead of stretching.
    final sized = ExcludeSemantics(
      child: Center(widthFactor: 1, heightFactor: 1, child: SizedBox.square(dimension: s, child: picture)),
    );
    return semanticLabel == null ? sized : Semantics(label: semanticLabel, child: sized);
  }
}

String _path(String name) => name == 'dot' ? 'assets/icons/dot.svg' : 'assets/illus/$name.svg';

/// Loads every icon into flutter_svg's cache once at startup so screens never
/// show a blank frame while an icon decodes.
Future<void> precacheAppIcons() async {
  for (final name in appIconNames) {
    final loader = SvgAssetLoader(_path(name));
    try {
      await svg.cache.putIfAbsent(loader.cacheKey(null), () => loader.loadBytes(null));
    } on FlutterError {
      // Missing asset: AppIcon falls back to the Material glyph.
    } on PlatformException {
      // Same as above on some engines.
    }
  }
}

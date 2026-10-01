import '../../core/widgets/app_icon.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Indian-grouped money (₹45,000 / ₹49,500.50). Null -> '—'.
String money(Object? value, {String currency = 'INR'}) {
  final v = value is num ? value : num.tryParse('${value ?? ''}');
  if (v == null) return '—';
  final whole = v == v.roundToDouble();
  return NumberFormat.currency(
    locale: 'en_IN',
    symbol: currency == 'INR' ? '₹' : '$currency ',
    decimalDigits: whole ? 0 : 2,
  ).format(v);
}

const _mask = '• • • • • •';

/// Bank-card style salary card. Everything private stays masked until
/// [revealed]; tapping it calls [onTap] (the screen asks for the
/// fingerprint first).
class SalaryCard extends StatelessWidget {
  const SalaryCard({
    super.key,
    required this.revealed,
    required this.onTap,
    this.profile,
    this.holderFallback,
    this.busy = false,
    this.compact = false,
  });

  final bool revealed;
  final VoidCallback? onTap;
  final Map<String, dynamic>? profile;
  final String? holderFallback;
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final currency = (p?['currency'] as String?) ?? 'INR';
    final bank = revealed ? ((p?['bank_name'] as String?) ?? 'Salary account') : 'Salary account';
    final holder = revealed ? ((p?['account_holder'] as String?) ?? holderFallback ?? '') : (holderFallback ?? '');
    final last4 = p?['account_last4'] as String?;
    final amount = revealed ? money(p?['monthly_salary'], currency: currency) : '₹ $_mask';
    final amountSize = compact ? 26.0 : 32.0;

    return Semantics(
      button: onTap != null,
      label: revealed ? 'Salary card. Monthly salary $amount. Tap to hide.' : 'Salary card, hidden. Tap to reveal.',
      excludeSemantics: true,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
        offset: revealed ? const Offset(0, -0.025) : Offset.zero,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
          scale: busy ? 0.985 : (revealed ? 1.01 : 1),
          child: AspectRatio(
            aspectRatio: compact ? 1.9 : 1.5,
            // The card lifts only when its private values are visible. This
            // gives the interaction a clear response without a perpetual
            // animation running in the background.
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: revealed ? const Color(0x502B3285) : const Color(0x332B3285),
                    blurRadius: revealed ? 28 : 18,
                    offset: Offset(0, revealed ? 14 : 8),
                    spreadRadius: revealed ? -3 : -5,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF1F2560), Color(0xFF3B47B5), Color(0xFF7A55D3)],
                      stops: [0, 0.55, 1],
                    ),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: busy ? null : onTap,
                      child: Stack(
                        children: [
                          // Soft decorative rings.
                          Positioned(right: -60, top: -70, child: _ring(200, 0.08)),
                          Positioned(right: 40, bottom: -90, child: _ring(180, 0.06)),
                          Positioned(left: -40, bottom: -60, child: _ring(140, 0.05)),
                          Padding(
                            padding: EdgeInsets.all(compact ? 18 : 22),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        bank,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.3,
                                        ),
                                      ),
                                    ),
                                    Transform.rotate(
                                      angle: math.pi / 2,
                                      child: const AppIcon(Icons.wifi_rounded, color: Colors.white70, size: 22),
                                    ),
                                  ],
                                ),
                                SizedBox(height: compact ? 8 : 14),
                                const _Chip(),
                                const Spacer(),
                                const Text(
                                  'MONTHLY SALARY',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 11,
                                    letterSpacing: 1.6,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 280),
                                  transitionBuilder: (child, a) => FadeTransition(
                                    opacity: a,
                                    child: SlideTransition(
                                      position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a),
                                      child: child,
                                    ),
                                  ),
                                  child: Text(
                                    amount,
                                    key: ValueKey(revealed),
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: amountSize,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: revealed ? 0.5 : 2,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            revealed && last4 != null
                                                ? '••••  ••••  ••••  $last4'
                                                : '••••  ••••  ••••  ••••',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              letterSpacing: 1.5,
                                              fontFeatures: [FontFeature.tabularFigures()],
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            holder.toUpperCase(),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 1.2),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (busy)
                                      const SizedBox(
                                        width: 26,
                                        height: 26,
                                        child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                                      )
                                    else
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.16),
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            AppIcon(
                                              revealed ? Icons.visibility_off_outlined : Icons.fingerprint_rounded,
                                              color: Colors.white,
                                              size: 18,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              revealed ? 'Hide' : 'Tap to reveal',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _ring(double size, double alpha) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white.withValues(alpha: alpha), width: 28),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        gradient: const LinearGradient(colors: [Color(0xFFF6D98B), Color(0xFFD9A93F)]),
      ),
      child: CustomPaint(painter: _ChipLines()),
    );
  }
}

class _ChipLines extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x66704B00)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), p);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), p);
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

import 'package:flutter/material.dart';

import '../theme.dart';

/// A high-contrast on/off toggle for the caregiver audience — many users are
/// older, and testers found the default Material switch ambiguous (fb
/// 2026-06-14: "people were confused about the slider status … elderly people
/// would have a hard time"). So the state is shown three ways at once:
///   * **"ON" / "OFF" text inside the track**,
///   * the **thumb position** (left = off, right = on), and
///   * a **neutral navy → green track color** that animates smoothly on
///     toggle. OFF is a low-emphasis navy (`primarySoft`), not red — a benign
///     "off" setting must read as calm, not as an error/danger state (a wall
///     of red "OFF" pills in Settings falsely signals something is wrong).
///     Red stays reserved for genuinely destructive/error states.
///
/// Drop-in for a Material [Switch]: same `value` + `onChanged` contract, and a
/// null `onChanged` renders a dimmed, non-interactive control.
class HoldcloseSwitch extends StatelessWidget {
  const HoldcloseSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  static const Duration _dur = Duration(milliseconds: 220);
  static const Curve _curve = Curves.easeInOut;
  static const double _width = 72;
  static const double _height = 34;
  static const double _thumb = 26;

  @override
  Widget build(BuildContext context) {
    final HoldcloseColors hc = context.hc;
    final bool enabled = onChanged != null;
    // ON = success green; OFF = a muted navy neutral (NOT error red), so a
    // column of benign "OFF" settings doesn't read as a wall of alarms.
    final Color track = value ? hc.success : hc.primarySoft;

    return Semantics(
      container: true,
      toggled: value,
      enabled: enabled,
      label: value ? 'On' : 'Off',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: AnimatedContainer(
          duration: _dur,
          curve: _curve,
          width: _width,
          height: _height,
          decoration: BoxDecoration(
            color: enabled ? track : track.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(_height / 2),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              // The state label sits on the side the thumb is NOT on, so it's
              // never covered. It slides + cross-fades as the value flips.
              AnimatedAlign(
                duration: _dur,
                curve: _curve,
                alignment:
                    value ? Alignment.centerLeft : Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: AnimatedSwitcher(
                    duration: _dur,
                    child: Text(
                      value ? 'ON' : 'OFF',
                      key: ValueKey<bool>(value),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ),
              ),
              // The sliding thumb.
              AnimatedAlign(
                duration: _dur,
                curve: _curve,
                alignment:
                    value ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Container(
                    width: _thumb,
                    height: _thumb,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Drop-in replacement for [SwitchListTile] backed by [HoldcloseSwitch].
/// Tapping anywhere on the row toggles, matching SwitchListTile's behavior;
/// [secondary] maps to the row's leading slot.
class HoldcloseSwitchListTile extends StatelessWidget {
  const HoldcloseSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.contentPadding,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? title;
  final Widget? subtitle;
  final Widget? secondary;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: contentPadding,
      leading: secondary,
      title: title,
      subtitle: subtitle,
      trailing: HoldcloseSwitch(value: value, onChanged: onChanged),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

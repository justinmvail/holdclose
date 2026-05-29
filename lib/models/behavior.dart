import 'package:freezed_annotation/freezed_annotation.dart';

part 'behavior.freezed.dart';
part 'behavior.g.dart';

/// One of the 8 canonical behaviors a caregiver can pick from the
/// decoder behavior picker (BUILD_SPEC.md §5.2).
///
/// "Enum-style": instances are constants ([Behavior.canonical]) keyed
/// by [id]. The id is what the LLM system prompt (BUILD_SPEC.md §7.1)
/// and the FakeLLMProvider canned responses (BUILD_SPEC.md §10.2) key
/// off. The label is shown on the card; the glyph is the emoji.
@freezed
abstract class Behavior with _$Behavior {
  const factory Behavior({
    required String id,
    required String label,
    required String glyph,
  }) = _Behavior;

  factory Behavior.fromJson(Map<String, dynamic> json) =>
      _$BehaviorFromJson(json);

  /// The 8 canonical behaviors locked by BUILD_SPEC.md §5.2.
  ///
  /// Order matches the 4×2 grid layout (row-major).
  static const List<Behavior> canonical = <Behavior>[
    Behavior(id: 'upset', label: 'Upset / crying', glyph: '💔'),
    Behavior(id: 'refusing_care', label: 'Refusing care', glyph: '🚪'),
    Behavior(id: 'wants_home', label: '"I want to go home"', glyph: '🏠'),
    Behavior(
      id: 'asking_for_someone',
      label: 'Asking for someone',
      glyph: '👤',
    ),
    Behavior(id: 'accusing', label: 'Accusing me', glyph: '💸'),
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅'),
    Behavior(id: 'wandering', label: 'Wandering / pacing', glyph: '🚶'),
    Behavior(id: 'hallucinating', label: 'Seeing things', glyph: '👁'),
  ];

  /// Lookup the canonical instance by [id]. Returns null for unknown
  /// ids (e.g. the "Something else — describe it" free-text path).
  static Behavior? byId(String id) {
    for (final Behavior b in canonical) {
      if (b.id == id) return b;
    }
    return null;
  }
}

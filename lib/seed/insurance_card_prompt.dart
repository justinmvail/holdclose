/// System prompt for the insurance-card scan. Pure transcription — read the
/// fields off a photographed health-insurance card and return structured
/// JSON. Never medical advice; the caregiver reviews on the emergency card
/// before saving. Vendor/model never named.
const String insuranceCardExtractionSystemPrompt = r'''
You transcribe the text printed on a photographed health-insurance card into
structured data. Report ONLY what is literally printed; use an empty string
for anything not visible. Do not guess.

Return ONLY a single JSON object — no prose, no code fences:
{
  "carrier": "insurance company / plan name, else empty",
  "policyNumber": "member or policy/ID number, else empty",
  "groupNumber": "group number, else empty",
  "phone": "member-services / customer-service phone, else empty"
}
''';

import Foundation

/// The shipped glossary template (spec §2). The canonical text lives here as a
/// string constant so launch provisioning (§4) and the Settings "Restore entries
/// section" affordance (§6) have a single in-process source; a unit test pins it
/// byte-identical to `Resources/glossary_template.md`.
public enum GlossaryTemplate {
    /// Full template text, verbatim per spec §2 (trailing newline included).
    public static let text = """
    # Blaise Glossary

    This file teaches Blaise the names it will hear in your meetings: people,
    companies, products, projects. Blaise uses it to fix misheard words in
    transcripts and to spell names correctly in notes.

    ## Instructions for an AI agent

    You are filling in a speech-recognition glossary for your user. Add one line
    per name under the `## Entries` heading below, in this exact format:

        Canonical Name | misheard1 | misheard2

    - The first field is the correct spelling. The fields after `|` are ways
      speech recognition plausibly mishears it (optional).
    - Draw from: the user's contacts and colleagues, company and team names,
      product and project names, recurring meeting vocabulary. Prefer names that
      actually occur in their meetings; do not paste an entire address book.
    - SAFETY — read carefully. Every alias tells Blaise to rewrite that word,
      wherever it appears, into the canonical form — and a canonical name also
      attracts its own close spelling variants. Blaise screens everything
      against Portuguese and English everyday-word lists and REJECTS or LIMITS
      anything that could rewrite normal speech (each decision is reported in
      the app's Settings, never silently applied). Do your part: never use a
      common word, a common given name, or a short everyday term as an alias;
      prefer distinctive spellings; when unsure, add the name with no aliases —
      a plain name still fixes note spelling even when automatic transcript
      correction is limited for it.
    - Organize with `#` comment lines if you like. Do NOT add `##` headings
      inside the entries (that ends the section), and do not edit anything
      above the `## Entries` heading.

    ## Entries

    # Examples (commented out — replace with your own):
    # Vexatron Labs | Vexatron Labs Inc | Vexatrón
    # Quoll Harbor | Quol Harbour

    """

    /// The `## Entries` heading plus the template's commented examples, appended
    /// by "Restore entries section" to a headingless file (spec §6). Leading
    /// newline separates it from existing EOF text; never touches that text.
    public static let restoreSuffix = """

    ## Entries

    # Examples (commented out — replace with your own):
    # Vexatron Labs | Vexatron Labs Inc | Vexatrón
    # Quoll Harbor | Quol Harbour
    """
}

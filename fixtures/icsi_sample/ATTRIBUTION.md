# Attribution — ICSI Meeting Corpus excerpt

`Bmr001_excerpt_5min.wav` is a test fixture for Blaise. It is a verbatim
~5-minute excerpt (the first 0:00–5:00) of the mixed-headset audio of meeting
**Bmr001** from the **ICSI Meeting Corpus**, a public corpus of real
multi-party research-group meetings recorded at the International Computer
Science Institute, Berkeley.

- **Source:** ICSI Meeting Corpus — https://groups.inf.ed.ac.uk/ami/icsi/
- **License:** Creative Commons Attribution 4.0 International (CC BY 4.0) —
  https://creativecommons.org/licenses/by/4.0/ — full text in
  [`LICENSE-CC-BY-4.0.txt`](./LICENSE-CC-BY-4.0.txt).
- **Citation:** A. Janin, D. Baron, J. Edwards, D. Ellis, et al.,
  "The ICSI Meeting Corpus," Proc. IEEE ICASSP, 2003.

## Modifications

The original `Bmr001.interaction.wav` (mixed headset, 16 kHz mono PCM, ~36 min)
was cut to its first five minutes and written as 16 kHz mono PCM — the source's
native format, so no resampling was applied. The trim is the only modification.
The excerpt is used solely as input audio for Blaise's pipeline regression and
audio-smoke tests.

This fixture contains no data related to Blaise's author or to any private
meeting. It is third-party CC BY 4.0 material, included and redistributed here
under that license with the attribution above.

## License scope — NOT the project's MIT license

Everything in this `fixtures/icsi_sample/` directory is licensed under
**CC BY 4.0**, not under Blaise's MIT license:

- `Bmr001_excerpt_5min.wav` — the audio excerpt (a trimmed derivative of the
  CC BY 4.0 source).
- The committed ASR / diarization / transcript JSON fixtures derived from it
  (`raw_asr.json`, `diarization.json`, `transcript_intermediate_pinned.json`,
  `transcript_pinned.json`, `pin_manifest.json`) — machine-generated
  **adaptations/derivatives** of the CC BY 4.0 audio, and therefore likewise
  CC BY 4.0.

The project's MIT `LICENSE` covers Blaise's own source code; it does **not**
extend to the contents of this directory. Any redistribution of these files
must preserve this attribution and the CC BY 4.0 notice in
`LICENSE-CC-BY-4.0.txt`.

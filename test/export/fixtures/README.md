# Export fixtures

`representative.txt` is the shared DOCX/PDF/EPUB trial manuscript. Use
`input.headings: "markdown"`; otherwise `#` is deliberately ordinary manuscript
text. `representative-expected.json` was authored independently of the parser and
contains exact body text, ruby readings, chapter titles/order/levels and semantic
annotation counts. Do not regenerate these expected values from the code under
test.

The fixture intentionally contains:

- Blank and final empty paragraphs, full-width spaces and a form-feed-only line.
- Explicit and implicit ruby, adjacent rubies, dots, lines, postfix dots and TCY.
- Literal `$math$`, `<tag>`, `*stars*`, English words and a URL.
- Decomposed dakuten, a supplementary variation selector, ZWJ emoji and VS16.

Compare code points exactly. Do not normalize Unicode or remove whitespace to
make a failed comparison pass. A renderer may display a joined emoji differently
while the package preserves its text; report that separately from text loss.

`unsupported-annotations.txt` must preserve unsupported/incomplete notes and
produce source-positioned diagnostics. It is suitable for checking permissive
preview versus strict submission behavior.

`script.txt` provides speaker names, dialogue indentation and stage directions
with ruby and TCY. Choose Japanese headings explicitly if its act/scene titles
should become structural headings.

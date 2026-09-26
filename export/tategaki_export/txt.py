"""Exact UTF-8 snapshot and explicitly encoded body text."""
from pathlib import Path


def export_txt(document, profile, workdir, run_command):
    workdir = Path(workdir)
    source = Path(profile['_source_path']).read_bytes()
    (workdir / 'source.txt').write_bytes(source)
    body = document['expectations']['body_text']
    options = profile['txt']
    # The original snapshot is never newline-converted.
    if options['newline'] == 'crlf':
        body = body.replace('\r\n', '\n').replace('\r', '\n').replace('\n', '\r\n')
    elif options['newline'] == 'lf':
        body = body.replace('\r\n', '\n').replace('\r', '\n')
    try:
        payload = body.encode(options['encoding'], errors='strict')
    except UnicodeEncodeError as error:
        target = error.object[error.start:error.end]
        positions = [run['start'] for block in document['blocks'] for run in block['runs']
                     if any(char in run['text'] for char in target)]
        raise ValueError(f"TXT encoding {options['encoding']} cannot encode {target!r}; "
                         f"body offset {error.start}, source run offsets {positions[:10]}") from error
    path = workdir / 'body.txt'
    path.write_bytes(payload)
    if path.read_bytes().decode(options['encoding']) != body:
        raise ValueError('TXT round trip failed')
    return {'path': str(path), 'validation': {'source_exact': True, 'body_exact': True,
            'encoding': options['encoding'], 'newline': options['newline']}, 'warnings': []}

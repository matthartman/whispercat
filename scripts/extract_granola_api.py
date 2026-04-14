#!/usr/bin/env python3
"""
Extract Granola meeting notes via the public API, including full transcripts.

Requires: GRANOLA_API_KEY environment variable
Writes: ~/Documents/Ghost Pepper Meetings/{date}/{slug}.md

Run extract_granola.py first (local cache, no API key needed), then run this
to enrich files with transcripts. Files that already have ## Transcript are skipped.
"""

import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path


API_BASE = 'https://public-api.granola.ai/v1'


def slugify(title: str, max_len: int = 60) -> str:
    slug = title.lower()
    slug = re.sub(r'[^\w\s-]', '', slug)
    slug = re.sub(r'[\s_]+', '-', slug)
    slug = slug.strip('-')
    return slug[:max_len] if slug else 'untitled'


def parse_date(created_at: str) -> datetime:
    return datetime.fromisoformat(created_at.replace("Z", "+00:00"))


def extract_attendees(people) -> list[str]:
    if not people:
        return []
    if isinstance(people, dict):
        attendees = people.get('attendees', [])
        names = []
        for a in attendees:
            try:
                name = a['details']['person']['name']['fullName']
                names.append(name)
            except (KeyError, TypeError):
                pass
        return names
    if isinstance(people, list):
        names = []
        for p in people:
            if isinstance(p, str):
                names.append(p)
            elif isinstance(p, dict):
                name = p.get('name', p.get('fullName', ''))
                if name:
                    names.append(name)
        return names
    return []


def api_get(path: str, api_key: str) -> dict:
    """Make a GET request to the Granola API."""
    url = f'{API_BASE}{path}'
    req = urllib.request.Request(url)
    req.add_header('Authorization', f'Bearer {api_key}')
    req.add_header('Accept', 'application/json')

    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ''
        print(f'  API error {e.code}: {body[:200]}')
        raise


def fetch_all_notes(api_key: str) -> list[dict]:
    """Fetch all notes via pagination."""
    all_notes = []
    cursor = None

    while True:
        path = '/notes'
        if cursor:
            path += f'?cursor={cursor}'

        data = api_get(path, api_key)
        notes = data.get('notes', data.get('data', []))
        all_notes.extend(notes)

        next_cursor = data.get('next_cursor')
        if not next_cursor or next_cursor == cursor:
            break
        cursor = next_cursor
        time.sleep(0.2)

    return all_notes


def fetch_note_with_transcript(note_id: str, api_key: str) -> dict:
    """Fetch a single note with its transcript."""
    return api_get(f'/notes/{note_id}?include=transcript', api_key)


def build_markdown(note: dict, transcript: str = '') -> str:
    title = note.get('title', 'Untitled Meeting')
    created_at = note.get('created_at', '')
    summary = note.get('summary', '')
    notes_md = note.get('notes_markdown', note.get('notes', ''))
    chapters = note.get('chapters', [])
    people = note.get('people', None)

    date_str = ''
    if created_at:
        try:
            dt = parse_date(created_at)
            date_str = dt.strftime('%Y-%m-%d %I:%M %p')
        except (ValueError, AttributeError):
            date_str = created_at

    attendees = extract_attendees(people)

    lines = ['---']
    lines.append(f'title: "{title}"')
    if date_str:
        lines.append(f'date: "{date_str}"')
    lines.append(f'granola_id: "{note.get("id", "")}"')
    if attendees:
        lines.append(f'attendees: {json.dumps(attendees)}')
    lines.append('source_type: meeting')
    lines.append('imported_from: granola')
    lines.append('---')
    lines.append('')
    lines.append(f'# {title}')
    lines.append('')
    if date_str:
        lines.append(f'**Date:** {date_str}')
    if attendees:
        lines.append(f'**Attendees:** {", ".join(attendees)}')
    if date_str or attendees:
        lines.append('')

    if summary:
        lines.append('## Summary')
        lines.append('')
        lines.append(summary)
        lines.append('')

    if notes_md:
        lines.append('## Notes')
        lines.append('')
        lines.append(notes_md)
        lines.append('')

    if chapters and isinstance(chapters, list):
        lines.append('## Chapters')
        lines.append('')
        for ch in chapters:
            if isinstance(ch, dict):
                ch_title = ch.get('title', ch.get('heading', ''))
                ch_summary = ch.get('summary', ch.get('content', ''))
                if ch_title:
                    lines.append(f'### {ch_title}')
                    lines.append('')
                if ch_summary:
                    lines.append(ch_summary)
                    lines.append('')

    if transcript:
        lines.append('## Transcript')
        lines.append('')
        lines.append(transcript)
        lines.append('')

    return '\n'.join(lines)


def main():
    api_key = os.environ.get('GRANOLA_API_KEY')
    if not api_key:
        print('Set GRANOLA_API_KEY environment variable.')
        print('Get your key from Granola settings.')
        sys.exit(1)

    output_base = os.path.expanduser('~/Documents/Ghost Pepper Meetings')
    if len(sys.argv) > 1:
        output_base = sys.argv[1]

    print('Fetching notes from Granola API...')
    notes = fetch_all_notes(api_key)
    print(f'Found {len(notes)} notes')

    written = 0
    skipped = 0
    enriched = 0

    for note in notes:
        title = note.get('title', 'Untitled')
        created_at = note.get('created_at', '')
        note_id = note.get('id', '')

        # Skip if no title or deleted
        if note.get('deleted_at'):
            skipped += 1
            continue

        date_folder = 'undated'
        if created_at:
            try:
                dt = parse_date(created_at)
                date_folder = dt.strftime('%Y-%m-%d')
            except (ValueError, AttributeError):
                pass

        slug = slugify(title)
        out_dir = os.path.join(output_base, date_folder)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, f'{slug}.md')

        # Check if file exists and already has transcript
        if os.path.exists(out_path):
            with open(out_path, 'r') as f:
                existing = f.read()
            if '## Transcript' in existing:
                skipped += 1
                continue

        # Fetch full note with transcript
        print(f'  Fetching transcript: {title[:50]}...')
        try:
            full_note = fetch_note_with_transcript(note_id, api_key)
            time.sleep(0.2)
        except Exception as e:
            print(f'  ✗ Failed: {e}')
            skipped += 1
            continue

        # Extract transcript
        transcript = ''
        transcript_data = full_note.get('transcript', [])
        if isinstance(transcript_data, list):
            parts = []
            for entry in transcript_data:
                if isinstance(entry, dict):
                    speaker = entry.get('speaker', entry.get('name', ''))
                    text = entry.get('text', entry.get('content', ''))
                    if speaker and text:
                        parts.append(f'**{speaker}:** {text}')
                    elif text:
                        parts.append(text)
                elif isinstance(entry, str):
                    parts.append(entry)
            transcript = '\n\n'.join(parts)
        elif isinstance(transcript_data, str):
            transcript = transcript_data

        # Merge with existing note data or use API data
        markdown = build_markdown(full_note, transcript)
        with open(out_path, 'w') as f:
            f.write(markdown)

        if transcript:
            enriched += 1
            print(f'  ✓ {date_folder}/{slug}.md (with transcript)')
        else:
            written += 1
            print(f'  ✓ {date_folder}/{slug}.md')

    print(f'\nDone! {written} new, {enriched} enriched with transcript, {skipped} skipped')
    print(f'Output: {output_base}')


if __name__ == '__main__':
    main()

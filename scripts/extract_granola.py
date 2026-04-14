#!/usr/bin/env python3
"""
Extract Granola meeting notes from the local cache into markdown files.

Reads: ~/Library/Application Support/Granola/cache-v6.json
Writes: ~/Documents/Ghost Pepper Meetings/{date}/{slug}.md

No API key needed — works entirely from the local cache.
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path


def slugify(title: str, max_len: int = 60) -> str:
    """Convert a title to a file-safe slug."""
    if not title:
        title = 'untitled'
    slug = title.lower()
    slug = re.sub(r'[^\w\s-]', '', slug)
    slug = re.sub(r'[\s_]+', '-', slug)
    slug = slug.strip('-')
    return slug[:max_len] if slug else 'untitled'


def parse_date(created_at: str) -> datetime:
    """Parse ISO format date from Granola."""
    return datetime.fromisoformat(created_at.replace("Z", "+00:00"))


def extract_attendees(people) -> list[str]:
    """Extract attendee names from the people field (handles both formats)."""
    if not people:
        return []

    # Format 1: dict with attendees list
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

    # Format 2: plain list of names or dicts
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


def build_markdown(doc: dict) -> str:
    """Build a markdown file from a Granola document."""
    title = doc.get('title', 'Untitled Meeting')
    created_at = doc.get('created_at', '')
    summary = doc.get('summary', '')
    notes_md = doc.get('notes_markdown', '')
    notes_plain = doc.get('notes_plain', '')
    chapters = doc.get('chapters', [])
    people = doc.get('people', None)

    date_str = ''
    if created_at:
        try:
            dt = parse_date(created_at)
            date_str = dt.strftime('%Y-%m-%d %I:%M %p')
        except (ValueError, AttributeError):
            date_str = created_at

    attendees = extract_attendees(people)

    # YAML frontmatter
    lines = ['---']
    lines.append(f'title: "{title}"')
    if date_str:
        lines.append(f'date: "{date_str}"')
    if 'id' in doc:
        lines.append(f'granola_id: "{doc["id"]}"')
    if attendees:
        lines.append(f'attendees: {json.dumps(attendees)}')
    lines.append('source_type: meeting')
    lines.append('imported_from: granola')
    lines.append('---')
    lines.append('')

    # Title
    lines.append(f'# {title}')
    lines.append('')
    if date_str:
        lines.append(f'**Date:** {date_str}')
    if attendees:
        lines.append(f'**Attendees:** {", ".join(attendees)}')
    if date_str or attendees:
        lines.append('')

    # Summary
    if summary:
        lines.append('## Summary')
        lines.append('')
        lines.append(summary)
        lines.append('')

    # Notes
    notes = notes_md or notes_plain
    if notes:
        lines.append('## Notes')
        lines.append('')
        lines.append(notes)
        lines.append('')

    # Chapters
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
            elif isinstance(ch, str):
                lines.append(f'- {ch}')
        lines.append('')

    return '\n'.join(lines)


def main():
    # Find Granola cache
    cache_path = os.path.expanduser(
        '~/Library/Application Support/Granola/cache-v6.json'
    )
    if not os.path.exists(cache_path):
        print(f'Granola cache not found at: {cache_path}')
        print('Make sure Granola is installed and has been used.')
        sys.exit(1)

    # Determine output directory
    # Use Ghost Pepper meetings directory if configured, else default
    output_base = os.path.expanduser('~/Documents/Ghost Pepper Meetings')
    if len(sys.argv) > 1:
        output_base = sys.argv[1]

    print(f'Reading Granola cache: {cache_path}')

    with open(cache_path, 'r') as f:
        data = json.load(f)

    # Navigate to documents
    try:
        documents = data['cache']['state']['documents']
    except (KeyError, TypeError):
        print('Could not find documents in cache. Structure may have changed.')
        sys.exit(1)

    print(f'Found {len(documents)} documents in cache')

    written = 0
    skipped = 0

    for doc_id, doc in documents.items():
        # Skip deleted
        if doc.get('deleted_at'):
            skipped += 1
            continue

        # Skip invalid meetings
        if doc.get('valid_meeting') is False:
            skipped += 1
            continue

        # Skip empty
        has_content = (
            doc.get('notes_markdown') or
            doc.get('notes_plain') or
            doc.get('summary')
        )
        if not has_content:
            skipped += 1
            continue

        title = doc.get('title', 'Untitled')
        created_at = doc.get('created_at', '')

        # Determine date folder
        date_folder = 'undated'
        if created_at:
            try:
                dt = parse_date(created_at)
                date_folder = dt.strftime('%Y-%m-%d')
            except (ValueError, AttributeError):
                pass

        # Build output path
        slug = slugify(title)
        out_dir = os.path.join(output_base, date_folder)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, f'{slug}.md')

        # Don't overwrite existing files
        if os.path.exists(out_path):
            skipped += 1
            continue

        # Store doc_id for API enrichment later
        doc['id'] = doc_id

        # Write markdown
        markdown = build_markdown(doc)
        with open(out_path, 'w') as f:
            f.write(markdown)

        written += 1
        print(f'  ✓ {date_folder}/{slug}.md — {title}')

    print(f'\nDone! {written} files written, {skipped} skipped')
    print(f'Output: {output_base}')


if __name__ == '__main__':
    main()

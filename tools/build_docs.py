from pathlib import Path
import json, os
import mistune

ROOT = Path(__file__).resolve().parents[1]
md = mistune.create_markdown(renderer='html')
CSS = 'assets/style.css'
JS = 'assets/site.js'

SITES = {
    'partner': json.loads((ROOT / 'config' / 'partner-nav.json').read_text()),
    'full': json.loads((ROOT / 'config' / 'full-nav.json').read_text()),
}

for kind, nav in SITES.items():
    docs_root = ROOT / 'docs' / kind
    site_root = ROOT / 'site' / kind
    for title, rel in nav:
        src = docs_root / rel
        if not src.exists():
            continue
        out = site_root / rel.replace('.md', '.html')
        out.parent.mkdir(parents=True, exist_ok=True)
        html = md(src.read_text())
        links = []
        for nav_title, nav_rel in nav:
            href = os.path.relpath(site_root / nav_rel.replace('.md', '.html'), out.parent)
            cls = 'active' if nav_rel == rel else ''
            links.append(f'<a class="{cls}" href="{href}">{nav_title}</a>')
        doc = f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>{title}</title><link rel='stylesheet' href='{os.path.relpath(ROOT / 'site' / CSS, out.parent)}'></head><body><div class='layout'><aside class='sidebar'><div class='brand'>EIXAM Docs - {kind}</div><nav>{''.join(links)}</nav></aside><main class='content'>{html}</main></div><script src='{os.path.relpath(ROOT / 'site' / JS, out.parent)}'></script></body></html>"
        out.write_text(doc)

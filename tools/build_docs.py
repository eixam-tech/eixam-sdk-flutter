from pathlib import Path
import json, re, os
import mistune

ROOT = Path(__file__).resolve().parents[1]
renderer = mistune.HTMLRenderer(escape=False)
md = mistune.create_markdown(renderer=renderer, plugins=['table', 'strikethrough'])

def slugify(text: str) -> str:
    text = text.lower()
    text = re.sub(r'[^a-z0-9]+', '-', text).strip('-')
    return text or 'section'

def render_markdown(text: str):
    lines = text.splitlines()
    toc = []
    out = []
    for line in lines:
        if line.startswith('#'):
            level = len(line) - len(line.lstrip('#'))
            title = line[level:].strip()
            if level in (2, 3):
                anchor = slugify(title)
                toc.append((level, title, anchor))
                out.append(f'<a id="{anchor}"></a>')
        out.append(line)
    text = '\n'.join(out)
    text = re.sub(r'\(([^)]+)\.md\)', lambda m: '(' + m.group(1) + '.html)', text)
    return md(text), toc

def build_one(site_name: str, nav_file: str):
    nav = json.loads((ROOT / 'config' / nav_file).read_text(encoding='utf-8'))
    site_root = ROOT / 'site' / site_name
    site_root.mkdir(parents=True, exist_ok=True)
    asset_dir = site_root / 'assets'
    asset_dir.mkdir(parents=True, exist_ok=True)
    (asset_dir / 'style.css').write_text((ROOT / 'tools' / 'style.css').read_text(encoding='utf-8'), encoding='utf-8')
    pages = []
    for label, src in nav:
        src_path = ROOT / src
        rel = src_path.relative_to(ROOT / 'docs' / site_name)
        out_path = site_root / rel.with_suffix('.html')
        out_path.parent.mkdir(parents=True, exist_ok=True)
        pages.append((label, rel.as_posix(), src_path, out_path))
    for label, rel, src_path, out_path in pages:
        text = src_path.read_text(encoding='utf-8')
        body, toc = render_markdown(text)
        current = rel.replace('.md', '.html')
        sidebar_items = []
        for nav_label, nav_rel, _, _ in pages:
            target = site_root / nav_rel.replace('.md', '.html')
            href = os.path.relpath(target, out_path.parent).replace('\\', '/')
            active = ' class="active"' if nav_rel.replace('.md', '.html') == current else ''
            sidebar_items.append(f'<a{active} href="{href}">{nav_label}</a>')
        toc_items = []
        for level, title, anchor in toc:
            toc_items.append(f'<a class="toc-level-{level}" href="#{anchor}">{title}</a>')
        m = re.search(r'^#\s+(.+)$', text, flags=re.M)
        page_title = m.group(1) if m else label
        css_href = os.path.relpath(site_root / 'assets' / 'style.css', out_path.parent).replace('\\', '/')
        html = f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{page_title}</title>
  <link rel="stylesheet" href="{css_href}" />
</head>
<body>
  <header class="topbar">
    <div class="brand">EIXAM Connect SDK</div>
    <div class="site-tag">{site_name} docs</div>
  </header>
  <div class="layout">
    <aside class="sidebar">
      <div class="sidebar-title">Navigation</div>
      {''.join(sidebar_items)}
    </aside>
    <main class="content">{body}</main>
    <aside class="toc">
      <div class="toc-title">On this page</div>
      {''.join(toc_items)}
    </aside>
  </div>
</body>
</html>'''
        out_path.write_text(html, encoding='utf-8')

if __name__ == '__main__':
    build_one('partner', 'partner-nav.json')
    build_one('full', 'full-nav.json')

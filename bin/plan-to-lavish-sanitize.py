import html
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit

SAFE_TAGS = {
    "a", "blockquote", "br", "code", "del", "div", "em", "h1", "h2",
    "h3", "h4", "h5", "h6", "hr", "li", "ol", "p", "pre", "span",
    "strong", "table", "tbody", "td", "th", "thead", "tr", "ul",
}
VOID_TAGS = {"br", "hr"}
HTML_VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}
SAFE_ATTRS = {"class", "id", "title", "href", "colspan", "rowspan"}


def safe_url(value):
    if value != value.strip() or any(ord(char) < 32 for char in value):
        return False
    return urlsplit(value).scheme.lower() in {"", "http", "https", "mailto"}


class Sanitizer(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.output = []
        self.skipped = 0

    def rendered_starttag(self, tag, attrs):
        rendered = []
        for name, value in attrs:
            name = name.lower()
            value = value or ""
            if name not in SAFE_ATTRS or name.startswith("on"):
                continue
            if name == "href" and not safe_url(value):
                continue
            rendered.append(f' {name}="{html.escape(value, quote=True)}"')
        return f"<{tag}{''.join(rendered)}>"

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if self.skipped:
            if tag not in HTML_VOID_TAGS:
                self.skipped += 1
            return
        if tag not in SAFE_TAGS:
            if tag not in HTML_VOID_TAGS:
                self.skipped = 1
            return
        self.output.append(self.rendered_starttag(tag, attrs))

    def handle_startendtag(self, tag, attrs):
        tag = tag.lower()
        if self.skipped or tag not in SAFE_TAGS:
            return
        self.output.append(self.rendered_starttag(tag, attrs))
        if tag not in VOID_TAGS:
            self.output.append(f"</{tag}>")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if self.skipped:
            if tag not in HTML_VOID_TAGS:
                self.skipped -= 1
            return
        if tag in SAFE_TAGS and tag not in VOID_TAGS:
            self.output.append(f"</{tag}>")

    def handle_data(self, data):
        if not self.skipped:
            self.output.append(html.escape(data))


parser = Sanitizer()
parser.feed(sys.stdin.read())
parser.close()
sys.stdout.write("".join(parser.output))

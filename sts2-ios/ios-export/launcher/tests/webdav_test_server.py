#!/usr/bin/env python3
"""最小 WebDAV 测试服务器（PROPFIND Depth 0/1、GET、PUT、MKCOL、Basic 认证），只用于宿主测试。
用法：webdav_test_server.py <根目录> <端口>；账号 tester / pw-123456。"""
import base64, email.utils, hashlib, http.server, os, sys, urllib.parse
from xml.sax.saxutils import escape

ROOT = os.path.abspath(sys.argv[1]); PORT = int(sys.argv[2]); PREFIX = '/dav/'
AUTH = 'Basic ' + base64.b64encode(b'tester:pw-123456').decode()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def local(self):
        path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        if not path.startswith(PREFIX): return None
        full = os.path.abspath(os.path.join(ROOT, path[len(PREFIX):]))
        return full if full == ROOT or full.startswith(ROOT + os.sep) else None
    def check(self):
        if self.headers.get('Authorization') != AUTH:
            self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="t"'); self.send_header('Content-Length', '0'); self.end_headers(); return None
        target = self.local()
        if target is None: self.reply(403)
        return target
    def reply(self, code, body=b'', ctype='text/plain'):
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def body(self):
        n = int(self.headers.get('Content-Length') or 0); return self.rfile.read(n) if n else b''
    def entry(self, full):
        rel = os.path.relpath(full, ROOT).replace(os.sep, '/')
        href = PREFIX + ('' if rel == '.' else urllib.parse.quote(rel) + ('/' if os.path.isdir(full) else ''))
        st = os.stat(full)
        if os.path.isdir(full): props = '<d:resourcetype><d:collection/></d:resourcetype>'
        else:
            etag = hashlib.md5(open(full, 'rb').read()).hexdigest()
            props = '<d:resourcetype/><d:getcontentlength>%d</d:getcontentlength><d:getetag>"%s"</d:getetag>' % (st.st_size, etag)
        props += '<d:getlastmodified>%s</d:getlastmodified>' % email.utils.formatdate(st.st_mtime, usegmt=True)
        return '<d:response><d:href>%s</d:href><d:propstat><d:prop>%s</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>' % (escape(href), props)
    def do_PROPFIND(self):
        target = self.check(); self.body()
        if target is None: return
        if not os.path.exists(target): return self.reply(404)
        items = [target]
        if os.path.isdir(target) and self.headers.get('Depth', '1') != '0': items += [os.path.join(target, n) for n in sorted(os.listdir(target))]
        xml = '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">%s</d:multistatus>' % ''.join(self.entry(i) for i in items)
        self.reply(207, xml.encode(), 'application/xml; charset=utf-8')
    def do_MKCOL(self):
        target = self.check(); self.body()
        if target is None: return
        if os.path.exists(target): return self.reply(405)
        if not os.path.isdir(os.path.dirname(target)): return self.reply(409)
        os.mkdir(target); self.reply(201)
    def do_PUT(self):
        target = self.check(); data = self.body()
        if target is None: return
        if not os.path.isdir(os.path.dirname(target)): return self.reply(409)
        open(target, 'wb').write(data); self.reply(201)
    def do_GET(self):
        target = self.check()
        if target is None: return
        if not os.path.isfile(target): return self.reply(404)
        self.reply(200, open(target, 'rb').read(), 'application/octet-stream')

http.server.ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()

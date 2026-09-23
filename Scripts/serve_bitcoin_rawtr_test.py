#!/usr/bin/env python3
"""Supply an opt-in simulator test with one private descriptor, in memory only."""
import getpass
import http.server


def main():
    descriptor = getpass.getpass('Private rawtr descriptor (hidden): ').strip()
    if not descriptor.startswith('rawtr('):
        raise SystemExit('Expected a rawtr descriptor.')

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            nonlocal descriptor
            if self.path != '/rawtr-once':
                self.send_error(404)
                return
            data = descriptor.encode('utf-8')
            descriptor = ''
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    with http.server.HTTPServer(('127.0.0.1', 18457), Handler) as server:
        server.timeout = 600
        print('Waiting for one local test request.', flush=True)
        server.handle_request()
    descriptor = ''


if __name__ == '__main__':
    main()

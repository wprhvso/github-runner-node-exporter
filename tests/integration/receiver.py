import argparse
import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--user", default="")
parser.add_argument("--password", default="")
parser.add_argument("--status", type=int, default=204)
parser.add_argument("--state", required=True)
args = parser.parse_args()

lock = threading.Lock()
state = {"accepted": 0, "rejected": 0, "bytes": 0, "snappy": 0, "paths": [], "writes": 0, "port": 0}


def flush():
    with open(args.state, "w") as handle:
        json.dump(state, handle)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        expected = "Basic " + base64.b64encode(
            f"{args.user}:{args.password}".encode()
        ).decode()
        authorized = self.headers.get("Authorization") == expected
        with lock:
            if authorized:
                state["accepted"] += 1
                if body:
                    state["writes"] += 1
                state["bytes"] += len(body)
                if self.headers.get("Content-Encoding") == "snappy":
                    state["snappy"] += 1
            else:
                state["rejected"] += 1
            if self.path not in state["paths"]:
                state["paths"].append(self.path)
            flush()
        status = args.status if authorized else 401
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
state["port"] = server.server_address[1]
flush()
server.serve_forever()

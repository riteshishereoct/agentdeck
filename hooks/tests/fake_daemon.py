import hashlib, json, os, socket, sys, threading, time, uuid

sock_path, mode, logfile = sys.argv[1:4]
envfile = sys.argv[4] if len(sys.argv) > 4 else ""
env = open(envfile, "rb").read() if envfile else b""
lock = threading.Lock()
H200 = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"


def read_req(c):
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = c.recv(4096)
        if not d:
            return None
        buf += d
    head, _, body = buf.partition(b"\r\n\r\n")
    lines = head.decode("latin1").split("\r\n")
    hd = {}
    for l in lines[1:]:
        k, _, v = l.partition(":")
        hd[k.strip().lower()] = v.strip()
    if hd.get("expect", "").lower() == "100-continue":
        c.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
    n = int(hd.get("content-length", "0"))
    while len(body) < n:
        d = c.recv(65536)
        if not d:
            break
        body += d
    return lines[0], hd, body


def reply(c, body, status="200 OK"):
    c.sendall(f"HTTP/1.1 {status}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)


def wait(c):
    if mode == "hold-silent":
        time.sleep(30)
    elif mode == "hold-heartbeat-forever":   # a live daemon: beats until the peer goes, then records when it saw that
        c.sendall(H200)
        c.settimeout(0.25)
        end = time.time() + 30
        while time.time() < end:
            try:
                c.sendall(b"    ")
                if c.recv(1) == b"":
                    break
            except TimeoutError:
                continue
            except OSError:
                break
        open(logfile + ".closed", "w").write("%.3f" % time.time())
    elif mode == "wait404":
        reply(c, b"", "404 Not Found")
    elif mode == "hold-json":
        c.sendall(H200 + env)
    elif mode in ("hold-heartbeat-json", "hold-heartbeat-empty"):
        c.sendall(H200)
        for _ in range(3):
            c.sendall(b"    ")
            time.sleep(1)
        if mode == "hold-heartbeat-json":
            c.sendall(env)


def handle(c):
    try:
        r = read_req(c)
        if r is None:
            return
        line, hd, body = r
        with lock, open(logfile, "a") as f:
            f.write(json.dumps({"line": line, "headers": hd, "sha256": hashlib.sha256(body).hexdigest()}) + "\n")
        if mode == "hang":
            time.sleep(30)
            return
        if "/v1/wait/" in line:
            return wait(c)
        if "/v1/event/" in line:
            return c.sendall(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
        if mode == "pass":
            reply(c, b"PASS")
        elif mode == "decide":
            reply(c, b"DECIDE " + env.rstrip(b"\n"))
        elif mode.startswith("hold") or mode == "wait404":
            reply(c, b"HOLD " + str(uuid.uuid4()).upper().encode())
        elif mode == "http500":
            reply(c, b"", "500 Internal Server Error")
        else:
            reply(c, b"WHAT")
    except OSError:
        pass
    finally:
        c.close()


s = socket.socket(socket.AF_UNIX)
s.bind(sock_path)
s.listen(64)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()

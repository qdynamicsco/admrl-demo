#!/usr/bin/env python3
"""Teflon/rocket SSD demo with NPU<->CPU verification."""
import argparse, os, sys, threading, time
import cv2
import numpy as np
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

latest_frame = None
frame_lock = threading.Lock()

MODEL  = "/opt/assets/detect_model.tflite"
LABELS = "/opt/assets/detect_labels.txt"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--source", default=None)
    p.add_argument("--cpu", action="store_true", help="Bypass NPU entirely")
    p.add_argument("--verify", action="store_true",
                   help="Run one frame on NPU and CPU and print tensor diffs, then exit")
    p.add_argument("--threshold", type=float, default=0.4)
    p.add_argument("--letterbox", action="store_true", default=True)
    p.add_argument("--port", type=int, default=8000)
    return p.parse_args()


def _interp_mod():
    try:
        from tflite_runtime.interpreter import Interpreter, load_delegate
    except ImportError:
        from ai_edge_litert.interpreter import Interpreter, load_delegate
    return Interpreter, load_delegate


def make_interpreter(use_npu):
    Interpreter, load_delegate = _interp_mod()
    delegates = []
    if use_npu:
        path = os.environ.get("TEFLON_DELEGATE", "/usr/local/lib/libteflon.so")
        print(f"Loading NPU delegate: {path}", flush=True)
        try:
            delegates = [load_delegate(path)]
        except Exception as e:
            sys.exit(f"Failed to load delegate: {e}")
    else:
        print("Running CPU (XNNPACK) inference", flush=True)
    it = Interpreter(model_path=MODEL, experimental_delegates=delegates,
                     num_threads=1 if use_npu else 4)
    it.allocate_tensors()
    return it


def map_outputs(out_details):
    """Robustly identify the 4 TFLite_Detection_PostProcess outputs.

    Canonical order is boxes[1,N,4], classes[1,N], scores[1,N], count[1],
    but delegates/converters can reorder, so use shape + semantics.
    """
    boxes = count = None
    flat = []
    for d in out_details:
        shp = [int(x) for x in d["shape"]]
        if len(shp) == 3 and shp[-1] == 4:
            boxes = d
        elif len(shp) == 1 or (len(shp) == 2 and shp[-1] == 1):
            count = d
        else:
            flat.append(d)
    if boxes is None or count is None or len(flat) != 2:
        raise RuntimeError(f"unexpected outputs: {[d['shape'] for d in out_details]}")
    flat.sort(key=lambda d: d["index"])
    return boxes, flat[0], flat[1], count   # classes, scores (fixed up at runtime)


def preprocess(frame, w, h, dtype, letterbox):
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    if letterbox:
        ih, iw = rgb.shape[:2]
        s = min(w / iw, h / ih)
        nw, nh = int(round(iw * s)), int(round(ih * s))
        pad = np.zeros((h, w, 3), np.uint8)
        ox, oy = (w - nw) // 2, (h - nh) // 2
        pad[oy:oy + nh, ox:ox + nw] = cv2.resize(rgb, (nw, nh))
        img, meta = pad, (s, ox, oy)
    else:
        img, meta = cv2.resize(rgb, (w, h)), (None, 0, 0)

    if dtype == np.uint8:
        data = img
    elif dtype == np.int8:
        data = (img.astype(np.int16) - 128).astype(np.int8)
    else:
        data = (img.astype(np.float32) - 127.5) / 127.5
    return np.expand_dims(data, 0), meta


def run(it, data):
    idx = it.get_input_details()[0]["index"]
    it.set_tensor(idx, data)
    it.invoke()
    return [it.get_tensor(d["index"]).copy() for d in it.get_output_details()]


def decode(it, outs, threshold):
    b, c, s, n = map_outputs(it.get_output_details())
    order = {d["index"]: i for i, d in enumerate(it.get_output_details())}
    boxes   = outs[order[b["index"]]][0]
    a       = outs[order[c["index"]]][0]
    bb      = outs[order[s["index"]]][0]
    count   = int(np.array(outs[order[n["index"]]]).flatten()[0])
    # scores are emitted sorted descending in [0,1]; classes are integers.
    def looks_like_scores(v):
        v = np.asarray(v, np.float64)
        return v.size and v.max() <= 1.0001 and np.all(np.diff(v) <= 1e-6)
    if looks_like_scores(bb) and not looks_like_scores(a):
        classes, scores = a, bb
    elif looks_like_scores(a) and not looks_like_scores(bb):
        classes, scores = bb, a
    else:  # ambiguous -> fall back to integer-ness
        classes, scores = (a, bb) if np.all(np.mod(a, 1) == 0) else (bb, a)
    count = max(0, min(count, len(scores)))
    keep = [i for i in range(count) if scores[i] > threshold]
    return boxes, classes, scores, keep


def unletterbox(box, meta, w_orig, h_orig, in_w, in_h):
    s, ox, oy = meta
    ymin, xmin, ymax, xmax = box
    if s is None:
        return (ymin * h_orig, xmin * w_orig, ymax * h_orig, xmax * w_orig)
    return ((ymin * in_h - oy) / s, (xmin * in_w - ox) / s,
            (ymax * in_h - oy) / s, (xmax * in_w - ox) / s)


def open_source(args):
    src, is_file = args.source, False
    if src is not None:
        if isinstance(src, str) and not src.isdigit():
            is_file = True
        else:
            src = int(src)
    elif os.path.exists("/dev/video0"):
        src = 0
    else:
        src, is_file = "/opt/assets/sample.mp4", True
    return cv2.VideoCapture(src), is_file


def verify(args):
    cap, _ = open_source(args)
    ok, frame = cap.read()
    if not ok:
        sys.exit("could not read a frame")
    npu = make_interpreter(True)
    cpu = make_interpreter(False)
    d = npu.get_input_details()[0]
    h, w = int(d["shape"][1]), int(d["shape"][2])
    data, _ = preprocess(frame, w, h, d["dtype"], args.letterbox)

    a = run(npu, data)
    b = run(cpu, data)
    print("\n--- NPU vs CPU ---")
    bad = False
    for det, x, y in zip(npu.get_output_details(), a, b):
        x = np.asarray(x, np.float64); y = np.asarray(y, np.float64)
        diff = np.abs(x - y)
        print(f"{det['name'][:40]:42s} shape={list(det['shape'])} "
              f"max|d|={diff.max():.5f} mean|d|={diff.mean():.5f}")
        bad |= diff.max() > 1e-3
    print("\nRESULT:", "MISMATCH -> driver/delegate bug" if bad else "match")
    print("\nNPU decode:", decode(npu, a, args.threshold)[3])
    print("CPU decode:", decode(cpu, b, args.threshold)[3])
    sys.exit(1 if bad else 0)


def inference_thread(args):
    global latest_frame
    it = make_interpreter(not args.cpu)
    d = it.get_input_details()[0]
    in_h, in_w = int(d["shape"][1]), int(d["shape"][2])
    with open(LABELS) as f:
        labels = [l.strip() for l in f]

    cap, is_file = open_source(args)
    ema = None
    while True:
        ok, frame = cap.read()
        if not ok:
            if is_file:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                continue
            break
        t0 = time.perf_counter()
        data, meta = preprocess(frame, in_w, in_h, d["dtype"], args.letterbox)
        outs = run(it, data)
        dt = time.perf_counter() - t0
        ema = dt if ema is None else 0.9 * ema + 0.1 * dt

        boxes, classes, scores, keep = decode(it, outs, args.threshold)
        H, W = frame.shape[:2]
        for i in keep:
            ymin, xmin, ymax, xmax = unletterbox(boxes[i], meta, W, H, in_w, in_h)
            x0, y0 = int(max(0, xmin)), int(max(0, ymin))
            x1, y1 = int(min(W, xmax)), int(min(H, ymax))
            cid = int(classes[i])
            name = labels[cid] if cid < len(labels) else f"ID {cid}"
            cv2.rectangle(frame, (x0, y0), (x1, y1), (0, 255, 0), 2)
            cv2.putText(frame, f"{name}: {int(scores[i]*100)}%", (x0, max(15, y0 - 8)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
        tag = "CPU" if args.cpu else "NPU"
        cv2.putText(frame, f"{tag} {1.0/ema:5.1f} fps  ({len(keep)} det)",
                    (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1,
                    (0, 0, 255) if args.cpu else (255, 0, 0), 2)
        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
        if ok:
            with frame_lock:
                latest_frame = buf.tobytes()


class CamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path != "/":
            self.send_error(404); return
        self.send_response(200)
        self.send_header("Content-Type",
                         "multipart/x-mixed-replace; boundary=jpgboundary")
        self.end_headers()
        try:
            while True:
                with frame_lock:
                    f = latest_frame
                if f is None:
                    time.sleep(0.05); continue
                self.wfile.write(b"--jpgboundary\r\n"
                                 b"Content-Type: image/jpeg\r\n"
                                 b"Content-Length: " + str(len(f)).encode() +
                                 b"\r\n\r\n" + f + b"\r\n")
                time.sleep(0.02)
        except Exception:
            pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    args = parse_args()
    if args.verify:
        verify(args)
    threading.Thread(target=inference_thread, args=(args,), daemon=True).start()
    ThreadedHTTPServer(("0.0.0.0", args.port), CamHandler).serve_forever()
#!/usr/bin/env python3
"""YOLO11 stream demo via Vendor RKNN API."""
import argparse
import os
import sys
import threading
import time
import cv2
import numpy as np
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from rknnlite.api import RKNNLite

sys.path.append('/opt/rknn_model_zoo/examples/yolo11/python')
try:
    import yolo11 as vendor_yolo
except ImportError as e:
    sys.exit(f"Failed to find vendor YOLO script. Check model zoo clone: {e}")

def pure_numpy_dfl(position):
    x = np.asarray(position)
    n, c, h, w = x.shape
    p_num = 4
    mc = c // p_num
    y = x.reshape(n, p_num, mc, h, w)
    
    # Softmax on axis 2
    exp_y = np.exp(y - np.max(y, axis=2, keepdims=True))
    y = exp_y / np.sum(exp_y, axis=2, keepdims=True)
    
    acc_metrix = np.arange(mc, dtype=np.float32).reshape(1, 1, mc, 1, 1)
    return np.sum(y * acc_metrix, axis=2)

# Apply the patch!
vendor_yolo.dfl = pure_numpy_dfl

MODEL = "/opt/assets/yolo11.rknn"

latest_frame = None
frame_lock = threading.Lock()


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--source", default=None)
    p.add_argument("--threshold", type=float, default=0.25)
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--letterbox", action="store_true", default=True)
    return p.parse_args()


def make_rynn():
    print(f"Loading RKNN model: {MODEL}", flush=True)
    rknn = RKNNLite()
    if rknn.load_rknn(MODEL) != 0:
        sys.exit("\nFailed to load model. Did you compile the ONNX to RKNN via x86 toolkit?")
    if rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_AUTO) != 0:
        sys.exit("\nFailed to init NPU. Is /dev/rknpu (or /dev/galcore) mapped into the container?")
    return rknn


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
        # Fallback to test video if no webcam passed
        src, is_file = "/opt/assets/sample.mp4", True
        
    cap = cv2.VideoCapture(src)
    
    if not is_file:
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        
    return cap, is_file


def preprocess(frame, w, h, letterbox):
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    if letterbox:
        ih, iw = rgb.shape[:2]
        s = min(w / iw, h / ih)
        nw, nh = int(round(iw * s)), int(round(ih * s))
        pad = np.zeros((h, w, 3), np.uint8)
        ox, oy = (w - nw) // 2, (h - nh) // 2
        pad[oy:oy + nh, ox:ox + nw] = cv2.resize(rgb, (nw, nh))
        return pad, (s, ox, oy)
    return cv2.resize(rgb, (w, h)), (None, 0, 0)


def inference_thread(args):
    global latest_frame
    rknn = make_rynn()
    cap, is_file = open_source(args)
    ema = None

    IN_W, IN_H = 640, 640

    while True:
        ok, frame = cap.read()
        if not ok:
            if is_file:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                continue
            break
            
        t0 = time.perf_counter()
        
        img_resized, meta = preprocess(frame, IN_W, IN_H, args.letterbox)
        input_data = np.expand_dims(img_resized, axis=0)
        
        # Inference runs blockingly
        outputs = rknn.inference(inputs=[input_data])
        
        dt = time.perf_counter() - t0
        ema = dt if ema is None else 0.9 * ema + 0.1 * dt

        # Offload decoding loop
        try:
            boxes, classes, scores = vendor_yolo.post_process(outputs)
            if boxes is not None:
                boxes, classes, scores = np.array(boxes), np.array(classes), np.array(scores)
                mask = scores >= args.threshold
                
                s, ox, oy = meta
                H, W = frame.shape[:2]

                for bbox, score, cid in zip(boxes[mask], scores[mask], classes[mask]):
                    xmin, ymin, xmax, ymax = bbox
                    
                    if s is not None:
                        x0, y0 = int((xmin - ox) / s), int((ymin - oy) / s)
                        x1, y1 = int((xmax - ox) / s), int((ymax - oy) / s)
                    else:
                        x0, y0 = int(xmin * W / IN_W), int(ymin * H / IN_H)
                        x1, y1 = int(xmax * W / IN_W), int(ymax * H / IN_H)
                        
                    x0, y0 = max(0, x0), max(0, y0)
                    x1, y1 = min(W, x1), min(H, y1)

                    cid = int(cid)
                    name = vendor_yolo.CLASSES[cid] if cid < len(vendor_yolo.CLASSES) else f"ID {cid}"
                    
                    cv2.rectangle(frame, (x0, y0), (x1, y1), (0, 255, 0), 2)
                    cv2.putText(frame, f"{name}: {int(score*100)}%", (x0, max(15, y0 - 8)),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
                
        except Exception as e:
            cv2.putText(frame, f"Decode err: {e}", (10, 80), 
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

        cv2.putText(frame, f"RKNN {1.0/max(1e-5, ema):5.1f} fps", (10, 30), 
                    cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 0, 0), 2)

        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
        if ok:
            with frame_lock:
                latest_frame = buf.tobytes()


class CamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return
            
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=jpgboundary")
        self.end_headers()
        try:
            while True:
                with frame_lock:
                    f = latest_frame
                if f is None:
                    time.sleep(0.05)
                    continue
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
    threading.Thread(target=inference_thread, args=(args,), daemon=True).start()
    print(f"Starting server on http://0.0.0.0:{args.port}", flush=True)
    ThreadedHTTPServer(("0.0.0.0", args.port), CamHandler).serve_forever()
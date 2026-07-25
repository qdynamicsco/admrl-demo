#!/usr/bin/env python3
"""Real-time SSD-MobileNet Object Detection over MJPEG web stream."""
import argparse, cv2, os, sys, threading, time
import numpy as np
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

latest_frame = None
frame_lock = threading.Lock()

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--source", default=None, 
                   help="Video source: device ID (e.g. 0), or file path (e.g. /opt/assets/sample.mp4)")
    return p.parse_args()

def video_inference_thread(source_arg):
    global latest_frame
    
    delegate_path = os.environ.get("TEFLON_DELEGATE", "/usr/local/lib/libteflon.so")
    print(f"Loading delegate: {delegate_path}")
    
    try:
        delegates = [load_delegate(delegate_path)]
    except Exception as e:
        sys.exit(f"Failed to load delegate: {e}")
        
    model_path = "/opt/assets/detect_model.tflite"
    interpreter = Interpreter(model_path=model_path, experimental_delegates=delegates)
    interpreter.allocate_tensors()
    
    in_details = interpreter.get_input_details()[0]
    out_details = interpreter.get_output_details()
    height, width = in_details['shape'][1], in_details['shape'][2]

    with open("/opt/assets/detect_labels.txt", "r") as f:
        labels = [line.strip() for line in f.readlines()]

    # Determine input source: explicit arg -> /dev/video0 -> sample.mp4
    is_file = False
    if source_arg is not None:
        source = int(source_arg) if source_arg.isdigit() else source_arg
        if isinstance(source, str): is_file = True
    elif os.path.exists("/dev/video0"):
        print("Detected /dev/video0 — using live webcam.")
        source = 0
    else:
        print("No webcam found — defaulting to built-in video /opt/assets/sample.mp4")
        source = "/opt/assets/sample.mp4"
        is_file = True

    cap = cv2.VideoCapture(source)
    if not cap.isOpened():
        sys.exit(f"Error: Could not open video source: {source}")

    print(f"Video pipeline active ({source}). Processing frames on NPU...")
    
    while True:
        ret, frame = cap.read()
        if not ret:
            if is_file: # Loop video file endlessly
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                continue
            else:
                break
            
        t0 = time.perf_counter()
        img_resized = cv2.resize(frame, (width, height))
        input_data = np.expand_dims(img_resized, axis=0)

        interpreter.set_tensor(in_details['index'], input_data)
        interpreter.invoke()

        boxes = interpreter.get_tensor(out_details[0]['index'])[0]
        classes = interpreter.get_tensor(out_details[1]['index'])[0]
        scores = interpreter.get_tensor(out_details[2]['index'])[0]
        
        fps = 1.0 / (time.perf_counter() - t0)

        h_orig, w_orig, _ = frame.shape
        for i in range(len(scores)):
            if scores[i] > 0.5:
                ymin = int(max(1, (boxes[i][0] * h_orig)))
                xmin = int(max(1, (boxes[i][1] * w_orig)))
                ymax = int(min(h_orig, (boxes[i][2] * h_orig)))
                xmax = int(min(w_orig, (boxes[i][3] * w_orig)))
                
                class_id = int(classes[i])
                label_str = labels[class_id] if class_id < len(labels) else f"ID {class_id}"
                label = f"{label_str}: {int(scores[i]*100)}%"
                
                cv2.rectangle(frame, (xmin, ymin), (xmax, ymax), (0, 255, 0), 2)
                cv2.putText(frame, label, (xmin, ymin - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)

        cv2.putText(frame, f"NPU FPS: {fps:.1f}", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 0, 0), 2)

        ret, buffer = cv2.imencode('.jpg', frame)
        with frame_lock:
            latest_frame = buffer.tobytes()

class CamHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'multipart/x-mixed-replace; boundary=--jpgboundary')
            self.end_headers()
            while True:
                with frame_lock:
                    if latest_frame is None:
                        time.sleep(0.1)
                        continue
                    frame_data = latest_frame
                try:
                    self.wfile.write(b"--jpgboundary\r\n")
                    self.send_header('Content-Type', 'image/jpeg')
                    self.send_header('Content-Length', str(len(frame_data)))
                    self.end_headers()
                    self.wfile.write(frame_data)
                    self.wfile.write(b"\r\n")
                except Exception:
                    break
                time.sleep(0.02)

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    pass

if __name__ == '__main__':
    args = parse_args()
    
    try:
        from tflite_runtime.interpreter import Interpreter, load_delegate
    except ImportError:
        from ai_edge_litert.interpreter import Interpreter, load_delegate

    t = threading.Thread(target=video_inference_thread, args=(args.source,), daemon=True)
    t.start()
    server = ThreadedHTTPServer(('0.0.0.0', 8000), CamHandler)
    print("Streaming live on http://<board-ip>:8000")
    server.serve_forever()
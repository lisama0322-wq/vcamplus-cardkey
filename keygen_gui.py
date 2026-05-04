"""VCamPlus 朋友卡密版 - 授权码生成工具 (Windows GUI)

打包成 exe:
  python -m PyInstaller --onefile --windowed --name VCamCardKeyGen --icon NONE keygen_gui.py
生成的 dist/VCamCardKeyGen.exe 可在 Win10/Win11 双击运行。
"""
import hashlib, hmac, secrets, time, os, sys
import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext

# 19 字节 SECRET (必须与 vcamplus-cardkey-src/Tweak.xm 内 _hmacSecret() 一致)
SECRET_HEX = "45e48b236d609e1da6adb8f1507512696055d5"
SECRET = bytes.fromhex(SECRET_HEX)

PLANS = [
    ("时卡 (1 小时)",  0),
    ("天卡 (24 小时)", 1),
    ("周卡 (7 天)",    2),
    ("月卡 (30 天)",   3),
    ("年卡 (365 天)",  4),
]
PLAN_HOURS = {0: 1, 1: 24, 2: 24*7, 3: 24*30, 4: 24*365}

ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

def b32_encode_10(data: bytes) -> str:
    bits = "".join(f"{b:08b}" for b in data)
    return "".join(ALPHA[int(bits[i:i+5], 2)] for i in range(0, 80, 5))

def make_key(plan_id: int) -> str:
    nonce = secrets.token_bytes(2)
    b0 = plan_id & 0x07
    msg = bytes([b0]) + nonce
    mac = hmac.new(SECRET, msg, hashlib.sha256).digest()[:7]
    raw = msg + mac
    s16 = b32_encode_10(raw)
    return "VCAM-" + "-".join(s16[i:i+4] for i in range(0, 16, 4))

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("VCamPlus 授权码生成工具")
        self.geometry("640x520")
        self.resizable(True, True)
        self._build_ui()

    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}

        top = ttk.LabelFrame(self, text=" 生成参数 ")
        top.pack(fill="x", padx=10, pady=8)

        ttk.Label(top, text="卡密类型:").grid(row=0, column=0, sticky="e", **pad)
        self.plan_var = tk.StringVar(value=PLANS[1][0])
        self.plan_cb = ttk.Combobox(top, textvariable=self.plan_var,
                                     values=[p[0] for p in PLANS],
                                     state="readonly", width=22)
        self.plan_cb.grid(row=0, column=1, sticky="w", **pad)

        ttk.Label(top, text="生成数量:").grid(row=1, column=0, sticky="e", **pad)
        self.count_var = tk.IntVar(value=10)
        self.count_sp = ttk.Spinbox(top, from_=1, to=500, textvariable=self.count_var, width=8)
        self.count_sp.grid(row=1, column=1, sticky="w", **pad)
        ttk.Label(top, text="(1 - 500)").grid(row=1, column=2, sticky="w", **pad)

        ttk.Label(top, text="备注:").grid(row=2, column=0, sticky="e", **pad)
        self.note_var = tk.StringVar()
        ttk.Entry(top, textvariable=self.note_var, width=42).grid(row=2, column=1, columnspan=2, sticky="we", **pad)

        btns = ttk.Frame(self)
        btns.pack(fill="x", padx=10, pady=4)
        ttk.Button(btns, text="生成", command=self.gen).pack(side="left", padx=4)
        ttk.Button(btns, text="复制全部", command=self.copy_all).pack(side="left", padx=4)
        ttk.Button(btns, text="保存到文件", command=self.save_file).pack(side="left", padx=4)
        ttk.Button(btns, text="清空", command=self.clear).pack(side="left", padx=4)
        self.status_var = tk.StringVar(value="就绪")
        ttk.Label(btns, textvariable=self.status_var, foreground="#666").pack(side="right", padx=4)

        out_frame = ttk.LabelFrame(self, text=" 生成结果 ")
        out_frame.pack(fill="both", expand=True, padx=10, pady=8)
        self.txt = scrolledtext.ScrolledText(out_frame, font=("Consolas", 12), wrap="none")
        self.txt.pack(fill="both", expand=True, padx=4, pady=4)

        ttk.Label(self, text=f"SECRET 指纹: {hashlib.sha256(SECRET).hexdigest()[:16]}  (与 dylib 一致才能通过校验)",
                  foreground="#888", font=("", 9)).pack(side="bottom", pady=4)

    def _selected_plan_id(self):
        for label, pid in PLANS:
            if label == self.plan_var.get():
                return pid
        return 1

    def gen(self):
        try:
            count = int(self.count_var.get())
        except Exception:
            messagebox.showerror("错误", "数量必须为整数")
            return
        if count < 1 or count > 500:
            messagebox.showerror("错误", "数量必须在 1 - 500 之间")
            return
        plan_id = self._selected_plan_id()
        plan_label = self.plan_var.get()
        note = self.note_var.get().strip()
        keys = [make_key(plan_id) for _ in range(count)]
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        header = f"# {ts}  类型={plan_label}  数量={count}  时长={PLAN_HOURS[plan_id]}h"
        if note: header += f"  备注={note}"
        self.txt.insert("end", header + "\n" + "\n".join(keys) + "\n\n")
        self.txt.see("end")
        self.status_var.set(f"已生成 {count} 张 {plan_label}")

    def copy_all(self):
        s = self.txt.get("1.0", "end").strip()
        if not s:
            self.status_var.set("没有内容可复制")
            return
        self.clipboard_clear()
        self.clipboard_append(s)
        self.update()
        self.status_var.set("已复制到剪贴板")

    def save_file(self):
        s = self.txt.get("1.0", "end").strip()
        if not s:
            messagebox.showwarning("提示", "没有内容可保存")
            return
        ts = time.strftime("%Y%m%d_%H%M%S")
        path = filedialog.asksaveasfilename(
            defaultextension=".txt",
            initialfile=f"vcamcards-{ts}.txt",
            filetypes=[("Text", "*.txt"), ("All", "*.*")])
        if not path: return
        try:
            with open(path, "w", encoding="utf-8") as f: f.write(s + "\n")
            self.status_var.set(f"已保存: {os.path.basename(path)}")
        except Exception as e:
            messagebox.showerror("保存失败", str(e))

    def clear(self):
        self.txt.delete("1.0", "end")
        self.status_var.set("已清空")

if __name__ == "__main__":
    App().mainloop()

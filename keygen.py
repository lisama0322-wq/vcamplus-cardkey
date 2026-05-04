"""VCamPlus 朋友卡密版 - 离线卡密生成 (路线 A，泛用卡密)

格式: VCAM-XXXX-XXXX-XXXX-XXXX  (16 字符 base32, RFC4648)

内部编码 (10 字节 = 80 bits):
  byte 0: low 3 bits = plan_id (0=hour 1=day 2=week 3=month 4=year)
          high 5 bits = 0 reserved
  bytes 1-2: 16-bit nonce (big-endian)
  bytes 3-9: 56-bit HMAC-SHA256(SECRET, byte0||nonce_be)[:7]

SECRET 必须与 vcamplus-cardkey-src/Tweak.xm 内 _hmacSecret() 完全一致。

CLI:
  python keygen.py gen <plan> <count> [--out file.txt]
  python keygen.py verify <key>
"""
import argparse, hashlib, hmac, secrets, sys, time
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    try: sys.stdout.reconfigure(encoding="utf-8")
    except Exception: pass

# 19 字节 SECRET (cardkey 版专用，与商业版/朋友版完全隔离)
SECRET_HEX = "45e48b236d609e1da6adb8f1507512696055d5"
SECRET = bytes.fromhex(SECRET_HEX)
assert len(SECRET) == 19

PLANS = {"hour": 0, "day": 1, "week": 2, "month": 3, "year": 4}
PLAN_NAMES = {v: k for k, v in PLANS.items()}
PLAN_HOURS = {0: 1, 1: 24, 2: 24*7, 3: 24*30, 4: 24*365}

ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"  # RFC 4648 base32

def b32_encode_10(data: bytes) -> str:
    assert len(data) == 10
    bits = "".join(f"{b:08b}" for b in data)
    return "".join(ALPHA[int(bits[i:i+5], 2)] for i in range(0, 80, 5))

def b32_decode_16(s: str) -> bytes:
    assert len(s) == 16
    bits = "".join(f"{ALPHA.index(c):05b}" for c in s)
    return bytes(int(bits[i:i+8], 2) for i in range(0, 80, 8))

def make_key(plan_id: int) -> str:
    nonce = secrets.token_bytes(2)
    b0 = plan_id & 0x07
    msg = bytes([b0]) + nonce
    mac = hmac.new(SECRET, msg, hashlib.sha256).digest()[:7]
    raw = msg + mac  # 10 bytes
    s16 = b32_encode_10(raw)
    return "VCAM-" + "-".join(s16[i:i+4] for i in range(0, 16, 4))

def verify_key(key: str):
    s = key.upper().replace("-", "")
    if not s.startswith("VCAM"):
        return None, "缺少 VCAM 前缀"
    body = s[4:]
    if len(body) != 16:
        return None, f"长度错误 (需 16 字符 + VCAM 前缀，实际 {len(body)})"
    try:
        raw = b32_decode_16(body)
    except Exception as e:
        return None, f"base32 解码失败: {e}"
    b0 = raw[0]
    plan_id = b0 & 0x07
    if plan_id not in PLAN_NAMES:
        return None, f"未知 plan_id={plan_id}"
    if b0 & 0xF8:
        return None, "reserved bits 非零"
    msg = raw[:3]
    mac = raw[3:]
    expect = hmac.new(SECRET, msg, hashlib.sha256).digest()[:7]
    if not hmac.compare_digest(mac, expect):
        return None, "MAC 校验失败"
    return plan_id, None

def cmd_gen(args):
    plan_id = PLANS[args.plan]
    keys = [make_key(plan_id) for _ in range(args.count)]
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(f"# vcamplus 朋友卡密版 plan={args.plan} count={args.count} time={int(time.time())}\n")
            f.write("\n".join(keys) + "\n")
        print(f"OK 生成 {args.count} 张 {args.plan} 卡 -> {args.out}")
    for k in keys:
        print(k)

def cmd_verify(args):
    plan_id, err = verify_key(args.key)
    if err:
        print(f"FAIL {err}")
        sys.exit(1)
    print(f"OK 有效卡密  plan={PLAN_NAMES[plan_id]}  时长={PLAN_HOURS[plan_id]}h")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    g = sp.add_parser("gen"); g.add_argument("plan", choices=PLANS.keys()); g.add_argument("count", type=int); g.add_argument("--out")
    g.set_defaults(func=cmd_gen)
    v = sp.add_parser("verify"); v.add_argument("key")
    v.set_defaults(func=cmd_verify)
    args = ap.parse_args()
    args.func(args)

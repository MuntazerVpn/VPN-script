#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os, re, json, uuid, html, secrets, string, subprocess, base64
from pathlib import Path
from datetime import datetime, timedelta
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ConversationHandler, MessageHandler, ContextTypes, filters

ENV = Path("/etc/aio-bot/.env")
BASE = Path("/etc/aio-bot")
XRAY = Path("/etc/xray/config.json")
SSH_DB = BASE / "ssh_users.json"
XRAY_DB = BASE / "xray_users.json"
QUOTA = BASE / "quota"
DOMAIN_FILE = Path("/etc/xray/domain")
BASE.mkdir(parents=True, exist_ok=True)
QUOTA.mkdir(parents=True, exist_ok=True)

if ENV.exists():
    for line in ENV.read_text(errors="ignore").splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            os.environ[k.strip()] = v.strip().strip('"').strip("'")

TOKEN = os.getenv("BOT_TOKEN", "").strip()
ADMINS = [int(x) for x in os.getenv("ADMIN_IDS", "").replace(" ", "").split(",") if x.isdigit()]
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
SSH_USER, SSH_PASS, SSH_DAYS, SSH_QUOTA, XRAY_NAME, XRAY_DAYS, EXT_DAYS, NEW_PASS = range(8)
SERVICES = ["ssh", "dropbear", "stunnel4", "nginx", "xray", "ssh-ws", "noobzvpns", "badvpn", "block-torrent", "aio-bot", "dnstt"]


def run(cmd, timeout=25):
    try:
        r = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
        return (r.stdout + r.stderr).strip() or "تم"
    except Exception as e:
        return f"خطأ: {e}"


def admin(update):
    return update.effective_user and update.effective_user.id in ADMINS


def admin_only(fn):
    async def wrap(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        if not admin(update):
            if update.effective_message:
                await update.effective_message.reply_text("🚫 غير مصرح")
            return ConversationHandler.END
        return await fn(update, ctx)
    return wrap


def jread(path, default):
    try:
        return json.loads(path.read_text(errors="ignore"))
    except Exception:
        return default


def jwrite(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    path.chmod(0o600)


def domain():
    if DOMAIN_FILE.exists() and DOMAIN_FILE.read_text().strip():
        return DOMAIN_FILE.read_text().strip()
    return run("hostname -I | awk '{print $1}'")


def valid_user(u):
    return bool(USER_RE.match(u)) and not u.startswith("-")


def user_exists(u):
    return subprocess.call(f"id {u} >/dev/null 2>&1", shell=True) == 0


def users():
    out = run("awk -F: '$3>=1000 && $1!=\"nobody\"{print $1}' /etc/passwd")
    return sorted([x.strip() for x in out.splitlines() if x.strip()])


def rnd(n=10):
    chars = string.ascii_letters + string.digits
    return "".join(secrets.choice(chars) for _ in range(n))


def qfile(u):
    return QUOTA / f"{u}.quota"


def write_quota(u, gb, exp):
    if gb <= 0:
        return
    qfile(u).write_text(f"USERNAME={u}\nLIMIT={int(gb*1024*1024*1024)}\nLIMIT_GB={gb:g}\nUSED=0\nEXPIRE={exp}\n")
    qfile(u).chmod(0o600)


def read_quota(u):
    f = qfile(u)
    d = {}
    if not f.exists():
        return d
    for line in f.read_text(errors="ignore").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


def human(n):
    try: n = float(n)
    except: n = 0
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024:
            return f"{n:.2f} {unit}"
        n /= 1024
    return f"{n:.2f} PB"


def menu_main():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("👤 حسابات SSH", callback_data="m_ssh"), InlineKeyboardButton("🧬 حسابات Xray", callback_data="m_xray")],
        [InlineKeyboardButton("📊 حالة السيرفر", callback_data="stats"), InlineKeyboardButton("⚙️ الخدمات", callback_data="services")],
        [InlineKeyboardButton("🧭 البورتات", callback_data="ports"), InlineKeyboardButton("🔌 المتصلين", callback_data="online")],
        [InlineKeyboardButton("🚫 حظر التورنت", callback_data="torrent_on"), InlineKeyboardButton("✅ رفع الحظر", callback_data="torrent_off")],
        [InlineKeyboardButton("🧹 تنظيف الكاش", callback_data="cache"), InlineKeyboardButton("♻️ إعادة تشغيل الكل", callback_data="restart_all")]
    ])


def menu_ssh():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("➕ إنشاء SSH", callback_data="ssh_create")],
        [InlineKeyboardButton("📋 قائمة SSH", callback_data="ssh_list"), InlineKeyboardButton("📶 الكوتا", callback_data="ssh_quota")],
        [InlineKeyboardButton("🔄 تمديد", callback_data="ssh_ext_menu"), InlineKeyboardButton("🔑 تغيير باسورد", callback_data="ssh_pass_menu")],
        [InlineKeyboardButton("🗑 حذف", callback_data="ssh_del_menu")],
        [InlineKeyboardButton("🔙 رجوع", callback_data="back")]
    ])


def menu_xray():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("➕ إنشاء Xray", callback_data="xray_create")],
        [InlineKeyboardButton("📋 قائمة Xray", callback_data="xray_list"), InlineKeyboardButton("🔗 الروابط", callback_data="xray_links_menu")],
        [InlineKeyboardButton("🗑 حذف Xray", callback_data="xray_del_menu"), InlineKeyboardButton("♻️ Restart Xray", callback_data="xray_restart")],
        [InlineKeyboardButton("🔙 رجوع", callback_data="back")]
    ])


@admin_only
async def start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await update.effective_message.reply_text("✅ أهلاً بك في لوحة تحكم السيرفر\nاختر من القائمة:", reply_markup=menu_main())


@admin_only
async def menus(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if q.data == "m_ssh":
        await q.edit_message_text("👤 إدارة حسابات SSH", reply_markup=menu_ssh())
    elif q.data == "m_xray":
        await q.edit_message_text("🧬 إدارة حسابات Xray", reply_markup=menu_xray())
    else:
        await q.edit_message_text("✅ القائمة الرئيسية", reply_markup=menu_main())


@admin_only
async def ssh_create(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    await q.edit_message_text("👤 أدخل اسم المستخدم:")
    return SSH_USER


async def ssh_user(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    u = update.message.text.strip()
    if not valid_user(u):
        await update.message.reply_text("❌ اسم غير صالح مثال user1")
        return SSH_USER
    if user_exists(u):
        await update.message.reply_text("⚠️ المستخدم موجود")
        return SSH_USER
    ctx.user_data["u"] = u
    await update.message.reply_text("🔑 أدخل كلمة المرور أو auto:")
    return SSH_PASS


async def ssh_pass(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    p = update.message.text.strip()
    if p.lower() == "auto":
        p = rnd()
    ctx.user_data["p"] = p
    await update.message.reply_text("📅 أدخل مدة الحساب بالأيام:")
    return SSH_DAYS


async def ssh_days(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    try:
        days = int(update.message.text.strip())
        assert 1 <= days <= 3650
    except Exception:
        await update.message.reply_text("❌ أدخل رقم من 1 إلى 3650")
        return SSH_DAYS
    ctx.user_data["days"] = days
    await update.message.reply_text("📶 أدخل الكوتا GB أو 0 بلا حد:")
    return SSH_QUOTA


async def ssh_quota_got(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    try:
        qgb = float(update.message.text.strip())
        assert qgb >= 0
    except Exception:
        await update.message.reply_text("❌ أدخل رقم صحيح")
        return SSH_QUOTA
    u, p, days = ctx.user_data["u"], ctx.user_data["p"], ctx.user_data["days"]
    exp = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
    out = run(f"useradd -M -s /usr/sbin/nologin -e {exp} {u} 2>&1")
    run(f"printf '%s:%s\\n' '{u}' '{p}' | chpasswd")
    write_quota(u, qgb, exp)
    db = jread(SSH_DB, {})
    db[u] = {"password": p, "expire": exp, "quota_gb": qgb}
    jwrite(SSH_DB, db)
    text = (
        "✅ تم إنشاء حساب SSH\n━━━━━━━━━━━━━━\n"
        f"👤 User: <code>{html.escape(u)}</code>\n🔑 Pass: <code>{html.escape(p)}</code>\n📅 Expire: <code>{exp}</code>\n"
        f"📶 Quota: <code>{'Unlimited' if qgb == 0 else str(qgb)+' GB'}</code>\n🌐 Host: <code>{html.escape(domain())}</code>\n"
        "SSH: <code>22 / 3303</code>\nDropbear: <code>69 / 109 / 111</code>\nSSL: <code>444 / 447 / 777</code>\nWS: <code>80 / 443 path /ssh</code>"
    )
    await update.message.reply_text(text, parse_mode="HTML")
    await update.message.reply_text("👤 إدارة حسابات SSH", reply_markup=menu_ssh())
    return ConversationHandler.END


@admin_only
async def ssh_list(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    us = users()
    lines = ["📋 حسابات SSH\n━━━━━━━━━━━━━━"]
    for u in us:
        exp = run(f"chage -l {u} 2>/dev/null | awk -F: '/Account expires/{{print $2}}'").strip()
        d = read_quota(u)
        qu = "♾ بلا حد" if not d else f"{human(d.get('USED','0'))}/{d.get('LIMIT_GB','?')}GB"
        lines.append(f"👤 {u} | 📅 {exp} | 📶 {qu}")
    await q.edit_message_text("\n".join(lines)[:3900] if us else "لا توجد حسابات", reply_markup=menu_ssh())


@admin_only
async def ssh_quota_list(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    lines = ["📶 الكوتا\n━━━━━━━━━━━━━━"]
    for u in users():
        d = read_quota(u)
        lines.append(f"👤 {u}: ♾ بلا حد" if not d else f"👤 {u}: {human(d.get('USED','0'))}/{d.get('LIMIT_GB','?')}GB")
    await q.edit_message_text("\n".join(lines)[:3900], reply_markup=menu_ssh())


@admin_only
async def ssh_del_menu(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    kb = [[InlineKeyboardButton(f"🗑 {u}", callback_data=f"ssh_del:{u}")] for u in users()]
    kb.append([InlineKeyboardButton("🔙 رجوع", callback_data="m_ssh")])
    await q.edit_message_text("اختر الحساب للحذف:", reply_markup=InlineKeyboardMarkup(kb))


@admin_only
async def ssh_del(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    u = q.data.split(":",1)[1]
    run(f"pkill -u {u} 2>/dev/null || true; userdel -r {u} 2>&1 || true")
    if qfile(u).exists():
        qfile(u).unlink()
    db = jread(SSH_DB, {})
    db.pop(u, None)
    jwrite(SSH_DB, db)
    await q.edit_message_text(f"🗑 تم حذف {u}", reply_markup=menu_ssh())


@admin_only
async def ssh_ext_menu(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    kb = [[InlineKeyboardButton(f"🔄 {u}", callback_data=f"ssh_ext:{u}")] for u in users()]
    kb.append([InlineKeyboardButton("🔙 رجوع", callback_data="m_ssh")])
    await q.edit_message_text("اختر الحساب:", reply_markup=InlineKeyboardMarkup(kb))


@admin_only
async def ssh_ext_pick(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    ctx.user_data["ext_user"] = q.data.split(":",1)[1]
    await q.edit_message_text("📅 أدخل عدد الأيام الجديدة من اليوم:")
    return EXT_DAYS


async def ssh_ext_days(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    try:
        days = int(update.message.text.strip())
    except:
        await update.message.reply_text("❌ رقم غير صحيح")
        return EXT_DAYS
    u = ctx.user_data["ext_user"]
    exp = (datetime.now()+timedelta(days=days)).strftime("%Y-%m-%d")
    run(f"usermod -e {exp} {u}")
    await update.message.reply_text(f"✅ تم تمديد {u} حتى {exp}")
    await update.message.reply_text("👤 إدارة حسابات SSH", reply_markup=menu_ssh())
    return ConversationHandler.END


@admin_only
async def ssh_pass_menu(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    kb = [[InlineKeyboardButton(f"🔑 {u}", callback_data=f"ssh_pass:{u}")] for u in users()]
    kb.append([InlineKeyboardButton("🔙 رجوع", callback_data="m_ssh")])
    await q.edit_message_text("اختر الحساب:", reply_markup=InlineKeyboardMarkup(kb))


@admin_only
async def ssh_pass_pick(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    ctx.user_data["pass_user"] = q.data.split(":",1)[1]
    await q.edit_message_text("🔑 أدخل كلمة المرور الجديدة أو auto:")
    return NEW_PASS


async def ssh_new_pass(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    p = update.message.text.strip()
    if p.lower() == "auto":
        p = rnd()
    u = ctx.user_data["pass_user"]
    run(f"printf '%s:%s\\n' '{u}' '{p}' | chpasswd")
    await update.message.reply_text(f"✅ تم تغيير كلمة المرور\n👤 {u}\n🔑 {p}")
    await update.message.reply_text("👤 إدارة حسابات SSH", reply_markup=menu_ssh())
    return ConversationHandler.END


def xcfg():
    return jread(XRAY, {"inbounds": [], "outbounds": [{"protocol":"freedom"}]})


def save_xcfg(c):
    XRAY.write_text(json.dumps(c, indent=2))
    run("systemctl restart xray", 40)


def add_xray(name, uid, pwd):
    c = xcfg()
    for ib in c.get("inbounds", []):
        tag = ib.get("tag", "")
        clients = ib.setdefault("settings", {}).setdefault("clients", [])
        if tag.startswith("vmess") and not any(x.get("email")==name for x in clients):
            clients.append({"id": uid, "alterId": 0, "email": name})
        if tag.startswith("vless") and not any(x.get("email")==name for x in clients):
            clients.append({"id": uid, "email": name, "flow": ""})
        if tag.startswith("trojan") and not any(x.get("email")==name for x in clients):
            clients.append({"password": pwd, "email": name})
    save_xcfg(c)


def del_xray(name):
    c = xcfg()
    for ib in c.get("inbounds", []):
        st = ib.get("settings", {})
        if "clients" in st:
            st["clients"] = [x for x in st["clients"] if x.get("email") != name]
    save_xcfg(c)


def xlinks(name, uid, pwd):
    d = domain()
    obj80 = {"v":"2","ps":f"{name}-vmess-80","add":d,"port":"80","id":uid,"aid":"0","net":"ws","type":"none","host":d,"path":"/vmess","tls":""}
    obj443 = dict(obj80); obj443["ps"]=f"{name}-vmess-443"; obj443["port"]="443"; obj443["tls"]="tls"
    vm80 = "vmess://" + base64.b64encode(json.dumps(obj80).encode()).decode()
    vm443 = "vmess://" + base64.b64encode(json.dumps(obj443).encode()).decode()
    vl80 = f"vless://{uid}@{d}:80?type=ws&security=none&host={d}&path=%2Fvless#{name}-vless-80"
    vl443 = f"vless://{uid}@{d}:443?type=ws&security=tls&host={d}&path=%2Fvless&sni={d}#{name}-vless-443"
    tr80 = f"trojan://{pwd}@{d}:80?type=ws&security=none&host={d}&path=%2Ftrojan#{name}-trojan-80"
    tr443 = f"trojan://{pwd}@{d}:443?type=ws&security=tls&host={d}&path=%2Ftrojan&sni={d}#{name}-trojan-443"
    return f"🧬 روابط {name}\n\nVMess 80:\n<code>{html.escape(vm80)}</code>\n\nVMess 443:\n<code>{html.escape(vm443)}</code>\n\nVLESS 80:\n<code>{html.escape(vl80)}</code>\n\nVLESS 443:\n<code>{html.escape(vl443)}</code>\n\nTrojan 80:\n<code>{html.escape(tr80)}</code>\n\nTrojan 443:\n<code>{html.escape(tr443)}</code>"


@admin_only
async def xray_create(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    await q.edit_message_text("🧬 أدخل اسم حساب Xray:")
    return XRAY_NAME


async def xray_name(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    n = update.message.text.strip()
    if not valid_user(n):
        await update.message.reply_text("❌ اسم غير صالح")
        return XRAY_NAME
    db = jread(XRAY_DB, {})
    if n in db:
        await update.message.reply_text("⚠️ موجود مسبقاً")
        return XRAY_NAME
    ctx.user_data["xname"] = n
    await update.message.reply_text("📅 أدخل مدة الحساب بالأيام:")
    return XRAY_DAYS


async def xray_days(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    try:
        days = int(update.message.text.strip())
    except:
        await update.message.reply_text("❌ رقم غير صحيح")
        return XRAY_DAYS
    n = ctx.user_data["xname"]
    uid = str(uuid.uuid4())
    pwd = rnd(16)
    exp = (datetime.now()+timedelta(days=days)).strftime("%Y-%m-%d")
    add_xray(n, uid, pwd)
    db = jread(XRAY_DB, {})
    db[n] = {"uuid": uid, "password": pwd, "expire": exp}
    jwrite(XRAY_DB, db)
    await update.message.reply_text(f"✅ تم إنشاء Xray\n📅 {exp}\n\n{xlinks(n,uid,pwd)}", parse_mode="HTML", disable_web_page_preview=True)
    await update.message.reply_text("🧬 إدارة حسابات Xray", reply_markup=menu_xray())
    return ConversationHandler.END


@admin_only
async def xray_list(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    db = jread(XRAY_DB, {})
    lines = ["📋 حسابات Xray\n━━━━━━━━━━━━━━"] + [f"🧬 {n} | 📅 {v.get('expire','N/A')}" for n,v in db.items()]
    await q.edit_message_text("\n".join(lines) if db else "لا توجد حسابات Xray", reply_markup=menu_xray())


@admin_only
async def xray_del_menu(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    db = jread(XRAY_DB, {})
    kb = [[InlineKeyboardButton(f"🗑 {n}", callback_data=f"xray_del:{n}")] for n in db]
    kb.append([InlineKeyboardButton("🔙 رجوع", callback_data="m_xray")])
    await q.edit_message_text("اختر الحساب للحذف:", reply_markup=InlineKeyboardMarkup(kb))


@admin_only
async def xray_del(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    n = q.data.split(":",1)[1]
    del_xray(n)
    db = jread(XRAY_DB, {}); db.pop(n, None); jwrite(XRAY_DB, db)
    await q.edit_message_text(f"🗑 تم حذف {n}", reply_markup=menu_xray())


@admin_only
async def xray_links_menu(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    db = jread(XRAY_DB, {})
    kb = [[InlineKeyboardButton(f"🔗 {n}", callback_data=f"xray_link:{n}")] for n in db]
    kb.append([InlineKeyboardButton("🔙 رجوع", callback_data="m_xray")])
    await q.edit_message_text("اختر الحساب:", reply_markup=InlineKeyboardMarkup(kb))


@admin_only
async def xray_link(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    n = q.data.split(":",1)[1]
    db = jread(XRAY_DB, {})
    v = db.get(n)
    if not v:
        await q.edit_message_text("غير موجود", reply_markup=menu_xray()); return
    await q.edit_message_text(xlinks(n, v["uuid"], v["password"])[:3900], parse_mode="HTML", reply_markup=menu_xray(), disable_web_page_preview=True)


@admin_only
async def xray_restart(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    out=run("systemctl restart xray; systemctl is-active xray")
    await q.edit_message_text("♻️ Xray: "+out, reply_markup=menu_xray())


@admin_only
async def stats(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    text = "📊 حالة السيرفر\n━━━━━━━━━━━━━━\n"
    text += "🌐 IP: " + run("hostname -I | awk '{print $1}'") + "\n"
    text += "🔗 Domain: " + domain() + "\n"
    text += "⚡ CPU: " + run("top -bn1 | grep 'Cpu(s)' | awk '{print $2+$4 \"%\"}'") + "\n"
    text += "💾 RAM: " + run("free -h | awk '/^Mem:/{print $3\"/\"$2}'") + "\n"
    text += "💿 Disk: " + run("df -h / | awk 'NR==2{print $3\"/\"$2\" \"$5}'") + "\n"
    text += "⏱ Uptime: " + run("uptime -p")
    await q.edit_message_text(text, reply_markup=menu_main())


@admin_only
async def services(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    lines=["⚙️ الخدمات\n━━━━━━━━━━━━━━"]
    for s in SERVICES:
        st = run(f"systemctl is-active {s} 2>/dev/null || true")
        lines.append(("🟢" if st=="active" else "🔴") + f" {s}: {st}")
    await q.edit_message_text("\n".join(lines), reply_markup=menu_main())


@admin_only
async def ports(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    await q.edit_message_text("🧭 البورتات\n━━━━━━━━━━━━━━\nV2Ray/Xray: 80 / 443\nVMess: /vmess\nVLESS: /vless\nTrojan: /trojan\nSSH: 22 / 3303\nDropbear: 69 / 109 / 111\nSSL: 444 / 447 / 777\nSSH WS: /ssh على 80/443\nSlowDNS: 5300 UDP\nNoobzVPN: 8080 / 8443\nBadVPN: 7300 UDP", reply_markup=menu_main())


@admin_only
async def online(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    await q.edit_message_text("🔌 المتصلين\n"+run("who; echo; ss -tn state established | head -30")[:3500], reply_markup=menu_main())


@admin_only
async def torrent_on(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    await q.edit_message_text("🚫 "+run("/usr/local/sbin/block-torrent apply 2>&1 || systemctl start block-torrent 2>&1")[:1000], reply_markup=menu_main())


@admin_only
async def torrent_off(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    await q.edit_message_text("✅ "+run("/usr/local/sbin/block-torrent remove 2>&1 || systemctl stop block-torrent 2>&1")[:1000], reply_markup=menu_main())


@admin_only
async def cache(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    await q.edit_message_text("🧹 "+run("sync; echo 3 > /proc/sys/vm/drop_caches; echo done"), reply_markup=menu_main())


@admin_only
async def restart_all(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q=update.callback_query; await q.answer()
    run("systemctl restart ssh dropbear stunnel4 nginx xray ssh-ws noobzvpns badvpn block-torrent 2>/dev/null || true", 60)
    await services(update, ctx)


async def cancel(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await update.effective_message.reply_text("تم الإلغاء", reply_markup=menu_main())
    return ConversationHandler.END


def main():
    if not TOKEN:
        raise SystemExit("BOT_TOKEN missing")
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("cancel", cancel))
    app.add_handler(ConversationHandler(
        entry_points=[CallbackQueryHandler(ssh_create, pattern="^ssh_create$")],
        states={SSH_USER:[MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_user)], SSH_PASS:[MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_pass)], SSH_DAYS:[MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_days)], SSH_QUOTA:[MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_quota_got)]},
        fallbacks=[CommandHandler("cancel", cancel), CommandHandler("start", start)], allow_reentry=True))
    app.add_handler(ConversationHandler(
        entry_points=[CallbackQueryHandler(xray_create, pattern="^xray_create$")],
        states={XRAY_NAME:[MessageHandler(filters.TEXT & ~filters.COMMAND, xray_name)], XRAY_DAYS:[MessageHandler(filters.TEXT & ~filters.COMMAND, xray_days)]},
        fallbacks=[CommandHandler("cancel", cancel), CommandHandler("start", start)], allow_reentry=True))
    app.add_handler(ConversationHandler(
        entry_points=[CallbackQueryHandler(ssh_ext_pick, pattern="^ssh_ext:")],
        states={EXT_DAYS:[MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_ext_days)]},
        fallbacks=[CommandHandler("cancel", cancel), CommandHandler("start", start)], allow_reentry=True))
    app.add_handler(ConversationHandler(
        entry_points=[CallbackQueryHandler(ssh_pass_pick, pattern="^ssh_pass:")],
        states={NEW_PASS:[MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_new_pass)]},
        fallbacks=[CommandHandler("cancel", cancel), CommandHandler("start", start)], allow_reentry=True))
    handlers = [
        (menus, "^(m_ssh|m_xray|back)$"), (ssh_list, "^ssh_list$"), (ssh_quota_list, "^ssh_quota$"),
        (ssh_del_menu, "^ssh_del_menu$"), (ssh_del, "^ssh_del:"), (ssh_ext_menu, "^ssh_ext_menu$"),
        (ssh_pass_menu, "^ssh_pass_menu$"), (xray_list, "^xray_list$"), (xray_del_menu, "^xray_del_menu$"),
        (xray_del, "^xray_del:"), (xray_links_menu, "^xray_links_menu$"), (xray_link, "^xray_link:"),
        (xray_restart, "^xray_restart$"), (stats, "^stats$"), (services, "^services$"), (ports, "^ports$"),
        (online, "^online$"), (torrent_on, "^torrent_on$"), (torrent_off, "^torrent_off$"),
        (cache, "^cache$"), (restart_all, "^restart_all$")
    ]
    for fn, pat in handlers:
        app.add_handler(CallbackQueryHandler(fn, pattern=pat))
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()

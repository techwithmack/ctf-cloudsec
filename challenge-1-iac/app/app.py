import os

from flask import Flask

app = Flask(__name__)

TEAM_ID = os.environ.get("TEAM_ID", "unknown")
TARGET_BUCKET_URL = os.environ.get("TARGET_BUCKET_URL", "")


@app.route("/")
def portal():
    return f"""<!DOCTYPE html>
<html>
<head>
<title>Meridian Systems - Developer Portal</title>
<style>
  :root {{ color-scheme: light; }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #f4f5f7;
    color: #1c2126;
  }}
  header {{
    background: #14181f;
    color: #fff;
    padding: 14px 28px;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }}
  header .brand {{ font-weight: 600; font-size: 15px; letter-spacing: .2px; }}
  header nav a {{
    color: #b7c0cc;
    text-decoration: none;
    margin-left: 22px;
    font-size: 13px;
  }}
  header nav a:hover {{ color: #fff; }}
  .banner {{
    background: #fff6e5;
    border-bottom: 1px solid #f0dca3;
    color: #7a5b00;
    padding: 8px 28px;
    font-size: 13px;
  }}
  main {{ max-width: 960px; margin: 32px auto; padding: 0 24px; }}
  h1 {{ font-size: 20px; margin-bottom: 2px; }}
  .subtitle {{ color: #5a6472; font-size: 13px; margin-top: 0; margin-bottom: 28px; }}
  .grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 16px;
  }}
  .card {{
    background: #fff;
    border: 1px solid #e4e7eb;
    border-radius: 8px;
    padding: 16px 18px;
  }}
  .card h3 {{ margin: 0 0 8px; font-size: 14px; }}
  .status {{ display: inline-flex; align-items: center; font-size: 12px; color: #2a7a3b; }}
  .dot {{ width: 7px; height: 7px; border-radius: 50%; background: #2fa84a; margin-right: 6px; display: inline-block; }}
  .card p {{ margin: 6px 0 0; font-size: 12px; color: #6b7280; }}
  footer {{ text-align: center; color: #9aa2ad; font-size: 12px; margin: 40px 0 20px; }}
</style>
</head>
<body>
<header>
  <div class="brand">Meridian Systems &middot; Developer Portal</div>
  <nav>
    <a href="#">Dashboard</a>
    <a href="#">Services</a>
    <a href="#">Runbooks</a>
    <a href="#">Support</a>
  </nav>
</header>
<div class="banner">This portal is mid-migration to the new internal platform. Some links may be broken - report issues in #platform-eng.</div>
<main>
  <h1>Welcome, {TEAM_ID}</h1>
  <p class="subtitle">Engineering workspace overview</p>
  <div class="grid">
    <div class="card">
      <h3>Auth Service</h3>
      <span class="status"><span class="dot"></span>Operational</span>
      <p>Handles SSO and session tokens.</p>
    </div>
    <div class="card">
      <h3>Billing API</h3>
      <span class="status"><span class="dot"></span>Operational</span>
      <p>Internal usage metering.</p>
    </div>
    <div class="card">
      <h3>Data Pipeline</h3>
      <span class="status"><span class="dot"></span>Operational</span>
      <p>Nightly ETL and reporting jobs.</p>
    </div>
    <div class="card">
      <h3>Storage Ops</h3>
      <span class="status"><span class="dot"></span>Operational</span>
      <p>Backup scheduling and archival.</p>
      <!-- TODO: remove before prod - forgotten backup bucket still wired up here: {TARGET_BUCKET_URL} -->
    </div>
  </div>
</main>
<footer>Meridian Systems Internal Tools &middot; not for external distribution</footer>
</body>
</html>
"""


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)

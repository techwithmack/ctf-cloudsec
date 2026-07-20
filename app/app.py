import os

from flask import Flask

app = Flask(__name__)

TEAM_ID = os.environ.get("TEAM_ID", "unknown")
TARGET_BUCKET_URL = os.environ.get("TARGET_BUCKET_URL", "")


@app.route("/")
def portal():
    return f"""<!DOCTYPE html>
<html>
<head><title>Aikido Internal Developer Portal</title></head>
<body>
<h1>Aikido Internal Developer Portal</h1>
<p>Welcome, engineering team {TEAM_ID}. This portal is under active migration.</p>
<p>Please report any broken links to #platform-eng.</p>
<!-- TODO: remove before prod - forgotten backup bucket still wired up here: {TARGET_BUCKET_URL} -->
</body>
</html>
"""


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
